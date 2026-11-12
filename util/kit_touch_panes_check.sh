#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~6 min, two web drives (2026-11-12)
# covers: builtin/kit/client_lua/shell.lua builtin/kit/client_lua/signals.lua builtin/kit/client_lua/field_entry.lua builtin/kit/client_lua/editor.lua extensions/launch_menu/preferences.lua src/client/web/index.html
# [KIT_PHONE_EDITING] stage 4, the touch mode's panes: Workbench's web
# client in headless Chrome by finger (TOUCH=1) as a phone in portrait
# (412x915) and in landscape (915x412), in the plan (kit_plan 0 0 16 8),
# as the phone test of 2026-11-12 left the header ("< <title>", the views'
# dropdown and Tools; no "..."):
#   - Tools in each target dump, "..." in none; Tools' first rows Server
#     (Workbench's accounts' Server window) and Menu;
#   - the palette's list at least 8 rows high in portrait, 5 in landscape
#     (its tabs one dropdown, the filter beside it);
#   - each pane reached without "...": Tools and Back, the palette by Back,
#     the inspector by a placing or a selection, the Signals view by the
#     views' dropdown on its entities, an entity's links by its inspector's
#     Links, the HUD view's, New scene... from the dropdown, and the dialogs
#     (Make prefab, New scene, New voxel type): every target in the UI half
#     at least the touch size, no window but the Signals view's viewport
#     (and a menu) over the world;
#   - a menu (a finger held) shown whole on the screen;
#   - a kit/door and a kit/button placed: the portrait inspector's body no
#     wider than its view;
#   - the button made a prefab (its menu by a finger held), the prefab
#     placed and turned by Turn + (the pane's height as with no turning);
#   - the Signals view: the button's links, Add link by its steps (an
#     output, the door, its input: the server's log); landscape: the Name
#     typed in the field entry mode and applied;
#   - a new scene (the server's log), and New voxel type typed in with the
#     stand-in keyboard up (buildatKeyboard.test): its field and Make above
#     the keyboard, made (the server's log); the keyboard gone with the
#     scene's name focused: the field let go, and a tap focuses it again
#     (the page's stand-in); portrait: the inspector's position typed in,
#     a drag begun on its pane's button keeps the field's focus;
#   - the game settings by Tools' Menu: Fullscreen (kit_fullscreen) listed,
#     off (the drive pins it), never turned on.
#
#   util/kit_touch_panes_check.sh [p412x915 l915x412]
#
# Shots: <tmp>/<run>/*.png (KEEP_TMP=1 keeps them).
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ] ||
	skip "no Chrome or web/"
check_tmp kit_touch_panes; t=$CHECK_TMP
runs=${*:-p412x915 l915x412}
for r in $runs; do
	case $r in
		p412x915) w=412 h=915 ;;
		l915x412) w=915 h=412 ;;
		*) fail "no run $r" ;;
	esac
	mkdir -p "$t/$r"
	python3 -I - "$t/$r/steps.json" "$w" "$h" <<'PY' || fail "steps of $r"
import json, sys
path, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
S = []
def a(*s): S.append(list(s))
def fr(n=3): a("frames", n)
# The plan's cells on the screen (kit_touch_mode_check.sh's gestures())
if H > W: wx, wy, ww, wh = 0, 0, W, round(H * 0.45)
else: wx, wy, ww, wh = 0, 0, W - round(W * 0.5), H
cx, cy, c = wx + ww / 2, wy + wh / 2, wh / 16
def at(x, z): return [round(cx + x * c), round(cy - z * c)]
D, B = at(-3, 0), at(3, 0)
# (the button: a new world's second entity placed)
BUTTON = 4
kb = "buildatKeyboard.test = %d, 'keyboard'" % int(H * 0.42)
nokb = "buildatKeyboard.test = null, 'no keyboard'"
def dump(name):
    fr(3)
    a("event", "kit_touch_targets " + name); a("event", "kit_ui_where " + name)
    a("waitlog", r"the windows at .*\(" + name + r"\)", 10)
def view(label, wait):
    # The header's dropdown: its list, a pick
    a("tap", "DropDownList", "shell views"); a("waitlog", "shell views open", 10); fr(3)
    a("tap", "Text", "shell views: " + label + "*"); a("waitlog", wait, 10); fr(10)
def back(to):
    a("tap", "Button", "shell back"); a("waitlog", "touch shell: back to the " + to + " pane", 10); fr(10)
def plan():
    a("event", "kit_plan 0 0 16 8"); a("waitlog", "kit editor: the view is 2D", 10); fr(5)
def place(t, x, y):
    # (from the palette's pane: the one placed selected, the inspector up)
    a("tap", "Button", "palette filter clear"); fr(2)
    a("tap", "LineEdit", "palette filter"); fr(2); a("type", t); fr(5)
    a("tap", "Button", t); a("waitlog", "kit editor: placing " + t, 10); fr(5)
    a("tap", x, y); a("waitlog", "touch shell: the inspector pane", 20); fr(10)
a("nav", "${URL}?pref=kit_editor_font=100&pref=kit_ui_mode=0")
a("waitlog", "accounts: the login page shown", 120); a("wait", 1000)
for _ in range(3): a("key", "Tab"); fr(2)
a("key", "Enter"); a("wait", 1000)
a("selall"); fr(2); a("type", "webboss"); fr(2); a("key", "Tab"); fr(2)
a("type", "checkpass12"); fr(2); a("key", "Tab"); fr(2)
a("type", "checkpass12"); fr(2); a("key", "Tab"); fr(2)
a("type", "${SETUP_CODE}"); fr(2); a("key", "Tab"); fr(2)
a("key", "Enter"); a("waitlog", "Joined as webboss", 30)
a("waitlog_any", "server window: the page ntfy", 30); fr(3)
a("tap", "Button", "Don't add"); fr(3)
a("waitlog_any", "world_menu: the list shown, 0 worlds", 30); fr(3)
a("tap", "Button", "New project...")
a("waitlog", "world_menu: the name screen shown", 10); fr(3)
a("tap", "Button", "Create")
a("waitlog", "player physics enabled", 120)
a("waitlog_any", "kit editor: edit rights: yes", 10); fr(5)
a("tap", "Button", "Menu", W, H); a("waitlog", "pause: the menu shown", 10); fr(3)
a("tap", "Button", "Edit*")
a("waitlog", "kit editor: touch shell on", 20)
a("waitlog", "kit editor: touch shell: pixels", 10); fr(10)
plan()
a("shot", "${OUT}/01_palette.png")
dump("palette")
# Tools: Server and Menu first; Back to the palette
a("tap", "Button", "shell tools"); a("waitlog", "touch shell: the tools pane", 10); fr(10)
a("shot", "${OUT}/05_tools.png"); dump("tools")
back("palette")
# A door and a button; the inspector
place("kit/door", *D)
if H > W:
    # Its position typed in, a drag begun on a button of the pane (the
    # door's: the button's sheet then starts at its head, Links)
    a("event", "kit_inspector_show position x"); a("waitlog", "the inspector shows position x", 10); fr(5)
    a("tap", "LineEdit", "position x"); fr(3)
    a("eval", kb); a("waitlog", r"touch shell: pixels: .*the keyboard [1-9]", 10); fr(10)
    a("drag", "Button", "position move", W // 2, int(H * 0.3), "touch"); fr(10)
    a("shot", "${OUT}/02b_dragged.png"); dump("dragged")
    a("eval", nokb); a("waitlog", "touch shell: the keyboard closed: the field let go", 10); fr(10)
back("palette")
place("kit/button", *B)
a("shot", "${OUT}/02_inspector.png")
dump("inspector")
# The button a prefab: its menu by a finger held, Make prefab...
a("hold", *B, 800); a("waitlog", "kit editor: the menu of", 10)
a("waitlog", "touch shell: a menu shown at", 10); fr(5)
a("tap", "Button", "menu Make prefab..."); a("waitlog", "touch shell: the dialog pane", 10); fr(10)
a("tap", "LineEdit", "prefab name"); fr(2); a("selall"); fr(2); a("type", "pf1"); fr(3)
a("shot", "${OUT}/06_prefab_dialog.png")
dump("prefab_dialog")
a("tap", "Button", "Save prefab"); a("waitlog", "touch shell: back to the inspector", 10); a("sync", 5000); fr(5)
# The prefab placed, turned on the way
back("palette")
a("tap", "Button", "palette filter clear"); fr(2)
a("tap", "LineEdit", "palette filter"); fr(2); a("type", "pf1"); fr(5)
a("tap", "Button", "[*"); a("waitlog", "the palette.s menu of", 10); fr(5)
a("tap", "Button", "menu Place"); a("waitlog", "kit editor: placing", 10); fr(10)
a("shot", "${OUT}/07_turning.png")
dump("turning")
a("tap", "Button", "shell turn +"); a("waitlog", "kit editor: placing turned 90", 10); fr(3)
a("tap", "Button", "shell cancel"); a("waitlog", "kit editor: placing nothing", 10); fr(5)
# The Signals view by the dropdown, on its entities; the button's
# inspector by its row, its links by the inspector's Links
view("Signals", "touch shell: the sg_list pane")
a("shot", "${OUT}/12_signals_list.png")
dump("sg_list")
a("tap", "Button", "select %d" % BUTTON); a("waitlog", "touch shell: the inspector pane", 10); fr(10)
a("tap", "Button", "inspector links"); a("waitlog", "touch shell: the sg_links pane", 10); fr(10)
a("shot", "${OUT}/08_signals_links.png")
dump("sg_links")
# (a landscape pane is short: Add link below its foot, scrolled to by a finger)
px = round(W * 0.75)
def scroll(y0, y1):
    if W > H: a("drag", px, round(H * y0), px, round(H * y1), "touch"); fr(10)
scroll(0.7, 0.17)
a("tap", "Button", "add link"); a("waitlog", "kit editor: signals: add link open", 10); fr(5)
a("tap", "Button", "link output 0 pressed"); a("waitlog", "add link: output 0 pressed", 10); fr(5)
a("shot", "${OUT}/09_signals_step_target.png")
dump("sg_step")
a("tap", "Button", "link target door*"); a("waitlog", "add link: target", 10); fr(5)
a("tap", "Button", "link input open"); a("waitlog", "kit editor: signals: linked", 10)
a("sync", 5000); fr(10)
a("shot", "${OUT}/10_signals_linked.png")
scroll(0.17, 0.75)
if W > H:
    a("tap", "LineEdit", "signals name"); fr(3); a("eval", kb)
    a("waitlog", r"field entry: signals name name \(text\)", 10)
    a("waitlog", "field entry: laid out", 10); fr(5)
    a("selall"); fr(2); a("type", "Lever"); fr(2)
    a("shot", "${OUT}/11_signals_name_entry.png")
    a("tap", "Button", "entry apply"); a("waitlog", "field entry: closed, applied", 10)
    a("eval", nokb); fr(5)
# The HUD view's pane, then out by the dropdown
view("HUD", "touch shell: the hud pane")
a("shot", "${OUT}/13_hud.png")
dump("hud")
view("2D", "kit editor: the view is 2D")
plan()
# New scene... from the dropdown; the keyboard gone with its field focused
view("New scene...", "touch shell: the dialog pane")
a("tap", "LineEdit", "scene name"); fr(2); a("selall"); fr(2); a("type", "second"); fr(2)
a("eval", kb); a("waitlog", "touch shell: typing in the dialog", 10); fr(10)
a("shot", "${OUT}/15_scene_dialog_keyboard.png")
dump("scene_dialog")
a("eval", nokb); a("waitlog", "touch shell: the keyboard closed: the field let go", 10); fr(5)
a("tap", "LineEdit", "scene name"); a("waitlog", "buildatText: a field focused in the tap: text", 10); fr(5)
a("tap", "Button", "Make scene"); a("waitlog", "kit editor: a new scene second", 10)
a("sync", 5000); fr(10)
# New voxel type, typed with the keyboard up (Voxels by the palette's
# tabs' dropdown)
back("palette")
a("tap", "DropDownList", "palette tabs"); a("waitlog", "palette tabs open", 10); fr(3)
a("tap", "Text", "palette tabs: Voxels"); a("waitlog", "kit editor: tool voxels", 10); fr(5)
# (below the view in landscape: its rows at the touch size)
a("event", "kit_inspector_show voxel new"); a("waitlog", "the inspector shows voxel new", 10); fr(5)
a("tap", "Button", "New voxel type..."); a("waitlog", "touch shell: the dialog pane", 10); fr(10)
a("tap", "LineEdit", "my_voxel"); fr(2); a("selall"); fr(2); a("type", "v1"); fr(2)
a("eval", kb); a("waitlog", "touch shell: typing in the dialog", 10); fr(10)
a("shot", "${OUT}/16_voxel_dialog_keyboard.png")
dump("voxel_dialog")
a("tap", "Button", "Make"); a("waitlog", "touch shell: back to the", 10)
a("eval", nokb); a("sync", 5000); fr(5)
a("tap", "Button", "shell cancel"); fr(5)
# The game settings: Tools' Menu; Fullscreen there, off
a("tap", "Button", "shell tools"); a("waitlog", "touch shell: the tools pane", 10); fr(10)
a("tap", "Button", "Menu"); a("waitlog", "pause: the menu shown", 10); fr(5)
a("tap", "Button", "Settings..."); a("waitlog", "Game settings shown", 10); fr(5)
a("shot", "${OUT}/17_settings.png")
dump("settings")
json.dump(S, open(path, "w"), indent=0)
PY
	echo "kit_touch_panes: $r"
	export TOUCH=1
	WEB_DRIVE_VIEWPORT=${w}x$h@1 "$here/util/web_drive.sh" chrome workbench \
			"$t/$r/steps.json" "$t/$r" > "$t/$r/drive.log" 2>&1 ||
		fail "the drive $r: $t/$r/drive.log"
	python3 -I - "$t/$r" "$w" "$h" <<'PY' || fail "$r: see above ($t/$r)"
import re, sys
d, W, H = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
page = open(d + "/page.log", errors="replace").read().splitlines()
server = open(d + "/server.log", errors="replace").read()
text = "\n".join(page)
on = next(i for i, l in enumerate(page) if "kit editor: edit mode on" in l)
def rect(s): return list(map(int, s.split()))
def overlap(a, b):
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]
# Each pane's window in its dump
PANE = {"palette": "palette", "inspector": "inspector", "tools": "bar",
    "prefab_dialog": "dialog", "sg_links": "sg_links", "sg_step": "sg_links",
    "sg_list": "sg_list", "scene_dialog": "dialog", "voxel_dialog": "dialog"}
geo, seen, rows = None, {}, None
for l in page[on:]:
    m = re.search(r"touch shell: pixels: the world ([\d ]+), the UI ([\d ]+), "
            r"the pane ([\d ]+), the keyboard (\d+), the touch size (\d+)", l)
    if m:
        geo = {"world": rect(m[1]), "ui": rect(m[2]), "pane": rect(m[3]),
            "kb": int(m[4]), "touch": int(m[5])}
        assert not overlap(geo["world"], geo["ui"]), f"the world and the UI half overlap: {l}"
        continue
    m = re.search(r"touch targets \((\w+)\): (.*)", l)
    if m and geo and m[1] != "settings":
        ur, T, small = geo["ui"], geo["touch"], []
        ts = re.findall(r'(\w+) "([^"]*)" (-?\d+ -?\d+ \d+ \d+)', m[2])
        for t in ts:
            x, y, w, h = rect(t[2])
            cx, cy = x + w / 2, y + h / 2
            if ur[0] <= cx < ur[0] + ur[2] and ur[1] <= cy < ur[1] + ur[3] and \
                    (w < T - 1 or h < T - 1):
                small.append(f"{t[0]} \"{t[1]}\" {w}x{h}")
        assert not small, f"under the touch size {T} ({m[1]}): {small}"
        # The header: Tools, no "..."
        labels = {t[1] for t in ts if t[0] == "Button"}
        assert "Tools" in labels and "..." not in labels, f"the header in {m[1]}: {sorted(labels)}"
        if m[1] == "palette":
            # The list's rows shown whole in the pane (sections, types)
            p = geo["pane"]
            rows = {rect(t[2])[1] for t in ts if t[0] == "Button" and
                re.match(r"(kit/|[-+] )", t[1]) and rect(t[2])[1] >= p[1] and
                rect(t[2])[1] + rect(t[2])[3] <= p[1] + p[3]}
        continue
    m = re.search(r"the windows at (.*) \((\w+)\)", l)
    if m and geo:
        wins = dict(re.findall(r"(\w+) (-?\d+ -?\d+ \d+ \d+)", m[1]))
        seen[m[2]] = wins
        for k, r in wins.items():
            # (the Signals view's viewport is the world's; the menus pop up)
            if k not in ("sg_view", "ctx"):
                assert not overlap(rect(r), geo["world"]), \
                    f"the {k} window {r} over the world {geo['world']} ({m[2]})"
        want = PANE.get(m[2])
        assert not want or want in wins, f"no {want} window in the {m[2]} pane: {m[1]}"
missing = set(PANE) | {"hud", "turning", "settings"}
missing -= set(seen)
assert not missing, f"no dumps of {missing}"
assert "sg_view" in seen["sg_links"], f"no Signals viewport: {seen['sg_links']}"
# The palette's list: a phone's pane shows more than its tabs (the phone
# test of 2026-11-12: two rows of it under them)
least = 8 if H > W else 5
assert rows and len(rows) >= least, f"the palette's list {len(rows or ())} rows, not {least}"
# Tools: Server and Menu first
ti = next(i for i, l in enumerate(page) if "touch targets (tools)" in l)
bar = next(l for l in reversed(page[:ti]) if "kit editor: bar: " in l)
names = [s.rsplit(" ", 1)[0] for s in bar.split("kit editor: bar: ")[1].split("; ")]
assert names[:2] == ["Server", "Menu"], f"not Server and Menu first in Tools: {names}"
# A menu shown whole on the screen
menus = re.findall(r"touch shell: a menu shown at (\d+) (\d+) (\d+) (\d+)", text)
assert menus, "no menu shown"
for x, y, w, h in (map(int, m) for m in menus):
    assert x + w <= W + 1 and y + h <= H + 1, f"a menu off the screen: {x} {y} {w} {h}"
# The inspector's body in its view
b = re.findall(r"the inspector's body (\d+) wide in its view's (\d+)", text)
assert b and all(int(x) <= int(v) for x, v in b), f"the inspector's body wider than its view: {b}"
# The prefab, turned while placed; the pane no shorter for it
assert re.search(r"An edit by webboss: saved prefab webboss/pf1", server), "no prefab saved (server.log)"
panes = []
for l in page:
    m = re.search(r"touch shell: pixels: .*the pane ([\d ]+),", l)
    if m: panes.append(rect(m[1]))
    if "placing turned 90" in l: break
else:
    raise AssertionError("not turned while placing")
assert len(panes) >= 2 and panes[-1][3] == panes[-2][3], f"the pane changed with Turn: {panes[-2:]}"
# The link, by the steps
assert re.search(r"An edit by webboss: linked \d+\.pressed -> \d+\.open", server), \
    "no link added (server.log)"
if W > H:
    assert re.search(r'kit editor: signals: renamed \d+ to "Lever"', text), "the Name not applied"
# A new scene; a voxel type typed with the keyboard up
assert re.search(r"An edit by webboss: made the scene second", server), "no scene made (server.log)"
assert re.search(r"webboss made voxel type webboss/v1", server), "no voxel type made (server.log)"
# (each dialog's last: the view is fitted and scrolled over a few frames)
typing = list(dict(re.findall(r"typing in the dialog ([^:]*): the field (\d+ to \d+, its buttons \d+ "
    r"to \d+, the keyboard from \d+)", text)).values())
typing = [re.findall(r"\d+", t) for t in typing]
assert len(typing) >= 2, f"no typing in the dialogs: {typing}"
for f0, f1, b0, b1, k in typing:
    assert int(f1) <= int(k) and int(b1) <= int(k), f"under the keyboard from {k}: the field {f0}-{f1}, the buttons {b0}-{b1}"
# The keyboard gone with a field focused: let go, focused again by a tap
# (the phone test of 2026-11-12: the keyboard came back no more)
k = text.rfind("touch shell: the keyboard closed: the field let go")
assert k >= 0 and "buildatText: a field focused in the tap: text" in text[k:], \
    "the field not let go as the keyboard closed, or not focused again by a tap"
# A drag begun on a pane's button: the field typed in kept the focus, the
# keyboard's room with it (the user's phone of 2026-11-12: the UI went back
# under the keyboard)
if H > W:
    d = next(i for i, l in enumerate(page) if "touch targets (dragged)" in l)
    px = next(l for l in reversed(page[:d]) if "touch shell: pixels:" in l)
    assert not re.search(r"the keyboard 0,", px), f"the focus gone with a drag: {px}"
# Fullscreen: in the settings, never on
m = re.search(r"Game settings shown: (.*)", text)
assert m and "kit_fullscreen" in m[1], f"no Fullscreen in the settings: {m and m[1]}"
assert "kit editor: fullscreen off" in text and "kit editor: fullscreen on" not in text, \
    "Kit's fullscreen not off"
print(f"ok: {len(seen)} dumps ({', '.join(sorted(seen))}), every target the touch size and off "
    f"the world, Tools in each; the palette's list {len(rows)} rows; {', '.join(names[:2])} first "
    f"in Tools; {len(menus)} menus on the screen; the inspector's body {b[-1][0]} in {b[-1][1]}; a "
    f"prefab turned while placed; a link by the steps; a scene and a voxel type made, the dialogs' "
    f"field and buttons above the keyboard ({len(typing)}), the field let go as it closed and "
    f"focused again{'; a field kept through a drag' if H > W else ''}; Fullscreen listed and off")
PY
done
echo "PASS: Kit's touch mode's panes ($runs): Tools, the palette, the inspector, Signals and its links, HUD and the dialogs reached without \"...\", at the touch size off the world; the palette's list rows; Server and Menu first in Tools; a menu on the screen; a link by steps; a prefab turned while placed; a scene and a voxel type made with the keyboard up, the field let go as it closed; in portrait a field kept through a drag on a button; Fullscreen listed and off ($t)"
