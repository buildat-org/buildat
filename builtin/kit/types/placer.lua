-- A placer ([KIT_CTF]): any item of use kind "use" puts something down.
-- A player in its scene clicking with `item` held takes one of it (with
-- `consume`) and gets a copy of `prefab` `distance` m ahead of them, in the
-- cell at their feet's level there; `signal` (an input of the copy's, ""
-- none) is sent to it then, as by them (kit/explosive's "arm"). Its
-- output placed: the copy's id.
-- simplified: put where their feet are, ahead, whatever is there (into a
-- wall too); the copy's own type may fall (c:move)

return {
	version = 1,
	players = true,
	look = {shape = "box", size = 0.25, color = "#806040"},
	params = {
		item = {type = "string", default = "", choices_from = "items"},
		prefab = {type = "prefab", default = ""},
		distance = {type = "number", default = 1.5, min = 0, max = 6},
		signal = {type = "string", default = "arm"},
		consume = {type = "bool", default = true},
	},
	outputs = {placed = "entity"},
	on_item = function(c, item, action, target, by)
		if action ~= "use" or item ~= c.params.item or c.params.prefab == "" then
			return
		end
		local p
		for _, q in ipairs(c.players or {}) do
			if q.id == c.player then
				p = q
			end
		end
		if not (p and p.pos and not p.away) then
			return
		end
		if c.params.consume and not c:take(item, 1) then
			return
		end
		-- yaw in degrees, 0 towards +z, 90 towards +x
		local a = math.pi / 180 * (tonumber(p.yaw) or 0)
		local d = c.params.distance
		local pos = {math.floor(p.pos[1] + math.sin(a) * d + 0.5),
			math.floor(p.pos[2] + 0.5),
			math.floor(p.pos[3] + math.cos(a) * d + 0.5)}
		local id = c:spawn{prefab = c.params.prefab, pos = pos}
		c:log(c:name(by), "places", c.params.prefab, "at", pos[1], pos[2],
			pos[3], "as", id)
		if id and c.params.signal ~= "" then
			c:send(id, c.params.signal)
		end
		c:emit("placed", id)
	end,
}
