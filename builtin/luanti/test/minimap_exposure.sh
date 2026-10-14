#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [BOX_PLAYTEST_2] (9b): the minimap's brightness over half a minute. The
# stamp is drawn a few times a second and its meter used to get one step per
# stamp, so the map cycled between white and right; this shoots the minimap
# corner every four seconds and prints each shot's mean and white share.
#
#   builtin/luanti/test/minimap_exposure.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/minimap_exposure"
mkdir -p "$out"
save=buildat_test_minimap_exposure
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/camera.lua" \
	start_server "$out/srv.log" "Mods loaded" 120 29783 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap 'kill -INT "$srv" 2>/dev/null' EXIT
# The shots four seconds apart are the measurement; the 2 s after the
# world is drawn is a settle for the minimap's first stamps
{
	echo "wait_log_any 60000 chat: camera: the floor and the wall are placed"
	echo "wait_log 30000 scene, 0 undrawn within 2"
	echo "delay 2000"
	for i in $(seq 1 8); do
		echo "screenshot $out/map_$i.png"
		# a timing test: the shots 4 s apart
		echo "delay 4000"
	done
	echo "quit"
} > "$out/cmds.txt"
timeout 120 bin/buildat -s localhost:29783 -w 1280x720 -l 3 -c @"$out/cmds.txt" \
	> "$out/cli.log" 2>&1 ||
	{ echo "FAIL: the drive (see $out/cli.log)"; exit 1; }
kill -INT "$srv" 2>/dev/null
# A poll: the server's exit
for i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
python3 - "$out" <<'PY'
import sys, statistics
from PIL import Image
out = sys.argv[1]
means = []
for i in range(1, 9):
	im = Image.open("%s/map_%d.png" % (out, i)).convert("L")
	w, h = im.size
	# The minimap sits in the top right corner, ten pixels in, 128 across
	# at this window size
	crop = im.crop((w - 138, 10, w - 10, 138))
	data = list(crop.getdata())
	mean = statistics.mean(data)
	white = 100.0 * sum(1 for v in data if v > 250) / len(data)
	means.append(mean)
	print("shot %d: mean %.0f, white %.2f %%" % (i, mean, white))
# simplified: from the third shot. The first two, 2-6 s after the stage,
# see the level come down once from the move (128, 124, then 100 and
# holding, 2026-10-13); the cycle this is about repeats. A line the map
# logs when its meter has settled would be the event to start at
spread = max(means[2:]) - min(means[2:])
print("spread %.0f levels over shots 3 to %d" % (spread, len(means)))
print("FAIL: the minimap's level moves between stamps" if spread > 20
		else "PASS: the minimap holds its level")
sys.exit(1 if spread > 20 else 0)
PY
