#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# needs: pixels
# [HOTBAR_LAYERS]: the hotbar drawn the same way after ten pause-menu opens
# and two fullscreen toggles. camera.lua's stage with items in some slots
# and not others; the hotbar strip of each shot is compared with the first
# one's, pixel for pixel: local/hotbar_layers/*.png.
#
#   builtin/luanti/test/hotbar_layers.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
. "$me/fullscreen_gate.sh"
out="$here/local/hotbar_layers"
mkdir -p "$out"
rm -f "$out"/*.png
save=buildat_test_hotbar_layers
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running"; exit 77
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
# The stage, and items in slots 1, 3 and 8 so that a slot that lost its item
# to the layering is one the shot can tell from a slot that never had one
{ cat "$me/camera.lua"; cat <<'LUA'
core.register_on_joinplayer(function(player)
	core.after(7, function()
		local inv = player:get_inventory()
		inv:set_stack("main", 1, "mcl_core:stone 7")
		inv:set_stack("main", 3, "mcl_core:dirt 12")
		inv:set_stack("main", 8, "mcl_tools:pick_wood")
		core.log("action", "hotbar_layers: the slots are filled")
		-- For the client to wait on; the chat is at the top, away from
		-- the hotbar's strip
		core.chat_send_player(player:get_player_name(),
				"hotbar_layers: the slots are filled")
	end)
end)
LUA
} > "$out/fixture.lua"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$out/srv.log" "Mods loaded" 400 29782 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap 'kill -INT "$srv" 2>/dev/null' EXIT
{
	# The slots drawn in the frames after the line
	echo "wait_log 90000 chat: hotbar_layers: the slots are filled"
	echo "delay 2000"
	echo "screenshot $out/start.png"
	# Ten opens and closes of the pause menu
	for i in $(seq 1 10); do
		echo "keypress Escape"; echo "wait_log 5000 pause: the menu shown"
		echo "keypress Escape"; echo "wait_log 5000 pause: the menu closed"
	done
	# The game drawn again after the last close
	echo "delay 1000"
	echo "screenshot $out/after_pause.png"
	fullscreen_section "$out"
	echo "quit"
} > "$out/cmds.txt"
bin/buildat -s localhost:29782 -w 1280x720 -l 3 -c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	{ echo "FAIL: the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"; exit 1; }
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
python3 - "$out" <<'PY'
import sys
from PIL import Image
out = sys.argv[1]
# The hotbar's strip: the bottom eighth of the frame, middle half across.
# A shot in fullscreen is a different size, so the strip is taken in shares
# of the frame rather than in pixels, and compared at the first one's size.
def strip(name):
	im = Image.open("%s/%s.png" % (out, name)).convert("RGB")
	w, h = im.size
	return im.crop((w // 4, h - h // 8, w - w // 4, h))
base = strip("start")
print("hotbar strip %dx%d" % base.size)
worst = 0
import os
shots = ["after_pause"]
for name in ("fullscreen", "after_f11"):
	if os.path.exists("%s/%s.png" % (out, name)):
		shots.append(name)
	else:
		print("(%s was skipped; FULLSCREEN=1 asks for the toggle)" % name)
for name in shots:
	im = strip(name).resize(base.size)
	a, b = list(base.getdata()), list(im.getdata())
	diff = sum(abs(p[0] - q[0]) + abs(p[1] - q[1]) + abs(p[2] - q[2])
			for p, q in zip(a, b)) / (3.0 * len(a))
	worst = max(worst, diff)
	print("%s: mean difference %.2f" % (name, diff))
# A fullscreen shot is the same hotbar at another resolution, so it is never
# pixel-identical; what a shuffled layer does is tens of levels, not ones
print("FAIL: the hotbar is drawn differently after a screen change" if worst > 8
		else "PASS: the same hotbar in all %d shots" % (len(shots) + 1))
sys.exit(1 if worst > 8 else 0)
PY
