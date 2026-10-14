-- Buildat: apps/vanilla/main/client_lua/key_rows.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- vanilla's key rows from before the client's key store, moved into it:
-- returns a function that puts apply(), public and own_rows() on a
-- luanti/keys.lua table. init.lua's (the loop's) and menu.lua's are two
-- tables, the menu running without the loop.
local cereal = require("buildat/extension/cereal")
local log = buildat.Logger("vanilla")

return function(keys)
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
end
-- vim: set noet ts=4 sw=4:
