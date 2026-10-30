-- A scoreboard: a score a player, on every player's screen. "add" gives
-- the player who set the signal off a point, "reset" clears them all.
-- Who it was is the signal's `by`, carried along the links: a zone a
-- player walks into, linked to "add", scores them
local function show(c)
	local names = {}
	for name in pairs(c.state.scores) do
		names[#names + 1] = name
	end
	table.sort(names, function(a, b)
		local sa, sb = c.state.scores[a], c.state.scores[b]
		if sa ~= sb then
			return sa > sb
		end
		return a < b
	end)
	local t = {}
	for _, name in ipairs(names) do
		t[#t + 1] = name .. " " .. c.state.scores[name]
	end
	c.state.text = c.params.title .. ": " .. (#t > 0 and
			table.concat(t, ", ") or "-")
end

return {
	version = 1,
	hud = "text",
	look = {shape = "box", size = 0.25, color = "#e04080"},
	params = {title = {type = "string", default = "Score"}},
	state = {
		scores = {default = {}},
		text = {default = "", shared = true},
	},
	inputs = {"add", "reset"},
	outputs = {"changed"},
	on_start = show,
	on_input = function(c, input, value, by)
		local scores = c.state.scores
		if input == "reset" then
			scores = {}
		else
			local name = by:match("^player:(.*)$")
			if not name then
				c:log("no player in", by, "to score")
				return
			end
			scores[name] = (scores[name] or 0) + 1
		end
		c.state.scores = scores
		show(c)
		c:log(c.state.text)
		c:emit("changed")
	end,
}
