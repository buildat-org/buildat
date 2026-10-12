#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [WATER_LIGHT]: the shore where a flow meets a pool, in a world of a fixed
# seed at a fixed place, shot straight down. What it asserts is the reading
# [WATER_LIGHT] 2 is about: the flowing row against the pool beside it, the
# same surface at the same angle. (Its A/B against the corner rule before
# 1627342e, BUILDAT_LIQUID_CORNER_AVG, read the same both ways and went
# with the flag, [RETIRE_DEAD].)
#
#   builtin/luanti/test/liquid_shore.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/liquid_shore"; mkdir -p "$out"
save=buildat_test_liquid_shore
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-mineclone2}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_RENDER_MODE=unlit \
	BUILDAT_LUANTI_LUA="$me/liquid_shore.lua" \
	start_server "$out/srv.log" "Mods loaded" 400 29788 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
sleep 5
srv=$(check_pgrep buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
trap 'kill -INT "$srv" 2>/dev/null' EXIT
shoot() { # <tag>
	{ echo "wait_log 180000 chat: liquid_shore: ready"
		# And the client's own world drawn before the shot, not only the
		# server's light settled
		echo "wait_log 120000 0 undrawn within 2"
		echo "delay 8000"
		# Straight down: the flowing row under the eye, the pool just
		# beyond it, both flat-on and both near
		echo "look 0 -89"
		echo "delay 1500"
		echo "screenshot $out/top_$1.png"
		echo "delay 500"
		echo "quit"; } > "$out/cmds_$1.txt"
	bin/buildat -s localhost:29788 -w 1280x720 -l 3 \
		-c @"$out/cmds_$1.txt" > "$out/cli_$1.log" 2>&1
}
shoot level
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
python3 - "$out" <<'PY'
import sys
from PIL import Image
out = sys.argv[1]
def mean(im, box):
	d = list(im.crop(box).getdata())
	return sum(sum(p) for p in d) / (3.0 * len(d))
# What [WATER_LIGHT] 2 asks, off the shot taken straight down: the
# flowing row is the band under the eye and the pool the band beyond it,
# both flat-on and both near, so nothing but the two nodes differs
it = Image.open("%s/top_level.png" % out).convert("RGB")
w, h = it.size
# The boundary runs a little below the middle of the frame: the pool is
# what is beyond it and the flowing row what is this side of it
flow = mean(it, (w // 3, h // 2 + 30, 2 * w // 3, h // 2 + 80))
pool = mean(it, (w // 3, h // 2 - 190, 2 * w // 3, h // 2 - 130))
print("straight down: the pool reads %.1f and the flowing row %.1f, "
		"%.1f apart" % (pool, flow, flow - pool))
# [WATER_LIGHT] 2: the two are the same water in the same light seen the
# same way, so what is left between them is the game's own art -- a flow
# twice the pool's brightness is a tint that did not reach it
ok = abs(flow - pool) < 0.25 * pool
print("PASS: the flowing row is the pool's own colour" if ok else
		"FAIL: flow and pool %.1f apart" % abs(flow - pool))
sys.exit(0 if ok else 1)
PY
