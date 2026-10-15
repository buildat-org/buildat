-- Buildat: apps/demo_skelenti/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- skelenti's client: the module's client loop, with the HUD and the
-- inventory (ui.lua) and the mobs (mobs.lua) Buildat's own, on its stages,
-- and Escape's pause menu (pause.lua).
-- The game turns the module's own hotbar, bars and crosshair off with its
-- HUD flags, and its forms are names the form stage hands to ui.lua.
local luanti = require("buildat/module/luanti")
local log = buildat.Logger("skelenti")

local function load(name)
	local ok, err, m = buildat.run_script_file(name)
	assert(ok and m, name .. ": " .. tostring(err))
	return m
end

local keys = luanti.run_client({log = "skelenti",
		pause = load("main/pause.lua")})
local ui = load("main/ui.lua")
keys.stage.form = ui.form
local mobs = load("main/mobs.lua")
-- The sound effects, made once at startup: the game's (luanti's media
-- names) and the mobs'
local sounds = load("main/sounds.lua")
local t0 = buildat.get_time_us()
local made = sounds.make(require("buildat/extension/blip"), luanti)
log:info(string.format("skelenti: %d sounds made in %.0f ms", made,
		(buildat.get_time_us() - t0) / 1000))
mobs.sounds = sounds
keys.stage.point = mobs.point
-- The music, by the place: a cave (little sky at the head), the danger
-- zone, or sunrise; none otherwise. A mood holds for 2 s before the
-- music follows it, so the edge of a cave does not flicker it.
local music = load("main/music.lua")
music.new(require("buildat/extension/urho3d"), log,
		require("buildat/extension/replicate").main_scene)
local field
-- since: seconds since the world was taken; the light settles in the first
-- few, and a cave is read off it
local mood = {now = nil, seen = nil, held = 0, since = 0}
local function danger_at(x, z)
	if not field then
		return 0
	end
	local i = math.floor((x - field.x0) / field.cell)
	local j = math.floor((z - field.z0) / field.cell)
	if i < 0 or j < 0 or i >= field.n or j >= field.n then
		return 0
	end
	return field.data:byte(j * field.n + i + 1) / 255
end
-- The danger at x, z between the field's cells, so it changes smoothly
-- underfoot
local function danger_smooth(x, z)
	if not field then
		return 0
	end
	local c = field.cell
	local fx, fz = (x - field.x0) / c - 0.5, (z - field.z0) / c - 0.5
	local i, j = math.floor(fx), math.floor(fz)
	local tx, tz = fx - i, fz - j
	local function at(a, b)
		return danger_at(field.x0 + (a + 0.5) * c, field.z0 + (b + 0.5) * c)
	end
	return (at(i, j) * (1 - tx) + at(i + 1, j) * tx) * (1 - tz) +
			(at(i, j + 1) * (1 - tx) + at(i + 1, j + 1) * tx) * tz
end
-- **The fog of the danger** (user, 2026-10-15): the viewing range down to
-- 8 nodes at full, the fade from nearer, set every frame from the danger
-- underfoot eased over about half a second; logged at each tenth
local fog = {d = 0, logged = -1}
local function update_fog(dt)
	local x, _, z = keys.player_pos()
	if not x then
		return
	end
	fog.d = fog.d + (danger_smooth(x, z) - fog.d) * math.min(1, dt * 2)
	local tenth = math.floor(fog.d * 10 + 0.5)
	if tenth ~= fog.logged then
		fog.logged = tenth
		log:info("skelenti: fog for danger " .. tenth / 10)
	end
	if fog.d < 0.05 then
		luanti.set_fog_limit(nil)
	else
		luanti.set_fog_limit(200 - 192 * fog.d, 0.7 - 0.7 * fog.d)
	end
end
local function mood_here()
	local x, y, z = keys.player_pos()
	if not x or mood.since < 5 then
		return nil
	end
	local _, sky = luanti.light_color(x, y + 1.6, z)
	if sky and sky < 8 then
		return "caves"
	end
	if danger_at(x, z) >= 0.5 then
		return "danger"
	end
	local t = luanti.time_of_day
	if t and t >= 0.2 and t < 0.33 then
		return "sunrise"
	end
end
local frame = keys.stage.frame
keys.stage.frame = function(dt)
	frame(dt)
	ui.draw_hud(keys)
	if keys.world_taken then
		mood.since = mood.since + dt
	end
	local m = mood_here()
	if m ~= mood.seen then
		mood.seen, mood.held = m, 0
	end
	mood.held = mood.held + dt
	if mood.held >= 2 and mood.now ~= m then
		mood.now = m
		log:info("skelenti: mood " .. tostring(m))
	end
	music.update(dt, mood.now)
	update_fog(dt)
end
-- The danger on the ground around the player, from main.cpp's
-- send_field(), drawn by the voxel shader as decay
-- ([SKELENTI_DANGER_LOOK])
local voxel_shading = require("buildat/module/voxel_shading")
buildat.sub_packet("skelenti:field", function(data)
	local x0, z0, cell, n, at = data:match("^(%-?%d+) (%-?%d+) (%d+) (%d+)\n()")
	n = tonumber(n)
	if not n or #data - at + 1 ~= n * n then
		log:warning("skelenti:field: not a field")
		return
	end
	voxel_shading.set_area_field(tonumber(x0), tonumber(z0), tonumber(cell),
			n, n, data:sub(at))
	field = {x0 = tonumber(x0), z0 = tonumber(z0), cell = tonumber(cell),
		n = n, data = data:sub(at)}
	log:info("skelenti: the danger field at " .. x0 .. "," .. z0)
end)
log:info("skelenti client ready")
-- vim: set noet ts=4 sw=4:
