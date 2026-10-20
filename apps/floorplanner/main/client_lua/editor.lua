-- Buildat: apps/floorplanner/main/client_lua/editor.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The editor: the scene built from the replica, the two cameras, the tools
-- and the panels. Walls and rooms on shared nodes ([FP_WALLS], [FP_ROOMS]),
-- boxes as definitions placed by instances ([FP_OBJECTS]).
--
-- Nothing here changes the document directly. A tool builds a batch and
-- sends it; what the server accepts comes back as fp:changes and the scene
-- is rebuilt from the replica. A drag shows its preview locally and is sent
-- when released.
local log = buildat.Logger("floorplanner")
local magic = require("buildat/extension/urho3d")
local function load(name)
	local ok, err, m = buildat.run_script_file("main/" .. name)
	if not ok or (type(m) ~= "table" and type(m) ~= "function") then
		error("floorplanner: could not load " .. name .. ": " .. tostring(err))
	end
	return m
end
local geom = load("geom.lua")
local panel = load("panel.lua")
local fit = load("fit.lua")
local keys = load("keys.lua")

local M = {}
-- init.lua's chat key, and its way past the T while a key is being bound
M.keys = keys
local doc
M.daylight = load("daylight.lua")

local GRID_STEPS = {1, 10, 50, 100, 200, 500, 1000}
local ANGLE_STEPS = {false, 1, 5, 15, 45, 90}
-- How near, in pixels, the cursor snaps to a node or an edge
local SNAP_PX = 12
local DRAG_PX = 4
-- Where a copy lands from what it was copied from
local COPY_OFFSET = 500
-- The view button goes round the views: the plan, the free camera, walking
local VIEW_NAMES = {["2d"] = "2D", ["3d"] = "3D", walk = "Walk"}
-- Walking: the body's radius, how high a step it takes, its height, mm.
-- A step takes a stair's riser, which building codes cap near 220 mm.
local BODY_R, STEP, HEAD = 250, 250, 1750
local JUSTIFY_CHOICES = {{"centered", 0}, {"left", 1}, {"right", 2},
	{"custom", 3}}
-- What a definition is, as main.cpp's DefKind
local KIND = {box = 0, voxel = 1, opening = 2, door = 3, window = 4,
	switch = 5, stairs = 6}
-- A door's or a window's parts, by the field each keeps its material in
local DOOR_PARTS = {mat = true, mat_leaf = true, mat_glass = true}
local KIND_NAMES = {[0] = "Box", [2] = "Opening", [3] = "Door",
	[4] = "Window", [5] = "Switch", [6] = "Stairs"}
-- A new opening, door and window
local HOSTED = {
	[2] = {w = 900, h = 2100, sill = 0},
	[3] = {w = 900, h = 2100, sill = 0},
	[4] = {w = 1200, h = 1200, sill = 900},
	[5] = {w = 80, h = 80, sill = 1050},
}
-- A door leaf's thickness and the gap round it, and a window's frame
local LEAF_T, LEAF_GAP, FRAME_W = 40, 4, 50

-- **What the editor's files share besides S** ([FP_EDITOR_MODULES]):
-- functions, handles and the rebuild's tables, so a part moved to a file
-- of its own (overlay.lua and on, each `function(E)`) reads them as E.x,
-- and a diff shows what one part takes from another
local E = {}

local S = {
	-- How the 3D view and walking are lit ([FP_DAYLIGHT]): "pbr", the
	-- plan's sun and sky at its place and hour in radiance, or "unlit",
	-- the plain look the plan view always has, for clarity and speed; every
	-- client starts pbr. The viewer's own, kept on the client.
	lighting = buildat.storage_read("lighting") or "pbr",
	view = "2d",
	show_ids = false, -- the material id decals
	plan_look = 1, -- the plan view's look (L): 0 lit, 1 flat, 2 technical
	tool = "select",
	voxel_mode = "place", -- the voxel tool's click in 3D
	angle = 4,      -- index into ANGLE_STEPS: the angle snap
	-- New walls
	thickness = 120, -- a new wall's, mm: a 90 mm stud and a board on each side (user)
	justify = 0,
	shift = 0,      -- a custom justify's, mm left of the line
	height = 0,
	hang = 0,
	room_walls = true, -- a room drawn gets walls on its edges
	-- and a plafond lamp at its middle (user: a room is dark without one)
	room_lamp = buildat.storage_read("room_lamp") ~= "0",
	-- New boxes
	box = {w = 600, h = 750, d = 600, align = 0, offset = 0},
	-- The object tool's other shape: stairs this wide, up this high (0: the
	-- plan's floor to floor) in risers of about this much, each this deep
	shape = "box",
	stairs = {w = 1000, h = 0, riser = 200, tread = 250},
	hosted = 3,     -- what the wall items tool puts in a wall
	voxel_size = 150, -- a new voxel volume's, mm (user, 2026-10-01: was 50)
	-- Doors and windows a viewer has opened, and lamps they have switched,
	-- which only they see
	local_open = {},
	local_on = {},
	local_blinds = {},
	linking = nil,  -- the switch whose lamps clicks add and remove
	material = nil, -- the palette entry picked
	-- The cursor, in window pixels
	mx = 0, my = 0,
	shift = false,
	-- The 2D camera: centre in mm, and how many mm tall the view is
	cx = 0, cz = 0, span = 12000,
	-- The 3D camera, in metres and degrees
	pos = {x = -4, y = 6, z = -6},
	-- Walking: where the feet are, mm, and the eyes above them
	walk = {x = 0, z = 0, feet = 0, noclip = false},
	-- The fingers down, by id ([FP_TOUCH] 3)
	fingers = {},
	eye = 1600,
	-- The pointer is a finger ([FP_TOUCH]): the page says so
	touch = buildat.get_env("BUILDAT_TOUCH") == "1",
	-- In a browser (only the web page sets it): the wheel comes in tenths
	-- of a notch there
	web = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil,
	-- Walking's vertical field of view in degrees, the viewer's own and
	-- kept on this client (user)
	walk_fov = tonumber(buildat.storage_read("walk_fov") or "") or 80,
	-- How fast the mouse turns the view, in percent: walking's look and
	-- the 3D view's orbit (user)
	mouse_sens = tonumber(buildat.storage_read("mouse_sens") or "") or 100,
	-- How much a wheel notch zooms, in percent, and whether the 3D view
	-- zooms toward the cursor rather than along its own direction (user)
	wheel_speed = tonumber(buildat.storage_read("wheel_speed") or "") or 100,
	zoom_to_cursor = buildat.storage_read("zoom_to_cursor") == "1",
	-- The middle drag in 3D moving the camera along the ground (XZ) rather
	-- than across the screen (user), the default; kept on the client
	pan_xz = buildat.storage_read("pan_xz") ~= "0",
	-- How far the 3D view's middle drag moves the camera, in percent of
	-- the point under the pointer following it (user); the plan view's
	-- stays one to one. Kept on the client, so a desktop and a phone each
	-- have their own.
	pan_speed = tonumber(buildat.storage_read("pan_speed") or "") or 100,
	-- The 3D view without the floors above the current one, to see into it
	-- from above (user); kept on the client
	hide_above = buildat.storage_read("hide_above") == "1",
	calib = nil,    -- an image being calibrated: {id, pts, measured}
	yaw = 35, pitch = 40,
	looking = false,
	-- Tool state
	draw = nil,     -- the wall tool's chain: {x, z, ref}
	corners = nil,  -- the room tool's corners so far: {{x, z, ref}, ...}
	typed = "",     -- a length being typed while drawing
	press = nil,    -- a mouse press that may become a drag
	drag = nil,     -- {kind = "node"|"move"|"box"|"footprint", ...}
	-- The select tool's selection: id -> kind ("instance", "wall", "room",
	-- "node"), and the one the panel shows
	sel = {},
	primary = nil,
	-- The face each wall in it was selected by: "left", "right" or "core"
	sel_face = {},
	nodes = {},     -- the node tool's selection: id -> true
	dirty = true,
	-- Real ids of this session's placeholders, as batch results give them
	real = {},
}

--
-- The scene
--
local scene = magic.Scene()
-- Held by the module: a scene nothing refers to is collected, and the
-- viewport drawing it is left with a dangling pointer
M.scene = scene
scene:CreateComponent("Octree")
local debug = scene:CreateComponent("DebugRenderer")

local zone = scene:CreateComponent("Zone")
zone.boundingBox = magic.BoundingBox(magic.Vector3(-1000, -1000, -1000),
		magic.Vector3(1000, 1000, 1000))
zone.ambientColor = magic.Color(0.55, 0.55, 0.58)
zone.fogColor = magic.Color(0.55, 0.62, 0.72)
zone.fogStart = 150
zone.fogEnd = 400

-- The sun, when the plan has it: shadowed, since light that went through
-- the walls would light the rooms as if they had none
local sun_node = scene:CreateChild("Sun")
local sun = sun_node:CreateComponent("Light")
sun.lightType = magic.LIGHT_DIRECTIONAL
sun.brightness = 1.0
sun.castShadows = true
sun.shadowBias = magic.BiasParameters(0.00005, 0.8, 0.002)
sun.shadowCascade = magic.CascadeParameters(8.0, 25.0, 80.0, 0.0, 0.8)
-- A faint unshadowed light from one side, so that the faces of a wall read
-- apart without the sun; it lights nothing that ambient light would not
local fill_node = scene:CreateChild("Fill")
fill_node.direction = magic.Vector3(0.5, -0.6, -0.7)
local fill = fill_node:CreateComponent("Light")
fill.lightType = magic.LIGHT_DIRECTIONAL
fill.brightness = 0.25
-- The lamps' lights, rebuilt with everything else
local lamps_node = scene:CreateChild("Lamps")

-- From the resource cache, which holds them: a Material made in Lua is
-- freed under a geometry still using it
local lit_material = magic.cache:GetResource("Material", "main/palette.xml")
-- A ceiling is seen from above by the sun, from its back: it casts all the
-- same ([FP_DAYLIGHT])
lit_material.shadowCullMode = magic.CULL_NONE
-- The same, for the type previews: its own so the plan's flat look is not
-- theirs
local preview_material = magic.cache:GetResource("Material",
		"main/palette_preview.xml")
local flat_material = magic.cache:GetResource("Material", "main/flat_vcol.xml")
M.shadow_material = magic.cache:GetResource("Material", "main/shadow_only.xml")
local glass_material = magic.cache:GetResource("Material",
		"main/palette_glass.xml")
-- What a Lua wrapper would otherwise free under the engine
M.kept = {}

-- simplified: the two low bits only, which is all a flip holds
local function bit_xor(a, b)
	local r = 0
	for i = 0, 1 do
		local p = 2 ^ i
		if (math.floor(a / p) % 2) ~= (math.floor(b / p) % 2) then
			r = r + p
		end
	end
	return r
end

-- The world is in metres; the plan in millimetres
local function W(mm)
	return mm / 1000
end

local function rgb_color(rgb, f)
	f = f or 1
	return magic.Color(math.floor(rgb / 65536) % 256 / 255 * f,
			math.floor(rgb / 256) % 256 / 255 * f, rgb % 256 / 255 * f)
end

local WHITE = magic.Color(1, 1, 1)
-- A lamp's vertices when it is off: its colour, and no light of its own
local UNLIT = magic.Color(1, 1, 1, 0)

-- A triangle facing n: Urho3D's front faces are clockwise as seen, which in
-- its left-handed space is cross(b - a, c - a) pointing at the viewer
-- The lists tri() gathers into, by the part they are for: a lookup here
-- rather than a field of the part, which an engine geometry would refuse
local TRI_LISTS = {}
local function tri(g, a, b, c, n, col, tint)
	local ux, uy, uz = b.x - a.x, b.y - a.y, b.z - a.z
	local vx, vy, vz = c.x - a.x, c.y - a.y, c.z - a.z
	local cx = uy * vz - uz * vy
	local cy = uz * vx - ux * vz
	local cz = ux * vy - uy * vx
	if cx * n.x + cy * n.y + cz * n.z < 0 then
		b, c = c, b
	end
	-- A number is a palette row, for the palette's shader; a Color is a
	-- flat colour, for the plan view's own
	local row = 0
	if type(col) == "number" then
		row, col = col, tint or WHITE
	end
	-- A list being built (TRI_LISTS, handed to the engine at once by
	-- buildat.set_triangle_geometry): 12 numbers a vertex, no call into the
	-- engine a vertex
	local out = TRI_LISTS[g]
	if out then
		local nx, ny, nz = n.x, n.y, n.z
		local cr, cg, cb, ca = col.r, col.g, col.b, col.a
		-- What of the sky's light this face does not get, which the
		-- texture coordinate's y carries to the shader ([FP_DAYLIGHT]):
		-- the room the face looks into, a little in front of it, or one
		-- value for a part built in its own frame
		local occ = M.tri_occ or 0
		local fn = M.tri_occ_fn
		if fn then
			occ = fn((a.x + b.x + c.x) / 3 + nx * 0.05,
					(a.z + b.z + c.z) / 3 + nz * 0.05)
		end
		local k = #out
		for _, p in ipairs({a, b, c}) do
			out[k + 1], out[k + 2], out[k + 3] = p.x, p.y, p.z
			out[k + 4], out[k + 5], out[k + 6] = nx, ny, nz
			out[k + 7], out[k + 8], out[k + 9], out[k + 10] = cr, cg, cb, ca
			out[k + 11], out[k + 12] = row, occ
			k = k + 12
		end
		return
	end
	-- An engine geometry, a call a vertex (plain {x, y, z} tables made
	-- into the engine's vectors here)
	local uv = magic.Vector2(row, 0)
	local nv = magic.Vector3(n.x, n.y, n.z)
	for _, v in ipairs({a, b, c}) do
		g:DefineVertex(magic.Vector3(v.x, v.y, v.z))
		g:DefineNormal(nv)
		g:DefineColor(col)
		g:DefineTexCoord(uv)
	end
end

-- A point or a direction as tri() takes it: a plain table, which costs
-- nothing to make or read where an engine vector is a sandbox object
local function V3(x, y, z)
	return {x = x, y = y, z = z}
end

-- A flat polygon at height y (mm) facing n, as one geometry
local function flat_polygon(g, pts, y, n, col)
	for _, t in ipairs(geom.triangulate(pts)) do
		local a, b, c = pts[t[1]], pts[t[2]], pts[t[3]]
		tri(g, V3(W(a[1]), W(y), W(a[2])), V3(W(b[1]), W(y), W(b[2])),
				V3(W(c[1]), W(y), W(c[2])), n, col)
	end
end

-- A box of half sizes hx, hy, hz (metres) about the origin, or about
-- (cx, cy, cz)
local function box_geometry(g, hx, hy, hz, col, cx, cy, cz, tint)
	cx, cy, cz = cx or 0, cy or 0, cz or 0
	local function V(x, y, z)
		return V3(cx + x * hx, cy + y * hy, cz + z * hz)
	end
	for _, f in ipairs({{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0},
			{0, 0, 1}, {0, 0, -1}}) do
		local n = V3(f[1], f[2], f[3])
		-- Two axes across the face
		local u = f[1] ~= 0 and {0, 1, 0} or {1, 0, 0}
		local v = f[3] ~= 0 and {0, 1, 0} or {0, 0, 1}
		if f[2] ~= 0 then
			u, v = {1, 0, 0}, {0, 0, 1}
		end
		local function C(a, b)
			return V(f[1] + u[1] * a + v[1] * b, f[2] + u[2] * a + v[2] * b,
					f[3] + u[3] * a + v[3] * b)
		end
		tri(g, C(-1, -1), C(1, -1), C(1, 1), n, col, tint)
		tri(g, C(-1, -1), C(1, 1), C(-1, 1), n, col, tint)
	end
end

local UP, DOWN = magic.Vector3(0, 1, 0), magic.Vector3(0, -1, 0)
-- The same for tri()
M.UP3, M.DOWN3 = V3(0, 1, 0), V3(0, -1, 0)

local ground_node = scene:CreateChild("Ground")
-- The ground: the plain grey, or under PBR the season's colour in its own
-- palette row ([FP_DAYLIGHT]); again when either changes
function M.build_ground()
	if not M.ground_row then
		return
	end
	local pbr = M.pbr_now()
	-- The technical plan look's ground darker than its floors
	local tech = S.view == "2d" and S.plan_look == 2
	local key = tostring(pbr) .. ":" .. tostring(M.ground_row) .. ":" ..
			tostring(tech)
	if key == M.ground_key then
		return
	end
	M.ground_key = key
	local g = ground_node:GetComponent("CustomGeometry") or
			ground_node:CreateComponent("CustomGeometry")
	g:SetNumGeometries(1)
	g:BeginGeometry(0, magic.TRIANGLE_LIST)
	-- Under PBR a disc of 200 m round the camera, whose edge is where the
	-- sky's treeline stands (PhysicalSky.glsl, TREE_DISTANCE): the node
	-- follows the camera (M.apply_daylight), and the lawn's pattern is the
	-- world's, so it stays put
	local r = 200000
	local pts = {{-r, -r}, {r, -r}, {r, r}, {-r, r}}
	if pbr then
		pts = {}
		for i = 1, 96 do
			local a = i / 96 * 2 * math.pi
			pts[i] = {r * math.cos(a), r * math.sin(a)}
		end
	end
	flat_polygon(g, pts, 0, M.UP3,
			pbr and M.ground_row or tech and magic.Color(0.6, 0.6, 0.6) or
			magic.Color(0.85, 0.85, 0.83))
	g:Commit()
	g:SetMaterial(0, lit_material)
end

local walls_node = scene:CreateChild("Walls")
local caps_node = scene:CreateChild("Caps")
-- The ceilings and what is aligned to them, hidden from above
local overhead_node = scene:CreateChild("Overhead")
-- Doors' and windows' own parts: the plan view draws symbols instead
local pieces_node = scene:CreateChild("Pieces")
-- The pictures traced over
local images_node = scene:CreateChild("Images")
-- Each surface's material id, on the surface
local decals_node = scene:CreateChild("Decals")
-- simplified: a material per picture file, and one made in Lua is freed
-- under the geometry using it, so there are eight of them in files and
-- eight pictures at most; the upgrade is the engine keeping what Lua made
local IMAGE_MATERIALS = 8

-- The cameras
local cam2d_node = scene:CreateChild("Camera2D")
local cam2d = cam2d_node:CreateComponent("Camera")
cam2d.orthographic = true
cam2d.nearClip = 0.001
cam2d.farClip = 100
cam2d_node.rotation = magic.Quaternion(90, 0, 0)

local cam3d_node = scene:CreateChild("Camera3D")
local cam3d = cam3d_node:CreateComponent("Camera")
cam3d.nearClip = 0.05
cam3d.farClip = 500
-- Vertical, in degrees; walking has S.walk_fov (set_view)
cam3d.fov = 60

-- A viewport for a view, made new each time: the engine frees one when the
-- viewports it is shown in are replaced, so one kept in Lua to show again
-- would be a dangling pointer. So would a render path.
local function viewport_for(v)
	if v == "2d" then
		return magic.Viewport:new(scene, cam2d)
	end
	local vp = magic.Viewport:new(scene, cam3d)
	-- Deferred, so that a house full of lamps costs a light each rather
	-- than a light for each thing each lights; the plan view stays forward
	local rp = vp.renderPath:Clone()
	-- PBR: in radiance, metered and tone mapped ([FP_DAYLIGHT]), and the
	-- ambient occluded in corners ([FP_AO])
	local pbr = S.lighting ~= "unlit"
	rp:Load(magic.cache:GetResource("XMLFile", pbr and
			"main/deferred_ssao.xml" or "RenderPaths/Deferred.xml"))
	if pbr then
		M.daylight.pbr_render_path(rp)
		-- [FP_WHITE_CONNECT] fp_frame.xml's textures made first: a frame
		-- drawn without one clears its name from the command for good
		-- (Urho3D's View::FindNamedTexture), and the white read from
		-- whatever is bound washes the view out until a reconnect
		M.probes_init()
		M.wb_init()
	end
	vp.renderPath = rp
	return vp
end

--
-- The document, as the editor reads it
--
local function settings()
	return doc.settings().ints
end

-- SNAP_PX and DRAG_PX for a finger ([FP_TOUCH] 4): a pixel is a device's, a fraction of
-- a CSS pixel on a phone, and a finger is broader than a pointer
function M.px(n)
	return S.touch and n * 2 * magic.ui.scale or n
end

-- Layouts ([FP_LAYOUTS]). The current one, S.layout, is edited, and its
-- own coordinates are the scene's: picking, snapping and the tools see only
-- its entities. Every other is drawn where it is relative to it.
-- S.view_layout is the layout whose entities of_type() gives: the current
-- one, but another while rebuild() builds that one
local of_type
do
	local function layout_of(e)
		if e.type == "wall" then
			local n = doc.ents[e.ints.a]
			return n and n.ints.layout
		elseif e.type == "room" then
			local n = doc.ents[e.lists.nodes[1]]
			return n and n.ints.layout
		end
		return e.ints.layout
	end

	local LAYERED = {node = true, wall = true, room = true, instance = true,
		image = true}
	of_type = function(t)
		local all = doc.of_type(t)
		if not LAYERED[t] then
			return all
		end
		local out = {}
		for _, e in ipairs(all) do
			if layout_of(e) == S.view_layout then
				out[#out + 1] = e
			end
		end
		return out
	end
end

local place = {parts = {}, areas = {}}
-- The current layout's fields, making the first one current when the
-- current one is gone
function place.current()
	local e = S.layout and doc.ents[S.layout]
	if not e or e.type ~= "layout" then
		e = doc.of_type("layout")[1]
		S.layout = e and e.id
	end
	doc.layout = S.layout
	S.view_layout = S.layout
	return e and e.ints or {x = 0, y = 0, z = 0, yaw = 0}
end

-- The world's own placement
place.WORLD = {x = 0, y = 0, z = 0, yaw = 0}
-- Where the frame of a placement l ({x, y, z, yaw}: layout fields, mm and
-- millidegrees) is in the frame of c: {x, y, z} mm and a yaw in degrees
function place.rel(l, c)
	local x, y, z = geom.unrot(l.x - c.x, l.y - c.y, l.z - c.z, 0, c.yaw / 1000,
			0)
	return {x = x, y = y, z = z, yaw = (l.yaw - c.yaw) / 1000}
end
-- A point of the frame r places, in the frame it is placed in, and back
function place.point(r, x, y, z)
	local px, py, pz = geom.rot(x, y, z, 0, r.yaw, 0)
	return px + r.x, py + r.y, pz + r.z
end
function place.unpoint(r, x, y, z)
	return geom.unrot(x - r.x, y - r.y, z - r.z, 0, r.yaw, 0)
end
-- Presence goes in the world's coordinates, and comes to where it is in
-- the current layout's: back = true for that way
function place.presence(p, back)
	local r = place.rel(place.current(), place.WORLD)
	local f = back and place.unpoint or place.point
	local q = {}
	for k, v in pairs(p) do
		q[k] = v
	end
	local _
	q.cx, _, q.cz = f(r, p.cx, 0, p.cz)
	if p.view >= 1 then
		q.px, q.py, q.pz = f(r, p.px, p.py, p.pz)
	else
		-- The plan view's py is its span
		q.px, _, q.pz = f(r, p.px, 0, p.pz)
	end
	q.yaw = p.yaw + (back and -1 or 1) * r.yaw * 1000
	for _, k in ipairs({"cx", "cz", "px", "py", "pz", "yaw"}) do
		q[k] = math.floor(q[k] + 0.5)
	end
	return q
end
-- Another layout current, the cameras staying where they are in the world
function place.switch(id)
	local e = doc.ents[id]
	if not e or e.type ~= "layout" or id == S.layout then
		return
	end
	local r = place.rel(place.current(), e.ints)
	S.layout = id
	place.current()
	local _
	S.cx, _, S.cz = place.point(r, S.cx, 0, S.cz)
	local x, y, z = place.point(r, S.pos.x * 1000, S.pos.y * 1000, S.pos.z * 1000)
	S.pos = {x = x / 1000, y = y / 1000, z = z / 1000}
	S.yaw = S.yaw + r.yaw
	local w = S.walk
	w.x, w.feet, w.z = place.point(r, w.x, w.feet, w.z)
	S.sel, S.primary, S.nodes, S.sel_face = {}, nil, {}, {}
	S.draw, S.corners, S.drag, S.press = nil
	S.dirty = true
end

-- The grid, the plan's own so it is saved and restored with it. Here, above
-- everything that snaps: a drag of a door along its wall called it from
-- above where it was defined, and got nil
local function grid_step()
	return settings().grid
end

local function node_pos(id)
	local d = S.drag
	if d and d.moved then
		if d.kind == "node" and d.id == id then
			return d.x, d.z
		elseif d.kind == "move" and d.nodes[id] then
			local n = doc.ents[id].ints
			-- A node sliding along the walls it is on (drag_slides)
			local o = d.nd and d.nd[id]
			return n.x + (o and o[1] or d.dx), n.z + (o and o[2] or d.dz)
		end
	end
	-- Where somebody else's drag has it
	local pv = doc.previewed(id)
	if pv and pv.x then
		return pv.x, pv.z
	end
	local n = doc.ents[id]
	if not n then
		return 0, 0
	end
	return n.ints.x, n.ints.z
end

-- A lamp's light colour at a temperature in kelvin
local function kelvin_rgb(k)
	local t = k / 100
	local r, g, b
	if t <= 66 then
		r, g = 255, 99.4708025861 * math.log(t) - 161.1195681661
	else
		r = 329.698727446 * (t - 60) ^ -0.1332047592
		g = 288.1221695283 * (t - 60) ^ -0.0755148492
	end
	if t >= 66 then
		b = 255
	elseif t <= 19 then
		b = 0
	else
		b = 138.5177312231 * math.log(t - 10) - 305.0447927307
	end
	local function c(v)
		return math.floor(math.max(0, math.min(255, v)) + 0.5)
	end
	return c(r) * 65536 + c(g) * 256 + c(b)
end

local function split_rgb(v)
	return math.floor(v / 65536) % 256 / 255, math.floor(v / 256) % 256 / 255,
			v % 256 / 255
end

-- A palette entry's colour as the plan view and the swatches show it: its
-- own colour with its finish applied, without the pattern
local palette_rgb

-- **The technical plan look** (a playtest, 2026-10-06): an object's cap
-- in one mid grey, not its material's colour
function M.cap_rgb(mat)
	return S.plan_look == 2 and 0x9a9a9a or palette_rgb(mat)
end

-- and its faces, which the shader would make as pale as a floor
function M.tech_tint()
	return S.view == "2d" and S.plan_look == 2 and
			magic.Color(0.65, 0.65, 0.65) or nil
end

function palette_rgb(id)
	local e = id and id ~= 0 and doc.ents[id]
	if not e or e.type ~= "palette" then
		return 0xb0b0b0
	end
	local p = e.ints
	if p.kind == 4 then
		return kelvin_rgb(p.temperature)
	end
	local br, bg, bb = split_rgb(p.base)
	local pr, pg, pb = split_rgb(p.color)
	local o = p.opacity / 1000
	local r, g, b
	if p.finish == 0 then
		r, g, b = br * pr, bg * pg, bb * pb
	elseif p.finish == 1 then
		r, g, b = pr, pg, pb
	else
		r, g, b = br + (pr - br) * o, bg + (pg - bg) * o, bb + (pb - bb) * o
	end
	return math.floor(r * 255 + 0.5) * 65536 + math.floor(g * 255 + 0.5) * 256 +
			math.floor(b * 255 + 0.5)
end

-- Whether a lamp instance is lit: a viewer's own switching wins
local function lamp_on(id)
	if S.local_on[id] ~= nil then
		return S.local_on[id]
	end
	return doc.ents[id].ints.on == 1
end

local function is_lamp_entry(id)
	local e = id and id ~= 0 and doc.ents[id]
	return e and e.type == "palette" and e.ints.kind == 4
end

-- Whether an instance gives light: a volume with lamp voxels, or a box of
-- a lamp material
local function is_lamp(id)
	local e = doc.ents[id]
	if not e or e.type ~= "instance" then
		return false
	end
	local def = doc.ents[e.ints.def].ints
	if def.kind == KIND.voxel then
		for _, m in pairs(doc.voxels[e.ints.def] or {}) do
			if is_lamp_entry(m) then
				return true
			end
		end
		return false
	end
	return def.kind == KIND.box and is_lamp_entry(def.mat)
end

-- The palette's rows: 0 is what has no material, 1 the glass a window has
-- when it was given none, and the entries follow in id order
local MATERIAL_KINDS = {[0] = "Drywall", "Wood", "Stone", "Wallpaper", "Lamp",
	"Glass", "Metal", "Tile", "Fabric", "Plaster", "Paneling"}
-- What a type looks like when an entry is switched to it
local KIND_DEFAULTS = {
	[0] = {base = 0xe8e4dc, color2 = 0x404040, scale = 200, roughness = 800,
			specular = 100},
	{base = 0xb07a48, color2 = 0x404040, scale = 300, roughness = 600,
			specular = 250},
	{base = 0x9a968e, color2 = 0x5a5650, scale = 400, roughness = 500,
			specular = 300},
	{base = 0xeadfc8, color2 = 0x8a6a4a, scale = 150, roughness = 900,
			specular = 50},
	{base = 0xffffff, color2 = 0x404040, scale = 200, roughness = 500,
			specular = 0},
	{base = 0xa8c8e0, color2 = 0x404040, scale = 200, roughness = 50,
			specular = 800},
	{base = 0xb8bcc0, color2 = 0x404040, scale = 200, roughness = 300,
			specular = 700},
	{base = 0xf0f0ec, color2 = 0x9a9890, scale = 200, roughness = 200,
			specular = 500},
	{base = 0x6a7a8a, color2 = 0x404040, scale = 3, roughness = 1000,
			specular = 20},
	{base = 0xe4ddd0, color2 = 0x404040, scale = 200, roughness = 900,
			specular = 60},
	-- Paneling: scale is a board's width
	{base = 0xd8b07a, color2 = 0x404040, scale = 120, roughness = 600,
			specular = 250},
}
-- A type as its preview shows it: its defaults over every other field's
local function kind_preview(k)
	local p = {color = 0xffffff, finish = 0, opacity = 500, reflect = 0,
		seed = 0, axis = 0, stagger = 0, grout = 3, temperature = 2700,
		brightness = 1000, speckle = 300, angle = 0, contrast = 1000, polish = 500,
		gap_depth = 15, gap_width = 60, handmade = 0, kind = k}
	for f, v in pairs(KIND_DEFAULTS[k]) do
		p[f] = v
	end
	return p
end

local palette_rows = {}
local palette_key = nil
-- Grows with every new palette texture, whose rows the meshes point at
E.palette_gen = 0

local function row(id)
	return palette_rows[id] or 0
end

-- The palette as the shader reads it: eight texels a row. The small
-- integers are spread out (type * 20, finish * 32, flags * 16) and read back
-- rounded: what the shader reads can be a level off what was written.
--   0: own colour, type          1: paint, finish
--   2: second colour, opacity    3: roughness, specular, reflect, seed low
--   4: log2 of the scale in mm / 16, flags (grain axis + 4 * stagger),
--      seed high, the type's own knob (lamp brightness, grout, speckle)
--   5: paneling's angle, grain contrast, paneling's polish and hand made
--      look
--   6: paneling's gap width and depth in tenths of a mm, high and low bytes
-- Rebuilt only when an entry changes, since each texture is kept.
local function palette_texture()
	local entries = of_type("palette")
	local parts = {}
	for _, e in ipairs(entries) do
		for k, v in pairs(e.ints) do
			parts[#parts + 1] = e.id .. k .. v
		end
	end
	table.sort(parts)
	-- and the ground's colour of the season, its row the last
	local ground, ground_mode = M.ground_rgb()
	local key = table.concat(parts, ",") .. ";" .. ground
	if key == palette_key then
		return
	end
	palette_key = key
	palette_rows = {}
	-- The two rows of nothing, a preview's for each type, the entries, then
	-- the ground's ([FP_DAYLIGHT])
	local n = #entries + 2 + #MATERIAL_KINDS + 1 + 1
	M.ground_row = n - 1
	local image = magic.Image:new()
	assert(image:SetSize(8, n, 4), "Image:SetSize")
	local function put(x, y, rgb, a)
		local r, g, b = split_rgb(rgb)
		image:SetPixel(x, y, magic.Color(r, g, b, a))
	end
	local function px(x, y, r, g, b, a)
		image:SetPixel(x, y, magic.Color(r, g, b, a))
	end
	-- The two rows of nothing: a flat grey, and a pale glass
	put(0, 0, 0xb0b0b0, 0)
	put(1, 0, 0xffffff, 0)
	put(2, 0, 0x404040, 1)
	px(3, 0, 0.9, 0.05, 0, 0)
	px(4, 0, 0.5, 0, 0, 0)
	put(0, 1, 0xa8c8e0, 5 * 20 / 255)
	put(1, 1, 0xffffff, 0)
	put(2, 1, 0x404040, 0.3)
	px(3, 1, 0.1, 0.8, 0.5, 0)
	px(4, 1, 0.5, 0, 0, 0)
	local function put_row(y, p)
		local base = p.kind == 4 and kelvin_rgb(p.temperature) or p.base
		put(0, y, base, p.kind * 20 / 255)
		put(1, y, p.color, p.finish * 32 / 255)
		put(2, y, p.color2, p.opacity / 1000)
		px(3, y, p.roughness / 1000, p.specular / 1000, p.reflect / 1000,
				(p.seed % 256) / 255)
		local knob = 0
		if p.kind == 4 then
			-- 0 to 1000 %, as its square root for the steps
			knob = math.sqrt(p.brightness / 10000)
		elseif p.kind == 7 then
			knob = math.min(1, p.grout / p.scale * 4)
		elseif p.kind == 9 then
			knob = p.speckle / 1000
		end
		px(4, y, math.log(p.scale) / math.log(2) / 16,
				(p.axis + 4 * p.stagger) * 16 / 255, math.floor(p.seed / 256) / 255,
				knob)
		-- Wood's grain contrast, paneling's angle, polish and hand made look
		px(5, y, p.angle / 180, p.contrast / 3000, p.polish / 1000,
				p.handmade / 1000)
		-- Paneling's gap width and depth, 16 bits each
		px(6, y, math.floor(p.gap_width / 256) / 255, (p.gap_width % 256) / 255,
				math.floor(p.gap_depth / 256) / 255, (p.gap_depth % 256) / 255)
	end
	for k = 0, #MATERIAL_KINDS do
		put_row(2 + k, kind_preview(k))
	end
	for i, e in ipairs(entries) do
		palette_rows[e.id] = i + 2 + #MATERIAL_KINDS
		put_row(i + 2 + #MATERIAL_KINDS, e.ints)
	end
	-- The ground: the shader's own type 11, grass or snow in its own
	-- colour; the knob is green 0, dry 0.5, snow 1
	put(0, M.ground_row, ground, 11 * 20 / 255)
	put(1, M.ground_row, 0xffffff, 0)
	put(2, M.ground_row, 0x404040, 1)
	px(3, M.ground_row, 1, 0, 0, 0)
	px(4, M.ground_row, 0.5, 0, 0, ((ground_mode or 1) - 1) / 2)
	local texture = magic.Texture2D:new()
	-- One level: a smaller one would average the rows' knobs together
	texture:SetNumLevels(1)
	assert(texture:SetData(image), "Texture2D:SetData")
	texture.filterMode = magic.FILTER_NEAREST
	M.kept[#M.kept + 1] = texture
	M.kept[#M.kept + 1] = image
	-- The one that is on the materials, for a new GL context to be given
	-- again (the ScreenMode handler below)
	M.palette_upload = {texture = texture, image = image}
	for _, m in ipairs({lit_material, glass_material, preview_material}) do
		m:SetTexture(magic.TU_DIFFUSE, texture)
		m:SetShaderParameter("PaletteRows", n)
	end
	E.palette_gen = E.palette_gen + 1
end

-- The types' previews ([FP_TYPES]): a quad of each, a metre square, side
-- by side in a scene of their own, drawn once into a texture PREVIEW_PX
-- high and PREVIEW_PX a type wide. The quads point at the preview rows of
-- the palette texture, so they are the shader's own look and follow it.
local PREVIEW_PX = 64
local function kind_previews()
	if M.previews then
		return M.previews.texture
	end
	local scene = magic.Scene.new()
	scene:CreateComponent("Octree")
	local zone = scene:CreateChild("zone"):CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-100, 100)
	zone.ambientColor = magic.Color(0.45, 0.45, 0.47)
	local light_node = scene:CreateChild("light")
	light_node.direction = magic.Vector3(0.3, -0.5, 1)
	local light = light_node:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.color = magic.Color(0.8, 0.78, 0.74)
	local count = #MATERIAL_KINDS + 1
	local g = scene:CreateChild("quads"):CreateComponent("CustomGeometry")
	g:SetNumGeometries(1)
	g:BeginGeometry(0, magic.TRIANGLE_LIST)
	local n = magic.Vector3(0, 0, -1)
	for k = 0, count - 1 do
		local x0, x1 = k * 1.0, k * 1.0 + 1.0
		local function V(x, y) return magic.Vector3(x, y, 0) end
		tri(g, V(x0, 0), V(x1, 0), V(x1, 1), n, 2 + k)
		tri(g, V(x0, 0), V(x1, 1), V(x0, 1), n, 2 + k)
	end
	g:Commit()
	g:SetMaterial(0, preview_material)
	local cam_node = scene:CreateChild("camera")
	local camera = cam_node:CreateComponent("Camera")
	camera.orthographic = true
	camera.orthoSize = 1.0
	cam_node.position = magic.Vector3(count / 2, 0.5, -5)
	local texture = magic.render_scene_to_texture(scene, cam_node,
			PREVIEW_PX * count, PREVIEW_PX)
	-- Kept: the scene goes when nothing holds it
	M.previews = {scene = scene, texture = texture}
	return texture
end

-- **A new GL context** (user: F11 on native lost every material): what is
-- written from Lua and not loaded from a file is not brought back by Urho,
-- so the palette's pixels go back on and the types' previews are drawn
-- again when next asked for. extensions/launch_world's handler is the model.
magic.SubscribeToEvent("ScreenMode", function()
	local pu = M.palette_upload
	if pu then
		pu.texture:SetData(pu.image)
	end
	M.previews = nil
	log:info("screen mode changed: the palette texture goes back on")
end)

-- The walls with their ends looked up, their outlines, the rooms with
-- their corners counter-clockwise, and the instances placed; rebuild()
-- fills them
E.outlines = {}
E.wall_data = {}
E.room_data = {}
E.inst_data = {}
-- The scene nodes rebuild() made, for the next one to remove
E.built = {}
-- What a walker bumps into: {pts, y0, y1}, footprints and their heights
E.solids = {}
-- The pictures, as rebuild() placed them: id -> {foot}
E.image_data = {}

-- A wall's height, and a hanging one's, go by the plan's ceiling, never
-- a room's: a wall is between rooms whose ceilings may differ (user,
-- 2026-10-02: no corner cases), where an object hangs from its room's
-- (M.ceiling_at)
local function wall_span(w)
	local ceiling = settings().ceiling
	local h = w.height > 0 and math.min(w.height, ceiling) or ceiling
	if w.hang == 1 then
		return ceiling - h, ceiling
	end
	return 0, h
end

-- The wall between two nodes, and whether it runs u -> v
local function wall_between(u, v)
	for id, w in pairs(E.wall_data) do
		if w.a_node == u and w.b_node == v then
			return id, true
		elseif w.a_node == v and w.b_node == u then
			return id, false
		end
	end
	return nil
end

local function room_ceiling(e)
	return e.ints.ceiling > 0 and e.ints.ceiling or settings().ceiling
end
-- **The ceiling over a point** (user, 2026-10-02: what hung from the
-- ceiling hung from the plan's, not its room's): the smallest room of the
-- layout being looked at that the point is in, else the plan's. From the
-- rooms themselves, as it is wanted before their data is built.
function M.ceiling_at(x, z)
	local best, area = nil, math.huge
	for _, e in ipairs(of_type("room")) do
		local pts = {}
		for _, n in ipairs(e.lists.nodes) do
			local nx, nz = node_pos(n)
			pts[#pts + 1] = {nx, nz}
		end
		if #pts >= 3 and geom.point_in_polygon(x, z, pts) then
			local a = math.abs(geom.area(pts))
			if a < area then
				best, area = e, a
			end
		end
	end
	return best and room_ceiling(best) or settings().ceiling
end

-- [FP_NET_WALLS] A wall hung from the ceiling with its bottom this high
-- or more over the floor (the plan's ceiling less its height) leaves the
-- floor under it
local NET_CLEAR = 1600
-- The inset polygon less the outlines (E.outlines) of every wall that
-- stands on the floor or hangs lower than NET_CLEAR and whose box meets
-- it; one on the room's own edge is outside the inset polygon already
local function net_area(inner)
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	for _, p in ipairs(inner) do
		x0, z0 = math.min(x0, p[1]), math.min(z0, p[2])
		x1, z1 = math.max(x1, p[1]), math.max(z1, p[2])
	end
	local feet = {}
	for id, o in pairs(E.outlines) do
		local e = doc.ents[id]
		if e and (wall_span(e.ints)) < NET_CLEAR then
			local a, b, c, d = math.huge, math.huge, -math.huge, -math.huge
			for _, p in ipairs(o.pts) do
				a, b = math.min(a, p[1]), math.min(b, p[2])
				c, d = math.max(c, p[1]), math.max(d, p[2])
			end
			if a < x1 and c > x0 and b < z1 and d > z0 then
				feet[#feet + 1] = o.pts
			end
		end
	end
	return geom.net_area(inner, feet)
end

local function build_room_data()
	E.room_data = {}
	for _, e in ipairs(of_type("room")) do
		local pts, ids = {}, {}
		for _, n in ipairs(e.lists.nodes) do
			local x, z = node_pos(n)
			pts[#pts + 1] = {x, z}
			ids[#ids + 1] = n
		end
		if not geom.is_ccw(pts) then
			local rp, ri = {}, {}
			for i = #pts, 1, -1 do
				rp[#rp + 1] = pts[i]
				ri[#ri + 1] = ids[i]
			end
			pts, ids = rp, ri
		end
		-- The net floor: each edge moved in to the face of the wall on it
		local offsets = {}
		for i = 1, #ids do
			local wid, forward = wall_between(ids[i], ids[i % #ids + 1])
			offsets[i] = 0
			if wid then
				local w = E.wall_data[wid]
				local lo, ro = geom.offsets(w.thickness, w.justify, w.shift)
				-- The room is left of its counter-clockwise edges
				offsets[i] = forward and lo or ro
			end
		end
		local inner = geom.inset(pts, offsets)
		E.room_data[e.id] = {pts = pts, ids = ids, inner = inner,
				gross = geom.area(pts), net = net_area(inner)}
	end
end

-- The smallest room the point is in
local function room_at(x, z)
	local best, ba = nil, math.huge
	for id, r in pairs(E.room_data) do
		if r.gross < ba and geom.point_in_polygon(x, z, r.pts) then
			best, ba = id, r.gross
		end
	end
	return best
end

local function copy_fields(p)
	local f = {}
	for k, v in pairs(p) do
		f[k] = v
	end
	return f
end

-- A wall's frame: its a end, its direction u and left normal n, how far
-- its faces are from its line, its length and the yaw that turns +X to u
local function wall_frame(id)
	local w = E.wall_data[id]
	if not w then
		return nil
	end
	local l = geom.len(w.bx - w.ax, w.bz - w.az)
	if l == 0 then
		return nil
	end
	local ux, uz = (w.bx - w.ax) / l, (w.bz - w.az) / l
	local lo, ro = geom.offsets(w.thickness, w.justify, w.shift)
	return {ax = w.ax, az = w.az, ux = ux, uz = uz, nx = -uz, nz = ux,
			lo = lo, ro = ro, len = l, yaw = math.deg(math.atan2(-uz, ux))}
end

-- An instance placed: its centre, rotation and extents in mm. The 90
-- degree pitch and roll swap the definition's axes; the yaw turns the
-- footprint, which is ex by ez in the yawed frame.
-- A volume's voxels' extent in cells: {x0, y0, z0, x1, y1, z1}, or nil
-- when it has none
local function voxel_bounds(def)
	local b = nil
	for key in pairs(doc.voxels[def] or {}) do
		local x, y, z = doc.voxel_cell(key)
		if not b then
			b = {x, y, z, x, y, z}
		else
			b[1], b[2], b[3] = math.min(b[1], x), math.min(b[2], y), math.min(b[3], z)
			b[4], b[5], b[6] = math.max(b[4], x), math.max(b[5], y), math.max(b[6], z)
		end
	end
	return b
end

-- **[FP_VOXEL_ALONE] A volume's size as it stands**: the box of its cells'
-- corners turned by its pitch, yaw and roll, {x0, y0, z0, x1, y1, z1} in
-- the layout's mm, and its cells in its own axes; nil with no voxels
function M.voxel_size_box(id)
	local e = doc.ents[id]
	local it = E.inst_data[id]
	local b = e and voxel_bounds(e.ints.def)
	if not b or not it then
		return nil
	end
	local sz = doc.ents[e.ints.def].ints.voxel_size
	local box = {math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge}
	for _, cx in ipairs({b[1] * sz, (b[4] + 1) * sz}) do
		for _, cy in ipairs({b[2] * sz, (b[5] + 1) * sz}) do
			for _, cz in ipairs({b[3] * sz, (b[6] + 1) * sz}) do
				local x, y, z = geom.rot(cx, cy, cz, it.pitch, it.yaw, it.roll)
				local p = {it.ox + x, it.oy + y, it.oz + z}
				for a = 1, 3 do
					box[a] = math.min(box[a], p[a])
					box[a + 3] = math.max(box[a + 3], p[a])
				end
			end
		end
	end
	return box, {b[4] - b[1] + 1, b[5] - b[2] + 1, b[6] - b[3] + 1}
end
function M.voxel_size_text(id)
	local box, n = M.voxel_size_box(id)
	if not box then
		return "Size: no voxels"
	end
	local function r(a)
		return math.floor(box[a + 3] - box[a] + 0.5)
	end
	return string.format("Size %d x %d x %d mm (%d x %d x %d voxels)", r(1),
			r(2), r(3), n[1], n[2], n[3])
end

-- Whether anything is selected that the movement keys would move: the
-- Nodes tool's nodes, else the selection
function M.selected_any()
	return next(S.tool == "node" and S.nodes or S.sel) ~= nil
end

-- **An opening keeps its place in the world when its wall's ends move**
-- (a playtest, 2026-10-06): it keeps its distance from the end that
-- stayed. With both ends moved by the same, the wall's own move, it goes
-- with the wall. With both moved apart, its old place is projected onto
-- the new line. Clamped into the wall.
-- simplified: only while a drag here or a preview of another's moves the
-- ends, and the drag's end sends the result; a node's X or Z typed in its
-- panel moves the openings with the a end as before
function M.kept_along(along, host, w)
	local wd = E.wall_data[host]
	local a, b = wd and doc.ents[wd.a_node], wd and doc.ents[wd.b_node]
	if not (a and b) then
		return along
	end
	local ax0, az0, bx0, bz0 = a.ints.x, a.ints.z, b.ints.x, b.ints.z
	local dax, daz, dbx, dbz = wd.ax - ax0, wd.az - az0, wd.bx - bx0, wd.bz - bz0
	local am, bm = dax ~= 0 or daz ~= 0, dbx ~= 0 or dbz ~= 0
	if (not am and not bm) or (dax == dbx and daz == dbz) then
		return along
	end
	local l = geom.len(wd.bx - wd.ax, wd.bz - wd.az)
	local l0 = geom.len(bx0 - ax0, bz0 - az0)
	if l == 0 or l0 == 0 then
		return along
	end
	local t
	if not am then
		t = along
	elseif not bm then
		t = l - (l0 - along)
	else
		local px, pz = ax0 + (bx0 - ax0) * along / l0, az0 + (bz0 - az0) * along / l0
		t = ((px - wd.ax) * (wd.bx - wd.ax) + (pz - wd.az) * (wd.bz - wd.az)) / l
	end
	local h = math.min(w / 2, l / 2)
	return math.max(h, math.min(l - h, t))
end

-- The rebuild ([FP_EDITOR_MODULES]): what it reads of this file
E.FRAME_W, E.IMAGE_MATERIALS, E.KIND, E.LEAF_GAP = FRAME_W, IMAGE_MATERIALS, KIND, LEAF_GAP
E.LEAF_T, E.M, E.S, E.TRI_LISTS = LEAF_T, M, S, TRI_LISTS
E.UNLIT, E.UP, E.V3, E.W = UNLIT, UP, V3, W
E.WHITE, E.box_geometry, E.build_room_data, E.caps_node = WHITE, box_geometry, build_room_data, caps_node
E.copy_fields, E.decals_node, E.fill, E.flat_material = copy_fields, decals_node, fill, flat_material
E.flat_polygon, E.geom, E.glass_material, E.grid_step = flat_polygon, geom, glass_material, grid_step
E.ground_node, E.images_node, E.is_lamp_entry, E.kelvin_rgb = ground_node, images_node, is_lamp_entry, kelvin_rgb
E.lamp_on, E.lamps_node, E.lit_material, E.log = lamp_on, lamps_node, lit_material, log
E.magic, E.node_pos, E.of_type, E.overhead_node = magic, node_pos, of_type, overhead_node
E.palette_texture, E.pieces_node, E.place, E.rgb_color = palette_texture, pieces_node, place, rgb_color
E.room_at, E.room_ceiling, E.row, E.scene = room_at, room_ceiling, row, scene
E.settings, E.sun, E.sun_node, E.tri = settings, sun, sun_node, tri
E.voxel_bounds, E.wall_between, E.wall_frame, E.wall_span = voxel_bounds, wall_between, wall_frame, wall_span
E.walls_node, E.zone = walls_node, zone
load("rebuild.lua")(E)
local rebuild, instances_of, voxel_meshes, open_amount = E.rebuild,
		E.instances_of, E.voxel_meshes, E.open_amount

-- Picking and snapping ([FP_EDITOR_MODULES]): what it reads of this file
E.ANGLE_STEPS, E.FRAME_W, E.KIND, E.M = ANGLE_STEPS, FRAME_W, KIND, M
E.S, E.SNAP_PX, E.W, E.cam3d = S, SNAP_PX, W, cam3d
E.geom, E.grid_step, E.is_lamp, E.magic = geom, grid_step, is_lamp, magic
E.node_pos, E.of_type, E.open_amount, E.room_at = node_pos, of_type, open_amount, room_at
E.room_ceiling, E.wall_between, E.wall_span = room_ceiling, wall_between, wall_span
load("pick.lua")(E)
local screen_size, mm_per_px, cursor_ray, ray_at_height = E.screen_size, E.mm_per_px, E.cursor_ray, E.ray_at_height
local cursor_floor, snap_radius, angle_step, nearest_node = E.cursor_floor, E.snap_radius, E.angle_step, E.nearest_node
local pick_surface, voxel_ray, snapped_point, wall_gaps = E.pick_surface, E.voxel_ray, E.snapped_point, E.wall_gaps

local real_id, send, default_material, add_wall, add_room, add_box, voxel_target, voxel_column
local voxel_edit, add_hosted, copy_selected, unlink, merge_ops, delete_selected, moved_by, apply_material, rotate_selection
do
	--
	-- Batches
	--
	-- A batch being built: its ops, and the room corner lists it has changed so
	-- far, which go out as one set per room at the end
	local function new_batch()
		return {ops = {}, lists = {}, split = {}, pairs = {}}
	end

	-- The two node ids of an edge, in either order, as one key
	local function pair_key(u, v)
		return math.min(u, v) .. ":" .. math.max(u, v)
	end

	local function add_op(b, op, ent)
		b.ops[#b.ops + 1] = {op = op, ent = ent}
	end

	local function room_list(b, id)
		if not b.lists[id] then
			local l = {}
			for i, n in ipairs(doc.ents[id].lists.nodes) do
				l[i] = n
			end
			b.lists[id] = l
		end
		return b.lists[id]
	end

	local function finish_batch(b)
		for id, l in pairs(b.lists) do
			if doc.ents[id] then
				add_op(b, "set", {id = id, lists = {nodes = l}})
			end
		end
		return b.ops
	end

	real_id = function(id)
		if id and id < 0 then
			return S.real[id]
		end
		return id
	end

	send = function(ops, done, apply)
		doc.send(ops, function(err, placeholders)
			for ph, id in pairs(placeholders) do
				S.real[ph] = id
			end
			if err ~= "" then
				doc.notice("Refused: " .. err)
			end
			if done then
				done(err)
			end
		end, nil, apply)
	end

	local function wall_fields(w)
		return {thickness = w.thickness, justify = w.justify, shift = w.shift,
				height = w.height,
				hang = w.hang, mat_left = w.mat_left, mat_right = w.mat_right,
				mat_core = w.mat_core}
	end

	-- The ops that give a point a node: an existing one, a new one on an edge,
	-- or a new one. A new node on an edge splits the wall on it and joins
	-- every room with that edge, so neighbours keep sharing their corners.
	-- Returns the node's id (maybe a placeholder), or nil when it cannot.
	local function node_for(b, x, z, ref)
		if ref and ref.node then
			return real_id(ref.node)
		end
		local ph = doc.placeholder()
		add_op(b, "create", {id = ph, type = "node",
				ints = {x = math.floor(x + 0.5), z = math.floor(z + 0.5)}})
		local e = ref and ref.edge
		if not e then
			return ph
		end
		if e.wall and doc.ents[e.wall] then
			if b.split[e.wall] then
				-- The second split of one wall in a batch would work from the
				-- first's stale end
				return nil
			end
			b.split[e.wall] = true
			-- The wall keeps a->node and a copy of it takes node->b
			local w = doc.ents[e.wall].ints
			add_op(b, "set", {id = e.wall, ints = {b = ph}})
			local f = wall_fields(w)
			f.a, f.b = ph, w.b
			local half = doc.placeholder()
			add_op(b, "create", {id = half, type = "wall", ints = f})
			-- What is in the wall past the split goes with the second half
			for _, inst in ipairs(of_type("instance")) do
				if inst.ints.host == e.wall and inst.ints.along > ref.t then
					add_op(b, "set", {id = inst.id, ints = {host = half,
							along = inst.ints.along - ref.t}})
				end
			end
			b.pairs[pair_key(w.a, ph)] = true
			b.pairs[pair_key(ph, w.b)] = true
		end
		for _, room in ipairs(of_type("room")) do
			local l = room_list(b, room.id)
			for i = 1, #l do
				local j = i % #l + 1
				if (l[i] == e.u and l[j] == e.v) or (l[i] == e.v and l[j] == e.u) then
					table.insert(l, i + 1, ph)
					break
				end
			end
		end
		return ph
	end

	default_material = function()
		if S.material and doc.ents[S.material] then
			return S.material
		end
		local p = of_type("palette")[1]
		return p and p.id or 0
	end

	-- The material a new wall face gets: the most common among the faces
	-- already facing the room it faces, else the one picked
	local function face_material(x, z)
		local room = room_at(x, z)
		if not room then
			return default_material()
		end
		local count, best, bn = {}, nil, 0
		for id, w in pairs(E.wall_data) do
			local l = geom.len(w.bx - w.ax, w.bz - w.az)
			if l > 0 then
				local mx, mz = (w.ax + w.bx) / 2, (w.az + w.bz) / 2
				local nx, nz = -(w.bz - w.az) / l, (w.bx - w.ax) / l
				local e = doc.ents[id].ints
				local d = w.thickness + 20
				for _, side in ipairs({{1, e.mat_left}, {-1, e.mat_right}}) do
					if side[2] ~= 0 and room_at(mx + nx * d * side[1],
							mz + nz * d * side[1]) == room then
						count[side[2]] = (count[side[2]] or 0) + 1
						if count[side[2]] > bn then
							best, bn = side[2], count[side[2]]
						end
					end
				end
			end
		end
		return best or default_material()
	end

	-- A new wall's ops between two node ids at the given points
	local function wall_op(b, a, ax, az, bnode, bx, bz)
		local l = geom.len(bx - ax, bz - az)
		local nx, nz = -(bz - az) / l, (bx - ax) / l
		local mx, mz = (ax + bx) / 2, (az + bz) / 2
		local d = S.thickness + 20
		local ph = doc.placeholder()
		add_op(b, "create", {id = ph, type = "wall", ints = {
				a = a, b = bnode, thickness = S.thickness, justify = S.justify,
				shift = S.shift,
				height = S.height, hang = S.hang,
				mat_left = face_material(mx + nx * d, mz + nz * d),
				mat_right = face_material(mx - nx * d, mz - nz * d)}})
		return ph
	end

	-- **What was put in is what is selected**, as a door already was: its
	-- panel is then its own, and an edit there goes to Select (user)
	local function select_placed(ph, kind)
		return function(err)
			if err == "" and S.real[ph] then
				S.sel, S.sel_face = {[S.real[ph]] = kind}, {}
				S.primary = S.real[ph]
				M.refresh_panels()
			end
		end
	end

	-- **A node put into an edge** (user: a room drawn with three corners
	-- made four): the wall on it split and every room along it given the
	-- corner, as a wall drawn from there does, and the node selected to be
	-- dragged. Returns whether it did.
	function M.insert_node(x, z, ref)
		if not (ref and ref.edge) then
			return false
		end
		local b = new_batch()
		local ph = node_for(b, x, z, ref)
		if not ph then
			return false
		end
		send(finish_batch(b), function(err)
			if err == "" and S.real[ph] then
				S.nodes = {[S.real[ph]] = true}
				M.refresh_panels()
			end
		end)
		return true
	end

	add_wall = function(from, x, z, ref)
		local fe, te = from.ref and from.ref.edge, ref and ref.edge
		if fe and te and fe.u == te.u and fe.v == te.v then
			doc.notice("Both ends on one edge: nothing to draw")
			return false
		end
		if from.ref and ref and from.ref.node and from.ref.node == ref.node then
			return false
		end
		if geom.len(x - from.x, z - from.z) < 1 then
			return false
		end
		local b = new_batch()
		local a = node_for(b, from.x, from.z, from.ref)
		local bn = node_for(b, x, z, ref)
		if not a or not bn then
			return false
		end
		local ph = wall_op(b, a, from.x, from.z, bn, x, z)
		send(finish_batch(b), select_placed(ph, "wall"))
		-- The chain goes on from the end, which is now a node
		S.draw = {x = x, z = z, ref = {node = bn}}
		return true
	end

	-- The room tool's corners, as a room and (if asked) walls on its edges
	add_room = function(corners)
		if #corners < 3 then
			return
		end
		local b = new_batch()
		local ids = {}
		for i, c in ipairs(corners) do
			ids[i] = node_for(b, c.x, c.z, c.ref)
			if not ids[i] then
				doc.notice("Two corners on one wall: split it first")
				return
			end
		end
		local ph = doc.placeholder()
		local mat = default_material()
		add_op(b, "create", {id = ph, type = "room", ints = {mat_floor = mat,
				mat_ceiling = mat}, strs = {name = "room " ..
				(#of_type("room") + 1)}, lists = {nodes = ids}})
		if S.room_walls then
			for i = 1, #ids do
				local j = i % #ids + 1
				local exists = b.pairs[pair_key(ids[i], ids[j])] or
						(ids[i] > 0 and ids[j] > 0 and wall_between(ids[i], ids[j]))
				if not exists then
					wall_op(b, ids[i], corners[i].x, corners[i].z, ids[j],
							corners[j].x, corners[j].z)
				end
			end
		end
		-- The lamp at the middle, when the middle is in the room (not
		-- always so for an L)
		if S.room_lamp then
			local pts = {}
			for i, c in ipairs(corners) do
				pts[i] = {c.x, c.z}
			end
			local cx, cz = geom.centroid(pts)
			if geom.point_in_polygon(cx, cz, pts) then
				M.plafond_ops(b.ops, cx, cz)
			end
		end
		local selected = select_placed(ph, "room")
		send(finish_batch(b), function(err)
			selected(err)
			-- The 3D view, while it is not looked at, above the new room and
			-- looking down at it (user: it began where nothing was)
			if err == "" and S.view == "2d" then
				M.look_at_corners(corners)
			end
		end)
	end

	-- The 3D camera south of the points' middle and above, looking down at
	-- 60 degrees from far enough to see them all
	function M.look_at_corners(corners)
		local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
		for _, c in ipairs(corners) do
			x0, z0 = math.min(x0, c.x), math.min(z0, c.z)
			x1, z1 = math.max(x1, c.x), math.max(z1, c.z)
		end
		local size = W(math.max(x1 - x0, z1 - z0, 1000))
		local dist = size / (2 * math.tan(math.rad(cam3d.fov) / 2)) * 2 + 1
		S.yaw, S.pitch = 0, 60
		local fx, fy, fz = geom.rot(0, 0, 1, S.pitch, S.yaw, 0)
		S.pos = {x = W((x0 + x1) / 2) - fx * dist, y = W(1200) - fy * dist,
				z = W((z0 + z1) / 2) - fz * dist}
	end

	-- **Splitting a room and combining two** ([FP_ROOM_SPLIT], user
	-- 2026-10-01), by two corners: a room is a list of nodes, and the walls
	-- and what is in them are their own and stay as they are. A corner may
	-- also be a node on one of the room's edges, which the room then gets.

	-- Where node n is in a room's list: its index, or the edge it lies on
	-- (after which it would go), or nil
	local function room_place(list, n)
		for i, m in ipairs(list) do
			if m == n then
				return i, false
			end
		end
		local ne = doc.ents[n]
		if not ne then
			return nil
		end
		for i = 1, #list do
			local u, v = doc.ents[list[i]], doc.ents[list[i % #list + 1]]
			if u and v then
				local _, _, t, d = geom.nearest_on_segment(ne.ints.x, ne.ints.z,
						u.ints.x, u.ints.z, v.ints.x, v.ints.z)
				if d < 2 and t > 0 and t < 1 then
					return i, true
				end
			end
		end
		return nil
	end

	-- The room's list with a and b in it, and their indices; nil when a
	-- corner is not the room's
	local function with_corners(room, a, b)
		local list = {}
		for i, n in ipairs(room.lists.nodes) do
			list[i] = n
		end
		for _, n in ipairs({a, b}) do
			local i, edge = room_place(list, n)
			if not i then
				return nil
			end
			if edge then
				table.insert(list, i + 1, n)
			end
		end
		local ia, ib
		for i, n in ipairs(list) do
			if n == a then ia = i end
			if n == b then ib = i end
		end
		return list, ia, ib
	end

	-- list[from], list[from + 1], ... list[to], round the end
	local function arc(list, from, to)
		local out, i = {}, from
		while true do
			out[#out + 1] = list[i]
			if i == to then
				return out
			end
			i = i % #list + 1
		end
	end

	local function pts_of(ids)
		local pts = {}
		for i, n in ipairs(ids) do
			local e = doc.ents[n].ints
			pts[i] = {e.x, e.z}
		end
		return pts
	end

	-- Whether segments p-q and r-s cross other than at their ends
	local function crosses(p, q, r, s2)
		local function side(a, b, c)
			return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
		end
		local d1, d2 = side(p, q, r), side(p, q, s2)
		local d3, d4 = side(r, s2, p), side(r, s2, q)
		return d1 * d2 < 0 and d3 * d4 < 0
	end

	-- The room split along a-b: nil and why, or the two lists
	function M.split_lists(room, a, b)
		local list, ia, ib = with_corners(room, a, b)
		if not list then
			return nil, "Both corners must be on the room"
		end
		local n = #list
		if ia % n + 1 == ib or ib % n + 1 == ia then
			return nil, "Those corners are the ends of one edge"
		end
		local pts = pts_of(list)
		local pa, pb = pts[ia], pts[ib]
		local mid = {(pa[1] + pb[1]) / 2, (pa[2] + pb[2]) / 2}
		if not geom.point_in_polygon(mid[1], mid[2], pts) then
			return nil, "The line between the corners goes outside the room"
		end
		for i = 1, n do
			if crosses(pa, pb, pts[i], pts[i % n + 1]) then
				return nil, "The line between the corners crosses the room's edge"
			end
		end
		return arc(list, ia, ib), arc(list, ib, ia)
	end

	function M.split_room(id, a, b)
		local room = doc.ents[id]
		local l1, l2 = M.split_lists(room, a, b)
		if not l1 then
			doc.notice(l2)
			return
		end
		-- The bigger keeps the room; the other is a copy of its settings
		if math.abs(geom.area(pts_of(l1))) < math.abs(geom.area(pts_of(l2))) then
			l1, l2 = l2, l1
		end
		local bt = new_batch()
		add_op(bt, "set", {id = id, lists = {nodes = l1}})
		local ph = doc.placeholder()
		local ints = {}
		for k, v in pairs(room.ints) do
			ints[k] = v
		end
		add_op(bt, "create", {id = ph, type = "room", ints = ints,
				strs = {name = room.strs.name .. " 2"}, lists = {nodes = l2}})
		-- A wall on the new edge, as a drawn room gets them
		if S.room_walls and not wall_between(a, b) then
			local ea, eb = doc.ents[a].ints, doc.ents[b].ints
			wall_op(bt, a, ea.x, ea.z, b, eb.x, eb.z)
		end
		send(bt.ops, function(err)
			if err == "" then
				doc.notice("Split " .. room.strs.name .. " in two")
			end
		end)
	end

	-- Rooms ra and rb joined through the edge from a to b that they share:
	-- nil and why, or the joined list
	function M.combine_list(ra, rb, a, b)
		local la, ia, ib = with_corners(ra, a, b)
		local lb, ja, jb = with_corners(rb, a, b)
		if not la or not lb then
			return nil, "Both corners must be on both rooms"
		end
		local want = math.abs(geom.area(pts_of(la))) +
				math.abs(geom.area(pts_of(lb)))
		-- Each room's way from b to a that is not the shared edge, and the
		-- other's from a to b: the one of the four whose area is the two's
		for _, pa in ipairs({arc(la, ib, ia), arc(la, ia, ib)}) do
			if pa[1] ~= b then
				local r = {}
				for i = #pa, 1, -1 do r[#r + 1] = pa[i] end
				pa = r
			end
			for _, pb in ipairs({arc(lb, ja, jb), arc(lb, jb, ja)}) do
				if pb[1] ~= a then
					local r = {}
					for i = #pb, 1, -1 do r[#r + 1] = pb[i] end
					pb = r
				end
				local out = {}
				for i = 1, #pa - 1 do out[#out + 1] = pa[i] end
				for i = 1, #pb - 1 do out[#out + 1] = pb[i] end
				if #out >= 3 and math.abs(math.abs(geom.area(pts_of(out))) -
						want) <= 0.001 * want + 1 then
					return out
				end
			end
		end
		return nil, "Those corners are not an edge the two rooms share"
	end

	function M.combine_rooms(ida, idb, a, b)
		local ra, rb = doc.ents[ida], doc.ents[idb]
		local list, why = M.combine_list(ra, rb, a, b)
		if not list then
			doc.notice(why)
			return
		end
		-- The bigger's settings and name
		if math.abs(geom.area(pts_of(ra.lists.nodes))) <
				math.abs(geom.area(pts_of(rb.lists.nodes))) then
			ida, idb, ra, rb = idb, ida, rb, ra
		end
		local bt = new_batch()
		add_op(bt, "set", {id = ida, lists = {nodes = list}})
		add_op(bt, "delete", {id = idb})
		send(bt.ops, select_placed(ida, "room"))
		doc.notice("Joined " .. rb.strs.name .. " into " .. ra.strs.name)
	end

	-- What two selected corners can do to the rooms: {{text, fn}, ...}
	function M.room_actions(a, b)
		local out, both = {}, {}
		for _, r in ipairs(of_type("room")) do
			if with_corners(r, a, b) then
				both[#both + 1] = r
				if M.split_lists(r, a, b) then
					out[#out + 1] = {"Split " .. r.strs.name .. " here", function()
						M.split_room(r.id, a, b)
					end}
				end
			end
		end
		for i = 1, #both do
			for j = i + 1, #both do
				local ra, rb = both[i], both[j]
				if M.combine_list(ra, rb, a, b) then
					out[#out + 1] = {"Combine " .. ra.strs.name .. " and " ..
							rb.strs.name, function()
						M.combine_rooms(ra.id, rb.id, a, b)
					end}
				end
			end
		end
		return out
	end

	-- **A plafond lamp** (user): a square 250 by 250, 50 thick, on the
	-- ceiling at (x, z), of the palette's lamp material -- a new "Lamp"
	-- entry when it has none -- and lit, as an instance starts. Its ops
	-- go onto ops, the instance's last.
	function M.plafond_ops(ops, x, z)
		local mat = nil
		for _, p in ipairs(of_type("palette")) do
			if p.ints.kind == 4 then
				mat = p.id
				break
			end
		end
		if not mat then
			mat = doc.placeholder()
			local k = KIND_DEFAULTS[4]
			ops[#ops + 1] = {op = "create", ent = {id = mat, type = "palette",
					ints = {kind = 4, base = k.base, color2 = k.color2,
					scale = k.scale, roughness = k.roughness,
					specular = k.specular}, strs = {name = "Lamp"}}}
		end
		local def = doc.placeholder()
		ops[#ops + 1] = {op = "create", ent = {id = def, type = "definition",
				ints = {kind = KIND.box, w = 250, h = 50, d = 250, mat = mat}}}
		ops[#ops + 1] = {op = "create", ent = {id = doc.placeholder(),
				type = "instance", ints = {def = def, x = math.floor(x + 0.5),
				z = math.floor(z + 0.5), align = 1, offset = 0}}}
	end

	-- A box drawn: a definition of that size and an instance of it. Stairs
	-- the same, given their depth or taking it from their steps (d nil).
	add_box = function(x, z, w, d)
		local def = doc.placeholder()
		local inst = doc.placeholder()
		local ints = {kind = KIND.box, w = w, h = S.box.h, d = d,
				mat = default_material()}
		if S.shape == "stairs" then
			local st = S.stairs
			local h = st.h > 0 and st.h or settings().floor_step
			local n = math.max(1, math.min(200, math.floor(h / st.riser + 0.5)))
			ints.kind, ints.h, ints.steps = KIND.stairs, h, n
			ints.d = d or n * st.tread
		end
		local ops = {}
		local align, offset = S.box.align, S.box.offset
		if S.shape == "lamp" then
			M.plafond_ops(ops, x, z)
			send(ops, select_placed(ops[#ops].ent.id, "instance"))
			return
		end
		ops[#ops + 1] = {op = "create", ent = {id = def, type = "definition",
				ints = ints}}
		ops[#ops + 1] = {op = "create", ent = {id = inst, type = "instance",
				ints = {def = def, x = math.floor(x + 0.5),
				z = math.floor(z + 0.5), align = align, offset = offset}}}
		send(ops, select_placed(inst, "instance"))
	end

	-- The voxel volume the voxel tool works on: the one selected
	voxel_target = function()
		local id = S.primary
		if id and S.sel[id] == "instance" and E.inst_data[id] and E.inst_data[id].voxel then
			return id
		end
		return nil
	end

	local function in_range(c)
		for a = 1, 3 do
			if c[a] < -128 or c[a] > 127 then
				return false
			end
		end
		return true
	end

	-- A new voxel volume at the point, of one voxel, selected
	local function add_volume(x, z, offset)
		local def = doc.placeholder()
		local inst = doc.placeholder()
		send({
			{op = "create", ent = {id = def, type = "definition", ints = {
					kind = KIND.voxel, voxel_size = S.voxel_size}}},
			{op = "create", ent = {id = inst, type = "instance", ints = {def = def,
					x = math.floor(x + 0.5), z = math.floor(z + 0.5),
					offset = offset or 0}}},
		}, function(err)
			if err == "" then
				doc.set_voxels(S.real[def], {[doc.voxel_key(0, 0, 0)] =
						default_material()})
				S.sel = {[S.real[inst]] = "instance"}
				S.primary = S.real[inst]
				M.refresh_panels()
			end
		end)
	end

	-- From above: the column of a volume's cells under the cursor, and the
	-- top voxel in it (nil when it is empty)
	voxel_column = function(id)
		local it = E.inst_data[id]
		local x, z = cursor_floor()
		if not x then
			return nil
		end
		local lx, _, lz = geom.unrot(x - it.ox, 0, z - it.oz, it.pitch, it.yaw,
				it.roll)
		local cx, cz = math.floor(lx / it.size), math.floor(lz / it.size)
		local top = nil
		for key in pairs(doc.voxels[doc.ents[id].ints.def] or {}) do
			local vx, vy, vz = doc.voxel_cell(key)
			if vx == cx and vz == cz and (not top or vy > top) then
				top = vy
			end
		end
		return cx, cz, top
	end

	-- The voxel tool at the cursor: place a voxel against what is under it,
	-- or dig the one under it, or (paint, Shift) give the one it would dig
	-- the palette entry
	-- **The cell a press or a release points at** in the selected volume
	-- (user): mode "dig" and "paint" an existing voxel, "place" the empty
	-- one on it -- or, off every voxel, the floor's cell beside the volume
	-- (within a cell of what it has, or anywhere when it has none): a volume
	-- that is being edited is not added to far from itself. nil: nothing.
	function M.voxel_cell(mode)
		local id = voxel_target()
		if not id then
			return nil
		end
		if S.view == "2d" then
			local cx, cz, top = voxel_column(id)
			if not cx then
				return nil
			end
			if mode == "place" then
				local c = {cx, top and top + 1 or 0, cz}
				return in_range(c) and id or nil, c
			end
			return top and id or nil, top and {cx, top, cz}
		end
		local hit, place = voxel_ray(id)
		if mode ~= "place" then
			return hit and id or nil, hit
		end
		if not place or not in_range(place) then
			return nil
		end
		if not hit then
			local b = voxel_bounds(doc.ents[id].ints.def)
			if b and (place[1] < b[1] - 1 or place[1] > b[4] + 1 or
					place[3] < b[3] - 1 or place[3] > b[6] + 1) then
				return nil
			end
		end
		return id, place
	end

	-- Where a held box would end: the cell pointed at, or for a fill off
	-- the volume's voxels the imaginary one in the plane facing the view
	function M.voxel_box_end(vb)
		local id, c = M.voxel_cell(vb.mode)
		if vb.mode == "place" and S.view ~= "2d" then
			local hit = voxel_ray(vb.id)
			if not hit then
				local pc = M.voxel_plane_cell(vb.id, vb.a)
				if pc then
					return vb.id, pc
				end
			end
		end
		return id, c
	end

	-- A box of cells from a to b, both in: emptied, painted where there are
	-- voxels, or filled where there are none
	local MAX_BOX = 100000
	function M.voxel_box(mode, id, a, b)
		if not doc.can("edit") then
			doc.notice("Viewing only: no edit privilege")
			return
		end
		local def = doc.ents[id].ints.def
		local vox = doc.voxels[def] or {}
		local lo = {math.min(a[1], b[1]), math.min(a[2], b[2]), math.min(a[3], b[3])}
		local hi = {math.max(a[1], b[1]), math.max(a[2], b[2]), math.max(a[3], b[3])}
		if (hi[1] - lo[1] + 1) * (hi[2] - lo[2] + 1) * (hi[3] - lo[3] + 1) > MAX_BOX then
			doc.notice("A box of more than " .. MAX_BOX .. " voxels: make it smaller")
			return
		end
		local mat = default_material()
		local sets = {}
		for x = lo[1], hi[1] do
			for y = lo[2], hi[2] do
				for z = lo[3], hi[3] do
					local key = doc.voxel_key(x, y, z)
					if mode == "dig" then
						if vox[key] then sets[key] = 0 end
					elseif mode == "paint" then
						if vox[key] then sets[key] = mat end
					elseif not vox[key] then
						sets[key] = mat
					end
				end
			end
		end
		if next(sets) then
			doc.set_voxels(def, sets)
		end
	end

	voxel_edit = function(dig, paint)
		if not doc.can("edit") then
			doc.notice("Viewing only: no edit privilege")
			return
		end
		local id = voxel_target()
		if not id then
			local x, z = snapped_point(nil)
			-- In 3D, on the top of what the crosshair is on (user: a lamp on
			-- a cupboard), a new volume starts there
			local offset = nil
			if S.view ~= "2d" then
				local s = pick_surface(true)
				local it = s and s.kind == "instance" and E.inst_data[s.id]
				if it and s.t then
					local o, d = cursor_ray()
					local y = (o.y + d.y * s.t) * 1000
					if d.y < 0 and math.abs(y - it.y1) < 20 then
						x, z = (o.x + d.x * s.t) * 1000, (o.z + d.z * s.t) * 1000
						offset = math.floor(it.y1 + 0.5)
					end
				end
			end
			if x and not dig and not paint then
				add_volume(x, z, offset)
			else
				doc.notice("Select a voxel volume, or place one on the floor")
			end
			return
		end
		local def = doc.ents[id].ints.def
		local sets = {}
		if S.view == "2d" then
			local cx, cz, top = voxel_column(id)
			if not cx then
				return
			end
			if dig or paint then
				if top then
					sets[doc.voxel_key(cx, top, cz)] = paint and default_material() or 0
				end
			else
				local c = {cx, top and top + 1 or 0, cz}
				if in_range(c) then
					sets[doc.voxel_key(c[1], c[2], c[3])] = default_material()
				end
			end
		else
			local ok, c = M.voxel_cell(paint and "paint" or dig and "dig" or "place")
			if ok then
				sets[doc.voxel_key(c[1], c[2], c[3])] = (dig and not paint) and 0 or
						default_material()
			end
		end
		if next(sets) then
			doc.set_voxels(def, sets)
		end
	end

	-- A door, window or opening put in a wall where the point is along it
	add_hosted = function(wall, x, z, side)
		local f = wall_frame(wall)
		if not f then
			return
		end
		local kind = S.hosted
		local d = HOSTED[kind]
		local along = geom.snap((x - f.ax) * f.ux + (z - f.az) * f.uz, grid_step())
		along = math.max(d.w / 2, math.min(f.len - d.w / 2, along))
		local def = doc.placeholder()
		local inst = doc.placeholder()
		local mat = default_material()
		send({
			{op = "create", ent = {id = def, type = "definition", ints = {
					kind = kind, w = d.w, h = d.h, mat = mat, mat_leaf = mat,
					trim = kind == KIND.opening and 0 or 70}}},
			{op = "create", ent = {id = inst, type = "instance",
					ints = {def = def, host = wall, along = math.floor(along + 0.5),
					sill = d.sill, flip = side == "right" and 1 or 0}}},
		})
	end

	-- Copies of the selected instances next to them: linked ones share the
	-- definition, the others get a copy of it
	-- A copied definition's voxels go to the copy once it exists
	-- simplified: a second message after the copy's batch, so undoing the copy
	-- is two steps
	local function copy_voxels(copies)
		for _, c in ipairs(copies) do
			local vox = doc.voxels[c.from]
			if vox and next(vox) and S.real[c.to] then
				local sets = {}
				for k, v in pairs(vox) do
					sets[k] = v
				end
				doc.set_voxels(S.real[c.to], sets)
			end
		end
	end

	copy_selected = function(linked)
		-- **A door, window or opening alone is copied into a wall of the
		-- user's choosing** (user: a linked clone of a window did not fit
		-- on its wall, and was wanted on another one anyway): the next
		-- click on a wall puts it there (M.place_copy), Esc gives up
		local only, n = nil, 0
		for id, kind in pairs(S.sel) do
			only, n = id, n + 1
		end
		local oe = only and doc.ents[only]
		if n == 1 and S.sel[only] == "instance" and oe and oe.ints.host ~= 0 then
			S.place_copy = {id = only, linked = linked}
			S.dirty = true
			return
		end
		local ops, new, voxel_copies = {}, {}, {}
		for id, kind in pairs(S.sel) do
			if kind == "instance" then
				local i = copy_fields(doc.ents[id].ints)
				if not linked then
					local def = doc.placeholder()
					ops[#ops + 1] = {op = "create", ent = {id = def,
							type = "definition", ints = copy_fields(
							doc.ents[i.def].ints)}}
					voxel_copies[#voxel_copies + 1] = {to = def, from = i.def}
					i.def = def
				end
				if i.host ~= 0 then
					-- Along the wall, next to it
					i.along = i.along + doc.ents[doc.ents[id].ints.def].ints.w + 100
				else
					i.x = i.x + COPY_OFFSET
					i.z = i.z - COPY_OFFSET
				end
				local ph = doc.placeholder()
				new[#new + 1] = ph
				ops[#ops + 1] = {op = "create", ent = {id = ph, type = "instance",
						ints = i}}
			end
		end
		if #ops == 0 then
			doc.notice("Copies are of objects; select one")
			return
		end
		send(ops, function(err)
			if err == "" then
				copy_voxels(voxel_copies)
				-- The copies are what is selected now
				S.sel = {}
				for _, ph in ipairs(new) do
					S.sel[S.real[ph]] = "instance"
					S.primary = S.real[ph]
				end
				M.refresh_panels()
			end
		end)
	end

	-- The copy S.place_copy is for, into this wall under the pointer: along
	-- it where the pointer is, snapped and kept inside it, the rest as the
	-- original has it; a linked one shares its definition
	function M.place_copy(wall, x, z, side)
		local pc = S.place_copy
		S.place_copy = nil
		S.dirty = true
		local src = pc and doc.ents[pc.id]
		local f = wall_frame(wall)
		if not src or not f then
			return
		end
		local i = copy_fields(src.ints)
		local w = doc.ents[i.def].ints.w
		local along = geom.snap((x - f.ax) * f.ux + (z - f.az) * f.uz, grid_step())
		i.along = math.floor(math.max(w / 2, math.min(f.len - w / 2, along)) + 0.5)
		i.host = wall
		local ops = {}
		if not pc.linked then
			local def = doc.placeholder()
			ops[#ops + 1] = {op = "create", ent = {id = def, type = "definition",
					ints = copy_fields(doc.ents[i.def].ints)}}
			i.def = def
		end
		local ph = doc.placeholder()
		ops[#ops + 1] = {op = "create", ent = {id = ph, type = "instance", ints = i}}
		send(ops, function(err)
			if err == "" then
				S.sel = {[S.real[ph]] = "instance"}
				S.primary = S.real[ph]
				M.refresh_panels()
			end
		end)
	end

	unlink = function(id)
		local i = doc.ents[id].ints
		local def = doc.placeholder()
		send({
			{op = "create", ent = {id = def, type = "definition",
					ints = copy_fields(doc.ents[i.def].ints)}},
			{op = "set", ent = {id = id, ints = {def = def}}},
		}, function(err)
			if err == "" then
				copy_voxels({{to = def, from = i.def}})
			end
		end)
	end

	-- Node `from` merged into node `into`: what referred to one refers to the
	-- other, and what that makes degenerate goes
	merge_ops = function(from, into)
		local b = new_batch()
		local ends = {}
		for id, w in pairs(E.wall_data) do
			local a, bb = w.a_node, w.b_node
			if a == from then a = into end
			if bb == from then bb = into end
			local key = pair_key(a, bb)
			if a == bb or ends[key] then
				add_op(b, "delete", {id = id})
			elseif a ~= w.a_node or bb ~= w.b_node then
				add_op(b, "set", {id = id, ints = {a = a, b = bb}})
			end
			if a ~= bb then
				ends[key] = true
			end
		end
		for _, room in ipairs(of_type("room")) do
			local l = room.lists.nodes
			local has_from, has_into = false, false
			for _, n in ipairs(l) do
				has_from = has_from or n == from
				has_into = has_into or n == into
			end
			if has_from then
				local nl = {}
				for _, n in ipairs(l) do
					if n ~= from then
						nl[#nl + 1] = n
					elseif not has_into then
						nl[#nl + 1] = into
					end
				end
				if #nl < 3 then
					add_op(b, "delete", {id = room.id})
				else
					add_op(b, "set", {id = room.id, lists = {nodes = nl}})
				end
			end
		end
		add_op(b, "delete", {id = from})
		return b.ops
	end

	local function unused_nodes(ops, gone_walls)
		local candidates = {}
		for id in pairs(gone_walls) do
			local w = doc.ents[id].ints
			candidates[w.a] = true
			candidates[w.b] = true
		end
		for n in pairs(candidates) do
			local used = false
			for id, w in pairs(E.wall_data) do
				if not gone_walls[id] and (w.a_node == n or w.b_node == n) then
					used = true
				end
			end
			for _, room in ipairs(of_type("room")) do
				for _, rn in ipairs(room.lists.nodes) do
					used = used or rn == n
				end
			end
			if not used then
				ops[#ops + 1] = {op = "delete", ent = {id = n}}
			end
		end
	end

	local function delete_nodes(ops, ids)
		for id in pairs(ids) do
			if doc.ents[id] then
				ops[#ops + 1] = {op = "delete", ent = {id = id}}
			end
		end
		-- A room left with corners but no floor goes too; the server only
		-- knows to remove one left with fewer than three
		for _, room in ipairs(of_type("room")) do
			local pts = {}
			for _, n in ipairs(room.lists.nodes) do
				if not ids[n] then
					pts[#pts + 1] = {node_pos(n)}
				end
			end
			if #pts >= 3 and #pts < #room.lists.nodes and
					geom.area(pts) < 10000 then
				ops[#ops + 1] = {op = "delete", ent = {id = room.id}}
			end
		end
	end

	delete_selected = function()
		local ops = {}
		if S.tool == "node" then
			delete_nodes(ops, S.nodes)
			S.nodes = {}
		else
			local walls, nodes, defs = {}, {}, {}
			for id, kind in pairs(S.sel) do
				if doc.ents[id] then
					if kind == "node" then
						nodes[id] = true
					else
						ops[#ops + 1] = {op = "delete", ent = {id = id}}
					end
					if kind == "wall" then
						walls[id] = true
					elseif kind == "instance" then
						local def = doc.ents[id].ints.def
						defs[def] = (defs[def] or 0) + 1
					end
				end
			end
			delete_nodes(ops, nodes)
			-- Their nodes go with the walls where nothing else holds them, and
			-- a definition with its last instance
			unused_nodes(ops, walls)
			for def, n in pairs(defs) do
				if instances_of(def) == n then
					ops[#ops + 1] = {op = "delete", ent = {id = def}}
				end
			end
			S.sel = {}
			S.primary = nil
		end
		if #ops > 0 then
			send(ops)
		end
	end

	-- What a selection moves: instances by their position, walls and rooms by
	-- their nodes
	moved_by = function(sel)
		local inst, nodes = {}, {}
		for id, kind in pairs(sel) do
			local e = doc.ents[id]
			if e then
				if kind == "instance" or kind == "image" then
					inst[id] = true
				elseif kind == "node" then
					nodes[id] = true
				elseif kind == "wall" then
					nodes[e.ints.a] = true
					nodes[e.ints.b] = true
				elseif kind == "room" then
					for _, n in ipairs(e.lists.nodes) do
						nodes[n] = true
					end
				end
			end
		end
		return inst, nodes
	end

	-- The selection turned by deg about its centre, counter-clockwise as seen
	-- from above: positions about the centre, and each instance's own yaw.
	-- A turn asked for while one is on its way waits for it, since it is
	-- computed from where the first leaves things.
	local turning, turn_queued = false, 0
	local function send_turn(deg)
		local inst, nodes = moved_by(S.sel)
		local sx, sz, n = 0, 0, 0
		for id in pairs(inst) do
			local c = E.inst_data[id] or doc.ents[id].ints
			sx, sz, n = sx + c.x, sz + c.z, n + 1
		end
		for id in pairs(nodes) do
			local x, z = node_pos(id)
			sx, sz, n = sx + x, sz + z, n + 1
		end
		if n == 0 then
			return
		end
		sx, sz = sx / n, sz / n
		local c, s = math.cos(math.rad(deg)), math.sin(math.rad(deg))
		local function turn(x, z)
			local dx, dz = x - sx, z - sz
			return math.floor(sx + dx * c - dz * s + 0.5),
					math.floor(sz + dx * s + dz * c + 0.5)
		end
		local ops = {}
		for id in pairs(inst) do
			local i = doc.ents[id].ints
			-- What is in a wall turns with the wall, not by itself
			if i.host == 0 then
				local x, z = turn(i.x, i.z)
				-- Yaw grows turning right, which from above is clockwise
				local yaw = (i.yaw - math.floor(deg * 1000 + 0.5)) % 360000
				ops[#ops + 1] = {op = "set", ent = {id = id, ints = {x = x, z = z,
						yaw = yaw}}}
			end
		end
		for id in pairs(nodes) do
			local p = doc.ents[id].ints
			local x, z = turn(p.x, p.z)
			ops[#ops + 1] = {op = "set", ent = {id = id, ints = {x = x, z = z}}}
		end
		turning = true
		send(ops, function()
			turning = false
			if turn_queued ~= 0 then
				local q = turn_queued
				turn_queued = 0
				rotate_selection(q)
			end
		end)
	end

	rotate_selection = function(deg)
		if turning then
			turn_queued = turn_queued + deg
		else
			send_turn(deg)
		end
	end

	-- The palette entry picked, on everything selected
	-- both: a wall's two faces; else only the face it was selected by, and
	-- a wall with none (selected by a box) is left alone
	apply_material = function(both)
		local mat = default_material()
		local ops = {}
		local faceless = 0
		for id, kind in pairs(S.sel) do
			local e = doc.ents[id]
			if e and kind == "instance" then
				-- A door's or a window's part, when one was picked in its panel
				local part = S.sel_face[id]
				ops[#ops + 1] = {op = "set", ent = {id = e.ints.def,
						ints = {[DOOR_PARTS[part] and part or "mat"] = mat}}}
			elseif e and kind == "wall" then
				local face = S.sel_face[id]
				local ints = both == true and {mat_left = mat, mat_right = mat} or
						face == "left" and {mat_left = mat} or
						face == "right" and {mat_right = mat} or
						face == "core" and {mat_core = mat} or nil
				if ints then
					ops[#ops + 1] = {op = "set", ent = {id = id, ints = ints}}
				else
					faceless = faceless + 1
				end
			elseif e and kind == "room" then
				ops[#ops + 1] = {op = "set", ent = {id = id, ints =
						S.sel_face[id] == "ceiling" and {mat_ceiling = mat} or
						{mat_floor = mat}}}
			end
		end
		if faceless > 0 then
			doc.notice(faceless .. " walls were selected by a box, not by a face: "
					.. "click a wall on the face to paint")
		end
		if #ops > 0 then
			send(ops)
		end
	end

end

-- The next of GRID_STEPS after the plan's
local function next_grid()
	local g = grid_step()
	local n = GRID_STEPS[1]
	for i, v in ipairs(GRID_STEPS) do
		if v == g then
			n = GRID_STEPS[i % #GRID_STEPS + 1]
		end
	end
	send({{op = "set", ent = {id = doc.settings().id, ints = {grid = n}}}})
	return n
end

-- The grid and the angle steps as the settings page says them (user: out
-- of the toolbar and into Settings, with their keys); on M, since this
-- file is at Lua's 200 locals
function M.grid_text(g)
	return g < 10 and g .. " mm" or (g / 10) .. " cm"
end
function M.angle_text(i)
	local a = ANGLE_STEPS[i]
	return a and a .. " deg" or "free"
end

--
-- The panels
--
local toolbar, props, palette_win
local label_nodes = {}

local refresh_panels

-- Walking and the voxel tool in 3D have two levels ([FP_ESC]): the pointer,
-- for the panels, and above it the crosshair, which holds the mouse
-- Luanti's way -- the view turns with it and the crosshair picks. A click on
-- the view goes up into the crosshair and Esc comes back down.
local function crosshair_view()
	-- A touchscreen has no pointer to hold: walking is by the stick and a
	-- drag ([FP_TOUCH] 3), and the voxel tool by taps
	-- The voxel tool works at the pointer in 3D (user: a touchscreen has
	-- no crosshair, and it needs none)
	return not S.touch and S.view == "walk"
end

local function update_capture()
	local want = S.crosshair and crosshair_view() and not S.paused or false
	if want ~= (S.captured or false) then
		S.captured = want
		S.looking = want
		magic.input:SetMouseMode(want and magic.MM_RELATIVE or magic.MM_ABSOLUTE)
	end
end

-- **The free camera and the walker are each their own** (user,
-- 2026-10-01: a walking shot could not be taken again from the same place
-- after an edit in 3D): M.update keeps the camera of the view in use --
-- S.cam3d, and the walker's look in S.walk -- and a view gone back to
-- takes its own again. The walker starts under the free camera the first
-- time, and again by "Walk from here".
local function set_view(v)
	-- Another view than a viewport's is out of it
	if S.vp and v ~= "3d" then
		M.leave_viewport()
	end
	-- 3D (here) from the plan view stays 3D until another view is picked
	if v ~= "3d" then
		S.no_plan_return = nil
	end
	if v == "walk" and S.view ~= "walk" then
		if not S.walk.placed then
			-- On the floor under the camera, or the plan's middle
			if S.view == "3d" then
				local x, z = S.pos.x * 1000, S.pos.z * 1000
				S.walk.x, S.walk.z = x, z
			else
				S.walk.x, S.walk.z = S.cx, S.cz
			end
			S.walk.feet = 0
			S.walk.yaw, S.walk.pitch = S.yaw, 0
			S.walk.placed = true
		end
		S.yaw, S.pitch = S.walk.yaw, S.walk.pitch
	end
	-- A view starts at its pointer, so the view button can go on from it
	if v ~= S.view then
		S.crosshair = false
	end
	S.view = v
	-- Only when it changes: the walk and the free camera share a viewport.
	-- The lighting's HDR frame is for the 3D one under PBR.
	local lighting = v ~= "2d" and S.lighting or "unlit"
	if (v == "2d") ~= (S.shown_2d == true) or not S.shown or
			lighting ~= S.shown_lighting then
		S.shown, S.shown_2d, S.shown_lighting = true, v == "2d", lighting
		magic.renderer.HDRRendering = lighting ~= "unlit"
		magic.set_preferred_viewports({viewport_for(v)})
		S.daylight_key = nil
		-- The lamps' brightness and the ground go with it
		S.dirty = true
	end
	-- The plan view's look: the materials lit or flat, or technical
	local flat = v == "2d" and S.plan_look or 0
	if flat ~= S.shown_look then
		-- The ground's and the objects' caps' colours go with it
		S.shown_look = flat
		S.dirty = true
	end
	lit_material:SetShaderParameter("PlanLook", flat)
	glass_material:SetShaderParameter("PlanLook", flat)
	caps_node.enabled = v == "2d"
	pieces_node.enabled = v ~= "2d"
	update_capture()
	refresh_panels()
end

-- **[FP_VOXEL_ALONE] On its own**: the selected volume the only thing of
-- the plan drawn, ALONE_LIFT over the ground at its own x and z (the view's
-- instance data, rebuild.lua; the document as it is), overcast at noon,
-- in 3D with the camera going round its middle: the movement keys left and
-- right round it and up and down over it (pitch -80..80), ALONE_TURN
-- degrees a second, the wheel and a pinch in and out (its size x 0.6 to
-- x 6). Out of it by the toggle, Escape, another tool or another selection,
-- the view, the camera and the light back as they were.
M.ALONE_TURN = 360
function M.alone_extent()
	local it = S.alone and E.inst_data[S.alone.id]
	return it and math.max(it.ex, it.ey, it.ez, 300) or 1000
end
function M.alone_center()
	local it = E.inst_data[S.alone.id]
	return it and {x = W(it.x), y = W(it.y), z = W(it.z)} or S.pos
end
function M.alone_clamp(dist)
	local s = W(M.alone_extent())
	return math.max(s * 0.6, math.min(s * 6, dist))
end
function M.alone_camera()
	local c = M.alone_center()
	S.pitch = math.max(-80, math.min(80, S.pitch))
	local fx, fy, fz = geom.rot(0, 0, 1, S.pitch, S.yaw, 0)
	local d = S.alone.dist
	S.pos = {x = c.x - fx * d, y = c.y - fy * d, z = c.z - fz * d}
end
function M.enter_alone(id)
	if S.alone or not E.inst_data[id] then
		return
	end
	S.alone = {id = id, prev = {view = S.view, yaw = S.yaw, pitch = S.pitch,
			pos = {x = S.pos.x, y = S.pos.y, z = S.pos.z}}}
	if S.view ~= "3d" then
		set_view("3d")
	end
	S.pitch = 30
	S.daylight_key = nil
	S.dirty = true
end
function M.leave_alone()
	local a = S.alone
	if not a then
		return
	end
	S.alone = nil
	for _, n in ipairs(M.alone_roots()) do
		n:SetDeepEnabled(true)
	end
	place.shown = {}
	if S.view ~= a.prev.view then
		set_view(a.prev.view)
	end
	S.pos, S.yaw, S.pitch = a.prev.pos, a.prev.yaw, a.prev.pitch
	S.daylight_key = nil
	S.dirty = true
	refresh_panels()
	log:info("voxel alone: left")
end
function M.alone_roots()
	return {walls_node, caps_node, overhead_node, pieces_node, images_node,
			decals_node, lamps_node}
end
-- After a rebuild and each frame: everything of the plan hidden (once a
-- rebuild) but the volume's mesh
function M.apply_alone()
	local a = S.alone
	if not a then
		return
	end
	if not a.hidden then
		a.hidden = true
		for _, n in ipairs(M.alone_roots()) do
			n:SetDeepEnabled(false)
		end
	end
	local m = E.voxel_meshes[a.id]
	if m then
		m.node.enabled = true
	end
	if not a.dist then
		a.dist = M.alone_clamp(W(M.alone_extent()) * 2)
	end
	local n = #E.built
	for _ in pairs(E.voxel_meshes) do
		n = n + 1
	end
	if not a.logged then
		a.logged = true
		log:info(string.format("voxel alone: %d, %d nodes hidden", a.id, n - 1))
	end
end

-- A view the user picked: 3D takes its own camera back. (On M: the chunk
-- is at Lua's limit of 200 locals.)
-- "3d_here": 3D from the camera there is -- walking's as it is, the plan
-- view's as a right drag turns it into 3D, looking down -- and from the
-- plan view without the orbit's way back into it (S.no_plan_return), the
-- 3D view's own camera going on from it.
-- "walk_here": walking from what the middle of the screen is on, on this
-- floor: the plan view's middle, or where the camera looks meets the
-- floor (under the camera where it does not); looking the way the camera
-- did, level, or from the plan view or 3D looking straight down, the way
-- the walk looked last. From 3D looking as one walking does, under the
-- camera, looking as it does.
function M.pick_view(v)
	if v == "save" then
		M.save_viewport()
		return
	elseif type(v) == "string" and v:sub(1, 3) == "vp:" then
		M.go_viewport(tonumber(v:sub(4)))
		return
	end
	if v == "3d_here" then
		local from_2d = S.view == "2d"
		if from_2d then
			local d = S.span / (2 * math.tan(math.rad(cam3d.fov) / 2))
			S.pos = {x = W(S.cx), y = W(d), z = W(S.cz)}
			S.yaw, S.pitch = 0, 90
		end
		M.leave_viewport()
		set_view("3d")
		S.no_plan_return = from_2d or nil
		return
	end
	if v == "walk_here" then
		local x, z
		local keep_look = S.view == "2d" or (S.view == "3d" and S.pitch > 80)
		-- From 3D looking as one walking does -- 30 degrees down or less,
		-- or up (user, 2026-10-02): from under the camera, looking as it
		-- does
		local as_walking = S.view == "3d" and S.pitch <= 30
		if S.view == "2d" then
			x, z = S.cx, S.cz
		elseif as_walking then
			x, z = S.pos.x * 1000, S.pos.z * 1000
		else
			local yaw, pitch = math.rad(S.yaw), math.rad(S.pitch)
			local fy = -math.sin(pitch)
			x, z = S.pos.x * 1000, S.pos.z * 1000
			if fy < -1e-3 then
				local t = -S.pos.y / fy
				x = (S.pos.x + math.sin(yaw) * math.cos(pitch) * t) * 1000
				z = (S.pos.z + math.cos(yaw) * math.cos(pitch) * t) * 1000
			end
		end
		S.walk.x, S.walk.z, S.walk.feet = x, z, 0
		if as_walking then
			S.walk.yaw, S.walk.pitch = S.yaw, S.pitch
		elseif not keep_look then
			S.walk.yaw, S.walk.pitch = S.yaw, 0
		end
		S.walk.placed = true
		v = "walk"
		if S.view == "walk" then
			S.yaw, S.pitch = S.walk.yaw, S.walk.pitch
		end
	end
	local was_vp = S.vp
	M.leave_viewport()
	if v == "3d" and (S.view ~= "3d" or was_vp) and S.cam3d then
		local c = S.cam3d
		S.pos = {x = c.x, y = c.y, z = c.z}
		S.yaw, S.pitch = c.yaw, c.pitch
	end
	set_view(v)
end

-- toggle: from the tool's button or key, which, the tool being in use,
-- leaves it for no tool at all (user, 2026-10-02): nothing can then be
-- selected, and what was lets go; Select's filter is as it was when it
-- comes back
-- The tools in their own files ([FP_EDITOR_MODULES]): id -> {label,
-- viewer_ok, clear(), press(), escape() -> true when it took the Esc,
-- guide(g, hl), overlay(thick)}, on the toolbar in tool_order after the
-- built-in ones
E.tools, E.tool_order = {}, {}
local BUILT_IN_TOOLS = {"select", "node", "wall", "room", "box", "hosted",
		"voxel", "paint"}

-- Esc to the tool in use first
local function tool_escape()
	local tl = S.tool and E.tools[S.tool]
	return tl and tl.escape and tl.escape()
end

local function clear_tools()
	for _, tl in pairs(E.tools) do
		if tl.clear then
			tl.clear()
		end
	end
end

local function set_tool(t, toggle)
	if toggle and t == S.tool then
		S.tool = nil
		S.draw, S.corners, S.drag = nil, nil, nil
		clear_tools()
		S.sel, S.sel_face, S.primary, S.nodes = {}, {}, nil, {}
		S.dirty = true
		refresh_panels()
		return
	end
	-- Viewing ([FP_VIEW_EDIT]): only Select, whose clicks show things
	clear_tools()
	local tl = E.tools[t]
	if t ~= "select" and not (tl and tl.viewer_ok) and not doc.can("edit") then
		doc.notice(doc.can("can_edit") and
				"Viewing: switch to Editing in the menu to use that tool" or
				"Viewing only: no edit privilege")
		return
	end
	if t ~= S.tool and S.view == "3d" then
		S.crosshair = false
	end
	-- A placing tool starts with nothing selected, so its panel is the
	-- settings of what it puts in until it has put one in
	if t ~= S.tool and (t == "wall" or t == "room" or t == "box" or
			t == "hosted") then
		S.sel, S.sel_face, S.primary = {}, {}, nil
	end
	S.tool = t
	S.draw = nil
	S.corners = nil
	S.typed = ""
	update_capture()
	refresh_panels()
end

local function build_toolbar()
	if toolbar then
		panel.discard(toolbar)
	end
	-- Rows of buttons, as many as the screen's width needs ([FP_TOUCH] 2);
	-- one on a desktop's. A touchscreen has no keys: no key in the names,
	-- and a Menu button for Esc's pause menu.
	toolbar = panel.window(magic.HA_LEFT, magic.VA_TOP, 8, 8)
	local row, used = panel.row(toolbar), 0
	local room = magic.ui.root.width - 16 - 12
	-- make(parent) makes the button
	local function place(make)
		-- Measured before it is put in a row: a row a button was taken back
		-- out of keeps the width it had with it
		local probe = make(magic.ui.root)
		local w = probe.minWidth + 4
		probe:Remove()
		if used > 0 and used + w > room then
			row, used = panel.row(toolbar), 0
		end
		-- Not stretched to the widest row
		local b = make(row)
		b.maxWidth = b.minWidth
		used = used + w
	end
	local function add(text, key, f, down, min_width)
		if key and not S.touch then
			text = text .. " (" .. key .. ")"
		end
		place(function(parent)
			return panel.button(parent, text, f, down, min_width)
		end)
	end
	-- The pause menu's own button, and on a desktop the key it is on: a
	-- phone has no Esc, and a newcomer does not know it yet (user)
	add("Menu", S.touch and nil or "Esc", function() M.open_pause() end)
	local views = {}
	for i, v in ipairs({"2d", "3d", "walk"}) do
		views[i] = {VIEW_NAMES[v] .. (S.touch and "" or
				" (" .. keys.name("view_" .. v) .. ")"), v}
	end
	-- **From where the view is** (user, 2026-10-02): 3D with this camera,
	-- or walking from what the middle of the screen is on (M.pick_view)
	if S.view ~= "3d" or S.vp then
		views[#views + 1] = {"3D (here)", "3d_here"}
	end
	views[#views + 1] = {"Walk (here)", "walk_here"}
	-- **Viewports** (user, 2026-10-01): saved from 3D or walking by an
	-- editor, gone to by anyone; picked again, or the dropdown opened and
	-- closed, the menus are hidden again
	if S.view ~= "2d" and not S.vp and doc.can("edit") then
		views[#views + 1] = {"Save viewport", "save"}
	end
	for _, e in ipairs(M.viewports()) do
		views[#views + 1] = {e.strs.name, "vp:" .. e.id}
	end
	place(function(parent)
		return panel.dropdown(parent, nil, views,
				S.vp and "vp:" .. S.vp or S.view, M.pick_view, 40, function()
			if S.vp then
				M.hide_ui()
			end
		end)
	end)
	-- The layout edited, and the window that picks another
	local l = S.layout and doc.ents[S.layout]
	add(l and l.strs.name or "Layouts", nil, function()
		S.layouts_open = not S.layouts_open
		log:info("Layouts menu " .. (S.layouts_open and "shown" or "closed"))
		refresh_panels()
	end, S.layouts_open)
	-- Viewing ([FP_VIEW_EDIT]): the tools that only make and change
	-- things are not there
	for _, t in ipairs({{"select", "Select"}, {"node", "Nodes"},
			{"wall", "Wall"}, {"room", "Room"}, {"box", "Object"},
			{"hosted", "Wall items"}, {"voxel", "Voxels"}, {"paint", "Material"}}) do
		if t[1] == "select" or doc.can("edit") then
			add(t[2], keys.name(t[1]), function() set_tool(t[1], true) end,
					S.tool == t[1])
		end
	end
	for _, id in ipairs(E.tool_order) do
		local tl = E.tools[id]
		if tl.viewer_ok or doc.can("edit") then
			add(tl.label, keys.name(id), function() set_tool(id, true) end,
					S.tool == id)
		end
	end
	-- The panels folded away on a narrow screen, opened here
	if panel.narrow() then
		for _, p in ipairs({{"palette", "Palette"}, {"props", "Properties"}}) do
			add(p[2], nil, function()
				panel.toggle_fold(p[1])
				refresh_panels()
			end, not panel.folded(p[1]))
		end
	end
	add("IDs", nil, function()
		S.show_ids = not S.show_ids
		S.dirty = true
		refresh_panels()
	end, S.show_ids)
	-- Viewing with a role that edits: the way to editing, last (user),
	-- where the tools were
	if not doc.can("edit") and doc.can("can_edit") then
		add("Start editing", nil, function() doc.set_editing(true) end)
	end
	-- The panels start under it
	S.panel_y = 8 + toolbar.height + 8
	-- **A touchscreen's keys** ([FP_TOUCH] 4): what Ctrl+Z, Ctrl+Y, Del,
	-- E and Esc do, at the lower right
	if S.touch_bar then
		S.touch_bar:Remove()
		S.touch_bar = nil
	end
	if S.touch then
		local b = panel.window(magic.HA_RIGHT, magic.VA_BOTTOM, -8, -8, true)
		S.touch_bar = b
		if doc.can("edit") then
			panel.button(b, "Undo", function() doc.undo() end)
			panel.button(b, "Redo", function() doc.redo() end)
			panel.button(b, "Delete", function() delete_selected() end)
			-- What Shift does to a wall or room drawn: the angle step
			-- instead of right angles (user)
			panel.button(b, "Angle " .. (S.touch_angle and
					M.angle_text(S.angle) or "90 deg"), function()
				S.touch_angle = not S.touch_angle
				refresh_panels()
			end)
		end
		if S.view == "walk" then
			panel.button(b, "Use", function() M.use() end)
		end
		panel.button(b, "Cancel", function() M.escape() end)
	end
end

local function m2(mm2)
	return string.format("%.2f m2", mm2 / 1e6)
end

local function sel_count()
	local n = 0
	for _ in pairs(S.sel) do
		n = n + 1
	end
	return n
end

-- The room actions of two corners, as buttons, or how to get one
function M.room_buttons(a, b)
	local acts = M.room_actions(a, b)
	for _, act in ipairs(acts) do
		panel.button(props, act[1], act[2])
	end
	if #acts == 0 then
		panel.label(props, "(two corners of a room split it,")
		panel.label(props, " two shared by two rooms join them)")
	end
end

-- What the voxel tool's click does in 3D, for a touchscreen above all,
-- which has no Ctrl or Shift
function M.voxel_mode_dropdown()
	panel.keep(function() return panel.dropdown(props, S.touch and "Tap" or "Click", {
		{"place a voxel", "place"}, {"dig one", "dig"},
		{"paint one", "paint"}}, S.voxel_mode, function(v)
		S.voxel_mode = v
		refresh_panels()
	end) end)
end

-- [FP_VOXEL_ALONE] Editing a volume in the plan or on its own
function M.voxel_alone_dropdown(id)
	panel.keep(function() return panel.dropdown(props, "View", {
		{"In the plan", "plan"}, {"On its own", "alone"}},
		S.alone and "alone" or "plan", function(v)
		if v == "alone" and not S.alone then
			M.enter_alone(id)
		elseif v == "plan" and S.alone then
			M.leave_alone()
		end
		refresh_panels()
	end) end)
end

local function build_props()
	if props then
		panel.discard(props)
	end
	props = panel.window(magic.HA_RIGHT, magic.VA_TOP, -8, S.panel_y or 50)
	if panel.folded("props") then
		props.visible = false
		return
	end
	local sel = S.primary and S.sel[S.primary] and doc.ents[S.primary]
	if S.stair_riser and not (sel and sel.id == S.stair_riser.inst) then
		S.stair_riser = nil
	end
	-- **With no tool, nothing** (user): nothing can be selected
	if not S.tool then
		props.visible = false
		return
	end
	-- **Select's filter, with nothing selected** (M.sel_filter): what is
	-- selected takes the panel over
	if S.tool == "select" and not sel and sel_count() == 0 then
		local f = M.sel_filter()
		local all = true
		for _, k in ipairs(M.SEL_KINDS) do
			all = all and f[k[1]]
		end
		panel.label(props, "Select picks:")
		panel.keep(function()
			panel.check(props, "All", all, function()
				M.set_sel_filter(nil, not all)
			end)
			for _, k in ipairs(M.SEL_KINDS) do
				panel.check(props, k[2], f[k[1]], function()
					M.set_sel_filter(k[1], not f[k[1]])
				end)
			end
		end)
		return
	end
	-- **An edit of what is selected leaves a placing tool for Select**, the
	-- selection kept (user): the next click in the view is then not one
	-- more of what was being edited
	local function editing_selection()
		if sel and (S.tool == "wall" or S.tool == "room" or S.tool == "box" or
				S.tool == "hosted") then
			set_tool("select")
		end
	end
	local function set(id, fields)
		send({{op = "set", ent = {id = id, ints = fields.ints,
				strs = fields.strs}}})
		-- The plan's own settings are not the selection's
		if id ~= doc.settings().id then
			editing_selection()
		end
	end
	local function num(text)
		local v = tonumber(text)
		return v and math.floor(v + 0.5)
	end
	local function int_field(id, label, name, value)
		panel.field(props, label, value, function(t)
			local v = num(t)
			if v then set(id, {ints = {[name] = v}}) end
		end)
	end
	-- **The panel's first line names what is selected and the part it was
	-- picked by** (a playtest, 2026-10-06), in its own colour
	local function heading(t)
		return panel.label(props, t, magic.Color(1.0, 0.75, 0.3))
	end
	local PART_NAMES = {mat = "the frame", mat_leaf = "the leaf",
			mat_glass = "the glass"}
	local count = sel_count()
	if S.tool == "node" then
		local n = 0
		for _ in pairs(S.nodes) do
			n = n + 1
		end
		heading(n .. " nodes selected")
		-- One node's place, to be read off another and typed in (user)
		if n == 1 then
			local id = next(S.nodes)
			local ne = doc.ents[id]
			if ne then
				int_field(id, "X mm", "x", ne.ints.x)
				int_field(id, "Z mm", "z", ne.ints.z)
			end
		end
		if n == 2 then
			local a = next(S.nodes)
			M.room_buttons(a, next(S.nodes, a))
		end
		panel.label(props, "Drag one to move them all;")
		panel.label(props, "drop one on another to merge;")
		panel.label(props, "double click an edge: a node into it")
		if n > 0 then
			panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
		end
	elseif count > 1 then
		heading(count .. " selected")
		-- Two corners: a room split or two combined there
		if count == 2 then
			local a = next(S.sel)
			local b = next(S.sel, a)
			if S.sel[a] == "node" and S.sel[b] == "node" then
				M.room_buttons(a, b)
			end
		end
		panel.button(props, "Turn left (" .. keys.name("turn_left") .. ")",
				function()
			rotate_selection(angle_step())
		end)
		panel.button(props, "Turn right (" .. keys.name("turn_right") .. ")",
				function()
			rotate_selection(-angle_step())
		end)
		panel.button(props, "Copy (Ctrl+D)", function() copy_selected(false) end)
		panel.button(props, "Linked clones (Ctrl+L)", function()
			copy_selected(true)
		end)
		panel.button(props, "Apply the palette entry", apply_material)
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif sel and sel.type == "instance" and sel.ints.host ~= 0 then
		local i = sel.ints
		local p = doc.ents[i.def].ints
		local links = instances_of(i.def)
		local part = PART_NAMES[S.sel_face[sel.id]]
		heading(KIND_NAMES[p.kind] .. " " .. sel.id .. (part and ", " .. part or "") ..
				(links > 1 and ("   linked x" .. links) or ""))
		-- **A window's sizes as its frame's or its glass's** (user): the
		-- frame's are what is stored, and the glass is inset from it by
		-- the frame and the sash on each side (build_hosted's FRAME_W
		-- twice). A double casement's glass is from its one outer edge to
		-- the other, the sashes' middle stiles over it.
		-- The gaps each way to the nearest wall meeting this one, typed to
		-- place it by that edge (a playtest, 2026-10-06)
		local g = M.opening_gaps(sel.id)
		for k = 1, g and 2 or 0 do
			panel.field(props, "Gap " .. k .. " mm",
					math.floor(math.abs(g[k].edge - g[k].face) + 0.5), function(t)
				local v = tonumber(t)
				if v then
					local along = k == 1 and g[1].face + v + g.hw or
							g[2].face - v - g.hw
					set(sel.id, {ints = {along = math.floor(along + 0.5)}})
				end
			end)
		end
		local glass = p.kind == KIND.window and p.measure == 1
		if p.kind == KIND.window then
			panel.dropdown(props, "Sizes of", {{"the frame", 0}, {"the glass", 1}},
					p.measure, function(v)
				set(i.def, {ints = {measure = v}})
			end)
		end
		local inset = glass and 2 * FRAME_W or 0
		local function sized(id, label, name, value, by)
			panel.field(props, label, value - by, function(t)
				local v = num(t)
				if v then set(id, {ints = {[name] = v + by}}) end
			end)
		end
		sized(i.def, "Width mm", "w", p.w, 2 * inset)
		sized(i.def, "Height mm", "h", p.h, 2 * inset)
		sized(sel.id, "Sill mm", "sill", i.sill, -inset)
		int_field(sel.id, "Along mm", "along", i.along)
		if p.kind == KIND.switch then
			panel.label(props, #sel.lists.lamps .. " lamps (E switches them)")
			panel.button(props, S.linking == sel.id and "Done linking" or
					"Link lamps: click them", function()
				S.linking = S.linking ~= sel.id and sel.id or nil
				refresh_panels()
			end, S.linking == sel.id)
			panel.button(props, "Other side of the wall", function()
				set(sel.id, {ints = {flip = bit_xor(i.flip, 1)}})
			end)
		elseif p.kind ~= KIND.opening then
			int_field(i.def, "Trim mm", "trim", p.trim)
			int_field(i.def, "Trim depth mm", "trim_depth", p.trim_depth)
			if p.kind == KIND.door then
				panel.check(props, "Double leaf", p.leaf == 1, function()
					set(i.def, {ints = {leaf = 1 - p.leaf}})
				end)
			else
				panel.dropdown(props, "Opens", {{"fixed", 0}, {"casement", 1},
						{"double casement", 2}}, p.leaf, function(v)
					set(i.def, {ints = {leaf = v}})
				end)
			end
			if p.kind == KIND.door then
				panel.check(props, "Glass pane", p.glazed == 1, function()
					set(i.def, {ints = {glazed = 1 - p.glazed}})
				end)
			end
			local r = panel.row(props)
			panel.button(r, "Other hinge", function()
				set(sel.id, {ints = {flip = bit_xor(i.flip, 1)}})
			end)
			panel.button(r, "Other side", function()
				set(sel.id, {ints = {flip = bit_xor(i.flip, 2)}})
			end)
			-- In degrees, 0 to 170 (user); stored in thousandths of a right
			-- angle, 90 degrees being 1000
			panel.field(props, "Open deg", math.floor(i.open * 0.09 + 0.5),
					function(t)
				local v = tonumber(t)
				if v then
					v = math.max(0, math.min(170, v))
					set(sel.id, {ints = {open = math.min(1889,
							math.floor(v / 0.09 + 0.5))}})
				end
			end)
			if p.kind == KIND.window then
				panel.field(props, "Blinds %", (i.blinds or 0) / 10, function(t)
					local v = tonumber(t)
					if v then
						set(sel.id, {ints = {blinds = math.floor(
								math.max(0, math.min(100, v)) * 10 + 0.5)}})
					end
				end)
			end
			-- The part a palette double click goes on, the palette showing
			-- what it has now; a part with none of its own shows the frame's
			panel.label(props, "Selected part (the palette's double click):")
			local part = DOOR_PARTS[S.sel_face[sel.id]] and S.sel_face[sel.id] or
					"mat"
			local slots = {{"Frame", "mat"}, {"Leaf", "mat_leaf"}}
			if p.kind == KIND.window or p.glazed == 1 then
				slots[3] = {"Glass", "mat_glass"}
			end
			-- Which part's palette entry shows: not an edit
			panel.keep(function() return panel.dropdown(props, "Part", slots,
					part, function(v)
				S.sel_face[sel.id] = v
				editing_selection()
				local m = p[v] ~= 0 and p[v] or p.mat
				if doc.ents[m] then
					S.material = m
				end
				refresh_panels()
			end) end)
		end
		panel.button(props, "Copy (Ctrl+D)", function() copy_selected(false) end)
		panel.button(props, "Linked clone (Ctrl+L)", function()
			copy_selected(true)
		end)
		if links > 1 then
			panel.button(props, "Unlink", function() unlink(sel.id) end)
		end
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif sel and sel.type == "instance" and
			doc.ents[sel.ints.def].ints.kind == KIND.voxel then
		local i = sel.ints
		local p = doc.ents[i.def].ints
		local links = instances_of(i.def)
		local n = 0
		for _ in pairs(doc.voxels[i.def] or {}) do
			n = n + 1
		end
		heading("Voxels " .. sel.id .. ": " .. n .. (links > 1 and
				("   linked x" .. links) or ""))
		int_field(i.def, "Voxel mm", "voxel_size", p.voxel_size)
		panel.label(props, M.voxel_size_text(sel.id))
		int_field(sel.id, "X mm", "x", i.x)
		int_field(sel.id, "Z mm", "z", i.z)
		panel.field(props, "Yaw deg", i.yaw / 1000, function(t)
			local v = tonumber(t)
			if v then
				set(sel.id, {ints = {yaw = math.floor(v * 1000 + 0.5) % 360000}})
			end
		end)
		int_field(sel.id, "Offset mm", "offset", i.offset)
		panel.check(props, "From the ceiling down", i.align == 1, function()
			set(sel.id, {ints = {align = 1 - i.align}})
		end)
		local r = panel.row(props)
		-- The turn most often wanted, as the field's value plus 90 (user)
		panel.button(r, "Yaw +90", function()
			set(sel.id, {ints = {yaw = (i.yaw + 90000) % 360000}})
		end)
		panel.button(r, "Pitch +90", function()
			set(sel.id, {ints = {pitch = (i.pitch + 1) % 4}})
		end)
		panel.button(r, "Roll +90", function()
			set(sel.id, {ints = {roll = (i.roll + 1) % 4}})
		end)
		panel.button(props, "Replace a material...", function()
			S.picker = nil
			S.replace = {def = i.def, to = default_material()}
			refresh_panels()
		end)
		panel.label(props, "Voxel tool (" .. keys.name("voxel") ..
				"): a click places, Ctrl+click")
		panel.label(props, "digs, Shift+click gives a voxel the entry")
		if S.tool == "voxel" then
			M.voxel_mode_dropdown()
			M.voxel_alone_dropdown(sel.id)
		end
		panel.button(props, "Copy (Ctrl+D)", function() copy_selected(false) end)
		panel.button(props, "Linked clone (Ctrl+L)", function()
			copy_selected(true)
		end)
		if links > 1 then
			panel.button(props, "Unlink", function() unlink(sel.id) end)
		end
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif sel and sel.type == "instance" then
		local i = sel.ints
		local def = doc.ents[i.def]
		local p = def.ints
		local links = instances_of(i.def)
		heading(KIND_NAMES[p.kind] .. " " .. sel.id .. (links > 1 and
				("   linked x" .. links) or ""))
		int_field(i.def, "Width mm", "w", p.w)
		if p.kind == KIND.stairs then
			-- **The height keeps the riser, and the steps follow** (user).
			-- The riser is the one before the first height edit, kept while
			-- these stairs stay selected, so that 10 mm at a time adds up
			-- to a step.
			-- simplified: in memory only; a Steps or Riser edit, another
			-- selection or a reload starts from the riser the stairs have
			panel.field(props, "Height mm", p.h, function(t)
				local v = num(t)
				if not v or v <= 0 then
					return
				end
				local r = S.stair_riser
				if not (r and r.inst == sel.id) then
					r = {inst = sel.id, riser = p.h / p.steps}
					S.stair_riser = r
				end
				set(i.def, {ints = {h = v, steps = math.max(1, math.min(200,
						math.floor(v / r.riser + 0.5)))}})
			end)
		else
			int_field(i.def, "Height mm", "h", p.h)
		end
		int_field(i.def, "Depth mm", "d", p.d)
		if p.kind == KIND.stairs then
			-- The riser sets the steps, the height staying; the tread sets
			-- the depth
			panel.field(props, "Steps", p.steps, function(t)
				local v = num(t)
				if v then
					S.stair_riser = nil
					set(i.def, {ints = {steps = v}})
				end
			end)
			panel.field(props, "Riser mm", math.floor(p.h / p.steps * 10 + 0.5) / 10,
					function(t)
				local v = tonumber(t)
				if v and v > 0 then
					S.stair_riser = nil
					set(i.def, {ints = {steps = math.max(1, math.min(200,
							math.floor(p.h / v + 0.5)))}})
				end
			end)
			panel.field(props, "Tread mm", math.floor(p.d / p.steps * 10 + 0.5) / 10,
					function(t)
				local v = tonumber(t)
				if v and v > 0 then
					set(i.def, {ints = {d = math.floor(v * p.steps + 0.5)}})
				end
			end)
			panel.label(props, "Up along its depth (yaw turns it)")
		end
		int_field(sel.id, "X mm", "x", i.x)
		int_field(sel.id, "Z mm", "z", i.z)
		panel.field(props, "Yaw deg", i.yaw / 1000, function(t)
			local v = tonumber(t)
			if v then
				set(sel.id, {ints = {yaw = math.floor(v * 1000 + 0.5) % 360000}})
			end
		end)
		int_field(sel.id, "Offset mm", "offset", i.offset)
		panel.check(props, "From the ceiling down", i.align == 1, function()
			set(sel.id, {ints = {align = 1 - i.align}})
		end)
		local r = panel.row(props)
		-- The turn most often wanted, as the field's value plus 90 (user)
		panel.button(r, "Yaw +90", function()
			set(sel.id, {ints = {yaw = (i.yaw + 90000) % 360000}})
		end)
		panel.button(r, "Pitch +90", function()
			set(sel.id, {ints = {pitch = (i.pitch + 1) % 4}})
		end)
		panel.button(r, "Roll +90", function()
			set(sel.id, {ints = {roll = (i.roll + 1) % 4}})
		end)
		-- The gaps to the walls, typed to move the box
		if E.inst_data[sel.id] and not E.inst_data[sel.id].hosted then
			for k, g in ipairs(wall_gaps(sel.id)) do
				if g.gap then
					panel.field(props, "Gap " .. ({"+X", "-X", "+Z", "-Z"})[k] ..
							" mm", math.floor(g.gap + 0.5), function(t)
						local v = tonumber(t)
						if v then
							local m = g.gap - v
							set(sel.id, {ints = {
									x = math.floor(i.x + g.dir[1] * m + 0.5),
									z = math.floor(i.z + g.dir[2] * m + 0.5)}})
						end
					end)
				end
			end
		end
		panel.button(props, "Copy (Ctrl+D)", function() copy_selected(false) end)
		panel.button(props, "Linked clone (Ctrl+L)", function()
			copy_selected(true)
		end)
		if links > 1 then
			panel.button(props, "Unlink", function() unlink(sel.id) end)
		end
		panel.button(props, "Apply the palette entry", apply_material)
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif sel and sel.type == "wall" then
		local w = sel.ints
		local ax, az = node_pos(w.a)
		local bx, bz = node_pos(w.b)
		local l = geom.len(bx - ax, bz - az)
		local face = S.sel_face[sel.id]
		heading("Wall " .. sel.id .. (face and ", the " .. (face == "core" and
				"top" or face .. " face") or ""))
		panel.field(props, "Length mm", math.floor(l + 0.5), function(t)
			local v = num(t)
			if v and v > 0 and l > 0 then
				set(w.b, {ints = {x = math.floor(ax + (bx - ax) * v / l + 0.5),
						z = math.floor(az + (bz - az) * v / l + 0.5)}})
			end
		end)
		int_field(sel.id, "Thickness mm", "thickness", w.thickness)
		int_field(sel.id, "Height mm", "height", w.height)
		panel.label(props, "(height 0: to the ceiling)")
		panel.dropdown(props, "Justify", JUSTIFY_CHOICES, w.justify, function(v)
			set(sel.id, {ints = {justify = v}})
		end)
		if w.justify == 3 then
			int_field(sel.id, "Offset mm (+ left)", "shift", w.shift)
		end
		panel.check(props, "Hangs from the ceiling", w.hang == 1, function()
			set(sel.id, {ints = {hang = 1 - w.hang}})
		end)
		local face_mat = face == "left" and w.mat_left or face == "right" and
				w.mat_right or face == "core" and w.mat_core or nil
		panel.label(props, face and ("Selected by its " .. (face == "core" and
				"top" or face .. " face") .. ", #" .. tostring(face_mat)) or
				"Click the wall on a face to pick it")
		if face then
			panel.button(props, "The palette entry on that face (double click)",
					function() apply_material() end)
		end
		panel.button(props, "The palette entry on both faces", function()
			apply_material(true)
		end)
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif sel and sel.type == "image" then
		local i = sel.ints
		heading("Picture: " .. sel.strs.file)
		int_field(sel.id, "mm per 1000 px", "scale", i.scale)
		panel.field(props, "Opacity %", i.opacity / 10, function(t)
			local v = tonumber(t)
			if v then set(sel.id, {ints = {opacity = math.floor(v * 10 + 0.5)}}) end
		end)
		panel.field(props, "Yaw deg", i.yaw / 1000, function(t)
			local v = tonumber(t)
			if v then
				set(sel.id, {ints = {yaw = math.floor(v * 1000 + 0.5) % 360000}})
			end
		end)
		if S.calib and S.calib.id == sel.id and S.calib.measured then
			panel.label(props, "The two points are " ..
					math.floor(S.calib.measured + 0.5) .. " mm apart; really:")
			panel.field(props, "Distance mm", "", function(t)
				local v = tonumber(t)
				if v and v > 0 then
					set(sel.id, {ints = {scale = math.max(1, math.floor(
							i.scale * v / S.calib.measured + 0.5))}})
				end
				S.calib = nil
			end, nil, true)
		else
			panel.button(props, S.calib and "Click two points on it" or
					"Calibrate: two points and their distance", function()
				S.calib = {id = sel.id, pts = {}}
				refresh_panels()
			end, S.calib ~= nil)
		end
		panel.button(props, "Lock it (a locked one cannot be picked)",
				function()
			set(sel.id, {ints = {locked = 1}})
		end)
		panel.check(props, "Shown in 3D too", i.show3d == 1, function()
			set(sel.id, {ints = {show3d = 1 - i.show3d}})
		end)
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif sel and sel.type == "room" then
		local r = E.room_data[sel.id]
		heading("Room " .. sel.id .. " \"" .. sel.strs.name .. "\", the " ..
				(S.sel_face[sel.id] == "ceiling" and "ceiling" or "floor"))
		panel.field(props, "Name", sel.strs.name, function(t)
			set(sel.id, {strs = {name = t}})
		end, 120, true)
		int_field(sel.id, "Ceiling mm", "ceiling", sel.ints.ceiling)
		panel.label(props, "(ceiling 0: the plan's)")
		if r then
			panel.label(props, "Floor " .. m2(r.net) .. " net")
			panel.label(props, m2(r.gross) .. " to the wall lines")
		end
		local on_ceiling = S.sel_face[sel.id] == "ceiling"
		panel.label(props, "Selected by its " .. (on_ceiling and "ceiling, #" ..
				sel.ints.mat_ceiling or "floor, #" .. sel.ints.mat_floor))
		panel.button(props, "The palette entry on the " .. (on_ceiling and
				"ceiling" or "floor") .. " (double click)",
				function() apply_material() end)
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif sel and sel.type == "node" then
		heading("Node " .. sel.id)
		int_field(sel.id, "X mm", "x", sel.ints.x)
		int_field(sel.id, "Z mm", "z", sel.ints.z)
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif S.tool == "hosted" then
		panel.label(props, "Click a wall to put in (I: the next):")
		local kinds = {}
		for _, k in ipairs({KIND.opening, KIND.door, KIND.window, KIND.switch}) do
			kinds[#kinds + 1] = {KIND_NAMES[k], k}
		end
		panel.dropdown(props, "Kind", kinds, S.hosted, function(k)
			S.hosted = k
			refresh_panels()
		end)
		local d = HOSTED[S.hosted]
		for _, f in ipairs({{"Width mm", "w"}, {"Height mm", "h"},
				{"Sill mm", "sill"}}) do
			panel.field(props, f[1], d[f[2]], function(t)
				local v = num(t)
				if v and (v > 0 or f[2] == "sill") then d[f[2]] = v end
			end)
		end
	elseif S.tool == "voxel" then
		panel.label(props, "Select a volume to edit it, or")
		panel.label(props, "place a voxel on the floor or on an")
		panel.label(props, "object's top to start one")
		panel.field(props, "Voxel mm", S.voxel_size, function(t)
			local v = num(t)
			if v and v > 0 then S.voxel_size = v end
		end)
		M.voxel_mode_dropdown()
	elseif S.tool == "box" then
		local stairs = S.shape == "stairs"
		panel.dropdown(props, "Shape", {{"box", "box"}, {"stairs", "stairs"},
				{"plafond lamp", "lamp"}}, S.shape or "box", function(v)
			S.shape = v
			refresh_panels()
		end)
		local lamp = S.shape == "lamp"
		panel.label(props, lamp and "New lamps: click where one goes; on the ceiling, lit" or
				stairs and "New stairs: click, or drag the footprint"
				or "New boxes: drag the footprint")
		if lamp then
		elseif stairs then
			local st = S.stairs
			for _, f in ipairs({{"Width mm", "w"}, {"Height mm (0: a floor)", "h"},
					{"Riser mm", "riser"}, {"Tread mm", "tread"}}) do
				panel.field(props, f[1], st[f[2]], function(t)
					local v = num(t)
					if v and (v > 0 or f[2] == "h" and v == 0) then st[f[2]] = v end
				end)
			end
			local h = st.h > 0 and st.h or settings().floor_step
			local n = math.max(1, math.floor(h / st.riser + 0.5))
			panel.label(props, n .. " steps of " ..
					math.floor(h / n * 10 + 0.5) / 10 .. " mm, " ..
					n * st.tread .. " mm deep")
		end
		for _, f in ipairs(lamp and {} or stairs and {{"Offset mm", "offset"}} or
				{{"Width mm", "w"}, {"Height mm", "h"}, {"Depth mm", "d"},
				{"Offset mm", "offset"}}) do
			panel.field(props, f[1], S.box[f[2]], function(t)
				local v = num(t)
				if v and (v > 0 or f[2] == "offset") then S.box[f[2]] = v end
			end)
		end
		if not lamp then
			panel.check(props, "From the ceiling down", S.box.align == 1, function()
				S.box.align = 1 - S.box.align
				refresh_panels()
			end)
		end
	else
		panel.label(props, "New walls")
		panel.field(props, "Thickness mm", S.thickness, function(t)
			local v = num(t)
			if v and v > 0 then S.thickness = v end
		end)
		panel.field(props, "Height mm", S.height, function(t)
			local v = num(t)
			if v and v >= 0 then S.height = v end
		end)
		panel.dropdown(props, "Justify", JUSTIFY_CHOICES, S.justify, function(v)
			S.justify = v
			refresh_panels()
		end)
		if S.justify == 3 then
			panel.field(props, "Offset mm (+ left)", S.shift, function(t)
				local v = num(t)
				if v then S.shift = math.max(-10000, math.min(10000, v)) end
			end)
		end
		panel.check(props, "Hang from the ceiling", S.hang == 1, function()
			S.hang = 1 - S.hang
			refresh_panels()
		end)
		panel.check(props, "Rooms get a ceiling lamp", S.room_lamp, function()
			S.room_lamp = not S.room_lamp
			buildat.storage_write("room_lamp", S.room_lamp and "1" or "0")
			refresh_panels()
		end)
		panel.check(props, "Rooms get walls", S.room_walls, function()
			S.room_walls = not S.room_walls
			refresh_panels()
		end)
	end
	if not doc.can("edit") then
		panel.label(props, doc.can("can_edit") and
				"Viewing: Editing is in the menu" or
				"Viewing only: no edit privilege", magic.Color(1, 0.6, 0.4))
	end
end

local build_palette, picker_win, close_picker
do
	local FINISHES = {[0] = "Over its colour", "White undercoat", "Stain"}
	local AXES = {[0] = "Grain along X", "Grain along Y", "Grain along Z"}
	-- Which knobs each type has, beyond the colours and the finish.
	-- Roughness and specular are the type's own (KIND_DEFAULTS, set when
	-- the type is picked), not shown: they only shape a lamp's or the sun's
	-- highlight, which the knobs did not visibly change (user, 2026-09-29)
	local KNOBS = {
		[0] = {"reflect"},
		{"reflect", "scale", "seed", "axis", "contrast"},
		{"reflect", "scale", "seed", "color2"},
		{"scale", "seed", "color2"},
		{"temperature", "brightness"},
		{"opacity", "reflect"},
		{"reflect", "scale"},
		{"reflect", "scale", "grout", "stagger", "color2"},
		{"scale"},
		{"scale", "seed", "speckle"},
		-- Paneling's polish stands for its roughness, specular and reflect
		{"scale", "seed", "angle", "contrast", "polish", "gap_depth",
			"gap_width", "handmade"},
	}
	local KNOB_LABELS = {roughness = "Roughness", specular = "Specular",
		reflect = "Reflective", scale = "Scale mm", seed = "Seed",
		temperature = "Kelvin", brightness = "Brightness", opacity = "Opacity",
		grout = "Grout mm", speckle = "Speckle", angle = "Angle deg",
		contrast = "Grain contrast", polish = "Polish",
		gap_depth = "Gap depth mm", gap_width = "Gap width mm",
		handmade = "Hand made"}
	-- Knobs in thousandths shown as percent
	local PERCENT = {roughness = true, specular = true, reflect = true,
		brightness = true, opacity = true, speckle = true, contrast = true,
		polish = true, handmade = true}
	-- Knobs in tenths of a mm, shown as mm, nudged by one
	local TENTHS = {gap_depth = true, gap_width = true}

	-- Everything that holds palette entry `from`, moved to `to`, and `from`
	-- deleted, in one batch
	local function replace_entry(from, to)
		local ops = {}
		for id, e in pairs(doc.ents) do
			local ints = {}
			for k, v in pairs(e.ints) do
				if v == from and k:sub(1, 3) == "mat" then
					ints[k] = to
				end
			end
			if next(ints) then
				ops[#ops + 1] = {op = "set", ent = {id = id, ints = ints}}
			end
		end
		ops[#ops + 1] = {op = "delete", ent = {id = from}}
		send(ops)
end

-- The colour picker ([FP_COLOR]) on one colour of one palette entry:
-- S.picker = {ent, field, title, groups, query}. Its named colours are
-- client_data/colors.txt's, the groups the field and the type call for.
local named_colours = nil
close_picker = function()
	if picker_win then
		panel.close_picker(picker_win)
		picker_win = nil
	end
	S.picker, S.replace = nil, nil
end

-- **Replacing a material in a voxel volume** (user: a lamp built of the
-- wrong voxels): S.replace = {def, from, to}, from what its voxels use to
-- any palette entry, as one voxel edit and so one undo. The picker's window
-- is its window too; one of the two is up at a time.
local HIGHLIGHT = magic.Color(1.0, 0.85, 0.3)
local build_picker
local function build_replace()
	local rp = S.replace
	local vox = doc.voxels[rp.def]
	if not doc.ents[rp.def] or not vox then
		S.replace = nil
		return
	end
	local counts = {}
	local used = 0
	for _, m in pairs(vox) do
		if not counts[m] then
			used = used + 1
		end
		counts[m] = (counts[m] or 0) + 1
	end
	-- One material in them: that is the one to replace
	if not rp.from and used == 1 then
		rp.from = next(counts)
	end
	local w = panel.window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
	picker_win = w
	w.minWidth = 320
	panel.label(w, "Replace a material in these voxels")
	-- From and To side by side (user): a palette is ten entries or more
	local cols = panel.row(w)
	local function list(label, want, field)
		local c = panel.column(cols)
		panel.label(c, label)
		for _, p in ipairs(of_type("palette")) do
			if not want or counts[p.id] then
				local picked = rp[field] == p.id
				panel.swatch_row(c, palette_rgb(p.id), "#" .. p.id .. "  " ..
						p.strs.name .. (counts[p.id] and ("  (" .. counts[p.id] ..
						" voxels)") or ""), function()
					rp[field] = p.id
					build_picker()
				end, picked, picked and HIGHLIGHT or nil)
			end
		end
	end
	list("From:", true, "from")
	list("To:", false, "to")
	local r = panel.row(w)
	if rp.from and rp.to and rp.from ~= rp.to and counts[rp.from] then
		panel.button(r, "Replace " .. counts[rp.from] .. " voxels", function()
			local sets = {}
			for key, m in pairs(vox) do
				if m == rp.from then
					sets[key] = rp.to
				end
			end
			doc.set_voxels(rp.def, sets)
			close_picker()
		end)
	end
	panel.button(r, "Cancel (Esc)", close_picker)
end

local function load_named()
	if not named_colours then
		named_colours = {}
		for _, file in ipairs({"main/colors.txt", "main/colors_tikkurila.txt"}) do
			local text = buildat.get_file_content(file) or ""
			for line in text:gmatch("[^\r\n]+") do
				local g, name, hex, family = line:match(
						"^(%w+)|([^|]+)|(%x%x%x%x%x%x)|?([^|]*)$")
				if g then
					named_colours[#named_colours + 1] = {group = g, name = name,
							rgb = tonumber(hex, 16), family = family ~= "" and family
							or nil}
				end
			end
		end
	end
	return named_colours
end

-- **Fit to samples** ([FP_SAMPLE_FIT]): the picker's window as a list of
-- colours sampled off a real surface, the entry as the fit would make it,
-- Apply as one edit. S.picker = {ent, fit = {samples = {{rgb, name}},
-- adding, query}}; "Add a sample" turns it into the colour picker, any
-- named colour, until a pick.
local function build_fit(pk, e)
	local ft = pk.fit
	local named = load_named()
	if ft.adding then
		picker_win = panel.color_picker({title = "Add a sample",
			rgb = ft.last or e.ints.base, named = named, query = ft.query,
			on_pick = function(rgb)
				local name = ""
				for _, n in ipairs(named) do
					if n.rgb == rgb then
						name = n.name
						break
					end
				end
				ft.samples[#ft.samples + 1] = {rgb = rgb, name = name}
				ft.adding, ft.last, ft.query = false, rgb, nil
				build_picker()
			end,
			on_query = function(q)
				ft.query = q
				build_picker()
			end,
			on_close = function()
				ft.adding = false
				build_picker()
			end})
		return
	end
	local woods, rgbs = {}, {}
	for _, n in ipairs(named) do
		if n.group == "wood" then
			woods[#woods + 1] = n
		end
	end
	for i, smp in ipairs(ft.samples) do
		rgbs[i] = smp.rgb
	end
	local r = fit.fit(e.ints, rgbs, woods)
	local w = panel.window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
	picker_win = w
	w.minWidth = 340
	panel.label(w, e.strs.name .. ": fit to samples")
	for i, smp in ipairs(ft.samples) do
		local row = panel.row(w)
		panel.chip(row, smp.rgb, 14)
		panel.label(row, (smp.name ~= "" and smp.name or
				string.format("%06x", smp.rgb)) ..
				(r and string.format("  dE %.1f", r.near[i]) or ""))
		panel.button(row, "Remove", function()
			table.remove(ft.samples, i)
			build_picker()
		end)
	end
	panel.button(w, "Add a sample...", function()
		ft.adding = true
		build_picker()
	end)
	if r then
		local function chips(label, list)
			local row = panel.row(w)
			panel.label(row, label)
			for _, v in ipairs(list) do
				panel.chip(row, v, 18)
			end
		end
		chips("Samples, darkest, mean, lightest:", r.target)
		chips("The fit:", {r.look[1], r.look[4], r.look[3]})
		panel.label(w, string.format("Off by dE %.1f", r.err))
		if #r.changes == 0 then
			panel.label(w, "The entry already matches: nothing changes")
		end
		for _, c in ipairs(r.changes) do
			panel.label(w, c)
		end
	end
	local row = panel.row(w)
	panel.button(row, "Apply", function()
		-- One edit, so one undo; the samples kept on the entry
		send({{op = "set", ent = {id = pk.ent, ints = r and r.ints or {},
				strs = {samples = fit.format(ft.samples)}}}})
		close_picker()
	end)
	panel.button(row, "Cancel (Esc)", close_picker)
end

build_picker = function()
	if picker_win then
		panel.close_picker(picker_win)
		picker_win = nil
	end
	if S.replace then
		return build_replace()
	end
	local pk = S.picker
	local e = pk and doc.ents[pk.ent]
	if not e then
		S.picker = nil
		return
	end
	if pk.fit then
		return build_fit(pk, e)
	end
	local named = {}
	for _, n in ipairs(load_named()) do
		for _, g in ipairs(pk.groups) do
			if n.group == g then
				named[#named + 1] = n
			end
		end
	end
	picker_win = panel.color_picker({title = pk.title, rgb = e.ints[pk.field],
		named = named, query = pk.query,
		on_pick = function(rgb)
			send({{op = "set", ent = {id = pk.ent, ints = {[pk.field] = rgb}}}})
		end,
		on_query = function(q)
			pk.query = q
			build_picker()
		end,
		on_close = close_picker})
end

-- Which named colours fit a field of an entry: a wood's own colour is a
-- wood's, a stain a stain's, paint a paint's -- never the others'
local function colour_groups(p, field)
	if field == "base" then
		return ({[1] = {"wood"}, [2] = {"stone"}, [5] = {"glass"},
				[6] = {"metal"}, [7] = {"tile"}, [10] = {"wood"}})[p.kind] or {"paint"}
	elseif field == "color" then
		return p.finish == 2 and {"stain"} or {"paint"}
	end
	return p.kind == 7 and {"grout"} or p.kind == 2 and {"stone"} or {"paint"}
end

build_palette = function()
	if palette_win then
		-- Where its list was scrolled to, for the one made in its place
		if M.palette_view then
			M.palette_scroll = M.palette_view.viewPosition.y
		end
		panel.discard(palette_win)
	end
	M.palette_view = nil
	palette_win = panel.window(magic.HA_LEFT, magic.VA_TOP, 8, S.panel_y or 50)
	if panel.folded("palette") then
		palette_win.visible = false
		return
	end
	-- **The palette folds to its title** (user): a click on the title
	-- row, or a right click that clears the selection, folds it, and it
	-- opens by itself when something new is selected or a tool it goes on
	-- is taken. Folded it is a dropdown's button saying the entry.
	local sel_now = S.primary or next(S.sel)
	if (sel_now and sel_now ~= S.palette_sel) or (S.tool and
			S.tool ~= S.palette_tool and S.tool ~= "select" and
			S.tool ~= "node") or S.replacing then
		S.palette_collapsed = false
	end
	S.palette_sel, S.palette_tool = sel_now, S.tool
	local cur = default_material()
	if S.replacing then
		panel.label(palette_win, "Pick the entry to use instead:")
	else
		local ce = doc.ents[cur]
		panel.keep(function() return panel.mark(panel.button(palette_win,
				S.palette_collapsed and ce and
				("Palette: #" .. cur .. "  " .. ce.strs.name) or "Palette",
				function()
			S.palette_collapsed = not S.palette_collapsed
			refresh_panels()
		end), S.palette_collapsed and "▼" or "▲") end)
		if S.palette_collapsed then
			-- The colour picker goes with it; a voxel replace keeps its own
			if S.picker and not S.replace then
				close_picker()
			end
			return
		end
	end
	local entries = of_type("palette")
	-- **Over PALETTE_ROWS entries, a list that scrolls** (user: a plan of
	-- twenty materials made a column taller than the screen): the rows in a
	-- column of their own in a ScrollView of that many rows, the wheel and
	-- its bar scrolling it; where it was scrolled to is kept over the
	-- panel's rebuilds, and an entry newly picked is scrolled into view
	local PALETTE_ROWS = 8
	local ROW = 30 + 4
	local list, view = palette_win, nil
	if #entries > PALETTE_ROWS then
		-- Made first, so that it is where the entries were; the column it
		-- is given is made in it, not in the panel: the panel's layout grew
		-- to all the entries while they were its, and a layout does not
		-- shrink, so the panel stayed that tall and spread its rows out
		-- (user, 2026-10-02)
		view = palette_win:CreateChild("ScrollView")
		list = view:CreateChild("UIElement")
		list:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
	end
	local cur_index, widest = nil, 0
	for i, p in ipairs(entries) do
		if p.id == cur then
			cur_index = i
		end
		local row = panel.swatch_row(list, palette_rgb(p.id), "#" .. p.id .. "  " ..
				p.strs.name .. "  (" .. MATERIAL_KINDS[p.ints.kind] .. ")",
				function()
			-- A second click on the same entry soon after is a double click:
			-- the entry goes on what is selected, as Apply does
			local now = buildat.get_time_us()
			local double = S.last_swatch == p.id and
					now - (S.last_swatch_us or 0) < 400000
			S.last_swatch, S.last_swatch_us = p.id, now
			if double and not S.replacing and next(S.sel) then
				S.material = p.id
				apply_material()
				refresh_panels()
				return
			end
			if S.replacing then
				if p.id ~= S.replacing then
					replace_entry(S.replacing, p.id)
				end
				S.replacing = nil
			end
			S.material = p.id
			refresh_panels()
		end, p.id == cur, p.id == cur and magic.Color(1.0, 0.85, 0.3) or nil)
		widest = math.max(widest, row.minWidth)
		if view then
			-- One height for all, which the scrolling counts in
			row:SetFixedHeight(30)
		end
	end
	if view then
		view:SetStyleAuto()
		-- Out of Tab's way, as the fields are what the keyboard is for
		view:SetFocusMode(magic.FM_NOTFOCUSABLE)
		view:SetScrollBarsVisible(false, true)
		view.scrollBarsAutoVisible = false
		view:SetFixedHeight(PALETTE_ROWS * ROW - 4)
		view:SetFixedWidth(widest + 20)
		list:SetFixedWidth(widest)
		view.contentElement = list
		-- At the panel's top left: it keeps where the window's layout had
		-- put it before it moved, which is below what the view shows
		list:SetPosition(0, 0)
		local y = M.palette_scroll or 0
		if cur_index and cur ~= M.palette_scrolled_to then
			local top = (cur_index - 1) * ROW
			local h = PALETTE_ROWS * ROW - 4
			if top < y or top + ROW > y + h then
				y = math.max(0, top - math.floor(h / 2))
			end
		end
		M.palette_scrolled_to = cur
		view.viewPosition = magic.IntVector2(0, y)
		M.palette_view = view
	end
	local e = doc.ents[cur]
	if S.picker and S.picker.ent ~= cur then
		close_picker()
	end
	build_picker()
	local function set(ints, strs)
		send({{op = "set", ent = {id = cur, ints = ints, strs = strs}}})
	end
	if e then
		local p = e.ints
		panel.field(palette_win, "Name", e.strs.name, function(t)
			set(nil, {name = t})
		end, 120, true)
		-- The types as a grid of their previews, opened under the button
		-- ([FP_TYPES]); Esc or the button again closes it
		if panel.view_only then
			panel.label(palette_win, "Type: " .. MATERIAL_KINDS[p.kind])
		else
			panel.mark(panel.button(palette_win, "Type: " .. MATERIAL_KINDS[p.kind],
					function()
				S.type_open = not S.type_open
				refresh_panels()
			end, S.type_open), S.type_open and "▲" or "▼")
		end
		if S.type_open and not panel.view_only then
			local tex = kind_previews()
			local r
			for k = 0, #MATERIAL_KINDS do
				if k % 4 == 0 then
					r = panel.row(palette_win)
				end
				panel.preview_button(r, tex, magic.IntRect(k * PREVIEW_PX, 0,
						(k + 1) * PREVIEW_PX, PREVIEW_PX), MATERIAL_KINDS[k],
						function()
					S.type_open = false
					if k ~= p.kind then
						-- A new type starts from its own look
						local d = KIND_DEFAULTS[k]
						set({kind = k, base = d.base, color2 = d.color2,
								scale = d.scale, roughness = d.roughness,
								specular = d.specular})
					end
					refresh_panels()
				end, k == p.kind)
			end
		end
		local function colour(label, name)
			local _, r = panel.field(palette_win, label,
					string.format("%06x", p[name]), function(t)
				local v = tonumber(t, 16)
				if v and v >= 0 and v <= 0xffffff then set({[name] = v}) end
			end, 90, true)
			panel.chip(r, p[name], 14, function()
				S.picker = {ent = cur, field = name, groups = colour_groups(p, name),
						title = e.strs.name .. ": " .. label}
				build_picker()
			end)
		end
		if p.kind ~= 4 then
			colour("Own colour", "base")
			colour("Paint", "color")
			panel.dropdown(palette_win, "Finish", {{FINISHES[0], 0},
					{FINISHES[1], 1}, {FINISHES[2], 2}}, p.finish, function(v)
				set({finish = v})
			end)
			if p.finish == 2 and p.kind ~= 5 then
				panel.field(palette_win, "Stain %", p.opacity / 10, function(t)
					local v = tonumber(t)
					if v then set({opacity = math.floor(v * 10 + 0.5)}) end
				end, 120)
			end
			local kept = fit.parse(e.strs.samples)
			if #kept > 0 then
				panel.label(palette_win, "Fitted to " .. #kept .. " samples")
			end
			if not panel.view_only then
				panel.button(palette_win, "Fit to samples...", function()
					S.picker = {ent = cur, fit = {samples = kept}}
					build_picker()
				end)
			end
		end
		for _, k in ipairs(KNOBS[p.kind]) do
			if k == "color2" then
				colour(p.kind == 7 and "Grout colour" or p.kind == 3 and
						"Pattern" or "Veins", "color2")
			elseif k == "axis" then
				panel.dropdown(palette_win, "Grain", {{"along X", 0},
						{"along Y", 1}, {"along Z", 2}}, p.axis, function(v)
					set({axis = v})
				end)
			elseif k == "stagger" then
				panel.check(palette_win, "Staggered", p.stagger == 1, function()
					set({stagger = 1 - p.stagger})
				end)
			else
				local tenth = PERCENT[k] or TENTHS[k]
				local shown = tenth and p[k] / 10 or p[k]
				panel.field(palette_win, (k == "scale" and p.kind == 10 and
						"Board mm" or KNOB_LABELS[k]) .. (PERCENT[k] and " %"
						or ""), shown, function(t)
					local v = tonumber(t)
					if v then
						set({[k] = math.floor((tenth and v * 10 or v) + 0.5)})
					end
				end, 120, nil, TENTHS[k] and 1)
			end
		end
	end
	local r = panel.row(palette_win)
	panel.button(r, "New entry", function()
		local ph = doc.placeholder()
		local ints = e and copy_fields(e.ints) or {}
		send({{op = "create", ent = {id = ph, type = "palette", ints = ints,
				strs = {name = "material " .. (#entries + 1),
				samples = e and e.strs.samples or nil}}}}, function(err)
			if err == "" then
				S.material = S.real[ph]
				refresh_panels()
			end
		end)
	end)
	if e and #entries > 1 then
		panel.button(r, "Replace", function()
			S.replacing = cur
			refresh_panels()
		end)
	end
end

end

-- The layouts window ([FP_LAYOUTS]), from the toolbar: each layout by its
-- group, to pick the one edited; the current one's own fields; a new floor
-- or building
place.build_window = function()
	if place.win then
		panel.discard(place.win)
		place.win = nil
	end
	if not S.layouts_open then
		return
	end
	local w = panel.window(magic.HA_CENTER, magic.VA_TOP, 0, S.panel_y or 50)
	place.win = w
	local function set(id, fields)
		send({{op = "set", ent = {id = id, ints = fields.ints,
				strs = fields.strs}}})
	end
	local function int_field(id, label, name, value)
		panel.field(w, label, value, function(t)
			local v = tonumber(t)
			if v then set(id, {ints = {[name] = math.floor(v + 0.5)}}) end
		end)
	end
	local top = panel.row(w)
	panel.label(top, "Layouts: click one to edit it")
	panel.keep(function() return panel.button(top, "Close", function()
		S.layouts_open = false
		refresh_panels()
	end) end)
	local list = doc.of_type("layout")
	table.sort(list, function(a, b)
		if a.strs.group ~= b.strs.group then
			return a.strs.group < b.strs.group
		end
		if a.ints.y ~= b.ints.y then
			return a.ints.y < b.ints.y
		end
		return a.id < b.id
	end)
	local groups, in_group = {}, 0
	local e = doc.ents[S.layout]
	for _, l in ipairs(list) do
		groups[l.strs.group] = true
		if e and l.strs.group == e.strs.group then
			in_group = in_group + 1
		end
		-- [FP_FLOOR_AREA] Its rooms' net floor summed (rebuild()'s)
		local a = place.areas[l.id]
		panel.keep(function() return panel.button(w, l.strs.group .. ": " ..
				l.strs.name .. (a and " (" .. m2(a) .. ")" or ""), function()
			place.switch(l.id)
			refresh_panels()
		end, l.id == S.layout) end)
	end
	-- At the bottom for everyone: what the 3D view shows of the floors
	-- over this one (user)
	local function above_toggle()
		panel.keep(function() return panel.check(w, "Hide the floors above in 3D",
				S.hide_above, function()
			S.hide_above = not S.hide_above
			buildat.storage_write("hide_above", S.hide_above and "1" or "0")
			refresh_panels()
		end) end)
	end
	if not e or not doc.can("edit") then
		above_toggle()
		return
	end
	panel.label(w, "This one")
	local id, c = e.id, e.ints
	local function create(ints, strs)
		local ph = doc.placeholder()
		send({{op = "create", ent = {id = ph, type = "layout", ints = ints,
				strs = strs}}}, function(err)
			if err == "" then
				place.switch(real_id(ph))
				refresh_panels()
			end
		end)
	end
	panel.field(w, "Name", e.strs.name, function(t)
		set(id, {strs = {name = t}})
	end, nil, true)
	panel.field(w, "Group", e.strs.group, function(t)
		set(id, {strs = {group = t}})
	end, nil, true)
	int_field(id, "X mm", "x", c.x)
	int_field(id, "Y mm", "y", c.y)
	-- Under the building's lowest floor when it is above the ground
	local fm = doc.ents[c.mat_foundation]
	panel.label(w, "Foundation: " .. (fm and "'" .. fm.strs.name .. "' #" ..
			c.mat_foundation or "plain grey"))
	panel.button(w, "Foundation: the palette entry", function()
		set(id, {ints = {mat_foundation = default_material()}})
	end)
	int_field(id, "Z mm", "z", c.z)
	panel.field(w, "Yaw deg", c.yaw / 1000, function(t)
		local v = tonumber(t)
		if v then
			set(id, {ints = {yaw = math.floor(v * 1000 + 0.5) % 360000}})
		end
	end)
	local st = settings()
	int_field(doc.settings().id, "Floor to floor mm", "floor_step",
			st.floor_step)
	panel.button(w, "Add a floor above", function()
		-- Over the group's top one
		local top = c
		for _, l in ipairs(list) do
			if l.strs.group == e.strs.group and l.ints.y > top.y then
				top = l.ints
			end
		end
		create({x = top.x, y = top.y + st.floor_step, z = top.z, yaw = top.yaw},
				{name = "Floor " .. in_group, group = e.strs.group})
	end)
	-- **The lamps of a floor, or of all of them, at once** (user: lighting
	-- without wiring switches when the switches are not what is studied):
	-- as a switch does, off if any is on. A viewer's too, for themselves.
	local function lamps_button(text, layout)
		panel.keep(function() return panel.button(w, text, function()
			local lamps = {}
			for _, x in ipairs(doc.of_type("instance")) do
				if (not layout or x.ints.layout == layout) and is_lamp(x.id) then
					lamps[#lamps + 1] = x.id
				end
			end
			if #lamps == 0 then
				doc.notice(layout and "No lamps on this floor" or "No lamps")
				return
			end
			M.flip_lamps(lamps)
		end) end)
	end
	lamps_button("Lamps on this floor on/off", id)
	lamps_button("All lamps on/off", nil)
	panel.button(w, "New building", function()
		-- Beside the others, 20 m past the furthest
		local x, n = 0, 1
		for _, l in ipairs(list) do
			x = math.max(x, l.ints.x)
		end
		while groups["Building " .. n] or n == 1 and groups.Building do
			n = n + 1
		end
		create({x = x + 20000, y = 0, z = 0, yaw = 0},
				{name = "Ground floor", group = "Building " .. n})
	end)
	local empty = #list > 1
	for _, t in ipairs({"node", "instance", "image"}) do
		for _, x in ipairs(doc.of_type(t)) do
			if x.ints.layout == id then
				empty = false
			end
		end
	end
	if empty then
		panel.button(w, "Delete this layout", function()
			send({{op = "delete", ent = {id = id}}})
		end)
	end
	above_toggle()
end

refresh_panels = function()
	-- Nothing to show between plans; resume() draws them again
	if S.suspended then
		return
	end
	-- A field being typed in is not pulled from under the typing; the
	-- rebuild waits for the next change after it
	if doc.typing() then
		S.panels_stale = true
		return
	end
	S.panels_stale = false
	S.props_stale = false
	local t0 = buildat.get_time_us()
	build_toolbar()
	-- Viewing ([FP_VIEW_EDIT]): the panels show everything and change
	-- nothing
	panel.view_only = not doc.can("edit")
	build_props()
	build_palette()
	place.build_window()
	panel.view_only = false
	if M.probe_what then
		M.probe_add("panels", (buildat.get_time_us() - t0) / 1000)
	end
end
M.refresh_panels = function() refresh_panels() end
-- [FP_MOVE_FAST] A move's: only the selection's props show what it
-- changed (the toolbar 20 ms and the palette 30 ms in the large plan,
-- the props 3-14)
function M.refresh_props()
	S.props_stale = false
	local t0 = buildat.get_time_us()
	panel.view_only = not doc.can("edit")
	build_props()
	panel.view_only = false
	if M.probe_what then
		M.probe_add("panels", (buildat.get_time_us() - t0) / 1000)
	end
end

-- The pause menu ([FP_EDITOR_MODULES]): what it reads of this file
E.pause_win = nil
E.GRID_STEPS, E.keys, E.panel, E.refresh_panels = GRID_STEPS, keys, panel, refresh_panels
E.send, E.set_view, E.update_capture = send, set_view, update_capture
load("pause.lua")(E)
local open_pause, close_pause = E.open_pause, E.close_pause

local function over_ui()
	local s = magic.ui.scale
	return panel.popup_open() or panel.over({toolbar, props, palette_win,
			E.pause_win, picker_win, place.win, S.touch_bar, doc.accounts.page,
			doc.accounts.frame}, S.mx / s, S.my / s)
end

local press_target, plan_facing, plan_aligned, stream_drag, use, use_target, walk
-- For the touch bar, built before use is
M.use = function() use() end
do
	--
	-- Input
	--
	-- What a left press would take, for the select and node tools: the same
	-- pick for the click and for what the guide shows. In the select tool an
	-- object under the cursor wins, then a node near it, then the wall,
	-- picture or room it is on.
	-- **Leeway round the selection** (user): with something selected, a
	-- press that misses it by up to LEEWAY_PX still takes it; tried at
	-- points round the pointer, nearest first
	M.LEEWAY_PX = 12
	function M.near_selection()
		if not next(S.sel) then
			return nil
		end
		local mx, my = S.mx, S.my
		local found = nil
		for _, r in ipairs({M.LEEWAY_PX / 2, M.LEEWAY_PX}) do
			local d = M.px(r)
			for i = 0, 7 do
				local a = i * math.pi / 4
				S.mx, S.my = mx + math.cos(a) * d, my + math.sin(a) * d
				local s = pick_surface(nil, M.sel_accept)
				if s and S.sel[s.id] then
					found = {kind = S.sel[s.id], id = s.id, side = S.sel_face[s.id]}
					break
				end
			end
			if found then
				break
			end
		end
		S.mx, S.my = mx, my
		return found
	end

	press_target = function()
		local x, z = cursor_floor()
		if S.tool == "select" then
			local s = pick_surface(nil, M.sel_accept)
			if not (s and S.sel[s.id]) then
				local near = M.near_selection()
				if near then
					return near
				end
			end
			if s and s.kind == "instance" then
				-- With the part: a door's leaf is selected as its leaf
				return {kind = "instance", id = s.id, side = s.side}
			end
			local n = x and M.sel_filter().nodes and nearest_node(x, z, snap_radius())
			if n then
				return {kind = "node", id = n}
			elseif s then
				return {kind = (s.kind == "wall" or s.kind == "image") and s.kind or
						"room", id = s.id,
						-- A room is selected by its floor or, from under it, its
						-- ceiling, as a wall is by a face
						side = s.kind == "ceiling" and "ceiling" or
						s.kind == "floor" and "floor" or s.side}
			end
		elseif S.tool == "node" then
			local n = x and nearest_node(x, z, snap_radius())
			if n then
				return {kind = "node", id = n}
			end
		elseif S.tool == "box" then
			-- The selected object, to be moved by a drag
			local s = pick_surface()
			if s and s.kind == "instance" and S.sel[s.id] then
				return {kind = "instance", id = s.id, side = s.side}
			end
		end
		return nil
	end

	-- The material of what a click selected: a wall's by the face it was
	-- selected by, a room's floor, an object's own; nil for what has none of
	-- one (a voxel volume, a node, a picture)
	local function material_of(t)
		local e = t and doc.ents[t.id]
		if not e then
			return nil
		end
		if t.kind == "wall" then
			local w = e.ints
			local m = t.side == "left" and w.mat_left or t.side == "right" and
					w.mat_right or (w.mat_core ~= 0 and w.mat_core or w.mat_left)
			return m
		elseif t.kind == "room" then
			return t.side == "ceiling" and e.ints.mat_ceiling or e.ints.mat_floor
		elseif t.kind == "instance" then
			local def = doc.ents[e.ints.def].ints
			local m = DOOR_PARTS[t.side] and def[t.side] or 0
			return def.kind ~= KIND.voxel and (m ~= 0 and m or def.mat) or nil
		end
		return nil
	end

	-- A selection shows its material in the palette, to see and edit it
	local function palette_follows(t)
		local m = material_of(t)
		if m and m ~= 0 and doc.ents[m] then
			S.material = m
		end
	end

	local function begin_press(button)
		if button ~= magic.MOUSEB_LEFT or over_ui() then
			return
		end
		local x, z = cursor_floor()
		S.press = {mx = S.mx, my = S.my, x = x, z = z}
		if S.calib then
			return
		end
		if S.linking then
			local s = pick_surface()
			if s and s.kind == "instance" then
				S.press.target = {kind = "instance", id = s.id}
			end
			return
		end
		S.press.target = press_target()
	end

	local function start_drag()
		local t = S.press.target
		-- **With something selected, the Object tool places nothing** (user,
		-- 2026-10-01: a click to check what was just put in put in another):
		-- a drag of the selected object moves it, as Select's does, and one
		-- elsewhere ends as a click that lets go of the selection
		if S.tool == "box" and sel_count() > 0 and not t then
			return
		end
		if S.tool == "box" and not t then
			-- A lamp is placed with a click, its size its own
			local x, z = snapped_point(nil)
			if x and S.shape ~= "lamp" then
				S.drag = {kind = "footprint", x0 = x, z0 = z, x1 = x, z1 = z}
			end
			return
		end
		if (S.tool == "node" or S.tool == "select") and not t then
			-- A box over what to select
			S.drag = {kind = "box"}
			return
		end
		if not t or not doc.can("edit") then
			return
		end
		if S.tool == "node" then
			if S.nodes[t.id] and next(S.nodes, next(S.nodes)) then
				local nodes = {}
				for id in pairs(S.nodes) do
					nodes[id] = true
				end
				S.drag = {kind = "move", inst = {}, nodes = nodes, dx = 0, dz = 0,
						moved = true}
			else
				S.nodes = {[t.id] = true}
				S.drag = {kind = "node", id = t.id, moved = true,
						x = doc.ents[t.id].ints.x, z = doc.ents[t.id].ints.z}
			end
			return
		end
		-- The select tool: the drag moves the selection, and only what was
		-- selected before the press (user, 2026-10-01: a press that missed
		-- the selected object moved the room under it). A drag that starts
		-- on anything else is the box over what to select, as on nothing;
		-- a click selects it. A lone node drags alone.
		if not S.sel[t.id] then
			S.drag = {kind = "box"}
			return
		end
		S.primary = t.id
		if t.kind == "node" and sel_count() == 1 then
			S.drag = {kind = "node", id = t.id, moved = true,
					x = doc.ents[t.id].ints.x, z = doc.ents[t.id].ints.z}
		else
			local inst, nodes = moved_by(S.sel)
			S.drag = {kind = "move", inst = inst, nodes = nodes, dx = 0, dz = 0,
					moved = true}
			M.drag_slides(S.drag, S.sel)
		end
	end

	-- **A wall moved slides its ends along the walls they are on**
	-- (a playtest, 2026-10-06): an end whose other walls lie on one line --
	-- a corner's one, a T's two halves -- moves only along that line, so
	-- that wall stays where it is. Only for a selection of walls alone: a
	-- room moved takes its corners with it. None along a line the moved
	-- wall itself lies on (a straight wall split in two).
	function M.drag_slides(d, sel)
		d.slide = {}
		for _, kind in pairs(sel) do
			if kind ~= "wall" then
				return
			end
		end
		for n in pairs(d.nodes) do
			local ne = doc.ents[n]
			local u, one_line, moved = nil, true, {}
			for _, w in pairs(E.wall_data) do
				local o = w.a_node == n and w.b_node or w.b_node == n and w.a_node
				local oe = o and doc.ents[o]
				if oe and ne then
					local dx, dz = oe.ints.x - ne.ints.x, oe.ints.z - ne.ints.z
					local l = geom.len(dx, dz)
					if l > 0 then
						dx, dz = dx / l, dz / l
						if d.nodes[o] then
							moved[#moved + 1] = {dx, dz}
						elseif not u then
							u = {dx, dz}
						elseif math.abs(u[1] * dz - u[2] * dx) > 0.01 then
							one_line = false
						end
					end
				end
			end
			if u and one_line then
				local along_moved = false
				for _, m in ipairs(moved) do
					along_moved = along_moved or math.abs(m[1] * u[2] - m[2] * u[1]) < 0.1
				end
				if not along_moved then
					d.slide[n] = u
				end
			end
		end
	end

	-- What a drag moves, as entity ids: what it locks and previews
	local function drag_ids(d)
		local ids = {}
		if d.kind == "node" then
			ids[1] = d.id
		elseif d.kind == "move" then
			for id in pairs(d.nodes) do
				ids[#ids + 1] = id
			end
			for id in pairs(d.inst) do
				ids[#ids + 1] = id
			end
		end
		return ids
	end

	-- The dragged things where the drag has them, for the others
	local function drag_preview(d)
		local ents = {}
		if d.kind == "node" then
			ents[1] = {id = d.id, ints = {x = d.x, z = d.z}}
		elseif d.kind == "move" then
			for id in pairs(d.nodes) do
				local x, z = node_pos(id)
				ents[#ents + 1] = {id = id, ints = {x = x, z = z}}
			end
			for id in pairs(d.inst) do
				local it = E.inst_data[id]
				if it and it.hosted then
					ents[#ents + 1] = {id = id, ints = {along = math.floor(
							it.along + 0.5)}}
				elseif it then
					ents[#ents + 1] = {id = id, ints = {x = math.floor(it.x + 0.5),
							z = math.floor(it.z + 0.5)}}
				end
			end
		end
		return ents
	end

	-- A drag of what can be moved takes its lock; refused, it is dropped
	local function lock_drag()
		local d = S.drag
		if not d or (d.kind ~= "node" and d.kind ~= "move") then
			return
		end
		doc.lock(drag_ids(d), function(why)
			if S.drag == d then
				S.drag = nil
				S.press = nil
				S.dirty = true
			end
			doc.notice(why)
		end)
	end

	local PREVIEW_SECONDS = 0.05
	local preview_timer = 0

	local function update_drag()
		local d = S.drag
		if d.kind == "box" then
			return
		end
		if d.kind == "footprint" then
			local x, z = snapped_point(nil)
			if x then
				d.x1, d.z1 = x, z
			end
			return
		end
		if d.kind == "node" then
			local x, z, ref = snapped_point(nil, {[d.id] = true})
			d.angle_lines = nil
			-- Off nodes and edges, the walls' angles before the grid
			if x and not ref.node and not ref.edge then
				-- Its walls' other ends, and its rooms' corners either side
				-- (a corner with no walls gets right angles too: a playtest,
				-- 2026-10-06), each with the line it is on now
				local ends, seen = {}, {}
				local n0 = doc.ents[d.id].ints
				local function add(other)
					if other and other ~= d.id and not seen[other] then
						seen[other] = true
						local ox, oz = node_pos(other)
						ends[#ends + 1] = {ox, oz,
								own = math.atan2(n0.z - oz, n0.x - ox)}
					end
				end
				for _, w in pairs(E.wall_data) do
					add(w.a_node == d.id and w.b_node or
							w.b_node == d.id and w.a_node or nil)
				end
				for _, r in ipairs(of_type("room")) do
					local ns = r.lists.nodes
					for k, n in ipairs(ns) do
						if n == d.id then
							add(ns[(k - 2) % #ns + 1])
							add(ns[k % #ns + 1])
						end
					end
				end
				local cx, cz = cursor_floor()
				local ax, az, lines = M.angle_snap(cx, cz, ends)
				if ax then
					x, z, d.angle_lines = ax, az, lines
				end
			end
			if x then
				d.x, d.z, d.onto = x, z, ref.node
			end
		else
			local x, z = cursor_floor()
			if x and S.press.x then
				local g = grid_step()
				d.dx = geom.snap(x - S.press.x, g)
				d.dz = geom.snap(z - S.press.z, g)
			end
			M.slide_deltas(d)
			-- **A door, window or opening dragged onto another wall goes
			-- into it** (user): where the pointer is on that wall
			d.rehost = nil
			local one, n = nil, 0
			for id in pairs(d.inst or {}) do
				one, n = id, n + 1
			end
			local oe = n == 1 and not next(d.nodes or {}) and doc.ents[one]
			if oe and oe.ints.host ~= 0 then
				local ps = pick_surface()
				local f = ps and ps.kind == "wall" and ps.id ~= oe.ints.host and
						wall_frame(ps.id)
				if f then
					local w = doc.ents[oe.ints.def].ints.w
					local along = geom.snap((ps.x - f.ax) * f.ux +
							(ps.z - f.az) * f.uz, grid_step())
					d.rehost = {wall = ps.id, along = math.max(w / 2,
							math.min(f.len - w / 2, along))}
				end
			end
		end
		S.dirty = true
	end

	-- The sliding ends' own moves: the drag's projected on their lines
	function M.slide_deltas(d)
		d.nd = {}
		for n, u in pairs(d.slide or {}) do
			local t = d.dx * u[1] + d.dz * u[2]
			d.nd[n] = {math.floor(u[1] * t + 0.5), math.floor(u[2] * t + 0.5)}
		end
	end

	-- The screen point of a plan point, in pixels
	local function to_screen(x, z)
		local cam = S.view == "2d" and cam2d or cam3d
		local p = cam:WorldToScreenPoint(magic.Vector3(W(x), 0, W(z)))
		local w, h = screen_size()
		return p.x * w, p.y * h
	end

	-- simplified: a drag is sent when it is released, so others see it land
	-- rather than move; streaming it goes with the drag locks in [FP_UNDO]
	-- The openings not dragged that keep their place (M.kept_along): their
	-- `along` as the drag's last build has it, where it changed
	local function kept_ops(d, ops)
		for id, it in pairs(E.inst_data) do
			local e = doc.ents[id]
			local a = it.hosted and math.floor(it.along + 0.5)
			if a and e and not (d.inst and d.inst[id]) and a ~= e.ints.along then
				ops[#ops + 1] = {op = "set", ent = {id = id, ints = {along = a}}}
			end
		end
	end

	local function end_drag()
		local d = S.drag
		-- Built with the drag's last move, which this frame may not have
		-- (a key step's never has), for the openings' places kept_ops
		-- reads: only the instances' when no node moves ([FP_MOVE_FAST]).
		-- A full build of it is the moved state, which the batch shown at
		-- once then needs no rebuild for (M.send_shown)
		local full = not d.light
		if d.kind == "node" or d.kind == "move" then
			M.move_t = buildat.get_time_us()
		end
		if (d.kind == "node" or d.kind == "move") and (S.dirty or d.keys) then
			full = not (d.kind == "move" and not next(d.nodes))
			if full then
				rebuild()
			else
				M.rebuild_light()
			end
		end
		S.drag = nil
		S.dirty = true
		if d.kind == "node" or d.kind == "move" then
			-- After the drag's batch, which the server takes first
			M.after_drag = true
		end
		if d.kind == "box" then
			local x0, x1 = math.min(S.press.mx, S.mx), math.max(S.press.mx, S.mx)
			local y0, y1 = math.min(S.press.my, S.my), math.max(S.press.my, S.my)
			local function inside(x, z)
				local sx, sy = to_screen(x, z)
				return sx >= x0 and sx <= x1 and sy >= y0 and sy <= y1
			end
			if S.tool == "node" then
				if not S.shift then
					S.nodes = {}
				end
				for _, n in ipairs(of_type("node")) do
					if inside(n.ints.x, n.ints.z) then
						S.nodes[n.id] = true
					end
				end
			else
				if not S.shift then
					S.sel = {}
				end
				for id, it in pairs(E.inst_data) do
					if inside(it.x, it.z) and M.sel_accept("instance", id) then
						S.sel[id] = "instance"
						S.primary = id
					end
				end
				for id, w in pairs(E.wall_data) do
					if inside(w.ax, w.az) and inside(w.bx, w.bz) and
							M.sel_accept("wall", id) then
						S.sel[id] = "wall"
						S.sel_face[id] = nil
						S.primary = id
					end
				end
				for id, r in pairs(E.room_data) do
					local all = true
					for _, p in ipairs(r.pts) do
						all = all and inside(p[1], p[2])
					end
					if all and M.sel_accept("room", id) then
						S.sel[id] = "room"
						S.primary = id
					end
				end
			end
			refresh_panels()
		elseif d.kind == "footprint" then
			local w, dd = math.abs(d.x1 - d.x0), math.abs(d.z1 - d.z0)
			if w >= 1 and dd >= 1 and doc.can("edit") then
				add_box((d.x0 + d.x1) / 2, (d.z0 + d.z1) / 2, w, dd)
			end
		elseif d.kind == "node" then
			if d.onto then
				send(merge_ops(d.id, d.onto))
				S.nodes = {}
			else
				local ops = {{op = "set", ent = {id = d.id, ints = {x = d.x, z = d.z}}}}
				kept_ops(d, ops)
				M.send_shown(ops, full)
			end
		elseif d.dx ~= 0 or d.dz ~= 0 or d.rehost then
			local ops = {}
			for n in pairs(d.nodes) do
				local p = doc.ents[n] and doc.ents[n].ints
				local o = d.nd and d.nd[n]
				if p then
					ops[#ops + 1] = {op = "set", ent = {id = n,
							ints = {x = p.x + (o and o[1] or d.dx),
							z = p.z + (o and o[2] or d.dz)}}}
				end
			end
			kept_ops(d, ops)
			for id in pairs(d.inst) do
				local i = doc.ents[id] and doc.ents[id].ints
				local it = E.inst_data[id]
				if i and it and it.hosted and d.rehost then
					ops[#ops + 1] = {op = "set", ent = {id = id,
							ints = {host = d.rehost.wall,
							along = math.floor(d.rehost.along + 0.5)}}}
				elseif i and it and it.hosted then
					ops[#ops + 1] = {op = "set", ent = {id = id,
							ints = {along = math.floor(it.along + 0.5)}}}
				elseif i then
					ops[#ops + 1] = {op = "set", ent = {id = id,
							ints = {x = i.x + d.dx, z = i.z + d.dz}}}
				end
			end
			M.send_shown(ops, full)
		end
	end

	-- [FP_MOVE_FAST] A move's batch shown at once: into the replica, a
	-- rebuild next frame unless the scene was built in full with the move
	-- (built), and the props; the server's echo of it changes nothing, and
	-- a refusal puts it back (doc.apply_sets)
	function M.send_shown(ops, built)
		send(ops, nil, true)
		S.dirty = not built
		S.props_stale = true
	end

	-- **The movement keys move the selection** in the plan view (a
	-- playtest, 2026-10-06): by (dx, dz) as a drag would, one undo step.
	-- False when nothing selected moves.
	function M.move_selection(dx, dz)
		if S.drag then
			return true
		end
		local sel = S.sel
		if S.tool == "node" then
			sel = {}
			for n in pairs(S.nodes) do
				sel[n] = "node"
			end
		end
		local inst, nodes = moved_by(sel)
		if not next(inst) and not next(nodes) then
			return false
		end
		local d = {kind = "move", inst = inst, nodes = nodes, dx = dx, dz = dz,
				moved = true, keys = true}
		M.drag_slides(d, sel)
		M.slide_deltas(d)
		S.drag = d
		M.move_t = buildat.get_time_us()
		if M.probe_what then
			M.probe_start(next(inst) or next(nodes))
		end
		-- One undo step for the selection's moves by the keys (user)
		doc.merge_tag = "keys " .. M.sel_gen
		end_drag()
		doc.merge_tag = nil
		return true
	end

	local function click()
		local t = S.press.target
		-- **With no tool, a click uses what it is on** (user, 2026-10-02),
		-- as a right click does: nothing else is the left button's then
		if not S.tool then
			local id, kind = M.use_pointed()
			if id then
				M.use_id(id, kind)
			end
			return
		end
		if S.calib and not S.calib.measured then
			local x, z = cursor_floor()
			if x then
				local c = S.calib
				c.pts[#c.pts + 1] = {x, z}
				if #c.pts == 2 then
					c.measured = geom.len(c.pts[2][1] - c.pts[1][1],
							c.pts[2][2] - c.pts[1][2])
					refresh_panels()
				end
			end
			return
		end
		if S.linking then
			-- A lamp clicked joins the switch's lamps, or leaves them
			local sw = doc.ents[S.linking]
			if t and t.kind == "instance" and sw and is_lamp(t.id) then
				local l, found = {}, false
				for _, v in ipairs(sw.lists.lamps) do
					if v == t.id then
						found = true
					else
						l[#l + 1] = v
					end
				end
				if not found then
					l[#l + 1] = t.id
				end
				send({{op = "set", ent = {id = S.linking, lists = {lamps = l}}}})
				doc.notice(found and "Unlinked" or "Linked")
			elseif t then
				doc.notice("That is not a lamp: a lamp is a box or voxels of a " ..
						"lamp material")
			end
			return
		end
		if S.tool == "select" then
			-- **What is selected, tapped again, opens its properties** when
			-- they are folded away (user, the sixth round): a phone has no
			-- other way to them from the view
			if t and S.sel[t.id] and not S.shift and panel.folded("props") then
				panel.toggle_fold("props")
			end
			if not S.shift then
				S.sel = {}
				S.primary = nil
			end
			if t then
				if S.sel[t.id] and S.shift then
					S.sel[t.id] = nil
				else
					S.sel[t.id] = t.kind
					S.sel_face[t.id] = t.side
					S.primary = t.id
					palette_follows(t)
				end
			end
			refresh_panels()
		elseif S.tool == "node" then
			-- A double click on an edge, off its nodes: a node into it
			local now = buildat.get_time_us()
			local double = S.last_node_click and
					now - S.last_node_click.t < 400000 and
					geom.len(S.mx - S.last_node_click.mx,
							S.my - S.last_node_click.my) < M.px(8)
			S.last_node_click = {t = now, mx = S.mx, my = S.my}
			if double and not t and doc.can("edit") then
				local x, z, ref = snapped_point(nil)
				if x and ref.edge and M.insert_node(x, z, ref) then
					S.last_node_click = nil
					return
				end
			end
			if not S.shift then
				S.nodes = {}
			end
			if t and t.kind == "node" then
				S.nodes[t.id] = not S.nodes[t.id] or nil
			end
			refresh_panels()
		elseif S.tool == "box" and sel_count() > 0 then
			-- The selected object clicked: nothing; elsewhere: let go of it,
			-- and the next click places
			if not t then
				S.sel, S.sel_face, S.primary = {}, {}, nil
				refresh_panels()
			end
		elseif S.tool == "box" then
			if not doc.can("edit") then
				doc.notice("Viewing only: no edit privilege")
				return
			end
			local x, z = snapped_point(nil)
			if x then
				if S.shape == "stairs" then
					add_box(x, z, S.stairs.w, nil)
				elseif S.shape == "lamp" then
					add_box(x, z, 250, 250)
				else
					add_box(x, z, S.box.w, S.box.d)
				end
			end
		elseif S.tool == "hosted" then
			-- **What is put in is not selected** (user, the tutorial: the
			-- door's properties hid the Kind of the next one). One clicked
			-- is, for its properties; any other click lets go of it.
			local s = pick_surface()
			local e = s and s.kind == "instance" and doc.ents[s.id]
			S.sel, S.sel_face, S.primary = {}, {}, nil
			if e and e.ints.host ~= 0 then
				S.sel[s.id] = "instance"
				S.sel_face[s.id] = s.side
				S.primary = s.id
				palette_follows({kind = "instance", id = s.id, side = s.side})
			elseif s and s.kind == "wall" and doc.can("edit") then
				add_hosted(s.id, s.x, s.z, s.side)
			end
			refresh_panels()
		elseif E.tools[S.tool] and E.tools[S.tool].press then
			E.tools[S.tool].press()
		elseif S.tool == "voxel" then
			voxel_edit(S.ctrl, S.shift)
		elseif S.tool == "wall" or S.tool == "room" then
			if not doc.can("edit") then
				doc.notice("Viewing only: no edit privilege")
				return
			end
			local from = S.tool == "wall" and S.draw or
					(S.corners and S.corners[#S.corners])
			local x, z, ref = snapped_point(from)
			if not x then
				return
			end
			S.typed = ""
			if S.tool == "room" then
				S.corners = S.corners or {}
				local first = S.corners[1]
				if first and #S.corners >= 3 and
						geom.len(x - first.x, z - first.z) <= snap_radius() then
					add_room(S.corners)
					S.corners = nil
				else
					S.corners[#S.corners + 1] = {x = x, z = z, ref = ref}
				end
			elseif S.draw then
				if S.draw.ref and S.draw.ref.node and not real_id(S.draw.ref.node) then
					-- The last segment's node has not come back yet
					return
				end
				add_wall(S.draw, x, z, ref)
			else
				S.draw = {x = x, z = z, ref = ref}
			end
		elseif S.tool == "paint" then
			local s = pick_surface()
			if s and doc.can("edit") then
				if s.kind == "instance" and E.inst_data[s.id].voxel then
					-- One voxel takes the material
					local hit = voxel_ray(s.id)
					if hit then
						doc.set_voxels(doc.ents[s.id].ints.def, {[doc.voxel_key(hit[1],
								hit[2], hit[3])] = default_material()})
					end
					return
				elseif s.kind == "instance" then
					send({{op = "set", ent = {id = doc.ents[s.id].ints.def,
							ints = {mat = default_material()}}}})
					return
				end
				local f = s.kind == "floor" and "mat_floor" or
						s.kind == "ceiling" and "mat_ceiling" or
						s.side == "left" and "mat_left" or
						s.side == "right" and "mat_right" or "mat_core"
				send({{op = "set", ent = {id = s.id,
						ints = {[f] = default_material()}}}})
			end
		end
	end

	-- The use key's, defined with it below

	-- Whether the 3D camera looks as the plan does: straight down, and north
	-- up within 10 degrees -- the plan has no other way up
	plan_facing = function()
		return S.pitch >= 89.5
	end

	plan_aligned = function()
		local off = (S.yaw % 360 + 180) % 360 - 180
		return plan_facing() and math.abs(off) <= 10
	end

	-- What a right or middle drag in 3D turns about or pans by: the point the
	-- pointer is on, in world metres -- the thing under it, or where its ray
	-- meets the floor -- or nil when it points at the sky. orbit: pointing
	-- at none of the plan, the middle of the box round the current
	-- layout's rooms, up to
	-- half their highest ceiling (user). An orbit about the floor, or the
	-- ground, turns about half the room's height over it (user)
	-- The middle of the box round the current layout's rooms (room_data is
	-- its, being built last), up to half their highest ceiling; nil
	-- without rooms
	function M.plan_middle()
		if not next(E.room_data) then
			return nil
		end
		local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
		local top = 0
		for id, r in pairs(E.room_data) do
			for _, p in ipairs(r.pts) do
				x0, z0 = math.min(x0, p[1]), math.min(z0, p[2])
				x1, z1 = math.max(x1, p[1]), math.max(z1, p[2])
			end
			top = math.max(top, room_ceiling(doc.ents[id]))
		end
		return {x = W((x0 + x1) / 2), y = W(top / 2), z = W((z0 + z1) / 2)}
	end

	local function camera_pivot(orbit)
		local o, d = cursor_ray()
		local s = pick_surface()
		if s and s.t then
			local p = {x = o.x + d.x * s.t, y = o.y + d.y * s.t, z = o.z + d.z * s.t}
			if orbit and s.kind == "floor" then
				p.y = W(room_ceiling(doc.ents[s.id]) / 2)
			end
			return p
		end
		if orbit and next(E.room_data) then
			return M.plan_middle()
		end
		local x, z, t = ray_at_height(0)
		if x then
			return {x = o.x + d.x * t, z = o.z + d.z * t,
					y = orbit and W(settings().ceiling / 2) or 0}
		end
		return nil
	end

	function M.mouse_down(button)
		if S.paused then
			return
		end
		-- Walking on a touchscreen is the fingers' (M.touch_begin)
		if S.touch and S.view == "walk" and not over_ui() then
			return
		end
		-- A copy being put into a wall (copy_selected): a click on one puts
		-- it there, and a click on nothing does nothing
		if S.place_copy and button == magic.MOUSEB_LEFT and not over_ui() and
				not S.captured then
			local s = pick_surface()
			if s and s.kind == "wall" and doc.can("edit") then
				M.place_copy(s.id, s.x, s.z, s.side)
			end
			S.swallow_up = true
			return
		end
		if crosshair_view() and not S.captured and not over_ui() and
				button == magic.MOUSEB_LEFT and (S.tool or not M.use_pointed()) then
			-- A click on the view goes up into the crosshair; with no tool,
			-- one on what can be used uses it (click)
			S.crosshair = true
			update_capture()
			S.swallow_up = true
			return
		end
		if S.captured and S.tool ~= "voxel" and button == magic.MOUSEB_RIGHT then
			-- Walking: the right button is Luanti's use, a door or a switch;
			-- with neither at the crosshair, it clears the selection as a
			-- right click does elsewhere (user)
			-- (the target at the crosshair, not the selected switch E takes)
			local s = pick_surface(true)
			if S.tool ~= "select" or s and s.kind == "instance" and
					use_target() == s.id then
				use()
			else
				S.sel, S.primary = {}, nil
				S.palette_collapsed = true
				S.dirty = true
				refresh_panels()
			end
			return
		end
		if S.captured and S.tool == "voxel" then
			-- Luanti's: the left button digs, the right one places -- and
			-- **held, a box** (user): from the cell pressed to the one let go
			-- on, both in; released where nothing is, nothing. A new volume
			-- when none is selected, on the press, as before.
			if button ~= magic.MOUSEB_LEFT and button ~= magic.MOUSEB_RIGHT then
				return
			end
			-- The other button while a box is held gives the box up, as Esc
			-- does (user); its own release is then nothing either
			if S.voxel_box then
				S.voxel_box.cancelled = true
				S.dirty = true
				return
			end
			if not voxel_target() then
				voxel_edit(button == magic.MOUSEB_LEFT, S.shift)
				return
			end
			local mode = button == magic.MOUSEB_RIGHT and "place" or
					S.shift and "paint" or "dig"
			local id, c = M.voxel_cell(mode)
			if id then
				S.voxel_box = {mode = mode, id = id, a = c, button = button}
				S.dirty = true
			end
			return
		end
		-- **The voxel tool at the pointer in 3D** (user): the left button
		-- does what the panel's Click says -- place, dig or paint -- Ctrl
		-- digs and Shift paints; held, a box. The right one orbits as ever.
		-- Pressed on nothing of the volume, it is a press as any other, so
		-- a finger's drag moves the view.
		if S.tool == "voxel" and S.view == "3d" and not S.captured and
				button == magic.MOUSEB_LEFT and not over_ui() then
			local mode = S.ctrl and "dig" or S.shift and "paint" or S.voxel_mode
			if S.voxel_box then
				S.voxel_box.cancelled = true
				S.dirty = true
				return
			end
			if not voxel_target() then
				if mode == "place" then
					voxel_edit(false, false)
					return
				end
			else
				local id, c = M.voxel_cell(mode)
				if id then
					S.voxel_box = {mode = mode, id = id, a = c, button = button}
					S.dirty = true
					return
				end
			end
		end
		if button == magic.MOUSEB_RIGHT then
			if S.draw or S.corners then
				S.draw = nil
				S.corners = nil
				S.typed = ""
				return
			end
			-- **A right click uses what it is on** (user), as the use key
			-- does (M.use_pointed): in 3D and walking, a right press that the
			-- mouse then hardly moves -- orbiting and turning are the right
			-- drag
			if not over_ui() then
				local id, kind = M.use_pointed()
				S.right_click = {moved = 0, use = id, kind = kind}
			end
			if S.view == "2d" and not over_ui() then
				-- Into 3D as if it had been 3D all along ([FP_ORBIT_2D]): the
				-- camera straight above the plan's middle, looking down, as
				-- high as makes its floor the plan's; then this is an orbit
				local d = S.span / (2 * math.tan(math.rad(cam3d.fov) / 2))
				S.pos = {x = W(S.cx), y = W(d), z = W(S.cz)}
				S.yaw, S.pitch = 0, 90
				set_view("3d")
			end
			if S.view == "walk" and not over_ui() then
				-- Walking at the pointer: a right drag turns, as the mouse does
				-- in the crosshair
				S.looking = true
				magic.input:SetMouseMode(magic.MM_RELATIVE)
			end
			if S.view == "3d" then
				-- Orbiting what is pointed, or the volume on its own
				local p = S.alone and M.alone_center() or camera_pivot(true)
				if p then
					S.orbit = p
					magic.input:SetMouseMode(magic.MM_RELATIVE)
				end
			end
			return
		end
		if button == magic.MOUSEB_MIDDLE then
			-- The plan and the 3D camera pan
			if S.view == "2d" then
				S.panning = true
			elseif S.view == "walk" and not S.captured then
				-- And a middle drag walks, as WASD do: up is forward
				if not over_ui() then
					S.walk_drag = true
					magic.input:SetMouseMode(magic.MM_RELATIVE)
				end
			elseif not S.captured then
				local p = camera_pivot()
				S.pan3d = {dist = p and geom.len(geom.len(p.x - S.pos.x,
						p.y - S.pos.y), p.z - S.pos.z) or 5}
				magic.input:SetMouseMode(magic.MM_RELATIVE)
			end
			return
		end
		begin_press(button)
	end

	function M.mouse_up(button)
		local vb = S.voxel_box
		if vb and vb.cancelled then
			-- Given up by the other button: both buttons' releases are
			-- nothing, and the box goes with the one that started it
			if button == vb.button then
				S.voxel_box = nil
			end
			return
		end
		if vb and button == vb.button then
			S.voxel_box = nil
			S.dirty = true
			local id, c = M.voxel_box_end(vb)
			if id == vb.id then
				M.voxel_box(vb.mode, id, vb.a, c)
			end
			return
		end
		if button == magic.MOUSEB_RIGHT and S.right_click then
			local rc = S.right_click
			S.right_click = nil
			if rc.use and rc.moved < 5 and doc.ents[rc.use] then
				S.orbit, S.pan3d = nil, nil
				if S.looking then
					S.looking = false
				end
				magic.input:SetMouseMode(magic.MM_ABSOLUTE)
				M.use_id(rc.use, rc.kind)
				return
			end
			-- **A right click on what has no right click action clears the
			-- selection** (user), and folds the palette: the view cleared
			-- of its panels. The drag it may have started ends below.
			if rc.moved < 5 and S.tool == "select" and not S.captured then
				S.sel, S.primary = {}, nil
				S.palette_collapsed = true
				S.dirty = true
				refresh_panels()
			end
		end
		if S.swallow_up then
			S.swallow_up = false
			return
		end
		-- The first finger's lift: a drag of the view, or a gesture of two,
		-- ends without a click
		if S.touch_cam or S.gesture then
			S.touch_cam, S.panning, S.orbit, S.press = nil, false, nil, nil
			S.pan3d = nil
			return
		end
		if S.captured and (S.tool == "voxel" or button ~= magic.MOUSEB_LEFT) then
			return
		end
		if button == magic.MOUSEB_MIDDLE and S.walk_drag then
			S.walk_drag = false
			magic.input:SetMouseMode(magic.MM_ABSOLUTE)
			return
		end
		if (button == magic.MOUSEB_RIGHT and S.orbit) or
				(button == magic.MOUSEB_MIDDLE and S.pan3d) then
			local orbited = S.orbit
			S.orbit, S.pan3d = nil, nil
			magic.input:SetMouseMode(magic.MM_ABSOLUTE)
			if orbited and plan_aligned() and not S.no_plan_return then
				-- Back to the plan, where its floor is the view's: the middle
				-- where the view's middle meets the floor, the span what the
				-- camera's height sees
				local o = S.pos
				local f = {geom.rot(0, 0, 1, S.pitch, S.yaw, 0)}
				local t = f[2] < -1e-6 and -o.y / f[2] or 0
				S.cx = (o.x + f[1] * t) * 1000
				S.cz = (o.z + f[3] * t) * 1000
				S.span = math.max(500, math.min(200000, math.abs(o.y) * 1000 * 2 *
						math.tan(math.rad(cam3d.fov) / 2)))
				set_view("2d")
			end
			return
		end
		if button == magic.MOUSEB_RIGHT or (button == magic.MOUSEB_MIDDLE and
				S.looking) then
			S.panning = false
			if S.looking then
				S.looking = false
				magic.input:SetMouseMode(magic.MM_ABSOLUTE)
			end
			return
		end
		if button == magic.MOUSEB_MIDDLE then
			S.panning = false
			return
		end
		if button ~= magic.MOUSEB_LEFT or not S.press then
			return
		end
		if S.drag then
			end_drag()
		else
			click()
		end
		if M.after_drag then
			M.after_drag = false
			doc.unlock()
		end
		S.press = nil
	end

	function M.mouse_move(x, y, dx, dy)
		if S.right_click then
			S.right_click.moved = S.right_click.moved + math.abs(dx) + math.abs(dy)
		end
		if S.orbit then
			-- The camera goes round the point with the view: its offset from
			-- the point is held in the camera's own frame, so the point stays
			-- where it was on the screen
			local p = S.orbit
			local ox, oy, oz = geom.unrot(S.pos.x - p.x, S.pos.y - p.y,
					S.pos.z - p.z, S.pitch, S.yaw, 0)
			-- A finger's orbit (the emulated mouse's) at half the mouse's
			-- speed (user)
			local k = 0.3 * S.mouse_sens / 100 * (S.touch and 0.5 or 1)
			S.yaw = S.yaw + dx * k
			S.pitch = math.max(-90, math.min(90, S.pitch + dy * k))
			local wx, wy, wz = geom.rot(ox, oy, oz, S.pitch, S.yaw, 0)
			S.pos = {x = p.x + wx, y = p.y + wy, z = p.z + wz}
			return
		end
		if S.pan3d then
			-- Across the view, as far as the pointed point moves under the
			-- pointer
			local _, h = screen_size()
			local k = S.pan3d.dist * 2 * math.tan(math.rad(cam3d.fov) / 2) / h *
					S.pan_speed / 100
			local rx, ry, rz = geom.rot(1, 0, 0, S.pitch, S.yaw, 0)
			local ux, uy, uz = geom.rot(0, 1, 0, S.pitch, S.yaw, 0)
			if S.pan_xz then
				-- Along the ground: the view's right and its forward, both
				-- level, the ground grabbed and pulled
				local fx, _, fz = geom.rot(0, 0, 1, 0, S.yaw, 0)
				local rl = geom.len(rx, rz)
				if rl > 1e-6 then
					rx, rz = rx / rl, rz / rl
				end
				ry = 0
				ux, uy, uz = fx, 0, fz
			end
			S.pos = {x = S.pos.x - (rx * dx - ux * dy) * k,
					y = S.pos.y - (ry * dx - uy * dy) * k,
					z = S.pos.z - (rz * dx - uz * dy) * k}
			return
		end
		if S.looking then
			local k = 0.15 * S.mouse_sens / 100
			S.yaw = S.yaw + dx * k
			S.pitch = math.max(-89, math.min(89, S.pitch + dy * k))
			return
		end
		if S.walk_drag then
			-- 10 mm a pixel, Shift two and a half times that as it runs
			local mm = S.shift and 25 or 10
			walk(0, -dy, dx, mm)
			return
		end
		S.mx, S.my = x, y
		if S.gesture then
			return
		end
		-- [FP_TOUCH] 3: a finger dragged anywhere but on the selection moves
		-- the view: the plan pans, the 3D camera orbits. The object tool's
		-- drag is its footprint's.
		if S.touch and S.press and not S.drag and S.tool ~= "box" and
				geom.len(x - S.press.mx, y - S.press.my) > M.px(DRAG_PX) then
			local t = S.press.target
			if not (t and (S.sel[t.id] or S.nodes[t.id])) then
				S.press = nil
				S.touch_cam = true
				if S.view == "2d" then
					S.panning = true
				else
					-- One finger pans, as the middle drag does (user: two
					-- orbit, which is the less often wanted)
					local p = camera_pivot()
					S.pan3d = {dist = p and geom.len(geom.len(p.x - S.pos.x,
							p.y - S.pos.y), p.z - S.pos.z) or 5}
				end
			end
		end
		if S.panning and S.view == "2d" then
			local k = mm_per_px()
			S.cx = S.cx - dx * k
			S.cz = S.cz + dy * k
		end
		if S.press and not S.drag and geom.len(x - S.press.mx, y - S.press.my) >
				M.px(DRAG_PX) then
			start_drag()
			lock_drag()
		end
		if S.drag then
			update_drag()
		end
	end

	-- The previews go out at most every PREVIEW_SECONDS
	stream_drag = function(dt)
		preview_timer = preview_timer + dt
		local d = S.drag
		if d and d.moved and (d.kind == "node" or d.kind == "move") and
				preview_timer >= PREVIEW_SECONDS then
			preview_timer = 0
			doc.preview(drag_preview(d))
		end
	end

	function M.mouse_wheel(wheel)
		if over_ui() then
			local sc = magic.ui.scale
			panel.nudge_at({toolbar, props, palette_win, E.pause_win, picker_win},
					S.mx / sc, S.my / sc, wheel > 0 and 1 or -1, S.shift)
			return
		end
		-- **A notch is a share of the distance** (user): 0.8 of it in and
		-- 1.25 out, to the speed setting's power -- the wheel is in notches,
		-- the web's in tenths (its SDL port counts them so)
		local notches = math.max(-10, math.min(10,
				S.web and wheel / 10 or wheel))
		local f = 0.8 ^ (notches * S.wheel_speed / 100)
		if S.view == "walk" then
			-- Walking: a metre a notch along the look, as it was
			local yaw, pitch = math.rad(S.yaw), math.rad(S.pitch)
			S.pos = {x = S.pos.x + math.sin(yaw) * math.cos(pitch) * notches,
					y = S.pos.y - math.sin(pitch) * notches,
					z = S.pos.z + math.cos(yaw) * math.cos(pitch) * notches}
		elseif S.alone and S.alone.dist then
			S.alone.dist = M.alone_clamp(S.alone.dist * f)
		elseif S.view == "2d" then
			-- Zoom about the cursor: the point under it stays under it
			local x0, z0 = cursor_floor()
			S.span = math.max(500, math.min(200000, S.span * f))
			local x1, z1 = cursor_floor()
			S.cx, S.cz = S.cx + x0 - x1, S.cz + z0 - z1
		else
			-- The distance: to what the pointer is on, else to the middle
			-- of the layout's rooms
			local o, d = cursor_ray()
			local s = pick_surface()
			local dist = s and s.t
			if not dist and next(E.room_data) then
				local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
				for _, rd in pairs(E.room_data) do
					for _, p in ipairs(rd.pts) do
						x0, z0 = math.min(x0, p[1]), math.min(z0, p[2])
						x1, z1 = math.max(x1, p[1]), math.max(z1, p[2])
					end
				end
				dist = geom.len(geom.len(W((x0 + x1) / 2) - S.pos.x, S.pos.y),
						W((z0 + z1) / 2) - S.pos.z)
			end
			dist = dist or 5
			-- Not through what is pointed at: 0.3 m short of it at most
			local step = math.min(dist * (1 - f), math.max(0, dist - 0.3))
			-- Along the view as it always was, or toward the cursor
			local dx, dy, dz = d.x, d.y, d.z
			if not S.zoom_to_cursor then
				local yaw, pitch = math.rad(S.yaw), math.rad(S.pitch)
				dx, dy, dz = math.sin(yaw) * math.cos(pitch), -math.sin(pitch),
						math.cos(yaw) * math.cos(pitch)
			end
			S.pos = {x = S.pos.x + dx * step, y = S.pos.y + dy * step,
					z = S.pos.z + dz * step}
		end
	end

	-- **Fingers** ([FP_TOUCH] 3). The first is also the left mouse button,
	-- which SDL makes of it; these see every finger. Two pinch to zoom and
	-- move together to pan, and whatever the first began as the mouse is
	-- dropped. Walking: a finger put down at the lower left is a stick, and
	-- any other turns the view.
	function M.touch_begin(id, x, y)
		if doc.ui_hidden then
			M.show_ui()
			return
		end
		local sc = magic.ui.scale
		local on_ui = panel.popup_open() or panel.over({toolbar, props,
				palette_win, E.pause_win, picker_win, place.win, S.touch_bar,
				doc.accounts.page, doc.accounts.frame}, x / sc, y / sc)
		S.fingers[id] = {x = x, y = y, x0 = x, y0 = y, t0 = buildat.get_time_us(),
				ui = on_ui}
		if on_ui or S.paused then
			return
		end
		local w, h = screen_size()
		if S.view == "walk" then
			if not S.stick and x < w * 0.45 and y > h * 0.55 then
				S.fingers[id].stick = true
				S.stick = {f = 0, r = 0}
			end
			return
		end
		local n = 0
		for _, f in pairs(S.fingers) do
			if not f.ui then
				n = n + 1
			end
		end
		if n == 2 then
			if S.drag then
				S.drag = nil
				doc.unlock()
			end
			S.press, S.touch_cam, S.panning, S.orbit = nil, nil, false, nil
			S.pan3d = nil
			if S.voxel_box then
				S.voxel_box = nil
			end
			S.dirty = true
			-- Two fingers in 3D orbit round the plan's middle (a finger's
			-- own point is what should move, user) and pinch toward it
			local p = S.alone and M.alone_center() or
					S.view == "3d" and (M.plan_middle() or camera_pivot(true))
			S.gesture = {pivot = p or nil, dist = p and geom.len(geom.len(
					p.x - S.pos.x, p.y - S.pos.y), p.z - S.pos.z) or 5}
		end
	end

	function M.touch_move(id, x, y, dx, dy)
		local f = S.fingers[id]
		if not f or f.ui then
			return
		end
		local px, py = f.x, f.y
		f.x, f.y = x, y
		if geom.len(x - f.x0, y - f.y0) > M.px(DRAG_PX) then
			f.moved = true
		end
		local w, h = screen_size()
		if f.stick then
			-- A tenth of the screen's short side is full speed
			local r = math.min(w, h) * 0.1
			S.stick.r = math.max(-1, math.min(1, (x - f.x0) / r))
			S.stick.f = math.max(-1, math.min(1, -(y - f.y0) / r))
			return
		end
		if S.view == "walk" then
			-- The mouse sensitivity setting's, at half of 0.2 (user)
			local k = 0.1 * S.mouse_sens / 100
			S.yaw = S.yaw + dx * k
			S.pitch = math.max(-89, math.min(89, S.pitch + dy * k))
			return
		end
		if not S.gesture then
			return
		end
		local o = nil
		for oid, of in pairs(S.fingers) do
			if oid ~= id and not of.ui then
				o = of
			end
		end
		if not o then
			return
		end
		-- The pair's middle moves half as far as this finger did, and their
		-- distance changes by the pinch
		local d0 = math.max(1, geom.len(px - o.x, py - o.y))
		local d1 = math.max(1, geom.len(x - o.x, y - o.y))
		local mdx, mdy = (x - px) / 2, (y - py) / 2
		if S.view == "2d" then
			S.mx, S.my = (x + o.x) / 2, (y + o.y) / 2
			local x0, z0 = cursor_floor()
			S.span = math.max(500, math.min(200000, S.span * d0 / d1))
			local x1, z1 = cursor_floor()
			local k = mm_per_px()
			S.cx = S.cx + (x0 or 0) - (x1 or 0) - mdx * k
			S.cz = S.cz + (z0 or 0) - (z1 or 0) + mdy * k
		else
			-- The pair's move orbits, as the right drag does, at a
			-- finger's speed
			local p = S.gesture.pivot
			if p then
				local ox, oy, oz = geom.unrot(S.pos.x - p.x, S.pos.y - p.y,
						S.pos.z - p.z, S.pitch, S.yaw, 0)
				local k = 0.15 * S.mouse_sens / 100
				S.yaw = S.yaw + mdx * k
				S.pitch = math.max(-90, math.min(90, S.pitch + mdy * k))
				local wx, wy, wz = geom.rot(ox, oy, oz, S.pitch, S.yaw, 0)
				S.pos = {x = p.x + wx, y = p.y + wy, z = p.z + wz}
			end
			-- Toward what the pair looks at, by as much as the pinch spreads:
			-- twice apart is half as far
			local fx, fy, fz = geom.rot(0, 0, 1, S.pitch, S.yaw, 0)
			local zoom = S.gesture.dist * (1 - d0 / d1)
			S.gesture.dist = S.gesture.dist - zoom
			if S.alone and S.alone.dist then
				S.gesture.dist = M.alone_clamp(S.gesture.dist)
				S.alone.dist = S.gesture.dist
			end
			S.pos = {x = S.pos.x + fx * zoom, y = S.pos.y + fy * zoom,
					z = S.pos.z + fz * zoom}
		end
	end

	-- A finger held still: the right button's, for what a finger can do
	-- with it -- a wall or a room being drawn ends, and a door or a switch
	-- is used
	function M.long_press()
		S.press = nil
		S.swallow_up = true
		if S.draw or S.corners then
			S.draw, S.corners, S.typed = nil, nil, ""
			doc.notice("Drawing ended")
		else
			use()
		end
	end

	function M.touch_end(id, x, y)
		local f = S.fingers[id]
		S.fingers[id] = nil
		if f and f.stick then
			S.stick = nil
		end
		-- Walking, a tap is the left click at the finger, as the guide says
		-- ([FP_CEILING_MATERIAL]: Select and Material did nothing): with no
		-- tool, a door, a window or a switch is used; held, it is anyway
		if f and S.view == "walk" and not f.stick and not f.ui and
				not f.moved and not S.paused and
				buildat.get_time_us() - f.t0 < 500000 then
			S.mx, S.my = x, y
			begin_press(magic.MOUSEB_LEFT)
			if S.press then
				click()
				S.press = nil
			end
		end
		if not next(S.fingers) then
			S.gesture = nil
		end
	end

	-- The next other user's view becomes this one's
	local go_to_index = 0
	local function go_to_next_user()
		local peers = {}
		for peer, o in pairs(doc.others) do
			if o.p then
				peers[#peers + 1] = peer
			end
		end
		if #peers == 0 then
			doc.notice("Nobody else is here")
			return
		end
		table.sort(peers)
		go_to_index = go_to_index % #peers + 1
		local o = doc.others[peers[go_to_index]]
		local p = place.presence(o.p, true)
		if p.view >= 1 then
			S.pos = {x = p.px / 1000, y = p.py / 1000, z = p.pz / 1000}
			S.yaw, S.pitch = p.yaw / 1000, p.pitch / 1000
			set_view("3d")
		else
			S.cx, S.cz, S.span = p.px, p.pz, math.max(500, p.py)
			set_view("2d")
		end
		doc.notice("At " .. o.name .. "'s view")
	end

	-- Lamps all on or all off: off if any of them is on, else on. For the
	-- plan's editors for everybody; a viewer switches them for themselves.
	function M.flip_lamps(lamps)
		local any = false
		for _, l in ipairs(lamps) do
			any = any or lamp_on(l)
		end
		if doc.can("edit") then
			local ops = {}
			for _, l in ipairs(lamps) do
				S.local_on[l] = nil
				ops[#ops + 1] = {op = "set", ent = {id = l, ints = {on = any and 0 or 1}}}
			end
			send(ops)
		else
			for _, l in ipairs(lamps) do
				S.local_on[l] = not any
			end
			S.dirty = true
		end
	end

	-- A switch's lamps
	local function flip_switch(id)
		local lamps = doc.ents[id].lists.lamps
		if #lamps == 0 then
			doc.notice("This switch has no lamps; link some to it")
			return
		end
		M.flip_lamps(lamps)
	end
	M.flip_switch = flip_switch

	-- **What can be used**, by the use key and by a right click alike
	-- (user, 2026-10-02): a door, a window, a switch or a lamp. An editor's
	-- use is everybody's; a viewer's is their own.
	-- What is under the pointer to use -- all of a door or a window, its
	-- frame and its hole too: an open door is shut by pointing through
	-- it. Its id and kind, or nil.
	function M.use_pointed()
		local s = pick_surface(true)
		local e = s and s.kind == "instance" and doc.ents[s.id]
		if not e then
			return nil
		end
		local kind = doc.ents[e.ints.def].ints.kind
		if kind == KIND.switch or kind == KIND.door or kind == KIND.window then
			return s.id, kind
		end
		-- A lamp on its own (user: as a door or a switch)
		if is_lamp(s.id) then
			return s.id, "lamp"
		end
		return nil
	end
	-- And for the use key, with nothing under the pointer, the switch
	-- selected: one being linked to its lamps is tried without pointing
	use_target = function()
		local id, kind = M.use_pointed()
		if id then
			return id, kind
		end
		local p = S.primary and doc.ents[S.primary]
		if p and p.type == "instance" and
				doc.ents[p.ints.def].ints.kind == KIND.switch then
			return S.primary, KIND.switch
		end
		return nil
	end
	function M.use_id(id, kind)
		if kind == KIND.switch then
			flip_switch(id)
		elseif kind == "lamp" then
			M.flip_lamps({id})
		elseif kind == KIND.window then
			M.toggle_blinds(id)
		else
			M.toggle_open(id)
		end
	end
	use = function()
		local id, kind = use_target()
		if id then
			M.use_id(id, kind)
		end
	end

	-- Shut to 90 degrees open, anything open to shut: the plan's for an
	-- editor, the viewer's own otherwise
	function M.toggle_open(id)
		local open = open_amount(id) > 0 and 0 or 1000
		if doc.can("edit") then
			S.local_open[id] = nil
			send({{op = "set", ent = {id = id, ints = {open = open}}}})
		else
			S.local_open[id] = open
			S.dirty = true
		end
	end
	-- A window's blind all the way down, or up from however far it is
	-- (user, 2026-10-02: a window is used by its blind, not its sashes)
	function M.toggle_blinds(id)
		local down = M.blinds_amount(id) > 0 and 0 or 1000
		if doc.can("edit") then
			S.local_blinds[id] = nil
			send({{op = "set", ent = {id = id, ints = {blinds = down}}}})
		else
			S.local_blinds[id] = down
			S.dirty = true
		end
	end

	-- A length typed while drawing: Enter draws the segment that long, in the
	-- direction the cursor gives
	local function commit_typed()
		local v = tonumber(S.typed)
		S.typed = ""
		local from = S.draw or (S.corners and S.corners[#S.corners])
		if not v or v <= 0 or not from then
			return
		end
		local x, z = snapped_point(from)
		if not x then
			return
		end
		local dx, dz = x - from.x, z - from.z
		local l = geom.len(dx, dz)
		if l == 0 then
			return
		end
		x = math.floor(from.x + dx / l * v + 0.5)
		z = math.floor(from.z + dz / l * v + 0.5)
		if S.draw then
			add_wall(S.draw, x, z, {})
		else
			S.corners[#S.corners + 1] = {x = x, z = z, ref = {}}
		end
	end

	-- Up and Down in a numeric field step it; whether the key was that
	function M.nudge(key, shift)
		if key ~= magic.KEY_UP and key ~= magic.KEY_DOWN then
			return false
		end
		return panel.nudge_focused(key == magic.KEY_UP and 1 or -1, shift)
	end

	-- Down one level ([FP_ESC]): the pause menu, the crosshair, what is in
	-- progress; at the bottom of a view, the pause menu. Esc's, and the
	-- touch bar's Cancel ([FP_TOUCH] 4).
	function M.escape()
		if panel.popup_open() then
			-- Its popup's, which Urho3D closed
			return
		elseif S.voxel_box then
			-- The box given up; the button's release does nothing then
			S.voxel_box = nil
			S.dirty = true
		elseif S.drag then
			-- **A drag given up** (user): nothing moves, and the button's
			-- release that follows is not a click
			local was = S.drag
			S.drag, S.press = nil, nil
			if was.kind == "node" or was.kind == "move" then
				doc.unlock()
			end
			S.swallow_up = true
			S.dirty = true
			refresh_panels()
		elseif S.place_copy then
			S.place_copy = nil
			S.dirty = true
		elseif S.alone then
			M.leave_alone()
		elseif S.paused then
			close_pause()
		elseif S.picker and S.picker.fit and S.picker.fit.adding then
			S.picker.fit.adding = false
			build_picker()
		elseif S.picker or S.replace then
			close_picker()
		elseif S.type_open then
			S.type_open = false
			refresh_panels()
		elseif S.captured then
			S.crosshair = false
			update_capture()
		elseif S.draw or S.corners then
			S.draw = nil
			S.corners = nil
			S.typed = ""
		elseif tool_escape() then
			-- the tool's own
		elseif S.linking then
			S.linking = nil
			refresh_panels()
		elseif S.calib then
			S.calib = nil
			refresh_panels()
		elseif S.tool and S.tool ~= "select" then
			-- **A tool is a level of its own** (user): out of it to Select,
			-- and from Select, or no tool, to the pause menu. The same in
			-- every view, walking included, where the mouse's capture goes
			-- first.
			set_tool("select")
		else
			open_pause()
		end
	end

	-- A key being bound takes the next key ([the keys page])
	function M.capture_key(key)
		local action = S.binding
		-- Not the Enter or Space that pressed the key's button itself,
		-- which reaches here after the UI took it
		if not action or buildat.get_time_us() - (S.binding_t or 0) < 100000 then
			return false
		end
		S.binding = nil
		if key == magic.KEY_BACKSPACE then
			keys.set(action, nil)
		elseif key ~= magic.KEY_ESCAPE then
			keys.set(action, key)
		end
		refresh_panels()
		M.keys_page()
		return true
	end

	function M.key_down(key, event_data)
		if M.capture_key(key) then
			return
		end
		local qualifiers = event_data and event_data:GetInt("Qualifiers") or 0
		local ctrl = qualifiers % 4 >= 2
		-- Alt with anything is the window manager's: Alt+Tab switches windows,
		-- not views
		if qualifiers % 8 >= 4 then
			return
		end
		if S.draw or S.corners then
			local digit = key >= magic.KEY_0 and key <= magic.KEY_9
			if digit then
				S.typed = S.typed .. tostring(key - magic.KEY_0)
				return
			elseif key == magic.KEY_BACKSPACE then
				S.typed = S.typed:sub(1, -2)
				return
			elseif key == magic.KEY_RETURN or key == magic.KEY_KP_ENTER then
				if S.typed == "" and S.corners and #S.corners >= 3 then
					add_room(S.corners)
					S.corners = nil
				else
					commit_typed()
				end
				return
			end
		end
		if ctrl then
			if key == magic.KEY_Z and S.shift or key == magic.KEY_Y then
				doc.redo()
			elseif key == magic.KEY_Z then
				doc.undo()
			elseif key == magic.KEY_D then
				copy_selected(false)
			elseif key == magic.KEY_L then
				copy_selected(true)
			end
			return
		end
		local function is(action)
			return key == keys.key(action)
		end
		-- The first of actions whose key it is
		local function is_any(actions)
			for _, a in ipairs(actions) do
				if is(a) then
					return a
				end
			end
		end
		if key == magic.KEY_ESCAPE then
			M.escape()
		elseif S.paused then
			-- The pause menu takes the keys: Up and Down go through it
			M.menu_key(key)
		elseif is("noclip") and S.view == "walk" then
			S.walk.noclip = not S.walk.noclip
			doc.notice(S.walk.noclip and "Noclip: walls do not stop you; " ..
					keys.name("up") .. " and " .. keys.name("down") ..
					" go up and down" or "Noclip off")
		elseif S.view == "2d" and doc.can("edit") and M.selected_any() and
				(is("forward") or is("back") or is("left") or is("right")) then
			local g = grid_step() * (S.shift and 10 or 1)
			M.move_selection((is("right") and g or is("left") and -g or 0),
					(is("forward") and g or is("back") and -g or 0))
		elseif is("use") then
			use()
		elseif is("next_user") then
			go_to_next_user()
		elseif is("flat") then
			S.plan_look = (S.plan_look + 1) % 3
			set_view(S.view)
		elseif is("view_2d") then
			M.pick_view("2d")
		elseif is("view_3d") then
			M.pick_view("3d")
		elseif is("view_walk") then
			M.pick_view("walk")
		elseif is("turn_left") then
			rotate_selection(angle_step())
		elseif is("turn_right") then
			rotate_selection(-angle_step())
		elseif is_any(BUILT_IN_TOOLS) or is_any(E.tool_order) then
			-- Again: out of it, to no tool
			set_tool(is_any(BUILT_IN_TOOLS) or is_any(E.tool_order), true)
		elseif is("grid") then
			next_grid()
		elseif is("angle") then
			S.angle = S.angle % #ANGLE_STEPS + 1
			refresh_panels()
		elseif is("delete") then
			delete_selected()
		end
	end

	do
		--
		-- Walking
		--
		-- The voxels of the volumes near (x, z) as footprints, for the walker,
		-- in every layout: stairs go up to another
		-- simplified: a volume pitched or rolled is its bounding box
		local function layer_voxel_solids(insts, x, z, out)
			for id, it in pairs(insts) do
				if it.voxel and geom.len(x - it.x, z - it.z) < math.max(it.ex, it.ez) +
						BODY_R * 2 then
					if it.pitch % 360 ~= 0 or it.roll % 360 ~= 0 then
						out[#out + 1] = {pts = it.foot, y0 = it.y0, y1 = it.y1}
					else
						local sz = it.size
						for key in pairs(doc.voxels[doc.ents[id].ints.def] or {}) do
							local cx, cy, cz = doc.voxel_cell(key)
							local pts = {}
							for k, c in ipairs({{0, 0}, {1, 0}, {1, 1}, {0, 1}}) do
								local px, _, pz = geom.rot((cx + c[1]) * sz, 0,
										(cz + c[2]) * sz, 0, it.yaw, 0)
								pts[k] = {it.ox + px, it.oz + pz}
							end
							if not geom.is_ccw(pts) then
								pts = {pts[4], pts[3], pts[2], pts[1]}
							end
							out[#out + 1] = {pts = pts, y0 = it.oy + cy * sz,
									y1 = it.oy + (cy + 1) * sz}
						end
					end
				end
			end
		end
		local function voxel_solids(x, z, out)
			for _, l in ipairs(place.layers) do
				local r = l.rel
				local lx, _, lz = place.unpoint(r, x, 0, z)
				local list = {}
				layer_voxel_solids(l.insts, lx, lz, list)
				for _, sd in ipairs(list) do
					local pts = {}
					for k, q in ipairs(sd.pts) do
						local px, _, pz = place.point(r, q[1], 0, q[2])
						pts[k] = {px, pz}
					end
					out[#out + 1] = {pts = pts, y0 = sd.y0 + r.y, y1 = sd.y1 + r.y}
				end
			end
		end

	-- The walker at (x, z) with its feet at `feet`, pushed out of what it is
	-- in, and standing on the highest thing under it it can step onto
	-- simplified: it steps down at once rather than falling
	local function collide(x, z, feet)
		local list = {}
		for _, sd in ipairs(E.solids) do
			list[#list + 1] = sd
		end
		voxel_solids(x, z, list)
		-- The world's ground, where the current layout has it
		return geom.walk(list, x, z, feet, BODY_R, STEP, HEAD,
				place.rel(place.WORLD, place.current()).y)
	end

	-- dt: seconds of walking at the keys' speed, or mm: that far, which is
	-- a middle drag's
	walk = function(dt, f, r, mm)
		local input = magic.input
		local w = S.walk
		-- Shift runs; Ctrl is the shortcuts' (Ctrl+D is a copy)
		local speed = mm or (S.shift and 5250 or 2100) * dt
		local yaw = math.rad(S.yaw)
		local dx = (math.sin(yaw) * f + math.cos(yaw) * r) * speed
		local dz = (math.cos(yaw) * f - math.sin(yaw) * r) * speed
		if w.noclip then
			w.x, w.z = w.x + dx, w.z + dz
			local u = 0
			if keys.down("up") then u = u + 1 end
			if keys.down("down") then u = u - 1 end
			w.feet = w.feet + u * speed
		else
			w.x, w.z, w.feet = collide(w.x + dx, w.z + dz, w.feet)
		end
		S.pos = {x = w.x / 1000, y = (w.feet + S.eye) / 1000, z = w.z / 1000}
		place.follow(w)
	end

	end

end

--
-- Every frame
--
local function move_camera(dt)
	local input = magic.input
	S.shift = input:GetKeyDown(magic.KEY_LSHIFT) or
			input:GetKeyDown(magic.KEY_RSHIFT)
	S.ctrl = input:GetKeyDown(magic.KEY_LCTRL) or
			input:GetKeyDown(magic.KEY_RCTRL)
	if doc.typing() or S.ctrl then
		return
	end
	local f, r, u = 0, 0, 0
	if keys.down("forward") then f = f + 1 end
	if keys.down("back") then f = f - 1 end
	if keys.down("right") then r = r + 1 end
	if keys.down("left") then r = r - 1 end
	if S.view == "2d" then
		-- With a selection the keys move it (M.move_selection), a press at a time
		if doc.can("edit") and M.selected_any() then
			return
		end
		local k = S.span * dt
		S.cx = S.cx + r * k
		S.cz = S.cz + f * k
		return
	end
	-- **The arrow keys turn and tilt the view** ([FP_TURN_KEYS]) while
	-- held, Shift faster; not with the menu up, whose keys they are
	local turn, tilt = 0, 0
	if keys.down("turn_view_right") then turn = turn + 1 end
	if keys.down("turn_view_left") then turn = turn - 1 end
	if keys.down("tilt_up") then tilt = tilt + 1 end
	if keys.down("tilt_down") then tilt = tilt - 1 end
	if (turn ~= 0 or tilt ~= 0) and not S.paused then
		local rate = (S.shift and 180 or 60) * dt
		S.yaw = S.yaw + turn * rate
		S.pitch = math.max(-89, math.min(89, S.pitch - tilt * rate))
	end
	-- [FP_VOXEL_ALONE] Round the volume (M.alone_camera puts the camera)
	if S.alone then
		if not S.paused then
			local rate = M.ALONE_TURN * dt
			S.yaw = S.yaw + r * rate
			S.pitch = math.max(-80, math.min(80, S.pitch + f * rate))
		end
		return
	end
	if S.view == "walk" then
		if S.stick then
			f, r = f + S.stick.f, r + S.stick.r
		end
		walk(dt, f, r)
		return
	end
	if keys.down("up") then u = u + 1 end
	if keys.down("down") then u = u - 1 end
	local speed = (S.shift and 12 or 4) * dt
	local yaw = math.rad(S.yaw)
	S.pos = {x = S.pos.x + (math.sin(yaw) * f + math.cos(yaw) * r) * speed,
			y = S.pos.y + u * speed,
			z = S.pos.z + (math.cos(yaw) * f - math.sin(yaw) * r) * speed}
end

local function place_cameras()
	local w, h = screen_size()
	cam2d.orthoSize = W(S.span)
	cam2d.aspectRatio = w / h
	cam2d_node.position = magic.Vector3(W(S.cx), W(settings().cut), W(S.cz))
	cam3d.aspectRatio = w / h
	cam3d_node.position = magic.Vector3(S.pos.x, S.pos.y, S.pos.z)
	cam3d_node.rotation = magic.Quaternion(S.pitch, S.yaw, 0)
end

-- What each button would do, above the chat
local hud = magic.ui.root:CreateChild("Text")
hud:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 15)
hud:SetAlignment(magic.HA_CENTER, magic.VA_BOTTOM)
hud:SetPosition(0, -12)
hud:SetTextEffect(magic.TE_SHADOW)
hud:SetTextAlignment(magic.HA_CENTER)
hud.priority = 90
if S.touch then
	hud:SetWordwrap(true)
end

local crosshair = magic.ui.root:CreateChild("Text")
crosshair:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 24)
crosshair:SetText("+")
crosshair:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
crosshair.visible = false
crosshair.priority = -10

-- A text over a place in the world, for this frame
local label_i = 0
-- The text each label was last set to (on M: the chunk is at Lua's
-- limit of 200 locals)
M.label_texts = {}
local function world_label(x_mm, y_mm, z_mm, text)
	label_i = label_i + 1
	local t = label_nodes[label_i]
	if not t then
		t = magic.ui.root:CreateChild("Text")
		t:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 13)
		t:SetTextEffect(magic.TE_SHADOW)
		-- Of the scene: under every panel and menu, whenever it was made
		t.priority = -10
		label_nodes[label_i] = t
	end
	local cam = S.view == "2d" and cam2d or cam3d
	local p = cam:WorldToScreenPoint(magic.Vector3(W(x_mm), W(y_mm), W(z_mm)))
	-- Set only when it changes: a text set is laid out again (user: a big
	-- plan panned slowly in Firefox)
	if M.label_texts[label_i] ~= text then
		M.label_texts[label_i] = text
		t:SetText(text)
	end
	t.visible = true
	local root = magic.ui.root
	t:SetPosition(math.floor(p.x * root.width) + 8,
			math.floor(p.y * root.height) - 18)
end

local function mm_text(v)
	return string.format("%d mm", math.floor(v + 0.5))
end

-- A user's colour, from their name
local function user_color(name)
	local h = 0
	for i = 1, #name do
		h = (h * 31 + name:byte(i)) % 360
	end
	local k = function(n)
		local x = (n + h / 30) % 12
		return 0.5 - 0.45 * math.max(-1, math.min(x - 3, 9 - x, 1))
	end
	return magic.Color(k(0), k(8), k(4))
end

-- A door's swing or a window's glass as a plan draws them: a door open
-- square to the wall with the arc it sweeps, a window as two lines
local function plan_symbol(id, it, line)
	local def = doc.ents[it.def].ints
	local e = doc.ents[id].ints
	local f = it.frame
	local col = S.plan_look == 2 and magic.Color(0.1, 0.4, 0.9) or
			magic.Color(0.2, 0.2, 0.25)
	local function at(a, c)
		-- A point a along the wall from the centre, c across it
		return f.ax + f.ux * (it.along + a) + f.nx * c,
				f.az + f.uz * (it.along + a) + f.nz * c
	end
	local hw = def.w / 2
	local mid = (f.lo - f.ro) / 2
	if def.kind == KIND.switch then
		local pts = it.foot
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			line(p[1], p[2], q[1], q[2], col)
		end
	elseif def.kind == KIND.window then
		for _, c in ipairs({mid - 15, mid + 15}) do
			local ax, az = at(-hw, c)
			local bx, bz = at(hw, c)
			line(ax, az, bx, bz, col)
		end
	elseif def.kind == KIND.door then
		local right = e.flip % 2 == 1
		local side = math.floor(e.flip / 2) % 2 == 1 and -1 or 1
		local face = side > 0 and f.lo or -f.ro
		local hinges = def.leaf == 1 and {{-hw, 1, hw}, {hw, -1, hw}} or
				{{right and hw or -hw, right and -1 or 1, 2 * hw}}
		for _, h in ipairs(hinges) do
			local r = h[3]
			local hx, hz = at(h[1], face)
			local ox, oz = at(h[1], face + side * r)
			line(hx, hz, ox, oz, col)
			local steps = 12
			local px, pz = at(h[1] + h[2] * r, face)
			for k = 1, steps do
				local a = k / steps * math.pi / 2
				local qx, qz = at(h[1] + h[2] * r * math.cos(a),
						face + side * r * math.sin(a))
				line(px, pz, qx, qz, col)
				px, pz = qx, qz
			end
		end
	end
end

--
-- The guides: what the pointer is on, highlighted, and what each button
-- would do to it, said ([FP_GUIDES]). compute_guide() makes the same picks
-- the clicks do, so what is shown is what is done.
--
local compute_guide, draw_guide, guide_text
do
	local HOVER = magic.Color(0.2, 0.9, 1.0)
	local DIG = magic.Color(1, 0.3, 0.2)
	local PLACE = magic.Color(0.2, 1, 0.3)
	-- What a right click does something to (user): a door's leaf to open
	-- or shut
	local RIGHT = magic.Color(1.0, 0.55, 0.1)

	local function name_of(id)
		local e = doc.ents[id]
		if not e then
			return "?"
		end
		if e.type == "instance" then
			local kind = doc.ents[e.ints.def].ints.kind
			return (kind == KIND.voxel and "voxels" or
					KIND_NAMES[kind]:lower()) .. " " .. id
		elseif e.type == "room" then
			return "room '" .. e.strs.name .. "'"
		elseif e.type == "image" then
			return "the picture " .. e.strs.file
		end
		return e.type .. " " .. id
	end
	M.name_of = name_of
	-- What using a thing does, and its highlight in the right button's
	-- colour: a door's or a window's leaves, the rest whole
	function M.use_text(id, kind)
		if kind == KIND.switch then
			local any = false
			for _, l in ipairs(doc.ents[id].lists.lamps) do
				any = any or lamp_on(l)
			end
			return "turn " .. name_of(id) .. "'s lamps " .. (any and "off" or "on")
		elseif kind == "lamp" then
			return "turn " .. name_of(id) .. (lamp_on(id) and " off" or " on")
		elseif kind == KIND.window then
			return (M.blinds_amount(id) > 0 and "raise " or "lower ") ..
					name_of(id) .. "'s blind"
		end
		return (open_amount(id) > 0 and "close " or "open ") .. name_of(id)
	end
	function M.use_hl(id, kind)
		return {kind = (kind == KIND.switch or kind == "lamp") and "instance" or
				"leaves", id = id, col = RIGHT}
	end

	local function mat_text(m)
		local e = m and m ~= 0 and doc.ents[m]
		if not e then
			return "no material"
		end
		return "'" .. e.strs.name .. "' #" .. m
	end

	local function cell_of(id, c)
		local e = doc.ents[id]
		local m = (doc.voxels[e.ints.def] or {})[doc.voxel_key(c[1], c[2], c[3])]
		return m
	end

	compute_guide = function()
		if S.paused or (over_ui() and not S.captured) then
			return nil
		end
		-- At the pointer of a view with a crosshair, a click goes up into it
		if crosshair_view() and not S.captured then
			local walking = S.view == "walk"
			local g = {hl = {}, left = walking and
					"into the crosshair: walk, look and point (Esc: back)" or
					"into the crosshair to dig and place (Esc: back)",
					right = walking and "drag: turn" or nil,
					middle = walking and "drag: walk" or nil}
			-- A right click uses what it is on (mouse_up), and with no tool
			-- a left one too
			local uid, ukind = M.use_pointed()
			if walking and uid then
				g.right = "click: " .. M.use_text(uid, ukind) .. "; drag: turn"
				g.hl[1] = M.use_hl(uid, ukind)
				if not S.tool then
					g.left = M.use_text(uid, ukind)
				end
			end
			return g
		end
		local g = {hl = {}}
		local function hl(t)
			g.hl[#g.hl + 1] = t
		end
		-- The camera's buttons
		if S.view == "2d" then
			g.middle = "drag: pan the plan"
			g.right = "drag: into 3D, orbiting round the pointer"
		elseif S.orbit and plan_facing() and not S.no_plan_return then
			g.right = plan_aligned() and "let go: back to the plan view" or
					"turn it north-up to let go into the plan view"
		elseif not S.captured then
			local s = pick_surface()
			g.right = (s or not next(E.room_data)) and
					"drag: orbit round what the pointer is on" or
					"drag: orbit round the middle of the plan"
			-- A right click uses what it is on (mouse_up)
			local uid, ukind = M.use_pointed()
			if uid then
				g.right = "click: " .. M.use_text(uid, ukind) .. "; " .. g.right
				hl(M.use_hl(uid, ukind))
				if not S.tool then
					g.left = M.use_text(uid, ukind)
				end
			end
			g.middle = "drag: pan the view"
		end
		local cur = default_material()
		local edit = doc.can("edit")
		-- The use key
		local uid, ukind = use_target()
		if uid then
			local what = M.use_text(uid, ukind)
			g.use = what
			-- Only when it is not what is under the pointer, which shows in
			-- the right button's colour (user, 2026-10-02: two boxes on a
			-- door, one of them whatever Select's filter said): the
			-- selected switch E works from anywhere
			if uid ~= M.use_pointed() then
				hl({kind = "instance", id = uid, col = PLACE})
			end
			if S.captured and S.tool ~= "voxel" then
				g.right = what
				-- The right button is the use key there: its colour
				hl(M.use_hl(uid, ukind))
				if not S.tool and M.use_pointed() == uid then
					g.left = what
				end
			end
		end
		if S.calib then
			local x, z = cursor_floor()
			if x and not S.calib.measured then
				hl({kind = "point", x = x, z = z})
				g.left = "calibration point " .. (#S.calib.pts + 1) .. " of 2 here"
			end
			g.note = "Esc: stop calibrating"
			return g
		end
		if S.linking then
			local s = pick_surface()
			if s and s.kind == "instance" and is_lamp(s.id) then
				hl({kind = "instance", id = s.id})
				local linked = false
				for _, l in ipairs(doc.ents[S.linking].lists.lamps) do
					linked = linked or l == s.id
				end
				g.left = (linked and "unlink " or "link ") .. name_of(s.id) ..
						(linked and " from " or " to ") .. name_of(S.linking)
			end
			g.note = "Linking lamps: point at a lamp; Esc: done"
			return g
		end
		local tool = S.place_copy and "place_copy" or S.tool
		if tool == "select" or tool == "node" then
			local t = press_target()
			if t then
				hl({kind = t.kind == "room" and t.side == "ceiling" and "ceiling" or
						t.kind, id = t.id})
				local name = name_of(t.id)
				if S.shift then
					g.left = (S.sel[t.id] and "take " .. name .. " out of" or
							"add " .. name .. " to") .. " the selection"
				elseif S.sel[t.id] or S.nodes[t.id] then
					g.left = (S.sel[t.id] and panel.folded("props") and
							"its properties" or "keep " .. name .. " selected") ..
							(edit and "; drag: move the selection" or "")
				else
					g.left = "select " .. name .. (t.kind == "wall" and t.side and
							(" by its " .. (t.side == "core" and "top" or
							t.side .. " face")) or t.kind == "room" and t.side and
							(" by its " .. t.side) or "") .. "; drag: select by a box"
				end
				if t.kind == "node" and edit then
					g.left = g.left .. " (onto another node: merge them)"
				end
			else
				g.left = (next(S.sel) or next(S.nodes)) and
						"clear the selection; drag: select by a box" or
						"drag: select by a box"
			end
		elseif tool == "wall" or tool == "room" then
			local from = tool == "wall" and S.draw or
					(S.corners and S.corners[#S.corners])
			local x, z, ref = snapped_point(from)
			if x and edit then
				local at = ref.node and " at node " .. ref.node or ref.edge and
						(ref.edge.wall and ", splitting wall " .. ref.edge.wall or
						" on a room's edge") or ""
				if ref.node then
					hl({kind = "node", id = ref.node})
				elseif ref.edge then
					hl({kind = "edge", u = ref.edge.u, v = ref.edge.v})
				end
				if tool == "wall" then
					g.left = (S.draw and "end the wall here" or "start a wall here") .. at
				else
					local first = S.corners and S.corners[1]
					if first and #S.corners >= 3 and
							geom.len(x - first.x, z - first.z) <= snap_radius() then
						g.left = "close the room: " .. #S.corners .. " corners"
					else
						g.left = "corner " .. ((S.corners and #S.corners or 0) + 1) ..
								" here" .. at
					end
				end
				if from then
					g.right = "stop drawing"
					g.note = "Type a length and Enter to draw it that long"
				end
			end
		elseif E.tools[tool] and E.tools[tool].guide then
			E.tools[tool].guide(g, hl)
		elseif tool == "box" then
			local x, z = snapped_point(nil)
			if x and edit then
				hl({kind = "point", x = x, z = z})
				g.left = S.shape == "lamp" and "put a plafond lamp on the ceiling here" or
						S.shape == "stairs" and "put stairs here, " ..
						S.stairs.w .. " mm wide, of " .. mat_text(cur) ..
						"; drag: draw their footprint" or
						"put a box here, " .. S.box.w .. " x " .. S.box.d ..
						" mm, of " .. mat_text(cur) .. "; drag: draw its footprint"
			end
		elseif tool == "place_copy" then
			local src = doc.ents[S.place_copy.id]
			local s = pick_surface()
			local f = s and s.kind == "wall" and wall_frame(s.id)
			g.left = "click a wall to put the " .. (S.place_copy.linked and
					"linked clone" or "copy") .. " in (Esc: no copy)"
			if f and src then
				local d = doc.ents[src.ints.def].ints
				local along = geom.snap((s.x - f.ax) * f.ux + (s.z - f.az) * f.uz,
						grid_step())
				along = math.max(d.w / 2, math.min(f.len - d.w / 2, along))
				hl({kind = "wall", id = s.id})
				hl({kind = "opening", frame = f, along = along, w = d.w,
						sill = src.ints.sill, h = d.h})
				g.left = "put the " .. (S.place_copy.linked and "linked clone" or
						"copy") .. " into wall " .. s.id .. ", " ..
						math.floor(along + 0.5) .. " mm along it (Esc: no copy)"
			end
		elseif tool == "hosted" then
			local s = pick_surface()
			local f = s and s.kind == "wall" and wall_frame(s.id)
			if f and edit then
				local d = HOSTED[S.hosted]
				local along = geom.snap((s.x - f.ax) * f.ux + (s.z - f.az) * f.uz,
						grid_step())
				along = math.max(d.w / 2, math.min(f.len - d.w / 2, along))
				hl({kind = "wall", id = s.id})
				hl({kind = "opening", frame = f, along = along, w = d.w,
						sill = d.sill, h = d.h})
				g.left = "put " .. KIND_NAMES[S.hosted]:lower() .. " into wall " ..
						s.id .. ", " .. math.floor(along + 0.5) .. " mm along it"
			end
		elseif tool == "voxel" then
			local id = voxel_target()
			if not edit then
			elseif not id then
				local x, z = snapped_point(nil)
				if x then
					hl({kind = "point", x = x, z = z})
					local what = "start a voxel volume here, of " .. mat_text(cur)
					if S.captured then
						g.right = what
					else
						g.left = what
					end
				end
			elseif S.view == "2d" then
				local cx, cz, top = voxel_column(id)
				if cx then
					local y = top and top + 1 or 0
					hl({kind = "cell", id = id, c = {cx, y, cz}, col = PLACE})
					g.left = "a voxel of " .. mat_text(cur) .. " on the column, layer " .. y
					if top then
						g.left = g.left .. "; Ctrl+Left: take the top one (" ..
								mat_text(cell_of(id, {cx, top, cz})) .. ") off" ..
								"; Shift+Left: make it " .. mat_text(cur)
					end
				end
			elseif S.voxel_box and S.voxel_box.cancelled then
				g.left = "given up: let go of the buttons"
			elseif S.voxel_box and S.voxel_box.id == id then
				-- The box a release here would make, from where it was pressed
				local vb = S.voxel_box
				local ok, c = M.voxel_box_end(vb)
				local col = vb.mode == "place" and PLACE or DIG
				if ok then
					hl({kind = "cell", id = id, c = vb.a, c2 = c, col = col})
					local n = (math.abs(c[1] - vb.a[1]) + 1) *
							(math.abs(c[2] - vb.a[2]) + 1) * (math.abs(c[3] - vb.a[3]) + 1)
					g.left = "let go: " .. ({place = "fill", dig = "empty",
							paint = "paint"})[vb.mode] .. " " .. n .. " cells; Esc: none"
				else
					hl({kind = "cell", id = id, c = vb.a, col = col})
					g.left = "let go here: nothing (point at the volume); Esc: none"
				end
			else
				local hit, place = voxel_ray(id)
				local pok, pc = M.voxel_cell("place")
				if not S.captured then
					-- At the pointer: the left button by the panel's Click
					local mode = S.ctrl and "dig" or S.shift and "paint" or
							S.voxel_mode
					if mode == "place" and pok then
						hl({kind = "cell", id = id, c = pc, col = PLACE})
						g.left = "place a voxel of " .. mat_text(cur) ..
								" here (hold: a box); Ctrl: dig, Shift: paint"
					elseif mode ~= "place" and hit then
						hl({kind = "cell", id = id, c = hit, col = DIG})
						g.left = (mode == "dig" and "dig this voxel (" ..
								mat_text(cell_of(id, hit)) .. ")" or "make this voxel " ..
								mat_text(cur)) .. " (hold: a box)"
					end
					hit = nil
				elseif hit then
					hl({kind = "cell", id = id, c = hit, col = DIG})
					g.left = "dig this voxel (" .. mat_text(cell_of(id, hit)) ..
							"); Shift+click: make it " .. mat_text(cur)
				end
				if pok and S.captured then
					hl({kind = "cell", id = id, c = pc, col = PLACE})
					g.right = "place a voxel of " .. mat_text(cur) ..
							" here (hold: a box)"
				end
				if hit then
					g.left = g.left .. " (hold: a box)"
				end
			end
		elseif tool == "paint" then
			local s = pick_surface()
			if s and edit then
				local old
				if s.kind == "instance" and E.inst_data[s.id].voxel then
					local hit = voxel_ray(s.id)
					if hit then
						hl({kind = "cell", id = s.id, c = hit})
						g.left = "make this voxel " .. mat_text(cur) .. " (now " ..
								mat_text(cell_of(s.id, hit)) .. ")"
					end
				elseif s.kind == "instance" then
					hl({kind = "instance", id = s.id})
					old = doc.ents[doc.ents[s.id].ints.def].ints.mat
					g.left = "make " .. name_of(s.id) .. " " .. mat_text(cur) ..
							" (now " .. mat_text(old) .. ")"
				elseif s.kind == "wall" then
					local w = doc.ents[s.id].ints
					hl({kind = "face", id = s.id, side = s.side})
					old = s.side == "left" and w.mat_left or s.side == "right" and
							w.mat_right or (w.mat_core ~= 0 and w.mat_core or w.mat_left)
					g.left = "make wall " .. s.id .. "'s " .. (s.side == "core" and
							"top and ends" or s.side .. " face") .. " " .. mat_text(cur) ..
							" (now " .. mat_text(old) .. ")"
				elseif s.kind == "floor" or s.kind == "ceiling" then
					local r = doc.ents[s.id]
					hl({kind = s.kind, id = s.id})
					old = s.kind == "floor" and r.ints.mat_floor or r.ints.mat_ceiling
					g.left = "make " .. name_of(s.id) .. "'s " .. s.kind .. " " ..
							mat_text(cur) .. " (now " .. mat_text(old) .. ")"
				end
			end
		end
		return g
	end

	guide_text = function(g)
		if not g then
			return ""
		end
		local lines = {}
		-- A touchscreen's are what the last tap did, and holding still
		-- ([FP_TOUCH] 4); the mouse's other buttons are its gestures
		local names = S.touch and {{"left", "Tap"}, {"use", "Hold"}} or
				{{"left", "Left"}, {"right", "Right"}, {"middle", "Middle"},
				{"use", keys.name("use")}}
		for _, b in ipairs(names) do
			local t = g[b[1]]
			-- A finger's drag on nothing moves the view, not a box
			if t and S.touch then
				t = t:gsub("; drag: select by a box", "")
				if t:match("^drag:") then
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

	-- A cell of a volume as its 12 edges
	local function cell_box(id, c, col, c2)
		local it = E.inst_data[id]
		if not it then
			return
		end
		local sz = it.size
		-- From one cell to another, both in
		c2 = c2 or c
		local lo = {math.min(c[1], c2[1]), math.min(c[2], c2[2]), math.min(c[3], c2[3])}
		local n = {math.abs(c[1] - c2[1]) + 1, math.abs(c[2] - c2[2]) + 1,
				math.abs(c[3] - c2[3]) + 1}
		local function corner(dx, dy, dz)
			local x, y, z = geom.rot((lo[1] + dx * n[1]) * sz,
					(lo[2] + dy * n[2]) * sz, (lo[3] + dz * n[3]) * sz,
					it.pitch, it.yaw, it.roll)
			return magic.Vector3(W(it.ox + x), W(it.oy + y), W(it.oz + z))
		end
		for _, e in ipairs({{0,0,0, 1,0,0}, {0,0,0, 0,1,0}, {0,0,0, 0,0,1},
				{1,1,1, 0,1,1}, {1,1,1, 1,0,1}, {1,1,1, 1,1,0},
				{1,0,0, 1,1,0}, {1,0,0, 1,0,1}, {0,1,0, 1,1,0},
				{0,1,0, 0,1,1}, {0,0,1, 1,0,1}, {0,0,1, 0,1,1}}) do
			debug:AddLine(corner(e[1], e[2], e[3]), corner(e[4], e[5], e[6]),
					col, false)
		end
	end

	-- An instance's box as its 12 edges
	local function inst_box(id, col)
		local it = E.inst_data[id]
		local function corner(sx, sy, sz)
			local x, y, z = geom.rot(sx * it.hx, sy * it.hy, sz * it.hz, it.pitch,
					it.yaw, it.roll)
			return magic.Vector3(W(it.x + x), W(it.y + y), W(it.z + z))
		end
		for _, e in ipairs({{-1,-1,-1, 1,-1,-1}, {-1,-1,-1, -1,1,-1},
				{-1,-1,-1, -1,-1,1}, {1,1,1, -1,1,1}, {1,1,1, 1,-1,1},
				{1,1,1, 1,1,-1}, {1,-1,-1, 1,1,-1}, {1,-1,-1, 1,-1,1},
				{-1,1,-1, 1,1,-1}, {-1,1,-1, -1,1,1}, {-1,-1,1, 1,-1,1},
				{-1,-1,1, -1,1,1}}) do
			debug:AddLine(corner(e[1], e[2], e[3]), corner(e[4], e[5], e[6]),
					col, false)
		end
	end

	draw_guide = function(g, P, line, outline)
		if not g then
			return
		end
		local plan = S.view == "2d"
		for _, h in ipairs(g.hl) do
			local col = h.col or HOVER
			if h.kind == "point" then
				debug:AddCross(P(h.x, h.z), plan and W(12 * mm_per_px()) or 0.15,
						col, false)
			elseif h.kind == "node" then
				local x, z = node_pos(h.id)
				debug:AddCross(P(x, z), plan and W(16 * mm_per_px()) or 0.25, col,
						false)
			elseif h.kind == "edge" then
				local ux, uz = node_pos(h.u)
				local vx, vz = node_pos(h.v)
				line(ux, uz, vx, vz, col)
			elseif h.kind == "wall" and E.outlines[h.id] then
				local y0, y1 = wall_span(doc.ents[h.id].ints)
				outline(E.outlines[h.id].pts, col, not plan and
						{W(y0) + 0.004, W(y1) + 0.004} or nil)
			elseif h.kind == "face" and E.outlines[h.id] then
				local o = E.outlines[h.id]
				local y0, y1 = wall_span(doc.ents[h.id].ints)
				for i = 1, #o.pts do
					if o.sides[i] == h.side then
						local p, q = o.pts[i], o.pts[i % #o.pts + 1]
						if plan then
							line(p[1], p[2], q[1], q[2], col)
						else
							for _, yy in ipairs({y0, y1}) do
								debug:AddLine(magic.Vector3(W(p[1]), W(yy), W(p[2])),
										magic.Vector3(W(q[1]), W(yy), W(q[2])), col, false)
							end
							for _, c in ipairs({p, q}) do
								debug:AddLine(magic.Vector3(W(c[1]), W(y0), W(c[2])),
										magic.Vector3(W(c[1]), W(y1), W(c[2])), col, false)
							end
						end
					end
				end
				if h.side == "core" then
					outline(o.pts, col, not plan and {W(y1) + 0.004} or nil)
				end
			elseif (h.kind == "floor" or h.kind == "room") and E.room_data[h.id] then
				outline(E.room_data[h.id].pts, col, not plan and {0.006} or nil)
			elseif h.kind == "ceiling" and E.room_data[h.id] then
				outline(E.room_data[h.id].pts, col,
						{W(room_ceiling(doc.ents[h.id])) - 0.004})
			elseif h.kind == "instance" and E.inst_data[h.id] then
				if plan then
					outline(E.inst_data[h.id].foot, col)
				else
					inst_box(h.id, col)
				end
			elseif h.kind == "leaves" and E.inst_data[h.id] then
				-- Each leaf's box, where it has swung to; a door with none
				-- (an opening) has its own box
				local leaves = E.inst_data[h.id].leaves or {}
				if #leaves == 0 then
					inst_box(h.id, col)
				end
				for _, lf in ipairs(leaves) do
					local function V(i)
						local x = i % 2 == 0 and lf.lo[1] or lf.hi[1]
						local y = math.floor(i / 2) % 2 == 0 and lf.lo[2] or lf.hi[2]
						local z = math.floor(i / 4) == 0 and lf.lo[3] or lf.hi[3]
						local wx, wy, wz = geom.rot(x, y, z, 0, lf.yaw, 0)
						return magic.Vector3(lf.x + wx, wy, lf.z + wz)
					end
					for _, e in ipairs({{0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2},
							{1, 3}, {4, 6}, {5, 7}, {0, 4}, {1, 5}, {2, 6},
							{3, 7}}) do
						debug:AddLine(V(e[1]), V(e[2]), col, false)
					end
				end
			elseif h.kind == "image" and E.image_data[h.id] then
				outline(E.image_data[h.id].foot, col)
			elseif h.kind == "cell" then
				cell_box(h.id, h.c, col, h.c2)
			elseif h.kind == "opening" then
				-- Where the door or window would go, on the wall's left face
				local f = h.frame
				local function at(a, y)
					return magic.Vector3(W(f.ax + f.ux * (h.along + a) + f.nx * f.lo),
							W(y), W(f.az + f.uz * (h.along + a) + f.nz * f.lo))
				end
				if plan then
					local pts = {}
					for k, c in ipairs({{-1, f.lo}, {1, f.lo}, {1, -f.ro}, {-1, -f.ro}}) do
						pts[k] = {f.ax + f.ux * (h.along + c[1] * h.w / 2) + f.nx * c[2],
								f.az + f.uz * (h.along + c[1] * h.w / 2) + f.nz * c[2]}
					end
					outline(pts, PLACE)
				else
					local a, b = -h.w / 2, h.w / 2
					local y0, y1 = h.sill, h.sill + h.h
					debug:AddLine(at(a, y0), at(b, y0), PLACE, false)
					debug:AddLine(at(b, y0), at(b, y1), PLACE, false)
					debug:AddLine(at(b, y1), at(a, y1), PLACE, false)
					debug:AddLine(at(a, y1), at(a, y0), PLACE, false)
				end
			end
		end
	end
end

-- The overlay ([FP_EDITOR_MODULES]): what it reads of this file that the
-- rebuild and the picking have not put in E
E.debug, E.BODY_R, E.HEAD, E.world_label = debug, BODY_R, HEAD, world_label
E.m2, E.plan_symbol, E.draw_guide, E.mm_text = m2, plan_symbol, draw_guide, mm_text
E.crosshair, E.user_color, E.over_ui = crosshair, user_color, over_ui
local draw_overlay = load("overlay.lua")(E)
load("tool_measure.lua")(E)

-- This user's presence, for the others, every PRESENCE_SECONDS
local PRESENCE_SECONDS = 0.1
local presence_timer = 0
local function send_presence(dt)
	presence_timer = presence_timer + dt
	if presence_timer < PRESENCE_SECONDS then
		return
	end
	presence_timer = 0
	local cx, cz = cursor_floor()
	local sel = {}
	for id in pairs(S.sel) do
		sel[#sel + 1] = id
	end
	for id in pairs(S.nodes) do
		sel[#sel + 1] = id
	end
	local p = {view = S.view == "walk" and 2 or S.view == "3d" and 1 or 0,
			cx = math.floor(cx or 0), cz = math.floor(cz or 0), sel = sel,
			yaw = math.floor(S.yaw * 1000), pitch = math.floor(S.pitch * 1000)}
	if S.view ~= "2d" then
		p.px, p.py, p.pz = math.floor(S.pos.x * 1000), math.floor(S.pos.y * 1000),
				math.floor(S.pos.z * 1000)
	else
		p.px, p.py, p.pz = math.floor(S.cx), math.floor(S.span), math.floor(S.cz)
	end
	doc.send_presence(place.presence(p))
end

-- The plan closed for another ([FP_OTHER_PLAN]): the editor waits, drawing
-- and showing nothing, until the next plan's snapshot resumes it
local SCENE_PARTS = {walls_node, caps_node, overhead_node, pieces_node,
	images_node, decals_node, lamps_node}
function M.suspend()
	close_pause()
	S.crosshair = false
	update_capture()
	S.suspended = true
	S.sel, S.primary, S.nodes, S.sel_face = {}, nil, {}, {}
	S.draw, S.corners, S.linking, S.calib, S.drag, S.press = nil
	-- What the plan left behind goes ([FP_PLANS]): enabled = false is not
	-- recursive, and it stayed drawn under the plans page. The next plan's
	-- snapshot builds its own.
	for _, n in ipairs(E.built) do
		n:Remove()
	end
	E.built = {}
	for _, parts in pairs(place.parts) do
		for _, n in pairs(parts) do
			n:Remove()
		end
	end
	place.parts = {}
	voxel_meshes = {}
	-- and what they were built from: fp:closed empties the entities, and a
	-- ray against an instance whose door was gone was an error (user,
	-- 2026-10-02)
	E.outlines, E.wall_data, E.room_data, E.inst_data, E.solids = {}, {}, {}, {}, {}
	place.layers = {}
	S.layout, S.layouts_open = nil, false
	place.build_window()
	for _, n in ipairs(SCENE_PARTS) do
		n.enabled = false
	end
	for _, w in ipairs({toolbar, props, palette_win, S.touch_bar}) do
		if w then
			w.visible = false
		end
	end
	for _, t in ipairs(label_nodes) do
		t.visible = false
	end
	hud:SetText("")
	crosshair.visible = false
end

-- **Where the view was, per plan** (user, 2026-09-30): the mode, the
-- layout and the cameras, kept on this client and put back when the plan is
-- next opened. The storage key is the plan's name in hex, since a name is
-- anything a user typed.
-- simplified: a plan name of over 60 bytes is not remembered
local function view_key()
	local n = doc and doc.plan_name or ""
	if n == "" or #n > 60 then
		return nil
	end
	return "view_" .. (n:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

local function view_record()
	local w = S.walk
	-- and after them the free camera and the walker's look, each kept
	-- while the other is in use
	local c = S.cam3d or {x = S.pos.x, y = S.pos.y, z = S.pos.z, yaw = S.yaw,
			pitch = S.pitch}
	return string.format("%s;%s;%.1f;%.1f;%.1f;%.4f;%.4f;%.4f;%.3f;%.3f;" ..
			"%.1f;%.1f;%.1f;%.4f;%.4f;%.4f;%.3f;%.3f;%.3f;%.3f;%d", S.view,
			tostring(S.layout or ""), S.cx, S.cz,
			S.span, S.pos.x, S.pos.y, S.pos.z, S.yaw, S.pitch, w.x, w.z, w.feet,
			c.x, c.y, c.z, c.yaw, c.pitch, w.yaw or S.yaw, w.pitch or 0,
			w.placed and 1 or 0)
end

-- Kept once a second when it changed; M.update calls it
function M.save_view(dt)
	S.view_save_t = (S.view_save_t or 0) + dt
	if S.view_save_t < 1 then
		return
	end
	S.view_save_t = 0
	local key = view_key()
	if not key then
		return
	end
	local rec = view_record()
	if rec ~= S.view_saved then
		S.view_saved = rec
		buildat.storage_write(key, rec)
	end
end

-- Put back once the plan's document is here: init.lua calls it after the
-- join. A layout that has gone leaves the current one as it is.
function M.restore_view()
	local key = view_key()
	local rec = key and buildat.storage_read(key)
	if not rec then
		return
	end
	local f = {}
	for part in (rec .. ";"):gmatch("([^;]*);") do
		f[#f + 1] = part
	end
	local n = {}
	for i = 3, 13 do
		n[i] = tonumber(f[i])
		if not n[i] then
			return
		end
	end
	local view = f[1]
	if view ~= "2d" and view ~= "3d" and view ~= "walk" then
		return
	end
	local layout = tonumber(f[2])
	local e = layout and doc.ents[layout]
	if e and e.type == "layout" then
		S.layout = layout
		place.current()
	end
	set_view(view)
	S.cx, S.cz, S.span = n[3], n[4], math.max(500, math.min(200000, n[5]))
	S.pos = {x = n[6], y = n[7], z = n[8]}
	S.yaw, S.pitch = n[9], math.max(-90, math.min(90, n[10]))
	S.walk.x, S.walk.z, S.walk.feet = n[11], n[12], n[13]
	-- A record from before the two cameras were apart has none of these
	local m = {}
	for i = 14, 21 do
		m[i] = tonumber(f[i])
	end
	if m[21] then
		S.cam3d = {x = m[14], y = m[15], z = m[16], yaw = m[17], pitch = m[18]}
		S.walk.yaw, S.walk.pitch, S.walk.placed = m[19], m[20], m[21] == 1
	end
	S.view_saved = view_record()
	S.dirty = true
	refresh_panels()
	log:info("The view of " .. doc.plan_name .. " put back: " .. view)
end

function M.resume()
	S.suspended = false
	walls_node.enabled = true
	images_node.enabled = true
	decals_node.enabled = true
	lamps_node.enabled = true
	for _, w in ipairs({toolbar, props, palette_win, S.touch_bar}) do
		if w then
			w.visible = true
		end
	end
	-- The rest of the scene's parts are set by the view
	set_view(S.view)
	S.dirty = true
end

-- **Viewports** (user, 2026-10-01): a camera saved in the plan, from 3D
-- or walking, to see it again from the very same place. Gone to, the
-- camera is fixed there -- nothing that moves a camera moves it -- with
-- its own field of view, what was selected is let go of, and the menus
-- and texts are hidden until a key, a click or a touch; and, when it
-- recalls its moment, the light is its day and minute. Selecting and
-- editing go on as in 3D. Another view leaves it.
-- Up and Down through the pause menu's page; true when taken
function M.menu_key(key)
	return E.pause_win ~= nil and panel.menu_key(E.pause_win, key)
end

function M.viewports()
	local list = {}
	for _, e in ipairs(doc.of_type("viewport")) do
		list[#list + 1] = e
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

function M.save_viewport()
	if S.view == "2d" or not doc.can("edit") or not S.layout then
		return
	end
	local n = 0
	for _, e in ipairs(M.viewports()) do
		local k = tonumber(e.strs.name:match("^Viewport (%d+)$") or "")
		if k and k > n then
			n = k
		end
	end
	local walk = S.view == "walk"
	local name = "Viewport " .. (n + 1)
	local function mm(m)
		return math.floor(m * 1000 + 0.5)
	end
	send({{op = "create", ent = {id = doc.placeholder(), type = "viewport",
			ints = {layout = S.layout, x = mm(S.pos.x), y = mm(S.pos.y),
			z = mm(S.pos.z), yaw = math.floor(S.yaw % 360 * 1000 + 0.5) % 360000,
			pitch = math.floor(S.pitch * 1000 + 0.5), walk = walk and 1 or 0,
			fov = math.floor((walk and S.walk_fov or 60) + 0.5),
			day = M.plan_day(), minute = math.floor(M.plan_minute()) % 1440,
			recall = 1}, strs = {name = name}}}})
	doc.notice("Saved as " .. name)
end

function M.hide_ui()
	doc.ui_hidden = true
	panel.close_popup()
end

function M.show_ui()
	if doc.ui_hidden then
		doc.ui_hidden = false
		refresh_panels()
	end
end

-- preview: the camera only, the menus and the selection as they are
function M.go_viewport(id, preview)
	local e = doc.ents[id]
	if not e or e.type ~= "viewport" then
		return
	end
	if e.ints.layout ~= S.layout then
		place.switch(e.ints.layout)
	end
	S.vp = nil
	set_view("3d")
	S.vp = id
	S.daylight_key = nil
	S.dirty = true
	if preview then
		return
	end
	S.sel, S.sel_face, S.primary, S.nodes = {}, {}, nil, {}
	refresh_panels()
	M.hide_ui()
end

-- **The white the eye is adapted to** (FpFrame.glsl): the probes' where
-- the camera is along its room -- or, standing in a doorway, the room it
-- looks into -- else the outdoor one; FpFrame.glsl moves the eye's to it
-- in a second or so. In fp_wb, a texture of two texels: the two drawn
-- probes' rows and how far between (the cube mode); and a white's colour
-- (worked out probes', or outdoors).
-- simplified: under plain PBR without probes, the outdoor white
-- fp_wb made, outdoors and white to start with
function M.wb_init()
	if M.wb then
		return M.wb
	end
	local image = magic.Image:new()
	assert(image:SetSize(2, 1, 4), "the white's image")
	image:SetPixel(0, 0, magic.Color(0, 0, 0, 1))
	image:SetPixel(1, 0, magic.Color(1, 1, 1, 1))
	local texture = magic.Texture2D:new()
	texture:SetNumLevels(1)
	texture.filterMode = magic.FILTER_NEAREST
	assert(texture:SetData(image), "the white's texture")
	assert(magic.cache:AddManualResource(texture, "fp_wb"), "the white in the cache")
	M.kept[#M.kept + 1] = image
	M.kept[#M.kept + 1] = texture
	M.wb = {image = image, texture = texture}
	return M.wb
end
function M.wb_tick(dt)
	if not M.pbr_now() then
		return
	end
	M.probes_init()
	local w = M.wb_init()
	local fx, fz = math.sin(math.rad(S.yaw)), math.cos(math.rad(S.yaw))
	local id
	for _, ahead in ipairs({0, 300, 600}) do
		-- Outdoors always for a volume on its own ([FP_VOXEL_ALONE])
		id = id or not S.alone and room_at(S.pos.x * 1000 + fx * ahead,
				S.pos.z * 1000 + fz * ahead) or nil
	end
	local slot = id and M.room_slot[id]
	local pr = slot and M.probe_rows[slot]
	local ra, rb, t, o = 0, 0, 0, M.wb_outdoor or {r = 1, g = 1, b = 1}
	M.wb_at = nil
	if pr then
		local a, b, f = M.probe_at(pr, S.pos.x, S.pos.z)
		local pa, pb = M.probe_pos[a], M.probe_pos[b]
		M.wb_at = {W(pa.x + (pb.x - pa.x) * f), W(pa.y + (pb.y - pa.y) * f),
				W(pa.z + (pb.z - pa.z) * f)}
		if M.cube_mode == 1 and M.probe_ready[a] and M.probe_ready[b] then
			ra, rb, t = a, b, f
		elseif M.cube_mode == 2 and M.cpu_cube[a] and M.cpu_cube[b] then
			local c = {0, 0, 0}
			for _, k in ipairs({{a, 1 - f}, {b, f}}) do
				for _, face in ipairs(M.cpu_cube[k[1]]) do
					for i = 1, 3 do
						c[i] = c[i] + face[i] * k[2]
					end
				end
			end
			o = {r = c[1], g = c[2], b = c[3]}
		else
			M.wb_at = nil
		end
	end
	local m = math.max(o.r, o.g, o.b, 1e-6)
	local key = string.format("%d %d %.3f %.4f %.4f %.4f", ra, rb, t,
			o.r / m, o.g / m, o.b / m)
	if key == w.key then
		return
	end
	w.key = key
	w.image:SetPixel(0, 0, magic.Color(ra / 255, rb / 255, t, 1))
	w.image:SetPixel(1, 0, magic.Color(o.r / m, o.g / m, o.b / m, 1))
	assert(w.texture:SetData(w.image), "the white's texture")
end

-- **A dump for the path-traced reference** (apps/floorplanner/test/
-- pathtrace_render.py, user, 2026-10-01): with BUILDAT_FP_REFDUMP naming a
-- viewport, that viewport is gone to and, REFDUMP_WAIT seconds on, when
-- the room probes have bounced their light round, the scene's meshes are
-- dumped (buildat.dump_meshes, into <user>/meshdumps) with what the render
-- needs beside them: the camera, the sun and the sky as apply_daylight
-- has them, and each palette row's albedo as M.room_bounce takes it; and
-- a screenshot, after which the client quits.
-- The lamps are switched off for this client, as the render has none.
-- simplified: the albedo is the entry's flat colour, without the
-- pattern's gaps and grain
M.REFDUMP_WAIT = 20
M.refdump = buildat.get_env("BUILDAT_FP_REFDUMP") and
		{name = buildat.get_env("BUILDAT_FP_REFDUMP")}
function M.refdump_tick(dt)
	local r = M.refdump
	if not r then
		return
	end
	-- Done: a second for the screenshot to land, then the client goes
	if r.done then
		r.quit_t = r.quit_t + dt
		if r.quit_t > 1 then
			M.refdump = nil
			buildat.quit()
		end
		return
	end
	if not r.t then
		for _, e in ipairs(M.viewports()) do
			if e.strs.name == r.name then
				M.go_viewport(e.id)
				r.t = 0
			end
		end
		-- The lamps off, for this client: the render has none
		for id in pairs(doc.ents) do
			if is_lamp(id) then
				S.local_on[id] = false
				S.dirty = true
			end
		end
		return
	end
	r.t = r.t + dt
	if r.t < M.REFDUMP_WAIT then
		return
	end
	r.done = true
	local function v3(x, y, z)
		return string.format("[%.6g, %.6g, %.6g]", x, y, z)
	end
	local function c3(c)
		return v3(c.r, c.g, c.b)
	end
	local function lin(rgb)
		return {r = (math.floor(rgb / 65536) / 255) ^ 2.2,
				g = (math.floor(rgb / 256) % 256 / 255) ^ 2.2,
				b = (rgb % 256 / 255) ^ 2.2}
	end
	local st = settings()
	local tx, h, tz = M.daylight.sun_toward(st.latitude, st.north,
			M.plan_day(), M.plan_minute())
	local ground = lin(M.ground_rgb())
	local light = M.daylight.light(h, ground, M.sun().sky == 1)
	local yaw, pitch = math.rad(S.yaw), math.rad(S.pitch)
	-- Each row the meshes point at: kind 5 is glass, 4 a lamp
	local rows = {'"0": {"albedo": ' .. c3(lin(0xb0b0b0)) .. ', "kind": 0}',
			'"1": {"albedo": ' .. c3(lin(0xa8c8e0)) .. ', "kind": 5}',
			string.format('"%d": {"albedo": %s, "kind": 0}', M.ground_row,
			c3(ground))}
	for _, e in ipairs(of_type("palette")) do
		rows[#rows + 1] = string.format('"%d": {"albedo": %s, "kind": %d}',
				row(e.id), c3(M.entry_albedo(e.id)), e.ints.kind)
	end
	local json = "{" .. table.concat({
		'"viewport": "' .. r.name:gsub('[%c"\\]', "") .. '"',
		'"camera_pos": ' .. v3(S.pos.x, S.pos.y, S.pos.z),
		'"camera_dir": ' .. v3(math.sin(yaw) * math.cos(pitch),
				-math.sin(pitch), math.cos(yaw) * math.cos(pitch)),
		'"fov": ' .. string.format("%.6g", cam3d.fov),
		-- Where the frame's white is taken (M.wb_tick): between the room's
		-- probes, or the eye's outdoors
		'"white_at": ' .. (M.wb_at and v3(M.wb_at[1], M.wb_at[2], M.wb_at[3]) or
				v3(S.pos.x, S.pos.y, S.pos.z)),
		'"sun_toward": ' .. v3(tx, h, tz),
		'"sun_irradiance": ' .. string.format("%.6g", light.sun),
		'"sun_color": ' .. c3(light.sun_color),
		'"sky_zenith": ' .. c3(light.zenith),
		'"sky_horizon": ' .. c3(light.horizon),
		'"sky_ambient": ' .. c3(light.ambient),
		'"rows": {\n' .. table.concat(rows, ",\n") .. "\n}",
	}, ",\n") .. "}\n"
	local name, err = buildat.dump_meshes(json, scene)
	log:info("Reference dump of " .. r.name .. ": " .. tostring(name or err))
	-- and the client's own frame of it, into <user>/screenshots
	local shot, serr = buildat.take_screenshot()
	log:info("Reference screenshot of " .. r.name .. ": " .. tostring(shot or serr))
	r.quit_t = 0
end

function M.leave_viewport()
	if not S.vp then
		return
	end
	S.vp = nil
	S.daylight_key = nil
	M.show_ui()
	refresh_panels()
end

function M.update(dt)
	panel.flush()
	if S.suspended then
		return
	end
	if M.probe_what then
		M.probe_frame()
	end
	-- A move's time, for the lighting it defers (M.apply_daylight)
	if S.drag and (S.drag.kind == "move" or S.drag.kind == "node") then
		M.move_t = buildat.get_time_us()
	end
	M.save_view(dt)
	cam3d.fov = M.fov_for(S.view == "walk" and S.walk_fov or 60)
	-- The floors above hidden in 3D, when the layouts menu says so, and
	-- every layout but a volume on its own ([FP_VOXEL_ALONE]). Deep: a
	-- layout's nodes hold its walls and objects as children.
	place.shown = place.shown or {}
	for id, parts in pairs(place.parts) do
		local shown = not S.alone and not (S.hide_above and S.view == "3d" and
				place.above and place.above[id])
		if place.shown[id] ~= shown then
			place.shown[id] = shown
			for _, n in pairs(parts) do
				n:SetDeepEnabled(shown)
			end
		end
	end
	M.apply_alone()
	move_camera(dt)
	-- A viewport's camera does not move: whatever moved it, it is put back
	local vp = S.vp and doc.ents[S.vp]
	if S.vp and not vp then
		M.leave_viewport()
	elseif vp then
		local v = vp.ints
		S.pos = {x = W(v.x), y = W(v.y), z = W(v.z)}
		S.yaw, S.pitch = v.yaw / 1000, v.pitch / 1000
		cam3d.fov = M.fov_for(v.fov)
	end
	-- The camera of the view in use, kept for when it is gone back to
	if S.vp then
		-- (a viewport's is its own)
	elseif S.view == "3d" then
		S.cam3d = {x = S.pos.x, y = S.pos.y, z = S.pos.z, yaw = S.yaw,
				pitch = S.pitch}
	elseif S.view == "walk" then
		S.walk.yaw, S.walk.pitch = S.yaw, S.pitch
	end
	-- [FP_VOXEL_ALONE] Out of it when the tool or the selection changes
	if S.alone and (S.tool ~= "voxel" or S.primary ~= S.alone.id or
			not E.inst_data[S.alone.id]) then
		M.leave_alone()
	end
	if S.alone and S.alone.dist then
		M.alone_camera()
	end
	place_cameras()
	send_presence(dt)
	stream_drag(dt)
	if S.dirty and S.drag and S.drag.light then
		M.rebuild_light()
	elseif S.dirty then
		rebuild()
	end
	local daylight_t = buildat.get_time_us()
	M.apply_daylight()
	if M.probe_what then
		M.probe_add("daylight", (buildat.get_time_us() - daylight_t) / 1000)
		M.probe_key_ready()
	end
	M.probes_tick()
	M.wb_tick(dt)
	M.refdump_tick(dt)
	-- A menu made since: its buttons for the keyboard
	if E.pause_win and E.pause_win ~= M.keyed_win then
		M.keyed_win = E.pause_win
		panel.keyboard_menu(E.pause_win)
	end
	panel.sweep()
	E.fit_pause()
	if S.panels_stale and not doc.typing() then
		refresh_panels()
	elseif S.props_stale and not doc.typing() then
		M.refresh_props()
	end
	label_i = 0
	-- No hints and no highlights while a viewport is shown clean
	S.guide = not doc.ui_hidden and compute_guide() or nil
	-- [FP_TOUCH] 4: a finger held still is the right button
	if S.touch and not S.paused then
		local only, n = nil, 0
		for _, f in pairs(S.fingers) do
			only, n = f, n + 1
		end
		if n == 1 and not only.ui and not only.stick and not only.moved and
				not only.held and buildat.get_time_us() - only.t0 > 500000 then
			only.held = true
			M.long_press()
		end
		-- The guide wraps to the screen, over the touch bar
		hud:SetFixedWidth(magic.ui.root.width - 24)
		hud:SetPosition(0, -(S.touch_bar and S.touch_bar.height + 20 or 12))
	end
	local text = guide_text(S.guide)
	if hud.text ~= text then
		hud:SetText(text)
	end
	-- **The plan's date and time while a time-lapse runs** (a playtest,
	-- 2026-10-06), at the top in either view
	if not M.clock then
		M.clock = magic.ui.root:CreateChild("Text")
		M.clock:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 18)
		M.clock:SetAlignment(magic.HA_CENTER, magic.VA_TOP)
		M.clock:SetPosition(0, 40)
		M.clock:SetTextEffect(magic.TE_SHADOW)
		M.clock.priority = 90
	end
	local clock = ""
	if M.sun().lapse > 0 and not doc.ui_hidden then
		local m = M.plan_minute()
		clock = M.daylight.date_text(M.plan_day()) .. string.format("  %02d:%02d",
				math.floor(m / 60), math.floor(m % 60))
	end
	if M.clock.text ~= clock then
		M.clock:SetText(clock)
	end
	draw_overlay()
	for i = label_i + 1, #label_nodes do
		label_nodes[i].visible = false
	end
	-- Hidden for a viewport: whatever was made or shown since
	if doc.ui_hidden then
		-- (pairs: any of them may be nil, where ipairs would stop)
		for _, w in pairs({toolbar, props, palette_win, picker_win, place.win,
				E.pause_win, S.touch_bar, hud, crosshair}) do
			w.visible = false
		end
		for i = 1, label_i do
			label_nodes[i].visible = false
		end
	else
		hud.visible = true
	end
end

function M.start(d)
	doc = d
	E.doc = d
	-- The editor's state, for what reads it from outside (tutorial.lua)
	M.S = S
	M.folded = panel.folded
	doc.members_changed = M.members_changed
	doc.backups_changed = M.backups_changed
	doc.ghost_changed = M.ghost_changed
	S.material = nil
	doc.listeners[#doc.listeners + 1] = function(changed, deleted)
		if S.suspended then
			return
		end
		for id in pairs(S.sel) do
			if not doc.ents[id] then
				S.sel[id] = nil
			end
		end
		if S.primary and not S.sel[S.primary] then
			S.primary = next(S.sel)
		end
		for id in pairs(S.nodes) do
			if not doc.ents[id] then
				S.nodes[id] = nil
			end
		end
		-- The panel reads the instances' placement and gaps
		rebuild()
		refresh_panels()
	end
	doc.privs_changed = function()
		if not doc.can("edit") and S.tool and S.tool ~= "select" then
			set_tool("select")
		end
		refresh_panels()
		-- The pause menu's mode shows what the server says
		if M.pause_top() then
			M.open_pause()
		end
	end
	doc.others_changed = function()
		S.dirty = true
	end
	doc.voxels_changed = function()
		S.dirty = true
		refresh_panels()
	end
	doc.on_round_trip = function(ms)
		if M.probe_what then
			M.probe_add("rtt", ms)
		end
	end
	-- A press off an open dropdown closes it, and one on the view does
	-- nothing else
	-- None of the input is the editor's under the plans page (M.suspend):
	-- a click on a plan there went on to pick in the plan just closed
	local function live(f)
		return function(...)
			if not S.suspended then
				f(...)
			end
		end
	end
	-- For a check: "event fp_room x0 z0 x1 z1" (mm), a room on those
	-- corners in the current layout, no walls ([FP_FLOOR_AREA]'s check)
	magic.SubscribeToEvent("command_seq:fp_room", function(_, d)
		local x0, z0, x1, z1 = d:GetString("Param"):match(
				"^(%S+) (%S+) (%S+) (%S+)$")
		x0, z0, x1, z1 = tonumber(x0), tonumber(z0), tonumber(x1), tonumber(z1)
		if not z1 then
			return
		end
		local walls = S.room_walls
		S.room_walls = false
		add_room({{x = x0, z = z0}, {x = x1, z = z0}, {x = x1, z = z1},
				{x = x0, z = z1}})
		S.room_walls = walls
		log:info("A room made by the drive")
	end)
	-- "event fp_wall x0 z0 x1 z1 [bottom]": a 100 mm centred wall, full
	-- height, or hung from the plan's ceiling down to bottom ([FP_NET_WALLS])
	magic.SubscribeToEvent("command_seq:fp_wall", function(_, d)
		local v = {}
		for w in d:GetString("Param"):gmatch("%S+") do
			v[#v + 1] = tonumber(w)
		end
		if not v[4] then
			return
		end
		local keep = {S.thickness, S.justify, S.shift, S.height, S.hang}
		S.thickness, S.justify, S.shift = 100, 0, 0
		S.height, S.hang = v[5] and settings().ceiling - v[5] or 0,
				v[5] and 1 or 0
		add_wall({x = v[1], z = v[2]}, v[3], v[4], nil)
		S.thickness, S.justify, S.shift, S.height, S.hang =
				keep[1], keep[2], keep[3], keep[4], keep[5]
		S.draw = nil
		log:info("A wall made by the drive")
	end)
	-- [FP_MOVE_FAST] For a check: "event fp_select <what> [view]", what
	-- being furniture (the last box on the floor), door or node (a wall's;
	-- the first) in the current layout by id selected (a node by the Nodes
	-- tool), the
	-- view (2d or 3d) picked and both cameras on it -- the plan view
	-- centred there, the 3D one 2.2 m over its floor looking down -- and
	-- the moves from then on measured (M.probe_frame)
	magic.SubscribeToEvent("command_seq:fp_select", function(_, d)
		local what, view = d:GetString("Param"):match("^(%S+) ?(%S*)$")
		if view and view ~= "" then
			M.pick_view(view)
		end
		local pick
		for _, e in ipairs(of_type(what == "node" and "node" or "instance")) do
			local i = e.ints
			local def = what ~= "node" and doc.ents[i.def]
			if (i.layout or 0) == (doc.layout or 0) and (what == "node" or
					def and def.ints.kind == (what == "door" and KIND.door or
					KIND.box) and (what == "door" or (i.offset or 0) == 0)) then
				pick = e
				if what ~= "furniture" then
					break
				end
			end
		end
		if not pick then
			log:info("fp_select: no " .. what)
			return
		end
		local x, z = pick.ints.x, pick.ints.z
		if what == "node" then
			set_tool("node")
			S.nodes = {[pick.id] = true}
		else
			set_tool("select")
			S.sel, S.primary = {[pick.id] = "instance"}, pick.id
			local it = E.inst_data[pick.id]
			x, z = it and it.x or x, it and it.z or z
		end
		local lay = doc.ents[doc.layout or 0]
		local y = lay and lay.ints.y or 0
		S.cx, S.cz = x, z
		S.pos = {x = W(x), y = W(y) + 2.2, z = W(z)}
		S.yaw, S.pitch = 0, 89.9
		M.probe_what = what
		S.dirty = true
		refresh_panels()
		log:info(string.format("fp_select: %s %d at %d %d", what, pick.id, x, z))
	end)
	-- "event fp_where": the selection's place logged, "fp_where: <id> <x>
	-- <z> <along>", with the grid step; "event fp_bad_move": a move of it
	-- 1000 mm in x shown at once in a batch the server refuses (a set of
	-- an entity there is none of), which puts it back
	local function probe_id()
		return S.tool == "node" and next(S.nodes) or S.primary
	end
	magic.SubscribeToEvent("command_seq:fp_where", function()
		local e = doc.ents[probe_id() or 0]
		if e then
			log:info(string.format("fp_where: %d %d %d %d grid %d", e.id, e.ints.x,
					e.ints.z, e.ints.along or 0, grid_step()))
		end
	end)
	magic.SubscribeToEvent("command_seq:fp_bad_move", function()
		local e = doc.ents[probe_id() or 0]
		if e then
			M.send_shown({{op = "set", ent = {id = e.id, ints = {x = e.ints.x + 1000}}},
					{op = "set", ent = {id = 999999999, ints = {x = 0}}}})
		end
	end)
	-- [FP_VOXEL_ALONE] For a check: "event fp_volume x z w h d size", a
	-- volume of w x h x d voxels of size mm at (x, z), selected under the
	-- voxel tool; "event fp_yaw deg", its yaw turned; "event fp_alone
	-- on|off"; "event fp_voxel_mode place|dig"; "event fp_cells", its
	-- cells, its size and the camera logged
	magic.SubscribeToEvent("command_seq:fp_volume", function(_, d)
		local v = {}
		for w in d:GetString("Param"):gmatch("%S+") do
			v[#v + 1] = tonumber(w)
		end
		local def, inst = doc.placeholder(), doc.placeholder()
		send({
			{op = "create", ent = {id = def, type = "definition", ints = {
					kind = KIND.voxel, voxel_size = v[6]}}},
			{op = "create", ent = {id = inst, type = "instance", ints = {def = def,
					x = v[1], z = v[2], offset = 0}}},
		}, function(err)
			if err ~= "" then
				return
			end
			local cells = {}
			for x = 0, v[3] - 1 do
				for y = 0, v[4] - 1 do
					for z = 0, v[5] - 1 do
						cells[doc.voxel_key(x, y, z)] = default_material()
					end
				end
			end
			doc.set_voxels(S.real[def], cells)
			set_tool("voxel")
			S.sel, S.primary = {[S.real[inst]] = "instance"}, S.real[inst]
			S.voxel_mode = "place"
			refresh_panels()
			log:info("fp_volume: " .. S.real[inst])
		end)
	end)
	magic.SubscribeToEvent("command_seq:fp_yaw", function(_, d)
		local e = doc.ents[S.primary or 0]
		if e then
			send({{op = "set", ent = {id = e.id, ints = {yaw = (e.ints.yaw or 0) +
					tonumber(d:GetString("Param")) * 1000}}}})
		end
	end)
	magic.SubscribeToEvent("command_seq:fp_alone", function(_, d)
		if d:GetString("Param") == "on" then
			M.enter_alone(S.primary)
		else
			M.leave_alone()
		end
		refresh_panels()
	end)
	magic.SubscribeToEvent("command_seq:fp_voxel_mode", function(_, d)
		S.voxel_mode = d:GetString("Param")
	end)
	magic.SubscribeToEvent("command_seq:fp_cells", function()
		local e = doc.ents[S.primary or 0]
		if not e then
			return
		end
		local cells = {}
		for key in pairs(doc.voxels[e.ints.def] or {}) do
			local x, y, z = doc.voxel_cell(key)
			cells[#cells + 1] = string.format("%d,%d,%d", x, y, z)
		end
		table.sort(cells)
		local n = #E.built
		for _ in pairs(E.voxel_meshes) do
			n = n + 1
		end
		log:info(string.format("fp_cells: %s; %s; camera %.1f %.1f %.2f %.2f %.2f "
				.. "dist %s; %d nodes, %s; %s; sky %s %s", table.concat(cells, " "),
				M.voxel_size_text(e.id), S.yaw, S.pitch, S.pos.x, S.pos.y, S.pos.z,
				S.alone and S.alone.dist and string.format("%.2f", S.alone.dist) or "-",
				n, S.view, S.alone and "alone" or "plan", tostring(M.sun().sky),
				tostring(M.sun().minute)))
	end)
	magic.SubscribeToEvent("MouseButtonDown", live(function(_, data)
		-- A viewport's hidden menus come back, and the click does nothing
		-- else
		if doc.ui_hidden then
			M.show_ui()
			S.swallow_up = true
			return
		end
		-- A press with a dropdown's popup up is the popup's
		if panel.popup_open() then
			S.swallow_up = true
			return
		end
		-- [FP_OUTSIDE_CLOSE] A press on the background round the pause
		-- menu (any of its pages) or the layouts menu closes it at the
		-- release, as vanilla's, and does nothing else; one that starts
		-- on the window and ends off it (a slider's drag) does not. Not
		-- the panels used with the view (props, palette): a press on any
		-- of them is not the background.
		-- simplified: the mouse's (a finger's made-up one included); the
		-- builtin accounts pages the menu opens keep their Back. Where the
		-- press is, not the last move: a press with no move before it in
		-- the frame (a tap, a scripted click) was judged by an old spot
		local sc = magic.ui.scale
		local mp = magic.input:GetMousePosition()
		S.mx, S.my = mp.x, mp.y
		local ux, uy = S.mx / sc, S.my / sc
		if S.paused and E.pause_win and not panel.over({E.pause_win}, ux, uy) then
			S.close_on_up = "pause menu"
		elseif not S.paused and place.win and not over_ui() then
			S.close_on_up = "layouts menu"
		end
		if S.close_on_up then
			S.swallow_up = true
			return
		end
		M.mouse_down(data:GetInt("Button"))
	end))
	magic.SubscribeToEvent("MouseButtonUp", live(function(_, data)
		if S.close_on_up then
			log:info("A press off the " .. S.close_on_up .. " closes it")
			if S.close_on_up == "pause menu" then
				close_pause()
			else
				S.layouts_open = false
				refresh_panels()
			end
			S.close_on_up = nil
		end
		M.mouse_up(data:GetInt("Button"))
	end))
	magic.SubscribeToEvent("MouseMove", live(function(_, data)
		M.mouse_move(data:GetInt("X"), data:GetInt("Y"), data:GetInt("DX"),
				data:GetInt("DY"))
	end))
	magic.SubscribeToEvent("MouseWheel", live(function(_, data)
		M.mouse_wheel(data:GetInt("Wheel"))
	end))
	magic.SubscribeToEvent("TouchBegin", live(function(_, data)
		local x, y = data:GetInt("X"), data:GetInt("Y")
		M.touch_begin(data:GetInt("TouchID"), x, y)
	end))
	magic.SubscribeToEvent("TouchMove", live(function(_, data)
		M.touch_move(data:GetInt("TouchID"), data:GetInt("X"), data:GetInt("Y"),
				data:GetInt("DX"), data:GetInt("DY"))
	end))
	magic.SubscribeToEvent("TouchEnd", live(function(_, data)
		M.touch_end(data:GetInt("TouchID"), data:GetInt("X"), data:GetInt("Y"))
	end))
	set_view("2d")
	-- A phone's address bar away from the first tap, until the menu
	buildat.set_web_fullscreen(true)
	log:info("Editor started")
end

-- [FP_MOVE_FAST] The check's measures, once "event fp_select" named what is
-- measured: a key step's time from the key (M.probe_start) to the frame
-- after the one that has its moved state built (M.probe_key_ready; not
-- M.probe or M.probe_ready, rebuild.lua's probes' [FP_WHITE_CONNECT]), and each
-- frame's time over a drag; logged as "fp move: <what> <view> key N ms" and
-- "... drag frames p50 N p95 N ms", with the rebuilds', the lighting's,
-- the panels' and the round trip's times in between
function M.probe_add(k, ms)
	local p = M.probe_drag or M.probe_key
	if p and ms > 0.05 then
		p[k] = (p[k] or 0) + ms
		p[k .. "_n"] = (p[k .. "_n"] or 0) + 1
	end
end
local function probe_parts(p)
	local out = {}
	for _, k in ipairs({"rebuild", "daylight", "panels", "rtt"}) do
		out[#out + 1] = string.format("%s %d %.1f ms", k, p[k .. "_n"] or 0,
				p[k] or 0)
	end
	return table.concat(out, ", ")
end
function M.probe_start(id)
	local e = doc.ents[id]
	local before = {}
	for k, v in pairs(e and e.ints or {}) do
		before[k] = v
	end
	M.probe_key = {t0 = buildat.get_time_us(), view = S.view, id = id,
			before = before}
end
function M.probe_key_ready()
	local p = M.probe_key
	if not p or p.ready or S.dirty then
		return
	end
	local e = doc.ents[p.id]
	for k, v in pairs(e and e.ints or {}) do
		if p.before[k] ~= v then
			p.ready = true
			return
		end
	end
end
function M.probe_frame()
	local now = buildat.get_time_us()
	local p = M.probe_key
	if p and p.ready then
		log:info(string.format("fp move: %s %s key %.1f ms; %s", M.probe_what,
				p.view, (now - p.t0) / 1000, probe_parts(p)))
		M.probe_key = nil
	end
	local d = S.drag
	if d and (d.kind == "move" or d.kind == "node") then
		if not M.probe_drag then
			M.probe_drag = {frames = {}, view = S.view}
		elseif M.frame_t then
			local f = M.probe_drag.frames
			f[#f + 1] = (now - M.frame_t) / 1000
		end
	elseif M.probe_drag and not d then
		local q = M.probe_drag
		local f = q.frames
		table.sort(f)
		if #f > 0 then
			log:info(string.format("fp move: %s %s drag frames p50 %.1f p95 %.1f "
					.. "ms (%d frames); %s", M.probe_what, q.view,
					f[math.ceil(#f * 0.5)], f[math.ceil(#f * 0.95)], #f, probe_parts(q)))
		end
		M.probe_drag = nil
	end
	M.frame_t = now
end

return M
-- vim: set noet ts=4 sw=4:
