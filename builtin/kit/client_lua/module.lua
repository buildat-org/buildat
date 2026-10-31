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
-- editor.lua's head says what it does and its options.
--
-- **Pointing** ([KIT] stage 4e2): what a click would do is shown on what
-- is pointed at, nothing where a click does nothing, in floorplanner's
-- colours (apps/floorplanner's guides: an action's own colour) --
-- kit.HOVER (selecting, the editor's left button), kit.USE (using an
-- object), kit.DIG (digging), kit.PLACE (placing).
--   kit.play_target(origin, dir, reach[, solid]) -> {left = {kind = "use",
--     id} or {kind = "dig", cell}, right = {kind = "place", cell, on,
--     normal}}: in play, what a left click does where the ray points (an
--     object a click uses, before what is behind it, else the voxel this
--     player may dig: edit rights, or a component's grant) and a right
--     click (a voxel placed on the pointed face where this player may);
--     either nil for nothing. solid(x, y, z): the voxels (the editor's
--     solid by default)
--   kit.show_target(t): t drawn this frame (vanilla's pointed box round
--     the object or the voxel, the placement face's frame), logged as it
--     changes ("kit: points at ..."); kit.show_target(nil) none
--   kit.may_dig(x, y, z), kit.may_place(x, y, z): this player's rights
--     and the grants there (a grant only while the server is Running)
--   kit.pick_entity(origin, dir, reach) -> id, t, usable: the usable
--     entity nearest along the ray (its look's box, turned as drawn; one
--     with no look near its cell); the rest the ray goes through.
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
do
	local heightmap = require("buildat/module/heightmap")
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
	t.minWidth = math.max(width or 0, t.width)
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
	return b
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
--   nodes: the body turns with the hinge), e.state (the server's), e.mine
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
		local hinge, front = off[1] - size[1] / 2, off[3] - size[3] / 2
		size[1], size[3] = size[3], size[1]
		off[1], off[3] = hinge + size[1] / 2, front + size[3] / 2
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
		if look.shape == "wedge" then
			wedge(n.body):SetMaterial(0, n.mat)
		else
			local m = n.body:CreateComponent("StaticModel")
			m.model = magic.cache:GetResource("Model", "Models/" ..
					(look.shape == "sphere" and "Sphere" or "Box") .. ".mdl")
			m.material = n.mat
			m.castShadows = true
		end
		if look.text then
			local l = n.look:CreateChild("Text")
			local t = l:CreateComponent("Text3D")
			t:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 16)
			t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
			t.faceCameraMode = magic.FC_ROTATE_XYZ
			t.fixedScreenSize = true
			t.textEffect = magic.TE_STROKE
			t.effectColor = magic.Color(0, 0, 0, 0.8)
			n.text = t
			n.text_node = l
		end
		local r = type(look.rotation) == "table" and look.rotation or {}
		n.look_rot = magic.Quaternion(tonumber(r[1]) or 0,
				tonumber(r[2]) or 0, tonumber(r[3]) or 0)
		n.at, n.at_yaw = nil, nil
	end
	-- A swing turns the body round its hinge: the middle of its thickness
	-- at its -x end, so the turned box is look_box's
	if type(look.when) == "table" and look.when.swing then
		local c = look_box(look, false)
		local px = c.off[1] - c.size[1] / 2 + c.size[3] / 2
		n.hinge.position = magic.Vector3(px, 0, c.off[3])
		n.hinge.rotation = magic.Quaternion(0, on and -90 or 0, 0)
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
	if n.text_node then
		n.text_node.position = magic.Vector3(b.off[1], b.off[2] + b.size[2] / 2 +
				0.45, b.off[3])
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
	log:info(string.format("kit: entity %d drawn %gx%gx%g at %g,%g,%g%s", id,
			b.size[1], b.size[2], b.size[3], b.off[1], b.off[2], b.off[3],
			b.solid and ", solid" or "") ..
			(look.shape == "wedge" and ", a wedge" or ""))
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
			draw_look(id, n, show.look)
		end
		-- Where it is, turned by its entity's yaw ([KIT] stage 4e2) over its
		-- look's own turn, or where an editor's drag has it meanwhile
		if n.look then
			local p = n.node.position
			local yaw = n.node.rotation:YawAngle()
			local pv = P.preview[id]
			-- An editor's preview: where its drag has it, until the server's
			-- node is there (or its time is up)
			if pv and pv.till and (buildat.get_time_us() > pv.till or
					((p - magic.Vector3(pv[1], pv[2], pv[3])):Length() < 0.01 and
					math.abs(((yaw - pv[4]) % 360 + 180) % 360 - 180) < 0.1)) then
				P.preview[id] = nil
				pv = nil
			end
			-- A vehicle this client drives: where it predicts it
			-- (controls.lua, [KIT] stage 4h)
			pv = pv or P.pose[id]
			if pv then
				p = magic.Vector3(pv[1], pv[2], pv[3])
				yaw = pv[4]
			end
			if not n.at or (n.at - p):Length() > 1e-4 or
					math.abs(yaw - n.at_yaw) > 1e-3 then
				n.at, n.at_yaw = magic.Vector3(p.x, p.y, p.z), yaw
				n.look.position = n.at
				n.look.rotation = magic.Quaternion(0, yaw, 0) * n.look_rot
			end
		end
		if n.text then
			local v = shown(parse(n.node:GetVar("kit:" .. tostring(show.look.text))))
			if v ~= n.last_text then
				n.last_text = v
				n.text.text = v
				log:info("kit: entity " .. id .. " shows \"" .. v .. "\"")
			end
		end
		if type(show.hud) == "string" then
			local v = shown(parse(n.node:GetVar("kit:" .. show.hud)))
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
	if P.items ~= "" then
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
	log:info("kit: items: " .. (#t > 0 and table.concat(t, ", ") or "none"))
end)

-- [KIT] stage 4e: the World's word to builders (a refusal, the seams of a
-- regeneration, what applies at the next start)
buildat.sub_packet("kit:warning", function(data)
	log:info("kit: warning: " .. tostring(data))
	ui_utils.show_notification(tostring(data), 8)
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

function M.may_dig(x, y, z)
	return E.can_edit or granted("dig", x, y, z)
end

function M.may_place(x, y, z)
	return E.can_edit or granted("place", x, y, z)
end

function M.play_target(origin, dir, reach, solid)
	dir = unit(dir)
	solid = solid or O.solid
	local id, et, usable = M.pick_entity(origin, dir, reach)
	local hit, front, vt
	if solid then
		hit, front, vt = voxel_ray({origin.x, origin.y, origin.z},
				{dir.x, dir.y, dir.z}, solid, reach)
	end
	local t = {}
	-- The object first: what is in front of the voxel is pointed at
	if id and (not hit or et <= vt + 0.05) then
		if usable then
			t.left = {kind = "use", id = id}
		end
		return t
	end
	if hit and M.may_dig(hit[1], hit[2], hit[3]) then
		t.left = {kind = "dig", cell = hit}
	end
	if hit and front and M.may_place(front[1], front[2], front[3]) then
		t.right = {kind = "place", cell = front, on = hit, normal = {
			front[1] - hit[1], front[2] - hit[2], front[3] - hit[3]}}
	end
	return t
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

-- ---- The editor: editor.lua, given what it shares with play
do
	local ok, err, install = buildat.run_script_file("kit/editor.lua")
	assert(ok and type(install) == "function", "kit: editor.lua: " ..
			tostring(err))
	install({M = M, E = E, O = O, P = P, send = send, log = log,
		color = color, row = row, text = text, label = label,
		button = button, edit = edit, v3 = v3, WARN = WARN, DIM = DIM,
		STYLE = STYLE, value = value, look_frame = look_frame,
		entity_t = entity_t, unit = unit})
end

-- ---- The players' controls: controls.lua ([KIT] stage 4h)
do
	local ok, err, install = buildat.run_script_file("kit/controls.lua")
	assert(ok and type(install) == "function", "kit: controls.lua: " ..
			tostring(err))
	install({M = M, E = E, O = O, P = P, log = log, STYLE = STYLE,
		value = value})
end

return M
-- vim: set noet ts=4 sw=4:
