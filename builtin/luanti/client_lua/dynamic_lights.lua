-- Buildat: builtin/luanti/client_lua/dynamic_lights.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The module's client half: the dynamic lights. Run by module.lua with its
-- M and what this reads of its own ([SPLITS]: moved out as it was):
--   dyn = <this file>(M, {object_nodes, sky_light, light_object(have, x,
--   y, z), scene() -> the objects' scene or nil})
-- dyn.lamp(x, y, z, lamp): the lamp level there with the lights in it.
-- Puts M.update_lights(dtime, eye) in M.
local log = buildat.Logger("luanti")
local magic = require("buildat/extension/urho3d")
local cereal = require("buildat/extension/cereal")

return function(M, o)
	local L = {}
	-- The dynamic lights drawn this frame, {x, y, z, level}, kept by
	-- M.update_lights(): an object and the hand are lit by them as by the
	-- map's lamp nibble at their level less the distance ([WIELD_LIGHT_LOOK])
	local dynamic_now = {}
	function L.lamp(x, y, z, lamp)
		for _, l in ipairs(dynamic_now) do
			local dx, dy, dz = l.x - x, l.y - y, l.z - z
			lamp = math.max(lamp, l.level - math.sqrt(dx * dx + dy * dy + dz * dz))
		end
		return lamp
	end
	-- Whether a place is within a dynamic light's reach, or just out of it
	local function near_dynamic(x, y, z)
		for _, l in ipairs(dynamic_now) do
			local dx, dy, dz = l.x - x, l.y - y, l.z - z
			if dx * dx + dy * dy + dz * dz < (l.level + 2) ^ 2 then
				return true
			end
		end
		return false
	end


	--
	-- The dynamic lights
	--
	-- core.buildat's lights (builtin/luanti/lua/buildat_api.lua): a light on an
	-- object, a held torch being one on the player, or at a place for a moment.
	-- Scene point lights, nothing in the map's light ([BUILDAT_WIELD_LIGHT]).
	--
	-- The range is the light's level in nodes and the falloff over it the
	-- map's from a placed torch ([WIELD_LIGHT_LOOK]): res/light_ramp.png the
	-- pbr lamp term's curve, res/light_ramp_parity.png the parity modes' --
	-- Luanti's light curve, which on the screen is near linear in the level,
	-- (level - 1.5) / 11.5 (a VoxeLibre wall at 1, 4, 8 and 12 nodes from a
	-- torch read 1, .70, .39 and .04 of the first, 2026-10-12), its peak at
	-- 0.81 of a white light's (PARITY_LAMP).
	-- simplified: one curve, a level 14 light's, stretched to every level;
	-- a lower level is dimmed as well. The map's own light adds under it
	-- rather than the brighter being taken, as Luanti does.
	local PARITY_LAMP = 0.81

	local MAX_DYNAMIC_LIGHTS = 8
	-- {kind, id, x, y, z, level, r, g, b, until}, as the server last said
	local dynamic_lights = {}
	local dynamic_pool = {}
	local dynamic_time = 0

	buildat.sub_packet("luanti:lights", function(data)
		local v = cereal.binary_input(data, {"array", "string"})
		dynamic_lights = {}
		for i = 1, #v - 9, 10 do
			local ttl = tonumber(v[i + 9]) or 0
			dynamic_lights[#dynamic_lights + 1] = {kind = v[i], id = v[i + 1],
				x = tonumber(v[i + 2]) or 0, y = tonumber(v[i + 3]) or 0,
				z = tonumber(v[i + 4]) or 0, level = tonumber(v[i + 5]) or 0,
				r = tonumber(v[i + 6]) or -1, g = tonumber(v[i + 7]) or -1,
				b = tonumber(v[i + 8]) or -1,
				ends = v[i] == "p" and dynamic_time + ttl or nil}
		end
		local said = {}
		for _, l in ipairs(dynamic_lights) do
			said[#said + 1] = l.kind .. " " .. (l.kind == "o" and
					(l.id == M.self_id and "self" or l.id) or
					(l.x .. "," .. l.y .. "," .. l.z)) .. " " .. l.level
		end
		log:info("luanti:lights: " .. #dynamic_lights .. ": " ..
				table.concat(said, "; "))
	end)

	-- Where a light is now: an object's drawn node, the player's own light at
	-- the hand (eye, the player's eye), a place's middle
	local function dynamic_light_pos(l, eye)
		if l.kind == "p" then
			return magic.Vector3(l.x, l.y, l.z)
		end
		if l.id == M.self_id and eye then
			return magic.Vector3(eye.x, eye.y - 0.4, eye.z)
		end
		local have = o.object_nodes[l.id]
		if have and have.node then
			local p = have.node.position
			return magic.Vector3(p.x, p.y + 0.5, p.z)
		end
		return nil
	end

	function M.update_lights(dtime, eye)
		dynamic_time = dynamic_time + dtime
		local best = {}
		for _, l in ipairs(dynamic_lights) do
			if not l.ends or l.ends > dynamic_time then
				local p = dynamic_light_pos(l, eye)
				if p then
					local dx, dy, dz = p.x - eye.x, p.y - eye.y, p.z - eye.z
					best[#best + 1] = {d = dx * dx + dy * dy + dz * dz, p = p, l = l}
				end
			end
		end
		table.sort(best, function(a, b) return a.d < b.d end)
		dynamic_now = {}
		for i = 1, math.max(#dynamic_pool, math.min(#best, MAX_DYNAMIC_LIGHTS)) do
			local entry, held = best[i], dynamic_pool[i]
			if entry and not held and o.scene() then
				local node = o.scene():CreateChild("dynamic_light_" .. i)
				held = {node = node, light = node:CreateComponent("Light")}
				held.light.lightType = magic.LIGHT_POINT
				held.light.castShadows = false
				-- The map's light is diffuse; a highlight on a texture looks wrong
				held.light.specularIntensity = 0
				dynamic_pool[i] = held
			end
			if held then
				if entry then
					local l, u = entry.l, M.light_units
					held.node.position = entry.p
					held.light.range = l.level
					dynamic_now[#dynamic_now + 1] = {x = entry.p.x, y = entry.p.y,
							z = entry.p.z, level = l.level}
					-- On the pbr path the colour the baked lamp term has at a
					-- full lamp: that is vVertexLight*albedo, and a point light's
					-- diffuse is albedo/pi (PBRVoxel.glsl). Without it, the
					-- old path's light added on top of the baked one, kept low.
					-- A light of no colour of its own is the map's lamp: under
					-- pbr the lamp unit's, else white as the parity modes'
					-- baked lamp light is. A level under 13 dimmer, as a placed
					-- one's light is at the same nibble.
					local r, g, b = 1, 1, 1
					local k = PARITY_LAMP * math.min(1, (l.level - 1.5) / 11.5)
					if l.r >= 0 then
						r, g, b = l.r, l.g, l.b
					end
					if u then
						k = o.sky_light.lamp_curve(l.level) * math.pi
						if l.r < 0 then
							r, g, b = u.lamp.r, u.lamp.g, u.lamp.b
						else
							k = k * math.max(u.lamp.r, u.lamp.g, u.lamp.b)
						end
					end
					local key = r * k .. "," .. g * k .. "," .. b * k ..
							(u and "" or ",parity")
					if key ~= held.color then
						held.light.brightness = 1
						held.light.color = magic.Color(r * k, g * k, b * k)
						held.light.rampTexture = magic.cache:GetResource("Texture2D",
								u and "luanti_client/res/light_ramp.png" or
								"luanti_client/res/light_ramp_parity.png")
					end
					held.color = key
					held.node.enabled = true
				else
					held.node.enabled = false
				end
			end
		end
		-- The objects near a light lit by it every frame, and once more as one
		-- leaves its reach: the light moves with its holder, and a still
		-- object's packets stop coming
		for id, have in pairs(o.object_nodes) do
			if have.node and id ~= M.self_id and
					(have.dyn_lit or #dynamic_now > 0) then
				local p = have.node.position
				local near = near_dynamic(p.x, p.y, p.z)
				if near or have.dyn_lit then
					have.dyn_lit = near
					o.light_object(have, p.x, p.y, p.z)
				end
			end
		end
	end

	return L
end
-- vim: set noet ts=4 sw=4:
