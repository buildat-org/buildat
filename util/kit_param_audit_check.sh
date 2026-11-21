#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-21)
# covers: apps/workbench/templates/brimstone_speedway/** builtin/kit/client_lua/controls.lua builtin/kit/types/controls.lua builtin/kit/types/environment.lua builtin/kit/client_lua/environment.lua builtin/kit/types/terrain.lua builtin/kit/kit.cpp builtin/kit/terrain.h
# [KIT_PARAM_AUDIT] (doc/kit_param_audit.txt) A builder's simple changes to
# Brimstone Speedway (new from its template on Workbench, one server,
# kitboss on a headless weston's Xwayland of the check's own) do what he
# would expect in play:
#   1. the trial's trial_laps 2: its HUD reads "Lap 1/2";
#   2. kit/controls' camera first_person alone (the template's chase_follow
#      0.3): through the U of corners 2 and 3 the eye's yaw follows the
#      car's (east, then west), looking level (fp_east.png, fp_west.png);
#   3. a kit/environment placed (time 8, its default inherit: fast_physical, no
#      shadows) and then lighting physical, the view top_down and the car
#      still: the walls' shadows on the ground, darker than its sunlit rest
#      and bluer (the sky's light alone) (env_fast.png, env_phys.png);
#   4. the trial's ground flat to noise: the World generated anew, hills
#      over a flat ground, its look changed (noise.png); [KIT_TERRAIN_FLATTEN]
#      flat round the track's parts: the client's ground along the racing
#      line where the flat one had it (not over the road, nor under it),
#      over 2 m off it on 8 or more of a 16 m grid over the map, and the car
#      driven on from the U bend to the east straight;
#   4b. [KIT_LIGHTING_SCENE] the root's environment's lighting inherit (the
#      default) drawn fast_physical; under the root's cartoon a kit/environment
#      placed on the trial with lighting physical draws the trial physical,
#      the lobby (scene world) cartoon, and the trial physical again;
#   5. every one of those undone: the composition exactly as it was.
#   util/kit_param_audit_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
python3 -c "import PIL" 2>/dev/null || skip "no python3 PIL"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_param_audit; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
check_build

python3 -I - "$here/apps/workbench/templates/brimstone_speedway/composition.json" \
		> "$t/ids" <<'PY' || fail "the template's composition"
import json, sys
d = json.load(open(sys.argv[1]))
E = d["entities"]
scene = {e["name"]: e["id"] for e in E if e.get("kind") == "scene"}
def typed(t, s=None):
    return [e["id"] for e in E if any(c["type"] == t for c in e.get("components", []))
            and (s is None or e.get("parent") == scene[s])]
print("TRIAL=%d CONTROLS=%d GROUND=%d" % ([e["id"] for e in E if e.get("name") == "the race"
      and e.get("parent") == scene["trial"]][0], typed("kit/controls")[0],
      typed("kit/terrain", "trial")[0]))
# (the trial's racing line, on the road: every sixth point, in the world)
yard = [e["id"] for e in E if e.get("parent") == scene["trial"] and
        any(c["type"] == "local/brim_yard" for c in e.get("components", []))][0]
line = [e for e in E if e.get("parent") == yard and e.get("name") == "the racing line"][0]
o = line["pos"]
print("ROAD='%s'" % " ".join("%.2f,%.2f" % (o[0] + p[0], o[2] + p[1])
      for p in line["components"][0]["params"]["points"][::6]))
PY
. "$t/ids"
export PATH_PTS="-100,-58,12 60,-58,10 60,-34,10 10,-34,9 0,-14,9 30,0,10 95,0,12 95,55,12 50,55,9 40,30,8 25,30,8 15,58,10 -40,58,12 -55,20,10 -30,5,9 -60,-10,10 -100,-20,12"

sock=buildat-param-audit-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
SL=$t/srv.log CL=$t/boss.log
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $BOSS 2>/dev/null || fail "the client is gone ($CL)"
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
n=0
edit() # <json>: an edit, one more to undo
{
	n=$((n + 1))
	step 10 "entities, $n to undo" "event kit_edit $1"
}
set_p() { edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
shot() { step 40 "Wrote screenshot $t/$1" "frames ${2:-10}" "screenshot $t/$1"; }
# The authored composition (the save's row, written within a second of an
# edit and at once by a stop) into <file>; with <same>: waited for until
# its entities are <same>'s
authored() # <file> [same]
{
	local i
	for i in $(seq 20); do
		python3 -I - "$t/user/apps/workbench/saves/game/save.sqlite" "$@" 2>/dev/null <<'PY' && return 0
import json, sqlite3, sys
db = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
r = db.execute("select value from store where store='kit' and key='authored'").fetchone()
assert r
a = json.loads(r[0])
json.dump(a, open(sys.argv[2], "w"), sort_keys=True, indent=1)
if len(sys.argv) > 3:
    # (next_id is not undone: an id once given is never given again)
    assert a["entities"] == json.load(open(sys.argv[3]))["entities"]
PY
		sleep 0.5
	done
	return 1
}
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate 1 || fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
mkfifo "$t/boss.cmd"
sleep 900 > "$t/boss.cmd" &
CHECK_PIDS+=($!)
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 SDL_AUDIODRIVER=dummy BUILDAT_JOIN_NAME=kitboss \
	BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	timeout 600 bin/buildat -C "$t/client_cache" -D "$t/cu" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -o lighting=game -c - \
	< "$t/boss.cmd" > "$CL" 2>&1 &
BOSS=$!
CHECK_PIDS+=($BOSS)
exec 3> "$t/boss.cmd"
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don*"'
await "$CL" 0 30 "world_menu: the list shown"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New game..."'
cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked" 'click Text "Brimstone Speedway"'
step 120 "kit editor: edit mode on" "frames 3" 'click Button "Create"'
authored "$t/authored0.json" || fail "no authored composition ($t/user)"

# 1, 2. trial_laps 2 and camera first_person; the trial through the U bend
mc=$(mark "$CL")
set_p $TRIAL trial_laps 2
set_p $CONTROLS camera '"first_person"'
step 10 "the server is Running" 'event kit_edit {"op": "play"}'
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
await "$CL" "$mc" 10 "kit: controls: camera first_person, pointer [a-z]+, movement local/brim_car"
m=$(mark "$SL")
step 10 "kit: ui full screen none" "frames 3" 'click Button "Time trial: The*"'
await "$SL" "$m" 10 "local/brim_race $TRIAL: kitboss starts a time trial"
await "$CL" "$mc" 10 'shown: "Lap 1/2 '
echo "ok: trial_laps 2: the HUD reads \"Lap 1/2\""
mc=$(mark "$CL")
SHOTS="30,-58,$t/fp_east.png 35,-34,$t/fp_west.png" \
	python3 -I "$here/util/kit_racer_drive.py" "$CL" "$t/boss.cmd" 30 \
	'kit: body at (1[5-9]|2[0-9])\.[0-9]+,-?[0-9.]+,-3[0-9]\.' > "$t/drive.log" 2>&1
step 5 "kit: chase yaw" "frames 3" "event kit_body"
python3 -I - "$CL" "$mc" <<'PY' || fail "the first-person eye's yaw ($CL, $t/drive.log)"
import re, sys
s = open(sys.argv[1], "rb").read().decode(errors="replace")[int(sys.argv[2]):]
D = [(float(m[1]), float(m[2])) for m in re.finditer(
    r"kit: chase yaw (-?[0-9.]+), the body's (-?[0-9.]+)", s)]
def off(a, b):
    return abs((a - b + 540) % 360 - 180)
# (as kit_racer's chase camera: east first, west last, never far behind)
assert len(D) > 20, len(D)
assert off(D[0][1], 90) < 20 and off(D[-1][1], 270) < 20, (D[0], D[-1])
most = max(off(c, b) for c, b in D)
assert most < 45 and off(D[-1][0], D[-1][1]) < 4, (most, D[-1])
print("ok: first_person followed the car from %.0f to %.0f degrees, at most %.0f off" %
      (D[0][0], D[-1][0], most))
PY

# 3. kit/environment: fast_physical, then physical; the car still, top_down
step 10 "kit editor: edit mode on" "frames 3" "keypress F6"
m=$(mark "$SL")
edit '{"op": "place", "type": "kit/environment", "on": "root", "pos": [0, 0, 0]}'
ENV=$(tail -c +$((m + 1)) "$SL" | grep -aoP "An edit by kitboss: placed kit/environment \K[0-9]+" | tail -1)
[ -n "$ENV" ] || fail "no kit/environment placed ($SL)"
set_p $ENV time 8
set_p $CONTROLS camera '"top_down"'
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
step 30 "kit: body at" "frames 60" "event kit_body"
shot env_fast.png 30
step 10 "kit editor: edit mode on" "frames 3" "keypress F6"
mc=$(mark "$CL")
set_p $ENV lighting '"physical"'
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
await "$CL" "$mc" 20 "kit: lighting physical"
shot env_phys.png 60
python3 -I - "$t/env_fast.png" "$t/env_phys.png" <<'PY' || fail "physical's shadows ($t/env_fast.png, $t/env_phys.png)"
import sys
from PIL import Image
A, B = (Image.open(f).convert("RGB") for f in sys.argv[1:])
w, h = A.size
# (the HUD's text off: the top 70 rows, the bottom 30)
px = [(A.getpixel((x, y)), B.getpixel((x, y))) for y in range(70, h - 30, 3)
      for x in range(0, w, 3)]
lum = lambda p: p[0] + p[1] + p[2]
r = sorted((lum(b) + 3) / (lum(a) + 3) for a, b in px)
med = r[len(r) // 2]
shade = [b for a, b in px if (lum(b) + 3) / (lum(a) + 3) < 0.7 * med]
lit = [b for a, b in px if (lum(b) + 3) / (lum(a) + 3) >= 0.9 * med]
br = lambda ps: sum(p[2] for p in ps) / max(1, sum(p[0] for p in ps))
ml = lambda ps: sum(map(lum, ps)) / max(1, len(ps)) / 3
f = len(shade) / len(px)
print("shade %.1f %% of the view, %.0f bright, b/r %.2f; lit %.0f, b/r %.2f" %
      (100 * f, ml(shade), br(shade), ml(lit), br(lit)))
assert f > 0.01 and ml(shade) < 0.75 * ml(lit) and br(shade) > br(lit) + 0.08
PY
echo "ok: kit/environment physical: shadows, darker and bluer than the sunlit ground"

# 4. The trial's ground flat to noise; the client's ground along the racing
# line and on a grid over the map (every 16 m) on each: its log's offset
GRID=$(for z in $(seq -72 16 72); do for x in $(seq -104 16 104); do printf '%s,%s ' $x $z; done; done)
ground() # <var>: set to the log's offset
{
	printf -v "$1" %s "$(mark "$CL")"
	cmd "event kit_ground $ROAD $GRID" "frames 3"
	await "$CL" "${!1}" 10 "kit: ground at 104,72 "
}
ground mf
step 10 "kit editor: edit mode on" "frames 3" "keypress F6"
m=$(mark "$SL")
set_p $GROUND generator '"noise"'
await "$SL" "$m" 60 "World by kitboss: noise "
g=$(tail -c +$((m + 1)) "$SL" | grep -aoP "World by kitboss: noise .*ground \K-?[0-9]+ to -?[0-9]+" | tail -1)
set -- $g
[ "${1:-0}" -lt -2 ] && [ "${3:-0}" -gt 2 ] || fail "the noise ground $g, not hills ($SL)"
parts=$(tail -c +$((m + 1)) "$SL" | grep -aoP "World: the noise flat round \K[0-9]+" | tail -1)
[ "${parts:-0}" -gt 100 ] || fail "the noise flat round ${parts:-no} parts, not the track's ($SL)"
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
shot noise.png 60
ground mn
python3 -I - "$CL" "$mf" "$mn" "$ROAD" <<'PY' || fail "the ground under the road ($CL)"
import re, sys
s = open(sys.argv[1], "rb").read().decode(errors="replace")
def at(o):
    return [(m[1], float(m[2])) for m in re.finditer(
        r"kit: ground at (\S+) (-?[0-9.]+)", s[int(o):])][:len(GRID) + len(ROAD)]
ROAD = sys.argv[4].split()
GRID = ["%d,%d" % (x, z) for z in range(-72, 73, 16) for x in range(-104, 105, 16)]
F, N = at(sys.argv[2]), at(sys.argv[3])
assert len(F) == len(N) == len(ROAD) + len(GRID), (len(F), len(N))
road = [(p, a, b) for (p, a), (_, b) in zip(F[:len(ROAD)], N[:len(ROAD)])]
hills = [abs(b - a) for (_, a), (_, b) in zip(F[len(ROAD):], N[len(ROAD):])]
moved = [r for r in road if abs(r[2] - r[1]) > 0.05]
print("the ground at %d points of the racing line %.2f to %.2f (flat: %.2f to %.2f); "
      "%d of %d points of the map moved over 2 m" % (len(road), min(r[2] for r in road),
      max(r[2] for r in road), min(r[1] for r in road), max(r[1] for r in road),
      sum(h > 2 for h in hills), len(hills)))
# (the road where the flat ground had it, the hills round it)
assert not moved, moved
assert sum(h > 2 for h in hills) >= 8
PY
# (still drivable: from the U bend on through corners 4 and 5, east)
python3 -I "$here/util/kit_racer_drive.py" "$CL" "$t/boss.cmd" 40 \
	'kit: body at (6[0-9]|7[0-9])\.[0-9]+,-?[0-9.]+,-?[0-9]\.' > "$t/drive_noise.log" 2>&1 ||
	fail "the car not driven on to the east straight on the noise ground ($t/drive_noise.log)"
python3 -I - "$t/env_phys.png" "$t/noise.png" <<'PY' || fail "the noise ground not seen ($t/env_phys.png, $t/noise.png)"
import sys
from PIL import Image
A, B = (Image.open(f).convert("RGB") for f in sys.argv[1:])
w, h = A.size
px = [(A.getpixel((x, y)), B.getpixel((x, y))) for y in range(70, h - 30, 3)
      for x in range(0, w, 3)]
f = sum(sum(abs(a[i] - b[i]) for i in range(3)) > 60 for a, b in px) / len(px)
print("%.0f %% of the view changed" % (100 * f))
# (the road and its walls as they were: the hills between, 18 % 2026-11-21)
assert f > 0.1
PY
echo "ok: the trial's ground noise: hills $g, flat round $parts parts (the road on the ground), the view changed, driven on"

# 4b. A scene's lighting: the root's inherit is fast_physical; under the
# root's cartoon a kit/environment on the trial with physical gives the
# trial physical, the lobby keeps cartoon, and back
step 10 "kit editor: edit mode on" "frames 3" "keypress F6"
mc=$(mark "$CL")
set_p $ENV lighting '"inherit"'
await "$CL" "$mc" 20 "kit: lighting fast_physical"
mc=$(mark "$CL")
set_p $ENV lighting '"cartoon"'
await "$CL" "$mc" 20 "kit: lighting cartoon"
mc=$(mark "$CL")
edit '{"op": "place", "type": "kit/environment", "on": "scene", "pos": [0, 0, 0], "params": {"lighting": "physical", "time": 8}}'
await "$CL" "$mc" 20 "kit: lighting physical"
switch() # <scene> <lighting>: the client's lighting after it, ms taken in $ms
{
	local t0=$(date +%s%N)
	step 30 "kit: lighting $2" "event kit_edit {\"op\": \"scene\", \"name\": \"$1\"}"
	ms=$((($(date +%s%N) - t0) / 1000000))
}
switch world cartoon; m1=$ms
switch trial physical; m2=$ms
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
echo "ok: lighting inherit on the root fast_physical; the trial's own physical under the root's cartoon, the lobby cartoon (${m1} ms), back physical (${m2} ms)"

# 5. All undone
step 10 "kit editor: edit mode on" "frames 3" "keypress F6"
step 10 "the server is Ended" 'event kit_edit {"op": "stop"}'
while [ $n -gt 0 ]; do
	n=$((n - 1))
	step 30 "entities, $n to undo" 'event kit_edit {"op": "undo"}'
done
authored "$t/authored1.json" "$t/authored0.json" ||
	fail "the composition not as it was after the undos: $t/authored0.json, $t/authored1.json"
echo "ok: every alteration undone: the composition's entities as they were"
cmd "quit"
echo "PASS: Brimstone's simple changes: trial_laps 2 in the HUD, first_person following the car, physical's shadows (darker, bluer), a noise ground seen with the road on it and driven on, all undone exactly; screenshots $t/fp_east.png $t/fp_west.png $t/env_fast.png $t/env_phys.png $t/noise.png"
# vim: set noet ts=4 sw=4:
