#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~6 min, two web drives (2026-11-11)
# covers: builtin/kit/client_lua/shell.lua builtin/kit/client_lua/signals.lua builtin/kit/client_lua/field_entry.lua builtin/kit/client_lua/editor.lua extensions/launch_menu/preferences.lua
# [KIT_PHONE_EDITING] stage 4, the touch mode's panes: Workbench's web
# client in headless Chrome by finger (TOUCH=1) as a phone in portrait
# (412x915) and in landscape (915x412), in the plan (kit_plan 0 0 16 8):
#   - "..." lists Server (Workbench's accounts' Server window);
#   - each pane opened from "..." (the Log, Builders, Tools, the Signals
#     view's entities and links, the HUD view's, Scenes) and the dialogs
#     (Make prefab, New scene, New voxel type): every target in the UI half
#     at least the touch size, no window but the Signals view's viewport
#     (and the "..." menu) over the world;
#   - a kit/door and a kit/button placed: the portrait inspector's body no
#     wider than its view;
#   - the button made a prefab (its menu by a finger held), the prefab
#     placed and turned by Turn + (the pane's height as with no turning);
#   - the Signals view: the button's links, Add link by its steps (an
#     output, the door, its input: the server's log); landscape: the Name
#     typed in the field entry mode and applied;
#   - a new scene (the server's log), and New voxel type typed in with the
#     stand-in keyboard up (buildatKeyboard.test): its field and Make above
#     the keyboard, made (the server's log);
#   - the game settings: Fullscreen (kit_fullscreen) listed, off (the drive
#     pins it), never turned on.
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
kb = "buildatKeyboard.test = %d, 'keyboard'" % int(H * 0.42)
nokb = "buildatKeyboard.test = null, 'no keyboard'"
def dump(name):
    fr(3)
    a("event", "kit_touch_targets " + name); a("event", "kit_ui_where " + name)
    a("waitlog", r"the windows at .*\(" + name + r"\)", 10)
def more(entry, wait):
    a("tap", "Button", "shell more"); a("waitlog", "touch shell: the ... menu", 10); fr(5)
    a("tap", "Button", "menu " + entry); a("waitlog", wait, 10); fr(10)
def plan():
    a("event", "kit_plan 0 0 16 8"); a("waitlog", "kit editor: the view is 2D", 10); fr(5)
def place(t, x, y):
    more("Palette", "touch shell: the palette pane")
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
# "..." with Server
a("tap", "Button", "shell more"); a("waitlog", "touch shell: the ... menu", 10); fr(5)
a("shot", "${OUT}/01_more.png")
dump("more")
# Tools (the palette's pane is up already)
a("tap", "Button", "menu Tools"); a("waitlog", "touch shell: the tools pane", 10); fr(10)
a("shot", "${OUT}/05_tools.png"); dump("tools")
# A door and a button; the inspector
place("kit/door", *D)
a("tap", "Button", "Cancel"); fr(5)
place("kit/button", *B)
a("shot", "${OUT}/02_inspector.png")
dump("inspector")
a("tap", "Button", "Cancel"); fr(5)
# The Log, Builders, Tools
more("Log", "touch shell: the log pane"); a("shot", "${OUT}/03_log.png"); dump("log")
more("Builders", "touch shell: the people pane"); a("shot", "${OUT}/04_builders.png"); dump("people")
# The button a prefab: its menu by a finger held, Make prefab...
a("hold", *B, 800); a("waitlog", "kit editor: the menu of", 10); fr(5)
a("tap", "Button", "menu Make prefab..."); a("waitlog", "touch shell: the dialog pane", 10); fr(10)
a("tap", "LineEdit", "prefab name"); fr(2); a("selall"); fr(2); a("type", "pf1"); fr(3)
a("shot", "${OUT}/06_prefab_dialog.png")
dump("prefab_dialog")
a("tap", "Button", "Save prefab"); a("waitlog", "touch shell: back to the", 10); a("sync", 5000); fr(5)
# The prefab placed, turned on the way
more("Palette", "touch shell: the palette pane")
a("tap", "Button", "palette filter clear"); fr(2)
a("tap", "LineEdit", "palette filter"); fr(2); a("type", "pf1"); fr(5)
a("tap", "Button", "[*"); a("waitlog", "the palette.s menu of", 10); fr(5)
a("tap", "Button", "menu Place"); a("waitlog", "kit editor: placing", 10); fr(10)
a("shot", "${OUT}/07_turning.png")
dump("turning")
a("tap", "Button", "shell turn +"); a("waitlog", "kit editor: placing turned 90", 10); fr(3)
a("tap", "Button", "shell cancel"); a("waitlog", "kit editor: placing nothing", 10); fr(5)
# The Signals view: the button's links, a link added by the steps
# (selected still: no new pane)
a("tap", *B); fr(10)
more("Signals view", "touch shell: the sg_links pane"); fr(10)
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
more("Signals: entities", "touch shell: the sg_list pane"); fr(5)
a("shot", "${OUT}/12_signals_list.png")
dump("sg_list")
more("World view", "kit editor: the view is 2D")
# The HUD view's pane
more("HUD view", "touch shell: the hud pane")
a("shot", "${OUT}/13_hud.png")
dump("hud")
more("World view", "kit editor: the view is ")
plan()
# Scenes: New scene...
more("Scenes", "touch shell: the scenes pane")
a("shot", "${OUT}/14_scenes.png")
dump("scenes")
a("tap", "Button", "scenes new"); a("waitlog", "touch shell: the dialog pane", 10); fr(10)
a("tap", "LineEdit", "scene name"); fr(2); a("selall"); fr(2); a("type", "second"); fr(2)
a("eval", kb); a("waitlog", "touch shell: typing in the dialog", 10); fr(10)
a("shot", "${OUT}/15_scene_dialog_keyboard.png")
dump("scene_dialog")
a("eval", nokb); fr(5)
a("tap", "Button", "Make scene"); a("waitlog", "kit editor: a new scene second", 10)
a("sync", 5000); fr(10)
# New voxel type, typed with the keyboard up
more("Palette", "touch shell: the palette pane")
a("tap", "Button", "Voxels*"); a("waitlog", "kit editor: tool voxels", 10); fr(5)
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
# The game settings: Fullscreen there, off
more("Menu", "pause: the menu shown")
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
PANE = {"inspector": "inspector", "people": "people", "tools": "bar",
    "prefab_dialog": "dialog", "sg_links": "sg_links", "sg_step": "sg_links",
    "sg_list": "sg_list", "scenes": "scenes", "scene_dialog": "dialog",
    "voxel_dialog": "dialog"}
geo, seen = None, {}
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
        wins = dict(re.findall(r"(\w+) (-?\d+ -?\d+ \d+ \d+)", m[1]))
        seen[m[2]] = wins
        for k, r in wins.items():
            # (the Signals view's viewport is the world's; the menus pop up)
            if k not in ("sg_view", "ctx"):
                assert not overlap(rect(r), geo["world"]), \
                    f"the {k} window {r} over the world {geo['world']} ({m[2]})"
        want = PANE.get(m[2])
        assert not want or want in wins, f"no {want} window in the {m[2]} pane: {m[1]}"
missing = set(PANE) | {"more", "log", "hud", "turning", "settings"}
missing -= set(seen)
assert not missing, f"no dumps of {missing}"
assert "sg_view" in seen["sg_links"], f"no Signals viewport: {seen['sg_links']}"
# "..." with Server
m = re.search(r"touch shell: the \.\.\. menu, \d+ in \d+ columns?: (.*)", text)
assert m and "Server" in m[1].split(", "), f"no Server in the ... menu: {m and m[0]}"
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
# Fullscreen: in the settings, never on
m = re.search(r"Game settings shown: (.*)", text)
assert m and "kit_fullscreen" in m[1], f"no Fullscreen in the settings: {m and m[1]}"
assert "kit editor: fullscreen off" in text and "kit editor: fullscreen on" not in text, \
    "Kit's fullscreen not off"
print(f"ok: {len(seen)} dumps ({', '.join(sorted(seen))}), every target the touch size and off "
    f"the world; Server in ...; the inspector's body {b[-1][0]} in {b[-1][1]}; a prefab turned "
    f"while placed; a link by the steps; a scene and a voxel type made, the dialogs' field and "
    f"buttons above the keyboard ({len(typing)}); Fullscreen listed and off")
PY
done
echo "PASS: Kit's touch mode's panes ($runs): the Log, Builders, Tools, Signals, HUD, Scenes and the dialogs as panes at the touch size off the world; a link by steps; a prefab turned while placed; a scene and a voxel type made with the keyboard up; Server in ...; Fullscreen listed and off ($t)"
