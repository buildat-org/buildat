-- Buildat: extension/luanti_client/itemdef.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- What an item is, out of Luanti's ITEMDEF.
--
-- The packet is
--   u8 version | u16 count | count u16-string wrappers | u16 aliases | pairs
-- and each wrapper is one item definition. As with NODEDEF, only the front of
-- a wrapper has to be understood and the rest is dropped, which is what makes
-- this survive a server that knows a newer version.
--
-- What is here for is digging: how long a node takes to dig is the node's
-- groups against the wielded tool's capabilities, and the tool capabilities
-- are in here. The item with the empty name is the hand, which is what digs
-- when nothing is wielded.

local M = {}

-- ItemDefinition types, in Luanti's order
M.TYPE_NONE = 0
M.TYPE_NODE = 1
M.TYPE_CRAFT = 2
M.TYPE_TOOL = 3

local ITEMDEF_VERSION = 6

-- ToolCapabilities: what a tool can dig and how fast. groupcaps is keyed by a
-- node group name; times is keyed by the rating a node has in that group, and
-- the match has to be exact, which is Luanti's own rule.
local function read_tool_capabilities(serialize, data)
	local r = serialize.reader(data)
	local version = r:u8()
	if version < 4 then
		error("luanti_client/itemdef: ToolCapabilities version "..version)
	end
	local caps = {
		full_punch_interval = r:f32(),
		max_drop_level = r:s16(),
		groupcaps = {},
		damage_groups = {},
	}
	for _ = 1, r:u32() do
		local name = r:string()
		local cap = {uses = r:s16(), maxlevel = r:s16(), times = {}}
		for _ = 1, r:u32() do
			local rating = r:s16()
			cap.times[rating] = r:f32()
		end
		caps.groupcaps[name] = cap
	end
	for _ = 1, r:u32() do
		caps.damage_groups[r:string()] = r:s16()
	end
	if version >= 5 then
		caps.punch_attack_uses = r:u16()
	end
	return caps
end

-- An item's image: a name, and from protocol 51 on an animation after it
-- (ItemImageDef::serialize)
local function read_image(r, protocol)
	local name = r:string()
	if protocol >= 51 then
		r:animation()
	end
	return name
end

local function read_item(serialize, r, protocol)
	local version = r:u8()
	if version < ITEMDEF_VERSION then
		error("luanti_client/itemdef: ItemDefinition version "..version)
	end
	local def = {}
	def.type = r:u8()
	def.name = r:string()
	def.description = r:string()
	def.inventory_image = read_image(r, protocol)
	def.wield_image = read_image(r, protocol)
	r:skip(12) -- wield_scale
	def.stack_max = r:s16()
	def.usable = r:u8() ~= 0
	def.liquids_pointable = r:u8() ~= 0
	local caps = r:string()
	if caps ~= "" then
		def.tool_capabilities = read_tool_capabilities(serialize, caps)
	end
	def.groups = {}
	for _ = 1, r:u16() do
		local name = r:string()
		def.groups[name] = r:s16()
	end
	def.node_placement_prediction = r:string()
	-- Two sounds, each a name and three floats
	for _ = 1, 2 do
		r:string()
		r:skip(12)
	end
	-- How far this item reaches; a negative value means the game's default
	def.range = r:f32()
	-- The sounds of a swing at something and at nothing, past what is
	-- skipped to them ([DIG_SWING_SOUND]); an older server's item ends
	-- before, and has none
	pcall(function()
		r:string()  -- palette_image
		r:skip(4)   -- color
		read_image(r, protocol)  -- inventory_overlay
		read_image(r, protocol)  -- wield_overlay
		r:string()  -- short_description
		if protocol <= 43 then
			r:u8()  -- place_param2
		end
		for _, key in ipairs({"sound_use", "sound_use_air"}) do
			local sound = {name = r:string()}
			sound.gain = r:f32()
			sound.pitch = r:f32()
			r:f32()  -- fade
			def[key] = sound
		end
	end)
	return def
end

-- parse(serialize, data, log) -> {[name] = def}, count, {[name] = name}
--
-- data is the decompressed ITEMDEF payload. An item whose definition cannot
-- be read is left out rather than stopping the rest.
--
-- The definitions are keyed by the item's aliases as well as by its own
-- name: a game keeps the names it has renamed items away from and a server
-- hands out stacks under either. The third value is the aliases themselves,
-- for whatever wants to know that a name is one.
function M.parse(serialize, data, log, protocol)
	local r = serialize.reader(data)
	local version = r:u8()
	if version ~= 0 then
		error("luanti_client/itemdef: version "..version)
	end
	local count = r:u16()
	local items = {}
	local failed = 0
	for _ = 1, count do
		local wrapper = serialize.reader(r:string())
		local ok, def = pcall(read_item, serialize, wrapper, protocol)
		if ok then
			items[def.name] = def
		else
			failed = failed + 1
			if failed == 1 and log then
				log:warning("itemdef: could not read an item: "..
						tostring(def))
			end
		end
	end
	if failed > 0 and log then
		log:warning("itemdef: "..failed.." of "..count..
				" item definitions could not be read")
	end
	-- An alias is another name for an item, which a server uses as readily
	-- as the real one; the definition goes under both names so that nothing
	-- else has to know about them
	local aliases = {}
	local ok, err = pcall(function()
		for _ = 1, r:u16() do
			local name = r:string()
			local convert_to = r:string()
			aliases[name] = convert_to
			if items[convert_to] and not items[name] then
				items[name] = items[convert_to]
			end
		end
	end)
	if not ok and log then
		log:warning("itemdef: could not read the aliases: "..tostring(err))
	end
	return items, count, aliases
end

-- dig_time(node_groups, caps) -> seconds and the group it went by
-- (official's main_group, which a "__group" dig sound is named after), or
-- nil for a node these capabilities cannot dig
--
-- Luanti's getDigParams(), without the wear: the fastest group the tool has
-- that the node is rated in, with the level difference taken into account.
function M.dig_time(node_groups, caps)
	if not caps then
		return nil
	end
	-- dig_immediate is a group the game uses to say "no tool needed"
	if not caps.groupcaps.dig_immediate then
		local immediate = node_groups.dig_immediate
		if immediate == 2 then
			return 0.5, "dig_immediate"
		elseif immediate == 3 then
			return 0, "dig_immediate"
		end
	end
	local level = node_groups.level or 0
	local best, main = nil, nil
	for name, cap in pairs(caps.groupcaps) do
		local leveldiff = cap.maxlevel - level
		if leveldiff >= 0 then
			local rating = node_groups[name]
			local time = rating and cap.times[rating]
			if time then
				if leveldiff > 1 then
					time = time / leveldiff
				end
				if not best or time < best then
					best, main = time, name
				end
			end
		end
	end
	return best, main
end

return M
-- vim: set noet ts=4 sw=4:
