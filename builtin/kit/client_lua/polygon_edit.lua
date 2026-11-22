-- Buildat: builtin/kit/client_lua/polygon_edit.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_PLANE] stage 3: kit/polygon drawn and edited in the editor's Front view
-- (NT.pg; editor_input.lua's press, drag, click, right click, keys, guide and
-- drawing call it). kit/polygon placed from the palette there: each click (a tap)
-- is a point where the pointer meets the plane, on the grid; the first one again or
-- Enter closes it: one place op with its points, its place their box's middle on
-- the 1/16 (one undo). Backspace takes the last point back; Escape or a right click
-- gives the drawing up. A selected polygon lying flat (yaw 0 or 180, any roll)
-- shows its points (boxes) and its edges' middles (crosses): a point dragged moves
-- it, an edge's middle clicked or dragged adds a point there, a right click (a
-- long press) on a point takes it away (3 kept); each a set op of its points (one
-- undo). The server checks the shape (kit.cpp's points_ok); its refusal is logged
-- as any edit's.
-- [KIT_TOP_DOWN] (4) The plan (2D) view does the same for one lying flat (pitch 90:
-- its x, y the world's x, z), on the plane at its height; drawn there in a scene
-- whose kit/controls' plane is horizontal (E.state.plane_y), placed lying flat at
-- that height (the place op's pitch 90). The inspector's "Edit in 2D view" shows a
-- flat one in the plan view.
-- simplified: no drawing in other games' plan view (a kit/polygon placed there is
-- the standing default, as before); turn one flat and edit it there
-- [KIT_GENERATORS] (4z37f) The same handles for any type's points param declared
-- level (a generator's corner list: the entity's own x and z, in the plan view),
-- each point's further values (its radius) kept as it moves, copied to a point
-- added after it.
return function(A)
local S, E, NT, M, magic, log = A.S, A.E, A.NT, A.M, A.magic, A.log
local send, find, front_at, GRID_STEPS = A.send, A.find, A.front_at, A.GRID_STEPS
local to_screen, px, SNAP_PX, drawn_at = A.to_screen, A.px, A.SNAP_PX, A.drawn_at
local plane_z, type_of, palette = A.plane_z, A.type_of, A.palette
local plane_at = A.plane_at
local G = {}
NT.pg = G
local TYPE = "kit/polygon"
-- (kit.cpp's MAX_POLYGON_POINTS)
local MAX_POINTS = 512

local function snap(v)
	local g = GRID_STEPS[S.grid] or 1
	return math.floor(v / g + 0.5) * g
end

local function sixteenth(v)
	return math.floor(v * 16 + 0.5) / 16
end

-- Its kit/polygon component, or one with a level points param: its index (from
-- 0), the component, the param's name, whether level
local function poly_comp(e)
	for i, c in ipairs(e and e.components or {}) do
		if c.type == TYPE then
			return i - 1, c, "points"
		end
		for k, d in pairs(type_of(c.type).params or {}) do
			if type(d) == "table" and d.type == "points" and d.level then
				return i - 1, c, k, true
			end
		end
	end
end

local function local_points(c, k)
	k = k or "points"
	local p = type(c.params) == "table" and c.params[k]
	if type(p) ~= "table" then
		local d = (type_of(c.type).params or {})[k]
		p = type(d) == "table" and d.default
	end
	return type(p) == "table" and p or {}
end

-- A point's values after its x and y
local function extra(p)
	local x = {}
	for i = 3, #p do
		x[#x + 1] = p[i]
	end
	return x
end

-- Its frame: a level param's points lie in its x, z (as a pitch 90 polygon's)
local function turn_of(e, lv)
	local q = NT.drawn_turn(e)
	return lv and q * magic.Quaternion(90, 0, 0) or q
end

-- [KIT_TOP_DOWN] (4) The view's frame: the world's axis across the screen and those
-- of a point's x and y (the Front view: z; x, y; the plan: y; x, z); nil: neither
local function frame()
	if S.view == "front" then
		return "z", "x", "y"
	elseif S.view == "2d" then
		return "y", "x", "z"
	end
end

-- A level plane's y (the server's plane_of()), nil: none
local function plane_y()
	return E.state and tonumber(E.state.plane_y)
end

-- Where the pointer meets the view's plane at d (along its axis), on the grid (nil:
-- along it, or no such view)
local function pointer_at(mx, my, d)
	local ax, u, v = frame()
	if not ax then
		return nil
	end
	local o, r = M.screen_ray(mx, my)
	local p = ax == "z" and front_at(o, r, d) or plane_at(o, r, d, "y")
	if not p then
		return nil
	end
	local c = {x = p.x, y = p.y, z = p.z}
	c[u], c[v], c[ax] = snap(c[u]), snap(c[v]), d
	return magic.Vector3(c.x, c.y, c.z)
end

-- A point's x and y in the view (its world u and v)
local function uv(p)
	local _, u, v = frame()
	return p[u or "x"], p[v or "y"]
end

local function under(p, mx, my)
	local sx, sy = to_screen(p)
	return sx ~= nil and math.abs(sx - mx) <= px(SNAP_PX) and
			math.abs(sy - my) <= px(SNAP_PX)
end

-- The selected polygon facing the view (its own z along the view's axis: standing in
-- the Front view, flat in the plan): {e, comp, wp (its points in the world as drawn,
-- Vector3s), o, q, d (o along the axis)}; nil: none
local function editing()
	local ax = frame()
	if not ax or not S.primary then
		return nil
	end
	local e, made_ = find(S.primary)
	local ci, c, k, lv = poly_comp(e)
	if not ci or made_ or not e.pos then
		return nil
	end
	local q = turn_of(e, lv)
	if math.abs((q * magic.Vector3(0, 0, 1))[ax]) < 0.999 then
		return nil
	end
	local o = drawn_at(e)
	local wp, ex = {}, {}
	for i, p in ipairs(local_points(c, k)) do
		wp[i] = o + q * magic.Vector3(tonumber(p[1]) or 0, tonumber(p[2]) or 0, 0)
		ex[i] = extra(p)
	end
	return {e = e, comp = ci, param = k, wp = wp, ex = ex, o = o, q = q, d = o[ax]}
end

-- Its points set (world ones, into its frame on the 1/16; ex: each one's further
-- values): one edit
local function set_points(ed, wp, what, ex)
	local q = ed.q
	local inv = magic.Quaternion(q.w, -q.x, -q.y, -q.z)
	local pts = {}
	for i, p in ipairs(wp) do
		local l = inv * (p - ed.o)
		pts[i] = {sixteenth(l.x), sixteenth(l.y)}
		for _, v in ipairs(ex[i] or {}) do
			pts[i][#pts[i] + 1] = v
		end
	end
	send({op = "set", id = ed.e.id, comp = ed.comp, param = ed.param, value = pts})
	log:info("kit editor: polygon " .. ed.e.id .. " " .. what .. ", " .. #pts ..
			" points")
end

-- Its points with one added in the middle of edge i (its values point i's): the
-- list, its index, the values
local function with_middle(ed, i)
	local wp, ex = {}, {}
	for k, p in ipairs(ed.wp) do
		wp[k], ex[k] = p, ed.ex[k]
	end
	table.insert(wp, i + 1, (ed.wp[i] + ed.wp[i % #ed.wp + 1]) * 0.5)
	table.insert(ex, i + 1, ed.ex[i])
	return wp, i + 1, ex
end

-- A handle under the pointer: editing()'s with point = i or edge = i (from point
-- i to the next); nil: none
function G.handle_at(mx, my)
	local ed = editing()
	if not ed then
		return nil
	end
	local n = #ed.wp
	for i = 1, n do
		if under(ed.wp[i], mx, my) then
			ed.point = i
			return ed
		end
	end
	for i = 1, n do
		if under((ed.wp[i] + ed.wp[i % n + 1]) * 0.5, mx, my) then
			ed.edge = i
			return ed
		end
	end
	return nil
end

-- A handle's drag (S.drag): a point, or an edge's new middle one
function G.start(ed)
	local wp, at, ex = ed.wp, ed.point, ed.ex
	if ed.edge then
		if #ed.wp >= MAX_POINTS then
			log:info("kit editor: polygon " .. ed.e.id .. " has " .. MAX_POINTS ..
					" points, the most")
			return nil
		end
		wp, at, ex = with_middle(ed, ed.edge)
	else
		wp = {}
		for k, p in ipairs(ed.wp) do
			wp[k] = p
		end
	end
	log:info("kit editor: dragging polygon " .. ed.e.id .. "'s point " .. at)
	return {kind = "poly", ed = ed, wp = wp, ex = ex, at = at, added = ed.edge ~= nil}
end

function G.update(d)
	local p = pointer_at(S.mx, S.my, d.ed.d)
	if p then
		d.wp[d.at] = p
		d.moved = true
	end
end

function G.finish(d)
	if d.moved or d.added then
		set_points(d.ed, d.wp, d.added and "point " .. d.at .. " added" or
				"point " .. d.at .. " moved", d.ex)
	end
end

-- Whether one turned q lies flat (its own z along the world's y)
local function flat(q)
	return math.abs((q * magic.Vector3(0, 0, 1)).y) >= 0.999
end
G.flat = flat

-- [KIT_POLYGON_ROW] The inspector's "Edit in 2D view": the Front view (a
-- side game's 2D) round the polygon's points (their box and a margin), where they
-- are edited; [KIT_TOP_DOWN] (4) one lying flat the plan view, cut over it
function G.show(e)
	local _, c, k, level = poly_comp(e)
	if not c or not e.pos then
		return
	end
	local o, q = drawn_at(e), turn_of(e, level)
	local lv = flat(q) and not M.side_game()
	local V = lv and "z" or "y"
	local x0, y0, x1, y1 = o.x, o[V], o.x, o[V]
	for _, p in ipairs(local_points(c, k)) do
		local w = o + q * magic.Vector3(tonumber(p[1]) or 0, tonumber(p[2]) or 0, 0)
		x0, y0 = math.min(x0, w.x), math.min(y0, w[V])
		x1, y1 = math.max(x1, w.x), math.max(y1, w[V])
	end
	local aspect = magic.ui.root.width / math.max(1, magic.ui.root.height)
	local span = math.max(8, 1.3 * (y1 - y0), 1.3 * (x1 - x0) / aspect)
	if lv then
		S.cx, S.cz, S.span = (x0 + x1) / 2, (y0 + y1) / 2, span
		S.cut = math.floor(o.y) + 1.5
		M.set_view("2d")
		log:info(string.format("kit editor: polygon %s in the plan view at %.2f,%.2f",
				tostring(e.id), S.cx, S.cz))
		return
	end
	S.fx, S.fy, S.fspan = (x0 + x1) / 2, (y0 + y1) / 2, span
	M.set_view("front")
	log:info(string.format("kit editor: polygon %s in the Front view at %.2f,%.2f",
			tostring(e.id), S.fx, S.fy))
end

-- Placing kit/polygon in the Front view (or the plan with a level plane): its
-- points drawn so far
function G.drawing()
	return S.placing ~= nil and S.placing.type == TYPE and (S.view == "front" or
			S.view == "2d" and plane_y() ~= nil)
end

-- ({pts, ax: the view's axis, d: the plane's place along it})
local function draft()
	local ax = frame()
	if not G.drawing() or S.pg_draft and S.pg_draft.ax ~= ax then
		S.pg_draft = nil
	end
	if not G.drawing() then
		return nil
	end
	S.pg_draft = S.pg_draft or {pts = {}, ax = ax, d = ax == "z" and plane_z() or
		plane_y()}
	return S.pg_draft
end

local function close(dr)
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for _, p in ipairs(dr.pts) do
		local x, y = uv(p)
		x0, y0 = math.min(x0, x), math.min(y0, y)
		x1, y1 = math.max(x1, x), math.max(y1, y)
	end
	local cx, cy = sixteenth((x0 + x1) / 2), sixteenth((y0 + y1) / 2)
	local pts = {}
	for i, p in ipairs(dr.pts) do
		local x, y = uv(p)
		pts[i] = {sixteenth(x - cx), sixteenth(y - cy)}
	end
	local lv = dr.ax == "y"
	local pos = lv and {cx, dr.d, cy} or {cx, cy, dr.d}
	-- Selected when it comes (place_at's)
	NT.select_new = true
	send({op = "place", type = TYPE, pos = pos, pitch = lv and 90 or nil,
		params = {points = pts}})
	log:info(string.format("kit editor: placed %s at %g,%g,%g%s, %d points", TYPE,
			pos[1], pos[2], pos[3], lv and " lying flat" or "", #pts))
	S.pg_draft, S.placing = nil, nil
	palette()
end

-- A click (a tap): a point drawn, the drawing closed, or an edge's middle added;
-- true when taken (t: the press's target, a handle's too)
function G.click(mx, my, t)
	local dr = draft()
	if dr then
		local p = pointer_at(mx, my, dr.d)
		if #dr.pts >= 3 and under(dr.pts[1], mx, my) then
			close(dr)
		elseif p and #dr.pts >= MAX_POINTS then
			log:info("kit editor: a polygon has " .. MAX_POINTS .. " points at most")
		elseif p then
			dr.pts[#dr.pts + 1] = p
			log:info(string.format("kit editor: polygon point %d at %g,%g", #dr.pts,
					uv(p)))
		end
		return true
	end
	local ed = t and t.poly
	if ed and ed.edge then
		if #ed.wp < MAX_POINTS then
			local wp, at, ex = with_middle(ed, ed.edge)
			set_points(ed, wp, "point " .. at .. " added", ex)
		end
		return true
	end
	return ed ~= nil
end

-- A right click (a long press) on a point: it taken away; true when taken
function G.right(mx, my)
	local ed = not G.drawing() and G.handle_at(mx, my)
	if not ed or not ed.point then
		return false
	end
	if #ed.wp <= 3 then
		log:info("kit editor: a polygon keeps 3 points")
		return true
	end
	local wp, ex = {}, {}
	for k, p in ipairs(ed.wp) do
		if k ~= ed.point then
			local n = #wp + 1
			wp[n], ex[n] = p, ed.ex[k]
		end
	end
	set_points(ed, wp, "point " .. ed.point .. " taken away", ex)
	return true
end

-- Enter closes the drawing, Backspace takes its last point back: true when taken
function G.key(key)
	local dr = S.pg_draft and draft()
	if not dr then
		return false
	end
	if key == magic.KEY_RETURN or key == magic.KEY_KP_ENTER then
		if #dr.pts >= 3 then
			close(dr)
		else
			log:info("kit editor: a polygon wants 3 points")
		end
		return true
	elseif key == magic.KEY_BACKSPACE and #dr.pts > 0 then
		dr.pts[#dr.pts] = nil
		log:info("kit editor: polygon point " .. (#dr.pts + 1) .. " taken back")
		return true
	end
	return false
end

-- The guide's words while drawing (nil: not drawing)
function G.guide(g, mx, my)
	local dr = draft()
	if not dr then
		return nil
	end
	local p = pointer_at(mx, my, dr.d)
	g.left = #dr.pts >= 3 and under(dr.pts[1], mx, my) and "close the polygon" or
			p and string.format("add a point at %g,%g", uv(p)) or nil
	g.right = "stop drawing"
	g.note = not S.touch and "Enter: close it, Backspace: remove the last point, " ..
			"Esc: stop" or nil
	return g
end

function G.draw(dbg)
	local YELLOW, GREEN = magic.Color(1, 0.9, 0.2), magic.Color(0.3, 1, 0.5)
	local r = ((S.view == "2d" and S.span or S.fspan) or 16) * 0.006
	local function dot(p, col)
		dbg:AddBoundingBox(magic.BoundingBox(p - magic.Vector3(r, r, r),
				p + magic.Vector3(r, r, r)), col, false)
	end
	local function outline(wp, col, closed)
		for i = 1, #wp - (closed and 0 or 1) do
			dbg:AddLine(wp[i], wp[i % #wp + 1], col, false)
		end
	end
	local dr = draft()
	if dr then
		local wp = {}
		for i, p in ipairs(dr.pts) do
			wp[i] = p
			dot(p, i == 1 and YELLOW or GREEN)
		end
		local p = S.mx and pointer_at(S.mx, S.my, dr.d)
		if p then
			wp[#wp + 1] = p
		end
		outline(wp, GREEN, false)
		return
	end
	local d = S.drag
	if d and d.kind == "poly" then
		outline(d.wp, GREEN, true)
		dot(d.wp[d.at], YELLOW)
		return
	end
	local ed = editing()
	if ed then
		outline(ed.wp, YELLOW, true)
		for i, p in ipairs(ed.wp) do
			dot(p, YELLOW)
			dbg:AddCross((p + ed.wp[i % #ed.wp + 1]) * 0.5, r * 3, GREEN, false)
		end
	end
end

return G
end
-- vim: set noet ts=4 sw=4:
