#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~60 s (2026-11-15)
# covers: builtin/kit/client_lua/ui.lua apps/workbench/templates/crag_trial/composition.json
# [KIT_LAYOUT_AUTO] Crag Trial's lobby on a phone: Workbench's web client in
# headless Chrome at 412x915 by finger (TOUCH=1), webboss (the admin) New
# from Crag Trial, F6:
#   - the lobby's chat and view (54, an auto panel at the bottom) a column:
#     the view the panel's width, the chat under it (lobby.png);
#   - the chat field tapped, a stand-in keyboard (buildatKeyboard.test) of
#     380: the group 54 lifted, the field above the keyboard (keyboard.png);
#     Enter: back down with the keyboard still up (the field's blur);
#     tapped again, the keyboard gone: back down (down.png); the UI scale
#     and the root's size (the lines' "in WxH") the same all along;
#   - turned to landscape: a row across the screen, the chat at its left
#     end and the view at its right, as before the panel (landscape.png).
#   util/kit_lobby_web_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ] ||
	skip "no Chrome or web/"
check_tmp kit_lobby_web; t=$CHECK_TMP
cat > "$t/phone.json" <<'J'
[
	["nav", "${URL}"],
	["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
	["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
	["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Enter"], ["waitlog", "Joined as webboss", 30],
	["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
	["tap", "Button", "Don't add"], ["frames", 3],
	["waitlog_any", "world_menu: the list shown, 0 worlds", 30], ["frames", 3],
	["tap", "Button", "New project..."],
	["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
	["tap", "DropDownList", "▼"], ["waitlog", "dropdown_[0-9]+ open", 10], ["frames", 3],
	["tap", "Text", "Crag Trial"], ["waitlog", "world_menu: template picked: crag_trial", 10],
	["frames", 3], ["tap", "Button", "Create"],
	["waitlog", "kit editor: edit mode on", 120], ["frames", 5],
	["key", "F6"], ["waitlog", "kit: ui full screen 45 up", 20], ["frames", 10],
	["wait", 1000], ["shot", "${OUT}/lobby.png"],
	["eval", "console.log('CHECK: focus'), 'mark'"],
	["tap", "LineEdit", "kit chat 46"], ["frames", 5],
	["eval", "buildatKeyboard.test = 380, 'keyboard'"],
	["waitlog", "kit: ui lifted for the keyboard: 54 by", 10],
	["type", "hello"], ["frames", 5], ["shot", "${OUT}/keyboard.png"],
	["key", "Enter"], ["waitlog", "kit: ui chat 46 said \\(5 bytes\\)", 10],
	["waitlog", "kit: ui lifted for the keyboard: none", 10], ["frames", 5],
	["tap", "LineEdit", "kit chat 46"],
	["waitlog", "kit: ui lifted for the keyboard: 54 by", 10], ["frames", 5],
	["eval", "buildatKeyboard.test = null, 'no keyboard'"],
	["waitlog", "kit: ui lifted for the keyboard: none", 10], ["frames", 5],
	["shot", "${OUT}/down.png"],
	["key", "Enter"], ["frames", 5], ["wait", 1000],
	["eval", "console.log('CHECK: blurred'), 'mark'"],
	["turn", "landscape"], ["frames", 10], ["wait", 1000],
	["shot", "${OUT}/landscape.png"],
	["eval", "console.log('CHECK: end'), 'mark'"]
]
J
TOUCH=1 WEB_DRIVE_VIEWPORT=412x915@1 "$here/util/web_drive.sh" chrome workbench "$t/phone.json" "$t/phone" ||
	fail "the web drive as a phone ($t/phone)"
python3 -I - "$t/phone/page.log" <<'PY' || fail "see above ($t/phone/*.png, $t/phone/page.log)"
import re, sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
def at(s):
    return next(i for i, l in enumerate(lines) if s in l)
f, b, e = at("CHECK: focus"), at("CHECK: blurred"), at("CHECK: end")
def where(part):
    w = {}
    for l in part:
        m = re.search(r"kit: ui (46|48) \w+ at (-?\d+),(-?\d+) (\d+)x(\d+) in (\d+)x(\d+) font \d+ \S+ order \S+ shown", l)
        if m:
            w[m[1]] = tuple(map(int, m.groups()[1:]))
    return w
p = where(lines[:f])
c, v = p.get("46"), p.get("48")
assert c and v and c[5] > c[4], f"no lobby in portrait: {p}"
assert c[2] == v[2] and c[1] >= v[1] + v[3] and c[1] + c[3] > c[5] * 0.9, f"not a column at the bottom: chat {c} view {v}"
# The UI fit and the root's size held from the tap to the blur
sc = [l for l in lines[f:b] if re.search(r"UI scale ", l)]
assert not sc, f"the UI scale changed with the keyboard: {sc}"
roots = {m[1] for l in lines[f:b] for m in [re.search(r"kit: ui \d+ \w+ at .* in (\d+x\d+) ", l)] if m}
assert roots <= {f"{c[4]}x{c[5]}"}, f"the root's size changed with the keyboard: {roots}"
lift = [re.search(r"lifted for the keyboard: 54 by (\d+), the field 46 at (-?\d+) to (-?\d+) over the keyboard at (\d+)", l)
        for l in lines[f:b]]
lift = [m for m in lift if m]
assert len(lift) >= 2, "not lifted twice"
for m in lift:
    dy, y0, y1, kb = map(int, m.groups())
    assert dy > 0 and 0 <= y0 and y1 <= kb, f"the field {y0}-{y1} not above the keyboard at {kb} ({m[0]})"
downs = [i for i in range(f, b) if "lifted for the keyboard: none" in lines[i]]
assert len(downs) >= 2, "not back down twice"
l = where(lines[b:e])
c2, v2 = l.get("46"), l.get("48")
assert c2 and v2 and c2[4] > c2[5] and c2[0] + c2[2] <= v2[0], f"not a row in landscape: chat {c2} view {v2}"
assert c2[0] < 0.05 * c2[4] and v2[0] + v2[2] > 0.95 * c2[4], f"the row not spread to the ends: chat {c2} view {v2}"
print(f"ok: portrait chat {c} view {v}; lifted {[m[0] for m in lift]}; landscape chat {c2} view {v2}")
PY
for p in lobby keyboard down landscape; do
	[ -s "$t/phone/$p.png" ] || fail "no screenshot $t/phone/$p.png"
done
echo "PASS: Crag Trial's lobby as a phone on the web: a column at the bottom, the chat field lifted above the keyboard and back down at the blur and as the keyboard went, the UI scale and the root held, a row across the screen in landscape ($t/phone)"
