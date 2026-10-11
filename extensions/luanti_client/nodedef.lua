-- Buildat: extension/luanti_client/nodedef.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- What a node id means, out of Luanti's NODEDEF.
--
-- The packet is
--   u8 version | u16 count | u32 string
-- and inside that string, per node,
--   u16 id | u16 string wrapper
-- Every node's definition is in its own length-prefixed wrapper, so only the
-- front of it has to be understood: the name, the draw type and the six tiles.
-- The rest of the wrapper -- physics, liquids, node boxes, sounds -- is skipped
-- whole, which is also what makes this survive a server that knows a newer
-- ContentFeatures version than the one written here.
--
-- The parsing goes down to TileDef because a tile is variable-length: what the
-- flags say decides whether a colour, a scale and an align style follow, and
-- the six tiles cannot be found without reading through them.

local M = {}

-- Luanti's NodeDrawType, in order
M.DRAWTYPE = {
	NORMAL = 0,
	AIRLIKE = 1,
	LIQUID = 2,
	FLOWINGLIQUID = 3,
	GLASSLIKE = 4,
	ALLFACES = 5,
	ALLFACES_OPTIONAL = 6,
	TORCHLIKE = 7,
	SIGNLIKE = 8,
	PLANTLIKE = 9,
	FENCELIKE = 10,
	RAILLIKE = 11,
	NODEBOX = 12,
	GLASSLIKE_FRAMED = 13,
	FIRELIKE = 14,
	GLASSLIKE_FRAMED_OPTIONAL = 15,
	MESH = 16,
	PLANTLIKE_ROOTED = 17,
}

-- The oldest ContentFeatures a server may send us; anything below this has a
-- different layout in the part that is read here
local CONTENTFEATURES_VERSION = 13

-- TileDef flags, from nodedef.cpp
local TILE_FLAG_HAS_COLOR = 8
local TILE_FLAG_HAS_SCALE = 16
local TILE_FLAG_HAS_ALIGN_STYLE = 32

local function has_flag(flags, flag)
	return flags % (flag * 2) >= flag
end

local function read_tiledef(r)
	local version = r:u8()
	if version < 6 then
		error("luanti_client/nodedef: TileDef version "..version)
	end
	local name = r:string()
	local animation = r:animation()
	local flags = r:u16()
	-- A tile with a colour of its own is not the one the node's paramtype2
	-- and palette give the rest of them; "white" is how a game says a tile
	-- is to be left alone
	local color = nil
	if has_flag(flags, TILE_FLAG_HAS_COLOR) then
		color = {r:u8(), r:u8(), r:u8()}
	end
	if has_flag(flags, TILE_FLAG_HAS_SCALE) then
		r:u8()
	end
	if has_flag(flags, TILE_FLAG_HAS_ALIGN_STYLE) then
		r:u8()
	end
	return {name = name, animation = animation, color = color}
end

-- Luanti's LiquidType
M.LIQUID_NONE = 0
M.LIQUID_FLOWING = 1
M.LIQUID_SOURCE = 2

-- How many extra tiles follow the six: six overlays, and six special tiles
-- (which is what a flowing liquid's surface and a rooted plant's top are)
local CF_SPECIAL_COUNT = 6

-- Luanti's NodeBoxType
M.NODEBOX_REGULAR = 0
M.NODEBOX_FIXED = 1
M.NODEBOX_WALLMOUNTED = 2
M.NODEBOX_LEVELED = 3
M.NODEBOX_CONNECTED = 4

-- On the wire a box's corners are in Luanti's BS units, where a node is ten
-- across; what comes out is in nodes, so a full node's box is -0.5...0.5.
local BS = 10.0

-- More boxes than any node has a use for; the limit is so that a broken
-- definition cannot ask for an unreasonable amount of geometry
local MAX_BOXES = 64

local function read_box(r)
	local x0, y0, z0 = r:f32() / BS, r:f32() / BS, r:f32() / BS
	local x1, y1, z1 = r:f32() / BS, r:f32() / BS, r:f32() / BS
	-- A box written the other way round is the same box
	return {
		math.min(x0, x1), math.min(y0, y1), math.min(z0, z1),
		math.max(x0, x1), math.max(y0, y1), math.max(z0, z1),
	}
end

local function read_boxes(r, out)
	for _ = 1, r:u16() do
		local box = read_box(r)
		if out and #out < MAX_BOXES then
			out[#out + 1] = box
		end
	end
	return out
end

-- read_node_box(r) -> {type =, boxes = {...}}
--
-- The boxes are the ones to draw for a node standing on its own: a
-- wallmounted box is the one for a node on the floor, and a connected one is
-- its fixed boxes plus the ones it has when nothing is connected. A
-- wallmounted box's three boxes are kept in wall = {top, bottom, side} as
-- well, because which of them a node wants is what its param2 says.
--
-- A connected box keeps its per-direction boxes too, in
-- connect = {[dir] = {boxes}} with dir in buildat's face order (1 is +Y and
-- 6 is -Z), and the ones it has when it stands alone in alone = {boxes}.
-- Which of them a voxel really wants is worked out per voxel by the mesher;
-- shapes.lua is what tags the quads for it.
--
-- simplified: the disconnected_<direction> boxes and disconnected_sides are
-- read past rather than kept. What uses them is rarer than the fences and
-- panes that use the rest, and each would be another tag on a quad.
local function read_node_box(r)
	local version = r:u8()
	if version < 6 then
		error("luanti_client/nodedef: NodeBox version "..version)
	end
	local box_type = r:u8()
	local boxes = {}
	local wall = nil
	-- A connected box's per-direction boxes, and the ones it has when
	-- nothing is connected to it
	local connect = nil
	local alone = nil
	if box_type == M.NODEBOX_FIXED or box_type == M.NODEBOX_LEVELED then
		read_boxes(r, boxes)
	elseif box_type == M.NODEBOX_WALLMOUNTED then
		wall = {top = read_box(r), bottom = read_box(r), side = read_box(r)}
		boxes[1] = wall.bottom
	elseif box_type == M.NODEBOX_CONNECTED then
		read_boxes(r, boxes) -- fixed
		-- Luanti's own order is top, bottom, front, left, back, right, and
		-- its front is -Z; these are the same six in buildat's face order,
		-- which is +Y, -Y, +X, -X, +Z, -Z.
		local CONNECT_FACE = {1, 2, 6, 4, 5, 3}
		connect = {}
		for i = 1, 6 do
			connect[CONNECT_FACE[i]] = read_boxes(r, {})
		end
		for _ = 1, 6 do
			read_boxes(r, nil) -- disconnected_<direction>
		end
		alone = read_boxes(r, {})
		read_boxes(r, nil) -- disconnected_sides
	end
	return {type = box_type, boxes = boxes, wall = wall,
			connect = connect, alone = alone}
end

