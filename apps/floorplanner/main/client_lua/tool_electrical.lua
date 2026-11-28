-- Buildat: apps/floorplanner/main/client_lua/tool_electrical.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [FP_ELECTRICAL] The Electrical view and its tools, over the editor's E
-- ([FP_EDITOR_MODULES]): the view (J) dims the building in the plan view
-- and draws the boxes, the board and the runs in IEC 60617 style
-- symbols, each named when pointed at; the tools place the board, place
-- boxes, draw runs and link what a switch controls; the properties panel
-- edits a box or a run and shows what electrical.lua derives for it; the
-- Circuits window lists and edits the circuits.
-- simplified: the plan view only; 3D shows none of it
return function(E)
local S, M, geom, magic, panel = E.S, E.M, E.geom, E.magic, E.panel
local send, refresh_panels, pick_surface, cursor_floor = E.send, E.refresh_panels,
		E.pick_surface, E.cursor_floor
local snap_radius, grid_step, mm_per_px, world_label = E.snap_radius, E.grid_step,
		E.mm_per_px, E.world_label
local settings, scene, flat_material, log, W = E.settings, E.scene, E.flat_material,
		E.log, E.W
local ok, err, el = buildat.run_script_file("main/electrical.lua")
if not ok or type(el) ~= "table" then
	error("floorplanner: could not load electrical.lua: " .. tostring(err))
end
E.electrical = el
local R = el.ROLE

S.electrical = false
-- What the Box tool puts in, the route the Run tool draws, the circuit it
-- draws for, the run being drawn, the switch and gang being linked
S.elec = {role = R.outlet, surface = 0, outlet = 0, count = 1, gangs = 1,
	route = 2, circuit = nil, draw = nil, link = nil, gang = 1}
local ELEC_TOOLS = {"eboard", "ebox", "erun", "elink"}
local IS_ELEC_TOOL = {eboard = true, ebox = true, erun = true, elink = true}

local function doc()
	return E.doc
end

-- What the document says, derived again after each change to it
local gen, hooked, derived, derived_gen = 0, nil, nil, -1
function E.elec_derived()
	local d = doc()
	if hooked ~= d then
		hooked = d
		table.insert(d.listeners, 1, function() gen = gen + 1 end)
		gen = gen + 1
	end
	if derived_gen ~= gen then
		derived, derived_gen = el.derive(d.ents, geom), gen
	end
	return derived
end

local function boards()
	local out = {}
	for _, b in ipairs(doc().of_type("ebox")) do
		if b.ints.role == R.board then
			out[#out + 1] = b
		end
	end
	return out
end

local function circuits()
	local out = doc().of_type("circuit")
	table.sort(out, function(a, b)
		if a.ints.number ~= b.ints.number then
			return a.ints.number < b.ints.number
		end
		return a.id < b.id
	end)
	return out
end

local function current_circuit()
	local c = S.elec.circuit and doc().ents[S.elec.circuit]
	if c and c.type == "circuit" then
		return c
	end
	c = circuits()[1]
	S.elec.circuit = c and c.id
	return c
end

local function circuit_text(c)
	return c.ints.number .. ": " .. (c.strs.name ~= "" and c.strs.name or
			(c.ints.kind == 1 and "data" or "power")) .. " (" ..
			(c.ints.kind == 1 and "" or c.ints.fuse .. " A, ") ..
			el.SECTIONS[c.ints.section] .. ")"
end

-- A box's name as the tooltip and the panel say it: the standard name of
-- its symbol, what it holds, its own name
function E.elec_name(id)
	local d = doc()
	local e = d.ents[id]
	if not e then
		return "?"
	end
	if e.type == "erun" then
		local c = d.ents[e.ints.circuit]
		return "run " .. id .. " of circuit " .. (c and c.ints.number or "?") ..
				", " .. el.box_name(d.ents, e.ints.a) .. " - " ..
				el.box_name(d.ents, e.ints.b)
	elseif e.type ~= "ebox" then
		return e.type .. " " .. id
	end
	local i = e.ints
	local t
	if i.role == R.outlet then
		t = (i.outlet == 1 and "data outlet (RJ45)" or "earthed outlet (Schuko)") ..
				(i.count > 1 and " x" .. i.count or "")
	elseif i.role == R.switch then
		local b = E.elec_derived().boxes[id]
		t = "switch box, " .. (b and b.inserts or "")
	elseif i.role == R.ceiling then
		t = "lamp at a ceiling box"
	elseif i.role == R.board then
		t = "board, main fuse " .. i.fuse .. " A"
	elseif i.role == R.equipment then
		t = "equipment connection"
	elseif i.role == R.device then
		t = "device box"
	else
		t = "junction box"
	end
	return t .. (e.strs.name ~= "" and " '" .. e.strs.name .. "'" or "") ..
			(i.surface == 1 and ", surface" or ", flush")
end

-- The current layout's boxes, where the plan shows them: their symbol's
-- frame, u along the wall and v into the room (a ceiling box: the plan's)
local function boxes_here()
	local d, out = doc(), {}
	for _, b in ipairs(d.of_type("ebox")) do
		local i = b.ints
		if i.layout == S.layout then
			local x, z = el.box_xz(d.ents, b, geom)
			local ux, uz, vx, vz = 1, 0, 0, 1
			local f = i.wall ~= 0 and el.wall_line(d.ents, i.wall, geom)
			if f then
				ux, uz, vx, vz = f.ux, f.uz, -f.uz, f.ux
				if i.side == 1 then
					vx, vz = -vx, -vz
				end
			end
			out[#out + 1] = {id = b.id, e = b, x = x, z = z, ux = ux, uz = uz,
					vx = vx, vz = vz, wall = f and true}
		end
	end
	return out
end

-- A symbol's unit in mm, the same on every zoom in pixels
local function sym_unit()
	return 16 * mm_per_px() -- (8 px was too small to read: the user)
end

local function box_at(x, z)
	if not x then
		return nil
	end
	-- Anywhere on its symbol: a wall box's reaches about 2 units into
	-- the room, a ceiling box's is round its point (a click on a switch's
	-- lever missed it, the room under it taken: the user)
	local best, bd, s = nil, math.huge, sym_unit()
	local snap = snap_radius() * 1.5
	for _, b in ipairs(boxes_here()) do
		local o = b.wall and s or 0
		local dd = geom.len(b.x + b.vx * o - x, b.z + b.vz * o - z)
		if dd <= math.max(snap, (b.wall and 2 or 1.3) * s) and dd < bd then
			best, bd = b, dd
		end
	end
	return best
end

local function run_at(x, z)
	if not x then
		return nil
	end
	local best, bd = nil, snap_radius()
	for id, r in pairs(E.elec_derived().runs) do
		local pts = r.on[S.layout]
		if pts then
			for i = 2, #pts do
				local p, q = pts[i - 1], pts[i]
				local _, _, _, dd = geom.nearest_on_segment(x, z, p[1], p[2], q[1], q[2])
				if dd <= bd then
					best, bd = id, dd
				end
			end
		end
	end
	return best
end

-- A run's handles: its points (pt, its index), and the middle of each
-- segment (ins, the index a point added there takes)
-- simplified: on the floor it was drawn on only, not a riser's other
local function handles(r)
	local out = {}
	for k = 2, #r.pts - 1 do
		out[#out + 1] = {pt = k - 1, x = r.pts[k][1], z = r.pts[k][2]}
	end
	for j = 1, #r.pts - 1 do
		out[#out + 1] = {ins = j, x = (r.pts[j][1] + r.pts[j + 1][1]) / 2,
				z = (r.pts[j][2] + r.pts[j + 1][2]) / 2}
	end
	return out
end

-- The selected run's handle at x, z
local function handle_at(x, z)
	local id = S.primary
	local r = S.sel[id] == "erun" and E.elec_derived().runs[id]
	if not (x and r and r.on[S.layout] == r.pts) then
		return nil
	end
	local best, bd = nil, snap_radius()
	for _, h in ipairs(handles(r)) do
		local dd = geom.len(h.x - x, h.z - z)
		if dd < bd then
			best, bd = h, dd
		end
	end
	return best and {kind = "erun", id = id, pt = best.pt, ins = best.ins}
end

-- A run's path as a point drag has it
local function drag_pts(dg)
	local out = {}
	for k, p in ipairs(E.elec_derived().runs[dg.run].pts) do
		out[k] = p
	end
	if dg.ins then
		table.insert(out, dg.ins + 1, {dg.x, dg.z})
	else
		out[dg.pt + 1] = {dg.x, dg.z}
	end
	return out
end

-- What a click of Select takes in the Electrical view: the selected run's
-- handle, a box, else a run
function E.elec_target()
	if not S.electrical or S.view ~= "2d" then
		return nil
	end
	local x, z = cursor_floor()
	local h = handle_at(x, z)
	if h then
		return h
	end
	local b = box_at(x, z)
	if b then
		return {kind = "ebox", id = b.id}
	end
	local r = run_at(x, z)
	return r and {kind = "erun", id = r} or nil
end

local function select(kind, id)
	S.sel, S.sel_face, S.primary = {[id] = kind}, {}, id
	refresh_panels()
end

local function height_for(role, layout, x, z)
	local st = settings()
	local h = ({[R.switch] = st.el_h_switch, [R.outlet] = st.el_h_outlet,
		[R.device] = st.el_h_device, [R.equipment] = st.el_h_equipment,
		[R.board] = st.el_h_board})[role]
	return h or el.ceiling_at(doc().ents, layout, x, z, geom) - st.el_h_junction
end

-- Where on a wall the pointer is: the wall, along it, and its face
local function wall_point()
	local s = pick_surface(false, function(k) return k == "wall" end)
	local f = s and s.kind == "wall" and E.wall_frame(s.id)
	if not f then
		return nil
	end
	local along = geom.snap((s.x - f.ax) * f.ux + (s.z - f.az) * f.uz, grid_step())
	along = math.max(0, math.min(f.len, along))
	local side = s.side == "left" and 0 or s.side == "right" and 1
	if not side then
		local cx, cz = cursor_floor()
		side = cx and ((cx - f.ax) * f.nx + (cz - f.az) * f.nz) < 0 and 1 or 0
	end
	return {wall = s.id, along = math.floor(along + 0.5), side = side,
			x = f.ax + f.ux * along, z = f.az + f.uz * along}
end

local function done(what)
	return function(err)
		log:info("fp elec: " .. what .. (err == "" and " done" or ": " .. err))
	end
end

-- **Dragged with Select**: a box along its wall, onto another wall as an
-- opening is, or on the ceiling; a run's point, or a new one from the
-- middle of a segment. editor.lua's drag calls these for its kind "elec".
function E.elec_drag(t)
	local e = doc().ents[t.id]
	if t.kind == "ebox" and e then
		local ints = {}
		for k, v in pairs(e.ints) do
			ints[k] = v
		end
		return {kind = "elec", box = t.id, ints = ints}
	elseif t.kind == "erun" and e and (t.pt or t.ins) then
		return {kind = "elec", run = t.id, pt = t.pt, ins = t.ins}
	end
end

local function snapped_cursor()
	local x, z = cursor_floor()
	if x and not S.ctrl then
		x, z = geom.snap(x, grid_step()), geom.snap(z, grid_step())
	end
	return x and math.floor(x + 0.5), z and math.floor(z + 0.5)
end

function E.elec_drag_update(dg)
	if dg.run then
		dg.x, dg.z = snapped_cursor()
		return
	end
	local i = dg.ints
	-- A switch or outlet box on the ceiling dragged onto a wall goes on it,
	-- at its role's height (the rest stay on the ceiling: a junction box
	-- dragged across a room would be caught by a wall on the way)
	local wp0 = i.wall == 0 and (i.role == R.switch or i.role == R.outlet) and
			wall_point()
	if wp0 then
		i.wall, i.along, i.side = wp0.wall, wp0.along, wp0.side
		i.height = height_for(i.role, i.layout, wp0.x, wp0.z)
		return
	end
	if i.wall == 0 then
		local x, z = snapped_cursor()
		if x then
			i.x, i.z = x, z
		end
		return
	end
	local wp = wall_point()
	if wp and wp.wall ~= i.wall then
		i.wall, i.along, i.side = wp.wall, wp.along, wp.side
		return
	end
	local f = el.wall_line(doc().ents, i.wall, geom)
	local x, z = cursor_floor()
	if f and x then
		local along = geom.snap((x - f.ax) * f.ux + (z - f.az) * f.uz, grid_step())
		i.along = math.floor(math.max(0, math.min(f.len, along)) + 0.5)
	end
end

function E.elec_drag_end(dg)
	local d = doc()
	if dg.box then
		local e, i = d.ents[dg.box], dg.ints
		if e and (i.wall ~= e.ints.wall or i.along ~= e.ints.along or
				i.side ~= e.ints.side or i.x ~= e.ints.x or i.z ~= e.ints.z) then
			send({{op = "set", ent = {id = dg.box, ints = i.wall ~= 0 and
					{wall = i.wall, along = i.along, side = i.side,
						height = i.height} or
					{x = i.x, z = i.z}}}}, done("box moved"))
		end
		return
	end
	if not (d.ents[dg.run] and E.elec_derived().runs[dg.run] and dg.x) then
		return
	end
	-- A point dropped on its neighbour goes; one added there is none
	local pts = drag_pts(dg)
	local k = dg.ins and dg.ins + 1 or dg.pt + 1
	for _, n in ipairs({pts[k - 1], pts[k + 1]}) do
		if geom.len(n[1] - dg.x, n[2] - dg.z) < snap_radius() then
			if dg.ins then
				return
			end
			table.remove(pts, k)
			break
		end
	end
	local l = {}
	for j = 2, #pts - 1 do
		l[#l + 1] = math.floor(pts[j][1] + 0.5)
		l[#l + 1] = math.floor(pts[j][2] + 0.5)
	end
	send({{op = "set", ent = {id = dg.run, lists = {pts = l}}}}, done("run points"))
end

-- A new box: on the wall under the pointer, else on the ceiling there
local function add_box(fields, at_wall_only)
	local wp = wall_point()
	local ints = {}
	for k, v in pairs(fields) do
		ints[k] = v
	end
	if wp then
		ints.wall, ints.along, ints.side = wp.wall, wp.along, wp.side
		ints.height = height_for(ints.role, S.layout, wp.x, wp.z)
	elseif at_wall_only then
		doc().notice("A board goes on a wall: click one")
		return
	elseif fields.role == R.switch or fields.role == R.outlet then
		-- (a click beside the wall put one on the ceiling: the user)
		doc().notice("A " .. (fields.role == R.switch and "switch" or "outlet") ..
				" box goes on a wall: click one")
		return
	else
		local x, z = cursor_floor()
		if not x then
			return
		end
		ints.x = math.floor(geom.snap(x, grid_step()) + 0.5)
		ints.z = math.floor(geom.snap(z, grid_step()) + 0.5)
	end
	ints.layout = S.layout
	return ints
end

E.tools.eboard = {
	label = "Board",
	press = function()
		local b = box_at(cursor_floor())
		if b then
			return select("ebox", b.id)
		end
		local ints = add_box({role = R.board, surface = 1, fuse = 25}, true)
		if not ints then
			return
		end
		-- One main board in the UI: a second click moves it
		local old = boards()[1]
		if old then
			send({{op = "set", ent = {id = old.id, ints = {layout = ints.layout,
					wall = ints.wall, along = ints.along, side = ints.side}}}},
					done("board moved"))
		else
			send({{op = "create", ent = {id = doc().placeholder(), type = "ebox",
					ints = ints, strs = {name = "Main board"}}}}, done("board placed"))
		end
	end,
	guide = function(g, hl)
		local wp = wall_point()
		g.left = wp and ((boards()[1] and "move the board to wall " or
				"put the board on wall ") .. wp.wall .. ", " .. wp.along ..
				" mm along it") or "click a wall to put the board on"
	end,
}

E.tools.ebox = {
	label = "Box",
	press = function()
		local b = box_at(cursor_floor())
		if b then
			return select("ebox", b.id)
		end
		local e = S.elec
		local ints = add_box({role = e.role, surface = e.surface,
				outlet = e.outlet, count = e.count, gangs = e.gangs})
		if ints then
			send({{op = "create", ent = {id = doc().placeholder(), type = "ebox",
					ints = ints}}}, done("box placed"))
		end
	end,
	guide = function(g, hl)
		local b = box_at(cursor_floor())
		if b then
			g.left = "select " .. E.elec_name(b.id)
			return
		end
		local wp = wall_point()
		local what = el.ROLE_NAMES[S.elec.role]:lower() ..
				(S.elec.surface == 1 and ", surface" or ", flush")
		g.left = wp and "put a " .. what .. " on wall " .. wp.wall or
				"put a " .. what .. " on the ceiling here"
	end,
}

E.tools.erun = {
	label = "Run",
	clear = function()
		S.elec.draw = nil
	end,
	escape = function()
		if S.elec.draw then
			S.elec.draw = nil
			return true
		end
	end,
	press = function()
		local x, z = cursor_floor()
		local b = box_at(x, z)
		local dr = S.elec.draw
		if not dr then
			if not b then
				local r = run_at(x, z)
				if r then
					select("erun", r)
				end
				return
			end
			if not current_circuit() then
				doc().notice("No circuit to draw for: add one in Circuits")
				return
			end
			S.elec.draw = {a = b.id, layout = S.layout, pts = {}}
		elseif b and b.id ~= dr.a then
			local pts = {}
			for _, p in ipairs(dr.pts) do
				pts[#pts + 1] = p[1]
				pts[#pts + 1] = p[2]
			end
			send({{op = "create", ent = {id = doc().placeholder(), type = "erun",
					ints = {circuit = current_circuit().id, a = dr.a, b = b.id,
					route = S.elec.route}, lists = {pts = pts}}}}, done("run drawn"))
			S.elec.draw = nil
		elseif not b and x then
			if S.layout ~= dr.layout then
				doc().notice("A riser: click a box on this floor to end it")
				return
			end
			local px = S.ctrl and x or geom.snap(x, grid_step())
			local pz = S.ctrl and z or geom.snap(z, grid_step())
			dr.pts[#dr.pts + 1] = {math.floor(px + 0.5), math.floor(pz + 0.5)}
		end
	end,
	guide = function(g, hl)
		local x, z = cursor_floor()
		local b = box_at(x, z)
		local dr = S.elec.draw
		local c = current_circuit()
		if not dr then
			g.left = b and "start a run of circuit " .. (c and c.ints.number or
					"(none)") .. " at " .. E.elec_name(b.id) or
					"click a box or the board to start a run"
		else
			g.left = b and b.id ~= dr.a and "end the run at " .. E.elec_name(b.id) or
					"a point of the run here"
			g.note = "Esc: give the run up; another floor: a riser"
		end
	end,
}

E.tools.elink = {
	label = "Controls",
	clear = function()
		S.elec.link = nil
	end,
	escape = function()
		if S.elec.link then
			S.elec.link = nil
			refresh_panels()
			return true
		end
	end,
	press = function()
		local b = box_at(cursor_floor())
		if not b then
			return
		end
		local sw = S.elec.link and doc().ents[S.elec.link]
		if b.e.ints.role == R.switch and (not sw or b.id ~= sw.id) then
			S.elec.link = b.id
			S.elec.gang = math.min(S.elec.gang, b.e.ints.gangs)
			return select("ebox", b.id)
		end
		if not sw then
			doc().notice("Click a switch box first")
			return
		end
		if not el.is_load(b.e) then
			doc().notice("A switch controls loads: outlets, devices, " ..
					"ceiling and equipment boxes")
			return
		end
		local field = "controls" .. S.elec.gang
		local l, found = {}, false
		for _, v in ipairs(sw.lists[field]) do
			if v == b.id then
				found = true
			else
				l[#l + 1] = v
			end
		end
		if not found then
			l[#l + 1] = b.id
		end
		send({{op = "set", ent = {id = sw.id, lists = {[field] = l}}}},
				done(found and "unlinked" or "linked"))
	end,
	guide = function(g, hl)
		local b = box_at(cursor_floor())
		local sw = S.elec.link
		if not sw then
			g.left = "click a switch box to link what its gangs control"
		elseif b and el.is_load(b.e) then
			g.left = "link or unlink " .. E.elec_name(b.id) .. " to gang " ..
					S.elec.gang .. " of " .. E.elec_name(sw)
		else
			g.left = "click the loads gang " .. S.elec.gang .. " controls"
		end
		g.note = "Esc: done linking"
	end,
}

-- The toolbar's part: the view's toggle, and while it is on its tools and
-- the Circuits window's toggle
function E.elec_toolbar(add)
	add("Electrical", E.keys.name("electrical"), function() E.elec_toggle() end,
			S.electrical)
	if not S.electrical then
		return
	end
	if doc().can("edit") then
		for _, id in ipairs(ELEC_TOOLS) do
			add(E.tools[id].label, nil, function() E.set_tool(id, true) end,
					S.tool == id)
		end
	end
	add("Circuits", nil, function()
		-- In the Layouts window's place: both are at the top middle
		S.circuits_open = not S.circuits_open
		S.layouts_open = S.layouts_open and not S.circuits_open
		refresh_panels()
	end, S.circuits_open)
end

-- Between plans: off, as the panels are
function E.elec_suspend()
	S.electrical, S.circuits_open, S.elec.draw, S.elec.link = false, false, nil, nil
	E.elec_window()
	E.elec_overlay()
end

function E.elec_toggle()
	S.electrical = not S.electrical
	log:info("Electrical view " .. (S.electrical and "on" or "off"))
	if not S.electrical then
		S.circuits_open = false
		if IS_ELEC_TOOL[S.tool] then
			E.set_tool("select")
		end
	end
	S.dirty = true
	refresh_panels()
end

local function dropdown(parent, label, choices, current, f)
	return panel.dropdown(parent, label, choices, current, f)
end

local ROLE_CHOICES = {}
for i = 0, R.equipment do
	ROLE_CHOICES[#ROLE_CHOICES + 1] = {el.ROLE_NAMES[i], i}
end
local OUTLET_CHOICES = {{"Schuko", 0}, {"RJ45", 1}}

-- Lines of a long text, split at its commas to the panel's width
local function wrapped(props, text, width)
	local line = ""
	for part in (text .. ", "):gmatch("(.-), ") do
		if line ~= "" and #line + #part > (width or 44) then
			panel.label(props, line .. ",")
			line = part
		else
			line = line == "" and part or line .. ", " .. part
		end
	end
	if line ~= "" then
		panel.label(props, line)
	end
end

-- The properties panel's part: a box, a run, or a tool's settings; true
-- when it took the panel
function E.elec_props(props, sel, heading, set, int_field, delete_selected)
	local d = doc()
	local function del()
		panel.button(props, "Delete (" .. E.keys.name("delete") .. ")",
				delete_selected)
	end
	if sel and sel.type == "ebox" then
		local i = sel.ints
		heading(el.ROLE_NAMES[i.role] .. " " .. sel.id)
		panel.label(props, E.elec_name(sel.id))
		panel.field(props, i.role == R.equipment and "Label" or "Name",
				sel.strs.name, function(t)
			set(sel.id, {strs = {name = t}})
		end, 120, true)
		if i.role ~= R.board then
			dropdown(props, "Role", ROLE_CHOICES, i.role, function(v)
				set(sel.id, {ints = {role = v}})
			end)
		else
			int_field(sel.id, "Main fuse A", "fuse", i.fuse)
		end
		panel.check(props, "Surface box (flush needs a cavity)", i.surface == 1,
				function()
			set(sel.id, {ints = {surface = 1 - i.surface}})
		end)
		if i.wall ~= 0 then
			int_field(sel.id, "Along mm", "along", i.along)
			int_field(sel.id, "Height mm", "height", i.height)
			panel.button(props, "Other face of the wall", function()
				set(sel.id, {ints = {side = 1 - i.side}})
			end)
		else
			int_field(sel.id, "X mm", "x", i.x)
			int_field(sel.id, "Z mm", "z", i.z)
			panel.label(props, "On the ceiling, at " ..
					el.box_height(d.ents, sel, geom) .. " mm")
		end
		if i.role == R.outlet then
			dropdown(props, "Outlets", OUTLET_CHOICES, i.outlet, function(v)
				set(sel.id, {ints = {outlet = v}})
			end)
			int_field(sel.id, "Count", "count", i.count)
		elseif i.role == R.switch then
			dropdown(props, "Gangs", {{"one switch", 1}, {"two (two-gang)", 2}},
					i.gangs, function(v)
				-- One gang: the second's links go with it
				send({{op = "set", ent = {id = sel.id, ints = {gangs = v},
						lists = v == 1 and {controls2 = {}} or nil}}})
			end)
			for g = 1, i.gangs do
				local l = sel.lists["controls" .. g]
				local names = {}
				for k, id in ipairs(l) do
					names[k] = el.box_name(d.ents, id)
				end
				local kind = E.elec_derived().gangs[sel.id .. ":" .. g]
				panel.label(props, "Gang " .. g .. (kind and ", " .. kind or "") ..
						": " .. (#names > 0 and "" or "controls nothing"))
				if #names > 0 then
					wrapped(props, table.concat(names, ", "))
				end
				panel.button(props, "Link gang " .. g .. ": click its loads",
						function()
					E.set_tool("elink")
					S.elec.link, S.elec.gang = sel.id, g
					select("ebox", sel.id)
				end, S.tool == "elink" and S.elec.link == sel.id and
						S.elec.gang == g)
			end
		end
		-- What controls it
		if el.is_load(sel) then
			for _, gr in ipairs(E.elec_derived().groups) do
				for _, l in ipairs(gr.loads) do
					if l == sel.id then
						panel.label(props, "Switched: group '" .. gr.name .. "'")
					end
				end
			end
		end
		del()
		return true
	elseif sel and sel.type == "erun" then
		local i = sel.ints
		local r = E.elec_derived().runs[sel.id]
		heading("Run " .. sel.id)
		panel.label(props, el.box_name(d.ents, i.a) .. " - " ..
				el.box_name(d.ents, i.b))
		panel.label(props, "Drag a point, or a + to add one;")
		panel.label(props, "a point dropped on the next goes")
		local cs = {}
		for _, c in ipairs(circuits()) do
			cs[#cs + 1] = {circuit_text(c), c.id}
		end
		dropdown(props, "Circuit", cs, i.circuit, function(v)
			set(sel.id, {ints = {circuit = v}})
		end)
		local routes = {}
		for k = 0, 4 do
			routes[#routes + 1] = {el.ROUTES[k], k}
		end
		dropdown(props, "Route", routes, i.route, function(v)
			set(sel.id, {ints = {route = v}})
		end)
		if i.route == 0 or i.route == 3 then
			int_field(sel.id, "Runs at mm (0: the higher box)", "elev", i.elev)
		end
		dropdown(props, "Conduit", {{"the circuit's", 0}, {"in conduit", 1},
				{"no conduit", 2}}, i.conduit, function(v)
			set(sel.id, {ints = {conduit = v}})
		end)
		if r and r.conduit then
			int_field(sel.id, "Conduit mm (0: " .. settings().el_conduit_d .. ")",
					"conduit_d", i.conduit_d)
		end
		local cables = {}
		for k = 0, 4 do
			cables[#cables + 1] = {el.CABLES[k], k}
		end
		dropdown(props, "Cable", cables, i.cable, function(v)
			set(sel.id, {ints = {cable = v}})
		end)
		dropdown(props, "Cross section", {{"the circuit's", 0}, {"1.5 mm2", 1},
				{"2.5 mm2", 2}, {"6.0 mm2", 3}}, i.section, function(v)
			set(sel.id, {ints = {section = v}})
		end)
		if r then
			panel.label(props, string.format("%d mm: %d along, %d up and down",
					math.floor(r.len + 0.5), math.floor(r.horiz + 0.5),
					math.floor(r.vert + 0.5)))
			panel.label(props, r.count .. " conductors:", magic.Color(0.6, 0.9, 1.0))
			wrapped(props, r.text)
			panel.label(props, "Cable: " .. r.cable .. ", " .. r.section)
			panel.label(props, r.conduit and "In a " .. r.conduit_d ..
					" mm conduit" or "No conduit")
			if r.warn then
				panel.label(props, r.warn, magic.Color(1, 0.6, 0.4))
			end
		end
		del()
		return true
	elseif sel or not IS_ELEC_TOOL[S.tool] then
		return false
	end
	if S.tool == "ebox" then
		local e = S.elec
		panel.label(props, "New boxes: click a wall, or the ceiling")
		panel.keep(function()
			dropdown(props, "Role", ROLE_CHOICES, e.role, function(v)
				e.role = v
				refresh_panels()
			end)
			panel.check(props, "Surface box", e.surface == 1, function()
				e.surface = 1 - e.surface
				refresh_panels()
			end)
			if e.role == R.outlet then
				dropdown(props, "Outlets", OUTLET_CHOICES, e.outlet, function(v)
					e.outlet = v
					refresh_panels()
				end)
				panel.field(props, "Count", e.count, function(t)
					local v = tonumber(t)
					if v and v >= 1 and v <= 8 then e.count = math.floor(v) end
				end)
			elseif e.role == R.switch then
				dropdown(props, "Gangs", {{"one switch", 1}, {"two (two-gang)", 2}},
						e.gangs, function(v)
					e.gangs = v
					refresh_panels()
				end)
			end
		end)
		panel.label(props, "Heights: Plan settings")
	elseif S.tool == "eboard" then
		panel.label(props, "Click a wall to put the board on;")
		panel.label(props, "with one, a click moves it")
	elseif S.tool == "erun" then
		local c = current_circuit()
		local cs = {}
		for _, x in ipairs(circuits()) do
			cs[#cs + 1] = {circuit_text(x), x.id}
		end
		panel.label(props, "Click a box, the points, a box")
		panel.keep(function()
			if #cs > 0 then
				dropdown(props, "Circuit", cs, c.id, function(v)
					S.elec.circuit = v
					refresh_panels()
				end)
			else
				panel.label(props, "No circuits: add one in Circuits")
			end
			local routes = {}
			for k = 0, 4 do
				routes[#routes + 1] = {el.ROUTES[k], k}
			end
			dropdown(props, "Route", routes, S.elec.route, function(v)
				S.elec.route = v
				refresh_panels()
			end)
		end)
	elseif S.tool == "elink" then
		local sw = S.elec.link and d.ents[S.elec.link]
		panel.label(props, sw and "Linking " .. E.elec_name(sw.id) or
				"Click a switch box")
		if sw and sw.ints.gangs == 2 then
			panel.keep(function()
				dropdown(props, "Gang", {{"1", 1}, {"2", 2}}, S.elec.gang, function(v)
					S.elec.gang = v
					refresh_panels()
				end)
			end)
		end
	end
	return true
end

-- **The listing** saved as CSV, as the plan's export is: into
-- <user>/exports, or the web's download
function E.elec_export()
	local d = doc()
	local name = (d.plan_name ~= "" and d.plan_name or "plan") .. "-electrical.csv"
	local path, why = buildat.save_file(name, el.listing_csv(el.listing(d.ents,
			geom, E.elec_derived())))
	log:info("fp elec: listing " .. (path and "exported to " .. path or
			"not exported: " .. why))
	d.notice(not path and "Not exported: " .. why or path == "" and
			"Exported " .. name .. ": see your downloads" or "Exported to " .. path)
end

-- **The Circuits window**: every circuit, picked to be drawn for and
-- edited, and the picked one's fields; or, its other page, what to buy
function E.elec_window()
	if E.elec_win then
		panel.discard(E.elec_win)
		E.elec_win = nil
	end
	if not (S.electrical and S.circuits_open) then
		return
	end
	local d = doc()
	local w = panel.window(magic.HA_CENTER, magic.VA_TOP, 0, S.panel_y or 50)
	E.elec_win = w
	local top = panel.row(w)
	for _, p in ipairs({{"Circuits", false}, {"To buy", true}}) do
		panel.keep(function() return panel.button(top, p[1], function()
			S.elec.buy = p[2]
			refresh_panels()
		end, (S.elec.buy or false) == p[2]) end)
	end
	panel.keep(function() return panel.button(top, "Close", function()
		S.circuits_open = false
		refresh_panels()
	end) end)
	if S.elec.buy then
		-- The listing's lines, as the CSV has them, in two columns
		local st = settings()
		local row = panel.row(w)
		panel.label(row, "Cables: " .. st.el_slack .. " mm slack a box end, " ..
				st.el_waste .. " % waste (Plan settings)")
		panel.keep(function() return panel.button(row, "Export CSV",
				E.elec_export) end)
		-- The pieces' kinds and the rest's, side by side; shorter than the
		-- CSV's: what the item says already, a switch's kinds in English
		local cols = panel.row(w)
		local c1, c2 = panel.column(cols), panel.column(cols)
		local short = {Board = "", Box = "", Cable = "", ["ML wire"] = ""}
		for _, r in ipairs(el.listing(d.ents, geom, E.elec_derived())) do
			local text = (short[r.kind] or r.kind .. " ") ..
					r.item:gsub(" %(%a+%)", "") .. (r.kind == "Fuse" and ", " ..
					r.notes:gsub(":.*", "") or "") .. ": " .. r.qty .. " " .. r.unit
			panel.label(r.unit == "pcs" and r.kind ~= "Fuse" and c1 or c2, text)
		end
		return
	end
	local function set(id, fields)
		send({{op = "set", ent = {id = id, ints = fields.ints, strs = fields.strs}}})
	end
	panel.label(w, "Click a circuit to draw runs for it")
	local board = boards()[1]
	if board then
		panel.label(w, "Board '" .. board.strs.name .. "', main fuse " ..
				board.ints.fuse .. " A")
	end
	local cur = current_circuit()
	for _, c in ipairs(circuits()) do
		panel.keep(function() return panel.button(w, circuit_text(c), function()
			S.elec.circuit = c.id
			refresh_panels()
		end, cur and c.id == cur.id) end)
	end
	if board then
		panel.button(w, "Add a circuit", function()
			local n = 0
			for _, c in ipairs(circuits()) do
				n = math.max(n, c.ints.number)
			end
			local ph = d.placeholder()
			send({{op = "create", ent = {id = ph, type = "circuit",
					ints = {board = board.id, number = n + 1}}}}, function(err)
				if err == "" then
					S.elec.circuit = E.real_id(ph)
					refresh_panels()
				end
			end)
		end)
	else
		panel.label(w, "Put a board in first (the Board tool)")
	end
	if not cur then
		return
	end
	local i = cur.ints
	panel.label(w, "Circuit " .. i.number)
	panel.field(w, "Number", i.number, function(t)
		local v = tonumber(t)
		if v then set(cur.id, {ints = {number = math.floor(v + 0.5)}}) end
	end)
	panel.field(w, "Name", cur.strs.name, function(t)
		set(cur.id, {strs = {name = t}})
	end, 160, true)
	dropdown(w, "Kind", {{"power", 0}, {"data", 1}}, i.kind, function(v)
		set(cur.id, {ints = {kind = v, section = v == 1 and 4 or 1,
				cond = v == 1 and 0 or 7}})
	end)
	if i.kind == 0 then
		local r = panel.row(w)
		for _, p in ipairs(el.CONDUCTORS) do
			panel.check(r, p[2], el.bit(i.cond, p[1]), function()
				set(cur.id, {ints = {cond = el.bit(i.cond, p[1]) and i.cond - p[1] or
						i.cond + p[1]}})
			end)
		end
		panel.field(w, "Fuse A", i.fuse, function(t)
			local v = tonumber(t)
			if v then set(cur.id, {ints = {fuse = math.floor(v + 0.5)}}) end
		end)
		dropdown(w, "Cross section", {{"1.5 mm2", 1}, {"2.5 mm2", 2},
				{"6.0 mm2", 3}}, i.section, function(v)
			set(cur.id, {ints = {section = v}})
		end)
	end
	panel.field(w, "Other wires (a, b)", cur.strs.wires, function(t)
		set(cur.id, {strs = {wires = t}})
	end, 160, true)
	panel.check(w, "Runs in conduit", i.conduit == 1, function()
		set(cur.id, {ints = {conduit = 1 - i.conduit}})
	end)
	for _, warn in ipairs((E.elec_derived().circuits[cur.id] or {}).warn or {}) do
		panel.label(w, warn, magic.Color(1, 0.6, 0.4))
	end
	panel.button(w, "Delete this circuit and its runs", function()
		send({{op = "delete", ent = {id = cur.id}}})
	end)
end

--
-- The view
--
-- The building dimmed under the layer, over the plan's cut faces (3 mm
-- under the cut) and under its lines (1 mm)
local dim_node = scene:CreateChild("ElecDim")
local dim_material = magic.cache:GetResource("Material", "main/fp_dim.xml")
local lines_node = scene:CreateChild("ElecLines")
-- The objects under the cut dimmed again, over the first (walls a little,
-- objects much)
local dim_objects_node = scene:CreateChild("ElecDimObjects")
local dim_objects_material = magic.cache:GetResource("Material", "main/fp_dim_objects.xml")
local dim_key, lines_key, lines_n, dim_objects_key
local DARK = magic.Color(0.1, 0.25, 0.75)
local SURFACE = magic.Color(0.65, 0.15, 0.65)
local CIRCUIT_COLORS = {magic.Color(0.85, 0.2, 0.1), magic.Color(0.1, 0.55, 0.15),
	magic.Color(0.1, 0.35, 0.85), magic.Color(0.75, 0.45, 0.0),
	magic.Color(0.55, 0.1, 0.7), magic.Color(0.0, 0.55, 0.55)}
local function circuit_color(c)
	return CIRCUIT_COLORS[((c and c.ints.number or 1) - 1) % #CIRCUIT_COLORS + 1]
end

-- A box's symbol, in its frame: p on the wall's face, u along the wall, v
-- into the room (a ceiling box: the plan's axes); s the symbol's size in
-- mm. seg(ax, az, bx, bz) in that frame's units of s.
local function symbol(seg, b, kinds)
	local i = b.ints
	local function circle(cx, cz, r, n)
		n = n or 16
		for k = 0, n - 1 do
			local a0, a1 = k / n * 2 * math.pi, (k + 1) / n * 2 * math.pi
			seg(cx + r * math.cos(a0), cz + r * math.sin(a0),
					cx + r * math.cos(a1), cz + r * math.sin(a1))
		end
	end
	local function rect(x0, z0, x1, z1)
		seg(x0, z0, x1, z0)
		seg(x1, z0, x1, z1)
		seg(x1, z1, x0, z1)
		seg(x0, z1, x0, z0)
	end
	local role = i.role
	if role == R.outlet then
		-- A socket outlet: a half circle open away from the wall on a stem;
		-- earthed (Schuko): the line across it; data: a triangle, TP
		local n = math.min(i.count, 4)
		for k = 1, n do
			local o = (k - (n + 1) / 2) * 2.4
			if i.outlet == 1 then
				seg(o - 1, 0.3, o + 1, 0.3)
				seg(o + 1, 0.3, o, 2.0)
				seg(o, 2.0, o - 1, 0.3)
			else
				seg(o, 0, o, 0.6)
				for a = 0, 7 do
					local a0, a1 = math.pi + a / 8 * math.pi, math.pi + (a + 1) / 8 * math.pi
					seg(o + math.cos(a0), 1.6 + math.sin(a0), o + math.cos(a1),
							1.6 + math.sin(a1))
				end
				seg(o - 1.3, 1.6, o + 1.3, 1.6)
			end
		end
	elseif role == R.switch then
		-- A switch: a small circle and a lever with a tick; two-way, a
		-- lever each way; intermediate, a bar across too; a gang each
		for g = 1, i.gangs do
			local o = i.gangs == 2 and (g == 1 and -1.4 or 1.4) or 0
			local kind = kinds[b.id .. ":" .. g] or "1-way"
			circle(o, 1.0, 0.3, 8)
			local function lever(sx)
				local ex, ez = o + sx * 0.9, 1.0 + sx * 1.5
				seg(o + sx * 0.18, 1.0 + sx * 0.25, ex, ez)
				seg(ex, ez, ex + sx * 0.45, ez - sx * 0.27)
			end
			lever(1)
			if kind:find("2%-way") or kind:find("intermediate") then
				lever(-1)
			end
			if kind:find("intermediate") then
				seg(o - 0.9, 1.6, o + 0.9, 0.4)
			end
		end
	elseif role == R.ceiling then
		-- A lamp: a circle with a cross in it
		circle(0, 0, 1.2)
		local c = 1.2 * 0.7071
		seg(-c, -c, c, c)
		seg(-c, c, c, -c)
	elseif role == R.board then
		-- A board: a box, its one half filled
		rect(-2, 0, 2, 1.6)
		seg(-2, 0, 2, 1.6)
		for k = 1, 3 do
			local t = k / 4
			seg(-2 + 4 * t, 0, 2, 1.6 * (1 - t))
		end
	elseif role == R.equipment then
		-- A fixed connection: a box with its outlet's stroke
		rect(-1.2, 0.3, 1.2, 2.1)
		seg(0, 0, 0, 0.3)
		seg(-0.6, 1.2, 0.6, 1.2)
	elseif role == R.device then
		rect(-0.8, 0.2, 0.8, 1.8)
	else
		-- A junction box: a small circle, a dot in it
		circle(0, i.wall ~= 0 and 0.8 or 0, 0.6, 12)
		circle(0, i.wall ~= 0 and 0.8 or 0, 0.2, 6)
	end
end

local function build_lines(y)
	local d = doc()
	local der = E.elec_derived()
	local k = mm_per_px()
	local s = sym_unit()
	local out = {}
	local function add(ax, az, bx, bz, c)
		local n = #out
		out[n + 1], out[n + 2], out[n + 3] = W(ax), y, W(az)
		out[n + 4], out[n + 5], out[n + 6], out[n + 7] = c.r, c.g, c.b, 1
		out[n + 8], out[n + 9], out[n + 10] = W(bx), y, W(bz)
		out[n + 11], out[n + 12], out[n + 13], out[n + 14] = c.r, c.g, c.b, 1
	end
	-- The runs: solid in a cavity, dashed on a surface; a slanted tick a
	-- conductor (to eight) across the middle of the longest segment
	for id, r in pairs(der.runs) do
		local e = d.ents[id]
		local pts = r.on[S.layout]
		if pts then
			local col = circuit_color(d.ents[e.ints.circuit])
			local long, li = -1, 2
			for j = 2, #pts do
				local p, q = pts[j - 1], pts[j]
				local l = geom.len(q[1] - p[1], q[2] - p[2])
				if l > long then
					long, li = l, j
				end
				if e.ints.route >= 3 then
					local n = math.max(1, math.floor(l / (5 * k)))
					for t = 0, n - 1, 2 do
						add(p[1] + (q[1] - p[1]) * t / n, p[2] + (q[2] - p[2]) * t / n,
								p[1] + (q[1] - p[1]) * (t + 1) / n,
								p[2] + (q[2] - p[2]) * (t + 1) / n, col)
					end
				else
					add(p[1], p[2], q[1], q[2], col)
				end
			end
			local p, q = pts[li - 1], pts[li]
			if long > 0 then
				local ux, uz = (q[1] - p[1]) / long, (q[2] - p[2]) / long
				local n = math.min(r.count or 0, 8)
				for t = 1, n do
					local o = (t - (n + 1) / 2) * 0.5 * s
					local mx, mz = (p[1] + q[1]) / 2 + ux * o, (p[2] + q[2]) / 2 + uz * o
					add(mx - (uz + ux * 0.5) * s * 0.7, mz + (ux - uz * 0.5) * s * 0.7,
							mx + (uz + ux * 0.5) * s * 0.7, mz - (ux - uz * 0.5) * s * 0.7,
							col)
				end
			end
		end
	end
	for _, b in ipairs(boxes_here()) do
		local i = b.e.ints
		local ux, uz, vx, vz = b.ux, b.uz, b.vx, b.vz
		local col = i.surface == 1 and SURFACE or DARK
		symbol(function(ax, az, bx, bz)
			add(b.x + (ux * ax + vx * az) * s, b.z + (uz * ax + vz * az) * s,
					b.x + (ux * bx + vx * bz) * s, b.z + (uz * bx + vz * bz) * s, col)
		end, b.e, der.gangs)
	end
	lines_n = #out
	if lines_n > 0 then
		buildat.set_line_geometry(lines_node, out)
		lines_node:GetComponent("CustomGeometry"):SetMaterial(0, flat_material)
	end
end

-- Each frame in the plan view, from draw_overlay: the dimming, the
-- layer, the labels, what is pointed at, the run being drawn and a
-- switch's links
function E.elec_overlay(line, dashed)
	local on = S.electrical and S.view == "2d"
	dim_node.enabled = on
	lines_node.enabled = on
	dim_objects_node.enabled = on
	if not on then
		return
	end
	local d = doc()
	local cut = settings().cut
	local okey = M.build_gen .. ":" .. cut .. ":" .. tostring(S.layout)
	if okey ~= dim_objects_key then
		dim_objects_key = okey
		dim_objects_node.position = magic.Vector3(0, W(cut) - 0.0024, 0)
		local g = dim_objects_node:GetComponent("CustomGeometry") or
				dim_objects_node:CreateComponent("CustomGeometry")
		g:SetNumGeometries(1)
		g:BeginGeometry(0, magic.TRIANGLE_LIST)
		local c = magic.Color(1, 1, 1, 1)
		for _, it in pairs(E.inst_data) do
			if not it.hosted and it.y0 < cut and it.foot and #it.foot >= 3 then
				for _, t in ipairs(geom.triangulate(it.foot)) do
					for k = 1, 3 do
						local p = it.foot[t[k]]
						g:DefineVertex(magic.Vector3(W(p[1]), 0, W(p[2])))
						g:DefineNormal(magic.Vector3(0, 1, 0))
						g:DefineColor(c)
					end
				end
			end
		end
		g:Commit()
		g:SetMaterial(0, dim_objects_material)
	end
	local y = W(cut) - 0.002
	if dim_key ~= cut then
		dim_key = cut
		dim_node.position = magic.Vector3(0, W(cut) - 0.0025, 0)
		local g = dim_node:GetComponent("CustomGeometry") or
				dim_node:CreateComponent("CustomGeometry")
		g:SetNumGeometries(1)
		g:BeginGeometry(0, magic.TRIANGLE_LIST)
		local r = 2000
		local c = magic.Color(1, 1, 1, 1)
		for _, p in ipairs({{-r, -r}, {r, r}, {r, -r}, {-r, -r}, {-r, r}, {r, r}}) do
			g:DefineVertex(magic.Vector3(p[1], 0, p[2]))
			g:DefineNormal(magic.Vector3(0, 1, 0))
			g:DefineColor(c)
		end
		g:Commit()
		g:SetMaterial(0, dim_material)
	end
	local der = E.elec_derived()
	local key = gen .. ":" .. mm_per_px() .. ":" .. tostring(S.layout) .. ":" .. cut
	if key ~= lines_key then
		lines_key = key
		build_lines(y)
	end
	lines_node.enabled = lines_n > 0
	local accent = magic.Color(1.0, 0.6, 0.1)
	-- Each run's circuit at its middle; a board's and an equipment box's
	-- name at it
	for id, r in pairs(der.runs) do
		local e = d.ents[id]
		local pts = r.on[S.layout]
		if pts and #pts >= 2 then
			local c = d.ents[e.ints.circuit]
			local m = math.ceil(#pts / 2)
			local p, q = pts[m], pts[m + 1] or pts[m]
			world_label((p[1] + q[1]) / 2, 0, (p[2] + q[2]) / 2, tostring(c and
					c.ints.number or "?"))
		end
	end
	for _, b in ipairs(boxes_here()) do
		if (b.e.ints.role == R.board or b.e.ints.role == R.equipment) and
				b.e.strs.name ~= "" then
			world_label(b.x, 0, b.z, b.e.strs.name)
		end
	end
	-- The selection, where a drag has it: a run's points and the middles
	-- of its segments (a point added there) on the floor it was drawn on
	local dg = S.drag and S.drag.kind == "elec" and S.drag
	for id, kind in pairs(S.sel) do
		local r = kind == "erun" and der.runs[id]
		local pts = r and (dg and dg.run == id and dg.x and drag_pts(dg) or
				r.on[S.layout])
		if pts then
			local h = 6 * mm_per_px()
			for j = 2, #pts do
				line(pts[j - 1][1], pts[j - 1][2], pts[j][1], pts[j][2], accent)
			end
			for _, hd in ipairs(r.on[S.layout] == r.pts and not dg and
					handles(r) or {}) do
				if hd.pt then
					for _, s in ipairs({{-h, -h, h, -h}, {h, -h, h, h}, {h, h, -h, h},
							{-h, h, -h, -h}}) do
						line(hd.x + s[1], hd.z + s[2], hd.x + s[3], hd.z + s[4], accent)
					end
				else
					line(hd.x - h, hd.z, hd.x + h, hd.z, accent)
					line(hd.x, hd.z - h, hd.x, hd.z + h, accent)
				end
			end
		elseif kind == "ebox" and d.ents[id] then
			local x, z = el.box_xz(d.ents, d.ents[id], geom)
			if dg and dg.box == id then
				x, z = el.box_xz(d.ents, {ints = dg.ints}, geom)
			end
			local s = 28 * mm_per_px()
			for t = 0, 15 do
				local a0, a1 = t / 16 * 2 * math.pi, (t + 1) / 16 * 2 * math.pi
				line(x + s * math.cos(a0), z + s * math.sin(a0), x + s * math.cos(a1),
						z + s * math.sin(a1), accent)
			end
		end
	end
	-- What a switch controls, dashed to each load, while it is selected or
	-- being linked
	local sw = S.elec.link and d.ents[S.elec.link] or
			S.primary and d.ents[S.primary]
	if sw and sw.type == "ebox" and sw.ints.role == R.switch then
		local sx, sz = el.box_xz(d.ents, sw, geom)
		for g = 1, sw.ints.gangs do
			for _, l in ipairs(sw.lists["controls" .. g]) do
				local le = d.ents[l]
				if le and le.ints.layout == S.layout then
					local lx, lz = el.box_xz(d.ents, le, geom)
					dashed({{sx, sz}, {lx, lz}}, g == 1 and magic.Color(0.9, 0.6, 0.0) or
							magic.Color(0.0, 0.7, 0.6))
				end
			end
		end
	end
	-- The run being drawn, to the pointer
	local dr = S.elec.draw
	local x, z = cursor_floor()
	if dr and S.tool == "erun" then
		local a = d.ents[dr.a]
		if a then
			local ax, az = el.box_xz(d.ents, a, geom)
			local pts = {{ax, az}}
			for _, p in ipairs(dr.pts) do
				pts[#pts + 1] = p
			end
			if x then
				pts[#pts + 1] = {x, z}
			end
			if dr.layout == S.layout then
				for j = 2, #pts do
					line(pts[j - 1][1], pts[j - 1][2], pts[j][1], pts[j][2], accent)
				end
			end
		end
	end
	-- **The tooltip**: what the pointer is on, named
	if x and not E.over_ui() then
		local b = box_at(x, z)
		local r = not b and run_at(x, z)
		if b or r then
			world_label(x, 0, z - 24 * mm_per_px(), E.elec_name(b and b.id or r))
		end
	end
end

--
-- For a check ([FP_ELECTRICAL]'s): "event fp_elec <command> <args>"
--
-- The case, by box names; a wall is found by a point on its line
local function wall_near(x, z)
	local d = doc()
	for _, w in ipairs(d.of_type("wall")) do
		local f = el.wall_line(d.ents, w.id, geom)
		local na = d.ents[w.ints.a]
		if f and na.ints.layout == S.layout then
			local t = (x - f.ax) * f.ux + (z - f.az) * f.uz
			local px, pz = f.ax + f.ux * t, f.az + f.uz * t
			if t >= 0 and t <= f.len and geom.len(px - x, pz - z) < 1 then
				return w.id, f, t
			end
		end
	end
end

local function by_name(name)
	for _, b in ipairs(doc().of_type("ebox")) do
		if b.strs.name == name then
			return b
		end
	end
end

local function circuit_no(n)
	for _, c in ipairs(circuits()) do
		if c.ints.number == n then
			return c
		end
	end
end

-- The user's case (the check's): a board, three rooms' boxes, four
-- circuits and their runs. Boxes: {name, role, x, z, into x, into z,
-- height (nil on the ceiling), fields}.
local CASE_BOXES = {
	{"Main board", R.board, 1000, 0, 1000, 1000, 1500, {surface = 1, fuse = 25}},
	{"J1", R.junction, 1000, 2000},
	{"SW W", R.switch, 0, 2000, 1000, 2000, 1050, {gangs = 2}},
	{"SW E", R.switch, 6000, 2000, 5000, 2000, 1050, {gangs = 2}},
	{"Living A", R.ceiling, 2000, 2000},
	{"Living B", R.ceiling, 4000, 2000},
	{"KJ", R.junction, 7500, 2000},
	{"Kitchen 1", R.ceiling, 7500, 1000},
	{"Kitchen 2", R.ceiling, 7500, 3000},
	{"SW K", R.switch, 6000, 3500, 7000, 3500, 1050},
	{"SJ", R.junction, 3000, 5500},
	{"SW S", R.switch, 0, 5500, 1000, 5500, 1050},
	{"Desk 1", R.outlet, 2000, 7000, 2000, 6000, 300, {count = 2}},
	{"Desk 2", R.outlet, 4000, 7000, 4000, 6000, 300, {count = 2}},
	{"Outlet S", R.outlet, 6000, 5500, 5000, 5500, 300},
	{"Data 1", R.outlet, 5000, 7000, 5000, 6000, 300, {outlet = 1}},
	{"Data 2", R.outlet, 5000, 4000, 5000, 5000, 300, {outlet = 1}},
}
local CASE_CONTROLS = {
	{"SW W", 1, {"Living A"}}, {"SW W", 2, {"Living B"}},
	{"SW E", 1, {"Living A"}}, {"SW E", 2, {"Living B"}},
	{"SW K", 1, {"Kitchen 1", "Kitchen 2"}},
	{"SW S", 1, {"Desk 1", "Desk 2"}},
}
local CASE_CIRCUITS = {
	{1, "Living lights", {}},
	{2, "Kitchen lights", {}},
	{3, "Study outlets", {fuse = 16, section = 2, conduit = 1}},
	{4, "Data", {kind = 1, section = 4, cond = 0}, "data 1"},
}
-- {circuit, a, b, route, fields}
local CASE_RUNS = {
	{1, "Main board", "J1", 2, {section = 2}},
	{1, "J1", "SW W", 2}, {1, "J1", "Living A", 2}, {1, "Living A", "Living B", 2},
	{1, "Living B", "SW E", 2},
	{2, "Main board", "KJ", 2}, {2, "KJ", "Kitchen 1", 2}, {2, "KJ", "Kitchen 2", 2},
	{2, "KJ", "SW K", 2},
	{3, "Main board", "SJ", 2}, {3, "SJ", "SW S", 2}, {3, "SJ", "Desk 1", 2},
	{3, "Desk 1", "Desk 2", 0}, {3, "SJ", "Outlet S", 2},
	{4, "Data 1", "Data 2", 3},
}

local function build_case()
	local ops, ph = {}, {}
	for _, b in ipairs(CASE_BOXES) do
		local id = doc().placeholder()
		ph[b[1]] = id
		local ints = {layout = S.layout, role = b[2]}
		for k, v in pairs(b[8] or {}) do
			ints[k] = v
		end
		if b[7] then
			local wid, f, t = wall_near(b[3], b[4])
			if not wid then
				log:info("fp elec case: no wall at " .. b[3] .. " " .. b[4])
				return
			end
			ints.wall, ints.along, ints.height = wid, math.floor(t + 0.5), b[7]
			ints.side = ((b[5] - f.ax) * -f.uz + (b[6] - f.az) * f.ux) >= 0 and 0 or 1
		else
			ints.x, ints.z = b[3], b[4]
		end
		ops[#ops + 1] = {op = "create", ent = {id = id, type = "ebox", ints = ints,
				strs = {name = b[1]}}}
	end
	for _, c in ipairs(CASE_CONTROLS) do
		local l = {}
		for k, n in ipairs(c[3]) do
			l[k] = ph[n]
		end
		ops[#ops + 1] = {op = "set", ent = {id = ph[c[1]],
				lists = {["controls" .. c[2]] = l}}}
	end
	for _, c in ipairs(CASE_CIRCUITS) do
		local id = doc().placeholder()
		ph["c" .. c[1]] = id
		local ints = {board = ph["Main board"], number = c[1]}
		for k, v in pairs(c[3]) do
			ints[k] = v
		end
		ops[#ops + 1] = {op = "create", ent = {id = id, type = "circuit",
				ints = ints, strs = {name = c[2], wires = c[4] or ""}}}
	end
	for _, r in ipairs(CASE_RUNS) do
		local ints = {circuit = ph["c" .. r[1]], a = ph[r[2]], b = ph[r[3]],
				route = r[4]}
		for k, v in pairs(r[5] or {}) do
			ints[k] = v
		end
		ops[#ops + 1] = {op = "create", ent = {id = doc().placeholder(),
				type = "erun", ints = ints, lists = {pts = {}}}}
	end
	-- The kitchen's outer wall a framed one with no cavity to cut into
	local w = wall_near(9000, 2000)
	if w then
		ops[#ops + 1] = {op = "set", ent = {id = w, ints = {cavity = 0}}}
	end
	send(ops, done("case"))
end

-- Every run's derivation, by its boxes' names, and every switch box's
-- inserts, in the log
local function dump(tag)
	local d = doc()
	local der = E.elec_derived()
	local lines = {}
	for id, r in pairs(der.runs) do
		local e = d.ents[id]
		lines[#lines + 1] = string.format("fp elec %s: run %s-%s: %s | %s | %s | %d mm",
				tag, el.box_name(d.ents, e.ints.a), el.box_name(d.ents, e.ints.b),
				r.text, r.cable, r.section, math.floor(r.len + 0.5))
	end
	for id, b in pairs(der.boxes) do
		lines[#lines + 1] = "fp elec " .. tag .. ": box " ..
				el.box_name(d.ents, id) .. ": " .. b.inserts
	end
	table.sort(lines)
	for _, l in ipairs(lines) do
		log:info(l)
	end
	log:info("fp elec " .. tag .. ": " .. #lines .. " lines")
end

-- Edits the server is to refuse, each logged with the reason
local function try(what)
	local d = doc()
	local function run(c, a, b, route, pts)
		local ca, ba, bb = circuit_no(c), by_name(a) or a, by_name(b) or b
		if not (ca and ba and bb) then
			log:info("fp elec try " .. what .. ": missing parts")
			return
		end
		send({{op = "create", ent = {id = d.placeholder(), type = "erun",
				ints = {circuit = ca.id, a = ba.id, b = bb.id, route = route},
				lists = {pts = pts or {}}}}}, done("try " .. what))
	end
	if what == "loop" then
		run(1, "SW E", "SW W", 2)
	elseif what == "data_schuko" then
		-- The data run moved to end at a Schuko box
		for _, r in ipairs(d.of_type("erun")) do
			if r.ints.circuit == circuit_no(4).id then
				send({{op = "set", ent = {id = r.id, ints = {b = by_name("Desk 2").id}}}},
						done("try " .. what))
			end
		end
	elseif what == "data_two" then
		run(4, "Data 2", "Data 1", 3)
	elseif what == "floor_route" then
		run(3, "Outlet S", "Desk 2", 1)
	elseif what == "wall_route" then
		-- To the box the check put on the kitchen's outer wall
		local w = wall_near(9000, 2000)
		local onto
		for _, b in ipairs(d.of_type("ebox")) do
			if b.ints.wall == w then
				onto = b
			end
		end
		run(2, "KJ", onto, 0)
	elseif what == "wall_along" then
		-- In the walls' cavities from SW K east, then 2500 mm along the
		-- kitchen's outer wall, 50 mm off its line, to a ceiling box
		run(2, "SW K", "Kitchen 1", 0, {8950, 3500, 8950, 1000})
	elseif what == "ceiling_switch" then
		-- A switch box on the ceiling 300 mm off the living room's west
		-- wall, as a click beside a wall used to put one, run to J1
		send({{op = "create", ent = {id = d.placeholder(), type = "ebox",
				ints = {layout = S.layout, role = R.switch, gangs = 1, x = 300,
					z = 3000}, strs = {name = "SW C"}}}}, function(err)
			if err == "" then
				run(1, "J1", "SW C", 2)
			end
		end)
	end
end

magic.SubscribeToEvent("command_seq:fp_elec", function(_, ev)
	local cmd, arg = ev:GetString("Param"):match("^(%S+) ?(.*)$")
	if cmd == "case" then
		build_case()
	elseif cmd == "dump" then
		dump(arg)
	elseif cmd == "try" then
		try(arg)
	elseif cmd == "delete" then
		local b = by_name(arg)
		if b then
			send({{op = "delete", ent = {id = b.id}}}, done("delete " .. arg))
		end
	elseif cmd == "undo" then
		doc().undo()
	elseif cmd == "view" then
		-- The plan view at x z, span mm tall, the layer on, a tool:
		-- "view x z span tool [role surface | circuit number]"
		local v = {}
		for w in arg:gmatch("%S+") do
			v[#v + 1] = w
		end
		M.pick_view("2d")
		S.cx, S.cz, S.span = tonumber(v[1]), tonumber(v[2]), tonumber(v[3])
		if not S.electrical then
			E.elec_toggle()
		end
		S.sel, S.sel_face, S.primary = {}, {}, nil
		E.set_tool(v[4] or "select")
		if v[4] == "erun" and v[5] then
			S.elec.circuit = circuit_no(tonumber(v[5])).id
		elseif v[5] then
			S.elec.role, S.elec.surface = tonumber(v[5]), tonumber(v[6] or 0)
		end
		S.dirty = true
		refresh_panels()
		log:info("fp elec view: " .. arg)
	elseif cmd == "export" then
		doc().export_plan()
	elseif cmd == "list" then
		E.elec_export()
	elseif cmd == "where" then
		-- Every box's place and every run's points, by name
		local d, lines = doc(), {}
		for _, b in ipairs(d.of_type("ebox")) do
			local i = b.ints
			local f = i.wall ~= 0 and el.wall_line(d.ents, i.wall, geom)
			local x, z = el.box_xz(d.ents, b, geom)
			lines[#lines + 1] = string.format("box %s: at %d %d, wall %s side %d",
					el.box_name(d.ents, b.id), math.floor(x + 0.5), math.floor(z + 0.5),
					f and string.format("%d,%d+%d", f.ax, f.az, f.len) or "none", i.side)
		end
		for _, r in ipairs(d.of_type("erun")) do
			lines[#lines + 1] = "run " .. el.box_name(d.ents, r.ints.a) .. "-" ..
					el.box_name(d.ents, r.ints.b) .. ": pts " ..
					(#r.lists.pts > 0 and table.concat(r.lists.pts, " ") or "none")
		end
		table.sort(lines)
		for _, l in ipairs(lines) do
			log:info("fp elec where " .. arg .. ": " .. l)
		end
	elseif cmd == "sel" then
		-- What is selected: its name and height
		local e = S.primary and doc().ents[S.primary]
		log:info("fp elec sel " .. arg .. ": " .. (e and e.type == "ebox" and
				el.box_name(doc().ents, e.id) .. " height " .. e.ints.height or "none"))
	elseif cmd == "riser" then
		-- A floor above, a ceiling box on it 1 m east of J1 and a run of
		-- circuit 1 up to it; then that floor's plan, logging whether it
		-- draws the run
		local d = doc()
		local pl, pb, pr = d.placeholder(), d.placeholder(), d.placeholder()
		send({{op = "create", ent = {id = pl, type = "layout",
				ints = {y = settings().floor_step}, strs = {name = "Upper"}}},
				{op = "create", ent = {id = pb, type = "ebox", ints = {layout = pl,
				role = R.ceiling, x = 2000, z = 2000}, strs = {name = "Up"}}},
				{op = "create", ent = {id = pr, type = "erun", ints = {
				circuit = circuit_no(1).id, a = by_name("J1").id, b = pb, route = 2},
				lists = {pts = {}}}}}, function(err)
			if err ~= "" then
				return log:info("fp elec riser: " .. err)
			end
			E.place.switch(E.real_id(pl))
			refresh_panels()
			local r = E.elec_derived().runs[E.real_id(pr)]
			log:info("fp elec riser: drawn on the upper floor: " ..
					tostring(r and r.on[S.layout] ~= nil) .. ", " ..
					(r and math.floor(r.len + 0.5) or "no") .. " mm")
		end)
	elseif cmd == "windows" then
		log:info("fp elec windows: layouts " .. tostring(E.place.win ~= nil) ..
				", circuits " .. tostring(E.elec_win ~= nil))
	end
end)
end
-- vim: set noet ts=4 sw=4:
