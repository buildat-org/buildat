-- Deepcore's harvester ([KIT_RTS], kit_plan 4z37zzo): on its own it finds ore
-- its team's refinery reaches, drives beside the one with the shortest way
-- there and on to the refinery, mines it a cell at
-- a time (`mine_time` s, `per_cell` money's worth into its cargo; the cell
-- becomes air) until it carries `cargo`, then drives to its team's nearest
-- refinery (a unit named "refinery" of its team: c.units) and unloads there,
-- the money its team's score (kit/team "add"; the round's money). Ordered
-- somewhere (kit/unit's walk, which wins while it waits: it is before
-- kit/unit on its entity), it goes there and looks for ore from there. Its
-- state cargo is shared (drawn by nothing yet).
--   The ore it reaches: a flood from the refinery over the cells a unit
-- stands in (air over a floor; a step up a cell, a drop of three at most:
-- the pathfinder's), each `ore` cell beside one a place to mine. The World's
-- cells are read in 16^3 chunks as the flood comes to them, both kept in
-- this file's upvalues (the type's: every harvester shares them), a few
-- chunks and `flood` cells a think, redone every `fresh` s (a digger's
-- tunnels seen then); a cell it mines goes into the flood at once. With
-- none reachable it waits where it is (its match tells the team's player);
-- with cargo it unloads first.
--   [KIT_RTS_PLAYTEST_1] (7) Ore in the floor beside a stand is mined too,
-- from the side, `down_cost` m further than ore level with it: one level
-- down a cell sideways, never under or next to a building. Any ore cell
-- with air over it (a floor) is mined only where that leaves a stair
-- (safe(): solid under it, no way up beside the stand over it lost),
-- checked at the flood and again as it starts. The cell mined is a stand
-- one down, in the flood at once, so the cut is a staircase it climbs back
-- (a step up of one cell, the pathfinder's), never a pit. (5) While it
-- mines, ore dust off the face.
-- simplified: no queue at the refinery; a harvester claims the cell it
-- goes for (others pick another); stuck on its way home (no nearer in 6 s)
-- it finds its way again, and an ore cell it gets no nearer to (3 s
-- stopped, 12 s moving) is skipped for a minute; the flood is from the
-- team's first refinery and sees cells, not buildings
local S = 16
local maps = {}

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

-- A cell as one number and back (|x|, |z| < 1024, -64 <= y < 960)
local function key(x, y, z)
	return ((y + 64) * 2048 + (z + 1024)) * 2048 + (x + 1024)
end

local function unkey(k)
	local x = k % 2048
	k = (k - x) / 2048
	local z = k % 2048
	return x - 1024, (k - z) / 2048 - 64, z - 1024
end

-- The shared map of the round (its session's): chunks {t, v}, the nets by
-- team, the claims {ore key = {id, until}}
local function map_of(c)
	local m = maps[c.session]
	if not m or c.now < m.now - 1 then
		-- (none yet, or the round's clock went back: a new round)
		m = {chunks = {}, nets = {}, claims = {}}
		maps[c.session] = m
	end
	m.now = c.now
	return m
end

-- The cell's name; nil: its chunk not read yet and no reads left this run
local function at(m, c, x, y, z)
	local cx, cy, cz = math.floor(x / S), math.floor(y / S), math.floor(z / S)
	local ck = ((cy + 64) * 256 + (cz + 128)) * 256 + (cx + 128)
	local ch = m.chunks[ck]
	if not ch or ch.t < m.since then
		if m.reads <= 0 then
			return nil
		end
		m.reads = m.reads - 1
		ch = {t = c.now, v = c:voxels_at({cx * S, cy * S, cz * S}, {S, S, S})}
		m.chunks[ck] = ch
	end
	return ch.v[1 + (x - cx * S) + S * ((z - cz * S) + S * (y - cy * S))] or ""
end

local function set_at(m, x, y, z, name)
	local cx, cy, cz = math.floor(x / S), math.floor(y / S), math.floor(z / S)
	local ch = m.chunks[((cy + 64) * 256 + (cz + 128)) * 256 + (cx + 128)]
	if ch then
		ch.v[1 + (x - cx * S) + S * ((z - cz * S) + S * (y - cy * S))] = name
	end
end

-- true, false or nil (not read yet): a unit stands in the cell
local function stands(m, c, x, y, z)
	local a = at(m, c, x, y, z)
	if a == nil then
		return nil
	elseif a ~= "air" then
		return false
	end
	local b = at(m, c, x, y - 1, z)
	if b == nil then
		return nil
	end
	return b ~= "air" and b ~= ""
end

local SIDES = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

-- [KIT_RTS_PLAYTEST_1] (7) Whether the ore cell (x, y, z) may be mined
-- without a pit. A cell with solid over it (a wall's): yes. One with air
-- over it is the floor of a stand, which drops a level as it goes: yes if
-- the cell under it is solid (none, or the World's floor: a hole) and no
-- stand beside the one over it is a step up from it (a solid cell with air
-- over that, which `reached`(x, y, z) says the refinery's flood reaches):
-- the way up from below through it would be lost. So the stand over it
-- drops into a stair one down, beside the stand it was mined from: each
-- level down a cell sideways, the cut a staircase. g(x, y, z): the cell's
-- name, nil not read yet; nil back: not read yet
local function safe(g, x, y, z, reached)
	local top, under = g(x, y + 1, z), g(x, y - 1, z)
	if top == nil or under == nil then
		return nil
	end
	if top ~= "air" then
		return true
	end
	if under == "air" or under == "" then
		return false
	end
	for _, d in ipairs(SIDES) do
		local s, o = g(x + d[1], y + 1, z + d[2]), g(x + d[1], y + 2, z + d[2])
		if s == nil or o == nil then
			return nil
		end
		if s ~= "air" and s ~= "" and o == "air" and reached(x + d[1], y + 2, z + d[2]) then
			return false
		end
	end
	return true
end

local function push(net, k)
	if not net.seen[k] then
		net.seen[k] = true
		net.q[#net.q + 1] = k
	end
end

-- A cell of the flood: its ore beside it, its neighbours queued; false: a
-- chunk to read first (next run)
local function expand(m, c, net, k, ore)
	local x, y, z = unkey(k)
	local head = at(m, c, x, y + 1, z)
	if head == nil then
		return false
	end
	local function g(a, b, d)
		return at(m, c, a, b, d)
	end
	local function reached(a, b, d)
		return net.seen[key(a, b, d)] == true
	end
	for _, d in ipairs(SIDES) do
		local nx, nz = x + d[1], z + d[2]
		-- (7) level with it, over its head, and in the floor beside it (a
		-- stair down: the cell over it air)
		for dy = -1, 1 do
			local n = at(m, c, nx, y + dy, nz)
			if n == nil then
				return false
			end
			local ok = key(nx, y + dy, nz)
			local e = net.has[ok]
			if n == ore and (not e or (e.down and dy >= 0)) then
				local sf = true
				if dy < 0 then
					local top = at(m, c, nx, y, nz)
					if top == nil then
						return false
					end
					sf = top == "air"
				end
				if sf then
					sf = safe(g, nx, y + dy, nz, reached)
					if sf == nil then
						return false
					end
				end
				if sf and e then
					-- (found down first, level now: mined from this stand)
					e[2], e.down = k, nil
				elseif sf then
					e = {ok, k, down = dy < 0 or nil}
					net.has[ok] = e
					net.ore[#net.ore + 1] = e
				end
			end
		end
		-- the step: level, up one (room over its head), down up to three
		local s = stands(m, c, nx, y, nz)
		if s == nil then
			return false
		elseif s then
			push(net, key(nx, y, nz))
		elseif at(m, c, nx, y, nz) == "air" then
			for dy = 1, 3 do
				local f = stands(m, c, nx, y - dy, nz)
				if f == nil then
					return false
				elseif f then
					push(net, key(nx, y - dy, nz))
					break
				elseif at(m, c, nx, y - dy, nz) ~= "air" then
					break
				end
			end
		elseif head == "air" then
			local u = stands(m, c, nx, y + 1, nz)
			if u == nil then
				return false
			elseif u then
				push(net, key(nx, y + 1, nz))
			end
		end
	end
	return true
end

local function new_net(m, from)
	local net = {q = {}, qi = 1, seen = {}, has = {}, ore = {},
		from = from}
	push(net, key(from[1], from[2], from[3]))
	return net
end

-- The flood on by `flood` cells; true once it is done
local function flood(m, c, net)
	local n, ore = 0, c.params.ore
	while net.qi <= #net.q and n < c.params.flood do
		if not expand(m, c, net, net.q[net.qi], ore) then
			return false
		end
		net.qi = net.qi + 1
		n = n + 1
	end
	return net.qi > #net.q
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

-- The team's net (the done one: its ore; a newer one flooding behind it)
-- after this run's share of the flood
local function net_of(c, m)
	local team = team_of(c)
	local first
	for _, u in ipairs(c.units or {}) do
		if not first and u.name == "refinery" and u.team == team then
			first = u
		end
	end
	local from = first and cell(first.pos) or cell(c.pos)
	local t = m.nets[team] or {}
	m.nets[team] = t
	local f = from[1] .. "," .. from[2] .. "," .. from[3]
	if not t.next and (not t.done or t.done.from_k ~= f or
			c.now - t.done.at > c.params.fresh) then
		t.next = new_net(m, from)
		t.next.from_k, t.next.at = f, c.now
		-- (chunks older than this flood's start read again)
		t.next.since = c.now - 0.01
	end
	if t.next then
		m.since = t.next.since
		if flood(m, c, t.next) then
			t.done, t.next = t.next, nil
			-- (its builders see what it reaches, as that changes)
			local said = #t.done.q .. " cells, " .. #t.done.ore .. " of ore"
			if said ~= t.said then
				t.said = said
				c:log(team .. "'s refinery reaches " .. said)
			end
		end
	elseif t.done.qi <= #t.done.q then
		-- (the cells a mined one opened)
		m.since = t.done.since
		flood(m, c, t.done)
	end
	return t.done
end

local BUILDINGS = {hq = true, refinery = true, factory = true}

-- (7) A floor cell under a building (its 5 x 5) or next to one: not mined
-- down (the flood sees cells, not buildings)
local function under_building(c, k)
	local x, _, z = unkey(k)
	for _, u in ipairs(c.units or {}) do
		if BUILDINGS[u.name] and math.abs(u.pos[1] - x) < 3.6 and
				math.abs(u.pos[3] - z) < 3.6 then
			return true
		end
	end
	return false
end

-- The ore of the net with the shortest way there and on to the refinery
-- (as the crow flies; ore in the floor `down_cost` m further, level ore
-- first): {ore key, stand key, down = true for ore in the floor}
local function pick(c, m, net)
	local skip, p = c.state.skip, c.pos
	local r = home(c)
	local h = r and r.pos or p
	local best, bd = nil, 1e18
	for _, e in ipairs(net.ore) do
		local cl = m.claims[e[1]]
		if not e.gone and not skip[tostring(e[1])] and
				(not cl or cl[1] == c.id or cl[2] < c.now) and
				not (e.down and under_building(c, e[1])) then
			local x, y, z = unkey(e[2])
			local d = math.sqrt((x - p[1]) ^ 2 + (y - p[2]) ^ 2 + (z - p[3]) ^ 2) +
				math.sqrt((x - h[1]) ^ 2 + (y - h[2]) ^ 2 + (z - h[3]) ^ 2) +
				(e.down and c.params.down_cost or 0)
			if d < bd then
				best, bd = e, d
			end
		end
	end
	return best
end

-- (7) safe() on the World's cells now (c:voxels_at round the ore at o), the
-- stands its team's flood (net; none: all) reaches
local function safe_live(c, o, net)
	local x0, y0, z0 = o[1] - 1, o[2] - 1, o[3] - 1
	local v = c:voxels_at({x0, y0, z0}, {3, 4, 3})
	return safe(function(x, y, z)
		return v[1 + (x - x0) + 3 * ((z - z0) + 3 * (y - y0))] or ""
	end, o[1], o[2], o[3], function(x, y, z)
		return not net or net.seen[key(x, y, z)] == true
	end)
end

-- [KIT_RTS_PLAYTEST_1] (5) A burst of ore dust off the face it mines, at
-- each think while it mines (one colour: one emitter a burst on a client;
-- big enough to see from the rts camera's height)
local function mine_effect(c, o, st)
	local dx, dy, dz = st[1] - o[1], st[2] - 0.5 - o[2], st[3] - o[3]
	local l = math.max(0.01, math.sqrt(dx * dx + dy * dy + dz * dz))
	dx, dy, dz = dx / l, dy / l, dz / l
	c:effect({at = {o[1] + dx * 0.55, o[2] + dy * 0.55, o[3] + dz * 0.55}, count = 10,
		shape = "square", colors = {"#60ffd0"}, dir = {dx, dy + 0.8, dz}, spread = 40,
		speed_min = 1.2, speed_max = 3, gravity = 9, ttl_min = 0.3, ttl_max = 0.6,
		size_min = 0.3, size_max = 0.5, fade = 0.5})
	if not c.state.dusted then
		c.state.dusted = true
		c:log("harvesting effect at " .. o[1] .. "," .. o[2] .. "," .. o[3])
	end
end

-- Standing still: a goal where it is (no goal, propose_move(nil), would let
-- kit/unit's last order win again: the way back to where it was sent)
local function hold(c)
	c:propose_move({to = {c.pos[1], c.pos[2], c.pos[3]}, range = 64})
end

local function think(c)
	local s = c.state
	c:after(c.params.think, "think")
	local m = map_of(c)
	m.reads = 2
	local net = net_of(c, m)
	if s.ordered then
		s.ordered = s.ordered - 1
		if s.ordered > 0 and (c.moving or s.ordered > 76) then
			return
		end
		s.ordered = false
		s.mode = "seek"
	end
	-- (with no ore it reaches, what it has unloaded too)
	if s.cargo >= c.params.cargo or (s.cargo > 0 and (s.mode == "none" or
			s.mode == "home" or s.mode == "stuck")) then
		local r, d = home(c)
		if not r then
			if s.mode ~= "no_refinery" then
				c:log("no refinery")
			end
			s.mode = "no_refinery"
			hold(c)
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
			hold(c)
		elseif s.mode ~= "home" or not c.moving then
			s.mode, s.near, s.since = "home", math.sqrt(d), c.now
			c:propose_move({to = r.pos, range = 2.6})
		elseif math.sqrt(d) < s.near - 0.5 then
			s.near, s.since = math.sqrt(d), c.now
		elseif c.now - s.since > 6 then
			-- no nearer in 6 s (a building put in its way since its way was
			-- found): its way again next time
			s.mode = "stuck"
			hold(c)
		end
		return
	end
	if s.mode == "go" or s.mode == "mine" then
		local o, st = s.ore, s.stand
		local here = d2({c.pos[1], 0, c.pos[3]}, {st[1], 0, st[3]}) < 1.0
		local ok = key(o[1], o[2], o[3])
		if here then
			if c:voxel_at(o[1], o[2], o[3]) ~= c.params.ore then
				s.mode = "seek"
			elseif s.mode == "go" then
				-- (7) checked again on the World as it is now
				if not safe_live(c, o, net) or (s.down and under_building(c, ok)) then
					c:log("not safe to mine " .. o[1] .. "," .. o[2] .. "," .. o[3] .. " now")
					s.skip[tostring(ok)] = c.now + 60
					m.claims[ok] = nil
					s.mode = "seek"
					return
				end
				s.mode = "mine"
				s.since = c.now
				hold(c)
				mine_effect(c, o, st)
			elseif c.now - (s.since or 0) >= c.params.mine_time then
				c:set_voxels_at({{o[1], o[2], o[3], "air"}})
				s.cargo = s.cargo + c.params.per_cell
				s.mined = s.mined + 1
				s.mode = "seek"
				m.claims[ok] = nil
				-- (7) below its refinery's level, or a stair down: said
				local r = home(c)
				if s.down or (r and st[2] < cell(r.pos)[2]) then
					c:log(string.format("mined %d,%d,%d%s from %d,%d,%d", o[1], o[2], o[3],
						s.down and " down" or "", st[1], st[2], st[3]))
				end
				-- (into the floods that reached it: what it opens is reached,
				-- flooded on from it the next runs)
				set_at(m, o[1], o[2], o[3], "air")
				local open = stands(m, c, o[1], o[2], o[3])
				for _, t in pairs(m.nets) do
					for _, n in ipairs({t.done or false, t.next or false}) do
						if n and n.has[ok] then
							n.has[ok].gone = true
							if open then
								push(n, ok)
							end
						end
					end
				end
				c:effect({at = {o[1], o[2], o[3]}, count = 12, shape = "square",
					colors = {"#40e0b0", "#20a080", "#808080", "#606060"},
					speed_min = 0.5, speed_max = 2, ttl_max = 0.6, size_max = 0.12})
			else
				mine_effect(c, o, st)
			end
			return
		end
		m.claims[ok] = {c.id, c.now + 10}
		local dd = math.sqrt(d2(c.pos, st))
		if dd < s.near - 0.5 then
			s.near, s.since = dd, c.now
		elseif c.now - s.since > (c.moving and 12 or 3) then
			-- not got nearer: that one later
			s.skip[tostring(ok)] = c.now + 60
			m.claims[ok] = nil
			s.mode = "seek"
		end
		return
	end
	-- seek
	for k, t in pairs(s.skip) do
		if t < c.now then
			s.skip[k] = nil
		end
	end
	if not net then
		-- (the flood still going: wait for it)
		return
	end
	local e, o, st
	for _ = 1, 4 do
		e = pick(c, m, net)
		if not e then
			break
		end
		local x, y, z = unkey(e[1])
		if c:voxel_at(x, y, z) == c.params.ore then
			o = {x, y, z}
			st = {unkey(e[2])}
			break
		end
		-- (mined since: gone)
		e.gone = true
	end
	if not o then
		if s.mode ~= "none" then
			c:log("no reachable ore")
		end
		s.mode = "none"
		hold(c)
		return
	end
	if s.mode == "none" then
		c:log("ore again")
	end
	m.claims[e[1]] = {c.id, c.now + 10}
	s.ore, s.stand, s.down = o, st, e.down == true
	s.mode, s.near, s.since = "go", 1e9, c.now
	c:propose_move({to = {st[1], st[2] - 0.5, st[3]}, range = 0.3})
end

-- [KIT_RTS_PLAYTEST_1] What it does, for the rts camera's selection window
-- (its shared state status)
local STATUS = {seek = "looking for ore", go = "going to the ore",
	mine = "mining", home = "carrying %d to the refinery",
	stuck = "carrying %d, finding a way", ordered = "moving",
	none = "idle: no ore its refinery reaches",
	no_refinery = "idle: carrying %d, no refinery"}

local function status(c)
	local s = c.state
	local n = math.floor(s.cargo)
	local t = (STATUS[s.mode] or tostring(s.mode)):gsub("%%d", n)
	return n > 0 and not t:find("carrying") and t .. ", carrying " .. n or t
end

return {
	version = 1,
	about = {
		group = "Creatures",
		what = "A Deepcore harvester: mines the ore its refinery reaches and carries it there for money.",
		params = {
			ore = "The voxel it mines.",
			cargo = "How much it carries before it goes to unload.",
			per_cell = "Money a cell of ore is worth.",
			mine_time = "Seconds a cell takes to mine.",
			think = "Seconds between its looks round.",
			flood = "Cells of the way from its refinery it looks along a think (the harvesters together).",
			fresh = "Seconds the way and the ore it knows stay before it looks again (a digger's tunnels seen then).",
			down_cost = "Metres ore in the floor counts as further away than ore level with it (level ore first).",
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
		per_cell = {type = "number", default = 25, min = 1, max = 1000},
		mine_time = {type = "number", default = 2, min = 0.1, max = 10},
		think = {type = "number", default = 0.5, min = 0.2, max = 5},
		flood = {type = "number", default = 200, min = 10, max = 2000},
		fresh = {type = "number", default = 20, min = 2, max = 600},
		down_cost = {type = "number", default = 16, min = 0, max = 1000},
	},
	state = {cargo = {default = 0, shared = true}, mode = {default = "seek"},
		ore = {default = false}, stand = {default = false}, since = {default = 0},
		near = {default = 0}, ordered = {default = false}, skip = {default = {}},
		mined = {default = 0}, down = {default = false}, dusted = {default = false},
		status = {default = "", shared = true}},
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
			c.state.status = status(c)
		end
	end,
}
