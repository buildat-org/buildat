-- Lights Out ([KIT_GENERATORS], a generator): a size x size board of
-- kit/lights_out_tile in front of it (+z), built in the editor as it is
-- placed and as its parameters change. A tile's press toggles it and its
-- four neighbours; it counts the lit tiles (drawn over it) and signals
-- "solved" when a press leaves none lit. seed: the start's pattern, made
-- by presses from the dark board so that it can be solved (0: the middle
-- tile's press; another seed, 2 x size presses of its own)
-- simplified: a live edit's rebuild while Running leaves the count off
-- until the next Play (the new tiles' start adds theirs)
local DIRS = {{0, 0}, {1, 0}, {-1, 0}, {0, 1}, {0, -1}}

-- A Lehmer generator from the seed, the same on every server
local function rng(seed)
	local s = math.floor(seed) % 2147483647
	if s <= 0 then
		s = s + 2147483646
	end
	return function(n)
		s = s * 16807 % 2147483647
		return s % n
	end
end

return {
	version = 1,
	params = {
		size = {type = "number", default = 5, min = 5, max = 7},
		seed = {type = "number", default = 0, min = 0, max = 1000000},
	},
	look = {shape = "box", size = {0.6, 0.3, 0.6}, color = "#6040a0",
		text = "lit"},
	state = {lit = {default = 0, shared = true}},
	about = {
		group = "Logic",
		what = "A puzzle: a board of tiles, a press flips a tile and its neighbours.",
		inputs = {
			add = "Changes the lit count. Value: a number; its tiles send 1 or -1.",
		},
		outputs = {
			solved = "A press left no tile lit.",
		},
	},
	inputs = {add = "number"},
	outputs = {solved = "none"},
	on_build = function(c)
		local n = math.floor(c.params.size)
		local lit = {}
		local function press(i, j)
			for _, d in ipairs(DIRS) do
				local a, b = i + d[1], j + d[2]
				if a >= 1 and a <= n and b >= 1 and b <= n then
					local k = (b - 1) * n + a
					lit[k] = not lit[k]
				end
			end
		end
		if c.params.seed == 0 then
			press(math.floor((n + 1) / 2), math.floor((n + 1) / 2))
		else
			local r = rng(c.params.seed)
			for _ = 1, 2 * n do
				press(r(n) + 1, r(n) + 1)
			end
		end
		local ids, on = {}, 0
		for j = 1, n do
			for i = 1, n do
				local k = (j - 1) * n + i
				on = on + (lit[k] and 1 or 0)
				ids[k] = c:child{type = "kit/lights_out_tile",
					name = "tile " .. i .. "," .. j,
					pos = {i - (n + 1) / 2, 0, j},
					params = {lit = lit[k] == true}}
			end
		end
		for j = 1, n do
			for i = 1, n do
				local k = (j - 1) * n + i
				for _, d in ipairs(DIRS) do
					local a, b = i + d[1], j + d[2]
					if a >= 1 and a <= n and b >= 1 and b <= n then
						c:link(ids[k], "pressed", ids[(b - 1) * n + a], "toggle")
					end
				end
				c:link(ids[k], "changed", 0, "add")
			end
		end
		c:log("built", n .. "x" .. n, on, "lit")
	end,
	on_input = function(c, input, value)
		local was = c.state.lit
		c.state.lit = was + (type(value) == "number" and value or 0)
		c:log("lit", c.state.lit)
		if was > 0 and c.state.lit <= 0 then
			c:log("solved")
			c:emit("solved")
		end
	end,
}
