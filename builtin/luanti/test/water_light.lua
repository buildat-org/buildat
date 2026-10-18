-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [WATER_LIGHT]: a passage dug into the ground with a water run in it, lit
-- from a shaft, read a node at a time. The one probe the item asks for:
-- how far the sky's light travels along water and down through it.
--
-- Dug into real terrain rather than built in the air: a chamber carved out
-- of stone starts dark, which is what makes a light reading mean anything.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=water_light_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/water_light.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
-- The terrain this was written against: devtest's v7, which a new world
-- no longer gets by default (valleys)
core.settings:set("mg_name", "v7")
local LEN = 10
local DEPTH = 10
local base = nil

local function solid_top(x, z)
	for y = 80, -30, -1 do
		local n = core.get_node({x = x, y = y, z = z})
		if n.name ~= "air" and n.name ~= "ignore" then
			return y
		end
	end
	return nil
end

local function air(p) core.set_node(p, {name = "air"}) end
local function water(p) core.set_node(p, {name = "basenodes:water_source"}) end

local function build()
	local top = solid_top(base.x, base.z)
	if not top then
		core.log("action", "water_light: no ground under the spawn")
		return false
	end
	base.y = top - 14
	-- The shaft: air from the surface down to the passage
	for y = base.y, top + 1 do
		air({x = base.x, y = y, z = base.z})
	end
	-- The passage: water along +x under the stone, its far end away from
	-- the shaft. Carved as water, so nothing has to flow.
	for i = 0, LEN - 1 do
		water({x = base.x + i, y = base.y, z = base.z})
	end
	-- And a column of water straight down from under the shaft, which is
	-- the other half of the rule: official's sunlight goes down
	-- undiminished through what propagates it, and water is not that
	for d = 1, DEPTH do
		water({x = base.x, y = base.y - d, z = base.z})
	end
	-- The control beside it: the same shaft with nothing in it
	for y = base.y - DEPTH, top + 1 do
		air({x = base.x, y = y, z = base.z + 3})
	end
	return true
end

local function read(tag)
	local rows = {}
	local function row(label, p)
		local n = core.get_node(p)
		local sky = math.floor((n.param1 or 0) % 16)
		local lamp = math.floor((n.param1 or 0) / 16) % 16
		rows[#rows + 1] = string.format("%s=%s/%d/%d", label,
				(n.name or "?"):gsub("^[%w_]+:", ""), sky, lamp)
	end
	for i = 0, LEN - 1 do
		row("water" .. i, {x = base.x + i, y = base.y, z = base.z})
	end
	for d = 1, DEPTH do
		row("column" .. d, {x = base.x, y = base.y - d, z = base.z})
	end
	for d = 0, DEPTH do
		row("air" .. d, {x = base.x, y = base.y - d, z = base.z + 3})
	end
	local def = core.registered_nodes["basenodes:water_source"] or {}
	rows[#rows + 1] = "sunlight_propagates=" ..
			tostring(def.sunlight_propagates)
	local line = table.concat(rows, " ")
	core.log("action", "water_light: " .. tag .. " " .. line)
	return line
end

core.register_on_joinplayer(function(player)
	core.settings:set("time_speed", "0")
	core.set_timeofday(0.5)
	local p = player:get_pos()
	base = {x = math.floor(p.x) + 6, y = 0, z = math.floor(p.z) + 6}
	core.after(6, function()
		if not build() then
			core.chat_send_all("water_light: done")
			return
		end
		core.log("action", "water_light: built at " .. base.x .. "," ..
				base.y .. "," .. base.z)
		-- **Read until two agree, rather than twice and hope.** A
		-- section's relight is deferred and runs under a budget, and
		-- the water is still spreading for a while after it is placed
		-- -- so the two readings agreeing is what says the world has
		-- finished moving. Taking exactly two of them made that a race
		-- with the desk: on a busy one the second still caught water
		-- flowing into the shaft and the run failed with the light
		-- blamed for it (2026-09-24). Up to eight tries, ten seconds
		-- apart; a light that never settles still fails, which is the
		-- assertion this was always making.
		local last, tries = nil, 0
		local function settle()
			tries = tries + 1
			local now = read("try" .. tries)
			-- **All dark is not a reading** (2026-09-24, the first
			-- container run of the quick tier): on a machine slow
			-- enough that nothing has been lit yet, two zero readings
			-- agree with each other and the check fails with the light
			-- blamed for a world that had not got there. The shaft is
			-- open to the sky by construction, so a zero at the top is
			-- the world not being ready rather than an answer.
			if now:match("water0=%d+/0") then
				last = nil
				if tries < 8 then
					core.after(10, settle)
					return
				end
			end
			if last and now == last then
				core.log("action", "water_light: settled after " ..
						tries .. " readings")
				core.log("action", "water_light: first " .. now)
				core.log("action", "water_light: second " .. now)
				core.log("action", "water_light: done")
				core.chat_send_all("water_light: done")
				return
			end
			last = now
			if tries >= 8 then
				core.log("action", "water_light: never settled")
				core.log("action", "water_light: first " ..
						tostring(last))
				core.log("action", "water_light: second " .. now .. " x")
				core.log("action", "water_light: done")
				core.chat_send_all("water_light: done")
				return
			end
			core.after(10, settle)
		end
		core.after(12, settle)
	end)
end)
