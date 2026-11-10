#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-09)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/types/bot.lua builtin/kit/types/bot.client.lua builtin/kit/types/goal.lua builtin/kit/types/arena.lua builtin/kit/types/team.lua builtin/kit/types/flag.lua builtin/kit/types/spawner.lua builtin/kit/types/pause_menu_action.lua apps/workbench/templates/ctf/**
# [KIT_GUIDE_BOTS_2] (kit_plan 4z7a) bots are players: capture the flag played
# by four bots, two against two, on a fresh Workbench project from the
# template, shortened by edit ops (prep 3 s, a point every 4 s, 2 to win, 4 a round):
#   1. "Add bot" four times in the lobby's pause menu: each bot walks onto
#      the golden pad (a goal with no line), the arena queues it and, all of
#      them ready (a bot is), a round starts with the four.
#   2. In the round's session each bot's copy joins a team (two and two, put
#      on its pad); a bot takes the flag (the guide's use goal), carries it
#      to its own team's zone (place_item, own_team) and places it: points,
#      and the round ends with a winner. kitboss stays in the lobby.
#   3. Account-bound: no bot is a player entity of an account (nothing
#      remembers it), none is listed as a peer of a session.
# Screenshots, kept with KEEP_TMP=1: $t/lobby.png
#   util/kit_ctf_bots_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_ctf_bots; t=$CHECK_TMP
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
await "$t/boss.log" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
step 30 "world_menu: the list shown" "frames 3"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New project..."'
cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked" 'click Text "Capture the flag"'
step 60 "player physics enabled" "frames 3" 'click Button "Create"'
await "$t/boss.log" 0 20 "kit editor: edit mode on"
# Shorter: the flag out in 3 s, a point every 4 s, 2 to win; a round for 4
set_ 30 repeats 3
set_ 28 score_interval 4
set_ 7 score_to_win 2
set_ 7 players 4
srv_mark
step 15 "the server is Running" 'event kit_edit {"op": "play"}'
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
# 1. Four bots from the pause menu, onto the pad, into a round
for i in 1 2 3 4; do
	add_bot 61
done
cmd "frames 60" "screenshot $t/lobby.png"
srv_mark
srv 90 "kit/arena 7: countdown over: a round for 4 players"
# 2. Their copies in the round: teams, the flag, the score, a winner
srv 30 "into session [0-9]+ as Bot"
srv 60 "joins team Blue"
srv 60 "kit/flag 28: taken by Bot"
srv 90 "kit/flag 28: placed by Bot"
srv 60 "kit/flag 28: scores 1 for (Red|Blue)"
srv 180 "kit/arena 7: round over: (Red|Blue) wins!"
cmd quit
exec 3>&-
wait $CLIENT 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 - "$t" <<'PY' || fail "the logs say otherwise ($t)"
import re, sys
t = sys.argv[1]
srv = open(f"{t}/srv.log", errors="replace").read()
made = re.findall(r"kit/spawner 61: made (\d+)", srv)
if len(made) != 4:
	sys.exit(f"bots made: {made}")
# Each bot into the round's session as a copy
into = re.findall(r"Bot (\d+) into session (\d+) as Bot (\d+)", srv)
if sorted(b for b, s, c in into) != sorted(made):
	sys.exit(f"the bots into the round: {into}")
copies = {c for b, s, c in into}
# Two and two in the teams
teams = re.findall(r"kit/team \d+: Bot (\d+) joins team (Red|Blue)", srv)
red = {b for b, n in teams if n == "Red"}
blue = {b for b, n in teams if n == "Blue"}
if len(red) != 2 or len(blue) != 2 or (red | blue) != copies:
	sys.exit(f"the teams: {teams}")
# A bot of a team took the flag and placed it, for a score; a winner
won = re.search(r"kit/arena 7: round over: (Red|Blue) wins! (Red|Blue) (\d+) : (Red|Blue) (\d+)", srv)
if not won:
	sys.exit("no winner")
placed = re.findall(r"kit/flag 28: placed by Bot (\d+)", srv)
if not set(placed) & copies:
	sys.exit(f"placed by: {placed}")
# Account-bound: no bot a player entity (remembered by name), none a peer
for b in made + list(copies):
	if re.search(rf"Bot {b} is entity", srv):
		sys.exit(f"Bot {b} became a player entity")
if re.search(r"Peer \d+ .*Bot \d+", srv):
	sys.exit("a bot as a peer")
print(f"bots {' '.join(made)}; Red {sorted(red)}, Blue {sorted(blue)}; {won.group(0)}")
PY
verdict_keep
[ "$verdict_rc" = 0 ] && echo "PASS: four bots play a round of capture the flag, two against two, to a winner"
verdict_exit
# vim: set noet ts=4 sw=4:
