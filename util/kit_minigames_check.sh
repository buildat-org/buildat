#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-03)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/box/box.c builtin/kit/types/arena.lua builtin/kit/types/team.lua builtin/kit/types/region.lua builtin/kit/types/team_match.prefab.json builtin/kit/client_lua/ui.lua apps/workbench/**
# [KIT_MINIGAMES_1] (kit_plan stage 7b, its first part) A round-based
# game from the palette: a fresh save on Workbench, the admin (kitboss)
# places kit/team_match (an arena -- the lobby, queue and round --, the
# teams Red and Blue with a base region and a button each) round a
# spawner, the teams' pads brought near it; the arena takes 2 to 4 with
# a 48 s countdown and a 120 s round (game time). Then:
#   1. kitboss in the zone waits alone; kitbob joins (the second): the
#      countdown starts; kitbob leaves (quits): it is cancelled.
#   2. kitbob again: the countdown's end makes session 1 with both, one
#      in each team, each on their team's pad; the round timer ticks.
#      kitbob's use of a team's button is refused in the default (no
#      team's member there) and taken for their own team in the round.
#      kitboss sets off Red's "add" 5: Red reaches its win_score, its
#      link into the arena's "win" ends the round, Red winning; the
#      scores shown; both back in the default.
#   3. Back in the zone: session 2; nobody wins: the timer's end makes
#      it a draw, shown in the default.
#   util/kit_minigames_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_minigames; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client() # <name>: its commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
{
	run_client 90 "$t/$1.log" timeout 400 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
export BUILDAT_JOIN_PASSWORD=checkpass12
ed() { printf 'event kit_edit %s\n' "$1"; }
edit() # <json> <undo count after>
{
	ed "$1"
	printf 'wait_log 10000 entities, %d to undo\n' "$2"
}
set_() # <id> <param> <value> <undo count after>
{
	edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}" "$4"
}
# The ids: 3 the World, the prefab's 4 arena, 5 Red, 6 Blue, 7 and 8
# their bases, 9 and 10 their buttons; 11 the spawner
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}' 1
	edit '{"op": "place", "prefab": "kit/team_match", "pos": [-2, 1, -2]}' 2
	edit '{"op": "move", "id": 5, "pos": [5, 1, 0]}' 3
	edit '{"op": "move", "id": 6, "pos": [-5, 1, 0]}' 4
	edit '{"op": "place", "type": "kit/spawner", "pos": [0, 1, 0]}' 5
	set_ 11 players true 6
	set_ 4 size '[5, 3, 5]' 7
	set_ 4 max_players 4 8
	# Game seconds: at CHECK_RATE 12, 4 s, 10 s and 2 s
	set_ 4 countdown 48 9
	set_ 4 duration 120 10
	set_ 4 results 24 11
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
wait_log 120000 kit editor: in session 1 game
keypress F6
wait_log 10000 kit editor: edit mode on
sync 2000
EOF
	# 2. Red's score to its win_score: the round's win
	ed '{"op": "try", "id": 5, "comp": 0, "input": "add", "value": 5}'
	cat <<'EOF'
wait_log 60000 kit editor: in session 0 default
wait_log 120000 kit editor: in session 2 game
wait_log 120000 kit editor: in session 0 default
sync 3000
quit
EOF
} > "$t/boss.cmds"
joined()
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
EOF
}
# 1. kitbob comes and goes during the countdown
{
	joined
	echo 'wait_log 60000 shown: "Starting in'
	echo quit
} > "$t/bob1.cmds"
# 2. kitbob for the rounds
{
	joined
	cat <<'EOF'
wait_log 60000 shown: "Starting in
event kit_use 9
event kit_use 10
sync 3000
wait_log 60000 shown: "Team
event kit_use 9
event kit_use 10
sync 3000
wait_log 60000 Red wins!
wait_log 60000 Last round: Red won
wait_log 120000 Last round: a draw
quit
EOF
} > "$t/bob2.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss &
boss=$!
wait_for_log "$t/srv.log" "kitboss entered; 1 of 2 inside" 240 ||
	fail "kitboss did not get into the arena's zone ($t/srv.log)"
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 client bob1
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE= client bob2
wait $boss || fail "the admin's client ($t/boss.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -a "kit/arena\|kit/team\|Session\|refused\|put at" "$s" |
	sed 's/^.*\(kit\|wasm\) *: /  /' | grep -v "^ *$" | cut -c1-160
# 1. The queue: one waits, a second starts the countdown, leaving cancels
want "$s" "kit/arena 4: kitboss entered; 1 of 2 inside" \
	"kit/arena 4: kitbob entered; 2 of 2 inside" \
	"kit/arena 4: countdown 48 s for 2 players" \
	"kit/arena 4: kitbob left: the countdown cancelled"
[ "$(grep -ac 'kit/arena 4: countdown over' "$s")" -ge 2 ] ||
	fail "not two rounds' countdowns ($s)"
echo "ok: a queue of 2 to 4: one waits, the second starts the countdown, a leave cancels it"
# 2. Session 1: both, one in each team, on its pad
want "$s" "kit/arena 4: countdown over: a round for 2 players" \
	"Session 1 (a game)" "kit/arena 4: round starts: 120 s"
python3 - "$s" <<'PY' || fail "the teams of session 1 ($s)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
s1 = log.split("Session 1 (a game)")[1].split("Session 1 ended")[0]
teams = dict(re.findall(r"kit/team \d+: (\w+) joins team (\w+)", s1))
assert sorted(teams) == ["kitbob", "kitboss"], teams
assert sorted(teams.values()) == ["Blue", "Red"], teams
pads = {"Red": "(5, 1, 0)", "Blue": "(-5, 1, 0)"}
for who, team in teams.items():
	assert "%s put at %s" % (who, pads[team]) in s1, (who, team, pads[team])
print("  " + ", ".join("%s in %s" % kv for kv in sorted(teams.items())))
PY
echo "ok: the countdown's end makes session 1 with both, one in each team, each on its team's pad"
want "$s" "kit/arena 4: round: 10 s left"
echo "ok: the round timer ticks"
want "$s" "Locked: its owners' only"
python3 - "$s" <<'PY' || fail "kitbob's use in the round ($s)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
s1 = log.split("Session 1 (a game)")[1].split("Session 1 ended")[0]
team = re.search(r"kitbob joins team (\w+)", s1).group(1)
button = {"Red": 9, "Blue": 10}[team]
assert "kit/button %d: pressed by kitbob" % button in s1, team
print("  kitbob's button (%s's) pressed in the round" % team)
PY
echo "ok: a team's button is its members' (a region owned by the team): refused in the default, kitbob's own in the round"
want "$s" "kit/arena 4: round over: Red wins!" "kit/arena 4: session 1 ended Red won (" \
	"Session 1 ended"
# (Red's 5, and kitbob's press of their own team's button)
grep -aq "kit/arena 4: round over: Red wins! Red [56] : Blue [01]" "$s" ||
	fail "no Red 5 in the result ($s)"
want "$t/bob2.log" "Red wins!" "Last round: Red won"
grep -aP 'Peer \d+ from session 1 to session 0' "$s" | wc -l | grep -qx 2 ||
	fail "not both back in the default after session 1 ($s)"
echo "ok: the win link ends the round, Red winning; the scores shown; both back in the default"
# 3. Session 2: the timer's end, a draw
want "$s" "Session 2 (a game)" "kit/arena 4: session 2 over: its time is up" \
	"kit/arena 4: round over: Draw" "kit/arena 4: session 2 ended a draw" \
	"Session 2 ended"
want "$t/bob2.log" "Last round: a draw"
echo "ok: the round timer's end without a win is a draw"
echo "PASS: minigames: the arena's queue (minimum, maximum, a countdown a leave cancels), a session for the round, two teams with their pads, a timer, the win link and a draw by time; team-owned regions"
# vim: set noet ts=4 sw=4:
