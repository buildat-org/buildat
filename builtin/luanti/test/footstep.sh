#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: 140s
# covers: builtin/luanti/client_lua/** builtin/luanti/lua/bootstrap.lua
# **Does walking make a noise** ([NO_SOUND]'s footsteps, and the bar the
# user set 2026-09-24: "a mod that never mentions sound still sounds
# right in Luanti"). Official Luanti plays a footstep in the engine off
# the player's own movement -- no mod asks for it -- so this tree played
# none at all until the node's own spec reached the client.
#
#   builtin/luanti/test/footstep.sh
#
# A platform of one node, the player on it, and five seconds of held W.
# What is read is the module's own line: which node was heard from and
# which file of the group played. minetest_game because its nodes carry
# sounds; devtest's do not, which is why this is not the game to ask.
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
. "$me/lib.sh"
out="$here/local/footstep"; mkdir -p "$out"
save=buildat_test_footstep
port=31997
GAME="${GAME:-minetest_game}"
cd "$here/Build"
[ -d "$BUILDAT_USER_PATH/shared/vanilla/games/$GAME" ] || {
	echo "SKIP: $GAME is not installed" >&2; exit "$SKIP"; }
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running" >&2
	exit "$SKIP"
fi
cat > "$out/fixture.lua" <<'LUA'
-- A flat platform of one node with the player standing on it
local ORIGIN = {x = 8, y = 10, z = 8}
local dirt = core.registered_nodes["default:dirt"] and "default:dirt" or
		core.registered_nodes["mcl_core:dirt"] and "mcl_core:dirt" or nil
core.register_on_joinplayer(function(player)
	if dirt == nil then
		core.log("action", "footstep: this game has no dirt to stand on")
		return
	end
	local air = core.get_content_id("air")
	local cid = core.get_content_id(dirt)
	local p1 = {x = ORIGIN.x - 12, y = ORIGIN.y - 2, z = ORIGIN.z - 12}
	local p2 = {x = ORIGIN.x + 12, y = ORIGIN.y + 6, z = ORIGIN.z + 12}
	local vm = VoxelManip(p1, p2)
	local emin, emax = vm:get_emerged_area()
	local area = VoxelArea(emin, emax)
	local data = vm:get_data()
	for i in area:iterp(p1, p2) do data[i] = air end
	for x = -12, 12 do
		for z = -12, 12 do
			data[area:index(ORIGIN.x + x, ORIGIN.y, ORIGIN.z + z)] = cid
		end
	end
	vm:set_data(data)
	vm:write_to_map()
	player:set_pos({x = ORIGIN.x, y = ORIGIN.y + 1, z = ORIGIN.z})
	core.log("action", "footstep: the player is on " .. dirt)
end)
LUA
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$out/srv.log" "Mods loaded" 120 "$port" \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
	[ $? = 1 ] || exit 1 # its own verdict below
srv=$SERVER_PID
if ! grep -aq "Mods loaded" "$out/srv.log"; then
	kill -9 "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
	echo "SKIP: the server did not come up" >&2; exit "$SKIP"
fi
# On the platform (the fixture's line is the server's): placed, the world
# around drawn, a second to land; then the five seconds of W
{ echo "wait_log 60000 the server put the player"
	echo "wait_log 60000 scene, 0 undrawn within 2"
	echo "delay 1000"
	echo "keydown W"
	# A timing test: walks 5 s
	echo "delay 5000"
	echo "keyup W"
	echo "quit"; } > "$out/cmds.txt"
run_client 60 "$out/cli.log" timeout 240 bin/buildat -s "localhost:$port" \
	-w 640x400 -l 3 -c @"$out/cmds.txt" > /dev/null 2>&1
rc=$?
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
if [ $rc != 0 ]; then
	echo "FAIL: the drive ($out/cli.log): $(grep -a "Command sequence failed\|run_client:" "$out/cli.log" | tail -1)"
	exit 1
fi
had=$(grep -ac "nodes with a footstep" "$out/cli.log")
known=$(grep -a "nodes with a footstep" "$out/cli.log" | head -1 |
	sed -n 's/.*predictions, \([0-9]*\) nodes with a footstep.*/\1/p')
played=$(grep -ac "luanti: footstep on " "$out/cli.log")
line=$(grep -a "luanti: footstep on " "$out/cli.log" | head -1 |
	sed 's/.*luanti: //')
echo "the client knows ${known:-0} nodes with a footstep;" \
		"walking played $played of them: ${line:-(nothing)}"
if [ "$had" -lt 1 ] || [ "${known:-0}" -lt 1 ]; then
	echo "FAIL: no node's footstep reached the client"
	exit 1
fi
if [ "$played" -lt 1 ]; then
	echo "FAIL: walking on a node with a footstep played nothing"
	grep -a "no footstep for" "$out/cli.log" | head -3
	exit 1
fi
echo "PASS: walking makes the noise the node says it does"
exit 0
# vim: set noet ts=4 sw=4:
