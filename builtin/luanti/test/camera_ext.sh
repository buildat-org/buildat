#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [THIRD_PERSON]: the extension client's camera key against official
# Luanti's server, the three views shot: local/camera_ext/first.png,
# behind.png, front.png; the stage is camera.lua's as a worldmod. Needs the
# Luanti checkout and its server binary the way episode.sh does.
#
#   builtin/luanti/test/camera_ext.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/camera_ext"; mkdir -p "$out"
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
( cd "$luanti" && exec "$bin" --server --world "$work" --port "$port" \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
srv=$!
trap 'kill "$srv" 2>/dev/null' EXIT
# "Server for gameid ... listening on": up
for i in $(seq 1 600); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && break
	kill -0 "$srv" 2>/dev/null || break
	sleep 0.2
done
grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null ||
	{ echo "the Luanti server did not come up ($out/luanti_srv.log)" >&2; exit 1; }
# A C says the view it turned to in the client's log; the 1.5 s after
# look_dir and after the first two is the third-person camera settling
# against the wall.
# camera.lua's stage, six seconds after the join, says so in the chat
cat > "$out/cmds.txt" <<CMDS
wait_log 90000 voxel types have their own textures
wait_log_any 30000 chat: camera: the floor and the wall are placed
# a settle: the stage's nodes drawn
delay 1500
look_dir 0 -0.1 1
# simplified: the world drawn in the new direction; a settle line after a
# turn (0 undrawn in view) would be the event
delay 1500
screenshot $out/first.png
keypress C
wait_log 5000 chat (local): Third person view
delay 1500
event scan cam
screenshot $out/behind.png
keypress C
wait_log 5000 chat (local): Third person view (front)
delay 1500
screenshot $out/front.png
keypress C
wait_log 5000 chat (local): First person view
quit
CMDS
BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=cam \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" > "$out/extension_cli.log" 2>&1 ||
	{ echo "FAIL: the drive ($out/extension_cli.log): $(grep -ao 'Command sequence failed.*' "$out/extension_cli.log" | head -1)"; exit 1; }
kill "$srv" 2>/dev/null
for i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
grep -a "person view\|E " "$out/extension_cli.log" | grep -av wait_log | sed 's/.*: //' | head -5
# [OVER_SHOULDER]'s open reading: where the camera and the model were in the
# frame the back view was shot in, said by the client itself
grep -a "camera at " "$out/extension_cli.log" | sed 's/.*: camera at/camera at/' | tail -1
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
echo "the three person views: $shots pictures, $errors error lines"
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
