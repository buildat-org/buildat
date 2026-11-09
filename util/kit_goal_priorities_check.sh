#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~4 min (2026-11-09)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/types/bot.lua builtin/kit/types/goal.lua builtin/kit/types/pickup.lua builtin/kit/types/placer.lua builtin/kit/types/explosive.lua builtin/kit/types/*.item.json builtin/kit/types/bomb.prefab.json builtin/kit/client_lua/ui.lua builtin/kit/client_lua/hands.lua apps/workbench/templates/ctf/**
# [KIT_GOAL_PRIORITIES] (kit_plan 4z7c) goals as a priority list: capture the
# flag with kitboss and three bots, two against two, on a fresh Workbench
# project from the template, set by edit ops (prep 3 s, a point every
# 8 s, 4 to win (a round long enough for a bomb), 4 a round, the bomb goal's
# pick the nearest opponent; the lobby's spawn moved onto the pad; kitboss's
# starting kit a sword and a bomb):
#   1. kitboss is ready on the pad, three bots added: a round for 4.
#   2. The bots: one picks up a weapon (find a weapon, priority 5, while it
#      holds none), one uses a bomb at the other team's base (place_item
#      while it holds an explosive: kit/placer's bomb explodes), one hits an
#      opponent (attack while it holds a blade), and a team scores (the flag,
#      priority 10).
#   3. kitboss's lines: the flag's (priority 10) on top; under it "Find a
#      weapon" while he holds the pickaxe, "Stab an opponent" with the sword,
#      "Bomb their base" with the bomb, each hidden as he holds another.
# Screenshots, kept with KEEP_TMP=1: $t/sword.png
#   util/kit_goal_priorities_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_goal_priorities; t=$CHECK_TMP
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
ed() { step 10 "kit editor: state:" "event kit_edit $1"; }
set_() { ed "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
srv() { await "$t/srv.log" "$SM" "$1" "$2"; }
srv_mark() { SM=$(mark "$t/srv.log"); }
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
step 10 "world_menu: template picked" 'click Text "Capture the flag"'
step 60 "player physics enabled" "frames 3" 'click Button "Create"'
await "$t/boss.log" 0 20 "kit editor: edit mode on"
set_ 30 repeats 3
set_ 28 score_interval 8
set_ 7 score_to_win 4
set_ 7 players 4
# The bomb by the nearest opponent (the goal's other pick): a bot walking
# to their base is stabbed on the way as often as not
set_ 66 pick '"nearest_opponent"'
set_ 42 items '"kit/pickaxe, kit/sword, kit/bomb"'
ed '{"op": "move", "ids": [4], "by": [0, 0, 11]}'
srv_mark
step 15 "the server is Running" 'event kit_edit {"op": "play"}'
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
# 1. kitboss on the pad, ready; three bots
srv 30 "kit/arena 7: kitboss entered"
cmd "frames 10" "keypress K"
srv 10 "kit/arena 7: kitboss is ready"
for i in 1 2 3; do
	srv_mark
	pause "Add bot"
	srv 10 "kit/spawner 61: made [0-9]+"
done
srv_mark
srv 90 "kit/arena 7: countdown over: a round for 4 players"
# 3. His lines as he holds each (the round's kit given)
srv 30 "kitboss has .*kit/bomb"
cmd "event kit_hold kit/pickaxe"
await "$t/boss.log" 0 30 'kit: ui 65 text at .* shown: "Find a weapon'
step 10 'kit: ui 67 text at .* shown: "Stab an opponent' "event kit_hold kit/sword"
cmd "frames 10" "screenshot $t/sword.png"
step 10 'kit: ui 66 text at .* shown: "Bomb their base' "event kit_hold kit/bomb"
step 10 'kit: ui 65 text at .* shown: "Find a weapon' "event kit_hold kit/pickaxe"
# 2. The bots
srv 120 "kit/pickup [0-9]+: Bot [0-9]+ takes [0-9]+ kit/(sword|bomb)"
srv 180 "kit/placer 68: Bot [0-9]+ places kit/bomb"
srv 30 "kit/explosive [0-9]+: explodes"
srv 180 "kit/bot [0-9]+: hits [0-9]+ with kit/sword"
srv 240 "kit/flag 28: scores 1 for"
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
# The bots' goals by priority: a bomb placed came from the bomb goal (66)
if not re.search(r"kit/bot \d+: uses kit/bomb for goal 66", srv):
	sys.exit("no bot used a bomb for goal 66")
if not re.search(r"kit/bot \d+: hits \d+ with kit/sword for goal 67", srv):
	sys.exit("no bot hit for goal 67")
# kitboss's lines: the flag's on top of each of the others in the window
y = {}
for m in re.finditer(r"kit: ui (5[67]|6[567]) text at (\d+),(\d+) .* (shown|hidden)", cl):
	if m.group(4) == "shown":
		y.setdefault(m.group(1), []).append(int(m.group(3)))
if "56" not in y:
	sys.exit("the flag's line never shown")
for k in ("65", "66", "67"):
	if k not in y or min(y[k]) <= min(y["56"]):
		sys.exit(f"line {k} not under the flag's: {y}")
for k, want in (("66", "Bomb their base"), ("67", "Stab an opponent")):
	if not re.search(rf"kit: ui {k} text at .* hidden", cl):
		sys.exit(f"line {k} ({want}) never hidden")
print("bots: weapon, bomb, hit, score; kitboss's lines", {k: min(v) for k, v in y.items()})
PY
verdict_keep
[ "$verdict_rc" = 0 ] && echo "PASS: bots act on their goals by priority and what they hold; a player's lines follow what he holds"
verdict_exit
# vim: set noet ts=4 sw=4:
