#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [VIEW_KEYS]: F3 (fog), Z held (zoom) and F12 (the engine's screenshot)
# driven on camera.lua's stage: local/viewkeys/plain.png, nofog.png,
# zoom.png and back.png; then V through the minimap's modes, which start
# hidden ([MINIMAP_OFF]): map_x4.png, map_x2.png, map_x1.png,
# radar_x4.png and back to map_off.png. Prints the chat and log lines the
# keys made.
#
#   builtin/luanti/test/viewkeys.sh
#
# VIEWKEYS_USER=<dir> runs it on another user directory than ../user (a
# scratch one has the default view range; it needs
# shared/vanilla/games/mineclone2 in it).
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
. "$me/fullscreen_gate.sh"
out="$here/local/viewkeys"
mkdir -p "$out"
# Last run's pictures are not this run's: a skipped fullscreen toggle left
# the old fullscreen.png in place and the check read it as fresh
rm -f "$out"/*.png
save=buildat_test_viewkeys
cd "$here/Build"
user=${VIEWKEYS_USER:-$BUILDAT_USER_PATH}
cli_user=()
[ -n "${VIEWKEYS_USER:-}" ] && cli_user=(-D "$VIEWKEYS_USER")
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$user/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/camera.lua" \
	start_server "$out/srv.log" "Mods loaded" 400 29778 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -D "$user" \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
sleep 5
srv=$(check_pgrep buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
cat > "$out/cmds.txt" <<CMDS
wait_log 60000 the server put the player
wait_log 60000 scene, 0 undrawn within 2
# "0 undrawn" is the mesher's count, not the frame: the first picture is
# the one the fullscreen check compares against, and taken two seconds
# after that line it came out at a frame mean of 19 against the usual 109
# (2026-09-22)
delay 8000
look_dir 0 -0.1 1
delay 2000
screenshot $out/plain.png
keypress F3
delay 1500
screenshot $out/nofog.png
keypress F3
keydown Z
delay 1500
screenshot $out/zoom.png
keyup Z
delay 800
screenshot $out/back.png
keypress F12
delay 1500
keypress V
delay 1200
screenshot $out/map_x4.png
keypress V
delay 1200
screenshot $out/map_x2.png
keypress V
delay 1200
screenshot $out/map_x1.png
keypress V
delay 1200
screenshot $out/radar_x4.png
keypress V
keypress V
keypress V
delay 1200
screenshot $out/map_off.png
$(fullscreen_section "$out")
delay 500
quit
CMDS
bin/buildat "${cli_user[@]}" -s localhost:29778 -w 1280x720 -o sound_mute=1 -l 3 -c @"$out/cmds.txt" \
	> "$out/cli.log" 2>&1
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep "chat (local)\|F12: screenshot\| E " "$out/cli.log" | sed 's/.*: //'
ls "$out"/*.png
# F11 twice: the world drawn in and after fullscreen ([BOX_PLAYTEST_3] 1;
# the extension's atlas is filled by hand, vanilla's is voxelworld's,
# which already restores -- this is the check that says so)
python3 - "$out" <<'PY'
import sys, statistics
from PIL import Image
out = sys.argv[1]
means = {}
for n in ("plain", "fullscreen", "after_f11"):
	try:
		im = Image.open("%s/%s.png" % (out, n)).convert("L")
	except IOError:
		continue  # the fullscreen half was not asked for
	w, h = im.size
	means[n] = statistics.mean(list(im.crop((0, h // 2, w, h)).getdata()))
print("frame means: " + ", ".join("%s %.0f" % (k, v) for k, v in means.items()))
drawn = min(means.values()) >= 25
if len(means) < 3:
	print("(the fullscreen toggle was skipped; FULLSCREEN=1 asks for it)")
elif not drawn:
	print("FAIL: the world went black across a screen mode change")
else:
	print("PASS: drawn before, in and after fullscreen")

# [MINIMAP_OFF]: a fresh run draws no minimap and the first V brings up
# surface mode. What says the starting mode exactly is the label the key
# prints -- V advances by one, so "surface mode, Zoom x4" out of the first
# press means the run started hidden. The pixels then only have to show
# that the map appeared: comparing two frames taken seconds apart cannot
# say more than that, since the sky behind the corner moves between them.
def corner(n):
	im = Image.open("%s/%s.png" % (out, n)).convert("L")
	w, h = im.size
	return list(im.crop((w - 210, 10, w - 10, 210)).getdata())

def apart(a, b):
	return sum(abs(p - q) for p, q in zip(a, b)) / float(len(a))

labels = []
for line in open("%s/cli.log" % out, errors="ignore"):
	i = line.find("Minimap ")
	if i >= 0:
		labels.append(line[i:].strip())
first = labels[0] if labels else "(none)"
appeared = apart(corner("plain"), corner("map_x4"))
print("the first V said %r; the minimap corner moved %.2f of a level" %
		(first, appeared))
hidden_at_start = (first == "Minimap in surface mode, Zoom x4" and
		appeared > 5.0 and labels[-1] == "Minimap hidden")
print("PASS: the minimap is off until V is pressed" if hidden_at_start
		else "FAIL: the minimap is drawn before it is asked for")
sys.exit(0 if (drawn and hidden_at_start) else 1)
PY
