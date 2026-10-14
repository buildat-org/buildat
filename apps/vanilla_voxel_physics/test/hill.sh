#!/bin/bash
# [VOXEL_PHYSICS_SAMPLE]: dig into a cave roof under a hill and it may come
# down (decided: generated matter is judged as it is). The fixture finds the
# highest column near the spawn, carves a 9x3x9 cavern (dirt spans two) under its top with
# two nodes of ground left over it, and puts the player inside; the
# client digs one node of the roof. The reading: the sim's bodies, and the
# cube of voxels before and after. The log is under local/voxel_physics/.
#
#   SEED=5 GAME=mineclone2 apps/vanilla_voxel_physics/test/hill.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
GAME="${GAME:-mineclone2}"
SEED="${SEED:-5}"
out="$here/local/voxel_physics"
mkdir -p "$out"
save="buildat_test_hill"
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla_voxel_physics/saves/$save"
cat > "$out/fixture.lua" <<LUA
rawset(_G, "FUZZ_SEED", $SEED)
LUA
cat >> "$out/fixture.lua" <<'LUA'
core.settings:set("fixed_map_seed", tostring(rawget(_G, "FUZZ_SEED")))
core.settings:set("time_speed", "0")
core.settings:set("mobs_spawn", "false")
-- Ground, not a tree: what digs as rock or soil
local function walkable(pos)
	local n = core.get_node(pos)
	local d = core.registered_nodes[n.name]
	local g = d and d.groups or {}
	return d and d.walkable and d.liquidtype == "none" and
			(g.cracky or g.crumbly or g.pickaxey or g.shovely) and not g.tree
end
-- The ground's top in a column, or nil for one not generated
local function top_of(x, z)
	for y = 60, -5, -1 do
		local n = core.get_node({x = x, y = y, z = z})
		if n.name == "ignore" then
			return nil
		end
		if walkable({x = x, y = y, z = z}) then
			return y
		end
	end
	return nil
end
-- Once the spawn's surroundings have been generated: at the join they
-- are not yet
local carve_at, joined = nil, nil
core.register_on_joinplayer(function(player)
	-- By the clock: a step's dtime here runs well behind the wall while
	-- the spawn generates
	carve_at, joined = core.get_us_time() + 15000000, player
	core.log("action", "hill: joined")
end)
core.register_on_mods_loaded(function()
core.register_globalstep(function(dtime)
	if carve_at == nil then
		return
	end
	if core.get_us_time() >= carve_at then
		carve_at = nil
		local player = joined
		if player then
			local ok, err = pcall(carve, player)
			if not ok then
				core.log("action", "hill: carve failed: " .. tostring(err))
			end
		end
	end
end)
end)
function carve(player)
	local p = player:get_pos()
	core.log("action", "hill: carving from " .. core.pos_to_string(vector.round(p)))
	local best, bx, bz = nil, nil, nil
	for x = math.floor(p.x) - 60, math.floor(p.x) + 60, 6 do
		for z = math.floor(p.z) - 60, math.floor(p.z) + 60, 6 do
			local t = top_of(x, z)
			-- A hill of dirt: sand is the game's own falling node
			local under = t and core.get_node({x = x, y = t - 2, z = z}).name
			if t and under and under:find("dirt", 1, true) and
					(best == nil or t > best) then
				best, bx, bz = t, x, z
			end
		end
	end
	if best == nil then
		core.log("action", "hill: no ground found")
		return
	end
	local air = core.get_content_id("air")
	-- Two nodes of ground left over the cavern: VoxeLibre's soil is a
	-- grass and two or three dirt, and dirt is what spans two and no more
	local p1 = {x = bx - 4, y = best - 5, z = bz - 4}
	local p2 = {x = bx + 4, y = best - 3, z = bz + 4}
	local vm = VoxelManip(p1, p2)
	local emin, emax = vm:get_emerged_area()
	local area = VoxelArea(emin, emax)
	local data = vm:get_data()
	for i in area:iterp(p1, p2) do
		data[i] = air
	end
	vm:set_data(data)
	vm:write_to_map()
	player:set_pos({x = bx, y = best - 5, z = bz})
	local roof = core.get_node({x = bx, y = best - 2, z = bz}).name
	core.log("action", string.format("hill: top %d at (%d, %d); cavern y=%d..%d, roof %s",
			best, bx, bz, best - 5, best - 3, roof))
end
-- The body's voxels as positions ([BODY_INTERACT]): region 0 starts at
-- y = 1000000; its (2, 1, 2) is in the first body's middle. Read,
-- dug with set_node, read again, eight seconds after the player's dig.
local probe_at = nil
core.register_on_dignode(function(pos, node, digger)
	core.log("action", "hill: dug " .. node.name .. " at " ..
			core.pos_to_string(pos))
	if digger and digger:is_player() and probe_at == nil then
		probe_at = core.get_us_time() + 8000000
	end
end)
core.register_on_mods_loaded(function()
	core.register_globalstep(function()
		if probe_at and core.get_us_time() >= probe_at then
			probe_at = nil
			local p = {x = 2, y = 1000001, z = 2}
			local before = core.get_node(p).name
			core.set_node(p, {name = "air"})
			core.log("action", "hill: region 0 (2, 1, 2) was " .. before ..
					", set to air, reads " .. core.get_node(p).name ..
					"; (2, 2, 2) reads " ..
					core.get_node({x = 2, y = 1000002, z = 2}).name)
		end
	end)
end)
LUA
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla_voxel_physics -P 29781 \
	-l "${LOG_LEVEL:-3}" > "$out/hill_srv.log" 2>&1 &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/hill_srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(check_pgrep buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
cat > "$out/cmds.txt" <<CMDS
delay 60000
look_dir 0 1 0.01
delay 300
event scan_volume 6 t0
mouse_down left
delay 4000
mouse_up left
delay 14000
event scan_volume 6 after
screenshot $out/hill_after.png
delay 500
quit
CMDS
bin/buildat -o launch_ui=launch_menu -s localhost:29781 -w 1280x720 -l "${CLIENT_LOG_LEVEL:-3}" \
	-c @"$out/cmds.txt" > "$out/hill_cli.log" 2>&1
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep "hill:\|voxel_ph" "$out/hill_srv.log" | grep -v "sim: \|fails: " | sed 's/.*I [a-z_]* *: //' | tail -12
grep "body\|voxel_physics" "$out/hill_cli.log" | sed 's/.*I [a-z_]* *: //' | tail -5
