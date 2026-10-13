#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-12)
# covers: extensions/launch_menu/init.lua client/launch_grid.lua
# [AITTA_ON_WEB]: the web client's launch menu (apps/play's page, headless
# Firefox) has Apps from Aitta: Home lists it under "Get more", a search
# for "aitta" finds it, and Enter opens the Aitta screen.
# simplified: the screen's list is [SERVERLESS_PLAY]'s (serverless releases,
# Play only); this one opens it against the default Aitta and does not
# wait for the list. get_more.png shows the row and its browser description.
# Needs web/ from util/build_web.sh.
#   util/aitta_on_web_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -s "$here/web/index.html" ] || skip "no web/ (util/build_web.sh)"
check_tmp aitta_on_web; t=$CHECK_TMP
# The waits after a waitlog are settles after the line: the screen it
# names drawn (before its shot) or focused (before the typing) in the
# frames after. Enter on Home's second row says "launch_menu: browse
# <its label>" and opens that list; Escape closes it ("<kind> closed").
cat > "$t/steps.json" <<J
[
	["nav", "\${URL}"],
	["waitlog", "launch_menu: [0-9]+ rows in", 120],
	["wait", 1500],
	["shot", "\${OUT}/home.png"],
	["key", "Down"],
	["key", "Enter"],
	["waitlog", "launch_menu: browse ", 10],
	["wait", 1500],
	["shot", "\${OUT}/get_more.png"],
	["key", "Escape"],
	["waitlog", "launch_menu: [a-z]+ closed", 10],
	["wait", 300],
	["type", "aitta"],
	["waitlog", "launch_menu: [0-9]+ rows for \"aitta\".*first Apps from Aitta", 20],
	["wait", 500],
	["key", "Enter"],
	["waitlog", "launch_menu: catalog Apps from Aitta", 20],
	["wait", 1500],
	["shot", "\${OUT}/aitta.png"]
]
J
cd "$here"
timeout 300 util/web_drive.sh firefox play "$t/steps.json" "$t/drive" > "$t/drive.txt" 2>&1 ||
	fail "the drive ($t/drive.txt, $t/drive)"
echo "PASS: the web launch menu lists Apps from Aitta, a search finds it, Enter opens it"
