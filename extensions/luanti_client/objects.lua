-- Buildat: extension/luanti_client/objects.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The things in the world that are not nodes: other players, mobs, dropped
-- items, and whatever else a game's mods put there.
--
-- The server sends them as a list of ids that went away and ids that arrived
-- with their initialization data, and then a stream of messages per id: where
-- an object is now, what it looks like, what it is doing. This reads those
-- into a table of objects; what to draw for one is the caller's business.
--
-- What is read of an object's properties is what it takes to put something
-- where it is and give it the right texture and size, and the first frame
-- of its animation. The rest -- the animation playing, bone positions --
-- is skipped, which is what makes this survive the messages it does not
-- implement.

local M = {}

-- Luanti's ActiveObjectCommand, from its activeobject.h
M.CMD_SET_PROPERTIES = 0
M.CMD_UPDATE_POSITION = 1
M.CMD_SET_TEXTURE_MOD = 2
M.CMD_SET_SPRITE = 3
M.CMD_PUNCHED = 4
M.CMD_UPDATE_ARMOR_GROUPS = 5
M.CMD_SET_ANIMATION = 6
M.CMD_ATTACH_TO = 8
M.CMD_SET_PHYSICS_OVERRIDE = 9

local PROPERTIES_VERSION = 4

-- Positions and speeds come in Luanti's BS units, where a node is ten across
local BS = 10.0

-- ObjectProperties, as far as anything here uses. The order is
-- ObjectProperties::deSerialize in Luanti's object_properties.cpp; everything
-- past use_texture_alpha is optional and is left alone.
function M.read_properties(r)
	local version = r:u8()
	if version ~= PROPERTIES_VERSION then
		error("luanti_client/objects: ObjectProperties version "..version)
	end
	local props = {}
	props.hp_max = r:u16()
	props.physical = r:u8() ~= 0
	r:skip(4) -- Used to be the weight
	-- The boxes are in nodes, not in BS units
	props.collision_min = {r:f32(), r:f32(), r:f32()}
	props.collision_max = {r:f32(), r:f32(), r:f32()}
	props.selection_min = {r:f32(), r:f32(), r:f32()}
	props.selection_max = {r:f32(), r:f32(), r:f32()}
	props.pointable = r:u8()
	props.visual = r:string()
	props.visual_size = {r:f32(), r:f32(), r:f32()}
	props.textures = {}
	for _ = 1, r:u16() do
		props.textures[#props.textures + 1] = r:string()
	end
	props.spritediv = {r:s16(), r:s16()}
	props.initial_sprite_basepos = {r:s16(), r:s16()}
	props.is_visible = r:u8() ~= 0
	r:u8() -- makes_footstep_sound
	props.automatic_rotate = r:f32()
	props.mesh = r:string()
	props.colors = {}
	for _ = 1, r:u16() do
		props.colors[#props.colors + 1] = r:u32()
	end
	r:u8() -- collide_with_objects
	r:f32() -- stepheight
	r:u8() -- automatic_face_movement_dir
	r:f32() -- automatic_face_movement_dir_offset
	props.backface_culling = r:u8() ~= 0
	props.nametag = r:string()
	r:skip(4) -- nametag_color
	r:f32() -- automatic_face_movement_max_rotation_per_sec
	props.infotext = r:string()
	props.wield_item = r:string()
	props.glow = r:u8()
	props.breath_max = r:u16()
	props.eye_height = r:f32()
	props.zoom_fov = r:f32()
	props.use_texture_alpha = r:u8() ~= 0
	return props
end

-- One message for one object. What it does not understand it ignores, which
-- is most of them: the object still sits in the right place.
function M.apply_message(obj, r)
	local cmd = r:u8()
	if cmd == M.CMD_SET_PROPERTIES then
		obj.props = M.read_properties(r)
		obj.visual_stale = true
	elseif cmd == M.CMD_UPDATE_POSITION then
		local x, y, z = r:f32() / BS, r:f32() / BS, r:f32() / BS
		r:f32(); r:f32(); r:f32() -- velocity
		r:f32(); r:f32(); r:f32() -- acceleration
		local rx, ry, rz = r:f32(), r:f32(), r:f32()
		local interpolate = r:u8() ~= 0
		r:u8() -- is_end_position
		local interval = r:f32()
		obj.target = {x, y, z}
		obj.yaw = ry
		if not interpolate or not obj.position then
			obj.position = {x, y, z}
			obj.interval = 0
		else
			-- How long the server says it will be until the next one, which
			-- is how long this move should take
			obj.interval = interval > 0 and interval or 0.1
		end
	elseif cmd == M.CMD_UPDATE_ARMOR_GROUPS then
		-- The whole set each time; what the player's own says is read for
		-- fall damage (immortal, fall_damage_add_percent)
		local groups = {}
		for _ = 1, r:u16() do
			local name = r:string()
			groups[name] = r:s16()
		end
		obj.armor_groups = groups
	elseif cmd == M.CMD_SET_ANIMATION then
		-- The frames a model plays (AO_CMD_SET_ANIMATION, GenericCAO's
		-- reader): what is drawn is the model posed at the first of them,
		-- as vanilla's module draws it ([LUANTI_SHARED_1019]). The speed,
		-- the blend and the loop after them are not read.
		local first = r:f32()
		if first ~= obj.anim_frame then
			obj.anim_frame = first
			obj.visual_stale = true
		end
	elseif cmd == M.CMD_SET_TEXTURE_MOD then
		obj.texture_mod = r:string()
		obj.visual_stale = true
	elseif cmd == M.CMD_ATTACH_TO then
		-- **What rides on something else** (AO_CMD_ATTACH_TO): the parent
		-- object, the bone of its model, and the offset in that bone's
		-- frame. Nothing here follows a bone -- a b3d skeleton's bones are
		-- not reachable from this side -- so an attached object has no
		-- position this can compute, and its own last one is wrong:
		-- VoxeLibre's wieldview then rides at its player's feet rather
		-- than in the hand, which is what the box saw ([OVER_SHOULDER]).
		-- Luanti puts it in the hand or not at all, so this takes the
		-- second: parent 0 detaches and the object is drawn again.
		local parent = r:s16()
		obj.attach_bone = r:string()
		obj.attached_to = parent ~= 0 and parent or nil
		-- Both ways round: attaching takes the drawn object away and
		-- detaching brings it back, and both go through the same queue
		obj.visual_stale = true
	elseif cmd == M.CMD_SET_PHYSICS_OVERRIDE then
		-- A mod's physics_override for the player this object is
		-- (PlayerSAO::getPropertyPacket's AO_CMD_SET_PHYSICS_OVERRIDE):
		-- the three multipliers, then the three flags as "not", then the
		-- rest (5.9+); the player's physics multiplies by them. The
		-- fixture's gravity 0 held nowhere here, and a game's speed
		-- potion did nothing ([DIG_PARITY], 2026-09-22).
		local ov = {speed = r:f32(), jump = r:f32(), gravity = r:f32()}
		if r:remaining() >= 3 then
			ov.sneak = r:u8() == 0 and 1 or 0
			ov.sneak_glitch = r:u8() == 0 and 1 or 0
			ov.new_move = r:u8() == 0
		end
		if r:remaining() >= 4 * 5 then
			ov.speed_climb = r:f32(); ov.speed_crouch = r:f32()
			ov.liquid_fluidity = r:f32(); ov.liquid_fluidity_smooth = r:f32()
			ov.liquid_sink = r:f32()
		end
		if r:remaining() >= 4 * 2 then
			ov.acceleration_default = r:f32(); ov.acceleration_air = r:f32()
		end
		obj.physics_override = ov
	end
end

-- The initialization data of an object that just arrived
function M.parse_init(serialize, data)
	local r = serialize.reader(data)
	local version = r:u8()
	if version < 1 then
		error("luanti_client/objects: init data version "..version)
	end
	local obj = {}
	obj.name = r:string()
	obj.is_player = r:u8() ~= 0
	obj.id = r:u16()
	obj.position = {r:f32() / BS, r:f32() / BS, r:f32() / BS}
	local rx, ry, rz = r:f32(), r:f32(), r:f32()
	obj.yaw = ry
	obj.hp = r:u16()
	obj.interval = 0
	for _ = 1, r:u8() do
		local message = serialize.reader(r:longstring())
		local ok, err = pcall(M.apply_message, obj, message)
		if not ok then
			obj.broken = tostring(err)
		end
	end
	return obj
end

-- Moves the objects towards where the server last said they are. Luanti does
-- the same: a position arrives every tenth of a second or so and the object
-- walks there rather than jumping.
function M.interpolate(objects, dtime)
	for _, obj in pairs(objects) do
		if obj.target and obj.position then
			local f = 1
			if obj.interval and obj.interval > 0 then
				f = dtime / obj.interval
				if f > 1 then
					f = 1
				end
			end
			-- Landed on the target once within a millimetre: an object
			-- easing forever is one placed and relit every frame
			for i = 1, 3 do
				local d = obj.target[i] - obj.position[i]
				obj.position[i] = (d > -0.001 and d < 0.001) and
						obj.target[i] or obj.position[i] + d * f
			end
		end
	end
end

return M
-- vim: set noet ts=4 sw=4:
