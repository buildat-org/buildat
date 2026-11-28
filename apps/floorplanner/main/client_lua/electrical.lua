-- Buildat: apps/floorplanner/main/client_lua/electrical.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [FP_ELECTRICAL] The electrical design read off the document: where each
-- box is, how long each run is, and what conductors each run carries,
-- derived from what the switches control. Nothing here touches the
-- engine or the scene: M.derive(ents, geom) is the whole of it, for the
-- inspector, the plan view's symbols and a check's log alike.
--
-- A power circuit's runs are a tree from its board (main.cpp refuses a
-- loop). Its loads are the outlet (Schuko), device, ceiling and equipment
-- boxes on it. A switch gang controls a list of loads; the gangs that
-- control the same list are a control group: one gang one-way, two in
-- different boxes two-way, more with intermediate switches between them.
-- Each run then carries:
--   PE and N towards every load past it;
--   the permanent live (each of the circuit's phases) towards every load
--   no switch controls, and towards each group's first switch (its feed);
--   two travellers along the tree path between each two switches of a
--   group next to each other in its chain;
--   a switched live from the group's last switch to each of its loads,
--   over the union of the tree paths;
--   the circuit's custom wires, on every run of it.
-- A group's chain (which switch is fed, which is last, the intermediates'
-- order) is the one of least conductor length.
local M = {}

M.ROLE = {junction = 0, switch = 1, outlet = 2, device = 3, ceiling = 4,
	equipment = 5, board = 6}
M.ROLE_NAMES = {[0] = "Junction box", "Switch box", "Outlet box",
	"Device box", "Ceiling box", "Equipment", "Board"}
M.SECTIONS = {"1.5 mm2", "2.5 mm2", "6.0 mm2", "CAT5E"}
-- As a cable's name has them
local SECTION_MM = {"1.5", "2.5", "6"}
M.ROUTES = {[0] = "in the wall's cavity", "in the floor's cavity",
	"in the ceiling's cavity", "on the wall's surface",
	"on the ceiling's surface"}
M.CABLES = {[0] = "by the conductors", "ML", "MMJ", "MCMK", "CAT5E"}
M.CONDUCTORS = {{1, "PE"}, {2, "N"}, {4, "L1"}, {8, "L2"}, {16, "L3"}}

local function bit(v, b)
	return math.floor(v / b) % 2 == 1
end
M.bit = bit

local function settings(ents)
	for _, e in pairs(ents) do
		if e.type == "settings" then
			return e.ints
		end
	end
	return {}
end

local function is_load(b)
	local r = b.ints.role
	return r == M.ROLE.device or r == M.ROLE.ceiling or r == M.ROLE.equipment or
			r == M.ROLE.outlet and b.ints.outlet == 0
end
M.is_load = is_load

-- A wall's a end, direction, length and face offsets
function M.wall_line(ents, id, geom)
	local w = ents[id]
	local a, b = w and ents[w.ints.a], w and ents[w.ints.b]
	if not (a and b) then
		return nil
	end
	local dx, dz = b.ints.x - a.ints.x, b.ints.z - a.ints.z
	local l = geom.len(dx, dz)
	if l == 0 then
		return nil
	end
	local lo, ro = geom.offsets(w.ints.thickness, w.ints.justify, w.ints.shift)
	return {ax = a.ints.x, az = a.ints.z, ux = dx / l, uz = dz / l, len = l,
			lo = lo, ro = ro, wall = w}
end

-- Where a box is in its layout's plan: on its wall's face (and the point
-- on the wall's line), or its own x, z on the ceiling
function M.box_xz(ents, b, geom)
	local i = b.ints
	local f = i.wall ~= 0 and M.wall_line(ents, i.wall, geom)
	if not f then
		return i.x, i.z, i.x, i.z
	end
	local lx, lz = f.ax + f.ux * i.along, f.az + f.uz * i.along
	local off = i.side == 0 and f.lo or -f.ro
	return lx - f.uz * off, lz + f.ux * off, lx, lz
end

-- The ceiling over a point of a layout: the smallest room's there, else
-- the plan's
function M.ceiling_at(ents, layout, x, z, geom)
	local best, area = nil, math.huge
	for _, e in pairs(ents) do
		if e.type == "room" then
			local pts = {}
			for _, n in ipairs(e.lists.nodes) do
				local ne = ents[n]
				if not ne or ne.ints.layout ~= layout then
					pts = {}
					break
				end
				pts[#pts + 1] = {ne.ints.x, ne.ints.z}
			end
			if #pts >= 3 and geom.point_in_polygon(x, z, pts) then
				local a = math.abs(geom.area(pts))
				if a < area then
					best, area = e, a
				end
			end
		end
	end
	return best and best.ints.ceiling > 0 and best.ints.ceiling or
			settings(ents).ceiling or 2600
end

function M.box_height(ents, b, geom)
	if b.ints.wall ~= 0 then
		return b.ints.height
	end
	local x, z = M.box_xz(ents, b, geom)
	return M.ceiling_at(ents, b.ints.layout, x, z, geom)
end

local function placement(ents, layout)
	local l = ents[layout]
	return l and l.ints or {x = 0, y = 0, z = 0, yaw = 0}
end

-- A point of one layout in another's frame
local function between(ents, from, to, x, y, z, geom)
	if from == to then
		return x, y, z
	end
	local f, t = placement(ents, from), placement(ents, to)
	local wx, wy, wz = geom.rot(x, y, z, 0, f.yaw / 1000, 0)
	wx, wy, wz = wx + f.x - t.x, wy + f.y - t.y, wz + f.z - t.z
	return geom.unrot(wx, wy, wz, 0, t.yaw / 1000, 0)
end

-- A run's path in its a box's layout: {{x, z}, ...} from a's face through
-- its points to b's, b's height there, and the height of the route's
-- horizontal part. Its length is the path's plus the drops from each box
-- to that height: a riser's is the floors' difference.
function M.run_path(ents, r, geom)
	local a, b = ents[r.ints.a], ents[r.ints.b]
	local la = a.ints.layout
	local ax, az = M.box_xz(ents, a, geom)
	local pts = {{ax, az}}
	local p = r.lists.pts or {}
	for i = 1, #p - 1, 2 do
		pts[#pts + 1] = {p[i], p[i + 1]}
	end
	local bx, bz = M.box_xz(ents, b, geom)
	local hb = M.box_height(ents, b, geom)
	bx, hb, bz = between(ents, b.ints.layout, la, bx, hb, bz, geom)
	pts[#pts + 1] = {bx, bz}
	local ha = M.box_height(ents, a, geom)
	local route = r.ints.route
	local e
	if route == 1 then
		e = 0
	elseif route == 2 or route == 4 then
		e = M.ceiling_at(ents, la, ax, az, geom)
	elseif r.ints.elev > 0 then
		e = r.ints.elev
	else
		e = b.ints.layout == la and math.max(ha, hb) or ha
	end
	local horiz = 0
	for i = 2, #pts do
		horiz = horiz + geom.len(pts[i][1] - pts[i - 1][1], pts[i][2] - pts[i - 1][2])
	end
	return pts, horiz, math.abs(ha - e) + math.abs(hb - e), e
end

function M.box_name(ents, id)
	local b = ents[id]
	if not b then
		return "box " .. tostring(id)
	end
	if b.strs.name ~= "" then
		return b.strs.name
	end
	return M.ROLE_NAMES[b.ints.role]:lower() .. " " .. id
end

-- The gangs that control the same loads, by that list: {key, loads (ids,
-- sorted), name, gangs = {{box, gang}, ...} in box order}
local function control_groups(ents)
	local groups, list = {}, {}
	local ids = {}
	for id, e in pairs(ents) do
		if e.type == "ebox" and e.ints.role == M.ROLE.switch then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local e = ents[id]
		for g = 1, e.ints.gangs do
			local loads = {}
			for _, l in ipairs(e.lists["controls" .. g] or {}) do
				if ents[l] then
					loads[#loads + 1] = l
				end
			end
			if #loads > 0 then
				table.sort(loads)
				local key = table.concat(loads, ",")
				local gr = groups[key]
				if not gr then
					local names = {}
					for k, l in ipairs(loads) do
						names[k] = M.box_name(ents, l)
					end
					gr = {key = key, loads = loads, gangs = {},
							name = table.concat(names, " + ")}
					groups[key] = gr
					list[#list + 1] = gr
				end
				gr.gangs[#gr.gangs + 1] = {box = id, gang = g}
			end
		end
	end
	table.sort(list, function(x, y) return x.key < y.key end)
	return list
end

-- The orders a chain of switches may take: every one up to 5, else
-- nearest the board first
-- simplified: past five switches in a group, one order
local function orders(sw, depth)
	if #sw > 5 then
		local o = {}
		for i, s in ipairs(sw) do
			o[i] = s
		end
		table.sort(o, function(x, y)
			if depth[x.box] ~= depth[y.box] then
				return depth[x.box] < depth[y.box]
			end
			return x.box * 10 + x.gang < y.box * 10 + y.gang
		end)
		return {o}
	end
	local out = {}
	local function perm(prefix, rest)
		if #rest == 0 then
			out[#out + 1] = prefix
			return
		end
		for i = 1, #rest do
			local p, r = {}, {}
			for _, v in ipairs(prefix) do
				p[#p + 1] = v
			end
			p[#p + 1] = rest[i]
			for j, v in ipairs(rest) do
				if j ~= i then
					r[#r + 1] = v
				end
			end
			perm(p, r)
		end
	end
	perm({}, sw)
	return out
end

-- One power circuit's runs: each run's conductors, into out
local function power_circuit(ents, c, runs, groups, out)
	local adj = {}
	for _, r in ipairs(runs) do
		for _, e in ipairs({{r.ints.a, r.ints.b}, {r.ints.b, r.ints.a}}) do
			adj[e[1]] = adj[e[1]] or {}
			table.insert(adj[e[1]], {run = r.id, to = e[2]})
		end
	end
	-- The tree from the board: each box's parent and the run to it
	local root = c.ints.board
	local par, par_run, depth = {}, {}, {[root] = 0}
	local queue, qi = {root}, 1
	while queue[qi] do
		local v = queue[qi]
		qi = qi + 1
		table.sort(adj[v] or {}, function(x, y) return x.run < y.run end)
		for _, e in ipairs(adj[v] or {}) do
			if depth[e.to] == nil then
				depth[e.to] = depth[v] + 1
				par[e.to], par_run[e.to] = v, e.run
				queue[#queue + 1] = e.to
			end
		end
	end
	local cr = out.circuits[c.id]
	for _, r in ipairs(runs) do
		if depth[r.ints.a] == nil then
			out.runs[r.id].warn = "not connected to the board"
		end
	end
	local function path(u, v)
		local edges = {}
		while depth[u] > depth[v] do
			edges[#edges + 1] = par_run[u]
			u = par[u]
		end
		while depth[v] > depth[u] do
			edges[#edges + 1] = par_run[v]
			v = par[v]
		end
		while u ~= v do
			edges[#edges + 1] = par_run[u]
			edges[#edges + 1] = par_run[v]
			u, v = par[u], par[v]
		end
		return edges
	end
	local len = function(id) return out.runs[id].len end
	local function add(set, edges, n)
		for _, e in ipairs(edges) do
			set[e] = (set[e] or 0) + (n or 1)
		end
	end
	local pe, live = {}, {}
	-- This circuit's groups: their loads and switches on its tree
	local switched, mine = {}, {}
	for _, g in ipairs(groups) do
		local loads = {}
		for _, l in ipairs(g.loads) do
			if depth[l] and is_load(ents[l]) and not switched[l] then
				loads[#loads + 1] = l
			end
		end
		if #loads > 0 then
			local sw = {}
			for _, s in ipairs(g.gangs) do
				if depth[s.box] then
					sw[#sw + 1] = s
				else
					cr.warn[#cr.warn + 1] = "group '" .. g.name .. "': switch box " ..
							s.box .. " is not on this circuit's runs"
				end
			end
			if #sw > 0 then
				for _, l in ipairs(loads) do
					switched[l] = true
				end
				mine[#mine + 1] = {g = g, loads = loads, sw = sw}
			end
		end
	end
	local loads = {}
	for v in pairs(depth) do
		if is_load(ents[v]) then
			loads[#loads + 1] = v
		end
	end
	table.sort(loads)
	for _, l in ipairs(loads) do
		local p = path(root, l)
		add(pe, p)
		if not switched[l] then
			for _, e in ipairs(p) do
				live[e] = 1
			end
		end
	end
	-- Each group's chain, the cheapest in conductor length: its feed's
	-- live where none runs yet, two travellers between each pair, the
	-- switched live from the last to the loads
	-- simplified: the groups one at a time, each given the live the ones
	-- before it brought; exact for one group
	local trav, sl = {}, {}
	for _, m in ipairs(mine) do
		local best, best_cost
		for _, o in ipairs(orders(m.sw, depth)) do
			local cost = 0
			for _, e in ipairs(path(root, o[1].box)) do
				if not live[e] then
					cost = cost + len(e)
				end
			end
			for i = 2, #o do
				for _, e in ipairs(path(o[i - 1].box, o[i].box)) do
					cost = cost + 2 * len(e)
				end
			end
			local u = {}
			for _, l in ipairs(m.loads) do
				add(u, path(o[#o].box, l))
			end
			for e in pairs(u) do
				cost = cost + len(e)
			end
			if not best_cost or cost < best_cost - 1e-6 then
				best, best_cost = o, cost
			end
		end
		m.chain = best
		for _, e in ipairs(path(root, best[1].box)) do
			live[e] = 1
		end
		local t, s = {}, {}
		for i = 2, #best do
			add(t, path(best[i - 1].box, best[i].box), 2)
		end
		for _, l in ipairs(m.loads) do
			for _, e in ipairs(path(best[#best].box, l)) do
				s[e] = 1
			end
		end
		trav[m], sl[m] = t, s
		local chain = {}
		for i, s in ipairs(best) do
			local kind = #best == 1 and "1-way" or (i == 1 or i == #best) and
					"2-way (vaihto)" or "intermediate (risti)"
			out.gangs[s.box .. ":" .. s.gang] = kind
			chain[i] = s.box .. "/" .. s.gang
		end
		out.groups[#out.groups + 1] = {name = m.g.name, circuit = c.id,
				chain = chain, loads = m.loads, feed = best[1].box,
				last = best[#best].box}
	end
	-- Each run's conductors
	local cond = c.ints.cond
	local phases, lname = {}, nil
	for _, p in ipairs(M.CONDUCTORS) do
		if p[1] >= 4 and bit(cond, p[1]) then
			phases[#phases + 1] = p[2]
			lname = lname or p[2]
		end
	end
	lname = lname or "L1"
	local wires = {}
	for w in (c.strs.wires or ""):gmatch("[^,]+") do
		w = w:match("^%s*(.-)%s*$")
		if w ~= "" then
			wires[#wires + 1] = w
		end
	end
	for _, r in ipairs(runs) do
		local items = {}
		local function item(name, n, group)
			items[#items + 1] = {name = name, n = n or 1, group = group}
		end
		if pe[r.id] then
			if bit(cond, 1) then item("PE") end
			if bit(cond, 2) then item("N") end
		end
		if live[r.id] then
			for _, p in ipairs(phases) do
				item(p)
			end
		end
		for _, m in ipairs(mine) do
			if trav[m][r.id] then
				item(lname .. " travellers", trav[m][r.id], m.g.name)
			end
		end
		for _, m in ipairs(mine) do
			if sl[m][r.id] then
				item(lname .. " switched", 1, m.g.name)
			end
		end
		for _, w in ipairs(wires) do
			item(w)
		end
		out.runs[r.id].items = items
	end
end

-- The cables a run needs for its conductors: ML one wire each, MMJ and
-- MCMK as many cores as they carry and their protective earth, several
-- cables past the biggest
-- simplified: an MMJ's green-yellow core is never a live one, so a run
-- with no PE still takes a core for it; past five cores (MCMK four and
-- its concentric earth) the conductors are shared out over the fewest
-- cables
local function cables(kind, n_pe, n, section)
	local mm = SECTION_MM[section] or "1.5"
	if n == 0 then
		return "none"
	end
	if kind == 4 then
		return "CAT5E"
	elseif kind == 1 then
		return "ML " .. mm .. " mm2 x" .. n
	end
	local live = n - n_pe
	local k = math.max(1, math.ceil(live / 4))
	local out = {}
	for i = 1, k do
		local q = math.floor(live / k) + (i <= live % k and 1 or 0)
		if kind == 3 then
			out[i] = "MCMK " .. math.max(2, q) .. "x" .. mm .. "/" .. mm
		else
			out[i] = "MMJ " .. math.max(3, q + 1) .. "x" .. mm .. "S"
		end
	end
	return table.concat(out, " + ")
end

function M.items_text(items)
	local t = {}
	for i, it in ipairs(items or {}) do
		t[i] = it.name .. (it.n > 1 and " x" .. it.n or "") ..
				(it.group and " (group '" .. it.group .. "')" or "")
	end
	return #t > 0 and table.concat(t, ", ") or "nothing (no load past it)"
end

-- Everything derived: runs[id] = {pts, len, horiz, vert, elev, items,
-- count, text, cable, section, conduit, conduit_d, warn}; gangs["box:gang"]
-- = the insert's kind; boxes[id] = {inserts}; groups = {{name, circuit,
-- chain, loads, feed, last}}; circuits[id] = {warn = {...}}
function M.derive(ents, geom)
	local st = settings(ents)
	local out = {runs = {}, gangs = {}, boxes = {}, groups = {}, circuits = {}}
	local by_circuit = {}
	local cids = {}
	for id, e in pairs(ents) do
		if e.type == "circuit" then
			by_circuit[id] = {}
			cids[#cids + 1] = id
			out.circuits[id] = {warn = {}}
		end
	end
	table.sort(cids)
	local rids = {}
	for id, e in pairs(ents) do
		if e.type == "erun" and ents[e.ints.a] and ents[e.ints.b] and
				by_circuit[e.ints.circuit] then
			rids[#rids + 1] = id
		end
	end
	table.sort(rids)
	for _, id in ipairs(rids) do
		local r = ents[id]
		local pts, horiz, vert, elev = M.run_path(ents, r, geom)
		out.runs[id] = {pts = pts, horiz = horiz, vert = vert, elev = elev,
				len = horiz + vert, items = {}}
		table.insert(by_circuit[r.ints.circuit], r)
	end
	local groups = control_groups(ents)
	for _, cid in ipairs(cids) do
		local c = ents[cid]
		if c.ints.kind == 1 then
			local wires = c.strs.wires ~= "" and c.strs.wires or "data"
			for _, r in ipairs(by_circuit[cid]) do
				out.runs[r.id].items = {{name = wires, n = 1}}
			end
		else
			power_circuit(ents, c, by_circuit[cid], groups, out)
		end
		for _, r in ipairs(by_circuit[cid]) do
			local o, i = out.runs[r.id], r.ints
			local n, n_pe = 0, 0
			for _, it in ipairs(o.items) do
				n = n + it.n
				n_pe = n_pe + (it.name == "PE" and 1 or 0)
			end
			o.count = n
			o.text = M.items_text(o.items)
			o.conduit = i.conduit == 1 or i.conduit == 0 and c.ints.conduit == 1
			o.conduit_d = o.conduit and (i.conduit_d > 0 and i.conduit_d or
					st.el_conduit_d or 20) or 0
			local sec = c.ints.kind == 1 and 4 or i.section > 0 and i.section or
					c.ints.section
			o.section = M.SECTIONS[sec]
			local kind = i.cable > 0 and i.cable or c.ints.kind == 1 and 4 or
					o.conduit and 1 or 2
			o.cable = cables(kind, n_pe, n, sec)
		end
	end
	-- Each switch box's inserts, for the listing: per gang its kind, from
	-- the chains above; a gang that controls nothing on a circuit, unlinked
	for id, e in pairs(ents) do
		if e.type == "ebox" and e.ints.role == M.ROLE.switch then
			local kinds = {}
			for g = 1, e.ints.gangs do
				kinds[g] = out.gangs[id .. ":" .. g] or
						(#(e.lists["controls" .. g] or {}) > 0 and
						"1-way (not on its circuit)" or "1-way (controls nothing)")
			end
			out.boxes[id] = {inserts = (e.ints.gangs == 2 and "two-gang: " or
					"single: ") .. table.concat(kinds, " + ")}
		end
	end
	return out
end

return M
-- vim: set noet ts=4 sw=4:
