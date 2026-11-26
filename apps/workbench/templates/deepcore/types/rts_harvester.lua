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
	for _, d in ipairs(SIDES) do
		local nx, nz = x + d[1], z + d[2]
		for dy = 0, 1 do
			local n = at(m, c, nx, y + dy, nz)
			if n == nil then
				return false
			end
			if n == ore then
				local ok = key(nx, y + dy, nz)
				if not net.has[ok] then
					net.has[ok] = true
					net.ore[#net.ore + 1] = {ok, k}
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

-- The ore of the net with the shortest way there and on to the refinery
-- (as the crow flies): {ore key, stand key}
local function pick(c, m, net)
	local skip, p = c.state.skip, c.pos
	local r = home(c)
	local h = r and r.pos or p
	local best, bd = nil, 1e18
	for _, e in ipairs(net.ore) do
		local cl = m.claims[e[1]]
		if not e.gone and not skip[tostring(e[1])] and
				(not cl or cl[1] == c.id or cl[2] < c.now) then
			local x, y, z = unkey(e[2])
			local d = math.sqrt((x - p[1]) ^ 2 + (y - p[2]) ^ 2 + (z - p[3]) ^ 2) +
				math.sqrt((x - h[1]) ^ 2 + (y - h[2]) ^ 2 + (z - h[3]) ^ 2)
			if d < bd then
				best, bd = e, d
			end
		end
	end
	return best
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
				s.mode = "mine"
				s.since = c.now
				hold(c)
			elseif c.now - (s.since or 0) >= c.params.mine_time then
				c:set_voxels_at({{o[1], o[2], o[3], "air"}})
				s.cargo = s.cargo + c.params.per_cell
				s.mined = s.mined + 1
				s.mode = "seek"
				m.claims[ok] = nil
				-- (into the floods that reached it: what it opens is reached,
				-- flooded on from it the next runs)
				set_at(m, o[1], o[2], o[3], "air")
				local open = stands(m, c, o[1], o[2], o[3])
				for _, t in pairs(m.nets) do
					for _, n in ipairs({t.done or false, t.next or false}) do
						if n and n.has[ok] then
							for _, e in ipairs(n.ore) do
								if e[1] == ok then
									e.gone = true
								end
							end
							if open then
								push(n, ok)
							end
						end
					end
				end
				c:effect({at = {o[1], o[2], o[3]}, count = 12, shape = "square",
					colors = {"#40e0b0", "#20a080", "#808080", "#606060"},
					speed_min = 0.5, speed_max = 2, ttl_max = 0.6, size_max = 0.12})
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
	s.ore, s.stand = o, st
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
	},
	state = {cargo = {default = 0, shared = true}, mode = {default = "seek"},
		ore = {default = false}, stand = {default = false}, since = {default = 0},
		near = {default = 0}, ordered = {default = false}, skip = {default = {}},
		mined = {default = 0}, status = {default = "", shared = true}},
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