-- One node's wrapper. Read as far as the fields anything here uses; the
-- caller has already cut the wrapper to length, so the rest -- node boxes,
-- sounds, the legacy fields -- is dropped. The order is
-- ContentFeatures::serialize() in Luanti's nodedef.cpp.
local function read_node(r)
	local version = r:u8()
	if version < CONTENTFEATURES_VERSION then
		error("luanti_client/nodedef: ContentFeatures version "..version)
	end
	local def = {}
	def.name = r:string()
	def.groups = {}
	for _ = 1, r:u16() do
		local group_name = r:string()
		def.groups[group_name] = r:s16()
	end
	r:u8() -- param_type
	def.param_type_2 = r:u8()
	def.drawtype = r:u8()
	-- The model a "mesh" drawtype is drawn as, which is a media name
	def.mesh = r:string()
	def.visual_scale = r:f32()
	local tile_count = r:u8()
	if tile_count ~= 6 then
		error("luanti_client/nodedef: "..tile_count.." tiles, expected 6")
	end
	-- Luanti's tile order is +Y, -Y, +X, -X, +Z, -Z, which is also the order
	-- buildat's VoxelDefinition.textures is in
	def.tiles = {}
	for i = 1, 6 do
		def.tiles[i] = read_tiledef(r)
	end
	-- The overlay of a tile is drawn on top of it; the special tiles belong to
	-- draw types that have surfaces the six do not cover
	def.overlays = {}
	for i = 1, 6 do
		def.overlays[i] = read_tiledef(r)
	end
	local special_count = r:u8()
	if special_count ~= CF_SPECIAL_COUNT then
		error("luanti_client/nodedef: "..special_count.." special tiles")
	end
	def.special = {}
	for i = 1, special_count do
		def.special[i] = read_tiledef(r)
	end
	r:u8() -- alpha for legacy clients; the real one is further down
	-- The colour a tile is multiplied by, for a node whose paramtype2 is not
	-- a palette index
	def.color = {r:u8(), r:u8(), r:u8()}
	-- The palette a "color" paramtype2 indexes, as a media name
	def.palette_name = r:string()
	def.waving = r:u8()
	-- Which of the node's sides may reach into a solid neighbour, as
	-- Luanti's bitmask; nonzero means the node connects to solid faces at
	-- all, which is what this uses it for
	def.connect_sides = r:u8()
	-- The nodes this one connects to, as node ids. Luanti's own rule is that
	-- both ends have to name each other when both are connecting nodes, and
	-- that a plain node is connected to when it declares usable faces.
	def.connects_to = {}
	for _ = 1, r:u16() do
		def.connects_to[#def.connects_to + 1] = r:u16()
	end
	-- What Luanti paints over the whole screen while the camera is inside this
	-- node, as ARGB: a weak blue for water, a strong orange for lava. The
	-- alpha is how much of it there is, and zero means the node has none.
	def.post_effect_color = {a = r:u8(), r = r:u8(), g = r:u8(), b = r:u8()}
	def.leveled = r:u8()
	-- Whether light travels through this node at all, which with the light it
	-- gives is what decides the light around it
	def.light_propagates = r:u8() ~= 0
	def.sunlight_propagates = r:u8() ~= 0
	def.light_source = r:u8()
	r:u8() -- is_ground_content
	-- Interaction: what the player can do to this node, and what it does back
	def.walkable = r:u8() ~= 0
	def.pointable = r:u8()
	def.diggable = r:u8() ~= 0
	def.climbable = r:u8() ~= 0
	def.buildable_to = r:u8() ~= 0
	def.rightclickable = r:u8() ~= 0
	def.damage_per_second = r:u32()
	def.liquid_type = r:u8()
	r:string() -- liquid_alternative_flowing
	-- The source of this liquid, which is what says whether two liquid nodes
	-- are the same liquid: a flowing water and a water source both name the
	-- water source, and lava names lava
	def.liquid_alternative_source = r:string()
	def.liquid_viscosity = r:u8()
	r:u8() -- liquid_renewable
	def.liquid_range = r:u8()
	def.drowning = r:u8()
	def.floodable = r:u8() ~= 0
	-- The shape, three times over: what the node is made of, what a ray
	-- picks, and what the player walks into. A node whose shape is a mesh
	-- has nothing in its node box, and then the selection box is the best
	-- thing there is to draw; the collision box is what the player walks
	-- into, and Luanti falls back to the node box when it is empty.
	def.node_box = read_node_box(r)
	def.selection_box = read_node_box(r)
	def.collision_box = read_node_box(r)

	-- Three sounds, each a name and three floats, and two legacy flags.
	-- The client's own to play, as official's: a footstep, the swing's dig
	-- sound and the dug one ([DIG_SWING_SOUND])
	for _, key in ipairs({"sound_footstep", "sound_dig", "sound_dug"}) do
		local sound = {name = r:string()}
		sound.gain = r:f32()
		sound.pitch = r:f32()
		r:f32()      -- fade
		def[key] = sound
	end
	r:u8()  -- legacy_facedir_simple
	r:u8()  -- legacy_wallmounted
	def.node_dig_prediction = r:string()
	r:u8()  -- leveled_max

	-- How the node's own texture alpha is meant to be used. Luanti's
	-- AlphaMode: 0 blend, 1 clip, 2 opaque, 3 what an old server sends for
	-- opaque. Without this, glass a game gave a real alpha to is alpha
	-- masked -- every texel either solid or gone -- where the game meant it
	-- to be seen through.
	def.alpha_mode = r:u8()
	-- >= 5.5: how much the node holds a body back (water's is its
	-- viscosity unless the game says otherwise) and whether a body in it
	-- swims -- what LocalPlayer reads for in_liquid ([WATER_PARITY]).
	-- Defaults for an older server: none, and swims if it is a liquid.
	def.move_resistance = 0
	def.liquid_move_physics = def.liquid_type ~= nil and def.liquid_type ~= 0
	if r:remaining() >= 2 then
		def.move_resistance = r:u8()
		def.liquid_move_physics = r:u8() ~= 0
	end
	return def
end

-- What a node's alpha mode says about which pass it belongs in. Blended
-- geometry is drawn after the solid world and back to front, which is what
-- the water already does; see VoxelDefinition::translucent.
M.ALPHAMODE_BLEND = 0

-- parse(data) -> {[id] = def}, count
--
-- A def holds name, groups, param_type_2, drawtype, the mesh, the six tiles
-- and their
-- overlays, the colour and palette, and what the player can do to the node:
-- walkable, climbable, diggable, pointable, buildable_to, liquid_type.
--
-- data is the decompressed NODEDEF payload. A node whose definition cannot be
-- read is left out rather than stopping the rest: one node drawn as a
-- placeholder is better than no world.
function M.parse(serialize, data, log)
	local r = serialize.reader(data)
	local version = r:u8()
	if version < 1 then
		error("luanti_client/nodedef: version "..version)
	end
	local count = r:u16()
	local inner = serialize.reader(r:longstring())
	local defs = {}
	local failed = 0
	for _ = 1, count do
		local id = inner:u16()
		local wrapper = serialize.reader(inner:string())
		local ok, def = pcall(read_node, wrapper)
		if ok then
			def.id = id
			defs[id] = def
		else
			failed = failed + 1
			if failed == 1 and log then
				log:warning("nodedef: could not read node "..id..": "..
						tostring(def))
			end
		end
	end
	if failed > 0 and log then
		log:warning("nodedef: "..failed.." of "..count..
				" node definitions could not be read")
	end
	return defs, count
end

return M
-- vim: set noet ts=4 sw=4:
