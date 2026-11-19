#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~5 min, two web drives (2026-11-19)
# covers: builtin/kit/client_lua/controls.lua builtin/kit/client_lua/ui.lua apps/workbench/main/client_lua/init.lua apps/workbench/templates/brimstone_speedway/types/brim_car.lua apps/workbench/templates/crag_trial/types/crag_bike.lua util/web_drive.js
# [KIT_TOUCH_THUMBS] Kit's touch buttons in play, as the phone test of
# 2026-11-19 asked: Workbench's web client in headless Chrome by finger
# (TOUCH=1) as a phone, portrait 412x915 turned to landscape:
#   - Brimstone Speedway, its time trial: the stack at the lower right
#     vertical, its side 15 to 18 mm (thumb(): 160 CSS px an inch), Gas
#     lowest, Brake over it; the car's touch_axes (Left, Right) a stack at
#     the lower left; in landscape the side still at least 15 mm;
#   - a press is its finger's: Gas held, the finger slid off it, still held;
#     lifted there, released; Gas and Right held by two fingers: the car
#     driven and turned 20 degrees or more, Right lifted: steering only let go;
#   - two fingers spread: the top-down camera nearer (pinched); kept: the
#     same zoom in a second trial after Stop and Play, and after a rejoin
#     (the page loaded again);
#   - Crag Trial, The Crags: the bike's lean stack (Lean left, Lean right),
#     Lean right held: r 1.
# Shots: $t/brim/{portrait,landscape}.png, $t/crag/{portrait,landscape}.png
# (KEEP_TMP=1 keeps them)
#   util/kit_touch_thumbs_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ] ||
	skip "no Chrome or web/"
check_tmp kit_touch_thumbs; t=$CHECK_TMP
python3 -I - "$t" <<'PY' || fail "the steps"
import json, sys
t = sys.argv[1]
W, H = 412, 915
def login(new):
    S = [["nav", "${URL}"], ["waitlog", "accounts: the login page shown", 120], ["wait", 1000]]
    if new:
        S += [["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
              ["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000]]
    S += [["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
          ["type", "checkpass12"], ["frames", 2]]
    if new:
        S += [["key", "Tab"], ["frames", 2], ["type", "checkpass12"], ["frames", 2], ["key", "Tab"],
              ["frames", 2], ["type", "${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2]]
    S += [["key", "Enter"], ["waitlog", "Joined as webboss", 30]]
    if new:
        S += [["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
              ["tap", "Button", "Don't add"], ["frames", 3]]
    return S
def new_game(name):
    return [["waitlog_any", "world_menu: the list shown, 0 worlds", 30], ["frames", 3],
            ["tap", "Button", "New game..."],
            ["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
            ["tap", "DropDownList", "▼"], ["waitlog", "dropdown_[0-9]+ open", 10], ["frames", 3],
            ["tap", "Text", name], ["waitlog", "world_menu: template picked", 10],
            ["frames", 3], ["tap", "Button", "Create"],
            ["waitlog", "kit editor: edit mode on", 120], ["frames", 5],
            ["key", "F6"], ["waitlog", "kit: ui full screen [0-9]+ up", 20], ["frames", 10]]
def mark(name):
    return [["eval", "console.log('CHECK: %s'), 'mark'" % name], ["event", "kit_body"],
            ["waitlog", "kit: zoom ", 10]]
def trial():
    return [["waitlog_any", "kit: the touch Menu over the full screen shown", 20],
            ["tap", "Button", "Time trial: The*"], ["waitlog", "GO!", 20], ["frames", 5]]
# ---- Brimstone
B = login(True) + new_game("Brimstone Speedway") + trial()
B += [["waitlog_any", "kit: the touch stacks of [0-9]+x9[0-9][0-9]:", 10], ["shot", "${OUT}/portrait.png"]]
# (Gas's and Brake's places: down and up again, before GO's car goes)
B += [["tap", "Button", "Brake"], ["frames", 3], ["tap", "Button", "Gas"], ["frames", 3]]
# Slid off and lifted
off = [W // 2, H // 3]
B += [["touch", "find", [["Button", "Gas", 0], ["Button", "Right", 0]]],
      ["touch", "touchStart", [["Button", "Gas", 1]]], ["frames", 10],
      ["touch", "touchMove", [off + [1]]], ["frames", 10]] + mark("slid off")
B += [["touch", "touchEnd", [off + [1]]], ["frames", 10]] + mark("lifted")
# Two fingers: Gas and Right, then Right lifted
B += mark("before") + [["touch", "touchStart", [["Button", "Gas", 1]]], ["frames", 3],
      ["touch", "touchStart", [["Button", "Gas", 1], ["Button", "Right", 2]]], ["wait", 1500]]
B += mark("both")
B += [["touch", "touchEnd", [["Button", "Right", 2]]], ["frames", 10]] + mark("right lifted")
B += [["touch", "touchEnd", []], ["frames", 10]]
# The pinch, spread
y = H * 0.3
B += [["fingers", 150, y, 262, y, 110, y, 302, y], ["waitlog", "kit: pinched the zoom to", 10],
      ["waitlog", "kit: the zoom [0-9.]+ kept for top_down", 10]] + mark("pinched")
# A second trial: Stop and Play
B += [["event", "kit_edit {\"op\": \"mode\", \"on\": true}"], ["waitlog", "kit editor: edit mode on", 10],
      ["event", "kit_edit {\"op\": \"stop\"}"], ["waitlog", "kit editor: the server is Ended", 10],
      ["event", "kit_edit {\"op\": \"play\"}"], ["waitlog", "kit editor: the server is Running", 10],
      ["event", "kit_edit {\"op\": \"mode\", \"on\": false}"], ["waitlog", "kit editor: edit mode off", 10],
      ["waitlog", "kit: ui full screen [0-9]+ up", 20], ["frames", 5]] + trial() + mark("second")
# A rejoin
B += login(False) + [["waitlog", "kit: ui full screen [0-9]+ up", 60], ["frames", 5]] + trial() + mark("rejoined")
B += [["turn", "landscape"], ["frames", 10], ["wait", 1000],
      ["waitlog_any", "kit: the touch stacks of 9[0-9][0-9]x[0-9]+:", 10], ["frames", 5],
      ["shot", "${OUT}/landscape.png"], ["eval", "console.log('CHECK: done'), 'mark'"]]
json.dump(B, open(t + "/brim.json", "w"), indent=0)
# ---- Crag Trial
C = login(True) + new_game("Crag Trial")
C += [["tap", "Button", "The Crags*"], ["waitlog", "player physics enabled", 20],
      ["waitlog_any", "kit: the touch stacks of [0-9]+x9[0-9][0-9]:", 10], ["frames", 10],
      ["shot", "${OUT}/portrait.png"],
      ["touch", "touchStart", [["Button", "Lean right", 1]]], ["frames", 10]] + mark("lean")
C += [["touch", "touchEnd", []], ["frames", 5],
      ["turn", "landscape"], ["frames", 10], ["wait", 1000],
      ["waitlog_any", "kit: the touch stacks of 9[0-9][0-9]x[0-9]+:", 10], ["frames", 5],
      ["shot", "${OUT}/landscape.png"], ["eval", "console.log('CHECK: done'), 'mark'"]]
json.dump(C, open(t + "/crag.json", "w"), indent=0)
PY
for g in brim crag; do
	TOUCH=1 WEB_DRIVE_VIEWPORT=412x915@1 "$here/util/web_drive.sh" chrome workbench \
		"$t/$g.json" "$t/$g" > "$t/$g.txt" 2>&1 ||
		fail "the web drive $g ($(tail -2 "$t/$g.txt"), $t/$g)"
done
python3 -I - "$t" <<'PY' || fail "see above ($t/brim, $t/crag)"
import re, sys
t = sys.argv[1]
def lines(g):
    return open(f"{t}/{g}/page.log", errors="replace").read().splitlines()
def stacks(L, size):
    m = [re.search(r"kit: the touch stacks of (%s): side (\d+) \(\d+ CSS px, ([\d.]+) mm\); "
                   r"right (-?\d+) (-?\d+) (\d+) (\d+); world's .*; left (-?\d+) (-?\d+) (\d+) (\d+)" % size, l)
         for l in L]
    m = [x for x in m if x]
    assert m, f"no touch stacks of {size}"
    return m[-1]
def check_stacks(L, size, n_left):
    m = stacks(L, size)
    size = m[1]
    W, H = map(int, size.split("x"))
    side, mm = int(m[2]), float(m[3])
    rx, ry, rw, rh, lx, ly, lw, lh = map(int, m.groups()[3:])
    assert 15 <= mm <= 18, f"{size}: the side {mm} mm: {m[0]}"
    assert W - 20 <= rx + rw <= W and H - 20 <= ry + rh <= H, f"{size}: not at the lower right: {m[0]}"
    assert rh > rw and rw < side + 20, f"{size}: not a column: {m[0]}"
    if n_left:
        assert lx <= 20 and H - 20 <= ly + lh <= H and lh > lw, f"{size}: no stack at the lower left: {m[0]}"
    print(f"ok: {size}: side {side} px, {mm} mm, right {rx},{ry} {rw}x{rh}, left {lx},{ly} {lw}x{lh}")
def after(L, name):
    i = next(i for i, l in enumerate(L) if "CHECK: " + name in l)
    m = next(re.search(r"kit: zoom ([\d.]+) \((\S+)\), input f (\S+) r (\S+), yaw (\S+)", l) for l in L[i:]
             if "kit: zoom " in l)
    return float(m[1]), m[2], float(m[3]), float(m[4]), float(m[5])
L = lines("brim")
check_stacks(L, r"\d+x9\d\d", 2)
check_stacks(L, r"9\d\dx\d+", 2)
ys = {}
for l in L:
    m = re.search(r"kit: touch button (Gas|Brake) up by finger \d+ at \d+,(\d+)", l)
    if m and m[1] not in ys:
        ys[m[1]] = int(m[2])
assert ys.get("Gas", 0) > ys.get("Brake", 1e9), f"Gas not under Brake: {ys}"
s, l_, b, both, rl = (after(L, n) for n in ("slid off", "lifted", "before", "both", "right lifted"))
assert s[2] == 1, f"Gas let go as the finger slid off: {s}"
assert l_[2] == 0, f"Gas still held after the finger lifted off it: {l_}"
assert both[2] == 1 and both[3] == 1, f"Gas and Right not both held: {both}"
turn = min(abs(both[4] - b[4]) % 360, 360 - abs(both[4] - b[4]) % 360)
assert turn >= 20, f"the car not turned by Right: {b} -> {both}"
assert rl[2] == 1 and rl[3] == 0, f"Right lifted let go of the wrong one: {rl}"
print(f"ok: Gas held slid off, let go lifted; Gas and Right by two fingers turned the car {turn:.0f} degrees; Right lifted: Gas still held")
p, sec, rj = after(L, "pinched"), after(L, "second"), after(L, "rejoined")
assert p[0] < 0.9, f"not pinched nearer: {p}"
assert abs(sec[0] - p[0]) < 0.01 and sec[1] == p[1], f"the zoom not kept into the second trial: {p} -> {sec}"
assert abs(rj[0] - p[0]) < 0.01, f"the zoom not kept across the rejoin: {p} -> {rj}"
print(f"ok: pinched to {p[0]} ({p[1]}), {sec[0]} in the second trial, {rj[0]} rejoined")
L = lines("crag")
check_stacks(L, r"\d+x9\d\d", 2)
check_stacks(L, r"9\d\dx\d+", 2)
assert any("; the left: Lean left, Lean right" in l for l in L), "no lean stack"
le = after(L, "lean")
assert le[3] == 1, f"Lean right not r 1: {le}"
print("ok: Crag Trial's lean stack, Lean right held: r 1")
PY
for p in brim/portrait brim/landscape crag/portrait crag/landscape; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
echo "PASS: Kit's touch stacks as a phone: thumb-sized columns at the lower right and left in portrait and landscape, presses by finger (held slid off, let go lifted, two fingers two buttons), Brimstone's car steered by its stack, the pinch zoom kept into a second trial and across a rejoin ($t)"
