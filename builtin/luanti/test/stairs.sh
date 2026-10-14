#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [VL_STAIRS]: a VoxeLibre stair is climbed by walking into it. A stone
# floor with a stair facing +z and one turned to face +x (param2 1); the
# client holds W into the first and D into the second, and the server logs
# where the player is every 0.1 s. The top step is y 200.5, which a stair
# that is a whole cube never lets the player reach. Prints PASS or FAIL.
#
#   builtin/luanti/test/stairs.sh
#
# covers: apps/vanilla/main/client_lua/init.lua
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
# Under the repo, not /tmp: the boxed server reads nothing in /tmp
out="$here/local/stairs"; mkdir -p "$out"
save=buildat_test_stairs
cd "$here/Build"
if check_pgrep buildat_server >/dev/null; then
	echo "SKIP: a buildat server is already running" >&2; exit "$SKIP"
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
srv=""
trap 'kill -INT "$srv" 2>/dev/null; true' EXIT
cat > "$out/fixture.lua" <<'LUA'
core.register_on_joinplayer(function(player)
	local function lay()
		for x = -3, 4 do for z = -3, 4 do
			core.set_node({x=x, y=199, z=z}, {name="mcl_core:stone"})
			for y = 200, 203 do core.set_node({x=x, y=y, z=z}, {name="air"}) end
		end end
		core.set_node({x=0, y=200, z=2}, {name="mcl_stairs:stair_stone_rough", param2=0})
		core.set_node({x=2, y=200, z=-2}, {name="mcl_stairs:stair_stone_rough", param2=1})
	end
	core.after(3, function()
		lay()
		player:set_pos({x=0, y=199.5, z=0})
		player:set_look_horizontal(0)
	end)
	-- Again, in case the mapgen wrote over the first
	core.after(5, function()
		lay()
		-- The drive waits for this line
		core.chat_send_player(player:get_player_name(), "stairs: ready")
	end)
	core.after(14, function()
		core.log("action", "stairs: second")
		core.chat_send_player(player:get_player_name(), "stairs: second")
		player:set_pos({x=0, y=199.5, z=-2})
		player:set_look_horizontal(0)
	end)
	local function tick()
		if player:is_player() then
			local p = player:get_pos()
			core.log("action", string.format("stairs: y=%.2f x=%.2f z=%.2f",
					p.y, p.x, p.z))
			core.after(0.1, tick)
		end
	end
	core.after(1, tick)
end)
LUA
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" BUILDAT_LUANTI_SEED=5 \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$out/srv.log" "Mods loaded" 120 auto \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla ||
	{ echo "FAIL: the server did not start"; exit 1; }
port=$SERVER_PORT
srv=$SERVER_PID
# The 4 s holds are the walks; the fixture moves the player to the
# second stair 9 s after "ready", past the first walk
printf 'wait_log 120000 chat: stairs: ready\ndelay 1000\nkeydown W\ndelay 4000\nkeyup W\nwait_log 20000 chat: stairs: second\ndelay 1000\nkeydown D\ndelay 4000\nkeyup D\ndelay 500\nquit\n' > "$out/cmds.txt"
timeout 180 bin/buildat -s "localhost:$port" -w 640x360 -o sound_mute=1 \
	-c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	{ echo "FAIL: the drive; see $out/cli.log"; exit 1; }
# The highest y and the furthest along the walk: past the stair (3) and up
# on it on the way is the pass. A stair that is a whole cube, or one turned
# the wrong way, puts a step of a whole voxel in the way and the player
# stops at 1.2 at y 199.5. The highest y is a coarse one -- the server
# hears the player's position a few times a second -- so 200.5 is not
# asked for.
walk() { awk -v k="$1" 'BEGIN { y = 0; f = -9 } /y=/ {
	for(i = 1; i <= NF; i++){ split($i, kv, "="); v[kv[1]] = kv[2] + 0 }
	if(v["y"] > y) y = v["y"]; if(v[k] > f && v[k] < 50) f = v[k] }
	END { print y, f }'; }
first=$(grep -a "stairs: " "$out/srv.log" | sed '/stairs: second/q' | walk z)
second=$(grep -a "stairs: " "$out/srv.log" | sed '1,/stairs: second/d' | walk x)
echo "the highest y and the furthest: $first walking +z, $second walking +x"
ok() { awk -v y="$1" -v f="$2" 'BEGIN { exit !(y > 199.9 && y < 201 && f > 3) }'; }
if ok $first && ok $second; then
	echo "PASS: both stairs climbed"
	exit 0
fi
echo "FAIL: a stair was not climbed; see $out/srv.log"
exit 1
# vim: set noet ts=4 sw=4:
