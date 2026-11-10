#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1.5 min (2026-11-10)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/editor_input.lua apps/workbench/templates/ctf/**
# [KIT_BUILDER_ROUND_CONTROLS] a builder ends the rounds and removes the bots
# from edit mode, whatever the template wires. A fresh Workbench project
# from the CTF template (the arena's countdown 1 s):
#   1. Played, two bots from the template's "Add bot": they queue and a
#      round starts with them (session 1); kitboss stays in the lobby.
#   2. kitbob (no edit rights) joins: his pause menu has neither control,
#      and his end_rounds and remove_bots are refused.
#   3. kitboss in edit mode: the template's bot items are out of the pause
#      menu, Kit's "End all rounds" and "Remove all bots" in it. Remove all
#      bots takes the two and their round's copies; End all rounds ends
#      session 1. Pressed again, each is refused: nothing left.
#   util/kit_builder_round_controls_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_builder_round_controls; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
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
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
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
srv() { await "$t/srv.log" "$SM" "$1" "$2"; }
srv_mark() { SM=$(mark "$t/srv.log"); }
menu() # the pause menu shown: its items line after <offset> in $M
{
	M=$(mark "$t/boss.log")
	step 10 "pause: the menu shown" "keypress Escape"
	cmd "frames 3"
}
pressed() # <button> <server regex>: in the pause menu
{
	srv_mark
	menu
	cmd "click Button \"$1\""
	srv 10 "$2"
}
await "$t/boss.log" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
step 30 "world_menu: the list shown" "frames 3"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New project..."'
cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked" 'click Text "Capture the flag"'
step 60 "player physics enabled" "frames 3" 'click Button "Create"'
await "$t/boss.log" 0 20 "kit editor: edit mode on"
ed '{"op": "set", "id": 7, "comp": 0, "param": "countdown", "value": 1}'
srv_mark
step 15 "the server is Running" 'event kit_edit {"op": "play"}'
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
# 1. Two bots into a round
for i in 1 2; do
	pressed "Add bot" "kit/spawner 61: made [0-9]+"
done
srv_mark
srv 60 "Session 1 \(a game\)"
srv 30 "into session 1 as Bot [0-9]+.*"
# 2. kitbob: no controls, refused
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 20000 kit: points at
frames 10
keypress Escape
wait_log 10000 pause: the items
keypress Escape
event kit_edit {"op": "end_rounds"}
wait_log 10000 kit editor: refused: end_rounds: no edit rights here
event kit_edit {"op": "remove_bots"}
wait_log 10000 kit editor: refused: remove_bots: no edit rights here
quit
EOF
BUILDAT_JOIN_NAME=kitbob run_client 60 "$t/bob.log" timeout 240 bin/buildat \
	-C "$t/client_cache_bob" -D "$t/cu_bob" -s localhost:$SERVER_PORT \
	-w 1024x700 -l 3 -c @"$t/bob.cmds" || fail "kitbob's client ($t/bob.log)"
items=$(grep -a "pause_me: pause: the items" "$t/bob.log" | tail -1)
case "$items" in *"Add bot"*) ;; *) fail "kitbob's menu has no Add bot: $items";; esac
case "$items" in *"all rounds"*|*"all bots"*) fail "kitbob's menu has a builder's item: $items";; esac
# 3. kitboss in edit mode: Kit's two, not the template's
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
menu
await "$t/boss.log" "$M" 10 "pause: the items .*End all rounds, Remove all bots"
items=$(tail -c +$((M + 1)) "$t/boss.log" | grep -a "pause_me: pause: the items" | tail -1)
case "$items" in *"Add bot"*) fail "the template's items in edit mode: $items";; esac
cmd "screenshot $t/menu.png" "keypress Escape" "frames 3"
pressed "Remove all bots" "kitboss removed all bots \(4\)"
pressed "End all rounds" "Session 1 ended by kitboss"
step 10 "refused: end_rounds: no round is running" 'event kit_edit {"op": "end_rounds"}'
step 10 "refused: remove_bots: no bots made in play" 'event kit_edit {"op": "remove_bots"}'
cmd quit
exec 3>&-
wait $CLIENT 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
grep -aq "kitboss ends all rounds (1)" "$t/srv.log" || fail "no ends all rounds (1) ($t/srv.log)"
grep -aq "An edit (end_rounds) by peer [0-9]* refused: no edit rights here" "$t/srv.log" ||
	fail "kitbob's end_rounds not refused by the server ($t/srv.log)"
grep -aq "Bot [0-9]* back from session 1" "$t/srv.log" &&
	fail "a removed bot came back from the round ($t/srv.log)"
echo "PASS: a builder's End all rounds and Remove all bots in edit mode; a player's refused"
