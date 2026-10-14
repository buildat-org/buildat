-- Buildat: extension/luanti_client/world_pointing.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- What the camera points at, the box around it and the crack on a node
-- being dug: a part of world.lua's M.new, which calls this with what it
-- reads of M.new's and keeps the box's node ([SPLITS]: moved out as it
-- was).

return function(self, magic, scene, camera_node, game_texture)
	-- What the camera is pointing at, up to range nodes away. Returns the
	-- node the ray stopped in and the last empty node before it, which is
	-- where a placed node would go, or nil for nothing in range.
	--
	-- Marching in steps a tenth of a node long and rounding to the nearest
	-- integer, which is what apps/demo_digger does: a node is the cube around
	-- its coordinate, so rounding is the whole test. A step that lands in the
	-- same node as the last one is skipped rather than asked about twice.
	local POINT_STEP = 0.1

	function self:point_ray(range)
		local p = camera_node.position
		local d = camera_node.direction
		local last = nil
		for i = 1, math.floor(range / POINT_STEP) do
			local x = math.floor(p.x + d.x * i * POINT_STEP + 0.5)
			local y = math.floor(p.y + d.y * i * POINT_STEP + 0.5)
			local z = math.floor(p.z + d.z * i * POINT_STEP + 0.5)
			if not last or x ~= last[1] or y ~= last[2] or z ~= last[3] then
				if self:is_pointable(x, y, z) then
					return {x, y, z}, last, i * POINT_STEP
				end
				last = {x, y, z}
			end
		end
		return nil
	end

	-- The nearest object the camera ray enters, up to range nodes away.
	-- Returns its id and how far along the ray its box begins, or nil.
	--
	-- An object is pointed at by its selection box, which is in nodes and is
	-- given around the object's own position. props.pointable is Luanti's
	-- PointabilityType: 0 is not pointable, 1 is, and 2 stops the ray
	-- without being pointed at itself -- so a 2 is tested for distance and
	-- then reported as nothing.
	--
	-- The player's own object is skipped: it stands where the camera is, so
	-- the ray starts inside its box and it would be pointed at all the
	-- time. init.lua marks it is_self.
	function self:point_objects(range, objects)
		local p = camera_node.position
		local d = camera_node.direction
		local best_id, best_t, best_blocks = nil, range, false
		for id, obj in pairs(objects) do
			local props = obj.props
			local pointable = props and props.pointable or 0
			-- An object riding on a bone is not drawn ([OVER_SHOULDER]),
			-- and what is not drawn is not pointed at either: the wieldview
			-- at a player's feet took every punch aimed past it
			if obj.position and pointable ~= 0 and not obj.is_self and
					not obj.attached_to and
					props.is_visible ~= false and
					props.selection_min and props.selection_max then
				local lo = {
					obj.position[1] + props.selection_min[1],
					obj.position[2] + props.selection_min[2],
					obj.position[3] + props.selection_min[3],
				}
				local hi = {
					obj.position[1] + props.selection_max[1],
					obj.position[2] + props.selection_max[2],
					obj.position[3] + props.selection_max[3],
				}
				-- The slab test: the ray is inside the box between the
				-- largest near crossing and the smallest far one
				local origin = {p.x, p.y, p.z}
				local dir = {d.x, d.y, d.z}
				local t0, t1 = 0, range
				for axis = 1, 3 do
					if math.abs(dir[axis]) < 1e-9 then
						if origin[axis] < lo[axis] or
								origin[axis] > hi[axis] then
							t0, t1 = 1, 0 -- Parallel and outside
						end
					else
						local a = (lo[axis] - origin[axis]) / dir[axis]
						local b = (hi[axis] - origin[axis]) / dir[axis]
						if a > b then
							a, b = b, a
						end
						t0 = math.max(t0, a)
						t1 = math.min(t1, b)
					end
				end
				if t0 <= t1 and t0 < best_t then
					best_id = pointable == 1 and id or nil
					best_t = t0
					best_blocks = true
				end
			end
		end
		if not best_blocks then
			return nil
		end
		return best_id, best_t
	end

	-- The outline of the face the ray came through, on the node it stopped
	-- in. One flat outline that gets turned to whichever face it is, which is
	-- what apps/demo_digger does; NoTextureVColMultiply darkens what is behind it
	-- rather than drawing over it, so it reads on any texture.
	-- What is pointed at: a frame around every face of the voxel, which
	-- together read as the wire box Luanti draws around it. Two triangles
	-- per side of each frame, in one geometry, and the whole thing is moved
	-- to the voxel that is pointed at rather than built again.
	--
	-- simplified: the box is the voxel's cube, not its shape, so what is
	-- outlined around a stair or a torch is the whole voxel. Luanti outlines
	-- the selection box, which is what would have to be handed in here.
	local pointed_node = scene:CreateChild("Pointed")
	do
		local cg = pointed_node:CreateComponent("CustomGeometry")
		cg:BeginGeometry(0, magic.TRIANGLE_LIST)
		cg:SetNumGeometries(1)
		local color = magic.Color(0.06, 0.06, 0.06)
		-- Just outside the voxel, so the frame does not fight the face it is
		-- drawn on for the depth buffer
		local d = 0.502
		-- Half of the 1/16 it was (user, 2026-10-14, [SELECTION_BOX])
		local w = 1.0 / 32

		-- One rectangle in a plane, given as the two axes it runs along and
		-- the constant of the third. axis is 1, 2 or 3 for x, y or z.
		-- Wound both ways: the frames on three of the six faces would
		-- otherwise face away from the middle of the voxel and be culled,
		-- which is the same as not drawing them at all.
		local function quad(axis, at, a0, b0, a1, b1)
			local corners = {
				{a0, b1}, {a1, b1}, {a1, b0}, {a1, b0}, {a0, b0}, {a0, b1},
				{a0, b1}, {a0, b0}, {a1, b0}, {a1, b0}, {a1, b1}, {a0, b1},
			}
			for _, c in ipairs(corners) do
				local p = {}
				if axis == 2 then
					p = {c[1], at, c[2]}
				elseif axis == 1 then
					p = {at, c[1], c[2]}
				else
					p = {c[1], c[2], at}
				end
				cg:DefineVertex(magic.Vector3(p[1], p[2], p[3]))
				cg:DefineColor(color)
				-- Unlit's VS reads a UV whatever NOUV says; WebGL refuses
				-- a draw that fetches an attribute the buffer has not got
				cg:DefineTexCoord(magic.Vector2(0, 0))
			end
		end

		-- The four bars of a frame in one plane
		local function frame(axis, at)
			quad(axis, at, -d, d - w, d, d)
			quad(axis, at, -d, -d, d, -d + w)
			quad(axis, at, d - w, -d + w, d, d - w)
			quad(axis, at, -d, -d + w, -d + w, d - w)
		end

		for axis = 1, 3 do
			frame(axis, d)
			frame(axis, -d)
		end
		cg:Commit()
		local m = magic.Material.new()
		m:SetTechnique(0, magic.cache:GetResource("Technique",
				"luanti_client/res/LuantiFrame.xml"))
		cg:SetMaterial(0, m)
		pointed_node.enabled = false
	end

	-- The crack over the voxel being dug. Luanti draws it as a second layer
	-- on the voxel's own tiles, which follows whatever shape it has; this is
	-- a cube just outside the voxel wearing one frame of the crack texture,
	-- which is the same picture on anything that is a cube.
	--
	-- simplified: so the crack on a stair or a torch is a cube around it.
	-- The faithful way is a voxel per (definition, crack frame) through the
	-- pair machinery, which is five more voxel types per definition -- and
	-- the definitions are already two and a half thousand.
	--
	-- One node per frame, enabled one at a time, rather than one node whose
	-- material is swapped: a Material lives only as long as something in the
	-- engine holds it, and a StaticModel that has been handed one is such a
	-- thing. Keeping materials in a Lua table and putting them back on the
	-- model later reads the freed one.
	local crack_nodes = {}
	local crack_worn = nil

	local function crack_node_for(resource)
		local node = crack_nodes[resource]
		if node then
			return node
		end
		node = scene:CreateChild("Crack")
		local model = node:CreateComponent("StaticModel")
		model.model = magic.cache:GetResource("Model", "Models/Box.mdl")
		local material = magic.Material.new()
		material:SetTechnique(0, magic.cache:GetResource("Technique",
				"luanti_client/res/UnlitAlphaMask.xml"))
		material:SetTexture(0, game_texture(resource))
		model.material = material
		-- Just outside the voxel, so the crack does not fight the face it is
		-- drawn on for the depth buffer
		node.scale = magic.Vector3(1.004, 1.004, 1.004)
		node.enabled = false
		crack_nodes[resource] = node
		return node
	end

	-- set_crack(under, resource)
	--
	-- under is the voxel being dug and resource the texture of the frame the
	-- dig has got to; either being nil takes the crack away.
	function self:set_crack(under, resource)
		if crack_worn and crack_worn ~= resource then
			crack_nodes[crack_worn].enabled = false
			crack_worn = nil
		end
		if not under or not resource then
			return
		end
		local node = crack_node_for(resource)
		node.position = magic.Vector3(under[1], under[2], under[3])
		node.enabled = true
		crack_worn = resource
	end

	return pointed_node
end
-- vim: set noet ts=4 sw=4:
