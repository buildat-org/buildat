-- kit/bot's client part ([KIT_BOT_DIFFICULTY]): while the bot asks this
-- player (its shared state asker, kit/spawner's "ask"), a dialog in the
-- middle of the screen: its aim, reaction and speed, each with - and +
-- (buttons named "bot <knob> -" and "bot <knob> +"), "Add" and "Cancel";
-- the pointer free while it is up. Add sends "kit:ui_text" "<id> <aim>
-- <reaction> <speed>", Cancel "<id> cancel". The values start at the last
-- this client sent (this run), else the bot's.
-- simplified: pixel sizes in the default style, not the HUD's percents
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local KNOBS = {
	{key = "aim", label = "Aim", unit = "%", step = 25, min = 0, max = 100},
	{key = "reaction", label = "Reaction", unit = " s", step = 0.2, min = 0,
		max = 3},
	{key = "speed", label = "Speed", unit = "%", step = 10, min = 30, max = 100},
}
-- [KIT_BOT_DRIVE] a driving bot's (its state `driving`): one row, Add
-- sends "<id> <skill>"
local DRIVE_KNOBS = {
	{key = "skill", label = "Skill", unit = "%", step = 10, min = 0, max = 100},
}
local function knobs_of(e)
	return e.state.driving == true and DRIVE_KNOBS or KNOBS
end
local WEB = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil
local last = nil
-- (one at a time: a second bot's replaces it)
local box = nil
-- (the bot answered: not asked again until its asker is gone)
local answered = {}

local function close(id)
	if box and (not id or box.id == id) then
		box.win:Remove()
		box = nil
	end
end

local function button(parent, s, name, fn)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	b:SetName(name)
	b.minHeight, b.minWidth = 26, 34
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(s)
	t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	b.minWidth = math.max(b.minWidth, t.width + 16)
	magic.SubscribeToEvent(b, "Released", fn)
	return b
end

local function shown(k, v)
	-- (0.2 steps: no 0.6000000001)
	return tostring(math.floor(v * 10 + 0.5) / 10):gsub("%.0$", "") .. k.unit
end

local function open(e)
	close()
	if not magic.ui.root.defaultStyle then
		magic.ui.root.defaultStyle = magic.cache:GetResource("XMLFile",
				"ui_utils/res/style.xml")
	end
	local win = magic.ui.root:CreateChild("Window")
	win:SetStyleAuto()
	win:SetLayout(magic.LM_VERTICAL, 6, magic.IntRect(14, 10, 14, 10))
	win:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	win.priority = 100
	local title = win:CreateChild("Text")
	title:SetStyleAuto()
	title:SetText("Add bot")
	box = {win = win, v = {}, id = e.id}
	for _, k in ipairs(knobs_of(e)) do
		local v = last and last[k.key] or tonumber(e.state[k.key])
		box.v[k.key] = math.max(k.min, math.min(k.max, v or k.min))
		local row = win:CreateChild("UIElement")
		row:SetLayout(magic.LM_HORIZONTAL, 6, magic.IntRect(0, 0, 0, 0))
		local l = row:CreateChild("Text")
		l:SetStyleAuto()
		l:SetText(k.label)
		l.minWidth = 90
		local val
		local function step(d)
			return function()
				local b = box
				if not b then
					return
				end
				b.v[k.key] = math.max(k.min, math.min(k.max, b.v[k.key] + d))
				b.changed = true
				val:SetText(shown(k, b.v[k.key]))
				e:log("bot dialog: " .. k.key .. " " .. shown(k, b.v[k.key]))
			end
		end
		button(row, "-", "bot " .. k.key .. " -", step(-k.step))
		val = row:CreateChild("Text")
		val:SetStyleAuto()
		val:SetText(shown(k, box.v[k.key]))
		val.minWidth = 60
		val:SetTextAlignment(magic.HA_CENTER)
		button(row, "+", "bot " .. k.key .. " +", step(k.step))
	end
	local row = win:CreateChild("UIElement")
	row:SetLayout(magic.LM_HORIZONTAL, 10, magic.IntRect(0, 6, 0, 0))
	local function answer(text)
		buildat.send_packet("kit:ui_text", e.id .. " " .. text)
		answered[e.id] = true
		e:log("bot dialog: sent " .. text)
		close()
	end
	button(row, "Add", "bot add", function()
		local v = box.v
		last = last or {}
		for k, x in pairs(v) do
			last[k] = x
		end
		if v.skill then
			return answer(string.format("%g", v.skill))
		end
		answer(string.format("%g %g %g", v.aim, math.floor(v.reaction * 10 + 0.5) / 10,
				v.speed))
	end)
	box.cancel = function() answer("cancel") end
	button(row, "Cancel", "bot cancel", box.cancel)
	ui_utils.dim_behind(win, "kit bot dialog")
	-- The pointer this player's to click with (as kit/ui_panel's)
	ui_utils.wants_clicks(win)
	local input = magic.input
	if not input.mouseVisible or (WEB and input:IsMouseLocked()) then
		input:SetMouseVisible(true, "Kit's bot dialog")
		if WEB then
			input:SetMouseMode(magic.MM_ABSOLUTE)
		end
	end
	local shown_v = {}
	for _, k in ipairs(knobs_of(e)) do
		shown_v[#shown_v + 1] = k.key .. " " .. string.format("%g", box.v[k.key])
	end
	e:log("bot dialog shown, the pointer free: " .. tostring(input.mouseVisible) .. ": " ..
			table.concat(shown_v, " "))
end

-- [UI_MODAL_DIM] A click off it is its Cancel (it was eaten), while no knob
-- has been moved: a choice made in it is not lost to a stray click
magic.SubscribeToEvent("UIMouseClick", function(_, d)
	local b = box
	if not b or b.changed then
		return
	end
	local rp, p, sz = magic.ui.root.position, b.win.screenPosition, b.win.size
	local x, y = d:GetInt("X") - rp.x, d:GetInt("Y") - rp.y
	if x < p.x or y < p.y or x >= p.x + sz.x or y >= p.y + sz.y then
		b.cancel()
	end
end)

return {
	on_state = function(e, key)
		local mine = tonumber(e.state.asker) == e.you and (e.you or 0) ~= 0
		if not mine then
			answered[e.id] = nil
		end
		if mine and (answered[e.id] or (box and box.id == e.id)) then
			return
		end
		-- (once its knobs are here too: the keys come one by one)
		if mine then
			if e.state.driving == nil then
				return
			end
			for _, k in ipairs(knobs_of(e)) do
				if tonumber(e.state[k.key]) == nil then
					return
				end
			end
			open(e)
		else
			close(e.id)
		end
	end,
	on_remove = function(e)
		close(e.id)
	end,
}
