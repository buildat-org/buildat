#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-18)
# covers: 3rdparty/Urho3D/Source/Urho3D/Graphics/OpenGL/OGLGraphics.cpp builtin/kit/client_lua/players.lua builtin/kit/client_lua/controls.lua apps/workbench/templates/brimstone_speedway/**
# [RACER_FEEL] (1) Brimstone Speedway in Workbench's web client in
# headless Firefox, webboss (the admin) New from it:
#   - (1) the time trial, the car driven weaving left and right: at
#     each stop "event kit_players" says the car's movement body drawn
#     (its CustomGeometries shown, the biggest's box over a square metre)
#     and which way it is turned; three yaws 20 degrees apart or more.
#     The car's body (a CustomGeometry with no texcoords) drawn after a
#     wheel's box was refused by Firefox ("Vertex fetch requires N, but
#     attribs only supply 24") and vanished as the car turned;
#     web_drive.sh fails on any such WebGL warning.
#   util/kit_racer_web_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${FIREFOX:-firefox}" > /dev/null && [ -f "$here/web/buildat.wasm" ] ||
	skip "no Firefox or web/"
check_tmp kit_racer_web; t=$CHECK_TMP
{
	cat <<'J'
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
 ["click", "Button", "Don't add"], ["frames", 3],
 ["waitlog_any", "world_menu: the list shown", 30], ["frames", 3],
 ["click", "Button", "New game..."],
 ["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
 ["click", "DropDownList", "▼"], ["waitlog", "dropdown_[0-9]+ open", 10], ["frames", 3],
 ["click", "Text", "Brimstone Speedway"], ["waitlog", "world_menu: template picked", 10],
 ["frames", 3], ["click", "Button", "Create"],
 ["waitlog", "kit editor: edit mode on", 120],
 ["frames", 10],
 ["key", "F6"], ["waitlog", "kit: ui full screen [0-9]+ up", 20], ["frames", 10],
 ["click", "Button", "Time trial: The*"],
 ["waitlog", "GO!", 20], ["frames", 5],
 ["holdkey", "w", 800],
J
	# (a weave along the straight: east, then left, right and back)
	for k in a:300 d:600 a:300 d:300 a:300; do
		cat <<J
 ["holdkey", ["w", "${k%:*}"], ${k#*:}], ["event", "kit_players"],
 ["waitlog", "movement body: ", 10], ["frames", 3],
J
	done
	cat <<'J'
 ["shot", "${OUT}/car.png"]
]
J
} > "$t/steps.json"
"$here/util/web_drive.sh" firefox workbench "$t/steps.json" "$t/web" ||
	fail "the web drive ($t/web)"
python3 -I - "$t/web/page.log" <<'PY' || fail "see above ($t/web/*.png, $t/web/page.log)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
m = [re.search(r"movement body: (\d+) geometries shown, the biggest ([0-9.]+) m2, turned (-?\d+)", l)
     for l in log.splitlines()]
m = [x for x in m if x]
assert len(m) >= 5, f"{len(m)} movement body lines, not 5"
for x in m:
    assert int(x[1]) >= 1 and float(x[2]) > 1, f"the body not drawn: {x[0]}"
yaws = []
for x in m:
    y = int(x[3])
    if all(min(abs(y - z), 360 - abs(y - z)) >= 20 for z in yaws):
        yaws.append(y)
assert len(yaws) >= 3, f"the car not turned through 3 yaws: {[x[0] for x in m]}"
print(f"ok: the car's body drawn at yaws {yaws}: {[x[0] for x in m]}")
PY
echo "PASS: Brimstone Speedway in Firefox: the car's body (a CustomGeometry without texcoords) drawn at every turn, no WebGL warning ($t/web)"
