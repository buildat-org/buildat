#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-23)
# covers: apps/workbench/templates/brimstone_stunts/** builtin/kit/types/controls.lua builtin/kit/client_lua/controls.lua builtin/kit/client_lua/move.lua builtin/kit/types/path.lua util/kit_racer_drive.py
# [KIT_STUNTS] (kit_plan 4z37zzd (1)) The Brimstone Stunts template (Brimstone
# Speedway's fork in kit/controls' chase camera) on Workbench; one server,
# kitboss on a headless weston's Xwayland of the check's own:
#   1. New from it: its types local/stunt_*, the camera chase, the car's draw
#      hook; the lobby (lobby.png);
#   2. a time trial's lap (trial_laps 1) driven round the Bone Yard's centre
#      line by util/kit_racer_drive.py: checkpoints 1-3 and the lap; at each
#      body sample the camera behind the car along the way the camera
#      faces, near the chase's distance and above the car, its yaw following
#      the car's (never far off, on it once straight); screenshots round the
#      lap (lap_*.png) and the result card (trial.png).
#   3. [KIT_STUNTS] (4z37zzd (2)) The heights, from the same samples and the
#      template's own polygons (the trial scene's generator's): off each
#      tabletop jump's lip the car over 0.4 m above its floor (the floor as
#      the car finds it: the highest top edge at most 0.6 over it, the road
#      0.555), then on it again; at the figure eight's crossing (the bridge)
#      the car once on the deck (y 5.055) and once under it (0.555), nowhere
#      between, not slowed there (no wall of the other level met); the
#      camera never inside a height's prism (w:ray meets them: under the deck
#      it comes in under the roof).
# Screenshots, kept with KEEP_TMP=1: $t/lobby.png, $t/lap_*.png (the start,
# the bridge's ramp, its deck, the east, a jump in the air and landed, under
# the bridge, the second jump, the last straight), $t/trial.png
#   util/kit_stunts_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_stunts; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
check_build

# The trial's race and the controls' distance (the template's)
python3 -I - "$here/apps/workbench/templates/brimstone_stunts/composition.json" \
		> "$t/ids" <<'PY' || fail "the template's composition"
import json, sys
d = json.load(open(sys.argv[1]))
scene = {e["name"]: e["id"] for e in d["entities"] if e.get("kind") == "scene"}
trial = [e["id"] for e in d["entities"] if e.get("name") == "the race" and
         e.get("parent") == scene["trial"]][0]
ctl = [c["params"] for e in d["entities"] for c in e.get("components", [])
       if c["type"] == "kit/controls"][0]
assert ctl["camera"] == "chase" and ctl["chase_follow"] > 0, ctl
print("TRIAL=%d DIST=%s" % (trial, ctl["distance"]))
PY
. "$t/ids"
# The Bone Yard's line: stunt_yard's default corners (a figure eight)
export PATH_PTS="-100,10,16 100,10,16 100,68,16 0,68,14 0,-68,14 -100,-68,16"

sock=buildat-stunts-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
SL=$t/srv.log CL=$t/boss.log CLIENT=
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL, $CL)"
}
cmd() { printf '%s\n' "$@" >&3; }
step() # <seconds> <regex in the client's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$CL")
	cmd "$@"
	await "$CL" "$m" "$s" "$re"
}
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate 1 || fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
grep -aq "workbench: the template in .*brimstone_stunts" "$SL" && fail "the template refused ($SL)"
mkfifo "$t/boss.cmd"
sleep 600 > "$t/boss.cmd" &
CHECK_PIDS+=($!)
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 SDL_AUDIODRIVER=dummy BUILDAT_JOIN_NAME=kitboss \
	BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 BUILDAT_JOIN_ADMIN="setting open_registration on" \
	timeout 400 bin/buildat -C "$t/client_cache" -D "$t/cu" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
	< "$t/boss.cmd" > "$CL" 2>&1 &
CLIENT=$!
CHECK_PIDS+=($CLIENT)
exec 3> "$t/boss.cmd"
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don*"'

# 1. New from the template: its types, the chase camera, the car drawn
await "$CL" 0 30 "world_menu: the list shown"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New game..."'
cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked" 'click Text "Brimstone Stunts"'
step 120 "kit editor: edit mode on" "frames 3" 'click Button "Create"'
for re in "The template's type local/stunt_car \([0-9]+ bytes\)" "The template's type local/stunt_race " \
		"The template's type local/stunt_mine " "The template's type local/stunt_weapons " \
		"The template's type local/stunt_yard "; do
	grep -aqE "$re" "$SL" || fail "no \"$re\" in $SL"
done
step 10 "entities, 1 to undo" "event kit_edit {\"op\": \"set\", \"id\": $TRIAL, \"comp\": 0, \"param\": \"trial_laps\", \"value\": 1}"
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
await "$CL" 0 10 "kit: controls: camera chase, pointer cursor, movement local/stunt_car, plane y 1"
await "$CL" 0 10 "stunt_car: the draw hook draws a car"
await "$CL" 0 10 'kit: ui [0-9]+ list .* shown, layer [0-9]+: "Pick your poison \| Race: The Bone Yard, by buildat \| Time trial: The Bone Yard, by buildat"'
step 10 "Wrote screenshot $t/lobby.png" "frames 10" "screenshot $t/lobby.png"
echo "ok: a game from Brimstone Stunts: its local/stunt_* types, the chase camera, the car's draw hook, the lobby"

# 2. The trial's lap in the chase view
m=$(mark "$SL")
step 10 "kit: ui full screen none" "frames 3" 'click Button "Time trial: The*"'
await "$SL" "$m" 10 "local/stunt_race $TRIAL: kitboss starts a time trial"
mc=$(mark "$CL")
SHOTS_IN_ORDER=1 SHOTS="-100,-10,$t/lap_1_start.png -30,10,$t/lap_2_ramp.png -3,10,$t/lap_3_deck.png 100,39,$t/lap_4_east.png 53,68,$t/lap_5_jump.png 30,68,$t/lap_6_landed.png 0,10,$t/lap_7_under.png -42,-68,$t/lap_8_jump2.png -100,-40,$t/lap_9_last.png" \
	python3 -I "$here/util/kit_racer_drive.py" "$CL" "$t/boss.cmd" 150 \
	'panel .* shown, layer [0-9]+: "The flag is down' > "$t/drive.log" 2>&1 ||
	fail "the driver: $(tail -2 "$t/drive.log")"
step 10 "Wrote screenshot $t/trial.png" "frames 10" "screenshot $t/trial.png"
python3 -I - "$SL" "$m" "$TRIAL" <<'PY' || fail "the trial's lap ($SL)"
import re, sys
s = open(sys.argv[1], "rb").read()[int(sys.argv[2]):].decode(errors="replace")
race = "local/stunt_race %s: kitboss " % sys.argv[3]
order = [l.split(race, 1)[1] for l in s.splitlines() if race in l]
lap = [i for i, l in enumerate(order) if l.startswith("lap 1 in")]
cp = [i for i, l in enumerate(order) if l.startswith("passed checkpoint")]
assert len(lap) == 1 and len(cp) == 3 and max(cp) < lap[0], order
assert any(l.startswith("finished the trial in") for l in order), order
print("ok: the trial: %s" % "; ".join(order[1:]))
PY
# Each sample (event kit_body: the body, the camera's place and the chase's
# yaw in turn): the camera behind the body along its own yaw, near the
# distance (a wall between shortens it; smoothing and the drawn place lag
# the step's a little) and above it; the yaw following the car's
python3 -I - "$CL" "$mc" "$DIST" <<'PY' || fail "the chase camera ($CL)"
import math, re, sys
s = open(sys.argv[1], "rb").read()[int(sys.argv[2]):].decode(errors="replace")
dist = float(sys.argv[3])
S, b, c = [], None, None
for l in s.splitlines():
    m = re.search(r"kit: body at (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+),", l)
    if m:
        b, c = tuple(map(float, m.groups())), None
    m = re.search(r"kit: camera at (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+) ", l)
    if m:
        c = tuple(map(float, m.groups()))
    m = re.search(r"kit: chase yaw (-?[0-9.]+), the body's (-?[0-9.]+)", l)
    if m and b and c:
        S.append((b, c, float(m[1]), float(m[2])))
        b = c = None
def off(a, b):
    return abs((a - b + 540) % 360 - 180)
assert len(S) > 100, len(S)
bad = []
for (bx, by, bz), (cx, cy, cz), cyaw, byaw in S:
    fx, fz = math.sin(math.radians(cyaw)), math.cos(math.radians(cyaw))
    back = -((cx - bx) * fx + (cz - bz) * fz)
    side = abs((cx - bx) * fz - (cz - bz) * fx)
    if not (1 < back < dist + 3 and side < 3 and 0.5 < cy - by < 5):
        bad.append((round(back, 1), round(side, 1), round(cy - by, 1)))
assert len(bad) <= len(S) // 20, "not behind the car: %d of %d: %r" % (len(bad), len(S), bad[:10])
most = max(off(cy, by) for _, _, cy, by in S)
assert most < 45, "the camera %.0f degrees off the car" % most
yaws = [by for _, _, _, by in S]
turned = sum(off(yaws[i], yaws[i - 1]) for i in range(1, len(yaws)))
assert turned > 300, turned
backs = sorted(-((c[0] - b[0]) * math.sin(math.radians(cy)) + (c[2] - b[2]) * math.cos(math.radians(cy)))
               for b, c, cy, _ in S)
