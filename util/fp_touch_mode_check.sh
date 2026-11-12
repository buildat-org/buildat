#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~4 min, four web drives (2026-11-12)
# covers: apps/floorplanner/main/client_lua/shell.lua apps/floorplanner/main/client_lua/editor.lua apps/floorplanner/main/client_lua/panel.lua apps/floorplanner/main/client_lua/pick.lua
# [KIT_PHONE_EDITING] 4z11 stage 5a, floorplanner's touch mode's split
# screen: its web client in headless Chrome by finger (TOUCH=1), the
# editor's UI mode left to the device (fp_ui_mode=0, touch on a
# touchscreen), as a phone in portrait (412x915) and in landscape
# (915x412), and left-handed in landscape (fp_ui_mode=3). In each: a plan
# made, Start editing, the header's 3D and 2D, the Room tool from the Tools
# pane and a room drawn by five taps in the world, then Select from Tools
# and a tap in the room:
#   - no UI fit from edit mode on (a fixed scale; an earlier fit undone);
#   - the world's rect and the UI half's apart and on the screen (the
#     pixels line), the world where the layout puts it;
#   - the header: 2D | 3D | Walk, lit as tapped;
#   - every target (a button, field, dropdown, check box: fp_touch_targets)
#     off the world's rect, and those in the UI half at least the touch
#     size (48 UI px) each way; no pane's window over the world;
#   - the room made (the server's log), and the tap in it selected it and
#     showed the Properties pane.
# And a mouse at 1600x900 (no TOUCH, the same fp_ui_mode=0): the desktop's
# layout (no shell, the toolbar at the top left with Menu (Esc)), a room
# drawn by clicks.
#
#   util/fp_touch_mode_check.sh [p412x915 l915x412 lh915x412 d1600x900]
#
# Shots: <tmp>/<run>/*.png (KEEP_TMP=1 keeps them).
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ] ||
	skip "no Chrome or web/"
check_tmp fp_touch_mode; t=$CHECK_TMP
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
import json, sys
path, W, H, mode, touch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5] == "1"
S = []
def a(*s): S.append(list(s))
def fr(n=3): a("frames", n)
tap = "tap" if touch else "click"
def dump(name):
    fr(5)
    a("event", "fp_touch_targets " + name)
    a("waitlog", r"fp shell: the windows at .*\(" + name + r"\)", 10)
# The world's rect as the layout puts it (fractions of the screen)
if not touch: wx, wy, ww, wh = 0, 0, W, H
elif H > W: wx, wy, ww, wh = 0, 0, W, round(H * 0.45)
elif mode == "3": wx, wy, ww, wh = round(W * 0.5), 0, W - round(W * 0.5), H
else: wx, wy, ww, wh = 0, 0, W - round(W * 0.5), H
def at(fx, fy): return [round(wx + fx * ww), round(wy + fy * wh)]
a("nav", "${URL}?pref=floorplanner_font=100&pref=fp_ui_mode=" + mode)
a("waitlog", "accounts: the login page shown", 120); a("wait", 1000)
for _ in range(3): a("key", "Tab"); fr(2)
a("key", "Enter"); a("wait", 1000)
a("selall"); fr(2); a("type", "webboss"); fr(2); a("key", "Tab"); fr(2)
a("type", "checkpass12"); fr(2); a("key", "Tab"); fr(2)
a("type", "checkpass12"); fr(2); a("key", "Tab"); fr(2)
a("type", "${SETUP_CODE}"); fr(2); a("key", "Tab"); fr(2)
a("key", "Enter"); a("waitlog", "Joined as webboss", 30); a("wait", 1000)
a("type", "phoneplan"); a("key", "Enter")
a("waitlog", "Entered the plan phoneplan", 30)
a("waitlog_any", "server window: the page ntfy", 30); fr(3)
a(tap, "Button", "Don't add"); fr(5)
a(tap, "Button", "Start editing")
if touch:
    a("waitlog", "fp shell on", 20)
    a("waitlog", "fp shell: pixels", 10); fr(10)
    a("shot", "${OUT}/01_edit.png")
    dump("edit")
    # The header's views lit as tapped
    for v, n in [("3d", "3D"), ("2d", "2D")]:
        a(tap, "Button", "shell view " + v)
        a("waitlog", r"fp shell: the header: .*, lit " + n, 10); fr(5)
    a("shot", "${OUT}/02_header.png")
    dump("tools")
    # The Room tool (its settings the Properties pane), a room by five taps
    a(tap, "Button", "Room"); a("waitlog", "fp shell: the props pane", 10); fr(10)
    dump("room_tool")
else:
    fr(10); a("shot", "${OUT}/01_desktop.png")
    dump("desktop")
    a(tap, "Button", "Room*"); fr(5)
for p in [(0.3, 0.3), (0.7, 0.3), (0.7, 0.7), (0.3, 0.7), (0.3, 0.3)]:
    a(tap, *at(*p)); fr(5)
a("sync", 5000); fr(10)
a("shot", "${OUT}/03_room.png")
if touch:
    # Select from Tools, a tap in the room: Properties
    a(tap, "Button", "shell more"); a("waitlog", r"fp shell: the \.\.\. menu", 10); fr(5)
    a(tap, "Button", "menu Tools"); a("waitlog", "fp shell: the tools pane", 10); fr(10)
    a(tap, "Button", "Select"); fr(5)
    # (the room made is selected: let go of it on nothing first)
    a(tap, *at(0.1, 0.1)); fr(10)
    a("event", "fp_touch_targets mark"); a("waitlog", r"\(mark\)", 10)
    # (off its middle, where its ceiling lamp is)
    a(tap, *at(0.4, 0.6)); a("waitlog", r"fp shell: selected \d+ \(room\)", 10)
    a("waitlog", "fp shell: the props pane", 10); fr(10)
    a("shot", "${OUT}/04_selected.png")
    dump("selected")
json.dump(S, open(path, "w"), indent=0)
PY
	echo "fp_touch_mode: $r"
	if [ "$touch" = 1 ]; then export TOUCH=1; else unset TOUCH; fi
	WEB_DRIVE_VIEWPORT=${w}x$h@1 "$here/util/web_drive.sh" chrome floorplanner \
			"$t/$r/steps.json" "$t/$r" > "$t/$r/drive.log" 2>&1 ||
		fail "the drive $r: $t/$r/drive.log"
	python3 -I - "$t/$r" "$w" "$h" "$touch" "$mode" <<'PY' || fail "$r: see above ($t/$r)"
import re, sys
d, W, H, touch, mode = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "1", sys.argv[5]
page = open(d + "/page.log", errors="replace").read().splitlines()
server = open(d + "/server.log", errors="replace").read()
assert re.search(r"An edit by webboss: \d+ ops, made: .*\broom\b", server), \
    "no room made (server.log)"
def rect(s): return list(map(int, s.split()))
def overlap(a, b):
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]
if not touch:
    assert not any("fp shell" in l and "fp shell: touch targets" not in l and
        "fp shell: the windows at" not in l for l in page), "a touch shell on a desktop"
    w = next(l for l in page if "(desktop)" in l and "the windows at" in l)
    tb = re.search(r"tools (\d+) (\d+) (\d+) (\d+)", w)
    assert tb and int(tb[1]) < 20 and int(tb[2]) < 20, f"the toolbar not at the top left: {w}"
    tg = next(l for l in page if "touch targets (desktop)" in l)
    assert 'Button "Menu (Esc)"' in tg, f"no Menu (Esc) on the desktop's toolbar"
    print(f"ok: the desktop's layout (the toolbar at {tb[0]}, Menu (Esc)), a room made")
    sys.exit(0)
on = next(i for i, l in enumerate(page) if "fp shell on" in l)
# (a fit made before, by the pause menu's window, is undone as the shell
# comes on: x1, the plain scale, once)
fits = [l for l in page[on:] if "UI scale fitted" in l and not l.endswith(": x1")]
scales = set(re.findall(r"UI scale ([\d.]+) \(", "\n".join(page[on:])))
assert not fits and len(scales) <= 1, f"the UI scale changed in edit mode: {fits} {scales}"
geo, seen = None, {"targets": 0, "windows": 0}
for l in page[on:]:
    m = re.search(r"fp shell: pixels: the world ([\d ]+), the UI ([\d ]+), "
            r"the pane ([\d ]+), the keyboard (\d+), the touch size (\d+)", l)
    if m:
        geo = {"world": rect(m[1]), "ui": rect(m[2]), "pane": rect(m[3]), "touch": int(m[5])}
        wr, ur = geo["world"], geo["ui"]
        assert not overlap(wr, ur), f"the world {wr} and the UI half {ur} overlap"
        assert ur[0] >= 0 and ur[0] + ur[2] <= W + 1 and ur[1] >= 0 and ur[1] + ur[3] <= H + 1, \
            f"the UI half {ur} off the screen"
        if H > W: assert wr[1] == 0 and abs(wr[3] - H * 0.45) < 3, f"the world {wr} not on top"
        elif mode == "3": assert wr[0] > W * 0.4, f"the world {wr} not at the right (LH)"
        else: assert wr[0] == 0 and abs(wr[2] - W * 0.5) < 3, f"the world {wr} not at the left"
        continue
    m = re.search(r"fp shell: touch targets \((\w+)\): (.*)", l)
    if m and geo and m[1] != "mark":
        seen["targets"] += 1
        wr, ur, T, small, over = geo["world"], geo["ui"], geo["touch"], [], []
        for k in re.findall(r'(\w+) "([^"]*)" (-?\d+ -?\d+ \d+ \d+)', m[2]):
            x, y, w, h = rect(k[2])
            if w == 0 or h == 0:
                continue
            if overlap([x, y, w, h], wr):
                over.append(f"{k[0]} \"{k[1]}\" {k[2]}")
            cx, cy = x + w / 2, y + h / 2
            if ur[0] <= cx < ur[0] + ur[2] and ur[1] <= cy < ur[1] + ur[3] and \
                    (w < T - 1 or h < T - 1):
                small.append(f"{k[0]} \"{k[1]}\" {w}x{h}")
        assert not small, f"under the touch size {T} ({m[1]}): {small}"
        assert not over, f"targets over the world {wr} ({m[1]}): {over}"
        continue
    m = re.search(r"fp shell: the windows at (.*) \((\w+)\)", l)
    if m and geo and m[2] != "mark":
        seen["windows"] += 1
        for k, r in re.findall(r"(\w+) (-?\d+ -?\d+ \d+ \d+)", m[1]):
            assert not overlap(rect(r), geo["world"]), \
                f"the {k} window {r} over the world {geo['world']} ({m[2]})"
assert seen["targets"] >= 4 and seen["windows"] >= 4, f"too few dumps: {seen}"
hd = [l for l in page if "fp shell: the header: " in l]
assert hd and all("2D | 3D | Walk" in l for l in hd), f"the header's views: {hd[:2]}"
lits = " ".join(re.search(r", lit (\w+)$", l)[1] for l in hd)
assert re.search(r"2D( \S+)* 3D( \S+)* 2D", lits), f"lit in turn: {lits}"
for l in page:
    m = re.search(r"fp shell: touch targets \((\w+)\): (.*)", l)
    if m:
        got = set(re.findall(r'Button "(2D|3D|Walk|\.\.\.)"', m[2]))
        assert got == {"2D", "3D", "Walk", "..."}, f"the header's buttons in {m[1]}: {got}"
mk = next(i for i, l in enumerate(page) if "touch targets (mark)" in l)
sel = next((i for i in range(mk, len(page)) if re.search(r"fp shell: selected \d+ \(room\)", page[i])), None)
assert sel is not None, "the room not selected by the tap"
assert any("fp shell: the props pane" in l for l in page[sel:]), "no Properties pane after the selection"
print(f"ok: {seen['targets']} target dumps, {seen['windows']} window dumps; the world {geo['world']}, "
    f"the UI {geo['ui']}, the touch size {geo['touch']}; the header lit {lits}; a room made by taps, "
    f"selected by one, Properties shown")
PY
done
echo "PASS: floorplanner's touch mode ($runs): no UI fit, the world and the UI half apart, the header's views, the targets at the touch size and off the world, a room drawn by finger and selected into Properties; the desktop's layout unchanged ($t)"
