#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-18)
# covers: apps/workbench/templates/brimstone_speedway/** builtin/kit/client_lua/move.lua builtin/kit/client_lua/players.lua builtin/kit/client_lua/controls.lua builtin/kit/kit.cpp
# [KIT_TOP_DOWN] (7), (8) The Brimstone Speedway template (a top-down racer:
# local/brim_car in kit/controls' plane horizontal, its race, checkpoints,
# crates and mines) on Workbench; one server, kitboss (the admin) and kitbob
# on a headless weston's Xwayland of the check's own; the cars driven round
# the oval's centre line by a closed loop over the fifo (each body line's
# place and yaw, A/D toward a point 10 m on):
#   0. New from it (the edits: one lap a race and a trial, a mine 30 damage,
#      crate 2 mines): the lobby's full screen and its two tracks
#      (lobby.png), Race: kitboss on the grid, the Start button; kitbob
#      joins and picks Race: the second slot (grid.png);
#   1. Start: the countdown, then both go at once (GO on both screens);
#   2. (8) bodies colliding: kitbob drives from his slot through the middle
#      of kitboss's standing car: kitboss pushed a metre or more
#      (the server's steps; his own client corrected) (push.png);
#   3. the race: kitboss round first, the crate's mines taken and one dropped
#      behind him on the north straight, kitbob after him onto it: the
#      mine's blast, his wreck (kit/health's death: the effects, a scorch
#      mark, wreck.png), back on the road at checkpoint 2 two seconds later;
#      kitboss 1st, kitbob 2nd, the race over; the result card (result.png);
#   4. the time trial (its own scene): kitboss over the line at the start
#      with no checkpoint passed: no lap (the car's step meets the line with
#      lap_open off), then round: checkpoints 1, 2, 3, the lap, the result
#      card with the time; no prediction correction on that lap (trial.png).
# Screenshots, kept with KEEP_TMP=1: $t/lobby.png, $t/grid.png, $t/push.png,
# $t/wreck.png, $t/result.png, $t/trial.png
#   util/kit_racer_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_racer; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
check_build

# The entities by name (the template's ids), the race's scene's and the trial's
python3 -I - "$here/apps/workbench/templates/brimstone_speedway/composition.json" \
		> "$t/ids" <<'PY' || fail "the template's composition"
import json, sys
d = json.load(open(sys.argv[1]))
scene = {e["name"]: e["id"] for e in d["entities"] if e.get("kind") == "scene"}
def find(name, s):
    return [e["id"] for e in d["entities"] if e.get("name") == name and
            e.get("parent") == scene[s]]
print("RACE=%d TRIAL=%d CRATE=%d" % (find("the race", "world")[0],
      find("the race", "trial")[0], find("crate", "world")[1]))
PY
. "$t/ids"

# The driver: round the oval's centre line (or at TARGET x,z), W held, A/D by
# the heading; till a regex is in the client's log or the time is up
cat > "$t/drive.py" <<'PY'
import math, os, re, sys, time
log, fifo, secs, stop = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
target = [float(v) for v in os.environ["TARGET"].split(",")] if os.environ.get("TARGET") else None
fire_on = os.environ.get("FIRE_ON")  # Space once as it shows in the log
out = open(fifo, "w", buffering=1)
L, RAD = 100.0, 30.0  # the straights' length, the bends' radius
LOOP = 2 * L + 2 * math.pi * RAD
def point(u):
    """The centre line u metres on from (-50, -30), heading +x (anticlockwise)"""
    u %= LOOP
    if u < L:
        return -50 + u, -RAD
    u -= L
    if u < math.pi * RAD:
        a = -math.pi / 2 + u / RAD
        return 50 + RAD * math.cos(a), RAD * math.sin(a)
    u -= math.pi * RAD
    if u < L:
        return 50 - u, RAD
    a = math.pi / 2 + (u - L) / RAD
    return -50 + RAD * math.cos(a), RAD * math.sin(a)
def dist2(q, x, z):
    px, pz = point(q)
    return (px - x) ** 2 + (pz - z) ** 2
def send(*cmds):
    out.write("\n".join(cmds) + "\n")
keys = set()
def key(k, on):
    if on and k not in keys:
        send("keydown " + k)
        keys.add(k)
    elif not on and k in keys:
        send("keyup " + k)
        keys.discard(k)
f = open(log, errors="replace")
f.seek(0, 2)
t0, u, x, z, stopped = time.time(), None, None, None, False
send("event kit_body")
while time.time() - t0 < secs:
    line = f.readline()
    if not line:
        time.sleep(0.01)
        continue
    if re.search(stop, line):
        stopped = True
        break
    if fire_on and re.search(fire_on, line):
        fire_on = None
        send("keypress Space")
        print("fired", flush=True)
    m = re.search(r"kit: body at (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+)", line)
    if m:
        if x is not None and (float(m[1]) - x) ** 2 + (float(m[3]) - z) ** 2 > 64:
            u = None  # (a teleport: found again on the whole loop)
        x, z = float(m[1]), float(m[3])
        continue
    m = re.search(r"kit: vehicle speed -?[0-9.]+,-?[0-9.]+,-?[0-9.]+, yaw (-?[0-9.]+)", line)
    if not m or x is None:
        continue
    if u is None:
        u = min(range(int(LOOP)), key=lambda q: dist2(q, x, z))
    u = min(range(u - 20, u + 60), key=lambda q: dist2(q, x, z))
    tx, tz = target or point(u + 10)
    err = (math.degrees(math.atan2(tx - x, tz - z)) - float(m[1]) + 540) % 360 - 180
    key("W", True)
    key("D", err > 3)
    key("A", err < -3)
    print("at %.1f,%.1f err %.0f" % (x, z, err), flush=True)
    send("frames 2", "event kit_body")
for k in list(keys):
    key(k, False)
print("stopped" if stopped else "time up", flush=True)
sys.exit(0 if stopped else 1)
PY

sock=buildat-racer-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
SL=$t/srv.log CL=$t/boss.log FD=3
mark() { wc -c < "$1"; }
as() # <boss|bob>: the client the next commands drive
{
	if [ "$1" = bob ]; then
		CL=$t/bob.log CLIENT=$BOB FD=4
	else
		CL=$t/boss.log CLIENT=$BOSS FD=3
	fi
}
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
seen() { tail -c +$(($2 + 1)) "$1" | grep -qaE "$3"; } # <log> <offset> <regex>
cmd() { printf '%s\n' "$@" >&$FD; }
step() # <seconds> <regex in the client's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$CL")
	cmd "$@"
	await "$CL" "$m" "$s" "$re"
}
body() # the body's x, z and corrections now, into bx, bz, bc
{
	local m
	m=$(mark "$CL")
	step 5 "kit: body at" "event kit_body"
	read bx bz bc <<< "$(tail -c +$((m + 1)) "$CL" | grep -aoP 'kit: body at \K-?[0-9.]+,-?[0-9.]+,-?[0-9.]+, [0-9]+ acks, [0-9]+' |
		tail -1 | sed -E 's/^(-?[0-9.]+),-?[0-9.]+,(-?[0-9.]+), [0-9]+ acks, ([0-9]+)$/\1 \2 \3/')"
}
drive() # <who> <seconds> <stop regex>: the driver on that client (env TARGET, FIRE_ON)
{
	python3 -I "$t/drive.py" "$t/$1.log" "$t/$1.cmd" "$2" "$3" > "$t/drive_$1.log" 2>&1
}
near() { awk -v a="$1" -v b="$2" -v e="$3" 'BEGIN { exit !((a - b) ^ 2 <= e * e) }'; }
# (the game's clock as the wall's: the race's countdown, its clock and its
# timers are the game's seconds, the cars' steps the wall's)
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate 1 || fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
grep -aq "workbench: the template in .*brimstone_speedway" "$SL" && fail "the template refused ($SL)"
client() # <name>: its commands from the fifo $t/<name>.cmd, its log $t/<name>.log
{
	mkfifo "$t/$1.cmd"
	sleep 900 > "$t/$1.cmd" &
	CHECK_PIDS+=($!)
	DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kit$1 \
		timeout 600 bin/buildat -C "$t/client_cache_$1" -D "$t/cu_$1" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
		< "$t/$1.cmd" > "$t/$1.log" 2>&1 &
	CHECK_PIDS+=($!)
}
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss
BOSS=$!
exec 3> "$t/boss.cmd"
as boss
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don*"'
# 0. New from the template, the edits, played: the lobby
await "$CL" 0 30 "world_menu: the list shown"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New game..."'
cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked" 'click Text "Brimstone Speedway"'
step 120 "kit editor: edit mode on" "frames 3" 'click Button "Create"'
for re in "The template's type local/brim_car \([0-9]+ bytes\)" "The template's type local/brim_race " \
		"The template's type local/brim_checkpoint " "The template's type local/brim_mine "; do
	grep -aqE "$re" "$SL" || fail "no \"$re\" in $SL"
done
n=0
for e in "$RACE laps 1" "$RACE mine_damage 30" "$CRATE weapon \"mines\"" "$TRIAL trial_laps 1"; do
	set -- $e
	n=$((n + 1))
	step 10 "entities, $n to undo" "event kit_edit {\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
done
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
await "$CL" 0 10 "kit: controls: camera top_down, pointer [a-z]+, movement local/brim_car, plane y 1"
await "$CL" 0 10 "brim_car: the draw hook draws a car"
await "$CL" 0 10 "kit: ui full screen [0-9]+ up"
await "$CL" 0 10 'kit: ui [0-9]+ list .* shown, layer [0-9]+: "Pick your poison \| Race: The Pit Loop, by buildat \| Time trial: The Pit Loop, by buildat"'
cmd "frames 10" "screenshot $t/lobby.png"
m=$(mark "$SL")
step 10 "kit: ui full screen none" "frames 3" 'click Button "Race: The*"'
await "$SL" "$m" 5 "local/brim_race $RACE: kitboss is on the grid, slot 1"
await "$CL" 0 10 '"On the grid: 1 car. Start when ready."'
echo "ok: a project from it: the top-down camera, the car's movement and hook; the lobby's tracks; Race: kitboss on the grid"
BUILDAT_JOIN_CREATE=1 client bob
BOB=$!
exec 4> "$t/bob.cmd"
as bob
await "$CL" 0 120 "Joined as kitbob"
await "$CL" 0 60 "kit: ui full screen [0-9]+ up"
m=$(mark "$SL")
step 10 "kit: ui full screen none" "frames 3" 'click Button "Race: The*"'
await "$SL" "$m" 5 "local/brim_race $RACE: kitbob is on the grid, slot 2"
cmd "frames 20" "screenshot $t/grid.png"
echo "ok: kitbob joined the grid, slot 2"

# 1. The start: the countdown, both go at once
as boss
m=$(mark "$SL")
mb=$(mark "$t/bob.log")
cmd "frames 3" 'click Button "Start the race"'
await "$SL" "$m" 5 "local/brim_race $RACE: kitboss starts the race: 2 cars"
await "$CL" "$m" 10 '"GO! Burn rubber, sinners!"'
await "$t/bob.log" "$mb" 2 '"GO! Burn rubber, sinners!"'
echo "ok: the countdown, GO on both screens"

# 2. (8) kitbob at kitboss's car standing on the grid: pushed by the server
body
x0=$bx z0=$bz c0=$bc
as bob
body
# (from his slot through the middle of kitboss's car, on: head-on into its
# back: 7-11 m. Under 0.5 m was kitbob's car stopping dead on it, the
# knock traded again each step of his batch before kitboss's step took it)
TARGET=$(awk -v x="$bx" -v z="$bz" -v X="$x0" -v Z="$z0" 'BEGIN { d = sqrt((X - x) ^ 2 + (Z - z) ^ 2)
	printf "%.2f,%.2f", X + (X - x) / d * 60, Z + (Z - z) / d * 60 }') drive bob 2 "NEVER"
step 10 "Wrote screenshot $t/push.png" "frames 10" "screenshot $t/push.png"
as boss
body
python3 -I - "$x0" "$z0" "$bx" "$bz" "$c0" "$bc" <<'PY' || fail "kitboss's car not pushed: $x0,$z0 to $bx,$bz ($CL, $t/drive_bob.log)"
import sys
x0, z0, x1, z1, c0, c1 = map(float, sys.argv[1:])
d = ((x1 - x0) ** 2 + (z1 - z0) ** 2) ** 0.5
assert d > 1, d
print("ok: kitbob drove into kitboss's standing car: pushed %.1f m (the server's steps, his client corrected %d times)" % (d, c1 - c0))
PY

# 3. The race: kitboss round, the mines dropped; kitbob after him onto one
as boss
m=$(mark "$SL")
FIRE_ON="Mines x" drive boss 60 'panel .* shown, layer [0-9]+: "The flag is down' &
DB=$!
await "$SL" "$m" 20 "local/brim_race $RACE: kitboss passed checkpoint 1 of 3"
as bob
drive bob 70 'panel .* shown, layer [0-9]+: "The flag is down' &
DO=$!
as boss
await "$SL" "$m" 30 "local/brim_race $RACE: kitboss drops a mine"
await "$SL" "$m" 30 "local/brim_race $RACE: kitbob hits a mine"
await "$SL" "$m" 2 "local/brim_race $RACE: kitbob wrecked by mine"
printf "%s\n" "frames 5" "screenshot $t/wreck.png" >&4 # (kitbob's view)
await "$SL" "$m" 2 "Entity $RACE made a copy of entity:[0-9]+"
await "$SL" "$m" 5 "local/brim_race $RACE: kitbob back on the road at checkpoint 2"
wait $DB || fail "kitboss's driver: $(tail -2 "$t/drive_boss.log")"
await "$SL" "$m" 5 "local/brim_race $RACE: kitboss finished 1st"
as bob
wait $DO || fail "kitbob's driver: $(tail -2 "$t/drive_bob.log")"
await "$SL" "$m" 5 "local/brim_race $RACE: kitbob finished 2nd"
await "$SL" "$m" 2 "local/brim_race $RACE: the race is over: everyone finished"
await "$t/bob.log" 0 5 'shown, layer [0-9]+: "You: 2nd \| 1st  kitboss  [0-9.:]+ \| 2nd  kitbob '
as boss
await "$CL" 0 5 'shown, layer [0-9]+: "You: 1st \| 1st  kitboss  [0-9.:]+ \| 2nd  kitbob '
cmd "frames 10" "screenshot $t/result.png"
echo "ok: the race: kitboss's mine, kitbob's wreck and his respawn at checkpoint 2; kitboss 1st, kitbob 2nd"

# 4. The time trial: no lap over the line with no checkpoint, then one
m=$(mark "$SL")
step 10 "kit: ui full screen [0-9]+ up" "frames 3" 'click Button "Lobby"'
step 10 "kit: ui full screen none" "frames 3" 'click Button "Time trial: The*"'
await "$SL" "$m" 10 "local/brim_race $TRIAL: kitboss starts a time trial"
await "$CL" "$m" 10 '"Lap 1/1   Time [0-9.]+   GO!'
mc=$(mark "$CL")
drive boss 40 'panel .* shown, layer [0-9]+: "The flag is down'
python3 -I - "$SL" "$m" "$TRIAL" <<'PY' || fail "the trial's lap ($SL)"
import re, sys
s = open(sys.argv[1], "rb").read()[int(sys.argv[2]):].decode(errors="replace")
race = "local/brim_race %s: kitboss " % sys.argv[3]
order = [l.split(race, 1)[1] for l in s.splitlines() if race in l]
lap = [i for i, l in enumerate(order) if l.startswith("lap 1 in")]
cp = [i for i, l in enumerate(order) if l.startswith("passed checkpoint")]
assert len(lap) == 1 and len(cp) == 3 and max(cp) < lap[0], order
assert any(l.startswith("finished the trial in") for l in order), order
print("ok: the trial: %s" % "; ".join(order[1:]))
PY
grep -aoP "at \K-?[0-9.]+" "$t/drive_boss.log" | head -20 | awk '$1 > -8 { f = 1 } END { exit !f }' ||
	fail "the car never crossed the line at the start ($t/drive_boss.log)"
# (up to the lap: the finish takes the car out of play, a step its client
# had already taken in play: a correction there is the run's end)
python3 -I - "$SL" "$m" "$CL" "$mc" "$TRIAL" <<'PY' || fail "corrections on the trial's lap ($CL)"
import sys
def lines(path, at):
    return open(path, "rb").read()[int(at):].decode(errors="replace").splitlines()
lap = [l.split()[2] for l in lines(sys.argv[1], sys.argv[2])
       if "local/brim_race %s: kitboss lap 1 in" % sys.argv[5] in l][0]
n = [l for l in lines(sys.argv[3], sys.argv[4]) if "kit: the body corrected by" in l and l.split()[2] < lap]
assert not n, n
PY
step 10 "Wrote screenshot $t/trial.png" "frames 10" "screenshot $t/trial.png"
echo "ok: the trial: over the line at the start no lap, then checkpoints, the lap, the result; no correction"
cmd "quit"
as bob
cmd "quit"
echo "PASS: Brimstone Speedway from its template: the lobby, the grid's Start, both cars off at once, a standing car pushed by another (the server's steps), kitboss's mine and kitbob's wreck and respawn at the checkpoint, the places by who finished first, a trial's lap only over every checkpoint with no correction; screenshots $t/lobby.png $t/grid.png $t/push.png $t/wreck.png $t/result.png $t/trial.png"
# vim: set noet ts=4 sw=4:
