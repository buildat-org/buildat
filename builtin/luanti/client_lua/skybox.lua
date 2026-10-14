-- Buildat: vanilla/client_lua/skybox.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- A game's own sky: six pictures on a cube rather than the gradient a
-- "regular" sky asks for, which is what `set_sky({type = "skybox",
-- textures = {...}})` means and what nodecore's night of coloured stars and
-- nebulae is.
--
-- A node of its own, disabled until a game asks for one: the gradient sky
-- belongs to `builtin/voxel_shading` and every game that says nothing keeps
-- it exactly as it was. In its own file because init.lua is at Lua 5.1's
-- limit of two hundred locals in a chunk.
--
-- simplified: the cube is built from the pictures as they arrive and rebuilt
-- only when the six names change. nodecore darkens its own faces by level,
-- which arrives as six new names and is handled; a texture whose own content
-- changes underneath is not.
local log = buildat.Logger("vanilla")
local magic = require("buildat/extension/urho3d")

local M = {}

-- Luanti's texture order is Y+, Y-, X+, X-, Z-, Z+; Urho3D's cube faces are
-- +X, -X, +Y, -Y, +Z, -Z, and **face 0 has to be set first** because
-- TextureCube:SetData() sizes the cube from it and refuses any face that
-- does not match. So this is Urho's order, naming Luanti's picture for each.
local FACE_OF = {3, 4, 1, 2, 6, 5}

-- A picture already square and the same size as the others goes to the cube
-- as it is. Anything else is resampled, and that is one Lua call per pixel,
-- so it is kept small.
local RESAMPLE_MAX = 128

-- Nearest neighbour into a new image rather than Image:Resize(), because the
-- image the resource cache hands over is shared: resizing it in place would
-- change it for whoever asks for the same texture next.
local function square_copy(img, size)
	local out = magic.Image:new()
	if not out:SetSize(size, size, 4) then
		return nil
	end
	local sx = img.width / size
	local sy = img.height / size
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			out:SetPixel(x, y, img:GetPixel(
					math.floor(x * sx), math.floor(y * sy)))
		end
	end
	return out
end

-- scene: where the node goes. gradient: the sky node create_skybox() made,
-- which is turned off while a game's own is up. texture_of: an expression to
-- a resource name, which is luanti.texture().
function M.new(scene, gradient, texture_of)
	local node = scene:CreateChild("GameSky")
	local box = node:CreateComponent("Skybox")
	box:SetModel(magic.cache:GetResource("Model", "Models/Box.mdl"))
	node.enabled = false

	-- What is on it now, so that the same six names arriving again cost
	-- nothing: a game may set its sky every few seconds, and minetest_game
	-- does
	local names_now = nil
	local self = {}

	function self:set(textures)
		local names = table.concat(textures or {}, "\1")
		if names == names_now then
			return
		end
		local images = {}
		local size, same = nil, true
		for i = 1, 6 do
			local expr = textures[i]
			local resource = expr and texture_of(expr)
			local img = resource and
					magic.cache:GetResource("Image", resource)
			if img == nil then
				log:warning("the game's skybox has no picture for face " .. i)
				return
			end
			images[i] = img
			if img.width ~= img.height then
				same = false
			end
			if size == nil then
				size = img.width
			elseif size ~= img.width then
				same = false
			end
			size = math.min(size, img.width, img.height)
		end
		if not same then
			size = math.min(size, RESAMPLE_MAX)
			for i = 1, 6 do
				images[i] = square_copy(images[i], size)
				if images[i] == nil then
					log:warning("the game's skybox could not be resampled")
					return
				end
			end
		end
		local cube = magic.TextureCube:new()
		for face = 0, 5 do
			if not cube:SetData(face, images[FACE_OF[face + 1]]) then
				log:warning("the game's skybox was refused at face " .. face)
				return
			end
		end
		local material = magic.Material:new()
		material:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/DiffSkybox.xml"))
		material:SetTexture(magic.TU_DIFFUSE, cube)
		-- The box is seen from the inside, so every face of it is
		-- back-facing: Techniques/DiffSkybox.xml does not say this and
		-- Urho3D's own skybox material does, which is why a skybox with the
		-- default culling draws nothing at all.
		material.cullMode = magic.CULL_NONE
		box.material = material
		names_now = names
		node.enabled = true
		gradient.enabled = false
		log:info("the game's own skybox is up, " .. size .. " a side" ..
				(same and "" or ", resampled"))
		-- And what the world reflects, which is the same sky: the cube the
		-- zone samples is otherwise the gradient sky's, baked, so a world
		-- under a game's own sky reflected one it was not under.
		return cube
	end

	-- true when there was one to take away, so that the caller knows to put
	-- the reflections back as well
	function self:clear()
		if names_now == nil then
			return false
		end
		names_now = nil
		node.enabled = false
		gradient.enabled = true
		return true
	end

	return self
end

do
	-- The face order is the whole of what is easy to get wrong here, and it
	-- is checked rather than trusted: Urho's face 0 is +X, which is Luanti's
	-- third picture, and every one of Luanti's six is used exactly once.
	assert(FACE_OF[1] == 3 and FACE_OF[2] == 4,
			"skybox: Urho's +X and -X are Luanti's third and fourth")
	assert(FACE_OF[3] == 1 and FACE_OF[4] == 2,
			"skybox: Urho's +Y and -Y are Luanti's first and second")
	local seen = {}
	for _, i in ipairs(FACE_OF) do
		assert(not seen[i], "skybox: picture " .. i .. " is used twice")
		seen[i] = true
	end
	assert(#FACE_OF == 6, "skybox: a cube has six faces")
end

return M
-- vim: set noet ts=4 sw=4:
