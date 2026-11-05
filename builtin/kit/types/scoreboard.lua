-- A scoreboard: the players' scores, on every player's screen. A score is
-- the player's own ([KIT] stage 4d: kit/score on their entity, which it
-- reads for every player): "add" gives the player who set the signal off
-- a point, "reset" makes every score 0. Who it was is the signal's `by`,
-- carried along the links: a zone a player walks into, linked to "add",
-- scores them. Players with no points are left out. "changed" carries
-- its text ([KIT_UI_COMPONENTS]): linked to a kit/ui_text's "value", the
-- board where the builder lays it out
local function show(c)
	local list = {}
	for _, p in ipairs(c.players or {}) do
		local s = p.state["kit/score"] and p.state["kit/score"].score or 0
		if s ~= 0 then
			list[#list + 1] = {p.name, s}
		end
	end
	table.sort(list, function(a, b)
		if a[2] ~= b[2] then
			return a[2] > b[2]
		end
		return a[1] < b[1]
	end)
	local t = {}
	for _, e in ipairs(list) do
		t[#t + 1] = e[1] .. " " .. e[2]
	end
	c.state.text = c.params.title .. ": " .. (#t > 0 and
			table.concat(t, ", ") or "-")
end

return {
	version = 2,
	players = true,
	hud = "text",
	look = {shape = "box", size = 0.25, color = "#e04080"},
	params = {title = {cat = "hud", type = "string", default = "Score"}},
	state = {text = {default = "", shared = true}},
	inputs = {add = "none", reset = "none"},
	outputs = {changed = "string:text"},
	on_start = show,
	on_input = function(c, input, value, by)
		if input == "reset" then
			for _, p in ipairs(c.players) do
				c:send(p.id, "reset")
			end
		elseif c.player then
			c:send(c.player, "add", 1)
		else
			c:log("no player in", by, "to score")
			return
		end
		-- The scores are the players' once their runs are done: shown then
		c:after(0)
	end,
	on_timer = function(c)
		show(c)
		c:log(c.state.text)
		c:emit("changed", c.state.text)
	end,
}
