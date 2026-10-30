-- Buildat: builtin/chat/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- builtin/chat's client half (api.h says what the chat is):
--   local chat = require("buildat/module/chat")
--   chat.attach(accounts)  -- the app's builtin/accounts instance: its chat
--                          -- console gets the lines and sends what is typed
--   chat.listeners[#chat.listeners + 1] = function(line) ... end
--   chat.people(accounts)  -- the People... button alone, in an app whose
--                          -- console has its own lines (vanilla's)
-- The console's People... ([CHAT_PEOPLE_BUTTON]): who may talk (a
-- moderator's dropdown), the people in the chat to report and, for a
-- moderator, to mute or unmute, and the reports waiting, each muted or
-- dismissed; a page of accounts' over the console, Back to it.
-- simplified: a button per person and action, which is fine for a
-- server's few dozen; a report has no reason or text of the reporter's
local ui_utils = require("buildat/extension/ui_utils")
local write_json = require("buildat/extension/network").write_json
local log = buildat.Logger("chat")

local M = {}
M.lines = {}
M.listeners = {}
M.state = {min = "everyone", may_talk = false, muted = false,
	moderator = false, people = {}}
M.queue = {}
-- [VANILLA_CHAT_MIN] chat:set_min's values as the players read them
-- (builtin/accounts' level names)
M.MIN_SHOWN = {everyone = "Guests and up", member = "Residents and up",
	helper = "Keepers and up"}
M.MIN_CHOICES = {{"Guests and up", "everyone"},
	{"Residents and up", "member"}, {"Keepers and up", "helper"}}
local KEEP = 200
local accounts = nil
-- The instances with the button, drawn again as the chat's news comes
local shown_in = {}
-- Set while a packet draws the page again: no asking again then
local quiet = false
local fill

function M.people(acc)
	shown_in[#shown_in + 1] = acc
	acc.chat_people = function(w) fill(acc, w) end
end

function M.attach(acc)
	accounts = acc
	M.people(acc)
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

local function redraw()
	quiet = true
	for _, acc in ipairs(shown_in) do
		acc.chat_people_redraw()
	end
	quiet = false
end

buildat.sub_packet("chat:state", function(data)
	local s = buildat.parse_json(data)
	if type(s) ~= "table" then
		return
	end
	M.state = s
	redraw()
end)

buildat.sub_packet("chat:queue", function(data)
	local q = buildat.parse_json(data)
	M.queue = type(q) == "table" and q or {}
	redraw()
end)
buildat.send_packet("chat:get", "")

-- The people page's content, into accounts' page w
fill = function(acc, w)
	local s = M.state
	local function text(t)
		acc.page_text(w, t)
	end
	local function button(label, f)
		acc.page_button(w, label, f)
	end
	if s.muted then
		text("A moderator has muted you.")
	elseif not s.may_talk then
		text("The chat is for " .. (M.MIN_SHOWN[s.min] or s.min) .. " now.")
	end
	if s.moderator then
		ui_utils.dropdown(w, M.MIN_CHOICES, s.min, function(v)
			buildat.send_packet("chat:set_min", v)
		end, {label = "Who may talk", fill = true})
	end
	if #(s.people or {}) == 0 then
		text("Nobody else is in the chat.")
	end
	for _, p in ipairs(s.people or {}) do
		local name = p.name
		if s.moderator then
			button((p.muted and "Unmute " or "Mute ") .. name, function()
				buildat.send_packet(p.muted and "chat:unmute" or "chat:mute",
						name)
			end)
		end
		button("Report " .. name, function()
			buildat.send_packet("chat:report", name)
		end)
	end
	if s.moderator then
		text(#M.queue == 0 and "No reports waiting." or
				(#M.queue .. " reported, waiting:"))
		for _, g in ipairs(M.queue) do
			local r = (g.reports or {})[1] or {}
			-- The lines before the report, the last few of them
			local lines = {}
			for l in (r.text or ""):gmatch("[^\n]+") do
				lines[#lines + 1] = l
			end
			local from = math.max(1, #lines - 5)
			text((g.listing or "?") .. ", " .. #(g.reports or {}) ..
					" report(s):\n" .. table.concat(lines, "\n", from))
			button("Mute " .. tostring(g.listing), function()
				buildat.send_packet("chat:decide", write_json(
						{group = g.id, decision = "mute"}))
			end)
			button("Dismiss", function()
				buildat.send_packet("chat:decide", write_json(
						{group = g.id, decision = "dismiss"}))
			end)
		end
	end
	-- Fresh as it opens; the answers draw it again
	if quiet then
		return
	end
	buildat.send_packet("chat:get", "")
	if s.moderator then
		buildat.send_packet("chat:queue", "")
	end
end

return M
-- vim: set noet ts=4 sw=4:
