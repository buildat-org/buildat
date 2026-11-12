#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~9 min, five web drives (2026-11-12)
# covers: builtin/kit/client_lua/shell.lua builtin/kit/client_lua/field_entry.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/controls.lua
# [KIT_PHONE_EDITING] stage 1, the touch mode's split screen: Workbench's
# web client in headless Chrome by finger (TOUCH=1), the editor's UI mode
# left to the device (kit_ui_mode=0, touch on a touchscreen), as a phone in
# portrait (412x915) and in landscape (915x412), and left-handed in
# landscape (kit_ui_mode=3). In each: edit mode by the play bar's Menu and
# the pause menu's Edit, the 2D view by the header's views' dropdown, a
# kit/button tapped in the palette's pane and the world tapped:
#   - no "UI scale" line from edit mode on (a fixed scale, no fit);
#   - every target in the UI half (a button, field, dropdown, check box:
#     kit_touch_targets) at least the touch size (32 UI px) each way;
#   - the world's rect and the UI half's apart, and no pane's window
#     (kit_ui_where) over the world;
#   - the world tap placed the kit/button (the server's log), and it is
#     selected, the placing ended;
#   - the world's hint one line (its lines);
#   - portrait: the inspector's "position x" tapped and a stand-in keyboard
#     up (buildatKeyboard.test, 42 % of the height): the UI half above it,
#     the world shorter by as much, the field above the keyboard.
# Stage 3, the world's gestures, by finger in p412x915 and l915x412, in the
# plan at a known camera (kit_plan 0 0 16 8):
#   - a kit/button placed at the world's foot: the plan panned to show it
#     (each placed one armed again from the palette, Back from the
#     inspector);
#   - two more placed side by side, B where A's out ports are on the
#     desktop: a tap on A, then on B selects B; nothing links, no port is
#     shown;
#   - Select+ on: a tap adds A to B, a drag on A moves both 3 cells (the
#     server's log), a drag on nothing boxes both;
#   - A alone turned by Turn + and raised by Up (the server's log);
#   - two fingers spread and moved: the plan zoomed, nothing selected or
#     edited meanwhile;
#   - the Voxels tab: a finger held places a voxel, a tap there digs it
#     (the client's and the server's log, the same cell).
# And m1600x900: the touch mode by mouse (kit_ui_mode=2, no TOUCH): the same
# with the left click a tap, the left drag a finger's, the right click a
# finger held, and for the two fingers a right drag (the plan panned) and a
# middle drag (the plan zoomed), nothing selected or edited meanwhile.
# Stage 2 (after stage 3's in the same runs), the field entry mode (field_entry.lua); the inspector scrolled to
# a field by the event kit_inspector_show:
#   - landscape (915x412): kit/button's hold (a number) typed with the
#     stand-in keyboard up: 99 refused in place, the mode kept, 2.5 applied
#     (the server's log); typed again and Cancelled (not sent); Next and
#     Prev through own_look (a yes/no list), sound_press (a choice list) and
#     back past hold to color_down; color (text) applied; sound_press picked
#     from its list, no keyboard; the inspector's + stepper and Apply; a
#     kit/door placed: mirror Yes applied; a size past the world refused by
#     the server, in place, and Cancelled; the door's position x typed in
#     the mode (the sweep of 2026-11-12: a wide screen's keyboard covered
#     the row) and applied, a move; the field and the buttons above the
#     keyboard;
#   - portrait (412x915): the x/y/z row and Move inside the pane; a kit/npc
#     placed, its lines (long text) open the mode and are applied.
# Stage 4b, the views and Walk:
#   - edit mode begins in 3D (also m1600x900); the header's Tools in each
#     target dump, no "..."; Walk, 3D and 2D picked in turn from its views'
#     dropdown, the header showing each (its line); in 3D Tools' To the
#     surface (the camera put above the ground);
#   - p412x915 and l915x412, Walk by finger: a kit/button placed ahead; a
#     drag from its middle while it is not selected, and one from the sky,
#     turn the view (controls.lua's line) with nothing selected or edited;
#     tapped, it is selected, and a drag from its middle moves it (the
#     server's log); the stick at the world's lower left walks (the body
#     moved); the touch bar (Jump) in the world's lower right;
#   - a drag from the header's empty part (the palette's, its title a
#     label) moves the divider (the world taller, the UI half wider);
#   - m1600x900: Walk by mouse as the desktop's, a click into the crosshair.
# And a mouse at 1600x900 (no TOUCH): the desktop's layout (the bar, the
# palette at the left, no shell), a click on the palette and one on the
# plan place the button.
#
#   util/kit_touch_mode_check.sh [p412x915 l915x412 lh915x412 m1600x900 d1600x900]
#
# Shots: <tmp>/<run>/*.png (KEEP_TMP=1 keeps them).
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ] ||
	skip "no Chrome or web/"
check_tmp kit_touch_mode; t=$CHECK_TMP
runs=${*:-p412x915 l915x412 lh915x412 m1600x900 d1600x900}
for r in $runs; do
	# gest: stage 3's gestures too
	gest=0
	case $r in
		p412x915) w=412 h=915 mode=0 touch=1 gest=1 ;;
		l915x412) w=915 h=412 mode=0 touch=1 gest=1 ;;
		lh915x412) w=915 h=412 mode=3 touch=1 ;;
		m1600x900) w=1600 h=900 mode=2 touch=0 gest=1 ;;
		d1600x900) w=1600 h=900 mode=0 touch=0 ;;
		*) fail "no run $r" ;;
	esac
	mkdir -p "$t/$r"
	python3 -I - "$t/$r/steps.json" "$w" "$h" "$mode" "$touch" "$gest" <<'PY' || fail "steps of $r"
import json, re, sys
path, W, H, mode, touch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5] == "1"
gest = sys.argv[6] == "1"
S = []
def a(*s): S.append(list(s))
def fr(n=3): a("frames", n)
tap = "tap" if touch else "click"
# [KIT_PHONE_EDITING] stage 3: the world's gestures in the plan at a known
# camera (16 cells across the world's height, about 0, 0), where the
# kit/buttons go: C at the world's foot, A and B side by side (B where A's
# port is: 2 cells), V a voxel's
def gestures():
    if H > W: wx, wy, ww, wh = 0, 0, W, round(H * 0.45)
    elif mode == "3": wx, wy, ww, wh = round(W * 0.5), 0, W - round(W * 0.5), H
    else: wx, wy, ww, wh = 0, 0, W - round(W * 0.5), H
    cx, cy, c = wx + ww / 2, wy + wh / 2, wh / 16
    def at(x, z): return [round(cx + x * c), round(cy - z * c)]
    drag = "drag" if touch else "ldrag"
    def plan():
        a("event", "kit_plan 0 0 16 8"); a("waitlog", "kit editor: the view is 2D", 10); fr(5)
    A, B, A2, V = at(-4, -4), at(-2, -4), at(-1, -4), at(4, 3)
    def arm():
        # (the palette Back from the inspector of the one placed before)
        a(tap, "Button", "shell back"); a("waitlog", "touch shell: back to the palette pane", 10); fr(10)
        a(tap, "Button", "kit/button"); a("waitlog", "kit editor: placing kit/button", 10); fr(5)
    plan()
    arm()
    a(tap, round(cx + 3 * c), wy + wh - 5); a("waitlog", "kit editor: state: 3 entities", 20)
    a("waitlog", "touch shell: panned to show", 10); fr(5)
    a("shot", "${OUT}/10_revealed.png")
    plan()
    arm()
    a(tap, *A); a("waitlog", "kit editor: state: 4 entities", 20); fr(3)
    arm()
    a(tap, *B); a("waitlog", "kit editor: state: 5 entities", 20)
    a("waitlog", "touch shell: the inspector pane", 10); fr(5)
    # A, then B where A's ports would be on the desktop
    a(tap, *A); a("waitlog", r"kit editor: selected \d+ \(", 10); fr(3)
    a(tap, *B); a("waitlog", r"kit editor: selected \d+ \(", 10); fr(3)
    a("shot", "${OUT}/11_selected.png")
    # Select more: A added, both moved by a drag on A
    a(tap, "Button", "shell select more"); a("waitlog", "select more on", 10); fr(3)
    a(tap, *A); a("waitlog", r"kit editor: selected \d+ .*, 2 in the selection", 10); fr(3)
    a(drag, A[0], A[1], round(A[0] + 3 * c), A[1])
    a("waitlog", "kit editor: moved 2 by 3, 0", 20); a("sync", 5000); fr(5)
    a("shot", "${OUT}/12_moved.png")
    # None, then both boxed on nothing
    a(tap, "Button", "shell select more"); a("waitlog", "select more off", 10); fr(3)
    a(tap, *at(-5, 2)); a("waitlog", "kit editor: selected none", 10); fr(3)
    a(tap, "Button", "shell select more"); a("waitlog", "select more on", 10); fr(3)
    a(drag, *at(-3, -2.5), *at(2.5, -5.5))
    a("waitlog", "kit editor: a box selected 2, 2 in the selection", 10); fr(3)
    a(tap, "Button", "shell select more"); a("waitlog", "select more off", 10); fr(3)
    # A alone: a turn step, a step up
    a(tap, *A2); a("waitlog", r"kit editor: selected \d+ \(", 10); fr(3)
    a(tap, "Button", "shell turn +"); a("sync", 5000); fr(3)
    a(tap, "Button", "shell up"); a("sync", 5000); fr(5)
    a("shot", "${OUT}/13_turned_raised.png")
    # The view moved: two fingers, or the right and middle drags
    a("event", "kit_mode view"); a("waitlog", r"the mode: edit \(view\)", 10)
    if touch:
        p, q, p1, q1 = at(-2, 1), at(2, 1), at(-4, 3), at(4, 3)
        a("fingers", *p, *q, *p1, *q1)
        a("waitlog", "kit editor: two fingers let go: the plan", 10)
    else:
        a("rdrag", *at(-2, 1), *at(1, 3)); a("waitlog", "the right drag let go", 10); fr(3)
        a("mouse_drag", "middle", 4, *at(0, 1), *at(0, 3))
        a("waitlog", "the middle let go", 10)
        a("wheel", *at(0, 1), -300); a("waitlog", "kit editor: the wheel: the plan", 10); fr(3)
    a("event", "kit_mode viewed"); a("waitlog", r"the mode: edit \(viewed\)", 10); fr(5)
    a("shot", "${OUT}/14_view_moved.png")
    # Voxels: held (a right click) places, a tap digs
    plan()
    a(tap, "Button", "shell back"); a("waitlog", "touch shell: back to the palette pane", 10); fr(10)
    a(tap, "DropDownList", "palette tabs"); a("waitlog", "palette tabs open", 10); fr(3)
    a(tap, "Text", "palette tabs: Voxels"); a("waitlog", "kit editor: tool voxels", 10); fr(5)
    if touch: a("hold", *V, 800)
    else: a("click", *V, 0, 2)
    a("waitlog", r"kit editor: place \S+ at", 10); a("sync", 5000); fr(5)
    a("shot", "${OUT}/15_voxel_placed.png")
    a(tap, *V); a("waitlog", "kit editor: dig at", 10); a("sync", 5000); fr(5)
    a(tap, "Button", "shell cancel"); a("waitlog", "kit editor: tool select", 10); fr(3)
    # A (a kit/button) selected again: stage 2's steps begin in its inspector
    a(tap, *A2); a("waitlog", "touch shell: the inspector pane", 10); fr(10)
a("nav", "${URL}?pref=kit_editor_font=100&pref=kit_ui_mode=" + mode)
a("waitlog", "accounts: the login page shown", 120); a("wait", 1000)
for _ in range(3): a("key", "Tab"); fr(2)
a("key", "Enter"); a("wait", 1000)
a("selall"); fr(2); a("type", "webboss"); fr(2); a("key", "Tab"); fr(2)
a("type", "checkpass12"); fr(2); a("key", "Tab"); fr(2)
a("type", "checkpass12"); fr(2); a("key", "Tab"); fr(2)
a("type", "${SETUP_CODE}"); fr(2); a("key", "Tab"); fr(2)
a("key", "Enter"); a("waitlog", "Joined as webboss", 30)
a("waitlog_any", "server window: the page ntfy", 30); fr(3)
a(tap, "Button", "Don't add"); fr(3)
a("waitlog_any", "world_menu: the list shown, 0 worlds", 30); fr(3)
a(tap, "Button", "New project...")
a("waitlog", "world_menu: the name screen shown", 10); fr(3)
a(tap, "Button", "Create")
a("waitlog", "player physics enabled", 120)
a("waitlog_any", "kit editor: edit rights: yes", 10); fr(5)
def dump(name):
    fr(3)
    a("event", "kit_touch_targets " + name); a("event", "kit_ui_where " + name)
    a("waitlog", r"the windows at .*\(" + name + r"\)", 10)
def view(label):
    # The header's dropdown: its list, a pick ("3D" the "3D · <scene>" too)
    a(tap, "DropDownList", "shell views"); a("waitlog", "shell views open", 10); fr(3)
    a(tap, "Text", "shell views: " + label + "*")
    a("waitlog", "kit editor: the view is " + label, 10); fr(5)
if not touch and mode == "2":
    # The touch mode by mouse: the pause menu's Edit, the plan, the palette's
    # filter, a click on the world, then stage 3's
    a("waitlog_any", "pause: the menu shown", 10); fr(3)
    a("click", "Button", "Edit*")
    a("waitlog", "kit editor: touch shell on", 20)
    a("waitlog", "kit editor: touch shell: pixels", 10); fr(10)
    a("shot", "${OUT}/01_edit.png")
    dump("edit")
    # (the palette's pane the first)
    a("event", "kit_plan 0 0 16 8"); a("waitlog", "kit editor: the view is 2D", 10); fr(10)
    a("click", "Button", "palette filter clear"); fr(2)
    a("click", "LineEdit", "palette filter"); fr(2); a("type", "kit/button"); fr(5)
    a("click", "Button", "kit/button"); a("waitlog", "kit editor: placing kit/button", 10); fr(10)
    a("shot", "${OUT}/03_placing.png")
    dump("placing")
    a("click", W // 4, H // 2); a("waitlog", "kit editor: state: 2 entities", 20)
    a("waitlog", "touch shell: the inspector pane", 10); fr(10)
    a("shot", "${OUT}/04_placed.png")
    dump("placed")
    gestures()
    dump("gestures")
    # Stage 4b: Walk by mouse as the desktop mode's: a click goes up into
    # the crosshair
    view("Walk")
    a("click", W // 4, H // 2); a("waitlog", "kit editor: into the crosshair", 10); fr(5)
    json.dump(S, open(path, "w"), indent=0)
    sys.exit(0)
if not touch:
    # The desktop's: the pause menu's Edit, the plan, the palette's filter
    # and a click on the plan
    a("waitlog_any", "pause: the menu shown", 10); fr(3)
    a("click", "Button", "Edit*"); a("waitlog", "kit editor: state: 1 entities", 20); fr(10)
    a("event", "kit_plan 0 0 50 0"); a("waitlog", "kit editor: the view is 2D", 10); fr(10)
    a("shot", "${OUT}/01_desktop.png")
    dump("desktop")
    a("click", "Button", "palette filter clear"); fr(2)
    a("click", "LineEdit", "palette filter"); fr(2); a("type", "kit/button"); fr(3)
    a("click", "Button", "kit/button"); a("waitlog", "kit editor: placing kit/button", 10)
    a("click", W // 2, int(H * 0.6)); a("waitlog", "kit editor: state: 2 entities", 20)
    fr(10); a("shot", "${OUT}/02_desktop_placed.png")
    json.dump(S, open(path, "w"), indent=0)
    sys.exit(0)
# The play bar's Menu (a mouse's join has the pause menu up already)
a("tap", "Button", "Menu", W, H); a("waitlog", "pause: the menu shown", 10); fr(3)
a("tap", "Button", "Edit*")
a("waitlog", "kit editor: touch shell on", 20)
a("waitlog", "kit editor: touch shell: pixels", 10); fr(10)
a("shot", "${OUT}/01_edit.png")
dump("edit")
# Stage 4b: begun in 3D; the header's views picked from its dropdown
# (Walk, 3D, then 2D for what follows), the header showing each; the Tools
# pane, its To the surface in 3D (item 2 of the phone test of 2026-11-12:
# the camera in a cave)
a("waitlog_any", "kit editor: the view is 3D", 10)
a("waitlog_any", r'touch shell: the header: "[^"]*", 3D', 10); fr(5)
a("shot", "${OUT}/02_header.png")
for n in ["Walk", "3D"]:
    view(n); a("waitlog", r'touch shell: the header: "[^"]*", ' + n, 10); fr(5)
a("tap", "Button", "shell tools"); a("waitlog", "touch shell: the tools pane", 10); fr(10)
a("tap", "Button", "To the surface"); a("waitlog", "kit editor: to the surface: the 3D camera at", 10); fr(5)
a("shot", "${OUT}/02_tools.png")
dump("tools")
a("tap", "Button", "shell back"); a("waitlog", "touch shell: back to the palette pane", 10); fr(10)
view("2D"); a("waitlog", r'touch shell: the header: "[^"]*", 2D', 10); fr(5)
a("tap", "Button", "palette filter clear"); fr(2)
a("tap", "LineEdit", "palette filter"); fr(2); a("type", "kit/button"); fr(5)
a("tap", "Button", "kit/button"); a("waitlog", "kit editor: placing kit/button", 10); fr(10)
a("shot", "${OUT}/03_placing.png")
dump("placing")
# The world's middle: above (tall), or beside the UI half
if H > W: x, y = W // 2, int(H * 0.45 / 2)
elif mode == "3": x, y = int(W * 0.75), H // 2
else: x, y = W // 4, H // 2
a("tap", x, y); a("waitlog", "kit editor: state: 2 entities", 20)
a("waitlog", "touch shell: the inspector pane", 10); fr(10)
a("shot", "${OUT}/04_placed.png")
dump("placed")
if H > W:
    # (the inspector's position after its parameters: scrolled to)
    a("event", "kit_inspector_show position x"); a("waitlog", "the inspector shows position x$", 10); fr(3)
    a("tap", "LineEdit", "position x"); fr(5)
    a("eval", "buildatKeyboard.test = %d, 'keyboard'" % int(H * 0.42))
    a("waitlog", "kit editor: typing in the inspector", 10)
    a("waitlog_any", r"touch shell: pixels: .*the keyboard [1-9]", 10); fr(10)
    a("shot", "${OUT}/05_keyboard.png")
    dump("keyboard")
    a("eval", "buildatKeyboard.test = null, 'no keyboard'"); fr(5)
if gest:
    gestures()
# Stage 2: the field entry mode. Another entity placed from the palette's
# pane, beside the first
def place(t):
    # (the palette Back from the inspector)
    a("tap", "Button", "shell back"); a("waitlog", "touch shell: back to the palette pane", 10); fr(10)
    a("tap", "Button", "palette filter clear"); fr(2)
    a("tap", "LineEdit", "palette filter"); fr(2); a("type", t); fr(5)
    a("tap", "Button", t); a("waitlog", "kit editor: placing " + t, 10); fr(10)
    a("tap", x, y + 60 if H > W else y - 60)
    a("waitlog", "touch shell: the inspector pane", 20); fr(10)
def tapf(t, name):
    # The inspector scrolled to it first: the pane is a few rows high
    a("event", "kit_inspector_show " + name)
    a("waitlog", "the inspector shows " + re.escape(name) + "$", 10); fr(3)
    a("tap", t, name)
def entry(field, kind):
    a("waitlog", r"field entry: \d+/\d+ %s \(%s\)" % (field, kind), 10)
    a("waitlog", "field entry: laid out", 10); fr(5)
kb = "buildatKeyboard.test = %d, 'keyboard'" % int(H * 0.42)
if H > W:
    # Long text opens the mode upright too
    place("kit/npc")
    tapf("LineEdit", "field lines"); entry("lines", "long text")
    a("eval", kb); a("waitlog", "field entry: laid out", 10); fr(5)
    a("shot", "${OUT}/06_long_text.png")
    a("selall"); fr(2); a("type", "Hello there|A second line, long enough to wrap in the box"); fr(3)
    a("tap", "Button", "entry apply"); a("waitlog", "field entry: closed, applied", 10)
    a("eval", "buildatKeyboard.test = null, 'no keyboard'"); fr(5)
elif mode == "0":
    a("shot", "${OUT}/05_inspector.png")
    # A number typed: refused in place (over its range), then applied
    tapf("LineEdit", "field hold"); fr(3); a("eval", kb); entry("hold", "number")
    a("shot", "${OUT}/06_entry_number.png")
    a("selall"); fr(2); a("type", "99"); fr(2)
    a("tap", "Button", "entry apply"); a("waitlog", "refused in place: hold: at most 60", 10); fr(5)
    a("shot", "${OUT}/07_entry_refused.png")
    a("selall"); fr(2); a("type", "2.5"); fr(2)
    a("tap", "Button", "entry apply"); a("waitlog", "field entry: closed, applied", 10); fr(5)
    # Cancel: typed and left
    tapf("LineEdit", "field hold"); fr(3); entry("hold", "number")
    a("selall"); fr(2); a("type", "7"); fr(2)
    a("tap", "Button", "entry cancel"); a("waitlog", "field entry: closed, cancelled", 10); fr(5)
    # Next and Prev: hold's neighbours (by name: color, color_down, hold,
    # own_look, sound_press, use)
    tapf("LineEdit", "field hold"); fr(3); entry("hold", "number")
    a("tap", "Button", "entry next"); entry("own_look", "bool")
    a("tap", "Button", "entry next"); entry("sound_press", "choice")
    a("shot", "${OUT}/08_entry_choice_next.png")
    a("tap", "Button", "entry prev"); entry("own_look", "bool")
    a("tap", "Button", "entry prev"); entry("hold", "number")
    a("tap", "Button", "entry prev"); entry("color_down", "text")
    a("tap", "Button", "entry cancel"); a("waitlog", "field entry: closed, cancelled", 10); fr(5)
    # Text
    tapf("LineEdit", "field color"); fr(3); entry("color", "text")
    a("selall"); fr(2); a("type", "#00ff00"); fr(2)
    a("tap", "Button", "entry apply"); a("waitlog", "field entry: closed, applied", 10); fr(5)
    # A choice: a list, no keyboard
    a("eval", "buildatKeyboard.test = null, 'no keyboard'")
    tapf("Button", "field sound_press"); entry("sound_press", "choice")
    a("shot", "${OUT}/09_choice_list.png")
    a("tap", "Button", "choice none"); a("waitlog", "field entry: picked none", 10)
    a("tap", "Button", "entry apply"); a("waitlog", "field entry: closed, applied", 10); fr(5)
    # The inspector's stepper, and its Apply
    tapf("Button", "field hold +"); a("waitlog", "field entry: stepped .* hold to 3.5", 10); fr(5)
    a("shot", "${OUT}/10_steppers.png")
    tapf("Button", "kit apply"); a("waitlog", r'kit editor: sent .*"hold".*3\.5', 10); fr(5)
    # A yes/no, and a refusal of the server's (a size past the world)
    place("kit/door")
    tapf("Button", "field mirror"); entry("mirror", "bool")
    a("tap", "Button", "choice Yes"); a("tap", "Button", "entry apply")
    a("waitlog", "field entry: closed, applied", 10); fr(5)
    tapf("LineEdit", "field size"); fr(3); a("eval", kb); entry("size", "text")
    a("selall"); fr(2); a("type", "1 2 99999"); fr(2)
    a("tap", "Button", "entry apply"); a("waitlog", "refused in place: Refused: set", 10); fr(5)
    a("shot", "${OUT}/11_entry_server_refused.png")
    a("tap", "Button", "entry cancel"); a("waitlog", "field entry: closed, cancelled", 10); fr(5)
    tapf("LineEdit", "position x"); fr(3)
    a("waitlog", r"field entry: position x position x \(number\)", 10)
    a("waitlog", "field entry: laid out", 10); fr(5)
    a("shot", "${OUT}/12_entry_position.png")
    a("selall"); fr(2); a("type", "5"); fr(2)
    a("tap", "Button", "entry apply"); a("waitlog", "field entry: closed, applied", 10); fr(5)
    a("eval", "buildatKeyboard.test = null, 'no keyboard'"); fr(5)
# Stage 4b, Walk by finger: a kit/button E1 placed ahead (the view 8
# degrees down: the tap about 10 m out, E1 where it was tapped); its middle
# found (selected, kit_knob_where), let go of; a drag from its middle and
# one back from the sky turn (nothing selected or moved; the view as it
# was); E1 tapped there and dragged from its middle (moved); the stick; Jump
if gest:
    if H > W: wx, wy, ww, wh = 0, 0, W, round(H * 0.45)
    else: wx, wy, ww, wh = 0, 0, W - round(W * 0.5), H
    def wp(fx, fy): return [round(wx + fx * ww), round(wy + fy * wh)]
    Q1, SKY = wp(0.6, 0.5), wp(0.6, 0.08)
    MID = r"the middle on the screen at (\d+), (\d+)"
    view("Walk")
    a("event", "kit_face 0 8"); fr(10)
    a("tap", "Button", "shell back"); a("waitlog", "touch shell: back to the palette pane", 10); fr(10)
    a("tap", "Button", "palette filter clear"); fr(2)
    a("tap", "LineEdit", "palette filter"); fr(2); a("type", "kit/button"); fr(5)
    a("tap", "Button", "kit/button"); a("waitlog", "kit editor: placing kit/button", 10); fr(5)
    a("tap", *Q1); a("waitlog", "kit editor: placed kit/button at", 10)
    a("waitlog", r"kit editor: selected \d+ \(", 20); fr(5)
    a("event", "kit_knob_where"); a("waitlog", "kit editor: the middle on the screen at", 10)
    a("tap", *SKY); a("waitlog", "kit editor: selected none", 10); fr(5)
    a("event", "kit_mode walk look")
    a("at_log", MID, "drag", -80, 0); a("waitlog", "kit: a look let go", 10); fr(5)
    a("drag", *SKY, SKY[0] + 80, SKY[1]); a("waitlog", "kit: a look let go", 10); fr(5)
    a("sync", 5000)
    a("event", "kit_mode walk looked")
    a("at_log", MID, "tap"); a("waitlog", r"kit editor: selected \d+ \(", 10); fr(10)
    a("shot", "${OUT}/20_walk_selected.png")
    # (from its middle: a knob nearer the finger turns it)
    a("event", "kit_knob_where"); a("waitlog", "kit editor: the middle on the screen at", 10)
    a("at_log", MID, "drag", 60, 0); a("waitlog", "kit editor: moving 1", 10)
    a("sync", 5000); fr(10)
    a("shot", "${OUT}/21_walk_dragged.png")
    a("event", "kit_mode walk stick")
    st = wp(0.2, 0.8)
    a("drag", *st, st[0], st[1] - 60); a("waitlog", "kit: the stick let go", 10); fr(10)
    a("tap", "Button", "touch bar Jump"); fr(10)
    a("shot", "${OUT}/22_walk_stick_jump.png")
    dump("walk")
# Stage 4b: the header dragged by its empty part (the palette's, its title
# a label) moves the divider
if touch:
    a("tap", "Button", "shell back"); a("waitlog", "touch shell: back to the palette pane", 10); fr(10)
    a("shot", "${OUT}/23_header_palette.png")
    if H > W: x0, y0, x1, y1 = 90, round(H * 0.45) + 30, 90, round(H * 0.56)
    elif mode == "3": x0, y0, x1, y1 = 90, 30, 240, 30
    else: x0, y0, x1, y1 = W - (W + 1) // 2 + 90, 30, W - (W + 1) // 2 - 60, 30
    a("event", "kit_mode divider %d" % x0)
    a("drag", x0, y0, x1, y1); a("waitlog", "kit editor: touch shell: the split", 10); fr(10)
    a("shot", "${OUT}/23_divider.png")
    dump("divider")
json.dump(S, open(path, "w"), indent=0)
PY
	echo "kit_touch_mode: $r"
	if [ "$touch" = 1 ]; then export TOUCH=1; else unset TOUCH; fi
	WEB_DRIVE_VIEWPORT=${w}x$h@1 "$here/util/web_drive.sh" chrome workbench \
			"$t/$r/steps.json" "$t/$r" > "$t/$r/drive.log" 2>&1 ||
		fail "the drive $r: $t/$r/drive.log"
	python3 -I - "$t/$r" "$w" "$h" "$touch" "$mode" "$gest" <<'PY' || fail "$r: see above ($t/$r)"
import json, math, re, sys
d, W, H, touch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "1"
mode, gest = sys.argv[5], sys.argv[6] == "1"
page = open(d + "/page.log", errors="replace").read().splitlines()
server = open(d + "/server.log", errors="replace").read()
assert re.search(r"An edit by webboss: placed kit/button \d+", server), \
    "the kit/button was not placed (server.log)"
on = next(i for i, l in enumerate(page) if "kit editor: edit mode on" in l)
if not touch and mode != "2":
    assert not any("touch shell" in l for l in page), "a touch shell on a desktop"
    assert any("kit editor: bar: " in l for l in page[on:]), "no bar on the desktop"
    w = next(l for l in page if "(desktop)" in l and "the windows at" in l)
    pal = re.search(r"palette (\d+) (\d+) (\d+) (\d+)", w)
    assert pal and int(pal[1]) < 40, f"the palette not at the left: {w}"
    print(f"ok: the desktop's layout ({w.split('the windows at ')[1]}), the button placed")
    sys.exit(0)
scale = [l for l in page[on:] if "UI scale" in l]
assert not scale, f"the UI scale changed in edit mode: {scale}"
def rect(s): return list(map(int, s.split()))
def overlap(a, b):
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]
geo = None
seen = {"targets": 0, "windows": 0}
for l in page[on:]:
    m = re.search(r"touch shell: pixels: the world ([\d ]+), the UI ([\d ]+), "
            r"the pane ([\d ]+), the keyboard (\d+), the touch size (\d+)", l)
    if m:
        geo = {"world": rect(m[1]), "ui": rect(m[2]), "pane": rect(m[3]),
            "kb": int(m[4]), "touch": int(m[5])}
        wr, ur = geo["world"], geo["ui"]
        assert not overlap(wr, ur), f"the world {wr} and the UI half {ur} overlap"
        assert ur[0] >= 0 and ur[0] + ur[2] <= W + 1 and ur[1] >= 0, f"the UI half {ur} off the screen"
        continue
    m = re.search(r"touch targets \((\w+)\): (.*)", l)
    if m and geo:
        seen["targets"] += 1
        ur, T, small = geo["ui"], geo["touch"], []
        for t in re.findall(r'(\w+) "([^"]*)" (-?\d+ -?\d+ \d+ \d+)', m[2]):
            x, y, w, h = rect(t[2])
            cx, cy = x + w / 2, y + h / 2
            if ur[0] <= cx < ur[0] + ur[2] and ur[1] <= cy < ur[1] + ur[3] and \
                    (w < T - 1 or h < T - 1):
                small.append(f"{t[0]} \"{t[1]}\" {w}x{h}")
        assert not small, f"under the touch size {T} ({m[1]}): {small}"
        continue
    m = re.search(r"the windows at (.*) \((\w+)\)", l)
    if m and geo:
        seen["windows"] += 1
        for k, r in re.findall(r"(\w+) (-?\d+ -?\d+ \d+ \d+)", m[1]):
            assert not overlap(rect(r), geo["world"]), \
                f"the {k} window {r} over the world {geo['world']} ({m[2]})"
assert seen["targets"] >= 4 and seen["windows"] >= 4, f"too few dumps: {seen}"
if H > W:
    t = "\n".join(page)
    m = re.search(r"typing in the inspector: the field (\d+) to (\d+), .*the keyboard from (\d+)", t)
    assert m, "no typing line"
    f0, f1, kb = map(int, m.groups())
    assert f1 <= kb, f"the field {f0}-{f1} under the keyboard at {kb}"
    k = [l for l in page if re.search(r"touch shell: pixels: .*the keyboard [1-9]", l)]
    g = re.search(r"the world ([\d ]+), the UI ([\d ]+), .*the keyboard (\d+)", k[-1])
    wr, ur, kbh = rect(g[1]), rect(g[2]), int(g[3])
    assert ur[1] + ur[3] <= H - kbh + 2, f"the UI half {ur} under the keyboard {kbh}"
    print(f"ok: the field {f0}-{f1} above the keyboard from {kb}; the world {wr}, the UI {ur}")
    # Stage 2: the x/y/z row inside the pane; long text in the mode, applied
    # (each against the pane of its time, less the inspector's scroll bar)
    pane, row = None, {}
    for l in page:
        m = re.search(r"touch shell: pixels: .*the pane ([\d ]+),", l)
        if m:
            pane = rect(m[1])
        m = re.search(r"the position row's (\w+) at ([\d ]+)", l)
        if m:
            r = row[m[1]] = rect(m[2])
            assert r[0] >= pane[0] and r[0] + r[2] <= pane[0] + pane[2] - 12, \
                f"the position row's {m[1]} {r} out of the pane {pane}"
    assert set(row) == {"x", "y", "z", "move"}, f"the position row: {row}"
    assert re.search(r"set \d+'s kit/npc lines to \"Hello there\|A second line", server), \
        "the long text not applied (server.log)"
    print(f"ok: the position row {row} in the pane {pane}; the long text applied")
if W > H and touch and mode == "0":
    t = "\n".join(page)
    def sets(what): return re.search(r"An edit by webboss: set \d+'s " + what, server)
    for what in [r"kit/button hold to 2\.5", r'kit/button color to "#00ff00"',
            r'kit/button sound_press to ""', r"kit/button hold to 3\.5", r"kit/door mirror to true"]:
        assert sets(what), f"not applied: {what} (server.log)"
    for what in [r"kit/button hold to 7\b", r"kit/button hold to 99\b"]:
        assert not sets(what), f"applied: {what} (server.log)"
    door = re.findall(r"An edit by webboss: placed kit/door (\d+)", server)[-1]
    assert re.search(r"An edit by webboss: moved " + door + r" to \[5,", server), \
        f"the door {door}'s position x not applied from the field entry mode (server.log)"
    assert re.search(r"An edit \(set\) by peer \d+ refused: kit/door's size", server), \
        "the size not refused (server.log)"
    # A refusal keeps the mode: Apply again, not a close, after each
    ev = [l for l in page if "field entry: " in l]
    for i, l in enumerate(ev):
        if "refused in place" in l:
            nxt = next((m for m in ev[i + 1:] if "closed" in m or "applied, waiting" in m), "")
            assert "closed" not in nxt or "cancelled" in nxt, f"closed by a refusal: {l} / {nxt}"
    order = re.findall(r"field entry: \d+/\d+ (\w+) \(", t)
    assert "hold own_look sound_press own_look hold color_down" in " ".join(order), f"Prev/Next: {order}"
    # The typed field and the buttons above the stand-in keyboard
    for l in ev:
        m = re.search(r"laid out (\d+)x(\d+), the field (\d+) to (\d+), the buttons (\d+) to (\d+), the keyboard (\d+)", l)
        if m and int(m[7]) > 0:
            top = int(m[2]) - int(m[7])
            assert int(m[4]) <= top and int(m[6]) <= top, f"under the keyboard: {l}"
    print(f"ok: the field entry mode: {len(order)} fields entered, applied and cancelled as asked, refusals in place")
if gest:
    # [KIT_PHONE_EDITING] stage 3: the gestures, by the client's and the
    # server's logs
    ids = re.findall(r"An edit by webboss: placed kit/button (\d+) at", server)
    assert len(ids) >= 4, f"not 4 kit/buttons placed: {ids}"
    C, A, B = ids[1], ids[2], ids[3]
    def at(pat, start=0):
        return next((i for i in range(start, len(page)) if re.search(pat, page[i])), None)
    assert at(r"touch shell: panned to show " + C + ",") is not None, \
        f"the view not panned to show {C}, placed at the world's foot"
    assert at(r"kit editor: linking from") is None, "a link begun"
    ports = [l for l in page[on:] if "kit editor: out ports of" in l]
    assert not ports, f"ports shown in the touch mode: {ports[:2]}"
    sel = at(r"kit editor: selected " + A + r" \(")
    sel = at(r"kit editor: selected ", sel + 1)
    assert re.search(r"selected " + B + r" \(", page[sel]), f"B not selected after A: {page[sel]}"
    more = at(r"select more on", sel)
    sel = at(r"kit editor: selected ", more)
    assert re.search(r"selected " + A + r" .*, 2 in the selection", page[sel]), \
        f"A not added: {page[sel]}"
    m = re.search(r"An edit by webboss: moved (\d+) (\d+) by \[3,0,0\]", server)
    assert m and {m[1], m[2]} == {A, B}, "A and B not moved by [3,0,0] (server.log)"
    assert at(r"kit editor: a box selected 2, 2 in the selection") is not None, "no box of 2"
    assert re.search(r"An edit by webboss: moved " + A + r" by \[0,0,0\], turned \d+", server), \
        f"{A} not turned (server.log)"
    m = re.search(r"An edit by webboss: moved " + A + r" to \[(-?[\d.]+),(-?[\d.]+),(-?[\d.]+)\]",
        server)
    assert m and m[1] == "-1" and m[3] == "-4", f"{A} not raised at -1, -4 (server.log): {m and m[0]}"
    v0, v1 = at(r"the mode: edit \(view\)"), at(r"the mode: edit \(viewed\)")
    edits = [l for l in page[v0:v1] if re.search(r"kit editor: (moved|selected|placed|place |dig |"
        r"turning|moving|a box|linking)", l)]
    assert not edits, f"the view's move edited: {edits}"
    if touch:
        m = re.search(r"two fingers let go: the plan ([\d.]+) across", "\n".join(page[v0:v1]))
        assert m and abs(float(m[1]) - 16) > 1, f"the plan not zoomed by two fingers: {m and m[0]}"
    else:
        t_ = "\n".join(page[v0:v1])
        m = re.search(r"the right drag let go: the plan at (-?[\d.]+),(-?[\d.]+)", t_)
        assert m and abs(float(m[1])) + abs(float(m[2])) > 1, f"the plan not panned: {m and m[0]}"
        m = re.search(r"the middle let go: the plan ([\d.]+) across", t_)
        assert m and abs(float(m[1]) - 16) > 1, f"the plan not zoomed: {m and m[0]}"
    t_ = "\n".join(page)
    p = re.search(r"kit editor: place (\S+) at (-?\d+),(-?\d+),(-?\d+)", t_)
    q = re.search(r"kit editor: dig at (-?\d+),(-?\d+),(-?\d+)", t_)
    assert p and q and p.groups()[1:] == q.groups(), f"not the placed voxel dug: {p and p[0]}, {q and q[0]}"
    cell = ",".join(q.groups())
    assert re.search(r"A voxel edit by webboss: placed \S+ at \(" + cell + r"\)", server) and \
        re.search(r"A voxel edit by webboss: dug at \(" + cell + r"\)", server), \
        f"no voxel placed and dug at ({cell}) (server.log)"
    print(f"ok: stage 3: {C} revealed; {B} tapped where {A}'s ports are on the desktop, selected; {A} added by "
        f"Select+, both moved, boxed; {A} turned and raised; the view moved with no edit; "
        f"a voxel placed and dug at ({cell})")
if touch or mode == "2":
    # [KIT_PHONE_EDITING] stage 4b: the touch mode's edit mode begun in 3D
    v = next(l for l in page[on:] if "kit editor: the view is " in l)
    assert v.endswith("the view is 3D"), f"edit mode begun not in 3D: {v}"
    print("ok: edit mode begun in 3D")
if touch:
    # The header: its views' dropdown showing each as it was picked; Tools
    # in each target dump, no "..."; its empty part dragged moved the divider
    hd = [l for l in page if "touch shell: the header: " in l]
    assert hd and all(re.search(r"\(Walk[^|]* \| 3D[^|]* \| 2D[^|]* \| Signals", l) for l in hd), \
        f"the header's views: {hd[:2]}"
    lits = " ".join(re.search(r'the header: "[^"]*", (\w+)', l)[1] for l in hd)
    assert re.search(r"^3D( \S+)* Walk( \S+)* 3D( \S+)* 2D", lits), f"shown in turn: {lits}"
    for l in page:
        m = re.search(r"touch targets \((\w+)\): (.*)", l)
        if m:
            got = set(re.findall(r'Button "(Tools|\.\.\.)"', m[2]))
            assert got == {"Tools"}, f"the header's buttons in {m[1]}: {got}"
    assert re.search(r"kit editor: to the surface: the 3D camera at", "\n".join(page)), \
        "not put above the ground by To the surface"
    # The world's hint one line (item 7 of the phone test of 2026-11-12:
    # two lines of the desktop's over the edit)
    gl = [l for l in page[on:] if "kit editor: guide: " in l and "its font" not in l]
    assert gl and not any(" | " in l for l in gl), f"the guide not one line: {gl[:3]}"
    m = re.search(r"touch shell: the split ([\d.]+) ([\d.]+)", "\n".join(page))
    assert m, "the divider not moved by the header"
    # (begun on the empty part: between the title and the views)
    dv = next(i for i, l in enumerate(page) if "the mode: edit (divider " in l)
    x0 = int(re.search(r"divider (\d+)", page[dv])[1])
    e = re.search(r"the empty part (\d+) to (\d+)", next(l for l in reversed(page[:dv])
        if "touch shell: the header: " in l))
    assert int(e[1]) < x0 < int(e[2]), f"the drag at {x0} not on the empty part {e[0]}"
    if H > W:
        assert float(m[1]) > 0.5, f"the world not taller: {m[0]}"
    else:
        assert float(m[2]) > 0.55, f"the UI half not wider: {m[0]}"
    print(f"ok: the header's views shown in turn ({lits}), Tools in each dump; {m[0]}")
if touch and gest:
    # Walk by finger: between the looks' marks no edit, the guide on E1 (the
    # last kit/button), the yaw turned from kit_face's 0 and back; after
    # them E1 selected by a tap and dragged; the stick walked; the touch bar
    # at the world's lower right
    def at(pat, start=0):
        return next((i for i in range(start, len(page)) if re.search(pat, page[i])), None)
    wl, wd = at(r"the mode: edit \(walk look\)"), at(r"the mode: edit \(walk looked\)")
    e1 = re.findall(r"An edit by webboss: placed kit/button (\d+) at", server)[-1]
    edits = [l for l in page[wl:wd] if re.search(r"kit editor: (moved|selected|placed|place |dig |"
        r"turning|moving|a box|linking)|the menu of", l)]
    assert not edits, f"the looks edited: {edits}"
    assert any(re.search(r"kit editor: guide: Tap: select .*\b" + e1 + r"\b", l) for l in page[wl:wd]), \
            f"the look's drag not begun on {e1} (no guide line of it)"
    yaws = [float(re.search(r"yaw ([\d.]+)", l)[1]) for l in page[wl:wd] if "kit: a look let go" in l]
    assert len(yaws) == 2 and min(yaws[0], 360 - yaws[0]) > 2 and abs(yaws[1] - yaws[0]) > 2, \
            f"the looks did not turn (from 0): {yaws}"
    sel = at(r"kit editor: selected \d+ \(", wd)
    assert re.search(r"selected " + e1 + r" \(", page[sel]), f"not {e1} selected by its tap: {page[sel]}"
    assert at(r"kit editor: moved 1 by", sel) and \
            re.search(r"An edit by webboss: moved " + e1 + r" to \[", server), \
            f"{e1} not dragged in Walk (server.log)"

    def xyz(pat):
        m = re.search(pat + r" (-?[\d.]+),(-?[\d.]+),(-?[\d.]+)", "\n".join(page[wd:]))
        assert m, f"no {pat}"
        return [float(v) for v in m.groups()]
    p0, p1 = xyz(r"kit: the stick down, the body at"), xyz(r"kit: the stick let go: the body at")
    walked = math.hypot(p1[0] - p0[0], p1[2] - p0[2])
    assert walked > 0.3, f"the stick walked {walked:.2f} m: {p0} to {p1}"
    bi = [i for i, l in enumerate(page) if "kit: the touch bar in the world at" in l]
    assert bi, "no touch bar in the world"
    b = [page[bi[-1]]]
    bx, by, bw, bh = map(int, re.search(r"at (\d+) (\d+) (\d+) (\d+)", b[-1]).groups())
    wr = rect(re.search(r"the world ([\d ]+), the UI", next(l for l in reversed(page[:bi[-1]])
        if "touch shell: pixels: " in l))[1])
    assert bx >= wr[0] and by >= wr[1] and bx + bw <= wr[0] + wr[2] + 1 and \
            by + bh <= wr[1] + wr[3] + 1 and bx + bw > wr[0] + wr[2] / 2, \
            f"the touch bar {b[-1]} not at the world's lower right {wr}"
    print(f"ok: Walk: {e1} tapped and dragged; the looks turned {yaws} with no edit; "
        f"the stick walked {walked:.2f} m; {b[-1].split('kit: ')[-1]}")
print(f"ok: {seen['targets']} target dumps, {seen['windows']} window dumps, the button placed; "
        f"the world {geo['world']}, the UI {geo['ui']}, the touch size {geo['touch']}")
PY
done
echo "PASS: Kit's touch mode ($runs): no UI fit, the targets at the touch size, the panes off the world, a palette tap and a world tap placed, the field above the keyboard; select, Select+, move, box, turn, raise, dig and place by finger and by mouse, the view moved with no edit; the field entry mode applying, cancelling and refusing in place, the position too; begun in 3D, the header's views' dropdown, Tools and divider, To the surface; Walk by finger (the stick, the looks, a selected entity moved); the desktop's layout unchanged ($t)"
