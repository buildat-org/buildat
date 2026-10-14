#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# needs: pixels
# cost: 243s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [DAWN_LIGHT]: the hour before the sun. At 4:00-5:00 (and 19:00-20:00) the
# halo is up while the day ramp is still zero, so the ground was black under
# a night sky with a bright halo in it. The same nine hours are shot twice --
# once with the pre-dawn term and once with BUILDAT_LUANTI_NO_PREDAWN=1 --
# and the ground and the sky of each are read against each other: the four
# hours in the two windows must gain, and the three probed hours (02:00,
# 05:45, 20:30) must not move at all.
#
#   builtin/luanti/test/dawn_light.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/dawn_light"; mkdir -p "$out"
save=buildat_test_dawn
hours="0200 0400 0430 0500 0545 1900 1930 2000 2030"
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
# unlit: the mode with no auto-exposure in its path, so a shot is the light
# as it is rather than the meter's answer to it. The mode is the server's to
# say, which is why it is here and not on the clients.
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_RENDER_MODE=unlit \
	BUILDAT_LUANTI_LUA="$me/dawn_light.lua" \
	start_server "$out/srv.log" "Mods loaded" 120 29786 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap 'kill -INT "$srv" 2>/dev/null' EXIT
shoot() { # <tag> <extra env>
	local tag=$1
	local cmds="$out/cmds_$tag.txt"
	: > "$cmds"
	echo "wait_log 60000 scene, 0 undrawn within 2" >> "$cmds"
	# The first hour 25 s after the join, then one every 8 s
	local first=40000
	for h in $hours; do
		echo "wait_log $first chat: dawn: hour $h" >> "$cmds"
		first=15000
		# simplified: a settle of 3 s, past the 2 s rule, for the light
		# after the clock moves (below: 600 ms was measured short); a
		# line from the client when a relight is done would replace it
		echo "delay 3000" >> "$cmds"
		echo "screenshot $out/${tag}_$h.png" >> "$cmds"
	done
	echo "quit" >> "$cmds"
	# **The meter settled rather than waited for** (2026-09-24): the
	# adaptation runs on the frame's TimeStep, which the engine clamps
	# at a tenth of a second, so three seconds of delay is three
	# frames' worth of adaptation on a machine drawing a frame a second
	# and thirty times that here. The shots came out darker in a
	# container and the window's gain read half of this desk's. At this
	# rate each frame is exposed on its own key, which is the value the
	# delay was waiting for.
	# **And the three seconds are not only the meter** (tried
	# 2026-09-25): cut to 600 ms with the adaptation already instant,
	# the window still gained but the three probed hours moved by 42 to
	# 63 levels of ground -- so what the rest of that delay buys is the
	# light itself settling after the fixture moves the clock. It
	# stays.
	# A run that has stopped logging is taken down rather than waited out
	run_client 60 "$out/cli_$tag.log" env BUILDAT_VANILLA_ADAPT=1000000 $2 \
		timeout 180 bin/buildat -s localhost:29786 -w 640x480 -l 3 -c @"$cmds" ||
		{ echo "FAIL: the drive ($out/cli_$tag.log): $(grep -a 'Command sequence failed\|run_client:' "$out/cli_$tag.log" | head -1)"; exit 1; }
}
# The fixture's clock starts on each join, so each client gets the whole
# round of hours from the beginning
shoot with "BUILDAT_LUANTI_NO_PREDAWN="
# The same name joins again: the server has let the first one go
wait_for_log "$out/srv.log" "Player singleplayer left" 10 ||
	{ echo "FAIL: the first client's player was not let go ($out/srv.log)"; exit 1; }
shoot without "BUILDAT_LUANTI_NO_PREDAWN=1"
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
python3 - "$out" $hours <<'PY'
import sys
from PIL import Image
out, hours = sys.argv[1], sys.argv[2:]
def bands(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    def mean(box):
        d = list(im.crop(box).getdata())
        return sum(sum(p) for p in d) / (3.0 * len(d))
    # The ground is the bottom third of the frame, the sky the top quarter
    return mean((0, h - h // 3, w, h)), mean((0, 0, w, h // 4))
print("hour   ground without -> with      sky without -> with")
gained, moved = [], []
for hh in hours:
    try:
        g0, s0 = bands("%s/without_%s.png" % (out, hh))
        g1, s1 = bands("%s/with_%s.png" % (out, hh))
    except Exception as e:
        print("FAIL: %s" % e); sys.exit(1)
    print("%s   %6.2f -> %6.2f            %6.2f -> %6.2f" % (hh, g0, g1, s0, s1))
    if hh in ("0400", "0430", "1930", "2000"):
        gained.append((hh, g1 - g0, s1 - s0))
    if hh in ("0200", "0545", "2030"):
        moved.append((hh, abs(g1 - g0), abs(s1 - s0)))
# The ground is what the complaint was about -- black under a bright halo --
# and it is what this reads. 4:30 and 19:30 are the middle of the window and
# gain most; 4:00 and 20:00 sit at the very start of the ramp, where the
# term is a twentieth of its peak, so they are only asked to gain at all.
# The sky's own gain is printed and not gated: its colours go through
# lit^2.2, so a term of 0.085 moves a night sky by a level.
lit = all(g > (5.0 if hh in ("0430", "1930") else 1.0)
          for hh, g, _ in gained)
still = all(g < 0.1 and s < 0.1 for _, g, s in moved)
print("the window gained: " + ", ".join("%s +%.2f ground +%.2f sky" % x
        for x in gained))
print("the probed hours moved: " + ", ".join("%s %.2f ground %.2f sky" % x
        for x in moved))
print("PASS: the dawn and dusk windows gained and the probed hours did not"
      if lit and still else
      "FAIL: window %s, probed hours %s" % (lit, still))
sys.exit(0 if (lit and still) else 1)
PY
