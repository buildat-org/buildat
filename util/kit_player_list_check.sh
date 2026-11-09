#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-09)
# covers: builtin/kit/types/ui_player_list.lua builtin/kit/client_lua/ui.lua
# [KIT_PLAYER_LIST] A kit/ui_player_list on Workbench. kitboss (the admin)
# places 3 kit/team Red, 4 kit/ui_button "Join red" -> 3 join, 5
# kit/scoreboard, 6 kit/ui_button "Score" -> 5 add and 7 the list, then
# comes back beside kitbob: he joins Red and scores twice. Both see
# "kitboss 2" in Red's colour over "kitbob 0" in none (boss.png).
# simplified: no bot yet ([KIT_BOTS] is not in this tree); a bot is a
# player entity and would be listed as one
#   util/kit_player_list_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_player_list; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
client() # <name>: its commands in $t/<name>.cmds
{
	sed -i "s|@T@|$t|g" "$t/$1.cmds"
	run_client 60 "$t/$1.log" timeout 180 bin/buildat -C "$t/client_cache_$1" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" || fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
n=0
edit()
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
place() { edit "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$2, 1, 6]}"; }
set_p() { edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
link() { edit "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"$2\", \"to\": $3, \"input\": \"$4\"}"; }
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
EOF
	place kit/team 0
	place kit/ui_button 1
	set_p 4 label '"Join red"'
	set_p 4 anchor '"left"'
	place kit/scoreboard 2
	place kit/ui_button 3
	set_p 6 label '"Score"'
	place kit/ui_player_list 4
	link 4 pressed 3 join
	link 6 pressed 5 add
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: ui 7 players
sync 2000
quit
EOF
} > "$t/boss1.cmds"
cat > "$t/boss2.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 30000 | kitbob 0
click Button "Join red"
wait_log_any 10000 kit: ui button 4 pressed
click Button "Score"
delay 300
click Button "Score"
wait_log_any 10000 : "Players | kitboss 2 #d03030 | kitbob 0 "
frames 10
screenshot @T@/boss.png
sync 3000
quit
EOF
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 60000 : "Players | kitboss 2 #d03030 | kitbob 0 "
frames 10
screenshot @T@/bob.png
sync 3000
quit
EOF
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss1
BUILDAT_JOIN_NAME=kitbob client bob &
bob=$!
BUILDAT_JOIN_NAME=kitboss client boss2
wait $bob || fail "client bob failed ($t/bob.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
grep -aq "kit/ui_player_list 7: players: kitboss #d03030 2, kitbob  0" "$t/srv.log" ||
	fail "the list's rows not as wanted ($t/srv.log)"
grep -aq "OFF SCREEN" "$t/boss2.log" "$t/bob.log" && fail "a UI component off the screen"
for p in boss bob; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
echo "PASS: a player list: names in their team's colour, scores, highest first, for both players; screenshots $t/boss.png $t/bob.png"
