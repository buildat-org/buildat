#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~4 min (2026-11-09)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/types/bot.lua builtin/kit/types/bot.client.lua builtin/kit/types/goal.lua builtin/kit/types/turret.lua builtin/kit/types/sea_vessel.lua builtin/kit/client_lua/move.lua builtin/kit/client_lua/controls.lua builtin/kit/client_lua/module.lua apps/workbench/templates/ship/**
# [KIT_GUIDE_STATIONS] (kit_plan 4z7b) bots at a ship's stations, and the
# gunner's impact marker, on a fresh Workbench project from the Ship template:
#   1. The marker: kitboss at the cannon's seat sets three elevations and
#      fires at each; where his marker said the shot would land ("event
#      kit_impact") and where the server says it landed agree within 2 m.
#   2. Two bots from the pause menu: one takes the cannon (the mines' goal,
#      an attack through it, priority 10), the other, the cannon taken, the
#      wheel (a reach through it, priority 5): the gunner fires and hits a
#      mine, the helmsman sails into the marked box out among the mines.
#   3. kitboss sees the same steps as HUD lines: the mines' and the sailing
#      out's shown, the sailing out's hidden once it is done.
# Screenshots, kept with KEEP_TMP=1: $t/marker.png, $t/bots.png
#   util/kit_guide_stations_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_guide_stations; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
mkfifo "$t/cmd"
sleep 900 > "$t/cmd" &
CHECK_PIDS+=($!)
# (not run_client: a job in the background reads /dev/null unless told)
check_build
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	timeout 600 bin/buildat -C "$t/client_cache" -D "$t/cu_boss" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -c - < "$t/cmd" > "$t/boss.log" 2>&1 &
CLIENT=$!
CHECK_PIDS+=($CLIENT)
exec 3> "$t/cmd"
cmd() { printf '%s\n' "$@" >&3; }
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($t/boss.log)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($t/srv.log, $t/boss.log)"
}
step() # <seconds> <regex in the client's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$t/boss.log")
	cmd "$@"
	await "$t/boss.log" "$m" "$s" "$re"
}
srv() { await "$t/srv.log" "$SM" "$1" "$2"; }
srv_mark() { SM=$(mark "$t/srv.log"); }
pause() # <button>: pressed in the pause menu
{
	step 10 "pause: the menu shown" "keypress Escape"
	cmd "frames 3" "click Button \"$1\""
}
# [KIT_BOT_DIFFICULTY] "Add bot" from the pause menu, its dialog's Add (with
# the knobs stepped first: "<knob> <-|+>"...)
add_bot() # <spawner> [<knob> <-|+>]...
{
	local m=$(mark "$t/boss.log") s=$1
	shift
	srv_mark
	pause "Add bot"
	srv 10 "kit/spawner $s: made [0-9]+"
	await "$t/boss.log" "$m" 10 "client part: bot dialog shown"
	cmd "frames 3"
	while [ $# -ge 2 ]; do
		step 5 "bot dialog: $1 " "click Button \"bot $1 $2\"" "frames 2"
		shift 2
	done
	cmd 'click Button "bot add"'
	srv 10 "kit/bot [0-9]+: knobs: .* by kitboss"
}
held() { cmd "keydown $1" "delay $2" "keyup $1" "frames 3"; }
await "$t/boss.log" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
step 30 "world_menu: the list shown" "frames 3"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New project..."'
cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked" 'click Text "Ship"'
step 60 "player physics enabled" "frames 3" 'click Button "Create"'
await "$t/boss.log" 0 20 "kit editor: edit mode on"
srv_mark
step 15 "the server is Running" 'event kit_edit {"op": "play"}'
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
srv 20 "Entity 12's kit/turret steps in play"
# 3. The steps as lines
await "$t/boss.log" 0 20 'kit: ui 43 text at .* shown: "Sink the five red mines'
await "$t/boss.log" 0 20 'kit: ui 47 text at .* shown: "Sail out among the mines'
# 1. The marker at three elevations: the gun turned a little right (off the
# far mine), lowered fully, then raised a step each time
await "$t/boss.log" 0 20 "kit: the body's frame: 10"
# (as kit_ship_check's gunner: the seat is in reach a few steps on)
cmd "frames 10" "look_dir 0.22 0 1"
held W 900
step 10 "movement kit/turret, seat 13" "event kit_use 13"
await "$t/boss.log" 0 10 "kit: impact marker on"
held D 200
held S 400
for k in 1 2 3; do
	cmd "frames 10"
	[ $k = 2 ] && cmd "screenshot $t/marker.png"
	# (the reading and the shot together: the deck moves between frames)
	srv_mark
	step 5 "kit: impact at" "event kit_impact" "keypress Space"
	srv 10 "kitboss's projectile [0-9]+ (lands|hits)"
	# (250 ms put the third 127 m out, past the terrain loaded: no landing)
	held W 60
done
step 10 "kit: controls: camera first_person" "keypress F"
await "$t/boss.log" 0 10 "kit: impact marker off"
# 2. Two bots: the gun, then the wheel
for i in 1 2; do
	add_bot 48
done
cmd "frames 30" "screenshot $t/bots.png"
SM=0
srv 30 "Bot [0-9]+ takes the seat of entity 13"
srv 30 "Bot [0-9]+ takes the seat of entity 11"
srv 60 "Bot [0-9]+ fires entity 12's kit/turret"
srv 120 "Bot [0-9]+'s projectile [0-9]+ hits entity 3[0-4]"
srv 180 "kit/goal 47: done"
await "$t/boss.log" 0 20 'kit: ui 47 text at .* hidden'
cmd quit
exec 3>&-
wait $CLIENT 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 -I - "$t" <<'PY' || fail "the logs say otherwise ($t)"
import math, re, sys
t = sys.argv[1]
srv = open(f"{t}/srv.log", errors="replace").read()
cl = open(f"{t}/boss.log", errors="replace").read()
# 1. Marker and landing, shot by shot
said = [tuple(map(float, m)) for m in re.findall(
	r"kit: impact at ([-0-9.]+) ([-0-9.]+) ([-0-9.]+) \(hit\)", cl)]
landed = [tuple(map(float, m)) for m in re.findall(
	r"kitboss's projectile \d+ lands at \(([-0-9.]+), ([-0-9.]+), ([-0-9.]+)\)", srv)]
if len(said) != 3 or len(landed) != 3:
	sys.exit(f"the marker said {said}, the shots landed {landed}")
off = [math.dist(a, b) for a, b in zip(said, landed)]
print("marker vs landing: " + ", ".join(f"{d:.2f} m ({math.dist(b, landed[0]):.0f} m past the first)"
	for d, b in zip(off, landed)))
if max(off) > 2:
	sys.exit(f"the marker is off: {off} m")
# (three different elevations: three different places)
if min(math.dist(a, b) for a, b in zip(landed, landed[1:])) < 4:
	sys.exit(f"the shots landed together: {landed}")
# 2. The bots: the gunner and the helmsman are two
gun = re.search(r"(Bot \d+) takes the seat of entity 13", srv).group(1)
helm = re.search(r"(Bot \d+) takes the seat of entity 11", srv).group(1)
if gun == helm:
	sys.exit(f"one bot at both stations: {gun}")
hits = re.findall(rf"{gun}'s projectile \d+ hits entity (3[0-4])", srv)
shots = len(re.findall(rf"{gun} fires entity 12's kit/turret", srv))
# (done by whoever came into the box first: the ship took them there, its
# helmsman at the wheel all the while)
done = srv.find("kit/goal 47: done")
if re.search(rf"{helm} leaves the seat of entity 11", srv[:done]):
	sys.exit(f"the helmsman {helm} left the wheel before the ship was out there")
if not hits:
	sys.exit(f"the gunner {gun} hit no mine in {shots} shots")
print(f"the gunner {gun}: {shots} shots, hits {hits}; the helmsman {helm} sailed out")
PY
verdict_keep
[ "$verdict_rc" = 0 ] && echo "PASS: bots man a ship's gun and helm; a gunner's impact marker agrees with the shots"
verdict_exit
# vim: set noet ts=4 sw=4:
