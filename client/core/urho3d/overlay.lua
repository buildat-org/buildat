-- Buildat: client/core/urho3d/overlay.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The trust colour, the trust code, the ID rows and the F9 overlay: no
-- part of the sandbox's boundary, which is init.lua's job. Run by
-- init.lua with the locals this reads; the overlay key is read through
-- overlay_key_of(), since init.lua's key settings change it
-- ([FILE_SPLITS_1019]: moved out as it was).

local Safe, add_global_event_handler, log, mouse, overlay_key_of,
		urho_SubscribeToEvent = ...

--
-- **The Starport trust colour** ([TRUST_COLOR]; user, 2026-10-03)
--
-- Any script can draw a window that looks like the client's Starport ID
-- login and ask for the password. So the client's own Starport fields
-- are drawn in a colour picked at random when the client starts, which no
-- script can read -- not from the fields (safe_classes' color getter), not
-- from the sample (never wrapped, magic_sandbox.is_hidden_ui), not from
-- the random source (the platform's, not math.random, whose state a
-- script could work back from its own draws) -- and the launcher shows
-- the sample at its top right. A login whose fields are not that colour
-- is not the client's.
--
-- simplified: twelve hues at two brightnesses, which a person tells apart
-- at a glance; a script guessing is right one time in 24. More colours
-- are more guesses to make and fewer a person can name.
local trust_rgb
do
	local b = buildat.random_bytes(2)
	local hue = (b:byte(1) % 12) / 12
	-- Dark enough under white text either way
	local v = (b:byte(2) % 2 == 0) and 0.4 or 0.6
	-- HSV with full saturation to RGB
	local i = math.floor(hue * 6)
	local f = hue * 6 - i
	local p, q, t = 0, v * (1 - f), v * f
	local rgb = ({{v, t, p}, {q, v, p}, {p, v, t}, {p, q, v}, {t, p, v},
			{v, p, q}})[i % 6 + 1]
	trust_rgb = {rgb[1], rgb[2], rgb[3]}
end

-- The colour, to the client's own code: never in Safe
local function trust_color()
	return trust_rgb[1], trust_rgb[2], trust_rgb[3]
end

-- **The trust code** ([TRUST_CODE]; user, 2026-10-05): three characters
-- stamped small in the overlay's bottom left, picked like the colour, so a
-- look-alike overlay in a game has 1 in 32768 of getting it right. No
-- 0, O, 1 or I; re-drawn if it spells a word on the list.
local trust_code
do
	local alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
	-- simplified: a few words that would be unpleasant to be shown; a
	-- longer list when someone gets one
	local blocked = {ASS = 1, FUK = 1, FUC = 1, FAG = 1, SEX = 1, KKK = 1,
			NAZ = 1, DIE = 1, CUM = 1, TIT = 1, WTF = 1, GAY = 1, SUX = 1}
	repeat
		local b = buildat.random_bytes(3)
		local c = {}
		for i = 1, 3 do
			local n = b:byte(i) % 32 + 1
			c[i] = alphabet:sub(n, n)
		end
		trust_code = table.concat(c)
	until not blocked[trust_code]
end

-- The code as a small Text on a raw element of the trust colour: the
-- overlay's last line, every Starport field. Its colour is the trust
-- colour halfway to white: every trust colour is dark enough for the
-- white labels on it (user, 2026-10-05). Hidden from scripts by its
-- name (magic_sandbox.is_hidden_ui), as inside a field a script could
-- otherwise walk to it.
local function trust_code_text(parent)
	local t = parent:CreateChild("Text")
	t:SetName("__trusted_hidden_trust_code")
	t:SetFont(cache:GetResource("Font", "own:Fonts/Overpass-Regular.ttf"), 9)
	t.text = trust_code
	local function mix(c)
		return c + (1 - c) * 0.5
	end
	t.color = Color(mix(trust_rgb[1]), mix(trust_rgb[2]), mix(trust_rgb[3]), 1)
	return t
end

-- And in the window title (user, 2026-10-05), which no script can read
-- or set. Not on the web: the title there is the page's, the server's.
if GetPlatform() ~= "Web" then
	graphics:SetWindowTitle(graphics:GetWindowTitle() .. " [" .. trust_code .. "]")
end

-- The sample: "Starport trust color:" and a square a text row high, at the
-- top right while the launcher has the screen (not connected anywhere).
-- Made of raw elements under a hidden name, over anything a script draws
-- (theirs stop at 999).
local trust_sample = nil
local trust_sample_shown = nil
-- [ID_LINE] (user, 2026-10-03): under the colour, "Starport ID: <name>"
-- and a Log out button per ID logged in, in the same overlay -- no script
-- can draw its look-alike over it, get it or press it (its elements are
-- never wrapped, its Log out answers a raw event to a function here).
-- Rebuilt when the IDs change, looked at twice a second.
local id_rows = {}
local id_signature = nil
local id_timer = 0
local id_logouts = 0
local offer_timer = 0
local function starport_module()
	local ok, sp = pcall(require, "buildat/core/starport")
	return ok and type(sp) == "table" and sp.logged_in_ids and sp or nil
end
-- A button of the overlay: raw, its Released answered by a global
-- function of a name no script knows to call
local function overlay_button(parent, text, fn)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	local bt = b:CreateChild("Text")
	bt:SetStyleAuto()
	bt.text = text
	bt:SetAlignment(HA_CENTER, VA_CENTER)
	b:SetFixedSize(bt:GetWidth() + 16, math.max(20, bt:GetHeight() + 6))
	id_logouts = id_logouts + 1
	local fname = "__buildat_trust_button_" .. id_logouts
	_G[fname] = fn
	urho_SubscribeToEvent(b, "Released", fname)
	return b
end
-- [ID_OVERLAY] (user, 2026-10-04): the launcher's Starport buttons are
-- here, on the colour: "Starport ID..." and "Starport settings..." while
-- no ID is logged in; an ID's lines when one is, and the settings under
-- them.
local function open_id(sp)
	local urls = sp.starport_urls and sp.starport_urls() or {}
	if #urls == 1 then
		sp.id_login(urls[1])
	else
		sp.open_settings()
	end
end
-- [STARPORT_RECOMMENDS]: the Hearth the Starport recommends, at the
-- address client/launch_grid.lua's hearth_target makes
local function join_hearth(sp, hearth)
	local scheme, host = hearth:match("^(https?)://([^/?#]+)")
	sp.join_with_id(scheme == "https" and "https://" .. host or
			(host:find(":%d+$") and host or host .. ":80"))
end
-- **The web has no trusted overlay** (user, 2026-10-07): the page and its
-- code are the server's ([WEB_ID_TRUST]), so a colour or an ID line there
-- would vouch for nothing, and the web holds no ID session to show. Only
-- "Discuss" per Starport recommending a Hearth, at the top right.
local is_web = GetPlatform() == "Web"
local function rebuild_web_rows(hearths, sp)
	for _, r in ipairs(id_rows) do
		r:Remove()
	end
	id_rows = {}
	local y = 8
	for _, h in ipairs(hearths) do
		local r = ui.root:CreateChild("UIElement")
		r:SetName("__trusted_hidden_id_" .. #id_rows + 1)
		r.defaultStyle = cache:GetResource("XMLFile",
				"own:ui_utils/res/style.xml")
		r.priority = 2001
		r:SetLayout(LM_HORIZONTAL, 8, IntRect(0, 0, 0, 0))
		r:SetAlignment(HA_RIGHT, VA_TOP)
		local host = #hearths > 1 and h.url:match("^%a+://([^/]+)")
		local b = overlay_button(r, "Discuss" ..
				(host and (" (" .. host .. ")") or ""),
				function() join_hearth(sp, h.hearth) end)
		r:SetPosition(-8, y)
		y = y + b:GetHeight() + 4
		r.visible = trust_sample_shown == true
		id_rows[#id_rows + 1] = r
	end
end
local function rebuild_id_rows(ids, sp)
	for _, r in ipairs(id_rows) do
		r:Remove()
	end
	id_rows = {}
	local several = #ids > 1
	-- Each line its own element on the root, right-aligned under the one
	-- before: a column of them stretched every line to the widest, and
	-- the colour's line went across the screen. **The colour is behind
	-- the lines** (user): one rectangle of it reaching the extents of
	-- all of them.
	local y = trust_sample:GetPosition().y
	local function line(i)
		local r = ui.root:CreateChild("UIElement")
		r:SetName("__trusted_hidden_id_" .. i)
		r.defaultStyle = trust_sample.defaultStyle
		r.priority = 2001
		r:SetLayout(LM_HORIZONTAL, 8, IntRect(0, 0, 0, 0))
		r:SetAlignment(HA_RIGHT, VA_TOP)
		return r
	end
	local function place(r, b)
		r:SetPosition(-8, y)
		y = y + math.max(r:GetHeight(), b:GetHeight()) + 4
		r.visible = trust_sample_shown == true
		id_rows[#id_rows + 1] = r
	end
	local function settings(r)
		return overlay_button(r, "Starport settings...", function()
			sp.open_settings()
		end)
	end
	for i, id in ipairs(ids) do
		local r = line(i)
		local t = r:CreateChild("Text")
		t:SetStyleAuto()
		local host = id.url:match("^%a+://([^/]+)") or id.url
		t.text = "Starport ID: " .. id.name .. (several and (" (" .. host .. ")") or "")
		t:SetVerticalAlignment(VA_CENTER)
		-- A gap of its own, as the colour's line has
		r:CreateChild("UIElement"):SetFixedSize(10, 4)
		local url = id.url
		local hearth = sp.recommended_hearth and sp.recommended_hearth(url)
		if hearth then
			-- **In a game it leaves first** ([OVERLAY_DISCUSS]): a join
			-- from inside one left luanti_client running, killed a local
			-- server into "The server exited", or did nothing
			local label = __buildat_discuss_label and __buildat_discuss_label()
			overlay_button(r, label or "Discuss", function()
				if not label then
					join_hearth(sp, hearth)
				elseif not __buildat_discuss_from_overlay(hearth) then
					log:warning("overlay: Discuss could not leave the game")
				end
			end)
		end
		local b = overlay_button(r, "Log out", function()
			sp.log_out(url)
			id_signature = nil -- rebuilt at the next look
			id_timer = 1
		end)
		place(r, b)
	end
	local r = line(#ids + 1)
	-- The code at the bottom left, the last line's first element, in the
	-- room left of its buttons when a line above is wider.
	-- simplified: with no ID logged in the last line is the only one and
	-- the code widens it; a corner of its own when that is not wanted
	trust_code_text(r):SetVerticalAlignment(VA_BOTTOM)
	-- Pushes the buttons to the right edge, under the line above
	local gap = r:CreateChild("UIElement")
	gap:SetFixedSize(0, 1)
	if #ids == 0 then
		overlay_button(r, "Starport ID...", function() open_id(sp) end)
	end
	place(r, settings(r))
	local pad = 4
	local w = 0
	for _, x in ipairs(id_rows) do
		w = math.max(w, x:GetWidth())
	end
	gap:SetFixedSize(w - r:GetWidth(), 1)
	local top = trust_sample:GetPosition().y
	local bg = ui.root:CreateChild("BorderImage")
	bg:SetName("__trusted_hidden_id_bg")
	-- Over the client's own dialogs (1000): a script's window clicked
	-- while one is up is raised to its priority (BringToFront), and a
	-- script sets 999 at most
	bg.priority = 2000
	bg:SetAlignment(HA_RIGHT, VA_TOP)
	bg:SetPosition(-8 + pad, top - pad)
	bg:SetFixedSize(w + 2 * pad, (y - 4 - top) + 2 * pad)
	bg.color = Color(trust_rgb[1], trust_rgb[2], trust_rgb[3], 1)
	bg.visible = trust_sample_shown == true
	id_rows[#id_rows + 1] = bg
end
-- **F9 shows and hides the overlay** ([TRUST_CODE]): a fake does not
-- answer the key, so it is still there after the second press. Shown
-- whenever the launcher gets the screen (the client's start, a leave),
-- where F9 acknowledges it (user, 2026-10-05); hidden on entering a game.
-- On the event's mux directly, as Safe.SubscribeToEvent's handlers never
-- get F9.
local trust_shown = true
local trust_in_game = nil
-- What the rows' visibility was last written for: show, id_rows, its
-- length, trust_sample
local rows_applied = {}
-- **A local save is a game from its start** ([LOCAL_SAVE_STARPORT]): the
-- launcher's "Starting <game>..." screen is up (launch_menu's
-- screens.lua), or the connecting screen
-- that follows it, before there is a server address to go by
local was_launching = false
-- The stack walked again only when it changed ([REWORK_1019_PERF] client
-- 12). simplified: by its length and its top; a screen renamed in place,
-- or one replaced at the same depth by a wrapper at the same address, is
-- not seen until the next push or pop
local launch_seen = {}
local function launching_local()
	local us = package.loaded["buildat/core/uistack"]
	local stack = us and us.main and us.main.stack or {}
	local n, top = #stack, stack[#stack]
	if launch_seen[1] == stack and launch_seen[2] == n and
			launch_seen[3] == top then
		return was_launching
	end
	launch_seen[1], launch_seen[2], launch_seen[3] = stack, n, top
	local starting, connecting = false, false
	for _, e in ipairs(stack) do
		local ok, name = pcall(function() return e:GetName() end)
		if ok and type(name) == "string" then
			starting = starting or name:find(": starting_local_server", 1, true) ~= nil or
					name:find(": stopping_old_server", 1, true) ~= nil
			connecting = connecting or name:find(": connecting", 1, true) ~= nil
		end
	end
	was_launching = starting or (was_launching and connecting)
	return was_launching
end
add_global_event_handler("KeyDown", "__buildat_trust_f9", function(_, event_data)
	if event_data["Key"]:GetInt() == overlay_key_of() and
			not event_data["Repeat"]:GetBool() then
		trust_shown = not trust_shown
		log:info("overlay key: trusted overlay " .. (trust_shown and "shown" or "hidden"))
	end
end)
Safe.SubscribeToEvent("Update", function(_, event_data)
	if trust_sample == nil and not is_web then
		trust_sample = ui.root:CreateChild("UIElement")
		trust_sample:SetName("__trusted_hidden_trust_color")
		trust_sample.defaultStyle = cache:GetResource("XMLFile",
				"own:ui_utils/res/style.xml")
		trust_sample:SetLayout(LM_HORIZONTAL, 6, IntRect(0, 0, 0, 0))
		trust_sample:SetAlignment(HA_RIGHT, VA_TOP)
		trust_sample:SetPosition(-8, 8)
		trust_sample.priority = 2000
		local line = trust_sample
		local label = line:CreateChild("Text")
		label:SetStyleAuto()
		label.text = "Starport trust color: "
		local row = math.max(12, label.rowHeight)
		-- Two thirds of a text row high and twice as wide (user), on the
		-- row's middle
		local h = math.floor(row * 2 / 3 + 0.5)
		-- A gap of its own: the layout's spacing left none here
		line:CreateChild("UIElement"):SetFixedSize(8, h)
		local swatch = line:CreateChild("BorderImage")
		swatch:SetFixedSize(2 * h, h)
		swatch:SetVerticalAlignment(VA_CENTER)
		swatch.color = Color(trust_rgb[1], trust_rgb[2], trust_rgb[3], 1)
	end
	-- No value at all when not connected, which tostring() refuses
	local address = __buildat_server_address()
	-- **A game with no Buildat server is a game too**
	-- ([OVERLAY_IN_LUANTI]): luanti_client's connection is its own, and
	-- it says it has a world up through ui_utils.set_in_game, which the
	-- error dialogs read as well (client/sandbox.lua)
	local uu = package.loaded["buildat/extension/ui_utils"]
	local in_game = address ~= nil or (uu ~= nil and uu.in_app == true) or
			launching_local()
	if in_game ~= trust_in_game then
		trust_in_game = in_game
		trust_shown = not trust_in_game
	end
	local show = trust_shown
	-- [STARPORT_RECOMMENDS]: new Aittas are offered on the launcher's
	-- screen only, never over a game; a newer version too ([VERSION_CHECK])
	if not trust_in_game then
		offer_timer = offer_timer + (event_data and
				event_data:GetFloat("TimeStep") or 0)
		if offer_timer >= 0.5 then
			offer_timer = 0
			local sp = starport_module()
			if sp and sp.offer_aittas then
				sp.offer_aittas()
			end
			if sp and sp.offer_version then
				sp.offer_version()
			end
		end
	end
	-- **The overlay open in a game frees the mouse** (user, 2026-10-07):
	-- the cursor shown and the game's mouse look still (GetMouseMove reads
	-- nought), given back as it closes
	local open = show and trust_in_game == true
	if open ~= mouse.overlay_open then
		mouse.overlay_open = open
		if open then
			mouse.saved_mode = input:GetMouseMode()
			input:SetMouseChangeReason("the overlay open")
			input:SetMouseMode(MM_FREE)
			input:SetMouseVisible(true)
		elseif mouse.hide_wanted then
			input:SetMouseChangeReason("the overlay closed")
			input:SetMouseMode(mouse.saved_mode or MM_ABSOLUTE)
			input:SetMouseVisible(false)
		end
	end
	if show ~= trust_sample_shown then
		trust_sample_shown = show
		-- Said when it changes ([TRUST_OVERLAY_LEAVE]): the sample gone
		-- after a leave was the user's report, and this is the first
		-- thing to read
		log:info("trust colour sample " .. (show and "shown" or "hidden") ..
				" (server address " .. tostring(address) .. ", in game " ..
				tostring(trust_in_game) .. ")")
	end
	-- The colour's own line only until the starport extension is there
	-- to build the buttons on the colour. Written as it changes: a row is
	-- made with its visibility
	if show ~= rows_applied[1] or id_rows ~= rows_applied[2] or
			#id_rows ~= rows_applied[3] or trust_sample ~= rows_applied[4] then
		rows_applied[1], rows_applied[2], rows_applied[3], rows_applied[4] =
				show, id_rows, #id_rows, trust_sample
		if trust_sample then
			trust_sample.visible = show and #id_rows == 0
		end
		for _, r in ipairs(id_rows) do
			r.visible = show
		end
	end
	if show then
		id_timer = id_timer + (event_data and event_data:GetFloat("TimeStep") or 0)
		if id_timer >= 0.5 or id_signature == nil then
			id_timer = 0
			local sp = starport_module()
			if is_web then
				local hearths, sig = {}, {}
				for _, url in ipairs(sp and sp.starport_urls and
						sp.starport_urls() or {}) do
					local h = sp.recommended_hearth and sp.recommended_hearth(url)
					if h then
						hearths[#hearths + 1] = {url = url, hearth = h}
						sig[#sig + 1] = url .. "|" .. h
					end
				end
				sig = table.concat(sig, "\n")
				if sig ~= id_signature and sp then
					id_signature = sig
					rebuild_web_rows(hearths, sp)
					log:info("trusted overlay: " .. #hearths .. " Discuss button(s)")
				end
				return
			end
			local ids = sp and sp.logged_in_ids() or {}
			local sig = {(sp and "" or "no extension") .. "|" ..
					tostring(__buildat_discuss_label and __buildat_discuss_label())}
			for _, id in ipairs(ids) do
				sig[#sig + 1] = id.url .. "|" .. id.name .. "|" ..
						tostring(sp.recommended_hearth and
						sp.recommended_hearth(id.url))
			end
			sig = table.concat(sig, "\n")
			if sig ~= id_signature and sp then
				id_signature = sig
				rebuild_id_rows(ids, sp)
				log:info("trusted overlay: " .. #ids .. " Starport ID line(s)")
			end
		end
	end
end)

return {trust_color = trust_color, trust_code_text = trust_code_text}
-- vim: set noet ts=4 sw=4:
