#!/bin/bash
# tier: full
# cost: ~4 min (2026-10-11)
# covers: apps/vanilla/main/client_lua/init.lua apps/vanilla/main/main.cpp
# [LOADING_SCREEN]: while the world loads, vanilla shows a screen of its
# own: one of the game's menu/background*.png at random, scaled to cover,
# on Buildat's dark colour; no HUD, no walking, no mouse look; it ends once
# the chunks near the player are drawn. Vanilla on VoxeLibre, the native
# client:
#   1. a join straight to the server (the game's media into the client's
#      cache): a picture chosen and shown;
#   2. a join over a link of 300 KB/s (util/netsim.py): the screenshot is
#      the chosen picture, covered and centred; W held and the mouse moved
#      while it shows move nothing (F5's place and yaw); "N of M" moves;
#      after "load: the world is in", W walks;
#   3. the minimal game, which has no menu/: the dark colour alone.
# simplified: native only; the web client draws the same script.
# Needs mineclone2 in the desk's games.
#   util/loading_screen_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || { echo "SKIP: no mineclone2"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp loading_screen; t=$CHECK_TMP
trap check_cleanup EXIT
mkdir -p "$t/srv/apps/vanilla/saves/ls/luanti" "$t/srv/shared/vanilla/games"
cp -r "$G" "$t/srv/shared/vanilla/games/"
echo "enable_damage = false" > "$t/srv/apps/vanilla/saves/ls/luanti/world.mt"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=ls start_server "$t/srv.log" \
	"STATUS Listening" 180 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client(){ run_client 60 "$1" timeout 400 "$here/Build/bin/buildat" -C "$t/nc" \
	-D "$t/nu" -w 800x450 -l 3 -o sound_mute=1 "${@:2}"; }

# 1
printf "wait_log 300000 load: the world is in\nquit\n" > "$t/1.cmds"
client "$t/1.log" -s "127.0.0.1:$SERVER_PORT" -c @"$t/1.cmds"
grep -aq "vanilla : load: the picture background[.0-9]*png, 1920x1080" "$t/1.log" ||
	fail "no picture on the first join ($t/1.log)"

# 2
LINK=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 "$here/util/netsim.py" --listen "$LINK" --to "127.0.0.1:$SERVER_PORT" \
	--delay 0 --rate 2400 > "$t/netsim.log" 2>&1 &
CHECK_PIDS+=($!)
sleep 1
cat > "$t/2.cmds" <<C
wait_log 120000 load: the picture
delay 300
screenshot $t/screen.png
wait_log 120000 load: Loading the world:
keypress F5
mouse_pos 400 225
keydown W
mouse_move 200 0
delay 400
mouse_move 0 120
delay 1600
keyup W
keypress F5
keypress F5
keypress F5
wait_log 300000 load: the world is in
delay 1500
screenshot $t/world.png
keydown W
delay 1500
keyup W
keypress F5
keypress F5
keypress F5
delay 500
quit
C
client "$t/2.log" -s "127.0.0.1:$LINK" -c @"$t/2.cmds"
grep -a "vanilla : load: \|loading picture" "$t/2.log" "$t/srv.log" | sed 's/.*: load: /load: /;s/.*I main *: //' | sed -n '1,4p;$p'
python3 - "$t" "$G/menu" <<'PY' || fail "the loading screen ($t/2.log)"
import re, sys
import numpy as np
from PIL import Image
t, menu = sys.argv[1], sys.argv[2]
log = open(t + "/2.log", errors="replace").read().splitlines()
pic = [re.search(r"vanilla : load: the picture (\S+), ", l) for l in log]
pic = [m.group(1) for m in pic if m][0]
# The screenshot against the picture covered and centred, away from the
# lines on it (F5's at the top, the loading line in the middle)
shot = np.asarray(Image.open(t + "/screen.png").convert("RGB")).astype(float)
h, w = shot.shape[:2]
src = Image.open(menu + "/" + pic).convert("RGB")
k = max(w / src.width, h / src.height)
sw, sh = round(src.width * k), round(src.height * k)
want = np.asarray(src.resize((sw, sh), Image.BILINEAR)).astype(float)
want = want[(sh - h) // 2:(sh - h) // 2 + h, (sw - w) // 2:(sw - w) // 2 + w]
rows = list(range(h // 8, 3 * h // 8)) + list(range(5 * h // 8, 7 * h // 8))
diff = np.abs(shot[rows] - want[rows]).mean()
print("%s on the screen, off by %.1f" % (pic, diff))
assert diff < 12, "the screen is not %s: off by %.1f" % (pic, diff)
# F5 before and after W and the mouse, both while the screen was up
end = [i for i, l in enumerate(log) if "vanilla : load: the world is in" in l][0]
f5 = [(i, re.search(r"\| \(([-\d.]+), ([-\d.]+), ([-\d.]+)\) \| yaw: ([-\d.]+)", l))
      for i, l in enumerate(log) if "| step:" in l]
f5 = [(i, tuple(float(v) for v in m.groups())) for i, m in f5 if m]
assert len(f5) >= 3, "%d F5 lines" % len(f5)
(i0, a), (i1, b) = f5[0], f5[1]
assert i1 < end, "the second F5 line after the world came in"
print("while loading: %s, then %s" % (a, b))
assert abs(a[0] - b[0]) < 0.1 and abs(a[2] - b[2]) < 0.1 and a[3] == b[3], \
    "the player moved or turned on the loading screen"
assert f5[-1][0] > end, "no F5 line after the world came in"
c = f5[-1][1]
print("after it: %s" % (c,))
assert abs(c[0] - b[0]) + abs(c[2] - b[2]) > 1, "W did not walk after the screen"
# "N of M" moving
n = [int(m.group(1)) for m in (re.search(r"load: Loading the world: (\d+) of \d+", l)
     for l in log) if m]
print("N of M: " + " ".join(map(str, n)))
assert len(set(n)) >= 2, "N of M stood still"
PY

# 3: the minimal game, through the same client
mkdir -p "$t/m/apps/vanilla/saves/mn/luanti"
echo "enable_damage = false" > "$t/m/apps/vanilla/saves/mn/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=mn start_server "$t/m.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/m" -C "$t/m.cache" -l 3 ||
	fail "the minimal server ($t/m.log)"
CHECK_PIDS+=($SERVER_PID)
printf "wait_log 120000 load: no loading picture\nscreenshot %s\nwait_log 120000 load: the world is in\nquit\n" \
	"$t/dark.png" > "$t/3.cmds"
client "$t/3.log" -s "127.0.0.1:$SERVER_PORT" -c @"$t/3.cmds"
python3 - "$t/dark.png" <<'PY' || fail "the minimal game's screen ($t/3.log)"
import sys
import numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
dark = (np.abs(a - [0x15, 0x15, 0x1a]).max(axis=2) <= 3).mean()
print("the dark colour on %.0f%% of the screen" % (dark * 100))
assert dark > 0.8
PY
grep -ac "loading picture: background" "$t/srv.log" | grep -qx 2 ||
	fail "not two pictures chosen ($t/srv.log)"
echo "PASS: a game's background on the loading screen, covered; nothing moves while it shows, and W walks after; a game without one: the dark colour"
