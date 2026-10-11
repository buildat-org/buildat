-- Buildat: builtin/luanti/lua/buildat_api.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- core.buildat: what Buildat gives a mod beyond Luanti's API. Luanti has no
-- such table, so a mod tests for it and runs there without it
-- ([BUILDAT_WIELD_LIGHT]).
--
-- Dynamic lights: a light on an object, or at a place for a moment, drawn
-- by the clients as a scene light. Nothing is written into the map's light,
-- which is what a Luanti wield light mod does and what costs a relight of
-- the map round the player at every step.
--
-- What reaches the clients: the whole list, as "luanti:lights", when it
-- has changed and at most ten times a second, and to a player who has just
-- joined. Ten strings a light: "o" and the object id, or "p" and the place;
-- the place's x, y, z; the level; r, g, b (r below 0: the node lights'
-- colour); and for a place, the seconds it has left.
-- simplified: every light to every player; the client keeps the nearest

core.buildat = {}

local object_lights = {} -- object id -> {level, color}
local place_lights = {}  -- "x,y,z" -> {pos, level, left}
local dirty = false
local sent_to = {}       -- player name -> true once the list has reached it
local since = 0

local function level_of(level)
	level = math.floor(tonumber(level) or 0)
	return math.max(0, math.min(14, level))
end

-- set_object_light(obj, level[, color]): the object gives light of
-- Luanti's level 0..14, 0 off; color a ColorSpec, or the node lights'
-- colour. Kept while the object lives.
function core.buildat.set_object_light(obj, level, color)
	local id = core.__ref_id(obj)
	if not id or not obj:is_valid() then
		return
	end
	level = level_of(level)
	local c = color and core.colorspec_to_table and
			core.colorspec_to_table(color) or nil
	local old = object_lights[id]
	if level == 0 then
		if old then
			object_lights[id] = nil
			dirty = true
		end
		return
	end
	if old and old.level == level and old.c == (c and
			(c.r .. "," .. c.g .. "," .. c.b) or nil) then
		return
	end
	object_lights[id] = {level = level, color = c,
			c = c and (c.r .. "," .. c.g .. "," .. c.b) or nil}
	dirty = true
end

-- add_light(pos, level[, ttl]): a light at a place, gone after ttl seconds
-- (0.5) unless added again
function core.buildat.add_light(pos, level, ttl)
	level = level_of(level)
	if level == 0 or not pos then
		return
	end
	local p = vector.round(pos)
	local key = p.x .. "," .. p.y .. "," .. p.z
	ttl = tonumber(ttl) or 0.5
	local old = place_lights[key]
	-- A light added again before it went is news only to its end: the
	-- clients hear of that when their copy is about to go (the step)
	place_lights[key] = {pos = p, level = level, left = ttl,
			client_left = old and old.client_left or 0}
	if not old or old.level ~= level then
		dirty = true
	end
end

local function flat_list()
	local out = {}
	local function color(c)
		if c then
			out[#out + 1] = tostring(c.r / 255)
			out[#out + 1] = tostring(c.g / 255)
			out[#out + 1] = tostring(c.b / 255)
		else
			out[#out + 1] = "-1"
			out[#out + 1] = "-1"
			out[#out + 1] = "-1"
		end
	end
	for id, l in pairs(object_lights) do
		for _, v in ipairs({"o", tostring(id), "0", "0", "0", tostring(l.level)}) do
			out[#out + 1] = v
		end
		color(l.color)
		out[#out + 1] = "0"
	end
	for _, l in pairs(place_lights) do
		for _, v in ipairs({"p", "0", tostring(l.pos.x), tostring(l.pos.y),
				tostring(l.pos.z), tostring(l.level)}) do
			out[#out + 1] = v
		end
		color(nil)
		out[#out + 1] = string.format("%.2f", l.left)
	end
	return out
end

function core.__step_lights(dtime)
	for key, l in pairs(place_lights) do
		l.left = l.left - dtime
		l.client_left = l.client_left - dtime
		if l.left <= 0 then
			place_lights[key] = nil
		elseif l.client_left < 0.15 and l.left > l.client_left + 0.05 then
			dirty = true
		end
	end
	-- Gone with its object
	for id in pairs(object_lights) do
		if not core.object_refs[id] then
			object_lights[id] = nil
			dirty = true
		end
	end
	since = since + dtime
	if not __luanti_send_lights or since < 0.1 then
		return
	end
	local names = {}
	for _, player in ipairs(core.get_connected_players()) do
		names[#names + 1] = player:get_player_name()
	end
	local flat
	for _, name in ipairs(names) do
		if dirty or not sent_to[name] then
			if not flat then
				flat = flat_list()
				for _, l in pairs(place_lights) do
					l.client_left = l.left
				end
			end
			__luanti_send_lights(name, flat)
			sent_to[name] = true
		end
	end
	if flat or dirty then
		since = 0
	end
	dirty = false
	-- Who left hears it all again when back
	local here = {}
	for _, name in ipairs(names) do
		here[name] = true
	end
	for name in pairs(sent_to) do
		if not here[name] then
			sent_to[name] = nil
		end
	end
end

-- vim: set noet ts=4 sw=4:
