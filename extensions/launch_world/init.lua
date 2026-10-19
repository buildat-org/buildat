-- extensions/launch_world: [LAUNCH_WORLD], the room you start in.
--
-- An alternative to `launch_menu`, never a replacement:
--   Build/bin/buildat -m launch_world
--
-- The room itself is world.lua; this file is only the entry the client
-- calls to boot a menu extension. It is an extension rather than a game
-- because the room *is* the launcher: starting a game is `ctx.launch` on
-- the trusted side, which a game's own sandbox cannot reach.
-- The safe API under one name, whichever side this runs on: inside the
-- sandbox `buildat` is the safe table itself ([LAUNCH_SANDBOX])
local api = buildat.safe or buildat
local log = buildat.Logger("launch_world")
local M = {}

function M.boot(action)
	-- **"backdrop" is the room behind somebody else's screen**
	-- ([TWO_AUDIENCES]' third option): it draws and drifts and takes no
	-- input, which is what a launch UI composing it wants. Anything
	-- else is the launch grid's one-action boot (-a kind/name/id), not
	-- wired up yet.
	local backdrop = (action == "backdrop")
	if action and not backdrop then
		log:warning("launch_world: -a " .. tostring(action) ..
				" is not handled yet")
	end
	-- **What the client asks a launcher for** ([MENU_CONTEXT]): the room
	-- hands back the three the client and a game's own menu call --
	-- `buildat.leave()` goes through `leave_app`, and [MENU_ERRORS]
	-- reads `in_app` to choose a dialog or a notice.
	local room = api.run_extension_file("world.lua")
	if type(room) == "table" then
		M.entered_app = room.entered_app
		M.leave_app = room.leave_app
		M.in_app = room.in_app
		M.app_loading = room.app_loading
		if backdrop and room.be_backdrop then
			room.be_backdrop()
		end
	end
end

-- A local server that died: ui_utils' dialog, as launch_menu's
function M.show_dead_server(title, on_close)
	local ui_utils = require("buildat/extension/ui_utils")
	return (ui_utils.safe or ui_utils).show_dead_server(title, on_close)
end

return M
-- vim: set noet ts=4 sw=4:
