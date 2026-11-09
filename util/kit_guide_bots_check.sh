#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-09)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/types/bot.lua builtin/kit/types/bot.prefab.json builtin/kit/types/guide.prefab.json builtin/kit/types/goal.lua builtin/kit/types/creature_walker.lua builtin/kit/types/pause_menu_action.lua builtin/kit/types/spawner.lua builtin/kit/client_lua/ui.lua builtin/kit/client_lua/players.lua apps/workbench/templates/puzzle_room/** apps/workbench/**
# [KIT_GUIDE_BOTS] (kit_plan 4z7) the puzzle room's guide, done by a bot and seen
# by a player, on a fresh Workbench project from the template:
#   1. Played: kitboss sees the guide's first step in its corner window
#      (a kit/ui_panel its goals name, [KIT_GUIDE_BOTS_2]).
#   2. "Add bot" in the pause menu: a bot comes, presses the button, runs
#      through the gate, flips lever A, then lever C (the levers goal's via),
#      and leaves through the door: each goal done for it, the last one too.
#   3. kitboss sees the same steps one at a time as he does each (a try of
#      the goal's complete as by him), the window gone after the last.
#   4. Without its via the levers goal leaves a bot stuck: a log line and its
#      nameplate; "Remove bots" takes them away.
# Screenshots, kept with KEEP_TMP=1: $t/guide.png, $t/walk.png, $t/bot.png, $t/stuck.png
#   util/kit_guide_bots_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_guide_bots; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
# (no --sim-rate: the room's gate is a race against its 5 s)
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
ed() { step 10 "kit editor: state:" "event kit_edit $1"; }
try() { step 10 "kit editor: tried|kit editor: .*refused" "event kit_edit {\"op\": \"try\", \"id\": $1, \"input\": \"$2\"}"; }
srv() { await "$t/srv.log" "$SM" "$1" "$2"; }
srv_mark() { SM=$(mark "$t/srv.log"); }
# A UI line of the client's after <offset>: entity <id>'s, what follows its order
# (in edit mode a line hidden in play is drawn: "shown, edit mode, hidden in play")
ui() { await "$t/boss.log" "$1" 10 "kit: ui $2 [a-z]+ at [0-9]+,[0-9]+ .* order [-0-9.]+ $3"; }
pause() # <button>: pressed in the pause menu
{
	step 10 "pause: the menu shown" "keypress Escape"
	cmd "frames 3" "click Button \"$1\""
}
await "$t/boss.log" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
step 30 "world_menu: the list shown" "frames 3"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New project..."'
cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked" 'click Text "Puzzle room"'
step 60 "player physics enabled" "frames 3" 'click Button "Create"'
await "$t/boss.log" 0 20 "kit editor: edit mode on"
# 1. Played: the guide's first step, in the window at the top right
m=$(mark "$t/boss.log")
srv_mark
step 15 "the server is Running" 'event kit_edit {"op": "play"}'
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
ui "$m" 47 'shown: "Press the red button"'
cmd "frames 30" "screenshot $t/guide.png"
# 2. A bot from the pause menu does the chain
srv_mark
pause "Add bot"
srv 10 "kit/spawner 52: made [0-9]+"
bot=$(tail -c +$((SM + 1)) "$t/srv.log" | grep -aoP 'kit/spawner 52: made \K[0-9]+' | head -1)
cmd "frames 40" "screenshot $t/walk.png"
srv 30 "kit/goal 47: done for Bot $bot"
srv 20 "kit/goal 48: done for Bot $bot"
cmd "frames 10" "screenshot $t/bot.png"
srv 30 "kit/goal 51: done for Bot $bot"
srv 30 "kit/goal 49: done for Bot $bot"
srv 30 "kit/goal 46: done for Bot $bot"
# 3. kitboss's steps, the same ones, each as he does it (a try: in edit mode)
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
for g in "47 48 The gate is open" "48 49 Find which two levers" "49 46 Leave through the door"; do
	set -- $g
	m=$(mark "$t/boss.log")
	try $1 complete
	ui "$m" $2 "shown, edit mode: \"$3"
done
m=$(mark "$t/boss.log")
try 46 complete
ui "$m" 46 "(hidden|shown, edit mode, hidden in play)"
# 4. No via: stuck; the bots taken away
step 10 "the server is Ended" 'event kit_edit {"op": "stop"}'
ed '{"op": "set", "id": 49, "comp": 0, "param": "via", "value": 0}'
srv_mark
step 15 "the server is Running" 'event kit_edit {"op": "play"}'
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
pause "Add bot"
srv 10 "kit/spawner 52: made [0-9]+"
srv 60 "kit/bot [0-9]+: stuck on goal 49: nothing to use"
cmd "frames 10" "screenshot $t/stuck.png"
srv_mark
pause "Remove bots"
srv 10 "kit/spawner 52: took away 1 copies"
cmd quit
exec 3>&-
wait $CLIENT 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 - "$t" <<'PY' || fail "the logs say otherwise ($t)"
import re, sys
t = sys.argv[1]
srv = open(f"{t}/srv.log", errors="replace").read()
cl = open(f"{t}/boss.log", errors="replace").read()
# The bot's goals in the guide's order
bot = re.search(r"kit/spawner 52: made (\d+)", srv).group(1)
done = re.findall(r"kit/goal (\d+): done for Bot " + bot + r"\b", srv)
if done != ["47", "48", "51", "49", "46"]:
	sys.exit(f"the bot's goals: {done}")
# Its uses: the button, lever A, lever C (the via)
uses = re.findall(r"kit/bot " + bot + r": uses (\d+)", srv)
if uses != ["22", "27", "31"]:
	sys.exit(f"the bot's uses: {uses}")
# kitboss's window: its steps in the top right, one shown at a time
shown = re.findall(r"kit: ui (\d+) text at (\d+),\d+ .* shown(?:: |, edit mode: )", cl)
first = [g for g, x in shown]
for g in ("47", "48", "49", "46"):
	if g not in first:
		sys.exit(f"kitboss never saw goal {g}'s step: {first}")
if any(int(x) < 600 for g, x in shown if g in ("47", "48", "49", "46")):
	sys.exit(f"a step outside the top right window: {shown}")
# [KIT_GUIDE_BOTS_2] in play the step inside the guide's window (55)
w = re.search(r"kit: ui 55 panel at (\d+),(\d+) (\d+)x(\d+) .* shown: ", cl)
g = re.search(r"kit: ui 47 text at (\d+),(\d+) (\d+)x(\d+) .* shown: ", cl)
if not w or not g:
	sys.exit("the guide's window or its first step not shown in play")
wx, wy, ww, wh = map(int, w.groups())
gx, gy, gw, gh = map(int, g.groups())
if not (wx <= gx and wy <= gy and gx + gw <= wx + ww and gy + gh <= wy + wh):
	sys.exit(f"the first step {g.groups()} not in the window {w.groups()}")
if re.search(r"kit: ui 51 text .* shown(?:: |, edit mode: )", cl):
	sys.exit("kitboss saw the bots' own goal")
print(f"bot {bot}: goals {' '.join(done)}, uses {' '.join(uses)}")
PY
verdict_keep
[ "$verdict_rc" = 0 ] && echo "PASS: a bot does the puzzle room's guide; a player sees its steps; stuck without a via"
verdict_exit
# vim: set noet ts=4 sw=4:
