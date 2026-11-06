-- Buildat: builtin/kit/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT] Kit on the client: play (below: every client's, edit rights or
-- not) and the editor (editor.lua, [KIT] stage 3, its UX floorplanner's
-- since stage 4e2; builtin/kit/api.h says what the server takes). An app
-- hosting Kit turns the editor on with
--   local kit = require("buildat/module/kit")
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
	magic.SubscribeToEvent(b, "Released", function()
		fn()
	end)
	return b, t
end

local function edit(parent, value, on_text)
	local e = parent:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minWidth = 120
	e.minHeight = 24
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
-- edge), a collision shape (a static body in the scene's physics) while
-- solid, its state `text` over it; a type's `hud = key` puts that state on
-- the screen.
-- **A type's client part** ([KIT] stage 4d): <name>.client.lua beside the
-- type, sent at join, run as the client's own Lua is (this module's
-- sandbox); it returns a table of handlers, each given `e`, the entity as
-- this client has it:
--   on_add(e), on_state(e, key) (a shared state changed: e.state[key]),
--   on_update(e, dt) (each frame), on_use(e) (this player used it, before
--   the server hears of it), on_remove(e)
--   e.id, e.node (its replicated node), e.look, e.hinge, e.body (its look's
--   nodes: the body turns with the hinge), e.swing (a swing's open angle:
--   -90, or 90 when.mirror), e.state (the server's), e.mine
--   (this player's own entity), e:shown(key) (the state as drawn),
--   e:near(d) (this player's entity within d of it),
--   e:predict(key, value, seconds) (drawn so at once, until the server's
--   value changes or the seconds, 1, pass), e:log(text)
-- kit.pointed(origin, dir, reach) -> the id of the entity nearest the ray
-- (its look's box, or near its cell), kit.use(id) uses it: the server
-- checks range and whether it is usable. The player's inventory (c:add,
-- c:take...) is a line on the screen. The Stop notice: "Your builds while
-- playing were discarded." (who built how many when others did too), and
-- for a builder "Keep them" (the tools' panel has it until the next Play).
-- For a drive (doc/client_commands.txt's event): "event kit_edit <json>"
-- sends an edit as the editor would, "event kit_use <id>" a use.
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
	local server = parse(n.node:GetVar("kit:" .. key))
	local p = n.predicted and n.predicted[key]
	if p then
		if buildat.get_time_us() < p.till and shown(server) == p.was then
			return p.value
		end
		n.predicted[key] = nil
	end
	return server
end

local function drop_look(n)
	if n.look then
		n.look:Remove()
	end
	n.wear_wanted, n.ghost, n.hidden = nil, nil, nil
	n.look, n.hinge, n.body, n.mat, n.text, n.solid, n.box, n.on = nil, nil,
			nil, nil, nil, nil, nil, nil
end

-- A client part's handler, protected: one that fails is left off for
-- that entity, logged
local function call(n, part, fn, ...)
	local f = part[fn]
	if type(f) ~= "function" or (n.failed and n.failed[part]) then
		return
	end
	local ok, err = pcall(f, n.e, ...)
	if not ok then
		n.failed = n.failed or {}
		n.failed[part] = true
		log:warning("kit: entity " .. tostring(n.e.id) .. "'s client part " ..
				fn .. ": " .. tostring(err))
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

replicate.sub_sync_node_added({}, function(node)
	local id = tonumber(node:GetName():match("^kit:(%d+)$"))
	if id then
		P.nodes[id] = {node = node}
	end
end)
replicate.sub_sync_node_removed(function(node, node_id)
	for id, n in pairs(P.nodes) do
		if n.node:GetID() == node_id then
			if n.added then
				for _, part in ipairs(parts_of(n)) do
					call(n, part, "on_remove")
				end
			end
			drop_look(n)
			P.nodes[id] = nil
		end
	end
end)

-- A look's box as it is drawn now (on: its state is true): its sides, its
-- middle from the entity, whether it is solid and its colour. A swing's
-- the box it is turned to (a quarter round its -x edge, towards +z)
local function look_box(look, on)
	local size, off = {}, {0, 0, 0}
	if type(look.size) == "table" then
		for i = 1, 3 do
			size[i] = math.max(0.02, math.min(64, tonumber(look.size[i]) or 1))
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
			-- Its bottom kept
			if i == 2 then
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
-- at its back
local function wedge(node)
	local cg = node:CreateComponent("CustomGeometry")
	cg:SetNumGeometries(1)
	cg:BeginGeometry(0, magic.TRIANGLE_LIST)
	local a, b = -0.5, 0.5
	local function tri(p1, p2, p3, nrm)
		for _, p in ipairs({p1, p2, p3}) do
			cg:DefineVertex(magic.Vector3(p[1], p[2], p[3]))
			cg:DefineNormal(nrm)
			cg:DefineTexCoord(magic.Vector2(0, 0))
		end
	end
	local slope = magic.Vector3(0, 1, -1):Normalized()
	-- The slope, the bottom, the back, the two sides
	tri({a, a, a}, {a, b, b}, {b, b, b}, slope)
	tri({a, a, a}, {b, b, b}, {b, a, a}, slope)
	tri({a, a, a}, {b, a, a}, {b, a, b}, magic.Vector3(0, -1, 0))
	tri({a, a, a}, {b, a, b}, {a, a, b}, magic.Vector3(0, -1, 0))
	tri({a, a, b}, {b, a, b}, {b, b, b}, magic.Vector3(0, 0, 1))
	tri({a, a, b}, {b, b, b}, {a, b, b}, magic.Vector3(0, 0, 1))
	tri({a, a, a}, {a, a, b}, {a, b, b}, magic.Vector3(-1, 0, 0))
	tri({b, a, a}, {b, b, b}, {b, a, b}, magic.Vector3(1, 0, 0))
	cg:Commit()
	return cg
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

-- [KIT_LOOK_MATERIAL] A unit box or wedge (wedge's) wearing a voxel
-- material's tiles (+y, -y, +x, -x, +z, -z, the voxels' order; a wedge's
-- slope its +y, its back +z), a texture a metre of its sides `size` as the
-- voxels wear theirs (a tile of a texture of several stretched over its
-- face); nil when the material has no textures here
local face_textures = {}
local function voxel_mesh(node, def, size, shape)
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
					s = seg.select_segment}
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
	local cg = node:CreateComponent("CustomGeometry")
	cg:SetNumGeometries(#faces)
	local mats = {}
	for g, f in ipairs(faces) do
		local tile, nr, ext, vs = f[1], f[2], f[3], f[4]
		local t = tex[tile] or tex[1] or select(2, next(tex))
		local nx, ny = t.n and t.n.x or 1, t.n and t.n.y or 1
		local nv = magic.Vector3(nr[1], nr[2], nr[3]):Normalized()
		cg:BeginGeometry(g - 1, magic.TRIANGLE_LIST)
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
				cg:DefineVertex(magic.Vector3(c[1], c[2], c[3]))
				cg:DefineNormal(nv)
				if nx > 1 or ny > 1 then
					cg:DefineTexCoord(magic.Vector2(
							(t.s.x + c[4] / ext[1]) / nx,
							(t.s.y + c[5] / ext[2]) / ny))
				else
					cg:DefineTexCoord(magic.Vector2(c[4], c[5]))
				end
			end
		end
		local m = magic.Material:new()
		m:SetTechnique(0, magic.cache:GetResource("Technique", look_tech))
		m:SetTexture(magic.TU_DIFFUSE, t.t)
		m:SetShaderParameter("MatDiffColor", tint0)
		m:SetShaderParameter("MatSpecColor", magic.Color(0.05, 0.05, 0.05))
		cg:SetMaterial(g - 1, m)
		mats[g] = m
	end
	cg:Commit()
	cg.castShadows = true
	return cg, mats
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
		-- its sides the shut look's
		local wants = look.shape ~= "sphere" and type(look.voxel) ==
				"string" and look.voxel ~= "" and look.voxel or nil
		local def = wants and voxel_def(wants)
		local worn = def and voxel_mesh(n.body, def,
				look_box(look, false).size, look.shape)
		if wants then
			log:info("kit: entity " .. id .. (worn and " wears " or
					" wears no ") .. wants)
		end
		-- Not in the registry yet: drawn again once it is
		n.wear_wanted = wants and not def and wants or nil
		if worn then
			-- (drawn)
		elseif look.shape == "wedge" then
			wedge(n.body):SetMaterial(0, n.mat)
		else
			local m = n.body:CreateComponent("StaticModel")
			m.model = magic.cache:GetResource("Model", "Models/" ..
					(look.shape == "sphere" and "Sphere" or "Box") .. ".mdl")
			m.material = n.mat
			m.castShadows = true
		end
		if look.text then
			-- In the hinge, so it goes with a slide ([KIT] stage 4l)
			local l = n.hinge:CreateChild("Text")
			local t = l:CreateComponent("Text3D")
			-- [KIT] stage 4l: text_facing "flat" (on the box's front, its -z
			-- side, as the entity faces) or "camera" (turning round y),
			-- text_size cells high, text_color; none: over it, a label of a
			-- fixed size on the screen
			local facing = look.text_facing
			if facing ~= "flat" and facing ~= "camera" then
				facing = nil
			end
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
			n.text = t
			n.text_node = l
			n.text_facing = facing
			n.text_size = math.max(0.02, math.min(8,
					tonumber(look.text_size) or 0.25))
		end
		local r = type(look.rotation) == "table" and look.rotation or {}
		n.look_rot = magic.Quaternion(tonumber(r[1]) or 0,
				tonumber(r[2]) or 0, tonumber(r[3]) or 0)
		n.at, n.at_q = nil, nil
	end
	-- A swing turns the body round its hinge: the middle of its thickness
	-- at its -x end, so the turned box is look_box's
	if type(look.when) == "table" and look.when.swing then
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
	local col = color(b.color, magic.Color(0.8, 0.8, 0.8))
	if look.material == "glass" then
		col = magic.Color(col.r, col.g, col.b, 0.4)
	end
	n.mat:SetShaderParameter("MatDiffColor", col)
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
	if b.solid then
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
	log:info(string.format("kit: entity %d drawn %gx%gx%g at %g,%g,%g%s", id,
			b.size[1], b.size[2], b.size[3], b.off[1], b.off[2], b.off[3],
			b.solid and ", solid" or "") ..
			(look.shape == "wedge" and ", a wedge" or ""))
end

-- [KIT_OWN_LOOK] A look hidden in play (its type's own_look off): not
-- drawn there (its text neither; its collision kept); in edit mode a
-- faded box of its size in its place. simplified: a box (a sphere's a
-- sphere) whatever its shape or worn material
local function own_look(id, n, look)
	local hidden = look.hidden == true
	if not hidden and not n.ghost then
		return
	end
	local ghost = hidden and E.editing
	local key = tostring(hidden) .. tostring(ghost)
	if key ~= n.hidden then
		n.hidden = key
		log:info("kit: entity " .. id .. (not hidden and " shown" or ghost and
				" drawn faded (own look off)" or " not drawn (own look off)"))
	end
	n.body.enabled = not hidden and n.box.color ~= "none"
	if n.text then
		n.text_node.enabled = not hidden or ghost
	end
	if ghost and not n.ghost then
		n.ghost = n.hinge:CreateChild("Ghost")
		local m = n.ghost:CreateComponent("StaticModel")
		m.model = magic.cache:GetResource("Model", "Models/" ..
				(look.shape == "sphere" and "Sphere" or "Box") .. ".mdl")
		m.material = material("glass")
		local c = color(n.box.color, magic.Color(0.8, 0.8, 0.8))
		m.material:SetShaderParameter("MatDiffColor",
				magic.Color(c.r, c.g, c.b, 0.45))
	end
	if n.ghost then
		n.ghost.enabled = ghost
		n.ghost.position = v3(n.box.off)
		n.ghost.scale = v3(n.box.size)
	end
end

-- The entity as its client parts have it
local function entity_view(id, n)
	local e = {id = id, node = n.node, state = {}}
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

-- [KIT_NESTING] The way an entity's looks are carried by those it is
-- under ("kit_parent", the entity it is under) as their looks slide
-- (kit/mover): its node is where the slide ends (the server's), the look
-- where the parent's is on the way
local function carried(n)
	local d = magic.Vector3(0, 0, 0)
	local pid = n.node:GetVar("kit_parent"):GetInt()
	for _ = 1, 16 do
		local pn = pid ~= 0 and P.nodes[pid]
		if not pn then
			break
		end
		if pn.slide_at and pn.slide_to and pn.look then
			d = d + pn.look.rotation * (pn.slide_at - pn.slide_to)
		end
		pid = pn.node:GetVar("kit_parent"):GetInt()
	end
	return d
end

local hud = nil
local function update_play(_, data)
	local dt = data:GetFloat("TimeStep")
	local lines = {}
	for id, n in pairs(P.nodes) do
		-- What it shows: again as an edit changes it
		local raw = n.node:GetVar("kit_show")
		raw = raw:IsEmpty() and "" or raw:GetString()
		if raw ~= n.show_raw then
			n.show_raw = raw
			n.show = network.parse_json(raw)
			drop_look(n)
			n.last_text = nil
		end
		local show = type(n.show) == "table" and n.show or {}
		if type(show.look) == "table" then
			-- [KIT_LOOK_MATERIAL] A voxel material not in the registry
			-- yet (a builder's new one, the registry still coming): drawn
			-- again once it is
			if n.look and n.wear_wanted and voxel_def(n.wear_wanted) then
				drop_look(n)
			end
			draw_look(id, n, show.look)
			own_look(id, n, show.look)
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
		if n.look then
			local p = n.node.position
			local nr = n.node.rotation
			local q = magic.Quaternion(nr.w, nr.x, nr.y, nr.z)
			local pv = P.preview[id]
			-- An editor's preview: where its drag has it, until the server's
			-- node is there (or its time is up)
			if pv and pv.till and (buildat.get_time_us() > pv.till or
					((p - magic.Vector3(pv[1], pv[2], pv[3])):Length() < 0.01 and
					same_q(q, pv_q(pv)))) then
				P.preview[id] = nil
				pv = nil
			end
			-- A vehicle this client drives: where it predicts it
			-- (controls.lua, [KIT] stage 4h)
			pv = pv or P.pose[id]
			if pv then
				p = magic.Vector3(pv[1], pv[2], pv[3])
				q = pv_q(pv)
			else
				p = p + carried(n)
			end
			if not n.at or (n.at - p):Length() > 1e-4 or
					not same_q(q, n.at_q) then
				n.at, n.at_q = magic.Vector3(p.x, p.y, p.z), q
				n.look.position = n.at
				n.look.rotation = q * n.look_rot
			end
		end
		if n.text then
			-- [KIT_INPUT_ACTIONS] "[use]": this player's key for it
			local v = M.key_text(shown(parse(n.node:GetVar("kit:" ..
					tostring(show.look.text)))))
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
				end
				log:info("kit: entity " .. id .. " shows \"" .. v .. "\"")
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
			e.look, e.hinge, e.body, e.mine = n.look, n.hinge, n.body,
					id == P.you
			e.swing = n.swing
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
			for _, part in ipairs(parts) do
				call(n, part, "on_update", dt)
			end
		end
	end
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
magic.SubscribeToEvent("Update", update_play)

-- The types' client parts, run as this module's own Lua is ([KIT] 4d)
buildat.sub_packet("kit:client_parts", function(data)
	local parts = network.parse_json(data)
	for t, src in pairs(type(parts) == "table" and parts or {}) do
		if type(src) == "string" and not P.parts[t] then
			local ok, part = buildat.eval(src, tostring(t) .. ".client")
			if ok and type(part) == "table" then
				P.parts[t] = part
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
-- keeps in them, drawn by KitVoxelSky*.xml; off, the plain look (the scene's
-- lights alone) at no cost. M.sky_light() is it; M.on_sky(cb) is told.
local sky_on, sky_cbs = false, {}
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
	local voxelworld = require("buildat/module/voxelworld")
	voxelworld.use_skylight = on
	voxelworld.remesh_all()
	for _, cb in ipairs(sky_cbs) do
		cb(on)
	end
end)

-- A chunk's look (voxelworld.sub_material_update, voxel_objects'
-- set_material_cb): KitVoxel*.xml on its solid faces, its "alpha" child
-- (water, blended) and its "masked" one (leaves and plants, cut out),
-- with the tint, and the sky light when the World has it; under physical
-- lighting ([KIT_LIGHTING], environment.lua) its albedo decoded
function M.voxel_look(node)
	local sky = (sky_on and "Sky" or "") ..
			(M.physical and M.physical() and "Phys" or "")
	for child, kind in pairs({[""] = "", alpha = "Alpha",
			masked = "Masked"}) do
		local n = child == "" and node or node:GetChild(child)
		local cg = n and n:GetComponent("CustomGeometry")
		local i = 0
		while cg and cg:GetMaterial(i) do
			cg:GetMaterial(i):SetTechnique(0, magic.cache:GetResource(
					"Technique", "kit/KitVoxel" .. sky .. kind .. ".xml"))
			i = i + 1
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
	local s = others and "Builds while playing were discarded (" ..
			table.concat(list, ", ") .. ")." or
			"Your builds while playing were discarded."
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
		return false, "The server is not Running"
	end
	local n = region_at(x, y, z)
	if not n then
		if action ~= "dig" and action ~= "place" then
			return true
		end
		if granted(action, x, y, z) then
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
			-- [KIT_FLAG_CLICK_RANGE] its type's own, if it has one
			local r = math.min(P.use_range, tonumber(show_of(n).use_range) or
					P.use_range)
			if (n.node.position - me):Length() > r then
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
		if f.col ~= tostring(col) then
			f.col = tostring(col)
			f.mat:SetShaderParameter("MatDiffColor", col)
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
	-- A voxel's face: the cell and the normal out of it, {x, y, z} each
	function h.face(cell, normal, col)
		local axis = normal[1] ~= 0 and 1 or normal[2] ~= 0 and 2 or 3
		local sign = (normal[axis] or 1) > 0 and 1 or -1
		local d = 0.5 + FRAME_OUT
		local w = h.w or FRAME_W
		local f = take(string.format("f%d%d,%.3f", axis, sign, w), col)
		-- Inside the dig frame of the same voxel, so both show
		put(f, function(cg) frame_geometry(cg, {d, d, d}, {axis, sign},
				w * 2, w) end)
		f.node.position = magic.Vector3(cell[1], cell[2], cell[3])
		f.node.rotation = magic.Quaternion(0, 0, 0)
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
			play_hl.box(v3(l.cell), magic.Vector3(d, d, d), nil, M.DIG)
			parts[#parts + 1] = "dig " .. table.concat(l.cell, ",")
		end
		if r and r.kind == "place" then
			play_hl.face(r.on, r.normal, M.PLACE)
			parts[#parts + 1] = "place " .. table.concat(r.cell, ",")
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

-- ---- [KIT_ENVIRONMENT] The environment, the lighting, the sky and the
-- weather: environment.lua
do
	local ok, err, install = buildat.run_script_file("kit/environment.lua")
	assert(ok and type(install) == "function", "kit: environment.lua: " ..
			tostring(err))
	install({M = M, O = O, log = log})
end

-- ---- The keys as named actions: input.lua ([KIT_INPUT_ACTIONS])
do
	local ok, err, install = buildat.run_script_file("kit/input.lua")
	assert(ok and type(install) == "function", "kit: input.lua: " ..
			tostring(err))
	install({M = M, E = E, O = O, log = log})
end

-- ---- [KIT_SOUNDS] The project's sounds, played: sounds.lua
-- (before the editor: its Sounds tab's)
do
	local ok, err, install = buildat.run_script_file("kit/sounds.lua")
	assert(ok and type(install) == "function", "kit: sounds.lua: " ..
			tostring(err))
	install({M = M, O = O, log = log})
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
		value = value})
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

return M
-- vim: set noet ts=4 sw=4:
