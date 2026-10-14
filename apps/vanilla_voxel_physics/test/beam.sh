#!/bin/bash
# [VOXEL_PHYSICS_SAMPLE]: a beam of dirt on one pillar, the pillar's top
# dug by the client -- the beam comes off as one body and falls; then the
# client looks at the fallen beam, digs a voxel of it and places a dirt on
# it, by their region positions ([BODY_INTERACT]). The server's body
# lines, where the body node ends up, the dig and the place on it are the
# reading; the log is under local/voxel_physics/.
#
#   GAME=mineclone2 apps/vanilla_voxel_physics/test/beam.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
GAME="${GAME:-mineclone2}"
out="$here/local/voxel_physics"
mkdir -p "$out"
save="buildat_test_beam"
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla_voxel_physics/saves/$save"
cat > "$out/fixture.lua" <<'LUA'
-- At the supported floor (y <= -60 holds by rule), so the platform stands
local ORIGIN = {x = 0, y = -61, z = 0}
core.settings:set("time_speed", "0")
core.settings:set("mobs_spawn", "false")
local function node_named(word)
	local found = {}
	for name, def in pairs(core.registered_nodes) do
		if name:find(word, 1, true) and not name:find("with", 1, true)
				and def.drawtype == "normal" then
			found[#found + 1] = name
		end
	end
	table.sort(found)
	return found[1]
end
local dirt = nil
core.register_on_mods_loaded(function()
	dirt = node_named("dirt")
end)
core.register_on_joinplayer(function(player)
	local air = core.get_content_id("air")
	local cid = core.get_content_id(dirt)
	local p1 = vector.subtract(ORIGIN, 6)
	local p2 = vector.add(ORIGIN, 8)
	local vm = VoxelManip(p1, p2)
	local emin, emax = vm:get_emerged_area()
	local area = VoxelArea(emin, emax)
	local data = vm:get_data()
	for i in area:iterp(p1, p2) do
		data[i] = air
	end
	-- The platform, the pillar at (2, *, 2) and the beam over it
	for x = -4, 6 do
		for z = -4, 6 do
			data[area:index(ORIGIN.x + x, ORIGIN.y, ORIGIN.z + z)] = cid
		end
	end
	for y = 1, 3 do
		data[area:index(ORIGIN.x + 2, ORIGIN.y + y, ORIGIN.z + 2)] = cid
	end
	for x = -1, 5 do
		data[area:index(ORIGIN.x + x, ORIGIN.y + 4, ORIGIN.z + 2)] = cid
	end
	vm:set_data(data)
	vm:write_to_map()
	player:set_pos({x = ORIGIN.x, y = ORIGIN.y + 1, z = ORIGIN.z})
	-- Dirt in hand, for the place on the fallen beam ([BODY_INTERACT])
	player:get_inventory():set_stack("main", 1, dirt .. " 10")
	player:set_wield_index(1)
	core.log("action", "beam: stamped with " .. dirt)
end)
-- Where a body's dig dropped its item ([BODY_INTERACT]): in the world by
-- the body, not a million nodes up
local report_at = nil
core.register_on_dignode(function(pos, node, digger)
	core.log("action", "beam: dug " .. node.name .. " at " ..
			core.pos_to_string(pos))
	if pos.y >= 1000000 then
		report_at = core.get_us_time() + 1500000
	end
end)
core.register_on_mods_loaded(function()
	core.register_globalstep(function()
		if report_at and core.get_us_time() >= report_at then
			report_at = nil
			-- A region read over the body ([BODY_INTERACT]): the box of
			-- region 0, and a VoxelManip of it that puts one more air in
			local found = core.find_nodes_in_area({x = 0, y = 1000000, z = 0},
					{x = 20, y = 1000020, z = 20}, {dirt})
			core.log("action", "beam: region 0 holds " .. #found .. " " .. dirt)
			if #found > 0 then
				local p1, p2 = found[1], found[1]
				local vm = VoxelManip(p1, p2)
				local data = vm:get_data()
				core.log("action", "beam: vmanip reads " ..
						core.get_name_from_content_id(data[1]) .. " at " ..
						core.pos_to_string(found[1]))
				data[1] = core.get_content_id("air")
				vm:set_data(data)
				vm:write_to_map()
				core.log("action", "beam: after the vmanip write it reads " ..
						core.get_node(found[1]).name)
			end
			for _, obj in ipairs(core.get_objects_inside_radius(ORIGIN, 12)) do
				local e = obj:get_luaentity()
				if e and e.name == "__builtin:item" then
					core.log("action", "beam: item " .. e.itemstring .. " at " ..
							core.pos_to_string(vector.round(obj:get_pos())))
				end
			end
		end
	end)
end)
LUA
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla_voxel_physics -P 29780 \
	-l "${LOG_LEVEL:-4}" > "$out/srv.log" 2>&1 &
for i in $(seq 1 400); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
sleep 5
srv=$(check_pgrep buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
cat > "$out/cmds.txt" <<CMDS
wait_log 60000 the server put the player
wait_log 60000 scene, 0 undrawn within 2
delay 2000
look_dir 2 0.5 2
delay 300
event scan_volume 6 t0
mouse_down left
delay 2000
mouse_up left
delay 8000
event scan_volume 6 after
screenshot $out/after.png
look_dir -1 -0.1 -0.3
delay 1000
screenshot $out/body.png
event look_body
delay 500
event scan
mouse_click right
delay 2000
screenshot $out/body_placed.png
mouse_down left
delay 2500
mouse_up left
delay 2000
screenshot $out/body_dug.png
delay 500
quit
CMDS
bin/buildat -o launch_ui=launch_menu -s localhost:29780 -w 1280x720 -l "${CLIENT_LOG_LEVEL:-3}" \
	-c @"$out/cmds.txt" > "$out/cli.log" 2>&1
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
grep "beam:\|voxel_ph" "$out/srv.log" | grep -v "sim: " | sed 's/.*I [a-z_]* *: //' | tail -16
# The dig on the body ([BODY_INTERACT]): the client points at the fallen
# beam and digs one of its voxels by its region position
grep "pointing at\|dug (" "$out/cli.log" | tail -3 | sed 's/.*I [a-z_]* *: //'
grep "region\|rebuilt\|places node" "$out/srv.log" | sed 's/.*[IV] [a-z_]* *: //' | tail -5
grep "body\|voxel_physics" "$out/cli.log" | sed 's/.*I [a-z_]* *: //' | tail -5
