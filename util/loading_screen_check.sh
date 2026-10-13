#!/bin/bash
# tier: full
# cost: ~7 min (2026-10-12)
# covers: apps/vanilla/main/client_lua/init.lua apps/vanilla/main/main.cpp src/client/state.cpp builtin/replicate/replicate.cpp
# [LOADING_SCREEN]: while the world loads, vanilla shows a screen of its
# own: one of the game's menu/background*.png at random, scaled to cover,
# on Buildat's dark colour; no HUD, no walking, no mouse look; it ends once
# the chunk the player is in is drawn. Vanilla on VoxeLibre, the native
# client:
#   1. a join straight to the server (the game's media into the client's
#      cache): a picture chosen and shown; again in a window wider than
#      the picture and one taller ([LOADING_PIC_FIT]): covered and
#      centred, not stretched, and the UI scale while it shows the one
#      after it;
#   2. a join over a link of 300 KB/s (util/netsim.py), stopped for 8 s
#      at the first "load: last" line: the screenshot is
#      the chosen picture, covered and centred; W held and the mouse moved
#      while it shows move nothing (F5's place and yaw); the line has no
#      "N of M" and the screen ends at the player's own chunk, well before
#      its 60 s after the first ([LOAD_OWN_CHUNK]); after "load: the world is in", W or A walks;
#   3. the minimal game, which has no menu/: the dark colour alone;
#   4. [LOADING_STRIPES]: in 2's screenshot at a "load: last" line, and
#      in 4, a join over the 300 KB/s link stopped for 25 s at its first
#      line: two full-width stripes of the brand page colour round a
#      line-high gap in the middle, the second 1.5 times as tall; the line
#      amber on the first, the glyph white and the name cyan on the
#      second; a line every 0.5 s; the client still there after the
#      stop, with no Leave button.
# simplified: a file's picture and a chunk's glyph on stripe two are not
# looked at: natively the game's files are all in before the screen, and
# the own chunk comes within a line of the first (2026-10-12)
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
# fuzz.sh's seed 3, good for walking: a random one could face a trunk
BUILDAT_LUANTI_SEED=3 BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=ls start_server "$t/srv.log" \
	"STATUS Listening" 180 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client(){ run_client 60 "$1" timeout 400 "$here/Build/bin/buildat" -C "$t/nc" \
	-D "$t/nu" -w ${WIN:-800x450} -l 3 -o sound_mute=1 "${@:2}" ||
	fail "the client ($1): $(grep -a "Command sequence failed\|run_client:" "$1" | tail -1 | cut -c 1-300)"; }
# link_up <log> <pid>: the netsim link listening, up to 10 s
link_up(){
	local i
	for i in $(seq 50); do
		grep -aq "netsim: listening" "$1" && return 0
		kill -0 "$2" 2>/dev/null || break
		sleep 0.2
	done
	fail "the link did not come up ($1)"
}
# covered <screenshot> <picture> <from> <to> ...: how far the screenshot is
# from the picture scaled to cover and centred, on the rows from..to
# (fractions of the height)
cat > "$t/covered.py" <<'PY'
import sys
import numpy as np
from PIL import Image
shot = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(float)
h, w = shot.shape[:2]
src = Image.open(sys.argv[2]).convert("RGB")
k = max(w / src.width, h / src.height)
sw, sh = round(src.width * k), round(src.height * k)
want = np.asarray(src.resize((sw, sh), Image.BILINEAR)).astype(float)
want = want[(sh - h) // 2:(sh - h) // 2 + h, (sw - w) // 2:(sw - w) // 2 + w]
rows = [r for a, b in zip(sys.argv[3::2], sys.argv[4::2])
        for r in range(int(float(a) * h), int(float(b) * h))]
print("%.1f" % np.abs(shot[rows] - want[rows]).mean())
PY
# stripes <screenshot>: the two stripes ([LOADING_STRIPES])
cat > "$t/stripes.py" <<'PY'
import sys
import numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
h, w = a.shape[:2]
near = lambda c: np.abs(a - c).max(axis=2) <= 6
page = near([0x1b, 0x1b, 0x22])
# A stripe's row: the page colour at both edges, across 8 columns each
full = page[:, :8].all(axis=1) & page[:, -8:].all(axis=1)
bands, y = [], 0
while y < h:
    if full[y]:
        y0 = y
        while y < h and full[y]:
            y += 1
        bands.append((y0, y))
    y += 1
assert len(bands) == 2, "%s: stripes at rows %s" % (sys.argv[1], bands)
(a0, a1), (b0, b1) = bands
h1, h2, gap = a1 - a0, b1 - b0, b0 - a1
print("%s: stripes %d and %d tall, %d apart, the gap's middle at %.1f of %d"
      % (sys.argv[1], h1, h2, gap, (a1 + b0) / 2, h))
assert abs(h2 - 1.5 * h1) <= 2, "the second not 1.5 times the first"
assert abs((a1 + b0) / 2 - h / 2) <= 2, "the gap not in the middle"
assert 0.5 * h1 <= gap <= h1, "the gap not a line high"
# By hue: the letters are smoothed into the stripe
r, g, b = a[..., 0], a[..., 1], a[..., 2]
amber = ((r > 120) & (r > g + 30) & (g > b + 30))[a0:a1].sum()
cyan = ((b > r + 50) & (g > r + 40))[b0:b1].sum()
white = near([255, 255, 255])[b0:b1].sum()
print("amber %d, cyan %d, white %d pixels" % (amber, cyan, white))
assert amber > 20 and cyan > 20 and white > 20, "a colour missing"
PY

# 1
printf "wait_log 120000 load: the world is in\nquit\n" > "$t/1.cmds"
client "$t/1.log" -s "127.0.0.1:$SERVER_PORT" -c @"$t/1.cmds"
grep -aq "vanilla : load: the picture background[.0-9]*png, 1920x1080" "$t/1.log" ||
	fail "no picture on the first join ($t/1.log)"
# Through a link of 3 MB/s: the screen ends at the player's own chunk
# ([LOAD_OWN_CHUNK]), which a local join has drawn before the screenshot
FAST=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 "$here/util/netsim.py" --listen "$FAST" --to "127.0.0.1:$SERVER_PORT" \
	--delay 0 --rate 24000 > "$t/netsim_fast.log" 2>&1 &
CHECK_PIDS+=($!)
link_up "$t/netsim_fast.log" $!
for WIN in 1000x450 900x600; do
	# Soon: the screen ends well under a second after the picture since
	# [REGISTRY_FILE]. The 1.5 s after it: time for a UI scale change the
	# world would make to be logged
	printf 'wait_log 60000 load: the picture\ndelay 100\nscreenshot %s\nwait_log 120000 load: the world is in\ndelay 1500\nquit\n' \
		"$t/1_$WIN.png" > "$t/1_$WIN.cmds"
	WIN=$WIN client "$t/1_$WIN.log" -s "127.0.0.1:$FAST" -c @"$t/1_$WIN.cmds"
	pic=$(grep -aoP "vanilla : load: the picture \K\S+(?=,)" "$t/1_$WIN.log" | head -1)
	[ -n "$pic" ] || fail "no picture at $WIN ($t/1_$WIN.log)"
	# Away from the stripes in the middle
	off=$(python3 "$t/covered.py" "$t/1_$WIN.png" "$G/menu/$pic" 0.05 0.3 0.7 0.95)
	# The UI scale from the picture on: one line at most, the screen's and
	# the world's alike
	scales=$(sed -n '/vanilla : load: the picture/,$p' "$t/1_$WIN.log" |
		grep -aoP "UI scale.*" | sort -u)
	echo "$WIN: $pic off by $off; ${scales:-no UI scale change after the picture}"
	python3 -c "import sys; sys.exit(float(sys.argv[1]) >= 12)" "$off" ||
		fail "the screen at $WIN is not $pic covered: off by $off ($t/1_$WIN.png)"
	[ "$(echo "$scales" | grep -c .)" -le 1 ] ||
		fail "the UI scale changed while the picture showed at $WIN: $scales"
done

# 2
LINK=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 "$here/util/netsim.py" --listen "$LINK" --to "127.0.0.1:$SERVER_PORT" \
	--delay 0 --rate 2400 > "$t/netsim.log" 2>&1 &
linkpid=$!
CHECK_PIDS+=($linkpid)
link_up "$t/netsim.log" $linkpid
# W held 2 s and the mouse moved on the screen, W and A walked 1.5 s each
# in the world; the F5s' lines logged in the last half second
cat > "$t/2.cmds" <<C
wait_log 60000 load: last
delay 200
screenshot $t/last.png
keypress F5
mouse_pos 400 225
keydown W
mouse_move 200 0
# a timing test: W held 2 s, the mouse moved twice in it
delay 400
mouse_move 0 120
# the rest of W held 2 s
delay 1600
keyup W
keypress F5
keypress F5
keypress F5
wait_log 60000 load: the picture
delay 100
screenshot $t/screen.png
wait_log 120000 load: the world is in
delay 1500
screenshot $t/world.png
keydown W
# a timing test: W walks 1.5 s
delay 1500
keyup W
keydown A
# a timing test: A walks 1.5 s
delay 1500
keyup A
keypress F5
keypress F5
keypress F5
# a settle: the three F5s' lines, logged in the frames after the keys
delay 500
quit
C
# Since [REGISTRY_FILE] the world can be in half a second after the
# picture: the link stopped at the first line, the picture still coming,
# keeps the screen up for the stripes and the keys; a stop once the
# picture shows is too late, what follows it already in the socket
kill -0 $linkpid 2>/dev/null || fail "the 300 KB/s link is not there"
( until grep -aq "vanilla : load: last " "$t/2.log" 2>/dev/null; do sleep 0.1; done
	kill -STOP $linkpid; sleep 8; kill -CONT $linkpid ) &
CHECK_PIDS+=($!)
client "$t/2.log" -s "127.0.0.1:$LINK" -c @"$t/2.cmds"
kill -CONT $linkpid 2>/dev/null
grep -a "vanilla : load: \|loading picture" "$t/2.log" "$t/srv.log" | sed 's/.*: load: /load: /;s/.*I main *: //' | sed -n '1,4p;$p'
python3 "$t/stripes.py" "$t/last.png" || fail "the stripes ($t/last.png)"
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
# W, then A: a spawn in a forest can face a trunk
assert abs(c[0] - b[0]) + abs(c[2] - b[2]) > 1, "W and A did not walk after the screen"
# [LOAD_OWN_CHUNK] No "N of M", and the screen gone at the player's own
# chunk, well before the 60 s
lines = [l for l in log if "vanilla : load: Loading the world" in l]
assert lines and not [l for l in lines if " of " in l], lines[:3]
# From the voxel registry, before which nothing is meshed, or the picture,
# the later: the registry is a cached file since [REGISTRY_FILE]. After
# the picture, up to 3 MB of the game's palettes, texmods and object
# properties (10 s at this rate) before the own chunk
def secs(l):
    h, m, x = l.split()[2].split(":")
    return int(h) * 3600 + int(m) * 60 + float(x)
reg = [secs(l) for l in log if "voxelwor: the voxel registry" in l]
assert reg, "no voxel registry"
shown = [secs(l) for l in log if "vanilla : load: the picture" in l]
took = secs(log[end]) - max(reg[0], shown[0])
print("the screen ended %.1f s after the voxel registry and the picture came" % took)
assert took < 20, "the screen stood %.1f s after the registry and the picture" % took
# [LOADING_STRIPES] A line every 0.5 s
ts = [secs(l) for l in log if "vanilla : load: last " in l]
gaps = sorted(b - a for a, b in zip(ts, ts[1:]))
assert gaps, "no load: last lines"
mid = gaps[len(gaps) // 2]
print("load: last lines %.2f s apart (median)" % mid)
assert 0.4 <= mid <= 0.6, "the lines %.2f s apart" % mid
PY

# 3: the minimal game, through the same client
mkdir -p "$t/m/apps/vanilla/saves/mn/luanti"
echo "enable_damage = false" > "$t/m/apps/vanilla/saves/mn/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=mn start_server "$t/m.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/m" -C "$t/m.cache" -l 3 ||
	fail "the minimal server ($t/m.log)"
CHECK_PIDS+=($SERVER_PID)
printf "wait_log 60000 load: no loading picture\nscreenshot %s\nwait_log 60000 load: the world is in\nquit\n" \
	"$t/dark.png" > "$t/3.cmds"
client "$t/3.log" -s "127.0.0.1:$SERVER_PORT" -c @"$t/3.cmds"
python3 - "$t/dark.png" <<'PY' || fail "the minimal game's screen ($t/3.log)"
import sys
import numpy as np
from PIL import Image
a = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
# The stripes' page colour counts: the minimal game sends no picture
dark = ((np.abs(a - [0x15, 0x15, 0x1a]).max(axis=2) <= 3) |
        (np.abs(a - [0x1b, 0x1b, 0x22]).max(axis=2) <= 3)).mean()
print("the dark colour on %.0f%% of the screen" % (dark * 100))
assert dark > 0.8
PY

# 4: the 300 KB/s link stopped for 25 s at the first line, 5 s short of
# the client's own leave. Not the 3 MB/s one since [REGISTRY_FILE]: with a
# warm cache all up to the own chunk is in the socket by the first line.
kill -0 $linkpid 2>/dev/null || fail "the 300 KB/s link is gone"
cat > "$t/4.cmds" <<C
wait_log 60000 Waiting for the server... 20 s
screenshot $t/stall.png
wait_log 120000 load: the world is in
quit
C
# A timing test: the link polled for the first line, then stopped 25 s
( until grep -aq "vanilla : load: Loading the world" "$t/4.log" 2>/dev/null; do sleep 0.1; done
	kill -STOP $linkpid; sleep 25; kill -CONT $linkpid ) &
CHECK_PIDS+=($!)
client "$t/4.log" -s "127.0.0.1:$LINK" -c @"$t/4.cmds"
kill -CONT $linkpid 2>/dev/null
grep -aq "vanilla : load: the world is in" "$t/4.log" ||
	fail "the world not in after the stop ($t/4.log)"
grep -aq "Leave offered" "$t/4.log" && fail "Leave offered ($t/4.log)"
python3 "$t/stripes.py" "$t/stall.png" || fail "the stripes in the stop ($t/stall.png)"

grep -ac "loading picture: background" "$t/srv.log" | grep -qx 5 ||
	fail "not five pictures chosen, one per VoxeLibre join ($t/srv.log)"
echo "PASS: a game's background on the loading screen, covered, the UI scale unmoved by it; nothing moves while it shows, it ends at the own chunk and W and A walk after; a game without one: the dark colour; the two stripes, a line every 0.5 s, no Leave in a 25 s stop"
