#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~6 min, four web drives (2026-11-11)
# covers: builtin/kit/client_lua/shell.lua builtin/kit/client_lua/field_entry.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua
# [KIT_PHONE_EDITING] stage 1, the touch mode's split screen: Workbench's
# web client in headless Chrome by finger (TOUCH=1), the editor's UI mode
# left to the device (kit_ui_mode=0, touch on a touchscreen), as a phone in
# portrait (412x915) and in landscape (915x412), and left-handed in
# landscape (kit_ui_mode=3). In each: edit mode by the play bar's Menu and
# the pause menu's Edit, the 2D view by the "..." menu's Tools pane, a
# kit/button tapped in the palette's pane and the world tapped:
#   - no "UI scale" line from edit mode on (a fixed scale, no fit);
#   - every target in the UI half (a button, field, dropdown, check box:
#     kit_touch_targets) at least the touch size (48 UI px) each way;
#   - the world's rect and the UI half's apart, and no pane's window
#     (kit_ui_where) over the world;
#   - the world tap placed the kit/button (the server's log);
#   - portrait: the inspector's "position x" tapped and a stand-in keyboard
#     up (buildatKeyboard.test, 42 % of the height): the UI half above it,
#     the world shorter by as much, the field above the keyboard.
# Stage 2, the field entry mode (field_entry.lua); the inspector scrolled to
# a field by the event kit_inspector_show:
#   - landscape (915x412): kit/button's hold (a number) typed with the
#     stand-in keyboard up: 99 refused in place, the mode kept, 2.5 applied
#     (the server's log); typed again and Cancelled (not sent); Next and
#     Prev through own_look (a yes/no list), sound_press (a choice list) and
#     back past hold to color_down; color (text) applied; sound_press picked
#     from its list, no keyboard; the inspector's + stepper and Apply; a
#     kit/door placed: mirror Yes applied; a size past the world refused by
#     the server, in place, and Cancelled; the field and the buttons above
#     the keyboard;
#   - portrait (412x915): the x/y/z row and Move inside the pane; a kit/npc
#     placed, its lines (long text) open the mode and are applied.
# And a mouse at 1600x900 (no TOUCH): the desktop's layout (the bar, the
# palette at the left, no shell), a click on the palette and one on the
# plan place the button.
#
#   util/kit_touch_mode_check.sh [p412x915 l915x412 lh915x412 d1600x900]
#
# Shots: <tmp>/<run>/*.png (KEEP_TMP=1 keeps them).
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ] ||
	skip "no Chrome or web/"
check_tmp kit_touch_mode; t=$CHECK_TMP
runs=${*:-p412x915 l915x412 lh915x412 d1600x900}
for r in $runs; do
	case $r in
		p412x915) w=412 h=915 mode=0 touch=1 ;;
		l915x412) w=915 h=412 mode=0 touch=1 ;;
		lh915x412) w=915 h=412 mode=3 touch=1 ;;
		d1600x900) w=1600 h=900 mode=0 touch=0 ;;
		*) fail "no run $r" ;;
	esac
	mkdir -p "$t/$r"
	python3 -I - "$t/$r/steps.json" "$w" "$h" "$mode" "$touch" <<'PY' || fail "steps of $r"
import json, re, sys
path, W, H, mode, touch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5] == "1"
S = []
def a(*s): S.append(list(s))
def fr(n=3): a("frames", n)
tap = "tap" if touch else "click"
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
# Walk to 2D by the Tools pane, the "..." menu's
a("tap", "Button", "shell more"); a("waitlog", "touch shell: the ... menu", 10); fr(5)
a("tap", "Button", "menu Tools"); a("waitlog", "touch shell: the tools pane", 10); fr(10)
a("tap", "DropDownList", "▼"); a("waitlog", "ui_utils: dropdown_[0-9]+ open", 10); fr(3)
a("tap", "Text", "2D"); a("waitlog", "kit editor: the view is 2D", 10); fr(10)
a("shot", "${OUT}/02_tools.png")
dump("tools")
a("tap", "Button", "shell more"); a("waitlog", "touch shell: the ... menu", 10); fr(5)
a("tap", "Button", "menu Palette"); a("waitlog", "touch shell: the palette pane", 10); fr(10)
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
a("tap", "Button", "Cancel"); fr(5)
if H > W:
    a("tap", "LineEdit", "position x"); fr(5)
    a("eval", "buildatKeyboard.test = %d, 'keyboard'" % int(H * 0.42))
    a("waitlog", "kit editor: typing in the inspector", 10)
    a("waitlog_any", r"touch shell: pixels: .*the keyboard [1-9]", 10); fr(10)
    a("shot", "${OUT}/05_keyboard.png")
    dump("keyboard")
    a("eval", "buildatKeyboard.test = null, 'no keyboard'"); fr(5)
# Stage 2: the field entry mode. Another entity placed from the palette's
# pane, beside the first
def place(t):
    a("tap", "Button", "shell more"); a("waitlog", "touch shell: the ... menu", 10); fr(5)
    a("tap", "Button", "menu Palette"); a("waitlog", "touch shell: the palette pane", 10); fr(10)
    a("tap", "Button", "palette filter clear"); fr(2)
    a("tap", "LineEdit", "palette filter"); fr(2); a("type", t); fr(5)
    a("tap", "Button", t); a("waitlog", "kit editor: placing " + t, 10); fr(10)
    a("tap", x, y + 60 if H > W else y - 60)
    a("waitlog", "touch shell: the inspector pane", 20); fr(10)
    a("tap", "Button", "Cancel"); fr(5)
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
    a("eval", "buildatKeyboard.test = null, 'no keyboard'"); fr(5)
json.dump(S, open(path, "w"), indent=0)
PY
	echo "kit_touch_mode: $r"
	if [ "$touch" = 1 ]; then export TOUCH=1; else unset TOUCH; fi
	WEB_DRIVE_VIEWPORT=${w}x$h@1 "$here/util/web_drive.sh" chrome workbench \
			"$t/$r/steps.json" "$t/$r" > "$t/$r/drive.log" 2>&1 ||
		fail "the drive $r: $t/$r/drive.log"
	python3 -I - "$t/$r" "$w" "$h" "$touch" <<'PY' || fail "$r: see above ($t/$r)"
import re, sys
d, W, H, touch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "1"
page = open(d + "/page.log", errors="replace").read().splitlines()
server = open(d + "/server.log", errors="replace").read()
assert re.search(r"An edit by webboss: placed kit/button \d+", server), \
    "the kit/button was not placed (server.log)"
on = next(i for i, l in enumerate(page) if "kit editor: edit mode on" in l)
if not touch:
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
if W > H and "lh" not in d:
    t = "\n".join(page)
    def sets(what): return re.search(r"An edit by webboss: set \d+'s " + what, server)
    for what in [r"kit/button hold to 2\.5", r'kit/button color to "#00ff00"',
            r'kit/button sound_press to ""', r"kit/button hold to 3\.5", r"kit/door mirror to true"]:
        assert sets(what), f"not applied: {what} (server.log)"
    for what in [r"kit/button hold to 7\b", r"kit/button hold to 99\b"]:
        assert not sets(what), f"applied: {what} (server.log)"
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
print(f"ok: {seen['targets']} target dumps, {seen['windows']} window dumps, the button placed; "
        f"the world {geo['world']}, the UI {geo['ui']}, the touch size {geo['touch']}")
PY
done
echo "PASS: Kit's touch mode ($runs): no UI fit, the targets at the touch size, the panes off the world, a palette tap and a world tap placed, the field above the keyboard, the field entry mode applying, cancelling and refusing in place; the desktop's layout unchanged ($t)"
