#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~25 s (2026-11-06)
# covers: builtin/kit/client_lua/signals.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/ui.lua builtin/kit/client_lua/input.lua
# [KIT_SIGNALS_VIEW] The editor's Signals view on Workbench. kitboss (the
# admin, 1024x700), a kit/flag with links to three kit/ui_bars and from a
# kit/timer:
#   0. [KIT_NO_WORLD_TYPES] The ui_bars, the timer and the logic placed at a
#      position have none: in the list's Scene group, a kit/starting_kit under
#      the flag too, a Prefab's in the save with none;
#   1. F5 from 3D: the list and the links side by side under the bar, the
#      Inspector button the list and the inspector over its viewport, no
#      panel, no other window; the 3D camera where it was afterwards;
#   2. a link added from the table (output, target, input by its dropdowns),
#      unlinked by its menu, hidden and shown by its checkbox: the server's
#      edits; the toggle's in the save;
#   3. a target's name selects it, its Inputs there;
#   4. the filter narrows the list, by type and by name; a view key while
#      typing in it; the list's symbols marked for what has a link either way;
#   5. a rename: the server's edit, undone by Ctrl+Z, again; in the save, and
#      read in the table by another client after the server's restart;
#   6. the viewport's camera on the selected entity, the walk camera's on one
#      with no position (a ui_bar: the HUD laid out in its rectangle, that bar
#      marked; game_rules: no HUD);
#   7. Escape back to the view before; Walk has its panels and HUD back;
#   8. a 1800x1000 window: all three columns; a touch client at 600x400: one
#      column at a time;
#   9. a real window made small and large again: the UI's fit back at x1.
#  10. [KIT_PALETTE_MENU] Add from palette, from 3D: the popup in the window;
#      closed by Escape, a press outside and its button, the view kept; a type
#      with no position placed at once, none, and selected in the list; a
#      positioned one back in 3D, armed, placed by the click there; small windows:
#      600x400 (touch: selected scrolled into view) and 800x500 at UI scale 2;
#  11. [KIT_PALETTE_MENU] A type with no position in the palette: its menu, Cancel,
#      Escape, another's button, a press on the view place nothing; Favourite; Place
#      at once and selected; a drag still places, a positioned one still arms.
#  12. [KIT_SIGNALS_PARENT_BUTTONS] Switch parent and Un-parent in its inspector:
#      armed, a click in the list picks; a refusal (itself, none with a position)
#      stays armed with its status over the list; past an edit, the filter and
#      another view; the row indented under the new one; Escape and the button
#      cancel, the view kept; narrow touch: armed, the list's column is up.
# Screenshots kept with KEEP_TMP=1: $t/parent_*.png, $t/popup.png, $t/palette_menu.png, $t/narrow_popup.png, $t/small_popup.png, $t/small_menu.png, $t/menu.png, $t/refit.png, $t/signals.png, $t/added.png, $t/hud.png,
# $t/game_wide.png, $t/wide.png, $t/narrow_*.png; look at them.
#   util/kit_signals_view_check.sh
#   util/kit_signals_view_check.sh web    item 12 in headless Chrome, mouse and finger
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = web ]; then
	# [KIT_SIGNALS_PARENT_BUTTONS] Item 12 in the web client, headless Chrome: by
	# the mouse at 1200x800, then by a finger at 1000x500
	export BUILDAT_WORKBENCH_STONE=1
	check_tmp kit_signals_web; t=$CHECK_TMP
	stub="(function(){ var held = null, refuse = false; Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }}); function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); } document.addEventListener('keydown', function(e){ if(e.key === 'Escape') refuse = true; }, true); document.addEventListener('mousedown', function(){ refuse = false; }, true); HTMLCanvasElement.prototype.requestPointerLock = function(){ if(refuse || !window.lockOk){ document.dispatchEvent(new Event('pointerlockerror')); return Promise.reject(new Error('refused')); } if(held !== this) set(this); return Promise.resolve(); }; document.exitPointerLock = function(){ if(held) set(null); }; return 'stub'; })()"
	steps() # <click|tap> <x1> <y1> <x2> <y2>: the two flags' cells on the screen
	{
		local p=$1
		cat <<J
[
	["nav", "\${URL}"],
	["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
J
		[ "$p" = tap ] || echo "	[\"eval\", \"$stub\"],"
		cat <<J
	["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
	["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "\${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Enter"], ["waitlog", "Joined as webboss", 30],
	["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
	["$p", "Button", "Don't add"], ["frames", 3],
	["waitlog_any", "world_menu: the list shown, 0 worlds", 30], ["frames", 3],
	["$p", "Button", "New project..."],
	["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
	["$p", "Button", "Create"],
	["waitlog", "player physics enabled", 120],
J
		if [ "$p" = tap ]; then
			cat <<J
	["waitlog_any", "kit editor: edit rights: yes", 10], ["frames", 5],
	["key", "F6"], ["waitlog", "kit editor: state: 1 entities", 20],
J
		else
			cat <<J
	["waitlog_any", "pause: the menu shown", 10],
	["eval", "window.lockOk = true, 'lock given from here'"],
	["click", 100, 700], ["waitlog", "pause: the menu closed", 10], ["wait", 1000],
	["waitlog_any", "kit editor: edit rights: yes", 10],
	["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["click", "Button", "Edit", 600, 339], ["waitlog", "kit editor: state: 1 entities", 20],
J
		fi
		cat <<J
	["key", "F1"], ["waitlog", "kit editor: the view is 2D", 10], ["frames", 3],
J
		# A short window: its panels by the bar's buttons, one column at a time
		[ "$p" = click ] || echo '	["tap", "Button", "Tools"], ["frames", 3],'
		cat <<J
	["$p", "Button", "kit/flag"], ["waitlog", "kit editor: placing kit/flag", 10], ["frames", 3],
J
		[ "$p" = click ] || echo '	["tap", "Button", "Tools"], ["frames", 3],'
		cat <<J
	["$p", $2, $3], ["waitlog", "kit editor: state: 2 entities", 10], ["frames", 3],
	["$p", $4, $5], ["waitlog", "kit editor: state: 3 entities", 10], ["frames", 3],
	["key", "Escape"], ["frames", 3],
J
		# None with a position, for its refusal; off the screen of a short window
		[ "$p" = tap ] || cat <<J
	["click", "Button", "kit/logic"], ["waitlog", "the palette's menu of kit/logic", 10], ["frames", 3],
	["click", "Button", "Place"], ["waitlog", "kit editor: state: 4 entities", 10], ["frames", 3],
J
		cat <<J
	["key", "F5"], ["waitlog", "kit editor: the view is Signals", 10], ["frames", 5],
J
		[ "$p" = click ] || echo '	["tap", "Button", "Entities"], ["frames", 5],'
		cat <<J
	["$p", "Button", "select 3"], ["waitlog", "kit editor: selected 3", 10], ["frames", 3],
	["$p", "Button", "Inspector"], ["frames", 5],
	["$p", "Button", "Switch parent"], ["waitlog", "kit editor: switch parent of 3: armed", 10], ["frames", 3],
	["shot", "\${OUT}/armed.png"],
J
		[ "$p" = tap ] || cat <<J
	["click", "Button", "select 5"], ["waitlog", "switch parent of 3: not 5", 10], ["frames", 3],
J
		cat <<J
	["$p", "Button", "select 3"], ["waitlog", "switch parent of 3: not 3", 10], ["frames", 3],
	["shot", "\${OUT}/refused.png"],
	["$p", "Button", "select 4"], ["waitlog", "signals: list \"\" .*, >3", 10], ["frames", 3],
	["shot", "\${OUT}/under.png"],
	["$p", "Button", "Inspector"], ["frames", 5],
	["$p", "Button", "Un-parent"], ["waitlog", "signals: list \"\" [^>]*$", 10], ["frames", 3],
	["$p", "Button", "Inspector"], ["frames", 5],
	["$p", "Button", "Switch parent"], ["waitlog", "switch parent of 3: armed", 10], ["frames", 3],
	["key", "Escape"], ["waitlog", "switch parent cancelled", 10], ["frames", 3],
	["$p", "Button", "Inspector"], ["frames", 5],
	["$p", "Button", "Switch parent"], ["waitlog", "switch parent of 3: armed", 10], ["frames", 3],
	["$p", "Button", "Inspector"], ["frames", 5],
	["$p", "Button", "Switch parent: Cancel"], ["waitlog", "switch parent cancelled", 10], ["frames", 3],
	["shot", "\${OUT}/cancelled.png"], ["sync", 5000]
]
J
	}
	steps click 900 550 650 700 > "$t/mouse.json"
	"$here/util/web_drive.sh" "${WEB_BROWSER:-chrome}" workbench "$t/mouse.json" "$t/mouse" ||
		fail "the web drive by the mouse ($t/mouse)"
	echo "ok: by the mouse in the web client; screenshots $t/mouse/armed.png $t/mouse/refused.png $t/mouse/under.png"
	steps tap 500 300 600 420 > "$t/touch.json"
	TOUCH=1 WEB_DRIVE_VIEWPORT=1000x500@1 "$here/util/web_drive.sh" chrome workbench "$t/touch.json" "$t/touch" ||
		fail "the web drive by a finger ($t/touch)"
	echo "ok: by a finger in the web client; screenshots $t/touch/armed.png $t/touch/refused.png"
	echo "PASS: Switch parent and Un-parent in the Signals view on the web"
	exit 0
fi
export BUILDAT_WORKBENCH_PROJECT=world
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_signals_view; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

client() # <name> <window> [client's options]: its commands in $t/<name>.cmds
{
	local name=$1 win=$2
	shift 2
	sed -i "s|@T@|$t|g" "$t/$name.cmds"
	run_client 60 "$t/$name.log" timeout 180 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$name" -s localhost:$SERVER_PORT -w "$win" -l 3 "$@" \
		-c @"$t/$name.cmds" || fail "client $name failed ($t/$name.log, $t/srv.log)"
}
serve() # <log>
{
	start_server "$1" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
		--sim-rate "$CHECK_RATE" || fail "the server did not come up ($1)"
	CHECK_PIDS+=($SERVER_PID)
}
stop_server()
{
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
edit() # <op json>: an edit and its answer
{
	printf 'event kit_edit %s\nwait_log 10000 kit editor: state:\n' "$1"
}
state() # the answer to the edit just asked for by a click
{
	echo "wait_log 10000 kit editor: state:"
}
id=2
place() # <type>: the next id
{
	id=$((id + 1))
	edit "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$id, 1, 6]}"
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
wait_log_any 10000 kit editor: edit mode on
frames 5
EOF
	place kit/flag; FLAG=$id
	place kit/ui_bar; BAR1=$id
	place kit/ui_bar; BAR2=$id
	place kit/ui_bar; BAR3=$id
	place kit/timer; TIMER=$id
	place kit/game_rules; RULES=$id
	place kit/logic; LOGIC=$id
	id=$((id + 1)); KID=$id
	edit "{\"op\": \"place\", \"type\": \"kit/starting_kit\", \"pos\": [1, 1, 1], \"parent\": $FLAG}"
	id=$((id + 3)); PIE=$id
	edit "{\"op\": \"place\", \"prefab\": \"kit/timer_pie\", \"pos\": [1, 1, 1]}"
	link $FLAG left $BAR1 value
	link $FLAG taken $BAR1 show
	link $FLAG home $BAR1 hide
	link $FLAG taken $BAR2 hide
	link $FLAG home $BAR2 hide
	link $FLAG placed $BAR2 show
	link $TIMER done $FLAG home
	link $FLAG scored $LOGIC a
	cat <<EOF
click Button "Entities"
frames 3
click Button "Scene (*"
wait_log_any 5000 kit editor: list Scene
screenshot @T@/scene_list.png
event kit_select $FLAG
frames 3
event kit_cam3d 40 30 40 0 0 0
frames 5
event kit_cam_where before
frames 3
keypress F5
frames 8
event kit_ui_where signals
event kit_tabs signals
frames 3
screenshot @T@/signals.png
EOF
	# 2. Added from the table: a third bar's value from "progress"
	cat <<EOF
click Button "add link"
frames 3
screenshot @T@/form.png
click DropDownList "▼" 450 293
frames 3
click Text "progress*"
frames 3
click DropDownList "▼" 450 327
frames 3
screenshot @T@/form_target.png
click Text "◆ $BAR3 ui_bar"
frames 3
click DropDownList "▼" 450 361
frames 3
click Text "value*"
frames 3
screenshot @T@/form_input.png
click Button "Link"
EOF
	state
	cat <<EOF
frames 3
screenshot @T@/added.png
click Button "Done"
frames 3
click Button "signal $FLAG.taken $BAR2.hide"
frames 3
screenshot @T@/menu.png
keypress Escape
frames 3
click Button "signal in $FLAG.taken $BAR2.hide"
frames 3
keypress Escape
frames 3
mouse_pos 310 409
frames 2
mouse_click right
frames 3
screenshot @T@/menu_right.png
click Button "Delete"
EOF
	state
	cat <<EOF
frames 3
click Button "visible $FLAG.left $BAR1.value"
EOF
	state
	cat <<EOF
frames 3
click Button "visible $FLAG.home $BAR1.hide"
EOF
	state
	cat <<EOF
frames 3
click Button "visible $FLAG.home $BAR1.hide"
EOF
	state
	# 3. A target's name selects it
	cat <<EOF
frames 3
click Button "goto $BAR1"
frames 5
screenshot @T@/target.png
click Button "goto $FLAG"
frames 5
EOF
	# 5. The name, undone, again
	cat <<EOF
click LineEdit "signals name"
frames 2
text Home flag
frames 2
click Button "Rename"
EOF
	state
	cat <<EOF
frames 3
screenshot @T@/renamed.png
keydown ctrl
keypress Z
keyup ctrl
EOF
	state
	cat <<EOF
frames 3
click LineEdit "signals name"
frames 2
text Home flag
frames 2
click Button "Rename"
EOF
	state
	# 4. The filter
	cat <<EOF
frames 3
click LineEdit "signals filter"
frames 2
text ui_bar
frames 3
screenshot @T@/filtered.png
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
frames 2
text home F
frames 3
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
frames 3
EOF
	# A view key with the focus in the filter, and back
	cat <<EOF
keypress F2
frames 5
keypress F5
frames 5
EOF
	# 6. The viewport; its HUD
	cat <<EOF
click Button "Inspector"
frames 5
screenshot @T@/inspector_tab.png
event kit_select $RULES
frames 5
screenshot @T@/nohud.png
event kit_select $BAR1
frames 5
screenshot @T@/hud.png
event kit_ui_where hud
event kit_select $RULES
frames 5
screenshot @T@/game_wide.png
event kit_select $FLAG
frames 5
click Button "Links"
frames 5
event kit_cam_where after
frames 3
EOF
	# 7. Back to the view before; Walk
	cat <<EOF
keypress Escape
frames 5
event kit_tabs out
frames 2
screenshot @T@/out.png
keypress F3
frames 5
screenshot @T@/walk.png
keypress F5
frames 5
EOF
	# 10. [KIT_PALETTE_MENU] The list's button, from 3D: its popup, by Escape, a
	# press outside and the button closed
	cat <<EOF
keypress F2
frames 5
keypress F5
frames 5
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
screenshot @T@/popup.png
event kit_ui_where popup_up
keypress Escape
frames 3
event kit_ui_where popup_escaped
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
mouse_pos 800 600
mouse_click left
frames 3
event kit_ui_where popup_outside
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
click Button "Add from palette"
frames 3
event kit_ui_where popup_button
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
click Button "kit/timer"
wait_log 5000 signals: picked kit/timer
EOF
	state
	cat <<EOF
frames 5
screenshot @T@/popup_placed.png
EOF
	# A type with a position: armed, the view left, placed by a click there
	cat <<EOF
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
click Button "kit/flag"
wait_log 5000 kit editor: placing kit/flag
frames 5
screenshot @T@/popup_armed.png
mouse_pos 550 400
frames 3
mouse_click left
EOF
	state
	cat <<EOF
mouse_click right
wait_log 5000 kit editor: placing nothing
frames 3
EOF
	# 11. [KIT_PALETTE_MENU] The palette: a type with no position has its menu:
	# Cancel, Escape, a press on another's button, a press on the view; Favourite
	# keeps it up; Place is an edit with no click on the view. A drag still places
	cat <<EOF
click Button "kit/logic"
wait_log 5000 the palette's menu of kit/logic
frames 3
screenshot @T@/palette_menu.png
event kit_ui_where menu_up
click Button "Cancel"
frames 3
event kit_ui_where menu_cancelled
screenshot @T@/palette_cancelled.png
click Button "kit/logic"
wait_log 5000 the palette's menu of kit/logic
frames 3
keypress Escape
frames 3
event kit_ui_where menu_escaped
click Button "kit/logic"
wait_log 5000 the palette's menu of kit/logic
frames 3
click Button "kit/action"
wait_log 5000 the palette's menu of kit/action
frames 3
screenshot @T@/palette_menu_other.png
mouse_pos 550 400
mouse_click left
frames 3
event kit_ui_where menu_outside
screenshot @T@/palette_outside.png
click Button "kit/flag"
wait_log 5000 kit editor: placing kit/flag
frames 3
screenshot @T@/palette_positioned.png
click Button "kit/flag"
wait_log 5000 kit editor: placing nothing
mouse_pos 114 153
frames 3
mouse_down left
frames 3
mouse_pos 550 400
wait_log 5000 kit editor: dragging kit/action from the palette
frames 3
mouse_up left
EOF
	state
	cat <<EOF
frames 3
event kit_ui_where after_drag
click Button "kit/logic"
wait_log 5000 the palette's menu of kit/logic
frames 3
click Button "Favourite kit/logic"
wait_log 5000 kit editor: kit/logic a favourite
frames 3
screenshot @T@/palette_favourite.png
click Button "Unfavourite kit/logic"
wait_log 5000 kit editor: kit/logic not a favourite
frames 3
click Button "Place"
EOF
	state
	cat <<EOF
frames 5
screenshot @T@/palette_placed.png
click Button "kit/environment"
wait_log 5000 the palette's menu of kit/environment
frames 3
screenshot @T@/palette_menu_root.png
click Button "Place"
EOF
	state
	cat <<EOF
frames 3
keypress F5
frames 5
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
click Button "kit/game_rules"
wait_log 5000 signals: picked kit/game_rules
EOF
	state
	cat <<EOF
frames 3
sync 3000
quit
EOF
} > "$t/kitboss.cmds"
serve "$t/srv.log"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code client kitboss 1024x700 -u 1
s=$t/srv.log b=$t/kitboss.log
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
kit() # <log>: Kit's own lines, not the drive's
{
	grep -a " I kit " "$1"
}
# 0. No position, in the Scene group
# A bar going leaves the body at the left (the engine's ScrollView kept its view
# size smaller than the panel); a notice comes under the editor's bar, which comes
# after it
grep -a "signals: a body off by" "$b" && fail "the links body sideways ($b)"
wantp "$b" "notification: from y (6[0-9]|7[0-9]), the top's foot at"
want "$s" "placed kit/ui_bar $BAR1, no position" "placed kit/timer $TIMER, no position" \
	"placed kit/starting_kit $KID, no position under $FLAG"
# (as first listed: what the popup and the palette add comes later)
kit "$b" | sed '/the view is Signals/q' | grep -a "kit editor: list Scene (" | tail -1 | grep -aq " $BAR1, $BAR2, $BAR3, $TIMER, $LOGIC, $KID, $((PIE - 2)), $((PIE - 1)), $PIE\$" ||
	fail "the Scene list ($b)"
echo "ok: types with no position placed: none, in the Scene list"
# 1. Two columns side by side, the slot taken by turns, under the bar, inside
# the window
kit "$b" > "$t/kit.txt"
python3 -I - "$t/kit.txt" <<'PY' || fail "the columns ($t/kit.txt)"
import re, sys
lines = [l for l in open(sys.argv[1], errors="replace") if "signals: columns in 1024x700" in l]
assert lines, "no columns line"
def columns(line):
    m = re.search(r"under (\d+): (.*)$", line)
    cols = {}
    for c in m[2].split(", "):
        n, x, y, w, h = c.split()
        cols[n] = (int(x), int(y), int(w), int(h))
    return int(m[1]), cols
links = [columns(l) for l in lines if " sg_links " in l]
right = [columns(l) for l in lines if " inspector " in l]
assert links and right, lines
top, cols = links[-1]
assert set(cols) == {"sg_list", "sg_links"}, cols
l, c = cols["sg_list"], cols["sg_links"]
assert l[0] + l[2] <= c[0] and c[0] + c[2] <= 1024 and l[1] + l[3] <= 700, cols
assert min(l[1], c[1]) >= top > 10, (top, cols)
top, cols = right[-1]
assert set(cols) == {"sg_list", "inspector", "sg_view"}, cols
i, v = cols["inspector"], cols["sg_view"]
assert i[0] == c[0] and i[2] == c[2] and cols["sg_list"] == l, (cols, c, l)
assert i[1] + i[3] <= v[1] and i[0] == v[0], cols
assert v[0] + v[2] <= 1024 and v[1] + v[3] <= 700, cols
assert i[1] >= top > 10, (top, cols)
PY
wantp "$b" "the windows at bar \d+ \d+ \d+ \d+, sg_list \d+ \d+ \d+ \d+, sg_links \d+ \d+ \d+ \d+ \(signals\)"
wantp "$b" "the view Signals|the view signals, the tabs"
want "$b" "kit editor: the view is Signals"
before=$(grep -a "the 3D camera at .*(before)" "$b" | sed 's/.*camera at //; s/ (.*//')
after=$(grep -a "the 3D camera at .*(after)" "$b" | sed 's/.*camera at //; s/ (.*//')
[ -n "$before" ] && [ "$before" = "$after" ] || fail "the 3D camera moved: $before, $after"
echo "ok: F5: the list beside the links or the inspector under the bar in 1024x700, no other panel; the 3D camera kept"
# 2.
[ "$(grep -ac "signals: the menu of $FLAG.taken $BAR2.hide" "$b")" = 3 ] || fail "a signal's menu by either button"
want "$b" "signals: linked $FLAG.progress -> $BAR3.value" "signals: unlinked $FLAG.taken -> $BAR2.hide" \
	"signals: $FLAG.left -> $BAR1.value shown in play" "signals: $FLAG.home -> $BAR1.hide shown in play" \
	"signals: $FLAG.home -> $BAR1.hide hidden in play"
want "$s" "linked $FLAG.progress -> $BAR3.value" "unlinked $FLAG.taken -> $BAR2.hide" \
	"showed $FLAG.left -> $BAR1.value in play" "hid $FLAG.home -> $BAR1.hide in play"
echo "ok: a link added, unlinked and hidden from the table"
# 3.
seq=$(kit "$b" | grep -a "kit editor: selected " | sed 's/.*selected //; s/ (.*//' | tr '\n' ' ')
case $seq in
*"$BAR1 $FLAG "*) ;;
*) fail "the target's name did not select: $seq ($b)" ;;
esac
want "$b" "signals: $BAR1 $BAR1 ui_bar: 0 out, "
echo "ok: a target's name selects it, its links both ways there"
# 4.
wantp "$b" "signals: list \"ui_bar\" \(4\): .*$BAR1, .*$BAR2, .*$BAR3"
wantp "$b" "signals: list \"home F\" \(1\): .*$FLAG\$"
echo "ok: the filter, by type and by name"
# Marked: from a link and to a link; game_rules and the unlinked third bar not,
# the bar once its link is added
want "$b" "signals: linked marks: $FLAG, $BAR1, $BAR2, $TIMER, $LOGIC" \
	"signals: linked marks: $FLAG, $BAR1, $BAR2, $BAR3, $TIMER, $LOGIC"
kit "$b" | grep -a "signals: linked marks: " | sed "s/.*marks: //" | grep -aw "$RULES" && fail "game_rules marked ($b)"
echo "ok: a list's symbols marked by links, either way"
seq=$(kit "$b" | grep -a "kit editor: the view is " | sed 's/.*view is //' | tr '\n' ' ')
case $seq in
*"3D Signals 3D Signals 3D Walk Signals "*) ;;
*) fail "the views: $seq ($b)" ;;
esac
echo "ok: a view key from the filter; Escape back to the view before"
# 5.
want "$s" "renamed $FLAG to Home flag"
want "$b" "signals: $FLAG $FLAG Home flag: "
# Undone in between: the placed name's line after the first rename
kit "$b" | grep -a "signals: $FLAG $FLAG " | sed 's/.*signals: //; s/:.*//' | uniq > "$t/names.txt"
awk 'index($0, "Home flag") { h = 1 } h && !index($0, "Home flag") { u = 1 } u && index($0, "Home flag") { a = 1 } END { exit !a }' "$t/names.txt" ||
	fail "the rename not undone and done again ($t/names.txt)"
echo "ok: a rename, undone, again"
# 6.
want "$b" "signals: the viewport shows entity $FLAG" \
	"signals: the viewport shows what the walk camera shows" \
	"signals: the HUD in the viewport on" "signals: the HUD in the viewport off"
kit "$b" > "$t/kit.txt"
python3 -I - "$t/kit.txt" "$BAR1" <<'PY' || fail "the HUD in the viewport ($t/kit.txt)"
import re, sys
bar = sys.argv[2]
lines = open(sys.argv[1], errors="replace").read().split("\n")
ui = re.compile(r"kit: ui %s bar at (\d+),(\d+) (\d+)x(\d+) in (\d+)x(\d+) .* (shown|hidden)" % bar)
on = [i for i, l in enumerate(lines) if ", marked" in l and ui.search(l)][-1]
cols = [l for l in lines[:on] if "signals: columns in 1024x700" in l][-1]
x, y, w, h = map(int, re.search(r"sg_view (\d+) (\d+) (\d+) (\d+)", cols).groups())
# Selected: shown and marked, inside the viewport's rectangle
m = ui.search(lines[on])
assert m[7] == "shown", m[0]
bx, by, bw, bh, aw, ah = map(int, m.groups()[:6])
assert aw < w and ah < h and aw > 100 and ah > 50, (aw, ah, w, h)
assert x <= bx and bx + bw <= x + w and y <= by and by + bh <= y + h, (m[0], x, y, w, h)
# Then game_rules selected: hidden, not marked
after = [l for l in lines[on + 1:] if ui.search(l) and ", marked" not in l]
assert after and ui.search(after[0])[7] == "hidden", after[:1]
PY
echo "ok: the viewport's camera; a HUD element selected lays the HUD out in its rectangle, marked"
# 7. The Walk view's panels back
wantp "$b" "kit: ui $BAR1 bar at .* in 1024x700 .* shown"
for p in signals form added target renamed filtered nohud hud game_wide out walk; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
# 10. The popup: up, closed each way with the view kept, inside the window; a
# type with no position placed with none and selected, a positioned one armed
# back in 3D and placed by the click there
wantp "$b" "the windows at .*ctx 12 \d+ \d+ \d+ \(popup_up\)"
for w in popup_escaped popup_outside popup_button menu_cancelled menu_escaped menu_outside after_drag; do
	kit "$b" | grep -a "the windows at .*($w)" | grep -aqv " ctx " || fail "a menu still up: $w ($b)"
done
kit "$b" > "$t/kit.txt"
python3 -I - "$t/kit.txt" 1024 700 <<'PY' || fail "the popup ($t/kit.txt)"
import re, sys
n = 0
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"the palette's popup, (\d+) items in (\d+) columns, (\d+) (\d+) (\d+) (\d+) in", l)
    if m:
        x, y, w, h = map(int, m.groups()[2:])
        assert x >= 0 and y >= 0 and x + w <= int(sys.argv[2]) and y + h <= int(sys.argv[3]), l
        n += 1
assert n >= 5, n
PY
seq=$(kit "$b" | grep -a "kit editor: the view is " | sed 's/.*view is //' | tr '\n' ' ')
case $seq in
*"Walk Signals 3D Signals 3D Signals ") ;;
*) fail "the views past the popup: $seq ($b)" ;;
esac
placed=$(grep -aoP "An edit by kitboss: placed kit/timer \K\d+(?=, no position)" "$s" | tail -1)
[ "$placed" != "$TIMER" ] || fail "the popup's timer not placed ($s)"
kit "$b" | sed -n '/signals: picked kit\/timer/,$p' | grep -aq "selected $placed " || fail "the popup's timer not selected ($b)"
wantp "$s" "An edit by kitboss: placed kit/flag \d+ at \[5,1,10\]"
echo "ok: Add from palette: closed by Escape, a press outside and its button; a type with no position placed and selected; a positioned one armed for the click in the view it came from"
# 11. The palette's menu: nothing placed until Place; a drag places
[ "$(grep -ac "An edit by kitboss: placed kit/logic" "$s")" = 2 ] || fail "kit/logic placed but for its Place ($s)"
[ "$(grep -ac "An edit by kitboss: placed kit/action" "$s")" = 1 ] || fail "kit/action placed but for its drag ($s)"
wantp "$s" "An edit by kitboss: placed kit/action \d+, no position"
placed=$(grep -aoP "An edit by kitboss: placed kit/logic \K\d+" "$s" | tail -1)
want "$b" "kit editor: selected $placed " "kit editor: kit/logic a favourite" "kit editor: kit/logic not a favourite" \
	"kit editor: placing kit/flag"
echo "ok: a type with no position has the palette's menu: Cancel, Escape, a press elsewhere place nothing, Place at once and selected, Favourite kept; a drag places, a positioned one arms"
# A type the root or the scene takes: the menu, not armed; a second kit/game_rules is not refused
wantp "$s" "An edit by kitboss: placed kit/environment \d+ (on the app root|on the scene)"
[ "$(grep -ac "An edit by kitboss: placed kit/game_rules [0-9]*  *on the app root" "$s")" = 2 ] || fail "the popup's kit/game_rules ($s)"
kit "$b" | grep -aE "placing kit/(environment|game_rules)" && fail "armed ($b)"
echo "ok: kit/environment and kit/game_rules have the palette's menu, placed on the root at once; the same from Add from palette"
# 5. The name after a restart; 8. A wide window, a narrow touch one
stop_server
python3 -I - "$t/user/apps/workbench/saves/world/save.sqlite" "$FLAG" "$BAR1" "$TIMER" "$LOGIC" "$KID" "$PIE" <<'PY' || fail "the save"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
a = json.loads(db.execute("SELECT value FROM store WHERE store = 'kit' AND key = 'authored'").fetchone()[0])
e = next(e for e in a["entities"] if e["id"] == int(sys.argv[2]))
assert e["name"] == "Home flag", e["name"]
ls = {(l["output"], l["to"], l["input"]): l.get("visible") for l in e["components"][0]["links"]}
assert ls[("left", int(sys.argv[3]), "value")] is True, ls
assert not ls[("home", int(sys.argv[3]), "hide")], ls
for i in sys.argv[3:]:
    x = next(e for e in a["entities"] if e["id"] == int(i))
    assert "pos" not in x, x
assert next(e for e in a["entities"] if e["id"] == int(sys.argv[6]))["parent"] == int(sys.argv[2])
PY
cat > "$t/kitwide.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: edit mode on
frames 5
event kit_select $FLAG
frames 3
keypress F5
frames 8
screenshot @T@/wide.png
sync 3000
quit
EOF
cat > "$t/kitnarrow.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: edit mode on
frames 5
event kit_select $FLAG
frames 3
keypress F5
frames 8
screenshot @T@/narrow_links.png
click Button "Entities"
frames 5
screenshot @T@/narrow_list.png
click Button "Inspector"
frames 5
screenshot @T@/narrow_inspector.png
click Button "Entities"
frames 5
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
screenshot @T@/narrow_popup.png
click Button "kit/logic"
wait_log 5000 signals: picked kit/logic
wait_log 10000 kit editor: state:
frames 5
screenshot @T@/narrow_placed.png
sync 3000
quit
EOF
# A small window at a UI scale of 2: 400x250 of UI
cat > "$t/kitsmall.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: edit mode on
frames 5
screenshot @T@/small_walk.png
click Button "Tools"
frames 3
screenshot @T@/small_tools.png
click Button "kit/action"
wait_log 5000 the palette's menu of kit/action
frames 3
screenshot @T@/small_menu.png
keypress Escape
frames 3
keypress F5
frames 8
click Button "Entities"
frames 5
click Button "Add from palette"
wait_log 5000 signals: the palette's popup
frames 3
screenshot @T@/small_popup.png
sync 3000
quit
EOF
serve "$t/srv2.log"
BUILDAT_JOIN_NAME=kitboss client kitwide 1800x1000 -u 1
BUILDAT_JOIN_NAME=kitboss BUILDAT_TOUCH=1 client kitnarrow 600x400 -u 1
BUILDAT_JOIN_NAME=kitboss client kitsmall 800x500 -u 2
for l in kitnarrow kitsmall; do
	kit "$t/$l.log" > "$t/kit.txt"
	python3 -I - "$t/kit.txt" <<'PY' || fail "the popup in $l ($t/kit.txt)"
import re, sys
m = re.findall(r"the palette's popup, \d+ items in \d+ columns, (\d+) (\d+) (\d+) (\d+) in (\d+)x(\d+)", open(sys.argv[1], errors="replace").read())
assert m
for x, y, w, h, rw, rh in m:
    x, y, w, h, rw, rh = map(int, (x, y, w, h, rw, rh))
    assert x >= 0 and y >= 0 and x + w <= rw and y + h <= rh, (x, y, w, h, rw, rh)
PY
done
# 12. [KIT_SIGNALS_PARENT_BUTTONS] Switch parent and Un-parent in this view: the
# parent picked in its list
p_join='wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: edit mode on
frames 5'
last=$(grep -ahoP "An edit by kitboss: placed kit/\S+ \K\d+" "$t/srv2.log" "$s" | sort -n | tail -1)
PARENT=$((last + 1))
{
	echo "$p_join"
	edit '{"op": "place", "type": "kit/flag", "pos": [9, 1, 9]}'
	cat <<EOF
event kit_select $FLAG
frames 3
keypress F5
frames 8
click Button "Inspector"
frames 5
screenshot @T@/parent_buttons.png
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of $FLAG: armed
frames 3
screenshot @T@/parent_armed.png
click Button "select $BAR1"
wait_log 5000 kit editor: switch parent of $FLAG: not $BAR1
frames 3
screenshot @T@/parent_refused.png
click LineEdit "signals filter"
frames 2
text flag
wait_log 5000 kit editor: signals: list "flag"
frames 3
click Button "select $FLAG"
wait_log 5000 kit editor: switch parent of $FLAG: not $FLAG
frames 3
EOF
	# Armed past the filter's rebuild above, an edit's and another view
	edit '{"op": "place", "type": "kit/timer", "pos": [1, 1, 1]}'
	cat <<EOF
frames 3
keypress F2
wait_log 5000 kit editor: the view is 3D
frames 3
screenshot @T@/parent_armed_3d.png
keypress F5
wait_log 5000 kit editor: the view is Signals
frames 5
click Button "select $PARENT"
wait_log 10000 kit editor: signals: list "flag"
frames 3
screenshot @T@/parent_under.png
click Button "Un-parent"
wait_log 10000 kit editor: signals: list "flag"
frames 3
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of $FLAG: armed
frames 2
keypress Escape
wait_log 5000 kit editor: switch parent cancelled
frames 3
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of $FLAG: armed
frames 2
click Button "Switch parent: Cancel"
wait_log 5000 kit editor: switch parent cancelled
frames 3
screenshot @T@/parent_cancelled.png
event kit_select $BAR1
frames 3
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of $BAR1: armed
frames 2
click Button "select $PARENT"
wait_log 10000 kit editor: state:
frames 3
click Button "Un-parent"
wait_log 10000 kit editor: state:
sync 3000
quit
EOF
} > "$t/kitparent.cmds"
{
	echo "$p_join"
	cat <<EOF
event kit_select $FLAG
frames 3
keypress F5
frames 8
click Button "Entities"
frames 5
click LineEdit "signals filter"
frames 2
text flag
wait_log 5000 kit editor: signals: list "flag"
frames 3
click Button "Inspector"
frames 5
screenshot @T@/parent_narrow_buttons.png
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of $FLAG: armed
frames 5
screenshot @T@/parent_narrow_armed.png
click Button "select $FLAG"
wait_log 5000 kit editor: switch parent of $FLAG: not $FLAG
frames 3
screenshot @T@/parent_narrow_refused.png
click Button "select $PARENT"
wait_log 10000 kit editor: signals: list "flag"
frames 5
click Button "Inspector"
frames 5
click Button "Un-parent"
wait_log 10000 kit editor: signals: list "flag"
sync 3000
quit
EOF
} > "$t/kitparent2.cmds"
BUILDAT_JOIN_NAME=kitboss client kitparent 1024x700 -u 1
BUILDAT_JOIN_NAME=kitboss BUILDAT_TOUCH=1 client kitparent2 600x400 -u 1
kit "$t/kitparent.log" | grep -a "switch parent\|un-parent\|signals: list \"flag\"\|the view is" > "$t/parent_seq.txt"
python3 -I - "$t/parent_seq.txt" "$FLAG" "$PARENT" <<'PY' || fail "the Signals list's Switch parent ($t/parent_seq.txt)"
import sys
flag, parent = sys.argv[2:]
ls = open(sys.argv[1], errors="replace").read().split("\n")
def at(w, frm=0):
    return next(i for i in range(frm, len(ls)) if w in ls[i])
armed = at("switch parent of %s: armed" % flag)
picked = at("switch parent of %s to %s" % (flag, parent), armed)
assert not any("cancelled" in l for l in ls[armed:picked]), ls[armed:picked]
under = at('list "flag"', picked)
ids = ls[under].split("):")[1].split(", ")
assert ">" + flag in [i.strip() for i in ids], ls[under]
after = at('list "flag"', at("un-parent " + flag, under))
assert ">" + flag not in ls[after], ls[after]
PY
wantp "$t/kitparent2.log" "signals: list \"flag\".*>$FLAG\b"
want "$t/kitparent.log" "kit editor: switch parent of $BAR1 to $PARENT" "kit editor: un-parent $BAR1"
# The view not left by the Escape that cancelled
seq=$(grep -a "the view is\|cancelled" "$t/parent_seq.txt" | sed 's/.*: //' | tr '\n' ',')
case $seq in
*"the view is Signals,switch parent cancelled,switch parent cancelled,") ;;
*) fail "the cancels or the view: $seq ($t/parent_seq.txt)" ;;
esac
if grep -aE "attempt to|stack traceback" "$t/kitparent.log" "$t/kitparent2.log" | head -5 | grep -a .; then
	fail "a Lua error in the logs"
fi
echo "ok: Switch parent and Un-parent in Signals: refusals stay armed, past a rebuild and another view, picked in the list, indented, Escape and the button cancel; narrow touch"
# 9. A real window (no -w: the fit is on) made small and large again: the UI
# back at its full scale, the Signals view's panels not holding the fit down
cat > "$t/kitfit.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log_any 10000 kit editor: edit mode on
frames 5
event kit_select $FLAG
frames 3
keypress F5
wait_log_any 10000 signals: columns in
wait_log_any 20000 screen mode: 500x400
wait_log_any 20000 UI scale fitted to the screen: x0
wait_log_any 20000 screen mode: 1400x900
wait_log_any 20000 UI scale fitted to the screen: x1
frames 5
screenshot @T@/refit.png
quit
EOF
sed -i "s|@T@|$t|g" "$t/kitfit.cmds"
BUILDAT_TEST_REAL_WINDOW=1 BUILDAT_JOIN_NAME=kitboss timeout 120 bin/buildat -C "$t/client_cache" -D "$t/cu_kitfit" \
	-s localhost:$SERVER_PORT -l 3 -c @"$t/kitfit.cmds" > "$t/kitfit.log" 2>&1 &
fit_pid=$!
CHECK_PIDS+=($fit_pid)
wait_for_log "$t/kitfit.log" "signals: columns in" 60
win=$(xdotool search --pid "$(pgrep -P "$fit_pid")" 2>/dev/null | tail -1)
[ -n "$win" ] || fail "no window of the client to resize"
xdotool windowsize "$win" 500 400
wait_for_log "$t/kitfit.log" "I __app   : UI scale fitted to the screen: x0" 20
xdotool windowsize "$win" 1400 900
wait "$fit_pid" || fail "the UI's scale did not come back in a larger window ($t/kitfit.log)"
grep -a "I __app   : UI scale [0-9]" "$t/kitfit.log" | tail -1 | grep -q "UI scale 0.833333 (1400x900)" || fail "the last scale ($t/kitfit.log)"
echo "ok: a window made small and large again has the UI at its full scale"
stop_server
want "$t/kitwide.log" "signals: $FLAG $FLAG Home flag: " "signals: columns in 1800x1000 "
wantp "$t/kitwide.log" "signals: columns in 1800x1000 under \d+: sg_list \d+ \d+ \d+ \d+, sg_links \d+ \d+ \d+ \d+, inspector \d+ \d+ \d+ \d+, sg_view "
# What the arrow says: a value's type, nothing for a trigger
wantp "$t/kitwide.log" "signals: $FLAG $FLAG Home flag: .*left>value number"
# A string's label
wantp "$t/kitwide.log" "signals: $FLAG $FLAG Home flag: .*scored>a team"
if grep -a "signals: $FLAG $FLAG Home flag: " "$t/kitwide.log" | grep -aq "home>hide"; then
	fail "a trigger shown as carrying a value ($t/kitwide.log)"
fi
wantp "$t/kitwide.log" "signals: the HUD in the viewport on"
wantp "$t/kitnarrow.log" "signals: columns in 600x400 under \d+: sg_links \d+ \d+ 588 \d+"
wantp "$t/kitnarrow.log" "signals: columns in 600x400 under \d+: sg_list \d+ \d+ 588 \d+"
wantp "$t/kitnarrow.log" "signals: columns in 600x400 under \d+: inspector \d+ \d+ 588 \d+$"
echo "ok: the name after a restart, read by another client; a wide window; one column at a time on a narrow touch one"
if grep -aE "kit: ui: |kit: ui handles: |attempt to|stack traceback" "$b" "$t/kitwide.log" "$t/kitnarrow.log" | grep -av " I kit editor" | head -5 | grep -a .; then
	fail "a Lua error in the logs"
fi
echo "PASS: the Signals view: its columns by width, links added, unlinked and hidden, names followed, a rename kept, the filter, the viewport and its HUD; screenshots $t/signals.png $t/added.png $t/hud.png $t/wide.png $t/narrow_links.png"
