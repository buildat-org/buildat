-- Deepcore's harvester ([KIT_RTS], kit_plan 4z37zzo): on its own it finds ore
-- near it or its team's HQ (`ore` voxels with a cell beside them it can stand in, within `scan`
-- cells across and a few up and down: c:voxels_at), drives beside the nearest,
-- mines it a cell at a time (`mine_time` s, `per_cell` money's worth into its
-- cargo; the cell becomes air) until it carries `cargo`, then drives to its
-- team's nearest refinery (a unit named "refinery" of its team: c.units) and
-- unloads there, the money its team's score (kit/team "add"; the round's
-- money). Ordered somewhere (kit/unit's walk, which wins while it waits: it
-- is before kit/unit on its entity), it goes there and looks for ore from
-- there. Its state cargo is shared (drawn by nothing yet).
-- simplified: no queue at the refinery; stuck on its way home (no nearer in
-- 4 s) it finds its way again; an ore cell it could not reach is
-- skipped for a minute
local function cell(p)
	return {math.floor(p[1] + 0.5), math.floor(p[2] + 0.5), math.floor(p[3] + 0.5)}
end

local function d2(a, b)
	return (a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2
end

local function team_of(c)
	local u = c:params_of("kit/unit")
	return u and u.team or ""
end

-- The nearest ore cell to p with a standing cell beside it: ore {x, y, z}, stand
local function seek(c, p)
	local a = cell(p)
	local r = math.floor(c.params.scan / 2)
	local x0, y0, z0 = a[1] - r, a[2] - 2, a[3] - r
	local sx, sy, sz = 2 * r + 1, 6, 2 * r + 1
	local v = c:voxels_at({x0, y0, z0}, {sx, sy, sz})
	local function at(x, y, z)
		if x < x0 or y < y0 or z < z0 or x >= x0 + sx or y >= y0 + sy or z >= z0 + sz then
			return ""
		end
		return v[1 + (x - x0) + sx * ((z - z0) + sz * (y - y0))] or ""
	end
	local function stands(x, y, z)
		local b = at(x, y - 1, z)
		return at(x, y, z) == "air" and at(x, y + 1, z) ~= "" and
			(at(x, y + 1, z) == "air" or y + 1 >= y0 + sy) and b ~= "air" and b ~= ""
	end
	local skip = c.state.skip or {}
	local best, bs, bd = nil, nil, 1e9
	local ore = c.params.ore
	local i = 0
	for y = y0, y0 + sy - 1 do
		for z = z0, z0 + sz - 1 do
			for x = x0, x0 + sx - 1 do
				i = i + 1
				if v[i] == ore and not skip[x .. "," .. y .. "," .. z] then
					for _, o in ipairs({{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1},
							{1, -1, 0}, {-1, -1, 0}, {0, -1, 1}, {0, -1, -1}}) do
						local s = {x + o[1], y + o[2], z + o[3]}
						if stands(s[1], s[2], s[3]) then
							local d = d2(s, a)
							if d < bd then
								best, bs, bd = {x, y, z}, s, d
							end
						end
					end
				end
			end
		end
	end
	return best, bs
end

local function home(c)
	local team = team_of(c)
	local best, bd = nil, 1e18
	for _, u in ipairs(c.units or {}) do
		if u.name == "refinery" and u.team == team then
			local d = d2(u.pos, c.pos)
			if d < bd then
				best, bd = u, d
			end
		end
	end
	return best, bd
end

local function think(c)
	local s = c.state
	c:after(c.params.think, "think")
	if s.ordered then
		s.ordered = s.ordered - 1
		if s.ordered > 0 and (c.moving or s.ordered > 76) then
			return
		end
		s.ordered = false
		s.mode = "seek"
	end
	if s.cargo >= c.params.cargo then
		local r, d = home(c)
		if not r then
			if s.mode ~= "no_refinery" then
				c:log("no refinery")
			end
			s.mode = "no_refinery"
			c:propose_move(nil)
			return
		end
		if d < 3.4 ^ 2 then
			for _, t in ipairs(c.teams or {}) do
				if t.params.name == team_of(c) then
					c:send(t.id, "add", s.cargo)
				end
			end
			c:log("unloaded " .. s.cargo .. " at " .. r.id)
			s.cargo = 0
			s.mode = "seek"
			c:propose_move(nil)
		elseif s.mode ~= "home" or not c.moving then
			s.mode, s.near, s.since = "home", math.sqrt(d), c.now
			c:propose_move({to = r.pos, range = 2.6})
		elseif math.sqrt(d) < s.near - 0.5 then
			s.near, s.since = math.sqrt(d), c.now
		elseif c.now - s.since > 4 then
			-- no nearer in 4 s (a building put in its way since its way was
			-- found): its way again next time
			s.mode = "stuck"
			c:propose_move(nil)
		end
		return
	end
	if s.mode == "go" or s.mode == "mine" then
		local o, st = s.ore, s.stand
		local here = d2({c.pos[1], 0, c.pos[3]}, {st[1], 0, st[3]}) < 1.0
		if here then
			if c:voxel_at(o[1], o[2], o[3]) ~= c.params.ore then
				s.mode = "seek"
			elseif s.mode == "go" then
				s.mode = "mine"
				s.since = c.now
				c:propose_move(nil)
			elseif c.now - (s.since or 0) >= c.params.mine_time then
				c:set_voxels_at({{o[1], o[2], o[3], "air"}})
				s.cargo = s.cargo + c.params.per_cell
				s.mined = (s.mined or 0) + 1
				s.mode = "seek"
				c:effect({at = {o[1], o[2], o[3]}, count = 12, shape = "square",
					colors = {"#40e0b0", "#20a080", "#808080", "#606060"},
					speed_min = 0.5, speed_max = 2, ttl_max = 0.6, size_max = 0.12})
			end
			return
		end
		s.tries = (s.tries or 0) + 1
		if s.tries > 24 then
			-- not got there: that one later
			local skip = s.skip or {}
			skip[o[1] .. "," .. o[2] .. "," .. o[3]] = c.now + 60
			s.skip = skip
			s.mode = "seek"
		end
		return
	end
	-- seek
	local skip = s.skip or {}
	for k, t in pairs(skip) do
		if t < c.now then
			skip[k] = nil
		end
	end
	s.skip = skip
	-- (round itself, else round its team's HQ: the base's ore pockets)
	local o, st = seek(c, c.pos)
	if not o then
		for _, u in ipairs(c.units or {}) do
			if not o and u.name == "hq" and u.team == team_of(c) then
				o, st = seek(c, u.pos)
			end
		end
	end
	if not o then
		if s.mode ~= "none" then
			c:log("no ore near")
		end
		s.mode = "none"
		c:propose_move(nil)
		return
	end
	s.ore, s.stand, s.tries = o, st, 0
	s.mode = "go"
	c:propose_move({to = {st[1], st[2] - 0.5, st[3]}, range = 0.3})
end

return {
	version = 1,
	about = {
		group = "Creatures",
		what = "A Deepcore harvester: mines ore near it and carries it to its team's refinery for money.",
		params = {
			ore = "The voxel it mines.",
			cargo = "How much it carries before it goes to unload.",
			per_cell = "Money a cell of ore is worth.",
			mine_time = "Seconds a cell takes to mine.",
			scan = "Cells across the square it looks for ore in.",
			think = "Seconds between its looks round.",
		},
	},
	component = true,
	creature = true,
	world_voxels = true,
	reads_units = true,
	reads_teams = true,
	params = {
		ore = {type = "voxel", default = "kit/ore"},
		cargo = {type = "number", default = 50, min = 1, max = 1000},
		per_cell = {type = "number", default = 10, min = 1, max = 1000},
		mine_time = {type = "number", default = 0.8, min = 0.1, max = 10},
		scan = {type = "number", default = 21, min = 3, max = 31},
		think = {type = "number", default = 0.5, min = 0.2, max = 5},
	},
	state = {cargo = {default = 0, shared = true}, mode = {default = "seek"},
		ore = {default = false}, stand = {default = false}, since = {default = 0},
		tries = {default = 0}, near = {default = 0}, ordered = {default = false}, skip = {default = {}},
		mined = {default = 0}},
	on_start = function(c)
		c:after(0.3 + math.random() * 0.5, "think")
	end,
	on_order = function(c, order)
		c.state.ordered = 80
		c.state.mode = "ordered"
		c:propose_move(nil)
	end,
	on_timer = function(c, name)
		if name == "think" then
			think(c)
		end
	end,
}
