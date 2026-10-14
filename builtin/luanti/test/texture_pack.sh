#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [VOXEL_MATERIALS] layer 2's upgrade path: a texture pack under
# user/shared/vanilla/texture_packs, chosen in the world's world.mt
# ([WORLD_TXP]), wins over what the game ships. The runner writes
# a pack of one magenta stone texture, stands the player on camera.lua's
# stone floor and reads how much of the floor is magenta; the pack is
# removed after (it refuses to run if one of that name is already there).
#
#   builtin/luanti/test/texture_pack.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/texture_pack"
mkdir -p "$out"
pack="$BUILDAT_USER_PATH/shared/vanilla/texture_packs/buildat_check_pack"
[ -e "$pack" ] && { echo "$pack is in the way" >&2; exit 2; }
save=buildat_test_texture_pack
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
mkdir -p "$pack"
trap 'rm -rf "$pack"' EXIT
python3 - "$pack" <<'PY'
import sys
from PIL import Image
Image.new("RGB", (16, 16), (255, 0, 255)).save(sys.argv[1] + "/default_stone.png")
PY
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
# [WORLD_TXP] a world's pack is its world.mt's choice
mkdir -p "$BUILDAT_USER_PATH/apps/vanilla/saves/$save/luanti"
echo "buildat_texture_pack = buildat_check_pack" \
	> "$BUILDAT_USER_PATH/apps/vanilla/saves/$save/luanti/world.mt"
# camera.lua's stage, its line also said in the chat for the client to
# wait for (a copy: the other runners' pictures keep their chat empty)
sed 's/core.log("action", "camera: the floor and the wall are placed")/&; core.chat_send_all("camera: the floor and the wall are placed")/' \
	"$me/camera.lua" > "$out/camera.lua"
grep -q chat_send_all.*the.floor "$out/camera.lua" || { echo "FAIL: camera.lua's line moved"; exit 1; }
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/camera.lua" \
	start_server "$out/srv.log" "Mods loaded" 400 29784 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap 'rm -rf "$pack"; kill -INT '$srv' 2>/dev/null' EXIT
# The 2 s after the stage's line: the player moved onto it and its floor
# meshed in the ticks after. A look_dir ends when the camera is aimed;
# the frames after it draw the new view
{
	echo "wait_log 60000 chat: camera: the floor and the wall are placed"
	echo "delay 2000"
	echo "look_dir 0 -0.6 1"
	# a settle: first person is aimed at once, the view drawn after it
	echo "delay 500"
	echo "screenshot $out/floor.png"
	echo "quit"
} > "$out/cmds.txt"
bin/buildat -s localhost:29784 -w 1280x720 -l 3 -c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	{ echo "FAIL: the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"; exit 1; }
kill -INT "$srv" 2>/dev/null
# The server's exit, polled
for i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
grep -a "texture pack:" "$out/srv.log" | sed 's/.*: //' | head -3
python3 - "$out" <<'PY'
import sys
from PIL import Image
im = Image.open("%s/floor.png" % sys.argv[1]).convert("RGB")
w, h = im.size
crop = im.crop((w // 3, h // 2, 2 * w // 3, h - h // 6))
px = list(crop.getdata())
mag = sum(1 for r, g, b in px if r > 150 and b > 150 and g < 100)
share = 100.0 * mag / len(px)
print("the floor is %.1f %% magenta" % share)
print("PASS: the pack's texture is what the world wears" if share > 20
		else "FAIL: the pack did not reach the world")
sys.exit(0 if share > 20 else 1)
PY
