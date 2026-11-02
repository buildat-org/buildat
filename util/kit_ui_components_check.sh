#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-02)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/types/ui_*.lua builtin/kit/types/scoreboard.lua builtin/kit/client_lua/ui.lua builtin/kit/client_lua/module.lua builtin/kit/client_lua/controls.lua
# [KIT_UI_COMPONENTS] UI as screen-space components (stage 4m) on
# Workbench. kitboss (the admin, 1024x700) places by the editor's packets
#   3 kit/ui_text "Presses: {value}" (top), 4 kit/ui_button "Press me"
#   (bottom), 5 kit/counter, 6 kit/ui_bar 0..4 (top left), 7 kit/ui_panel
#   "Hello" for the player (to "player"), in it 8 a kit/ui_text with
#   "[fire]" and 9 kit/ui_button "Close" (closes), 10 kit/action fire
#   (key R) and 11 a kit/ui_button bound to it (no label: "Fire");
#   4 pressed -> 5 count and -> 7 show, 5 changed -> 3 value and 6 value;
# and the checks:
#   1. edit mode draws every UI component framed, the hidden dialog too
#      (overlay.png); a click on "Press me" selects it, a drag moves it;
#   2. play: kitboss clicks "Press me": the text says "Presses: 1", the bar
#      0.25 full, the dialog his (play.png); "Close" hides it; the bound
#      button presses the action (the server's "Action fire pressed");
#   3. a flood of 2000 presses of 4: at most the acts' burst reaches it
#      (the counter), as kit:action's;
#   4. kitbob (a second player, 1024x700) is not shown kitboss's dialog,
#      and a press of its Close sent anyway is refused "not on their
#      screen"; his own press shows him his own;
#   5. every UI component on the screen at 1024x700 (no "OFF SCREEN"),
#      and in the web client by finger (TOUCH=1, 1000x500, headless
#      Chrome), a guest: a tap on "Press me" shows them their dialog
#      (touch.png),
#      the bottom button over the touch bars.
# Screenshots kept with KEEP_TMP=1: $t/overlay.png, $t/play.png,
# $t/bob.png, $t/drive/touch.png; look at them.
#   util/kit_ui_components_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_ui_components; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

client() # <name>: its commands in $t/<name>.cmds
{
	sed -i "s|@T@|$t|g" "$t/$1.cmds"
	run_client 60 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" || fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}

n=0
edit() # <op json>: an edit and its answer
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
place() # <type> <x>
{
	edit "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$2, 1, 6]}"
}
set_p() # <id> <param> <json value>
{
	edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
}
link() # <from> <output> <to> <input>
{
	edit "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"$2\", \"to\": $3, \"input\": \"$4\"}"
}
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
	place kit/ui_text 0
	set_p 3 text '"Presses: {value}"'
	place kit/ui_button 1
	set_p 4 label '"Press me"'
	place kit/counter 2
	place kit/ui_bar 3
	set_p 6 label '"Presses {value} of 4"'
	set_p 6 max 4
	set_p 6 start 0
	place kit/ui_panel 4
	set_p 7 to '"player"'
	set_p 7 title '"Hello"'
	place kit/ui_text 5
	set_p 8 panel 7
	set_p 8 anchor '"top_left"'
	set_p 8 y 0
	set_p 8 text '"Only you see this. [fire] fires."'
	place kit/ui_button 6
	set_p 9 panel 7
	set_p 9 label '"Close"'
	set_p 9 closes true
	set_p 9 anchor '"bottom_right"'
	set_p 9 y 0
	place kit/action 7
	place kit/ui_button 8
	set_p 11 action '"fire"'
	set_p 11 label '""'
	set_p 11 anchor '"right"'
	set_p 11 x 12
	link 4 pressed 5 count
	link 4 pressed 7 show
	link 5 changed 3 value
	link 5 changed 6 value
	cat <<'EOF'
wait_log_any 10000 kit: ui 9 button
frames 10
screenshot @T@/overlay.png
click Button "Press me"
wait_log 10000 kit editor: selected 4
mouse_down left
delay 100
mouse_pos 562 647
delay 200
mouse_pos 612 647
delay 200
mouse_up left
wait_log 10000 kit: ui 4 dragged to
EOF
	n=$((n + 2))
	printf 'wait_log 10000 entities, %d to undo\n' "$n"
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
frames 10
click Button "Press me"
wait_log 10000 shown: "Hello"
wait_log_any 10000 shown: "Presses: 1"
frames 10
screenshot @T@/play.png
click Button "Fire"
wait_log 10000 kit: action fire released
click Button "Close"
wait_log 10000 kit: ui button 9 pressed
sync 3000
event kit_ui_flood 4 2000
sync 3000
delay 1500
sync 3000
quit
EOF
} > "$t/kitboss.cmds"
cat > "$t/kitbob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit: ui 9 button
frames 10
event kit_ui_flood 9 1
sync 3000
click Button "Press me"
wait_log 10000 shown: "Hello"
frames 10
screenshot @T@/bob.png
sync 3000
quit
EOF

web=""
if command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ]; then
	web="-W $here/web"
fi
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 $web \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client kitboss
BUILDAT_JOIN_NAME=kitbob client kitbob
if [ -n "$web" ]; then
	# A guest (Workbench lets one in, no login)
	cat > "$t/web.json" <<'J'
[
 ["nav", "${URL}"],
 ["waitlog", "player physics enabled", 120],
 ["waitlog_any", "kit: ui 9 button", 30], ["frames", 10],
 ["tap", "Button", "Press me"], ["waitlog", "kit: ui 7 panel .* shown: ", 10],
 ["frames", 10], ["shot", "${OUT}/touch.png"], ["sync", 3000]
]
J
	TOUCH=1 WEB_DRIVE_VIEWPORT=1000x500@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/web.json" "$t/drive" \
		> "$t/drive.txt" 2>&1 || fail "the web drive ($(tail -2 "$t/drive.txt"), $t/drive)"
fi
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
b=$t/kitboss.log o=$t/kitbob.log s=$t/srv.log
grep -a "kit: ui [0-9]\|UI button\|UI press\|Action fire" "$b" "$o" "$s" |
	sed 's/^.*\(kit\|kit\.cpp\)[a-z_/ 0-9]*: //' | cut -c1-160 | head -60

# 1. The overlay
want "$b" "kit: ui 7 panel" "kit: ui 4 dragged to"
grep -aqP 'kit: ui 7 panel at .* shown, edit mode, hidden in play: "Hello"' "$b" ||
	fail "edit mode did not draw the hidden dialog ($b)"
want "$s" "set 4's kit/ui_button x to"
echo "ok: edit mode: every UI component drawn, the hidden dialog too; a click selects one, a drag moves it"
# 2. Play
want "$b" 'kit: ui 3 text' '"Presses: 1"' 'kit: ui button 11 pressed (action fire)'
grep -aP 'kit: ui 6 bar .*0\.25 full' "$b" | grep -q . || fail "the bar did not follow the count ($b)"
want "$s" "UI button 4 pressed by kitboss" "kit/counter 5: count 1 by kitboss" \
	"Action fire pressed by kitboss" "UI button 9 pressed by kitboss" \
	"kit/ui_panel 7: shown for kitboss" "kit/ui_panel 7: hidden for kitboss"
grep -aq 'kit: ui 8 text .*"Only you see this. \[R\] fires."' "$b" ||
	fail "the dialog's text has no [R] for [fire] ($b)"
echo "ok: play: the button counts, the text and the bar follow, the dialog is the presser's, Close hides it, a bound button presses its action"
# 3. The flood
p=$(grep -ac "UI button 4 pressed by kitboss" "$s")
[ "$p" -ge 2 ] && [ "$p" -le 50 ] ||
	fail "the flood's 2000 presses reached the button $p times ($s)"
echo "ok: a flood of 2000 presses: $p reached the button"
# 4. Per player
awk '/kit: flooding|kit: ui button 4 pressed/ { exit } /kit: ui 7 panel .* shown/ { bad = 1 } END { exit bad }' "$o" ||
	fail "kitbob was shown kitboss's dialog ($o)"
want "$s" "A UI press of 9 1 from peer" "refused: not on their screen" \
	"UI button 4 pressed by kitbob" "kit/ui_panel 7: shown for kitbob"
grep -aq "UI button 9 pressed by kitbob" "$s" && fail "kitbob pressed a button not on his screen ($s)"
echo "ok: the dialog only its player's; a press of a button not on the screen refused"
# 5. On the screen
grep -aq "OFF SCREEN" "$b" "$o" && fail "a UI component off the screen at 1024x700 ($(grep -al "OFF SCREEN" "$b" "$o"))"
for p in overlay play bob; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
if [ -z "$web" ]; then
	echo "PASS: Kit's UI components natively (the web skipped: no Chrome or web/); screenshots $t/overlay.png $t/play.png $t/bob.png"
	exit 0
fi
pl=$t/drive/page.log
grep -aq "OFF SCREEN" "$pl" && fail "a UI component off the screen on the web by finger ($pl)"
grep -aqP "UI button 4 pressed by p\\d+" "$s" && grep -aqP "kit/ui_panel 7: shown for p\\d+" "$s" ||
	fail "the guest's tap did not press the button and show their dialog ($s)"
# The bottom button over the touch bars: its foot above the bars' top
foot=$(grep -aoP 'kit: ui 4 button at \d+,\K\d+ \d+x\d+' "$pl" | tail -1 |
	awk '{ split($2, s, "x"); print $1 + s[2] }')
bars=$(grep -aoP 'kit: ui touch bars at y \K\d+' "$pl" | tail -1)
[ -n "$foot" ] && [ -n "$bars" ] && [ "$foot" -le "$bars" ] ||
	fail "the bottom button (foot $foot) not over the touch bars ($bars; $pl)"
[ -s "$t/drive/touch.png" ] || fail "no screenshot $t/drive/touch.png"
echo "PASS: Kit's UI components: the overlay, a text and a bar following a signal, a button's press linked and flooded, a per-player dialog, on the screen natively and on the web by finger; screenshots $t/overlay.png $t/play.png $t/bob.png $t/drive/touch.png"
