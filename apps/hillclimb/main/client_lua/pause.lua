-- Buildat: apps/hillclimb/main/client_lua/pause.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- hillclimb's pause menu ([HC_PAUSE_MENU]), Escape's, as skeldat's
-- pause.lua (its own copy: apps do not consume each other): Continue, The
-- hill... (the Tab menu), High scores..., Chat..., Settings... and Leave
-- the game. The
-- game goes on under it -- a shared server's clock and the other cars --
-- and init.lua sends no driving input while it is up (pause.held()).
--   local pause = run_script_file("main/pause.lua")(h)
-- h.hill_menu(): the Tab menu opened; h.chat(back): the chat page, back()
-- once it closes; h.keys(): the keys read again after the settings window;
-- h.may_pick(): whether this player picks the hill; h.drive(set): a High
-- scores set's parameters made the hill
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local uistack = require("buildat/extension/uistack")
uistack = uistack.safe or uistack
local log = buildat.Logger("hillclimb")

return function(h)
	local M = {}
	local root = nil
	-- Settings or the chat opened from the menu, which comes back after
	local away = false
	-- The menu again next frame: the Escape that closed the settings
	-- window would otherwise close it again
	local pending = nil
	-- Frames counted, and the one it opened in: init.lua's Escape that
	-- frame is the one that closed the window it came back from
	local frame, opened = 0, -1
	magic.SubscribeToEvent("Update", function()
		frame = frame + 1
		if pending then
			local fn = pending
			pending = nil
			fn()
		end
	end)

	-- Up, or away in a window it comes back from: no driving, no keys
	function M.held()
		return root ~= nil or away
	end
	function M.shown()
		return root ~= nil
	end
	-- Whether this frame's Escape is the menu's to close it with
	function M.escape_closes()
		return root ~= nil and opened ~= frame
	end
	function M.close()
		if not root then
			return
		end
		uistack.main:pop(root)
		root = nil
		-- A clicked button stays the focus, and Space would press it again
		magic.ui:SetFocusElement(nil)
		log:info("pause: the menu closed")
	end
	local function back()
		away = false
		pending = M.open
	end

	-- [HC_SCORES] The High scores page, skeldat's ([SKELDAT_HIGH_SCORES],
	-- its own copy): every parameter set with times, and a set's entries,
	-- all of them, scrolled by the wheel; from the server's hillclimb:scores,
	-- asked by "sets" and "set <key>"
	local scores = nil
	local function close_scores()
		if scores then
			uistack.main:pop(scores)
			scores = nil
			magic.ui:SetFocusElement(nil)
		end
	end
	local function ask(what)
		buildat.send_packet("hillclimb:scores", what)
	end
	-- rows: {label, badge, action or nil}; extra: {label, action} buttons
	-- over Back
	local function scores_page(title, rows, extra, on_back)
		close_scores()
		away = true
		scores = uistack.main:push({desc = "scores"})
		local w = magic.ui.root.width - 40
		local menu = ui_utils.vertical_menu(scores, {min_width = w})
		menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		local t = menu.window:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText(title)
		local view = ui_utils.list_view(menu.window, w - 20,
				math.max(100, magic.ui.root.height - 190), {wheel = 40,
				label_share = 0.45})
		for _, r in ipairs(rows) do
			local b = view:row({label = r[1], badge = r[2]})
			if r[3] then
				menu:add(b, r[3])
			end
		end
		view:fit()
		for _, e in ipairs(extra) do
			menu:add(e[1], e[2])
		end
		menu:add("Back", on_back, true)
		menu:on_key(function(key)
			if key == magic.KEY_ESCAPE then
				on_back()
				return true
			end
		end)
	end
	local function result(e)
		return (e.laps or -1) >= 0 and string.format("%d laps, the last at "
				.. "%.2f s", e.laps, e.t or 0) or string.format("%.2f s", e.t or 0)
	end
	buildat.sub_packet("hillclimb:scores", function(data)
		local j = buildat.parse_json(data) or {}
		if j.sets then
			local rows = {}
			for _, set in ipairs(j.sets) do
				-- One label: a set's name is long for a badge beside it
				rows[#rows + 1] = {string.format("%s%s: %s, %d %s",
					set.current and "> " or "", tostring(set.name),
					result(set.best or {}), set.count or 0,
					set.count == 1 and "time" or "times"), nil,
					function() ask("set " .. set.key) end}
			end
			if #rows == 0 then
				rows[1] = {"No times yet"}
			end
			scores_page("High scores (> this hill)", rows, {}, function()
				close_scores()
				back()
			end)
			log:info("pause: high scores shown, " .. #j.sets .. " sets")
		elseif j.set then
			local set, rows = j.set, {}
			for i, e in ipairs(set.entries or {}) do
				local worn = (e.fin or 0) + (e.unfin or 0) == 0 and "fresh" or
						string.format("after %d runs (%d finished)",
						e.fin + e.unfin, e.fin)
				rows[#rows + 1] = {string.format("%d. %s", i, tostring(e.name)),
					string.format("%s, %s, seed %s, %s", result(e), tostring(e.date),
					tostring(e.seed), worn)}
			end
			local extra = {}
			-- An older version's hill is not what the code makes now
			if set.drivable and h.may_pick() then
				extra[1] = {"Drive this hill", function()
					close_scores()
					away = false
					h.drive(set)
				end}
			end
			scores_page(tostring(set.name), rows, extra, function()
				ask("sets")
			end)
			log:info("pause: scores of " .. tostring(set.key) .. " shown, " ..
					#rows .. " entries")
		end
	end)
	function M.open()
		if root then
			return
		end
		root = uistack.main:push({desc = "pause"})
		opened = frame
		local menu = ui_utils.vertical_menu(root, {min_width = 260})
		menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		menu:add("Continue", M.close, true)
		menu:add("The hill...", function()
			M.close()
			h.hill_menu()
		end)
		menu:add("High scores...", function()
			M.close()
			away = true
			ask("sets")
		end)
		menu:add("Chat...", function()
			M.close()
			away = true
			h.chat(back)
		end)
		menu:add("Settings...", function()
			M.close()
			away = true
			log:info("pause: settings shown")
			buildat.show_game_settings{on_close = function()
				h.keys()
				log:info("pause: settings closed")
				back()
			end}
		end)
		menu:add("Leave the game", function()
			log:info("pause: leave")
			buildat.leave()
		end)
		log:info("pause: the menu shown")
	end
	return M
end
-- vim: set noet ts=4 sw=4:
