-- Buildat: apps/demo_skelenti/main/client_lua/worlds.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The world dialog, while the server runs no world (main.cpp): the saves
-- to play, a name to make a new one with, and a delete for each. The
-- server answers skelenti:worlds with "list\n<name>..." for this list,
-- "wait" for a client that may not pick, and "up" when the world is in,
-- after which init.lua is the client.
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local uistack = require("buildat/extension/uistack")
uistack = uistack.safe or uistack
local log = buildat.Logger("skelenti")

local root = nil

local function close()
	if root then
		uistack.main:pop(root)
		root = nil
	end
end

-- The dialog drawn again, with `names` (nil: the wait) and `note` above
local function draw(names, note)
	close()
	root = uistack.main:push({desc = "worlds"})
	local menu = ui_utils.vertical_menu(root, {min_width = 320})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local function text(s)
		local t = menu.window:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText(s)
	end
	text("skelenti")
	if note then
		text(note)
	end
	if not names then
		menu:add("Leave the game", function() buildat.leave() end)
		magic.input:SetMouseVisible(true)
		return
	end
	local function pick(packet, name, what)
		log:info("worlds: " .. what .. " " .. name)
		buildat.send_packet(packet, name)
		draw({}, what .. " " .. name .. "...")
	end
	for _, name in ipairs(names) do
		menu:add("Play " .. name, function()
			pick("skelenti:world_play", name, "Loading")
		end, true)
		menu:add("Delete " .. name, function()
			ui_utils.show_confirm_dialog("Delete the world " .. name ..
					"? It cannot be undone.", function()
				log:info("worlds: delete " .. name)
				buildat.send_packet("skelenti:world_delete", name)
			end, nil, "Delete", "Keep")
		end)
	end
	if #names > 0 or not note then
		text("New world, named:")
		local edit = menu.window:CreateChild("LineEdit")
		edit:SetStyleAuto()
		edit.minHeight = 26
		edit:SetText(#names == 0 and "world" or "")
		menu:add("Create", function()
			local name = edit:GetText():match("^%s*(.-)%s*$")
			if name ~= "" then
				pick("skelenti:world_create", name, "Creating")
			end
		end)
	end
	menu:add("Leave the game", function() buildat.leave() end)
	magic.input:SetMouseVisible(true)
	-- What a check waits for
	log:info("worlds: the dialog shown, " .. #names .. " worlds")
end

buildat.sub_packet("skelenti:worlds", function(data)
	if data == "up" then
		close()
		return
	end
	if data == "wait" then
		draw(nil, "Waiting for the host to pick a world")
		return
	end
	local names = {}
	for name in data:gmatch("\n([^\n]+)") do
		names[#names + 1] = name
	end
	draw(names)
end)
-- vim: set noet ts=4 sw=4:
