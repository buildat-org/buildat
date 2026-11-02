-- A text on the players' screens ([KIT_UI_COMPONENTS], stage 4m): a
-- score, a countdown, a hint. In `text`, {value} is the last value on
-- "value", [<action>] each player's key for it, | a new line. Where:
-- `anchor` (a corner, an edge's middle or the centre) and x, y, UI units
-- in from it, on the screen or in its `panel` (a kit/ui_panel: shown
-- while it is). Who sees it: everyone, or with `to` "player" each player
-- their own, the player who set a signal off the one it changes (a signal
-- by no player, everyone's). "show", "hide" and "toggle" show it;
-- `shown`: at the start. Edit mode draws every UI component where it
-- would be, to click on
local function view(c, by)
	if c.params.to ~= "player" or not c.player then
		return c.state
	end
	c.state.own[by] = c.state.own[by] or {}
	return c.state.own[by]
end

return {
	version = 1,
	ui = {kind = "text", text = "param:text", anchor = "param:anchor",
		x = "param:x", y = "param:y", size = "param:size",
		color = "param:color", background = "param:background",
		panel = "param:panel"},
	params = {
		text = {type = "string", default = "Score: {value}"},
		anchor = {type = "string", default = "top", choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {type = "number", default = 0, min = -2000, max = 2000},
		y = {type = "number", default = 40, min = -2000, max = 2000},
		size = {type = "number", default = 18, min = 8, max = 64},
		color = {type = "string", default = "#ffffff"},
		background = {type = "string", default = "none"},
		panel = {type = "entity", default = 0},
		to = {type = "string", default = "everyone",
			choices = {"everyone", "player"}},
		shown = {type = "bool", default = true},
	},
	state = {
		shown = {default = true, shared = true},
		value = {default = "", shared = true},
		own = {default = {}, per_player = true},
	},
	inputs = {value = "any", clear = "none", show = "none", hide = "none",
		toggle = "none"},
	on_start = function(c)
		c.state.shown = c.params.shown
	end,
	on_params = function(c, changed)
		if changed.shown ~= nil then
			c.state.shown = c.params.shown
		end
	end,
	on_input = function(c, input, value, by)
		local v = view(c, by)
		if input == "value" or input == "clear" then
			v.value = input == "value" and value ~= nil and value or ""
		elseif input == "toggle" then
			local now = v.shown
			if now == nil then
				now = c.state.shown
			end
			v.shown = not now
		else
			v.shown = input == "show"
		end
		c:log(input, v == c.state and "for everyone" or "for " .. c:name(by))
	end,
}
