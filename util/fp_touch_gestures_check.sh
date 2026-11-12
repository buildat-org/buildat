#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~4 min, three web drives (2026-11-12)
# covers: apps/floorplanner/main/client_lua/shell.lua apps/floorplanner/main/client_lua/field_entry.lua apps/floorplanner/main/client_lua/editor.lua apps/floorplanner/main/client_lua/panel.lua
# [KIT_PHONE_EDITING] 4z11 stage 5b, floorplanner's touch mode's gestures,
# mouse and keyboard: its web client in headless Chrome, a plan made, Start
# editing, a room drawn in the world, then (each move of the view read by
# "event fp_view" before and after, or by the line the gesture ends with):
#   - p412x915, by finger (TOUCH=1): in 2D two fingers spread zoom in, one
#     dragged on nothing pans; in 3D two moved together orbit; a finger
#     begun in the UI half and dragged into the world moves nothing; Walk:
#     the stick at the world's lower left walks, a drag elsewhere turns; the
#     room selected, its Name tapped and a stand-in keyboard
#     (buildatKeyboard.test) shorter than the world, then one taller: the
#     field above it each time;
#   - l915x412, by finger: two fingers zoom; the room's Name tapped with the
#     keyboard up opens the field entry mode: "Hall" typed and Next (the
#     Ceiling, a number), its + stepper, Cancel; the Ceiling's "abc" refused
#     in place, then "2600" applied; a Name typed and cancelled; the server
#     has the two edits and no more;
#   - m1280x800, a mouse in the touch mode (fp_ui_mode=2): in 2D the wheel
#     zooms, a right drag pans, a middle drag zooms, a left drag on nothing
#     pans; in 3D a right drag orbits; a right drag begun in the UI half
#     moves nothing; in Walk the wheel does nothing.
#
#   util/fp_touch_gestures_check.sh [p412x915 l915x412 m1280x800]
#
# Shots: <tmp>/<run>/*.png (KEEP_TMP=1 keeps them).
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ] ||
	skip "no Chrome or web/"
check_tmp fp_touch_gestures; t=$CHECK_TMP
runs=${*:-p412x915 l915x412 m1280x800}
for r in $runs; do
	case $r in
		p412x915) w=412 h=915 mode=0 touch=1 ;;
		l915x412) w=915 h=412 mode=0 touch=1 ;;
		m1280x800) w=1280 h=800 mode=2 touch=0 ;;
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
# The world's rect as the layout puts it, the UI half beside it
if H > W: wx, wy, ww, wh = 0, 0, W, round(H * 0.45)
else: wx, wy, ww, wh = 0, 0, W - round(W * 0.5), H
def at(fx, fy): return [round(wx + fx * ww), round(wy + fy * wh)]
# (the status line's, in the UI half: no target there)
UI = [W // 2, H - 8] if H > W else [W - W // 4, H - 8]
def view(name):
    a("event", "fp_view " + name); a("waitlog", r"fp_view \(" + name + r"\)", 10)
def views(v, n_):
    a(tap, "Button", "shell view " + v)
    a("waitlog", r"fp shell: the header: .*, lit " + n_, 10); fr(10)
a("nav", "${URL}?pref=floorplanner_font=100&pref=fp_ui_mode=" + mode)
a("waitlog", "accounts: the login page shown", 120); a("wait", 1000)
for _ in range(3): a("key", "Tab"); fr(2)
a("key", "Enter"); a("wait", 1000)
a("selall"); fr(2); a("type", "webboss"); fr(2); a("key", "Tab"); fr(2)
a("type", "checkpass12"); fr(2); a("key", "Tab"); fr(2)
a("type", "checkpass12"); fr(2); a("key", "Tab"); fr(2)
a("type", "${SETUP_CODE}"); fr(2); a("key", "Tab"); fr(2)
a("key", "Enter"); a("waitlog", "Joined as webboss", 30); a("wait", 1000)
a("type", "gestplan"); a("key", "Enter")
a("waitlog", "Entered the plan gestplan", 30)
a("waitlog_any", "server window: the page ntfy", 30); fr(3)
a(tap, "Button", "Don't add"); fr(5)
a(tap, "Button", "Start editing")
a("waitlog", "fp shell on", 20); a("waitlog", "fp shell: pixels", 10); fr(10)
views("2d", "2D")
a(tap, "Button", "Room" if touch else "Room*"); a("waitlog", "fp shell: the props pane", 10); fr(10)
for p in [(0.3, 0.3), (0.7, 0.3), (0.7, 0.7), (0.3, 0.7), (0.3, 0.3)]:
    a(tap, *at(*p)); fr(5)
a("sync", 5000); fr(10)
a(tap, "Button", "shell more"); a("waitlog", r"fp shell: the \.\.\. menu", 10); fr(5)
a(tap, "Button", "menu Tools"); a("waitlog", "fp shell: the tools pane", 10); fr(10)
a(tap, "Button", "Select" if touch else "Select*"); fr(5)
a(tap, *at(0.1, 0.1)); fr(10)
a("shot", "${OUT}/01_room.png")
if touch:
    # 2D: two fingers spread, one on nothing dragged
    view("2d0")
    a("fingers", *at(0.4, 0.5), *at(0.6, 0.5), *at(0.2, 0.5), *at(0.8, 0.5))
    a("waitlog", "fp editor: two fingers let go: 2d", 10); fr(5)
    a("drag", *at(0.15, 0.15), *at(0.15, 0.4)); a("waitlog", "fp editor: the view dragged: 2d", 10); fr(5)
    # A finger from the UI half into the world: nothing
    view("ui0"); a("drag", *UI, *at(0.5, 0.2)); fr(10); view("ui1")
    # 3D: two moved together
    views("3d", "3D"); view("3d0")
    a("fingers", *at(0.4, 0.5), *at(0.6, 0.5), *at(0.6, 0.5), *at(0.8, 0.5))
    a("waitlog", "fp editor: two fingers let go: 3d", 10); fr(5)
    a("shot", "${OUT}/02_3d.png")
    # Walk: the stick, then a look
    views("walk", "Walk"); fr(10); view("w0")
    a("drag", *at(0.15, 0.85), *at(0.15, 0.65)); fr(5); view("w1")
    a("drag", *at(0.7, 0.3), *at(0.9, 0.3)); fr(5); view("w2")
    a("shot", "${OUT}/03_walk.png")
    views("2d", "2D")
    # The room selected (off its middle: its lamp), its Name typed in
    a(tap, *at(0.4, 0.6)); a("waitlog", r"fp shell: selected \d+ \(room\)", 10)
    a("waitlog", "fp shell: the props pane", 10); fr(10)
if touch and H > W:
    a(tap, "LineEdit", "room*"); fr(5)
    for k in [0.3, 0.6]:
        a("eval", "buildatKeyboard.test = %d, 'keyboard'" % int(H * k))
        a("waitlog", r"fp shell: pixels: .*the keyboard [1-9]", 10)
        a("waitlog", "fp shell: typing: the field", 10); fr(10)
        a("event", "fp_view kb%d" % int(k * 10)); a("waitlog", r"fp_view \(kb", 10)
        a("shot", "${OUT}/04_keyboard_%d.png" % int(k * 10))
    a("eval", "buildatKeyboard.test = null, 'no keyboard'"); fr(5)
elif touch:
    kb = "buildatKeyboard.test = %d, 'keyboard'" % int(H * 0.42)
    def entry(label, kind):
        a("waitlog", r"fp editor: field entry: %s \(%s\)" % (label, kind), 10)
        a("waitlog", "fp editor: field entry: laid out", 10); fr(5)
    a(tap, "LineEdit", "room*"); fr(3); a("eval", kb); entry("Name", "text")
    a("shot", "${OUT}/04_entry_name.png")
    a("selall"); fr(2); a("type", "Hall"); fr(2)
    a(tap, "Button", "entry next"); entry("Ceiling mm", "number")
    a(tap, "Button", "entry +"); a("waitlog", "field entry: stepped Ceiling mm to 10$", 10)
    a("shot", "${OUT}/05_entry_ceiling.png")
    a(tap, "Button", "entry cancel"); a("waitlog", r"field entry: closed, cancelled \(Ceiling mm\)", 10)
    a("sync", 5000); fr(10)
    a(tap, "LineEdit", "Hall"); fr(3); entry("Name", "text")
    a(tap, "Button", "entry next"); entry("Ceiling mm", "number")
    a("selall"); fr(2); a("type", "abc"); fr(2)
    a(tap, "Button", "entry apply"); a("waitlog", "field entry: refused in place: Ceiling mm: a number", 10)
    a("shot", "${OUT}/06_entry_refused.png")
    a("selall"); fr(2); a("type", "2600"); fr(2)
    a(tap, "Button", "entry apply"); a("waitlog", r"field entry: closed, applied \(Ceiling mm\)", 10)
    a("sync", 5000); fr(10)
    a(tap, "LineEdit", "Hall"); fr(3); entry("Name", "text")
    a("selall"); fr(2); a("type", "Nope"); fr(2)
    a(tap, "Button", "entry cancel"); a("waitlog", r"field entry: closed, cancelled \(Name\)", 10)
    a("eval", "buildatKeyboard.test = null, 'no keyboard'"); a("sync", 5000); fr(10)
    a("shot", "${OUT}/07_entry_done.png")
if not touch:
    # 2D: the wheel, a right drag, a middle drag, a left drag on nothing
    a("mouse", *at(0.5, 0.5)); a("wheel", *at(0.5, 0.5), -300)
    a("waitlog", "fp editor: the wheel: 2d", 10); fr(5)
    a("rdrag", *at(0.5, 0.5), *at(0.6, 0.6)); a("waitlog", "fp editor: the right drag let go: 2d", 10); fr(5)
    a("mouse_drag", "middle", 4, *at(0.5, 0.5), *at(0.5, 0.3))
    a("waitlog", "fp editor: the middle let go: 2d", 10); fr(5)
    a("ldrag", *at(0.15, 0.15), *at(0.15, 0.4)); a("waitlog", "fp editor: the view dragged: 2d", 10); fr(5)
    # 3D: a right drag orbits; one from the UI half moves nothing
    views("3d", "3D")
    a("rdrag", *at(0.5, 0.5), *at(0.7, 0.5)); a("waitlog", "fp editor: the right drag let go: 3d", 10); fr(5)
    view("ui0"); a("rdrag", *UI, *at(0.5, 0.5)); fr(10); view("ui1")
    a("shot", "${OUT}/02_3d.png")
    # Walk: no wheel
    views("walk", "Walk")
    a("mouse", *at(0.5, 0.5)); a("wheel", *at(0.5, 0.5), -300)
    a("waitlog", "fp editor: the wheel: not in Walk", 10); fr(5)
json.dump(S, open(path, "w"), indent=0)
PY
	echo "fp_touch_gestures: $r"
	if [ "$touch" = 1 ]; then export TOUCH=1; else unset TOUCH; fi
	WEB_DRIVE_VIEWPORT=${w}x$h@1 "$here/util/web_drive.sh" chrome floorplanner \
			"$t/$r/steps.json" "$t/$r" > "$t/$r/drive.log" 2>&1 ||
		fail "the drive $r: $t/$r/drive.log"
	python3 -I - "$t/$r" "$w" "$h" "$touch" <<'PY' || fail "$r: see above ($t/$r)"
import re, sys
d, W, H, touch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] == "1"
page = open(d + "/page.log", errors="replace").read().splitlines()
server = open(d + "/server.log", errors="replace").read().splitlines()
def first(pat):
    return next(re.search(pat, l) for l in page if re.search(pat, l))
def fv(name):
    return first(r"fp_view \(" + name + r"\): (.*)")[1]
def plan(s):
    m = re.search(r"2d: the plan at (-?\d+), (-?\d+), (\d+) mm across", s)
    return int(m[1]), int(m[2]), int(m[3])
def cam(s):
    m = re.search(r"the camera at (-?[\d.]+), (-?[\d.]+), (-?[\d.]+) m, yaw (-?[\d.]+), pitch (-?[\d.]+)", s)
    return [float(x) for x in m.groups()]
ok = []
if touch:
    z0, z1 = plan(fv("2d0")), plan(first(r"two fingers let go: (2d.*)")[1])
    assert z1[2] < z0[2] * 0.8, f"two fingers spread did not zoom in: {z0} {z1}"
    p1 = plan(first(r"the view dragged: (2d.*)")[1])
    assert abs(p1[1] - z1[1]) > 100, f"one finger on nothing did not pan: {z1} {p1}"
    assert fv("ui0") == fv("ui1"), f"a finger from the UI half moved the world: {fv('ui0')} / {fv('ui1')}"
    c0, c1 = cam(fv("3d0")), cam(first(r"two fingers let go: (3d.*)")[1])
    assert abs(c1[3] - c0[3]) > 2, f"two fingers in 3D did not orbit: {c0} {c1}"
    w0, w1, w2 = cam(fv("w0")), cam(fv("w1")), cam(fv("w2"))
    assert abs(w1[0] - w0[0]) + abs(w1[2] - w0[2]) > 0.1, f"the stick did not walk: {w0} {w1}"
    assert abs(w2[3] - w1[3]) > 2, f"a drag in Walk did not turn: {w1} {w2}"
    ok.append("pinch, pan, orbit, the UI half's finger nothing, the stick and a look")
if touch and H > W:
    for k in ["kb3", "kb6"]:
        i = next(i for i, l in enumerate(page) if "fp_view (" + k + ")" in l)
        ty = [l for l in page[:i] if "fp shell: typing: the field" in l][-1]
        m = re.search(r"the field (\d+) to (\d+), the keyboard from (\d+)", ty)
        f0, f1, kb = map(int, m.groups())
        assert f0 >= 0 and f1 <= kb, f"{k}: the field {f0}-{f1} under the keyboard from {kb}"
        px = [l for l in page[:i] if "fp shell: pixels" in l][-1]
        g = re.search(r"the world (\d+) (\d+) (\d+) (\d+), the UI (\d+) (\d+) (\d+) (\d+)", px)
        world, ui = list(map(int, g.groups()[:4])), list(map(int, g.groups()[4:]))
        assert ui[1] + ui[3] <= kb + 2, f"{k}: the UI half {ui} under the keyboard from {kb}"
        if k == "kb3":
            assert ui[3] == H - round(H * 0.45), f"{k}: the UI half resized: {ui}"
        ok.append(f"{k}: the field {f0}-{f1} above the keyboard from {kb}, the world {world}, the UI {ui}")
elif touch:
    for l in page:
        m = re.search(r"field entry: laid out (\d+)x(\d+), the field (\d+) to (\d+), the buttons (\d+) to (\d+), the keyboard (\d+)", l)
        if m:
            top = int(m[2]) - int(m[7])
            assert int(m[4]) <= top and int(m[6]) <= top, f"under the keyboard: {l}"
    z0, z1 = plan(fv("2d0")), plan(first(r"two fingers let go: (2d.*)")[1])
    assert z1[2] < z0[2] * 0.8, f"two fingers spread did not zoom in: {z0} {z1}"
    made = next(i for i, l in enumerate(server) if re.search(r"An edit by webboss: \d+ ops, made: .*\broom\b", l))
    edits = [l for l in server[made + 1:] if "An edit by webboss" in l]
    assert len(edits) == 2, f"not the two edits (Name by Next, the Ceiling by Apply): {edits}"
    assert not any("refused" in l for l in server[made:]), "a batch refused"
    ok.append("the entry's Next and Apply at the server, Cancel and the refusal not")
else:
    wl = first(r"the wheel: (2d.*)")[1]
    rd = first(r"the right drag let go: (2d.*)")[1]
    md = first(r"the middle let go: (2d.*)")[1]
    ld = first(r"the view dragged: (2d.*)")[1]
    assert plan(rd)[:2] != plan(wl)[:2], f"the right drag did not pan: {wl} / {rd}"
    assert plan(md)[2] < plan(rd)[2] * 0.9, f"the middle drag up did not zoom in: {rd} / {md}"
    assert plan(ld)[:2] != plan(md)[:2], f"the left drag did not pan: {md} / {ld}"
    o = first(r"the right drag let go: (3d.*)")[1]
    assert fv("ui0") == fv("ui1"), f"a right drag from the UI half moved the world: {fv('ui0')} / {fv('ui1')}"
    assert any("the wheel: not in Walk" in l for l in page), "no wheel line in Walk"
    ok.append(f"the wheel, right, middle and left drags in 2D, the orbit ({o}), the UI half's drag nothing, no wheel in Walk")
print("ok: " + "; ".join(ok))
PY
done
echo "PASS: floorplanner's touch mode's gestures, mouse and keyboard ($runs) ($t)"
