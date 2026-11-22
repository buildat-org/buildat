-- A parameter set in play with no code ([KIT_PLAYER_PARAMS]): "set" sets
-- `param` of the `target` entity's `target_type` component (c:set_param), to
-- `value` (source "value"; the text "true", "false", a number, or three
-- numbers "x, y, z" are taken as such, any other as text) or to the
-- signal's number times `scale` plus `offset`, held within `min` and `max`
-- (source "signal": a stat to a bar's size); "reset" puts the target's own
-- back. `to` "player": for the player the signal carries alone (their
-- camera, their body's gravity, their HUD; a signal by no player does
-- nothing), "everyone": for all. Until Stop, as c:set_param's.
-- simplified: a text parameter whose value is a number's text ("12") or
-- "true" cannot be set from `value` (it goes as a number or a boolean)
local function parse(s)
	if s == "true" then
		return true
	elseif s == "false" then
		return false
	end
	local n = tonumber(s)
	if n and n == n and n - n == 0 then
		return n
	end
	local x, y, z = s:match("^%s*(%-?[%d.]+)%s*,%s*(%-?[%d.]+)%s*,%s*(%-?[%d.]+)%s*$")
	if x and tonumber(x) and tonumber(y) and tonumber(z) then
		return {tonumber(x), tonumber(y), tonumber(z)}
	end
	return s
end

return {
	version = 1,
	no_position = true,
	params = {
		target = {type = "entity", default = 0},
		target_type = {type = "string", default = "kit/controls"},
		param = {type = "string", default = "camera"},
		value = {type = "string", default = "chase"},
		to = {type = "string", default = "player",
			choices = {"player", "everyone"}},
		source = {type = "string", default = "value",
			choices = {"value", "signal"}},
		scale = {type = "number", default = 1, min = -1000000, max = 1000000},
		offset = {type = "number", default = 0, min = -1000000, max = 1000000},
		min = {type = "number", default = -1000000, min = -1000000,
			max = 1000000},
		max = {type = "number", default = 1000000, min = -1000000,
			max = 1000000},
	},
	about = {
		group = "Logic",
		what = "Sets a parameter of another entity in play, for the player who set it off or for everyone: a camera, a gravity, a bar's size.",
		inputs = {
			set = "Sets the parameter: to its value, or (source signal) to the signal's number through scale, offset, min and max.",
			reset = "Puts the target's own value back.",
		},
		params = {
			target = "The entity whose parameter it sets (for a player's camera, the entity holding the scene's kit/controls).",
			target_type = "The type of the target's component the parameter is of, as kit/controls or kit/walker.",
			param = "The parameter's name, as camera, distance or gravity.",
			value = "The value set (source value): true, false, a number, three numbers as x, y, z, or a text.",
			to = "player: for the player who set it off alone; everyone: for all.",
			source = "value: the value above; signal: the signal's number through scale, offset, min and max.",
			scale = "The signal's number is multiplied by this (source signal).",
			offset = "Then this is added (source signal).",
			min = "The least value set (source signal).",
			max = "The greatest value set (source signal).",
		},
	},
	inputs = {set = "any", reset = "none"},
	on_input = function(c, input, value, by)
		local p = c.params
		local who = type(by) == "string" and by:match("^player:%d+$") and by
		if p.to == "player" and not who then
			c:log(input, "by", c:name(by), "(no player): nothing set")
			return
		end
		if p.target == 0 then
			c:log(input, ": no target")
			return
		end
		local v
		if input == "set" and p.source == "signal" then
			v = tonumber(value)
			if not v or v ~= v or v - v ~= 0 then
				c:log("set by", tostring(value), "(no number): nothing set")
				return
			end
			v = math.max(p.min, math.min(p.max, v * p.scale + p.offset))
		elseif input == "set" then
			v = parse(p.value)
		end
		c:set_param(p.target, p.target_type, p.param, v,
				who and p.to == "player" and {player = who} or nil)
		c:log(input, p.param, "of", p.target, v ~= nil and "to " ..
				(type(v) == "table" and table.concat(v, ", ") or tostring(v)) or "back",
				who and p.to == "player" and "for " .. c:name(who) or "for everyone")
	end,
}
