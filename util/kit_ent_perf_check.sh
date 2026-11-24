#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-24)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/types/unit_walker.lua
# [KIT_ENT_PERF] (kit_plan 4z37zzk, doc/plan/kit_rts_perf.md) The server's
# cost of many entities, on one Workbench server at a time (three in turn)
# with one scripted client on a headless weston's Xwayland of the check's
# own, no sound:
#   - units 100 and 200: each a kit/part (collision off), kit/unit_walker
#     (movement.native = "path": stepped in C++) and workbench/ent_unit
#     (below): two sides, ordered 20 m along x and back every 8 s (all at
#     once: a mass re-path), each firing kit/bow (c:fire) at the nearest
#     of the other side's units every second; kit/health with hit points
#     no shot takes;
#   - static 1000: 200 kit/parts with collision, each with 4 more
#     (collision off) under it, round the spawn, the client walking among
#     them (its body stepped each input: P1's snapshot of the solid looks).
# Measured over 10 s once the client is in (Kit's BUILDAT_KIT_METER lines
# and their phases, the client's socket by ss). Asserted:
#   - units: no drive or body past its budget, half of the units arrived
#     at an order, shots hit with hit.unit given; Kit's tick and the bytes
#     a second a moving unit sends a client under LIMITS;
#   - static: the player's steps (step_bodies a tick) and the box's share
#     of a tick under LIMITS, no body past its budget.
#   util/kit_ent_perf_check.sh
#   ENT_CASES="units:100" util/kit_ent_perf_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
command -v ss > /dev/null || skip "no ss"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
CASES=${ENT_CASES:-units:100 units:200 static:200}
check_tmp kit_ent_perf; t=$CHECK_TMP
cd "$here/Build"
check_build
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1 SDL_AUDIODRIVER=dummy
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_WORKBENCH_TYPES=$t/user/apps/workbench/check_types
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
# A unit: an order 20 m along x and back each 8 s; a shot each second at the
# nearest unit of the other side (z < 0 one side, z >= 0 the other: the orders
# are along x); each hit logs its unit
cat > "$BUILDAT_WORKBENCH_TYPES/ent_unit.lua" <<'EOF'
return {
	version = 1,
	about = {what = "A check's RTS unit: ordered to and fro, firing at the other side."},
	component = true,
	creature = true,
	nearby = 14,
	state = {n = {default = 0}, home = {default = false}},
	on_start = function(c)
		c.state.home = c.pos
		c:after(1, "order")
		c:after(1 + c.id % 10 / 10, "fire")
	end,
	on_timer = function(c, name)
		if name == "fire" then
			for _, n in ipairs(c.nearby or {}) do
				if not n.player and (n.pos[3] < 0) ~= (c.pos[3] < 0) then
					c:fire({item = "kit/bow", at = {n.pos[1], n.pos[2], n.pos[3]}})
					break
				end
			end
			c:after(1, "fire")
			return
		end
		local h = c.state.home or c.pos
		c.state.n = c.state.n + 1
		c:propose_move({to = {h[1] + c.state.n % 2 * 20, h[2], h[3]}, range = 0.5})
		c:after(8, "order")
	end,
	modify_hit = function(c, hit, by)
		if hit.unit then
			c:log("hit by unit " .. hit.unit)
		end
	end,
}
EOF

start_server "$t/srv0.log" "Hosted: |Not hosted: " 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv0.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
db=$t/user/apps/workbench/saves/world/save.sqlite
[ -f "$db" ] || fail "no save ($t/user)"
# The rows of a case: units (10 columns 2.5 m apart along x, rows 2.5 m
# apart along z, a side at z < 0 and one beyond), static (17 x 17 3.5 m apart)
rows() # <kind> <n>
{
	python3 -I - "$db" "$1" "$2" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
kind, n = sys.argv[2], int(sys.argv[3])
ents = [{"id": 2, "parent": 1, "name": "world", "kind": "scene"},
	{"id": 3, "parent": 2, "name": "start", "pos": [0, 1, 0],
		"components": [{"type": "kit/spawner", "params": {"players": True}}]}]
def part(size, color, solid):
	return {"type": "kit/part", "params": {"size": size, "color": color, "collision": solid}}
if kind == "units":
	xs = [-28 + 2.5 * i for i in range(10)]
	zs = [-28 + 2.5 * i for i in range(23)]
else:
	xs = zs = [-28 + 3.5 * i for i in range(17)]
cells = [(x, z) for z in zs for x in xs if abs(x) > 3 or abs(z) > 3]
assert len(cells) >= n, (len(cells), n)
CHILD = [([0.8, 0.4, 0.8], [0, 0.5, 0]), ([0.2, 0.2, 1.0], [0, 0.5, 0.8]),
	([0.3, 0.5, 1.9], [0.7, -0.1, 0]), ([0.3, 0.5, 1.9], [-0.7, -0.1, 0])]
nid = 10
for i in range(n):
	x, z = cells[i]
	uid = nid
	nid += 1
	if kind == "units":
		ents.append({"id": uid, "parent": 2, "name": "u%d" % i, "pos": [x, 1, z],
			"components": [part([0.8, 0.6, 0.8], "#3060c0", False), {"type": "kit/unit_walker"},
				{"type": "workbench/ent_unit"},
				{"type": "kit/health", "params": {"max": 1000000}}]})
		continue
	ents.append({"id": uid, "parent": 2, "name": "s%d" % i, "pos": [x, 1, z],
		"components": [part([1.4, 0.6, 1.8], "#3060c0", True)]})
	for size, off in CHILD:
		ents.append({"id": nid, "parent": uid, "name": "p%d" % nid, "pos": off,
			"components": [part(size, "#404040", False)]})
		nid += 1
def put(k, v):
	db.execute("insert or replace into store (store, key, value) values (?, ?, ?)",
		("kit", k, json.dumps(v).encode()))
put("authored", {"kit": 1, "api": 1, "next_id": nid, "entities": ents})
put("session", {"by": "", "restore": [], "round": [], "running": True})
db.execute("delete from store where store = ? and key = ?", ("kit", "runtime"))
db.commit()
PY
}
# "<pid> <bytes received>" of each client's socket to the server
rx()
{
	ss -Htinp state established "( dport = :$SERVER_PORT )" 2>/dev/null |
		python3 -I -c 'import re, sys
for m in re.finditer(r"pid=(\d+).*?bytes_received:(\d+)", sys.stdin.read(), re.S):
	print(m.group(1), m.group(2))'
}
lines() { grep -ac "$2" "$1" 2>/dev/null; }
await_n() # <log> <regex> <n> <seconds>
{
	local i
	for i in $(seq $(($4 * 5))); do
		[ "$(lines "$1" "$2")" -ge "$3" ] && return 0
		kill -0 "$SERVER_PID" 2>/dev/null || fail "the server is gone ($1)"
		sleep 0.2
	done
	fail "no $3 lines \"$2\" in $1 in $4 s"
}

sock=bentperf-$$
XDG_RUNTIME_DIR=/run/user/$(id -u) weston --backend=headless --renderer=pixman \
	--xwayland --socket=$sock --width=800 --height=600 --idle-time=0 \
	> "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
d=
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"

: > "$t/table"
for case in $CASES; do
	kind=${case%%:*} N=${case#*:}
	# [CHECK_MEMORY] 2 GB over the server's ~300 MB and the client's ~450 MB
	avail=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
	[ "$avail" -ge $((2048 + 750)) ] || fail "$avail MB free before $case, 2.8 GB wanted"
	u=$t/$kind$N
	mkdir -p "$u"
	rows "$kind" "$N" || fail "the rows ($db)"
	SL=$u/srv.log
	BUILDAT_KIT_METER=1 start_server "$SL" "Hosted: |Not hosted: " 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
		fail "the server did not come up ($SL)"
	SRV=$SERVER_PID
	grep -aq "Not hosted: " "$SL" && fail "not hosted ($SL)"
	code= extra=()
	if [ ! -e "$t/admin_made" ]; then
		wait_for_log "$SL" "setup code [A-Z0-9]+" 30
		code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
		[ -n "$code" ] || fail "no setup code ($SL)"
		extra=(BUILDAT_JOIN_CODE="$code")
	fi
	mkfifo "$u/c1.cmd"
	sleep 900 > "$u/c1.cmd" &
	FEED=$!
	CHECK_PIDS+=($FEED)
	env DISPLAY="$d" WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=entperf \
		"${extra[@]}" bin/buildat -C "$t/cc" -D "$t/cu" -s localhost:$SERVER_PORT \
		-w 480x300 -l 3 -o sound_mute=1 -c - < "$u/c1.cmd" > "$u/c1.log" 2>&1 &
	CL=$!
	CHECK_PIDS+=($CL)
	wait_for_log "$u/c1.log" "Joined as entperf" 120 || fail "the client did not join ($u/c1.log, $SL)"
	# (the admin's first join, by the setup code: a dialog over the view)
	if [ -n "$code" ]; then
		touch "$t/admin_made"
		echo 'wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don*"' > "$u/c1.cmd"
	fi
	wait_for_log "$u/c1.log" "player physics enabled" 60 || fail "no body ($u/c1.log)"
	# (static: it walks among the parts, to and fro)
	if [ "$kind" = static ]; then
		for i in $(seq 60); do
			printf 'keydown w\ndelay 1000\nkeyup w\nkeydown s\ndelay 1000\nkeyup s\n'
		done > "$u/c1.cmd" &
		CHECK_PIDS+=($!)
	fi
	m0=$(lines "$SL" "kit *: meter:")
	await_n "$SL" "kit *: meter:" $((m0 + 2)) 30
	rx > "$u/rx0"
	s0=$(date +%s%N)
	a0=$(lines "$SL" ": arrived")
	await_n "$SL" "kit *: meter:" $((m0 + 4)) 30
	rx > "$u/rx1"
	s1=$(date +%s%N)
	a1=$(lines "$SL" ": arrived")
	python3 -I - "$u" "$kind" "$N" "$s0" "$s1" "$m0" "$((a1 - a0))" \
			<<'PY' >> "$t/table" || fail "the measures ($u)"
import re, sys
u, kind, n, s0, s1, m0, arrived = sys.argv[1:]
log = open(u + "/srv.log", errors="replace").read()
m = re.findall(r"meter: \d+ ticks in [0-9.]+ s, gap ([0-9.]+)/([0-9.]+) ms, "
	r"Kit's tick ([0-9.]+)/([0-9.]+) ms, the box ([0-9.]+)/([0-9.]+) %", log)[int(m0) + 2:int(m0) + 4]
ph = re.findall(r"phases: ms a tick: (.*)", log)[int(m0) + 2:int(m0) + 4]
bodies = [float(re.search(r"step_bodies ([0-9.]+)", p).group(1)) for p in ph]
w = [[float(x) for x in r] for r in m]
dt = (int(s1) - int(s0)) / 1e9
a = dict(l.split() for l in open(u + "/rx0"))
z = dict(l.split() for l in open(u + "/rx1"))
rate = [(int(z[p]) - int(a[p])) / dt for p in z if p in a][0]
past = len(set(re.findall(r"Entity (\d+)'s \S+: past its budget", log))) + \
	len(set(re.findall(r"(\S+)'s body \([^)]*\): .*past its budget", log)))
hits = len(re.findall(r"Entity \d+ hits entity \d+ with kit/bow", log))
units = len(re.findall(r"hit by unit \d+", log))
print("%s %s %.1f %.1f %.1f %.2f %.0f %d %s %d %d" % (kind, n, sum(r[2] for r in w) / len(w),
	max(r[3] for r in w), sum(r[4] for r in w) / len(w), sum(bodies) / len(bodies), rate,
	past, arrived, hits, units))
PY
	echo quit > "$u/c1.cmd"
	kill "$FEED" 2>/dev/null
	wait "$CL" 2>/dev/null
	kill -INT "$SRV" 2>/dev/null
	wait "$SRV" 2>/dev/null
done

python3 -I - "$t/table" <<'PY'
import sys
print("case | Kit's tick mean/worst ms | the box % | player steps ms a tick | "
	"bytes/s to the client | past budget | arrived | shots hit (hit.unit seen)")
for l in open(sys.argv[1]):
	f = l.split()
	print("%s %s | %s/%s | %s | %s | %s | %s | %s | %s (%s)" % tuple(f))
PY
check_slow
python3 -I - "$t/table" "$CHECK_SLOW" <<'PY'
import sys
slow = float(sys.argv[2])
# LIMITS, from the desk's (2026-11-24, CHECK_SLOW 1.2): units 100/200 Kit's
# tick 9/18 ms (a third of it the units' timers in the box), worst 36/51 (an
# order's re-path), ~510 bytes/s a moving unit; static 1000 the player's steps
# 7 ms a tick, the box 5 %. The times about 1.7x over them by CHECK_SLOW, the
# box and the bytes not (the game's own units). Before [KIT_ENT_PERF] 100
# walking kit/creature_walkers read 57 ms (the tick past its budget, every
# drive disabled at once) and a moving unit 2 kB/s.
bad = []
for l in open(sys.argv[1]):
	kind, n, tick, worst, box, bodies, rate, past, arrived, hits, units = l.split()
	n = int(n)
	if int(past):
		bad.append("%s %d: %s past their budget" % (kind, n, past))
	if kind == "units":
		L = {"tick": 0.15 * n * slow, "worst": (0.3 * n + 40) * slow, "bytes": 700 * n + 10000}
		if float(tick) > L["tick"]:
			bad.append("units %d: Kit's tick %s ms over %.0f" % (n, tick, L["tick"]))
		if float(worst) > L["worst"]:
			bad.append("units %d: its worst tick %s ms over %.0f" % (n, worst, L["worst"]))
		if float(rate) > L["bytes"]:
			bad.append("units %d: %s bytes/s to the client over %d" % (n, rate, L["bytes"]))
		if int(arrived) < n / 2:
			bad.append("units %d: %s arrived" % (n, arrived))
		if not int(hits) or not int(units):
			bad.append("units %d: %s shots hit, %s with hit.unit" % (n, hits, units))
	else:
		L = {"bodies": 10 * slow, "box": 15}
		if float(bodies) > L["bodies"]:
			bad.append("static %d: the player's steps %s ms a tick over %.1f" % (n, bodies, L["bodies"]))
		if float(box) > L["box"]:
			bad.append("static %d: the box %s %% of a tick's budget over %d" % (n, box, L["box"]))
	print("limits at %s %d: %s" % (kind, n, ", ".join("%s %.0f" % kv for kv in sorted(L.items()))))
for b in bad:
	print("over: " + b)
sys.exit(1 if bad else 0)
PY
verdict_keep
[ "$verdict_rc" = 0 ] || fail "past the limits (the table above; $t)"
echo "PASS: 100 and 200 native units walking and firing, 1000 static entities round a player, within the limits"
