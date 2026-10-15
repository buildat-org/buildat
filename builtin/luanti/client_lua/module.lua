-- Buildat: builtin/luanti/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The module's client half, and the first piece of it: the textures a
-- Luanti game names with an expression rather than with a file.
--
-- A tile in a node definition can be "default_dirt.png^grass_side.png" or
-- "[combine:32x16:0,0=a.png" -- a small language over raster operations. The
-- server cannot resolve them: what they are for is the client's own texture
-- size, filtering and texture packs, and two of them are resolved at runtime
-- (the crack over a node being dug, a palette's colour). So the server sends
-- the expressions and this composes them, under the same names the voxel
-- definitions were registered with.
--
-- texmod.lua reads the language and hands back compose_image() operations;
-- everything here is the files.
local log = buildat.Logger("luanti")
local magic = require("buildat/extension/urho3d")
local cereal = require("buildat/extension/cereal")
local voxelworld = require("buildat/module/voxelworld")
-- No chunk is meshed before this client's texture modifiers are composed
-- ([TEXMOD_RACE]); allow_streaming() below lifts this once they are
voxelworld.hold_streaming()

local M = {}

-- Beside this file: a module's client half is served whole, and this is how
-- one file of it reaches another
local ok, err, texmod = buildat.run_script_file("luanti/texmod.lua")
if not ok or type(texmod) ~= "table" then
	error("luanti: could not load texmod.lua: " .. tostring(err))
end

-- Where the composed textures go: a resource directory of its own, under the
-- cache, which is the only place compose_image() writes and
-- add_resource_dir() adds. A file lies in it under its resource name, so the
-- prefix is a directory here too; both are made by the first write.
local RESOURCE_DIR = buildat.get_cache_path() .. "/luanti_res"
local RESOURCE_PREFIX = "luanti_texmod/"
-- What the server serves the game's own files as; see media_resource_name()
-- in builtin/luanti/luanti.cpp
local MEDIA_PREFIX = "luanti_media/"

local dir_added = false
-- The directory is a resource directory once there is something in it: the
-- first file made it, and what comes after it is looked up by name -- a
-- nested expression blits the pieces it is made of.
local function added_dir()
	if not dir_added then
		dir_added = buildat.add_resource_dir(RESOURCE_DIR)
	end
end
-- Expression -> the resource name it was composed under, for this run. The
-- files outlive it, but composing one twice costs only the work.
local composed = {}
-- How many were composed and how long it took since the count was last
-- read: what a form's first draw spends on its pictures ([FORMSPEC_FRAME])
local compose_stats = {n = 0, us = 0}

local function hex_hash(s)
	return buildat.hex(buildat.sha1(s))
end

local function resource_of(expr)
	return RESOURCE_PREFIX .. hex_hash(expr) .. ".png"
end

local function path_of(resource)
	return RESOURCE_DIR .. "/" .. resource
end

-- A colour of the expression's own, for one that cannot be composed: the
-- node is then a flat colour rather than a hole in the world, which is what
-- it was before the client resolved anything.
local function fallback_colour(expr)
	local h = hex_hash(expr)
	local function byte(i)
		return 64 + tonumber(string.sub(h, i, i + 1), 16) % 160
	end
	return {byte(1), byte(3), byte(5), 255}
end

local function write_fallback(resource, expr)
	local okc, errc = pcall(buildat.compose_image, {
		size = {16, 16},
		ops = {{op = "fill", color = fallback_colour(expr)}},
		write = path_of(resource),
	})
	if not okc then
		log:warning("could not write a fallback for \"" .. expr .. "\": " ..
				tostring(errc))
		return
	end
	added_dir()
end

-- One expression into one file, and the pieces it is made of into files of
-- their own. The name the top one is written under is the server's, because
-- that is what the voxel definitions say; a piece is named after itself.
local function compose(top_expr, top_resource)
	local ctx
	ctx = {
		resource = function(name)
			return MEDIA_PREFIX .. name
		end,
		-- "[png:" carries a whole file; it becomes one, under a name of
		-- its own, and from there it is a file like any other
		png = function(bytes)
			local resource = RESOURCE_PREFIX .. hex_hash(bytes) .. ".png"
			if composed[resource] then
				return resource
			end
			local okc, errc = pcall(buildat.compose_image, {
				ops = {{op = "blit", src_data = bytes}},
				write = path_of(resource),
			})
			if not okc then
				log:warning("[png: could not be written: " .. tostring(errc))
				return nil
			end
			added_dir()
			composed[resource] = resource
			return resource
		end,
		compose = function(expr, ops, size)
			local resource = (expr == top_expr) and top_resource or
					resource_of(expr)
			if composed[expr] then
				return composed[expr]
			end
			local t0 = buildat.get_time_us()
			local okc, errc = pcall(buildat.compose_image, {
				size = size,
				ops = ops,
				write = path_of(resource),
			})
			compose_stats.n = compose_stats.n + 1
			compose_stats.us = compose_stats.us + buildat.get_time_us() - t0
			if not okc then
				log:warning("compose_image failed for \"" ..
						string.sub(expr, 1, 60) .. "\": " .. tostring(errc))
				return nil
			end
			added_dir()
			composed[expr] = resource
			return resource
		end,
	}
	return texmod.resolve(top_expr, ctx)
end

-- Any expression, composed under a name of its own: what the registry named
-- is composed when the server says so, and this is for the ones that turn up
-- later -- a formspec's background, an item's inventory image.
local cube_texture
local shape_texture
-- (mesh name) -> its quads, asked for if they have not come; beside
-- want_model() below
local shape_model

local function texture_of(expr)
	if expr == nil or expr == "" then
		return nil
	end
	if composed[expr] then
		return composed[expr]
	end
	if string.sub(expr, 1, 6) == "\1cube\1" then
		return cube_texture(expr)
	end
	if string.sub(expr, 1, 7) == "\1shape\1" then
		return shape_texture(expr)
	end
	local got = compose(expr, resource_of(expr))
	if got then
		added_dir()
	end
	return got
end

-- How big the little cube an inventory draws a node as is composed. It is
-- scaled to the slot afterwards, so this only decides how much of the
-- texture's detail survives; nine times a unit, because that is what
-- Luanti's own geometry is in.
local CUBE_UNIT = 8
local CUBE_SIZE = 9 * CUBE_UNIT
-- What the server sends instead of one expression when an item places a
-- node that is a cube: the marker and then the three faces a viewer sees,
-- the sides already carrying the multiply that darkens them. See
-- core.__item_image_of() in the module's lua/bootstrap.lua.
local CUBE_MARK = "\1cube\1"

-- Luanti's own geometry, from createInventoryCubeImage() in
-- src/client/imagesource.cpp: on a canvas of nine units the cube is eight
-- wide and nine tall, a face's horizontal edge runs four across and two
-- down, and a side face's vertical edge runs five down. Being taller than it
-- is wide is the point -- a cube that fills a square canvas reads as
-- squashed. Taken from extensions/luanti_client, which worked them out.
local CUBE_FACES = {
	{at = {4.5 * CUBE_UNIT, 0},
			u = {4 * CUBE_UNIT, 2 * CUBE_UNIT},
			v = {-4 * CUBE_UNIT, 2 * CUBE_UNIT}},
	{at = {0.5 * CUBE_UNIT, 2 * CUBE_UNIT},
			u = {4 * CUBE_UNIT, 2 * CUBE_UNIT}, v = {0, 5 * CUBE_UNIT}},
	{at = {4.5 * CUBE_UNIT, 4 * CUBE_UNIT},
			u = {4 * CUBE_UNIT, -2 * CUBE_UNIT}, v = {0, 5 * CUBE_UNIT}},
}

-- The three tiles sheared into the cube Luanti draws, or nil if one of them
-- could not be composed. Luanti renders the node with a camera; three
-- sheared tiles is the picture that comes out of that, without a render
-- target.
function cube_texture(expr)
	if composed[expr] then
		return composed[expr]
	end
	local faces = {}
	for part in string.gmatch(string.sub(expr, #CUBE_MARK + 1), "[^\1]+") do
		faces[#faces + 1] = part
	end
	if #faces ~= 3 then
		return nil
	end
	local ops = {}
	for i, face in ipairs(CUBE_FACES) do
		local resource = texture_of(faces[i])
		if resource == nil then
			return nil
		end
		ops[#ops + 1] = {op = "shear", src = resource, at = face.at,
				u = face.u, v = face.v}
	end
	local resource = resource_of(expr)
	local okc, errc = pcall(buildat.compose_image, {
		size = {CUBE_SIZE, CUBE_SIZE},
		ops = ops,
		write = path_of(resource),
	})
	if not okc then
		log:warning("the inventory cube could not be composed: " ..
				tostring(errc))
		return nil
	end
	added_dir()
	composed[expr] = resource
	return resource
end

-- A node box's or a mesh's node as the shape Luanti's inventory draws:
-- core.__item_image_of()'s "\1shape\1" geometry and six tiles, projected
-- by the shared res/item_shape.lua ([VL_INV_PARITY]). nil until a mesh's
-- quads have come; the form is drawn again when they do.
local SHAPE_MARK = "\1shape\1"
local ok_ishape, err_ishape, item_shape =
		buildat.run_script_file("luanti/item_shape.lua")
if not ok_ishape or type(item_shape) ~= "table" then
	error("luanti: could not load item_shape.lua: " .. tostring(err_ishape))
end

-- The geometry and the six tiles of a shape expression
local function shape_parts(expr)
	local parts = {}
	for part in string.gmatch(string.sub(expr, #SHAPE_MARK + 1), "[^\1]+") do
		parts[#parts + 1] = part
	end
	local geom = table.remove(parts, 1)
	return geom, parts
end

function shape_texture(expr)
	if composed[expr] then
		return composed[expr]
	end
	local geom, tiles = shape_parts(expr)
	if not geom or #tiles ~= 6 then
		return nil
	end
	local quads
	if geom:sub(1, 2) == "b:" then
		local boxes = {}
		for b in string.gmatch(geom:sub(3), "[^;]+") do
			local n = {}
			for v in string.gmatch(b, "[^,]+") do
				n[#n + 1] = tonumber(v)
			end
			if #n ~= 6 then
				return nil
			end
			boxes[#boxes + 1] = n
		end
		quads = item_shape.box_quads(boxes)
	elseif geom:sub(1, 2) == "m:" then
		local have = shape_model(geom:sub(3))
		if not have then
			return nil
		end
		-- The server's quads count their tiles from 0
		quads = {}
		for i, q in ipairs(have) do
			quads[i] = {p = q.p, uv = q.uv, tile = (q.tile or 0) + 1}
		end
	else
		return nil
	end
	local ops = item_shape.ops(quads, CUBE_UNIT, function(tile, shade)
		local t = tiles[math.min(math.max(tile, 1), 6)]
		return texture_of(shade and t .. "^[multiply:" .. shade or t)
	end)
	if not ops then
		return nil
	end
	local resource = resource_of(expr)
	local okc, errc = pcall(buildat.compose_image, {
		size = {CUBE_SIZE, CUBE_SIZE},
		ops = ops,
		write = path_of(resource),
	})
	if not okc then
		log:warning("the inventory shape could not be composed: " ..
				tostring(errc))
		return nil
	end
	added_dir()
	composed[expr] = resource
	return resource
end

M.texture = texture_of

-- Whether this client has composed the texture modifiers the server named.
-- A chunk meshed before they arrive is drawn with whatever the atlas could
-- find; see [TEXMOD_RACE] in doc/plan/luanti_module_plan.md. The reference
-- set will not photograph a state until this is true.
local texmods_done = false

-- The same table from a packet or from the served file
-- A table this client is handed at startup: served as a file by
-- client_file and answered on request by the luanti module
-- ([BLOCKED_MODULE]). The file is read as soon as the handler is known --
-- the module may be inside a mapgen handler for half a minute and answer
-- nothing in that time -- and the packet is still subscribed to, for what a
-- game adds while it runs.
local function startup_packet(name, file, fn)
	buildat.sub_packet(name, fn)
	local blob = buildat.get_file_content(file)
	if blob then
		log:info(name .. ": from the served file, " .. #blob .. " bytes")
		fn(blob)
	end
end

local function texmods_from_data(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local n = 0
	local failed = 0
	-- The pairs are flat: a resource name and then the expression it is for
	for i = 1, #values - 1, 2 do
		local resource = values[i]
		local expr = values[i + 1]
		if composed[expr] ~= resource then
			local got = compose(expr, resource)
			if got == resource then
				n = n + 1
			else
				-- Either the expression uses something texmod.lua does not
				-- build, or a file it names is not here
				log:info("texmod: a flat colour for \"" ..
						string.sub(expr, 1, 60) .. "\"")
				write_fallback(resource, expr)
				failed = failed + 1
			end
		end
	end
	texmods_done = true
	log:info("luanti:texmods: " .. n .. " textures composed, " .. failed ..
			" could not be")
	-- Now the world may come: nothing is meshed before its textures are
	-- there ([TEXMOD_RACE])
	voxelworld.allow_streaming()
	for name, _ in pairs(texmod.unimplemented) do
		log:info("texmod: no \"" .. name .. "\" yet")
	end
	-- Whatever has been drawn already was drawn without these
	if n > 0 or failed > 0 then
		voxelworld.remesh_all()
	end
end

buildat.sub_packet("luanti:texmods", function(data)
	texmods_from_data(data)
end)

--
-- What the player is carrying
--
-- The server sends this to one client -- the player's own -- whenever their
-- inventory has changed. What draws it is whoever is drawing: a formspec
-- once there is one, and the launcher's own line of text until then.

-- Where the server put the player: the spawn the first time, where the last
-- run left them after that, and a teleport whenever a mod moves them. The
-- player's own walking is the game's -- it is the one with the camera and
-- the keys -- so this is only the times the server decides.
M.player_pos = nil

local player_pos_subs = {}

-- sub_player_pos(f) -> f({x, y, z, look_h, look_v}) every time the server
-- puts the player somewhere, and once now if it already has. The two angles
-- are Luanti's: the horizontal one counter-clockwise from +Z and the
-- vertical one positive downwards, in radians. A game with a camera of its
-- own converts them; the launcher's yaw is the horizontal one negated in
-- degrees and its pitch is the vertical one as it is.
function M.sub_player_pos(f)
	player_pos_subs[#player_pos_subs + 1] = f
	if M.player_pos then
		f(M.player_pos)
	end
end

buildat.sub_packet("luanti:player_pos", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local p = {
		x = tonumber(values[1]) or 0,
		y = tonumber(values[2]) or 0,
		z = tonumber(values[3]) or 0,
		look_h = tonumber(values[5]) or 0,
		look_v = tonumber(values[6]) or 0,
	}
	M.player_pos = p
	-- Which object is the player's own: it is not one to point at, being
	-- the thing the camera is inside of
	M.self_id = values[4]
	for _, f in ipairs(player_pos_subs) do
		f(p)
	end
end)

-- list name -> an array of item strings, one per slot; an empty slot is ""
M.inventory = {}

local inventory_subs = {}

-- sub_inventory(f) -> f(lists) every time the player's inventory changes,
-- and once now if one has already arrived
function M.sub_inventory(f)
	inventory_subs[#inventory_subs + 1] = f
	if next(M.inventory) then
		f(M.inventory)
	end
end

buildat.sub_packet("luanti:inventory", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local lists = {}
	local i = 1
	while i + 1 <= #values do
		local name = values[i]
		local size = tonumber(values[i + 1]) or 0
		local stacks = {}
		for slot = 1, size do
			stacks[slot] = values[i + 1 + slot] or ""
		end
		lists[name] = stacks
		i = i + 2 + size
	end
	M.inventory = lists
	for _, f in ipairs(inventory_subs) do
		f(lists)
	end
end)

--
-- The objects
--
-- Everything in a Luanti world that is not a node: the item a dig dropped,
-- whatever a mod added. The server says where they are every step and what
-- they look like when that changes; what makes something of it is here.
--
-- simplified: a cube or a flat sprite, both wearing one texture, and the
-- plain box for everything else. Luanti's meshes are two file formats of
-- their own and a milestone with them; see "what an object looks like" in
-- doc/plan/luanti_module_plan.md.

-- Where the objects go, which is the game's scene rather than this module's
-- business. Nothing is drawn until a game says.
local object_scene = nil
-- id -> {node =, kind =, texture =}. The material is held by the component
-- it was given to and is not kept here: see the comment in
-- extensions/luanti_client/world.lua about what happens when it is.
local object_nodes = {}
-- id -> {kind =, texture =}, as the server last said
local object_looks = {}

function M.set_scene(scene)
	object_scene = scene
end

-- The first Text at a font size is FreeType rasterizing the face, 35-140
-- ms each, and the forms use four sizes: the first inventory drew in
-- 260 ms and failed a fuzz row on its frame ([FORMSPEC_FRAME]). Made
-- once here, under the loading line, where the hitch has something to
-- hide behind. The launcher calls it when the world is up.
-- `event status_text <text>` in a command sequence ([DRIVE_STATUS]): one
-- line at the top right, for watching a driven client live -- what the
-- driver is attempting, as it happens, without the log beside it. The
-- launcher's status row's font and inset; the pale yellow of the
-- fixture's own status line, so it reads as the harness's, not the
-- game's. Replaced on each event, cleared by an empty one. The second
-- command_seq:* receiver; any sequence can use it.
local status_text = nil
magic.SubscribeToEvent("command_seq:status_text", function(event_type, event_data)
	local text = event_data:GetString("Param") or ""
	if status_text == nil then
		status_text = magic.ui.root:CreateChild("Text")
		status_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 13)
		status_text:SetTextEffect(magic.TE_SHADOW)
		status_text.effectColor = magic.Color(0, 0, 0, 0.85)
		status_text.color = magic.Color(1, 1, 0.5)
		status_text.horizontalAlignment = magic.HA_RIGHT
		status_text.verticalAlignment = magic.VA_TOP
		status_text:SetPosition(-8, 8)
		status_text.priority = 1000
	end
	status_text:SetText(text)
	status_text.visible = text ~= ""
end)

function M.warm_fonts()
	local holder = magic.ui.root:CreateChild("UIElement")
	holder.defaultStyle = magic.cache:GetResource("XMLFile",
			"ui_utils/res/style.xml")
	for _, size in ipairs({12, 13, 14, 15, 16}) do
		local t = holder:CreateChild("Text")
		t:SetStyleAuto()
		t.text = "0"
		t:SetFontSize(size)
	end
	holder:Remove()
end

local function object_texture(expr)
	local resource = texture_of(expr)
	if not resource then
		return nil
	end
	local tex = magic.cache:GetResource("Texture2D", resource)
	if tex then
		-- A Luanti game's textures are pixel art; smoothing them is wrong
		-- at every size
		tex.filterMode = magic.FILTER_NEAREST
	end
	return tex
end

-- mesh name -> {quads = {...}} once the server has answered, or false while
-- it is being asked for: a model is asked for by name and arrives once.
local models = {}
-- Who redraws on the item images (M.sub_item_images), and the mesh nodes
-- a hand draws as their mesh (luanti:wield_meshes); up here, since a
-- model arriving tells them too
local item_image_subs = {}
local wield_meshes = {}
M.wield_generation = 0
-- mesh name and textures -> the node its geometry was built on, which every
-- object of that kind is a clone of. Every vertex is a sandbox call, and the
-- extension measured a VoxeLibre skeleton at 250 ms of them; a clone is
-- copied inside the engine instead.
local model_templates = {}

-- A model is filed by its name and the frame it is posed at: "name" for
-- the bind pose, "name@frame" for a pose ([OBJECT_MESH])
local function model_key(name, frame)
	return frame and (name .. "@" .. tostring(frame)) or name
end

local function want_model(name, frame)
	if name == nil or name == "" or models[model_key(name, frame)] ~= nil then
		return
	end
	models[model_key(name, frame)] = false
	buildat.send_packet("luanti:get_model",
			cereal.binary_output({name, frame and tostring(frame) or ""},
			{"array", "string"}))
end

shape_model = function(name)
	want_model(name)
	return models[name] and models[name].quads or nil
end

-- The quads of one model, grouped by the material they wear, on a node of
-- their own. Both windings, because a model's is not something to rely on.
local function build_model(node, quads, textures)
	-- The geometry is built in the engine (one geometry per tile, both
	-- windings), which answers the tiles in geometry order: a skeleton
	-- built quad by quad from here was 250 ms of sandbox calls, and a
	-- posed model is one build per frame ([OBJECT_MESH] step 1)
	local tiles = buildat.set_quad_geometry(node, quads)
	local order = {}
	for i = 1, #tiles do
		order[i] = tiles[i] + 1
	end
	local cg = node:GetComponent("CustomGeometry")
	local materials = {}
	for i = 1, #order do
		local material = magic.Material.new()
		-- A cut-out with the depth write on ([OBJECT_MESH]): alpha
		-- blending without it painted a hat layer's texels over the head
		-- behind them and turned skirts inside-out
		material:SetTechnique(0, magic.cache:GetResource("Technique",
				"luanti_client/res/LuantiUnlitMask.xml"))
		local tex = object_texture(textures[order[i]] or textures[1] or "")
		if tex then
			material:SetTexture(magic.TU_DIFFUSE, tex)
		end
		cg:SetMaterial(i - 1, material)
		materials[i] = material
	end
	return cg, materials
end

-- How far a camera has to be to have the whole of a model in the picture:
-- the box its quads are in, as a centre and the radius of the sphere around
-- that box.
local function model_bounds(quads)
	local lo = {math.huge, math.huge, math.huge}
	local hi = {-math.huge, -math.huge, -math.huge}
	for _, q in ipairs(quads) do
		for c = 0, 3 do
			for a = 1, 3 do
				local v = q.p[c * 3 + a]
				lo[a] = math.min(lo[a], v)
				hi[a] = math.max(hi[a], v)
			end
		end
	end
	local c = {}
	local d2 = 0
	for a = 1, 3 do
		c[a] = (lo[a] + hi[a]) / 2
		d2 = d2 + (hi[a] - lo[a]) * (hi[a] - lo[a])
	end
	return c, math.max(math.sqrt(d2) / 2, 0.01)
end

-- A formspec's model[] element: the mesh in a little scene of its own,
-- which Urho3D's View3D renders into a texture the size of the element. It
-- is the one way to have something three-dimensional in among the UI rather
-- than behind all of it -- a viewport over the screen is drawn under every
-- UI element there is, and the form is one.
--
-- The element owns its scene and the form takes the element away when it is
-- drawn again, so nothing here has to be freed by hand.
--
-- simplified: no animation, no mouse control and no continuous turn -- what
-- is drawn is the mesh at the angles the element names. The upgrade is a
-- frame of a skeleton, which wants the animation crossing as well as the
-- quads. Nothing is drawn at all until the model arrives; the form is drawn
-- again when it does.
local function model_element(parent, w, h, mesh, textures, rot_x, rot_y)
	want_model(mesh)
	local have = models[mesh]
	if not have or w < 1 or h < 1 then
		return nil
	end
	local view = parent:CreateChild("View3D")
	view.size = magic.IntVector2(math.floor(w), math.floor(h))
	-- Cleared to nothing around the model, the form showing through: a
	-- target with alpha, the clear's alpha 0, drawn blended
	view.format = magic.Graphics.GetRGBAFormat()
	view.blendMode = magic.BLEND_ALPHA
	local scene = magic.Scene.new()
	scene:CreateComponent("Octree")
	local zone = scene:CreateChild("zone"):CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-1000, 1000)
	zone.fogColor = magic.Color(0, 0, 0, 0)
	zone.fogStart = 10000
	zone.fogEnd = 10000
	zone.ambientColor = magic.Color(1, 1, 1)
	-- The model hangs off a pivot at its own centre, so that the angles the
	-- element names turn it in place rather than around whatever point the
	-- game happened to build it about
	local pivot = scene:CreateChild("pivot")
	local node = pivot:CreateChild("model")
	build_model(node, have.quads, textures or {})
	local centre, radius = model_bounds(have.quads)
	node.position = magic.Vector3(-centre[1], -centre[2], -centre[3])
	pivot.rotation = magic.Quaternion(rot_x, rot_y, 0)
	local cam_node = scene:CreateChild("camera")
	local cam = cam_node:CreateComponent("Camera")
	-- The whole sphere in the picture, with a little room around it, and
	-- the narrow way of a tall element is what has to fit
	local dist = radius / math.tan(math.rad(cam.fov / 2)) * 1.1
	if h > w then
		dist = dist * h / w
	end
	cam_node.position = magic.Vector3(0, 0, -dist)
	cam_node.direction = magic.Vector3(0, 0, 1)
	view:SetView(scene, cam)
	return view
end

local function model_template(look)
	local key = model_key(look.mesh, look.frame) .. "\1" ..
			table.concat(look.textures or {}, "\1")
	local entry = model_templates[key]
	if entry == nil then
		local node = object_scene:CreateChild("model_template")
		node.enabled = false
		local _, materials = build_model(node,
				models[model_key(look.mesh, look.frame)].quads,
				look.textures or {})
		entry = {node = node, materials = materials}
		model_templates[key] = entry
	end
	return entry
end

local function make_object_node(look)
	-- A model, if the quads have arrived: a clone of the template, whose
	-- materials it is given again -- a Material made in Lua has no resource
	-- name, so it is not an attribute Urho3D copies with the node
	if look.kind == "mesh" and look.mesh ~= nil then
		want_model(look.mesh, look.frame)
		if models[model_key(look.mesh, look.frame)] then
			local template = model_template(look)
			local node = template.node:Clone()
			node.enabled = true
			local cg = node:GetComponent("CustomGeometry")
			-- Cloned per object, so that each is lit by where it stands
			-- ([OBJECT_LIGHT]); the template's stay as made
			local mats = {}
			for i = 1, #template.materials do
				mats[i] = template.materials[i]:Clone()
				cg:SetMaterial(i - 1, mats[i])
			end
			return node, mats
		end
	end
	-- The texture first: a compose that raises leaves no node in the scene
	local tex = object_texture(look.texture)
	local node = object_scene:CreateChild("luanti_object")
	if look.kind == "sprite" and tex then
		local set = node:CreateComponent("BillboardSet")
		set.numBillboards = 1
		set.faceCameraMode = magic.FC_ROTATE_XYZ
		set.sorted = true
		local material = magic.Material.new()
		-- Unlit and alpha-masked. A lit technique is wrong here: the light
		-- a voxel game needs is bright enough that a sprite under it comes
		-- out a white blob, and what a sprite wears is its own colours.
		-- Masked with the depth write on, as Luanti's alpha reference:
		-- the pointed frame's far edges go behind it ([SELECTION_BOX])
		material:SetTechnique(0, magic.cache:GetResource("Technique",
				"luanti_client/res/LuantiUnlitMask.xml"))
		material:SetTexture(magic.TU_DIFFUSE, tex)
		set.material = material
		local b = set:GetBillboard(0)
		if b then
			b.size = magic.Vector2(0.5, 0.5)
			b.enabled = true
			if look.frame then
				local dx, dy, fx, fy = look.frame[1], look.frame[2],
						look.frame[3], look.frame[4]
				b.uv = magic.Rect(fx / dx, fy / dy, (fx + 1) / dx, (fy + 1) / dy)
			end
		end
		set:Commit()
		return node, {material}
	end
	local model = node:CreateComponent("StaticModel")
	model.model = magic.cache:GetResource("Model", "Models/Box.mdl")
	if tex then
		local material = magic.Material.new()
		-- Masked with the depth write on, as the sprite above
		material:SetTechnique(0, magic.cache:GetResource("Technique",
				"luanti_client/res/LuantiUnlitMask.xml"))
		material:SetTexture(magic.TU_DIFFUSE, tex)
		model.material = material
		model.castShadows = true
		return node, {material}
	end
	-- Nothing to wear: the box it was before anything said otherwise
	model.material = magic.cache:GetResource("Material",
			"Materials/Stone.xml")
	model.castShadows = true
	return node, {}
end

-- The light where an object stands ([OBJECT_LIGHT], official's
-- GenericCAO::updateLight): the voxel's skylight nibble at the day's
-- amount or its lamp nibble, the brighter, on the same floor and ramp the
-- launcher lights the hand with -- flat, as the objects are drawn unlit.
-- The day's amount is the launcher's, told through M.set_daylight().
M.daylight = 1.0
function M.set_daylight(amount)
	M.daylight = math.max(0, math.min(1, amount or 1))
end

-- **The app's fog limit**: the viewing range lowered to far nodes, the
-- fade from start (a share of it, as Luanti's fog_start), for as long as
-- it is set -- the lower of it and the game's sky's fog_distance wins.
-- Cheap enough to set every frame. nil gives the range back.
M.fog_limit = nil
M.on_fog_limit = nil -- client.lua's, to apply it
function M.set_fog_limit(far, start)
	M.fog_limit = far and {far = far, start = start} or nil
	if M.on_fog_limit then
		M.on_fog_limit()
	end
end

-- Under pbr the frame is in radiance and the display floor would sit a
-- hundred times over a cave: the launcher tells what PBRVoxel.glsl gives
-- a face with no sun -- the hour's ambient (the sky share of it), the
-- bounce (the rest), a lamp at full -- and the flat colour is that at the
-- voxel's nibbles, no floor. Unset, the parity modes' floor and ramp.
-- sun: the sun's on a level face, for a voxel under the open sky
M.light_units = nil
function M.set_light_units(ambient, bounce, lamp, sun)
	M.light_units = ambient and {ambient = ambient, bounce = bounce,
			lamp = lamp, sun = sun} or nil
end

-- The flat colour at a position, and the sky and lamp levels it is from,
-- or nil where no voxel is loaded (the caller keeps what it had: a
-- full-bright guess lit caves). no_sun leaves the sun out, for a lit
-- model that has the sun's light of its own.
M.PBR_TEXEL_K = 0.44
-- Voxel id -> whether it stops a player, which here stands for stopping
-- light. simplified: glass and leaves count as blockers, and a place in
-- one is lit from beside it, which is its own light or a level under it.
local solid_ids = {count = -1}
local function solid(reg, v)
	if solid_ids.count ~= reg:get_count() then
		solid_ids = {count = reg:get_count()}
	end
	local id = reg:id_of(v)
	local s = solid_ids[id]
	if s == nil then
		local def = reg:get_by_id(id)
		s = def ~= nil and def.physically_solid or false
		solid_ids[id] = s
	end
	return s
end
local BESIDE = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1},
		{0, 0, -1}}

-- PBRVoxel.glsl's lamp term at a lamp nibble (0..15): its falloff over the
-- nibble's distance from a torch's level. res/light_ramp.png is the same
-- curve over a level 14 light's reach.
local function lamp_curve(level)
	local d = math.max(math.min(12 - level, 12), 1)
	return (1 / d - 1 / 12) * 12 / 11
end

-- The dynamic lights drawn this frame, {x, y, z, level}, kept by
-- M.update_lights(): an object and the hand are lit by them as by the
-- map's lamp nibble at their level less the distance ([WIELD_LIGHT_LOOK])
local dynamic_now = {}
local function dynamic_lamp(x, y, z, lamp)
	for _, l in ipairs(dynamic_now) do
		local dx, dy, dz = l.x - x, l.y - y, l.z - z
		lamp = math.max(lamp, l.level - math.sqrt(dx * dx + dy * dy + dz * dz))
	end
	return lamp
end
-- Whether a place is within a dynamic light's reach, or just out of it
local function near_dynamic(x, y, z)
	for _, l in ipairs(dynamic_now) do
		local dx, dy, dz = l.x - x, l.y - y, l.z - z
		if dx * dx + dy * dy + dz * dz < (l.level + 2) ^ 2 then
			return true
		end
	end
	return false
end

-- settle: the light as the flood leaves it, read from the open voxels
-- beside it as well, a level under theirs (sunlight full straight down).
-- A voxel just dug arrives as air with no light and is relit a second
-- or more later ([DROP_LIGHT_FIRST]), and a solid one holds a light of
-- its own; both read so without settle.
function M.light_color(x, y, z, no_sun, settle)
	local px, py, pz = math.floor(x + 0.5), math.floor(y + 0.5),
			math.floor(z + 0.5)
	local v = voxelworld.get_static_voxel(buildat.Vector3(px, py, pz))
	if v == nil then
		return nil
	end
	local reg = voxelworld.get_voxel_registry()
	local sky, lamp = reg:light_sky_of(v), reg:light_lamp_of(v)
	local blocked = solid(reg, v)
	if settle or blocked then
		if blocked then
			sky, lamp = 0, 0
		end
		for _, d in ipairs(BESIDE) do
			local w = voxelworld.get_static_voxel(buildat.Vector3(
					px + d[1], py + d[2], pz + d[3]))
			if w ~= nil and not solid(reg, w) then
				local s = reg:light_sky_of(w)
				sky = math.max(sky, (d[2] == 1 and s == 15) and 15 or s - 1)
				lamp = math.max(lamp, reg:light_lamp_of(w) - 1)
			end
		end
	end
	lamp = dynamic_lamp(x, y, z, lamp)
	local levels_sky, levels_lamp = sky, lamp
	sky, lamp = sky / 15, lamp / 15
	local u = M.light_units
	if u == nil then
		local k = 0.28 + 0.72 * math.max(sky * M.daylight, lamp)
		return magic.Color(k, k, k, 1.0), levels_sky, levels_lamp
	end
	-- PBRVoxel.glsl's vertex terms for a face with no sun: the ambient by
	-- the sky share (the nibble times the face's local shade, which the
	-- mesher packs beside it and an object has no reading of: taken as
	-- the nibble again, an open place's), the bounce where the shaped
	-- nibble (the knee at 2..11) says the sky does not reach, a lamp by
	-- its falloff over the nibble's distance from a torch's level.
	-- simplified: no ground term and no normal (a side sees half the
	-- sky); level 2 is where a normal takes its share.
	local t = math.max(0, math.min(1, (sky - 2 / 15) / (9 / 15)))
	local shaped = t * t * (3 - 2 * t)
	local share = sky * sky
	local bounce = (0.15 + sky) * (1 - shaped) * sky
	local lit = lamp_curve(15 * lamp)
	-- The pbr path decodes its texel (pow 2.2) and an unlit object does
	-- not: a mid texel (0.5) is 0.44 of itself decoded, and the object is
	-- scaled by that so a mid tone sits level with the world's.
	-- simplified: one factor for every texel; the upgrade is an unlit
	-- technique that decodes, which level 2's material does anyway.
	local k = M.PBR_TEXEL_K
	local a, b, l = u.ambient, u.bounce, u.lamp
	-- The sun where the sky nibble is full, which in Luanti is direct
	-- sunlight, at half: the mean of a face turned to it and one turned
	-- away (user: the whole of it made a held pickaxe too bright).
	-- simplified: no shadow map and no normal; an object in a tree's
	-- shadow on open ground is half sunlit. [OBJECT_LIGHT] level 2 is
	-- the sun's direction and shadow on it.
	local s = u.sun and sky >= 1 and not no_sun and u.sun or
			{r = 0, g = 0, b = 0}
	local h = 0.5
	return magic.Color(k * (a.r * share + b.r * bounce + l.r * lit + h * s.r),
			k * (a.g * share + b.g * bounce + l.g * lit + h * s.g),
			k * (a.b * share + b.b * bounce + l.b * lit + h * s.b), 1.0),
			levels_sky, levels_lamp
end

-- **Under pbr a model is lit as the held item is** ([OBJECT_SUN],
-- [SKELENTI_MOB_LIGHT]): Urho's PBR lit passes on its normals, so the
-- sun's direction shades its sides and the shadow map the world's light
-- pass has falls on it, and it casts into that map. Its colour is the
-- light where it stands without the sun, over the zone's ambient, which
-- the shader multiplies it by (the launcher's hand the same, client.lua's
-- update_sky). Returns nil where no voxel is loaded, as light_color().
-- Only while M.light_units is set (pbr); a parity mode's model is flat.
function M.model_light(x, y, z, settle)
	local c, sky, lamp = M.light_color(x, y, z, true, settle)
	local a = M.light_units and M.light_units.ambient
	if c == nil or a == nil then
		return c, sky, lamp
	end
	-- Without light_color()'s texel factor: the lit passes decode the
	-- texel themselves, and the factor on top of that drew a boar in the
	-- sun near black
	local k = M.PBR_TEXEL_K
	local function ratio(v, av)
		return av > 1e-6 and v / av / k or 0
	end
	return magic.Color(ratio(c.r, a.r), ratio(c.g, a.g), ratio(c.b, a.b), 1.0),
			sky, lamp
end
-- A model's material for pbr (lit) or the flat light (unlit)
function M.set_model_technique(m, pbr)
	m:SetTechnique(0, magic.cache:GetResource("Technique", pbr and
			"luanti/PBRLitAlphaMask.xml" or
			"luanti_client/res/LuantiUnlitMask.xml"))
	m:SetShaderParameter("Roughness", 1.0)
	m:SetShaderParameter("Metallic", 0.0)
end

-- Set on an object's materials when it moves (and when the day turns; the
-- launcher's set_daylight is every frame, the objects are placed by
-- packet), at the middle of its box; skipped when it has not changed
local function light_object(have, x, y, z)
	if #have.materials == 0 then
		return
	end
	-- A model through pbr ([OBJECT_SUN]); a sprite has no normals
	local pbr = M.light_units ~= nil and have.look ~= nil and
			have.look.kind ~= "sprite"
	if have.pbr ~= pbr then
		have.pbr = pbr
		have.lit = nil
		for _, m in ipairs(have.materials) do
			M.set_model_technique(m, pbr)
		end
		local cg = have.node:GetComponent("CustomGeometry")
		if cg then
			cg.castShadows = pbr
		end
	end
	local box = have.box or {1, 1, 1}
	local c, sky, lamp
	if pbr then
		c, sky, lamp = M.model_light(x, y + box[2] / 2, z, have.new)
	else
		c, sky, lamp = M.light_color(x, y + box[2] / 2, z, false, have.new)
	end
	if c == nil then
		return
	end
	local o = have.lit
	if o and math.abs(c.r - o.r) < 1 / 255 and math.abs(c.g - o.g) < 1 / 255
			and math.abs(c.b - o.b) < 1 / 255 then
		return
	end
	have.lit = c
	log:verbose(string.format("luanti: object %s lit at %.1f,%.1f,%.1f sky %d lamp %d",
			have.id, x, y, z, sky, lamp))
	for _, m in ipairs(have.materials) do
		m:SetShaderParameter("MatDiffColor", c)
	end
end

-- A look that changed is a node made again: a billboard and a model are
-- different components, and one object is not redrawn often enough for the
-- difference to be worth keeping.
-- Building a node -- a model cloned, a material and a texture made -- is
-- the cost of the objects packet, and a packet is every object in view: a
-- spawn wave or a look change across a herd was 0.1-0.4 s in one frame
-- ([FRAME_PEAK], the fuzz campaign's frame column). So a packet builds
-- under a budget and the rest wait for the next; an object not built yet
-- is not drawn for a frame or two, and the packet a fifth of a second
-- later places it. Reset by the packet, spent by object_node().
local OBJECT_BUILD_BUDGET_US = 4000
local object_build_left_us = OBJECT_BUILD_BUDGET_US
local objects_deferred = 0

local function object_node(id)
	local have = object_nodes[id]
	local look = object_looks[id] or {kind = "box", texture = ""}
	-- A model whose quads arrived after the object did is built then: what
	-- was drawn until now is the box it falls back to
	local drawn_as = look.kind
	if look.kind == "mesh" and
			not (look.mesh and models[model_key(look.mesh, look.frame)]) then
		drawn_as = "box"
	end
	if have and have.drawn_as == drawn_as and have.texture == look.texture and
			have.mesh == look.mesh and have.frame == look.frame then
		return have.node
	end
	if object_build_left_us <= 0 then
		objects_deferred = objects_deferred + 1
		return nil
	end
	if have then
		-- Out of the table before the build: a build that raises -- a
		-- texture that cannot be composed -- must not leave the entry
		-- pointing at a node already removed, or the next packet removes
		-- it again through a dangling pointer (the Windows client's page
		-- fault, [WIN_SMOKE_STALL])
		object_nodes[id] = nil
		have.node:Remove()
	end
	local t0 = buildat.get_time_us()
	local node, materials = make_object_node(look)
	object_build_left_us = object_build_left_us -
			(buildat.get_time_us() - t0)
	object_nodes[id] = {node = node, drawn_as = drawn_as, mesh = look.mesh, frame = look.frame,
			texture = look.texture, look = look, materials = materials or {},
			lit = nil, born = buildat.get_time_us(), id = id}
	return node
end

-- The detail a model's appearance carries: the mesh file, the size it is
-- drawn at, and one texture per material. See appearance_of() in
-- lua/entity.lua.
local function parse_look(kind, texture, detail)
	local look = {kind = kind, texture = texture}
	if kind == "sprite" and detail ~= nil and detail:sub(1, 1) == "\2" then
		-- A sheet's division and the frame shown: dx,dy,fx,fy
		local dx, dy, fx, fy = detail:match("^\2(%d+),(%d+),(%-?%d+),(%-?%d+)$")
		if dx then
			look.frame = {tonumber(dx), tonumber(dy), tonumber(fx), tonumber(fy)}
		end
		return look
	end
	if kind == "sprite" and detail ~= nil and detail ~= "" then
		-- A sprite of an item lying about: the detail is the item's name
		look.item = detail
		return look
	end
	if kind ~= "mesh" or detail == nil or detail == "" then
		return look
	end
	local parts = {}
	for part in string.gmatch(detail .. "\1", "([^\1]*)\1") do
		parts[#parts + 1] = part
	end
	look.mesh = parts[1]
	look.size = {1, 1, 1}
	local i = 1
	local anim = {}
	for n in string.gmatch(parts[2] or "", "[^,]+") do
		if i <= 3 then
			look.size[i] = tonumber(n) or 1
		else
			-- The fourth number is the frame the model is posed at; the
			-- fifth to seventh the animation's last frame, its speed and
			-- whether it loops ([OBJECT_MESH] step 1)
			anim[i - 3] = tonumber(n)
		end
		i = i + 1
	end
	look.frame = anim[1]
	if anim[1] and anim[2] and anim[2] > anim[1] and (anim[3] or -1) >= 0 then
		look.anim = {first = anim[1], last = anim[2], speed = anim[3],
				loop = anim[4] ~= 0}
	end
	look.textures = {}
	for j = 3, #parts do
		look.textures[j - 2] = parts[j]
	end
	want_model(look.mesh, look.frame)
	return look
end

-- **What the packet last said about an object** ([PACKET_STALL] (3),
-- measured on this desk 2026-09-26). The server sends every object's
-- full state whenever any one of them moved, and standing still in a
-- VoxeLibre world that is 78 to 83 objects several times a second, of
-- which a handful are moving. Placing one costs a node lookup, three
-- transforms through the binding, a box table and a voxel light lookup
-- -- about 0.4 ms, so 25 to 42 ms a packet, and that packet is the
-- frame. Two minutes standing still: 407 packets over 5 ms, 5.1
-- seconds of frame time in them.
--
-- So an object the packet says nothing new about is left where it is.
-- The nine doubles are compared in place -- no table is built to
-- compare, since building one per object per packet is the cost being
-- removed. Cleared wherever the node would have to be made again: a
-- look that changed, an object that went.
local object_last = {}

-- object_box(id) -> min, max: the box an object is aimed at and framed
-- by, in world coordinates: its selection box about its position, which
-- is what Luanti points at ([OBJECT_SELECTION_BOX]); before its look has
-- said where that is, its collision box
function M.object_box(id)
	local last, look = object_last[id], object_looks[id]
	if not last then
		return nil
	end
	local sel, mid = look and look.sel, look and look.middle
	if sel and mid then
		local x, y, z = last[1] - mid[1], last[2] - mid[2], last[3] - mid[3]
		return {x + sel[1], y + sel[2], z + sel[3]},
				{x + sel[4], y + sel[5], z + sel[6]}
	end
	local hx, hy, hz = last[4] / 2, last[5] / 2, last[6] / 2
	return {last[1] - hx, last[2] - hy, last[3] - hz},
			{last[1] + hx, last[2] + hy, last[3] + hz}
end

-- pointed_object(x, y, z, dx, dy, dz, max_distance) -> id, distance
--
-- Which object a ray runs into first, by object_box(): the game points
-- the ray because it has the camera, and what is in the world is here. A
-- slab-test against an axis-aligned box.
-- simplified: a box is not turned with the object, which is Luanti's own
-- default (selectionbox's rotate = false)
function M.pointed_object(x, y, z, dx, dy, dz, max_distance)
	local best, best_t = nil, max_distance
	for id, have in pairs(object_nodes) do
		local look = object_looks[id]
		-- Not the player's own object: the camera is inside it, so a ray
		-- from the eye hits it before anything else in the world
		local lo, hi = M.object_box(id)
		if id ~= M.self_id and lo and (look == nil or look.pointable ~= false) then
			local t0, t1 = 0, best_t
			local function slab(o, d, l, h)
				if math.abs(d) < 1e-9 then
					return o >= l and o <= h
				end
				local a = (l - o) / d
				local b = (h - o) / d
				if a > b then
					a, b = b, a
				end
				if a > t0 then t0 = a end
				if b < t1 then t1 = b end
				return t0 <= t1
			end
			if slab(x, dx, lo[1], hi[1]) and slab(y, dy, lo[2], hi[2]) and
					slab(z, dz, lo[3], hi[3]) and t0 >= 0 and t0 < best_t then
				best, best_t = id, t0
			end
		end
	end
	return best, best_t
end

-- What an object is drawn with, for the scan's bins ([SCAN_DRIVE]): its
-- texture's or its mesh's name, or its kind
function M.object_label(id)
	local have = object_nodes[id]
	if have == nil then
		return "?"
	end
	if have.look and have.look.item then
		return "item:" .. have.look.item:gsub("[%s|]", "_")
	end
	local t = have.texture or have.mesh
	if type(t) == "table" then
		t = t[1]
	end
	return (tostring(t or have.drawn_as or "?"):gsub("[%s|]", "_"))
end

-- How many packets it takes to re-light every object that is standing
-- still, and which slice this packet does
local LIGHT_TURNS = 8
local object_light_turn = 0
-- The doubles after the id, against what was placed last time
local function object_same(prev, v, i)
	if prev == nil then
		return false
	end
	for k = 1, 12 do
		if prev[k] ~= v[i + k] then
			return false
		end
	end
	return true
end

startup_packet("luanti:object_props", "luanti_data/object_props.bin", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	for i = 1, #values - 5, 6 do
		local look = parse_look(values[i + 1], values[i + 2], values[i + 3])
		-- The same model playing the same range keeps the pose it is at
		-- rather than going back to the range's first while the look
		-- changes for something else, or the speed
		local was = object_looks[values[i]]
		if was and was.anim and look.anim and was.mesh == look.mesh and
				was.anim.first == look.anim.first and
				was.anim.last == look.anim.last then
			look.frame = was.frame
		end
		object_looks[values[i]] = look
		look.pointable = values[i + 4] ~= "0"
		-- The collision box's middle and the selection box, about the
		-- object's position ([OBJECT_SELECTION_BOX])
		local b = {}
		for n in string.gmatch(values[i + 5] or "", "%S+") do
			b[#b + 1] = tonumber(n) or 0
		end
		if #b == 9 then
			look.middle = {b[1], b[2], b[3]}
			look.sel = {b[4], b[5], b[6], b[7], b[8], b[9]}
		end
		-- A look that changed is a node made again, and the next packet
		-- has to do it rather than recognise the same doubles
		object_last[values[i]] = nil
	end
end)

-- Set where the form is drawn, far below: a model that arrives after the
-- form asking for it was drawn has to make it draw again
local form_model_arrived

buildat.sub_packet("luanti:model", function(data)
	local values = cereal.binary_input(data, {"object",
		{"name", "string"},
		{"frame", "string"},
		{"nums", {"array", "double"}},
	})
	local name = values.name
	if name == nil or name == "" then
		return
	end
	-- The frame it was asked posed at rides second; the quads follow as
	-- 21 numbers each
	name = model_key(name, tonumber(values.frame))
	local nums = values.nums
	local quads = {}
	for i = 1, #nums - 20, 21 do
		local q = {tile = nums[i], p = {}, uv = {}}
		for j = 1, 12 do
			q.p[j] = nums[i + j]
		end
		for j = 1, 8 do
			q.uv[j] = nums[i + 12 + j]
		end
		quads[#quads + 1] = q
	end
	local centre, radius = model_bounds(quads)
	log:info(string.format("luanti:model: %s, %d quads, radius %.2f about %.1f,%.1f,%.1f",
			name, #quads, radius, centre[1], centre[2], centre[3]))
	if #quads == 0 then
		-- Nothing could read it: the objects of this kind keep their box,
		-- and asking again would only ask again
		models[name] = false
		return
	end
	models[name] = {quads = quads}
	-- Whatever was drawn as a box while this was on its way is drawn again
	for id, have in pairs(object_nodes) do
		if have.mesh == name and have.drawn_as ~= "mesh" then
			have.node:Remove()
			object_nodes[id] = nil
		end
	end
	-- And so is a form with a model[] in it: the form is on the screen
	-- before the model it names has been asked for
	if form_model_arrived then
		form_model_arrived()
	end
	-- And a hand holding a mesh node ([WIELD_MESH]): what draws the hand
	-- listens for the item images, which is when it tries again. Only for
	-- a wield mesh: a mob's poses arrive several a second
	for _, wm in pairs(wield_meshes) do
		if wm.mesh == values.name then
			for _, f in ipairs(item_image_subs) do
				f()
			end
			break
		end
	end
end)

-- The frame an animated object is at, into its look: the pose asked for
-- is the frame the clock has reached, sampled at up to POSE_RATE poses a
-- second of animation so that a walk is a handful of poses rather than
-- one per frame -- each pose is a model asked of the server and a
-- template built once. The node is rebuilt from the pose's template
-- by object_node() when the frame changed and its pose has arrived; until
-- it arrives the last pose stays. Official blends bones per frame; this
-- steps through poses ([OBJECT_MESH] step 1).
-- simplified: a pose per sampled frame; the upgrade is the bones and the
-- keys through Urho3D's AnimatedModel, one build per model.
local POSE_RATE = 8
local anim_clock = {}
local function animate_object(id)
	local look = object_looks[id]
	local a = look and look.anim
	if not a then
		anim_clock[id] = nil
		return false
	end
	-- The clock is where the animation was (at, in frames) when it or its
	-- speed was last set: a new range starts at its first frame, a new
	-- speed goes on from the frame reached (set_animation_frame_speed:
	-- VoxeLibre's walk keeps pace with the mob)
	local now = buildat.get_time_us() / 1000000
	local c = anim_clock[id]
	if not c or c.first ~= a.first or c.last ~= a.last then
		c = {t = now, at = 0, speed = a.speed, first = a.first, last = a.last}
		anim_clock[id] = c
	elseif c.speed ~= a.speed then
		c.at, c.t, c.speed = c.at + (now - c.t) * c.speed, now, a.speed
	end
	local length = a.last - a.first + 1
	local at = c.at + (now - c.t) * a.speed
	if a.loop then
		at = at % length
	elseif at >= length - 1 then
		at = length - 1
	end
	local step = math.max(1, math.floor(a.speed / POSE_RATE + 0.5))
	local frame = a.first + math.floor(at / step) * step
	if frame ~= look.frame then
		want_model(look.mesh, frame)
		if models[model_key(look.mesh, frame)] then
			look.frame = frame
		end
		-- The node is made again for the new frame, so the packet must
		-- not take this object for one that has not changed
		return true
	end
	return false
end

-- Where one object is now, out of the eight numbers the server sends for
-- each: the id, the middle of its collision box, the box itself, and its
-- yaw.
-- Whether the player's own object is drawn: the third-person views want
-- it, the first-person view has the camera inside it ([THIRD_PERSON])
M.draw_self = false
function M.set_draw_self(on)
	M.draw_self = on and true or false
end

-- **A thing riding the player's own object is drawn from where the client
-- has the player now** ([WIELD_AT_FEET]): the server's place for it is as
-- old as its last step, and in third person the held item trailed the
-- player. Its offset from the player as the server had it, turned on by
-- how far the client has turned since (a bone attachment only: one by
-- position keeps world axes, as drawn_pos_of() does), from the client's
-- own place for the player. Each packet, and each set_self_pose().
-- simplified: the player's box is taken to stand on its feet (its middle
-- half its height up); a box whose bottom is not at the feet moves the
-- item by that much
-- set_self_pose() comes only while the player's own object is drawn, so
-- in first person what rides it stays at the server's place
local self_pose = nil
local riders = {} -- id -> true: what rides the player's own object
local function follow_self(id)
	local have, prev, me = object_nodes[id], object_last[id],
			object_last[M.self_id]
	riders[id] = (have and prev and id ~= M.self_id and
			tostring(math.floor(prev[10])) == M.self_id) or nil
	if not (riders[id] and me and self_pose and M.draw_self) then
		return
	end
	local dx, dy, dz = prev[1] - me[1], prev[2] - me[2], prev[3] - me[3]
	if prev[12] ~= -1000 then
		-- Luanti's yaw is counter-clockwise from +Z and the client's the
		-- other way round (vanilla's sub_player_pos)
		local d = -math.rad(self_pose.yaw) - prev[12]
		local s, c = math.sin(d), math.cos(d)
		dx, dz = dx * c - dz * s, dx * s + dz * c
	end
	have.node.position = magic.Vector3(self_pose.x + dx,
			self_pose.y + me[5] / 2 + dy, self_pose.z + dz)
end

local function place_object(id, v, i)
	-- The id this rides and whether it is forced visible ride the last two
	-- of the stride ([WIELD_AT_FEET] (1)); "0" is nothing.
	local parent_id = tostring(math.floor(v[i + 10]))
	local attached_to_self = parent_id == M.self_id and v[i + 11] == 0
	if (id == M.self_id or attached_to_self) and not M.draw_self then
		-- The player's own object is not drawn: the camera is inside it, so
		-- what a game's own player model comes to is a column of itself up
		-- the middle of the screen. Luanti's client leaves it out of a
		-- first-person view for the same reason, and so is a thing attached
		-- to it unless the game forces it visible ([WIELD_AT_FEET] (1)):
		-- VoxeLibre's wieldview rides the player and must not sit in the
		-- camera. It may have been drawn already -- which object is the
		-- player's own arrives after the objects themselves do -- so it
		-- goes now if it was.
		local had = object_nodes[id]
		if had then
			had.node:Remove()
			object_nodes[id] = nil
		end
		return
	end
	local posed = animate_object(id)
	-- Nothing about it has changed and its node is already made and
	-- placed. **The light is still asked for, but not every packet**:
	-- the hour moves under a mob that does not, so an object that never
	-- moves would keep the colour it was born with -- and asking costs
	-- a Vector3, four calls into C++ and a Color each, which measured
	-- as the whole of what was left after the skip (26 to 30 ms a
	-- packet for 75 objects). One object in LIGHT_TURNS a packet, in
	-- turn, so every one of them is re-lit within about two seconds and
	-- no packet pays for more than a few.
	-- A new one, for its first second, every packet and settled
	-- (M.light_color): a drop lands where a node was just dug
	local have = object_nodes[id]
	if have and have.born then
		have.new = buildat.get_time_us() - have.born < 1000000
		have.born = have.new and have.born or nil
	end
	if not posed and have and object_same(object_last[id], v, i)
			and id ~= M.self_id then
		if have.new or
				((i - 1) / 13 + object_light_turn) % LIGHT_TURNS == 0 then
			light_object(have, v[i + 1], v[i + 2], v[i + 3])
		end
		return
	end
	local node = object_node(id)
	if node == nil then
		-- Out of this packet's budget; the next one places it
		return
	end
	if object_nodes[id] ~= have then
		-- Made just now
		have = object_nodes[id]
		have.new = true
	end
	-- The packet's place is the collision box's middle, which is where a
	-- box scaled to it goes; a model and a sprite are drawn at the
	-- position itself, as Luanti draws them ([OBJECT_SELECTION_BOX]):
	-- a mob's model stood half its height up in the air
	local mid = (have.drawn_as == "mesh" or have.drawn_as == "sprite") and
			object_looks[id] and object_looks[id].middle
	if mid then
		node.position = magic.Vector3(v[i + 1] - mid[1], v[i + 2] - mid[2],
				v[i + 3] - mid[3])
	else
		node.position = magic.Vector3(v[i + 1], v[i + 2], v[i + 3])
	end
	-- The player's own model is the client's to place: see set_self_pose
	if id == M.self_id and self_pose then
		node.position = magic.Vector3(self_pose.x, self_pose.y, self_pose.z)
	end
	-- What the object collides with, which is what is aimed at: a model is
	-- drawn at its own size and that is not the same box -- a mob authored
	-- small is a mob nobody could hit. See M.pointed_object().
	have.box = {v[i + 4], v[i + 5], v[i + 6]}
	light_object(have, v[i + 1], v[i + 2], v[i + 3])
	if have.drawn_as == "mesh" then
		-- A model is drawn at the size the object asked for rather than at
		-- what it collides with, and it is authored in Luanti's own scene
		-- units, where a node is ten across -- which is the tenth
		local size = have.look.size or {1, 1, 1}
		node.scale = magic.Vector3(math.max(0.005, size[1] / 10),
				math.max(0.005, size[2] / 10),
				math.max(0.005, size[3] / 10))
	else
		node.scale = magic.Vector3(v[i + 4], v[i + 5], v[i + 6])
	end
	-- Luanti's rotation is radians and Urho's euler is degrees; a billboard
	-- turns with the camera and does not care. Luanti's object rotation is
	-- roll (Z), then pitch (X), then yaw (Y), which is the order Urho's
	-- euler composes in.
	-- simplified: the pitch's and roll's signs are taken as the yaw's,
	-- which draws right; whether Luanti's right-handed object rotation
	-- flips them is not checked against a shot yet.
	node.rotation = magic.Quaternion(math.deg(v[i + 8]), math.deg(v[i + 7]),
			math.deg(v[i + 9]))
	if id == M.self_id and self_pose then
		node.rotation = magic.Quaternion(0, self_pose.yaw, 0)
	end
	-- Placed: what it was placed with, for the next packet to compare
	local prev = object_last[id]
	if prev == nil then
		prev = {}
		object_last[id] = prev
	end
	for k = 1, 12 do
		prev[k] = v[i + k]
	end
	follow_self(id)
end

buildat.sub_packet("luanti:objects", function(data)
	if not object_scene then
		return
	end
	local t0 = buildat.get_time_us()
	local v = cereal.binary_input(data, {"array", "double"})
	local t1 = buildat.get_time_us()
	local seen = {}
	local STRIDE = 13
	local i = 1
	object_build_left_us = OBJECT_BUILD_BUDGET_US
	objects_deferred = 0
	object_light_turn = (object_light_turn + 1) % LIGHT_TURNS
	while i + STRIDE - 1 <= #v do
		local id = tostring(math.floor(v[i]))
		seen[id] = true
		place_object(id, v, i)
		i = i + STRIDE
	end
	local t2 = buildat.get_time_us()
	-- A slow packet says where it went: decoding the doubles, or placing
	-- **At info over twenty milliseconds** ([PACKET_STALL]'s step 1,
	-- 2026-09-25): this line is the only place the decode and the
	-- placing are told apart, and at debug it never reached a log --
	-- a client at -l 4 prints no Lua debug at all, so the measurement
	-- the item asks for could not be taken. Twenty is a third of a
	-- frame at 60 and rare enough not to be noise.
	local said = (t2 - t0 >= 20000) and log.info or log.debug
	if t2 - t0 >= 8000 or objects_deferred > 0 then
		said(log, string.format("objects: %d in %.0f ms: decode %.0f ms, " ..
				"place %.0f ms (built %.0f ms, %d deferred)", #v / STRIDE,
				(t2 - t0) / 1000, (t1 - t0) / 1000, (t2 - t1) / 1000,
				(OBJECT_BUILD_BUDGET_US - object_build_left_us) / 1000,
				objects_deferred))
	end
	-- What is not in the list any more has been removed
	for id, have in pairs(object_nodes) do
		if not seen[id] then
			have.node:Remove()
			object_nodes[id] = nil
			object_looks[id] = nil
			anim_clock[id] = nil
			object_last[id] = nil
		end
	end
end)

--
-- The sounds
--
-- One Urho3D SoundSource per sound the server started: at a place in the
-- world, on an object it follows, or in the player's own head, which is
-- Luanti's own three. The fades run here, and a source that has finished
-- takes its node with it. The scene is the game's, the same one the objects
-- are drawn in; nothing plays until a game has said which.
--
-- The drawing half is extensions/luanti_client's world.lua, near enough
-- verbatim; what is different is the shape of the message, which is this
-- module's own -- see lua/sound.lua.

-- A positioned sound at Luanti's gain ([SOUND_GAIN_LUANTI]): three
-- times the asked one, over the distance from 1 node out (OpenAL's
-- inverse distance, clamped), never over 1 (AL_MAX_GAIN) -- the world
-- against the music as in Luanti. Urho3D's own attenuation is off (near
-- and far beyond any world), its panning kept.
-- One table: the main chunk is at Lua's 200 locals. ear: where the
-- listener was at the last update.
-- generated: media name -> a Sound the app made ([SKELENTI_SOUNDS]).
local snd = {NO_ATTENUATION = 1e9, ear = nil, generated = {}}

-- set_sound(media_name, sound): a Sound the app made, played wherever
-- the media file of that name would be -- the server's half is
-- set_generated_sounds() in api.h, which says which names there are
function M.set_sound(name, sound)
	snd.generated[name] = sound
end
local handle_sounds = {}

function snd.heard(entry)
	if not entry.positional or not snd.ear then
		return entry.gain
	end
	local d = (entry.node.position - snd.ear):Length()
	return math.min(1, 3 * entry.gain / math.max(d, 1))
end

local function stop_sound(handle)
	local entry = handle_sounds[handle]
	if entry == nil then
		return
	end
	handle_sounds[handle] = nil
	entry.source:Stop()
	entry.node:Remove()
end

local function play_sound(handle, name, gain, pitch, loop, fade, location,
		x, y, z, object_id, far)
	if object_scene == nil then
		return
	end
	local sound = snd.generated[name] or
			magic.cache:GetResource("Sound", MEDIA_PREFIX .. name)
	if sound == nil then
		log:warning("luanti:sound: no sound \"" .. name .. "\"")
		return
	end
	sound.looped = loop
	local node = object_scene:CreateChild("sound")
	local source
	local follows = location == "object" and object_id ~= "0" and
			object_id or nil
	if location == "local" then
		source = node:CreateComponent("SoundSource")
	else
		local at = follows and object_nodes[follows]
		node.position = at and at.node.position or magic.Vector3(x, y, z)
		source = node:CreateComponent("SoundSource3D")
		source.nearDistance = snd.NO_ATTENUATION
		source.farDistance = snd.NO_ATTENUATION
	end
	source.soundType = magic.SOUND_EFFECT
	local entry = {node = node, source = source, started = false,
			object_id = follows, positional = location ~= "local"}
	-- A fade on the packet means it starts silent and comes up to the gain
	-- it asked for
	if fade > 0 then
		entry.target = gain
		entry.step = fade
		gain = 0
	end
	entry.gain = gain
	source.gain = snd.heard(entry)
	if pitch > 0 and pitch ~= 1 then
		source.frequency = sound.frequency * pitch
	end
	source:Play(sound)
	log:debug(string.format("luanti:sound: %s gain %.3f %s heard at %.3f",
			name, gain, location, source.gain))
	-- A loop is a game's music or ambience: few, and what a check waits for
	if loop then
		log:info("luanti:sound: " .. name .. " looped")
	end
	stop_sound(handle)
	handle_sounds[handle] = entry
end

-- One step of a fade, the extension's ([LUANTI_SHARED])
local _, _, sounds_proto = buildat.run_script_file("luanti/sounds.lua")
local fade_step = sounds_proto.fade_step

-- **A footstep** ([NO_SOUND], 2026-09-25): official Luanti plays these
-- in the engine off the player's own movement, so nothing on the wire
-- ever asks for one and a game that never mentions sound still sounds
-- right. The game says where a foot is and what it is on; this decides
-- whether that is a step and what it sounds like.
--
-- **The stride is a distance, not a timer**: it keeps up with a run,
-- and a player edging along a ledge does not patter.
-- What a node sounds like underfoot: name -> {gain, pitch, files}. The
-- records arrive with the dig properties, which are parsed further down
-- this file -- declared here because a local is only in scope after its
-- declaration and this is what reads it.
local node_footsteps = {}
-- And what a node sounds like dug and placed ([NO_SOUND], 2026-09-25).
-- The builtin plays those two with the digger excluded -- official's own
-- client plays them for the player who did it -- so these are the
-- client's to play or nobody's.
local node_dug = {}
local node_placed = {}
-- And the swing's ([DIG_SWING_SOUND]): a node's dig sound (false for one
-- that is silent on purpose; "__group:<group>" the default's by group),
-- and an item's use sound at something and at nothing
local node_dig = {}
local item_use = {}
local item_use_air = {}
local action_sound_n = 0
local FOOTSTEP_STRIDE = 1.9
local footstep_at = nil
local footstep_n = 0
local footstep_said = {}

-- footstep(node_name, x, y, z) -> whether one was played
function M.footstep(node_name, x, y, z)
	local spec = node_footsteps[node_name or ""]
	if spec == nil or object_scene == nil then
		-- Said once a node: a game whose nodes carry no footstep is
		-- silent on purpose, and one whose do and is silent anyway is
		-- this line missing its record
		if node_name and not footstep_said[node_name] then
			footstep_said[node_name] = true
			log:info("luanti: no footstep for " .. node_name)
		end
		return false
	end
	if footstep_at then
		local dx, dz = x - footstep_at.x, z - footstep_at.z
		if dx * dx + dz * dz < FOOTSTEP_STRIDE * FOOTSTEP_STRIDE then
			return false
		end
	end
	footstep_at = {x = x, z = z}
	footstep_n = footstep_n + 1
	local file = spec.files[math.random(#spec.files)]
	-- In the player's own head, which is where their own feet are; a
	-- positioned sound at the player's position is the same thing with
	-- a distance model in the way
	play_sound("foot:" .. footstep_n, file, spec.gain, spec.pitch,
			false, 0, "local", x, y, z, "0", 32)
	-- Once a node at info and every step at debug: a walk across a
	-- world is hundreds of steps, and what a reader wants to know is
	-- which nodes have been heard from
	if not footstep_said[node_name] then
		footstep_said[node_name] = true
		log:info("luanti: footstep on " .. tostring(node_name) .. ": " ..
				file)
	else
		log:debug("luanti: footstep on " .. tostring(node_name) .. ": " ..
				file)
	end
	return true
end

-- dig_sound(node_name, x, y, z) / place_sound(...) -> whether one played.
-- The player's own dig and place, which the server does not send them:
-- item.lua's node_dig and item_place call sound_play with
-- exclude_player = the player who did it, since official Luanti's client
-- plays its own. In the head at the spec's gain, as its SoundMaker plays
-- them ([SOUND_GAIN_LUANTI]); at the place they were a distance model's
-- third of Luanti's.
local action_said = {}

local function action_sound(which, table_of, node_name, x, y, z)
	local spec = table_of[node_name or ""]
	if spec == nil or object_scene == nil then
		-- Once a node, the way a footstep says it: a game whose nodes
		-- carry no dug sound is silent on purpose, and one whose do and
		-- is silent anyway is this record missing or the scene not up
		local key = which .. ":" .. tostring(node_name)
		if not action_said[key] then
			action_said[key] = true
			log:info("luanti: no " .. which .. " sound for " ..
					tostring(node_name) ..
					(object_scene == nil and " (no scene yet)" or ""))
		end
		return false
	end
	action_sound_n = action_sound_n + 1
	local file = spec.files[math.random(#spec.files)]
	play_sound(which .. ":" .. action_sound_n, file, spec.gain, spec.pitch,
			false, 0, "local", x, y, z, "0", 32)
	-- Once a node at info and the rest at debug, as a footstep says it:
	-- a session digs hundreds of nodes and what a reader wants is which
	-- kinds have been heard from
	local key = which .. ":" .. tostring(node_name)
	if not action_said[key] then
		action_said[key] = true
		log:info("luanti: " .. which .. " " .. tostring(node_name) ..
				": " .. file)
	else
		log:debug("luanti: " .. which .. " " .. tostring(node_name) ..
				": " .. file)
	end
	return true
end

function M.dig_sound(node_name, x, y, z)
	return action_sound("dug", node_dug, node_name, x, y, z)
end

function M.place_sound(node_name, x, y, z)
	return action_sound("place", node_placed, node_name, x, y, z)
end

-- swing_sound(node_name, main_group, item_name, pointing, x, y, z) -> the
-- dig file, the use file, each nil for none. Official's
-- SoundMaker::cameraPunchLeft, played as the swing crosses 0.15: the dug
-- node's dig sound (node_name nil when no diggable node is being dug), its
-- "__group" by the group the dig went by when it says nothing, and the
-- wielded item's sound_use at something, sound_use_air at nothing. Both in
-- the player's head, as official's.
function M.swing_sound(node_name, main_group, item_name, pointing, x, y, z)
	if object_scene == nil then
		return nil, nil
	end
	local played = {}
	local dig = nil
	if node_name then
		dig = node_dig[node_name]
		if dig == nil and main_group then
			dig = node_dig["__group:" .. main_group]
		end
	end
	local use = (pointing and item_use or item_use_air)[item_name or ""]
	for i, spec in ipairs({dig or false, use or false}) do
		if spec and #spec.files > 0 then
			action_sound_n = action_sound_n + 1
			local file = spec.files[math.random(#spec.files)]
			play_sound("swing:" .. action_sound_n, file, spec.gain, spec.pitch,
					false, 0, "local", x, y, z, "0", 32)
			played[i] = file
		end
	end
	return played[1], played[2]
end

-- The fades, the sounds that follow an object, and the nodes of the ones
-- that have finished. The game calls this every frame.
-- ear: where the listener is, for the positioned sounds' gain
function M.update_sounds(dtime, ear)
	snd.ear = ear or snd.ear
	for handle, entry in pairs(handle_sounds) do
		local follow = entry.object_id and object_nodes[entry.object_id]
		if follow then
			entry.node.position = follow.node.position
		end
		if entry.target then
			local gain, done = fade_step(entry.gain, entry.target, entry.step,
					dtime)
			entry.gain = gain
			if done then
				entry.target = nil
				if gain <= 0 then
					stop_sound(handle)
				end
			end
		end
		-- Not on the frame it started: a source has not been mixed yet and
		-- says it is not playing
		if handle_sounds[handle] then
			entry.source.gain = snd.heard(entry)
			if entry.started and not entry.source.playing then
				stop_sound(handle)
			end
			entry.started = true
		end
	end
end

buildat.sub_packet("luanti:sound", function(data)
	local v = cereal.binary_input(data, {"array", "string"})
	if v[1] == "play" then
		play_sound(v[2], v[3], tonumber(v[4]) or 1, tonumber(v[5]) or 1,
				v[6] == "1", tonumber(v[7]) or 0, v[8], tonumber(v[9]) or 0,
				tonumber(v[10]) or 0, tonumber(v[11]) or 0, v[12],
				tonumber(v[13]) or 32)
	elseif v[1] == "stop" then
		stop_sound(v[2])
	elseif v[1] == "fade" then
		local entry = handle_sounds[v[2]]
		if entry then
			entry.step = tonumber(v[3]) or 1
			entry.target = tonumber(v[4]) or 0
		end
	end
end)

--
-- The particles
--
-- An Urho3D ParticleEmitter per spawner, and one of a single particle that
-- fires once. The drawing is extensions/luanti_client's world.lua near
-- enough verbatim -- what is different is the shape of the message, which
-- is lua/particles.lua's and says what each index is.

local SINGLE_PARTICLE_MAX = 128
local DYING_SPAWNERS_MAX = 32
local PARTICLE_FRAMES_MAX = 64
-- A particle's size is in Luanti's scene units, where a node is ten across;
-- everything here is in nodes
local PARTICLE_SIZE_TO_NODES = 1 / 10

local particle_nodes = {}     -- spawner id -> what draws it
local dying_spawners = {}     -- ones whose particles are still expiring
local single_particles = {}

local function particle_frames(effect, tex, anim, ttl)
	if tex == nil or anim.type == 0 then
		return
	end
	local frames = {}
	local step = nil
	if anim.type == 1 then
		-- A vertical strip. One frame is as tall as the image is wide,
		-- times the aspect the game asked for.
		local frame_h = tex.width / anim.aspect_w * anim.aspect_h
		local count = frame_h > 0 and
				math.floor(tex.height / frame_h + 0.5) or 1
		if count < 2 then
			return
		end
		for i = 0, count - 1 do
			frames[#frames + 1] = {0, i / count, 1, (i + 1) / count}
		end
		-- Luanti's length is the whole animation
		step = anim.length / count
	elseif anim.type == 2 then
		-- A sheet, left to right and then down, which is the order Luanti
		-- numbers its frames in
		local across = math.max(1, anim.frames_w)
		local down = math.max(1, anim.frames_h)
		if across * down < 2 then
			return
		end
		for y = 0, down - 1 do
			for x = 0, across - 1 do
				frames[#frames + 1] = {x / across, y / down,
						(x + 1) / across, (y + 1) / down}
			end
		end
		-- And here it is the length of one frame
		step = anim.length
	end
	if step == nil or step <= 0 then
		return
	end
	local at, i, added = 0, 1, 0
	while at < ttl and added < PARTICLE_FRAMES_MAX do
		local f = frames[i]
		effect:AddTextureTime(magic.Rect(f[1], f[2], f[3], f[4]), at)
		at = at + step
		i = i % #frames + 1
		added = added + 1
	end
end

-- What velocity range a direction box holds, the extension's
-- ([LUANTI_SHARED])
local _, _, particles_proto = buildat.run_script_file("luanti/particles.lua")
local speed_range = particles_proto.speed_range

local function middle(a, b)
	return {(a[1] + b[1]) / 2, (a[2] + b[2]) / 2, (a[3] + b[3]) / 2}
end

-- The effect is handed to the emitter by the caller, once it has set the
-- fields that differ between a spawner and a single particle: assigning the
-- same effect twice is a no-op in Urho3D, so everything has to be on it
-- before it goes on.
local particle_materials = {}
local function particle_effect(resource, amount, ttl_min, ttl_max, size_min,
		size_max, vel_min, vel_max, acc, active_time, anim)
	local effect = magic.ParticleEffect.new()
	-- One material a texture, made the first time it is drawn and kept
	-- here, which is also what keeps it alive: every particle of a snow
	-- storm made its own, and that was half of what a particle cost
	-- ([PACKET_STALL], 2026-10-03)
	local cached = particle_materials[resource]
	local material = cached and cached.material
	local tex = cached and cached.tex
	if not cached then
		material = magic.Material.new()
		tex = magic.cache:GetResource("Texture2D", resource)
		if tex then
			-- Nearest magnification and mipmapped minification, the way
			-- extensions/luanti_client's particles are: crisp up close, and
			-- a particle far away is not a sparkle of whichever texel won
			-- ([RENDER_SURVEY], texture filtering)
			tex.filterMode = magic.FILTER_NEAREST_ANISOTROPIC
			material:SetTexture(0, tex)
		end
		-- Particles are blended rather than cut out -- smoke and a spark
		-- are soft-edged -- and unlit, like the objects. Urho3D ships the
		-- technique.
		material:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/DiffUnlitParticleAlpha.xml"))
		-- **Held by the resource cache, not by this table** ([PARTICLE_SEGV]):
		-- a Material made in Lua lives only while the engine holds it, so
		-- when the last effect using one went it was freed, and the next
		-- particle of that texture handed the freed one to SetMaterial --
		-- SIGSEGV in RefCounted. The cache's reference keeps it.
		magic.cache:AddManualResource(material, "luanti_particle/" ..
				resource:gsub("[^%w%._%-/]", "_"):gsub("%.%.", "_"))
		particle_materials[resource] = {material = material, tex = tex}
	end
	effect.material = material
	effect.numParticles = amount
	effect.relative = false
	effect.scaled = true
	effect.sorted = true
	-- A fresh emitter is not in view until it has a particle in it, and
	-- Urho3D does not update an emitter that is out of view: without this
	-- the first particle is never emitted and nothing is ever seen
	effect.updateInvisible = true
	-- White, and only white: a particle with no colour frame at all comes
	-- out as one anyway, but saying so is what keeps it that way
	effect:AddColorTime(magic.Color(1, 1, 1, 1), 0)
	particle_frames(effect, tex, anim, ttl_max)
	effect.minTimeToLive = ttl_min
	effect.maxTimeToLive = ttl_max
	-- Luanti's size is the whole particle across and a billboard's is half
	-- of one side, so a rain drop's size of 4 is four tenths of a node
	local half = PARTICLE_SIZE_TO_NODES / 2
	effect:SetMinParticleSize(magic.Vector2(size_min * half, size_min * half))
	effect:SetMaxParticleSize(magic.Vector2(size_max * half, size_max * half))
	effect:SetMinDirection(magic.Vector3(vel_min[1], vel_min[2], vel_min[3]))
	effect:SetMaxDirection(magic.Vector3(vel_max[1], vel_max[2], vel_max[3]))
	local near, far = speed_range(vel_min, vel_max)
	effect.minVelocity = near
	effect.maxVelocity = far
	effect:SetConstantForce(magic.Vector3(acc[1], acc[2], acc[3]))
	effect.dampingForce = 0
	-- An active time with no inactive time after it is one burst and then
	-- nothing, which is what a spawner with a time and a single particle
	-- both are. Zero active time never stops, which is what a spawner with
	-- no time is.
	effect.activeTime = active_time
	effect.inactiveTime = 0
	return effect, material
end

-- What makes two spawners the same spawner: everything about them that this
-- draws. A game that takes its spawner away and adds it again -- VoxeLibre's
-- weather does, twenty times a second -- gets the emitter it had back rather
-- than a new one, which is what keeps its rain falling in a stream instead
-- of in fifty-millisecond bursts.
local function spawner_signature(p)
	local n = {p.texture, p.amount, p.time, p.attached, p.vertical and 1 or 0}
	for _, v in ipairs({p.pos_min, p.pos_max, p.vel_min, p.vel_max,
			p.acc_min, p.acc_max}) do
		for i = 1, 3 do
			n[#n + 1] = string.format("%g", v[i])
		end
	end
	for _, v in ipairs({p.exp_min, p.exp_max, p.size_min, p.size_max}) do
		n[#n + 1] = string.format("%g", v)
	end
	return table.concat(n, "/")
end

local function remove_spawner(id)
	local old = particle_nodes[id]
	if old == nil then
		return
	end
	particle_nodes[id] = nil
	-- The particles a spawner has already made outlive it, which is what
	-- Luanti does: its own particles are not owned by the spawner that made
	-- them. So the emitter stops emitting and the node goes when the last
	-- particle it made has expired.
	if old.emitter then
		old.emitter.emitting = false
	end
	old.life = old.ttl_max + 0.2
	old.attached = nil
	dying_spawners[#dying_spawners + 1] = old
	-- A cap, because each of these holds a pool of billboards: the oldest
	-- goes, which is the one whose particles are nearest the end of their
	-- lives anyway
	while #dying_spawners > DYING_SPAWNERS_MAX do
		table.remove(dying_spawners, 1).node:Remove()
	end
end

local function add_spawner(id, p)
	local resource = texture_of(p.texture)
	log:debug("luanti:particles: spawner " .. id .. " " .. p.texture ..
			" -> " .. tostring(resource) .. ", attached " ..
			tostring(p.attached))
	if resource == nil or object_scene == nil then
		return
	end
	local pos = middle(p.pos_min, p.pos_max)
	-- The same spawner as one that was taken away a moment ago: pick its
	-- emitter back up where it left off
	local signature = spawner_signature(p)
	for i, e in ipairs(dying_spawners) do
		if e.signature == signature then
			table.remove(dying_spawners, i)
			if e.emitter then
				e.emitter.emitting = true
			end
			e.life = p.time > 0 and (p.time + p.exp_max + 0.5) or nil
			e.attached = p.attached ~= "0" and p.attached or nil
			e.offset = pos
			particle_nodes[id] = e
			return
		end
	end
	local node = object_scene:CreateChild("particles")
	node.position = magic.Vector3(pos[1], pos[2], pos[3])
	local amount = math.max(1, math.min(p.amount, 1000))
	local effect, material = particle_effect(resource, amount,
			math.max(0.01, p.exp_min), math.max(0.01, p.exp_max),
			math.max(0.001, p.size_min), math.max(0.001, p.size_max),
			p.vel_min, p.vel_max, middle(p.acc_min, p.acc_max), p.time,
			p.animation)
	-- What the emitter box is: the position range, which the node sits in
	-- the middle of
	effect.emitterType = 1 -- EMITTER_BOX
	effect:SetEmitterSize(magic.Vector3(
			math.max(0, p.pos_max[1] - p.pos_min[1]),
			math.max(0, p.pos_max[2] - p.pos_min[2]),
			math.max(0, p.pos_max[3] - p.pos_min[3])))
	-- Luanti spawns amount particles over time seconds, and amount a second
	-- when there is no time at all
	local rate = p.time > 0 and amount / p.time or amount
	effect.minEmissionRate = rate
	effect.maxEmissionRate = rate
	local emitter = node:CreateComponent("ParticleEmitter")
	emitter.effect = effect
	emitter.emitting = true
	emitter.castShadows = false
	-- Luanti's vertical particle is an upright quad turned to the player
	-- about Y rather than one facing the camera, which is what makes a rain
	-- drop look like a falling drop rather than a blob
	if p.vertical then
		emitter.faceCameraMode = magic.FC_ROTATE_Y
	end
	-- The effect and its material are kept for as long as the emitter is:
	-- both were made in Lua, and a Lua-made Urho3D object is destroyed when
	-- the last Lua reference to it goes, whatever the engine still holds.
	particle_nodes[id] = {node = node, emitter = emitter, effect = effect,
			material = material, signature = signature,
			life = p.time > 0 and (p.time + p.exp_max + 0.5) or nil,
			attached = p.attached ~= "0" and p.attached or nil,
			offset = pos, ttl_max = math.max(0.01, p.exp_max)}
end

local function add_single(p)
	if #single_particles >= SINGLE_PARTICLE_MAX then
		return
	end
	local resource = texture_of(p.texture)
	if resource == nil or object_scene == nil then
		return
	end
	local ttl = math.max(0.01, p.exp_min)
	local node = object_scene:CreateChild("particle")
	node.position = magic.Vector3(p.pos_min[1], p.pos_min[2], p.pos_min[3])
	local effect, material = particle_effect(resource, 1, ttl, ttl,
			math.max(0.001, p.size_min), math.max(0.001, p.size_max),
			p.vel_min, p.vel_max, middle(p.acc_min, p.acc_max), 0.05,
			p.animation)
	effect.emitterType = 0 -- EMITTER_SPHERE, of no size
	effect:SetEmitterSize(magic.Vector3(0, 0, 0))
	effect.minEmissionRate = 100
	effect.maxEmissionRate = 100
	local emitter = node:CreateComponent("ParticleEmitter")
	emitter.effect = effect
	emitter.emitting = true
	emitter.castShadows = false
	if p.vertical then
		emitter.faceCameraMode = magic.FC_ROTATE_Y
	end
	single_particles[#single_particles + 1] = {node = node, life = ttl + 0.5,
			effect = effect, material = material}
end

-- Ages the emitters and takes away the ones that are done with. A spawner
-- with no time of its own is not aged: the server deletes it. The game calls
-- this every frame.
-- eye is where the player is, for a spawner attached to their own object --
-- which is not one this client draws; see lua/particles.lua. It may be nil
-- for a game that has no player of its own.
function M.update_particles(dtime, eye)
	for id, entry in pairs(particle_nodes) do
		-- A spawner attached to an object has its positions relative to
		-- that object and follows it; a game's weather is a spawner
		-- attached to the player
		local p = nil
		if entry.attached == "self" then
			p = eye
		elseif entry.attached then
			local at = object_nodes[entry.attached]
			p = at and at.node.position or nil
		end
		if p then
			entry.node.position = magic.Vector3(p.x + entry.offset[1],
					p.y + entry.offset[2], p.z + entry.offset[3])
		end
		if entry.life then
			entry.life = entry.life - dtime
			if entry.life <= 0 then
				entry.node:Remove()
				particle_nodes[id] = nil
			end
		end
	end
	local d = 1
	while d <= #dying_spawners do
		local entry = dying_spawners[d]
		entry.life = entry.life - dtime
		if entry.life <= 0 then
			entry.node:Remove()
			table.remove(dying_spawners, d)
		else
			d = d + 1
		end
	end
	local i = 1
	while i <= #single_particles do
		local entry = single_particles[i]
		entry.life = entry.life - dtime
		if entry.life <= 0 then
			entry.node:Remove()
			table.remove(single_particles, i)
		else
			i = i + 1
		end
	end
end

-- The record lua/particles.lua sends, by index
local function parse_particles(v)
	local function num(i)
		return tonumber(v[i]) or 0
	end
	local function v3(i)
		return {num(i), num(i + 1), num(i + 2)}
	end
	return {
		texture = v[3],
		amount = math.floor(num(4)),
		time = num(5),
		vertical = v[6] == "1",
		attached = v[7],
		pos_min = v3(8), pos_max = v3(11),
		vel_min = v3(14), vel_max = v3(17),
		acc_min = v3(20), acc_max = v3(23),
		exp_min = num(26), exp_max = num(27),
		size_min = num(28), size_max = num(29),
		animation = {type = math.floor(num(30)), aspect_w = num(31),
				aspect_h = num(32), length = num(33),
				frames_w = math.floor(num(34)),
				frames_h = math.floor(num(35))},
	}
end

buildat.sub_packet("luanti:particles", function(data)
	local v = cereal.binary_input(data, {"array", "string"})
	if v[1] == "spawner" then
		remove_spawner(v[2])
		add_spawner(v[2], parse_particles(v))
	elseif v[1] == "particle" then
		add_single(parse_particles(v))
	elseif v[1] == "delete" then
		remove_spawner(v[2])
	end
end)

--
-- The dynamic lights
--
-- core.buildat's lights (builtin/luanti/lua/buildat_api.lua): a light on an
-- object, a held torch being one on the player, or at a place for a moment.
-- Scene point lights, nothing in the map's light ([BUILDAT_WIELD_LIGHT]).
--
-- The range is the light's level in nodes and the falloff over it the
-- map's from a placed torch ([WIELD_LIGHT_LOOK]): res/light_ramp.png the
-- pbr lamp term's curve, res/light_ramp_parity.png the parity modes' --
-- Luanti's light curve, which on the screen is near linear in the level,
-- (level - 1.5) / 11.5 (a VoxeLibre wall at 1, 4, 8 and 12 nodes from a
-- torch read 1, .70, .39 and .04 of the first, 2026-10-12), its peak at
-- 0.81 of a white light's (PARITY_LAMP).
-- simplified: one curve, a level 14 light's, stretched to every level;
-- a lower level is dimmed as well. The map's own light adds under it
-- rather than the brighter being taken, as Luanti does.
local PARITY_LAMP = 0.81

local MAX_DYNAMIC_LIGHTS = 8
-- {kind, id, x, y, z, level, r, g, b, until}, as the server last said
local dynamic_lights = {}
local dynamic_pool = {}
local dynamic_time = 0

buildat.sub_packet("luanti:lights", function(data)
	local v = cereal.binary_input(data, {"array", "string"})
	dynamic_lights = {}
	for i = 1, #v - 9, 10 do
		local ttl = tonumber(v[i + 9]) or 0
		dynamic_lights[#dynamic_lights + 1] = {kind = v[i], id = v[i + 1],
			x = tonumber(v[i + 2]) or 0, y = tonumber(v[i + 3]) or 0,
			z = tonumber(v[i + 4]) or 0, level = tonumber(v[i + 5]) or 0,
			r = tonumber(v[i + 6]) or -1, g = tonumber(v[i + 7]) or -1,
			b = tonumber(v[i + 8]) or -1,
			ends = v[i] == "p" and dynamic_time + ttl or nil}
	end
	local said = {}
	for _, l in ipairs(dynamic_lights) do
		said[#said + 1] = l.kind .. " " .. (l.kind == "o" and
				(l.id == M.self_id and "self" or l.id) or
				(l.x .. "," .. l.y .. "," .. l.z)) .. " " .. l.level
	end
	log:info("luanti:lights: " .. #dynamic_lights .. ": " ..
			table.concat(said, "; "))
end)

-- Where a light is now: an object's drawn node, the player's own light at
-- the hand (eye, the player's eye), a place's middle
local function dynamic_light_pos(l, eye)
	if l.kind == "p" then
		return magic.Vector3(l.x, l.y, l.z)
	end
	if l.id == M.self_id and eye then
		return magic.Vector3(eye.x, eye.y - 0.4, eye.z)
	end
	local have = object_nodes[l.id]
	if have and have.node then
		local p = have.node.position
		return magic.Vector3(p.x, p.y + 0.5, p.z)
	end
	return nil
end

function M.update_lights(dtime, eye)
	dynamic_time = dynamic_time + dtime
	local best = {}
	for _, l in ipairs(dynamic_lights) do
		if not l.ends or l.ends > dynamic_time then
			local p = dynamic_light_pos(l, eye)
			if p then
				local dx, dy, dz = p.x - eye.x, p.y - eye.y, p.z - eye.z
				best[#best + 1] = {d = dx * dx + dy * dy + dz * dz, p = p, l = l}
			end
		end
	end
	table.sort(best, function(a, b) return a.d < b.d end)
	dynamic_now = {}
	for i = 1, math.max(#dynamic_pool, math.min(#best, MAX_DYNAMIC_LIGHTS)) do
		local entry, held = best[i], dynamic_pool[i]
		if entry and not held and object_scene then
			local node = object_scene:CreateChild("dynamic_light_" .. i)
			held = {node = node, light = node:CreateComponent("Light")}
			held.light.lightType = magic.LIGHT_POINT
			held.light.castShadows = false
			-- The map's light is diffuse; a highlight on a texture looks wrong
			held.light.specularIntensity = 0
			dynamic_pool[i] = held
		end
		if held then
			if entry then
				local l, u = entry.l, M.light_units
				held.node.position = entry.p
				held.light.range = l.level
				dynamic_now[#dynamic_now + 1] = {x = entry.p.x, y = entry.p.y,
						z = entry.p.z, level = l.level}
				-- On the pbr path the colour the baked lamp term has at a
				-- full lamp: that is vVertexLight*albedo, and a point light's
				-- diffuse is albedo/pi (PBRVoxel.glsl). Without it, the
				-- old path's light added on top of the baked one, kept low.
				-- A light of no colour of its own is the map's lamp: under
				-- pbr the lamp unit's, else white as the parity modes'
				-- baked lamp light is. A level under 13 dimmer, as a placed
				-- one's light is at the same nibble.
				local r, g, b = 1, 1, 1
				local k = PARITY_LAMP * math.min(1, (l.level - 1.5) / 11.5)
				if l.r >= 0 then
					r, g, b = l.r, l.g, l.b
				end
				if u then
					k = lamp_curve(l.level) * math.pi
					if l.r < 0 then
						r, g, b = u.lamp.r, u.lamp.g, u.lamp.b
					else
						k = k * math.max(u.lamp.r, u.lamp.g, u.lamp.b)
					end
				end
				local key = r * k .. "," .. g * k .. "," .. b * k ..
						(u and "" or ",parity")
				if key ~= held.color then
					held.light.brightness = 1
					held.light.color = magic.Color(r * k, g * k, b * k)
					held.light.rampTexture = magic.cache:GetResource("Texture2D",
							u and "luanti_client/res/light_ramp.png" or
							"luanti_client/res/light_ramp_parity.png")
				end
				held.color = key
				held.node.enabled = true
			else
				held.node.enabled = false
			end
		end
	end
	-- The objects near a light lit by it every frame, and once more as one
	-- leaves its reach: the light moves with its holder, and a still
	-- object's packets stop coming
	for id, have in pairs(object_nodes) do
		if have.node and id ~= M.self_id and
				(have.dyn_lit or #dynamic_now > 0) then
			local p = have.node.position
			local near = near_dynamic(p.x, p.y, p.z)
			if near or have.dyn_lit then
				have.dyn_lit = near
				light_object(have, p.x, p.y, p.z)
			end
		end
	end
end

--
-- The formspecs
--
-- The window a mod puts on the player's screen. formspec.lua says what the
-- elements are, formspec_ui.lua puts Urho3D elements there, and this is the
-- wiring: what a texture and an item and a list are, what a click on the
-- result means, and what goes back to the server.
--
-- What a click on a slot means is here: a stack is picked up whole or in
-- half, put down whole, one at a time or ten at a time, and what is held is
-- a drawing until the server has made the move.
local ok_fs, err_fs, formspec = buildat.run_script_file("luanti/formspec.lua")
if not ok_fs or type(formspec) ~= "table" then
	error("luanti: could not load formspec.lua: " .. tostring(err_fs))
end
-- The HUD a game draws itself: an element per id, under the names Luanti's
-- own HUDADD carries -- pos, align, dir and the rest -- and the flags
-- saying which of the client's own the game wants drawn. Whoever is drawing
-- subscribes; what is here is keeping them.
M.hud_elements = {}
M.hud_flags = 511
-- How much life and breath the player has, which is what the client's own
-- bars draw; a game that draws its own turns those off with the flags
M.stats = {hp = 20, hp_max = 20, breath = 10, breath_max = 10}

local hud_subs = {}

-- sub_hud(f) -> f(elements, flags) every time the game changes what is on
-- the screen, and once now
function M.sub_hud(f)
	hud_subs[#hud_subs + 1] = f
	f(M.hud_elements, M.hud_flags)
end

-- Once a frame, not once a packet: the subscribers redraw the whole HUD,
-- and a game joins with a few hundred hud packets in a row and changes a
-- statbar several times a second after that. The 245 packets of a
-- VoxeLibre join were 2.3 s in one frame ([FORMSPEC_FRAME], the
-- `luanti:hud` row of the fuzz campaign's frame column).
local hud_dirty = false
local function hud_changed()
	hud_dirty = true
end
local function flush_hud()
	if not hud_dirty then
		return
	end
	hud_dirty = false
	for _, f in ipairs(hud_subs) do
		f(M.hud_elements, M.hud_flags)
	end
end
-- Microseconds this module's own frame work took since the frame peak
-- last read it ([FRAME_PEAK]): the HUD redraw, which is most of it
M.frame_us = 0
magic.SubscribeToEvent("Update", function()
	local t0 = buildat.get_time_us()
	flush_hud()
	M.frame_us = M.frame_us + buildat.get_time_us() - t0
end)

-- What the client's own hotbar is drawn out of, as the game last said it:
-- how many slots, the picture behind them and the one that marks the slot in
-- hand. Luanti's client owns the hotbar and a game only says these three
-- things about it. The images are texture modifier expressions like any
-- other; luanti.texture() is what turns one into something drawable.
M.hotbar = {count = 8}

buildat.sub_packet("luanti:hud", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local op = values[1]
	if op == "clear" then
		M.hud_elements = {}
	elseif op == "add" then
		local id = tonumber(values[2])
		local e = {}
		for i = 3, #values - 1, 2 do
			e[values[i]] = values[i + 1]
		end
		if id then
			M.hud_elements[id] = e
		end
	elseif op == "change" then
		local id = tonumber(values[2])
		local e = id and M.hud_elements[id]
		if e then
			e[values[3]] = values[4]
		end
	elseif op == "remove" then
		local id = tonumber(values[2])
		if id then
			M.hud_elements[id] = nil
		end
	elseif op == "flags" then
		M.hud_flags = tonumber(values[2]) or M.hud_flags
		log:info("luanti:hud flags " .. M.hud_flags)
	elseif op == "hotbar" then
		M.hotbar = {
			count = math.max(1, math.min(32, tonumber(values[2]) or 8)),
			image = values[3] ~= "" and values[3] or nil,
			selected_image = values[4] ~= "" and values[4] or nil,
		}
	elseif op == "lighting" then
		-- The game's set_lighting() for this player: how dark a shadow is
		-- (0 none, 1 black) and the colour saturation (1 as is)
		M.lighting = {
			shadow_intensity = tonumber(values[2]) or 0,
			saturation = tonumber(values[3]) or 1,
		}
	elseif op == "stats" then
		M.stats = {
			hp = tonumber(values[2]) or 0,
			hp_max = tonumber(values[3]) or 20,
			breath = tonumber(values[4]) or 11,
			breath_max = tonumber(values[5]) or 11,
		}
	end
	hud_changed()
end)

-- Luanti wraps a translated line in escape sequences; this takes them out.
-- The chat log goes through it already, and so does anything else drawing
-- text a game wrote.
function M.strip_escapes(text)
	return formspec.strip_escapes(text or "")
end

-- A line of a game's text as the pieces it is drawn in, each with the colour
-- the markup in it asked for: {{text =, color = {r, g, b} or nil}, ...}.
-- Whoever draws text with colour in it goes through this instead of
-- strip_escapes(); see core.colorize() on the other side.
function M.text_segments(text)
	return formspec.split_colors(text or "")
end

-- Whether a flag is set in what the game asked for; the names are Luanti's
-- HUD_FLAG_* and hud.lua has the numbers
function M.hud_flag(name)
	local FLAG = {hotbar = 1, healthbar = 2, crosshair = 4, wielditem = 8,
			breathbar = 16, minimap = 32, minimap_radar = 64,
			basic_debug = 128, chat = 256}
	local bit = FLAG[name]
	if bit == nil then
		return true
	end
	return math.floor(M.hud_flags / bit) % 2 == 1
end

-- The sky the game says it has: the colour overhead, the colour at the
-- horizon, and whether there are clouds and how thick. Whoever draws the sky
-- subscribes; see set_sky() in the module's lua/entity.lua for what a mod
-- can say and what of it crosses.
M.sky = nil

local sky_subs = {}

-- What the player's movement is multiplied by: set_physics_override() on
-- the server, arriving as name/value pairs. The client's own constants times
-- these are what a game's speed boots, low gravity and jump curse are made
-- of. The whole table comes each time, so what is here is what is in force.
local physics = {speed = 1, jump = 1, gravity = 1, sneak = 1,
		sneak_glitch = 0}
local physics_subs = {}

function M.physics()
	return physics
end

function M.sub_physics(f)
	physics_subs[#physics_subs + 1] = f
	f(physics)
end

buildat.sub_packet("luanti:physics", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local t = {}
	for i = 1, #values - 1, 2 do
		t[values[i]] = tonumber(values[i + 1]) or 1
	end
	physics = t
	for _, f in ipairs(physics_subs) do
		f(physics)
	end
end)

-- How wide the view is and where the eyes are: set_fov() and
-- set_eye_offset() on the server. fov is in degrees, or a multiplier of the
-- client's own when is_multiplier is set, and 0 means "the client decides".
local camera = {fov = 0, is_multiplier = false, transition = 0,
		eye = {x = 0, y = 0, z = 0}}
local camera_subs = {}

function M.camera()
	return camera
end

function M.sub_camera(f)
	camera_subs[#camera_subs + 1] = f
	f(camera)
end

buildat.sub_packet("luanti:camera", function(data)
	local v = cereal.binary_input(data, {"array", "string"})
	camera = {
		fov = tonumber(v[1]) or 0,
		is_multiplier = (tonumber(v[2]) or 0) ~= 0,
		transition = tonumber(v[3]) or 0,
		eye = {x = tonumber(v[4]) or 0, y = tonumber(v[5]) or 0,
				z = tonumber(v[6]) or 0},
		-- Which modes the camera key may reach ([THIRD_PERSON])
		mode = v[7] or "any",
	}
	log:info("luanti:camera: fov " .. camera.fov ..
			(camera.is_multiplier and " (multiplier)" or "") ..
			", eyes " .. camera.eye.x .. "," .. camera.eye.y .. "," ..
			camera.eye.z)
	for _, f in ipairs(camera_subs) do
		f(camera)
	end
end)

function M.sub_sky(f)
	sky_subs[#sky_subs + 1] = f
	if M.sky then
		f(M.sky)
	end
end

buildat.sub_packet("luanti:sky", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local e = {}
	for i = 1, #values - 1, 2 do
		e[values[i]] = values[i + 1]
	end
	local function rgb(s)
		if s == nil then
			return nil
		end
		local r, g, b = string.match(s, "^([^,]*),([^,]*),(.*)$")
		if r == nil then
			return nil
		end
		return {r = tonumber(r) or 0, g = tonumber(g) or 0,
				b = tonumber(b) or 0}
	end
	-- A skybox's six pictures, in Luanti's order: Y+, Y-, X+, X-, Z-, Z+.
	-- Empty unless the game said type = "skybox".
	local textures = {}
	for i = 1, 6 do
		textures[i] = e["texture" .. i]
	end
	M.sky = {
		type = e.type or "regular",
		textures = textures,
		zenith = rgb(e.zenith),
		horizon = rgb(e.horizon),
		-- The same two at the other hours of the day, for whoever draws a
		-- sky that follows a clock; nil where the game said nothing
		night_zenith = rgb(e.night_zenith),
		night_horizon = rgb(e.night_horizon),
		dawn_zenith = rgb(e.dawn_zenith),
		dawn_horizon = rgb(e.dawn_horizon),
		-- What the sun and the moon paint the horizon with as they cross
		-- it, and whether the game meant them: "custom" is the game's own
		-- two, "default" is Luanti's classic tinting. Both are always
		-- filled, at Luanti's own defaults where the game said nothing.
		sun_tint = rgb(e.sun_tint),
		moon_tint = rgb(e.moon_tint),
		fog_tint_type = e.fog_tint_type or "default",
		-- The sky a player who cannot see the sky is under, and whether the
		-- game lets a client dim for that
		indoors = rgb(e.indoors),
		auto_dim_skybox = e.auto_dim_skybox ~= "0",
		-- What a skybox sky fogs with, how far the bodies' orbit is tilted,
		-- and Luanti's fog table. fog_start is a fraction of the viewing
		-- range; fog_distance is an upper bound on that range and nil for
		-- "the client decides".
		base_color = rgb(e.base_color),
		body_orbit_tilt = tonumber(e.body_orbit_tilt or ""),
		fog_color = rgb(e.fog_color),
		fog_start = tonumber(e.fog_start or ""),
		fog_distance = tonumber(e.fog_distance or ""),
		clouds = e.clouds ~= "0",
		density = tonumber(e.density or ""),
		cloud_color = rgb(e.cloud_color),
		cloud_alpha = tonumber(e.cloud_alpha or ""),
		-- {x, z} in nodes a second
		cloud_speed = e.cloud_speed and {tonumber(e.cloud_speed:match(
				"^[^,]+") or ""), tonumber(e.cloud_speed:match(",(.+)$") or
				"")} or nil,
		-- What else is up there: Luanti's set_sun, set_moon and set_stars
		sun_visible = e.sun_visible ~= "0",
		sun_scale = tonumber(e.sun_scale or ""),
		-- The game's own picture of each, as the expression it named: a
		-- game that names none gets Luanti's own sun.png and moon.png,
		-- which fall back to the sky's painted square when the game does
		-- not ship one -- which is what Luanti does with them too
		sun_texture = e.sun_texture,
		moon_visible = e.moon_visible ~= "0",
		moon_scale = tonumber(e.moon_scale or ""),
		moon_texture = e.moon_texture,
		stars_visible = e.stars_visible ~= "0",
		star_count = tonumber(e.star_count or ""),
		star_color = rgb(e.star_color),
		star_scale = tonumber(e.star_scale or ""),
	}
	local tint = M.sky.sun_tint
	log:info("luanti:sky: a " .. M.sky.type .. " sky" ..
			(M.sky.textures[1] and (", six pictures starting " ..
			M.sky.textures[1]) or "") ..
			", " .. M.sky.fog_tint_type .. " tint" ..
			(tint and string.format(" %.2f,%.2f,%.2f",
			tint.r, tint.g, tint.b) or ""))
	for _, f in ipairs(sky_subs) do
		f(M.sky)
	end
end)

-- What a game said the light should be whatever the hour: Luanti's
-- override_day_night_ratio, 0 for night and 1 for day, or nil for "the
-- clock decides". The sun still goes where the time says.
M.day_night_override = nil

local day_night_subs = {}

function M.sub_day_night(f)
	day_night_subs[#day_night_subs + 1] = f
	f(M.day_night_override)
end

buildat.sub_packet("luanti:daynight", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	M.day_night_override = tonumber(values[1] or "")
	for _, f in ipairs(day_night_subs) do
		f(M.day_night_override)
	end
end)

-- What time it is in the world, as the server last said: the fraction of a
-- day and how many game seconds a real one is. The server says it every few
-- seconds and whoever draws the sky carries it on in between, because a sky
-- that jumps every five seconds is worse than one that drifts.
M.time_of_day = nil
M.time_speed = 72

local time_subs = {}

-- sub_time(f) -> f(time_of_day, time_speed) whenever the server says, and
-- once now if it already has
function M.sub_time(f)
	time_subs[#time_subs + 1] = f
	if M.time_of_day then
		f(M.time_of_day, M.time_speed)
	end
end

-- How long the clock packet waited on the way down ([NET_CHANNELS]): the
-- server stamps it, the two clocks differ by a constant, so the wait is
-- the excess over the smallest (received - sent) seen; the worst per
-- five seconds is logged, as the server logs luanti:where's on the way up
local time_age = {base = nil, worst = 0, from = 0}

buildat.sub_packet("luanti:time", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	M.time_of_day = tonumber(values[1]) or 0
	M.time_speed = tonumber(values[2]) or 72
	local sent = tonumber(values[3])
	if sent then
		local now = buildat.get_time_us()
		local d = now - sent
		if time_age.base == nil or d < time_age.base then
			time_age.base = d
		end
		local age = d - time_age.base
		if age > time_age.worst then
			time_age.worst = age
		end
		if time_age.from == 0 then
			time_age.from = now
		elseif now - time_age.from >= 5000000 then
			log:info(string.format("time: the worst wait behind the wire " ..
					"down in five seconds %d ms", math.floor(time_age.worst / 1000)))
			time_age.worst = 0
			time_age.from = now
		end
	end
	for _, f in ipairs(time_subs) do
		f(M.time_of_day, M.time_speed)
	end
end)

-- What has been said, oldest first: a mod talking, a "/" command answering,
-- or another player. The game draws it; what is here is keeping it.
M.chat_lines = {}
-- The same lines with their markup still in them, for whoever draws them in
-- the colours a game asked for; see M.text_segments()
M.chat_raw = {}

local chat_subs = {}

-- sub_chat(f) -> f(line, lines) for every line said from now on
function M.sub_chat(f)
	chat_subs[#chat_subs + 1] = f
end

buildat.sub_packet("luanti:chat", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	-- Luanti wraps a translated line in escape sequences -- the translation
	-- context, the arguments, the colours -- and what is left once they are
	-- taken out is the English the game shipped. Translating them properly
	-- is a job for whoever brings the .tr files across.
	local raw = values[1] or ""
	local line = formspec.strip_escapes(raw)
	-- In the log, as a line the client says to itself is: what a game says
	-- is what a driven run reads, and it is the one thing a fixture can
	-- put in the client's own log
	log:info("chat: " .. line)
	M.chat_lines[#M.chat_lines + 1] = line
	M.chat_raw[#M.chat_raw + 1] = raw
	-- A log nobody trims grows for as long as the session lasts
	while #M.chat_lines > 200 do
		table.remove(M.chat_lines, 1)
		table.remove(M.chat_raw, 1)
	end
	for _, f in ipairs(chat_subs) do
		f(line, M.chat_lines, raw)
	end
end)

-- A line the client says to itself, in the chat as official's client
-- puts its own notes ("Fly mode enabled")
function M.chat_local(line)
	-- In the log too: what a key said is what a driven run reads
	log:info("chat (local): " .. tostring(line))
	M.chat_lines[#M.chat_lines + 1] = line
	M.chat_raw[#M.chat_raw + 1] = line
	for _, f in ipairs(chat_subs) do
		f(line, M.chat_lines, line)
	end
end

-- What the player may do, the server's list on join and on every change
-- ([FLY_MODES]); privs.fly and the rest are true when held
M.privs = {}
local privs_subs = {}
function M.sub_privs(f)
	privs_subs[#privs_subs + 1] = f
end
buildat.sub_packet("luanti:privs", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local privs = {}
	for _, p in ipairs(values) do
		privs[p] = true
	end
	M.privs = privs
	log:info("privileges: " .. table.concat(values, ", "))
	for _, f in ipairs(privs_subs) do
		f(privs)
	end
end)

-- The fly, fast and noclip the player left on in this world, once on join
-- ([FLY_STATE_SAVE]); f(modes) is called with it at once if it came already.
-- M.send_modes() tells the server a toggle.
local modes = nil
local modes_subs = {}
function M.sub_modes(f)
	modes_subs[#modes_subs + 1] = f
	if modes then
		f(modes)
	end
end
buildat.sub_packet("luanti:modes", function(data)
	modes = {}
	for _, m in ipairs(cereal.binary_input(data, {"array", "string"})) do
		modes[m] = true
	end
	for _, f in ipairs(modes_subs) do
		f(modes)
	end
end)
function M.send_modes(fly, fast, noclip)
	buildat.send_packet("luanti:fields", cereal.binary_output({
		"__buildat:modes", "fly", fly and "1" or "", "fast", fast and "1" or "",
		"noclip", noclip and "1" or ""}, {"array", "string"}))
end

local ok_ui, err_ui, formspec_ui =
		buildat.run_script_file("luanti/formspec_ui.lua")
if not ok_ui or type(formspec_ui) ~= "table" then
	error("luanti: could not load formspec_ui.lua: " .. tostring(err_ui))
end

-- item name -> the expression it is drawn as; see core.__item_images()
local item_images = {}
-- Which palette an item's definition names ([ITEM_META_LOOK]): a stack with
-- a palette_index of its own is coloured by reading that picture
local item_palettes = {}


-- sub_item_images(f) -> f() when the images arrive, and once now if they
-- already have. Whatever draws an item has to follow them: the inventory
-- arrives before they do -- it is the server that sends it and the client
-- that has to ask for these -- so a hotbar drawn once at the start is drawn
-- without them and never again.
function M.sub_item_images(f)
	item_image_subs[#item_image_subs + 1] = f
	if next(item_images) then
		f()
	end
end

-- What an item is drawn with, as a resource name, or nil when the game
-- shipped no image for it. A formspec's slots go through the same lookup;
-- this is here for what is drawn outside one, which is the hotbar.
function M.item_texture(item_name)
	return texture_of(item_images[item_name])
end

-- One face of it, for whoever paints the item onto a shape of their own
-- rather than into a slot: the little cube's top for a node that is drawn as
-- one, because a cube wearing a picture of a cube is not what the hand
-- holds, and the item's own picture for everything else.
function M.item_face_texture(item_name)
	local expr = item_images[item_name]
	if expr ~= nil and string.sub(expr, 1, #CUBE_MARK) == CUBE_MARK then
		expr = string.match(string.sub(expr, #CUBE_MARK + 1), "^[^\1]+")
	elseif expr ~= nil and string.sub(expr, 1, #SHAPE_MARK) == SHAPE_MARK then
		local _, tiles = shape_parts(expr)
		expr = tiles[1]
	end
	return texture_of(expr)
end
-- What the hand holds, as a shape ([WIELD_MESH] 1 and 2, official's
-- WieldMeshSceneNode::setItem): a flat item is its picture extruded into
-- a slab -- a front and a back quad per opaque pixel and an edge quad
-- wherever an opaque pixel borders a transparent one, each quad's texture
-- coordinates at that pixel's centre -- so a pickaxe held is a pickaxe;
-- a node that is a cube is the cube with its three visible faces (top and
-- two sides, the sides darkened as the inventory's picture darkens them),
-- and anything else the extrusion of its own picture. Builds into the
-- given node's CustomGeometry, one geometry per texture, and returns the
-- textures' resource names in geometry order, or nil for an item with no
-- picture. The mesh is a unit across; the caller scales it.
-- The second value is what it is: "mesh", "cube" or "flat", which the
-- caller sizes by (official's node and extruded scales). A mesh node
-- whose model has not arrived is nil, and is asked for.
function M.wield_geometry(node, item_name, expr_override)
	local wm = not expr_override and wield_meshes[item_name]
	if wm then
		-- Posed at its first frame, as Luanti draws a node's mesh: a
		-- skinned one's bind pose is not the shape (VoxeLibre's arm came
		-- apart into its bones' pieces)
		local have = models[model_key(wm.mesh, 0)]
		if not have then
			want_model(wm.mesh, 0)
			return nil
		end
		local tiles = buildat.set_quad_geometry(node, have.quads)
		local textures = {}
		for i = 1, #tiles do
			local resource = texture_of(wm.tiles[tiles[i] + 1] or
					wm.tiles[1] or "")
			if resource == nil then
				return nil
			end
			textures[i] = resource
		end
		return textures, "mesh"
	end
	local expr = expr_override or item_images[item_name]
	if expr == nil then
		return nil
	end
	local cg = node:GetComponent("CustomGeometry") or
			node:CreateComponent("CustomGeometry")
	-- The face's normal, for a lit technique; the second winding's is the
	-- other way
	local function normal(a, b, c)
		local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
		local vx, vy, vz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
		local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz,
				ux * vy - uy * vx
		local l = math.sqrt(nx * nx + ny * ny + nz * nz)
		l = l > 0 and l or 1
		nx, ny, nz = nx / l, ny / l, nz / l
		return magic.Vector3(nx, ny, nz), magic.Vector3(-nx, -ny, -nz)
	end
	-- Both windings of every quad: a shape in the hand is looked at from
	-- whatever side the hand turns to, and a face culled for its winding
	-- was a dirt block held as a thin dark plate
	local function quad(a, b, c, d, u, v)
		local n, back = normal(a, b, c)
		for i, p in ipairs({a, b, c, a, c, d, a, c, b, a, d, c}) do
			cg:DefineVertex(magic.Vector3(p[1], p[2], p[3]))
			cg:DefineNormal(i <= 6 and n or back)
			cg:DefineTexCoord(magic.Vector2(u, v))
		end
	end
	if string.sub(expr, 1, #CUBE_MARK) == CUBE_MARK then
		local faces = {}
		for part in string.gmatch(string.sub(expr, #CUBE_MARK + 1), "[^\1]+") do
			faces[#faces + 1] = part
		end
		if #faces ~= 3 then
			return nil
		end
		-- top, then the two sides the picture shows and their two hidden
		-- opposites wearing the same; the bottom wears the top's
		local textures = {}
		for i = 1, 3 do
			local resource = texture_of(faces[i])
			if resource == nil then
				return nil
			end
			textures[i] = resource
		end
		cg:SetNumGeometries(3)
		local h = 0.5
		-- top and bottom on geometry 0, +/-x sides on 1, +/-z on 2
		cg:BeginGeometry(0, magic.TRIANGLE_LIST)
		local function uvface(a, b, c, d)
			local uv = {{0, 0}, {1, 0}, {1, 1}, {0, 1}}
			local ps = {a, b, c, d}
			local n, back = normal(a, b, c)
			for k, i in ipairs({1, 2, 3, 1, 3, 4, 1, 3, 2, 1, 4, 3}) do
				cg:DefineVertex(magic.Vector3(ps[i][1], ps[i][2], ps[i][3]))
				cg:DefineNormal(k <= 6 and n or back)
				cg:DefineTexCoord(magic.Vector2(uv[i][1], uv[i][2]))
			end
		end
		uvface({-h, h, -h}, {h, h, -h}, {h, h, h}, {-h, h, h})
		uvface({-h, -h, h}, {h, -h, h}, {h, -h, -h}, {-h, -h, -h})
		cg:BeginGeometry(1, magic.TRIANGLE_LIST)
		uvface({h, h, -h}, {h, h, h}, {h, -h, h}, {h, -h, -h})
		uvface({-h, h, h}, {-h, h, -h}, {-h, -h, -h}, {-h, -h, h})
		cg:BeginGeometry(2, magic.TRIANGLE_LIST)
		uvface({-h, h, -h}, {-h, -h, -h}, {h, -h, -h}, {h, h, -h})
		uvface({h, h, h}, {h, -h, h}, {-h, -h, h}, {-h, h, h})
		cg:Commit()
		return textures, "cube"
	end
	local resource = texture_of(expr)
	if resource == nil then
		return nil
	end
	local img = magic.cache:GetResource("Image", resource)
	if img == nil or img.width == 0 then
		return nil
	end
	local w, h = img.width, img.height
	local function opaque(x, y)
		if x < 0 or y < 0 or x >= w or y >= h then
			return false
		end
		return img:GetPixel(x, y).a > 0.5
	end
	cg:SetNumGeometries(1)
	cg:BeginGeometry(0, magic.TRIANGLE_LIST)
	local t = 0.5 / w
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			if opaque(x, y) then
				local u, v = (x + 0.5) / w, (y + 0.5) / h
				local x0, x1 = (x - w / 2) / w, (x + 1 - w / 2) / w
				local y0, y1 = (h / 2 - y - 1) / h, (h / 2 - y) / h
				quad({x0, y1, -t}, {x1, y1, -t}, {x1, y0, -t}, {x0, y0, -t}, u, v)
				quad({x0, y1, t}, {x0, y0, t}, {x1, y0, t}, {x1, y1, t}, u, v)
				if not opaque(x - 1, y) then
					quad({x0, y1, -t}, {x0, y0, -t}, {x0, y0, t}, {x0, y1, t}, u, v)
				end
				if not opaque(x + 1, y) then
					quad({x1, y1, t}, {x1, y0, t}, {x1, y0, -t}, {x1, y1, -t}, u, v)
				end
				if not opaque(x, y - 1) then
					quad({x0, y1, t}, {x1, y1, t}, {x1, y1, -t}, {x0, y1, -t}, u, v)
				end
				if not opaque(x, y + 1) then
					quad({x0, y0, -t}, {x1, y0, -t}, {x1, y0, t}, {x0, y0, t}, u, v)
				end
			end
		end
	end
	cg:Commit()
	return {resource}, "flat"
end

-- The ones that have no image, said once each
local imageless = {}

-- "basenodes:stone 7" -> {name = "basenodes:stone", count = 7}
-- A stack's own metadata, which rides in the itemstring after the wear as
-- "\1key\2value\3" pairs (classes.lua's meta_to_string) -- a stack that
-- was coloured or given a picture of its own by a mod says so there
-- ([ITEM_META_LOOK])
local function parse_stack_meta(str)
	if not string.find(str, "\1", 1, true) then
		return nil
	end
	local fields = nil
	for k, v in string.gmatch(str, "\1([^\2]*)\2([^\3]*)\3") do
		fields = fields or {}
		fields[k] = v
	end
	return fields
end

local function parse_stack(str)
	if str == nil or str == "" then
		return nil
	end
	local name, count, wear = string.match(str, "^([^ ]+) *(%d*) *(%d*)")
	if name == nil or name == "" then
		return nil
	end
	return {name = name, count = tonumber(count) or 1,
			wear = tonumber(wear) or 0, meta = parse_stack_meta(str)}
end
-- A stack string as {name, count, wear, meta}, nil for an empty one
M.parse_stack = parse_stack

-- The colour a palette gives at an index, as "#rrggbb": the palette is a
-- picture of N colours, read left to right and then down, and Luanti
-- stretches it over the 256 index values ([ITEM_META_LOOK])
local palette_colors = {}
local function palette_color(palette, index)
	local key = palette .. "\1" .. tostring(index)
	local got = palette_colors[key]
	if got ~= nil then
		return got or nil
	end
	local resource = texture_of(palette)
	local img = resource and magic.cache:GetResource("Image", resource)
	if img == nil or img.width == 0 or img.height == 0 then
		palette_colors[key] = false
		return nil
	end
	local n = img.width * img.height
	local at = math.floor(index * n / 256)
	if at >= n then
		at = n - 1
	end
	local c = img:GetPixel(at % img.width, math.floor(at / img.width))
	local hex = string.format("#%02x%02x%02x",
			math.floor(math.max(0, math.min(1, c.r)) * 255 + 0.5),
			math.floor(math.max(0, math.min(1, c.g)) * 255 + 0.5),
			math.floor(math.max(0, math.min(1, c.b)) * 255 + 0.5))
	palette_colors[key] = hex
	return hex
end

-- What a stack's metadata says its colour is: its own `color`, or the
-- colour its item's palette gives at `palette_index`
local function meta_color(stack)
	local meta = stack.meta
	if meta == nil then
		return nil
	end
	if meta.color and meta.color ~= "" then
		return meta.color
	end
	local index = tonumber(meta.palette_index)
	local palette = index and item_palettes[stack.name]
	if palette then
		return palette_color(palette, math.max(0, math.min(255, index)))
	end
	return nil
end

-- A texmod added to an expression: to each face of a node's little cube,
-- which is this client's own form and not a texmod, or to the picture
local function add_to_expr(expr, add)
	if add == "" then
		return expr
	end
	if string.sub(expr, 1, #CUBE_MARK) == CUBE_MARK then
		local faces = {}
		for part in string.gmatch(
				string.sub(expr, #CUBE_MARK + 1), "[^\1]+") do
			faces[#faces + 1] = part .. add
		end
		return CUBE_MARK .. table.concat(faces, "\1")
	end
	if string.sub(expr, 1, #SHAPE_MARK) == SHAPE_MARK then
		local geom, tiles = shape_parts(expr)
		for i = 1, #tiles do
			tiles[i] = tiles[i] .. add
		end
		return SHAPE_MARK .. geom .. "\1" .. table.concat(tiles, "\1")
	end
	return expr .. add
end

-- What a stack looks like: its item's picture, or what its own metadata
-- says instead -- inventory_image in place of it, color multiplied into it
-- ([ITEM_META_LOOK]). palette_index is not read: the palette is the
-- server's and is not sent.
function M.stack_texture(stack)
	if stack == nil then
		return nil
	end
	local meta = stack.meta
	if meta == nil then
		return M.item_texture(stack.name)
	end
	local expr = meta.inventory_image
	if expr == nil or expr == "" then
		expr = item_images[stack.name]
	end
	if expr == nil or expr == "" then
		return M.item_texture(stack.name)
	end
	local add = ""
	local color = meta_color(stack)
	if color then
		add = add .. "^[multiply:" .. color
	end
	-- And a picture over it, which is what an overlay is
	if meta.inventory_overlay and meta.inventory_overlay ~= "" then
		add = add .. "^" .. meta.inventory_overlay
	end
	expr = add_to_expr(expr, add)
	return texture_of(expr) or M.item_texture(stack.name)
end

-- What the hand should hold, from a stack's itemstring: the image
-- expression its metadata asks for -- wield_image before inventory_image,
-- the colour multiplied into either, and into each face of a node's little
-- cube so that a coloured node is still a cube ([ITEM_META_LOOK]) -- or nil
-- for a stack whose look is its item's. The second value is what a caller
-- should key its cache by, since two stacks of one item may differ.
function M.wield_look(str)
	local stack = parse_stack(str)
	if stack == nil then
		return nil, nil
	end
	local meta = stack.meta
	if meta == nil then
		return nil, stack.name
	end
	local expr = meta.wield_image
	if expr == nil or expr == "" then
		expr = meta.inventory_image
	end
	local own = expr ~= nil and expr ~= ""
	if not own then
		expr = item_images[stack.name]
	end
	if expr == nil or expr == "" then
		return nil, stack.name
	end
	-- The colour, and a picture over it, on each face of a node's cube or
	-- on the flat picture
	local add = ""
	local color = meta_color(stack)
	if color then
		add = add .. "^[multiply:" .. color
	end
	if meta.wield_overlay and meta.wield_overlay ~= "" then
		add = add .. "^" .. meta.wield_overlay
	end
	-- Metadata that does not touch the look (VoxeLibre's hand carries
	-- some) leaves the item's own, which for a mesh node is its mesh
	if not own and add == "" then
		expr = nil
	else
		expr = add_to_expr(expr, add)
	end
	-- wield_scale is how much bigger the hand holds it; a vector as
	-- "x,y,z" or one number for all three
	local sx, sy, sz = nil, nil, nil
	if meta.wield_scale and meta.wield_scale ~= "" then
		local a1, b1, c1 = string.match(meta.wield_scale,
				"^%s*([%d.%-]+)%s*,%s*([%d.%-]+)%s*,%s*([%d.%-]+)%s*$")
		if a1 then
			sx, sy, sz = tonumber(a1), tonumber(b1), tonumber(c1)
		else
			local one = tonumber(meta.wield_scale)
			sx, sy, sz = one, one, one
		end
	end
	return expr, stack.name .. "\1" .. (expr or "") .. "\1" ..
			tostring(meta.wield_scale or ""), sx, sy, sz
end

-- The whole of a stack's look from its itemstring, for a client that keeps
-- its own hotbar: the texture, what the count should read, the name and the
-- wear
function M.stack_look(str)
	local stack = parse_stack(str)
	if stack == nil then
		return nil
	end
	return M.stack_texture(stack), M.stack_count_text(stack), stack.name,
			stack.wear
end

-- And what the count under it says: count_meta names the meta key whose
-- value is drawn in place of the number
function M.stack_count_text(stack)
	if stack == nil then
		return nil
	end
	local meta = stack.meta
	if meta and meta.count_meta and meta[meta.count_meta] then
		return tostring(meta[meta.count_meta])
	end
	if stack.count and stack.count > 1 then
		return tostring(stack.count)
	end
	return nil
end

--
-- What a dig costs, and how far one reaches
--
-- The client works both out for itself, which is what Luanti does: the
-- server answering "this one takes 1.4 seconds" when the button goes down
-- puts the network in front of every dig. What it takes is the nodes'
-- groups and the items' tool capabilities, which arrive once as
-- luanti:dig_props; the arithmetic under that is Luanti's getDigParams()
-- and getToolRange(), and is the same code extensions/luanti_client has in
-- itemdef.lua and inventory.lua.

-- item name -> {range =, description =, caps =}; see core.__dig_props()
local item_props = {}
-- node name -> {group = rating}, only the groups a tool rates
local node_groups = {}
-- The colour a node paints over the screen while the camera is in it,
-- {a, r, g, b} in 0..255, by node name; a "p" record of luanti:dig_props
local node_post_effect = {}
-- What a client predicts the server will do with a dig or a place of the
-- named item ([PREDICTION]); a "d" record of luanti:dig_props
local predictions = {}
-- A short tap digs with these, by what is pointed at (M.short_dig)
local touch_modes = {}

local function split_tab(s)
	local fields = {}
	for field in string.gmatch(s .. "\t", "([^\t]*)\t") do
		fields[#fields + 1] = field
	end
	return fields
end

local function parse_item_record(fields)
	local caps = nil
	if fields[5] ~= "" then
		caps = {
			full_punch_interval = tonumber(fields[5]) or 1,
			groupcaps = {},
		}
		for i = 6, #fields do
			local group, maxlevel, uses, times =
					string.match(fields[i], "^([^:]*):([^:]*):([^:]*):(.*)$")
			if group then
				local cap = {
					maxlevel = tonumber(maxlevel) or 1,
					uses = tonumber(uses) or 0,
					times = {},
				}
				for rating, time in string.gmatch(times, "([^=,]+)=([^,]+)") do
					cap.times[tonumber(rating)] = tonumber(time)
				end
				caps.groupcaps[group] = cap
			end
		end
	end
	item_props[fields[2]] = {
		range = tonumber(fields[3]) or -1,
		description = fields[4],
		caps = caps,
	}
end

local function parse_node_record(fields)
	local groups = {}
	for group, rating in string.gmatch(fields[3] or "", "([^=,]+)=([^,]+)") do
		groups[group] = tonumber(rating)
	end
	node_groups[fields[2]] = groups
end

-- What the tooltip under the mouse says, which is the item's own short
-- description or the first line of its long one
-- The quantities a line of detail wants, in the words
-- extensions/luanti_client's own debug line uses, so that the two can be
-- diffed number by number rather than looked at. See
-- doc/plan/luanti_module_plan.md, "The numbers before the pixels": a count
-- that differs is a fault with a name, where a picture that differs is a
-- question.
function M.counts()
	local objects, hud, items, meshes, texmods = 0, 0, 0, 0, 0
	for _ in pairs(object_nodes) do
		objects = objects + 1
	end
	for _ in pairs(M.hud_elements) do
		hud = hud + 1
	end
	for _ in pairs(item_images) do
		items = items + 1
	end
	-- A mesh that is still being asked for is false rather than a table,
	-- and is not one this client has
	for _, model in pairs(models) do
		if model then
			meshes = meshes + 1
		end
	end
	-- Texture expressions this client composed, the pieces a nested one is
	-- made of included. A node's own tiles are not among them: the module
	-- composes those and serves them as files, so what is left here is what
	-- an item, an object or the HUD asked for.
	-- extensions/luanti_client's own "composed" counts the world's tiles
	-- instead, so the two numbers are not the same measurement.
	for _ in pairs(composed) do
		texmods = texmods + 1
	end
	return {objects = objects, hud = hud, items = items, meshes = meshes,
			composed = texmods}
end

function M.item_description(item_name)
	local props = item_props[item_name]
	return props and props.description or nil
end

-- The groups a tool rates this node by, by the name the voxel registry
-- holds -- VoxelDefinition::name.block_name is the node's name
function M.node_groups(node_name)
	return node_groups[node_name]
end

-- post_effect_of(node_name) -> {a, r, g, b} in 0..255, or nil: what
-- Luanti's renderPostFx() paints over the screen with the camera in the
-- node. Water and lava in every game; nothing in most nodes.
-- The prediction record of an item or node, or nil for one with none:
-- {place = node name or "", dig = node name or "", rightclick, buildable_to,
-- placed_param2, walkable}. See core.__dig_props().
function M.prediction(name)
	return predictions[name]
end

-- Whether a short tap digs (and a long one places) with this item in hand,
-- pointed at kind: "nothing", "node" or "object" ([TOUCH_PARITY]; the
-- item's touch_interaction, dig.lua's t record)
function M.short_dig(name, kind)
	local i = kind == "nothing" and 1 or kind == "node" and 2 or 3
	return (touch_modes[name] or "lls"):sub(i, i) == "s"
end

function M.post_effect_of(node_name)
	return node_post_effect[node_name]
end

local function caps_of(stack_str)
	local stack = parse_stack(stack_str)
	local props = stack and item_props[stack.name]
	return props and props.caps or nil
end

-- Luanti's ItemStack::getToolCapabilities(): what is wielded, then the hand
-- slot when the wielded item has none, then the empty item's
function M.dig_capabilities(wield_index)
	local main = M.inventory.main
	local caps = caps_of(main and main[wield_index])
	if caps then
		return caps
	end
	local hand = M.inventory.hand
	caps = caps_of(hand and hand[1])
	if caps then
		return caps
	end
	local empty = item_props[""]
	return empty and empty.caps or nil
end

-- How long the wielded item takes on this node, or nil for a node it cannot
-- dig at all, and the group it went by (official's main_group, which a
-- "__group" dig sound is named after). Luanti's getDigParams(): the group
-- that digs it fastest wins, a tool whose maxlevel is more than one above
-- the node's level is faster still, and dig_immediate is a fixed time.
local function dig_time_with(caps, groups)
	if not caps.groupcaps.dig_immediate then
		local immediate = groups.dig_immediate
		if immediate == 2 then
			return 0.5, "dig_immediate"
		elseif immediate == 3 then
			return 0, "dig_immediate"
		end
	end
	local level = groups.level or 0
	local best, main = nil, nil
	for name, cap in pairs(caps.groupcaps) do
		local leveldiff = cap.maxlevel - level
		if leveldiff >= 0 then
			local rating = groups[name]
			local time = rating and cap.times[rating]
			if time then
				if leveldiff > 1 then
					time = time / leveldiff
				end
				if best == nil or time < best then
					best, main = time, name
				end
			end
		end
	end
	return best, main
end

function M.dig_time(node_name, wield_index)
	local caps = M.dig_capabilities(wield_index)
	local groups = node_groups[node_name]
	if caps == nil or groups == nil then
		return nil
	end
	local best, main = dig_time_with(caps, groups)
	if best ~= nil then
		return best, main
	end
	-- A tool that cannot dig this node digs it as the hand would
	-- (Game::handleDigging: "If not diggable, try hand digging (in case
	-- the tool is not useful)"): a wooden pickaxe on a log, which the
	-- driver stood holding for eight seconds with nothing happening
	local main = M.inventory.main
	if caps_of(main and main[wield_index]) == nil then
		return nil
	end
	local hand = M.inventory.hand
	local hand_caps = caps_of(hand and hand[1]) or
			(item_props[""] and item_props[""].caps) or nil
	if hand_caps == nil then
		return nil
	end
	return dig_time_with(hand_caps, groups)
end

-- How far the player can reach, in nodes. Luanti's getToolRange(): the
-- wielded item's own range, the hand's when it has none, and four when
-- neither says.
function M.dig_range(wield_index)
	local main = M.inventory.main
	local stack = parse_stack(main and main[wield_index])
	local props = stack and item_props[stack.name]
	local range = props and props.range or -1
	if range >= 0 then
		return range
	end
	local hand = M.inventory.hand
	local hand_stack = parse_stack(hand and hand[1])
	local hand_props = item_props[hand_stack and hand_stack.name or ""] or
			item_props[""]
	local hand_range = hand_props and hand_props.range or -1
	if hand_range >= 0 then
		return hand_range
	end
	return 4
end

local ui = nil
-- The form on the screen: res/form_session.lua's, made at its first use;
-- session.form is {formname =, spec =, at =, state =, drawn =} or nil
local session = nil
local player_spec = ""    -- what the player's own inventory key opens
-- A location -> the lists that are there, for the inventories a form draws
-- that are not the player's own: "x,y,z" for the node the form is about,
-- which is one node because one form is about one node, and
-- "detached:<name>" for one that belongs to nobody. Cleared when a form
-- opens, so it holds what the form on the screen is about and nothing else.
-- See core.__send_node_inventory().
local node_inventory = {}

local function make_ui()
	if ui then
		return ui
	end
	ui = formspec_ui.new(magic, buildat, log, {
		texture = texture_of,
		-- A stack rather than a name when there is one: its own metadata
		-- may put another picture or a colour on it ([ITEM_META_LOOK])
		item_image = function(item_name, stack)
			local resource = stack and stack.meta and M.stack_texture(stack)
					or texture_of(item_images[item_name])
			if not resource and not imageless[item_name] then
				imageless[item_name] = true
				log:info("item: no image for \"" .. item_name .. "\"")
			end
			local expr = item_images[item_name]
			return resource, not (stack and stack.meta) and expr ~= nil and
					string.sub(expr, 1, #CUBE_MARK) == CUBE_MARK
		end,
		stack_count_text = function(stack)
			return M.stack_count_text(stack)
		end,
		-- The player's own lists, the node the form is about --
		-- "current_name" and "context" are that node, and a nodemeta:
		-- location names one outright -- or a detached inventory, which
		-- belongs to nobody and is sent under its own name.
		inventory = function(location, list_name)
			local lists = nil
			if location == "current_player" or
					string.sub(location, 1, 7) == "player:" then
				lists = M.inventory
			elseif location == "current_name" or location == "context" then
				local form = session and session.form
				lists = form and form.at and node_inventory[form.at] or nil
			elseif string.sub(location, 1, 9) == "detached:" then
				lists = node_inventory[location]
			else
				local at = string.match(location, "^nodemeta:(.*)$")
				lists = at and node_inventory[at] or nil
			end
			local stacks = lists and lists[list_name]
			if not stacks then
				return nil
			end
			local items = {}
			for i, str in ipairs(stacks) do
				items[i] = parse_stack(str)
			end
			return {size = #stacks, items = items}
		end,
		model = model_element,
		style = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml"),
		-- A plain white pixel, which a box or a tint is drawn with. Composed
		-- rather than shipped: it is one operation and one file either way.
		white = texture_of("[fill:1x1:#ffffffff"),
		formspec = formspec,
	})
	return ui
end

local ok_fsess, err_fsess, form_session =
		buildat.run_script_file("luanti/form_session.lua")
if not ok_fsess or type(form_session) ~= "table" then
	error("luanti: could not load form_session.lua: " .. tostring(err_fsess))
end

-- What a form sends, for an app drawing its own (the form stage):
-- fields, {quit = "true"} when it is closed; a move, from and to being
-- {location =, list =, index =} ("current_player", "nodemeta:x,y,z",
-- "detached:<name>"); a craft of count from the grid
function M.send_fields(formname, fields)
	local flat = {formname}
	for k, v in pairs(fields) do
		flat[#flat + 1] = tostring(k)
		flat[#flat + 1] = tostring(v)
	end
	buildat.send_packet("luanti:fields", cereal.binary_output(flat,
			{"array", "string"}))
end
function M.inv_move(count, from, to)
	buildat.send_packet("luanti:inv_action", cereal.binary_output({
		"move", from.location, from.list, tostring(from.index),
		to.location, to.list, tostring(to.index), tostring(count),
	}, {"array", "string"}))
end
function M.inv_craft(count)
	buildat.send_packet("luanti:inv_action", cereal.binary_output(
			{"craft", tostring(count)}, {"array", "string"}))
end
-- The lists of the node a form is about ("x,y,z") or of a detached
-- inventory ("detached:<name>"), list name -> stack strings; nil until
-- the server sends them. f(at) when they come or change.
function M.node_lists(at)
	return node_inventory[at]
end
local node_inventory_subs = {}
function M.sub_node_inventory(f)
	node_inventory_subs[#node_inventory_subs + 1] = f
end

local function S()
	if session then
		return session
	end
	session = form_session.new({
		magic = magic, log = log, formspec = formspec, ui = make_ui(),
		send_fields = function(form, fields)
			M.send_fields(form.formname, fields)
		end,
		move = function(count, from, to) M.inv_move(count, from, to) end,
		craft = function(count) M.inv_craft(count) end,
		item_description = function(name)
			local desc = M.item_description(name)
			return desc and M.strip_escapes(desc)
		end,
		item_image = function(name)
			return texture_of(item_images[name])
		end,
		white = texture_of("[fill:1x1:#ffffffff"),
		style = magic.cache:GetResource("XMLFile",
				"ui_utils/res/style.xml"),
		compose_stats = compose_stats,
	})
	return session
end

local function current_form()
	return session and session.form
end

-- hover(x, y, held): where the cursor is, in the UI's own coordinates, and
-- whether the left button is down (a scrollbar's thumb dragged); nil when
-- the mouse is off the screen
function M.hover(x, y, held)
	S():hover(x, y, held)
end

-- A button let go, "left", "right" or "middle": a stack dragged to a slot
function M.release(button)
	S():release(button)
end

-- Called every frame: a stale form drawn again, the tooltip, the stack in
-- hand
function M.update_tooltip(dtime)
	S():frame(dtime)
end

-- Only a form that has a model in it: drawing one again is cheap, and
-- every other form on the screen when a model arrives is somebody else's
-- A form's model[] or an item drawn as a mesh's shape
form_model_arrived = function()
	if current_form() then
		session:redraw()
	end
end

local function show_form(formname, spec, at, handler)
	-- The app's own drawing of it, the client loop's form stage
	if not handler and M.form_stage and M.form_stage(formname, spec,
			at ~= "" and at or nil) then
		return
	end
	-- What the last form was about is not what this one is about: the node
	-- goes, because the server sends this form's own. The detached ones
	-- stay -- they belong to nobody and the player's own inventory form,
	-- which the client opens by itself, is drawn out of them.
	for at, _ in pairs(node_inventory) do
		if string.sub(at, 1, 9) ~= "detached:" then
			node_inventory[at] = nil
		end
	end
	S():open(spec, formname, {at = at ~= "" and at or nil,
			handler = handler})
end

-- The wheel over a form, Urho3D's delta ([FORMSPEC_SCROLL]): the client
-- that owns the mouse calls this while a form is open, since the wheel is
-- the hotbar's otherwise
function M.form_wheel(delta)
	return S():wheel(delta)
end

-- A game's own window over the world, such as vanilla's pause menu: while
-- it is up form_open() says so, as for a form, and Escape calls `close`.
-- `window`, if given, is what form_window() reports for a scan. hold(nil)
-- lets go. keep_on_escape: Escape does nothing, the window's own buttons
-- close it. on, if given: on.click(x, y, button) -> true gets the clicks
-- a form would (mouse and touch alike), in the UI root's coordinates;
-- on.key(key) -> true the keys before Escape is looked at.
local held, held_window, held_keep, held_on = nil, nil, false, {}
function M.hold(close, window, keep_on_escape, on)
	held, held_window, held_keep = close, window, keep_on_escape or false
	held_on = close and on or {}
end
-- held() -> whether a game's window holds the world now
function M.held()
	return held ~= nil
end

-- form_open() -> whether a form is on the screen, so that whoever else is
-- reading the mouse leaves it alone while one is
function M.form_open()
	return current_form() ~= nil or held ~= nil
end

-- The open form's name and drawn window, for whoever reports what is on
-- the screen ([SCAN_EVENT]); nil when none is open
-- The open form's slots for the scan ([SCAN_DRIVE]): where each is on
-- the screen, which list and index, and what is in it -- what a driver
-- drags between. Nil when no form is open.
function M.form_slots()
	return S():slots()
end

-- Every object the client has a node for, but the player's own, with
-- where it is: the scan projects them into the frame and lists the ones
-- on the screen ([SCAN_EVENT]); a bin's ray misses most items
-- Where the player's own model stands and which way it faces, set by
-- the game's client half every frame while a third-person view is on
-- ([BOX_PLAYTEST_4] 4, 5): the client knows its own feet and its own
-- look, where the server's echo of them is a round trip old and is the
-- position the player *reported* -- on the box the model floated about
-- a node above the ground and never turned. Official's client draws its
-- own model from its LocalPlayer the same way.
function M.set_self_pose(x, y, z, yaw)
	self_pose = {x = x, y = y, z = z, yaw = yaw}
	local have = object_nodes[M.self_id]
	if have and M.draw_self then
		have.node.position = magic.Vector3(x, y, z)
		have.node.rotation = magic.Quaternion(0, yaw, 0)
	end
	for id, _ in pairs(riders) do
		follow_self(id)
	end
end

-- The player's own object, when it is drawn: where its node is and
-- which way it faces, for a run reading a third-person shot
-- ([BOX_PLAYTEST_4] 4, 5)
function M.self_object()
	local have = object_nodes[M.self_id]
	if have == nil then
		return nil
	end
	local p = have.node.position
	return {x = p.x, y = p.y, z = p.z, yaw = have.node.rotation:YawAngle()}
end

-- What rides the player's own object, where it is drawn ([WIELD_AT_FEET])
function M.riders()
	local out = {}
	for id, _ in pairs(riders) do
		local p = object_nodes[id].node.position
		out[#out + 1] = {id = id, x = p.x, y = p.y, z = p.z}
	end
	return out
end

function M.objects()
	local out = {}
	for id, have in pairs(object_nodes) do
		if id ~= M.self_id and (have.look == nil or have.look.pointable ~= false) then
			local p = have.node.position
			out[#out + 1] = {id = id, x = p.x, y = p.y, z = p.z,
					label = M.object_label(id)}
		end
	end
	return out
end

function M.form_window()
	local form = current_form()
	if form == nil and held and held_window then
		return "", held_window
	end
	if form == nil or form.drawn == nil then
		return nil, nil
	end
	return form.formname, form.drawn.window
end

-- What the player's own inventory key opens. Nothing here binds a key: which
-- key that is belongs to the game, and this is what it calls.
function M.open_player_inventory()
	if current_form() then
		S():close(true)
		return
	end
	if player_spec == "" then
		log:info("no inventory formspec; the game has not set one")
		return
	end
	show_form("", player_spec)
	if current_form() then
		current_form().source = "inventory"
		-- What a check waits for
		log:info("form: the inventory opened")
	end
end

-- A form of the client's own: the game describes it the way a server would
-- and draws it through the same renderer, and the fields a button sends go
-- to the handler rather than out. What wants one is a menu that is about the
-- client rather than about the game -- the launcher's pause menu. The
-- handler is called with quit = "true" when the player closed it.
function M.show_local_form(spec, handler)
	show_form("", spec, nil, handler)
end

-- The open form closed by the game itself, the way its Escape would
function M.close_form()
	S():close(true)
end

-- A click, from whoever is reading the mouse: "left", "right" or
-- "middle". Returns whether the form took it, so that a click that was not
-- on one still digs.
function M.click(x, y, button)
	if held_on.click then
		return held_on.click(x, y, button)
	end
	return S():click(x, y, button)
end

-- Escape closes it, which is the player closing it
function M.key(key)
	if S():key(key) then
		return true
	end
	-- A held window's keys are its own: what is typed into its fields is
	-- not the game's
	if held and not current_form() then
		if held_on.key and held_on.key(key) then
			return true
		end
		if key == magic.KEY_ESCAPE and not held_keep then
			local close = held
			held, held_window = nil, nil
			close()
		end
		return true
	end
	return false
end

-- The move was the server's to make, so what a form shows is stale until the
-- inventory comes back
M.sub_inventory(function()
	if session then
		session:redraw()
	end
end)

buildat.sub_packet("luanti:formspec", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	show_form(values[1] or "", values[2] or "", values[3] or "")
end)

-- What is in the node the open form is about; the position leads
buildat.sub_packet("luanti:node_inventory", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local at = values[1]
	if at == nil then
		return
	end
	local lists = {}
	local i = 2
	while i + 1 <= #values do
		local name = values[i]
		local size = tonumber(values[i + 1]) or 0
		local stacks = {}
		for slot = 1, size do
			stacks[slot] = values[i + 1 + slot] or ""
		end
		lists[name] = stacks
		i = i + 2 + size
	end
	node_inventory[at] = lists
	for _, f in ipairs(node_inventory_subs) do
		f(at)
	end
	if session then
		session:redraw()
	end
end)

buildat.sub_packet("luanti:player_formspec", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	-- What a check waits for: the inventory key opens something from now
	if player_spec == "" and (values[1] or "") ~= "" then
		log:info("form: the game set the inventory")
	end
	player_spec = values[1] or ""
	-- The open inventory too: this is how a game turns its own page, as
	-- VoxeLibre's creative one does ([CREATIVE_PAGES])
	local form = current_form()
	if form and form.source == "inventory" and player_spec ~= "" then
		form.spec = player_spec
		session:redraw()
		log:info("form: the inventory drawn again, the game's new one")
	end
end)

startup_packet("luanti:dig_props", "luanti_data/dig_props.bin", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local items, nodes, preds, footsteps = 0, 0, 0, 0
	for i = 1, #values do
		local fields = split_tab(values[i])
		if fields[1] == "i" then
			parse_item_record(fields)
			items = items + 1
		elseif fields[1] == "n" then
			parse_node_record(fields)
			nodes = nodes + 1
		elseif fields[1] == "t" then
			touch_modes[fields[2]] = fields[3]
		elseif fields[1] == "d" then
			preds = preds + 1
			local flags = fields[5] or ""
			predictions[fields[2]] = {
				place = fields[3] or "",
				dig = fields[4] or "air",
				rightclick = string.find(flags, "r", 1, true) ~= nil,
				buildable_to = string.find(flags, "b", 1, true) ~= nil,
				placed_param2 = string.find(flags, "p", 1, true) ~= nil,
				walkable = string.find(flags, "w", 1, true) ~= nil,
			}
		elseif fields[1] == "h" or fields[1] == "u" or fields[1] == "v" then
			local files = {}
			for f in string.gmatch(fields[5] or "", "[^,]+") do
				files[#files + 1] = f
			end
			local into = fields[1] == "h" and node_dig or
					fields[1] == "u" and item_use or item_use_air
			into[fields[2]] = {
				gain = tonumber(fields[3]) or 1.0,
				pitch = tonumber(fields[4]) or 1.0,
				files = files,
			}
		elseif fields[1] == "g" or fields[1] == "q" then
			-- What it sounds like dug and placed, the same shape as the
			-- footstep's record
			local files = {}
			for f in string.gmatch(fields[5] or "", "[^,]+") do
				files[#files + 1] = f
			end
			if #files > 0 then
				local into = fields[1] == "g" and node_dug or node_placed
				into[fields[2]] = {
					gain = tonumber(fields[3]) or 1.0,
					pitch = tonumber(fields[4]) or 1.0,
					files = files,
				}
			end
		elseif fields[1] == "s" then
			-- What the node sounds like underfoot ([NO_SOUND]): the
			-- gain, the pitch and the files the group resolved to
			local files = {}
			for f in string.gmatch(fields[5] or "", "[^,]+") do
				files[#files + 1] = f
			end
			if #files > 0 then
				node_footsteps[fields[2]] = {
					gain = tonumber(fields[3]) or 1.0,
					pitch = tonumber(fields[4]) or 1.0,
					files = files,
				}
				footsteps = footsteps + 1
			end
		elseif fields[1] == "p" then
			local c = {}
			for v in string.gmatch(fields[3] or "", "[^,]+") do
				c[#c + 1] = tonumber(v) or 0
			end
			node_post_effect[fields[2]] = {a = c[1] or 0, r = c[2] or 0,
					g = c[3] or 0, b = c[4] or 0}
		end
	end
	local dug_n, placed_n = 0, 0
	for _ in pairs(node_dug) do dug_n = dug_n + 1 end
	for _ in pairs(node_placed) do placed_n = placed_n + 1 end
	log:info("luanti:dig_props: " .. items .. " items, " .. nodes ..
			" nodes with groups, " .. preds .. " predictions, " ..
			footsteps .. " nodes with a footstep, " .. dug_n ..
			" with a dug sound and " .. placed_n .. " with a place sound")
end)

-- item name -> {mesh = name, tiles = {expr, ...}} for a mesh node in a
-- hand ([WIELD_MESH]; core.__wield_meshes())
startup_packet("luanti:wield_meshes", "luanti_data/wield_meshes.bin",
		function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	for i = 1, #values - 1, 2 do
		local parts = {}
		for part in string.gmatch(values[i + 1] .. "\1", "([^\1]*)\1") do
			parts[#parts + 1] = part
		end
		local tiles = {}
		for j = 2, #parts do
			tiles[j - 1] = parts[j]
		end
		wield_meshes[values[i]] = {mesh = parts[1], tiles = tiles}
	end
	log:info("luanti:wield_meshes: " .. math.floor(#values / 2) .. " items")
	-- A shape the hand built before these came (the picture, flat) is
	-- stale: the caller drops what it built for an older generation
	M.wield_generation = M.wield_generation + 1
	for _, f in ipairs(item_image_subs) do
		f()
	end
end)
buildat.send_packet("luanti:get_wield_meshes", "")

startup_packet("luanti:item_palettes", "luanti_data/item_palettes.bin",
		function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	for i = 1, #values - 1, 2 do
		item_palettes[values[i]] = values[i + 1]
	end
	log:info("luanti:item_palettes: " .. math.floor(#values / 2) ..
			" items have one")
end)
buildat.send_packet("luanti:get_item_palettes", "")

startup_packet("luanti:item_images", "luanti_data/item_images.bin", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local n = 0
	for i = 1, #values - 1, 2 do
		item_images[values[i]] = values[i + 1]
		n = n + 1
	end
	log:info("luanti:item_images: " .. n .. " items")
	if session then
		session:redraw()
	end
	for _, f in ipairs(item_image_subs) do
		f()
	end
end)

-- What the server says about the world: the game's name, the seed and which
-- Luanti this is. The status line shows them beside the numbers it works out
-- for itself, so that a shot of this can be compared with a shot of official
-- Luanti without anything being looked up.
local world_info = {game = "", seed = "", version = "", mode = "pbr",
		orbit_tilt = nil}
local world_info_subs = {}

function M.world_info()
	return world_info
end

-- sub_world_info(f) -> f(info) once it has arrived, and now if it already
-- has. A game's client half needs info.mode -- "unlit", "shadows" or "pbr",
-- see [RENDER_MODES] -- before it draws its first chunk; the answer is to
-- what this client asked for below, or the server's default.
function M.sub_world_info(f)
	world_info_subs[#world_info_subs + 1] = f
	if world_info.version ~= "" then
		f(world_info)
	end
end

-- What the game's locale/*.tr files say, for the language the server chose:
-- domain, key, value repeating. Everything a game writes carries a marker
-- where a translatable string went in, and this end is where they are
-- looked up -- see formspec.lua's M.translate().
startup_packet("luanti:translations", "luanti_data/translations.bin", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local by_domain = {}
	local n = 0
	for i = 1, #values - 2, 3 do
		local domain = values[i]
		by_domain[domain] = by_domain[domain] or {}
		by_domain[domain][values[i + 1]] = values[i + 2]
		n = n + 1
	end
	formspec.set_translations(by_domain)
	log:info("luanti:translations: " .. n .. " strings")
end)

local world_info_logged = false
buildat.sub_packet("luanti:world_info", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	world_info = {game = values[1] or "", seed = values[2] or "",
			version = values[3] or "", mode = values[4] or "pbr",
			-- Empty means the client's own default; see the sky handler in
			-- apps/vanilla
			orbit_tilt = tonumber(values[5] or ""),
			-- The server's longest step, held and decayed, and the phase
			-- that set it; re-sent when it moves. See [STEP_PEAK].
			step_peak = tonumber(values[6] or "") or 0,
			step_peak_phase = values[7] or "",
			step_latest = tonumber(values[8] or "") or 0}
	-- Once: the packet comes again whenever the step peak moves
	if not world_info_logged then
		world_info_logged = true
		log:info("luanti:world_info: " .. world_info.version .. ", game " ..
				world_info.game .. ", seed " .. world_info.seed .. ", " ..
				world_info.mode)
	end
	for _, f in ipairs(world_info_subs) do
		f(world_info)
	end
end)

-- The texture modifiers are served as a file as well ([BLOCKED_MODULE]):
-- the module that answers the packet below can be held for half a minute by
-- a slow mapgen -- realtest's sections were 29.6 s each and this client drew
-- 840 missing textures -- while client_file has a queue of its own and the
-- file is here by the time this runs. The request stays for what a game adds
-- later, and the handler skips what is composed already.
do
	local blob = buildat.get_file_content("luanti_data/texmods.bin")
	if blob then
		log:info("luanti:texmods: from the served file, " .. #blob .. " bytes")
		texmods_from_data(blob)
	end
end

-- Asked for rather than sent, because a packet that arrives before the
-- script that subscribes to it has nowhere to go
buildat.send_packet("luanti:get_texmods", "")
buildat.send_packet("luanti:get_item_images", "")
buildat.send_packet("luanti:get_object_props", "")
buildat.send_packet("luanti:get_dig_props", "")
--
-- The reference set's readiness channel; see [ONE_CYCLE] in
-- doc/plan/rendering_plan.md.
--
-- The server marks a state once it has nothing left to send for it. **The
-- ordering is the mechanism**: the channel is reliable and ordered, so every
-- chunk packet sent before the marker has already been handled by the time
-- this handler runs. From here on "my mesh queue is empty" is a fact about
-- the whole state rather than about whatever has arrived so far -- which is
-- the ambiguity that three cycles of shooting were hedging against.
--
-- The reply carries the picture's name and nothing else. The fixture set the
-- state, so it is the one that knows which state this is, and because it
-- advances on the reply rather than on a clock there is never more than one
-- state in flight.
local refshot_token = nil
local refshot_still = 0
local refshot_dump = false

local refshot_at = nil

-- The game's client half sets this to snap its exposure adaptation to the
-- current frame; see the readiness rule below. nil means no exposure.
M.exposure_reset = nil
-- The same for the sky-visibility cube: set by the game's client half, called
-- on the frame the exposure is snapped
M.sky_vis_snap = nil
-- Optional: returns one line about what the frame is lit by, logged with the
-- picture. The game's client half sets it.
M.refshot_note = nil

buildat.sub_packet("luanti:refshot_mark", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	refshot_token = tonumber(values[1] or "")
	-- Where the state is looking from, so that the readiness test can be
	-- about that place rather than about the queue as a whole
	refshot_at = {x = tonumber(values[2] or "") or 0,
			y = tonumber(values[3] or "") or 0,
			z = tonumber(values[4] or "") or 0}
	refshot_dump = values[5] == "1"
	refshot_still = 0
end)

magic.SubscribeToEvent("Update", function(event_type, event_data)
	if refshot_token == nil or not texmods_done then
		return
	end
	-- **The test is positive: is the world around the viewpoint drawn.**
	-- Two weaker tests were tried and both photograph an empty sky. "The
	-- mesh queue is empty" is never true of a run that forceloads its
	-- viewpoints -- thousands of chunks stay queued for places the camera is
	-- nowhere near. "Nothing in the queue is due" is true of a place whose
	-- chunks have not been asked for yet, which is exactly the moment after
	-- a teleport. Only "every chunk around there has a scene node" says the
	-- picture will have a world in it.
	if voxelworld.undrawn_around(refshot_at, 2) > 0 then
		refshot_still = 0
		return
	end
	-- And nothing still due, so that what is drawn is also up to date:
	-- next_mesh_f is distance over trigger distance at the head of the
	-- spatial queue, and voxelworld meshes while that is at most 1.
	local f = voxelworld.counts().next_mesh_f
	if f ~= nil and f <= 1.0 then
		refshot_still = 0
		return
	end
	-- Three frames, because the head of the queue is momentarily out of
	-- range between the chunk that finished and the one behind it
	refshot_still = refshot_still + 1
	-- **The visibility cube first, the exposure after it** (2026-09-25):
	-- sharing the exposure's frame cost a re-take its night rows -- vp4
	-- at 20:30 came out at a mean of 108 against the kept reference's 8
	-- -- because the snap is several sweeps of ray casting in one frame
	-- and the meter's two reset frames were spent on it. A frame of its
	-- own, and the exposure's snap is the last thing before the picture.
	if refshot_still == 2 then
		if M.sky_vis_snap then
			M.sky_vis_snap()
		end
		return
	end
	if refshot_still < 3 then
		return
	end
	-- **And the exposure settled before the picture** ([PT_SETTLE]): a
	-- reference is the converged value by definition, and the client's
	-- adaptation takes seconds over the fifteen stops between a night
	-- state and the dawn after it. The game's client half snaps its
	-- adaptation to the frame's metered key on this call -- one frame
	-- with the rate forced to infinity -- and the picture is taken four
	-- frames on, which is the snap and the frame after it.
	if refshot_still == 3 then
		if M.exposure_reset then
			M.exposure_reset()
		end
		return
	end
	if refshot_still < 7 then
		return
	end
	-- What the frame was drawn with, in the log beside the picture and in
	-- the shots' own order: a reading taken from the per-frame code
	-- instead lands wherever that code last printed, which is not the
	-- frame the picture is of ([UNDERGROUND_LIGHT]).
	if M.refshot_note then
		local note = M.refshot_note()
		if note then
			log:info("REFSHOT readings: " .. note)
		end
	end
	local name, err = buildat.take_screenshot()
	if name == nil then
		-- One already pending is not a failure: the next frame will do
		if tostring(err):find("pending") then
			return
		end
		name = "ERROR " .. tostring(err)
	end
	local mesh = ""
	if refshot_dump then
		-- With the atlas registry's account of which resource owns which
		-- tile, written beside the dump as <stem>_atlas.json
		local reg = voxelworld.get_atlas_registry()
		local atlas = reg and reg.describe_segments and
				reg:describe_segments() or nil
		if atlas then
			-- And which expression each composed texture came from: a
			-- luanti_texmod/<hash>.png says nothing by itself
			local function q(str)
				return '"' .. str:gsub('[%c"\\]', function(c)
					return string.format("\\u%04x", c:byte())
				end) .. '"'
			end
			local lines = {}
			for expr, resource in pairs(composed) do
				if type(resource) == "string" then
					lines[#lines + 1] = q(resource) .. ": " .. q(expr)
				end
			end
			-- And which segments a light-emitting node draws, with its
			-- light_source, so the render can emit from them ([LAMP_REF])
			local vreg = voxelworld.get_voxel_registry()
			local lights = vreg and vreg.describe_lights and
					vreg:describe_lights(reg) or "[]"
			atlas = '{"segments": ' .. atlas .. ', "lights": ' .. lights ..
					', "composed": {\n' .. table.concat(lines, ",\n") ..
					'\n}}\n'
		end
		mesh = buildat.dump_meshes(atlas) or ""
	end
	buildat.send_packet("luanti:refshot_shot", cereal.binary_output(
			{tostring(refshot_token), name, mesh}, {"array", "string"}))
	refshot_token = nil
end)

-- The mode is this client's to ask for -- BUILDAT_RENDER_MODE on its own
-- process, the same variable extensions/luanti_client reads -- and the
-- server's environment is the default for a client that says nothing. That
-- is what lets one server serve a client in each mode; see [PROBE_CYCLE].
-- Without the variable, what the player chose in vanilla's View settings
-- for this server ([VANILLA_PLAYER_SETTINGS]); on the client's own local
-- server nothing, so that the server reads settings.json's
-- ([VIEW_SETTINGS_LOCAL])
local is_local = buildat.connected_locally()
buildat.send_packet("luanti:get_world_info",
		buildat.get_env("BUILDAT_RENDER_MODE") or
		(not is_local and buildat.storage_read("view_render_mode")) or "")
buildat.send_packet("luanti:get_translations", "")

local ok_bodies, err_bodies, bodies =
		buildat.run_script_file("luanti/bodies.lua")
if not ok_bodies or type(bodies) ~= "table" then
	error("luanti: could not load bodies.lua: " .. tostring(err_bodies))
end
for k, v in pairs(bodies) do
	M[k] = v
end

-- **The client loop** ([LUANTI_APP_GLUE]): the player in the world --
-- the controller, the camera, keys, pointing and digging, the hotbar, the
-- wielded item, the HUD, chat, the sky and touch -- in client.lua, whose
-- header lists app's hooks. Returns the loop's shared table.
function M.run_client(app)
	M.app = app or {}
	local ok, err, keys = buildat.run_script_file("luanti/client.lua")
	if not ok or type(keys) ~= "table" then
		error("luanti: could not load client.lua: " .. tostring(err))
	end
	return keys
end

return M
-- vim: set noet ts=4 sw=4:
