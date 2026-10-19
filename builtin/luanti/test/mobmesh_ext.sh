#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-10-19)
# covers: extensions/luanti_client/res/mesh_read.lua extensions/luanti_client/res/b3dmesh.lua extensions/luanti_client/objects.lua
# [LUANTI_SHARED_1019]: mobmesh.sh's stage (mobmesh.lua as a worldmod) under
# official Luanti's server, drawn by the extension client: the mobs' .b3d
# read by the module's own readers (res/mesh_read.lua) and posed at their
# animation's first frame, not the bind pose. The shots are
# local/mobmesh_ext/mobs.png and zombie_side.png. Needs the Luanti checkout
# and its server binary the way camera_ext.sh does.
#
#   builtin/luanti/test/mobmesh_ext.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/mobmesh_ext"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}
[ -x "$bin" ] || { echo "SKIP: no $bin"; exit 77; }
if check_pgrep buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	echo "SKIP: a client or a Luanti server is already running"; exit 77
fi
check_build
check_tmp mobmesh_ext; work=$CHECK_TMP/world
mkdir -p "$work/worldmods/mobmesh"
cat > "$work/world.mt" <<MT
gameid = mineclone2
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
world_name = mobmesh
creative_mode = false
server_announce = false
MT
cp "$me/mobmesh.lua" "$work/worldmods/mobmesh/init.lua"
printf 'name = mobmesh\n' > "$work/worldmods/mobmesh/mod.conf"
{ echo "fixed_map_seed = 5"; echo "time_speed = 0"; echo "enable_damage = false"
	echo "mute_sound = true"; } > "$out/luanti.conf"
port=30030
( cd "$luanti" && exec "$bin" --server --world "$work" --port "$port" \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
srv=$!
# check_cleanup waits for it to exit: the next check skips while it runs
CHECK_PIDS+=($srv)
for i in $(seq 1 600); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && break
	kill -0 "$srv" 2>/dev/null || break
	sleep 0.2
done
grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null ||
	{ echo "FAIL: the Luanti server did not come up ($out/luanti_srv.log)"; exit 1; }
# mobmesh.lua puts the player twice: on the stage 6 s after the join, then
# beside the zombie 16 s later. simplified: as mobmesh.sh, delays after
# the first placing rather than a line for the stage
cat > "$out/cmds.txt" <<CMDS
wait_log 90000 voxel types have their own textures
wait_log 60000 model mobs_mc_zombie.b3d
delay 10000
look_dir 1 -0.15 0
delay 2000
screenshot $out/mobs.png
delay 6000
look_dir 2.5 0.2 1
delay 1500
screenshot $out/zombie_side.png
quit
CMDS
BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=mobs \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" > "$out/extension_cli.log" 2>&1 ||
	{ echo "FAIL: the drive ($out/extension_cli.log): $(grep -ao 'Command sequence failed.*' "$out/extension_cli.log" | head -1)"; exit 1; }
grep -ao 'model [^ ]*\.b3d.*quads' "$out/extension_cli.log" | sort -u
posed=$(grep -ac 'model [^ ]*\.b3d posed at frame' "$out/extension_cli.log")
errors=$(sed '/Command sequence complete/q' "$out/extension_cli.log" | grep -ac " E ")
shots=$(ls "$out"/*.png 2>/dev/null | wc -l)
[ "${posed:-0}" -ge 1 ] || { echo "FAIL: no .b3d mob posed at a frame ($out/extension_cli.log)"; exit 1; }
[ "${errors:-0}" -eq 0 ] || { echo "FAIL: the client logged $errors error lines ($out/extension_cli.log)"; exit 1; }
[ "$shots" -ge 2 ] || { echo "FAIL: $shots pictures"; exit 1; }
echo "PASS: luanti_client read the mobs' .b3d with the module's readers, $posed posed at a frame ($out/mobs.png, zombie_side.png)"
# vim: set noet ts=4 sw=4:
