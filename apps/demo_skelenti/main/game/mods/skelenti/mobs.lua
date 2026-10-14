-- Buildat: apps/demo_skelenti/main/game/mods/skelenti/mobs.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The game's side of the mobs, which are the app's (main/main.cpp): what
-- its C++ asks the world through the bridge (call_json), and nothing
-- else. A mob's place is its feet; a node at integer y spans y-0.5 to
-- y+0.5, so feet on the node at y are at y+0.5.

local function round(v) return math.floor(v + 0.5) end

-- An unloaded node is a wall: nothing walks into the unknown
local function walkable(x, y, z)
	local n = core.get_node_or_nil({x = x, y = y, z = z})
	if not n then
		return true
	end
	local d = core.registered_nodes[n.name]
	return not d or d.walkable ~= false
end

local function water(x, y, z)
	local n = core.get_node_or_nil({x = x, y = y, z = z})
	return n and core.get_item_group(n.name, "water") > 0 or false
end

-- The sky's light by the hour: 15 under open sky at noon, 0 at night
-- simplified: the hour as day or night, not a ramp; the module's
-- get_natural_light() reads the sky nibble and not the hour
local function sun(x, y, z)
	local tod = core.get_timeofday()
	if tod < 0.23 or tod > 0.77 then
		return 0
	end
	return core.get_natural_light({x = x, y = y, z = z}) or 0
end

-- Where something h nodes tall can stand in the column at x, z, from a
-- step up to three down from feet y: {feet y or false, the sun's light
-- there now, whether it is in water}; false and "unloaded" when the
-- column is not all there
local function ground(x, y, z, h)
	local cx, cy, cz = round(x), round(y), round(z)
	for c = cy - 4, cy + h + 1 do
		if not core.get_node_or_nil({x = cx, y = c, z = cz}) then
			return {false, 0, false, "unloaded"}
		end
	end
	for c = cy + 1, cy - 3, -1 do
		if walkable(cx, c - 1, cz) then
			local free = true
			for i = 0, h - 1 do
				if walkable(cx, c + i, cz) then
					free = false
					break
				end
			end
			if free then
				return {c - 0.5, sun(cx, c, cz), water(cx, c, cz)}
			end
		end
	end
	return {false, 0, false}
end

-- {g = {{x, y, z, h}, ...}, p = {{x, y, z}, ...}} -> {g = {ground(), ...},
-- p = {solid, ...}}: the ground under each walker, whether each point
-- (an arrow) is in a solid node
function core.skelenti_sense(a)
	local g, p = {}, {}
	for i, q in ipairs(a.g or {}) do
		g[i] = ground(q[1], q[2], q[3], q[4])
	end
	for i, q in ipairs(a.p or {}) do
		p[i] = walkable(round(q[1]), round(q[2]), round(q[3]))
	end
	return {g = g, p = p}
end

-- {{n, x, y, z, hp}, ...}, the feet
function core.skelenti_players()
	local out = {}
	for _, pl in ipairs(core.get_connected_players()) do
		local pos = pl:get_pos()
		out[#out + 1] = {pl:get_player_name(), pos.x, pos.y, pos.z,
				pl:get_hp()}
	end
	return out
end

-- A place for a kind to spawn near x, y, z, 12 to 24 nodes off, or nil:
-- a boar on grass under the open sky by day, a skeleton on the floor of
-- a place the sun never reaches and no torch lights
function core.skelenti_spawn_spot(a)
	local tod = core.get_timeofday()
	if a.kind == "boar" and (tod < 0.25 or tod > 0.75) then
		return nil
	end
	for _ = 1, 8 do
		local r, t = 12 + math.random() * 12, math.random() * 2 * math.pi
		local x, z = round(a.x + r * math.cos(t)), round(a.z + r * math.sin(t))
		local y0 = round(a.y)
		for y = y0 + 12, y0 - 16, -1 do
			local below = core.get_node_or_nil({x = x, y = y - 1, z = z})
			local p = {x = x, y = y, z = z}
			if below and not walkable(x, y, z) and not walkable(x, y + 1, z)
					and not water(x, y, z) and walkable(x, y - 1, z) then
				if a.kind == "boar" then
					if below.name == "skelenti:grass" and
							core.get_node_light(p, 0.5) == 15 then
						return {x, y - 0.5, z}
					end
				elseif core.get_node_light(p, 0.5) <= 3 and
						(core.get_node_light(p) or 0) <= 4 then
					return {x, y - 0.5, z}
				end
			end
		end
	end
	return nil
end

-- {n, hp} -> the player's hp after losing that much, or nil
function core.skelenti_hurt(a)
	local pl = core.get_player_by_name(a.n)
	if not pl or pl:get_hp() <= 0 then
		return nil
	end
	pl:set_hp(pl:get_hp() - a.hp, {type = "punch"})
	return pl:get_hp()
end

-- {n} -> what the player's hit does: the wielded item's fleshy damage,
-- a sword's or tool's wear taken for it
function core.skelenti_hit(a)
	local pl = core.get_player_by_name(a.n)
	if not pl then
		return nil
	end
	local stack = pl:get_wielded_item()
	local caps = stack:get_tool_capabilities()
	local dmg = caps and caps.damage_groups and caps.damage_groups.fleshy or 1
	if core.registered_tools[stack:get_name()] then
		stack:add_wear(65535 / (core.get_item_group(stack:get_name(),
				"sword") > 0 and 200 or 100))
		pl:set_wielded_item(stack)
	end
	return dmg
end

-- {x, y, z, items = {"skelenti:bone 2", ...}}: dropped where a mob died
function core.skelenti_drop(a)
	for _, s in ipairs(a.items or {}) do
		core.add_item({x = a.x, y = a.y + 0.5, z = a.z}, s)
	end
end

-- {n, d}: the fog of a place's danger, 0 to 1 (main.cpp's danger()): the
-- viewing range down from the client's own to 40 nodes, the fade
-- starting nearer
function core.skelenti_fog(a)
	local pl = core.get_player_by_name(a.n)
	if not pl then
		return nil
	end
	if a.d < 0.05 then
		pl:set_sky({fog = {fog_distance = -1, fog_start = 0.7}})
	else
		pl:set_sky({fog = {fog_distance = math.floor(200 - 160 * a.d),
				fog_start = 0.7 - 0.6 * a.d}})
	end
	return true
end
