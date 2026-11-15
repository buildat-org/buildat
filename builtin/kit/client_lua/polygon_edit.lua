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
return function(A)
local S, E, NT, M, magic, log = A.S, A.E, A.NT, A.M, A.magic, A.log
local send, find, front_at, GRID_STEPS = A.send, A.find, A.front_at, A.GRID_STEPS
local to_screen, px, SNAP_PX, drawn_at = A.to_screen, A.px, A.SNAP_PX, A.drawn_at
local plane_z, type_of, palette = A.plane_z, A.type_of, A.palette
local G = {}
NT.pg = G
local TYPE = "kit/polygon"
-- (kit.cpp's MAX_POLYGON_POINTS)
local MAX_POINTS = 128

local function snap(v)
	local g = GRID_STEPS[S.grid] or 1
	return math.floor(v / g + 0.5) * g
end

local function sixteenth(v)
	return math.floor(v * 16 + 0.5) / 16
end

-- Its kit/polygon component: its index (from 0) and the component
local function poly_comp(e)
	for i, c in ipairs(e and e.components or {}) do
		if c.type == TYPE then
			return i - 1, c
		end
	end
end

local function local_points(c)
	local p = type(c.params) == "table" and c.params.points
	if type(p) ~= "table" then
		local d = (type_of(TYPE).params or {}).points
		p = type(d) == "table" and d.default
	end
	return type(p) == "table" and p or {}
end

-- Where the pointer meets the plane at z, on the grid (nil: along it)
local function pointer_at(mx, my, z)
	local o, v = M.screen_ray(mx, my)
	local p = front_at(o, v, z)
	return p and magic.Vector3(snap(p.x), snap(p.y), z)
end

local function under(p, mx, my)
	local sx, sy = to_screen(p)
	return sx ~= nil and math.abs(sx - mx) <= px(SNAP_PX) and
			math.abs(sy - my) <= px(SNAP_PX)
end

-- The selected polygon in the Front view, lying flat: {e, comp, wp (its points in
-- the world as drawn, Vector3s), o, q}; nil: none
local function editing()
	if S.view ~= "front" or not S.primary then
		return nil
	end
	local e, made_ = find(S.primary)
	local ci, c = poly_comp(e)
	if not ci or made_ or not e.pos then
		return nil
	end
	local q = NT.drawn_turn(e)
	if math.abs((q * magic.Vector3(0, 0, 1)).z) < 0.999 then
		return nil
	end
	local o = drawn_at(e)
	local wp = {}
	for i, p in ipairs(local_points(c)) do
		wp[i] = o + q * magic.Vector3(tonumber(p[1]) or 0, tonumber(p[2]) or 0, 0)
	end
	return {e = e, comp = ci, wp = wp, o = o, q = q}
end

-- Its points set (world ones, into its frame on the 1/16): one edit
local function set_points(ed, wp, what)
	local q = ed.q
	local inv = magic.Quaternion(q.w, -q.x, -q.y, -q.z)
	local pts = {}
	for i, p in ipairs(wp) do
		local l = inv * (p - ed.o)
		pts[i] = {sixteenth(l.x), sixteenth(l.y)}
	end
	send({op = "set", id = ed.e.id, comp = ed.comp, param = "points", value = pts})
	log:info("kit editor: polygon " .. ed.e.id .. " " .. what .. ", " .. #pts ..
			" points")
end

-- Its points with one added in the middle of edge i: the list, its index
local function with_middle(ed, i)
	local wp = {}
	for k, p in ipairs(ed.wp) do
		wp[k] = p
	end
	table.insert(wp, i + 1, (ed.wp[i] + ed.wp[i % #ed.wp + 1]) * 0.5)
	return wp, i + 1
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
	local wp, at = ed.wp, ed.point
	if ed.edge then
		if #ed.wp >= MAX_POINTS then
			log:info("kit editor: polygon " .. ed.e.id .. " has " .. MAX_POINTS ..
					" points, the most")
			return nil
		end
		wp, at = with_middle(ed, ed.edge)
	else
		wp = {}
		for k, p in ipairs(ed.wp) do
			wp[k] = p
		end
	end
	log:info("kit editor: dragging polygon " .. ed.e.id .. "'s point " .. at)
	return {kind = "poly", ed = ed, wp = wp, at = at, added = ed.edge ~= nil}
end

function G.update(d)
	local p = pointer_at(S.mx, S.my, d.ed.o.z)
	if p then
		d.wp[d.at] = p
		d.moved = true
	end
end

function G.finish(d)
	if d.moved or d.added then
		set_points(d.ed, d.wp, d.added and "point " .. d.at .. " added" or
				"point " .. d.at .. " moved")
	end
end

-- [KIT_POLYGON_ROW] The inspector's "Edit in Front view": the Front view
-- round the polygon's points (their box and a margin), where they are edited
function G.show(e)
	local _, c = poly_comp(e)
	if not c or not e.pos then
		return
	end
	local o, q = drawn_at(e), NT.drawn_turn(e)
	local x0, y0, x1, y1 = o.x, o.y, o.x, o.y
	for _, p in ipairs(local_points(c)) do
		local w = o + q * magic.Vector3(tonumber(p[1]) or 0, tonumber(p[2]) or 0, 0)
		x0, y0 = math.min(x0, w.x), math.min(y0, w.y)
		x1, y1 = math.max(x1, w.x), math.max(y1, w.y)
	end
	local aspect = magic.ui.root.width / math.max(1, magic.ui.root.height)
	S.fx, S.fy = (x0 + x1) / 2, (y0 + y1) / 2
	S.fspan = math.max(8, 1.3 * (y1 - y0), 1.3 * (x1 - x0) / aspect)
	M.set_view("front")
	log:info(string.format("kit editor: polygon %s in the Front view at %.2f,%.2f",
			tostring(e.id), S.fx, S.fy))
end

-- Placing kit/polygon in the Front view: its points drawn so far
function G.drawing()
	return S.placing ~= nil and S.placing.type == TYPE and S.view == "front"
end

local function draft()
	if not G.drawing() then
		S.pg_draft = nil
		return nil
	end
	S.pg_draft = S.pg_draft or {pts = {}, z = plane_z()}
	return S.pg_draft
end

local function close(dr)
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for _, p in ipairs(dr.pts) do
		x0, y0 = math.min(x0, p.x), math.min(y0, p.y)
		x1, y1 = math.max(x1, p.x), math.max(y1, p.y)
	end
	local cx, cy = sixteenth((x0 + x1) / 2), sixteenth((y0 + y1) / 2)
	local pts = {}
	for i, p in ipairs(dr.pts) do
		pts[i] = {sixteenth(p.x - cx), sixteenth(p.y - cy)}
	end
	-- Selected when it comes (place_at's)
	NT.select_new = true
	send({op = "place", type = TYPE, pos = {cx, cy, dr.z}, params = {points = pts}})
	log:info(string.format("kit editor: placed %s at %g,%g,%g, %d points", TYPE, cx, cy,
			dr.z, #pts))
	S.pg_draft, S.placing = nil, nil
	palette()
end

-- A click (a tap): a point drawn, the drawing closed, or an edge's middle added;
-- true when taken (t: the press's target, a handle's too)
function G.click(mx, my, t)
	local dr = draft()
	if dr then
		local p = pointer_at(mx, my, dr.z)
		if #dr.pts >= 3 and under(dr.pts[1], mx, my) then
			close(dr)
		elseif p and #dr.pts >= MAX_POINTS then
			log:info("kit editor: a polygon has " .. MAX_POINTS .. " points at most")
		elseif p then
			dr.pts[#dr.pts + 1] = p
			log:info(string.format("kit editor: polygon point %d at %g,%g", #dr.pts,
					p.x, p.y))
		end
		return true
	end
	local ed = t and t.poly
	if ed and ed.edge then
		if #ed.wp < MAX_POINTS then
			local wp, at = with_middle(ed, ed.edge)
			set_points(ed, wp, "point " .. at .. " added")
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
	local wp = {}
	for k, p in ipairs(ed.wp) do
		if k ~= ed.point then
			wp[#wp + 1] = p
		end
	end
	set_points(ed, wp, "point " .. ed.point .. " taken away")
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
	local p = pointer_at(mx, my, dr.z)
	g.left = #dr.pts >= 3 and under(dr.pts[1], mx, my) and "close the polygon" or
			p and string.format("a point of the polygon at %g,%g", p.x, p.y) or nil
	g.right = "stop drawing"
	g.note = not S.touch and "Enter: close it, Backspace: its last point back, " ..
			"Esc: stop" or nil
	return g
end

function G.draw(dbg)
	local YELLOW, GREEN = magic.Color(1, 0.9, 0.2), magic.Color(0.3, 1, 0.5)
	local r = (S.fspan or 16) * 0.006
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
		local p = S.mx and pointer_at(S.mx, S.my, dr.z)
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
