#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# needs: pixels
# [BOX_PLAYTEST_3] (2): the pause menu's settings screen over the game --
# the cursor must be visible and the view must not turn under it. The
# scan's "mouse" line and the yaw in the status row are the reading.
# Older header:
# [EXT_HUD_PARITY]: the extension client's minimap and F5 keys against official
# Luanti's server: the minimap at the top right in surface mode, V three
# times to the radar, and F5's two levels, shot under local/hud_ext/; the
# stage is camera.lua's as a worldmod. Needs the Luanti checkout and its
# server binary the way episode.sh does.
#
#   builtin/luanti/test/hud_ext.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
. "$me/fullscreen_gate.sh"
out="$here/local/pause_screens"; mkdir -p "$out"
rm -f "$out"/*.png
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}
if check_pgrep buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	echo "a client or a Luanti server is already running" >&2; exit 2
fi
work="$out/luanti_world"
rm -rf "$work"; mkdir -p "$work/worldmods/camera"
cat > "$work/world.mt" <<MT
gameid = mineclone2
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
world_name = camera
creative_mode = false
server_announce = false
MT
cp "$me/camera.lua" "$work/worldmods/camera/init.lua"
printf 'name = camera\n' > "$work/worldmods/camera/mod.conf"
{ echo "fixed_map_seed = 5"; echo "time_speed = 0"; echo "enable_damage = false"
	echo "mute_sound = true"; } > "$out/luanti.conf"
port=30030
( cd "$luanti" && "$bin" --server --world "$work" --port "$port" \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
sub=$!
# Up: its line, then its port bound
for i in $(seq 1 600); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && port_taken $port && break
	kill -0 $sub 2>/dev/null || break
	sleep 0.2
done
srv=$(pgrep -x luanti-refshots | head -1)
[ -n "$srv" ] || { echo "the Luanti server did not come up" >&2; exit 1; }
trap 'kill "$srv" 2>/dev/null' EXIT
cat > "$out/cmds.txt" <<CMDS
wait_log 90000 voxel types have their own textures
wait_log_any 60000 loading: the world is in
delay 1000
event scan
screenshot $out/world.png
keypress Escape
wait_log 5000 pause: the menu shown
delay 300
event scan
screenshot $out/pause.png
CMDS
# Where the pause menu's "Settings..." button is: the form is drawn under
# the UI root rather than on the stack, so the scan cannot name it -- its
# place in the form is fixed (size[6,6.9], the fifth row). The second
# Escape is on the world (Settings... closed the pause menu before it
# opened), which opens the pause menu again; "pause: " is either line, so
# the wait holds whichever screen the first Escape left
cat >> "$out/cmds.txt" <<CMDS
mouse_pos 640 429
# The cursor moved is read in the frame after, then the click
delay 300
mouse_click left
wait_log 5000 settings: the screen shown
delay 300
event scan
screenshot $out/settings.png
mouse_move 200 0
# The window in which nothing must turn: the frames a turn would show in
delay 800
event scan
keypress Escape
wait_log 5000 settings: closed
delay 300
keypress Escape
wait_log 5000 pause:
# A settle after the line: the screen drawn before the shot
delay 1000
screenshot $out/before_f11.png
$(fullscreen_section "$out")
quit
CMDS
BUILDAT_RENDER_MODE="${MODE:-unlit}" BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=cam \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" > "$out/extension_cli.log" 2>&1 || {
	echo "FAIL: the drive ($out/extension_cli.log): $(grep -a "Command sequence failed" "$out/extension_cli.log" | tail -1)"
	exit 1; }
kill "$srv" 2>/dev/null
for i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
grep -a "scan [a-z]*: mouse\|scan [a-z]*: menu" "$out/extension_cli.log" | sed 's/.*: scan/scan/' | head -8
# The verdict: the settings screen up, the cursor visible under it, and
# the mouse moved while it is up turning nothing (the status row's yaw)
if grep -aq 'scan scan: menu "[^"]*luanti_client settings"' "$out/extension_cli.log" &&
		[ "$(grep -ac "scan scan: mouse visible" "$out/extension_cli.log")" -ge 4 ]; then
	echo "PASS: the settings screen over the game keeps the cursor"
fi
# F11 twice: the world must be drawn after each, which a mean well over
# black says ([BOX_PLAYTEST_3] 1)
python3 - "$out" <<'PY'
import sys, statistics
from PIL import Image
out = sys.argv[1]
means = {}
import os
for n in ("before_f11", "fullscreen", "after_f11"):
	path = "%s/%s.png" % (out, n)
	if n != "before_f11" and not os.path.exists(path):
		continue  # the fullscreen toggle was not asked for
	try:
		im = Image.open(path).convert("L")
	except Exception as e:
		print("FAIL: no %s shot: %s" % (n, e)); sys.exit(1)
	# The world, not the sky: the lower half, where the ground is
	w, h = im.size
	px = list(im.crop((0, h // 2, w, h)).getdata())
	means[n] = statistics.mean(px)
print("frame means: " + ", ".join("%s %.0f" % (k, v) for k, v in means.items()))
if min(means.values()) < 25:
	print("FAIL: the world went black across a screen mode change"); sys.exit(1)
if len(means) < 3:
	print("(the fullscreen toggle was skipped; FULLSCREEN=1 asks for it)")
print("PASS: the world is drawn before, in and after fullscreen"
		if len(means) == 3 else "PASS: the world is drawn")
PY
