-- Buildat: builtin/kit/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT] Kit on the client: play (below: every client's, edit rights or
-- not) and the editor (editor.lua, [KIT] stage 3, its UX floorplanner's
-- since stage 4e2; builtin/kit/api.h says what the server takes). An app
-- hosting Kit turns the editor on with
--   local kit = require("buildat/module/kit").internal
--   kit.editor{scene = scene, camera = camera_node, ground_y = 1,
--       solid = function(x, y, z) return <a voxel there> end}
-- editor.lua's head says what it does and its options; input.lua's the
-- keys as named actions (kit.declare_keys, kit.key_text...).
--
-- **Pointing** ([KIT] stage 4e2): what a click would do is shown on what
-- is pointed at, nothing where a click does nothing, in floorplanner's
-- colours (apps/floorplanner's guides: an action's own colour) --
-- kit.HOVER (selecting, the editor's left button), kit.USE (using an
-- object), kit.DIG (digging), kit.PLACE (placing).
--   kit.play_target(origin, dir, reach[, solid]) -> {left = {kind = "use",
--     id} or {kind = "dig", cell} or {kind = "refused", why}, right =
--     {kind = "place", cell, on, normal}}: in play, what a left click does where the ray points (an
--     object a click uses, before what is behind it, else the voxel this
--     player may dig: edit rights, or a component's grant) and a right
--     click (a voxel placed on the pointed face where this player may);
--     either nil for nothing. solid(x, y, z): the voxels (the editor's
--     solid by default)
--   kit.show_target(t): t drawn this frame (vanilla's pointed box round
--     the object or the voxel, the placement face's frame), logged as it
--     changes ("kit: points at ..."); kit.show_target(nil) none
--   kit.allows(action, x, y, z) -> ok, why: whether this player may
--     "dig", "place", "enter" or "use" there by the regions' rules ([KIT]
--     stage 4j; the server's allows()), and why not; kit.refused(why) shows it
--   kit.may_dig(x, y, z), kit.may_place(x, y, z): this player's rights
--     and the grants there (a grant only while the server is Running)
--   kit.pick_entity(origin, dir, reach) -> id, t, usable: the usable
--     entity nearest along the ray (its look's box, turned as drawn; one
--     with no look near its cell); the rest the ray goes through. usable
--     false: its use is nobody's, through its links only
--     ([KIT_USE_ACCESS]).
--     simplified: a solid one (a shut gate) too, so a dig can reach the
--     voxel behind it; the server's own rules still hold
--   kit.highlighter() -> h: frames drawn this frame: h.begin(),
--     h.box(centre, half sides, rotation or nil, colour), h.face(cell,
--     normal, colour), h.finish() (the ones not drawn again hidden)
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local network = require("buildat/extension/network")
local log = buildat.Logger("kit")

local M = {}
-- The editor's state that play reads too (editing, the rights, the
-- server's state); editor.lua keeps the rest
local E = {editing = false, running = false, by = "", can_edit = false}
local O = {ground_y = 0} -- the app's options, kit.editor's

M.HOVER = magic.Color(0.2, 0.9, 1.0)
M.DIG = magic.Color(1, 0.3, 0.2)
M.PLACE = magic.Color(0.2, 1, 0.3)
M.USE = magic.Color(1.0, 0.55, 0.1)

-- [KIT] stage 4f: one material, one look: a World's heightmap draws its
-- ground textures as the voxels draw theirs, a 16 px texture a metre (a
-- cell) and nearest filtered, not a texture 4 m across smoothed (a texel
-- 25 cm, magnified and blurry close up)
local heightmap = require("buildat/module/heightmap")
do
	heightmap.detail_metres = 1
	heightmap.filter = magic.FILTER_NEAREST
end

local WARN = magic.Color(1.0, 0.55, 0.45)
local DIM = magic.Color(0.7, 0.7, 0.7)
local STYLE = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")

local function color(hex, fallback)
	local r, g, b = tostring(hex):match("^#(%x%x)(%x%x)(%x%x)$")
	if not r then
		return fallback
	end
	return magic.Color(tonumber(r, 16) / 255, tonumber(g, 16) / 255,
			tonumber(b, 16) / 255)
end

local function send(t)
	local text = network.write_json(t)
	log:info("kit editor: sent " .. tostring(text))
	buildat.send_packet("kit:edit", text)
end

local function row(parent)
	local r = parent:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	-- (the touch mode's panes stretch a row's targets across it, shell.lua)
	r:SetVar("KitRow", "1")
	return r
end

local function text(parent, s, c)
	local t = parent:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(s)
	if c then
		t:SetColor(c)
	end
	return t
end

local function label(parent, s, width)
	local t = text(parent, s)
	-- Its text's own width (minWidth): a row's layout may have stretched
	-- its width already
	t.minWidth = math.max(width or 0, t.minWidth)
	return t
end

-- [UI_MODAL_DIM_LEFT] Whether a screen pushed over the game (the pause
-- menu, a dialog) is over b: b not in it (in one top-level element with
-- it), the music editor's buttons being in its own
local function screen_over(b)
	local us = require("buildat/extension/uistack")
	local top = (us.safe or us).main:top()
	return top ~= nil and not top:GetName():find("game is running", 1, true) and
			b:IsDrawnOver(top) ~= nil
end

local function button(parent, s, fn, down)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	b.minHeight = 24
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(s)
	t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	b.minWidth = t.width + 16
	if down then
		t:SetColor(magic.Color(1.0, 0.85, 0.3))
	end
	-- (a Kit window beside the screen, under its shade, took the clicks:
	-- the editor's bar, inspector and palette)
	magic.SubscribeToEvent(b, "Released", function()
		if not screen_over(b) then
			fn()
		end
	end)
	return b, t
end

local function edit(parent, value, on_text)
	local e = parent:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minWidth = 120
	e.minHeight = 24
	-- The text inside the style's 4-pixel border: the style gives no
	-- inset, so the first glyph sat on the border and a focused field's
	-- highlight hid it (the web's publish form showed "oop" for "loop")
	e.clipBorder = magic.IntRect(4, 0, 4, 0)
	e:SetText(value)
	magic.SubscribeToEvent(e, "TextChanged", function()
		on_text(e:GetText())
	end)
	return e
end

local function v3(t)
	return magic.Vector3(t[1], t[2], t[3])
end

-- ---- Play: what every client sees of Kit, edit rights or not
-- A positional entity's node ("kit:<id>") carries its shared state (the
-- var "kit:<key>", JSON) and what its types show (the var "kit_show",
-- {look, hud, client, shared, player}): a type's look (builtin/kit/api.h)
-- is drawn where the entity is, in both modes, from its state: a box
-- (size: its sides, offset: its middle from the entity's position, as the
-- server made them of its extent), a sphere or ([KIT] stage 4d) a wedge,
-- turned by its rotation, its material's, its `when` over it while the
-- state `state` is true (a swing a quarter turn round a hinge at its -x
-- edge; [KIT_COLLECTIBLE] a vanish, update_play's), a collision shape (a
-- static body in the scene's physics) while solid, its state `text` over
-- it; a type's `hud = key` puts that state on the screen.
-- **A type's client part** ([KIT] stage 4d): <name>.client.lua beside the
-- type, sent at join, run as the client's own Lua is (this module's
-- sandbox); it returns a table of handlers, each given `e`, the entity as
-- this client has it:
--   on_add(e), on_state(e, key) (a shared state changed: e.state[key]),
--   on_update(e, dt) (each frame; [KIT_ENT_PERF_2] with the table's
--   skip_offscreen = true, not while the entity is out of the play camera's
--   view: offscreen() below), on_use(e) (this player used it, before
--   the server hears of it), on_remove(e); [KIT_PLANE] stage 4: a movement's
--   draw(s, node, yaw, p) draws the players' bodies (move.lua's top)
--   [KIT_CLIENT_REACT] (1) on_enter(e), on_leave(e): this player's own
--   predicted body met its zone or left it, by this client's own test
--   (update_zones below), before the server's on_enter hears of it
--   e.id, e.node (its replicated node), e.look, e.hinge, e.body (its look's
--   nodes: the body turns with the hinge), e.swing (a swing's open angle:
--   -90, or 90 when.mirror), e.state (the server's), e.mine
--   (this player's own entity), e.you (this player's entity's id,
--   [KIT_BOT_DIFFICULTY]), e:shown(key) (the state as drawn),
--   e:near(d) (this player's entity within d of it),
--   e:predict(key, value, seconds) (drawn so at once, until the server's
--   value changes or the seconds, 1, pass), e:log(text) (this client's log),
--   [KIT_UI_CLIENT_PART] e.ui (its element's rect, the screen, set{...}:
--   ui.lua's M.ui_api);
--   [KIT_CLIENT_REACT] require("buildat/module/kit") is [KIT_API_1] the
--   table at this file's end: kit.shared, kit.pointed, kit.use,
--   kit.body_state(), kit.body_pos(), kit.seated(), [RACER_FEEL] (2), (3)
--   kit.shake(a) (controls.lua's head), kit.effect{...}, kit.mark{...},
--   kit.clear_marks() (effects.lua), kit.ui_keys() (ui.lua),
--   kit.press_action, kit.key_down, kit.key_name, kit.key_text (input.lua),
--   [KIT_MOVE_DRAW] kit.material (below),
--   also from a movement's draw; kit.internal (this module) is outside Kit
--   API 1; a handler that errs is off for that
--   entity here, its first failure sent (call() below). api.h's client
--   parts paragraph says what else a part reaches and what is refused
-- kit.pointed(origin, dir, reach) -> the id of the entity nearest the ray
-- (its look's box, or near its cell), kit.use(id) uses it: the server
-- checks range and whether it is usable. The player's inventory (c:add,
-- c:take...) is a line on the screen. The Stop notice: "Your builds while
-- playing were discarded." (who built how many when others did too), and
-- for a builder "Keep them" (the tools' panel has it until the next Play).
-- For a drive (doc/client_commands.txt's event): "event kit_edit <json>"
-- sends an edit as the editor would, "event kit_use <id>" a use,
-- "event kit_type <json>" a custom type's "kit:type", "event
-- kit_publishing <json>" a Publishing page's op.
local replicate = require("buildat/extension/replicate")
local P = {nodes = {}, items = "", parts = {}, you = 0, preview = {},
	pose = {}}

local function parse(v)
	if v:IsEmpty() then
		return nil
	end
	return network.parse_json(v:GetString())
end

local function shown(v)
	if v == nil then
		return ""
	end
	if type(v) == "table" then
		return network.write_json(v)
	end
	return tostring(v)
end

-- A state as it is drawn: the server's, or this client's prediction until
-- the server's value changes from what it was then, or its time is up
local function value(n, key)
	key = tostring(key)
	-- ([KIT_LOBBY] a per_player state: this player's own, kit:mine's; a
	-- gem each rider takes for themselves)
	local own = n.id and M.mine_state and M.mine_state(n.id, key)
	if own ~= nil then
		return own
	end
	local server = parse(n.node:GetVar("kit:" .. key))
	local p = n.predicted and n.predicted[key]
	if p then
		if buildat.get_time_us() < p.till and shown(server) == p.was then
			return p.value
		end
		-- ([KIT_PREDICT_UNDONE] dropped outside draw_look, by a client
		-- part's e:shown: its look drawn again, or still() keeps it on)
		n.predicted[key] = nil
		n.calm = 0
	end
	return server
end

local function drop_look(n)
	-- ([KIT_ENT_PERF_2] out of what it was merged into: merge.lua's)
	if M.merge_drop then
		M.merge_drop(n)
	end
	if n.look then
		n.look:Remove()
	end
	n.mesh = nil
	-- ([KIT_SIDE_SCENERY] (8) a parallax layer's copies of it, below)
	for _, c in ipairs(n.par_copies and n.par_copies.nodes or {}) do
		c:Remove()
	end
	n.par_copies, n.par, n.par_solid = nil, nil, nil
	n.wear_wanted, n.ghost, n.hidden, n.ghost_alpha, n.poly = nil, nil, nil, nil, nil
	n.vanish = nil
	n.look, n.hinge, n.body, n.mat, n.text, n.solid, n.box, n.on = nil, nil,
			nil, nil, nil, nil, nil, nil
	n.text_back, n.text_back_node, n.edge_mat = nil, nil, nil
	n.worn, n.far_look = nil, nil
end

-- [KIT_3D_GAINS_1] (4z38) Culling by distance: a look's drawables drawn no farther
-- than M.look_reach (environment.lua's: kit/environment's fog_end and a tenth, the
-- far clip's; nil, no environment: no limit) and their own reach (Urho3D measures
-- from a drawable's box's middle: a long road piece's near end stays); a far
-- kit/parallax layer's never (its pass's far_look)
local CULLED = {"StaticModel", "CustomGeometry", "Text3D"}
local function cull(n)
	local d = M.look_reach
	local function walk(node)
		for _, kind in ipairs(CULLED) do
			local c = node:GetComponent(kind)
			if c then
				local r = 0
				if d then
					local bb = c.worldBoundingBox
					r = (bb.max - bb.min):Length() / 2
				end
				c.drawDistance = d and d + r or 0
			end
		end
		for i = 0, node:GetNumChildren() - 1 do
			walk(node:GetChild(i))
		end
	end
	if n.look and n.far_look ~= n.look then
		walk(n.look)
	end
end
function M.set_look_reach(d)
	d = tonumber(d)
	if d == M.look_reach then
		return
	end
	M.look_reach = d
	local k = 0
	for _, n in pairs(P.nodes) do
		if n.look then
			cull(n)
			k = k + 1
		end
	end
	if M.merge_reach then
		M.merge_reach()
	end
	log:info("kit: looks drawn " .. (d and string.format("to %.0f m", d) or
			"at any distance") .. " (" .. k .. " looks)")
end

-- [KIT_LIGHTING_SCENE] The lighting turned physical or back (environment.lua's
-- set_lighting): every look drawn again (its colour, a voxel material's
-- technique, a text's, look_technique and text3d)
function M.relit()
	for _, n in pairs(P.nodes) do
		if n.look then
			drop_look(n)
			n.last_text = nil
			n.gen, n.calm = (n.gen or 0) + 1, 0
		end
	end
end

-- A client part's handler, protected: one that fails is left off for
-- that entity, logged, and ([KIT_CLIENT_REACT] (4)) told to the server
-- ("kit:part_failed" {id, type, handler, error}: the entity's log, a
-- builder's editor Log; the server bounds how many). simplified: an old
-- part's on_remove as a new one replaces it is not told (its type unknown)
local function call(n, part, fn, ...)
	local f = part[fn]
	if type(f) ~= "function" or (n.failed and n.failed[part]) then
		return
	end
	-- (here, not by the frame: a still look's part is called too)
	local e = n.e
	e.look, e.hinge, e.body, e.swing = n.look, n.hinge, n.body, n.swing
	e.mine, e.you = n.id == P.you, P.you
	local ok, err = pcall(f, e, ...)
	if not ok then
		n.failed = n.failed or {}
		n.failed[part] = true
		-- Its place as the part's (eval names the chunk as this file).
		-- simplified: an error inside this file's own e: functions is
		-- named so too
		local t = ""
		for name, p in pairs(P.parts) do
			t = p == part and name or t
		end
		err = tostring(err):gsub('^%[string "[^"]*"%]:', t .. ".client:", 1)
		log:warning("kit: entity " .. tostring(n.e.id) .. "'s client part " ..
				fn .. ": " .. err)
		buildat.send_packet("kit:part_failed", network.write_json({
				id = n.e.id, type = t, handler = fn, error = err:sub(1, 300)}))
	end
end

local function parts_of(n)
	local r = {}
	local show = type(n.show) == "table" and n.show or {}
	for _, t in ipairs(type(show.client) == "table" and show.client or {}) do
		if P.parts[t] then
			r[#r + 1] = P.parts[t]
		end
	end
	return r
end

-- (P.by_nid: the entity ids by their node's id; n.nid its node's id;
-- [KIT_STUNTS_PERF] P.nodes_gen counts the nodes come and gone, for what is
-- kept across frames of them)
P.by_nid, P.nodes_gen = {}, 0
replicate.sub_sync_node_added({}, function(node)
	local id = tonumber(node:GetName():match("^kit:(%d+)$"))
	if id then
		local nid = node:GetID()
		P.nodes[id] = {node = node, id = id, nid = nid}
		P.by_nid[nid] = id
		P.nodes_gen = P.nodes_gen + 1
	end
end)
replicate.sub_sync_node_removed(function(node, node_id)
	local id = P.by_nid[node_id]
	local n = id and P.nodes[id]
	P.by_nid[node_id] = nil
	if n and n.nid == node_id then
		if n.added then
			for _, part in ipairs(parts_of(n)) do
				call(n, part, "on_remove")
			end
		end
		drop_look(n)
		P.nodes[id] = nil
		P.nodes_gen = P.nodes_gen + 1
	end
end)

-- A look's box as it is drawn now (on: its state is true): its sides, its
-- middle from the entity, whether it is solid and its colour. A swing's
-- the box it is turned to (a quarter round its -x edge, towards +z)
local function look_box(look, on)
	local size, off = {}, {0, 0, 0}
	-- ([KIT_SIDE_SCENERY] a polygon's box up to 512 wide: kit.cpp's
	-- MAX_POLYGON_EXTENT)
	local cap = look.shape == "polygon" and 512 or 64
	if type(look.size) == "table" then
		for i = 1, 3 do
			size[i] = math.max(0.02, math.min(cap, tonumber(look.size[i]) or 1))
		end
	else
		local s = (tonumber(look.size) or 0.4) * 2
		size = {s, s, s}
	end
	if type(look.offset) == "table" then
		for i = 1, 3 do
			off[i] = tonumber(look.offset[i]) or 0
		end
	end
	local w = on and type(look.when) == "table" and look.when or {}
	local solid = look.solid == true
	if w.solid ~= nil then
		solid = w.solid == true
	end
	if type(w.scale) == "table" then
		for i = 1, 3 do
			local was = size[i]
			size[i] = size[i] * (tonumber(w.scale[i]) or 1)
			-- Its bottom kept ([KIT_CLIENT_REACT] (6) a polygon's box scaled
			-- about its own point, as its mesh is)
			if look.shape == "polygon" then
				off[i] = off[i] * (tonumber(w.scale[i]) or 1)
			elseif i == 2 then
				off[2] = off[2] - (was - size[2]) / 2
			end
		end
	end
	if w.swing then
		-- [KIT_DOOR_MIRROR] mirror: the other way, from its back to -z
		local hinge, front = off[1] - size[1] / 2, off[3] - size[3] / 2
		local back = off[3] + size[3] / 2
		size[1], size[3] = size[3], size[1]
		off[1] = hinge + size[1] / 2
		off[3] = w.mirror == true and back - size[3] / 2 or
				front + size[3] / 2
	end
	return {size = size, off = off, solid = solid, color = w.color or look.color}
end

local function v3(t)
	return magic.Vector3(t[1], t[2], t[3])
end

-- A unit wedge (-0.5...0.5), its slope rising along +z to the full height
-- at its back; its triangles too (set_triangle_geometry's 12 numbers a vertex:
-- [KIT_ENT_PERF_2] what merge.lua bakes)
local WEDGE = {}
do
	local a, b = -0.5, 0.5
	local function tri(p1, p2, p3, nrm)
		for _, p in ipairs({p1, p2, p3}) do
			for _, v in ipairs({p[1], p[2], p[3], nrm[1], nrm[2], nrm[3], 1, 1, 1, 1, 0, 0}) do
				WEDGE[#WEDGE + 1] = v
			end
		end
	end
	local s = math.sqrt(0.5)
	local slope = {0, s, -s}
	-- The slope, the bottom, the back, the two sides
	tri({a, a, a}, {a, b, b}, {b, b, b}, slope)
	tri({a, a, a}, {b, b, b}, {b, a, a}, slope)
	tri({a, a, a}, {b, a, a}, {b, a, b}, {0, -1, 0})
	tri({a, a, a}, {b, a, b}, {a, a, b}, {0, -1, 0})
	tri({a, a, b}, {b, a, b}, {b, b, b}, {0, 0, 1})
	tri({a, a, b}, {b, b, b}, {a, b, b}, {0, 0, 1})
	tri({a, a, a}, {a, a, b}, {a, b, b}, {-1, 0, 0})
	tri({b, a, a}, {b, b, b}, {b, a, b}, {1, 0, 0})
end
local function wedge(node)
	buildat.set_triangle_geometry(node, WEDGE)
	return node:GetComponent("CustomGeometry"), WEDGE
end
-- [KIT_ENT_PERF_2] Models/Box.mdl's unit box as such triangles: each face its
-- normal out, its corners' texture coordinates 0...1
local BOX = {}
do
	for _, f in ipairs({{{1, 0, 0}, {0, 0, 1}}, {{-1, 0, 0}, {0, 0, -1}},
			{{0, 1, 0}, {1, 0, 0}}, {{0, -1, 0}, {1, 0, 0}},
			{{0, 0, 1}, {-1, 0, 0}}, {{0, 0, -1}, {1, 0, 0}}}) do
		local nr, u = f[1], f[2]
		-- v = normal x u, so u x v is the normal: wound as voxel_mesh's (cross(p2
		-- - p1, p3 - p1) along the normal)
		local v = {nr[2] * u[3] - nr[3] * u[2], nr[3] * u[1] - nr[1] * u[3],
			nr[1] * u[2] - nr[2] * u[1]}
		for _, c in ipairs({{-1, -1}, {1, -1}, {1, 1}, {-1, -1}, {1, 1}, {-1, 1}}) do
			for k = 1, 3 do
				BOX[#BOX + 1] = nr[k] / 2 + u[k] * c[1] / 2 + v[k] * c[2] / 2
			end
			for _, x in ipairs({nr[1], nr[2], nr[3], 1, 1, 1, 1, (c[1] + 1) / 2,
					(1 - c[2]) / 2}) do
				BOX[#BOX + 1] = x
			end
		end
	end
end

-- A look's material ([KIT] stage 4d): plain, metal, glass or glow
local TECHNIQUES = {glass = "Techniques/NoTextureAlpha.xml",
	glow = "Techniques/NoTextureUnlit.xml"}
local function material(name)
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			TECHNIQUES[name] or "Techniques/NoTexture.xml"))
	m:SetShaderParameter("MatSpecColor", name == "metal" and
			magic.Color(0.6, 0.6, 0.6, 30) or magic.Color(0.05, 0.05, 0.05))
	return m
end

-- [KIT_LOOK_MATERIAL] A voxel material's definition by its name (a
-- block's, not one of its shapes'): its id looked up again while the
-- registry grows (a builder's new voxel). [KIT_SCENES_STALE_DEF] Only ids
-- are kept, the definition fetched from the registry of the moment: a
-- scene switch or a season replaces the registry, and a definition kept
-- from the old one is freed memory (a crash reading its textures)
local voxel_ids = {count = -1, by = {}}
local function voxel_def(name)
	local reg = require("buildat/module/voxelworld").get_voxel_registry()
	if not reg then
		return nil
	end
	local function named(id)
		local def = id and reg:get_by_id(id)
		return def and def.name and def.name.block_name == name and def or nil
	end
	local count = reg:get_count()
	local def = count == voxel_ids.count and named(voxel_ids.by[name])
	if def or (count == voxel_ids.count and voxel_ids.by[name] == nil) then
		return def or nil
	end
	voxel_ids.count, voxel_ids.by = count, {}
	for id = 1, count - 1 do
		local d = reg:get_by_id(id)
		local bn = d and d.name and d.name.block_name
		if bn and not voxel_ids.by[bn] then
			voxel_ids.by[bn] = id
		end
	end
	return named(voxel_ids.by[name])
end

-- [KIT_LOOK_MATERIAL] A voxel material's tiles (+y, -y, +x, -x, +z, -z, the
-- voxels' order) {t the texture, n its segments, s the one, its name}, its tint (its
-- palette's entry 0) and the technique a look wearing it is drawn with; nil
-- when it has no textures here
local face_textures = {}
local function voxel_tiles(def)
	local tex = {}
	for i = 1, 6 do
		local seg = def.textures[i]
		local name = seg and seg.resource_name or ""
		if name ~= "" then
			local t = face_textures[name]
			if t == nil then
				t = magic.cache:GetResource("Texture2D", name) or false
				if t then
					t.filterMode = magic.FILTER_NEAREST
				end
				face_textures[name] = t
			end
			if t then
				tex[i] = {t = t, n = seg.total_segments,
					s = seg.select_segment, name = name}
			end
		end
	end
	if not next(tex) then
		return nil
	end
	-- [KIT_TINT_MASK] Worn as the voxels wear it untinted: its palette's
	-- entry 0 (a re-painted texture's own colour), masked by a solid one's
	-- alpha
	local pal = def.tint_palette
	local c0 = pal and tonumber(pal[1]) or 0xffffff
	local tint0 = magic.Color(math.floor(c0 / 65536) % 256 / 255,
			math.floor(c0 / 256) % 256 / 255, c0 % 256 / 255, 1)
	local look_tech = def.translucent and "kit/KitVoxelLookAlpha.xml" or
			def.alpha_masked and "kit/KitVoxelLookMasked.xml" or
			"kit/KitVoxelLook.xml"
	return tex, tint0, look_tech
end

-- [KIT_LIGHTING_SCENE] A look's technique: under physical a solid voxel
-- material's albedo decoded to linear, as the World's voxels' are (undecoded,
-- Brimstone's dirt road read pale beige; a plain colour is decoded where it is
-- set). simplified: the solid look alone; a translucent, cut out or glass look
-- stays as cartoon's (a Phys copy of their XML each is the upgrade)
local function look_technique(name)
	if name == "kit/KitVoxelLook.xml" and M.physical and M.physical() then
		name = "kit/KitVoxelLookPhys.xml"
	end
	return magic.cache:GetResource("Technique", name)
end

-- [KIT_LOOK_MATERIAL] A unit box or wedge (wedge's) wearing a voxel
-- material's tiles (voxel_tiles; a wedge's slope its +y, its back +z), a
-- texture a metre of its sides `size` as the voxels wear theirs (a tile of a
-- texture of several stretched over its face); nil when the material has no
-- textures here
local function voxel_mesh(node, def, size, shape)
	local tex, tint0, look_tech = voxel_tiles(def)
	if not tex then
		return nil
	end
	local sx, sy, sz = size[1], size[2], size[3]
	local a, b = -0.5, 0.5
	-- Each face: its tile, its normal (unit box), its corners {x, y, z}
	-- (unit) with where they are on it in metres {u, v} (v down), as
	-- triangles; its extent in metres (a segment's fraction)
	local faces
	local function corner(x, y, z, u, v)
		return {x, y, z, u, v}
	end
	if shape == "wedge" then
		local L = math.sqrt(sy * sy + sz * sz)
		-- The slope: from its back top (v 0) down to its front bottom
		local function sl(x, y, z)
			return corner(x, y, z, (x + 0.5) * sx, (0.5 - z) * L)
		end
		local function bt(x, y, z)
			return corner(x, y, z, (x + 0.5) * sx, (z + 0.5) * sz)
		end
		local function bk(x, y, z)
			return corner(x, y, z, (0.5 - x) * sx, (0.5 - y) * sy)
		end
		local function sd(x, y, z, k)
			return corner(x, y, z, (k * z + 0.5) * sz, (0.5 - y) * sy)
		end
		faces = {
			{1, {0, 1, -1}, {sx, L}, {sl(a, a, a), sl(a, b, b), sl(b, b, b),
				sl(a, a, a), sl(b, b, b), sl(b, a, a)}},
			{2, {0, -1, 0}, {sx, sz}, {bt(a, a, a), bt(b, a, a), bt(b, a, b),
				bt(a, a, a), bt(b, a, b), bt(a, a, b)}},
			{5, {0, 0, 1}, {sx, sy}, {bk(a, a, b), bk(b, a, b), bk(b, b, b),
				bk(a, a, b), bk(b, b, b), bk(a, b, b)}},
			{4, {-1, 0, 0}, {sz, sy}, {sd(a, a, a, 1), sd(a, a, b, 1),
				sd(a, b, b, 1)}},
			{3, {1, 0, 0}, {sz, sy}, {sd(b, a, a, -1), sd(b, b, b, -1),
				sd(b, a, b, -1)}},
		}
	else
		-- Its normal, its across and down edges
		local quads = {
			{{0, 1, 0}, {1, 0, 0}, {0, 0, -1}},
			{{0, -1, 0}, {1, 0, 0}, {0, 0, 1}},
			{{1, 0, 0}, {0, 0, 1}, {0, -1, 0}},
			{{-1, 0, 0}, {0, 0, -1}, {0, -1, 0}},
			{{0, 0, 1}, {-1, 0, 0}, {0, -1, 0}},
			{{0, 0, -1}, {1, 0, 0}, {0, -1, 0}},
		}
		faces = {}
		for i, f in ipairs(quads) do
			local nr, eu, ev = f[1], f[2], f[3]
			local mu = math.abs(eu[1] * sx + eu[2] * sy + eu[3] * sz)
			local mv = math.abs(ev[1] * sx + ev[2] * sy + ev[3] * sz)
			local function at(fu, fv)
				local p = {}
				for k = 1, 3 do
					p[k] = nr[k] * 0.5 + eu[k] * (fu - 0.5) +
							ev[k] * (fv - 0.5)
				end
				return corner(p[1], p[2], p[3], fu * mu, fv * mv)
			end
			faces[i] = {i, nr, {mu, mv}, {at(0, 0), at(1, 0), at(1, 1),
				at(0, 0), at(1, 1), at(0, 1)}}
		end
	end
	-- ([KIT_ENT_PERF_2] the faces' triangles handed over in one call, each a
	-- list of set_triangle_geometry's: the parts merge.lua bakes)
	local mats, lists, parts = {}, {}, {}
	for g, f in ipairs(faces) do
		local tile, nr, ext, vs = f[1], f[2], f[3], f[4]
		local t = tex[tile] or tex[1] or select(2, next(tex))
		local nx, ny = t.n and t.n.x or 1, t.n and t.n.y or 1
		local nl = math.sqrt(nr[1] * nr[1] + nr[2] * nr[2] + nr[3] * nr[3])
		local nv = {nr[1] / nl, nr[2] / nl, nr[3] / nl}
		local list = {}
		lists[g] = list
		for q = 1, #vs, 3 do
			local tri = {vs[q], vs[q + 1], vs[q + 2]}
			-- Wound so it faces its normal: cross(p2 - p1, p3 - p1) along
			-- it (the wedge's)
			local e1, e2 = {}, {}
			for k = 1, 3 do
				e1[k] = tri[2][k] - tri[1][k]
				e2[k] = tri[3][k] - tri[1][k]
			end
			local cx = {e1[2] * e2[3] - e1[3] * e2[2], e1[3] * e2[1] -
					e1[1] * e2[3], e1[1] * e2[2] - e1[2] * e2[1]}
			if cx[1] * nr[1] + cx[2] * nr[2] + cx[3] * nr[3] < 0 then
				tri[2], tri[3] = tri[3], tri[2]
			end
			for _, c in ipairs(tri) do
				local u, v = c[4], c[5]
				if nx > 1 or ny > 1 then
					u, v = (t.s.x + c[4] / ext[1]) / nx, (t.s.y + c[5] / ext[2]) / ny
				end
				local o = #list
				list[o + 1], list[o + 2], list[o + 3] = c[1], c[2], c[3]
				list[o + 4], list[o + 5], list[o + 6] = nv[1], nv[2], nv[3]
				list[o + 7], list[o + 8], list[o + 9], list[o + 10] = 1, 1, 1, 1
				list[o + 11], list[o + 12] = u, v
			end
		end
		local m = magic.Material:new()
		m:SetTechnique(0, look_technique(look_tech))
		m:SetTexture(magic.TU_DIFFUSE, t.t)
		m:SetShaderParameter("MatDiffColor", tint0)
		m:SetShaderParameter("MatSpecColor", magic.Color(0.05, 0.05, 0.05))
		mats[g] = m
		-- (what makes the material: one baked with another of the same key shares it)
		parts[g] = {list = list, mat = m, key = string.format("v|%s|%s|%s|%.4f,%.4f,%.4f",
				look_tech, t.name, tostring(M.physical and M.physical()), tint0.r,
				tint0.g, tint0.b)}
	end
	buildat.set_triangle_geometry(node, lists)
	local cg = node:GetComponent("CustomGeometry")
	for g, m in ipairs(mats) do
		cg:SetMaterial(g - 1, m)
	end
	cg.castShadows = true
	return cg, mats, parts
end

-- [KIT_PLANE] stage 3: a polygon look's mesh in its own frame: its points (x, y)
-- extruded its depth along z round 0, its two faces (move.lua's triangles; with
-- bands slabs') and a side an edge; n.poly its points and half depth
-- (entity_t's). Returns the CustomGeometry, its faces' triangles, whether it
-- wears textures and its top band's triangles.
-- [KIT_SIDE_SCENERY] Wearing a voxel material (def, voxel_tiles'), textured
-- world-aligned where its node is (at, q), a repeat a cell, so pieces side by side
-- tile: on its faces u and v are the world's x and -y (lying flat, its faces
-- level: x and -z, else a stripe); on a side nearer level than
-- upright the world's x and -z, else z and -y. Its faces wear the material's
-- bottom tile where that is not its top (grass: the dirt under its turf), else
-- its -z side's. An edge facing up (its normal out within 60 degrees of the
-- world's up) wears the top tile on its side and, on the faces, a band of it
-- look.edge_depth deep: the edge pushed straight down that far (a parallelogram),
-- cut out of the faces' triangles (convex pieces, Sutherland and Hodgman), its
-- part inside them the top's, so a concave outline's band stays inside it and
-- no two overlap. Its colour is unused (the material's own tint, as a kit/part's),
-- its material kept: metal shinier, glass at 0.4 alpha, glow unlit.
-- simplified: a texture of several segments repeats whole
local polygon_mesh
do
	local MV
	-- A convex polygon {x1, y1...} cut to a * x + b * y <= c
	local function cut(p, a, b, c)
		local o, k = {}, #p / 2
		for i = 1, k do
			local j = i % k + 1
			local px, py, qx, qy = p[2 * i - 1], p[2 * i], p[2 * j - 1], p[2 * j]
			local dp, dq = a * px + b * py - c, a * qx + b * qy - c
			if dp <= 0 then
				o[#o + 1], o[#o + 2] = px, py
			end
			if (dp < 0 and dq > 0) or (dp > 0 and dq < 0) then
				local t = dp / (dp - dq)
				o[#o + 1], o[#o + 2] = px + (qx - px) * t, py + (qy - py) * t
			end
		end
		return o
	end
	local function solid(p)
		local s, k = 0, #p / 2
		for i = 1, k do
			local j = i % k + 1
			s = s + p[2 * i - 1] * p[2 * j] - p[2 * j - 1] * p[2 * i]
		end
		return k >= 3 and math.abs(s) > 1e-9
	end
	-- [KIT_POLYGON_POINTS] A simple polygon {x1, y1...} as convex pieces in slabs
	-- along (mx, my) (u = mx * x + my * y), a slab between each two of its points'
	-- u: in each, the edges through it bottom to top along (ux, uy), each two
	-- bounding a piece. A band's sides are two of those u, so it cuts only the
	-- pieces under it: ear clipping's long slivers under a skyline were cut by
	-- every band they passed (512 points: some 64000 triangles a face, a second's
	-- build)
	local function slabs(pts, mx, my, ux, uy)
		local k, us, u, seen = #pts / 2, {}, {}, {}
		for i = 1, k do
			u[i] = mx * pts[2 * i - 1] + my * pts[2 * i]
			if not seen[u[i]] then
				seen[u[i]] = true
				us[#us + 1] = u[i]
			end
		end
		table.sort(us)
		local out = {}
		for s = 1, #us - 1 do
			local u0, u1 = us[s], us[s + 1]
			local um = (u0 + u1) / 2
			local cr = {}
			for i = 1, k do
				local j = i % k + 1
				if (u[i] < um) ~= (u[j] < um) then
					local ax, ay, bx, by = pts[2 * i - 1], pts[2 * i], pts[2 * j - 1], pts[2 * j]
					local t0, t1 = (u0 - u[i]) / (u[j] - u[i]), (u1 - u[i]) / (u[j] - u[i])
					local tm = (t0 + t1) / 2
					cr[#cr + 1] = {ax + (bx - ax) * t0, ay + (by - ay) * t0,
						ax + (bx - ax) * t1, ay + (by - ay) * t1,
						h = ux * (ax + (bx - ax) * tm) + uy * (ay + (by - ay) * tm)}
				end
			end
			table.sort(cr, function(a, b) return a.h < b.h end)
			for c = 1, #cr - 1, 2 do
				local a, b = cr[c], cr[c + 1]
				local p = {a[1], a[2], a[3], a[4], b[3], b[4], b[1], b[2]}
				-- (two edges meeting at a point: a triangle)
				if p[5] == p[3] and p[6] == p[4] then
					table.remove(p, 5)
					table.remove(p, 5)
				end
				if p[#p - 1] == p[1] and p[#p] == p[2] then
					p[#p], p[#p - 1] = nil, nil
				end
				out[#out + 1] = p
			end
		end
		return out
	end
	local function face_uv(x, y)
		return x, -y
	end
	local function level_uv(x, y, z)
		return x, -z
	end
	local function upright_uv(x, y, z)
		return z, -y
	end
	polygon_mesh = function(node, look, n, def, at, q)
		if not MV then
			local _, err, m = buildat.run_script_file("kit/move.lua")
			assert(type(m) == "table", "kit: move.lua: " .. tostring(err))
			MV = m
		end
		local pts = {}
		for _, p in ipairs(type(look.points) == "table" and look.points or {}) do
			pts[#pts + 1] = type(p) == "table" and tonumber(p[1]) or 0
			pts[#pts + 1] = type(p) == "table" and tonumber(p[2]) or 0
		end
		local d = math.max(0.02, math.min(64, tonumber(look.depth) or 1)) / 2
		n.poly = {pts = pts, d = d}
		local tiles, tint0, tech
		if def then
			tiles, tint0, tech = voxel_tiles(def)
		end
		-- Its own x, y, z to the world's (less whole cells) and the world's down in
		-- its x and y (its own -y while it stands upright)
		local W, down, faces_uv = nil, nil, face_uv
		if tiles then
			local ex, ey = q * magic.Vector3(1, 0, 0), q * magic.Vector3(0, 1, 0)
			local ez = q * magic.Vector3(0, 0, 1)
			if math.abs(ez.y) > 0.7 then
				faces_uv = level_uv
			end
			local fx, fy = at.x - math.floor(at.x), at.y - math.floor(at.y)
			local fz = at.z - math.floor(at.z)
			W = function(x, y, z)
				return ex.x * x + ey.x * y + ez.x * z + fx,
						ex.y * x + ey.y * y + ez.y * z + fy,
						ex.z * x + ey.z * y + ez.z * z + fz
			end
			local l = math.sqrt(ex.y * ex.y + ey.y * ey.y)
			down = l > 0.1 and {-ex.y / l, -ey.y / l} or {0, -1}
		end
		-- 1: the faces' (all of it untextured), 2: the top tile's
		-- (set_triangle_geometry's 12 numbers a vertex)
		local geo = {{}, {}}
		local function tri(g, p1, p2, p3, nr, uv)
			-- Wound so it faces its normal (voxel_mesh's)
			local e1x, e1y, e1z = p2[1] - p1[1], p2[2] - p1[2], p2[3] - p1[3]
			local e2x, e2y, e2z = p3[1] - p1[1], p3[2] - p1[2], p3[3] - p1[3]
			if (e1y * e2z - e1z * e2y) * nr[1] + (e1z * e2x - e1x * e2z) * nr[2] +
					(e1x * e2y - e1y * e2x) * nr[3] < 0 then
				p2, p3 = p3, p2
			end
			local list = geo[g]
			for _, p in ipairs({p1, p2, p3}) do
				local u, v = 0, 0
				if W then
					u, v = uv(W(p[1], p[2], p[3]))
				end
				local o = #list
				list[o + 1], list[o + 2], list[o + 3] = p[1], p[2], p[3]
				list[o + 4], list[o + 5], list[o + 6] = nr[1], nr[2], nr[3]
				list[o + 7], list[o + 8], list[o + 9], list[o + 10] = 1, 1, 1, 1
				list[o + 11], list[o + 12] = u, v
			end
		end
		-- The sides, each its edge's normal out (counter-clockwise: to the right);
		-- each edge facing up its band: four sides a * x + b * y <= c (between the
		-- lines down through its ends, under it and over it pushed down by D) and
		-- its box
		local D = math.max(0, math.min(4, tonumber(look.edge_depth) or 0.25))
		local k, area = #pts / 2, 0
		for i = 1, k do
			local j = i % k + 1
			area = area + pts[2 * i - 1] * pts[2 * j] - pts[2 * j - 1] * pts[2 * i]
		end
		local sg = area > 0 and 1 or -1
		local bands = {}
		for i = 1, k do
			local j = i % k + 1
			local ax, ay, bx, by = pts[2 * i - 1], pts[2 * i], pts[2 * j - 1], pts[2 * j]
			local ex, ey = bx - ax, by - ay
			local l = math.sqrt(ex * ex + ey * ey)
			if l > 0 then
				local nr = {sg * ey / l, -sg * ex / l, 0}
				local nd = down and nr[1] * down[1] + nr[2] * down[2] or 0
				local up = nd <= -0.5
				local uv = nil
				if W then
					local wax, way = W(ax, ay, 0)
					local wbx, wby = W(bx, by, 0)
					uv = math.abs(wbx - wax) >= math.abs(wby - way) and level_uv or
							upright_uv
				end
				local g = up and 2 or 1
				tri(g, {ax, ay, -d}, {bx, by, -d}, {bx, by, d}, nr, uv)
				tri(g, {ax, ay, -d}, {bx, by, d}, {ax, ay, d}, nr, uv)
				if up and D > 0 then
					local mx, my = -down[2], down[1]
					local ma, mb = mx * ax + my * ay, mx * bx + my * by
					local na = nr[1] * ax + nr[2] * ay
					local cx, cy = down[1] * D, down[2] * D
					bands[#bands + 1] = {{mx, my, math.max(ma, mb)},
						{-mx, -my, -math.min(ma, mb)}, {nr[1], nr[2], na},
						{-nr[1], -nr[2], -(na + D * nd)},
						x0 = math.min(ax, bx, ax + cx, bx + cx),
						x1 = math.max(ax, bx, ax + cx, bx + cx),
						y0 = math.min(ay, by, ay + cy, by + cy),
						y1 = math.max(ay, by, ay + cy, by + cy)}
				end
			end
		end
		-- The faces: the triangles less the bands, the bands' parts in them
		-- ([KIT_POLYGON_POINTS] with bands: in slabs along down's normal)
		local pieces, band = {}, {}
		if bands[1] then
			pieces = slabs(pts, -down[2], down[1], -down[1], -down[2])
		else
			local tris = MV.triangulate(pts)
			for t = 1, #tris - 2, 3 do
				local a, b, c = tris[t], tris[t + 1], tris[t + 2]
				pieces[#pieces + 1] = {pts[2 * a - 1], pts[2 * a], pts[2 * b - 1],
					pts[2 * b], pts[2 * c - 1], pts[2 * c]}
			end
		end
		for _, h in ipairs(bands) do
			local rest = {}
			for _, p in ipairs(pieces) do
				if not p.x0 then
					p.x0, p.y0, p.x1, p.y1 = math.huge, math.huge, -math.huge, -math.huge
					for v = 1, #p, 2 do
						p.x0, p.x1 = math.min(p.x0, p[v]), math.max(p.x1, p[v])
						p.y0, p.y1 = math.min(p.y0, p[v + 1]), math.max(p.y1, p[v + 1])
					end
				end
				if p.x1 <= h.x0 or p.x0 >= h.x1 or p.y1 <= h.y0 or p.y0 >= h.y1 then
					rest[#rest + 1] = p
				else
					local inside = p
					for s = 1, 4 do
						local out = cut(inside, -h[s][1], -h[s][2], -h[s][3])
						if solid(out) then
							rest[#rest + 1] = out
						end
						inside = cut(inside, h[s][1], h[s][2], h[s][3])
					end
					if solid(inside) then
						band[#band + 1] = inside
					end
				end
			end
			pieces = rest
		end
		local band_tris, face_tris = 0, 0
		for g, list in ipairs({pieces, band}) do
			for _, p in ipairs(list) do
				for v = 3, #p / 2 do
					for _, z in ipairs({-d, d}) do
						tri(g, {p[1], p[2], z}, {p[2 * v - 3], p[2 * v - 2], z},
								{p[2 * v - 1], p[2 * v], z}, {0, 0, z < 0 and -1 or 1},
								faces_uv)
					end
					band_tris = band_tris + (g == 2 and 1 or 0)
					face_tris = face_tris + 1
				end
			end
		end
		-- [KIT_STILL_LOOKS] The geometries' vertices handed over in one call:
		-- defined a vertex a call, Brimstone Speedway's 270 polygons were most
		-- of a join's two seconds (2026-11-19)
		local used, lists = {}, {}
		for g = 1, 2 do
			if geo[g][1] then
				used[#used + 1], lists[#lists + 1] = g, geo[g]
			end
		end
		buildat.set_triangle_geometry(node, lists)
		local cg = node:GetComponent("CustomGeometry")
		cg.castShadows = true
		-- ([KIT_ENT_PERF_2] merge.lua's parts: an untextured one's material the
		-- look's own, its colour's, draw_look's)
		local parts = {}
		for i, l in ipairs(lists) do
			parts[i] = {list = l}
		end
		if tiles then
			local function tile(i)
				return tiles[i] or tiles[6] or select(2, next(tiles))
			end
			local top = tile(1)
			local face = tiles[2] and tiles[2].name ~= top.name and tiles[2] or tile(6)
			local glass = look.material == "glass"
			-- Glow keeps a translucent type's blend and a cut out one's cut
			local glow = def.translucent and "kit/KitVoxelLookGlowAlpha.xml" or
					def.alpha_masked and "kit/KitVoxelLookGlowMasked.xml" or
					"kit/KitVoxelLookGlow.xml"
			for i, g in ipairs(used) do
				local m = magic.Material:new()
				m:SetTechnique(0, look_technique(
						look.material == "glow" and glow or
						glass and (def.translucent or def.alpha_masked) and
						"kit/KitVoxelLookAlpha.xml" or
						glass and "kit/KitVoxelLookGlass.xml" or tech))
				m:SetTexture(magic.TU_DIFFUSE, (g == 2 and top or face).t)
				m:SetShaderParameter("MatDiffColor", glass and
						magic.Color(tint0.r, tint0.g, tint0.b, 0.4) or tint0)
				m:SetShaderParameter("MatSpecColor", look.material == "metal" and
						magic.Color(0.6, 0.6, 0.6, 30) or magic.Color(0.05, 0.05, 0.05))
				cg:SetMaterial(i - 1, m)
				parts[i].mat = m
				parts[i].key = string.format("p|%s|%s|%s|%s|%.4f,%.4f,%.4f", tech,
						(g == 2 and top or face).name, tostring(look.material),
						tostring(M.physical and M.physical()), tint0.r, tint0.g, tint0.b)
			end
		end
		return cg, face_tris, tiles ~= nil, band_tris, parts
	end
end

-- The look drawn as its state has it: built the first time, changed as the
-- state changes
local function draw_look(id, n, look)
	local on = false
	if look.state then
		on = value(n, look.state) == true
	end
	if n.look and n.on == on then
		return
	end
	if look.state then
		log:info("kit: entity " .. id .. "'s look: " .. tostring(look.state) ..
				(on and " on" or " off"))
	end
	-- [KIT_COLLECTIBLE] when.vanish "fly": turned on from off as drawn (not
	-- a look built anew), the body shrinks, turns and rises first (below)
	local vanish = on and n.look and n.drawn_on == false and
			type(look.when) == "table" and look.when.vanish == "fly"
	n.drawn_on = on
	n.on = on
	local b = look_box(look, on)
	n.box = b
	if not n.look then
		local scene = replicate.main_scene
		n.look = scene:CreateChild("kit_look")
		n.hinge = n.look:CreateChild("Hinge")
		n.body = n.hinge:CreateChild("Body")
		n.mat = material(look.material)
		-- [KIT_LOOK_MATERIAL] A box or a wedge wearing a voxel material:
		-- its sides the shut look's ([KIT_SIDE_SCENERY] a polygon's
		-- polygon_mesh's)
		local wants = look.shape ~= "sphere" and type(look.voxel) ==
				"string" and look.voxel ~= "" and look.voxel or nil
		local def = wants and voxel_def(wants)
		local worn = nil
		if look.shape == "polygon" then
			-- [KIT_SIDE_SCENERY] textured where its node is (at rest, a moving
			-- object's): built again when that changes (update_play)
			local r = n.rest
			local at = r and magic.Vector3(r[1], r[2], r[3]) or n.node.position
			local q = r and magic.Quaternion(r[4], r[5], r[6], r[7]) or
					n.node.rotation
			local cg, nt, tex, bt, parts = polygon_mesh(n.body, look, n, def, at, q)
			if not tex then
				cg:SetMaterial(0, n.mat)
				parts[1].body_col = true
			end
			n.mesh = parts
			worn = tex
			n.poly.tris, n.poly.band = nt, tex and bt or nil
			n.poly.at = tex and {at.x, at.y, at.z, q.w, q.x, q.y, q.z} or nil
		elseif def then
			local cg, _, parts = voxel_mesh(n.body, def, look_box(look, false).size,
					look.shape)
			worn, n.mesh = cg, parts
		end
		if wants then
			log:info("kit: entity " .. id .. (worn and " wears " or
					" wears no ") .. wants)
		end
		n.worn = worn
		-- Not in the registry yet: drawn again once it is
		n.wear_wanted = wants and not def and wants or nil
		-- ([KIT_ENT_PERF_2] n.mesh: its triangles in the body's frame for
		-- merge.lua, each part {list, mat, key} or body_col/edge_col: the look's
		-- own material, of its colour. simplified: a sphere's none: never merged)
		if worn or n.poly then
			-- (drawn)
		elseif look.shape == "wedge" then
			local cg = wedge(n.body)
			cg:SetMaterial(0, n.mat)
			-- ([KIT_ENT_PERF_2] as a box: merged, the two are one geometry)
			cg.castShadows = true
			n.mesh = {{list = WEDGE, body_col = true}}
		else
			local m = n.body:CreateComponent("StaticModel")
			m.model = magic.cache:GetResource("Model", "Models/" ..
					(look.shape == "sphere" and "Sphere" or "Box") .. ".mdl")
			m.material = n.mat
			m.castShadows = true
			n.mesh = look.shape ~= "sphere" and {{list = BOX, body_col = true}} or nil
		end
		-- [KIT_COLLECTIBLE] edge = "#rrggbb": a box's twelve edges as boards
		-- of that colour (a crate's frame), in the body, so a when's scale
		-- and a vanish take them along. simplified: a box's alone, each
		-- board an eighth of its shortest side wide, standing out a quarter
		-- of that; a width field is the upgrade
		if type(look.edge) == "string" and look.edge ~= "" and
				(look.shape == nil or look.shape == "box") then
			local s = look_box(look, false).size
			local w = math.min(s[1], s[2], s[3]) / 8
			local out = w / 4
			n.edge_mat = material(look.material)
			local el = {}
			if n.mesh then
				n.mesh[#n.mesh + 1] = {list = el, edge_col = true}
			end
			for axis = 1, 3 do
				for _, q in ipairs({{-1, -1}, {-1, 1}, {1, -1}, {1, 1}}) do
					local pos, sc, k = {0, 0, 0}, {}, 0
					for i = 1, 3 do
						if i == axis then
							sc[i] = 1 + 2 * out / s[i]
						else
							k = k + 1
							pos[i] = q[k] * (0.5 - (w / 2 - out) / s[i])
							sc[i] = w / s[i]
						end
					end
					local e = n.body:CreateChild("Edge")
					e.position = v3(pos)
					e.scale = v3(sc)
					-- (in the body's frame: a box's normals stay its axes)
					for o = 0, #BOX - 1, 12 do
						for k = 1, 3 do
							el[#el + 1] = pos[k] + sc[k] * BOX[o + k]
						end
						for k = 4, 12 do
							el[#el + 1] = BOX[o + k]
						end
					end
					local m = e:CreateComponent("StaticModel")
					m.model = magic.cache:GetResource("Model", "Models/Box.mdl")
					m.material = n.edge_mat
					m.castShadows = true
				end
			end
		end
		if look.text then
			-- [KIT] stage 4l: text_facing "flat" (on the box's front, its -z
			-- side, as the entity faces) or "camera" (turning round y),
			-- text_size cells high, text_color; none: over it, a label of a
			-- fixed size on the screen
			local facing = look.text_facing
			if facing ~= "flat" and facing ~= "camera" then
				facing = nil
			end
			-- In the hinge, so it goes with a slide ([KIT] stage 4l)
			local function text3d(name)
				local l = n.hinge:CreateChild(name)
				local t = l:CreateComponent("Text3D")
				t:SetFont(magic.cache:GetResource("Font", buildat.font_sans),
						facing and 48 or 16)
				t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
				t:SetTextAlignment(magic.HA_CENTER)
				t.faceCameraMode = facing == "flat" and magic.FC_NONE or
						facing == "camera" and magic.FC_ROTATE_Y or
						magic.FC_ROTATE_XYZ
				t.fixedScreenSize = not facing
				if facing ~= "flat" then
					t.textEffect = magic.TE_STROKE
					t.effectColor = magic.Color(0, 0, 0, 0.8)
				end
				if type(look.text_color) == "string" then
					t:SetColor(color(look.text_color, magic.Color(1, 1, 1)))
				end
				-- [KIT_LIGHTING_SCENE] Under physical after the exposure and
				-- the tonemap (environment.lua's lit_path): as UI text, the
				-- same in sun, shade and dusk. In the frame's radiance it was
				-- metered down to near black against a sunlit board
				if M.physical and M.physical() then
					local m = magic.Material:new()
					m:SetTechnique(0, magic.cache:GetResource("Technique",
							"kit/KitText.xml"))
					m.cullMode = magic.CULL_NONE
					t.material = m
				end
				return l, t
			end
			local l, t = text3d("Text")
			-- [KIT_AGENT_FEEDBACK_1117] text_back: flat text on the back too
			-- (+z), turned round so it reads from there (kit/sign's both_sides)
			if facing == "flat" and look.text_back == true then
				n.text_back_node, n.text_back = text3d("TextBack")
				n.text_back_node.rotation = magic.Quaternion(0, 180, 0)
			end
			n.text = t
			n.text_node = l
			n.text_facing = facing
			n.text_size = math.max(0.02, math.min(8,
					tonumber(look.text_size) or 0.25))
		end
		local r = type(look.rotation) == "table" and look.rotation or {}
		n.look_rot = magic.Quaternion(tonumber(r[1]) or 0,
				tonumber(r[2]) or 0, tonumber(r[3]) or 0)
		local lr = n.look_rot
		n.look_rq = {lr.w, lr.x, lr.y, lr.z}
		n.at, n.at_q = nil, nil
	end
	-- A swing turns the body round its hinge: the middle of its thickness
	-- at its -x end, so the turned box is look_box's
	if n.poly then
		-- ([KIT_PLANE] stage 3: a polygon's mesh is in its own frame, b the box round;
		-- [KIT_CLIENT_REACT] (6) its `when` scale about its own point, its offset
		-- the slide's below)
		local sc = on and type(look.when) == "table" and type(look.when.scale) ==
				"table" and look.when.scale or {}
		n.body.position = magic.Vector3(0, 0, 0)
		n.body.scale = magic.Vector3(tonumber(sc[1]) or 1, tonumber(sc[2]) or 1,
				tonumber(sc[3]) or 1)
	elseif type(look.when) == "table" and look.when.swing then
		local c = look_box(look, false)
		local px = c.off[1] - c.size[1] / 2 + c.size[3] / 2
		n.hinge.position = magic.Vector3(px, 0, c.off[3])
		-- [KIT_DOOR_MIRROR] Open: -90, or 90 mirrored (the client part's
		-- e.swing)
		n.swing = look.when.mirror == true and 90 or -90
		n.hinge.rotation = magic.Quaternion(0, on and n.swing or 0, 0)
		n.body.position = magic.Vector3(c.off[1] - px, c.off[2], 0)
		n.body.scale = v3(c.size)
	else
		n.body.position = v3(b.off)
		n.body.scale = v3(b.size)
	end
	n.vanish = nil
	if vanish and not n.poly and not look.when.swing then
		n.vanish = {t = 0, from = look_box(look, false)}
		n.body.position = v3(n.vanish.from.off)
		n.body.scale = v3(n.vanish.from.size)
	end
	local col = color(b.color, magic.Color(0.8, 0.8, 0.8))
	-- [KIT_LIGHTING_SCENE] Under physical decoded to linear, as a voxel's
	-- albedo (look_technique); a glow's drawn unlit, as given
	if M.physical and M.physical() and look.material ~= "glow" then
		col = magic.Color(col.r ^ 2.2, col.g ^ 2.2, col.b ^ 2.2, col.a)
	end
	if look.material == "glass" then
		col = magic.Color(col.r, col.g, col.b, 0.4)
	end
	n.mat:SetShaderParameter("MatDiffColor", col)
	-- ([KIT_ENT_PERF_2] the look's own materials' keys for merge.lua: what
	-- makes them, its colour now)
	local mk = string.format("m|%s|%.4f,%.4f,%.4f,%.4f", tostring(look.material),
			col.r, col.g, col.b, col.a)
	local ek = mk
	if n.edge_mat then
		local ec = color(look.edge, magic.Color(0.3, 0.2, 0.1))
		if M.physical and M.physical() and look.material ~= "glow" then
			ec = magic.Color(ec.r ^ 2.2, ec.g ^ 2.2, ec.b ^ 2.2, ec.a)
		end
		n.edge_mat:SetShaderParameter("MatDiffColor", ec)
		ek = string.format("m|%s|%.4f,%.4f,%.4f,%.4f", tostring(look.material),
				ec.r, ec.g, ec.b, ec.a)
	end
	for _, p in ipairs(n.mesh or {}) do
		if p.body_col then
			p.mat, p.key = n.mat, mk
		elseif p.edge_col then
			p.mat, p.key = n.edge_mat, ek
		end
	end
	-- [KIT_LOOK_MATERIAL] (a voxel material is its own colours: col is
	-- unused there)
	-- [KIT] stage 4l: color "none", no box drawn (a sign's letters alone)
	n.body.enabled = b.color ~= "none"
	if n.text_node then
		if n.text_facing then
			-- Just in front of the box's front
			n.text_node.position = magic.Vector3(b.off[1], b.off[2],
					b.off[3] - b.size[3] / 2 - 0.01)
			n.board_w, n.board_h = b.size[1], b.size[2]
			if n.text_back_node then
				n.text_back_node.position = magic.Vector3(b.off[1], b.off[2],
						b.off[3] + b.size[3] / 2 + 0.01)
			end
		else
			n.text_node.position = magic.Vector3(b.off[1], b.off[2] +
					b.size[2] / 2 + 0.45, b.off[3])
		end
	end
	-- [KIT] stage 4l: when.offset, the look moved by it while its state is
	-- on; over when.slide seconds (kit/mover), else at once
	local w = type(look.when) == "table" and look.when or {}
	local wo = type(w.offset) == "table" and w.offset or nil
	if wo then
		local full = magic.Vector3(tonumber(wo[1]) or 0, tonumber(wo[2]) or 0,
				tonumber(wo[3]) or 0)
		n.slide_to = on and full or magic.Vector3(0, 0, 0)
		local secs = tonumber(w.slide) or 0
		n.slide_speed = secs > 0 and full:Length() / secs or nil
		if not n.slide_at or not n.slide_speed then
			n.slide_at = n.slide_to
		end
		n.hinge.position = n.slide_at
		if n.solid then
			n.solid.position = n.slide_at
		end
	else
		n.slide_to, n.slide_at = nil, nil
	end
	-- Solid: a static body (no mass) the players' bodies meet; a wedge's
	-- its slope and its back, thin
	if n.solid then
		n.solid:Remove()
		n.solid = nil
	end
	-- (a polygon's collision is move.lua's prism)
	if b.solid and not n.poly then
		n.solid = n.look:CreateChild("Solid")
		local function box(pos, size, rot)
			local s = n.solid:CreateChild("Box")
			s.position = pos
			if rot then
				s.rotation = rot
			end
			s:CreateComponent("RigidBody")
			s:CreateComponent("CollisionShape"):SetBox(size)
		end
		if look.shape == "wedge" then
			local sy, sz = b.size[2], b.size[3]
			box(v3(b.off), magic.Vector3(b.size[1], 0.1,
					math.sqrt(sy * sy + sz * sz)), magic.Quaternion(
					-math.deg(math.atan2(sy, sz)), 0, 0))
			box(magic.Vector3(b.off[1], b.off[2], b.off[3] + sz / 2 - 0.05),
					magic.Vector3(b.size[1], sy, 0.1))
		else
			box(v3(b.off), v3(b.size))
		end
	end
	if n.solid and n.slide_at then
		n.solid.position = n.slide_at
	end
	cull(n)
	log:info(string.format("kit: entity %d drawn %gx%gx%g at %g,%g,%g%s", id,
			b.size[1], b.size[2], b.size[3], b.off[1], b.off[2], b.off[3],
			b.solid and ", solid" or "") ..
			(look.shape == "wedge" and ", a wedge" or "") ..
			(n.poly and ", a polygon of " .. #n.poly.pts / 2 .. " points, " ..
			tostring(n.poly.tris) .. " triangles" or "") ..
			(n.poly and n.poly.band and ", textured, " .. n.poly.band ..
			" triangles in its top band" or ""))
end

-- [KIT_OWN_LOOK] A look hidden in play (its type's own_look off): not
-- drawn there (its text neither; its collision kept); in edit mode a
-- faded box of its size in its place. simplified: a box (a sphere's a
-- sphere) whatever its shape or worn material
-- [KIT_SHIP_VIEW] Also faded where a seated player's line of sight
-- crosses it on the craft ridden (n.see_through, controls.lua's)
local function own_look(id, n, look)
	local hidden = look.hidden == true
	local seen = n.see_through == true and not hidden
	if not hidden and not seen and not n.ghost then
		return
	end
	local ghost = hidden and E.editing or seen
	local key = tostring(hidden) .. tostring(ghost)
	if key ~= n.hidden then
		n.hidden = key
		log:info("kit: entity " .. id .. (seen and " drawn faded (in the view)" or
				not hidden and " shown" or ghost and " drawn faded (own look off)" or
				" not drawn (own look off)"))
	end
	n.body.enabled = not hidden and not seen and n.box.color ~= "none"
	if n.text then
		n.text_node.enabled = not hidden or ghost
		if n.text_back_node then
			n.text_back_node.enabled = n.text_node.enabled
		end
	end
	if ghost and not n.ghost then
		n.ghost = n.hinge:CreateChild("Ghost")
		local m = n.ghost:CreateComponent("StaticModel")
		m.model = magic.cache:GetResource("Model", "Models/" ..
				(look.shape == "sphere" and "Sphere" or "Box") .. ".mdl")
		m.material = material("glass")
		n.ghost_mat = m.material
	end
	local a = seen and 0.2 or 0.45
	if n.ghost and ghost and n.ghost_alpha ~= a then
		n.ghost_alpha = a
		local c = color(n.box.color, magic.Color(0.8, 0.8, 0.8))
		n.ghost_mat:SetShaderParameter("MatDiffColor", magic.Color(c.r, c.g, c.b, a))
	end
	if n.ghost then
		n.ghost.enabled = ghost
		n.ghost.position = v3(n.box.off)
		n.ghost.scale = v3(n.box.size)
	end
end

-- The entity as its client parts have it
local function entity_view(id, n)
	-- ([KIT_UI_CLIENT_PART] e.ui: ui.lua's M.ui_api)
	local e = {id = id, node = n.node, state = {}, params = {},
		ui = M.ui_api and M.ui_api(id, n)}
	function e:shown(key)
		return value(n, key)
	end
	function e:predict(key, v, seconds)
		key = tostring(key)
		n.predicted = n.predicted or {}
		n.predicted[key] = {value = v, was = shown(parse(n.node:GetVar("kit:" ..
				key))), till = buildat.get_time_us() + (tonumber(seconds) or 1) *
				1000000}
		n.on = nil
		log:info("kit: entity " .. id .. " predicted " .. key .. " = " ..
				shown(v))
	end
	function e:log(text)
		log:info("kit: entity " .. id .. "'s client part: " .. tostring(text))
	end
	-- Whether this player's own entity is within d of it
	function e:near(d)
		local me = P.nodes[P.you]
		return me ~= nil and (me.node.position - n.node.position):Length() <=
				(tonumber(d) or 0)
	end
	return e
end

-- A preview's or a pose's turn (a vehicle's: its yaw)
local function pv_q(v)
	return v.q or magic.Quaternion(0, v[4], 0)
end
local function same_q(a, b)
	return math.abs(a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z) > 1 - 1e-6
end
-- ([KIT_ENT_PERF] a node's turn written through one Quaternion kept for it, its
-- numbers set: a new one is ~8 us in the sandbox)
local TURN = magic.Quaternion(1, 0, 0, 0)
local function set_turn(node, w, x, y, z)
	TURN.w, TURN.x, TURN.y, TURN.z = w, x, y, z
	node.rotation = TURN
end

-- [KIT_NESTING] The way an entity's looks are carried by those it is
-- under ("kit_parent", the entity it is under) as their looks slide
-- (kit/mover): its node is where the slide ends (the server's), the look
-- where the parent's is on the way
-- ([KIT_ENT_PERF] the numbers dx, dy, dz; a node's kit_parent read again only
-- once the server has changed it, n.vgen: a GetVar is ~5 us)
local function parent_id(n)
	if n.pid_gen ~= n.vgen or not n.pid then
		n.pid, n.pid_gen = n.node:GetVar("kit_parent"):GetInt(), n.vgen
	end
	return n.pid
end
local function carried(n)
	local d = nil
	local pid = parent_id(n)
	for _ = 1, 16 do
		local pn = pid ~= 0 and P.nodes[pid]
		if not pn then
			break
		end
		if pn.slide_at and pn.slide_to and pn.look then
			d = (d or magic.Vector3(0, 0, 0)) + pn.look.rotation * (pn.slide_at - pn.slide_to)
		end
		pid = parent_id(pn)
	end
	if not d then
		return 0, 0, 0
	end
	return d.x, d.y, d.z
end

-- [KIT_SIDE_SCENERY] (8) The kit/parallax layer an entity is under: the
-- nearest up its kit_parent whose show has `parallax` ({follow, follow_y,
-- repeat}), its P.nodes entry; nil: none. Remembered across frames
-- (controls.lua's world() asks for every node each step; [KIT_STUNTS_PERF]
-- read each frame it was ~8 ms of Stunts' frame): forgotten as a node comes
-- or goes, a remembered one's kit_parent changes (n.par_pid, read again once
-- the server changes the node) or a show turns a layer or stops being one;
-- each frame on a client without replicate.take_changed
local par_memo, par_any, par_gen = {}, false, nil
function M.parallax_layer(id, n)
	if not par_any then
		return nil
	end
	if par_gen ~= P.nodes_gen then
		par_memo, par_gen = {}, P.nodes_gen
	end
	if par_memo[id] ~= nil then
		return par_memo[id] or nil
	end
	local chain, found = {id}, false
	for _ = 1, 16 do
		local pv = n.node:GetVar("kit_parent")
		local pid = pv:IsEmpty() and 0 or pv:GetInt()
		n.par_pid = pid
		local p = pid ~= 0 and P.nodes[pid]
		if not p then
			break
		end
		if type(p.show) == "table" and type(p.show.parallax) == "table" then
			found = p
			break
		end
		if par_memo[pid] ~= nil then
			found = par_memo[pid]
			break
		end
		chain[#chain + 1] = pid
		n = p
	end
	for _, c in ipairs(chain) do
		par_memo[c] = found
	end
	return found or nil
end

local hud = nil
-- [KIT_STILL_LOOKS] A look that has stood still CALM frames in play, with
-- nothing else on it that changes by the frame (no text, HUD line, client
-- part with on_update, pending prediction, slide, attachment, preview,
-- pose, moving links; its parent not sliding), is read again only once
-- the server updates its node
-- (replicate.take_changed(): its attributes or vars came), in play and in
-- edit mode: a node's place, turn and show are dear reads through the
-- sandbox, and a track of 250 polygons read each frame was some 18 ms of
-- the frame in play (Brimstone Speedway's, 2026-11-18), 25 of the editor's
-- 150 on llvmpipe (2026-11-19). n.gen counts what changed in its place,
-- turn or show (controls.lua's world() keeps what it made of it till
-- then); n.still: skipped this frame. A client without take_changed reads
-- a still one each 16th frame, staggered by its id (drawn so up to 16
-- frames late), and every look each frame in edit mode. (0a7h) A look's
-- state: the server's kit:<key> marks its node; this player's own (ui.lua's
-- kit:mine) sets n.calm = 0; a prediction keeps it read till confirmed or
-- its time is up. A client part's on_add, on_state, on_enter, on_leave and
-- on_use come without the frame's read. Anything else that changes how a
-- look is drawn from outside its entity's node must set n.calm = 0 too, or
-- a still look never shows it
local CALM, frame_no = 8, 0
-- [KIT_COLLECTIBLE] A look's when.vanish: seconds, metres risen
local VANISH_TIME, VANISH_RISE = 0.35, 0.8
local changed = {}
-- (for "event kit_looks": what the frames since the last ask read and cost)
local LK = {frames = 0, read = 0, looks = 0, us = 0}
local function still(id, n)
	if not n.look or (n.calm or 0) < CALM then
		return false
	end
	if replicate.take_changed then
		if changed[n.nid] then
			return false
		end
	elseif E.editing or (frame_no + id) % 16 == 0 then
		return false
	end
	-- (one past its time dropped here: its look drawn again this frame)
	if n.predicted and next(n.predicted) then
		local now = buildat.get_time_us()
		for k, p in pairs(n.predicted) do
			if now >= p.till then
				n.predicted[k] = nil
			end
		end
		return false
	end
	local show = n.show
	local look = show.look
	-- (a part not here yet, or its on_add not run: read till it has)
	for _, t in ipairs(type(show.client) == "table" and show.client or {}) do
		local part = P.parts[t]
		if not (part and n.added) or part.on_update then
			return false
		end
	end
	local pn = n.pid and n.pid ~= 0 and P.nodes[n.pid]
	-- ([KIT_ENT_PERF] a moving one is still while parked: its links have not
	-- moved it this frame, controls.lua's place_moving)
	local moving = n.rest and not (n.parked and n.moved == P.moved_frame)
	return not (n.text or show.hud ~= nil or look.hidden or moving or n.vanish or
			n.slide_to or n.wear_wanted or n.ghost or n.see_through or
			n.attach_to or P.preview[id] or P.pose[id] or (pn and pn.slide_to))
end
-- [KIT_ENT_PERF_2] (kit_plan 4z37zzm) A client part with skip_offscreen = true
-- (a field of its table, api.h): its on_update not called while its entity
-- is out of the play camera's view (its look's box round its place, a metre
-- spare) or past the looks' reach (M.look_reach); in edit mode or with no
-- camera, called as ever. Its other handlers are called as ever.
-- simplified: the camera of the frame before (controls.lua places it after)
local VW = {frame = -1}
local function offscreen(n)
	if VW.frame ~= frame_no then
		VW.frame, VW.ok = frame_no, false
		local cn = not E.editing and O.camera
		local cam = cn and cn:GetComponent("Camera")
		if cam then
			local m = cn.worldTransform
			VW.m = {m.m00, m.m01, m.m02, m.m03, m.m10, m.m11, m.m12, m.m13, m.m20,
				m.m21, m.m22, m.m23}
			local zoom = math.max(1e-3, cam.zoom)
			local a = cam.aspectRatio
			a = (a and a > 0.1) and a or 2
			VW.ortho = cam.orthographic
			if VW.ortho then
				VW.hy = cam.orthoSize / 2 / zoom
				VW.hx = VW.hy * a
			else
				VW.ty = math.tan(math.rad(cam.fov) / 2) / zoom
				VW.tx = VW.ty * a
			end
			VW.far = math.min(cam.farClip, M.look_reach or math.huge)
			VW.ok = true
		end
	end
	if not VW.ok then
		return false
	end
	local p = n.at
	if not p then
		local np = n.node.position
		p = {x = np.x, y = np.y, z = np.z}
	end
	local s = n.box and n.box.size or {0, 0, 0}
	local r = math.sqrt(s[1] * s[1] + s[2] * s[2] + s[3] * s[3]) / 2 + 1
	local m = VW.m
	local dx, dy, dz = p.x - m[4], p.y - m[8], p.z - m[12]
	local x = dx * m[1] + dy * m[5] + dz * m[9]
	local y = dx * m[2] + dy * m[6] + dz * m[10]
	local z = dx * m[3] + dy * m[7] + dz * m[11]
	if z < -r or z - r > VW.far then
		return true
	end
	if VW.ortho then
		return math.abs(x) > VW.hx + r or math.abs(y) > VW.hy + r
	end
	return math.abs(x) > z * VW.tx + r * math.sqrt(1 + VW.tx * VW.tx) or
			math.abs(y) > z * VW.ty + r * math.sqrt(1 + VW.ty * VW.ty)
end
local function update_play(_, data)
	local dt = data:GetFloat("TimeStep")
	local lines = {}
	local layers = false
	-- [KIT_MOVING_OBJECTS] what moves at this frame's time, before anything reads it
	-- ([KIT_3D_GAINS_1] (4z38) controls.lua's kit_frame and kit_parent kept, n.fp,
	-- till the server changes the node; each frame without take_changed)
	changed = replicate.take_changed and replicate.take_changed() or changed
	if not replicate.take_changed then
		par_memo = {}
	end
	-- ([KIT_STUNTS_PERF] the changed ones alone, not a walk of every node; n.vgen
	-- counted up: ui.lua's state() kept till then; P.changed: controls.lua's
	-- moving_tick)
	if replicate.take_changed then
		for nid in pairs(changed) do
			local n = P.nodes[P.by_nid[nid] or 0]
			if n then
				n.fp, n.vgen = nil, (n.vgen or 0) + 1
			end
		end
	else
		for _, n in pairs(P.nodes) do
			n.fp, n.vgen = nil, (n.vgen or 0) + 1
		end
	end
	P.changed = replicate.take_changed and changed or nil
	-- ([KIT_STUNTS_PERF] the parallax layers remembered: again once a
	-- remembered node's kit_parent changes)
	for nid in pairs(changed) do
		local n = P.nodes[P.by_nid[nid] or 0]
		if n and n.par_pid then
			local pv = n.node:GetVar("kit_parent")
			if (pv:IsEmpty() and 0 or pv:GetInt()) ~= n.par_pid then
				par_memo, n.par_pid = {}, nil
			end
		end
	end
	if M.moving_tick then
		M.moving_tick()
	end
	frame_no = frame_no + 1
	local busy = {}
	for id, n in pairs(P.nodes) do
		n.still = still(id, n)
		M.merge_seen(n, n.still)
		if n.still then
			layers = layers or type(n.show.parallax) == "table"
		else
			busy[id] = n
		end
		LK.read = LK.read + (n.look and not n.still and 1 or 0)
		LK.looks = LK.looks + (n.look and 1 or 0)
	end
	for id, n in pairs(busy) do
		local look_was, on_was, calm = n.look, n.on, true
		-- What it shows: again as an edit changes it ([KIT_3D_GAINS_1] (4z38) read
		-- only once the server has changed the node: a look-less node or one with
		-- a part's on_update is here each frame)
		local raw = n.show_raw
		if raw == nil or changed[n.nid] or not replicate.take_changed then
			raw = n.node:GetVar("kit_show")
			raw = raw:IsEmpty() and "" or raw:GetString()
		end
		if raw ~= n.show_raw then
			n.show_raw = raw
			local was_layer = type(n.show) == "table" and type(n.show.parallax) == "table"
			n.show = network.parse_json(raw)
			if was_layer ~= (type(n.show) == "table" and type(n.show.parallax) == "table") then
				par_memo = {}
			end
			drop_look(n)
			n.last_text = nil
			n.gen, calm = (n.gen or 0) + 1, false
		end
		local show = type(n.show) == "table" and n.show or {}
		layers = layers or type(show.parallax) == "table"
		if type(show.look) == "table" then
			-- [KIT_LOOK_MATERIAL] A voxel material not in the registry
			-- yet (a builder's new one, the registry still coming): drawn
			-- again once it is
			if n.look and n.wear_wanted and voxel_def(n.wear_wanted) then
				drop_look(n)
			end
			-- [KIT_SIDE_SCENERY] A textured polygon moved or turned (at rest):
			-- built again once it is still (a node's move is smoothed over some
			-- frames), its textures the world's where it is now
			local pa = n.look and n.poly and n.poly.at
			if pa then
				local r, p, q = n.rest, n.node.position, n.node.rotation
				local now = r and {r[1], r[2], r[3], r[4], r[5], r[6], r[7]} or
						{p.x, p.y, p.z, q.w, q.x, q.y, q.z}
				local moved, stirred, last = 0, 0, n.poly.last or now
				for i = 1, 7 do
					moved = moved + math.abs(now[i] - pa[i])
					stirred = stirred + math.abs(now[i] - last[i])
				end
				n.poly.last = now
				if moved > 1e-4 and stirred < 1e-6 then
					drop_look(n)
				end
			end
			draw_look(id, n, show.look)
			own_look(id, n, show.look)
			-- [KIT_COLLECTIBLE] A vanish under way: VANISH_TIME s of the body
			-- shrinking, turning half round and rising, then the look as on
			local v = n.vanish
			if v then
				v.t = v.t + dt
				local k = math.min(1, v.t / VANISH_TIME)
				local f, o = v.from.size, v.from.off
				local s = math.max(0.01, 1 - k)
				n.body.scale = magic.Vector3(f[1] * s, f[2] * s, f[3] * s)
				n.body.position = magic.Vector3(o[1], o[2] + VANISH_RISE *
						k * (2 - k), o[3])
				n.body.rotation = magic.Quaternion(0, 180 * k, 0)
				if k >= 1 then
					n.vanish = nil
					n.body.position, n.body.scale = v3(n.box.off), v3(n.box.size)
					n.body.rotation = magic.Quaternion(0, 0, 0)
					log:info("kit: entity " .. id .. " vanished")
				end
			end
			-- A slide under way ([KIT] stage 4l)
			if n.slide_to and n.slide_at and n.slide_speed and
					(n.slide_to - n.slide_at):Length() > 1e-5 then
				local d = n.slide_to - n.slide_at
				local step = n.slide_speed * dt
				if d:Length() <= step then
					n.slide_at = n.slide_to
					log:info("kit: entity " .. id .. " slid to " ..
							string.format("%g,%g,%g", n.slide_at.x,
							n.slide_at.y, n.slide_at.z))
				else
					n.slide_at = n.slide_at + d:Normalized() * step
				end
				n.hinge.position = n.slide_at
				if n.solid then
					n.solid.position = n.slide_at
				end
			end
		end
		-- Where it is, turned by its entity's turn ([KIT] stage 4e2) over its
		-- look's own, or where an editor's drag has it meanwhile
		-- ([KIT_ENT_PERF] in plain numbers: n.at {x, y, z} and n.at_q {w, x, y, z}
		-- tables, the look's place and turn written from them; one moving_tick
		-- moved this frame (n.moved) its numbers, not read back: placing a moving
		-- node was ~190 us of sandbox values a frame)
		if n.look then
			local x, y, z, qw, qx, qy, qz
			if n.moved and n.moved == P.moved_frame then
				x, y, z, qw, qx, qy, qz = n.sx, n.sy, n.sz, n.sw, n.sa, n.sb, n.sc
			else
				local p, nr = n.node.position, n.node.rotation
				x, y, z, qw, qx, qy, qz = p.x, p.y, p.z, nr.w, nr.x, nr.y, nr.z
			end
			local was = n.raw
			if not was or was[1] ~= x or was[2] ~= y or was[3] ~= z or was[4] ~= qw or
					was[5] ~= qx or was[6] ~= qy or was[7] ~= qz then
				n.raw, n.gen, calm = {x, y, z, qw, qx, qy, qz}, (n.gen or 0) + 1, false
			end
			local pv = P.preview[id]
			-- An editor's preview: where its drag has it, until the server's
			-- node is there (or its time is up)
			if pv and pv.till then
				local dx, dy, dz = x - pv[1], y - pv[2], z - pv[3]
				if buildat.get_time_us() > pv.till or (dx * dx + dy * dy + dz * dz < 1e-4 and
						same_q({w = qw, x = qx, y = qy, z = qz}, pv_q(pv))) then
					P.preview[id] = nil
					pv = nil
				end
			end
			-- A vehicle this client drives: where it predicts it
			-- (controls.lua, [KIT] stage 4h)
			pv = pv or P.pose[id]
			if pv then
				x, y, z = pv[1], pv[2], pv[3]
				local q = pv_q(pv)
				qw, qx, qy, qz = q.w, q.x, q.y, q.z
			else
				local dx, dy, dz = carried(n)
				x, y, z = x + dx, y + dy, z + dz
			end
			local at, aq = n.at, n.at_q
			local dx, dy, dz = at and x - at.x, at and y - at.y, at and z - at.z
			if not at or dx * dx + dy * dy + dz * dz > 1e-8 or
					math.abs(qw * aq.w + qx * aq.x + qy * aq.y + qz * aq.z) <= 1 - 1e-6 then
				n.at, n.at_q = {x = x, y = y, z = z}, {w = qw, x = qx, y = qy, z = qz}
				-- (as numbers, for the editor's pick: no sandbox reads)
				n.at_xyz = {x, y, z}
				n.look.position = n.at
				-- (its turn over the look's own, n.look_rq)
				local r = n.look_rq
				set_turn(n.look, qw * r[1] - qx * r[2] - qy * r[3] - qz * r[4],
						qw * r[2] + qx * r[1] + qy * r[4] - qz * r[3],
						qw * r[3] - qx * r[4] + qy * r[1] + qz * r[2],
						qw * r[4] + qx * r[3] - qy * r[2] + qz * r[1])
				calm = false
			end
		end
		if n.look ~= look_was or n.on ~= on_was then
			calm = false
		end
		n.calm = calm and (n.calm or 0) + 1 or 0
		M.merge_busy(n, calm)
		if n.text then
			-- [KIT_INPUT_ACTIONS] {key:use}: this player's key for it
			local v = shown(parse(n.node:GetVar("kit:" ..
					tostring(show.look.text))))
			-- [KIT_TEMPLATES] look.text_idle: drawn while the state has nothing,
			-- as while Stopped, when no on_start has written it
			if (v == nil or v == "") and show.look.text_idle then
				v = tostring(show.look.text_idle):gsub("{value}", ""):gsub("|", "\n")
			end
			v = M.key_text(v)
			if v ~= n.last_text then
				n.last_text = v
				n.text.text = v
				-- Its letters text_size high: the font's 48 pixels at 1/128
				-- of a cell each (Text3D's scaling)
				-- [KIT_SIGN_WRAP] wrapped to the board's width, a tenth
				-- spare, and made smaller while it is taller than the
				-- board, the width wrapped again at the size it is.
				-- simplified: down to 0.3 of its size; past that it
				-- overflows (a sign's text is a builder's to shorten)
				if n.text_facing then
					local px, k = n.text_size / 48, 1
					if (n.board_w or 0) > 0 and (n.board_h or 0) > 0 then
						n.text.wordwrap = true
						for _ = 1, 4 do
							n.text.width = math.max(1, math.floor(
									n.board_w * 0.9 / (px * k)))
							local h = n.text.height * px * k
							if h <= n.board_h * 0.9 or k <= 0.3 then
								break
							end
							-- Wrapped wider as it shrinks: its height goes
							-- about as the square of the size
							k = math.max(0.3, k * math.sqrt(n.board_h * 0.9 / h))
						end
						log:info(string.format("kit: entity %d's text wrapped "
								.. "at %d px, x%.2f, %.2f of %.2f cells high", id,
								n.text.width, k, n.text.height * px * k,
								n.board_h))
					end
					local sc = n.text_size * k / (48 / 128)
					n.text_node.scale = magic.Vector3(sc, sc, sc)
					-- (the back's the same)
					if n.text_back then
						if (n.board_w or 0) > 0 and (n.board_h or 0) > 0 then
							n.text_back.wordwrap = true
							n.text_back.width = n.text.width
						end
						n.text_back.text = v
						n.text_back_node.scale = magic.Vector3(sc, sc, sc)
					end
				end
				log:info("kit: entity " .. id .. " shows \"" .. v .. "\"" ..
						(n.text_back and " on both sides" or ""))
			end
		end
		if type(show.hud) == "string" then
			local v = M.key_text(shown(parse(n.node:GetVar("kit:" .. show.hud))))
			if v ~= "" then
				lines[#lines + 1] = {id, v}
			end
		end
		-- Its client parts
		local parts = parts_of(n)
		if #parts > 0 then
			n.e = n.e or entity_view(id, n)
			local e = n.e
			-- [KIT_SMALL_PIECES] its types' client_params, as the server shows
			-- them (an edit's change in the next show)
			if n.params_show ~= n.show then
				n.params_show = n.show
				e.params = type(show.params) == "table" and show.params or {}
			end
			if not n.added then
				n.added, n.vals = true, {}
				for _, part in ipairs(parts) do
					call(n, part, "on_add")
				end
			end
			for _, k in ipairs(type(show.shared) == "table" and show.shared or
					{}) do
				local v = n.node:GetVar("kit:" .. tostring(k))
				v = v:IsEmpty() and "" or v:GetString()
				if v ~= n.vals[k] then
					n.vals[k] = v
					e.state[k] = network.parse_json(v)
					for _, part in ipairs(parts) do
						call(n, part, "on_state", k)
					end
				end
			end
			local off = nil
			for _, part in ipairs(parts) do
				-- ([KIT_ENT_PERF_2] a part's skip_offscreen: not out of view)
				if part.skip_offscreen == true and off == nil then
					off = offscreen(n)
				end
				if not (off and part.skip_offscreen == true) then
					call(n, part, "on_update", dt)
				else
					LK.skipped = (LK.skipped or 0) + 1
				end
			end
		end
	end
	par_any = layers
	M.merge_flush()
	table.sort(lines, function(a, b) return a[1] < b[1] end)
	local t = {}
	for _, l in ipairs(lines) do
		t[#t + 1] = l[2]
	end
	-- [KIT_HUD] not beside Kit's own slots (its hotbar and screen)
	if P.items ~= "" and not (M.slots_own and M.slots_own()) then
		t[#t + 1] = P.items
	end
	local text = table.concat(t, "\n")
	if text ~= P.hud_text then
		P.hud_text = text
		if not hud then
			hud = magic.ui.root:CreateChild("Text")
			hud:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 15)
			hud:SetAlignment(magic.HA_RIGHT, magic.VA_TOP)
			hud:SetPosition(-12, 50)
		end
		hud:SetText(text)
		log:info("kit: the screen says \"" .. text:gsub("\n", " | ") .. "\"")
	end
	-- The Stop notice goes by itself
	if P.notice and buildat.get_time_us() > P.notice_until then
		P.notice:Remove()
		P.notice = nil
	end
end
magic.SubscribeToEvent("Update", function(_, data)
	local t0 = buildat.get_time_us()
	-- ([KIT_3D_GAINS_1] (4z38) the frames' time, start to start: a frame-time
	-- sample for a check)
	if LK.t then
		local dt = t0 - LK.t
		LK.dt, LK.worst = (LK.dt or 0) + dt, math.max(LK.worst or 0, dt)
	end
	LK.t = t0
	update_play(_, data)
	local us = buildat.get_time_us() - t0
	LK.frames, LK.us = LK.frames + 1, LK.us + us
	-- ([KIT_PLAYTEST_REC_2] rec.lua's perf rows: the pass's time since the start)
	LK.all_us = (LK.all_us or 0) + us
end)
function M.play_us()
	return LK.all_us or 0
end
-- [KIT_STILL_LOOKS] (a drive's: the looks read a frame since the last ask, of
-- how many, and this pass's ms a frame; [KIT_3D_GAINS_1] (4z38) the frames' own
-- ms, the mean and the worst)
magic.SubscribeToEvent("command_seq:kit_looks", function()
	local f = math.max(1, LK.frames)
	log:info(string.format("kit: looks: %d frames, %.1f read a frame of %.1f, " ..
			"%.2f ms a frame; frames %.1f ms, the worst %.1f; %.1f on_update skipped a " ..
			"frame (off screen)", LK.frames, LK.read / f, LK.looks / f, LK.us / f / 1000,
			(LK.dt or 0) / f / 1000, (LK.worst or 0) / 1000, (LK.skipped or 0) / f))
	LK.frames, LK.read, LK.looks, LK.us, LK.dt, LK.worst = 0, 0, 0, 0, 0, 0
	LK.skipped = 0
end)
-- [KIT_ENT_PERF] (a check's: "event kit_look_where <id> ...": each entity's look as
-- drawn, its node's place and turn read back (under the scene's root), one frame's)
magic.SubscribeToEvent("command_seq:kit_look_where", function(_, data)
	local parts = {}
	for id in data:GetString("Param"):gmatch("%d+") do
		local n = P.nodes[tonumber(id)]
		if n and n.look then
			local p, q = n.look.position, n.look.rotation
			parts[#parts + 1] = string.format("%s %.5f,%.5f,%.5f %.7f,%.7f,%.7f,%.7f", id,
					p.x, p.y, p.z, q.w, q.x, q.y, q.z)
		else
			parts[#parts + 1] = id .. " none"
		end
	end
	log:info("kit: looks where: " .. table.concat(parts, "; "))
end)

-- [KIT_CLIENT_REACT] (1) Zones on this client: its own predicted body
-- (controls.lua's zone_body) against the zones of the entities with client
-- parts (show.zones: {nx, ny, nz} a position parameter's cells, "look" its
-- look), in the shapes the server meets them (move.lua's port of kit.cpp's),
-- each frame, right after the steps (controls.lua's, before it sends them):
-- the parts' on_enter(e) and on_leave(e) as that changes, logged ("kit:
-- entity N's zone entered (this client)"), so one animates at once; the
-- server still decides (its own on_enter). None while Ended, out of play in
-- a lobby, nor a look zone under a kit/parallax layer. A shape kept till its
-- entity moves or turns, its look's state turns or its show changes; one
-- more than FAR metres from the body read again each 16th frame only (a
-- node's place is a dear read; met first by its kept bounds).
-- "event kit_zones" logs what the pass costs.
-- simplified: a far zone moving faster than FAR in 16 frames (15 m/s at
-- 60 fps) is met up to 16 frames late; a seat's rider stays as it was (the
-- server meets the seat's point, not predicted here); a kit/goal's reach
-- box round its target and a disabled component's zone are left out
local ZN = {inside = {}, frame = 0, frames = 0, us = 0, tested = 0, built = 0,
	max_us = 0, stepped = false}
local FAR = 4
local function zone_shapes(id, n, show, Z, body)
	local c = n.zone_cache
	if c and c.raw == n.show_raw and (ZN.frame + id) % 16 ~= 0 then
		local far = false
		for k = 1, 3 do
			far = far or body.hi[k] < c.lo[k] - FAR or body.lo[k] > c.hi[k] + FAR
		end
		if far then
			return c.shapes
		end
	end
	local p, r = n.node.position, n.node.rotation
	local look = type(show.look) == "table" and show.look or nil
	local key = look and type(look.state) == "string" and look.state ~= "" and look.state
	local on = key and parse(n.node:GetVar("kit:" .. key)) == true or false
	local at = {p.x, p.y, p.z, r.w, r.x, r.y, r.z, on}
	if c and c.raw == n.show_raw then
		local same = true
		for i = 1, 8 do
			same = same and c.at[i] == at[i]
		end
		if same then
			return c.shapes
		end
	end
	ZN.built = ZN.built + 1
	local R, pos, shapes = Z.quat_matrix(r.w, r.x, r.y, r.z), {p.x, p.y, p.z}, {}
	c = {at = at, raw = n.show_raw, shapes = shapes, lo = {math.huge, math.huge,
		math.huge}, hi = {-math.huge, -math.huge, -math.huge}}
	for i, z in ipairs(show.zones) do
		if i > 4 then
			break
		end
		local s
		if z == "look" then
			s = not M.parallax_layer(id, n) and Z.zone_look(look, on, pos, R)
		elseif type(z) == "table" then
			s = Z.zone_cells(pos, R, z)
		end
		if s then
			shapes[#shapes + 1] = s
			for k = 1, 3 do
				c.lo[k], c.hi[k] = math.min(c.lo[k], s.lo[k]), math.max(c.hi[k], s.hi[k])
			end
		end
	end
	n.zone_cache = c
	return shapes
end
local function update_zones()
	local Z = M.zone_math
	if not Z or (M.riding and M.riding()) then
		return
	end
	local t0 = buildat.get_time_us()
	ZN.frame = ZN.frame + 1
	local body = E.running and M.zone_body and
			not (M.out_of_play and M.out_of_play() and not M.waiting()) and M.zone_body()
	for id, n in pairs(P.nodes) do
		local show = type(n.show) == "table" and n.show
		local inside = false
		if body and n.added and show and type(show.zones) == "table" then
			for _, s in ipairs(zone_shapes(id, n, show, Z, body)) do
				ZN.tested = ZN.tested + 1
				if Z.zone_meets(s, body) then
					inside = true
					break
				end
			end
		end
		if inside ~= (ZN.inside[id] == true) then
			ZN.inside[id] = inside or nil
			log:info("kit: entity " .. id .. "'s zone " .. (inside and "entered" or
					"left") .. " (this client)")
			for _, part in ipairs(parts_of(n)) do
				call(n, part, inside and "on_enter" or "on_leave")
			end
		end
	end
	for id in pairs(ZN.inside) do
		if not P.nodes[id] then
			ZN.inside[id] = nil
		end
	end
	local us = buildat.get_time_us() - t0
	ZN.frames, ZN.us = ZN.frames + 1, ZN.us + us
	ZN.max_us = math.max(ZN.max_us, us)
end
-- (controls.lua's after its steps; a frame's own pass only where no steps
-- ran the frame before)
function M.update_zones()
	ZN.stepped = true
	update_zones()
end
magic.SubscribeToEvent("Update", function()
	if not ZN.stepped then
		update_zones()
	end
	ZN.stepped = false
end)
-- (a drive's: the pass's cost since the last ask)
magic.SubscribeToEvent("command_seq:kit_zones", function()
	local n = 0
	for _ in pairs(ZN.inside) do
		n = n + 1
	end
	log:info(string.format("kit: zones: %d frames, %.1f us a frame (at most %d), " ..
			"%.1f shapes met a frame, %d built, %d inside", ZN.frames,
			ZN.us / math.max(1, ZN.frames), ZN.max_us, ZN.tested / math.max(1, ZN.frames),
			ZN.built, n))
	ZN.frames, ZN.us, ZN.tested, ZN.built, ZN.max_us = 0, 0, 0, 0, 0
end)

-- The types' client parts, run as this module's own Lua is ([KIT] 4d).
-- [KIT_CUSTOM_TYPES] One sent again with another source (a custom type
-- edited) replaces it on the entities that have it (the old one's
-- on_remove, the new one's on_add); an empty one takes it away
P.part_src = P.part_src or {}
-- [KIT_CLIENT_REACT] (2) kit.shared: one plain table every client part of
-- every entity shares (`require("buildat/module/kit").shared`), keys by
-- convention the type's name. Local, nothing sent; it lasts for the
-- connection (a part's reload, a scene switch, Play and Stop keep it).
-- simplified: no cleanup of its own; a part clears its keys in on_remove
M.shared = {}
local function swap_part(t, old, new)
	for _, n in pairs(P.nodes) do
		local show = type(n.show) == "table" and n.show or {}
		local has = false
		for _, c in ipairs(type(show.client) == "table" and show.client or {}) do
			has = has or c == t
		end
		if n.added and has then
			if old then
				call(n, old, "on_remove")
				-- ([KIT_UI_CLIENT_PART] what it set on its element goes with it)
				n.ui_set, n.ui_v = nil, (n.ui_v or 0) + 1
			end
			if new then
				call(n, new, "on_add")
			end
		end
	end
end
buildat.sub_packet("kit:client_parts", function(data)
	local parts = network.parse_json(data)
	for t, src in pairs(type(parts) == "table" and parts or {}) do
		if src == "" then
			if P.parts[t] then
				swap_part(t, P.parts[t], nil)
				log:info("kit: the client part of " .. tostring(t) .. " gone")
			end
			P.parts[t], P.part_src[t] = nil, nil
		elseif type(src) == "string" and P.part_src[t] ~= src then
			P.part_src[t] = src
			local ok, part = buildat.eval(src, tostring(t) .. ".client")
			if ok and type(part) == "table" then
				local old = P.parts[t]
				P.parts[t] = part
				if old then
					swap_part(t, old, part)
				end
				log:info("kit: the client part of " .. tostring(t))
			else
				log:warning("kit: the client part of " .. tostring(t) ..
						" does not load: " .. tostring(part))
			end
		end
	end
end)

-- This player's own entity
buildat.sub_packet("kit:you", function(data)
	local y = network.parse_json(data)
	P.you = type(y) == "table" and tonumber(y.id) or 0
	P.my_name = type(y) == "table" and y.name or nil
	P.use_range = type(y) == "table" and tonumber(y.use_range) or nil
	-- [KIT_TOOLS_1] Kit's hotbar (hands.lua)
	P.hands = type(y) == "table" and y.hands == true
	log:info("kit: this player is entity " .. tostring(P.you))
	-- [KIT_MUSIC_LOAD_HOLD] a scene entered: its music waits for its load
	if M.music_entered then
		M.music_entered()
	end
	-- [KIT_AGENT_NEXT_1] The server's camera: it says it is in
	if type(y) == "table" and y.camera == true then
		log:info("kit: the server's camera is in")
		buildat.send_packet("kit:camera_ready", "")
	end
end)

buildat.sub_packet("kit:items", function(data)
	local items = network.parse_json(data)
	local t = {}
	for k, v in pairs(type(items) == "table" and items or {}) do
		t[#t + 1] = tostring(k) .. " x" .. tostring(v)
	end
	table.sort(t)
	P.items = #t > 0 and "Items: " .. table.concat(t, ", ") or ""
	M.hands_items(items)
	log:info("kit: items: " .. (#t > 0 and table.concat(t, ", ") or "none"))
end)

-- [KIT] stage 4e: the World's word to builders (a refusal, the seams of a
-- regeneration)
buildat.sub_packet("kit:warning", function(data)
	log:info("kit: warning: " .. tostring(data))
	ui_utils.show_notification(tostring(data), 8)
end)

-- [KIT_VOXEL_FORMAT] The World's sky light ("kit:sky" {"on": bool}, at
-- the join and on a change; "relit" once the loaded sections are): the voxels meshed with the light the server
-- keeps in them, drawn by KitVoxelSky*.xml. M.sky_light() is it;
-- M.on_sky(cb) is told. [KIT_SKY_LIGHT_CAVES] Off, the same meshes and
-- look with the sky taken as full everywhere (the light bits not read,
-- they are stale then): the corners' shade alone, on the ambient and the
-- sun. Its cost is a vertex colour on every voxel mesh.
local sky_on, sky_cbs = false, {}
do
	local voxelworld = require("buildat/module/voxelworld")
	voxelworld.use_skylight = true
	buildat.set_mesh_sky_full(true)
end
function M.sky_light()
	return sky_on
end
function M.on_sky(cb)
	sky_cbs[#sky_cbs + 1] = cb
end
buildat.sub_packet("kit:sky", function(data)
	local d = network.parse_json(data)
	local on = type(d) == "table" and d.on == true
	if on and d.relit then
		log:info("kit: sky light: the loaded world relit")
	end
	if on == sky_on then
		return
	end
	sky_on = on
	log:info("kit: sky light " .. (on and "on" or "off"))
	buildat.set_mesh_sky_full(not on)
	require("buildat/module/voxelworld").remesh_all()
	for _, cb in ipairs(sky_cbs) do
		cb(on)
	end
end)

-- A chunk's look (voxelworld.sub_material_update, voxel_objects'
-- set_material_cb): KitVoxel*.xml on its solid faces, its "alpha" child
-- (water, blended) and its "masked" one (leaves and plants, cut out),
-- with the tint, and the sky light when the World has it; under physical
-- lighting ([KIT_LIGHTING], environment.lua) its albedo decoded
-- [KIT_RTS] The depth cut (KitVoxel.glsl's KITCUT): the chunks' materials
-- by their node's id, each given the cut's y (CUT.off: none) and, with a
-- cut, no culling (a cut wall's back shows). simplified: a chunk gone keeps
-- its entry until its id is used again (a World's chunks are bounded)
-- [KIT_RTS] Fog of war's darkening (KITFOG): with CUT.fog on, the chunks
-- wear the Fog variants of their techniques (mats.tech their names without
-- it); rts.lua sets the circles
local CUT = {y = nil, off = 1e4, mats = {}, fog = false}
local function cut_material(m)
	m:SetShaderParameter("KitCut", CUT.y or CUT.off)
	m.cullMode = CUT.y and magic.CULL_NONE or magic.CULL_CCW
end
local function technique(name)
	return magic.cache:GetResource("Technique", name ..
			(CUT.fog and "Fog" or "") .. ".xml")
end
function M.voxel_look(node)
	local sky = "Sky" .. (M.physical and M.physical() and "Phys" or "")
	local mats = {tech = {}}
	for child, kind in pairs({[""] = "", alpha = "Alpha",
			masked = "Masked"}) do
		local n = child == "" and node or node:GetChild(child)
		local cg = n and n:GetComponent("CustomGeometry")
		local i = 0
		while cg and cg:GetMaterial(i) do
			local m = cg:GetMaterial(i)
			local t = "kit/KitVoxel" .. sky .. kind
			m:SetTechnique(0, technique(t))
			cut_material(m)
			mats[#mats + 1] = m
			mats.tech[#mats] = t
			i = i + 1
		end
	end
	CUT.mats[node:GetID()] = mats
end
-- Fog of war's darkening on every chunk drawn, or off
function M.set_fog(on)
	if on == CUT.fog then
		return
	end
	CUT.fog = on
	for _, mats in pairs(CUT.mats) do
		for i, m in ipairs(mats) do
			m:SetTechnique(0, technique(mats.tech[i]))
		end
	end
end
-- The cut at world y (nil: none) on every chunk drawn
function M.set_cut(y)
	if y == CUT.y then
		return
	end
	CUT.y = y
	for _, mats in pairs(CUT.mats) do
		for _, m in ipairs(mats) do
			cut_material(m)
		end
	end
end

-- The season's look: the server's registry with the season's textures in
-- ("kit:season": the season, a line, the registry), the voxels unchanged;
-- no registry: the World's own again
local season_base = nil
buildat.sub_packet("kit:season", function(data)
	local nl = data:find("\n", 1, true)
	local season = nl and data:sub(1, nl - 1) or data
	local reg_data = nl and data:sub(nl + 1) or ""
	local voxelworld = require("buildat/module/voxelworld")
	if reg_data ~= "" then
		local reg = buildat.createVoxelRegistry()
		voxelworld.make_named_textures(reg_data)
		reg:deserialize(reg_data)
		season_base = season_base or voxelworld.get_voxel_registry()
		voxelworld.set_voxel_registry(reg)
		log:info("kit: season " .. season .. ": registry swapped")
	elseif season_base then
		voxelworld.set_voxel_registry(season_base)
		season_base = nil
		voxelworld.registry_from_file()
		log:info("kit: season " .. season .. ": own registry again")
	else
		return
	end
	voxel_defs.count = -1
	voxelworld.remesh_all()
end)

-- A regeneration's sections all generated again (a check's wait)
buildat.sub_packet("kit:regenerated", function(data)
	log:info("kit: World: generated again")
end)
-- [KIT_SCENES_GENERATED] A new World's first sections all generated: the
-- scene's (a check's wait)
buildat.sub_packet("kit:generated", function(data)
	log:info("kit: World of the scene " .. data .. ": generated")
end)

-- The Stop notice: the round's builds were discarded, who built them when
-- others did; a builder may keep them (here, or the tools' panel until the
-- next Play). Not a dialog: it takes no focus and goes by itself
local NOTICE_S = 15
buildat.sub_packet("kit:discarded", function(data)
	local d = network.parse_json(data)
	if type(d) ~= "table" or type(d.counts) ~= "table" then
		return
	end
	local list, others = {}, false
	for name, k in pairs(d.counts) do
		list[#list + 1] = (name == d.you and "you" or tostring(name)) .. " " ..
				tostring(k)
		others = others or name ~= d.you
	end
	table.sort(list)
	local s = others and "Builds made during play were discarded (" ..
			table.concat(list, ", ") .. ")." or
			"Your builds made during play were discarded."
	log:info("kit: builds discarded: " .. s)
	if P.notice then
		P.notice:Remove()
	end
	local w = magic.ui.root:CreateChild("Window")
	if not magic.ui.root.defaultStyle then
		magic.ui.root.defaultStyle = STYLE
	end
	w:SetStyleAuto()
	w:SetLayout(magic.LM_HORIZONTAL, 6, magic.IntRect(8, 6, 8, 6))
	w:SetFocusMode(magic.FM_NOTFOCUSABLE)
	text(w, s)
	if d.can_keep == true then
		button(w, "Keep them", function()
			send({op = "keep"})
			if P.notice then
				P.notice:Remove()
				P.notice = nil
			end
		end)
	end
	w:SetAlignment(magic.HA_RIGHT, magic.VA_TOP)
	w:SetPosition(-10, 90)
	P.notice, P.notice_until = w, buildat.get_time_us() + NOTICE_S * 1000000
end)

function M.use(id)
	log:info("kit: use " .. tostring(id))
	-- Its client parts first: what this player sees at once
	local n = P.nodes[tonumber(id) or -1]
	if n and n.e then
		for _, part in ipairs(parts_of(n)) do
			call(n, part, "on_use")
		end
	end
	buildat.send_packet("kit:use", tostring(id))
end

magic.SubscribeToEvent("command_seq:kit_edit", function(_, data)
	local text = data:GetString("Param")
	log:info("kit editor: sent " .. text)
	buildat.send_packet("kit:edit", text)
end)
-- [KIT_CUSTOM_TYPES] "event kit_type <json>": a "kit:type" as the editor's,
-- from any client (a check's refusals)
magic.SubscribeToEvent("command_seq:kit_type", function(_, data)
	buildat.send_packet("kit:type", data:GetString("Param"))
end)
-- [KIT_SERVER_PUBLISH] "event kit_publishing <json>": a "kit:publishing"
-- (the Publishing page's ops) from any client (a check's refusals)
magic.SubscribeToEvent("command_seq:kit_publishing", function(_, data)
	local text = data:GetString("Param")
	log:info("kit editor: publishing " .. text)
	buildat.send_packet("kit:publishing", text)
end)
magic.SubscribeToEvent("command_seq:kit_use", function(_, data)
	M.use(data:GetString("Param"))
end)
-- For a drive ([KIT_USE_FLOOD]): "event kit_use_flood <id> <n>" sends n
-- uses of it at once, as a misbehaving client would
magic.SubscribeToEvent("command_seq:kit_use_flood", function(_, data)
	local id, n = data:GetString("Param"):match("^(%d+) (%d+)$")
	log:info("kit: flooding " .. tostring(n) .. " uses of " .. tostring(id))
	for _ = 1, math.min(tonumber(n) or 0, 100000) do
		buildat.send_packet("kit:use", id)
	end
end)
-- [KIT_SESSIONS_1] For a check: "event kit_probe <x> <y> <z>" logs the
-- voxel this client has there and the entities it has
magic.SubscribeToEvent("command_seq:kit_probe", function(_, data)
	local c = {}
	for n in data:GetString("Param"):gmatch("%-?%d+") do
		c[#c + 1] = tonumber(n)
	end
	local voxelworld = require("buildat/module/voxelworld")
	local reg = voxelworld.get_voxel_registry()
	local v = voxelworld.get_static_voxel(magic.Vector3(c[1] or 0, c[2] or 0,
			c[3] or 0))
	local def = reg and reg:get_by_id(reg:id_of(v))
	local ids = {}
	for id in pairs(P.nodes) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	local rg = M.region_at and M.region_at(c[1] or 0, c[2] or 0, c[3] or 0)
	log:info("kit probe: voxel " .. (def and def.name and
			tostring(def.name.block_name) or "?") .. ", entities " ..
			table.concat(ids, ",") .. (rg and ", region " ..
			rg.node:GetVar("kit_id"):GetInt() or ""))
end)
-- [KIT_TERRAIN_FLATTEN] For a check: "event kit_ground <x> <z>..." logs the
-- heightmap's ground this client has at each point (none: no heightmap)
magic.SubscribeToEvent("command_seq:kit_ground", function(_, data)
	local s = data:GetString("Param")
	for x, z in s:gmatch("(%-?[%d.]+),(%-?[%d.]+)") do
		local h = heightmap.height_at(tonumber(x), tonumber(z))
		log:info("kit: ground at " .. x .. "," .. z .. " " ..
				(h and string.format("%.2f", h) or "none"))
	end
end)
-- [KIT_FREE_ROTATION] For a drive: "event kit_pose <id>...": where an entity's
-- node and look are as drawn
magic.SubscribeToEvent("command_seq:kit_pose", function(_, data)
	for id in data:GetString("Param"):gmatch("%d+") do
		local n = P.nodes[tonumber(id)]
		local a = n and (n.look or n.node)
		if a then
			local p, q = a.position, a.rotation
			log:info(string.format("kit pose: %s %.4f,%.4f,%.4f turn "
					.. "%.5f,%.5f,%.5f,%.5f%s", id, p.x, p.y, p.z, q.w, q.x, q.y, q.z,
					n.look and " look" or ""))
		else
			log:info("kit pose: " .. id .. " none")
		end
	end
end)
-- For a drive: "event kit_select <id>..." selects them in the editor, the
-- last the primary
magic.SubscribeToEvent("command_seq:kit_select", function(_, data)
	local add = false
	for id in data:GetString("Param"):gmatch("%d+") do
		if M.select then
			M.select(tonumber(id), add)
		end
		add = true
	end
end)


-- ---- Pointing ([KIT] stage 4e2)

-- The ray meets a box (its middle c, its half sides half, {x, y, z} each)
-- at t (nil: it does not)
local function ray_box(o, d, c, half)
	local t0, t1 = 0, math.huge
	for i = 1, 3 do
		local lo, hi = c[i] - half[i], c[i] + half[i]
		if math.abs(d[i]) < 1e-9 then
			if o[i] < lo or o[i] > hi then
				return nil
			end
		else
			local a, b = (lo - o[i]) / d[i], (hi - o[i]) / d[i]
			if a > b then
				a, b = b, a
			end
			t0, t1 = math.max(t0, a), math.min(t1, b)
			if t0 > t1 then
				return nil
			end
		end
	end
	return t0
end

local function unit(dir)
	local l = math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
	if l < 1e-9 then
		return magic.Vector3(0, 0, 1)
	end
	return magic.Vector3(dir.x / l, dir.y / l, dir.z / l)
end

-- An entity's look as drawn: its middle in the world, its half sides and
-- its turn (the yaw's over the look's own); nil without a look
local function look_frame(n)
	if not n.box or not n.look then
		return nil
	end
	local rot = n.look.rotation
	local c = n.look.position + rot * v3(n.box.off)
	return c, magic.Vector3(n.box.size[1] / 2, n.box.size[2] / 2,
			n.box.size[3] / 2), rot
end

-- The ray in a turned box's own frame: its middle the origin
local function ray_in(origin, dir, c, rot)
	local inv = magic.Quaternion(rot.w, -rot.x, -rot.y, -rot.z)
	local o = inv * (origin - c)
	local d = inv * dir
	return {o.x, o.y, o.z}, {d.x, d.y, d.z}
end

-- How far along the ray it meets the entity (its node n), or nil
local function entity_t(n, origin, dir)
	local c, half, rot = look_frame(n)
	if c and n.poly then
		-- [KIT_PLANE] stage 3: a polygon's faces where its points have them.
		-- simplified: not its sides (a ray along its face misses it)
		local o, d = ray_in(origin, dir, n.look.position, rot)
		local best, q, k = nil, n.poly.pts, #n.poly.pts / 2
		for _, z in ipairs(math.abs(d[3]) > 1e-9 and {-n.poly.d, n.poly.d} or {}) do
			local t = (z - o[3]) / d[3]
			local x, y = o[1] + d[1] * t, o[2] + d[2] * t
			local inside = false
			for i = 1, k do
				local j = i % k + 1
				if (q[2 * i] > y) ~= (q[2 * j] > y) and x < q[2 * i - 1] + (y - q[2 * i]) *
						(q[2 * j - 1] - q[2 * i - 1]) / (q[2 * j] - q[2 * i]) then
					inside = not inside
				end
			end
			if inside and t >= 0 and (not best or t < best) then
				best = t
			end
		end
		return best
	end
	if c then
		-- A little larger than drawn (a thin button: as thick as a third of a
		-- cell)
		local h = {}
		for i, k in ipairs({"x", "y", "z"}) do
			h[i] = math.max(half[k], 0.15) + 0.1
		end
		local o, d = ray_in(origin, dir, c, rot)
		return ray_box(o, d, {0, 0, 0}, h)
	end
	local p = n.node.position
	local wx, wy, wz = p.x - origin.x, p.y - origin.y, p.z - origin.z
	local tt = wx * dir.x + wy * dir.y + wz * dir.z
	local dx, dy, dz = wx - dir.x * tt, wy - dir.y * tt, wz - dir.z * tt
	-- A cell's corner is 0.87 from its middle; a face's middle 0.5
	if tt > 0 and math.sqrt(dx * dx + dy * dy + dz * dz) <= 0.75 then
		return tt
	end
end

local function show_of(n)
	return type(n.show) == "table" and n.show or {}
end

function M.pick_entity(origin, dir, reach, skip)
	dir = unit(dir)
	local best, bd, usable = nil, nil, false
	for id, n in pairs(P.nodes) do
		local show = show_of(n)
		-- What a click uses: one that does nothing (a player's entity, a
		-- spawner's pad) the ray goes through, to the voxel behind
		if show.usable and not show.player and not (skip and skip[id]) then
			local t = entity_t(n, origin, dir)
			if t and t <= reach + 0.5 and (not bd or t < bd) then
				best, bd, usable = id, t, show.usable == true
			end
		end
	end
	return best, bd, usable
end

-- The old name: the id alone
function M.pointed(origin, dir, reach)
	return (M.pick_entity(origin, dir, reach))
end

-- The first cell along the ray that solid() says is a voxel, the cell
-- before it (the face's side; nil when the ray starts in it) and how far
-- along the ray it was entered, at most `reach` on (a walk from cell to
-- cell, Amanatides and Woo); cells are voxels centred on whole numbers
local function voxel_ray(o, v, solid, reach)
	local c, step, tmax, tdelta = {}, {}, {}, {}
	for k = 1, 3 do
		local p = o[k] + 0.5
		c[k] = math.floor(p)
		if v[k] > 1e-9 then
			step[k], tmax[k], tdelta[k] = 1, (c[k] + 1 - p) / v[k], 1 / v[k]
		elseif v[k] < -1e-9 then
			step[k], tmax[k], tdelta[k] = -1, (p - c[k]) / -v[k], -1 / v[k]
		else
			step[k], tmax[k], tdelta[k] = 0, math.huge, math.huge
		end
	end
	local prev, t = nil, 0
	for _ = 1, 4096 do
		if t > reach then
			return nil
		end
		if solid(c[1], c[2], c[3]) then
			return {c[1], c[2], c[3]}, prev, t
		end
		prev = {c[1], c[2], c[3]}
		local k = 1
		if tmax[2] < tmax[k] then k = 2 end
		if tmax[3] < tmax[k] then k = 3 end
		t = tmax[k]
		c[k] = c[k] + step[k]
		tmax[k] = tmax[k] + tdelta[k]
	end
end
M.voxel_ray = voxel_ray

-- [KIT_HM_VOXELS] A heightmap's ground for the voxel tools: a cell whose
-- top is at or under the terrain at its middle is ground, pointed at and
-- built on, never dug (the voxels over it are air until built). The cell
-- the terrain cuts through is air: the first layer built, partly sunken
-- (a wall without a gap under it), each of its voxels still seen
local SUNK = 1e-4 -- a cell sunken less than this is ground
function M.terrain_cell(x, y, z)
	local h = heightmap.terrain and heightmap.height_at(x, z)
	return type(h) == "number" and y + 0.5 <= h + SUNK
end

-- Where the ray meets the terrain's surface, back from t (where it is in
-- the ground's cells, under the surface): {x, h, z}, or nil
local function surface_point(o, v, t)
	local function under(s)
		local x, z = o[1] + v[1] * s, o[3] + v[3] * s
		local h = heightmap.height_at(x, z)
		return type(h) == "number" and o[2] + v[2] * s <= h
	end
	local step = 0.1 / math.max(1e-6, math.sqrt(v[1] ^ 2 + v[2] ^ 2 + v[3] ^ 2))
	-- (Over the surface already at t, between samples: t's point)
	local a, b = t, nil -- a under, b over
	for i = 1, under(t) and 80 or 0 do
		local s = t - step * i
		if s <= 0 then
			break
		end
		if not under(s) then
			b = s
			break
		end
		a = s
	end
	if b then
		for _ = 1, 12 do
			local m = (a + b) / 2
			if under(m) then a = m else b = m end
		end
	end
	local x, z = o[1] + v[1] * a, o[3] + v[3] * a
	local h = heightmap.height_at(x, z)
	return type(h) == "number" and {x, h, z} or nil
end

-- Where a placement on a ray's hit (voxel_ray's hit, front and t; o and v
-- the ray) goes: the cell before a voxel's face; on the heightmap the
-- cell the terrain cuts through where the ray meets it, the lowest one at
-- least partly seen (the face's cell when that one is taken)
function M.place_front(hit, front, o, v, t, solid)
	if not (hit and M.terrain_cell(hit[1], hit[2], hit[3])) then
		return front
	end
	local p = surface_point(o, v, t)
	if not p then
		return front
	end
	local c = {math.floor(p[1] + 0.5), math.floor(p[2] + 0.5 + SUNK),
			math.floor(p[3] + 0.5)}
	if solid and solid(c[1], c[2], c[3]) then
		return front
	end
	return c
end

-- solid() with a heightmap's ground in it
local function with_terrain(solid)
	if not heightmap.terrain then
		return solid
	end
	return function(x, y, z)
		return M.terrain_cell(x, y, z) or (solid and solid(x, y, z) or false)
	end
end
M.with_terrain = with_terrain

-- Whether a component grants this player key ("dig" or "place") at the
-- cell: its `grants` box (from its own cell up and on) holds it and its
-- state's key is true, while the server is Running (the server's
-- granted(), api.h)
local function granted(key, x, y, z)
	if not E.running then
		return false
	end
	for _, n in pairs(P.nodes) do
		local g = show_of(n).grants
		if type(g) == "table" and value(n, key) == true then
			local p = n.node.position
			local ox, oy, oz = math.floor(p.x + 1e-4), math.floor(p.y + 1e-4),
					math.floor(p.z + 1e-4)
			if x >= ox and x < ox + (tonumber(g[1]) or 1) and y >= oy and
					y < oy + (tonumber(g[2]) or 1) and z >= oz and
					z < oz + (tonumber(g[3]) or 1) then
				return true
			end
		end
	end
	return false
end

-- [KIT] stage 4j: the region deciding a cell (the smallest enabled one
-- holding it), as the server's region_at(): its node, or nil
local function region_at(x, y, z)
	local best, best_v
	for _, n in pairs(P.nodes) do
		local g = show_of(n).region
		if type(g) == "table" and value(n, "enabled") ~= false then
			local sz = value(n, "size")
			if type(sz) ~= "table" then
				sz = g
			end
			local e = {}
			-- ([KIT_CTF] the server's MAX_REGION_EXTENT)
			for i = 1, 3 do
				e[i] = math.max(1, math.min(384, math.floor(tonumber(sz[i]) or 1)))
			end
			local p = n.node.position
			local r = n.node.rotation
			local inside
			if math.abs(r.x) + math.abs(r.y) + math.abs(r.z) > 1e-6 then
				-- [KIT_FREE_ROTATION] Turned with its parent: the cell's middle
				-- in its frame
				local l = magic.Quaternion(r.w, -r.x, -r.y, -r.z) *
						(magic.Vector3(x, y, z) - p)
				local a, b, c = math.floor(l.x + 0.5), math.floor(l.y + 0.5),
						math.floor(l.z + 0.5)
				inside = a >= 0 and a < e[1] and b >= 0 and b < e[2] and c >= 0 and
						c < e[3]
			else
				local ox, oy, oz = math.floor(p.x + 1e-4), math.floor(p.y + 1e-4),
						math.floor(p.z + 1e-4)
				inside = x >= ox and x < ox + e[1] and y >= oy and y < oy + e[2] and
						z >= oz and z < oz + e[3]
			end
			if inside then
				local v = e[1] * e[2] * e[3]
				if not best or v < best_v then
					best, best_v = n, v
				end
			end
		end
	end
	return best
end
M.region_at = region_at

local REFUSED = {dig = "Protected: no digging here",
	place = "Protected: no placing here",
	enter = "Protected: no entering here",
	use = "Protected: no using things here"}

-- Whether this player may do action at the cell, and why not (the
-- server's allows(); a region's allow hook is the server's alone)
function M.allows(action, x, y, z)
	-- [KIT_BUILDER_PLAY_RULES] a builder builds freely in edit mode only;
	-- out of it they play by the rules as everyone
	if E.can_edit and E.editing and (action == "dig" or action == "place") then
		return true
	end
	if (action == "dig" or action == "place") and not E.running then
		return false, "The game is not running"
	end
	local n = region_at(x, y, z)
	if not n then
		if action ~= "dig" and action ~= "place" then
			return true
		end
		if granted(action, x, y, z) then
			return true
		end
		-- [KIT_TERRAIN_PLAY_RULES] the World's dig and place, over its map
		local tr = E.terrain_rules or {}
		local m = tr.map
		local who = tr[action] or "none"
		if type(m) == "table" and not (x >= m[1] and x < m[1] + m[3] and
				z >= m[2] and z < m[2] + m[4]) then
			who = "none"
		end
		if who == "all" or (who == "builders" and E.can_edit) then
			return true
		end
		return false, REFUSED[action]
	end
	local o = value(n, "owners")
	local mine = false
	if o == "builders" then
		mine = E.can_edit == true
	elseif type(o) == "table" then
		for _, name in ipairs(o) do
			mine = mine or name == P.my_name
		end
	elseif type(o) == "string" and o ~= "nobody" then
		for name in o:gmatch("[^,%s]+") do
			mine = mine or name == P.my_name
		end
	end
	local rules = value(n, "rules")
	local rule = type(rules) == "table" and rules[action]
	if rule == "all" or rule == (mine and "owners" or "others") then
		return true
	end
	return false, REFUSED[action] or "Protected"
end

function M.may_dig(x, y, z)
	return (M.allows("dig", x, y, z))
end

function M.may_place(x, y, z)
	return (M.allows("place", x, y, z))
end

-- [KIT_WHEEL_TRACKPAD] Whole wheel notches for a stepping use (key: whose),
-- signed as the event's Wheel. A native wheel event is whole notches; the
-- web's are tenths (the SDL port's), and a trackpad or a smooth scroll
-- sends a notch in many small events: they add up here, a step a notch.
-- A turn the other way drops what was left over
M.wheel_left = {web = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil}
function M.wheel_steps(key, wheel)
	-- (in the event's own units, integers: tenths added as 0.1 miss a notch)
	local unit = M.wheel_left.web and 10 or 1
	local acc = M.wheel_left[key] or 0
	acc = acc * wheel < 0 and wheel or acc + wheel
	local n = acc < 0 and -math.floor(-acc / unit) or math.floor(acc / unit)
	M.wheel_left[key] = acc - n * unit
	return n
end

-- A refusal told (a click the rules refuse), not more than once a second
-- for the same reason
local told, told_at = nil, 0
function M.refused(why)
	local now = buildat.get_time_us()
	if why == told and now - told_at < 1000000 then
		return
	end
	told, told_at = why, now
	log:info("kit: refused: " .. tostring(why))
	ui_utils.show_notification(tostring(why), 3)
end

function M.play_target(origin, dir, reach, solid)
	dir = unit(dir)
	solid = solid or O.solid
	-- Not the seat held: the ray goes out of it
	local seat = M.seated and M.seated()
	local skip = {}
	if seat then
		skip[seat] = true
	end
	-- [WB_HOVER_OUT_OF_REACH] Only what a click would use: within the
	-- server's use range of the player (their place in the world as the
	-- server has it: the body's feet and a half, or their entity's), not
	-- the ray's reach past a camera far behind; one a click walks to
	-- (kit/click_to_move) wherever it is
	local me = M.body_pos and M.body_pos()
	me = me and me + magic.Vector3(0, 0.5, 0) or
			P.nodes[P.you] and P.nodes[P.you].node.position
	if me and P.use_range and not (M.clicks_move and M.clicks_move()) then
		for nid, n in pairs(P.nodes) do
			-- [KIT_FLAG_CLICK_RANGE] its type's own, if it has one (only what
			-- pick_entity would take: a node's place is a dear read)
			local show = show_of(n)
			local r = math.min(P.use_range, tonumber(show.use_range) or
					P.use_range)
			if show.usable and not show.player and
					(n.node.position - me):Length() > r then
				skip[nid] = true
			end
		end
	end
	-- [KIT_FLAG_CLICK_RANGE] One that a click does nothing to just now: the
	-- ray goes through
	for nid, n in pairs(P.nodes) do
		local k = show_of(n).use_when
		if type(k) == "string" and parse(n.node:GetVar("kit:" .. k)) == false then
			skip[nid] = true
		end
	end
	local id, et, usable = M.pick_entity(origin, dir, reach, skip)
	local hit, front, vt
	solid = with_terrain(solid)
	if solid then
		hit, front, vt = voxel_ray({origin.x, origin.y, origin.z},
				{dir.x, dir.y, dir.z}, solid, reach)
		front = M.place_front(hit, front, {origin.x, origin.y, origin.z},
				{dir.x, dir.y, dir.z}, vt, solid)
	end
	local t = {}
	-- [KIT_TOOLS_1] A melee item held: a player or an entity with health
	-- in its reach is hit, a click at nothing swings; an item of use kind
	-- "use" is used (on what is pointed at)
	local sheet = M.held_item()
	if sheet and sheet.use == "use" then
		t.left = {kind = "item", id = id or 0}
		return t
	end
	-- [KIT_TOOLS_2] a ranged item's click is its shot (hands.lua's)
	if sheet and sheet.use == "ranged" then
		t.left = {kind = "shoot"}
		return t
	end
	local me_far = me and (origin - me):Length() or 0
	local hid, ht = M.hit_pick(origin, dir, me_far > 1 and me_far or 0)
	if hid and (not hit or ht <= vt + 0.05) and (not id or ht <= et) then
		t.left = {kind = "hit", id = hid}
		return t
	end
	if sheet and sheet.use == "melee" and not id and not hit then
		t.left = {kind = "swing"}
	end
	-- [KIT_AIRSHIPS] A free voxel object's cell nearer than the voxel and the
	-- entity: dug and placed on in its frame (M.object_build; the server's
	-- kit/hull says who may)
	local ot = M.object_target and M.object_target(origin, dir, reach)
	if ot and (not hit or ot.t < vt) and (not id or ot.t < et) then
		local n = ot.normal
		local c = {ot.cell[1] + n[1], ot.cell[2] + n[2], ot.cell[3] + n[3]}
		t.left = {kind = "dig", object = ot.id, cell = ot.cell,
			centre = ot.centre, rot = ot.rot}
		t.right = {kind = "place", object = ot.id, cell = c, on = ot.cell,
			normal = n, centre = ot.centre, rot = ot.rot,
			param = M.shape_param({x = ot.dir[1], y = ot.dir[2], z = ot.dir[3]}, n)}
		return t
	end
	-- The object first: what is in front of the voxel is pointed at
	if id and (not hit or et <= vt + 0.05) then
		-- [KIT_USE_ACCESS] the region's use rule asked; one used through
		-- its links only (usable "locked") told so. simplified: an object's
		-- owners-only use is the server's to refuse
		local p = P.nodes[id].node.position
		local ok, why = M.allows("use", math.floor(p.x + 1e-4),
				math.floor(p.y + 1e-4), math.floor(p.z + 1e-4))
		if not usable then
			ok, why = false, "Locked: used through its links only"
		end
		t.left = ok and {kind = "use", id = id} or {kind = "refused", why = why}
		return t
	end
	if hit and not M.terrain_cell(hit[1], hit[2], hit[3]) then
		local ok, why = M.allows("dig", hit[1], hit[2], hit[3])
		-- [KIT] stage 4j: refused, the click says why
		t.left = ok and {kind = "dig", cell = hit} or
				{kind = "refused", why = why}
	end
	local place_ok, place_why = false, nil
	if hit and front then
		place_ok, place_why = M.allows("place", front[1], front[2], front[3])
		if not place_ok then
			t.right = {kind = "refused", why = place_why}
		end
	end
	if hit and front and place_ok then
		local n = {front[1] - hit[1], front[2] - hit[2], front[3] - hit[3]}
		if math.abs(n[1]) + math.abs(n[2]) + math.abs(n[3]) ~= 1 then
			-- Over the heightmap's hit point: its top
			n = {0, 1, 0}
		end
		t.right = {kind = "place", cell = front, on = hit, normal = n,
			param = M.shape_param(dir, n, vt and origin.y + dir.y * vt)}
	end
	return t
end

-- [KIT_FLAG_RIGHT_CLICK] An entity whose type's right_use (a shared
-- state's name) holds this player's id: their right click uses it, not a
-- placing (kit/flag carried)
do
	local target = M.play_target
	function M.play_target(...)
		local t = target(...)
		for id, n in pairs(P.nodes) do
			local k = type(n.show) == "table" and n.show.right_use
			if type(k) == "string" and P.you ~= 0 and
					tonumber(parse(n.node:GetVar("kit:" .. k))) == P.you then
				t.right = {kind = "use", id = id}
			end
		end
		return t
	end
end

-- ---- [KIT_VOXEL_FORMAT] The hand's shape and tint (stage 4g2): what a
-- placing puts down besides the material -- M.hand.shape ("" the cube,
-- "slab", "stair", "inner_stair", "outer_stair", "panel", "pillar"; a
-- material with shapes only) and M.hand.tint (0...15, the material's tint
-- ramp). The editor's palette sets them; Workbench's placing and the
-- editor's voxels tool read them.
M.SHAPES = {"slab", "stair", "inner_stair", "outer_stair", "panel", "pillar"}
M.hand = {shape = "", tint = 0}
-- The voxel name the hand puts down of a material
function M.hand_voxel(material)
	if not material or material == "air" or M.hand.shape == "" or
			(M.material_has_shapes and not M.material_has_shapes(material)) then
		return material
	end
	return material .. ":" .. M.hand.shape
end
-- A shape's param, placed looking along dir onto a face whose normal is n
-- ({x, y, z} toward the placed cell) at height y of the hit: its facing
-- Luanti's dir_to_facedir (the shape's back away from the player), upside
-- down when put against an underside or on the upper half of a side
-- (Luanti's slabs)
function M.shape_param(dir, n, y)
	local f
	if math.abs(dir.x) > math.abs(dir.z) then
		f = dir.x < 0 and 3 or 1
	else
		f = dir.z < 0 and 2 or 0
	end
	local up = false
	if n and n[2] == -1 then
		up = true
	elseif n and n[2] == 0 and y then
		up = y - math.floor(y + 0.5) > 0
	end
	return f + (up and 4 or 0)
end

-- ---- The frames: vanilla's pointed box (extensions/luanti_client's
-- world_pointing.lua), bars on each face just outside what is framed, in
-- the action's colour; one face of it for a placement
local FRAME_W = 1 / 32
local FRAME_OUT = 0.002

-- The bars of a frame round a box of half sides h (faces: its own six, or
-- one: {axis, sign}), as triangles both ways round
local function frame_geometry(cg, h, face, inset, w)
	cg:SetNumGeometries(1)
	cg:BeginGeometry(0, magic.TRIANGLE_LIST)
	w = w or FRAME_W
	local function quad(axis, at, a0, b0, a1, b1)
		local i, j = axis == 1 and 2 or 1, axis == 3 and 2 or 3
		for _, c in ipairs({{a0, b1}, {a1, b1}, {a1, b0}, {a1, b0}, {a0, b0},
				{a0, b1}, {a0, b1}, {a0, b0}, {a1, b0}, {a1, b0}, {a1, b1},
				{a0, b1}}) do
			local p = {}
			p[axis], p[i], p[j] = at, c[1], c[2]
			cg:DefineVertex(magic.Vector3(p[1], p[2], p[3]))
			cg:DefineNormal(magic.Vector3(0, 1, 0))
			-- Unlit's VS reads a UV whatever NOUV says
			cg:DefineTexCoord(magic.Vector2(0, 0))
		end
	end
	for axis = 1, 3 do
		local i, j = axis == 1 and 2 or 1, axis == 3 and 2 or 3
		local hi, hj = h[i] - (inset or 0), h[j] - (inset or 0)
		for _, sign in ipairs({1, -1}) do
			if not face or (face[1] == axis and face[2] == sign) then
				local at = sign * h[axis]
				quad(axis, at, -hi, hj - w, hi, hj)
				quad(axis, at, -hi, -hj, hi, -hj + w)
				quad(axis, at, hi - w, -hj + w, hi, hj - w)
				quad(axis, at, -hi, -hj + w, -hi + w, hj - w)
			end
		end
	end
	cg:Commit()
end

function M.highlighter()
	local h = {pool = {}, used = 0}
	local function take(key, col)
		h.used = h.used + 1
		local f = h.pool[h.used]
		local scene = O.scene or replicate.main_scene
		if not f then
			local node = scene:CreateChild("kit_frame")
			local cg = node:CreateComponent("CustomGeometry")
			local m = magic.Material:new()
			m:SetTechnique(0, magic.cache:GetResource("Technique",
					"Techniques/NoTextureUnlit.xml"))
			f = {node = node, cg = cg, mat = m}
			h.pool[h.used] = f
		end
		f.node.enabled = true
		if f.key ~= key then
			f.key = key
			f.fresh = true
		end
		-- [KIT_HOVER_BOX_NIGHT] unlit, so dimmed with the scene's light
		local k = math.floor(M.light_level() * 100 + 0.5) / 100
		if math.floor(k * 20) ~= M.frames_light then
			M.frames_light = math.floor(k * 20)
			log:info("kit: the frames' light " .. k)
		end
		if f.col ~= tostring(col) .. k then
			f.col = tostring(col) .. k
			f.mat:SetShaderParameter("MatDiffColor",
					magic.Color(col.r * k, col.g * k, col.b * k))
		end
		return f
	end
	local function put(f, geometry)
		if f.fresh then
			f.fresh = false
			geometry(f.cg)
			f.cg:SetMaterial(0, f.mat)
		end
	end
	function h.begin()
		h.used = 0
	end
	-- centre and half: Vector3; rot: a Quaternion or nil. h.w: the bars'
	-- width (nil: vanilla's 1/32 of a cell)
	function h.box(centre, half, rot, col)
		local hx, hy, hz = half.x + FRAME_OUT, half.y + FRAME_OUT,
				half.z + FRAME_OUT
		local w = h.w or FRAME_W
		local f = take(string.format("b%.3f,%.3f,%.3f,%.3f", hx, hy, hz, w), col)
		put(f, function(cg) frame_geometry(cg, {hx, hy, hz}, nil, nil, w) end)
		f.node.position = centre
		f.node.rotation = rot or magic.Quaternion(0, 0, 0)
	end
	-- A voxel's face: the cell and the normal out of it, {x, y, z} each;
	-- [KIT_AIRSHIPS] on a free object, the cell's middle (centre, a Vector3) and
	-- the object's turn (rot) where it is drawn, normal in its frame
	function h.face(cell, normal, col, centre, rot)
		local axis = normal[1] ~= 0 and 1 or normal[2] ~= 0 and 2 or 3
		local sign = (normal[axis] or 1) > 0 and 1 or -1
		local d = 0.5 + FRAME_OUT
		local w = h.w or FRAME_W
		local f = take(string.format("f%d%d,%.3f", axis, sign, w), col)
		-- Inside the dig frame of the same voxel, so both show
		put(f, function(cg) frame_geometry(cg, {d, d, d}, {axis, sign},
				w * 2, w) end)
		f.node.position = centre or magic.Vector3(cell[1], cell[2], cell[3])
		f.node.rotation = rot or magic.Quaternion(0, 0, 0)
	end
	function h.finish()
		for i = h.used + 1, #h.pool do
			h.pool[i].node.enabled = false
		end
	end
	return h
end

-- An entity's frame as drawn: round its look, or a cell's round it
function M.frame_entity(h, id, col)
	local n = P.nodes[id]
	if not n then
		return
	end
	local c, half, rot = look_frame(n)
	if c then
		h.box(c, half, rot, col)
	else
		h.box(n.node.position, magic.Vector3(0.4, 0.4, 0.4), nil, col)
	end
end

local play_hl = nil
local shown_text = nil
function M.show_target(t)
	-- [KIT_DIG_HOLD] hands.lua's held dig follows it
	M.pointed_target = t
	play_hl = play_hl or M.highlighter()
	play_hl.begin()
	local s = "nothing"
	if t then
		local l, r = t.left, t.right
		local parts = {}
		if l and l.kind == "use" then
			M.frame_entity(play_hl, l.id, M.USE)
			parts[#parts + 1] = "use " .. l.id
		elseif l and l.kind == "dig" then
			local d = 0.5
			play_hl.box(l.centre or v3(l.cell), magic.Vector3(d, d, d), l.rot, M.DIG)
			parts[#parts + 1] = "dig " .. table.concat(l.cell, ",") ..
					(l.object and " on " .. l.object or "")
		end
		if r and r.kind == "place" then
			play_hl.face(r.on, r.normal, M.PLACE, r.centre, r.rot)
			parts[#parts + 1] = "place " .. table.concat(r.cell, ",") ..
					(r.object and " on " .. r.object or "")
		end
		if #parts > 0 then
			s = table.concat(parts, ", ")
		end
	end
	play_hl.finish()
	if s ~= shown_text then
		shown_text = s
		log:info("kit: points at " .. s)
	end
end

-- [KIT_AIRSHIPS] A place or dig on a free voxel object (play_target's with
-- `object`): its cell in its frame; a placing carries the hand's shape and tint
function M.object_build(a, voxel)
	local param, tint = 0, 0
	if voxel ~= "air" then
		voxel = M.hand_voxel(voxel)
		param = M.hand.shape ~= "" and (a.param or 0) or 0
		tint = M.hand.tint or 0
	end
	local data = string.format('{"id": %d, "cell": [%d, %d, %d], "voxel": "%s", ' ..
			'"param": %d, "tint": %d}', a.object, a.cell[1], a.cell[2], a.cell[3],
			voxel, param, tint)
	log:info("kit: builds on an object: " .. data)
	buildat.send_packet("kit:obuild", data)
end
-- For a drive: "event kit_obuild <json>" sends it as it is (the server's refusal)
magic.SubscribeToEvent("command_seq:kit_obuild", function(_, data)
	log:info("kit: builds on an object: " .. data:GetString("Param"))
	buildat.send_packet("kit:obuild", data:GetString("Param"))
end)

-- ---- [KIT_AGENT_VISUALS] **An agent's pictures** (Kit's get_view): the
-- server asks a client of the agent's own account, or
-- ([KIT_AGENT_NEXT_1]) the server's camera, "kit:view" {id, camera,
-- budget, views: [{w, h, pos, look_at or yaw and pitch, ortho, far}]}, to
-- draw each view with a camera of its own -- at pos, or where the view the
-- window draws is (its fov, its orthographic) -- into a w x h texture of
-- its own (a RenderSurface: the window's view, camera and render path are
-- left as they are), read back as a PNG and sent "kit:view" "<id> <k>
-- <settled>\n<PNG>", or "<id> <k> 1\n<why not>". The scene is this
-- client's, as far as it has loaded it. The user is told by a notice. The
-- server's camera (camera true) meshes round each view first and waits
-- for its chunks to come and be meshed, budget ms at most for them all.
local VIEW = {}
function VIEW.answer(id, k, settled, body)
	buildat.send_packet("kit:view", id .. " " .. (k - 1) .. " " ..
			(settled and 1 or 0) .. "\n" .. body)
end
-- The next view of the request set up, or the request done
function VIEW.next()
	local q = VIEW.q
	VIEW.k = VIEW.k + 1
	local k = VIEW.k
	local v = q.views[k]
	if not v then
		VIEW.q, VIEW.voxel_camera = nil, nil
		-- ([KIT_3D_GAINS_1] (4z38) the looks culled again)
		if VIEW.reach then
			M.set_look_reach(VIEW.reach)
			VIEW.reach = nil
		end
		return
	end
	local function skip(why)
		log:info("kit: no picture for the agent: " .. why)
		VIEW.answer(q.id, k, true, why)
		return VIEW.next()
	end
	local w, h = type(v) == "table" and tonumber(v.w) or 0,
			type(v) == "table" and tonumber(v.h) or 0
	if w < 16 or h < 16 or w > 1024 or h > 768 then
		return skip("the size must be from 16x16 to 1024x768")
	end
	local main = magic.renderer:GetViewport(0)
	local from, cam0
	if O.camera then
		if M.view_camera then
			from, cam0 = M.view_camera()
		else
			from, cam0 = O.camera, O.camera:GetComponent("Camera")
		end
	end
	local scene = O.scene or replicate.main_scene
	if not (main and from and cam0 and scene) then
		return skip("this client draws no view")
	end
	local node = scene:CreateChild("kit: agent's camera")
	local cam = node:CreateComponent("Camera")
	local play = O.camera and O.camera:GetComponent("Camera") or cam0
	local function vec(t)
		return type(t) == "table" and tonumber(t[1]) and tonumber(t[2]) and
				tonumber(t[3]) and magic.Vector3(t[1], t[2], t[3])
	end
	local pos = vec(v.pos)
	-- [KIT_3D_GAINS_1] (4z38) a pose (a map from high up, far) sees every look, the
	-- fog's cull lifted till the request is done
	if pos and M.look_reach then
		VIEW.reach = M.look_reach
		M.set_look_reach(nil)
	end
	if pos then
		-- A pose: the play camera's lens, or an orthographic one (a map)
		cam.fov, cam.nearClip, cam.farClip = play.fov, play.nearClip, play.farClip
		if tonumber(v.ortho) then
			cam.orthographic, cam.orthoSize = true, tonumber(v.ortho)
		end
		if tonumber(v.far) then
			cam.farClip = math.max(play.farClip, tonumber(v.far))
		end
		node.position = pos
		if vec(v.look_at) then
			node:LookAt(vec(v.look_at))
		else
			node.rotation = magic.Quaternion(tonumber(v.pitch) or 0,
					tonumber(v.yaw) or 0, 0)
		end
	else
		cam.fov, cam.nearClip, cam.farClip = cam0.fov, cam0.nearClip, cam0.farClip
		cam.orthographic, cam.orthoSize = cam0.orthographic, cam0.orthoSize
		cam.zoom = cam0.zoom
		-- simplified: its direction, not its roll (no camera here rolls)
		node.position = from.worldPosition
		node.direction = from.worldDirection
	end
	local tex = magic.Texture2D:new()
	tex:SetNumLevels(1)
	if not tex:SetSize(w, h, magic.Graphics.GetRGBAFormat(),
			magic.TEXTURE_RENDERTARGET) then
		node:Remove()
		return skip("no render target of " .. w .. "x" .. h)
	end
	local vp = magic.Viewport:new(scene, cam)
	vp.renderPath = main.renderPath
	local surface = tex:GetRenderSurface()
	surface:SetViewport(0, vp)
	surface.updateMode = magic.SURFACE_MANUALUPDATE
	-- The server's camera: the chunks round the view meshed first.
	-- ([KIT_PLAY_PICTURE_UI]) Its own view is the player's screen: the UI
	-- laid out at the picture's size from now (a frame at least before it
	-- is drawn) and drawn over it
	if q.camera and pos then
		require("buildat/module/voxelworld").set_camera(node)
	elseif q.camera then
		magic.picture_ui(tex)
	end
	-- ([KIT_SIDE_SCENERY] (8) a pose's camera is the parallax layers' while
	-- it draws: pose, cam, aspect)
	VIEW.job = {node = node, tex = tex, vp = vp, surface = surface,
			frames = 0, t = buildat.get_time_us(), pose = pos ~= nil, cam = cam,
			aspect = w / h, hidden = q.camera and true or false,
			at = q.camera and tonumber(v.at) or nil}
	-- (the layers placed for it now: a picture queued here is drawn this
	-- frame, maybe after their Update)
	M.parallax_tick()
	if not q.camera then
		VIEW.job.drawn = 0
		surface:QueueUpdate()
	end
end
-- The renderer's views of this frame set up: a picture queued before is
-- drawn in this frame (kit/parallax's pose camera off from the next)
magic.SubscribeToEvent("PostRenderUpdate", function()
	local j = VIEW.job
	if j and j.drawn == 0 then
		j.drawn_in = true
	end
end)
buildat.sub_packet("kit:view", function(data)
	local q = network.parse_json(data)
	if type(q) ~= "table" or type(q.id) ~= "string" or #q.id > 64 then
		return
	end
	if type(q.views) ~= "table" or #q.views < 1 or #q.views > 8 then
		return VIEW.answer(q.id, 1, true, "no views asked")
	end
	if VIEW.q then
		for k = 1, #q.views do
			VIEW.answer(q.id, k, true, "a picture is being taken")
		end
		return
	end
	VIEW.q, VIEW.k = q, 0
	VIEW.t0, VIEW.budget = buildat.get_time_us(), (tonumber(q.budget) or 0) * 1000
	if q.camera then
		VIEW.voxel_camera = require("buildat/module/voxelworld").get_camera()
		log:info(string.format("kit: the server's camera draws %d view(s)",
				#q.views))
	else
		local v = q.views[1]
		log:info(string.format("kit: Your agent took a picture (%s, %s)",
				#q.views == 1 and tostring(v.w) .. "x" .. tostring(v.h) or
				#q.views .. " views", v.pos and "its pose" or "this view"))
		ui_utils.show_notification("Your agent took a picture", 3)
	end
	VIEW.next()
end)
-- The server's camera's view has its chunks: none came lately and none
-- is waiting for its mesh (the first view waits 0.4 s for them to start
-- coming); out of budget it is drawn as it is. ([KIT_PLAY_PICTURE_UI]) A
-- view `at` ms after the request (play_input's picture steps, at 0: its
-- body's surroundings are loaded) is drawn then
function VIEW.settled(j)
	local now = buildat.get_time_us()
	if j.at then
		return now - VIEW.t0 >= j.at * 1000, true
	end
	if now - VIEW.t0 > VIEW.budget then
		return true, false
	end
	if now - j.t < (VIEW.k == 1 and 400000 or 100000) then
		return false
	end
	local a = buildat.last_arrival()
	if a and a.kind == "chunk" and now - a.t < 300000 then
		return false
	end
	return (buildat.idle_pending and buildat.idle_pending() or "") == "", true
end
-- Read the frame after it was drawn (the frame it was queued in draws it)
magic.SubscribeToEvent("Update", function()
	local j = VIEW.job
	if not j then
		return
	end
	j.frames = j.frames + 1
	if not j.drawn then
		local done, settled = VIEW.settled(j)
		if j.frames < 2 or not done then
			return
		end
		j.drawn, j.settled = j.frames, settled
		j.surface:QueueUpdate()
		return
	end
	if j.frames < j.drawn + 2 then
		return
	end
	VIEW.job = nil
	local png, why = magic.texture_png(j.tex)
	-- (voxelworld's camera back before the node goes)
	if VIEW.q.camera then
		require("buildat/module/voxelworld").set_camera(VIEW.voxel_camera)
	end
	j.node:Remove()
	local id, k = VIEW.q.id, VIEW.k
	if not png then
		log:info("kit: no picture for the agent: " .. tostring(why))
		VIEW.answer(id, k, true, tostring(why))
	else
		log:info("kit: the picture sent, " .. #png .. " bytes" ..
				(j.settled == false and " (before its loading settled)" or ""))
		VIEW.answer(id, k, j.settled ~= false, png)
	end
	VIEW.next()
end)
-- [KIT_AGENT_NEXT_1] 3a: the server's camera's play_input ran its
-- commands ("event kit_play_done <id>", the last of them)
magic.SubscribeToEvent("command_seq:kit_play_done", function(_, data)
	buildat.send_packet("kit:play_done", data:GetString("Param"))
end)

-- ---- [KIT_ENVIRONMENT] The environment, the lighting, the sky and the
-- weather: environment.lua
do
	local ok, err, install = buildat.run_script_file("kit/environment.lua")
	assert(ok and type(install) == "function", "kit: environment.lua: " ..
			tostring(err))
	install({M = M, O = O, log = log})
end

-- ---- [KIT_ENT_PERF_2] Looks drawn merged: merge.lua
do
	local ok, err, install = buildat.run_script_file("kit/merge.lua")
	assert(ok and type(install) == "function", "kit: merge.lua: " ..
			tostring(err))
	install({M = M, P = P, log = log, parent_id = parent_id})
end

-- ---- The keys as named actions: input.lua ([KIT_INPUT_ACTIONS])
do
	local ok, err, install = buildat.run_script_file("kit/input.lua")
	assert(ok and type(install) == "function", "kit: input.lua: " ..
			tostring(err))
	install({M = M, E = E, O = O, log = log})
end

-- ---- [KIT_PLAYTEST_REC] A builder's playtest recorded: rec.lua
do
	local ok, err, install = buildat.run_script_file("kit/rec.lua")
	assert(ok and type(install) == "function", "kit: rec.lua: " ..
			tostring(err))
	install({M = M, E = E, O = O, log = log, STYLE = STYLE, text = text,
		row = row, button = button})
end

-- ---- [KIT_SOUNDS] The project's sounds, played: sounds.lua
-- (before the editor: its Sounds tab's)
do
	local ok, err, install = buildat.run_script_file("kit/sounds.lua")
	assert(ok and type(install) == "function", "kit: sounds.lua: " ..
			tostring(err))
	install({M = M, O = O, log = log})
end

-- ---- [MUSIC_SYNTH] kit/music, played: music.lua
do
	local ok, err, install = buildat.run_script_file("kit/music.lua")
	assert(ok and type(install) == "function", "kit: music.lua: " ..
			tostring(err))
	install({log = log, M = M})
end

-- ---- The editor: editor.lua, given what it shares with play
do
	local ok, err, install = buildat.run_script_file("kit/editor.lua")
	assert(ok and type(install) == "function", "kit: editor.lua: " ..
			tostring(err))
	install({M = M, E = E, O = O, P = P, send = send, log = log,
		color = color, row = row, text = text, label = label,
		button = button, edit = edit, v3 = v3, WARN = WARN, DIM = DIM,
		STYLE = STYLE, value = value, look_frame = look_frame,
		entity_t = entity_t, unit = unit,
		-- What an entity's name stands behind wherever it is shown
		ENTITY = "◆ "})
end

-- ---- The players' controls: controls.lua ([KIT] stage 4h)
do
	local ok, err, install = buildat.run_script_file("kit/controls.lua")
	assert(ok and type(install) == "function", "kit: controls.lua: " ..
			tostring(err))
	install({M = M, E = E, O = O, P = P, log = log, STYLE = STYLE,
		value = value, material = material})
end

-- ---- [KIT_RTS] The rts camera, the selection and the orders: rts.lua
do
	local ok, err, install = buildat.run_script_file("kit/rts.lua")
	assert(ok and type(install) == "function", "kit: rts.lua: " ..
			tostring(err))
	install({M = M, E = E, O = O, P = P, log = log, material = material,
		STYLE = STYLE, text = text, button = button})
end

-- ---- [KIT_TOOLS_1] The hands, the hotbar, the hit: hands.lua
do
	local ok, err, install = buildat.run_script_file("kit/hands.lua")
	assert(ok and type(install) == "function", "kit: hands.lua: " ..
			tostring(err))
	install({M = M, E = E, O = O, P = P, log = log, entity_t = entity_t,
		material = material, wedge = wedge, voxel_def = voxel_def,
		voxel_mesh = voxel_mesh, color = color})
end

-- ---- [KIT_PLAYER_MODEL] The players' bodies: players.lua (after
-- hands.lua: the held item's look, the swings)
do
	local ok, err, install = buildat.run_script_file("kit/players.lua")
	assert(ok and type(install) == "function", "kit: players.lua: " ..
			tostring(err))
	install({M = M, O = O, P = P, log = log, color = color})
end

-- ---- [KIT_PARTICLES] Effects: effects.lua (after players.lua: a hit's tint)
do
	local ok, err, install = buildat.run_script_file("kit/effects.lua")
	assert(ok and type(install) == "function", "kit: effects.lua: " ..
			tostring(err))
	install({M = M, O = O, P = P, log = log, color = color,
		voxel_def = voxel_def})
end

-- ---- [KIT_UI_COMPONENTS] UI as screen-space components: ui.lua
do
	local ok, err, install = buildat.run_script_file("kit/ui.lua")
	assert(ok and type(install) == "function", "kit: ui.lua: " ..
			tostring(err))
	install({M = M, E = E, O = O, P = P, log = log, STYLE = STYLE,
		send = send})
end

-- ---- [KIT_INVENTORY_PLAY] [KIT_HUD] The slots, the hotbar, the health
-- bar, the inventory screen and chests: inventory.lua (after ui.lua: its
-- ui_at over the UI components')
do
	local ok, err, install = buildat.run_script_file("kit/inventory.lua")
	assert(ok and type(install) == "function", "kit: inventory.lua: " ..
			tostring(err))
	install({M = M, E = E, O = O, P = P, log = log, voxel_def = voxel_def,
		color = color})
end

-- ---- [KIT_SIDE_SCENERY] (8) **kit/parallax**: the looks under a layer
-- (M.parallax_layer) drawn offset by the camera's travel from the layer's
-- place, 1 - follow of it along x and 1 - follow_y of it up ([KIT_TOP_DOWN] (5)
-- along z with kit/controls' plane horizontal: a top-down view's up), so a place
-- authored is where it is drawn with the camera at the layer's x; with
-- `repeat` > 0 copies of the look every repeat along x, enough to cover
-- the view at its depth. The camera: a get_view pose's while one is being
-- drawn, else the play camera (play, spectating, the server's camera); in
-- edit mode none: drawn where authored (the editor's note says so). An
-- Update of its own subscribed after controls.lua's, which places the
-- camera of this frame.
-- simplified: a copy is the look cloned (its Lua-made materials set again,
-- its collision bodies left out), made again as the look is rebuilt, its
-- state flips, it is hidden or shown or its text changes; a client part's
-- change to the look in between shows on the original alone. 32 copies an
-- entity at most, round the camera. Nested layers: the nearest one alone.
-- A get_view pose in a builder's own window: its camera for the frame its
-- picture is drawn in alone (queued, drawn in the frame whose
-- PostRenderUpdate comes after: VIEW's drawn_in), the window's again after
-- it (the server's camera's hidden window: until its picture is read).
-- simplified: that one frame shows the pose's offsets in the builder's
-- window too (Urho3D draws a frame's views from one scene state; moving
-- the looks between the views would need each view's octree and
-- transforms updated again)
local PAR = {said = {}, max = 32}
local function par_camera()
	local j = VIEW.job
	if j and j.pose and (j.hidden or not j.drawn_in) then
		return j.node, j.cam, j.aspect
	end
	if E.editing or not O.camera then
		return nil
	end
	return O.camera, O.camera:GetComponent("Camera")
end
-- How far the view reaches either side of its middle at p's depth (m)
local function par_half_width(cn, cam, p, aspect)
	local a = aspect or cam.aspectRatio
	a = (a and a > 0.1) and a or 2
	local zoom = math.max(1e-3, cam.zoom)
	if cam.orthographic then
		return cam.orthoSize / 2 * a / zoom * 1.1 + 1
	end
	local d, c = cn.worldDirection, cn.worldPosition
	local depth = math.max(0, (p.x - c.x) * d.x + (p.y - c.y) * d.y +
			(p.z - c.z) * d.z)
	return depth * math.tan(math.rad(cam.fov) / 2) * a / zoom * 1.1 + 1
end
-- A Lua-made material is no attribute: a clone has none, so they are set
-- again from the original's, down its tree
local function par_materials(a, b)
	local sa, sb = a:GetComponent("StaticModel"), b:GetComponent("StaticModel")
	if sa and sb then
		sb.material = sa.material
	end
	local ca, cb = a:GetComponent("CustomGeometry"), b:GetComponent("CustomGeometry")
	if ca and cb then
		for i = 0, 63 do
			local m = ca:GetMaterial(i)
			if not m then
				break
			end
			cb:SetMaterial(i, m)
		end
	end
	for i = 0, math.min(a:GetNumChildren(), b:GetNumChildren()) - 1 do
		par_materials(a:GetChild(i), b:GetChild(i))
	end
end
local function par_copies(n, want)
	local key = tostring(n.on) .. "|" .. tostring(n.hidden) .. "|" ..
			tostring(n.last_text)
	local cs = n.par_copies or {nodes = {}}
	local stale = cs.src ~= n.look or cs.key ~= key
	-- (taken away, not disabled: a node's enabled is not its children's)
	while #cs.nodes > (stale and 0 or want) do
		cs.nodes[#cs.nodes]:Remove()
		cs.nodes[#cs.nodes] = nil
	end
	cs.src, cs.key = n.look, key
	n.par_copies = want > 0 and cs or nil
	while #cs.nodes < want do
		local c = n.look:Clone()
		local s = c:GetChild("Solid")
		if s then
			s:Remove()
		end
		par_materials(n.look, c)
		cs.nodes[#cs.nodes + 1] = c
	end
	return cs.nodes
end
-- [KIT_3D_GAINS_1] (4z38) A far layer's look ({far = true}): each of its drawables'
-- materials (its own, made for it: changed in place, its copies share them) on
-- KitFar*.xml, behind the world as the sky is, its render order past the sky's (128),
-- the farther from the layer first (they write no depth: the nearer ridge drawn over
-- the farther); no draw distance, no shadow. Out from under it (or far off): the look
-- built again
local FAR = {}
local function far_look(n, order)
	FAR.plain = FAR.plain or magic.cache:GetResource("Technique", "kit/KitFar.xml")
	FAR.tex = FAR.tex or magic.cache:GetResource("Technique", "kit/KitFarTex.xml")
	local function walk(node)
		local sm = node:GetComponent("StaticModel")
		if sm then
			local m = sm.material
			if m then
				m:SetTechnique(0, FAR.plain)
				m.renderOrder = order
			end
			sm.castShadows, sm.drawDistance = false, 0
		end
		local cg = node:GetComponent("CustomGeometry")
		if cg then
			for i = 0, 63 do
				local m = cg:GetMaterial(i)
				if not m then
					break
				end
				m:SetTechnique(0, n.worn and FAR.tex or FAR.plain)
				m.renderOrder = order
			end
			cg.castShadows, cg.drawDistance = false, 0
		end
		for i = 0, node:GetNumChildren() - 1 do
			walk(node:GetChild(i))
		end
	end
	walk(n.look)
	for _, c in ipairs(n.par_copies and n.par_copies.nodes or {}) do
		walk(c)
	end
	n.far_look = n.look
end
local function par_tick()
	-- (none drawn offset is the common case: no layer, no walk)
	if not par_any and not PAR.drawn then
		return
	end
	PAR.drawn = par_any
	local cn, cam, aspect = par_camera()
	local c = cn and cn.worldPosition
	-- (for a check: the frames drawn with a pose's camera placing the layers)
	local j = VIEW.job
	local pose = j and cn == j.node and j or nil
	if pose ~= PAR.pose then
		log:info("kit: parallax: a get_view pose's camera " .. (pose and "on" or
				"off after " .. PAR.pose_frames .. " frames drawn with it"))
		PAR.pose, PAR.pose_frames = pose, 0
	end
	for id, n in pairs(P.nodes) do
		local L = cn and n.look and n.at and M.parallax_layer(id, n)
		if L then
			local s = L.show.parallax
			local f = math.max(0, math.min(1, tonumber(s.follow) or 0.5))
			local fy = math.max(0, math.min(1, tonumber(s.follow_y) or 1))
			local R = math.max(0, tonumber(s["repeat"]) or 0)
			local lp = L.node.position
			-- ([KIT_TOP_DOWN] (5) follow_y along z in a level plane)
			local lv = M.level_plane()
			local RZ = lv and math.max(0, tonumber(s.repeat_z) or 0) or 0
			local at = n.at + magic.Vector3((1 - f) * (c.x - lp.x),
					lv and 0 or (1 - fy) * (c.y - lp.y), lv and (1 - fy) * (c.z - lp.z) or 0)
			local k0, k1, m0, m1 = 0, 0, 0, 0
			if R > 0 or RZ > 0 then
				-- (its look's reach from its place: the box's middle and half
				-- its diagonal)
				local b = n.box or {size = {1, 1, 1}, off = {0, 0, 0}}
				local r = v3(b.off):Length() + v3(b.size):Length() / 2
				local hw = par_half_width(cn, cam, at, aspect) + r
				-- ([KIT_3D_GAINS_1] (4z38) repeat_z: a grid, PAR.max in all; along z
				-- as far as along x. simplified: the view's reach either way)
				local function span(cv, av, step, most)
					if step <= 0 then
						return 0, 0
					end
					local a = math.ceil((cv - hw - av) / step)
					local b2 = math.max(a, math.floor((cv + hw - av) / step))
					if b2 - a + 1 > most then
						local mid = math.floor((cv - av) / step + 0.5)
						a, b2 = mid - math.floor(most / 2) + 1, mid + math.floor(most / 2)
						if b2 - a + 1 > most then
							b2 = a + most - 1
						end
					end
					return a, b2
				end
				local mz = RZ > 0 and math.floor(math.sqrt(PAR.max)) or 1
				k0, k1 = span(c.x, at.x, R, RZ > 0 and math.floor(PAR.max / mz) or PAR.max)
				m0, m1 = span(c.z, at.z, RZ, mz)
			end
			-- [KIT_3D_GAINS_1] (4z38) far: behind the world (far_look)
			local far = s.far == true
			if far and n.far_look ~= n.look then
				local dx, dz = n.at.x - lp.x, n.at.z - lp.z
				far_look(n, 250 - math.min(100, math.floor(math.sqrt(dx * dx + dz * dz) / 10)))
				log:info(string.format("kit: entity %d under parallax layer %d drawn far " ..
						"(behind the world)", id, L.id))
			end
			-- (never met: its static bodies not moved about in the physics
			-- world either; the look built again once it is out from under)
			if n.solid then
				n.solid:Remove()
				n.solid, n.par_solid = nil, true
			end
			local nk = k1 - k0 + 1
			n.look.position = at + magic.Vector3(k0 * R, 0, m0 * RZ)
			local q = n.look.rotation
			for j, copy in ipairs(par_copies(n, nk * (m1 - m0 + 1) - 1)) do
				copy.position = at + magic.Vector3((k0 + j % nk) * R, 0,
						(m0 + math.floor(j / nk)) * RZ)
				copy.rotation = q
			end
			n.par = true
			local said = L.id .. " " .. f .. " " .. fy .. " " .. R .. " " .. RZ
			if PAR.said[id] ~= said then
				PAR.said[id] = said
				log:info(string.format("kit: entity %d under parallax layer %d " ..
						"(follow %g, follow_y %g, repeat %g, repeat_z %g)", id, L.id, f,
						fy, R, RZ))
			end
			if not far and n.far_look then
				drop_look(n)
				n.par, PAR.said[id] = nil, nil
			end
		elseif n.par then
			-- (the editor's, or out from under a layer: where authored)
			n.look.position = n.at
			par_copies(n, 0)
			n.par = nil
			if n.par_solid or n.far_look then
				drop_look(n)
			end
			if PAR.said[id] then
				PAR.said[id] = nil
				log:info("kit: entity " .. id .. " drawn where authored" ..
						(cn and " (under no parallax layer)" or " (edit mode)"))
			end
		end
	end
end
magic.SubscribeToEvent("Update", par_tick)
magic.SubscribeToEvent("PostRenderUpdate", function()
	if PAR.pose then
		PAR.pose_frames = PAR.pose_frames + 1
	end
end)
M.parallax_tick = par_tick
-- For a drive: "event kit_parallax <id>..." logs each one's look as drawn,
-- where it is authored, its copies' x and the camera's place
magic.SubscribeToEvent("command_seq:kit_parallax", function(_, data)
	local cn = par_camera()
	local c = cn and cn.worldPosition
	for w in data:GetString("Param"):gmatch("%d+") do
		local id = tonumber(w)
		local n = P.nodes[id]
		if not (n and n.look and n.at) then
			log:info("kit: parallax: entity " .. id .. " has no look drawn")
		else
			local p, a, xs = n.look.position, n.at, {}
			for _, copy in ipairs(n.par_copies and n.par_copies.nodes or {}) do
				xs[#xs + 1] = string.format("%.2f", copy.position.x)
			end
			log:info(string.format("kit: parallax: entity %d drawn at %.3f,%.3f," ..
					"%.3f, authored %.3f,%.3f,%.3f, %d copies%s, the camera %s", id,
					p.x, p.y, p.z, a.x, a.y, a.z, #xs, #xs > 0 and " at x " ..
					table.concat(xs, " ") or "", c and string.format("%.3f,%.3f,%.3f",
					c.x, c.y, c.z) or "none (where authored)"))
		end
	end
end)

-- [KIT_MOVE_DRAW] kit.material(hex, {unlit = bool, texture = name}): a plain
-- material of the colour "#rrggbb" (lit; unlit: its own colour whatever the
-- light), or with a texture (a resource name: a put_texture's "kit/up/..."), drawn
-- as it is, pixels kept sharp; a texture that does not load here is the plain
-- colour. One material for the same arguments, shared by every part (put on as
-- many models as wanted; changing it changes them all).
-- simplified: 1024 kept at most, any more made anew each call
local MATS, MATS_N = {}, 0
function M.material(hex, opts)
	local c = color(hex)
	if not c then
		error("kit.material: a colour \"#rrggbb\", not " .. tostring(hex), 2)
	end
	if opts ~= nil and type(opts) ~= "table" then
		error("kit.material: options are {unlit = bool, texture = name}", 2)
	end
	local unlit = opts and opts.unlit == true
	local tex_name = opts and type(opts.texture) == "string" and opts.texture ~= "" and
			opts.texture or nil
	local key = hex:lower() .. (unlit and " u" or "") .. (tex_name and " " .. tex_name or "")
	if MATS[key] then
		return MATS[key]
	end
	local tex = tex_name and magic.cache:GetResource("Texture2D", tex_name)
	local m = magic.Material:new()
	if tex then
		tex.filterMode = magic.FILTER_NEAREST
		m:SetTechnique(0, magic.cache:GetResource("Technique", unlit and
				"Techniques/DiffUnlit.xml" or "Techniques/Diff.xml"))
		m:SetTexture(magic.TU_DIFFUSE, tex)
	else
		if tex_name then
			log:info("kit: kit.material: no texture " .. tex_name .. ", the colour " .. hex)
		end
		m:SetTechnique(0, magic.cache:GetResource("Technique", unlit and
				"Techniques/NoTextureUnlit.xml" or "Techniques/NoTexture.xml"))
		m:SetShaderParameter("MatDiffColor", c)
	end
	if MATS_N < 1024 then
		MATS[key], MATS_N = m, MATS_N + 1
	end
	return m
end

-- [KIT_API_1] (item 3) What require("buildat/module/kit") gives: the 16
-- names of Kit API 1 for client parts and a movement's draw, and
-- `internal`, this whole module, outside the promise. The apps that host
-- Kit (Workbench, sample_kit, skeldat) take .internal; a game's part that
-- does may break in any release, and publishing it warns (kit.cpp's
-- EXPERIMENTAL). Any other name is nil here.
-- simplified: a plain table, no facade: a part runs in Kit's own
-- environment (buildat.eval), so the hatch is only marked, not closed; an
-- environment of a part's own is the upgrade (client/api.lua's eval owner
-- gate, security code)
local API = {internal = M}
for _, k in ipairs({"shared", "pointed", "use", "body_state", "body_pos",
		"seated", "shake", "effect", "mark", "clear_marks", "ui_keys",
		"press_action", "key_down", "key_name", "key_text", "material"}) do
	API[k] = assert(M[k], "kit: no " .. k)
end
return API
-- vim: set noet ts=4 sw=4:
