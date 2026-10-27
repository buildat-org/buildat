#!/bin/bash
# tier: full
# needs: pixels
# cost: ~20 s (2026-10-27)
# covers: src/client/app.cpp extensions/ui_utils/res/style.xml extensions/launch_menu/preferences.lua extensions/ui_utils/init.lua
# [TRUSTED_SCREENS_OWN_FILES]: a server's module named ui_utils serves
# ui_utils/res/style.png, solid magenta. The game draws that name itself
# at the top left (the served file is in effect) and opens its settings
# window, the client's (launch_menu/preferences.lua, as the Engine
# settings), which loads its style by "own:" names: the client's
# installed files, so the window has no magenta in it.
# [TRUSTED_SCREENS_REST]: a module named load_glyphs serves page.png, solid
# magenta, the name the load screen's page glyph was loaded by. Before the
# settings the game takes the load screen and stages a line, which draws
# that glyph: the client's, no magenta there either.
#   util/trusted_own_files_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp trusted_own; t=$CHECK_TMP
app="$t/u/dev_apps/hostile_style"
mkdir -p "$app/launcher" "$app/main/client_lua" "$app/ui_utils/client_data/res" \
	"$app/load_glyphs/client_data" "$t/c"
cat > "$app/launcher/init.lua" <<'EOF'
return function(ctx) return {{id = "run", label = "hostile_style",
	run = function() ctx.launch{app = "hostile_style"} end}} end
EOF
cat > "$app/main/meta.json" <<'EOF'
{"engine_api": 2, "kind": "check", "disable_cpp": true,
	"client_main": "init.lua",
	"dependencies": [{"module": "network"}, {"module": "client_lua"},
		{"module": "client_data"}, {"module": "ui_utils"},
		{"module": "load_glyphs"}]}
EOF
for m in ui_utils load_glyphs; do
	echo '{"engine_api": 2, "disable_cpp": true, "dependencies": [{"module": "client_data"}]}' \
		> "$app/$m/meta.json"
done
python3 -c 'import sys; from PIL import Image
Image.new("RGBA", (256, 128), (255, 0, 255, 255)).save(sys.argv[1])
Image.new("RGBA", (16, 16), (255, 0, 255, 255)).save(sys.argv[2])' \
	"$app/ui_utils/client_data/res/style.png" "$app/load_glyphs/client_data/page.png"
cat > "$app/main/client_lua/init.lua" <<'EOF'
local magic = require("buildat/extension/urho3d")
local log = buildat.Logger("hostile_style")
local e = magic.ui.root:CreateChild("BorderImage")
e.texture = magic.cache:GetResource("Texture2D", "ui_utils/res/style.png")
e.imageRect = magic.IntRect(0, 0, 32, 32)
e.position = magic.IntVector2(0, 0)
e.size = magic.IntVector2(32, 32)
e.priority = 5000
local ui_utils = require("buildat/extension/ui_utils")
local screen = (ui_utils.safe or ui_utils).load_screen()
screen.stage("hostile_style")
log:info("hostile_style: load screen staged")
magic.SubscribeToEvent("command_seq:hostile_settings", function()
	screen.close()
	buildat.show_game_settings({})
	log:info("hostile_style: settings opened")
end)
EOF
printf '%s\n' "wait_log_any 60000 hostile_style: load screen staged" \
	"screenshot $t/load.png" "event hostile_settings" \
	"wait_log_any 5000 hostile_style: settings opened" \
	"wait_log_any 5000 Game settings shown" "screenshot $t/shot.png" quit \
	> "$t/cmds.txt"
cd "$here/Build"
run_client 30 "$t/cli.log" timeout -k 5 90 bin/buildat -C "$t/c" -D "$t/u" \
	-a dev/hostile_style/run -w 640x360 -l 3 -o sound_mute=1 -c @"$t/cmds.txt"
[ -f "$t/load.png" ] && [ -f "$t/shot.png" ] ||
	fail "no screenshot ($(grep -ao 'Command sequence failed.*' "$t/cli.log" | head -1))"
# Magenta in the top left corner, the game's square (the served file
# drawn; 32 units are fewer pixels at the scripted UI size), and how much
# of it anywhere else
magenta() { python3 -c 'import sys; from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB"); w, h = im.size
m = lambda p: p[0] > 200 and p[1] < 60 and p[2] > 200
own = sum(m(im.getpixel((x, y))) for x in range(64) for y in range(64))
other = sum(m(p) for p in im.getdata()) - own
print(own, other)' "$1"; }
for shot in load shot; do
	read -r own other < <(magenta "$t/$shot.png")
	[ "$own" -gt 100 ] ||
		fail "the served style.png is not in effect ($own magenta pixels at the top left of $shot.png)"
	[ "$other" -lt 50 ] || case $shot in
		load) fail "the load screen drew the served load_glyphs/page.png: $other magenta pixels ($t/load.png)";;
		*) fail "the game settings window drew the served style.png: $other magenta pixels ($t/shot.png)";;
	esac
done
echo "PASS: a server's ui_utils/res/style.png is the game's; the load screen's glyph and the settings window are the client's"
