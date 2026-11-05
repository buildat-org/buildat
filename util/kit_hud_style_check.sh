#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-05)
# covers: builtin/kit/client_lua/ui.lua builtin/kit/client_lua/inventory.lua builtin/kit/client_lua/hands.lua builtin/kit/client_lua/players.lua builtin/kit/types/ui_*.lua builtin/kit/types/game_rules.lua builtin/kit/types/timer.lua builtin/kit/client_data/hud_atlas.png
# [KIT_HUD_STYLE] The UI components' styles on Workbench. kitboss (the admin,
# 1024x700 at UI scale 1: 1 percent 7 UI units) places elements by the
# editor's packets, and the checks:
#   1. a bar at 50 in each of the four directions: its fill's rectangle; a
#      pie at 25: step 8 of 32; at 100: 32;
#   2. {value:time}, {value:int} and {value} of one value;
#   3. sizes by vmin: kitbob's 1400x1000 (1 percent 10 units);
#   4. a long label in a narrow bar: its font shrunk from 14, then clipped;
#   5. order (a text over a bar, in the log and on overlay.png);
#   6. a column panel of three, the middle one hidden: no gap for it, and a
#      panel of no background not drawn while all its children are hidden;
#   7. blink_below, kit/timer's progress into a bar;
#   8. "plain" on a text and a bar (play.png);
#   9. edit mode: a drag in whole percents, one snapped to another's edge, a
#      handle's resize; Kit's own hotbar dragged, kit/game_rules placed to
#      keep it, and there after the server's restart (kitcat's client);
#      in 2D and 3D no HUD, in Walk it is back; a UI component chosen (its
#      palette button, its prefab's, one selected) goes to Walk, kit/flag's
#      button does not;
#      [KIT_HUD_VIEW] F4 from 2D: no panels, the world's keys and clicks not
#      taken, the HUD still dragged; Escape back to 2D; again, a double click
#      on nothing back to 2D, one on the hotbar's frame not;
#  10. copy style from one bar to another: the style's parameters set,
#      x, y, label and the links not;
#  11. a save's version 1 kit/ui_text's pixels converted against 1080 p at
#      load: the same pixels at the automatic scale (kitdan, 1 percent 10.8),
#      version 2 in the save afterwards;
#  12. the health bar: a bar in Kit's HUD, as the rules' health_* say;
#  13. the web client (headless Chrome, WebGL): the same elements, the pies
#      from the atlas ($t/drive/web.png).
# Screenshots kept with KEEP_TMP=1: $t/overlay.png (edit mode), $t/inspector.png
# (the handles), $t/copy_list.png (the dropdown), $t/play.png,
# $t/big.png (kitbob's larger window), $t/big_menu.png (the menu over them all),
# $t/after.png, $t/auto.png; look at them.
#   util/kit_hud_style_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_hud_style; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1


client() # <name> <window> [client's options]: its commands in $t/<name>.cmds
{
	local name=$1 win=$2
	shift 2
	sed -i "s|@T@|$t|g" "$t/$name.cmds"
	run_client 60 "$t/$name.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$name" -s localhost:$SERVER_PORT -w "$win" -l 3 "$@" \
		-c @"$t/$name.cmds" || fail "client $name failed ($t/$name.log, $t/srv.log)"
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
wantp() # <log> <perl regex>
{
	grep -aqP -- "$2" "$1" || fail "no /$2/ in $1"
}
serve() # <log>
{
	start_server "$1" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 $web \
		--sim-rate "$CHECK_RATE" || fail "the server did not come up ($1)"
	CHECK_PIDS+=($SERVER_PID)
}
web=""
if command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ]; then
	web="-W $here/web"
fi
stop_server()
{
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}

edit() # <op json>: an edit and its answer
{
	printf 'event kit_edit %s\nwait_log 10000 kit editor: state:\n' "$1"
}
id=2
place() # <type>: the next id
{
	id=$((id + 1))
	edit "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$id, 1, 6]}"
}
sets() # <id> <param> <json> ...
{
	local i=$1
	shift
	while [ $# -gt 0 ]; do
		edit "{\"op\": \"set\", \"id\": $i, \"comp\": 0, \"param\": \"$1\", \"value\": $2}"
		shift 2
	done
}
bar() # <direction> <x> <y> <w> <h>: at 50
{
	place kit/ui_bar
	sets $id direction "\"$1\"" x "$2" y "$3" width "$4" height "$5" start 50 label '""'
}
drag() # <from x> <from y> <to x> <to y>: the mouse, in steps
{
	printf 'frames 5\nmouse_pos %d %d\nframes 2\nmouse_down left\ndelay 50\nmouse_pos %d %d\ndelay 50\nmouse_pos %d %d\ndelay 50\nmouse_up left\n' \
		"$1" "$2" $((($1 + $3) / 2)) $((($2 + $4) / 2)) "$3" "$4"
}
answers() # <n>: that many edits' answers
{
	local i
	for i in $(seq "$1"); do
		echo "wait_log 10000 kit editor: state:"
	done
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
	# 9. First, with little on the screen to snap to, right of the editor's
	# panel (408 wide): 1 percent 7 units
	place kit/ui_text; DRAG=$id
	sets $id text '"Drag"' anchor '"top_left"' x 60 y 30
	place kit/ui_bar; EDGE=$id
	sets $id label '"edge"' anchor '"top_left"' x 86.5 y 60 width 12 height 4 color '"#ff00ff"' direction '"top_to_bottom"' blink_below 0.5 background '"#102030a0"'
	place kit/ui_bar; SIZED=$id
	sets $id label '"sized"' anchor '"top_left"' x 50 y 60 width 20 height 4
	echo "wait_log_any 10000 kit: ui $SIZED bar"
	# 60, 30 by 12, 5 percents, nothing near
	drag 440 220 524 255
	echo "wait_log 10000 kit: ui $DRAG dragged to 72, 35"
	answers 2
	# Its left edge at 86.14 percents: the other's at 605 of 7 units a percent, not 86
	drag 524 255 623 255
	echo "wait_log 10000 kit: ui $DRAG dragged to 86.43, 35 (snapped)"
	answers 2
	# The selected one's corner handle, at (490, 448): 20 x 4 -> 25 x 6
	cat <<EOF
event kit_select $SIZED
wait_log_any 10000 kit editor: selected $SIZED
EOF
	drag 490 448 525 462
	echo "wait_log 10000 kit: ui $SIZED resized to 25 x 6"
	answers 4
	# Kit's own hotbar, from the bottom's middle
	cat <<EOF
event kit_select
wait_log_any 10000 kit: ui own:hotbar own at
EOF
	drag 512 665 512 500
	echo "wait_log 10000 kit: ui own:hotbar dragged to"
	echo "wait_log 10000 kit: ui own:hotbar own at"
	# In edit mode the HUD is the Walk view's
	for v in "F2 3D" "F3 Walk" "F1 2D" "F3 Walk"; do
		printf 'keypress %s\nwait_log_any 10000 kit editor: the view is %s\ndelay 300\n' $v
	done
	# To choose a UI component goes to Walk: one selected, its palette
	# button, its prefab's; another type's stays
	cat <<EOF
keypress F2
frames 5
event kit_select $SIZED
frames 5
keypress F1
frames 5
click Button "kit/flag"
frames 5
click Button "kit/flag"
frames 5
mouse_pos 60 300
frames 2
$(for i in $(seq 20); do printf 'mouse_wheel -1\nframes 1\n'; done)
frames 5
click Button "kit/ui_bar"
frames 5
click Button "kit/ui_bar"
frames 5
keypress F2
frames 5
click Button "[kit/health_bar]"
frames 5
click Button "[kit/health_bar]"
frames 5
EOF
	# The HUD view, from 2D (kitboss's last was Walk). Escape; a double click
	# on the hotbar stays, on nothing goes back
	cat <<EOF
keypress F1
frames 5
keypress F4
frames 5
screenshot @T@/hud_view.png
keypress T
frames 5
EOF
	drag 512 503 512 480
	cat <<EOF
wait_log 10000 kit: ui own:hotbar dragged to
keypress Escape
frames 5
keypress F4
frames 5
mouse_pos 512 480
frames 2
mouse_click left
mouse_click left
frames 5
screenshot @T@/hud_view2.png
mouse_pos 300 300
frames 2
mouse_click left
mouse_click left
frames 5
screenshot @T@/hud_view3.png
keypress F3
frames 5
EOF
	id=$((id + 1)) # kit/game_rules, placed to keep it
	echo "sync 3000"
	# 1. Four directions at the left, a pie and a full one
	bar left_to_right 2 10 20 3; L2R=$id
	bar right_to_left 2 14 20 3; R2L=$id
	bar bottom_to_top 2 18 3 20; B2T=$id
	bar top_to_bottom 6 18 3 20; T2B=$id
	place kit/ui_bar; PIE=$id
	sets $id form '"pie"' start 25 label '"{value:int}"' x 10 y 18
	place kit/ui_bar; PIE_FULL=$id
	sets $id form '"pie"' start 100 label '""' x 18 y 18 width 12
	# 2. The formats
	place kit/ui_text; FMT=$id
	sets $id text '"{value:time} / {value:int} / {value}"' anchor '"top"' y 12
	# 4. A long label in a narrow bar
	place kit/ui_bar; LONG=$id
	sets $id label '"A label a good deal longer than this bar"' x 2 y 40 width 12 height 3 size 2
	# 5. A text over a bar, by order; a text under one
	place kit/ui_bar; UNDER=$id
	sets $id label '""' x 2 y 45 width 24 height 4 start 100 order 1
	place kit/ui_text; OVER=$id
	sets $id text '"over the bar"' anchor '"top_left"' x 3 y 45 background '"none"' border '"none"' order 2
	place kit/ui_text; BEHIND=$id
	sets $id text '"under the bar"' anchor '"top_left"' x 14 y 45 background '"none"' border '"none"' order 0
	# 6. A column: A, B (hidden), C; a panel with only hidden children
	place kit/ui_panel; COL=$id
	sets $id layout '"column"' gap 1 width 0 height 0 anchor '"top_right"' x 2 y 10 shown true background '"none"' border '"none"'
	place kit/ui_text; A=$id
	sets $id panel $COL text '"First"'
	place kit/ui_text; B=$id
	sets $id panel $COL text '"Hidden"' shown false
	place kit/ui_text; C=$id
	sets $id panel $COL text '"Third"'
	place kit/ui_panel; EMPTY=$id
	sets $id layout '"row"' width 0 height 0 anchor '"right"' shown true background '"none"' border '"none"'
	place kit/ui_text; EMPTY_KID=$id
	sets $id panel $EMPTY text '"Nothing shown"' shown false
	# 7. Blink, a timer's progress
	place kit/ui_bar; BLINK=$id
	sets $id x 2 y 52 width 20 height 3 start 10 blink_below 0.25 label '"low"' color '"#d82828"'
	place kit/ui_bar; PROG=$id
	sets $id x 30 y 12 width 12 height 2 min 0 max 1 start 0 label '"prog {value}"'
	place kit/timer; TIMER=$id
	sets $id interval 0.5 repeats 4
	edit "{\"op\": \"link\", \"id\": $TIMER, \"comp\": 0, \"output\": \"progress\", \"to\": $PROG, \"input\": \"value\"}"
	# 8. Plain
	place kit/ui_bar; PBAR=$id
	sets $id style '"plain"' anchor '"bottom_right"' x 2 y 20 width 20 height 3 start 60 color '"#40c040"' label '"plain"'
	place kit/ui_text; PTEXT=$id
	sets $id style '"plain"' text '"plain text"' anchor '"bottom_right"' x 2 y 25
	# 10. Copy style, from the edge one, by the sheet's dropdown
	STYLE_FROM=$EDGE
	place kit/ui_bar; STYLE_TO=$id
	sets $id label '"copy to"' anchor '"top_left"' x 60 y 70 width 10 height 3
	edit "{\"op\": \"link\", \"id\": $TIMER, \"comp\": 0, \"output\": \"progress\", \"to\": $STYLE_TO, \"input\": \"value\"}"
	cat <<EOF
wait_log_any 10000 kit: ui $STYLE_TO bar
frames 10
screenshot @T@/overlay.png
event kit_select $STYLE_TO
wait_log_any 5000 kit editor: selected $STYLE_TO
delay 500
screenshot @T@/inspector.png
mouse_pos 882 350
frames 5
mouse_click left
delay 500
screenshot @T@/copy_list.png
click Text "$STYLE_FROM kit/ui_bar $STYLE_FROM"
wait_log_any 10000 kit editor: copied the style of $STYLE_FROM to $STYLE_TO
sync 3000
event kit_edit {"op": "try", "id": $FMT, "input": "value", "value": 125.4}
wait_log 10000 2:05 / 125 / 125.4
event kit_edit {"op": "try", "id": $TIMER, "input": "start"}
wait_log 15000 "prog 1"
keypress F6
wait_log 10000 kit editor: edit mode off
frames 10
screenshot @T@/play.png
sync 3000
quit
EOF
} > "$t/kitboss.cmds"
cat > "$t/kitbob.cmds" <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit: ui $STYLE_TO bar
frames 20
screenshot @T@/big.png
keypress Escape
delay 500
screenshot @T@/big_menu.png
keypress Escape
sync 3000
quit
EOF
serve "$t/srv.log"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client kitboss 1024x700 -u 1
BUILDAT_JOIN_NAME=kitbob client kitbob 1400x1000 -u 1
if [ -n "$web" ]; then
	# A player who makes an account, as kit_ui_components_check's
	cat > "$t/web.json" <<J
[
 ["nav", "\${URL}"],
 ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "webhud"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Enter"], ["waitlog", "Joined as webhud", 30],
 ["waitlog", "player physics enabled", 120],
 ["waitlog_any", "kit: ui $PIE bar", 30],
 ["waitlog_any", "pie step 8 of 32", 30], ["frames", 10],
 ["shot", "\${OUT}/web.png"], ["sync", 3000]
]
J
	WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/web.json" "$t/drive" \
		> "$t/drive.txt" 2>&1 || fail "the web drive ($(tail -2 "$t/drive.txt"), $t/drive)"
	echo "ok: the web client: pies from the atlas ($t/drive/web.png)"
fi
b=$t/kitboss.log o=$t/kitbob.log s=$t/srv.log
hx=$(grep -aoP "kit: ui own:hotbar own at \K\d+,\d+" "$o" | tail -1)
stop_server
! grep -a "kit: ui: \|kit: ui handles\|kit: markers:" "$b" | grep -av "placed to keep\|the pointer freed\|selected Kit" | head -5 | grep . ||
	fail "an error in ui.lua ($b)"

# 1. The fills at 50: 20 x 3 percents = 140 x 21, the border 1
wantp "$b" "kit: ui $L2R bar .*0\.50 full, fill 1,1 69x19"
wantp "$b" "kit: ui $R2L bar .*0\.50 full, fill 70,1 69x19"
wantp "$b" "kit: ui $B2T bar .*0\.50 full, fill 1,70 19x69"
wantp "$b" "kit: ui $T2B bar .*0\.50 full, fill 1,1 19x69"
wantp "$b" "kit: ui $PIE bar .*0\.25 full, pie step 8 of 32"
wantp "$b" "kit: ui $PIE_FULL bar .*1\.00 full, pie step 32 of 32"
echo "ok: a bar's four directions; a pie's step floor(f * 32)"
# 2.
want "$b" "2:05 / 125 / 125.4"
echo "ok: {value:time}, {value:int}, {value}"
# 3. The same element at both windows
wantp "$b" "kit: ui $L2R bar at \d+,\d+ 140x21 in 1024x700 font"
wantp "$o" "kit: ui $L2R bar at \d+,\d+ 200x30 in 1400x1000 font"
wantp "$b" "kit: ui $FMT text at .* in 1024x700 font 13 "
wantp "$o" "kit: ui $FMT text at .* in 1400x1000 font 18 "
echo "ok: sizes in vmin at two windows"
# 4. The label: under its size (14 at 7 units), not wrapped
f=$(grep -aoP "kit: ui $LONG bar at .* font \K\d+" "$b" | tail -1)
[ -n "$f" ] && [ "$f" -lt 14 ] && [ "$f" -ge 8 ] || fail "the long label's font $f ($b)"
echo "ok: a long label's font $f of 14"
# 5.
wantp "$b" "kit: ui $OVER text .* order 2 "
wantp "$b" "kit: ui $UNDER bar .* order 1 "
wantp "$b" "kit: ui $BEHIND text .* order 0 "
# 6. In play (after edit mode's last lines): A at y, C right under it
ya=$(grep -aP "kit: ui $A text at .* shown: " "$b" | tail -1 | grep -aoP "at \d+,\K\d+ \d+x\d+")
yc=$(grep -aP "kit: ui $C text at .* shown: " "$b" | tail -1 | grep -aoP "at \d+,\K\d+")
[ -n "$ya" ] && [ -n "$yc" ] || fail "no column lines ($b)"
exp=$(echo "$ya" | awk '{ split($2, s, "x"); print $1 + s[2] + 7 }')
[ "$yc" = "$exp" ] || fail "the column: Third at $yc, not $exp under First ($ya): a gap for the hidden one? ($b)"
grep -aP "kit: ui $B text at .* shown: " "$b" | grep -qv "edit mode" && fail "the hidden child shown ($b)"
wantp "$b" "kit: ui $EMPTY panel at .* hidden: "
echo "ok: a column stacks the shown, no gap for the hidden; an empty one not drawn"
# 7.
wantp "$b" "kit: ui $BLINK bar .*, blinks: "
# The ticks may come together to the client: some on the way, and the end
wantp "$b" "kit: ui $PROG bar .* 0\.(25|50|75) full"
wantp "$b" "kit: ui $PROG bar .* 1\.00 full"
echo "ok: blink_below; kit/timer's progress"
# 8.
wantp "$b" "kit: ui $PBAR bar .* plain order"
wantp "$b" "kit: ui $PTEXT text .* plain order"
# 9. The drags
want "$s" "set $SIZED's kit/ui_bar width to 25" "set $SIZED's kit/ui_bar height to 6"
want "$s" "kit/game_rules"
echo "ok: a drag in whole percents, snapped to an edge, a handle's resize"
# The HUD by view: the hotbar's frame's last line under each
for v in "3D hidden" "2D hidden" "Walk shown"; do
	set -- $v
	awk -v v="the view is $1" -v w="kit: ui own:hotbar own at .* $2, edit mode" '
		index($0, "the view is ") { on = index($0, v) > 0 }
		on && $0 ~ w { f = 1 }
		END { exit !f }' "$b" || fail "the HUD in the $1 view is not $2 ($b)"
done
echo "ok: in edit mode the HUD in the Walk view only"
# In order: 3D, one selected, Walk; 2D, kit/flag there, still 2D; its button
# again; kit/ui_bar armed, Walk; 3D; the prefab armed, Walk
seq=$(grep -a " I kit " "$b" | grep -a "kit editor: the view is \|kit editor: placing \|kit editor: selected $SIZED " |
	sed 's/.*kit editor: //; s/ (.*//' | tr '\n' ';')
case $seq in
*"the view is 3D;selected $SIZED;the view is Walk;the view is 2D;placing kit/flag;placing nothing;placing kit/ui_bar;the view is Walk;placing nothing;the view is 3D;placing [kit/health_bar];the view is Walk;placing nothing;"*) ;;
*) fail "choosing and the views: $seq ($b)" ;;
esac
seq=$(grep -a " I kit " "$b" | grep -a "kit editor: the view is \|kit editor: a double click\|kit: ui own:hotbar dragged" |
	sed 's/.*kit editor: //; s/.*kit: ui //; s/ to .*//' | tr '\n' ';')
case $seq in
*"the view is 2D;the view is HUD;own:hotbar dragged;the view is 2D;the view is HUD;a double click out of the HUD view;the view is 2D;the view is Walk;"*) ;;
*) fail "the HUD view: $seq ($b)" ;;
esac
echo "ok: the HUD view: out by Escape and by a double click on nothing, to the view before"
echo "ok: a UI component chosen goes to Walk, another type stays"
# 10. Copy style
for p in color direction blink_below background width height; do
	want "$s" "set $STYLE_TO's kit/ui_bar $p to"
done
for p in label x y; do
	[ "$(grep -ac "set $STYLE_TO's kit/ui_bar $p to" "$s")" = 1 ] ||
		fail "copy style changed $STYLE_TO's $p ($s)"
done
wantp "$s" "link.*$TIMER.*$STYLE_TO"
echo "ok: copy style: the style's parameters, not the place, the label or the link"
# 11. A version 1 save: a kit/ui_text in pixels, written into the save
db=$t/user/apps/workbench/saves/world/save.sqlite
OLD=9000
python3 -I - "$db" "$DRAG" "$OLD" <<'PY' || fail "could not add the old text ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
a = json.loads(db.execute("SELECT value FROM store WHERE store = 'kit' AND key = 'authored'").fetchone()[0])
parent = next(e for e in a["entities"] if e["id"] == int(sys.argv[2]))["parent"]
a["entities"].append({"id": int(sys.argv[3]), "parent": parent, "name": "old text",
	"pos": [0, 1, 0], "components": [{"type": "kit/ui_text", "version": 1, "params": {
		"text": "old", "anchor": "top_left", "x": 108, "y": 216, "size": 27}}]})
db.execute("UPDATE store SET value = ? WHERE store = 'kit' AND key = 'authored'", (json.dumps(a),))
db.commit()
PY
cat > "$t/kitcat.cmds" <<EOF
wait_log_any 60000 Joined as kitcat
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit: ui $OLD text
wait_log_any 10000 kit: ui own:hotbar own at
frames 10
screenshot @T@/after.png
sync 3000
quit
EOF
sed 's/kitcat/kitdan/; s/after\.png/auto.png/' "$t/kitcat.cmds" > "$t/kitdan.cmds"
serve "$t/srv2.log"
BUILDAT_JOIN_NAME=kitcat client kitcat 1400x1000 -u 1
BUILDAT_JOIN_NAME=kitdan client kitdan 1024x700
stop_server
c=$t/kitcat.log d=$t/kitdan.log s2=$t/srv2.log
# 108, 216, 27 at 1080: 10, 20, 2.5 percents
want "$s2" "kit/ui_text's migrate from version 1"
wantp "$c" "kit: ui $OLD text at 100,200 .* font 25 "
wantp "$d" "kit: ui $OLD text at 108,216 .* font 27 "
python3 -I - "$db" "$OLD" <<'PY' || fail "the old text in the save after a load ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
a = json.loads(db.execute("SELECT value FROM store WHERE store = 'kit' AND key = 'authored'").fetchone()[0])
c = next(e for e in a["entities"] if e["id"] == int(sys.argv[2]))["components"][0]
assert c["version"] == 2 and c["params"]["x"] == 10 and c["params"]["size"] == 2.5, c
PY
echo "ok: a version 1 save's pixels converted against 1080 p, once"
# The dragged hotbar stayed, at the same window
wantp "$c" "kit: ui own:hotbar own at $hx "
echo "ok: Kit's own hotbar dragged stays after a restart (at $hx)"
# 12. The health bar is a bar of Kit's own
wantp "$c" "kit: ui own:health bar at \d+,\d+ \d+x\d+ in 1400x1000 font \d+ shapes order 0 shown.*1\.00 full"
for p in overlay play big after auto; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
echo "PASS: Kit's HUD styles: four bars, pies, formats, vmin, order, stacking, blink, plain, snapping, handles, Kit's own HUD kept, copy style, the save's conversion, the health bar; screenshots $t/overlay.png $t/play.png $t/big.png $t/after.png $t/auto.png"
