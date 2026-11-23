#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-23)
# covers: apps/workbench/templates/brimstone_stunts/** builtin/kit/types/controls.lua builtin/kit/client_lua/controls.lua util/kit_racer_drive.py
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
# Screenshots, kept with KEEP_TMP=1: $t/lobby.png, $t/lap_*.png, $t/trial.png
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
# The Bone Yard's line (util/kit_racer_check.sh's: the generator's output is
# Brimstone's)
export PATH_PTS="-100,-58,12 60,-58,10 60,-34,10 10,-34,9 0,-14,9 30,0,10 95,0,12 95,55,12 50,55,9 40,30,8 25,30,8 15,58,10 -40,58,12 -55,20,10 -30,5,9 -60,-10,10 -100,-20,12"

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
SHOTS="-40,-58,$t/lap_1_start.png 60,-58,$t/lap_2_u_bend.png 10,-34,$t/lap_3_chicane.png 95,0,$t/lap_4_east.png 95,55,$t/lap_5_ne.png 15,58,$t/lap_6_north.png -55,20,$t/lap_7_west.png -100,-20,$t/lap_8_last.png" \
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
for f in lap_1_start lap_2_u_bend lap_3_chicane lap_4_east lap_5_ne lap_6_north lap_7_west lap_8_last; do
	[ -f "$t/$f.png" ] || fail "no screenshot $t/$f.png ($t/drive.log)"
done
cmd "quit"
echo "PASS: Brimstone Stunts from its template: its types, a time trial's lap in the chase camera behind the car, following its heading; screenshots $t/lobby.png $t/lap_*.png $t/trial.png"
# vim: set noet ts=4 sw=4:
