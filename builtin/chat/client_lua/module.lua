-- Buildat: builtin/chat/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- builtin/chat's client half (api.h says what the chat is):
--   local chat = require("buildat/module/chat")
--   chat.attach(accounts)  -- the app's builtin/accounts instance: its chat
--                          -- console gets the lines and sends what is typed
--   chat.listeners[#chat.listeners + 1] = function(line) ... end
--   chat.open(hold)        -- the chat's menu over the app
-- hold(close, window) is the app's way of keeping its world's hands off
-- the mouse and the keys while a window is up, hold(nil) of giving them
-- back. The menu: who may talk (a moderator's dropdown), the people in
-- the chat to report and, for a moderator, to mute or unmute, and the
-- reports waiting, each muted or dismissed.
-- simplified: a button per person and action, which is fine for a
-- server's few dozen; a report has no reason or text of the reporter's
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local uistack = require("buildat/extension/uistack")
uistack = uistack.safe or uistack
local write_json = require("buildat/extension/network").write_json
local log = buildat.Logger("chat")

local M = {}
M.lines = {}
M.listeners = {}
M.state = {min = "everyone", may_talk = false, muted = false,
	moderator = false, people = {}}
M.queue = {}
local KEEP = 200
local accounts = nil
local root, hold_fn, close

function M.attach(acc)
	accounts = acc
	for _, line in ipairs(M.lines) do
		acc.chat_add(line, nil, true)
	end
	acc.chat_send = function(text)
		M.say(text)
	end
end

function M.say(text)
	buildat.send_packet("chat:say", text)
end

buildat.sub_packet("chat:line", function(line)
	M.lines[#M.lines + 1] = line
	while #M.lines > KEEP do
		table.remove(M.lines, 1)
	end
	log:info("chat: " .. line)
	if accounts then
		accounts.chat_add(line)
	end
	for _, f in ipairs(M.listeners) do
		f(line)
	end
end)

local refresh
buildat.sub_packet("chat:state", function(data)
	local s = buildat.parse_json(data)
	if type(s) ~= "table" then
		return
	end
	M.state = s
	if root then
		refresh()
	end
end)

buildat.sub_packet("chat:queue", function(data)
	local q = buildat.parse_json(data)
	M.queue = type(q) == "table" and q or {}
	if root then
		refresh()
	end
end)
buildat.send_packet("chat:get", "")

local function text(parent, s)
	local t = parent:CreateChild("Text")
	t:SetStyleAuto()
	t:SetWordwrap(true)
	t:SetFixedWidth(360)
	t:SetText(s)
	return t
end

local function build()
	root = uistack.main:push({desc = "chat"})
	local menu = ui_utils.vertical_menu(root, {min_width = 360})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local s = M.state
	text(menu.window, "Chat")
	if s.muted then
		text(menu.window, "A moderator has muted you.")
	elseif not s.may_talk then
		text(menu.window, "The chat is for " .. (s.min == "member" and
				"members" or "helpers") .. " and up now.")
	end
	if s.moderator then
		menu:add_dropdown("Who may talk", {"everyone", "member", "helper"},
				s.min, function(v)
			buildat.send_packet("chat:set_min", v)
		end)
	end
	for _, p in ipairs(s.people or {}) do
		local name = p.name
		if s.moderator then
			menu:add((p.muted and "Unmute " or "Mute ") .. name, function()
				buildat.send_packet(p.muted and "chat:unmute" or "chat:mute",
						name)
			end)
		end
		menu:add("Report " .. name, function()
			buildat.send_packet("chat:report", name)
		end)
	end
	if s.moderator then
		text(menu.window, #M.queue == 0 and "No reports waiting." or
				(#M.queue .. " reported, waiting:"))
		for _, g in ipairs(M.queue) do
			local r = (g.reports or {})[1] or {}
			-- The lines before the report, the last few of them
			local lines = {}
			for l in (r.text or ""):gmatch("[^\n]+") do
				lines[#lines + 1] = l
			end
			local from = math.max(1, #lines - 5)
			text(menu.window, (g.listing or "?") .. ", " ..
					#(g.reports or {}) .. " report(s):\n" ..
					table.concat(lines, "\n", from))
			menu:add("Mute " .. tostring(g.listing), function()
				buildat.send_packet("chat:decide", write_json(
						{group = g.id, decision = "mute"}))
			end)
			menu:add("Dismiss", function()
				buildat.send_packet("chat:decide", write_json(
						{group = g.id, decision = "dismiss"}))
			end)
		end
	end
	menu:add("Close", function() close() end, true)
	hold_fn(close, menu.window)
end

function close()
	if not root then
		return
	end
	uistack.main:pop(root)
	root = nil
	hold_fn(nil)
	magic.ui:SetFocusElement(nil)
	log:info("chat: the menu closed")
end

function refresh()
	uistack.main:pop(root)
	root = nil
	build()
end

function M.open(hold)
	if root then
		return
	end
	hold_fn = hold
	build()
	buildat.send_packet("chat:get", "")
	if M.state.moderator then
		buildat.send_packet("chat:queue", "")
	end
	log:info("chat: the menu shown")
end

return M
-- vim: set noet ts=4 sw=4:
