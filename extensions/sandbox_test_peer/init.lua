-- Buildat: extension/sandbox_test_peer/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
-- [EXT_CALLER_FRAME]: **another installed extension beside the launch UI**
-- (sandbox_test, which requires this). From callbacks the client runs it
-- calls the verbs that act on its own files and storage through a tail
-- call and through a C function, where no frame of its own is on the
-- stack; each must still be its own and not the launch UI's. The launch
-- UI's side of it is in sandbox_test's launch_attack.lua.
local log = buildat.Logger("sandbox_test_peer")
local magic = require("buildat/core/urho3d")
local M = {safe = {}}

-- Its own marks, written from its own chunk, which the pcalls below read
buildat.storage_write("peer_own", "peer")
buildat.cache_write("peer_own", "peer")

-- Tail calls straight from the client's delivery, a write each frame
magic.SubscribeToEvent("Update", function()
	return buildat.storage_write("peer_mark", "peer")
end)
magic.SubscribeToEvent("Update", function()
	return buildat.cache_write("peer_mark", "peer")
end)

-- And through pcall, a few frames on: what came back is its own
local frames = 0
magic.SubscribeToEvent("Update", function()
	frames = frames + 1
	if frames ~= 3 then return end
	local results = {
		-- A file only the launch UI has
		read_extension_file = select(2, pcall(buildat.read_extension_file,
				"launch_attack.lua")) == nil,
		-- The same one, run: looked for in this extension's directory
		run_extension_file = (function()
			local ok, e = pcall(buildat.run_extension_file,
					"launch_attack.lua")
			return not ok and tostring(e):find("sandbox_test_peer") ~= nil
		end)(),
		storage_read = select(2, pcall(buildat.storage_read, "peer_own")) ==
				"peer",
		cache_read = select(2, pcall(buildat.cache_read, "peer_own")) ==
				"peer",
	}
	local own, bad = 0, {}
	for name, ok in pairs(results) do
		if ok then own = own + 1 else bad[#bad + 1] = name end
	end
	table.sort(bad)
	log:info("sandbox_test_peer: " .. own .. " of 4 its own" ..
			(#bad > 0 and ", NOT: " .. table.concat(bad, ", ") or ""))
end)

-- And a function of its own the launch UI calls, tail-calling eval: the
-- code must not run in the launch UI's environment, with its buildat
function M.safe.hook()
	return buildat.eval("return buildat.read_extension_file('launch_attack.lua')")
end

-- [SAFE_UNSUB_PEER] The launch UI's global handlers, by the names it
-- hands over and by the function itself: none is this extension's to
-- unsubscribe. Returns how many went, and what its own unsubscribe of
-- its own returned (1).
function M.safe.unsubscribe(list)
	local n = 0
	for _, c in ipairs(list) do
		n = n + magic.UnsubscribeFromEvent(c[1], c[2])
	end
	local own = magic.SubscribeToEvent("Update", function() end)
	return n, magic.UnsubscribeFromEvent("Update", own)
end

return M
-- vim: set noet ts=4 sw=4:
