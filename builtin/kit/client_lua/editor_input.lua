-- Buildat: builtin/kit/client_lua/editor_input.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_EDITOR_LOCALS] The editor's second half, moved out of editor.lua, whose
-- main function was at the 200 locals a Lua 5.1 function may have: the ports
-- and the knob, a press and a drag, the terrain and voxels tools, the mouse,
-- fingers and keys, what the pointer would do and the drawing, and M.editor
-- turning it all on. editor.lua's head says what the editor does; it runs this
-- file where this code stood, so each A.x below is what that local was then.
-- A local of editor.lua written later must not be taken by value here: the
-- cameras, made by M.editor, are returned by make_cameras(). Returned to
-- editor.lua: terrain_panel, which its palette calls.
return function(A)
local aitta, ANGLE_STEPS, angle_text, apply_viewport, begin_link =
		A.aitta, A.ANGLE_STEPS, A.angle_text, A.apply_viewport, A.begin_link
local BRUSH_NAMES, BRUSHES, button, BX, camera_pivot =
		A.BRUSH_NAMES, A.BRUSHES, A.button, A.BX, A.camera_pivot
local caps, changed, close_menu, color, context_menu =
		A.caps, A.changed, A.close_menu, A.color, A.context_menu
local DIM, DRAG_PX, drawn_at, drop, E =
		A.DIM, A.DRAG_PX, A.drawn_at, A.drop, A.E
local ED, entities, find, fit_inspector, focus =
		A.ED, A.entities, A.find, A.fit_inspector, A.focus
local GRID_STEPS, grid_text, ground_at, inside, inspector_window =
		A.GRID_STEPS, A.grid_text, A.ground_at, A.inside, A.inspector_window
local K, key_held, label, log, log_bar =
		A.K, A.key_held, A.label, A.log, A.log_bar
local LONG_PRESS_US, M, made, magic, make_cameras =
		A.LONG_PRESS_US, A.M, A.made, A.magic, A.make_cameras
local MAX_BRUSH, MAX_RAY, MEM, move_camera, name_of =
		A.MAX_BRUSH, A.MAX_RAY, A.MEM, A.move_camera, A.name_of
local narrow, network, NT, O, over_ui =
		A.narrow, A.network, A.NT, A.O, A.over_ui
local P, palette, palette_at, pan3d_start, people =
		A.P, A.palette, A.palette_at, A.pan3d_start, A.people
local pick, place_cameras, place_cell, PLAN_3D_MAX_H, plan_aligned =
		A.pick, A.place_cameras, A.place_cell, A.PLAN_3D_MAX_H, A.plan_aligned
local plane_at, preview, px, rebuild_bar, refresh =
		A.plane_at, A.preview, A.px, A.rebuild_bar, A.refresh
local release_preview, RIGHT_CLICK_PX, rot3d, round, row =
		A.release_preview, A.RIGHT_CLICK_PX, A.rot3d, A.round, A.row
local S, screen_size, sel_ids, select, send =
		A.S, A.screen_size, A.sel_ids, A.select, A.send
local set_view, show_log, SNAP_PX, STYLE, T =
		A.set_view, A.show_log, A.SNAP_PX, A.STYLE, A.T
local text, to_screen, touch, type_of, typing =
		A.text, A.to_screen, A.touch, A.type_of, A.typing
local ui_utils, v3, vbox, VIEW_KEYS, voxel_names =
		A.ui_utils, A.v3, A.vbox, A.VIEW_KEYS, A.voxel_names
local W, window = A.W, A.window
local terrain_panel, zoom_at
local brush_at, stroke_begin, stroke_move, stroke_end, draw_brush
local cam3d_node, cam3d

-- ---- Ports and the knob: what is dragged to link and to turn
local PORTS = {out = {}, ["in"] = {}}
local ports_root = nil

-- The ports of a kind shown beside an entity: {label, comp, name}...;
-- nil hides them
local function show_ports(kind, id, list)
	if not ports_root then
		-- Under the panels (their priority -1)
		ports_root = magic.ui.root:CreateChild("UIElement")
		ports_root.priority = -2
	end
	local P_ = PORTS[kind]
	local key = id and tostring(id) .. ":" .. table.concat((function()
		local l = {}
		for _, p in ipairs(list) do l[#l + 1] = p.label end
		return l
	end)(), ",") or ""
	if P_.key ~= key then
		for _, p in ipairs(P_.items or {}) do
			p.button:Remove()
		end
		P_.items, P_.key, P_.id = {}, key, id
		for _, p in ipairs(id and list or {}) do
			if not ports_root.defaultStyle then
				ports_root.defaultStyle = STYLE
			end
			local b = button(ports_root, p.label, function() end)
			b.priority = -2
			P_.items[#P_.items + 1] = {button = b, comp = p.comp, name = p.name}
		end
	end
	if not id then
		return
	end
	local e = find(id)
	local sx, sy = nil, nil
	if e and e.pos then
		sx, sy = to_screen(drawn_at(e))
	end
	local sc = magic.ui.scale
	local y0 = sy and sy / sc - #P_.items * 13
	local at = {}
	for i, p in ipairs(P_.items) do
		p.button.visible = sx ~= nil
		if sx then
			-- Outputs at the right of it, inputs at the left
			local x = kind == "out" and sx / sc + 24 or sx / sc - 24 -
					p.button.width
			local y = y0 + (i - 1) * 26
			p.button:SetPosition(math.floor(x), math.floor(y))
			at[#at + 1] = string.format("%s %d,%d", p.name,
					math.floor((x + p.button.width / 2) * sc),
					math.floor((y + p.button.height / 2) * sc))
		end
	end
	-- Where they are, for a drive, as they come or move
	local where = table.concat(at, ", ")
	if where ~= P_.where then
		P_.where = where
		if where ~= "" then
			log:info("kit editor: " .. kind .. " ports of " .. id .. ": " .. where)
		end
	end
end

local function port_at(kind, mx, my)
	local sc = magic.ui.scale
	for _, p in ipairs(PORTS[kind].items or {}) do
		if p.button.visible and inside(p.button, mx / sc, my / sc) then
			return p
		end
	end
end

local function outputs_of(e)
	local l = {}
	for ci, c in ipairs(e and e.components or {}) do
		for _, o in ipairs(type_of(c.type).outputs or {}) do
			l[#l + 1] = {label = o .. " >", comp = ci - 1, name = o}
		end
	end
	return l
end

local function inputs_of(e)
	local l, seen = {}, {}
	for _, c in ipairs(e and e.components or {}) do
		for _, i in ipairs(type_of(c.type).inputs or {}) do
			if not seen[i] then
				seen[i] = true
				l[#l + 1] = {label = "> " .. i, name = i}
			end
		end
	end
	return l
end

-- The selection's knob: on a circle round the primary, the way it faces
-- [KIT_FREE_ROTATION] The selection's handles, each a ring with a knob, each
-- turning one of its angles (the rows': Quaternion(pitch, yaw, roll), so roll
-- first and yaw last): yaw round the world's y, pitch round its right as the
-- yaw has it, roll round its forward as yaw and pitch have it. A knob at the
-- angle a is at c + (v0 cos a + u sin a) r. The plan looks down y: yaw only
local function knobs()
	local e, is_made = nil, false
	if S.primary then
		e, is_made = find(S.primary)
	end
	if not e or not e.pos or is_made or NT.sym_copy(e) then
		return nil
	end
	local c = drawn_at(e)
	local n = P.nodes[e.id]
	local r = 1.2
	if n and n.box then
		r = math.max(r, math.max(n.box.size[1], n.box.size[3]) / 2 + 0.6)
	end
	r = math.max(r, NT.pf.knob_radius(e))
	local pv = P.preview[e.id]
	local a = pv and pv.angles or {pv and pv[4] or e.yaw or 0, e.pitch or 0,
		e.roll or 0}
	local V = magic.Vector3
	local list = {{which = 1, name = "yaw", axis = V(0, 1, 0), v0 = V(0, 0, 1),
		u = V(1, 0, 0), angle = a[1], r = r, col = magic.Color(1, 0.9, 0.2)}}
	if S.view ~= "2d" then
		local y, yx = magic.Quaternion(0, a[1], 0), magic.Quaternion(a[2], a[1], 0)
		list[2] = {which = 2, name = "pitch", axis = y * V(1, 0, 0), v0 = V(0, 1, 0),
			u = y * V(0, 0, 1), angle = a[2], r = r * 1.15,
			col = magic.Color(1, 0.35, 0.3)}
		list[3] = {which = 3, name = "roll", axis = yx * V(0, 0, 1), v0 = yx * V(1, 0, 0),
			u = yx * V(0, 1, 0), angle = a[3], r = r * 1.3,
			col = magic.Color(0.4, 0.6, 1)}
	end
	-- A ring seen edge-on (its axis over ~80 degrees from the line of sight)
	-- is left out: its turn cannot be seen from there (user, 2026-11-10).
	-- The one being dragged stays
	local sx, sy = to_screen(c)
	local v
	if sx then
		local _
		_, v = M.screen_ray(sx, sy)
	end
	local d = S.drag and S.drag.kind == "turn" and S.drag.h
	local l = v and math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) or 0
	for i = #list, 1, -1 do
		local k = list[i]
		-- |cos| of the angle between its axis and the line of sight (the
		-- sandbox's Vector3 has no DotProduct)
		local a = k.axis
		k.cos = l > 0 and math.abs(a.x * v.x + a.y * v.y + a.z * v.z) / l or 1
		if k.cos < 0.17 and
				not (d and d.which == k.which) then
			table.remove(list, i)
		end
	end
	for _, k in ipairs(list) do
		local t = math.rad(k.angle)
		k.at = c + (k.v0 * math.cos(t) + k.u * math.sin(t)) * k.r
	end
	return list, c
end

-- The knob under a point of the screen, the nearest of them
local function near_knob(mx, my)
	local list, c = knobs()
	if not list then
		return nil
	end
	local cx, cy = to_screen(c)
	local best, best_d
	for _, k in ipairs(list) do
		local sx, sy = to_screen(k.at)
		-- Nearer it than the entity's middle: a finger's wide reach on a
		-- small plan takes the entity
		if sx ~= nil and math.abs(sx - mx) <= px(SNAP_PX) and
				math.abs(sy - my) <= px(SNAP_PX) then
			local dd = (sx - mx) ^ 2 + (sy - my) ^ 2
			if (cx == nil or dd < (cx - mx) ^ 2 + (cy - my) ^ 2) and
					(not best or dd < best_d) then
				best, best_d = k, dd
			end
		end
	end
	return best
end

-- [KIT_GROUP_TURN_JUMP] A check's look for the selection's knob: where it
-- is on the screen
magic.SubscribeToEvent("command_seq:kit_knob_where", function()
	local list, c = knobs()
	local sx, sy
	local names = {}
	for _, k in ipairs(list or {}) do
		names[#names + 1] = string.format("%s (cos %.2f)", k.name, k.cos)
	end
	log:info("kit editor: the rings shown: " .. table.concat(names, " ") .. ";")
	if list then
		sx, sy = to_screen(list[1].at)
		local mx, my = to_screen(c)
		if mx then
			log:info(string.format("kit editor: the middle on the screen at %d, %d",
					mx, my))
		end
	end
	log:info(sx and string.format("kit editor: the knob on the screen at "
			.. "%d, %d", sx, sy) or "kit editor: no knob on the screen")
	for i = 2, list and #list or 0 do
		local x, y = to_screen(list[i].at)
		if x then
			log:info(string.format("kit editor: the %s knob on the screen at "
					.. "%d, %d", list[i].name, x, y))
		end
	end
end)

-- [KIT_PHONE_EDITING] stage 3, a check's look for entities ("event
-- kit_entity_where <id> ..."): where each is drawn on the screen, pixels
magic.SubscribeToEvent("command_seq:kit_entity_where", function(_, data)
	for id in data:GetString("Param"):gmatch("%d+") do
		local e = find(tonumber(id))
		local sx, sy = nil, nil
		if e and e.pos then
			sx, sy = to_screen(drawn_at(e))
		end
		log:info(sx and string.format("kit editor: entity %s on the screen at "
				.. "%d, %d", id, sx, sy) or "kit editor: entity " .. id ..
				" not on the screen")
	end
end)

-- ---- What a press would take: the knob, a port, an entity
local function press_target(mx, my)
	local kn = near_knob(mx, my)
	if kn then
		return {knob = kn}
	end
	local port = port_at("out", mx, my)
	if port then
		return {port = port}
	end
	local p = pick(mx, my)
	if p and p.id then
		return {id = p.id}
	end
	-- [KIT_PHONE_EDITING] stage 3: the touch mode's finger: else the entity
	-- drawn nearest, within half the touch size (a 30 px box in the plan is
	-- smaller than a finger)
	-- simplified: by its middle on the screen, not its drawn box
	if S.touch and NT.sh.on() then
		local best, bd = nil, (NT.sh.TOUCH / 2 * magic.ui.scale) ^ 2
		for _, e in ipairs(entities()) do
			local sx, sy = nil, nil
			if e.pos then
				sx, sy = to_screen(drawn_at(e))
			end
			local d = sx and (sx - mx) ^ 2 + (sy - my) ^ 2
			if d and d <= bd then
				best, bd = e.id, d
			end
		end
		if best then
			return {id = best}
		end
	end
	return {pick = p}
end

-- [KIT_PHONE_EDITING] stage 3: Select more (the touch mode's toggle): a tap
-- adds to the selection, a drag on nothing boxes
local function more()
	return NT.sh.on() and NT.sh.multi == true
end

local function snap(v, g)
	return math.floor(v / g + 0.5) * g
end

-- Each selected authored entity, with a position ([KIT_NESTING] but one
-- under another of them, which takes it along)
local function movable()
	local l = {}
	for _, id in ipairs(sel_ids()) do
		local e, is_made = find(id)
		-- ([KIT_SYMMETRY] a copy is moved by its source)
		if e and e.pos and not is_made and not NT.under_one_of(e, S.sel) and
				not NT.sym_copy(e) then
			l[#l + 1] = e
		end
	end
	return l
end

local function clear_preview()
	P.preview = {}
end

local function start_drag()
	local t = S.press.target
	if t.knob then
		local _, c = knobs()
		S.drag = {kind = "turn", c = c, h = t.knob, turn = 0}
		log:info("kit editor: turning " .. S.primary .. " by its " .. t.knob.name)
		return
	end
	if t.port then
		begin_link(PORTS.out.id, t.port.comp, t.port.name)
		S.drag = {kind = "link", from = PORTS.out.id}
		refresh()
		return
	end
	if t.id and S.sel[t.id] and #movable() > 0 then
		local e = find(t.id)
		local o, v = M.screen_ray(S.press.mx, S.press.my)
		local y = e.pos and e.pos[2] or O.ground_y
		local hp = plane_at(o, v, y)
		if hp then
			S.drag = {kind = "move", y = y, hp = hp, dx = 0, dz = 0,
				ids = movable()}
			log:info("kit editor: moving " .. #S.drag.ids)
			return
		end
	end
	-- A finger's drag on what is not selected moves the view
	-- ([FP_TOUCH] 3): no box. ([KIT_PHONE_EDITING] The touch mode's, the
	-- mouse's too, but under Select more)
	if (S.touch or NT.sh.on()) and not (S.press.shift and more()) then
		return
	end
	S.drag = {kind = "box"}
end

local function update_drag()
	local d = S.drag
	if d.kind == "move" then
		local o, v = M.screen_ray(S.mx, S.my)
		local hc = plane_at(o, v, d.y)
		if hc then
			local g = GRID_STEPS[S.grid]
			d.dx, d.dz = snap(hc.x - d.hp.x, g), snap(hc.z - d.hp.z, g)
		end
		for _, e in ipairs(d.ids) do
			preview(e, {d.dx, 0, d.dz}, 0)
		end
	elseif d.kind == "turn" then
		local o, v = M.screen_ray(S.mx, S.my)
		-- The handle's plane through the entity; edge on: as it was
		local h = d.h
		local function dot(a, b)
			return a.x * b.x + a.y * b.y + a.z * b.z
		end
		local den = dot(v, h.axis)
		local hit_t = math.abs(den) > 1e-3 and dot(d.c - o, h.axis) / den
		if hit_t and hit_t > 0 then
			local rel = o + v * hit_t - d.c
			local a = math.deg(math.atan2(dot(rel, h.u), dot(rel, h.v0)))
			local step = ANGLE_STEPS[S.angle]
			if step then
				a = snap(a, step)
			end
			d.turn = ((a - h.angle) % 360 + 540) % 360 - 180
		end
		-- About the group's middle, the mean of their positions, as the
		-- server's move_group
		local l, m = movable(), {0, 0, 0}
		for _, e in ipairs(l) do
			for k = 1, 3 do
				m[k] = m[k] + e.pos[k] / #l
			end
		end
		local mid = magic.Vector3(m[1], m[2], m[3])
		for _, e in ipairs(l) do
			preview(e, {0, 0, 0}, d.turn, mid, d.h)
		end
	end
end

local function place_at(cell, item)
	if not cell or not item then
		return
	end
	-- [KIT_NESTING] under the entity the inspector's "Place under this"
	-- named, while it is there (a root's or a scene's type goes on it all
	-- the same, the server's)
	if S.under and not find(S.under) then
		S.under = nil
	end
	local parent = S.under
	-- [KIT_PANEL_PARENT] a UI element in the panel selected
	local sel = S.primary and find(S.primary)
	if not parent and NT.is_ui(item.type) and NT.is_panel(sel) then
		parent = sel.id
	end
	-- [KIT_POSITIONLESS_PLACE] Whatever was placed is selected when it
	-- comes, the inspector up: the builder sees it and sets its parameters
	NT.select_new = true
	if item.clipboard then
		send({op = "place", clipboard = true, pos = cell,
			turn = item.turn or 0, parent = parent})
	elseif item.prefab then
		send({op = "place", prefab = item.prefab, pos = cell,
			turn = item.turn or 0, parent = parent, free = item.free,
			detached = NT.pf.detached(item) or nil})
	elseif item.pickup then
		-- [KIT_ITEMS_TAB] an item from the Items tab: a pickup of it
		send({op = "place", type = "kit/pickup", pos = cell, parent = parent,
			params = {item = item.pickup}})
	else
		send({op = "place", type = item.type, pos = cell, parent = parent})
	end
	log:info("kit editor: placed " .. item.label .. " at " ..
			table.concat(cell, ",") .. (parent and " under " .. parent or ""))
end

-- [KIT_PALETTE_MENU] A positionless type placed at once, in the scene
-- edited (the server wants a pos and does not keep it), and selected when
-- it comes (place_at): nothing else shows it placed.
-- simplified: the first new entity of the next state is taken for it; another
-- builder's in the same instant selects that one instead
function NT.place_now(it)
	S.placing = nil
	place_at({0, 0, 0}, it)
	palette()
end

local function end_drag()
	local d = S.drag
	S.drag = nil
	if d.kind == "move" then
		if d.dx == 0 and d.dz == 0 then
			clear_preview()
			return
		end
		if #d.ids == 1 then
			local e = d.ids[1]
			send({op = "move", id = e.id, pos = {e.pos[1] + d.dx, e.pos[2],
				e.pos[3] + d.dz}})
		else
			local ids = {}
			for _, e in ipairs(d.ids) do
				ids[#ids + 1] = e.id
			end
			send({op = "move", ids = ids, by = {d.dx, 0, d.dz}})
		end
		release_preview()
		log:info(string.format("kit editor: moved %d by %g, %g", #d.ids, d.dx,
				d.dz))
	elseif d.kind == "turn" then
		local l = movable()
		if d.turn == 0 or #l == 0 then
			clear_preview()
			return
		end
		local ids = {}
		for _, e in ipairs(l) do
			ids[#ids + 1] = e.id
		end
		local a = d.h.axis
		send({op = "move", ids = ids, by = {0, 0, 0}, turn = d.turn,
			axis = d.h.which ~= 1 and {a.x, a.y, a.z} or nil})
		-- What was shown at the release, for a check against the rows
		for id, pv in pairs(P.preview) do
			log:verbose(string.format("kit editor: turn preview %d at %g,%g,%g "
					.. "yaw %g", id, pv[1], pv[2], pv[3], pv[4]))
		end
		release_preview()
		log:info(string.format("kit editor: turned %d by %g", #l, d.turn))
	elseif d.kind == "box" then
		local x0, x1 = math.min(S.press.mx, S.mx), math.max(S.press.mx, S.mx)
		local y0, y1 = math.min(S.press.my, S.my), math.max(S.press.my, S.my)
		if not S.press.shift then
			S.sel = {}
			S.primary = nil
		end
		local n = 0
		for _, e in ipairs(entities()) do
			if e.pos then
				local sx, sy = to_screen(drawn_at(e))
				if sx and sx >= x0 and sx <= x1 and sy >= y0 and sy <= y1 then
					S.sel[e.id] = true
					S.primary = S.primary or e.id
					n = n + 1
				end
			end
		end
		log:info("kit editor: a box selected " .. n .. ", " .. #sel_ids() ..
				" in the selection")
		focus()
		refresh()
	elseif d.kind == "link" then
		local link = E.link
		local port = port_at("in", S.mx, S.my)
		local to = port and PORTS["in"].id
		if not to then
			local p = pick(S.mx, S.my, {[d.from] = true})
			to = p and p.id
		end
		local te, made_ = nil, false
		if to then
			te, made_ = find(to)
		end
		if not link or not te or made_ or to == d.from then
			E.link, E.status = nil, ""
			log:info("kit editor: link dropped on nothing")
		else
			local ins = inputs_of(te)
			local input = port and port.name or (#ins == 1 and ins[1].name)
			if input then
				send({op = "link", id = link.id, comp = link.comp,
					output = link.output, to = to, input = input})
				log:info("kit editor: link dropped on " .. to .. " " .. input)
				E.link, E.status = nil, ""
			else
				-- Which input: the inspector's To buttons
				log:info("kit editor: link dropped on " .. to .. ", " .. #ins ..
						" inputs")
				select(to)
			end
		end
		show_ports("in", nil)
		refresh()
	end
end

-- A click (a press let go where it was)
local function click()
	local t = S.press.target
	if S.placing then
		local c = place_cell(S.press.mx, S.press.my)
		if c then
			place_at(c, S.placing)
		end
		return
	end
	-- [KIT_PHONE_EDITING] stage 3, the touch mode's (no ports): a link begun
	-- by the inspector's Link <output> ended by a tap on an entity of one
	-- input (of more, it is selected: the inspector's To buttons)
	local link = NT.sh.on() and t.id and E.link
	if link and t.id ~= link.id and not S.reparent then
		local ins = inputs_of(find(t.id))
		if #ins == 1 then
			send({op = "link", id = link.id, comp = link.comp,
				output = link.output, to = t.id, input = ins[1].name})
			log:info("kit editor: link tapped on " .. t.id .. " " .. ins[1].name)
			E.link, E.status = nil, ""
			refresh()
			return
		end
	end
	if t.id and NT.pick_parent(t.id) then
		return
	end
	if t.id then
		select(t.id, S.press.shift)
		return
	end
	-- Switch parent armed: a click on nothing keeps it armed
	if S.reparent then
		return
	end
	if not S.press.shift then
		if next(S.sel) then
			select(nil)
		end
		-- The cursor, which the other builders see
		local c = place_cell(S.press.mx, S.press.my)
		if c then
			E.cursor = c
			log:info("kit editor: cursor at " .. table.concat(c, ","))
			focus()
		end
	end
end

-- The right button let go where it was pressed: placing stops; on an
-- entity its menu, on nothing the selection goes ([FP]'s)
local function right_click(rc)
	if S.tool == "terrain" then
		M.set_tool(nil)
		return
	end
	if S.placing then
		S.placing = nil
		log:info("kit editor: placing nothing")
		palette()
		return
	end
	local p = pick(rc.mx, rc.my)
	if p and p.id then
		context_menu(p.id, rc.mx, rc.my)
	elseif next(S.sel) then
		select(nil)
	end
end

-- Escape's, the tools' first ([FP_ESC]: down one level): a dialog or the
-- menu, a drag, placing, a pending link, the crosshair. True when taken
function M.escape()
	if S.view == "hud" then
		set_view(S.before_hud)
		return true
	end
	if W.dialog or W.ctx then
		drop("dialog")
		close_menu()
		return true
	end
	if NT.sig() then
		if not NT.sg.escape() then
			set_view(S.before_signals or "walk")
		end
		return true
	end
	if S.drag then
		S.drag, S.press = nil, nil
		clear_preview()
		show_ports("in", nil)
		E.link, E.status = nil, ""
		log:info("kit editor: the drag given up")
		return true
	end
	if T.down then
		stroke_end(S.mx, S.my)
		return true
	end
	if S.reparent then
		NT.arm_parent(nil)
		return true
	end
	-- In the crosshair Escape leaves it first, the voxels tool kept
	if S.tool and not M.looking() then
		M.set_tool(nil)
		return true
	end
	if S.placing then
		S.placing = nil
		log:info("kit editor: placing nothing")
		palette()
		return true
	end
	if M.cancel_link() then
		return true
	end
	if M.looking() then
		S.crosshair = false
		log:info("kit editor: out of the crosshair")
		changed()
		return true
	end
	return false
end

-- A pending link cancelled: true if there was one (the tools' Escape
-- takes it before the app's pause menu)
function M.cancel_link()
	if not E.link then
		return false
	end
	E.link, E.status = nil, ""
	log:info("kit editor: link cancelled")
	refresh()
	return true
end

-- [KIT] stage 5 kit.show_credits(): who made what the composition uses,
-- the server's (each package with its version and licences, Kit's, the
-- app's and each builder's). From the pause menu (menu given): a page of
-- it, its Close or Escape the menu again
function M.show_credits(menu)
	menu = type(menu) == "table" and menu or nil
	drop("dialog")
	local w = window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
	W.dialog = w
	w.priority = 10
	w:SetFixedWidth(math.min(560, magic.ui.root.width - 16))
	text(w, "Credits: what this world is made of")
	for _, c in ipairs(E.credits or {}) do
		local who = c.package and tostring(c.package) .. " " ..
				tostring(c.version) .. " by " .. tostring(c.author) .. " (" ..
				tostring(c.license_code) .. ", " .. tostring(c.license_media) ..
				")" or c.of == "kit" and "Kit (Buildat)" or c.of == "app" and
				"The app (" .. tostring(c.author) .. ")" or
				"Built here by " .. tostring(c.author)
		local uses = {}
		for _, u in ipairs(type(c.uses) == "table" and c.uses or {}) do
			uses[#uses + 1] = tostring(u)
		end
		local t = text(w, who)
		t:SetWordwrap(true)
		local u = text(w, "  " .. table.concat(uses, ", "), DIM)
		u:SetWordwrap(true)
		log:info("kit editor: credit " .. who .. ": " .. table.concat(uses, " "))
	end
	if #(E.credits or {}) == 0 then
		text(w, "Nothing placed yet", DIM)
	end
	local function close()
		drop("dialog")
		log:info("kit editor: the credits closed")
		if menu then
			menu.back()
		end
	end
	button(w, "Close", close)
	if menu then
		menu.hold(close, w)
	end
end

-- Kit's items in an app's pause menu (extensions/pause_menu), a builder's:
-- Edit ("Play mode" while the tools are on), Run or End, End all rounds
-- and Remove all bots; everyone's
-- Credits...; and the tools' Escape first
function M.add_menu_items(menu)
	E.menu = menu
	menu.add(function()
		return E.can_edit and (E.editing and "Play mode" or "Edit") or nil
	end, M.toggle_tools, {order = 10})
	menu.add(function()
		return E.can_edit and not E.persistent and
				(E.running and "End" or "Run") or nil
	end, function()
		if E.running then M.stop() else M.play() end
	end, {order = 11})
	-- [KIT_BUILDER_ROUND_CONTROLS] a builder's, in edit mode too and in a
	-- round: every round ended, every bot made in play gone (the server's
	-- refusal says when there is none)
	menu.add(function()
		return E.can_edit and "End all rounds" or nil
	end, function() send({op = "end_rounds"}) end, {order = 12})
	menu.add(function()
		return E.can_edit and "Remove all bots" or nil
	end, function() send({op = "remove_bots"}) end, {order = 13})
	menu.add("Credits...", function() M.show_credits(menu) end,
			{order = 70, page = true})
	menu.on_escape(M.escape)
	M.on_change(menu.refresh)
	O.menu = O.menu or function() menu.open() end
end

-- The crosshair let go of (the app's lost pointer lock): true if it was up
function M.drop_crosshair()
	if not M.looking() then
		return false
	end
	S.crosshair = false
	changed()
	return true
end

-- ---- [KIT] stage 4f: the terrain tool. T (or the panel's Terrain tab)
-- shows its brushes: Raise, Lower, Smooth, Flatten (to the
-- stroke's first point), Paint (the biome's ground), Fill (a rectangle
-- dragged, up to its first corner's level, with the biome's ground or
-- water) and Decorate (the biome's scatter; in a cave its floor's and
-- wall's), their size and strength ([ and ], with Shift the strength) and
-- the biome. A left drag on the ground is a stroke (one undo), its dabs
-- as it moves and while it stays; a touchscreen's finger the same. The
-- brush is a circle on the ground in what it does' colour; a right click
-- or Escape puts the tool away (floorplanner's Object tool).
-- [KIT_VOXEL_EDITS] Under the brushes the World's edited sections, each
-- with its cells unlike the generator's, Regenerate and Regenerate all
-- (Ended: the section generated again, one undo); a row hovered outlines
-- its section brighter; with the tool on every edited section is
-- outlined in 2D and 3D
local heightmap = require("buildat/module/heightmap")

function M.set_tool(tool)
	if S.tool == tool then
		return
	end
	-- [KIT_PREFAB_VOXELS] the Box tool's box goes with it
	if S.tool == "box" then
		S.vbox, S.box_drag = nil, nil
	end
	S.tool = tool
	T.down, T.fill = false, nil
	S.placing = nil
	if tool then
		S.reparent = nil
	end
	log:info("kit editor: tool " .. tostring(tool or "select"))
	if tool == "terrain" then
		send({op = "edited"})
	end
	refresh()
end

function M.brush_size(d)
	T.size = math.max(1, math.min(MAX_BRUSH, T.size + d))
	log:info("kit editor: brush size " .. T.size)
	palette()
end

function M.brush_strength(d)
	T.strength = math.max(1, math.min(5, T.strength + d))
	log:info("kit editor: brush strength " .. T.strength)
	palette()
end

-- What a brush does, in its colour: adding green, taking away red, the
-- rest the hover's
local function brush_color()
	return (T.brush == "lower" or T.brush == "dedecorate") and M.DIG or
			(T.brush == "smooth" or
			T.brush == "flatten" or T.brush == "reset") and M.HOVER or M.PLACE
end

local BRUSH_TEXT = {raise = "raise the ground", lower = "lower the ground",
	smooth = "smooth the ground", flatten = "flatten to the stroke's start",
	paint = "paint the biome's ground", decorate = "decorate (the biome's)",
	dedecorate = "take the World's decorations away",
	fill = "drag: fill a rectangle up to here",
	reset = "back to the generated ground",
	seed = "a ball of ground here, in the air too (an island's start)"}

terrain_panel = function(w)
	local r
	for i, b in ipairs(BRUSHES) do
		if i % 2 == 1 then
			r = row(w)
		end
		button(r, BRUSH_NAMES[b], function()
			T.brush = b
			log:info("kit editor: brush " .. b)
			palette()
		end, T.brush == b)
	end
	for _, k in ipairs({{"Size", T.size, M.brush_size},
			{"Strength", T.strength, M.brush_strength}}) do
		local sr = row(w)
		label(sr, k[1] .. " " .. k[2], 80)
		button(sr, "-", function() k[3](-1) end)
		button(sr, "+", function() k[3](1) end)
	end
	local tr = E.state and E.state.terrain or {}
	local choices = {}
	for _, b in ipairs(tr.biomes or {}) do
		choices[#choices + 1] = {b, b}
	end
	if T.brush == "fill" then
		choices[#choices + 1] = {"water", "water"}
	end
	text(w, "Biome", DIM)
	ui_utils.dropdown(w, choices, T.biome or tr.biome, function(v)
		T.biome = v
		log:info("kit editor: brush biome " .. tostring(v))
	end, {height = 24})
	text(w, tr.surface == "heightmap" and "On the heightmap (and voxel islands)" or
			"On the voxels", DIM)
	-- [KIT_VOXEL_EDITS] The sections somebody wrote, which a change of the
	-- World's parameters keeps: each its cells unlike the generator's
	-- (hovered, outlined in the view), Regenerate dropping its writes (one
	-- undo)
	local l = ED.list
	if not l then
		return
	end
	local secs = type(l.sections) == "table" and l.sections or {}
	text(w, "Edited sections: " .. (#secs + (tonumber(l.more) or 0)), DIM)
	if #secs == 0 then
		return
	end
	for _, e in ipairs(secs) do
		local s = e.s
		local n = tonumber(e.cells) or -1
		local r = row(w)
		label(r, table.concat(s, ",") .. ": " .. (n < 0 and
				"not loaded" or n .. " cells") .. (e.owned and
				" (a component's)" or ""), 130)
		button(r, "Regenerate", function()
			log:info("kit editor: regenerate " .. table.concat(s, ","))
			send({op = "regenerate", s = s})
		end)
		ED.rows[#ED.rows + 1] = {el = r, s = s}
	end
	button(w, "Regenerate all", function()
		log:info("kit editor: regenerate all")
		send({op = "regenerate", all = true})
	end)
end

-- The edited sections hovered in the terrain panel's list (the pointer's
-- pixels), and outlined in the view: the terrain tool's, the hovered one
-- brighter
local function draw_edited(dbg, mx, my)
	if S.tool ~= "terrain" or not ED.list then
		return
	end
	local sc = magic.ui.scale
	local x, y = mx / sc, my / sc
	local hover = nil
	if NT.view and inside(NT.view, x, y) then
		for _, r in ipairs(ED.rows) do
			if inside(r.el, x, y) then
				hover = r.s
			end
		end
	end
	local key = hover and table.concat(hover, ",")
	if key ~= ED.hover then
		ED.hover = key
		log:info("kit editor: section hovered: " .. tostring(key))
	end
	if S.view == "walk" then
		return
	end
	local n = tonumber(ED.list.size) or 64
	for _, e in ipairs(type(ED.list.sections) == "table" and
			ED.list.sections or {}) do
		local s = e.s
		local lit = table.concat(s, ",") == key
		dbg:AddBoundingBox(magic.BoundingBox(
				magic.Vector3(s[1] * n - 0.5, s[2] * n - 0.5, s[3] * n - 0.5),
				magic.Vector3((s[1] + 1) * n - 0.5, (s[2] + 1) * n - 0.5,
				(s[3] + 1) * n - 0.5)), lit and magic.Color(1, 1, 0.3) or
				magic.Color(1, 0.45, 0.1), false)
	end
end

-- The ground the pointer is on: {x, y, z}, a voxel's cell (its top cell)
-- or a heightmap's point; nil off the ground. [KIT_AIRSHIPS_2] on = "voxels":
-- a voxel over a heightmap (a floating island's), which the brush works on
-- instead of the map; the seed's is the cell in front of the voxel pointed
-- at (of a heightmap's ground nearer than SEED_AIR), else SEED_AIR cells
-- along the ray, in the air
local SEED_AIR = 12
brush_at = function(mx, my)
	local o, v = M.screen_ray(mx, my)
	v = v:Normalized()
	if O.solid then
		local hit, front, t = M.voxel_ray({o.x, o.y, o.z}, {v.x, v.y, v.z},
				O.solid, MAX_RAY)
		local vox = hit and heightmap.terrain and
				not M.terrain_cell(hit[1], hit[2], hit[3])
		if T.brush == "seed" and hit and front and (vox or
				not heightmap.terrain or t < SEED_AIR) then
			return {x = front[1], y = front[2], z = front[3], on = "voxels"}
		elseif T.brush == "seed" then
		elseif hit and heightmap.terrain and not vox then
			local p = o + v * t
			local h = heightmap.height_at(p.x, p.z)
			if h then
				return {x = p.x, y = h, z = p.z}
			end
		elseif hit then
			return {x = hit[1], y = hit[2], z = hit[3],
				on = vox and "voxels" or nil}
		end
	end
	if T.brush == "seed" then
		local p = o + v * SEED_AIR
		return {x = round(p.x), y = round(p.y), z = round(p.z), on = "voxels"}
	end
	local g = ground_at(o, v)
	return g and {x = g[1], y = g[2] - 1, z = g[3]} or nil
end

-- The ground's surface at a column near y0 (a voxel's top face), for the
-- brush's circle
local function surface_y(x, z, y0)
	if heightmap.terrain then
		local h = heightmap.height_at(x, z)
		return h and h + 0.05 or y0
	end
	if not O.solid then
		return O.ground_y - 0.45
	end
	local cx, cz = round(x), round(z)
	local top = round(y0) + T.size + 3
	local above = O.solid(cx, top + 1, cz)
	for y = top, top - T.size - 12, -1 do
		local s = O.solid(cx, y, cz)
		if s and not above then
			return y + 0.55
		end
		above = s
	end
	return round(y0) + 0.55
end

local function dab(pt)
	send({op = "terrain", tool = T.brush, x = pt.x, y = pt.y, z = pt.z,
		size = T.size, strength = T.strength, stroke = T.stroke,
		biome = T.biome, level = T.level, on = pt.on})
	T.last = {x = pt.x, z = pt.z, t = buildat.get_time_us()}
	T.dabs = T.dabs + 1
end

stroke_begin = function(mx, my)
	local pt = brush_at(mx, my)
	if not pt then
		return false
	end
	-- An id of its own: every dab of it one undo
	T.stroke = math.floor(buildat.get_time_us()) % 1000000000000
	T.down, T.level, T.dabs = true, pt.y, 0
	log:info(string.format("kit editor: a %s stroke at %g, %g, %g%s", T.brush,
			pt.x, pt.y, pt.z, pt.on and " (on the " .. pt.on .. ")" or ""))
	if T.brush == "fill" then
		T.fill = pt
		return true
	end
	dab(pt)
	return true
end

-- Each frame while it is down: a dab where it moved half the brush, or
-- where it stays a while
stroke_move = function(mx, my)
	-- (a seed is one a click: held, the next would go on the one before)
	if not T.down or T.brush == "fill" or T.brush == "seed" then
		return
	end
	local pt = brush_at(mx, my)
	if not pt or not T.last then
		return
	end
	local now = buildat.get_time_us()
	local d = math.sqrt((pt.x - T.last.x) ^ 2 + (pt.z - T.last.z) ^ 2)
	if (d >= math.max(1, T.size * 0.5) and now - T.last.t > 50000) or
			now - T.last.t > 150000 then
		dab(pt)
	end
end

stroke_end = function(mx, my)
	if not T.down then
		return
	end
	T.down = false
	if T.brush == "fill" and T.fill then
		local pt = brush_at(mx, my) or T.fill
		send({op = "terrain", tool = "fill", x = T.fill.x, y = T.fill.y,
			z = T.fill.z, x1 = pt.x, z1 = pt.z, level = T.level,
			biome = T.biome, stroke = T.stroke})
		log:info(string.format("kit editor: fill %g, %g to %g, %g", T.fill.x,
				T.fill.z, pt.x, pt.z))
	else
		log:info("kit editor: the stroke ended, " .. T.dabs .. " dabs")
	end
	T.fill = nil
	-- The edited sections as the stroke left them (after its dabs: the
	-- server takes them in order)
	send({op = "edited"})
end

-- The brush on the ground: its circle (a fill's rectangle) where it is
draw_brush = function(dbg, mx, my)
	if S.tool ~= "terrain" or (over_ui(mx, my) and not T.down) then
		return
	end
	local col = brush_color()
	local pt = brush_at(mx, my)
	if T.brush == "fill" and T.fill then
		pt = pt or T.fill
		local y = T.level + (heightmap.terrain and 0.05 or 0.55)
		local x0, x1 = math.min(T.fill.x, pt.x) - 0.5, math.max(T.fill.x, pt.x) + 0.5
		local z0, z1 = math.min(T.fill.z, pt.z) - 0.5, math.max(T.fill.z, pt.z) + 0.5
		dbg:AddBoundingBox(magic.BoundingBox(magic.Vector3(x0, y - 0.02, z0),
				magic.Vector3(x1, y + 0.02, z1)), col, false)
		return
	end
	if not pt then
		return
	end
	if T.brush == "seed" then
		local r = T.size - 0.5
		dbg:AddBoundingBox(magic.BoundingBox(magic.Vector3(pt.x - r, pt.y - r,
				pt.z - r), magic.Vector3(pt.x + r, pt.y + r, pt.z + r)), col, false)
		return
	end
	local r = T.size + 0.5
	local prev = nil
	for i = 0, 40 do
		local a = i / 40 * 2 * math.pi
		local x, z = pt.x + r * math.cos(a), pt.z + r * math.sin(a)
		local p = magic.Vector3(x, surface_y(x, z, pt.y), z)
		if prev then
			dbg:AddLine(prev, p, col, false)
		end
		prev = p
	end
	dbg:AddCross(magic.Vector3(pt.x, surface_y(pt.x, pt.z, pt.y), pt.z), 0.6,
			col, false)
end

-- ---- [KIT_EDIT_VOXELS] the voxels tool (V, or Voxels on the palette's
-- title): on while a voxel is in hand (the palette's Voxel list; "none"
-- puts it away, as do V and Escape). A left click places it on the face
-- pointed at, Shift+left digs the voxel pointed at, each one edit (one
-- undo) through Kit's routed writes ("set_voxel"); walking, as play, the
-- left button digs and the right one places (a tap and a finger held), at
-- the crosshair within play's reach (O.reach, 6 cells past the body); the
-- other views at the pointer, where the right button stays the view's and
-- the entity menu's.
-- simplified: a click is one cell, and in 2D and 3D a touchscreen's tap
-- selects as before; a left drag filling a box (Shift: clearing one), one op and
-- one undo, is the upgrade
local function voxel_target(mx, my)
	if not O.solid then
		return nil
	end
	local o, v = M.screen_ray(mx, my)
	v = v:Normalized()
	local reach = MAX_RAY
	if S.view == "walk" then
		-- A camera away from the eye reaches as far past the player
		-- (Workbench's target())
		local b = M.body_pos and M.body_pos()
		local far = b and math.sqrt((o.x - b.x) ^ 2 + (o.y - b.y - 1.5) ^ 2 +
				(o.z - b.z) ^ 2) or 0
		reach = (O.reach or 6) + (far > 1 and far or 0)
	end
	local solid = M.with_terrain(O.solid)
	local hit, front, t = M.voxel_ray({o.x, o.y, o.z}, {v.x, v.y, v.z}, solid,
			reach)
	-- [KIT_HM_VOXELS] on the heightmap: the cell over the hit point
	front = M.place_front(hit, front, {o.x, o.y, o.z}, {v.x, v.y, v.z}, t,
			solid)
	return hit and {cell = hit, front = front,
		y = t and o.y + v.y * t} or nil
end

local function voxel_click(mx, my, dig)
	local t = voxel_target(mx, my)
	local c = t and (dig and t.cell or t.front)
	if not c or not S.voxel then
		return
	end
	-- The heightmap is not dug: voxels only (the Terrain tool's)
	if dig and M.terrain_cell(c[1], c[2], c[3]) then
		log:info("kit editor: dig: the heightmap is not dug, at " ..
				table.concat(c, ","))
		return
	end
	local name = dig and "air" or M.hand_voxel(S.voxel)
	local j = {op = "set_voxel", pos = c, voxel = name}
	if not dig then
		-- [KIT_VOXEL_FORMAT] the facing from the view, the tint
		local o, v = M.screen_ray(mx, my)
		v = v:Normalized()
		local n = {c[1] - t.cell[1], c[2] - t.cell[2], c[3] - t.cell[3]}
		if math.abs(n[1]) + math.abs(n[2]) + math.abs(n[3]) ~= 1 then
			n = {0, 1, 0}
		end
		j.param = M.hand.shape ~= "" and M.shape_param(v, n, t.y) or 0
		j.tint = M.hand.tint
	end
	-- [KIT_HM_VOXELS] on the heightmap: the surface it is sunken in
	local h = not dig and M.terrain_cell(t.cell[1], t.cell[2], t.cell[3]) and
			heightmap.height_at(c[1], c[3])
	if h then
		log:info(string.format("kit editor: on the heightmap, its surface " ..
				"at %.3f", h))
	end
	log:info("kit editor: " .. (dig and "dig" or "place " .. name) .. " at " ..
			table.concat(c, ",") .. (j.param and j.param ~= 0 and
			" param " .. j.param or "") .. (j.tint and j.tint ~= 0 and
			" tint " .. j.tint or ""))
	send(j)
end

-- [KIT_PREFAB_VOXELS] The Box tool: a click on a voxel (or the ground
-- cell) a corner of the box, the first and then the second; a third
-- starts a new box
local function box_click(mx, my)
	local t = voxel_target(mx, my)
	local c = t and t.cell or place_cell(mx, my)
	if not c then
		return
	end
	local b = S.vbox
	if not b or b.b then
		S.vbox = {a = c}
		log:info("kit editor: box corner " .. table.concat(c, ","))
	else
		b.b = c
		log:info("kit editor: box " .. table.concat(vbox(), ","))
	end
	refresh()
end

-- [KIT_PREFAB_VOXELS] The copy (the server's, the builder's): the
-- selected entities and the Box tool's voxels
function M.copy()
	local ids, box = sel_ids(), vbox()
	if #ids == 0 and not box then
		log:info("kit editor: copy: nothing selected and no box")
		return
	end
	send({op = "copy", ids = #ids > 0 and ids or nil, box = box})
	log:info("kit editor: copy of " .. #ids .. " entities" .. (box and
			" and the box " .. table.concat(box, ",") or ""))
end

-- A paste: the copy placed as a prefab is, turned with Z and X
function M.paste()
	if not (E.state and E.state.clipboard) then
		log:info("kit editor: paste: nothing copied")
		return
	end
	M.set_tool(nil)
	S.placing = {clipboard = true, label = "Paste", turn = 0}
	log:info("kit editor: pasting")
	refresh()
end

function M.toggle_box()
	M.set_tool(S.tool ~= "box" and "box" or nil)
end

-- The box a voxel prefab's (or the copy's) voxels would fill placed at
-- cell, turned: its low and high cells
local function turn_xz(x, z, turn)
	for _ = 1, math.floor((turn or 0) / 90) % 4 do
		x, z = z, -x
	end
	return x, z
end
function M.placed_box(cell, item)
	local cb = item.clipboard and E.state and E.state.clipboard
	local size = cb and cb.size
	if not size or size[1] == 0 then
		return nil
	end
	local at = cb.at or {0, 0, 0}
	local x0, z0 = turn_xz(at[1], at[3], item.turn)
	local x1, z1 = turn_xz(at[1] + size[1] - 1, at[3] + size[3] - 1, item.turn)
	local base = {round(cell[1]), round(cell[2]), round(cell[3])}
	return {base[1] + math.min(x0, x1), base[2] + at[2],
			base[3] + math.min(z0, z1)},
		{base[1] + math.max(x0, x1), base[2] + at[2] + size[2] - 1,
			base[3] + math.max(z0, z1)}
end

-- [KIT_REPARENT_BUTTONS] Switch parent armed for id (nil: disarmed)
function NT.arm_parent(id)
	if S.reparent == id then
		return
	end
	S.reparent = id
	if id then
		S.placing = nil
		-- A window with one column at a time: the list it is picked from
		if NT.sig() and NT.sg.is_narrow then
			NT.sg.tab = "list"
		end
		log:info("kit editor: switch parent of " .. id .. ": armed (" ..
				NT.parent_cancel() .. ")")
		E.status = "Switch parent: pick the new parent of " .. id ..
				" (" .. NT.parent_cancel() .. ")"
	else
		log:info("kit editor: switch parent cancelled")
		E.status = ""
	end
	refresh()
end

-- ([KIT_SIGNALS_PARENT_LEFTOVERS] A touchscreen has no Escape: the
-- Inspector's "Switch parent: Cancel" button)
function NT.parent_cancel()
	return S.touch and "Cancel: the Inspector's button" or "Escape: cancel"
end

-- The entity clicked while Switch parent is armed: its parent, one of the
-- scene's positioned or a panel (only a UI element under that: the server
-- says so); true when taken
function NT.pick_parent(id)
	local child = S.reparent
	if not child then
		return false
	end
	local e, is_made = find(id)
	if id == child or not e or is_made or not (e.pos or NT.is_panel(e)) then
		E.status = "Switch parent: " .. (id == child and "not itself" or
				is_made and "not one made in play" or
				"one with a position or a panel") .. "; " .. NT.parent_cancel()
		log:info("kit editor: switch parent of " .. child .. ": not " .. id)
		people()
		return true
	end
	log:info("kit editor: switch parent of " .. child .. " to " .. id)
	send({op = "parent", id = child, parent = id})
	S.reparent, E.status = nil, ""
	refresh()
	return true
end

-- ---- Input: the mouse ([FP]'s mouse_down, mouse_up, mouse_move)
local function mouse_down(button_)
	if not E.editing or S.touch then
		return
	end
	local mx, my = S.mx, S.my
	if button_ == magic.MOUSEB_LEFT and not M.looking() then
		local item = palette_at(mx, my)
		if item then
			NT.menu_press(mx, my)
			S.palette_press = {item = item, mx = mx, my = my}
			S.palette_dragged = nil
			return
		end
	end
	if over_ui(mx, my) and not M.looking() then
		NT.menu_press(mx, my)
		return
	end
	if W.ctx then
		close_menu()
		S.swallow_up = button_
		return
	end
	-- Walking, a click on the view goes up into the crosshair, where the
	-- app has a mouse look ([FP_ESC]). ([KIT_PHONE_EDITING] Not in the touch
	-- mode, where the left click is a finger's tap and the right drag turns)
	local sh = NT.sh.on()
	if O.mouse_look and S.view == "walk" and not S.crosshair and
			button_ == magic.MOUSEB_LEFT and not sh then
		S.crosshair = true
		S.swallow_up = button_
		log:info("kit editor: into the crosshair")
		changed()
		return
	end
	if S.tool == "terrain" and button_ == magic.MOUSEB_LEFT then
		stroke_begin(mx, my)
		return
	end
	if S.tool == "box" and button_ == magic.MOUSEB_LEFT then
		-- [KIT_BOX_ADJUST] a face's handle dragged
		local h = BX.box_handle_at(mx, my)
		if h then
			local sx, sy = to_screen(h.at)
			BX.box_grab(h, sx, sy, key_held(magic.KEY_LSHIFT) or
					key_held(magic.KEY_RSHIFT))
			return
		end
		box_click(mx, my)
		return
	end
	if S.tool == "voxels" and button_ == magic.MOUSEB_LEFT then
		-- Walking, the left button digs as in play (the touch mode's in each
		-- view, as a finger's tap)
		voxel_click(mx, my, S.view == "walk" or sh or
				key_held(magic.KEY_LSHIFT) or key_held(magic.KEY_RSHIFT))
		return
	end
	if button_ == magic.MOUSEB_RIGHT then
		S.right_click = {moved = 0, mx = mx, my = my}
		if M.looking() then
			return
		end
		-- 2D: into 3D once it moves (mouse_move), a click staying a click
		if S.view == "3d" then
			S.orbit = camera_pivot(mx, my)
		end
		return
	end
	if button_ == magic.MOUSEB_MIDDLE then
		-- ([KIT_PHONE_EDITING] the touch mode's: a pinch, up zooming in)
		if sh then
			S.pinch = {mx = mx, my = my}
		elseif S.view == "2d" then
			S.panning = true
		elseif S.view == "3d" then
			S.pan3d = pan3d_start(mx, my)
		end
		return
	end
	if button_ == magic.MOUSEB_LEFT then
		local shift = key_held(magic.KEY_LSHIFT) or key_held(magic.KEY_RSHIFT) or
				more()
		S.press = {mx = mx, my = my, shift = shift,
			target = press_target(mx, my)}
	end
end

local function mouse_up(button_)
	if not E.editing or S.touch then
		return
	end
	if S.swallow_up == button_ then
		S.swallow_up = nil
		return
	end
	if button_ == magic.MOUSEB_LEFT and T.down then
		stroke_end(S.mx, S.my)
		return
	end
	if button_ == magic.MOUSEB_LEFT and S.box_drag then
		BX.box_drop()
		return
	end
	if button_ == magic.MOUSEB_LEFT and S.palette_press then
		local pp = S.palette_press
		S.palette_press = nil
		if S.drag and S.drag.kind == "palette" then
			S.drag = nil
			if not over_ui(S.mx, S.my) then
				place_at(place_cell(S.mx, S.my), pp.item)
			else
				log:info("kit editor: the drag from the palette given up")
			end
		end
		return
	end
	if button_ == magic.MOUSEB_RIGHT then
		local rc = S.right_click
		S.right_click = nil
		local orbited = S.orbit
		S.orbit = nil
		if rc and rc.moved < RIGHT_CLICK_PX and S.tool == "voxels" and
				(S.view == "walk" or NT.sh.on()) then
			-- Walking, the right button places as in play (the touch mode's in
			-- each view, as a finger held)
			voxel_click(rc.mx, rc.my, false)
		elseif rc and rc.moved < RIGHT_CLICK_PX then
			if M.looking() then
				-- The menu wants the pointer
				S.crosshair = false
				changed()
				local w, h, ox, oy = screen_size()
				rc.mx, rc.my = ox + w / 2, oy + h / 2
			end
			right_click(rc)
		elseif orbited and S.from_plan and plan_aligned() then
			-- Back to the plan, where its floor is the view's
			local o = S.pos
			local q = rot3d() * magic.Vector3(0, 0, 1)
			local t = q.y < -1e-6 and ((S.cut or O.ground_y) - o.y) / q.y or 0
			S.cx, S.cz = o.x + q.x * t, o.z + q.z * t
			S.span = math.max(4, math.min(400, math.abs(o.y - (S.cut or 0)) *
					2 * math.tan(math.rad(cam3d.fov) / 2)))
			set_view("2d")
		elseif rc and NT.sh.on() then
			-- (the touch mode's: a right drag moved the view, for a check)
			local p = S.pos or {x = 0, y = 0, z = 0}
			log:info(string.format("kit editor: the right drag let go: the plan "
					.. "at %.1f,%.1f, the camera at %.1f,%.1f,%.1f", S.cx or 0,
					S.cz or 0, p.x, p.y, p.z))
		end
		return
	end
	if button_ == magic.MOUSEB_MIDDLE then
		if S.pan3d then
			local f = S.pan3d.from
			log:info(string.format("kit editor: panned in 3D from %.2f,%.2f,%.2f"
					.. " to %.2f,%.2f,%.2f", f.x, f.y, f.z, S.pos.x, S.pos.y,
					S.pos.z))
		end
		if S.pinch then
			log:info("kit editor: the middle let go: " .. (S.view == "2d" and
					string.format("the plan %.1f across", S.span) or S.pos and
					string.format("the camera at %.1f,%.1f,%.1f", S.pos.x,
					S.pos.y, S.pos.z) or "in " .. tostring(S.view)))
		end
		S.panning, S.pan3d, S.pinch = false, nil, nil
		return
	end
	if button_ ~= magic.MOUSEB_LEFT or not S.press then
		return
	end
	if S.press.cam then
		-- ([KIT_PHONE_EDITING] the touch mode's left drag on nothing: the
		-- view moved)
		S.press, S.pan3d = nil, nil
		return
	end
	if S.drag then
		end_drag()
	else
		click()
	end
	S.press = nil
end

local function mouse_move(x, y, dx, dy)
	if S.box_drag then
		BX.box_drag_move(x, y)
		return
	end
	local rc = S.right_click
	-- [KIT_PHONE_EDITING] stage 3, the touch mode's mouse: the middle a
	-- pinch (up zooms in, about where it was pressed), the right drag the
	-- two fingers' (the plan pans; 3D orbits and Walk turns as before)
	if S.pinch then
		zoom_at(-dy / 20, S.pinch.mx, S.pinch.my)
		return
	end
	if rc and S.view == "2d" and NT.sh.on() then
		rc.moved = rc.moved + math.abs(dx) + math.abs(dy)
		if rc.moved >= RIGHT_CLICK_PX then
			local _, h = screen_size()
			local k = S.span / h
			S.cx, S.cz = S.cx - dx * k, S.cz + dy * k
		end
		return
	end
	if rc then
		rc.moved = rc.moved + math.abs(dx) + math.abs(dy)
		if S.view == "2d" and rc.moved >= RIGHT_CLICK_PX and
				not M.looking() then
			-- Into 3D as if it had been 3D all along ([FP_ORBIT_2D]): the
			-- camera straight above the plan's middle, looking down, as
			-- high as makes the cut's plane the plan's; then this is an
			-- orbit round what was pressed.
			-- [KIT_PLAN_3D_SKY] No higher than PLAN_3D_MAX_H: from a plan
			-- zoomed out, the camera sat past Workbench's fog (120 to 200)
			-- and drew only sky; lower, it sees the plan's middle.
			-- simplified: a fixed height, not the app's fog read from its
			-- zone; an app fogging nearer than 100 still fogs it
			local d = math.min(PLAN_3D_MAX_H,
					S.span / (2 * math.tan(math.rad(cam3d.fov) / 2)))
			S.pos = {x = S.cx, y = (S.cut or O.ground_y) + d, z = S.cz}
			S.yaw, S.pitch = 0, 90
			local pivot = camera_pivot(rc.mx, rc.my)
			set_view("3d")
			S.from_plan = true
			S.orbit = pivot
		end
	end
	if S.orbit then
		-- The camera round the point, its offset held in the camera's frame
		local p = S.orbit
		local q0 = rot3d()
		local inv = magic.Quaternion(q0.w, -q0.x, -q0.y, -q0.z)
		local off = inv * (magic.Vector3(S.pos.x, S.pos.y, S.pos.z) - p)
		local k = 0.3 * (S.touch and 0.5 or 1)
		S.yaw = S.yaw + dx * k
		S.pitch = math.max(-90, math.min(90, S.pitch + dy * k))
		local wp = p + rot3d() * off
		S.pos = {x = wp.x, y = wp.y, z = wp.z}
		return
	end
	if S.pan3d then
		-- In the XZ plane: the point grabbed stays under the pointer where
		-- both rays meet its height; else (looking level) by the view's
		-- right and its forward along the ground
		local o0, v0 = M.screen_ray(x - dx, y - dy)
		local o1, v1 = M.screen_ray(x, y)
		local a, b = plane_at(o0, v0, S.pan3d.y), plane_at(o1, v1, S.pan3d.y)
		-- [KIT_CAM_MIN_MOVE] never slower than a point this far away
		-- grabbed: close to a surface, or under it, the pan still goes
		local _, h = screen_size()
		local kpx = 2 * math.tan(math.rad(cam3d.fov) / 2) / h
		local least = 6 * kpx * math.sqrt(dx * dx + dy * dy)
		local mx_, mz_
		if a and b then
			mx_, mz_ = b.x - a.x, b.z - a.z
			local m = math.sqrt(mx_ * mx_ + mz_ * mz_)
			if m < 1e-6 then
				mx_ = nil
			elseif m < least then
				mx_, mz_ = mx_ * least / m, mz_ * least / m
			end
		end
		if not mx_ then
			local k = math.max(6, S.pan3d.dist) * kpx
			local yaw = math.rad(S.yaw)
			local rx, rz = math.cos(yaw), -math.sin(yaw)
			-- right (rx, rz), forward along the ground (-rz, rx)
			mx_, mz_ = (rx * dx + rz * dy) * k, (rz * dx - rx * dy) * k
		end
		S.pos = {x = S.pos.x - mx_, y = S.pos.y, z = S.pos.z - mz_}
		return
	end
	if M.looking() then
		return
	end
	S.mx, S.my = x, y
	if S.panning and S.view == "2d" then
		local _, h = screen_size()
		local k = S.span / h
		S.cx, S.cz = S.cx - dx * k, S.cz + dy * k
	end
	local pp = S.palette_press
	if pp and not S.drag and math.abs(x - pp.mx) + math.abs(y - pp.my) >
			px(DRAG_PX) and not palette_at(x, y) then
		S.drag = {kind = "palette", item = pp.item}
		S.palette_dragged = true
		NT.palette_chosen(pp.item)
		log:info("kit editor: dragging " .. pp.item.label .. " from the palette")
	end
	if S.press and not S.drag and not S.press.cam and math.abs(x - S.press.mx) +
			math.abs(y - S.press.my) > px(DRAG_PX) then
		start_drag()
		-- ([KIT_PHONE_EDITING] the touch mode's: as a finger's, a drag on
		-- nothing moves the view)
		if not S.drag and NT.sh.on() then
			S.press.cam = true
			if S.view == "3d" then
				S.pan3d = pan3d_start(x, y)
			end
		end
	end
	if S.drag then
		update_drag()
	elseif S.press and S.press.cam and S.view == "2d" then
		local _, h = screen_size()
		local k = S.span / h
		S.cx, S.cz = S.cx - dx * k, S.cz + dy * k
	end
end

-- [KIT_WALK_WHEEL] Walking with the voxels tool on (the crosshair's or
-- the pointer's): the wheel steps the voxel in hand through the Voxel
-- list, Shift+wheel its shape (a material with shapes), Ctrl+Shift+wheel
-- its tint; up the one before, as Luanti's hotbar, round at the ends
local function wheel_hand(wheel, q)
	local shift = q % 2 == 1
	local ctrl = math.floor(q / 2) % 2 == 1
	local step = wheel > 0 and -1 or 1
	local function round(i, n)
		return (i - 1) % n + 1
	end
	if ctrl and not shift then
		return
	end
	if not shift then
		local names = voxel_names()
		if #names == 0 then
			return
		end
		local at = 0
		for i, n in ipairs(names) do
			if n == S.voxel then
				at = i
			end
		end
		return M.pick_voxel(names[round(at == 0 and (step > 0 and 0 or 1) +
				step or at + step, #names)])
	end
	if not S.voxel then
		return
	end
	if ctrl then
		local n = #M.tints_of(S.voxel)
		M.hand.tint = (M.hand.tint + step) % n
		log:info("kit editor: tint " .. M.tint_label(S.voxel, M.hand.tint))
		return palette()
	end
	if not M.material_has_shapes(S.voxel) then
		log:info("kit editor: " .. S.voxel .. " has no shapes")
		return
	end
	local shapes = {""}
	local at = 1
	for _, sh in ipairs(M.SHAPES) do
		shapes[#shapes + 1] = sh
		if sh == M.hand.shape then
			at = #shapes
		end
	end
	M.hand.shape = shapes[round(at + step, #shapes)]
	log:info("kit editor: shape " .. (M.hand.shape ~= "" and
			M.hand.shape:gsub("_", " ") or "cube"))
	if O.pick_voxel then
		O.pick_voxel(S.voxel)
	end
	palette()
end

local WEB = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil
local function mouse_wheel(wheel, q)
	if not E.editing then
		return
	end
	if S.view == "walk" and S.tool == "voxels" and wheel ~= 0 and
			(M.looking() or not over_ui(S.mx, S.my)) then
		-- ([KIT_WHEEL_TRACKPAD] a step a notch, a trackpad's small events
		-- added)
		local n = M.wheel_steps("hand", wheel)
		for _ = 1, math.abs(n) do
			wheel_hand(n, q or 0)
		end
		return
	end
	if over_ui(S.mx, S.my) then
		return
	end
	-- In notches; the web's in tenths (its SDL port counts them so)
	zoom_at(math.max(-10, math.min(10, WEB and wheel / 10 or wheel)), S.mx,
			S.my)
end

-- The wheel's zoom by notches (up, in) about a point of the screen
zoom_at = function(notches, mx, my)
	local f = 0.8 ^ notches
	if S.view == "2d" then
		-- About the pointer: the point under it stays under it
		local o0 = M.screen_ray(mx, my)
		S.span = math.max(4, math.min(400, S.span * f))
		place_cameras()
		local o1 = M.screen_ray(mx, my)
		S.cx, S.cz = S.cx + o0.x - o1.x, S.cz + o0.z - o1.z
	elseif S.view == "3d" then
		local o, v = M.screen_ray(mx, my)
		local p = pick(mx, my, nil, true)
		local dist = p and p.t or 10
		local step = math.min(dist * (1 - f), math.max(0, dist - 0.3))
		-- [KIT_CAM_MIN_MOVE] at least a cell a notch: close to a surface,
		-- or under it, the wheel still moves along the look
		local least = math.abs(notches) * 1
		if notches ~= 0 and math.abs(step) < least then
			step = notches > 0 and least or -least
		end
		S.pos = {x = S.pos.x + v.x * step, y = S.pos.y + v.y * step,
			z = S.pos.z + v.z * step}
	end
end

-- ---- Fingers ([FP_TOUCH] 3 and 4): a tap a click, a drag on the
-- selection moves it, elsewhere the view; two pinch and pan or orbit; held
-- still the right click. Walking, the app's stick and turn, the taps and
-- the holds Kit's
local function fingers_n()
	local n = 0
	for _, f in pairs(S.fingers) do
		if not f.ui then
			n = n + 1
		end
	end
	return n
end

local function touch_begin(id, x, y)
	if not E.editing then
		return
	end
	local item = palette_at(x, y)
	local ui = over_ui(x, y)
	S.fingers[id] = {x = x, y = y, x0 = x, y0 = y,
		t0 = buildat.get_time_us(), ui = ui and not item, item = item}
	if item then
		NT.menu_press(x, y)
		S.palette_press = {item = item, mx = x, my = y, finger = id}
		return
	end
	if ui then
		NT.menu_press(x, y)
		return
	end
	if W.ctx then
		close_menu()
		S.fingers[id].ui = true
		return
	end
	S.mx, S.my = x, y
	if fingers_n() == 2 then
		-- Whatever the first began is dropped (a stroke ends where it is)
		if T.down then
			T.fill = nil
			stroke_end(x, y)
		end
		S.press, S.drag, S.panning, S.pan3d = nil, nil, false, nil
		clear_preview()
		local p = S.view == "3d" and camera_pivot(x, y) or nil
		S.gesture = {pivot = p, dist = p and (p - cam3d_node.position):Length()
			or 5}
		return
	end
	-- [KIT] stage 4f: a finger on the ground paints the terrain tool's
	-- stroke
	if S.tool == "terrain" and S.view ~= "walk" then
		S.fingers[id].stroke = stroke_begin(x, y)
		return
	end
	-- [KIT_PHONE_EDITING] stage 3, the touch mode's Box tool: a face's
	-- handle dragged (a tap is a corner, touch_end)
	local h = NT.sh.on() and S.tool == "box" and BX.box_handle_at(x, y)
	if h then
		local sx, sy = to_screen(h.at)
		BX.box_grab(h, sx, sy, false)
		S.fingers[id].box = true
		return
	end
	if S.view ~= "walk" then
		S.press = {mx = x, my = y, target = press_target(x, y), finger = id,
			shift = more()}
	end
end

local function touch_move(id, x, y, dx, dy)
	local f = S.fingers[id]
	if not f or f.ui then
		return
	end
	local px_, py_ = f.x, f.y
	f.x, f.y = x, y
	if math.abs(x - f.x0) + math.abs(y - f.y0) > px(DRAG_PX) then
		f.moved = true
	end
	local pp = S.palette_press
	if pp and pp.finger == id then
		S.mx, S.my = x, y
		-- Out of the panel's view, not off a button: a finger scrolling the
		-- list crosses the gaps between them
		local sc = magic.ui.scale
		if not S.drag and f.moved and not (NT.view and
				inside(NT.view, x / sc, y / sc)) then
			S.drag = {kind = "palette", item = pp.item}
			NT.palette_chosen(pp.item)
			log:info("kit editor: dragging " .. pp.item.label .. " from the palette")
		end
		return
	end
	if f.stroke then
		S.mx, S.my = x, y
		return
	end
	if f.box then
		if S.box_drag then
			BX.box_drag_move(x, y)
		end
		return
	end
	if S.view == "walk" then
		return
	end
	if S.gesture then
		local o = nil
		for oid, of in pairs(S.fingers) do
			if oid ~= id and not of.ui then
				o = of
			end
		end
		if not o then
			return
		end
		local d0 = math.max(1, math.sqrt((px_ - o.x) ^ 2 + (py_ - o.y) ^ 2))
		local d1 = math.max(1, math.sqrt((x - o.x) ^ 2 + (y - o.y) ^ 2))
		local mdx, mdy = (x - px_) / 2, (y - py_) / 2
		if S.view == "2d" then
			-- About the point between the fingers, which follows them
			local w, h, ox, oy = screen_size()
			local ax, ay = (px_ + o.x) / 2 - ox, (py_ + o.y) / 2 - oy
			local k = S.span / h
			local wx, wz = S.cx + (ax - w / 2) * k, S.cz - (ay - h / 2) * k
			S.span = math.max(4, math.min(400, S.span * d0 / d1))
			k = S.span / h
			ax, ay = ax + mdx, ay + mdy
			S.cx, S.cz = wx - (ax - w / 2) * k, wz + (ay - h / 2) * k
		else
			local p = S.gesture.pivot
			if p then
				local q0 = rot3d()
				local inv = magic.Quaternion(q0.w, -q0.x, -q0.y, -q0.z)
				local off = inv * (magic.Vector3(S.pos.x, S.pos.y, S.pos.z) - p)
				S.yaw = S.yaw + mdx * 0.15
				S.pitch = math.max(-90, math.min(90, S.pitch + mdy * 0.15))
				local wp = p + rot3d() * off
				S.pos = {x = wp.x, y = wp.y, z = wp.z}
			end
			local fw = rot3d() * magic.Vector3(0, 0, 1)
			local zoom = S.gesture.dist * (1 - d0 / d1)
			S.gesture.dist = S.gesture.dist - zoom
			S.pos = {x = S.pos.x + fw.x * zoom, y = S.pos.y + fw.y * zoom,
				z = S.pos.z + fw.z * zoom}
		end
		return
	end
	S.mx, S.my = x, y
	if S.press and not S.drag and not S.touch_cam and f.moved then
		start_drag()
		if not S.drag then
			-- The view moves: the plan pans, the 3D camera pans
			S.touch_cam = true
			if S.view == "3d" then
				S.pan3d = pan3d_start(x, y)
			end
		end
	end
	if S.drag then
		update_drag()
	elseif S.touch_cam then
		if S.view == "2d" then
			local _, h = screen_size()
			local k = S.span / h
			S.cx, S.cz = S.cx - dx * k, S.cz + dy * k
		elseif S.pan3d then
			mouse_move(x, y, dx, dy)
		end
	end
end

local function touch_end(id, x, y)
	local f = S.fingers[id]
	S.fingers[id] = nil
	if not f then
		return
	end
	local pp = S.palette_press
	if pp and pp.finger == id then
		S.palette_press = nil
		if S.drag and S.drag.kind == "palette" then
			S.drag = nil
			if not over_ui(x, y) then
				place_at(place_cell(x, y), pp.item)
			end
		end
		-- An untouched one: its button's own tap arms it
		return
	end
	if f.stroke then
		S.mx, S.my = x, y
		stroke_end(x, y)
		return
	end
	if f.box then
		if S.box_drag then
			BX.box_drop()
		end
		return
	end
	if f.ui or f.held then
		return
	end
	if S.gesture then
		if fingers_n() == 0 then
			S.gesture = nil
			-- (S.pos is the 3D camera's: nil in a view never orbited,
			-- alpha.8's crash on touch)
			log:info(string.format("kit editor: two fingers let go: %s",
					S.view == "2d" and string.format("the plan %.1f across",
					S.span) or S.pos and string.format(
					"the camera at %.1f,%.1f,%.1f", S.pos.x, S.pos.y,
					S.pos.z) or "in " .. tostring(S.view)))
		end
		return
	end
	S.mx, S.my = x, y
	local sh = NT.sh.on()
	if S.drag then
		end_drag()
	elseif not f.moved and not S.touch_cam and S.tool == "voxels" and
			(S.view == "walk" or sh) then
		-- Walking with the voxels tool, as play's: a tap digs (the touch
		-- mode's in each view)
		voxel_click(x, y, true)
	elseif not f.moved and not S.touch_cam and sh and S.tool == "box" then
		box_click(x, y)
	elseif not f.moved and not S.touch_cam then
		-- A tap: the left click at the finger
		S.press = S.press or {mx = x, my = y, shift = more()}
		S.press.target = S.press.target or press_target(x, y)
		click()
	end
	S.press, S.touch_cam, S.pan3d = nil, nil, nil
end

-- A finger held still: the right button's ([FP_TOUCH] 4)
local function long_press_tick()
	if not S.touch or not E.editing then
		return
	end
	local only, n = nil, 0
	for fid, f in pairs(S.fingers) do
		only, n = f, n + 1
		only.id = fid
	end
	if n == 1 and not only.ui and not only.item and not only.moved and
			not only.held and not only.stroke and
			buildat.get_time_us() - only.t0 > LONG_PRESS_US then
		only.held = true
		S.press, S.drag = nil, nil
		if S.tool == "voxels" and (S.view == "walk" or NT.sh.on()) then
			-- Walking with the voxels tool, as play's: held, it places (the
			-- touch mode's in each view)
			voxel_click(only.x, only.y, false)
		else
			right_click({mx = only.x, my = only.y})
		end
	end
end

-- ---- Keys
local function nudge(d)
	local l = movable()
	if #l == 0 then
		return false
	end
	if #l == 1 then
		local e = l[1]
		send({op = "move", id = e.id, pos = {e.pos[1] + d[1], e.pos[2] + d[2],
			e.pos[3] + d[3]}})
	else
		local ids = {}
		for _, e in ipairs(l) do
			ids[#ids + 1] = e.id
		end
		send({op = "move", ids = ids, by = d})
	end
	return true
end

-- [KIT_TURN_KEYS_DROP] By, not to: a press before the last one's state is back
-- counts
local function turn_selection(deg)
	local l = movable()
	if #l > 0 then
		local ids = {}
		for _, e in ipairs(l) do
			ids[#ids + 1] = e.id
		end
		send({op = "move", ids = ids, by = {0, 0, 0}, turn = deg})
	end
end

-- Z and X (dir -1 and 1), the touch mode's turn buttons: a prefab or a
-- paste being placed a quarter, else the selection by the angle step
function NT.turn_step(dir)
	if S.placing and (S.placing.prefab or S.placing.clipboard) then
		-- [KIT_PREFAB_VOXELS] a prefab or a paste turned a quarter
		S.placing.turn = ((S.placing.turn or 0) + dir * 90) % 360
		log:info("kit editor: placing turned " .. S.placing.turn)
	else
		turn_selection(dir * (ANGLE_STEPS[S.angle] or 15))
	end
end

-- [KIT_PHONE_EDITING] stage 3, the touch mode's buttons: up or down a grid
-- step (PageUp, PageDown), and Ctrl+D's duplicate
function NT.raise(dir)
	nudge({0, dir * GRID_STEPS[S.grid], 0})
end

function NT.duplicate()
	local ids = sel_ids()
	if #ids > 0 then
		send({op = "duplicate", ids = ids, by = {1, 0, 0}})
	end
end

-- [KIT_PHONE_EDITING] stage 3: an entity just placed near the world's
-- edge in the touch mode (the UI half's beside it): the plan or the 3D
-- camera panned so that it is the touch size inside it, its height kept
-- simplified: not in Walk (the player's eye); by its middle, not its box
function NT.reveal(id)
	local r = NT.sh.on() and S.view ~= "walk" and NT.sh.world_px()
	local e = r and find(id)
	local sx, sy = nil, nil
	if e and e.pos then
		sx, sy = to_screen(drawn_at(e))
	end
	if not sx then
		return
	end
	local m = math.min(NT.sh.TOUCH * magic.ui.scale, r[3] / 2, r[4] / 2)
	local tx = math.max(r[1] + m, math.min(r[1] + r[3] - m, sx))
	local ty = math.max(r[2] + m, math.min(r[2] + r[4] - m, sy))
	if math.abs(tx - sx) < 1 and math.abs(ty - sy) < 1 then
		return
	end
	local o0, v0 = M.screen_ray(sx, sy)
	local o1, v1 = M.screen_ray(tx, ty)
	-- (the plan's rays are straight down from its camera, which may be under
	-- the entity: any height below it)
	local y = S.view == "2d" and o0.y - 1 or drawn_at(e).y
	local a, b = plane_at(o0, v0, y), plane_at(o1, v1, y)
	if not a or not b then
		return
	end
	if S.view == "2d" then
		S.cx, S.cz = S.cx + a.x - b.x, S.cz + a.z - b.z
	else
		S.pos = {x = S.pos.x + a.x - b.x, y = S.pos.y, z = S.pos.z + a.z - b.z}
	end
	log:info(string.format("kit editor: touch shell: panned to show %d, from "
			.. "%d,%d to %d,%d on the screen", id, sx, sy, tx, ty))
end

-- [KIT_HUD_VIEW] A click or a tap: two on nothing of the HUD leave the view.
-- (ui.lua's own handlers select and drag what is of the HUD)
function NT.hud_press(x, y)
	-- ([KIT_PARAM_CATEGORIES] the panel's and its dropdowns' clicks are its own)
	if over_ui(x, y) then
		S.hud_click = nil
		return
	end
	-- The first of a double click may close it
	if W.hud_panel then
		S.hud_panel_off = true
		NT.hud_panel()
	end
	local now, c = buildat.get_time_us(), S.hud_click
	if c and now - c.t < 400000 and math.abs(x - c.x) + math.abs(y - c.y) <
			px(24) then
		S.hud_click = nil
		log:info("kit editor: a double click out of the HUD view")
		M.escape()
	else
		S.hud_click = {t = now, x = x, y = y}
	end
end

local function key_down(key, ctrl, shift)
	-- [KIT_INPUT_ACTIONS] the keys by their actions (input.lua)
	local is = function(id) return M.key(id, key) end
	if is("view_hud") then
		return set_view("hud")
	elseif is("view_signals") then
		return set_view("signals")
	elseif S.view == "signals" and is("undo") and ctrl then
		return send({op = "undo"})
	elseif NT.world_off() and not (is("view_2d") or is("view_3d") or
			is("view_walk")) then
		return
	elseif is("view_2d") then
		return set_view("2d")
	elseif is("view_3d") then
		return set_view("3d")
	elseif is("view_walk") then
		return set_view("walk")
	elseif is("next") then
		-- The last accessed first (S.recent), then the rest by id; Shift
		-- the other way
		local list, placed, rest = {}, {}, {}
		for _, x in ipairs(entities()) do
			if x.pos then
				placed[x.id] = true
				rest[#rest + 1] = x.id
			end
		end
		for _, id in ipairs(S.recent) do
			if placed[id] then
				list[#list + 1] = id
				placed[id] = false
			end
		end
		table.sort(rest)
		local at = 0
		for _, id in ipairs(rest) do
			if placed[id] then
				list[#list + 1] = id
			end
		end
		for i, id in ipairs(list) do
			if id == S.primary then
				at = i
			end
		end
		at = S.tab_at and list[S.tab_at] and S.tab_at or at
		if #list > 0 then
			S.tab_at = at == 0 and (shift and #list or 1) or
					(at - 1 + (shift and -1 or 1)) % #list + 1
			select(list[S.tab_at], false, true)
		end
	elseif is("undo") and ctrl then
		send({op = "undo"})
	elseif is("copy") and ctrl then
		M.copy()
	elseif is("paste") and ctrl then
		M.paste()
	elseif is("duplicate") and ctrl then
		NT.duplicate()
	elseif is("delete") then
		M.delete_selected()
	elseif ctrl then
		return
	elseif is("terrain") and E.state and E.state.terrain then
		M.set_tool(S.tool ~= "terrain" and "terrain" or nil)
	elseif is("voxels") and E.state and E.state.voxels and O.solid then
		M.toggle_voxels()
	elseif is("box") and O.solid then
		M.toggle_box()
	elseif S.tool == "terrain" and (is("smaller") or is("larger")) then
		local d = is("smaller") and -1 or 1
		if shift then
			M.brush_strength(d)
		else
			M.brush_size(d)
		end
	elseif is("grid") then
		M.next_grid()
	elseif is("angle") then
		M.next_angle()
	elseif is("turn_left") or is("turn_right") then
		NT.turn_step(is("turn_left") and -1 or 1)
	else
		local g = shift and 0.25 or GRID_STEPS[S.grid]
		local d = nil
		for _, n in ipairs({{"nudge_left", -1, 0, 0}, {"nudge_right", 1, 0, 0},
				{"nudge_forward", 0, 0, 1}, {"nudge_back", 0, 0, -1},
				{"nudge_up", 0, 1, 0}, {"nudge_down", 0, -1, 0},
				-- 2D: the movement keys move the selection, a press at a time
				S.view == "2d" and {"left", -1, 0, 0} or {},
				S.view == "2d" and {"right", 1, 0, 0} or {},
				S.view == "2d" and {"forward", 0, 0, 1} or {},
				S.view == "2d" and {"back", 0, 0, -1} or {}}) do
			if not d and n[1] and is(n[1]) then
				d = {n[2], n[3], n[4]}
			end
		end
		if d then
			nudge({d[1] * g, d[2] * g, d[3] * g})
		end
	end
end

-- ---- What the pointer would do ([FP_GUIDES]): what it is on, framed in
-- the action's colour, and what each button does, said at the bottom
local hover = M.highlighter()
local guide_hud, guide_shown = nil, nil
local box_bars = {}

-- The box being dragged, four thin bars
local function draw_box_rect()
	local d = S.drag
	local on = d and d.kind == "box" and S.press
	if #box_bars == 0 then
		for i = 1, 4 do
			local b = magic.ui.root:CreateChild("BorderImage")
			b.color = M.HOVER
			b.priority = 50
			box_bars[i] = b
		end
	end
	for _, b in ipairs(box_bars) do
		b.visible = on and true or false
	end
	if not on then
		return
	end
	local sc = magic.ui.scale
	local x0, x1 = math.min(S.press.mx, S.mx) / sc, math.max(S.press.mx, S.mx) / sc
	local y0, y1 = math.min(S.press.my, S.my) / sc, math.max(S.press.my, S.my) / sc
	local function put(b, x, y, w, h)
		b:SetPosition(math.floor(x), math.floor(y))
		b.width, b.height = math.max(1, math.floor(w)), math.max(1, math.floor(h))
	end
	put(box_bars[1], x0, y0, x1 - x0, 1)
	put(box_bars[2], x0, y1, x1 - x0, 1)
	put(box_bars[3], x0, y0, 1, y1 - y0)
	put(box_bars[4], x1, y0, 1, y1 - y0)
end

-- The ghost of what a drop or a click would place: its cell's frame in
-- placing's colour, its name over it
local ghost_label = nil
local function ghost(cell, item)
	if not ghost_label then
		ghost_label = O.scene:CreateChild("kit_ghost_label")
		local t = ghost_label:CreateComponent("Text3D")
		t:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 14)
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		t.faceCameraMode = magic.FC_ROTATE_XYZ
		t.fixedScreenSize = true
		t.textEffect = magic.TE_STROKE
		t.effectColor = magic.Color(0, 0, 0, 0.8)
		t:SetColor(M.PLACE)
	end
	local t = ghost_label:GetComponent("Text3D")
	if not cell then
		ghost_label.enabled = false
		return
	end
	ghost_label.enabled = true
	-- Over it, and in the plan north of it
	ghost_label.position = magic.Vector3(cell[1], cell[2] + 0.8,
			cell[3] + (S.view == "2d" and 0.9 or 0))
	local label = item.label .. ((item.turn or 0) ~= 0 and
			" (turned " .. item.turn .. ")" or "")
	if t.text ~= label then
		t.text = label
	end
	hover.box(v3(cell), magic.Vector3(0.45, 0.45, 0.45), nil, M.PLACE)
	-- [KIT_PREFAB_VOXELS] a paste's voxels' box
	local lo, hi = M.placed_box(cell, item)
	if lo then
		O.debug:AddBoundingBox(magic.BoundingBox(
				magic.Vector3(lo[1] - 0.5, lo[2] - 0.5, lo[3] - 0.5),
				magic.Vector3(hi[1] + 0.5, hi[2] + 0.5, hi[3] + 0.5)),
				M.PLACE, false)
	end
end

local function compute_guide()
	local g = {}
	local mx, my = S.mx, S.my
	if M.looking() then
		local w, h, ox, oy = screen_size()
		mx, my = ox + w / 2, oy + h / 2
	end
	-- Walking at the pointer, where the app looks: a click goes up into
	-- the crosshair
	if O.mouse_look and S.view == "walk" and not S.crosshair and not S.touch then
		g.left = "into the crosshair to select and place (Esc: back)"
		g.right = "drag: turn"
		return g
	end
	local d = S.drag
	if d then
		if d.kind == "move" then
			g.left = string.format("let go: move %d by %g, %g (grid %s)",
					#d.ids, d.dx, d.dz, grid_text())
		elseif d.kind == "turn" then
			g.left = string.format("let go: turn by %g (step %s)", d.turn,
					angle_text())
		elseif d.kind == "box" then
			g.left = "let go: select what is in the box"
		elseif d.kind == "link" then
			local p = pick(mx, my, {[d.from] = true})
			local te = p and p.id and find(p.id)
			local inport = port_at("in", mx, my)
			if inport then
				-- On one of the target's inputs: its ports stay
				M.frame_entity(hover, PORTS["in"].id, M.HOVER)
				show_ports("in", PORTS["in"].id, inputs_of(find(PORTS["in"].id)))
				g.left = "let go: link to " .. PORTS["in"].id .. "'s " ..
						inport.name
			elseif te then
				local ins = inputs_of(te)
				show_ports("in", p.id, ins)
				M.frame_entity(hover, p.id, M.HOVER)
				g.left = "let go: link to " .. name_of(te) .. (#ins == 1 and "'s " ..
						ins[1].name or #ins == 0 and " (it has no inputs)" or
						": onto one of its inputs")
			else
				show_ports("in", nil)
				g.left = "let go on an entity's input to link to it"
			end
		elseif d.kind == "palette" then
			local c = not over_ui(mx, my) and place_cell(mx, my)
			if c then
				ghost(c, d.item)
				g.left = "let go: place " .. d.item.label .. " at " ..
						table.concat(c, ",")
			else
				ghost(nil)
				g.left = "let go on the view to place " .. d.item.label
			end
		end
		return g
	end
	if T.down then
		g.left = T.brush == "fill" and "let go: fill the rectangle up to " ..
				string.format("%g", T.level) or "let go: end the stroke (" ..
				T.dabs .. " dabs, one undo)"
		return g
	end
	if over_ui(mx, my) then
		return nil
	end
	if S.tool == "terrain" then
		ghost(nil)
		local right = S.view == "2d" and "drag: into 3D, orbiting" or
				S.view == "3d" and "drag: orbit" or "drag: turn"
		if brush_at(mx, my) then
			g.left = BRUSH_TEXT[T.brush] .. (T.brush == "fill" and "" or
					string.format(" (size %d, strength %d%s); drag: a stroke",
					T.size, T.strength, T.biome and ", " .. T.biome or ""))
		end
		g.right = "put the terrain tool away; " .. right
		g.note = not S.touch and "[ ]: size, Shift [ ]: strength, Esc: away" or nil
		return g
	end
	if S.tool == "box" then
		ghost(nil)
		local t = voxel_target(mx, my)
		local c = t and t.cell or place_cell(mx, my)
		-- [KIT_BOX_ADJUST] a handle: its face dragged
		local h = S.box_drag and S.box_drag.h or BX.box_handle_at(mx, my)
		if h then
			g.left = "drag: the box's " .. h.name .. " face (Shift: the " ..
					"whole box)"
		elseif c then
			hover.box(v3(c), magic.Vector3(0.5, 0.5, 0.5), nil, M.HOVER)
			g.left = ((S.vbox and not S.vbox.b) and "the box's second corner"
					or "the box's first corner") .. " at " .. table.concat(c, ",")
		end
		g.right = S.view == "2d" and "drag: into 3D, orbiting" or
				S.view == "3d" and "drag: orbit" or "drag: turn"
		g.note = not S.touch and M.key_text("Ctrl+[copy]: copy the box (and " ..
				"the selection), Ctrl+[paste]: paste, [box] or Esc: put the " ..
				"box away") or nil
		return g
	end
	if S.tool == "voxels" and (S.view == "walk" or NT.sh.on()) then
		-- [KIT_PLAYTEST_TWEAKS] walking as in play: left digs, right places
		-- ([KIT_PHONE_EDITING] the touch mode's in each view)
		ghost(nil)
		local t = voxel_target(mx, my)
		if t then
			hover.box(v3(t.cell), magic.Vector3(0.5, 0.5, 0.5), nil, M.DIG)
			if t.front then
				hover.face(t.cell, {t.front[1] - t.cell[1], t.front[2] -
						t.cell[2], t.front[3] - t.cell[3]}, M.PLACE)
			end
			g.left = "dig " .. table.concat(t.cell, ",")
			g.right = t.front and "place " .. tostring(S.voxel) .. " at " ..
					table.concat(t.front, ",") or nil
		end
		g.note = not S.touch and M.key_text("[voxels]: put the voxels away") ..
				(M.looking() and ", Esc: out of the crosshair" or "") or nil
		return g
	end
	if S.tool == "voxels" then
		ghost(nil)
		local t = voxel_target(mx, my)
		if t then
			if key_held(magic.KEY_LSHIFT) or key_held(magic.KEY_RSHIFT) then
				hover.box(v3(t.cell), magic.Vector3(0.5, 0.5, 0.5), nil, M.DIG)
			elseif t.front then
				hover.face(t.cell, {t.front[1] - t.cell[1], t.front[2] -
						t.cell[2], t.front[3] - t.cell[3]}, M.PLACE)
			end
			g.left = t.front and "place " .. tostring(S.voxel) .. " at " ..
					table.concat(t.front, ",") or nil
			g.shift = "dig " .. table.concat(t.cell, ",")
		end
		local p = pick(mx, my)
		g.right = (p and p.id and "its menu; " or "") .. (S.view == "2d" and
				"drag: into 3D, orbiting" or S.view == "3d" and "drag: orbit" or
				"drag: turn")
		g.note = not S.touch and M.key_text("[voxels] or Esc: put the voxels " ..
				"away") or nil
		return g
	end
	if S.placing then
		local c = place_cell(mx, my)
		ghost(c, S.placing)
		g.left = c and "place " .. S.placing.label .. " at " ..
				table.concat(c, ",") or nil
		g.right = "stop placing"
		g.note = "Esc: stop placing"
		return g
	end
	ghost(nil)
	-- [KIT_REPARENT_BUTTONS] the new parent picked
	if S.reparent then
		local p = pick(mx, my)
		local e = p and p.id ~= S.reparent and find(p.id)
		if e and e.pos then
			M.frame_entity(hover, e.id, M.PLACE)
			g.left = "make " .. name_of(e) .. " the parent of " .. S.reparent
		else
			g.left = "pick the new parent of " .. S.reparent
		end
		g.note = "Esc: cancel the parent's switch"
		return g
	end
	local kn = near_knob(mx, my)
	if kn then
		hover.box(kn.at, magic.Vector3(0.15, 0.15, 0.15), nil, M.HOVER)
		g.left = "drag: " .. kn.name .. " of the selection (step " .. angle_text() .. ")"
		return g
	end
	local port = port_at("out", mx, my)
	if port then
		g.left = "drag: link " .. port.name .. " to another's input"
		return g
	end
	local p = pick(mx, my)
	local e = p and p.id and find(p.id)
	local right_drag = S.view == "2d" and "drag: into 3D, orbiting" or
			S.view == "3d" and "drag: orbit round what the pointer is on" or
			"drag: turn"
	if e then
		M.frame_entity(hover, e.id, M.HOVER)
		local name = name_of(e)
		local shift = key_held(magic.KEY_LSHIFT) or key_held(magic.KEY_RSHIFT) or
				more()
		if shift then
			g.left = (S.sel[e.id] and "take " .. name .. " out of" or "add " ..
					name .. " to") .. " the selection"
		elseif S.sel[e.id] then
			g.left = "keep " .. name .. " selected; drag: move the selection"
		else
			g.left = "select " .. name .. ((S.touch or NT.sh.on()) and "" or
					"; drag: select by a box")
		end
		local _, is_made = find(e.id)
		g.right = (is_made and "" or "its menu; ") .. right_drag
	else
		-- ([KIT_PHONE_EDITING] the touch mode's drag on nothing pans but
		-- under Select+, where a tap keeps the selection)
		local let = next(S.sel) and not more() and "let go of the selection"
		local box = (not (S.touch or NT.sh.on()) or more()) and
				"drag: select by a box"
		g.left = let and box and let .. "; " .. box or let or box or nil
		g.right = (next(S.sel) and "let go of the selection; " or "") .. right_drag
	end
	if S.view ~= "walk" then
		g.middle = "drag: pan the view"
	end
	return g
end

local function guide_text(g)
	if not g then
		return ""
	end
	local lines = {}
	local names = S.touch and {{"left", "Tap"}, {"right", "Hold"}} or
			{{"left", "Left"}, {"shift", "Shift+left"}, {"right", "Right"},
			{"middle", "Middle"}}
	for _, b in ipairs(names) do
		local t = g[b[1]]
		if t and S.touch then
			t = t:gsub("; drag: [^;]*", ""):gsub("^drag: [^;]*;? ?", "")
			if t == "" then
				t = nil
			end
		end
		if t then
			lines[#lines + 1] = b[2] .. ": " .. t
		end
	end
	if g.note then
		lines[#lines + 1] = g.note
	end
	return table.concat(lines, "\n")
end

local function draw_guide()
	if not guide_hud then
		guide_hud = magic.ui.root:CreateChild("Text")
		guide_hud:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 15)
		guide_hud:SetAlignment(magic.HA_CENTER, magic.VA_BOTTOM)
		guide_hud:SetTextEffect(magic.TE_SHADOW)
		guide_hud:SetTextAlignment(magic.HA_CENTER)
		guide_hud.priority = 90
	end
	local s = ""
	if E.editing and not NT.world_off() and not (E.menu and E.menu.held()) then
		s = guide_text(compute_guide())
	else
		ghost(nil)
	end
	-- [KIT_PHONE_EDITING] The touch mode's: one line, at the foot of the
	-- world's rect (shell.lua)
	local sh = NT.sh.on() and NT.sh.world
	if sh then
		s = s:match("^[^\n]*")
	end
	if s ~= guide_shown then
		guide_shown = s
		guide_hud:SetText(s)
		if s ~= "" then
			log:info("kit editor: guide: " .. s:gsub("\n", " | "))
		end
	end
	if sh then
		guide_hud:SetAlignment(magic.HA_LEFT, magic.VA_TOP)
		guide_hud:SetVar("FollowsRoot", "1")
		guide_hud:SetPosition(sh[1] + math.floor((sh[3] - guide_hud.width) / 2),
				sh[2] + sh[4] - guide_hud.height - 8)
		return
	end
	guide_hud:SetAlignment(magic.HA_CENTER, magic.VA_BOTTOM)
	guide_hud:SetVar("FollowsRoot", "")
	-- Over the touch bar, and on a narrow screen over the people's panel
	local y = W.touch and W.touch.height + 20 or 12
	if narrow() and W.people then
		y = math.max(y, W.people.height + 58)
	end
	guide_hud:SetPosition(0, -y)
end

-- ---- Drawing: every entity a box, the selection yellow, gizmos, zones,
-- links, the cursor, the knob, the link being dragged, the builders
-- [KIT] stage 4l: the links shown in play, for every player: drawn as in
-- edit mode, lit 0.6 s as a signal passes
local function draw_play_links()
	local dbg = O.debug
	local now = buildat.get_time_us()
	E.play_drawn = E.play_drawn or {}
	for id, n in pairs(P.nodes) do
		local show = type(n.show) == "table" and n.show or {}
		-- [KIT] stage 4j: a region's border, its show_border on (its size
		-- as a resize has it)
		if show.border and type(show.region) == "table" and n.node and
				n.node:GetVar("kit:enabled"):GetString() ~= "false" then
			local sz = network.parse_json(n.node:GetVar("kit:size"):GetString())
			if type(sz) ~= "table" then
				sz = show.region
			end
			local p = n.node.position
			local o = magic.Vector3(math.floor(p.x + 1e-4) - 0.5,
					math.floor(p.y + 1e-4) - 0.5, math.floor(p.z + 1e-4) - 0.5)
			local e = {}
			-- ([KIT_CTF] the server's MAX_REGION_EXTENT)
			for i = 1, 3 do
				e[i] = math.max(1, math.min(384, math.floor(tonumber(sz[i]) or 1)))
			end
			local r = n.node.rotation
			if math.abs(r.x) + math.abs(r.y) + math.abs(r.z) > 1e-6 then
				-- [KIT_FREE_ROTATION] turned with its parent
				NT.pf.draw_box(dbg, p, r, {-0.5, -0.5, -0.5},
						{e[1] - 0.5, e[2] - 0.5, e[3] - 0.5}, magic.Color(1, 0.3, 0.3))
			else
				dbg:AddBoundingBox(magic.BoundingBox(o, magic.Vector3(o.x + e[1],
						o.y + e[2], o.z + e[3])), magic.Color(1, 0.3, 0.3), true)
			end
			local key = "border " .. id
			local was = E.play_drawn[key]
			local now_s = table.concat(e, "x")
			if was ~= now_s then
				E.play_drawn[key] = now_s
				log:info("kit: region " .. id .. " border " .. now_s ..
						" drawn in play")
			end
		end
		for _, to in ipairs(type(show.links) == "table" and show.links or {}) do
			local o = P.nodes[to]
			if o and n.node and o.node then
				local a, b = n.at or n.node.position, o.at or o.node.position
				local key = id .. ">" .. tostring(to)
				local lit = (E.flows[key] or 0) > now
				local col = lit and magic.Color(1, 1, 0.3) or
						magic.Color(0.2, 1, 0.4)
				dbg:AddLine(a, b, col, false)
				dbg:AddCross(magic.Vector3(a.x + (b.x - a.x) * 0.85,
						a.y + (b.y - a.y) * 0.85, a.z + (b.z - a.z) * 0.85),
						lit and 0.6 or 0.3, col, false)
				local was = E.play_drawn[key]
				if was ~= (lit and "lit" or "drawn") then
					E.play_drawn[key] = lit and "lit" or "drawn"
					log:info("kit: link " .. key .. " " .. E.play_drawn[key] ..
							" in play")
				end
			end
		end
	end
end

local function draw()
	if not E.editing and S.view == "hud" then
		set_view(S.before_hud)
	end
	if E.editing and S.view == "hud" then
		show_ports("out", nil)
		show_ports("in", nil)
		draw_guide()
		NT.hud_panel()
		return
	end
	if not E.editing then
		show_ports("out", nil)
		show_ports("in", nil)
		draw_play_links()
		return
	end
	-- [KIT_BAR_SERVER_OVERLAP] Wrapped again at a new screen width (the
	-- root's at the client's fit x1; see rebuild_bar)
	if W.bar and S.bar_root_w ~= NT.fit1_w() then
		rebuild_bar()
	end
	-- (after the text size's scaling, which scaled the cap people() set)
	if W.people and NT.cap_w(20) then
		W.people.maxWidth = NT.cap_w(20)
	end
	NT.fit_panel()
	fit_inspector()
	log_bar()
	local dbg = O.debug
	local now = buildat.get_time_us()
	-- A Try's answer shown long enough
	if E.tried and now >= E.tried.till then
		E.tried = nil
		inspector_window()
	end
	local YELLOW = magic.Color(1, 0.9, 0.2)
	-- [KIT_PREFAB_VOXELS] the Box tool's box (its first corner alone
	-- until the second)
	local vb = S.vbox
	if vb and vb.a then
		local a, b = vb.a, vb.b or vb.a
		dbg:AddBoundingBox(magic.BoundingBox(
				magic.Vector3(math.min(a[1], b[1]) - 0.5,
					math.min(a[2], b[2]) - 0.5, math.min(a[3], b[3]) - 0.5),
				magic.Vector3(math.max(a[1], b[1]) + 0.5,
					math.max(a[2], b[2]) + 0.5, math.max(a[3], b[3]) + 0.5)),
				magic.Color(0.3, 1, 0.5), false)
		-- [KIT_BOX_ADJUST] its handles, the axes' colours, the one under
		-- the pointer or dragged yellow
		local under = S.box_drag and S.box_drag.h or
				BX.box_handle_at(S.mx or 0, S.my or 0)
		local AXIS_COLOURS = {magic.Color(1, 0.35, 0.3),
			magic.Color(0.4, 1, 0.4), magic.Color(0.35, 0.6, 1)}
		for _, h in ipairs(BX.box_handles()) do
			local r = 0.2
			dbg:AddBoundingBox(magic.BoundingBox(
					h.at - magic.Vector3(r, r, r), h.at + magic.Vector3(r, r, r)),
					(under and under.name == h.name) and YELLOW or
					AXIS_COLOURS[h.k], false)
		end
	end
	NT.pf.draw(dbg)
	NT.sym_draw(dbg)
	-- The round's own entities, orange (players are drawn by the app)
	for _, e in ipairs(made()) do
		if e.pos and e.kind ~= "player" then
			local c = drawn_at(e)
			dbg:AddBoundingBox(magic.BoundingBox(
					magic.Vector3(c.x - 0.35, c.y - 0.35, c.z - 0.35),
					magic.Vector3(c.x + 0.35, c.y + 0.35, c.z + 0.35)),
					S.sel[e.id] and YELLOW or magic.Color(1, 0.55, 0.1), false)
		end
	end
	for _, e in ipairs(entities()) do
		if e.pos then
			local m = drawn_at(e)
			local x, y, z = m.x, m.y, m.z
			dbg:AddBoundingBox(magic.BoundingBox(
					magic.Vector3(x - 0.4, y - 0.4, z - 0.4),
					magic.Vector3(x + 0.4, y + 0.4, z + 0.4)),
					S.sel[e.id] and YELLOW or magic.Color(0.8, 0.8, 0.8), false)
			if S.sel[e.id] and P.nodes[e.id] and P.nodes[e.id].box then
				-- Its look's outline too
				local c, half, rot = K.look_frame(P.nodes[e.id])
				if c then
					hover.box(c, half, rot, YELLOW)
				end
			end
			for _, c in ipairs(e.components or {}) do
				local g = type_of(c.type).gizmo
				if type(g) == "table" then
					local col = color(g.color, magic.Color(0.3, 0.9, 1))
					local s = tonumber(g.size) or 0.5
					if g.shape == "box" then
						dbg:AddBoundingBox(magic.BoundingBox(
								magic.Vector3(x - s, y - s, z - s),
								magic.Vector3(x + s, y + s, z + s)), col, false)
					else
						dbg:AddSphere(magic.Sphere(m, s), col, false)
					end
				end
				-- [KIT_GOALS] A chain's final goal, on the map: gold, its box and a
				-- post above it
				if c.type == "kit/goal" and NT.goal_check().final[e.id] then
					local gold = magic.Color(1, 0.75, 0.1)
					local ex = type(c.params) == "table" and c.params.size or {}
					local sx = math.max(1, tonumber(ex[1]) or 1)
					local sy = math.max(1, tonumber(ex[2]) or 1)
					local sz = math.max(1, tonumber(ex[3]) or 1)
					dbg:AddBoundingBox(magic.BoundingBox(
							magic.Vector3(x - 0.7, y - 0.7, z - 0.7),
							magic.Vector3(x + sx - 0.3, y + sy - 0.3, z + sz - 0.3)),
							gold, false)
					dbg:AddLine(m, magic.Vector3(x, y + sy + 3, z), gold, false)
					dbg:AddCross(magic.Vector3(x, y + sy + 3, z), 1.5, gold, false)
				end
				-- A zone's and an owned volume's extent, from its cell on
				local t = type_of(c.type)
				for _, k in ipairs({"zone", "volume", "grants", "voxel_box",
						"region", "world_region"}) do
					local n = t[k] and c.params and c.params[t[k]]
					if type(n) == "table" then
						local ext = {}
						for i = 1, 3 do
							ext[i] = math.max(1, math.floor(tonumber(n[i]) or 1))
						end
						local bc = k == "zone" and
								magic.Color(0.3, 0.75, 1) or k == "voxel_box" and
								magic.Color(0.63, 0.38, 0.88) or k == "region" and
								magic.Color(1, 0.3, 0.3) or k == "world_region" and
								magic.Color(0.3, 0.75, 0.3) or magic.Color(1, 0.6, 0.2)
						local tq = NT.drawn_turn(e)
						-- [KIT_FREE_ROTATION] a zone and a region turn with it; the
						-- others are the world's voxels
						if (k == "zone" or k == "region") and math.abs(tq.x) +
								math.abs(tq.y) + math.abs(tq.z) > 1e-6 then
							NT.pf.draw_box(dbg, m, tq, {-0.5, -0.5, -0.5},
									{ext[1] - 0.5, ext[2] - 0.5, ext[3] - 0.5}, bc)
						else
							dbg:AddBoundingBox(magic.BoundingBox(
									magic.Vector3(x - 0.5, y - 0.5, z - 0.5),
									magic.Vector3(x + ext[1] - 0.5, y + ext[2] - 0.5,
									z + ext[3] - 0.5)), bc, false)
						end
					end
				end
				for _, l in ipairs(c.links or {}) do
					local to = find(l.to)
					if to and to.pos then
						local a, b = m, drawn_at(to)
						-- Lit while a signal passes ([KIT] stage 4d)
						local lit = (E.flows[e.id .. ">" .. l.to] or 0) > now
						local col = lit and magic.Color(1, 1, 0.3) or
								magic.Color(0.2, 1, 0.4)
						dbg:AddLine(a, b, col, false)
						dbg:AddCross(magic.Vector3(a.x + (b.x - a.x) * 0.85,
								a.y + (b.y - a.y) * 0.85, a.z + (b.z - a.z) * 0.85),
								lit and 0.6 or 0.3, col, false)
					end
				end
			end
		end
	end
	-- [KIT_SIGNALS_VIEW] The boxes and links for its viewport; no tools
	if S.view == "signals" then
		show_ports("out", nil)
		show_ports("in", nil)
		return
	end
	if E.cursor then
		dbg:AddCross(magic.Vector3(E.cursor[1], E.cursor[2] - 0.5,
				E.cursor[3]), 0.8, magic.Color(1, 0.4, 1), false)
	end
	-- The knob, and the turn being dragged
	local list, kc = knobs()
	for _, k in ipairs(list or {}) do
		dbg:AddCircle(kc, k.axis, k.r, k.col, 32, false)
		dbg:AddLine(kc, k.at, k.col, false)
		dbg:AddSphere(magic.Sphere(k.at, 0.12), k.col, false)
	end
	-- The ports: the selected one's outputs (none in a drag of another kind)
	local e = S.primary and find(S.primary)
	local _, is_made = nil, false
	if e then
		_, is_made = find(S.primary)
	end
	local d = S.drag
	-- ([KIT_PHONE_EDITING] stage 3: none in the touch mode: beside a
	-- finger-sized entity they took its taps; the inspector's Link <output>)
	if e and not is_made and (not d or d.kind == "link") and not M.looking() and
			not NT.sh.on() then
		show_ports("out", e.id, outputs_of(e))
	else
		show_ports("out", nil)
	end
	if not d or d.kind ~= "link" then
		show_ports("in", nil)
	else
		local from = find(d.from)
		local o, v = M.screen_ray(S.mx, S.my)
		local p = pick(S.mx, S.my, {[d.from] = true})
		local to = o + v * (p and p.t or 6)
		if from and from.pos then
			dbg:AddLine(drawn_at(from), to, M.HOVER, false)
		end
	end
	draw_box_rect()
	draw_edited(dbg, S.mx, S.my)
	if not (E.menu and E.menu.held()) then
		local mx, my = S.mx, S.my
		if M.looking() then
			local w, h, ox, oy = screen_size()
			mx, my = ox + w / 2, oy + h / 2
		end
		draw_brush(dbg, mx, my)
	end
end

-- The other builders' names over what they have selected
local function label_of(name, col)
	local l = E.labels[name]
	if not l then
		l = O.scene:CreateChild("kit_builder_label")
		local t = l:CreateComponent("Text3D")
		t:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 14)
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		t.faceCameraMode = magic.FC_ROTATE_XYZ
		t.fixedScreenSize = true
		t.textEffect = magic.TE_STROKE
		t.effectColor = magic.Color(0, 0, 0, 0.8)
		E.labels[name] = l
	end
	if E.label_text[name] ~= name then
		local t = l:GetComponent("Text3D")
		t:SetColor(col)
		t.text = name
		E.label_text[name] = name
	end
	return l
end

local function draw_builders(dbg)
	local shown = {}
	for _, b in ipairs(E.editing and E.builders or {}) do
		if not b.you then
			local c = color(b.color, magic.Color(1, 1, 1))
			local e = (tonumber(b.sel) or 0) > 0 and find(b.sel)
			if e and e.pos then
				local x, y, z = e.pos[1], e.pos[2], e.pos[3]
				dbg:AddBoundingBox(magic.BoundingBox(
						magic.Vector3(x - 0.5, y - 0.5, z - 0.5),
						magic.Vector3(x + 0.5, y + 0.5, z + 0.5)), c, false)
				local l = label_of(tostring(b.name), c)
				l.position = magic.Vector3(x, y + 0.9, z)
				shown[tostring(b.name)] = true
			end
			if type(b.cursor) == "table" then
				dbg:AddCross(magic.Vector3(b.cursor[1], b.cursor[2] - 0.5,
						b.cursor[3]), 0.8, c, false)
			end
		end
	end
	for name, l in pairs(E.labels) do
		if not shown[name] and E.label_text[name] ~= "" then
			l:GetComponent("Text3D").text = ""
			E.label_text[name] = ""
		end
	end
end

-- ---- The editor turned on
function M.editor(options)
	for k, v in pairs(options) do
		O[k] = v
	end
	O.ground_y = O.ground_y or 0
	-- The scene's own one where it has it (the replicated scene does): the
	-- view draws the first
	O.debug = O.scene:GetComponent("DebugRenderer") or
			O.scene:CreateComponent("DebugRenderer")
	cam3d_node, cam3d = make_cameras()
	rebuild_bar()
	-- [KIT_EDITOR_PANELS] Kit's section of the game's settings window: a
	-- builder's "Always keep builds" (the server's, for everyone's rounds)
	buildat.add_game_settings_section("kit", {title = "Kit",
			draw = function(_, ui)
		NT.settings_redraw = ui.redraw
		if E.can_edit and not E.persistent then
			ui.button("Always keep builds: " .. (E.always_keep and "yes" or
					"no"), function()
				send({op = "always_keep", on = not E.always_keep})
			end)
			ui.text("Players' builds kept at End without asking (a builder's)",
					"dim")
		else
			ui.text("Nothing to set here: Kit's settings are a builder's, " ..
					"in a world of rounds", "dim")
		end
	end})

	buildat.sub_packet("kit:edit_state", function(data)
		local s = network.parse_json(data)
		if type(s) ~= "table" then
			return
		end
		-- [KIT_EDIT_MODE_FPS] The keys the same as last time come by name: the
		-- last state's values kept. None at all yet (Kit loaded again): all of
		-- it asked for. (A key in "same" the last state lacks was null.)
		local same = type(s.same) == "table" and s.same or {}
		s.same = nil
		if #same > 0 and not NT.raw_state then
			log:info("kit editor: the whole state asked for")
			send({op = "state"})
			return
		end
		local kept = {}
		for _, k in ipairs(same) do
			kept[k] = true
			s[k] = NT.raw_state[k]
		end
		NT.raw_state = s
		NT.state_changed = {}
		for k in pairs(s) do
			if not kept[k] then
				NT.state_changed[k] = true
			end
		end
		local was = E.editing
		E.editing = s.editing == true
		if E.can_edit ~= (s.can_edit == true) then
			E.can_edit = s.can_edit == true
			log:info("kit editor: edit rights: " .. (E.can_edit and "yes" or "no"))
			if E.can_edit and not E.editing and MEM.edit ~= "want" then
				ui_utils.show_notification("You may edit here: Edit, or " ..
						M.key_name("edit"), 4)
			end
		end
		-- Done: the hint would lie over the inspector's first row
		if E.editing and not was then
			ui_utils.close_notification()
		end
		for _, p in ipairs(s.people or {}) do
			log:info("kit editor: people: " .. tostring(p.name) ..
					(p.admin and " admin" or p.builder and " builder" or " player"))
		end
		if E.editing and #(s.voxels or {}) ~= #((E.state or {}).voxels or {}) then
			log:info("kit editor: " .. #(s.voxels or {}) .. " voxels to place")
		end
		-- [AITTA_KEY_IDENTITY] A package's name as people read it, said
		-- when it changes (its Aitta's vouch, a second "alice")
		local old_names = (E.state or {}).names or {}
		for id, label in pairs(E.editing and type(s.names) == "table" and
				s.packages or {}) do
			local l = s.names[id]
			if l and l ~= old_names[id] then
				log:info("kit editor: installed " .. tostring(l) .. " as " .. id)
			end
		end
		-- Entities new since the last state (placed, duplicated): Tab's
		-- order's top
		if E.editing then
			local known = {}
			for _, e in ipairs(s.authored and s.authored.entities or {}) do
				known[e.id] = true
				if S.known and not S.known[e.id] then
					touch(e.id)
					-- (the first: a prefab's root, its parts after it)
					if NT.select_new == true then
						NT.select_new = e.id
					end
				end
			end
			S.known = known
		end
		E.state = E.editing and s or nil
		-- [KIT_SCENES] the scene edited, and the composition's
		if E.state and (E.state.scene ~= E.scene_logged or
				#(E.state.scenes or {}) ~= E.scenes_logged) then
			E.scene_logged = E.state.scene
			E.scenes_logged = #(E.state.scenes or {})
			log:info("kit editor: in the scene " .. tostring(E.state.scene) ..
					" of " .. table.concat(E.state.scenes or {}, ", "))
		end
		if was ~= E.editing then
			log:info("kit editor: edit mode " .. (E.editing and "on" or "off"))
			E.link, E.status = nil, ""
			S.drag, S.press, S.placing, S.crosshair = nil, nil, nil, false
			S.reparent = nil
			T.down, T.fill = false, nil
			drop("ctx")
			drop("dialog")
			if not E.editing then
				E.builders = {}
			end
			apply_viewport()
		end
		E.credits = type(s.credits) == "table" and s.credits or {}
		E.discarded = type(s.discarded) == "table" and s.discarded or {}
		local keep_was = E.always_keep
		E.always_keep = s.always_keep == true
		E.persistent = s.persistent == true
		if keep_was ~= E.always_keep then
			log:info("kit editor: always keep builds: " ..
					(E.always_keep and "yes" or "no"))
			-- (the window gone, its redraw fails harmlessly)
			pcall(NT.settings_redraw or function() end)
		end
		if not next(E.discarded) then
			E.choose = false
		end
		if E.running ~= (s.running == true) or E.by ~= tostring(s.by or "") then
			E.running, E.by = s.running == true, tostring(s.by or "")
			log:info("kit editor: the server is " .. (E.running and "Running" or
					"Ended") .. " (by " .. E.by .. ")" ..
					(E.persistent and ", persistent" or ""))
		end
		-- [KIT_TERRAIN_PLAY_RULES] who builds outside every region
		E.terrain_rules = type(s.terrain_rules) == "table" and
				s.terrain_rules or {}
		-- [KIT_SESSIONS_1] the session they are in: a draft's bar has
		-- Publish and Leave draft, a session's no Run/End
		E.session = type(s.session) == "table" and s.session or {}
		local sk = tostring(E.session.id or 0) .. " " ..
				tostring(E.session.kind or "default")
		if E.session_logged ~= sk then
			E.session_logged = sk
			log:info("kit editor: in session " .. sk)
			rebuild_bar()
		end
		if E.editing then
			local n = #entities()
			log:info("kit editor: state: " .. n .. " entities, " ..
					tostring(s.undo) .. " to undo")
			NT.goal_check()
			for _, e in ipairs(entities()) do
				local links = {}
				for _, c in ipairs(e.components or {}) do
					for _, l in ipairs(c.links or {}) do
						links[#links + 1] = l.output .. "->" .. l.to .. "." ..
								l.input
					end
				end
				local pe = NT.parent_of(e)
				log:verbose("kit editor: entity " .. e.id .. " " ..
						tostring(e.name) .. (e.pos and " at " ..
						table.concat(e.pos, ",") or "") .. ((e.yaw or 0) ~= 0 and
						" yaw " .. e.yaw or "") .. ((e.pitch or 0) ~= 0 and
						" pitch " .. e.pitch or "") .. ((e.roll or 0) ~= 0 and
						" roll " .. e.roll or "") .. (pe and " under " .. pe.id or
						"") .. " links " .. table.concat(links, " "))
			end
			for id in pairs(S.sel) do
				if not find(id) then
					S.sel[id] = nil
				end
			end
			if S.primary and not find(S.primary) then
				S.primary = next(S.sel)
			end
			if S.reparent and not find(S.reparent) then
				S.reparent = nil
			end
			if type(NT.select_new) == "number" then
				local id = NT.select_new
				NT.select_new, NT.sg.reveal = nil, id
				select(id)
				NT.show_inspector()
				NT.reveal(id)
			end
			NT.pf.state()
		end
		refresh("state")
		changed()
		if E.editing and S.tool == "terrain" then
			send({op = "edited"})
		end
		E.state_seen = true
		MEM.restore(was)
	end)
	-- [KIT_TRY_INPUTS] A Try's answer: what the entity emitted ("→ opened"),
	-- in the inspector for 3 s
	buildat.sub_packet("kit:tried", function(data)
		local a = network.parse_json(data)
		if type(a) ~= "table" then
			return
		end
		local outs = {}
		for _, o in ipairs(type(a.emitted) == "table" and a.emitted or {}) do
			local v = type(o) == "table" and o[2]
			outs[#outs + 1] = tostring(type(o) == "table" and o[1]) ..
					(v ~= nil and type(v) ~= "table" and " " .. tostring(v) or "")
		end
		local t = "→ " .. (#outs > 0 and table.concat(outs, ", ") or
				"nothing emitted")
		E.tried = {id = tonumber(a.id), text = t,
			till = buildat.get_time_us() + 3000000}
		log:info("kit editor: tried " .. tostring(a.id) .. "'s " ..
				tostring(a.input) .. ": " .. t)
		inspector_window()
	end)
	-- [KIT_SIGNALS_LIVE] What the watched entity's outputs emitted
	buildat.sub_packet("kit:fired", function(data)
		NT.sg.fired(network.parse_json(data))
	end)
	-- [KIT_VOXEL_EDITS] The edited sections, the terrain panel's list
	buildat.sub_packet("kit:edited", function(data)
		local a = network.parse_json(data)
		if type(a) ~= "table" then
			return
		end
		ED.list = a
		local parts = {}
		local secs = type(a.sections) == "table" and a.sections or {}
		for i = 1, math.min(#secs, 16) do
			parts[i] = table.concat(secs[i].s or {}, ",") .. "=" ..
					tostring(secs[i].cells)
		end
		log:info("kit editor: edited sections: " .. #secs .. " " ..
				table.concat(parts, " "))
		if S.tool == "terrain" then
			palette()
		end
	end)
	buildat.sub_packet("kit:builders", function(data)
		local a = network.parse_json(data)
		E.builders = type(a) == "table" and a or {}
		for _, b in ipairs(E.builders) do
			local name = tostring(b.name)
			local was = E.seen[name] or {}
			local cur = type(b.cursor) == "table" and table.concat(b.cursor, ",") or
					"none"
			if not b.you and (was.sel ~= b.sel or was.cursor ~= cur) then
				log:info("kit editor: builder " .. name .. " (" .. tostring(b.color) ..
						") selects " .. tostring(b.sel) .. ", cursor " .. cur)
			end
			E.seen[name] = {sel = b.sel, cursor = cur}
		end
		people()
	end)
	-- [KIT] stage 4d: signals passing along links light their lines, and
	-- the selected entity's log
	buildat.sub_packet("kit:flow", function(data)
		local a = network.parse_json(data)
		local till = buildat.get_time_us() + 600000
		for _, f in ipairs(type(a) == "table" and a or {}) do
			E.flows[tostring(f[1]) .. ">" .. tostring(f[3])] = till
			log:info("kit editor: signal " .. tostring(f[1]) .. "." ..
					tostring(f[2]) .. " -> " .. tostring(f[3]) .. "." ..
					tostring(f[4]))
		end
	end)
	-- [KIT] stage 4l: the costs, every few seconds while editing
	buildat.sub_packet("kit:costs", function(data)
		local c = network.parse_json(data)
		if type(c) ~= "table" then
			return
		end
		E.costs = c
		if S.cost_text and S.cost_id then
			local line = M.cost_line(S.cost_id)
			S.cost_text.text = line
			-- [KIT_COST_LOG_FLAKY] Told once a line, also when the inspector
			-- showed it already (the costs in before the selection)
			local said = S.cost_said
			if not said or said.id ~= S.cost_id or said.line ~= line then
				S.cost_said = {id = S.cost_id, line = line}
				log:info("kit editor: entity " .. S.cost_id .. ": " .. line)
			end
		end
	end)
	buildat.sub_packet("kit:log", function(data)
		local l = network.parse_json(data)
		if type(l) ~= "table" or type(l.lines) ~= "table" then
			return
		end
		E.logs[tonumber(l.id) or 0] = l.lines
		log:info("kit editor: log of " .. tostring(l.id) .. ": " ..
				tostring(l.lines[#l.lines]))
		show_log()
	end)
	-- [KIT] stage 4f: a terrain dab's answer
	buildat.sub_packet("kit:terrain", function(data)
		local a = network.parse_json(data)
		if type(a) == "table" then
			log:info("kit editor: terrain: " .. tostring(a.what) .. " (" ..
					tostring(a.undo) .. " to undo)")
		end
	end)
	-- [KIT] stage 4g: an upload's name, the dialog's texture
	buildat.sub_packet("kit:texture", function(data)
		E.voxel_form.texture = data
		log:info("kit editor: uploaded " .. data)
		if W.dialog then
			M.voxel_dialog()
		end
	end)
	-- [KIT] stage 5: an install's answer, and the export to publish
	buildat.sub_packet("kit:package", function(data)
		local a = network.parse_json(data)
		if type(a) ~= "table" then
			return
		end
		E.status = a.ok and "Package: " .. tostring(a.what) or
				"Package refused: " .. tostring(a.why)
		log:info("kit editor: " .. E.status)
		if E.editing then
			people()
		else
			ui_utils.show_notification(E.status, 4)
		end
	end)
	buildat.sub_packet("kit:export", function(data)
		local a = network.parse_json(data)
		if type(a) ~= "table" then
			return
		end
		log:info("kit editor: the export of " .. tostring(a.author))
		aitta.kit_publish({name = E.package_name, author = a.author,
			files = a.files, hex = a.hex, dependencies = a.dependencies})
	end)
	buildat.sub_packet("kit:edit_refused", function(data)
		log:info("kit editor: refused: " .. tostring(data))
		-- [KIT_WATCH_REFUSED_PLAY] The Signals view's live values, asked
		-- in a race with leaving edit mode: nothing the builder did
		if tostring(data):sub(1, 7) == "watch: " then
			return
		end
		E.status = "Refused: " .. tostring(data)
		NT.select_new = nil
		NT.pf.refused()
		clear_preview()
		if E.editing then
			people()
		else
			ui_utils.show_notification(E.status, 4)
		end
	end)
	magic.SubscribeToEvent("KeyDown", function(_, data)
		local key = data:GetInt("Key")
		-- [KIT_DROPDOWN_ARROWS_MOVE] an open dropdown's popup has the keys:
		-- its arrows and PageUp/PageDown moved the selection too, and none
		-- of the editor's keys are meant while it is open (Escape or a
		-- click closes it)
		-- ([KIT_SIGNALS_VIEW] the view keys there: the filter keeps the focus)
		if (typing() and not NT.sg.view_key(key, VIEW_KEYS)) or
				ui_utils.dropdown_open() then
			return
		end
		if M.key("edit", key) then
			return M.toggle_tools()
		end
		if E.editing and not (E.menu and E.menu.held()) then
			local q = data:GetInt("Qualifiers")
			key_down(key, q == magic.QUAL_CTRL, q == magic.QUAL_SHIFT)
		end
	end)
	magic.SubscribeToEvent("MouseButtonDown", function(_, data)
		local m = magic.input:GetMousePosition()
		if not M.looking() then
			S.mx, S.my = m.x, m.y
		end
		if S.view == "hud" and E.editing then
			if data:GetInt("Button") == magic.MOUSEB_LEFT and not S.touch then
				NT.hud_press(m.x, m.y)
				-- (out of the view by it: its release is not the view's)
				S.swallow_up = S.view ~= "hud" and magic.MOUSEB_LEFT or nil
			end
			return
		end
		if NT.world_off() then
			return
		end
		mouse_down(data:GetInt("Button"))
	end)
	magic.SubscribeToEvent("MouseButtonUp", function(_, data)
		if NT.world_off() then
			return
		end
		mouse_up(data:GetInt("Button"))
	end)
	magic.SubscribeToEvent("MouseMove", function(_, data)
		if not E.editing or S.touch or NT.world_off() then
			return
		end
		mouse_move(data:GetInt("X"), data:GetInt("Y"), data:GetInt("DX"),
				data:GetInt("DY"))
	end)
	magic.SubscribeToEvent("MouseWheel", function(_, data)
		if S.touch or NT.world_off() then
			return
		end
		mouse_wheel(data:GetInt("Wheel"), data:GetInt("Qualifiers"))
	end)
	magic.SubscribeToEvent("TouchBegin", function(_, data)
		if S.touch and S.view == "hud" and E.editing then
			NT.hud_press(data:GetInt("X"), data:GetInt("Y"))
		elseif S.touch and not NT.world_off() then
			touch_begin(data:GetInt("TouchID"), data:GetInt("X"), data:GetInt("Y"))
		end
	end)
	magic.SubscribeToEvent("TouchMove", function(_, data)
		if S.touch and not NT.world_off() then
			touch_move(data:GetInt("TouchID"), data:GetInt("X"), data:GetInt("Y"),
					data:GetInt("DX"), data:GetInt("DY"))
		end
	end)
	magic.SubscribeToEvent("TouchEnd", function(_, data)
		if S.touch and not NT.world_off() then
			touch_end(data:GetInt("TouchID"), data:GetInt("X"), data:GetInt("Y"))
		end
	end)
	magic.SubscribeToEvent("ExitRequested", function()
		MEM.tick(0, true)
	end)
	-- [KIT_EDITOR_FONT] The editor's panels at the editor's text size
	-- (S.font; the play HUD as it is): each frame, which scales only what
	-- is new
	magic.SubscribeToEvent("Update", function(_, data)
		local dt = data:GetFloat("TimeStep")
		MEM.tick(dt)
		if S.uploading then
			local name, png = buildat.picked_file()
			if name then
				S.uploading = false
				log:info("kit editor: uploading " .. name)
				buildat.send_packet("kit:texture", png)
			elseif png then
				S.uploading = false
				E.status = tostring(png)
				people()
			end
		end
		if E.editing then
			move_camera(dt)
			place_cameras()
			NT.sg.tick()
			long_press_tick()
			if T.down then
				stroke_move(S.mx, S.my)
			end
		end
		do
			local w, h = screen_size()
			caps.update(E.editing and S.view == "2d", w / math.max(1, h))
		end
		hover.begin()
		-- The frames' bars: vanilla's, and in the plan about 3 pixels
		local _, sh = screen_size()
		hover.w = E.editing and S.view == "2d" and 3 * S.span / math.max(1, sh) or
				nil
		draw()
		draw_guide()
		hover.finish()
		draw_builders(O.debug)
		if magic.ui_text_scale then
			for _, w in pairs(W) do
				magic.ui_text_scale(w, S.font)
			end
			-- [KIT_SIGNALS_FONT_FIT] For a check: the Signals view's columns as
			-- the scaler left them
			if NT.sig() then
				local said = {}
				for _, k in ipairs({"sg_list", "sg_links", "sg_view", "inspector"}) do
					local w = W[k]
					if w and w.visible then
						said[#said + 1] = string.format("%s %d %d %d %d", k,
								w.position.x, w.position.y, w.width, w.height)
					end
				end
				local line = "kit editor: signals: columns scaled: " ..
						table.concat(said, ", ")
				if line ~= NT.sg_scaled_said then
					NT.sg_scaled_said = line
					log:info(line)
				end
			end
		end
		-- [KIT_PHONE_EDITING] The touch mode's layout after the scaling
		NT.sh.tick()
	end)
end
return terrain_panel
end
-- vim: set noet ts=4 sw=4:
