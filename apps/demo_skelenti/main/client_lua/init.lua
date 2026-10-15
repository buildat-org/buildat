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
keys.stage.point = mobs.point
local frame = keys.stage.frame
keys.stage.frame = function(dt)
	frame(dt)
	ui.draw_hud(keys)
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
	log:info("skelenti: the danger field at " .. x0 .. "," .. z0)
end)
log:info("skelenti client ready")
-- vim: set noet ts=4 sw=4:
