#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: broken
# broken: back to full; the client logged 3 error lines; the same on dev
#   (local/runs/dev_baseline)
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
out="$here/local/hud_ext"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}
if check_pgrep buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	echo "SKIP: a client or a Luanti server is already running"; exit 77
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
# "Server for gameid=... listening on": up, or the server gone
for i in $(seq 1 600); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && break
	kill -0 $sub 2>/dev/null || break
	sleep 0.2
done
srv=$(pgrep -x luanti-refshots | head -1)
[ -n "$srv" ] || { echo "the Luanti server did not come up" >&2; exit 1; }
trap 'kill "$srv" 2>/dev/null' EXIT
# The delays are settles: the world, the minimap and the text drawn in the
# frames after the line or the turn
cat > "$out/cmds.txt" <<CMDS
wait_log 90000 voxel types have their own textures
delay 2000
look_dir 0 -0.1 1
# a settle: the view and the minimap redrawn at the new look
delay 1500
screenshot $out/minimap_surface.png
keypress V
wait_log 5000 V: Minimap
keypress V
wait_log 5000 V: Minimap
keypress V
wait_log 5000 V: Minimap
delay 1500
screenshot $out/minimap_radar.png
keypress F5
wait_log 5000 F5: 
delay 500
screenshot $out/f5_level1.png
keypress F5
wait_log 5000 F5: 
delay 500
screenshot $out/f5_level2.png
quit
CMDS
BUILDAT_RENDER_MODE="${MODE:-unlit}" BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=cam \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" > "$out/extension_cli.log" 2>&1 ||
	{ echo "FAIL: the drive ($(grep -a "Command sequence failed" "$out/extension_cli.log" | tail -1))"; exit 1; }
kill "$srv" 2>/dev/null
# The server's exit, polled
for i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
grep -a "Minimap\|E " "$out/extension_cli.log" | sed 's/.*: //' | head -6
ls "$out"/*.png
# **The verdict is that the run happened and said nothing angry**
# ([CI_RUNS]'s contract, 2026-09-25): what these pictures should look
# like is a person's reading -- that is why they are shot -- but a run
# that drew none, or a client that logged an error, is a failure nobody
# had to look at a picture to call. The exit status was `ls`'s until now.
shots=$(ls "$out"/*.png 2>/dev/null | wc -l)
# grep -c prints its count and exits 1 when that count is nought, so a
# "|| echo 0" beside it prints the number twice (2026-09-25)
errors=$(grep -ac " E " "$out/extension_cli.log" 2>/dev/null)
errors=${errors:-0}
echo "the HUD's pictures: $shots pictures, $errors error lines"
if [ "$shots" -lt 1 ]; then
	echo "FAIL: the run drew no pictures at all"
	exit 1
fi
if [ "$errors" -gt 0 ]; then
	echo "FAIL: the client logged $errors error lines; see $out/extension_cli.log"
	exit 1
fi
echo "PASS: the run drew $shots pictures and the client logged no error"
exit 0
# vim: set noet ts=4 sw=4:
