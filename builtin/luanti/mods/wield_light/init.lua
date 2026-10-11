-- Buildat: builtin/luanti/mods/wield_light/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- [BUILDAT_WIELD_LIGHT] A player's light is the brightest light_source of
-- the wielded item, the offhand's and the worn ones', given through
-- core.buildat.set_object_light: a light the clients draw at the player,
-- nothing written into the map. The other wield lights a world may have
-- are made to give theirs the same way (the table below); the luanti
-- module's modloader turns vl_wieldlight's and cozylights' off by their
-- settings before they load.

if not core.buildat then
	core.log("warning", "wield_light: no core.buildat, so nothing to do " ..
			"(it is for Buildat)")
	return
end
local set_object_light, add_light = core.buildat.set_object_light,
		core.buildat.add_light

local function level_of(name)
	local def = core.registered_items[name]
	return def and tonumber(def.light_source) or 0
end

local function list_max(inv, list, best)
	for _, stack in ipairs(inv:get_list(list) or {}) do
		best = math.max(best, level_of(stack:get_name()))
	end
	return best
end

-- Light that other mods give an object through wielded_light's API:
-- object -> {category -> level}
local extra = {}
local function extra_of(obj)
	local best = 0
	for _, level in pairs(extra[obj] or {}) do
		best = math.max(best, level)
	end
	return best
end

local nodecore_glow = core.global_exists("nodecore") and nodecore.dynamic_light_add
local function player_level(player)
	local inv = player:get_inventory()
	-- NodeCore has no wielded item to speak of: anything in the inventory
	-- lights the player, as its own player light does
	if nodecore_glow then
		return list_max(inv, "main", 0)
	end
	local best = level_of(player:get_wielded_item():get_name())
	if core.global_exists("mcl_offhand") and mcl_offhand.get_offhand then
		best = math.max(best, level_of(mcl_offhand.get_offhand(player):get_name()))
	else
		best = list_max(inv, "offhand", best)
	end
	-- 3d_armor and VoxeLibre keep what is worn in the player's "armor"
	return list_max(inv, "armor", best)
end

local wait = 0
core.register_globalstep(function(dtime)
	wait = wait - dtime
	if wait > 0 then
		return
	end
	wait = 0.1
	for _, player in ipairs(core.get_connected_players()) do
		-- set_object_light sends only a change
		set_object_light(player, math.max(player_level(player), extra_of(player)))
	end
	for obj in pairs(extra) do
		if not obj:is_valid() then
			extra[obj] = nil
		elseif not obj:is_player() then
			set_object_light(obj, extra_of(obj))
		end
	end
end)

-- Mods that only put light-giving nodes where the player is: their nodes
-- give no light, so placing them changes nothing in the map's light, and
-- the mod itself and what depends on it keep running
local dark_nodes = {
	"^mcl_wieldlight:light_",
	"^illumination:light_",
	"^tph_wielditem:light_",
	"^nc_api_active:light%d",
}
local dark = {}
for name, def in pairs(core.registered_nodes) do
	for _, pattern in ipairs(dark_nodes) do
		if name:find(pattern) and (def.light_source or 0) > 0 then
			dark[#dark + 1] = name
		end
	end
end
for _, name in ipairs(dark) do
	core.override_item(name, {light_source = 0})
end

-- wielded_light (bell07): its API kept, so its per-item levels and the
-- mods built on it keep working; what it tracks becomes an object light
if core.global_exists("wielded_light") and wielded_light.track_user_entity then
	local function track(obj, cat, item)
		if not obj or not obj:is_valid() then
			return
		end
		extra[obj] = extra[obj] or {}
		extra[obj][cat or ""] = wielded_light.get_light_def(item)
	end
	wielded_light.track_user_entity = track
	wielded_light.track_item_entity = track
	if wielded_light.update_light_by_item then
		wielded_light.update_light_by_item = function(item, pos)
			add_light(pos, (wielded_light.get_light_def(item)))
		end
	end
	if wielded_light.update_light then
		wielded_light.update_light = function(pos, level)
			add_light(pos, level)
		end
	end
end

-- NodeCore: its lights at a place (a torch, an item stack on show, a
-- climbing spot) are add_light's, kept while the caller's check says so
if nodecore_glow then
	local checks = {} -- "x,y,z" -> {pos, level, check}
	nodecore.dynamic_light_add = function(pos, level, check)
		if not pos or not level or level < 1 then
			return
		end
		pos = vector.round(pos)
		add_light(pos, level, 0.3)
		checks[core.pos_to_string(pos)] = check and
				{pos = pos, level = level, check = check} or nil
		return true
	end
	local since = 0
	core.register_globalstep(function(dtime)
		since = since + dtime
		if since < 0.25 then
			return
		end
		since = 0
		for key, c in pairs(checks) do
			if c.check() then
				add_light(c.pos, c.level, 0.3)
			else
				checks[key] = nil
			end
		end
	end)
end

-- vim: set noet ts=4 sw=4:
