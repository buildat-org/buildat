#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-04)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/types/arena.lua builtin/kit/types/team.lua apps/workbench/**
# kit/arena's rounds: [KIT_ARENA_SCORE_TO_WIN], [KIT_ARENA_INSTANT_ROUND],
# [KIT_LATE_JOIN]. A fresh Workbench save, the admin (kitboss) places
# kit/team_match round the spawn (the arena's zone over it: players come
# and come back into the queue); the arena: 2 to 3 players, score_to_win
# 3, after_round 120, late_join "join_or_parallel", join_team
# "lowest_score", max_rounds 2 (game seconds; CHECK_RATE 12).
#   1. kitboss and kitbob: session 1, a team each; kitbob scores for his
#      team; kitcat comes: into the running round (room for 3), late, into
#      the team with the lower score (kitboss's); kitcat scores to 3: the
#      round ends as his team's win by the score to win.
#   2. All three back in the queue: the countdown 120 s (after_round, not
#      the 24 s countdown). kitboss sets max_players 2, players 1, duration
#      60 meanwhile: session 2 takes two, the third waits and starts
#      session 3 alongside (a parallel round; join_or_parallel with no
#      room). Session 2's players back in the queue count down 120 s
#      again; session 3's end starts that countdown over.
#   util/kit_arena_rounds_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_arena_rounds; t=$CHECK_TMP
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
ed() { printf 'event kit_edit %s\nwait_log 10000 kit editor: state:\n' "$1"; }
set_() # <id> <param> <value>
{
	ed "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
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
	ed '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	ed '{"op": "place", "prefab": "kit/team_match", "pos": [-2, 1, -2]}'
	ed '{"op": "move", "id": 5, "pos": [5, 1, 0]}'
	ed '{"op": "move", "id": 6, "pos": [-5, 1, 0]}'
	ed '{"op": "place", "type": "kit/spawner", "pos": [0, 1, 0]}'
	set_ 11 players true
	set_ 4 size '[5, 3, 5]'
	set_ 4 players 2
	set_ 4 max_players 3
	set_ 4 countdown 24
	set_ 4 duration 2400
	set_ 4 results 12
	set_ 4 score_to_win 3
	set_ 4 after_round 120
	set_ 4 late_join '"join_or_parallel"'
	set_ 4 join_team '"lowest_score"'
	set_ 4 max_rounds 2
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log 120000 kit editor: in session 1 game
wait_log 120000 kit editor: in session 0 default
keypress F6
wait_log 10000 kit editor: edit mode on
EOF
	set_ 4 max_players 2
	set_ 4 players 1
	set_ 4 duration 60
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log 200000 Last round: a draw
delay 15000
quit
EOF
} > "$t/boss.cmds"
joined() # <name>
{
	printf 'wait_log_any 60000 Joined as %s\nwait_log_any 60000 player physics enabled\n' "$1"
}
press() # <times>: both teams' buttons (the other's refused)
{
	local i
	for i in $(seq "$1"); do
		printf 'event kit_use 9\nevent kit_use 10\nsync 3000\ndelay 1000\n'
	done
}
tail_cmds()
{
	cat <<'EOF'
wait_log 200000 Last round: a draw
delay 15000
quit
EOF
}
{
	joined kitbob
	echo 'wait_log 60000 shown: "Team'
	press 2
	echo 'wait_log_any 200000 wins! | Round ended by lobby: score to win (3)'
	tail_cmds
} > "$t/bob.cmds"
{
	joined kitcat
	echo 'wait_log 60000 shown: "Team'
	press 6
	echo 'wait_log_any 200000 wins! | Round ended by lobby: score to win (3)'
	tail_cmds
} > "$t/cat.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
export BUILDAT_JOIN_CREATE=1
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss &
boss=$!
wait_for_log "$t/srv.log" "kitboss entered; 1 of 2 inside" 240 ||
	fail "kitboss did not get into the arena's zone ($t/srv.log)"
BUILDAT_JOIN_NAME=kitbob client bob &
bob=$!
wait_for_log "$t/srv.log" "kit/team [56]: score 1 by kitbob" 240 ||
	fail "kitbob did not score ($t/srv.log)"
BUILDAT_JOIN_NAME=kitcat client cat
wait $bob || fail "kitbob's client ($t/bob.log)"
wait $boss || fail "kitboss's client ($t/boss.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -a "kit/arena\|joins team\|Session [0-9]" "$s" | grep -v "s left" |
	sed 's/^.*\(kit\|wasm\) *: /  /' | grep -v "^ *$" | cut -c1-160
python3 - "$s" <<'PY' || fail "the rounds ($s)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
A = "kit/arena 4: "
def part(n):
	return log.split("Session %d (a game)" % n)[1].split("Session %d ended" % n)[0]
# 1. the late join by the lower score, the win by the score to win
s1 = part(1)
teams = dict(re.findall(r"kit/team \d+: (\w+) joins team (\w+)", s1))
assert sorted(teams) == ["kitbob", "kitboss", "kitcat"], teams
assert teams["kitbob"] != teams["kitboss"], teams
assert re.search(A + r"kitcat joins the running round in session 1 \(2 in it\)", log), "no late join"
assert A + "kitcat joins late (lowest_score)" in s1
assert teams["kitcat"] == teams["kitboss"], ("not the lower score's team", teams)
win = teams["kitcat"]
m = re.search(A + r"session 1 over: %s has 3 of 3 points" % win, s1)
assert m, "no win by the score to win"
assert "round over: %s wins!" % win in s1 and "Round ended by lobby: score to win (3)" in s1
print("  session 1: %s; kitcat late into %s; %s wins at 3" % (teams, win, win))
# 2. the countdown after the round, the parallel round, the restart
after1 = log.split("Session 1 ended")[1]
c = re.search(A + r"countdown (\d+) s for", after1)
assert c and c.group(1) == "120", "the countdown after round 1: " + (c.group(0) if c else "none")
assert A + "countdown over: a round for 2 players" in after1
s2_at, s3_at = log.find("Session 2 (a game)"), log.find("Session 3 (a game)")
assert 0 < s2_at < s3_at < log.find("Session 2 ended"), "session 3 not alongside session 2"
assert A + "countdown over: a round for 1 players" in log[s2_at:s3_at]
assert A + "session 2 over: its time is up" in log and A + "session 3 over: its time is up" in log
after2 = log.split("Session 2 ended")[1]
c = re.search(A + r"countdown (\d+) s for", after2)
assert c and c.group(1) == "120", "the countdown after round 2: " + (c.group(0) if c else "none")
after3 = log.split("Session 3 ended")[1]
assert A + "a round ended: the countdown starts over, 120 s" in after3, "no restart"
print("  ok")
PY
echo "PASS: kit/arena: a late joiner into the running round's lower-scored team, the win by the score to win, the countdown after a round (after_round), a parallel round for the one left waiting, and a running countdown started over at a round's end"
# vim: set noet ts=4 sw=4: