-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Is a VoxeLibre mob drawn as its model? ([OBJECT_MESH] step 0)
--
--   builtin/luanti/test/mobmesh.sh
--
-- A zombie, a villager and a cow four nodes in front of the player, with the
-- ground under them. What the log says is what each one's properties
-- are once mcl_mobs' on_activate has set them (the visual, the mesh, the
-- size, the textures) and what the client asked for; the shot says what
-- is drawn.
core.register_on_joinplayer(function(player)
	core.after(6, function()
		-- A stone platform in the sky over the spawn, so the stage is the
		-- same whatever the world put at the spawn; the player at its
		-- west end looking east at the mobs
		local p = player:get_pos()
		-- The first height over the spawn where the whole stage and three
		-- above it are air: a forest's canopy and a hill are what a fixed
		-- height ran into
		local base = {x = math.floor(p.x), y = math.floor(p.y) + 4, z = math.floor(p.z)}
		for y = base.y, base.y + 60 do
			local clear = true
			for dz = -6, 6 do
				for dx = -8, 6 do
					for dy = -1, 3 do
						if core.get_node({x = base.x + dx, y = y + dy,
								z = base.z + dz}).name ~= "air" then
							clear = false
						end
					end
				end
			end
			if clear then
				base.y = y
				break
			end
		end
		for dz = -6, 6 do
			for dx = -8, 6 do
				core.set_node({x = base.x + dx, y = base.y - 1, z = base.z + dz},
						{name = "mcl_core:stone"})
			end
		end
		player:set_pos({x = base.x - 6, y = base.y + 2.5, z = base.z})
		-- Facing east, as the drive will look: the turn is the line the
		-- client logs for the stage ("the server put the player at ...
		-- looking 90"), told apart from the spawn's placing
		player:set_look_horizontal(3 * math.pi / 2)
		-- Then from the zombie's front-left, close, for its depth
		core.after(16, function()
			player:set_pos({x = base.x - 2.5, y = base.y + 1.5, z = base.z - 4})
		end)
		local objs = {}
		for i, name in ipairs({"mobs_mc:zombie", "mobs_mc:villager", "mobs_mc:cow"}) do
			local at = {x = base.x, y = base.y + 1, z = base.z + (i - 2) * 3}
			objs[name] = core.add_entity(at, name)
			-- Standing still, harmless and not burning, so the shots are of
			-- the model and not of the fight (mcl_mobs' own fields)
			local le = objs[name] and objs[name]:get_luaentity()
			if le then
				le.walk_chance = 0
				le.passive = true
				le.ignited_by_sunlight = false
				le.sunlight_damage = 0
			end
			core.log("action", "mobmesh: " .. name .. " at " .. core.pos_to_string(at) ..
					(objs[name] and "" or " -- add_entity answered nil"))
		end
		core.after(2, function()
			for name, obj in pairs(objs) do
				local pr = obj:get_properties() or {}
				local v = pr.visual_size or {}
				core.log("action", string.format(
						"mobmesh: %s visual=%s mesh=%s size=%s,%s,%s textures=%s",
						name, tostring(pr.visual), tostring(pr.mesh),
						tostring(v.x), tostring(v.y), tostring(v.z),
						table.concat(pr.textures or {}, ";")))
			end
		end)
	end)
end)
