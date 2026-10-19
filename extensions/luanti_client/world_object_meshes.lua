-- Buildat: extension/luanti_client/world_object_meshes.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- What an object is drawn with: the sprite visuals, an item's cube, a
-- model's mesh and the template nodes, and self:set_object(). A part of
-- world.lua's M.new, which calls this with what it reads of M.new's; o:
-- object_nodes, box_model, box_technique (the stand-in box's and a
-- sprite's), light_object(entry, x, y, z), daylight() ([SPLITS]: moved
-- out as it was).

return function(self, magic, scene, game_texture, object_technique,
		texture, o)
	-- The visuals drawn as a flat picture turned to the camera rather than
	-- as a box: Luanti's sprite, and the two an item entity uses. A dropped
	-- item's picture is the one an inventory draws for it, which for a node
	-- is already the little isometric cube -- the same picture Luanti's
	-- wielditem comes out as.
	--
	-- simplified: upright_sprite is in here too, where Luanti turns it with
	-- the object's own yaw rather than to the camera.
	local SPRITE_VISUALS = {
		sprite = true,
		upright_sprite = true,
		item = true,
		wielditem = true,
	}

	-- The six faces of a unit cube, each as two triangles with the tile's
	-- own image on it: what a dropped node looks like in Luanti, where it is
	-- a small cube of the node's tiles turning on the spot. The order is
	-- Luanti's tile order -- +Y, -Y, +X, -X, +Z, -Z -- and each face is
	-- given as its four corners in the order the uv corners go, so the
	-- picture comes out the right way up.
	local CUBE_FACES = {
		{{-0.5, 0.5, -0.5}, {0.5, 0.5, -0.5}, {0.5, 0.5, 0.5},
				{-0.5, 0.5, 0.5}},
		{{-0.5, -0.5, 0.5}, {0.5, -0.5, 0.5}, {0.5, -0.5, -0.5},
				{-0.5, -0.5, -0.5}},
		{{0.5, 0.5, 0.5}, {0.5, 0.5, -0.5}, {0.5, -0.5, -0.5},
				{0.5, -0.5, 0.5}},
		{{-0.5, 0.5, -0.5}, {-0.5, 0.5, 0.5}, {-0.5, -0.5, 0.5},
				{-0.5, -0.5, -0.5}},
		{{0.5, 0.5, 0.5}, {-0.5, 0.5, 0.5}, {-0.5, -0.5, 0.5},
				{0.5, -0.5, 0.5}},
		{{-0.5, 0.5, -0.5}, {0.5, 0.5, -0.5}, {0.5, -0.5, -0.5},
				{-0.5, -0.5, -0.5}},
	}
	local CUBE_UV = {{0, 0}, {1, 0}, {1, 1}, {0, 1}}

	-- A face's normal from three of its corners, and the back winding's,
	-- for the lit technique the meshes wear under pbr ([OBJECT_SUN]); the
	-- same as buildat.set_quad_geometry()'s
	local function face_normal(ax, ay, az, bx, by, bz, cx, cy, cz)
		local ux, uy, uz = bx - ax, by - ay, bz - az
		local vx, vy, vz = cx - ax, cy - ay, cz - az
		local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz,
				ux * vy - uy * vx
		local l = math.sqrt(nx * nx + ny * ny + nz * nz)
		l = l > 0 and l or 1
		return magic.Vector3(nx / l, ny / l, nz / l),
				magic.Vector3(-nx / l, -ny / l, -nz / l)
	end

	-- A mesh's materials and shadow: under pbr lit, casting into the sun's
	-- map ([OBJECT_SUN]), with the voxels' rough non-metal surface
	local function dress(material)
		material:SetTechnique(0, object_technique)
		if self.pbr then
			material:SetShaderParameter("Roughness", 1.0)
			material:SetShaderParameter("Metallic", 0.0)
		end
	end

	-- One geometry per face, so each can wear its own tile. The materials
	-- are handed to the component and nothing else holds them, which is what
	-- keeps them alive; see the crack above.
	local function build_item_cube(node, tiles)
		local cg = node:CreateComponent("CustomGeometry")
		cg:SetNumGeometries(6)
		for face = 1, 6 do
			cg:BeginGeometry(face - 1, magic.TRIANGLE_LIST)
			local corners = CUBE_FACES[face]
			local a, b, c = corners[1], corners[2], corners[3]
			local n, back = face_normal(a[1], a[2], a[3], b[1], b[2], b[3],
					c[1], c[2], c[3])
			-- Both windings, so which way round a face was given does not
			-- decide whether it is drawn: the frame outline above does the
			-- same thing for the same reason
			for k, i in ipairs({1, 2, 3, 1, 3, 4, 1, 3, 2, 1, 4, 3}) do
				local p = corners[i]
				cg:DefineVertex(magic.Vector3(p[1], p[2], p[3]))
				cg:DefineNormal(k <= 6 and n or back)
				cg:DefineTexCoord(magic.Vector2(CUBE_UV[i][1],
						CUBE_UV[i][2]))
			end
		end
		cg:Commit()
		cg.castShadows = self.pbr
		local materials = {}
		for face = 1, 6 do
			local material = magic.Material.new()
			dress(material)
			material:SetTexture(0, game_texture(
					tiles[face] or tiles[1] or texture))
			cg:SetMaterial(face - 1, material)
			materials[face] = material
		end
		return cg, materials
	end

	-- An object drawn as its own model: the quads objmesh or b3dmesh read,
	-- one geometry per material so that each wears the texture the object
	-- gave for that material. Both windings, like the item cube above, for
	-- the same reason: a model's winding is not something to rely on.
	local function build_object_mesh(node, quads, tiles)
		local by_group = {}
		local order = {}
		for _, q in ipairs(quads) do
			local g = q.group or 1
			if not by_group[g] then
				by_group[g] = {}
				order[#order + 1] = g
			end
			local into = by_group[g]
			into[#into + 1] = q
		end
		table.sort(order)
		local cg = node:CreateComponent("CustomGeometry")
		cg:SetNumGeometries(#order)
		for i = 1, #order do
			cg:BeginGeometry(i - 1, magic.TRIANGLE_LIST)
			for _, q in ipairs(by_group[order[i]]) do
				local p = q.p
				local n, back = face_normal(p[1], p[2], p[3], p[4], p[5], p[6],
						p[7], p[8], p[9])
				for k, c in ipairs({1, 2, 3, 1, 3, 4, 1, 3, 2, 1, 4, 3}) do
					local o = (c - 1) * 3
					cg:DefineVertex(magic.Vector3(q.p[o + 1], q.p[o + 2],
							q.p[o + 3]))
					cg:DefineNormal(k <= 6 and n or back)
					cg:DefineTexCoord(magic.Vector2(q.uv[(c - 1) * 2 + 1],
							q.uv[(c - 1) * 2 + 2]))
				end
			end
		end
		cg:Commit()
		cg.castShadows = self.pbr
		local materials = {}
		for i = 1, #order do
			local material = magic.Material.new()
			dress(material)
			material:SetTexture(0, game_texture(
					tiles[order[i]] or tiles[1] or texture))
			cg:SetMaterial(i - 1, material)
			materials[i] = material
		end
		return cg, materials
	end

	-- **A model in a form** (model[], the inventory's player): a View3D of
	-- its own scene under `parent`, the quads turned in place by the
	-- element's angles and the camera back far enough for all of them.
	-- Cleared to nothing around the model, so the form shows through.
	-- simplified: the rest pose, no mouse turning, as vanilla's module.lua
	-- model_element.
	function self:model_view(parent, w, h, quads, tiles, rot_x, rot_y)
		if not quads or #quads == 0 or w < 1 or h < 1 then
			return nil
		end
		local view = parent:CreateChild("View3D")
		view.size = magic.IntVector2(math.floor(w), math.floor(h))
		view.format = magic.Graphics.GetRGBAFormat()
		view.blendMode = magic.BLEND_ALPHA
		local s = magic.Scene.new()
		s:CreateComponent("Octree")
		local zone = s:CreateChild("zone"):CreateComponent("Zone")
		zone.boundingBox = magic.BoundingBox(-1000, 1000)
		zone.fogColor = magic.Color(0, 0, 0, 0)
		zone.fogStart = 10000
		zone.fogEnd = 10000
		zone.ambientColor = magic.Color(1, 1, 1)
		local lo, hi = {math.huge, math.huge, math.huge},
				{-math.huge, -math.huge, -math.huge}
		for _, q in ipairs(quads) do
			for i = 0, 11 do
				local a = i % 3 + 1
				lo[a] = math.min(lo[a], q.p[i + 1])
				hi[a] = math.max(hi[a], q.p[i + 1])
			end
		end
		local radius = math.max(0.001, 0.5 * math.sqrt((hi[1] - lo[1])^2 +
				(hi[2] - lo[2])^2 + (hi[3] - lo[3])^2))
		local pivot = s:CreateChild("pivot")
		local node = pivot:CreateChild("model")
		build_object_mesh(node, quads, tiles or {})
		node.position = magic.Vector3(-(lo[1] + hi[1]) / 2,
				-(lo[2] + hi[2]) / 2, -(lo[3] + hi[3]) / 2)
		pivot.rotation = magic.Quaternion(rot_x, rot_y, 0)
		local cam_node = s:CreateChild("camera")
		local cam = cam_node:CreateComponent("Camera")
		local dist = radius / math.tan(math.rad(cam.fov / 2)) * 1.1
		if h > w then
			dist = dist * h / w
		end
		cam_node.position = magic.Vector3(0, 0, -dist)
		cam_node.direction = magic.Vector3(0, 0, 1)
		view:SetView(s, cam)
		return view
	end

	-- The template node of one kind of object mesh: mesh name and textures
	-- -> a node that is not drawn, holding the geometry and its materials.
	--
	-- Every vertex of an object's mesh is a sandbox call
	-- (CustomGeometry:DefineVertex), which for a mob of a few thousand quads
	-- is a quarter of a second -- measured on VoxeLibre: a skeleton took 250
	-- ms, and every skeleton in the world paid it again. So the first of a
	-- kind is built once and the rest are clones of it, which Urho3D copies
	-- inside the engine. The materials are shared with the template, which
	-- is also what keeps them alive: a Material made in Lua lives only while
	-- something in the engine holds it.
	local object_templates = {}

	local function object_template(mesh)
		local key = (mesh.name or "?").."|"..
				table.concat(mesh.tiles or {}, "|")
		local entry = object_templates[key]
		if not entry then
			local node = scene:CreateChild("object_template")
			node.enabled = false
			local cg, materials = build_object_mesh(node, mesh.quads,
					mesh.tiles)
			entry = {node = node, materials = materials}
			object_templates[key] = entry
		end
		return entry
	end


	-- What an object is drawn as.
	--
	-- simplified: an object whose visual is a mesh this can read is drawn as
	-- that mesh posed at its animation's first frame -- the animation does
	-- not play, so a mob stands still -- a sprite visual is a billboard, and everything
	-- else is a box with the object's first texture on it. A box wearing a
	-- cow's texture reads as a cow where nothing at all reads as nothing at
	-- all, which is what the models Urho3D cannot read fall back to.
	--
	-- obj is what objects.lua parsed; resource(obj) says what it is drawn
	-- wearing, as a resource name, or nil for an object whose texture is not
	-- there yet, and as the six tiles of a node or the quads of a model when
	-- it is one of those.
	function self:set_object(obj, resource)
		local props = obj.props
		-- An item that is a node comes back with the six tiles it is drawn
		-- with as well; then it is a small cube of them rather than a
		-- picture of one
		local own, tiles, mesh = resource(obj)
		local cube = tiles ~= nil
		local meshed = not cube and mesh ~= nil
		local sprite = not cube and not meshed and props ~= nil and
				SPRITE_VISUALS[props.visual] or false
		local entry = o.object_nodes[obj.id]
		-- A visual that changed changes which component draws it
		if entry and (entry.sprite ~= sprite or entry.cube ~= cube or
				entry.meshed ~= meshed) then
			scene:RemoveChild(entry.node)
			entry = nil
			o.object_nodes[obj.id] = nil
		end
		if not entry then
			-- A mesh is a copy of its kind's template, which carries the
			-- geometry and the materials already; everything else is built
			-- on a node of its own
			local template = meshed and object_template(mesh) or nil
			local node = template and template.node:Clone() or
					scene:CreateChild("object_"..obj.id)
			entry = {node = node, sprite = sprite, cube = cube,
					meshed = meshed}
			if template then
				node.enabled = true
				entry.textured = true
				entry.materials = template.materials
				entry.model = node:GetComponent("CustomGeometry")
				-- The clone's own materials: a Material made in Lua has no
				-- resource name, so it is not an attribute Urho3D can copy
				for i = 1, #template.materials do
					entry.model:SetMaterial(i - 1, template.materials[i])
				end
			elseif cube then
				entry.model, entry.materials = build_item_cube(node, tiles)
				entry.textured = true
			elseif sprite then
				local set = node:CreateComponent("BillboardSet")
				set.numBillboards = 1
				-- Turned about Y only: a sprite that also leans back when
				-- the camera looks down does not read as standing in the
				-- world
				set.faceCameraMode = magic.FC_ROTATE_Y
				set.castShadows = false
				set.sorted = true
				local billboard = set:GetBillboard(0)
				billboard.position = magic.Vector3(0, 0, 0)
				billboard.enabled = true
				set:Commit()
				entry.model = set
				entry.billboard = billboard
			else
				local model = node:CreateComponent("StaticModel")
				model:SetModel(o.box_model)
				model.castShadows = false
				entry.model = model
			end
			o.object_nodes[obj.id] = entry
		end
		-- Where it is and how big: the object's collision box, which is in
		-- nodes and is not centred on the object's own position
		local sx, sy, sz = 0.6, 1.8, 0.6
		local cy = 0.9
		if props and props.collision_min and props.collision_max then
			sx = math.max(0.05, props.collision_max[1] - props.collision_min[1])
			sy = math.max(0.05, props.collision_max[2] - props.collision_min[2])
			sz = math.max(0.05, props.collision_max[3] - props.collision_min[3])
			cy = (props.collision_max[2] + props.collision_min[2]) / 2
		end
		-- Only the stand-in box is centred on its collision box: Luanti
		-- draws a model, a sprite and a cube at the position itself, and
		-- the selection box is about that ([OBJECT_SELECTION_BOX])
		if cube or meshed or sprite then cy = 0 end
		entry.offset = cy
		if cube then
			-- Drawn at the size the object asked for rather than at what
			-- it collides with, the same as a sprite. visual_size is what
			-- Luanti scales the item mesh by, and a dropped node comes out
			-- at about a third of a node, which is what its 0.4 is.
			--
			-- simplified: Luanti's own chain to a final size runs through
			-- the wield mesh's own scale factors; this takes visual_size as
			-- it is, which lands in the same place for a dropped node.
			local v = props and props.visual_size or nil
			entry.node.scale = magic.Vector3(
					math.max(0.05, v and v[1] or 1),
					math.max(0.05, v and v[2] or 1),
					math.max(0.05, v and v[3] or v and v[1] or 1))
			-- How fast it turns, in degrees a second; automatic_rotate is
			-- radians a second
			entry.spin = (props and props.automatic_rotate or 0) *
					180 / math.pi
		elseif meshed then
			-- A model is drawn at the size the object asked for, the same as
			-- a sprite: what it collides with is not what it looks like.
			--
			-- An object's model is authored in Luanti's own scene units,
			-- where a node is ten across, and visual_size scales it in those.
			-- Everything here is in nodes, so the tenth is the conversion. A
			-- node's "mesh" drawtype is the other way round -- authored one
			-- unit to the node -- which is why shapes.lua does not do this.
			local v = props and props.visual_size or nil
			local to_nodes = 1 / 10
			entry.node.scale = magic.Vector3(
					math.max(0.005, (v and v[1] or 1) * to_nodes),
					math.max(0.005, (v and v[2] or 1) * to_nodes),
					math.max(0.005, (v and v[3] or v and v[1] or 1) *
							to_nodes))
		elseif sprite then
			-- A billboard is sized by itself, and by what the object asked
			-- for rather than by what it collides with: a dropped item's
			-- collision box is a whole node and its picture is not
			local w = props.visual_size and props.visual_size[1] or 1
			local h = props.visual_size and props.visual_size[2] or 1
			entry.node.scale = magic.Vector3(1, 1, 1)
			entry.billboard.size = magic.Vector2(math.max(0.05, w) / 2,
					math.max(0.05, h) / 2)
			entry.model:Commit()
		else
			entry.node.scale = magic.Vector3(sx, sy, sz)
		end
		entry.node.position = magic.Vector3(obj.position[1],
				obj.position[2] + cy, obj.position[3])
		entry.at_x, entry.at_y, entry.at_z = obj.position[1], obj.position[2],
				obj.position[3]
		-- A cube of its own is turned by its spin below and by nothing else
		if not entry.spin or entry.spin == 0 then
			entry.node.rotation = magic.Quaternion(0, -(obj.yaw or 0), 0)
			entry.at_yaw = obj.yaw or 0
		end
		entry.lit_at = o.daylight() and math.floor(o.daylight() * 256)
		o.light_object(entry, obj.position[1], obj.position[2], obj.position[3])

		-- Cleared whatever the object is drawn as: a cube's tiles go on
		-- once, and a flag left set would rebuild it every frame
		local was_stale = obj.visual_stale
		obj.visual_stale = false
		if not cube and not meshed and (was_stale or not entry.textured) then
			-- An object whose texture is not there yet wears the placeholder
			-- rather than nothing: a box with no material at all is drawn
			-- flat white, which reads as a hole in the world
			local name = own or (not entry.material and texture)
			if name then
				local material = magic.Material.new()
				material:SetTechnique(0, o.box_technique)
				material:SetTexture(0, game_texture(name))
				entry.model.material = material
				entry.material = material
				entry.light_key = nil
				-- The placeholder does not count as textured: the object's
				-- own texture may still turn up
				entry.textured = own ~= nil
			end
		end
	end
end
-- vim: set noet ts=4 sw=4:
