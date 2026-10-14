-- Buildat: apps/vanilla/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- A window onto a Luanti world running inside buildat_server: the module's
-- client loop (builtin/luanti/client_lua/client.lua, [LUANTI_APP_GLUE])
-- with vanilla's own parts on it -- the pause menu (pause.lua), and the
-- settings: settings.json's rows by main:settings, the key rows moved
-- into the key store, the View section of the settings window.
local cereal = require("buildat/extension/cereal")
local luanti = require("buildat/module/luanti")
local log = buildat.Logger("vanilla")

local keys = luanti.run_client({
	log = "vanilla",
	pause = (function(ok, err, m)
		if not ok or type(m) ~= "function" then
			error("vanilla: could not load pause.lua: " .. tostring(err))
		end
		return m
	end)(buildat.run_script_file("main/pause.lua")),
})

-- The settings list as the server sent it. The "key.<action>=<name>"
-- rows it held before the store -- in the server's settings.json, or a
-- public server's in this client's storage ("key_rows") -- are moved into
-- the store once and dropped there. Returns how many there were.
function keys.apply(list)
	local rows, kept = {}, {}
	for _, row in ipairs(list) do
		local action, name = row:match("^key%.([%w_]+)=(.+)$")
		if action then
			rows[action] = name
		elseif not row:match("^key%.") then
			kept[#kept + 1] = row
		end
	end
	keys.settings = kept
	if next(rows) == nil then
		return 0
	end
	buildat.set_app_keys(nil, rows)
	keys.declare()
	log:info("key bindings moved from the settings to the key store")
	if keys.public then
		buildat.storage_write("key_rows", "")
	else
		buildat.send_packet("main:set_settings",
				cereal.binary_output(kept, {"array", "string"}))
	end
	return 1
end

-- **A public server's key rows were the client's own** ([VANILLA_PUBLIC]
-- 6), kept in the client's storage for that server; read once more so
-- that apply() moves them. pause.lua sets keys.public from main:account.
keys.public = false

function keys.own_rows(list)
	if not keys.public then
		return list
	end
	local out = {}
	for _, row in ipairs(list) do
		if not row:match("^key%.") then
			out[#out + 1] = row
		end
	end
	for row in (buildat.storage_read("key_rows") or ""):gmatch("[^\n]+") do
		out[#out + 1] = row
	end
	return out
end

keys.set_view = function(name, value)
	if keys.view_local then
		local list = {}
		for _, row in ipairs(keys.settings or {}) do
			if not row:match("^" .. name .. "=") then
				list[#list + 1] = row
			end
		end
		list[#list + 1] = name .. "=" .. value
		keys.settings = list
		buildat.send_packet("main:set_settings",
				cereal.binary_output(list, {"array", "string"}))
	else
		buildat.storage_write("view_" .. name, value)
	end
	keys.view_rows[name] = value
	keys.apply_view(name .. "=" .. value)
	log:info("view: " .. name .. " = " .. value)
end

keys.rejoin = function(later)
	local why = keys.rejoin_why
	if not later then
		keys.rejoin_why = nil
	end
	local ok, err = buildat.rejoin(why, keys.world, later)
	log:info("view: rejoin: " .. tostring(ok) .. " " .. tostring(err))
end

buildat.sub_packet("main:settings", function(data)
	local list = keys.own_rows(cereal.binary_input(data, {"array", "string"}))
	keys.view_local = buildat.connected_locally()
	for i, row in ipairs(list) do
		local name = row:match("^([%w_]+)=")
		if name and keys.view_rows[name] then
			local own = not keys.view_local and
					buildat.storage_read("view_" .. name) or ""
			if own ~= "" then
				list[i] = name .. "=" .. own
			end
			keys.view_rows[name] = list[i]:match("=(.*)$")
		end
	end
	local v = keys.view_rows
	log:info(string.format("view settings: render %s, distant %s, " ..
			"bobbing %s, shoulder %s", v.render_mode, v.lod_detail,
			v.view_bobbing_amount, v.third_person_shoulder))
	keys.apply(list)
	keys.view.web = nil
	for _, row in ipairs(list) do
		local w = row:match("^web_view_range=(%d+)$")
		if w then
			keys.view.web = tonumber(w)
		end
	end
	for _, row in ipairs(list) do
		local n = row:match("^view_range=(%d+)$")
		if n then
			keys.view.ceiling = tonumber(n)
			keys.view.apply()
		end
		keys.apply_view(row)
	end
	if keys.rejoin_why then
		keys.rejoin_due = true
	end
end)

table.insert(keys.settings_sections, 1, {title = "View", draw = function(_, ui)
	local v = keys.view_rows
	-- Fixed for a session: a new one is a rejoin
	ui.dropdown("Render mode", {{"PBR", "pbr"},
			{"Shadows", "shadows"}, {"Unlit", "unlit"}}, v.render_mode,
			function(m)
		if m == v.render_mode then
			return
		end
		keys.set_view("render_mode", m)
		keys.rejoin_why = "Rejoining for the render mode " .. m .. "..."
		-- A local server's write is in once its list comes back: armed
		-- now, on the click, and run by the main:settings handler
		keys.rejoin(keys.view_local)
	end)
	ui.dropdown("Distant terrain detail", {{"Full", "full"},
			{"Reduced past half range", "half"},
			{"Reduced past a third", "third"}}, v.lod_detail,
			function(d) keys.set_view("lod_detail", d) end)
	ui.toggle("View bobbing", v.view_bobbing_amount ~= "0", function(on)
		keys.set_view("view_bobbing_amount", on and "1" or "0")
	end)
	ui.toggle("Over the shoulder", v.third_person_shoulder == "1",
			function(on)
		keys.set_view("third_person_shoulder", on and "1" or "0")
	end)
	ui.dropdown("Debug info (F5)", {{"Off", "0"}, {"Basic", "1"},
			{"Full", "2"}}, tostring(keys.detail_level()), function(l)
		keys.set_detail(tonumber(l))
	end)
end})

buildat.send_packet("main:get_settings", "")
log:info("vanilla client ready")
-- vim: set noet ts=4 sw=4:
