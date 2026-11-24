#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-24)
# covers: builtin/kit/client_lua/controls.lua builtin/kit/client_lua/module.lua builtin/kit/client_lua/move.lua
# [KIT_ENT_PERF] (kit_plan 4z37zzl) A client drawing 100 moving units of 5 parts
# each (a unit's root and 4 kit/parts under it): 2 groups, each a unit steered
# round a circle of 1.5 m by a check type (a steered movement: the client draws
# it on its track) and 49 more units under it, on a Workbench save of the
# check's own, one client on a headless weston's Xwayland:
#   - Kit's own ms a frame (update_play: the moving nodes placed, the looks
#     drawn; "event kit_looks") under a bound;
#   - each look drawn where the server's movement has it, by this script's own
#     sums (nothing of move.lua's): a group's root on its circle, facing along
#     it (the type's yaw); each unit under it and each part at its parent's
#     place and turn applied to its own offset, turned as its parent; the
#     groups moving between samples.
# simplified: 2 movements the server steps, not 100: with 500 entities in the
# world alpha.70's box fits some 4 in a step's budget, and one past it is
# stopped for good (4z37zzk's item). The client's work is its 500 moving
# nodes'; it reckons a link's turn once a frame, not each node's.
#   util/kit_ent_client_perf_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
N=100
check_tmp kit_ent_client_perf; t=$CHECK_TMP
cd "$here/Build"
check_build
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1 SDL_AUDIODRIVER=dummy
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_WORKBENCH_TYPES=$t/user/apps/workbench/check_types
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
# Round a circle of 1.5 m from where it starts (centre 1.5 m to its -x), at
# 3 m/s, facing along it
cat > "$BUILDAT_WORKBENCH_TYPES/ent_mover.lua" <<'EOF'
return {
	version = 1,
	about = {what = "A check's unit: round a small circle."},
	component = true,
	movement = {body = {r = 0.5, h = 1}, steered = true},
	params = {},
	step = function(s, i, dt, w, p)
		local pos = type(s.pos) == "table" and s.pos or {0, 0, 0}
		if type(s.home) ~= "table" then
			s.home = {pos[1], pos[2], pos[3]}
			s.a = 0
		end
		local R = 1.5
		local a = ((tonumber(s.a) or 0) + 3 / R * dt) % (2 * w.PI)
		s.a = a
		s.pos = {s.home[1] + R * w.cos(a) - R, s.home[2], s.home[3] + R * w.sin(a)}
		s.yaw = (-a * 180 / w.PI) % 360
		s.vel = {0, 0, 0}
	end,
}
EOF

# The save, made by a first start; the units written into it
start_server "$t/srv0.log" "Hosted: |Not hosted: " 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv0.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
db=$t/user/apps/workbench/saves/world/save.sqlite
[ -f "$db" ] || fail "no save ($t/user)"
# Unit i: entity 10 + 5 i, its parts the 4 after it; each fiftieth a group's
# root, the 49 after it under it. "$t/units": id parent x y z (the root's in
# the world, the others' in their parent)
python3 -I - "$db" "$N" > "$t/units" <<'PY' || fail "the rows ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
n = int(sys.argv[2])
ents = [{"id": 2, "parent": 1, "name": "world", "kind": "scene"},
	{"id": 3, "parent": 2, "name": "start", "pos": [0, 21, -40],
		"components": [{"type": "kit/spawner", "params": {"players": True}}]},
	{"id": 4, "parent": 2, "name": "platform", "pos": [0, 20, -40],
		"components": [{"type": "kit/part", "params": {"size": [1.5, 1, 1.5]}}]}]
def part(size, color):
	return {"type": "kit/part", "params": {"size": size, "color": color, "collision": False}}
PARTS = [([0.8, 0.4, 0.8], [0, 0.5, 0], "#c03030"), ([0.2, 0.2, 1.0], [0, 0.5, 0.8], "#404040"),
	([0.3, 0.5, 1.9], [0.7, -0.1, 0], "#303030"), ([0.3, 0.5, 1.9], [-0.7, -0.1, 0], "#303030")]
ROOTS = [(-14, -8), (14, -8)]
UNDER = [(dx, 0, dz) for dz in range(0, 13, 3) for dx in range(-12, 16, 3) if dx or dz]
for i in range(n):
	u = 10 + 5 * i
	if i % 50 == 0:
		x, z = ROOTS[i // 50]
		g, pos = u, [x, 1, z]
		ents.append({"id": u, "parent": 2, "name": "unit %d" % i, "pos": pos,
			"components": [part([1.4, 0.6, 1.8], "#3060c0"), {"type": "workbench/ent_mover"}]})
		print(u, 2, *pos)
	else:
		pos = list(UNDER[i % 50 - 1])
		ents.append({"id": u, "parent": g, "name": "unit %d" % i, "pos": pos,
			"components": [part([1.4, 0.6, 1.8], "#3060c0")]})
		print(u, g, *pos)
	for k, (size, off, col) in enumerate(PARTS):
		ents.append({"id": u + 1 + k, "parent": u, "name": "p%d_%d" % (i, k), "pos": off,
			"components": [part(size, col)]})
def put(k, v):
	db.execute("insert or replace into store (store, key, value) values (?, ?, ?)",
		("kit", k, json.dumps(v).encode()))
put("authored", {"kit": 1, "api": 1, "next_id": 10 + 5 * n, "entities": ents})
put("session", {"by": "", "restore": [], "round": [], "running": True})
db.execute("delete from store where store = ? and key = ?", ("kit", "runtime"))
db.commit()
PY

sock=bentcl-$$
XDG_RUNTIME_DIR=/run/user/$(id -u) weston --backend=headless --renderer=pixman \
	--xwayland --socket=$sock --width=1100 --height=800 --idle-time=0 \
	> "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
d=
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"

SL=$t/srv.log
start_server "$SL" "Hosted: |Not hosted: " 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($SL)"
grep -aq "Not hosted: " "$SL" && fail "not hosted ($SL)"
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
CL=$t/c1.log
mkfifo "$t/c1.cmd"
sleep 900 > "$t/c1.cmd" &
CHECK_PIDS+=($!)
env DISPLAY="$d" WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitboss \
	BUILDAT_JOIN_CODE="$code" "BUILDAT_JOIN_ADMIN=setting open_registration on" \
	bin/buildat -C "$t/cc1" -D "$t/cu1" -s localhost:$SERVER_PORT -w 640x400 -l 3 \
	-o sound_mute=1,vsync=0 -c - < "$t/c1.cmd" > "$CL" 2>&1 &
CHECK_PIDS+=($!)
wait_for_log "$CL" "Joined as kitboss" 120 || fail "the client did not join ($CL, $SL)"
wait_for_log "$CL" "admin script: done" 30 || fail "the admin script ($CL)"
ids=$(awk '{ for (k = 0; k < 5; k++) printf "%d ", $1 + k }' "$t/units")
# The units' looks there, Kit's ms over 200 frames, then the looks where
# drawn: three samples 30 frames apart
{
	echo 'wait_log_any 30000 server window: the page ntfy'
	echo 'frames 3'
	echo 'click Button "Don*"'
	echo 'max_fps 1000'
	echo 'wait_log 60000 player physics enabled'
	echo 'event kit_face 0 40'
	echo 'frames 120'
	echo 'event kit_looks'
	echo 'frames 200'
	echo 'event kit_looks'
	for k in 1 2 3; do
		echo "event kit_look_where $ids"
		echo 'frames 30'
	done
	echo "screenshot $t/units.png"
} > "$t/c1.cmd"
wait_for_log "$CL" "Wrote screenshot" 300 || fail "the drive did not finish ($CL)"
grep -a "error shown in a dialog" "$CL" && fail "a script error ($CL)"

python3 -I - "$CL" "$t/units" "$N" <<'PY'
import math, re, sys
log = open(sys.argv[1], errors="replace").read()
n = int(sys.argv[3])
units = [l.split() for l in open(sys.argv[2])]
bad = []
# Kit's ms a frame: the second ask's (200 frames)
looks = re.findall(r"kit: looks: (\d+) frames, [0-9.]+ read a frame of ([0-9.]+), ([0-9.]+) ms a frame; "
	r"frames ([0-9.]+) ms", log)
if len(looks) < 2:
	sys.exit("FAIL: no kit: looks lines")
frames, nlooks, ms, frame = int(looks[1][0]), float(looks[1][1]), float(looks[1][2]), float(looks[1][3])
print("%d frames: %.0f looks, Kit %.2f ms a frame, a frame %.1f ms" % (frames, nlooks, ms, frame))
if nlooks < 5 * n:
	bad.append("%.0f looks, not %d" % (nlooks, 5 * n))
# LIMIT: here (llvmpipe, beside other work) 4z37zzl read 20 ms, alpha.70 140
LIMIT = 45
if ms > LIMIT:
	bad.append("Kit's %.2f ms a frame over %d" % (ms, LIMIT))
def rot(q, v):
	w, x, y, z = q
	vx, vy, vz = v
	# q v q^-1
	tx, ty, tz = 2 * (y * vz - z * vy), 2 * (z * vx - x * vz), 2 * (x * vy - y * vx)
	return (vx + w * tx + y * tz - z * ty, vy + w * ty + z * tx - x * tz,
		vz + w * tz + x * ty - y * tx)
OFF = [(0, 0.5, 0), (0, 0.5, 0.8), (0.7, -0.1, 0), (-0.7, -0.1, 0)]
samples = []
for l in re.findall(r"kit: looks where: (.*)", log):
	s = {}
	for part in l.split("; "):
		f = part.split()
		if len(f) == 3:
			p = tuple(float(v) for v in f[1].split(","))
			q = tuple(float(v) for v in f[2].split(","))
			s[int(f[0])] = (p, q)
	samples.append(s)
if len(samples) < 3:
	sys.exit("FAIL: %d look samples" % len(samples))
worst_r = worst_face = worst_part = worst_turn = 0
# (on its parent: the parent's place and turn applied to its offset)
def on(s, child, parent, off):
	global worst_part, worst_turn
	c, (p, q) = s.get(child), s[parent]
	if not c:
		bad.append("entity %d not drawn" % child)
		return
	o = rot(q, off)
	worst_part = max(worst_part, math.dist((p[0] + o[0], p[1] + o[1], p[2] + o[2]), c[0]))
	worst_turn = max(worst_turn, 1 - abs(sum(a * b for a, b in zip(q, c[1]))))
roots = [u for u in units if u[1] == "2"]
for s in samples:
	for u, parent, x, y, z in units:
		u, x, y, z = int(u), float(x), float(y), float(z)
		if u not in s:
			bad.append("unit %d not drawn" % u)
			continue
		p, q = s[u]
		if parent == "2":
			cx, cz = x - 1.5, z
			r = math.hypot(p[0] - cx, p[2] - cz)
			worst_r = max(worst_r, abs(r - 1.5))
			a = math.atan2(p[2] - cz, p[0] - cx)
			fx, _, fz = rot(q, (0, 0, 1))
			face = math.degrees(math.acos(max(-1, min(1, (-math.sin(a) * fx + math.cos(a) * fz) /
				max(1e-9, math.hypot(fx, fz))))))
			worst_face = max(worst_face, face)
		elif int(parent) in s:
			on(s, u, int(parent), (x, y, z))
		for k, off in enumerate(OFF):
			on(s, u + 1 + k, u, off)
moved = sum(1 for u in roots if int(u[0]) in samples[0] and int(u[0]) in samples[-1] and
	math.dist(samples[0][int(u[0])][0], samples[-1][int(u[0])][0]) > 0.05)
print("%d samples: off the circle %.4f m, facing off its way %.2f deg, a unit or part off "
	"its place %.5f m, off its turn %.2g; %d of %d groups moved" % (len(samples), worst_r,
	worst_face, worst_part, worst_turn, moved, len(roots)))
# (a track's step between keys cuts the circle, an extrapolated one leaves it
# by its tangent; the parts are the root's to the float)
if worst_r > 0.2:
	bad.append("a unit %.3f m off its circle" % worst_r)
if worst_face > 20:
	bad.append("a unit facing %.1f deg off its way" % worst_face)
if worst_part > 0.002:
	bad.append("a part %.4f m off its place on the unit" % worst_part)
if worst_turn > 1e-6:
	bad.append("a part turned other than its unit (%.2g)" % worst_turn)
if moved < len(roots):
	bad.append("%d of %d groups moved" % (moved, len(roots)))
for b in bad[:20]:
	print("over: " + b)
sys.exit(1 if bad else 0)
PY
verdict_keep
[ "$verdict_rc" = 0 ] || fail "the units' draw (above; $t)"
echo "PASS: $N moving units of 5 parts drawn where their movement has them, Kit within its bound"
