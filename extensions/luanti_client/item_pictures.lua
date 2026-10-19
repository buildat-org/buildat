-- Buildat: extension/luanti_client/item_pictures.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- A voxel's inventory picture: the little cube, or its node box's or
-- model's shape. A part of init.lua's connection, which calls this with
-- what it reads of its own and keeps what it hands back ([SPLITS]: moved
-- out as it was):
--   inventory_cube, inventory_shape = <this file>(texmod, texmod_ctx,
--   tile_expression(def, i), read_mesh(def))
-- Each takes a node definition and answers a resource name, or nil.
local item_shape = buildat.run_extension_file("res/item_shape.lua")

return function(texmod, texmod_ctx, tile_expression, read_mesh)
	-- Which drawtypes are a cube, and so are drawn as the little cube an
	-- inventory shows a voxel as. A nodebox, a plant or a mesh is not:
	-- what those look like is their own shape, and their flat tile is a
	-- better lie than a cube would be. NDT_MESH is left out for the same
	-- reason even though the world draws it as its box.
	local CUBE_ITEM_DRAWTYPES = {
		[0] = true,  -- NDT_NORMAL
		[2] = true,  -- NDT_LIQUID
		[3] = true,  -- NDT_FLOWINGLIQUID
		[4] = true,  -- NDT_GLASSLIKE
		[5] = true,  -- NDT_ALLFACES
		[6] = true,  -- NDT_ALLFACES_OPTIONAL
		[13] = true, -- NDT_GLASSLIKE_FRAMED
		[15] = true, -- NDT_GLASSLIKE_FRAMED_OPTIONAL
	}

	-- How big the cube is drawn. It is scaled to the slot afterwards, so
	-- this only decides how much of the texture's detail survives. Nine
	-- times a unit, because that is what Luanti's own geometry is in;
	-- with a unit of eight a face's edge comes out 32 pixels.
	local CUBE_UNIT = 8
	local CUBE_SIZE = 9 * CUBE_UNIT

	-- A voxel as the cube Luanti draws in an inventory: the top face and
	-- the two the viewer would see, each a parallelogram, the sides
	-- darkened so that the three read as three faces.
	--
	-- Luanti renders the node with a camera; three sheared tiles is the
	-- picture that comes out of that, without a render target.
	local function inventory_cube(def)
		if not CUBE_ITEM_DRAWTYPES[def.drawtype] then
			return nil
		end
		-- Luanti's own geometry, from createInventoryCubeImage() in
		-- src/client/imagesource.cpp: on a canvas of nine units the cube
		-- is eight wide and nine tall, a face's horizontal edge runs
		-- four across and two down, and a side face's vertical edge runs
		-- five down. Being taller than it is wide is the point -- a cube
		-- that fills a square canvas reads as squashed.
		local k = CUBE_UNIT
		-- Tiles are +Y, -Y, +X, -X, +Z, -Z: the top and the two faces
		-- that point at a viewer standing off the +X +Z corner
		--
		-- A side is darkened by asking for the tile with a [multiply on
		-- it rather than by darkening the canvas: the expression
		-- language already does that, and a multiply over the canvas
		-- would darken the faces already drawn as well.
		-- The shades are Luanti's too: 214/256 and 171/256 of the top's
		-- own brightness, which as a [multiply is #d5d5d5 and #aaaaaa
		local faces = {
			{tile = 1, at = {4.5 * k, 0},
					u = {4 * k, 2 * k}, v = {-4 * k, 2 * k}},
			{tile = 5, at = {0.5 * k, 2 * k},
					u = {4 * k, 2 * k}, v = {0, 5 * k},
					shade = "#d5d5d5"},
			{tile = 3, at = {4.5 * k, 4 * k},
					u = {4 * k, -2 * k}, v = {0, 5 * k},
					shade = "#aaaaaa"},
		}
		local ops = {}
		local key = "\0cube"
		for _, face in ipairs(faces) do
			local expr = tile_expression(def, face.tile)
			if not expr then
				return nil
			end
			if face.shade then
				expr = expr.."^[multiply:"..face.shade
			end
			local resource = texmod.resolve(expr, texmod_ctx)
			if not resource then
				return nil
			end
			key = key.."\0"..expr
			ops[#ops + 1] = {op = "shear", src = resource,
					at = face.at, u = face.u, v = face.v}
		end
		return texmod_ctx.compose(def.name..key, ops,
				{CUBE_SIZE, CUBE_SIZE})
	end

	-- A node box's or a mesh's node as its shape, the way Luanti's
	-- inventory renders it (res/item_shape.lua)
	local function inventory_shape(def)
		local quads = nil
		if def.drawtype == 12 and def.node_box and
				#def.node_box.boxes > 0 then -- NDT_NODEBOX
			quads = item_shape.box_quads(def.node_box.boxes)
		elseif def.drawtype == 16 then -- NDT_MESH
			quads = read_mesh(def)
		end
		if not quads then
			return nil
		end
		local key = "\0shape"
		local ops = item_shape.ops(quads, CUBE_UNIT, function(tile, shade)
			local expr = tile_expression(def, math.min(tile, 6))
			if not expr then
				return nil
			end
			if shade then
				expr = expr.."^[multiply:"..shade
			end
			key = key.."\0"..expr
			return texmod.resolve(expr, texmod_ctx)
		end)
		return ops and texmod_ctx.compose(def.name..key, ops,
				{CUBE_SIZE, CUBE_SIZE})
	end

	return inventory_cube, inventory_shape
end
-- vim: set noet ts=4 sw=4:
