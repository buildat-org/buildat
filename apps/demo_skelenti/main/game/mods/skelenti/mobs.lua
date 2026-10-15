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
-- a place the sun never reaches and no torch lights -- or on any floor
-- where the danger d is 0.5 or more (main.cpp's DAYLIGHT_DANGER)
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
				elseif (a.d or 0) >= 0.5 or
						core.get_node_light(p, 0.5) <= 3 and
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

-- **The danger of a place**, as main.cpp's danger() works it out, for the
-- mapgen here: main.cpp hands over the world's salt (skelenti_salt) and
-- the danger at three places, which must come out the same here
local salt
local function mul32(a, b)
	-- a * b mod 2^32 without passing 2^53: a in halves
	local hi, lo = math.floor(a / 65536), a % 65536
	return ((hi * b) % 65536 * 65536 + lo * b) % 4294967296
end
local function hash(a, b, k)
	local v = bit.bxor(mul32(a % 4294967296, 73856093),
			mul32(b % 4294967296, 19349663), k)
	v = v % 4294967296
	v = bit.bxor(v, bit.rshift(v, 13)) % 4294967296
	v = mul32(v, 0x5bd1e995)
	v = bit.bxor(v, bit.rshift(v, 15)) % 4294967296
	return (v % 65536) / 65535
end
local function danger(x, z)
	local C = 80
	local ix, iz = math.floor(x / C), math.floor(z / C)
	local function smooth(t) return t * t * (3 - 2 * t) end
	local tx, tz = smooth(x / C - ix), smooth(z / C - iz)
	local function h(a, b) return hash(a, b, salt) end
	local v = (h(ix, iz) * (1 - tx) + h(ix + 1, iz) * tx) * (1 - tz) +
			(h(ix, iz + 1) * (1 - tx) + h(ix + 1, iz + 1) * tx) * tz
	return math.min(1, math.max(0, (v - 0.3) / 0.6))
end

-- {salt, at = {{x, z, d}, ...}} -> true, or nil and why
function core.skelenti_salt(a)
	salt = a.salt
	for _, p in ipairs(a.at or {}) do
		if math.abs(danger(p[1], p[2]) - p[3]) > 0.001 then
			salt = nil
			return {"the danger at " .. p[1] .. "," .. p[2] .. " is " ..
					danger(p[1], p[2]) .. " here, " .. p[3] .. " in main.cpp"}
		end
	end
	return true
end

-- **Bones piled in the danger zone** (user, 2026-10-15): on the ground
-- of a column now and then, more often the higher the danger, a stack of
-- bone blocks with a skull, two or a bone on top, or one of those alone.
-- simplified: a chunk made before main.cpp's salt arrives gets none.
local PILE_FROM = 0.3
core.register_on_generated(function(minp, maxp)
	if not salt then
		return
	end
	local vm, emin, emax = core.get_mapgen_object("voxelmanip")
	local hm = core.get_mapgen_object("heightmap")
	if not vm or not hm then
		return
	end
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local data, p2 = vm:get_data(), vm:get_param2_data()
	local id = core.get_content_id
	local AIR, BLOCK = id("air"), id("skelenti:bone_block")
	local TOPS = {id("skelenti:skull"), id("skelenti:skulls"),
		id("skelenti:bone_lying")}
	local ground = {[id("skelenti:grass")] = true,
		[id("skelenti:dirt")] = true, [id("skelenti:sand")] = true}
	local sx, n = maxp.x - minp.x + 1, 0
	for z = minp.z, maxp.z do
		for x = minp.x, maxp.x do
			local d = danger(x, z)
			local r = hash(x, z, salt + 7)
			local y = hm[(z - minp.z) * sx + (x - minp.x) + 1]
			if d > PILE_FROM and r < 0.15 * ((d - PILE_FROM) /
					(1 - PILE_FROM)) ^ 1.5 and y and y >= minp.y and
					y + 6 <= maxp.y and ground[data[area:index(x, y, z)]] then
				-- r below the chance spread anew: the height and the top
				local q = hash(z, x, salt + 13)
				local height = math.floor(q * q * (1 + 5 * d))
				local top = 1 + math.floor(hash(x + z, x - z, salt) * 4)
				for i = 1, height + 1 do
					local vi = area:index(x, y + i, z)
					if data[vi] ~= AIR then
						break
					end
					if i <= height then
						data[vi] = BLOCK
					elseif TOPS[top] then
						data[vi], p2[vi] = TOPS[top], math.floor(q * 97) % 4
					end
				end
				n = n + 1
			end
		end
	end
	if n > 0 then
		vm:set_data(data)
		vm:set_param2_data(p2)
		vm:write_to_map()
	end
end)
