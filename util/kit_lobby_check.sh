#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-15)
# covers: builtin/kit/types/lobby.lua builtin/kit/types/ui_chat.lua builtin/kit/types/ui_view.lua builtin/kit/types/ui_panel.lua builtin/kit/client_lua/ui.lua builtin/kit/client_lua/editor.lua
# [KIT_LOBBY] A lobby on Workbench. kitboss (the admin) places 3 kit/lobby,
# its lobby screen 4 (a kit/ui_panel, screen full, to the player: 5 a
# kit/ui_chat, 6 Play -> 3 play, 7 a kit/ui_view following 3's entered and
# left), its result screen 8 (screen over: 9 a text, 10 Again -> 3 again,
# 11 Lobby -> 3 lobby), 12 a HUD panel with 13 Finish -> 3 over and 14 a
# HUD text. Back beside kitbob, each in the lobby (a full screen: no world,
# no HUD), kitboss says a line in the lobby's chat, plays (the screen
# gone, the view following him), finishes (the result card over the play),
# again, finishes, back to the lobby; then edits: kitbob's chat line from
# the lobby a notification in his edit mode. The desktop HUD view: the
# frame and the tool panel, its shape a phone's, its screen picker on the
# lobby. Screenshots: lobby.png, result.png, bob_lobby.png, notify.png,
# hud.png, hud_412x915.png, hud_lobby.png
#   util/kit_lobby_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_lobby; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
client() # <name> <size>: its commands in $t/<name>.cmds
{
	sed -i "s|@T@|$t|g" "$t/$1.cmds"
	run_client 60 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache_$1" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w "$2" -u 1 -l 3 \
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
in_panel() { edit "{\"op\": \"parent\", \"id\": $1, \"parent\": $2}"; }
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
	place kit/lobby 0
	place kit/ui_panel 1
	set_p 4 title '"Lobby"'
	set_p 4 screen '"full"'
	set_p 4 to '"player"'
	place kit/ui_chat 2
	in_panel 5 4
	place kit/ui_button 3
	in_panel 6 4
	set_p 6 label '"Play"'
	set_p 6 anchor '"center"'
	link 6 pressed 3 play
	place kit/ui_view 4
	in_panel 7 4
	set_p 7 title '"On the track"'
	link 3 entered 7 follow
	link 3 left 7 unfollow
	place kit/ui_panel 5
	set_p 8 title '"Result"'
	set_p 8 screen '"over"'
	set_p 8 to '"player"'
	set_p 8 layout '"column"'
	set_p 8 width 0
	set_p 8 height 0
	place kit/ui_text 6
	in_panel 9 8
	set_p 9 text '"Your time: 0:42"'
	place kit/ui_button 7
	in_panel 10 8
	set_p 10 label '"Again"'
	link 10 pressed 3 again
	place kit/ui_button 8
	in_panel 11 8
	set_p 11 label '"Lobby"'
	link 11 pressed 3 lobby
	place kit/ui_panel 9
	set_p 12 title '"Run"'
	set_p 12 anchor '"top_left"'
	set_p 12 shown true
	place kit/ui_button 10
	in_panel 13 12
	set_p 13 label '"Finish"'
	link 13 pressed 3 over
	place kit/ui_text 11
	set_p 14 text '"Builder away"'
	set_p 3 lobby_screen 4
	set_p 3 over_screen 8
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: ui full screen 4 up
sync 2000
quit
EOF
} > "$t/boss1.cmds"
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 30000 kit: ui full screen 4 up
wait_log_any 30000 kit: ui 7 view
click LineEdit "kit chat 5"
delay 300
text hello lobby
delay 300
keypress Return
wait_log_any 10000 kit: ui chat 5 said (11 bytes)
wait_log_any 10000 hello lobby"
frames 10
screenshot @T@/lobby.png
click Button "Play"
wait_log 10000 kit: ui full screen none
wait_log_any 10000 shown: "Builder away"
frames 5
click Button "Finish"
wait_log 10000 shown, layer 8: "Result"
frames 10
screenshot @T@/result.png
click Button "Again"
wait_log 10000 hidden, layer 8: "Result"
frames 5
click Button "Finish"
wait_log 10000 shown, layer 8: "Result"
frames 5
click Button "Lobby"
wait_log 10000 kit: ui full screen 4 up
frames 5
keypress F6
wait_log 10000 kit editor: edit mode on
EOF
	cat <<'EOF'
event kit_edit {"op": "set", "id": 14, "comp": 0, "param": "text", "value": "Builder here"}
wait_log_any 10000 : "Builder here"
wait_log_any 60000 kit: chat while editing:
frames 10
screenshot @T@/notify.png
keypress F4
wait_log 10000 kit editor: the view is HUD
wait_log_any 10000 kit editor: the HUD tool panel
frames 10
screenshot @T@/hud.png
click DropDownList "hud shape"
wait_log 10000 hud shape open
frames 3
click Text "hud shape: Phone 412x915"
wait_log 10000 kit editor: the HUD view's shape is 412x915
frames 10
screenshot @T@/hud_412x915.png
click DropDownList "hud screen"
wait_log 10000 hud screen open
frames 3
click Text "hud screen: ◆ 4 ui_panel"
wait_log 10000 kit editor: the HUD view shows screen 4
frames 10
screenshot @T@/hud_lobby.png
sync 3000
quit
EOF
} > "$t/boss2.cmds"
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 30000 kit: ui full screen 4 up
wait_log_any 120000 : "Builder here"
click LineEdit "kit chat 5"
delay 300
text hi builder
delay 300
keypress Return
wait_log_any 10000 kit: ui chat 5 said (10 bytes)
wait_log_any 10000 hi builder"
frames 10
screenshot @T@/bob_lobby.png
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
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss1 1280x720
BUILDAT_JOIN_NAME=kitbob client bob 1024x600 &
bob=$!
BUILDAT_JOIN_NAME=kitboss client boss2 1280x720
wait $bob || fail "client bob failed ($t/bob.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log b=$t/boss2.log
for l in "kit/lobby 3: kitboss: none -> lobby" "kit/lobby 3: kitboss: lobby -> playing" \
		"kit/lobby 3: kitboss: playing -> over" "kit/lobby 3: kitboss: over -> lobby" \
		"kit/lobby 3: kitbob: none -> lobby" "kit/ui_view 7: follows kitboss"; do
	grep -aqF "$l" "$s" || fail "no \"$l\" ($s)"
done
# Again from the result: over -> playing a second time
[ "$(grep -acF "kit/lobby 3: kitboss: over -> playing" "$s")" -ge 1 ] ||
	fail "Again did not start a run ($s)"
grep -aqF "kit: chat while editing: " "$b" || fail "no chat notification ($b)"
grep -aqF "hi builder" "$b" || fail "kitbob's line did not reach kitboss ($b)"
# The tool panel and its frame: the room left, then a phone's, centred
grep -aqP "the HUD tool panel 390x720, the frame 0 0 890 720$" "$b" ||
	fail "the tool panel or the frame not as wanted ($b)"
grep -aqP "the HUD tool panel 390x720, the frame 283 0 324 720$" "$b" ||
	fail "the 412x915 frame not as wanted ($b)"
grep -aq "OFF SCREEN" "$b" "$t/bob.log" && fail "a UI component off the screen"
for p in lobby result bob_lobby notify hud hud_412x915 hud_lobby; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
echo "PASS: a lobby: each player's lobby, run and result screens, its chat and view, chat lines a builder's notifications, the desktop HUD view's frame, shapes and screens; screenshots in $t"
