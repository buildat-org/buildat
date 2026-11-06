#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-02)
# covers: apps/workbench/main/client_lua/init.lua builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/types/ui_*.lua builtin/kit/types/scoreboard.lua builtin/kit/client_lua/ui.lua builtin/kit/client_lua/module.lua builtin/kit/client_lua/controls.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/signals.lua
# [KIT_UI_COMPONENTS] UI as screen-space components (stage 4m) on
# Workbench. kitboss (the admin, 1024x700) places by the editor's packets
#   3 kit/ui_text "Presses: {value}" (top), 4 kit/ui_button "Press me"
#   (bottom), 5 kit/counter, 6 kit/ui_bar 0..4 (top left), 7 kit/ui_panel
#   "Hello" for the player (to "player"), under it 8 a kit/ui_text with
#   "[fire]" and 9 kit/ui_button "Close" (closes), 10 kit/action fire
#   (key R) and 11 a kit/ui_button bound to it (no label: "Fire");
#   4 pressed -> 5 count and -> 7 show, 5 changed -> 3 value and 6 value;
# and the checks:
#   1. edit mode draws every UI component framed, the hidden dialog too
#      (overlay.png); a click on "Press me" selects it, a drag moves it;
#   2. play: kitboss clicks "Press me": the text says "Presses: 1", the bar
#      0.25 full, the dialog his (play.png), no crosshair over it
#      ([KIT_UI_CROSSHAIR]); "Close" hides it; the bound
#      button presses the action (the server's "Action fire pressed");
#   3. a flood of 2000 presses of 4: at most the acts' burst reaches it
#      (the counter), as kit:action's;
#   4. kitbob (a second player, 1024x700) is not shown kitboss's dialog,
#      and a press of its Close sent anyway is refused "not on their
#      screen"; his own press shows him his own;
#   5. every UI component on the screen at 1024x700 (no "OFF SCREEN"),
#      and in the web client by finger (TOUCH=1, 1000x500, headless
#      Chrome), a player with an account: a tap on "Press me" shows them their dialog
#      (touch.png),
#      the bottom button over the touch bars.
#   6. [KIT_PANEL_PARENT] A panel its elements' parent, natively, over two
#      restarts of the save: on a fresh load in it and indented under it in
#      the editor's list and in Signals' (list.png, signals_list.png); Switch
#      parent into it picked in the list and Un-parent; a door refused under
#      it by every way there; a UI element under a door not in a panel; a
#      panel in a panel; placing in it with it selected and with Place under
#      this; a copy of it pasted, its delete and undo, a paste into the panel,
#      a prefab saved and placed keep the tree; a text and a player's dialog in
#      play (dialog.png, closed.png).
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
	edit '{"op": "parent", "id": 8, "parent": 7}'
	set_p 8 anchor '"top_left"'
	set_p 8 y 0
	set_p 8 text '"Only you see this. [fire] fires."'
	place kit/ui_button 6
	edit '{"op": "parent", "id": 9, "parent": 7}'
	set_p 9 label '"Close"'
	set_p 9 closes true
	set_p 9 anchor '"bottom_right"'
	set_p 9 y 0
	place kit/action 7
	place kit/ui_button 8
	set_p 11 action '"fire"'
	set_p 11 label '""'
	set_p 11 anchor '"right"'
	set_p 11 x 1.1
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
	# A player who makes an account ([WB_LAN]: Workbench lets no one in
	# without a login; the registration open by kitboss's script), by the
	# keys workbench_check's web part uses, no code field
	cat > "$t/web.json" <<'J'
[
 ["nav", "${URL}"],
 ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "webfinger"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Enter"], ["waitlog", "Joined as webfinger", 30],
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
# [KIT_UI_CROSSHAIR] No crosshair over the dialog (a panel with a button
# wants the clicks), back once Close hid it
awk '/kit: ui button 4 pressed/ && !p { p = 1 }
	p == 1 && /workbench: the crosshair hidden/ { p = 2 }
	p == 2 && /kit: ui button 9 pressed/ { p = 3 }
	p == 3 && /workbench: the crosshair shown/ { p = 4 }
	END { exit p != 4 }' "$b" ||
	fail "the crosshair not hidden over the dialog and shown after it ($b)"
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
# 6. [KIT_PANEL_PARENT] A panel is its elements' parent. The run above saved
# 7 with 8 and 9 under it: a fresh load, two restarts in all
n=0
ed() { printf 'event kit_edit %s\n' "$1"; }
edited() { n=$((n + 1)); printf 'wait_log 10000 entities, %d to undo\n' "$n"; }
edit() { ed "$1"; edited; }
refused() # <json> <reason>
{
	ed "$1"
	printf 'wait_log 10000 kit editor: refused: %s\n' "$2"
}
opened()
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state:
frames 3
click Button "Entities"
frames 3
click Button "Scene (*"
wait_log 5000 kit editor: list Scene
frames 5
EOF
}
place_ui() # <type>: from the palette's menu, with what is selected as it is
{
	cat <<EOF
click Button "Components"
frames 5
mouse_pos 60 300
frames 2
$(for i in $(seq 20); do printf 'mouse_wheel -1\nframes 1\n'; done)
frames 5
click Button "$1"
wait_log 5000 the palette's menu of $1
frames 3
click Button "Place"
EOF
	edited
	printf 'frames 3\n'
}
{
	opened
	cat <<'EOF'
screenshot @T@/list.png
keypress F5
wait_log 10000 kit editor: signals: list ""
frames 8
screenshot @T@/signals_list.png
keypress Escape
wait_log 10000 kit editor: the view is
frames 3
click Button "Entities"
frames 3
click Button "Scene (*"
frames 3
EOF
	# 12: Switch parent into the panel by the inspector, picked in the list;
	# Un-parent
	edit '{"op": "place", "type": "kit/ui_text", "pos": [0, 0, 0]}'
	edit '{"op": "set", "id": 12, "comp": 0, "param": "text", "value": "Twelve"}'
	cat <<'EOF'
event kit_select 12
frames 3
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of 12: armed
frames 3
click Button "select 7"
EOF
	edited
	cat <<'EOF'
frames 5
screenshot @T@/in_panel.png
wait_log_any 5000 kit: ui 12 text at
click Button "Un-parent"
EOF
	edited
	printf 'frames 5\n'
	# 13: a door; refused under a panel, by the edit, by the place, by a prefab,
	# and by the buttons (its status)
	edit '{"op": "place", "type": "kit/door", "pos": [3, 1, 3]}'
	refused '{"op": "parent", "id": 13, "parent": 7}' "parent: parent: only a UI element goes under the panel 7"
	refused '{"op": "place", "type": "kit/door", "pos": [1, 1, 1], "parent": 7}' "place: parent: only a UI element goes under the panel 7"
	refused '{"op": "place", "prefab": "kit/button_door", "pos": [1, 1, 1], "parent": 7}' "place: parent: only a UI element goes under the panel 7"
	refused '{"op": "parent", "id": 8, "parent": 3}' "parent: parent: entity 3 has no position"
	cat <<'EOF'
event kit_select 13
frames 3
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of 13: armed
frames 3
click Button "select 7"
wait_log 5000 kit editor: refused: parent: parent: only a UI element goes under the panel 7
frames 5
screenshot @T@/refused.png
EOF
	# A UI element under a door: as it was, not in a panel
	edit '{"op": "parent", "id": 12, "parent": 13}'
	edit '{"op": "parent", "id": 12, "parent": 0}'
	# 14 a panel in the panel, 15 placed in it by the edit's parent
	edit '{"op": "place", "type": "kit/ui_panel", "pos": [0, 0, 0]}'
	edit '{"op": "parent", "id": 14, "parent": 7}'
	edit '{"op": "place", "type": "kit/ui_text", "pos": [0, 0, 0], "parent": 14}'
	# 16 placed from the palette with the panel selected; 17 with Place under
	# this on the inner one
	printf 'event kit_select 7\nframes 3\n'
	place_ui kit/ui_text
	cat <<'EOF'
event kit_select 14
frames 3
click Button "Place under this"
wait_log 5000 kit editor: placing under 14
frames 3
EOF
	place_ui kit/ui_bar
	cat <<'EOF'
event kit_select 14
frames 3
click Button "Placing under this: stop"
wait_log 5000 kit editor: placing under the scene
frames 3
EOF
	# 18...24: 7 copied and pasted with its six; deleted with them, back by
	# the undo
	ed '{"op": "copy", "ids": [7]}'
	echo "sync 5000"
	edit '{"op": "place", "clipboard": true, "pos": [0, 0, 0]}'
	edit '{"op": "delete", "id": 18}'
	n=$((n - 2))
	edit '{"op": "undo"}'
	# 25...27: 14 copied and pasted, keeping 15 and 17; 28...30: again, into
	# the panel
	ed '{"op": "copy", "ids": [14]}'
	echo "sync 5000"
	edit '{"op": "place", "clipboard": true, "pos": [0, 0, 0]}'
	edit '{"op": "place", "clipboard": true, "pos": [0, 0, 0], "parent": 7}'
	ed '{"op": "copy", "ids": [13]}'
	echo "sync 5000"
	refused '{"op": "place", "clipboard": true, "pos": [1, 1, 1], "parent": 7}' "place: parent: only a UI element goes under the panel 7"
	# 31 the root, 32...34: 14 as a prefab, placed
	edit '{"op": "save_prefab", "ids": [14], "name": "inner"}'
	edit '{"op": "place", "prefab": "kitboss/inner", "pos": [0, 0, 0]}'
	# 35: an element older than 36, its panel
	edit '{"op": "place", "type": "kit/ui_text", "pos": [0, 0, 0]}'
	edit '{"op": "place", "type": "kit/ui_panel", "pos": [0, 0, 0]}'
	edit '{"op": "parent", "id": 35, "parent": 36}'
	cat <<'EOF'
frames 5
screenshot @T@/list2.png
sync 3000
quit
EOF
} > "$t/boss2.cmds"
{
	opened
	cat <<'EOF'
frames 3
screenshot @T@/list3.png
keypress F6
wait_log 10000 kit editor: edit mode off
frames 10
click Button "Close"
wait_log 10000 hidden: "Hello"
frames 10
screenshot @T@/closed.png
click Button "Press me"
wait_log 10000 shown: "Hello"
frames 10
screenshot @T@/dialog.png
sync 3000
quit
EOF
} > "$t/boss3.cmds"
panel_server() # <n>
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
		--sim-rate "$CHECK_RATE" || fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
panel_server 2
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CREATE= client boss2
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
panel_server 3
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CREATE= client boss3
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
db=$(find "$t/user" -name save.sqlite -path "*/saves/world/*" | head -1)
[ -n "$db" ] || fail "no save.sqlite under $t/user"
python3 -I - "$db" "$t" <<'PY' || fail "a panel's elements ($t/boss2.log, $t/boss3.log, $t/srv2.log, $db)"
import json, re, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
t = sys.argv[2]
row = lambda k: json.loads(db.execute("select value from store where store='kit' and key=?", (k,)).fetchone()[0])
au = row("authored")
ents = {e["id"]: e for e in au["entities"]}
parent = lambda i: ents[i]["parent"]
scene = parent(7)
# Under the panel, no position given them, no "panel" parameter left
for i, p in {8: 7, 9: 7, 14: 7, 15: 14, 16: 7, 17: 14, 12: scene, 35: 36, 13: scene}.items():
    assert parent(i) == p, (i, ents[i])
for i in (7, 8, 9, 12, 14, 15, 16, 17, 35, 36):
    assert "pos" not in ents[i], ents[i]
    assert "panel" not in ents[i]["components"][0].get("params", {}), ents[i]
# The copy: back by the undo, the same tree beside the panel
kids = lambda p: sorted(i for i in ents if ents[i]["parent"] == p)
assert parent(18) == scene and len(kids(18)) == 4, (ents[18], kids(18))
inner = [i for i in kids(18) if ents[i]["components"][0]["type"] == "kit/ui_panel"]
assert len(inner) == 1 and len(kids(inner[0])) == 2, (inner, ents)
# The pastes: at the scene and in the panel
assert parent(25) == scene and kids(25) == [26, 27], (ents[25], kids(25))
assert parent(28) == 7 and kids(28) == [29, 30], (ents[28], kids(28))
# The prefab: the panel and its members by the parent
pf = row("prefab:kitboss/inner")
assert [e["parent"] for e in pf["entities"]] == [0, 1, 1], pf["entities"]
assert [e["components"][0]["type"] for e in pf["entities"]] == ["kit/ui_panel", "kit/ui_text", "kit/ui_bar"], pf
assert ents[31]["prefab"]["of"] == "kitboss/inner" and kids(31) == [32] and kids(32) == [33, 34], ents[31]
# The lists, in the editor and in Signals, on a fresh load and after
b2 = open(t + "/boss2.log", errors="replace").read()
b3 = open(t + "/boss3.log", errors="replace").read()
scene_list = lambda s: re.findall(r"kit editor: list Scene \(\d+\): (.*)", s)
sig_list = lambda s: re.findall(r'kit editor: signals: list "" \(\d+\): (.*)', s)
assert any(re.search(r"\b7, >8, >9\b", l) for l in scene_list(b2)), scene_list(b2)[:3]
assert any(re.search(r"\b7, >8, >9\b", l) for l in sig_list(b2)), sig_list(b2)[:3]
assert any(re.search(r"\b7, >8, >9, >12\b", l) for l in scene_list(b2)), scene_list(b2)
assert any(re.search(r"\b7, >8, >9, 1", l) for l in scene_list(b2)), "un-parent"
assert any(re.search(r"\b7, >8, >9, >14, >>15\b", l) for l in scene_list(b2)), scene_list(b2)
assert any(re.search(r"\b7, >8, >9, >14, >>15, >>17, >16\b", l) for l in scene_list(b3)), scene_list(b3)
assert any(re.search(r"\b36, >35\b", l) for l in scene_list(b3)), scene_list(b3)
# Laid out in it: the element's box in the panel's, fresh and when switched
def box(s, i, after=0):
    m = None
    for m in re.finditer(r"kit: ui %d \w+ at (-?\d+),(-?\d+) (\d+)x(\d+) " % i, s[after:]):
        pass
    assert m, ("no line of", i)
    return [int(x) for x in m.groups()]
def inside(a, b):
    return a[0] >= b[0] and a[1] >= b[1] and a[0] + a[2] <= b[0] + b[2] and a[1] + a[3] <= b[1] + b[3]
assert inside(box(b3, 8), box(b3, 7)), (box(b3, 8), box(b3, 7))
assert inside(box(b3, 9), box(b3, 7)), (box(b3, 9), box(b3, 7))
assert inside(box(b3, 15), box(b3, 14)), (box(b3, 15), box(b3, 14))
# Its elements shown only while it is; the flood before the restart left it up
play = b3[b3.index("edit mode off"):]
states = [m[0] + " " + m[1] for m in re.findall(r"kit: ui (7|8|9) \w+ at [^:]* (shown|hidden)\b", play)]
assert states[-3:] == ["7 shown", "8 shown", "9 shown"] and "8 hidden" in states and "9 hidden" in states, states
i = b2.index("switch parent of 12 to 7")
j = b2.index("un-parent 12")
assert inside(box(b2[:j], 12, i), box(b2[:j], 7)), (box(b2[:j], 12, i), box(b2[:j], 7))
PY
want "$t/boss2.log" "kit editor: switch parent of 12 to 7" "kit editor: un-parent 12"
want "$t/srv2.log" "put 12 under 7" "put 12 under the scene" "placed kit/ui_text 15, no position under 14" \
	"placed kit/ui_text 16, no position under 7" "placed kit/ui_bar 17, no position under 14" \
	"pasted the copy as 18...24" "deleted 18 and 6 under it"
want "$t/srv3.log" "kit/ui_panel 7: shown for kitboss" "UI button 9 pressed by kitboss" "kit/ui_panel 7: hidden for kitboss"
echo "ok: a panel's elements by the parent: in it, indented in both lists, Switch parent and Un-parent, a door refused, placing in it, paste, delete, undo and prefab keep them, over a save and a load; screenshots $t/list.png $t/signals_list.png $t/dialog.png"
if [ -z "$web" ]; then
	echo "PASS: Kit's UI components natively (the web skipped: no Chrome or web/); screenshots $t/overlay.png $t/play.png $t/bob.png"
	exit 0
fi
pl=$t/drive/page.log
grep -aq "OFF SCREEN" "$pl" && fail "a UI component off the screen on the web by finger ($pl)"
grep -aq "UI button 4 pressed by webfinger" "$s" && grep -aq "kit/ui_panel 7: shown for webfinger" "$s" ||
	fail "the web player's tap did not press the button and show their dialog ($s)"
# The bottom button over the touch bars: its foot above the bars' top
foot=$(grep -aoP 'kit: ui 4 button at \d+,\K\d+ \d+x\d+' "$pl" | tail -1 |
	awk '{ split($2, s, "x"); print $1 + s[2] }')
bars=$(grep -aoP 'kit: ui touch bars at y \K\d+' "$pl" | tail -1)
[ -n "$foot" ] && [ -n "$bars" ] && [ "$foot" -le "$bars" ] ||
	fail "the bottom button (foot $foot) not over the touch bars ($bars; $pl)"
[ -s "$t/drive/touch.png" ] || fail "no screenshot $t/drive/touch.png"
echo "PASS: Kit's UI components: the overlay, a text and a bar following a signal, a button's press linked and flooded, a per-player dialog, on the screen natively and on the web by finger; screenshots $t/overlay.png $t/play.png $t/bob.png $t/drive/touch.png"