print("ok: the chase camera over %d samples: behind the car %.1f m (median; %d off), "
      "its yaw at most %.0f deg off the car's through %.0f deg of turns" %
      (len(S), backs[len(backs) // 2], len(bad), most, turned))
PY
# 3. The heights: the jumps, the bridge over and under, the camera out of them
python3 -I - "$CL" "$mc" "$here/apps/workbench/templates/brimstone_stunts/composition.json" <<'PY' ||
import json, math, re, sys
s = open(sys.argv[1], "rb").read()[int(sys.argv[2]):].decode(errors="replace")
d = json.load(open(sys.argv[3]))
scene = {e["name"]: e["id"] for e in d["entities"] if e.get("kind") == "scene"}
gen = [e["id"] for e in d["entities"] if e.get("parent") == scene["trial"] and
       e["components"][0]["type"] == "local/stunt_yard"][0]
# The standing polygons (no pitch): their outline in the world's x, y, z0...z1
polys = []
for e in d["entities"]:
    c = e["components"][0] if e.get("parent") == gen else {}
    if c.get("type") == "kit/polygon" and not e.get("pitch"):
        x, y, z = e["pos"]
        h = c["params"]["depth"] / 2
        polys.append((e["name"], [(x + a, y + b) for a, b in c["params"]["points"]], z - h, z + h))
assert sum(1 for p in polys if p[0] == "the bridge") == 1, [p[0] for p in polys]
jumps = [p for p in polys if p[0] == "a tabletop jump"]
assert len(jumps) >= 2, [p[0] for p in polys]
def floor(x, y, z):
    """The car's floor: the highest top edge (going +x: the generator writes
    the outline clockwise) at most 0.6 over y, else the road's top"""
    best = 0.555
    for _, pts, z0, z1 in polys:
        if not z0 < z < z1:
            continue
        for (ax, ay), (bx, by) in zip(pts, pts[1:] + pts[:1]):
            if ax < bx and ax <= x <= bx:
                t = ay + (by - ay) * (x - ax) / (bx - ax)
                if t <= y + 0.6:
                    best = max(best, t)
    return best
def inside(x, y, z):
    for name, pts, z0, z1 in polys:
        if z0 < z < z1:
            c = False
            for (ax, ay), (bx, by) in zip(pts, pts[1:] + pts[:1]):
                if (ay > y) != (by > y) and x < ax + (bx - ax) * (y - ay) / (by - ay):
                    c = not c
            if c:
                return name
S, b, c = [], None, None
for l in s.splitlines():
    m = re.search(r"kit: body at (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+),", l)
    if m:
        b, c = tuple(map(float, m.groups())), None
    m = re.search(r"kit: camera at (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+) ", l)
    if m:
        c = tuple(map(float, m.groups()))
    m = re.search(r"kit: vehicle speed (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+),", l)
    if m and b and c:
        S.append((b, c, math.hypot(float(m[1]), float(m[3]))))
        b = c = None
assert len(S) > 100, len(S)
# The jumps: over each one's span, some sample 0.4 m over the floor, a later
# one on it
for name, pts, z0, z1 in jumps:
    xs = [p[0] for p in pts]
    on = [(bx, by - floor(bx, by, bz)) for (bx, by, bz), _, _ in S
          if min(xs) - 15 < bx < max(xs) and z0 < bz < z1]
    up = [i for i, (_, h) in enumerate(on) if h > 0.4]
    assert up and any(abs(h) < 0.05 for _, h in on[up[-1]:]), (name, xs[0], on)
    print("ok: the jump at x %.0f...%.0f: %d samples, %.2f m over the floor at most, landed" %
          (min(xs), max(xs), len(on), max(h for _, h in on)))
# The crossing: on the deck, under it
cross = [(by, v) for (bx, by, bz), _, v in S if abs(bx) < 8 and 4 < bz < 16]
over = [v for y, v in cross if abs(y - 5.055) < 0.06]
under = [v for y, v in cross if abs(y - 0.555) < 0.06]
assert over and under and len(over) + len(under) == len(cross), cross
assert min(over + under) > 8, cross
print("ok: the bridge: %d samples on its deck (y 5.055), %d under it (y 0.555), none between, "
      "at %.1f m/s at least" % (len(over), len(under), min(over + under)))
bad = [(b, c, inside(*c)) for b, c, _ in S if inside(*c)]
assert not bad, bad[:5]
cu = [c for (bx, by, bz), c, _ in S if abs(bx) < 8 and 4 < bz < 16 and by < 1]
print("ok: the camera out of every height's prism over %d samples (under the deck: at y %s)" %
      (len(S), ", ".join("%.2f" % c[1] for c in cu)))
PY
	fail "the heights ($CL)"
for f in lap_1_start lap_2_ramp lap_3_deck lap_4_east lap_5_jump lap_6_landed lap_7_under lap_8_jump2 lap_9_last; do
	[ -f "$t/$f.png" ] || fail "no screenshot $t/$f.png ($t/drive.log)"
done
cmd "quit"
echo "PASS: Brimstone Stunts from its template: its types, a time trial's lap in the chase camera behind the car, following its heading, over two jumps and the bridge and under it; screenshots $t/lobby.png $t/lap_*.png $t/trial.png"
# vim: set noet ts=4 sw=4:
