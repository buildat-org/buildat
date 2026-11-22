#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-22)
# covers: util/web_server.cmake builtin/luanti_mapgen/meta.json util/package.sh
# drives: builtin/kit/kit.cpp builtin/kit/client_lua/editor.lua apps/workbench/** builtin/world_menu/**
# [KIT_WORKBENCH_WEB_LOCAL] Workbench as a single-player playground in the
# page: /?local=workbench (web/local/workbench, util/build_web_server.sh
# workbench) from apps/play's server, headless Chrome, no buildat server
# for the game:
#   1. The name asked, Manage's New game... from Brimstone Speedway, the
#      editor (its frame split measured); a kit/sign placed;
#   2. Games...: Export this game, the browser's download; Publish this
#      game... says why not (the page reaches no Aitta) and sends nothing;
#   3. Play mode, the race: Add bot from the pause menu, the race started,
#      the bot past its first checkpoint (the frame split, the page's
#      memory, the files' sizes);
#   4. Games...: Import a game from a file..., the download as "copy": the
#      switch reloads the page (index.html), which opens it in the editor;
#   5. The page loaded again: the name kept, "copy" open again, the list
#      has both games (kept in IndexedDB), Play on "game" opens it with the
#      sign (one entity more than the template).
# Screenshots, kept with KEEP_TMP=1: $t/web/*.png
#   util/workbench_web_local_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$here/web/local/workbench/buildat_server.wasm" ] ||
	skip "no web/local/workbench (util/build_web_server.sh workbench)"
command -v "${CHROME:-google-chrome}" > /dev/null || skip "no Chrome"
check_tmp workbench_web_local; t=$CHECK_TMP
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9 BUILDAT_AITTA_DEFAULT=https://127.0.0.1:9 \
	BUILDAT_HEARTH_DEFAULT=https://127.0.0.1:9

cd "$here/Build"
BUILDAT_LUANTI_LIST=http://127.0.0.1:9 start_server "$t/play.log" \
		"STATUS Listening" 120 auto bin/buildat_server -m ../apps/play \
		-D "$t/play" -C "$t/play.cache" -W "$here/web" -l 3 ||
	fail "the page's server ($t/play.log)"
CHECK_PIDS+=($SERVER_PID)
cat > "$t/steps.json" <<'J'
[
 ["nav", "${URL}"],
 ["waitlog", "local: asking the player's name", 60], ["type", "tester"], ["key", "Enter"],
 ["waitlog", "world_menu: the list shown, 0 worlds", 120], ["frames", 5],
 ["click", "Button", "New game..."],
 ["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
 ["click", "DropDownList", "▼"], ["waitlog", "dropdown_[0-9]+ open", 10], ["frames", 3],
 ["click", "Text", "Brimstone Speedway"], ["waitlog", "world_menu: template picked", 10],
 ["frames", 3], ["click", "Button", "Create"],
 ["waitlog", "kit editor: edit mode on", 240],
 ["waitlog", "frame split: [0-9]+ frames", 30],
 ["waitlog", "frame split: [0-9]+ frames", 30],
 ["shot", "${OUT}/editor.png"],
 ["event", "kit_edit {\"op\": \"place\", \"type\": \"kit/sign\", \"pos\": [0, 1, 0]}"],
 ["waitlog", "server: .*An edit by tester: placed kit/sign", 20],
 ["frames", 5], ["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
 ["click", "Button", "Games..."], ["waitlog", "world_menu: the list shown, 1 worlds", 10], ["frames", 3],
 ["click", "Button", "Export this game"],
 ["waitlog", "kit editor: Exported game.template.zip \\([0-9]+ KiB\\)", 30],
 ["downloaded", "game.template.zip", 20], ["frames", 3],
 ["click", "Button", "Publish this game..."],
 ["waitlog", "kit editor: A game running in the page cannot publish", 10], ["frames", 10],
 ["shot", "${OUT}/publish.png"],
 ["key", "F6"], ["waitlog", "kit editor: edit mode off", 10], ["frames", 5],
 ["click", "Button", "Race: The*"],
 ["waitlog", "server: .*tester is on the grid, slot 1", 20], ["frames", 5],
 ["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
 ["click", "Button", "Add bot"],
 ["waitlog", "bot dialog shown", 20], ["frames", 3],
 ["click", "Button", "bot add"],
 ["waitlog", "bot dialog: sent", 20], ["frames", 5],
 ["click", "Button", "Start the race"],
 ["waitlog", "server: .*tester starts the race: 2 cars", 10],
 ["waitlog", "GO!", 30],
 ["holdkey", "w", 1500],
 ["waitlog", "server: .*Driver [0-9]+ passed checkpoint 1 of", 90],
 ["shot", "${OUT}/race.png"],
 ["waitlog", "frame split: [0-9]+ frames", 30],
 ["eval", "performance.measureUserAgentSpecificMemory().then(m => 'memory ' + Math.round(m.bytes / 1048576) + ' MiB: ' + m.breakdown.filter(b => b.bytes > 1048576).map(b => (b.attribution[0] || {}).scope + ' ' + Math.round(b.bytes / 1048576)).join(', '))"],
 ["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
 ["click", "Button", "Games..."], ["waitlog", "world_menu: the list shown, 1 worlds", 10], ["frames", 3],
 ["click", "Button", "Import a game from a file..."], ["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
 ["selall"], ["frames", 2], ["type", "copy"], ["frames", 2],
 ["file", "${OUT}/game.template.zip"],
 ["click", "Button", "Create"],
 ["waitlog", "world_menu: create copy from game.template.zip \\([0-9]+ bytes\\)", 30],
 ["waitlog", "server: .*workbench: the project \"copy\" from a file", 60],
 ["waitlog", "Disconnected from server: The server is switching", 30],
 ["waitlog", "local: playing as tester", 60],
 ["waitlog", "server: .*workbench: the project \"copy\" opens", 120],
 ["waitlog", "kit editor: edit mode on", 120], ["frames", 10],
 ["shot", "${OUT}/imported.png"],
 ["nav", "${URL}"],
 ["waitlog", "local: playing as tester", 60],
 ["waitlog", "server: .*workbench: the project \"copy\" opens", 120],
 ["waitlog", "server: .*tester joined world as entity", 60],
 ["waitlog", "kit: music: the scene loaded", 60], ["frames", 10],
 ["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
 ["click", "Button", "Games..."], ["waitlog", "world_menu: the list shown, 2 worlds", 10], ["frames", 3],
 ["click", "Text", "game"], ["frames", 5],
 ["shot", "${OUT}/kept.png"],
 ["click", "Button", "Play"],
 ["waitlog", "Disconnected from server: The server is switching", 30],
 ["waitlog", "local: playing as tester", 60],
 ["waitlog", "server: .*Hosted: [0-9]+ entities", 120],
 ["waitlog", "server: .*tester joined world as entity", 60], ["frames", 30],
 ["shot", "${OUT}/reopened.png"]
]
J
WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/?local=workbench&frame_split=1" \
	"$here/util/web_drive.sh" chrome workbench "$t/steps.json" "$t/web" > "$t/drive.log" 2>&1 ||
	{ tail -5 "$t/drive.log"; fail "the drive ($t/web/page.log)"; }
page=$t/web/page.log
grep -a "a thread of the local server failed\|IndexedDB write\|would not open\|cannot be opened\|malformed" "$page" &&
	fail "the page's server failed or a save did ($page)"
# The asked name only once: the reload is in as tester
[ "$(grep -ac "local: asking the player's name" "$page")" = 1 ] || fail "the name asked again after the reload"
# One entity more on the reload than the template's first start: the sign
grep -ao "Hosted: [0-9]* entities" "$page" | awk '{print $2}' > "$t/hosted"
python3 -I - "$t/hosted" <<'PY' || fail "the sign was not kept over the reload ($page)"
import sys
n = [int(x) for x in open(sys.argv[1]).read().split()]
print("hosted:", n)
assert len(n) >= 3 and n[-1] == n[0] + 1, n
PY
[ -s "$t/web/game.template.zip" ] || fail "no download"
echo "the export: $(wc -c < "$t/web/game.template.zip") bytes"
# The measurements: the editor's frame (the second split after the editor
# opened: the build landed), the race's, the page's memory, the files
split() # <after regex> <nth> <label>
{
	awk -v re="$1" -v nth="$2" '$0 ~ re {e = 1} e && /frame split: [0-9]+ frames/ {
		if (++n == nth) {print; exit}}' "$page" |
		sed "s/.*frame split: /$3: /;s/; ms\/s.*the rest/; the rest/;s/; the update.*//"
}
split "kit editor: edit mode on" 2 editor
split "starts the race" 1 race
grep -a "eval: \"memory" "$t/drive.log"
grep -a "server: .*network: .*ticks/s" "$page" | tail -1 | sed 's/.*network: /server: /'
for f in "$here"/web/local/workbench/buildat_server.*; do
	python3 -I -c 'import gzip, sys; b = open(sys.argv[1], "rb").read(); print("%s %.2f MB, %.2f gzipped" % (sys.argv[1].split("/")[-1], len(b) / 1e6, len(gzip.compress(b, 6)) / 1e6))' "$f"
done
echo "PASS: Workbench in the page: a game from Brimstone Speedway in the editor, exported, Publish saying why not, raced with a bot, the export imported, both games and the edit kept over a reload"
