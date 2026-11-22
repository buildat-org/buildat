-- Records ([KIT_RECORDS]): each player's best "time" or "score" (a number,
-- by the player; `better` says whether lower or higher wins), kept by their
-- name (kept state: play and a restart never reset them, a builder's "Clear
-- kept state" does). Each value sends best (their best now, by them), a new
-- best new_best (the value, by them) first; a player coming into the round
-- gets their best too. The top `count` go out on board as they change (and
-- at the start): "1. name 12.3|2. ...", a time to a tenth, a score as it is
-- (a kit/sign's or kit/ui_text's {value}); a Clear kept state's empty
-- board within a second.
local function shown(c, v)
	if c.state.kind == "score" then
		return string.format("%.10g", v)
	end
	return string.format("%.1f", math.floor(v * 10 + 0.5) / 10)
end

local function beats(c, a, b)
	if c.params.better == "higher" then
		return a > b
	end
	return a < b
end

local function board(c, always)
	local all = {}
	for name, v in pairs(c.state.bests) do
		all[#all + 1] = {name, v}
	end
	table.sort(all, function(a, b)
		return beats(c, a[2], b[2]) or a[2] == b[2] and a[1] < b[1]
	end)
	local lines = {}
	for i = 1, math.min(c.params.count, #all) do
		lines[i] = i .. ". " .. all[i][1] .. " " .. shown(c, all[i][2])
	end
	local text = table.concat(lines, "|")
	if always or text ~= c.state.board then
		c.state.board = text
		c:emit("board", text)
	end
end

return {
	version = 1,
	no_position = true,
	params = {
		better = {type = "string", default = "lower", choices = {"lower", "higher"}},
		count = {type = "number", default = 5, min = 1, max = 50},
	},
	state = {
		bests = {default = {}, kept = true},
		-- "time" or "score": the last value's kind, how the board shows them
		kind = {default = "time", kept = true},
		board = {default = ""},
	},
	about = {
		group = "Logic",
		what = "Each player's best time or score, kept across rounds and restarts, and the top ones as a board. A timed run: its finish to a kit/stopwatch's stop, the stopwatch's elapsed straight to time here, a crash to the stopwatch's reset (no time sent).",
		inputs = {
			time = "A player's time. Value: its seconds.",
			score = "A player's score. Value: the number.",
		},
		outputs = {
			best = "The player's best, after each value and as they come into the round. Value: the best.",
			new_best = "The player beat their best (or set their first). Value: the new best.",
			board = "The top ones as they change. Value: \"1. name 12.3|2. ...\".",
		},
		params = {
			better = "Whether a lower value (a time) or a higher one (a score) is the better.",
			count = "How many the board shows.",
		},
	},
	inputs = {time = "number", score = "number"},
	outputs = {best = "number", new_best = "number", board = "string"},
	on_start = function(c)
		board(c, true)
		c:after(1, "board")
	end,
	-- simplified: a builder's Clear kept state (and its undo) runs no
	-- handler, so the board is looked at once a second; a player's best on
	-- their HUD stays till their next value. A Kit call on a kept state
	-- set would make this a run at the change.
	on_timer = function(c, name)
		if name == "board" then
			board(c)
			c:after(1, "board")
		end
	end,
	on_join = function(c, by)
		local best = c.state.bests[c:name(by)]
		if best then
			c:emit("best", best, by)
		end
	end,
	on_input = function(c, input, value, by)
		local v = tonumber(value)
		if not v or type(by) ~= "string" or not by:match("^player:%d+$") then
			c:log(input, tostring(value), "by", c:name(by), ": no player's number")
			return
		end
		c.state.kind = input
		local name = c:name(by)
		local old = c.state.bests[name]
		if not old or beats(c, v, old) then
			c.state.bests[name] = v
			c:log(name, "has a new best:", shown(c, v), old and "(was " ..
					shown(c, old) .. ")" or "(the first)")
			c:emit("new_best", v, by)
		end
		c:emit("best", c.state.bests[name], by)
		board(c)
	end,
}
