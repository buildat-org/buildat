-- Logic ([KIT] stage 4l): a gate between signals. Inputs `a` and `b`
-- take a level: false, 0, "" and a signal's "off" are off, anything
-- else (a signal with no value too, a button's "pressed") is on; `a_off`
-- and `b_off` set them off (a button's "released"). `out` signals its
-- result as it changes (true or false) and "on" or "off" with it.
--   and, or, xor: of a and b
--   not: of a (on at the start, a being off)
--   latch: on as a goes on, off as b goes on (b's reset first when both)
--   pulse: on as a goes on, off `time` seconds after (a new a starts it
--          over)
local function level(v)
	return v ~= false and v ~= 0 and v ~= "" and v ~= "off"
end

local function result(c)
	local m, a, b = c.params.mode, c.state.a, c.state.b
	if m == "and" then
		return a and b
	elseif m == "or" then
		return a or b
	elseif m == "xor" then
		return a ~= b
	elseif m == "not" then
		return not a
	end
	return c.state.out
end

local function set_out(c, on, by)
	if c.state.out == on then
		return
	end
	c.state.out = on
	c:log(c.params.mode, on and "on" or "off", by and ("by " .. c:name(by)) or "")
	c:emit("out", on)
	c:emit(on and "on" or "off")
end

return {
	version = 1,
	no_position = true,
	params = {
		mode = {type = "string", default = "and",
			choices = {"and", "or", "xor", "not", "latch", "pulse"}},
		time = {type = "number", default = 1, min = 0.05, max = 3600},
	},
	state = {
		a = {default = false},
		b = {default = false},
		out = {default = false, shared = true},
	},
	about = {
		what = "A gate between signals: and, or, xor, not, latch or pulse.",
		inputs = {
			a = "Sets a. Value: false, 0, \"\" and \"off\" are off, anything else (none too) on.",
			b = "Sets b, a latch's reset. Value: as a's.",
			a_off = "Sets a off.",
			b_off = "Sets b off.",
		},
		outputs = {
			out = "The result changed. Value: true or false.",
			on = "The result went on.",
			off = "The result went off.",
		},
	},
	inputs = {a = "any", b = "any", a_off = "none", b_off = "none"},
	outputs = {out = "bool", on = "none", off = "none"},
	on_start = function(c)
		if c.params.mode == "not" then
			set_out(c, true)
		end
	end,
	on_input = function(c, input, value, by)
		local m = c.params.mode
		if input == "a" then
			c.state.a = level(value)
		elseif input == "b" then
			c.state.b = level(value)
		elseif input == "a_off" then
			c.state.a = false
		elseif input == "b_off" then
			c.state.b = false
		end
		if m == "latch" then
			if input == "b" and c.state.b then
				set_out(c, false, by)
			elseif input == "a" and c.state.a then
				set_out(c, true, by)
			end
		elseif m == "pulse" then
			-- Each a that is on (a signal with no value is a new one)
			if input == "a" and c.state.a then
				set_out(c, true, by)
				c:after(c.params.time, "pulse")
			end
		else
			set_out(c, result(c), by)
		end
	end,
	on_timer = function(c, name)
		if name == "pulse" then
			set_out(c, false)
		end
	end,
	on_params = function(c)
		if c.params.mode ~= "latch" and c.params.mode ~= "pulse" then
			set_out(c, result(c))
		end
	end,
}
