#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# A survey of Kit's editor on touchscreens ([KIT_PHONE_EDITING]'s design
# sweep, 2026-11-11), not a check: Workbench's web client in headless Chrome
# by finger (TOUCH=1) at phone and tablet sizes and by mouse at a desktop's,
# through util/web_drive.sh, every editor screen shot. page.log has the UI
# scale lines and "SURVEY: <shot>" before each shot; drive.log has every tap
# target's rectangle per shot ("DUMP <shot> <type>": the client's answer to a
# click by a label no element has). The editor's default font (80 %). A
# field typed in has a stand-in keyboard (buildatKeyboard.test, 42 % of the
# height), which the page does not draw. fp412x915: the floorplanner's
# editor as a phone, briefly.
#
#   util/kit_phone_survey.sh <out dir> [p412x915 p360x780 l915x412 t800x1280
#       t1280x800 d1600x900 fp412x915]
#
# One size at a time, each a server of its own; <out dir>/<size>/ gets the
# shots, page.log, server.log, drive.log and steps.json.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 1 ] || { sed -n '14,15p' "$0" | sed 's/^# *//' >&2; exit 2; }
out=$(mkdir -p "$1" && cd "$1" && pwd); shift
sizes=${*:-p412x915 p360x780 l915x412 t800x1280 t1280x800 d1600x900 fp412x915}
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9 BUILDAT_AITTA_DEFAULT=https://127.0.0.1:9 \
	BUILDAT_HEARTH_DEFAULT=https://127.0.0.1:9
status=0
for s in $sizes; do
	# Touch; the editor's narrow() (Tools and Inspector are the bar's);
	# where a finger scrolls the inspector, as a fraction of the width (on
	# its labels: a drag begun on a field focuses it); the game
	case $s in
		p412x915|p360x780) t=1 n=1 dx=0.25 g=workbench ;;
		l915x412) t=1 n=1 dx=0.62 g=workbench ;;
		t800x1280) t=1 n=1 dx=0.33 g=workbench ;;
		t1280x800) t=1 n=0 dx=0.57 g=workbench ;;
		d1600x900) t=0 n=0 dx=0 g=workbench ;;
		fp412x915) t=1 n=1 dx=0 g=floorplanner ;;
		*) echo "kit_phone_survey: no size $s" >&2; exit 2 ;;
	esac
	wh=${s:1}; wh=${wh#p}; w=${wh%x*} h=${wh#*x}
	mkdir -p "$out/$s"
	python3 -I - "$g" "$t" "$out/$s/steps.json" "$w" "$h" "$n" "$dx" <<'PY' || exit 1
import json, sys
game, touch, path = sys.argv[1], sys.argv[2] == "1", sys.argv[3]
W, H, narrow = int(sys.argv[4]), int(sys.argv[5]), sys.argv[6] == "1"
DX = int(W * float(sys.argv[7]))
KB = int(H * 0.42)
S = []
def a(*s): S.append(list(s))
def fr(n=3): a("frames", n)
def tap(t, l, *xy): a("tap" if touch else "click", t, l, *xy)
def at(x, y): a("tap" if touch else "click", int(x), int(y))
def kb(h):
    if touch:
        a("eval", "buildatKeyboard.test = %s, 'keyboard %s'" % (h, h)); fr(5)
def shot(name):
    fr(5)
    a("eval", "console.log('SURVEY: %s'), 'note'" % name)
    a("shot", "${OUT}/" + name + ".png")
    a("event", "kit_ui_where " + name); fr(2)
    for t in ("Button", "LineEdit", "DropDownList", "CheckBox", "Text"):
        a("eval", "Module.buildatFound = null, Module.buildatFind = "
                "'click %s \"\\u0001\"', 'ask'" % t)
        fr(2)
        a("eval", "'DUMP %s %s\\n' + Module.buildatFound" % (name, t))
def view(v):
    if touch:
        a("tap", "DropDownList", "▼", 60, 18)
        a("waitlog", "ui_utils: dropdown_[0-9]+ open", 10); fr(3)
        a("tap", "Text", v)
    else:
        a("key", {"2D": "F1", "3D": "F2", "Walk": "F3", "Signals": "F5"}[v])
    a("waitlog", "kit editor: the view is " + v, 10); fr(5)
def cancel():
    if touch: a("tap", "Button", "Cancel", W, H)
    else: a("key", "Escape")
def let_go():
    # Escape with nothing to cancel opens the pause menu on a desktop
    if touch: cancel()
    else: a("click", W // 2, int(H * 0.85))
def scroll_down():
    if touch:
        for _ in range(3):
            a("drag", DX, int(H * 0.75), DX, int(H * 0.17), "touch"); fr(5)
        a("wait", 800)
    else:
        a("mouse", W - 100, int(H * 0.5))
        for _ in range(12): a("wheel", W - 100, int(H * 0.5), 120); fr(2)
def filt(s):
    tap("Button", "palette filter clear"); fr(2)
    tap("LineEdit", "palette filter"); fr(2); a("type", s); fr(3)

cx, cy = W // 2, int(H * 0.55)
a("nav", "${URL}")
a("waitlog", "accounts: the login page shown", 120); a("wait", 1000)
for _ in range(3): a("key", "Tab"); fr(2)
a("key", "Enter"); a("wait", 1000)
a("selall"); fr(2); a("type", "webboss"); fr(2); a("key", "Tab"); fr(2)
a("type", "checkpass12"); fr(2); a("key", "Tab"); fr(2)
a("type", "checkpass12"); fr(2); a("key", "Tab"); fr(2)
a("type", "${SETUP_CODE}"); fr(2); a("key", "Tab"); fr(2)
a("key", "Enter"); a("waitlog", "Joined as webboss", 30)
if game == "floorplanner":
    a("wait", 1000)
    shot("fp_00_plans")
    a("type", "phoneplan"); a("key", "Enter")
    a("waitlog", "Entered the plan phoneplan", 30); a("wait", 1000)
    a("waitlog_any", "server window: the page ntfy", 30); fr(3)
    tap("Button", "Don't add"); fr(5)
    shot("fp_01_entered")
    tap("Button", "Start editing"); fr(5)
    shot("fp_01b_editing")
    tap("Button", "Palette"); fr(5)
    shot("fp_01c_palette")
    tap("Button", "Palette"); fr(5)
    # A room drawn (its tool by its key: the toolbar's Room is the same)
    a("key", "r"); fr(3)
    for x, y in ((0.3, 0.4), (0.7, 0.4), (0.7, 0.6), (0.3, 0.6), (0.3, 0.4)):
        at(W * x, H * y); fr(3)
    a("wait", 800)
    shot("fp_02_room")
    a("key", "Escape"); fr(3)
    at(W * 0.5, H * 0.4); a("wait", 800)
    shot("fp_03_selected")
    kb(KB)
    tap("LineEdit", "*", W, H); fr(5)
    shot("fp_04_field_keyboard")
    kb("null")
    a("key", "F2"); a("wait", 1000)
    shot("fp_05_3d")
    json.dump(S, open(path, "w"), indent=0)
    sys.exit(0)
a("waitlog_any", "server window: the page ntfy", 30); fr(3)
tap("Button", "Don't add"); fr(3)
a("waitlog_any", "world_menu: the list shown, 0 worlds", 30); fr(3)
tap("Button", "New project...")
a("waitlog", "world_menu: the name screen shown", 10); fr(3)
tap("Button", "Create")
a("waitlog", "player physics enabled", 120)
a("waitlog_any", "kit editor: edit rights: yes", 10); a("wait", 1000)
shot("00_play")
if touch:
    tap("Button", "Menu", W, H)
else:
    a("key", "Escape")
a("waitlog", "pause: the menu shown", 10)
shot("01_pause_menu")
tap("Button", "Edit", W // 2, H // 2)
a("waitlog", "kit editor: state: 1 entities", 20); a("wait", 1000)
shot("02_edit_walk")
# The view dropdown
tap("DropDownList", "▼", 60, 18)
a("waitlog", "ui_utils: dropdown_[0-9]+ open", 10)
shot("03_view_dropdown")
tap("Text", "3D*"); a("waitlog", "kit editor: the view is 3D", 10)
shot("04_3d")
# The scene dropdown and its dialog, typed in
tap("DropDownList", "▼", W, 18)
a("waitlog", "ui_utils: dropdown_[0-9]+ open", 10)
shot("05_scene_dropdown")
tap("Text", "New scene...")
shot("06_scene_dialog")
tap("LineEdit", "*", W // 2, H // 2); kb(KB)
shot("07_scene_dialog_keyboard")
kb("null"); tap("Button", "Cancel", W // 2, H // 2)
# The palette, its filter typed in, its menu
if narrow: tap("Button", "Tools"); fr(5)
shot("08_palette")
tap("Button", "palette filter clear"); fr(2)
tap("LineEdit", "palette filter"); kb(KB); a("type", "kit/game_rules"); fr(3)
shot("09_palette_filter_keyboard")
kb("null")
tap("Button", "kit/game_rules")
a("waitlog", "the palette.s menu of kit/game_rules", 10)
shot("10_palette_menu")
tap("Button", "menu Place"); a("waitlog", "kit editor: selected 3", 10); fr(5)
shot("11_rules_selected")
# The 2D view, an entity placed from the palette by a tap
view("2D")
shot("12_2d")
if narrow: tap("Button", "Tools"); fr(5)
filt("kit/button")
tap("Button", "kit/button"); a("waitlog", "kit editor: placing kit/button", 10)
shot("13_placing")
if narrow: tap("Button", "Tools"); fr(5)
at(cx, cy); a("waitlog", "kit editor: state: 3 entities", 10)
shot("14_placed")
cancel(); fr(3)
if narrow: tap("Button", "Inspector"); fr(5)
# The entity tapped in the plan, then held (its menu)
at(cx, cy); a("sync", 5000); fr(5)
shot("15_entity_tapped")
let_go(); fr(3)
a("event", "kit_select 4"); a("waitlog", "kit editor: selected 4", 10); fr(3)
if touch: a("hold", cx, cy, 800)
else: a("click", cx, cy, 100, 2)
a("waitlog", "kit editor: the menu of", 10)
shot("15b_context_menu")
let_go(); fr(3)
a("event", "kit_select 4"); a("waitlog", "kit editor: selected 4", 10); fr(3)
if narrow: tap("Button", "Inspector"); fr(8)
shot("16_inspector_button")
# A door beside it, its Try, its log
a("event", 'kit_edit {"op": "place", "type": "kit/door", "pos": [3, 1, 0]}')
a("waitlog", "kit editor: state: 4 entities", 10)
a("event", "kit_select 5"); a("waitlog", "kit editor: selected 5", 10); fr(8)
shot("17_inspector_door")
scroll_down()
tap("Button", "open"); a("sync", 5000); fr(10)
shot("17b_door_tried")
if narrow:
    tap("Button", "Inspector"); fr(8)
    shot("17c_log_inspector_folded")
    tap("Button", "Inspector"); fr(8)
# Two selected, by the event: a finger has no way to
a("event", "kit_select 4 5"); a("waitlog", "2 in the selection", 10); fr(8)
shot("17d_two_selected")
# The long one: kit/terrain, its foot, a field typed in over the keyboard
a("event", 'kit_edit {"op": "place", "type": "kit/terrain", "pos": [0, 1, 4]}')
a("waitlog", "kit editor: state: 5 entities", 10)
a("event", "kit_select 6"); a("waitlog", "kit editor: selected 6", 10); fr(8)
shot("18_inspector_terrain")
scroll_down()
shot("19_inspector_terrain_foot")
tap("LineEdit", "64", W, H)
if touch:
    kb(KB)
    a("waitlog", "kit editor: typing in the inspector", 10)
a("type", "8"); fr(5)
shot("20_inspector_typing_keyboard")
tap("Button", "Apply"); a("waitlog", "entities, [0-9]+ to undo", 10)
kb("null"); fr(5)
# The left panel's other tabs, the voxel dialog typed in
if narrow: tap("Button", "Tools"); fr(5)
for tab in ("Terrain", "Voxels", "Box", "Entities", "Items", "Sounds"):
    tap("Button", tab + "*", 0, 0); fr(8)
    shot("21_tools_" + tab.lower())
tap("Button", "Voxels*", 0, 0); fr(5)
tap("Button", "New voxel type...*"); fr(8)
shot("22_voxel_dialog")
tap("LineEdit", "my_voxel"); kb(KB)
shot("22b_voxel_dialog_keyboard")
kb("null")
tap("Button", "Cancel", W // 2, H // 2); fr(5)
tap("Button", "Place", 0, 0); fr(3)
if narrow: tap("Button", "Tools"); fr(5)
# The builders' panel and the touch bar, nothing selected
let_go(); fr(5)
shot("23_people_touchbar")
# End and Run
tap("Button", "End"); a("sync", 5000); fr(10)
shot("24_ended")
tap("Button", "Run"); a("sync", 5000); fr(10)
shot("25_running")
# Signals, the button selected
a("event", "kit_select 4"); a("waitlog", "kit editor: selected 4", 10); fr(3)
view("Signals")
shot("26_signals")
tap("Button", "+ Add link"); fr(8)
shot("27_signals_add_link")
view("3D")
shot("28_3d_selected")
view("Walk")
shot("28b_walk")
tap("Button", "Play mode"); a("waitlog", "kit editor: edit mode off", 10); fr(10)
shot("29_play_mode")
json.dump(S, open(path, "w"), indent=0)
PY
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/buildat_phone_survey.XXXXXX")
	echo "kit_phone_survey: $s"
	if [ "$t" = 1 ]; then export TOUCH=1; else unset TOUCH; fi
	WEB_DRIVE_VIEWPORT=${w}x$h@1 "$here/util/web_drive.sh" chrome "$g" \
			"$out/$s/steps.json" "$tmp" > "$out/$s/drive.log" 2>&1 ||
		{ status=1; echo "kit_phone_survey: $s failed: $out/$s/drive.log" >&2; }
	cp "$tmp"/*.png "$tmp/page.log" "$tmp/server.log" "$out/$s/" 2>/dev/null
	# (the browser's last writes into its profile can outlive web_drive.sh)
	rm -rf "$tmp" 2>/dev/null || { sleep 1; rm -rf "$tmp"; }
done
exit $status
