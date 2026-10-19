-- Buildat: builtin/luanti/lua/entity.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The objects: everything in a Luanti world that is not a node. A mod
-- registers an entity and adds one to the map, and from then on it is a
-- luaentity -- a table of the mod's own -- and an ObjectRef, which is the
-- handle everything else holds it by.
--
-- In Luanti this half is C++ and only the prototypes are Lua. Here it is all
-- Lua: an object is a position, a velocity, an acceleration and a box, and
-- the step moves it and tells it what it ran into. That is what the vendored
-- builtin's own entities are written against -- the dropped item and the
-- falling node -- and they are the ones that make a dig and a dug-out
-- support do anything at all.
--
-- simplified, and each is its own milestone rather than a corner cut here:
--
-- * Nothing draws them. The objects are the server's; the client half of the
--   module is what would show them, and until it does a world with an item
--   in it looks empty. Nothing in here depends on that being true.
-- * Nothing saves them. Luanti writes an object into the block it is in and
--   reads it back when the block loads; here the world is loaded whole for
--   the run, so static_save, get_staticdata and the dtime_s an on_activate
--   is given have nothing to be different about yet. M6's map is where they
--   start to.
-- * No attachments, so collide_with_objects and the parent and child of an
--   attachment are the empty answer rather than an answer.
-- * The collision is axis by axis against the voxels a box overlaps, with no
--   stepping up and no sliding along a corner. An item lands on the floor
--   and stays out of a wall, which is what the builtin's entities ask about.

local objects = {}      -- id -> the object's own state
local next_id = 1

local __show_objects_to = __luanti_show_objects_to
local __show_object_props_to = __luanti_show_object_props_to
local __send_inventory = __luanti_send_inventory
local __send_player_pos = __luanti_send_player_pos

-- The client's own bars: how much life and breath the player has. Luanti
-- sends these as their own packets and draws hearts and bubbles for them;
-- what a game draws instead is the HUD elements above, and the healthbar
-- and breathbar flags are how it says so.
-- Defined where the rest of the HUD is sent, far below; a player's hotbar is
-- set from up here as well
local send_hotbar
local send_hud
-- Where a new player starts, defined with the join below; respawn() up
-- here asks it too
local find_spawn_pos

local function send_stats(o)
	if o and o.player_name and __luanti_send_hud then
		__luanti_send_hud(o.player_name, {"stats",
				tostring(o.hp or 0),
				tostring((o.props and o.props.hp_max) or 20),
				tostring(o.breath or 10),
				tostring((o.props and o.props.breath_max) or 10)})
	end
end

-- What Luanti's server tells a mod when something about a player changed.
-- The names are its own, and its own builtin listens: the hearts and the
-- bubbles on the screen are statbar HUD elements that the builtin adds,
-- changes and takes away as these arrive. Without them a player's health
-- is drawn once, at whatever it was when they joined.
local function player_event(o, name)
	if not o or not o.ref then
		return
	end
	for _, cb in ipairs(core.registered_playerevents or {}) do
		local ok, err = pcall(cb, o.ref, name)
		if not ok then
			core.log("error", "playerevent " .. name .. ": " .. tostring(err))
		end
	end
end

local __show_formspec = __luanti_show_formspec
local __player_formspec = __luanti_player_formspec
local __send_node_inventory = __luanti_send_node_inventory

-- What an entity gets until its initial_properties and set_properties say
-- otherwise. The names are Luanti's, and the ones nothing here reads are
-- kept so that a mod's get_properties() answers with what it set.
local DEFAULT_PROPERTIES = {
	hp_max = 1,
	breath_max = 0,
	physical = false,
	collide_with_objects = true,
	collisionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
	selectionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
	pointable = true,
	visual = "sprite",
	visual_size = {x = 1, y = 1, z = 1},
	textures = {},
	colors = {},
	spritediv = {x = 1, y = 1},
	initial_sprite_basepos = {x = 0, y = 0},
	is_visible = true,
	makes_footstep_sound = false,
	automatic_rotate = 0,
	stepheight = 0,
	static_save = true,
	shaded = true,
	show_on_minimap = false,
	-- The rest of Luanti's own defaults, whether or not anything here reads
	-- them: a mod reads its own object's properties back and does
	-- arithmetic on what it gets. VoxeLibre's environmental sounds add
	-- eye_height to the player's position at every join, and with that one
	-- missing the whole callback died on "arithmetic on a nil value" --
	-- which is what a default nobody thought was needed looks like from the
	-- other side. See src/object_properties.h in Luanti.
	eye_height = 1.625,
	zoom_fov = 0,
	glow = 0,
	backface_culling = true,
	use_texture_alpha = false,
	damage_texture_modifier = "^[brighten",
	nametag = "",
	nametag_color = "#ffffffff",
	infotext = "",
	wield_item = "",
	mesh = "",
	automatic_face_movement_dir = false,
	automatic_face_movement_max_rotation_per_sec = -1,
	rotate_selectionbox = false,
	nametag_scale_z = false,
}

local function vec(v)
	return {x = v.x or 0, y = v.y or 0, z = v.z or 0}
end

-- What the API hands back: a vector with its metatable, because a mod calls
-- methods on what it is given -- pos:round(), pos:offset(0, 5, 0). The
-- vendored builtin is what has vector, so this is a call and not a copy of
-- one made while this file loaded.
local function out_vec(v)
	return vector.new(v.x, v.y, v.z)
end

--
-- ObjectRef
--

local ObjectRef = {}
ObjectRef.__index = ObjectRef

-- **A ref is userdata, as Luanti's is**, made with Lua 5.1's newproxy():
-- a zero-size userdata whose metatable is the class, so `type(ref)` is
-- "userdata" and a game that branches on that -- capturetheflag's
-- PlayerName(), VoxeLibre's mob line of sight -- takes the branch it
-- takes on Luanti. See [REF_IS_TABLE] in doc/plan/luanti_module_plan.md.
-- A userdata holds no fields, so the id is kept beside it, weakly: a ref
-- nobody holds any more takes its entry with it. Every ref of a class
-- shares one metatable through newproxy(prototype).
local ref_ids = setmetatable({}, {__mode = "k"})
local ObjectRef_proto = newproxy(true)
getmetatable(ObjectRef_proto).__index = ObjectRef
getmetatable(ObjectRef_proto).__metatable = ObjectRef

-- new_ref(class_proto, id) -> a ref of that class for object id
local function new_ref(proto, id)
	local ref = newproxy(proto)
	ref_ids[ref] = id
	return ref
end

-- The object id behind a ref, for the few places that send one over the
-- wire; nil for anything that is not a ref
function core.__ref_id(ref)
	return ref_ids[ref]
end

-- A removed object's handle stays valid to hold and answers with nothing,
-- because a mod keeps one across a step as a matter of course
local function state_of(ref)
	return objects[ref_ids[ref]]
end

function ObjectRef:is_valid()
	return state_of(self) ~= nil
end

function ObjectRef:get_pos()
	local o = state_of(self)
	return o and out_vec(o.pos) or nil
end

function ObjectRef:set_pos(pos)
	local o = state_of(self)
	if o then
		o.pos = vec(pos)
	end
end

function ObjectRef:move_to(pos, continuous)
	self:set_pos(pos)
end

function ObjectRef:get_velocity()
	local o = state_of(self)
	return o and out_vec(o.vel) or nil
end

function ObjectRef:set_velocity(vel)
	local o = state_of(self)
	if o then
		o.vel = vec(vel)
	end
end

function ObjectRef:add_velocity(vel)
	local o = state_of(self)
	if o then
		o.vel = {x = o.vel.x + (vel.x or 0), y = o.vel.y + (vel.y or 0),
				z = o.vel.z + (vel.z or 0)}
	end
end

function ObjectRef:get_acceleration()
	local o = state_of(self)
	return o and out_vec(o.acc) or nil
end

function ObjectRef:set_acceleration(acc)
	local o = state_of(self)
	if o then
		o.acc = vec(acc)
	end
end

function ObjectRef:get_rotation()
	local o = state_of(self)
	return o and out_vec(o.rot) or nil
end

function ObjectRef:set_rotation(rot)
	local o = state_of(self)
	if o then
		o.rot = vec(rot)
	end
end

function ObjectRef:get_yaw()
	local o = state_of(self)
	return o and o.rot.y or nil
end

function ObjectRef:set_yaw(yaw)
	local o = state_of(self)
	if o then
		o.rot.y = yaw
	end
end

function ObjectRef:get_properties()
	-- With the metatables, because a property can be a vector and a mod
	-- reading one back expects what it put in
	local o = state_of(self)
	return o and table.copy_with_metatables(o.props) or nil
end

-- The properties Luanti keeps as vectors rather than as whatever table a
-- mod handed over: a mod setting one from a plain table reads a vector back
local PROPERTY_VECTOR2 = {spritediv = true, initial_sprite_basepos = true}
local PROPERTY_VECTOR3 = {visual_size = true}

-- Defined with the physics further down; set_properties sends on a
-- zoom_fov change
local send_physics
function ObjectRef:set_properties(props)
	local o = state_of(self)
	if not o or type(props) ~= "table" then
		return
	end
	for k, v in pairs(props) do
		if PROPERTY_VECTOR2[k] and type(v) == "table" then
			v = vector2.new(v.x or v[1] or 0, v.y or v[2] or 0)
		elseif PROPERTY_VECTOR3[k] and type(v) == "table" then
			-- visual_size = {x, y} is Luanti's older spelling and its z is
			-- the x: a 0 here drew every VoxeLibre mob as a sheet
			-- ([OBJECT_MESH])
			local x = v.x or v[1] or 0
			v = vector.new(x, v.y or v[2] or 0, v.z or v[3] or x)
		end
		o.props[k] = v
	end
	o.look_dirty = true
	if props.hp_max and o.hp > props.hp_max then
		o.hp = props.hp_max
	end
	if o.player_name then
		player_event(o, "properties_changed")
		-- zoom_fov rides the physics packet ([VIEW_KEYS]): official gates
		-- the zoom key on it (0 off, 15 in creative)
		if props.zoom_fov ~= nil then
			send_physics(o)
		end
	end
end

function ObjectRef:get_armor_groups()
	local o = state_of(self)
	return o and table.copy(o.armor_groups) or nil
end

function ObjectRef:set_armor_groups(groups)
	local o = state_of(self)
	if o then
		o.armor_groups = table.copy(groups or {})
	end
end

function ObjectRef:get_hp()
	local o = state_of(self)
	return o and o.hp or 0
end

function ObjectRef:set_hp(hp, reason)
	local o = state_of(self)
	if not o then
		return
	end
	o.hp = math.max(0, math.min(hp, o.props.hp_max or 1))
	if o.hp == 0 and o.le and o.le.on_death then
		-- Who did it, which a mod reads to know what killed its mob; the
		-- hit points are already zero here, which is what Luanti's own
		-- on_death sees too
		o.le:on_death(type(reason) == "table" and reason.object or nil)
	end
	if o.hp == 0 then
		self:remove()
	end
end

-- A punch is the entity's own on_punch first, and the damage the tool does
-- second -- unless the entity says it dealt with it, which is what returning
-- true from on_punch means in Luanti. What the damage is is
-- core.get_hit_params(), rated by this object's armour groups.
function ObjectRef:punch(puncher, time_from_last_punch, tool_capabilities, dir)
	local o = state_of(self)
	if not o then
		return
	end
	-- What it would do is worked out first, because on_punch is told: a mod
	-- that draws a damage number reads that argument and not the hit points
	local hit = core.get_hit_params(o.armor_groups, tool_capabilities,
			time_from_last_punch)
	-- The punch_operable group turns a bare-hand punch into a use, not a
	-- hit: Luanti's getPunchDamage() skips the damage when the wielded
	-- item's name is empty (and only then -- its FIXME says non-tool items
	-- should count too, but they do not)
	if (tonumber(o.armor_groups and o.armor_groups.punch_operable) or 0) > 0
			and puncher and puncher.get_wielded_item
			and puncher:get_wielded_item():get_name() == "" then
		hit = {hp = 0, wear = 0}
	end
	local handled = false
	if o.le and o.le.on_punch then
		handled = o.le:on_punch(puncher, time_from_last_punch,
				tool_capabilities, dir, hit.hp) and true or false
	end
	if handled or o.hp == nil then
		return
	end
	-- An immortal object is not hit at all: Luanti's getPunchDamage()
	-- answers did_punch = false for it. VoxeLibre's mobs are all immortal
	-- and keep their own health; without this the engine's hp went down a
	-- point a punch beside it, and a mob vanished at zero with its own
	-- health nearly full.
	if (tonumber(o.armor_groups and o.armor_groups.immortal) or 0) > 0 then
		return
	end
	if hit.hp > 0 then
		self:set_hp(o.hp - hit.hp, {type = "punch", object = puncher})
	end
end

function ObjectRef:right_click(clicker)
	local o = state_of(self)
	if o and o.le and o.le.on_rightclick then
		o.le:on_rightclick(clicker)
	end
end

function ObjectRef:get_luaentity()
	local o = state_of(self)
	return o and o.le or nil
end

function ObjectRef:get_entity_name()
	local o = state_of(self)
	return o and o.le and o.le.name or nil
end

function ObjectRef:is_player()
	return false
end

-- Luanti has one class for players and everything else, so this answers on
-- any object: the empty string when it is not a player. Mods lean on that
-- rather than on is_player -- VoxeLibre's minecarts push away from whatever
-- is nearby and read the name to decide -- and a missing method is a
-- globalstep that dies instead of an object that is not a player.
function ObjectRef:get_player_name()
	return ""
end

-- Any object's, as Luanti's (l_object.cpp): an entity wields nothing, and
-- VoxeLibre's mob on_punch asks an arrow that hit it (seed 4's drive,
-- 2026-10-05)
function ObjectRef:get_wielded_item()
	return ItemStack()
end

function ObjectRef:set_wielded_item(item)
	return false
end

function ObjectRef:remove()
	local o = state_of(self)
	if not o then
		return
	end
	objects[o.id] = nil
	core.luaentities[o.id] = nil
	core.object_refs[o.id] = nil
	if o.guid then
		core.objects_by_guid[o.guid] = nil
	end
	if o.le and o.le.on_deactivate then
		o.le:on_deactivate(true)
	end
end

-- The ones there is nothing here to do: what they change is how an object
-- looks, and nothing draws it yet. They answer rather than being missing,
-- because a mod that sets a texture and carries on should carry on.
for _, name in ipairs({
	"set_texture_mod",
	"set_nametag_attributes", "set_observers",
	"set_local_animation", -- an entity's; a player's is PlayerRef's below
}) do
	ObjectRef[name] = function() end
end


-- Which frame of its sheet a sprite shows: the start frame is kept and
-- reaches the client with the look (a burning mob's flame, an XP orb's
-- colour, devtest's armour phases). simplified: the first frame only;
-- num_frames and framelength would step it on the client, as the model's
-- animation would ([OBJECT_ANIM]); select_x_by_camera is not read.
function ObjectRef:set_sprite(start_frame, num_frames, framelength, select_x_by_camera)
	local o = state_of(self)
	if o then
		local f = start_frame or {x = 0, y = 0}
		o.sprite = {x = math.floor(tonumber(f.x) or 0),
				y = math.floor(tonumber(f.y) or 0)}
		o.look_dirty = true
	end
end

-- The animation is kept and its first frame reaches the client with the
-- look, which draws the model posed there ([OBJECT_MESH]: a mob standing
-- as its game poses it rather than in its bind pose). The frames in
-- between are step 1's.
function ObjectRef:set_animation(frame_range, frame_speed, frame_blend, frame_loop)
	local o = state_of(self)
	if o then
		local range = frame_range or {x = 1, y = 1}
		o.animation = {x = range.x or 1, y = range.y or 1,
				speed = frame_speed or 15, blend = frame_blend or 0,
				loop = frame_loop ~= false}
		o.look_dirty = true
	end
end

-- The speed alone, which VoxeLibre's mobs set every step to keep the walk
-- in pace with the mob; the client goes on from the frame it is at.
-- simplified: rounded to a quarter of an octave, because a new speed is
-- the look sent again (every mob, every step, otherwise); a speed message
-- of its own, as Luanti's, would carry it exactly.
function ObjectRef:set_animation_frame_speed(frame_speed)
	local o = state_of(self)
	local s = tonumber(frame_speed)
	if o and o.animation and s then
		o.animation.speed = s > 0 and 2 ^ (math.floor(math.log(s) / math.log(2) * 4 + 0.5) / 4) or 0
		o.look_dirty = true
	end
end

function ObjectRef:get_animation()
	local o = state_of(self)
	local a = o and o.animation or {x = 1, y = 1, speed = 15, blend = 0, loop = true}
	return {x = a.x, y = a.y}, a.speed, a.blend, a.loop
end

-- Luanti's own deprecated names, which it keeps as real methods on ObjectRef
-- rather than behind a deprecation shim, so a mod written against them works
-- unchanged. Twelve of them, out of luamethod_aliased() in
-- src/script/lua_api/l_object.cpp. Wasteland's item_drop calls getpos sixty
-- times a second, and without these its globalstep dies on every one.
for name, old in pairs({
	get_pos = "getpos", set_pos = "setpos", move_to = "moveto",
	set_velocity = "setvelocity", get_velocity = "getvelocity",
	add_velocity = "add_player_velocity",
	set_acceleration = "setacceleration",
	get_acceleration = "getacceleration",
	set_yaw = "setyaw", get_yaw = "getyaw",
	set_texture_mod = "settexturemod", set_sprite = "setsprite",
}) do
	-- The check: an alias of a method that was renamed away is a nil call at
	-- sixty hertz, which is exactly the failure these exist to prevent
	assert(ObjectRef[name], "no ObjectRef:" .. name .. " to alias as " .. old)
	ObjectRef[old] = ObjectRef[name]
end

-- Where a bone of a model is put, which a mod sets to aim a gun, open a lid
-- or sit a rider down. Luanti keeps the newer override form and answers the
-- older position-and-rotation one out of it, which is what this does.
--
-- simplified: like the attachments above, this is what was set and read
-- back and not what is drawn -- the models are in their rest pose here. What
-- a mod cares about between one call and the next is that its own numbers
-- survive, angles included: nothing is normalised, so a rotation of a
-- thousand degrees comes back as a thousand degrees.
local function bone_property(v, default)
	return {vec = vector.new(v and v.vec or default),
			interpolation = v and v.interpolation or 0,
			absolute = v and v.absolute or false}
end

function ObjectRef:set_bone_override(bone, override)
	local o = state_of(self)
	if o == nil or bone == nil then
		return
	end
	o.bones = o.bones or {}
	if override == nil then
		o.bones[bone] = nil
		return
	end
	o.bones[bone] = {
		position = bone_property(override.position, vector.zero()),
		rotation = bone_property(override.rotation, vector.zero()),
		scale = bone_property(override.scale, vector.new(1, 1, 1)),
	}
end

function ObjectRef:get_bone_override(bone)
	local o = state_of(self)
	local have = o and o.bones and o.bones[bone] or nil
	return {
		position = bone_property(have and have.position, vector.zero()),
		rotation = bone_property(have and have.rotation, vector.zero()),
		scale = bone_property(have and have.scale, vector.new(1, 1, 1)),
	}
end

function ObjectRef:get_bone_overrides()
	local o = state_of(self)
	local out = {}
	for bone, _ in pairs(o and o.bones or {}) do
		out[bone] = self:get_bone_override(bone)
	end
	return out
end

-- The older pair, which is the same thing with the rotation in degrees
function ObjectRef:set_bone_position(bone, position, rotation)
	self:set_bone_override(bone, {
		position = {vec = position or vector.zero(), absolute = true},
		rotation = {vec = (rotation or vector.zero()):apply(math.rad),
				absolute = true},
	})
end

function ObjectRef:get_bone_position(bone)
	local override = self:get_bone_override(bone)
	return override.position.vec, override.rotation.vec:apply(math.deg)
end

-- What is riding what. A mod attaches a player to a boat, a mob to a mob and
-- an item to a hand, and reads it back; the callbacks it hears are the
-- parent's on_attach_child and on_detach_child and the child's own
-- on_detach.
--
-- simplified: this is the bookkeeping and not the drawing. Nothing moves a
-- child with its parent yet, which is M5's "attachments and bones" -- what
-- it wants is the parent's place and the bone's, and the client half has
-- neither. A mod that attaches and reads back gets what it set.
function ObjectRef:set_attach(parent, bone, position, rotation, forced_visible)
	local o = state_of(self)
	local p = parent and state_of(parent) or nil
	if o == nil or p == nil or parent == self then
		return
	end
	if o.attached_to then
		self:set_detach()
	end
	o.attached_to = {ref = parent, bone = bone, position = position,
			rotation = rotation, forced_visible = forced_visible}
	p.children = p.children or {}
	p.children[#p.children + 1] = self
	if p.le and p.le.on_attach_child then
		p.le:on_attach_child(self)
	end
end

function ObjectRef:get_attach()
	local o = state_of(self)
	local a = o and o.attached_to or nil
	if a == nil then
		return nil
	end
	return a.ref, a.bone, a.position, a.rotation, a.forced_visible
end

function ObjectRef:set_detach()
	local o = state_of(self)
	local a = o and o.attached_to or nil
	if a == nil then
		return
	end
	o.attached_to = nil
	local p = state_of(a.ref)
	if p and p.children then
		for i, child in ipairs(p.children) do
			if child == self then
				table.remove(p.children, i)
				break
			end
		end
	end
	if p and p.le and p.le.on_detach_child then
		p.le:on_detach_child(self)
	end
	if o.le and o.le.on_detach then
		o.le:on_detach(a.ref)
	end
end

function ObjectRef:get_children()
	local o = state_of(self)
	local out = {}
	for _, child in ipairs(o and o.children or {}) do
		out[#out + 1] = child
	end
	return out
end

function ObjectRef:get_guid()
	local o = state_of(self)
	return o and o.guid or nil
end

function ObjectRef:get_texture_mod() return "" end
function ObjectRef:get_animation() return {x = 1, y = 1}, 15, 0, true end




function ObjectRef:get_nametag_attributes() return {text = "", color = nil} end
function ObjectRef:get_observers() return nil end

--
-- The map of them
--

-- A position in a body's region ([BODY_INTERACT]) is where the body's
-- voxel is drawn: an object added there -- a dug node's drop, a mob -- is
-- in the world, not a million nodes up
local function world_pos(pos)
	if type(pos) == "table" and (tonumber(pos.y) or 0) >= 1000000 then
		local wx, wy, wz = __luanti_region_to_world(pos.x, pos.y, pos.z)
		if wx then
			return {x = wx, y = wy, z = wz}
		end
	end
	return pos
end
core.__region_to_world_pos = world_pos

function core.add_entity(pos, name, staticdata)
	pos = world_pos(pos)
	local proto = core.registered_entities[name]
	if proto == nil then
		core.log("error", "add_entity(): no entity called " .. tostring(name))
		return nil
	end
	local id = next_id
	next_id = id + 1
	local ref = new_ref(ObjectRef_proto, id)
	local o = {
		id = id,
		ref = ref,
		pos = vec(pos),
		vel = {x = 0, y = 0, z = 0},
		acc = {x = 0, y = 0, z = 0},
		rot = {x = 0, y = 0, z = 0},
		props = table.copy(DEFAULT_PROPERTIES),
		armor_groups = {},
		hp = 1,
	}
	objects[id] = o
	-- What a mod holds an object by when a reference will not do: unique
	-- while the world runs, and in the table Luanti keeps them in.
	--
	-- simplified: it is this run's own id and not something the world
	-- remembers. Luanti's survives a restart, which is what a mod storing
	-- one in its own storage is relying on; nothing here stores objects
	-- across a run to begin with.
	o.guid = "obj" .. id
	core.objects_by_guid[o.guid] = ref
	-- The luaentity is a table of its own with the prototype as its
	-- metatable, which is what Luanti's own luaentity_Add does: what a mod
	-- sets on self belongs to this entity, and everything else is found
	-- through the prototype -- including what the prototype inherits from a
	-- class of its own, which is how every mob mod is written. A copy of
	-- the prototype would lose exactly that.
	if rawget(proto, "__index") == nil then
		proto.__index = proto
	end
	local le = setmetatable({}, proto)
	le.object = ref
	o.le = le
	core.luaentities[id] = le
	core.object_refs[id] = ref
	if proto.initial_properties then
		ref:set_properties(proto.initial_properties)
	end
	o.hp = o.props.hp_max or 1
	if le.on_activate then
		local ok, err = pcall(le.on_activate, le, staticdata or "", 0)
		if not ok then
			core.log("error", "on_activate: " .. tostring(err))
		end
	end
	-- on_activate may have removed it, and then there is nothing to hand back
	if objects[id] == nil then
		return nil
	end
	return ref
end

-- One of the entities an imported world was holding, with the state its own
-- on_activate wrote. A game that does not register it says so once per kind
-- rather than per entity, which is the importer's to count, so this only
-- says whether it was made.
function core.__import_entity(x, y, z, name, staticdata)
	if core.registered_entities[name] == nil then
		return false
	end
	return core.add_entity({x = x, y = y, z = z}, name, staticdata) ~= nil
end

-- An item nobody registered is not dropped at all, which is what Luanti's
-- own l_add_item answers with nil for: a typo in a mod would otherwise put
-- an entity in the world holding nothing anybody can name.
function core.add_item(pos, item)
	pos = world_pos(pos)
	local stack = ItemStack(item)
	if stack:is_empty() or not stack:is_known() then
		return nil
	end
	return core.spawn_item(pos, stack)
end

local function object_list(match)
	local list = {}
	for _, o in pairs(objects) do
		if match(o.pos) then
			list[#list + 1] = o.ref
		end
	end
	return list
end

function core.get_objects_inside_radius(pos, radius)
	local r2 = radius * radius
	return object_list(function(p)
		local dx, dy, dz = p.x - pos.x, p.y - pos.y, p.z - pos.z
		return dx * dx + dy * dy + dz * dz <= r2
	end)
end

function core.get_objects_in_area(min_pos, max_pos)
	return object_list(function(p)
		return p.x >= min_pos.x and p.x <= max_pos.x and
				p.y >= min_pos.y and p.y <= max_pos.y and
				p.z >= min_pos.z and p.z <= max_pos.z
	end)
end

--
-- Players
--
-- A player is an object with somebody on the other end of it: it is in the
-- same table as the entities, so everything that looks for objects finds it,
-- and what is different is that nothing here moves it -- where a player is
-- is what their client says.
--
-- simplified: no physics, no privileges, no chat and no HUD. The client
-- half is what would draw a HUD or open a formspec, and the HUD calls here
-- keep what they are told so that a mod reading them back gets what it set.
-- Damage is what a mod does with set_hp; nothing else takes hit points off
-- a player, because nothing else knows where the player has walked.

local players = {}      -- name -> the object's id

-- Everything an object has, and the rest below
local PlayerRef = setmetatable({}, {__index = ObjectRef})
PlayerRef.__index = PlayerRef
local PlayerRef_proto = newproxy(true)
getmetatable(PlayerRef_proto).__index = PlayerRef
getmetatable(PlayerRef_proto).__metatable = PlayerRef

-- Every object by the name that outlives a restart; a player's is their
-- name, which is what Luanti uses and what a mod stores
core.objects_by_guid = {}

-- False once the player has left: Luanti's answers on the RemotePlayer
-- behind the ref, which is gone by then, and a mod's timer that outlives
-- the player asks this first
function PlayerRef:is_player()
	return state_of(self) ~= nil
end

-- A player's client moves the player and says so; when the server moves one
-- instead -- a spawn, a teleport, a mod putting them somewhere -- the client
-- has to be told, or it walks on from where it thought it was.
local function tell_the_client(o)
	if o and o.player_name and __send_player_pos then
		-- And which object is theirs, because a client that cannot tell its
		-- own from the rest points at itself: it is standing inside it; and
		-- which way they are facing, which a world they have been in before
		-- saved along with where they stood
		__send_player_pos(o.player_name, o.pos.x, o.pos.y, o.pos.z, o.id,
				o.look.h, o.look.v)
		-- Till the client has it, its reports are from before
		o.told = {x = o.pos.x, y = o.pos.y, z = o.pos.z, at = core.get_us_time()}
	end
end

function PlayerRef:set_pos(pos)
	ObjectRef.set_pos(self, pos)
	tell_the_client(state_of(self))
end

function PlayerRef:move_to(pos, continuous)
	self:set_pos(pos)
end

function PlayerRef:get_player_name()
	local o = state_of(self)
	return o and o.player_name or ""
end

function PlayerRef:get_guid()
	return self:get_player_name()
end

function PlayerRef:get_meta()
	local o = state_of(self)
	return o and o.meta or nil
end

function PlayerRef:get_inventory()
	local o = state_of(self)
	return o and o.inventory or nil
end

function PlayerRef:add_pos(v)
	local o = state_of(self)
	if o then
		o.pos = {x = o.pos.x + (v.x or 0), y = o.pos.y + (v.y or 0),
				z = o.pos.z + (v.z or 0)}
		tell_the_client(o)
	end
end

-- Luanti builds the reason out of what the caller passed and says where the
-- change came from, and the registered callbacks see the difference before
-- the hit points move -- the difference itself, which is not clamped to the
-- range the hit points end up in.
--
-- The callbacks are not run in a pcall here, which is the one place in this
-- module where that is so: whoever called set_hp() is a mod, the callback
-- is a mod's, and an error between two of them belongs to the caller rather
-- than to the module.
function PlayerRef:set_hp(hp, reason)
	local o = state_of(self)
	if not o then
		return
	end
	local t = {}
	for k, v in pairs(type(reason) == "table" and reason or {}) do
		t[k] = v
	end
	if type(reason) == "string" then
		t.type = reason
	end
	t.type = t.type or "set_hp"
	t.from = t.from or "mod"
	local hp_max = o.props.hp_max or 20
	local change = math.floor(tonumber(hp) or 0) - o.hp
	-- Kept inside a 32-bit integer, so that asking for the smallest number
	-- there is does not become one smaller still
	change = math.max(-2147483648, math.min(2147483647, change))
	-- Damage does nothing to somebody who is already dead
	if o.hp <= 0 and change < 0 then
		return
	end
	if core.registered_on_player_hpchange then
		local modified = core.registered_on_player_hpchange(self, change, t)
		if type(modified) == "number" then
			change = modified
		end
	end
	local was = o.hp
	o.hp = math.max(0, math.min(was + change, hp_max))
	send_stats(o)
	player_event(o, "health_changed")
	if o.hp == 0 and was > 0 then
		for _, cb in ipairs(core.registered_on_dieplayers or {}) do
			cb(self, t)
		end
	end
end

-- Luanti's respawn (Server::RespawnPlayer): full health and breath first,
-- the health through set_hp so the hpchange callbacks see it, then the
-- on_respawnplayer callbacks, all of them (RUN_CALLBACKS_MODE_OR, no short
-- circuit: VoxeLibre's mcl_spawn answers true, and the callbacks after it
-- put out a death's fire), and one that answers true has put the player
-- somewhere itself (a bed); otherwise the spawn point. The order
-- matters: VoxeLibre's health bar reads get_hp() in its respawn callback,
-- and with the health set after it the bar stayed at nought until the
-- next hit (the first driven run, 2026-09-19). The death screen's button
-- is what calls it, and a mod's /respawn.
function PlayerRef:respawn()
	local o = state_of(self)
	if not o or not o.player_name then
		return
	end
	self:set_hp(o.props.hp_max or 20, {type = "respawn"})
	o.breath = o.props.breath_max or 10
	local placed = false
	for _, cb in ipairs(core.registered_on_respawnplayers or {}) do
		local ok, moved = pcall(cb, self)
		if not ok then
			core.log("error", "on_respawnplayer: " .. tostring(moved))
		elseif moved then
			placed = true
		end
	end
	if not placed then
		local spawn = find_spawn_pos()
		o.pos = {x = spawn.x, y = spawn.y, z = spawn.z}
		o.vel = {x = 0, y = 0, z = 0}
		tell_the_client(o)
	end
	send_stats(o)
end

function PlayerRef:get_hp()
	local o = state_of(self)
	return o and o.hp or 0
end

-- Luanti's two angles, and the directions they mean (lua_api.md,
-- get_look_vertical and get_look_horizontal): the horizontal one is
-- counter-clockwise from +Z, so it turns towards -X; the vertical one is
-- **positive downwards**, -pi/2 being straight up and pi/2 straight down.
-- This is the same vector Luanti's own l_get_look_dir() builds out of
-- (rotation.Y + 90) and -pitch.
function PlayerRef:get_look_dir()
	local o = state_of(self)
	if not o then
		return vector.new(0, 0, 1)
	end
	local h, v = o.look.h, o.look.v
	return vector.new(-math.sin(h) * math.cos(v), -math.sin(v),
			math.cos(h) * math.cos(v))
end

function PlayerRef:get_look_horizontal()
	local o = state_of(self)
	return o and o.look.h or 0
end

function PlayerRef:set_look_horizontal(h)
	local o = state_of(self)
	if o then
		o.look.h = h
		-- As Luanti, which sends it as it sends a set_pos
		tell_the_client(o)
	end
end

function PlayerRef:get_look_vertical()
	local o = state_of(self)
	return o and o.look.v or 0
end

function PlayerRef:set_look_vertical(v)
	local o = state_of(self)
	if o then
		o.look.v = v
		-- As Luanti, which sends it as it sends a set_pos
		tell_the_client(o)
	end
end

-- And the deprecated pair, which Luanti keeps and calls broken because each
-- is the other way round from the one above it: its yaw is counter-clockwise
-- from +X rather than +Z, and its pitch is positive upwards. A mod still
-- calling them gets what Luanti gives them.
function PlayerRef:get_look_yaw()
	return self:get_look_horizontal() + math.pi / 2
end

function PlayerRef:set_look_yaw(y)
	self:set_look_horizontal(y - math.pi / 2)
end

function PlayerRef:get_look_pitch()
	return -self:get_look_vertical()
end

function PlayerRef:set_look_pitch(v)
	self:set_look_vertical(-v)
end

function PlayerRef:get_wield_index()
	local o = state_of(self)
	return o and o.wield_index or 1
end

function PlayerRef:set_wield_index(i)
	local o = state_of(self)
	if o then
		o.wield_index = math.max(1, math.floor(tonumber(i) or 1))
	end
end

function PlayerRef:get_wield_list()
	return "main"
end

function PlayerRef:get_wielded_item()
	local o = state_of(self)
	if not o then
		return ItemStack()
	end
	-- The selected slot, empty or not: Luanti's Lua get_wielded_item asks
	-- for the selected item only (l_object.cpp), and the "hand" list is
	-- the C++ dig's and punch's business -- see PlayerRef:get_hand_item;
	-- the dig episode's census read the hand here where official read
	-- nothing (2026-09-22)
	return o.inventory:get_stack("main", o.wield_index)
end

-- What the punch and the dig hit with: the selected item, or the "hand"
-- list's first when the slot is empty and a game keeps one
-- (Player::getWieldedItem with a hand; VoxeLibre's mcl_meshhand puts its
-- hand there with its own tool_capabilities and range)
function PlayerRef:get_hand_item()
	local o = state_of(self)
	if not o then
		return ItemStack()
	end
	local selected = o.inventory:get_stack("main", o.wield_index)
	if selected:get_name() == "" and o.inventory:get_size("hand") > 0 then
		local hand = o.inventory:get_stack("hand", 1)
		if not hand:is_empty() then
			return hand
		end
	end
	return selected
end

function PlayerRef:set_wielded_item(item)
	local o = state_of(self)
	if not o then
		return false
	end
	o.inventory:set_stack("main", o.wield_index, ItemStack(item))
	return true
end

-- The hotbar is as long as the list behind it, which is what Luanti clamps
-- it to and what a mod setting it expects to read back
function PlayerRef:hud_set_hotbar_itemcount(n)
	local o = state_of(self)
	if not o then
		return false
	end
	n = math.floor(tonumber(n) or 0)
	if n < 1 then
		return false
	end
	o.hotbar = math.min(n, o.inventory:get_size("main"))
	send_hotbar(o)
	return true
end

function PlayerRef:hud_get_hotbar_itemcount()
	local o = state_of(self)
	return o and o.hotbar or 0
end

function PlayerRef:get_breath()
	local o = state_of(self)
	return o and o.breath or 0
end

function PlayerRef:set_breath(b)
	local o = state_of(self)
	if o then
		o.breath = math.max(0, math.floor(tonumber(b) or 0))
		send_stats(o)
		player_event(o, "breath_changed")
	end
end

-- What the client's movement is multiplied by. Luanti's own defaults are
-- ones, and a game that wants speed boots, low gravity or a jump curse
-- changes them; the client cannot work any of it out for itself, so what is
-- sent is the whole table each time rather than the change.
--
-- Every field Luanti's own override has (lua_api.md, set_physics_override):
-- the three multipliers, the two sneak flags, new_move, and a multiplier
-- per movement constant. A field the game never set goes as 1.
local PHYSICS_FIELDS = {"speed", "jump", "gravity", "sneak", "sneak_glitch",
		"new_move", "speed_climb", "speed_crouch", "speed_fast", "speed_walk",
		"liquid_fluidity", "liquid_fluidity_smooth", "liquid_sink",
		"acceleration_default", "acceleration_air", "acceleration_fast"}

local MOVEMENT_FIELDS = {"acceleration_default", "acceleration_air",
		"acceleration_fast", "speed_walk", "speed_crouch", "speed_fast",
		"speed_climb", "speed_jump", "liquid_fluidity",
		"liquid_fluidity_smooth", "liquid_sink", "gravity"}

send_physics = function(o)
	if not (o and o.player_name and __luanti_send_physics) then
		return
	end
	local flat = {}
	for _, k in ipairs(PHYSICS_FIELDS) do
		local v = o.physics[k]
		if type(v) == "boolean" then
			v = v and 1 or 0
		end
		flat[#flat + 1] = k
		flat[#flat + 1] = tostring(tonumber(v) or 1)
	end
	-- And the constants themselves, the game's movement_* settings (its
	-- minetest.conf is in the defaults), which is what TOCLIENT_MOVEMENT
	-- carries: VoxeLibre's liquid_sink is 23 against the client's 10
	-- ([WATER_PARITY]). Only the ones set; the client keeps its own for
	-- the rest.
	for _, k in ipairs(MOVEMENT_FIELDS) do
		local v = core.settings and core.settings:get("movement_" .. k)
		if tonumber(v) then
			flat[#flat + 1] = "movement_" .. k
			flat[#flat + 1] = tostring(tonumber(v))
		end
	end
	flat[#flat + 1] = "zoom_fov"
	flat[#flat + 1] = tostring(tonumber(o.props and o.props.zoom_fov) or 0)
	__luanti_send_physics(o.player_name, flat)
end

-- The player's own model's frames -- idle, walk, dig, walk while digging
-- -- and their speed, kept and answered as Luanti's are (lua_api.md,
-- set_local_animation; the defaults are Luanti's). simplified: kept, not
-- sent -- nothing here animates a model yet ([OBJECT_ANIM]); when the
-- client draws the player's own model in third person animated, this is
-- what it reads, the way set_physics_override's table reaches it.
local function v2(t, x, y)
	if type(t) == "table" then
		return {x = tonumber(t.x) or x, y = tonumber(t.y) or y}
	end
	return {x = x, y = y}
end
-- **Said once a session** ([DRAW_SETTERS]): a mod that calls a setter
-- this tree keeps but does not draw gets no warning that nothing
-- happened, which the second feature sweep called the worst shape a gap
-- can have. The value is still kept and answered, so a mod that reads it
-- back sees what it set.
local said_not_drawn = {}
local function not_drawn(what, why)
	if said_not_drawn[what] then
		return
	end
	said_not_drawn[what] = true
	core.log("warning", what .. ": kept and answered, not drawn -- " .. why)
end

function PlayerRef:set_local_animation(idle, walk, dig, walk_while_dig, frame_speed)
	local o = state_of(self)
	if not o then
		return
	end
	not_drawn("set_local_animation",
			"nothing here animates a player's own model yet " ..
			"([OBJECT_ANIM]); the frames are read back by get_local_" ..
			"animation and will be what the model plays when one is drawn")
	o.local_animation = {
		idle = v2(idle, 1, 1), walk = v2(walk, 1, 1), dig = v2(dig, 1, 1),
		walk_while_dig = v2(walk_while_dig, 1, 1),
		frame_speed = tonumber(frame_speed) or 30,
	}
end
function PlayerRef:get_local_animation()
	local o = state_of(self)
	local a = o and o.local_animation or {idle = {x = 1, y = 1},
			walk = {x = 1, y = 1}, dig = {x = 1, y = 1},
			walk_while_dig = {x = 1, y = 1}, frame_speed = 30}
	return {x = a.idle.x, y = a.idle.y}, {x = a.walk.x, y = a.walk.y},
			{x = a.dig.x, y = a.dig.y},
			{x = a.walk_while_dig.x, y = a.walk_while_dig.y}, a.frame_speed
end

function PlayerRef:get_physics_override()
	local o = state_of(self)
	return o and table.copy(o.physics) or nil
end

function PlayerRef:set_physics_override(t)
	local o = state_of(self)
	if o and type(t) == "table" then
		for k, v in pairs(t) do
			o.physics[k] = v
		end
		send_physics(o)
	end
end

-- Luanti's own bit order for the same thing; PlayerControl::getKeysPressed
-- in src/player.cpp
local CONTROL_BITS = {"up", "down", "left", "right", "jump", "aux1",
		"sneak", "dig", "place", "zoom"}

-- What the client says it is holding, unpacked into the table a mod reads.
-- LMB and RMB are Luanti's older names for dig and place and follow them.
local function set_control_bits(o, bits)
	bits = math.floor(tonumber(bits) or 0)
	local c = o.control
	for i = 1, #CONTROL_BITS do
		c[CONTROL_BITS[i]] = (bits % 2 ^ i) >= 2 ^ (i - 1)
	end
	c.LMB = c.dig
	c.RMB = c.place
end

do
	local o = {control = {}}
	set_control_bits(o, 0)
	assert(o.control.up == false and o.control.zoom == false,
			"control bits: nothing held is nothing set")
	-- forward and sneak, which is bits 0 and 6
	set_control_bits(o, 1 + 64)
	assert(o.control.up and o.control.sneak and not o.control.jump,
			"control bits: the bits pick the right keys")
	-- Every one of them, which is what says the top bit is not lost
	set_control_bits(o, 2 ^ #CONTROL_BITS - 1)
	for _, name in ipairs(CONTROL_BITS) do
		assert(o.control[name], "control bits: " .. name .. " went missing")
	end
	assert(o.control.LMB and o.control.RMB,
			"control bits: LMB and RMB follow dig and place")
end

function PlayerRef:get_player_control()
	local o = state_of(self)
	local c = o and o.control
	if not c then
		return {up = false, down = false, left = false, right = false,
				jump = false, aux1 = false, sneak = false, dig = false,
				place = false, LMB = false, RMB = false, zoom = false}
	end
	-- A copy: what a mod does to the table it is given is its own business
	local out = {}
	for k, v in pairs(c) do
		out[k] = v
	end
	return out
end

function PlayerRef:get_player_control_bits()
	local o = state_of(self)
	local c = o and o.control
	if not c then
		return 0
	end
	local bits = 0
	for i = 1, #CONTROL_BITS do
		if c[CONTROL_BITS[i]] then
			bits = bits + 2 ^ (i - 1)
		end
	end
	return bits
end

function PlayerRef:get_player_velocity()
	return self:get_velocity()
end

function PlayerRef:add_player_velocity(v)
	self:add_velocity(v)
end

function PlayerRef:get_inventory_formspec()
	local o = state_of(self)
	return o and o.inventory_formspec or ""
end

function PlayerRef:set_inventory_formspec(spec)
	local o = state_of(self)
	if o then
		o.inventory_formspec = tostring(spec or "")
	end
end

function PlayerRef:get_formspec_prepend()
	local o = state_of(self)
	return o and o.formspec_prepend or ""
end

function PlayerRef:set_formspec_prepend(spec)
	local o = state_of(self)
	if o then
		o.formspec_prepend = tostring(spec or "")
	end
end

-- What is still the client's alone, and kept nowhere: these answer with
-- nothing rather than being missing and taking a mod down on the line that
-- sets one
for _, name in ipairs({
	"set_minimap_modes", "send_mapblock", "set_nametag_color",
}) do
	PlayerRef[name] = function() end
end

-- What the game says about how this player's world is drawn: kept and
-- merged the way Luanti merges it (a call sets the fields it names and
-- leaves the rest), answered back by get_lighting(), and sent down the
-- HUD line as `lighting <shadows.intensity> <saturation>` -- the two the
-- launcher draws today; the exposure block is [PBR_LEVEL]'s and the
-- volumetric light nobody's yet. See [DRAW_SETTERS].
local LIGHTING_DEFAULT = {shadows = {intensity = 0}, saturation = 1,
		exposure = {luminance_min = -3, luminance_max = -3,
		exposure_correction = 0, speed_dark_bright = 1000,
		speed_bright_dark = 1000, center_weight_power = 1},
		volumetric_light = {strength = 0}}

local function merge_into(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" and type(dst[k]) == "table" then
			merge_into(dst[k], v)
		else
			dst[k] = v
		end
	end
end

function PlayerRef:set_lighting(t)
	local o = state_of(self)
	if not o or type(t) ~= "table" then
		return
	end
	if not o.lighting then
		o.lighting = {}
		merge_into(o.lighting, LIGHTING_DEFAULT)
	end
	merge_into(o.lighting, t)
	-- All of it reaches the client, flat, in the order of
	-- luanti_client/res/sky_model.lua's LIGHTING, which says what it does
	-- not draw ([VANILLA_WEATHER] 6)
	local l = o.lighting
	local e, b = l.exposure or {}, l.bloom or {}
	local tint = l.shadows.tint
	if type(tint) == "string" then
		tint = core.colorspec_to_table(tint)
	end
	tint = type(tint) == "table" and tint or {}
	local out = {"lighting"}
	for _, v in ipairs({{l.shadows.intensity, 0}, {l.saturation, 1},
			{e.luminance_min, -3}, {e.luminance_max, -3},
			{e.exposure_correction, 0}, {e.speed_dark_bright, 1000},
			{e.speed_bright_dark, 1000}, {e.center_weight_power, 1},
			{(l.volumetric_light or {}).strength, 0},
			{b.intensity, 0.05}, {b.strength_factor, 1}, {b.radius, 1},
			{tint.r, 0}, {tint.g, 0}, {tint.b, 0}}) do
		out[#out + 1] = tostring(tonumber(v[1]) or v[2])
	end
	send_hud(o, out)
end

function PlayerRef:get_lighting()
	local o = state_of(self)
	local out = {}
	merge_into(out, LIGHTING_DEFAULT)
	if o and o.lighting then
		merge_into(out, o.lighting)
	end
	return out
end

-- What the client draws its hotbar out of: how many slots, the picture
-- behind them and the one that marks the slot in hand. Luanti's client owns
-- the hotbar and a game only says these three things about it, which is how
-- it is here too -- the launcher draws it, and this is what it is told.
function PlayerRef:hud_set_hotbar_image(name)
	local o = state_of(self)
	if o then
		o.hotbar_image = tostring(name or "")
		send_hotbar(o)
	end
end

function PlayerRef:hud_get_hotbar_image()
	local o = state_of(self)
	return o and o.hotbar_image or ""
end

function PlayerRef:hud_set_hotbar_selected_image(name)
	local o = state_of(self)
	if o then
		o.hotbar_selected_image = tostring(name or "")
		send_hotbar(o)
	end
end

function PlayerRef:hud_get_hotbar_selected_image()
	local o = state_of(self)
	return o and o.hotbar_selected_image or ""
end

-- Luanti's own name for the same thing, which some mods use
PlayerRef.hud_set_hotbar_image_selected =
		PlayerRef.hud_set_hotbar_selected_image

local MODES_FORM, send_camera, send_day_night, send_modes, send_sky, send_whole_hud
MODES_FORM, send_camera, send_day_night, send_modes, send_sky, send_whole_hud,
		send_hud, send_hotbar =
		assert(loadfile(__luanti_module_path .. "/lua/sky_hud.lua"))(
		PlayerRef, out_vec, player_event, state_of, vec)

--
-- A player in the save
--
-- What Luanti's player database holds -- where a player is, which way they
-- are looking, their health, their breath, what a mod wrote on them and what
-- is in their inventory -- kept by name, so that it outlives both the
-- client's connection and the run. Step 5d of
-- doc/plan/world_persistence_plan.md.
--
-- simplified: written when a player leaves and at shutdown, not on a timer,
-- so a server that is killed loses what changed since. The clock beside it in
-- the save is written the same way and names the same upgrade path.

local saved_players = {}

local function snapshot_player(o)
	local lists = {}
	for list_name, stacks in pairs(o.inventory:get_lists()) do
		local as_strings = {}
		for i, stack in ipairs(stacks) do
			as_strings[i] = stack:to_string()
		end
		lists[list_name] = as_strings
	end
	local fields = {}
	for k, v in pairs(o.meta.fields) do
		fields[k] = v
	end
	return {
		-- Always where they are: the client is the player and a client is
		-- always somewhere, so this is the position their client last
		-- reported. Where a player who has never been here starts is the
		-- spawn search's business and not this one's.
		pos = {x = o.pos.x, y = o.pos.y, z = o.pos.z},
		look = {h = o.look.h, v = o.look.v},
		hp = o.hp,
		breath = o.breath,
		fields = fields,
		inventory = lists,
	}
end

-- The other direction, onto a player who has just been made. The inventory
-- lists are item strings and the fields are strings, which is what the node
-- metadata in the save is written as too.
local function restore_player(o, saved)
	if type(saved) ~= "table" then
		return
	end
	if type(saved.pos) == "table" then
		o.pos = {x = tonumber(saved.pos.x) or 0,
				y = tonumber(saved.pos.y) or 0,
				z = tonumber(saved.pos.z) or 0}
	end
	if type(saved.look) == "table" then
		o.look = {h = tonumber(saved.look.h) or 0,
				v = tonumber(saved.look.v) or 0}
	end
	o.hp = tonumber(saved.hp) or o.hp
	o.breath = tonumber(saved.breath) or o.breath
	-- Not the held slot: a join starts at 1 as Luanti's does, and the
	-- client says its own at once; a restored one was held until the
	-- first change, the light of a torch with it ([WIELD_SLOT_JOIN])
	for k, v in pairs(saved.fields or {}) do
		o.meta.fields[k] = v
	end
	for list_name, stacks in pairs(saved.inventory or {}) do
		o.inventory:set_size(list_name, #stacks)
		for i, str in ipairs(stacks) do
			o.inventory:set_stack(list_name, i, ItemStack(str))
		end
	end
end

-- The module calls these at shutdown and once the mods have loaded, the way
-- it does the node metadata: what an inventory holds is item strings, and an
-- item string means nothing until the mod that registered it is there.
--
-- The auth entries come along, because a privilege a mod granted is as much
-- a part of a player as their health is, and bootstrap.lua keeps them in a
-- table of its own.
function core.__save_players()
	local out = {}
	local n = 0
	for name, id in pairs(players) do
		local o = objects[id]
		if o then
			saved_players[name] = snapshot_player(o)
		end
	end
	for name, saved in pairs(saved_players) do
		out[name] = saved
		n = n + 1
	end
	return core.serialize({v = 1, players = out, auth = core.__auth_entries}), n
end

-- The number read, or nil for a row this cannot read (a newer Buildat's,
-- or broken), which luanti.cpp then never writes over
function core.__load_players(data)
	local t = core.deserialize(data)
	-- 0.6's had no v and is 1's shape
	if type(t) ~= "table" or (t.v or 1) ~= 1 then
		return nil
	end
	local n = 0
	for name, saved in pairs(t.players or {}) do
		saved_players[name] = saved
		n = n + 1
	end
	for name, entry in pairs(t.auth or {}) do
		core.__auth_entries[name] = entry
	end
	return n
end

--
-- Formspecs
--
-- The window a mod puts on a player's screen: a string of elements the client
-- draws and sends back what was pressed in. Nothing here knows what one looks
-- like -- builtin/luanti/client_lua does.

-- Which node a player's open form is about, when it is about one. Luanti
-- calls it the form's context, and "current_name" in a formspec means it;
-- the fields of such a form go to the node rather than to the global
-- callbacks, and so do its inventory lists.
local form_nodes = {}
-- And which detached inventories its lists name, because those belong to
-- nobody and the client has to be sent them the way a node's are. Read out
-- of the spec: a list[] naming one is the only way a form can show one.
local form_detached = {}
-- The name of the form last shown to each player, by core.show_formspec:
-- fields under any other name are dropped, as Luanti's server drops them
-- (handleCommand_InventoryFields, m_formspec_state_data). "" -- the
-- player's own inventory, a node's form -- always passes. A mod's form
-- for admins was answerable by anyone who knew its name
-- ([SECURITY_RUN_1]).
local shown_forms = {}

local function detached_in_spec(spec)
	local out = {}
	for name in string.gmatch(tostring(spec or ""), "detached:([%w_%-%.:]+)") do
		out[name] = true
	end
	return out
end

local function pos_string(pos)
	return math.floor(pos.x) .. "," .. math.floor(pos.y) .. "," ..
			math.floor(pos.z)
end

-- The player's formspec prepend in front of a form, unless the form says
-- no_prepend[]: Luanti's client does that to every form it shows, and
-- VoxeLibre's grey panel is in its prepend ([VL_INV_PARITY]). Done here
-- because this client is sent the forms and not the prepend.
local function prepended(playername, spec)
	local id = players[playername]
	local p = id and objects[id] and objects[id].formspec_prepend or ""
	if spec == "" or p == "" or spec:find("no_prepend[", 1, true) then
		return spec
	end
	-- The marker says where the prepend ends: Luanti reads a prepend in
	-- legacy coordinates whatever the form's are
	return p .. "__prepend_end[]" .. spec
end

function core.show_formspec(playername, formname, formspec)
	if type(playername) ~= "string" or type(formspec) ~= "string" then
		return false
	end
	form_nodes[playername] = nil
	form_detached[playername] = detached_in_spec(formspec)
	shown_forms[playername] = formspec ~= "" and tostring(formname or "") or
			nil
	__show_formspec(playername, tostring(formname or ""),
			prepended(playername, formspec), "")
	return true
end

-- The form a node carries in its own metadata, which is what a chest is.
-- Luanti's client opens one itself; here the server does, because the node
-- metadata is the server's.
local function show_node_formspec(playername, pos, formspec)
	form_nodes[playername] = {x = math.floor(pos.x), y = math.floor(pos.y),
			z = math.floor(pos.z)}
	form_detached[playername] = detached_in_spec(formspec)
	__show_formspec(playername, "", prepended(playername, formspec),
			pos_string(form_nodes[playername]))
end

-- An empty formspec is "take it away", which is what Luanti's own protocol
-- says too
function core.close_formspec(playername, formname)
	if type(playername) ~= "string" then
		return false
	end
	form_nodes[playername] = nil
	form_detached[playername] = nil
	if formname == nil or formname == "" or
			shown_forms[playername] == formname then
		shown_forms[playername] = nil
	end
	__show_formspec(playername, tostring(formname or ""), "", "")
	return true
end

-- What comes back, as the module hands it over: the player it was, the form
-- it was, and the fields. Luanti runs these in reverse registration order and
-- stops at the first one that says it handled the form.
function core.__player_receive_fields(playername, formname, fields)
	local id = players[playername]
	local ref = id and core.object_refs[id]
	if not ref then
		return
	end
	-- The client's fly, fast and noclip as they are toggled, kept in the
	-- player's meta, which the world's save keeps ([FLY_STATE_SAVE]); no
	-- mod's form, so no mod's callback
	if formname == MODES_FORM then
		local on = {}
		for _, m in ipairs({"fly", "fast", "noclip"}) do
			if fields[m] == "1" then
				on[#on + 1] = m
			end
		end
		ref:get_meta():set_string("buildat:modes", table.concat(on, ","))
		return
	end
	-- A form a node carries goes to that node, which is where Luanti sends
	-- the fields of one too, and nowhere else
	local at = form_nodes[playername]
	if at then
		local def = core.registered_nodes[core.get_node(at).name]
		if def and def.on_receive_fields then
			local ok, err = pcall(def.on_receive_fields, at, formname, fields,
					ref)
			if not ok then
				core.log("error", "on_receive_fields: " .. tostring(err))
			end
		end
		if fields.quit then
			form_nodes[playername] = nil
		end
		return
	end
	if formname ~= "" then
		if shown_forms[playername] ~= formname then
			core.log("action", playername .. " submitted the form \"" ..
					tostring(formname):sub(1, 80) .. "\", which was not shown")
			return
		end
		if fields.quit then
			shown_forms[playername] = nil
		end
	end
	for _, cb in ipairs(core.registered_on_player_receive_fields or {}) do
		local ok, handled = pcall(cb, ref, formname, fields)
		if not ok then
			core.log("error", "on_player_receive_fields: " .. tostring(handled))
		elseif handled then
			return
		end
	end
end

-- What the other mouse button comes to: the wielded item's on_place,
-- core.item_place() (the vendored builtin's own) by default -- so the
-- pointed node's on_rightclick wins if it has one and is not overridden,
-- and the player's wielded item is placed otherwise. Returns whether
-- anything happened.
--
-- simplified: no sneaking, so a node with an on_rightclick cannot be built
-- against. Luanti's client sends whether the player was holding sneak, and
-- this would be that flag.
-- When each player last punched anything, because what a punch is worth is
-- the fraction of the tool's full_punch_interval that has passed since
local last_punch = {}

-- What a click on an object comes to. The wielded item's tool capabilities
-- are what does the damage, the entity's own on_punch runs first and can say
-- it dealt with it, and the tool wears by what it did -- which is Luanti's
-- own order in LuaEntitySAO::punch().
function core.__punch_object(playername, id)
	local pid = players[playername]
	local puncher = pid and core.object_refs[pid] or nil
	local ref = core.object_refs[tonumber(id) or -1]
	if ref == nil or puncher == nil then
		return false
	end
	-- Anything, from anywhere, was a punch: an object id is all the
	-- client sends ([SECURITY_RUN_1])
	local at = ref:get_pos()
	if not at or not core.__may_interact(puncher, at) then
		return false
	end
	local wielded = puncher.get_hand_item and puncher:get_hand_item() or
			puncher:get_wielded_item()
	local caps = wielded:get_tool_capabilities()
	local now = core.get_us_time() / 1000000
	-- A first punch is worth a whole interval, which is what Luanti's own
	-- "a long time ago" is
	local since = last_punch[playername] and (now - last_punch[playername]) or
			1000000
	last_punch[playername] = now
	local hit = core.get_hit_params(ref:get_armor_groups() or {}, caps, since,
			wielded:get_wear())
	ref:punch(puncher, since, caps, puncher:get_look_dir())
	if hit.wear > 0 then
		wielded:add_wear(hit.wear)
		puncher:set_wielded_item(wielded)
	end
	return true
end

-- The two nodes a place touches go back to the clients whatever came of
-- it, so a client that predicted the placement ([PREDICTION]) is put right
-- when the server refused it: written unchanged, the chunks are committed
-- and sent again, which is what Luanti's server does after a placement
-- of an item with a prediction
function core.__use_node(playername, under, above, sneak)
	local r = core.__use_node_inner(playername, under, above, sneak)
	local n = core.get_node(above)
	if n.name ~= "ignore" then
		core.swap_node(above, n)
	end
	n = core.get_node(under)
	if n.name ~= "ignore" then
		core.swap_node(under, n)
	end
	return r
end

function core.__use_node_inner(playername, under, above, sneak)
	local id = players[playername]
	local ref = id and core.object_refs[id]
	if not ref then
		return false
	end
	-- The node clicked, within reach and with interact (__use_node puts
	-- the client right either way)
	if not core.__may_interact(ref, under) then
		return false
	end
	-- What the client was holding when it clicked. Luanti's own
	-- item_place() reads it: a node with an on_rightclick is used when it
	-- is not held and built against when it is, which is the only way to
	-- put a node down on top of a chest.
	local o = objects[id]
	if o and o.control then
		o.control.sneak = sneak and true or false
	end
	-- A node with a formspec in its metadata opens it, which is what
	-- Luanti's own client does before it asks the server to place anything
	local meta = core.get_meta(under)
	local spec = meta and meta:get_string("formspec") or ""
	local pointed = {type = "node", under = under, above = above}
	local wielded = ref:get_wielded_item()
	if spec ~= "" and not sneak then
		show_node_formspec(playername, under, spec)
		-- "on_rightclick callbacks are called anyway" (Game::nodePlacement):
		-- the node's own handler runs beside the form, and nothing is placed
		local n = core.get_node(under)
		local d = n and core.registered_nodes[n.name]
		if d and d.on_rightclick then
			local left = d.on_rightclick(under, n, ref, wielded, pointed)
			if left ~= nil then
				ref:set_wielded_item(left)
			end
		end
		return true
	end
	-- Not into the player's own space: Luanti's client refuses a placement
	-- whose walkable node would collide with the player (Game::nodePlacement)
	-- and the server trusts it; this client sends every click and the
	-- refusal is here. The driver put a crafting table where its head was
	-- and stood inside it (2026-09-19). A node with an on_rightclick is
	-- used, not placed, unless sneaking, so those go through.
	local def = core.registered_nodes[wielded:get_name()]
	local under_node = core.get_node(under)
	local under_def = under_node and core.registered_nodes[under_node.name]
	if def and def.walkable ~= false and
			not (under_def and under_def.on_rightclick and not sneak) then
		-- Where the node lands, which is what nodePlacement tests: into
		-- under when that is buildable_to (grass, snow, a flower --
		-- item_place_node's rule), else into above ([POINTABLE])
		local at = (under_def and under_def.buildable_to) and under or above
		local p = ref:get_pos()
		local box = ref:get_properties().collisionbox or
				{-0.3, 0, -0.3, 0.3, 1.75, 0.3}
		if at.x + 0.5 > p.x + box[1] and at.x - 0.5 < p.x + box[4] and
				at.y + 0.5 > p.y + box[2] and at.y - 0.5 < p.y + box[5] and
				at.z + 0.5 > p.z + box[3] and at.z - 0.5 < p.z + box[6] then
			return false
		end
	end
	-- The wielded item's own on_place, as Luanti's server calls it
	-- (ScriptApiItem::item_OnPlace): a tool's or a bucket's does what
	-- core.item_place(), every item's default, does not ([VANILLA_ON_PLACE])
	local idef = core.registered_items[wielded:get_name()]
	local on_place = idef and idef.on_place or core.item_place
	local before = wielded:to_string()
	local left = on_place(wielded, ref, pointed)
	if left ~= nil then
		ref:set_wielded_item(left)
		return left:to_string() ~= before
	end
	-- An on_rightclick that returned nothing still did something
	return true
end

-- The place button with nothing pointed at: the wielded item's
-- on_secondary_use, which is where food starts being eaten ([TOUCH_EAT]).
-- Luanti's INTERACT_ACTIVATE, pointed_thing nothing; with interact, as all
-- of Luanti's interactions.
function core.__use_wielded(playername)
	local id = players[playername]
	local ref = id and core.object_refs[id]
	if not ref or not core.check_player_privs(playername, {interact = true}) then
		return false
	end
	local wielded = ref:get_wielded_item()
	local def = core.registered_items[wielded:get_name()]
	if not def or not def.on_secondary_use then
		return false
	end
	local left = def.on_secondary_use(wielded, ref, {type = "nothing"})
	if left ~= nil then
		ref:set_wielded_item(left)
	end
	return true
end

-- The game's own say on a move that touches the player's inventory:
-- core.register_allow_player_inventory_action and
-- core.register_on_player_inventory_action. A move inside it is "move"; a
-- stack leaving it is "take" and one arriving "put", which is how
-- src/inventorymanager.cpp splits it. The first allow that answers with
-- anything decides, and a number is a limit.
local function player_actions(ref, from_mine, to_mine, from_list, from_i,
		to_list, to_i, count, stack)
	if from_mine and to_mine then
		return {{"move", {from_list = from_list, to_list = to_list,
				from_index = from_i, to_index = to_i, count = count}}}
	end
	local t = {}
	if from_mine then
		t[#t + 1] = {"take", {listname = from_list, index = from_i,
				stack = ItemStack(stack)}}
	end
	if to_mine then
		t[#t + 1] = {"put", {listname = to_list, index = to_i,
				stack = ItemStack(stack)}}
	end
	return t
end

local function player_allowed(ref, actions, count)
	for _, act in ipairs(actions) do
		local ok, n = pcall(core.run_callbacks,
				core.registered_allow_player_inventory_actions, 5, ref,
				act[1], ref:get_inventory(), act[2])
		if not ok then
			core.log("error", "allow_player_inventory_action: " ..
					tostring(n))
			return 0
		end
		-- Below zero is Luanti's own "no limit"
		if type(n) == "number" and n >= 0 then
			count = math.min(count, n)
		end
	end
	return count
end

local function player_told(ref, actions)
	for _, act in ipairs(actions) do
		local ok, err = pcall(core.run_callbacks,
				core.registered_on_player_inventory_actions, 0, ref, act[1],
				ref:get_inventory(), act[2])
		if not ok then
			core.log("error", "on_player_inventory_action: " .. tostring(err))
		end
	end
end

-- What the drop key comes to: the item's own on_drop, which is Luanti's
-- core.item_drop unless the game says otherwise -- it spawns the item as an
-- object and throws it a little way in front of the player. count is how
-- many of the stack go, and nothing is one of them.
--
-- What could not be dropped stays in hand: add_item() failing is the world
-- being full rather than the player having thrown something away.
function core.__drop_wielded(playername, count)
	local id = players[playername]
	local ref = id and core.object_refs[id]
	-- Not without interact, as in Luanti ([SECURITY_RUN_4])
	if not ref or not core.check_player_privs(playername, {interact = true}) then
		return false
	end
	local inv = ref:get_inventory()
	local index = ref:get_wield_index()
	local stack = inv:get_stack("main", index)
	if stack:is_empty() then
		return false
	end
	count = tonumber(count) or 0
	if count <= 0 or count > stack:get_count() then
		count = stack:get_count()
	end
	local taking = ItemStack(stack)
	taking:set_count(count)
	count = player_allowed(ref, {{"take", {listname = "main", index = index,
			stack = taking}}}, count)
	if count <= 0 then
		return false
	end
	local dropped = stack:take_item(count)
	-- on_drop empties the stack it is given
	local taken = ItemStack(dropped)
	local def = core.registered_items[dropped:get_name()]
	local on_drop = def and def.on_drop or core.item_drop
	local left = on_drop(dropped, ref, ref:get_pos())
	-- Nothing at all came back from an on_drop of the game's own, which
	-- means it did not take the stack
	if left == nil then
		left = dropped
	end
	if not left:is_empty() then
		stack:add_item(left)
	end
	inv:set_stack("main", index, stack)
	if left:get_count() < count then
		taken:set_count(count - left:get_count())
		player_told(ref, {{"take", {listname = "main", index = index,
				stack = taken}}})
	end
	return true
end

--
-- An inventory action
--
-- What picking a stack up in one slot and putting it down in another comes
-- to. Luanti's own client sends the move when the stack is put down rather
-- than when it is picked up, so this is one message and the client's "held"
-- is only a drawing.
--
-- Three kinds of inventory can be either end of it: the player's own, a
-- node's, and one that belongs to nobody. The last two carry callbacks that
-- say how much of a move they allow and are told once it has happened.

-- The inventory a formspec location names, the node position if it is a
-- node's and the name if it is a detached one. "current_name" and "context"
-- are the node the open form is about.
local function inventory_at(ref, playername, location)
	if location == "current_player" or
			string.sub(location, 1, 7) == "player:" then
		return ref:get_inventory(), nil
	end
	local detached = string.match(location, "^detached:(.*)$")
	if detached then
		return core.get_inventory({type = "detached", name = detached}),
				nil, detached
	end
	local pos = nil
	if location == "current_name" or location == "context" then
		pos = form_nodes[playername]
	else
		local x, y, z = string.match(location,
				"^nodemeta:(-?%d+),(-?%d+),(-?%d+)$")
		if x then
			pos = {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
		end
	end
	if not pos then
		return nil, nil
	end
	local meta = core.get_meta(pos)
	return meta and meta:get_inventory() or nil, pos
end

-- Whether a player may move items in or out of an inventory that is not
-- their own, as Luanti's server decides it (handleCommand_InventoryAction):
-- not at all without interact; a node's only within reach -- from the eye,
-- the wielded tool's range (or the hand's, or 4) and 2.6 for the node's
-- extent, checkInteractDistance's numbers -- and a detached one only if it
-- is for everyone or for them. A client says which inventory, and any
-- position or name was taken as given ([SECURITY_RUN_1]).
local function may_reach(ref, playername, pos, detached)
	if not pos and not detached then
		return true
	end
	if not core.check_player_privs(playername, {interact = true}) then
		return false
	end
	if detached then
		local for_whom = core.__detached_players[detached]
		if for_whom and for_whom ~= playername then
			return false
		end
	end
	if pos then
		local p = ref:get_pos()
		local props = ref:get_properties() or {}
		local eye = {x = p.x, y = p.y + (props.eye_height or 1.625), z = p.z}
		local def = ref:get_wielded_item():get_definition()
		local range = def and def.range
		if type(range) ~= "number" or range < 0 then
			local hand = core.registered_items[""]
			range = hand and type(hand.range) == "number" and hand.range or 4
		end
		if vector.distance(eye, pos) > range + 2.6 then
			return false
		end
	end
	return true
end

-- The same rule for what a player does to the world: dig, punch, place
-- and punch an object all need interact and to be within reach, as in
-- Luanti's handleCommand_Interact. Called from bootstrap.lua's dig and
-- punch, and below.
function core.__may_interact(ref, pos)
	if not ref or not ref.is_player or not ref:is_player() then
		return true -- nobody: a mod's own dig_node()
	end
	return may_reach(ref, ref:get_player_name(), pos, nil)
end

local function same_pos(a, b)
	return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

-- How much of a move the nodes it touches allow. Luanti asks the node a
-- stack leaves and the node it goes to; a number is a limit and anything
-- below zero is none at all.
local function allowed_count(ref, playername, from_pos, from_list, from_i,
		to_pos, to_list, to_i, count, stack)
	local function ask(f, ...)
		if not f then
			return count
		end
		local ok, n = pcall(f, ...)
		if not ok then
			core.log("error", "allow_metadata_inventory: " .. tostring(n))
			return 0
		end
		if type(n) ~= "number" then
			return count
		end
		if n < 0 then
			-- Luanti's own "no limit"
			return count
		end
		return math.min(count, n)
	end
	if same_pos(from_pos, to_pos) then
		local def = core.registered_nodes[core.get_node(from_pos).name]
		return ask(def and def.allow_metadata_inventory_move, from_pos,
				from_list, from_i, to_list, to_i, count, ref)
	end
	if from_pos then
		local def = core.registered_nodes[core.get_node(from_pos).name]
		count = ask(def and def.allow_metadata_inventory_take, from_pos,
				from_list, from_i, stack, ref)
	end
	if to_pos and count > 0 then
		local def = core.registered_nodes[core.get_node(to_pos).name]
		count = ask(def and def.allow_metadata_inventory_put, to_pos, to_list,
				to_i, stack, ref)
	end
	return count
end

-- The same two questions for a detached inventory, whose callbacks belong to
-- whoever created it rather than to a node. Luanti asks allow_move when both
-- ends are the same inventory and allow_take/allow_put otherwise, and a
-- number below zero is none at all.
local function detached_allowed(ref, from_name, from_inv, from_list, from_i,
		to_name, to_inv, to_list, to_i, count, stack)
	local function ask(name, f, ...)
		if not f then
			return count
		end
		local ok, n = pcall(f, ...)
		if not ok then
			core.log("error", "detached inventory " .. name .. ": " ..
					tostring(n))
			return 0
		end
		if type(n) ~= "number" then
			return count
		end
		if n < 0 then
			return count
		end
		return math.min(count, n)
	end
	if from_name and from_name == to_name then
		local cb = core.detached_inventories[from_name] or {}
		return ask(from_name, cb.allow_move, from_inv, from_list, from_i,
				to_list, to_i, count, ref)
	end
	if from_name then
		local cb = core.detached_inventories[from_name] or {}
		count = ask(from_name, cb.allow_take, from_inv, from_list, from_i,
				stack, ref)
	end
	if to_name and count > 0 then
		local cb = core.detached_inventories[to_name] or {}
		count = ask(to_name, cb.allow_put, to_inv, to_list, to_i, stack, ref)
	end
	return count
end

local function detached_moved(ref, from_name, from_inv, from_list, from_i,
		to_name, to_inv, to_list, to_i, count, stack)
	local function tell(name, f, ...)
		if not f then
			return
		end
		local ok, err = pcall(f, ...)
		if not ok then
			core.log("error", "detached inventory " .. name .. ": " ..
					tostring(err))
		end
	end
	if from_name and from_name == to_name then
		local cb = core.detached_inventories[from_name] or {}
		tell(from_name, cb.on_move, from_inv, from_list, from_i, to_list,
				to_i, count, ref)
		return
	end
	if from_name then
		local cb = core.detached_inventories[from_name] or {}
		tell(from_name, cb.on_take, from_inv, from_list, from_i, stack, ref)
	end
	if to_name then
		local cb = core.detached_inventories[to_name] or {}
		tell(to_name, cb.on_put, to_inv, to_list, to_i, stack, ref)
	end
end

-- And what the nodes are told once it has happened
local function moved(ref, from_pos, from_list, from_i, to_pos, to_list, to_i,
		count, stack)
	local function tell(f, ...)
		if not f then
			return
		end
		local ok, err = pcall(f, ...)
		if not ok then
			core.log("error", "on_metadata_inventory: " .. tostring(err))
		end
	end
	if same_pos(from_pos, to_pos) then
		local def = core.registered_nodes[core.get_node(from_pos).name]
		tell(def and def.on_metadata_inventory_move, from_pos, from_list,
				from_i, to_list, to_i, count, ref)
		return
	end
	if from_pos then
		local def = core.registered_nodes[core.get_node(from_pos).name]
		tell(def and def.on_metadata_inventory_take, from_pos, from_list,
				from_i, stack, ref)
	end
	if to_pos then
		local def = core.registered_nodes[core.get_node(to_pos).name]
		tell(def and def.on_metadata_inventory_put, to_pos, to_list, to_i,
				stack, ref)
	end
end

-- Returns whether anything moved. count of zero is the whole stack.
local function move_stack(from_inv, from_list, from_i, to_inv, to_list, to_i,
		count)
	if from_inv == to_inv and from_list == to_list and from_i == to_i then
		return false
	end
	local src = from_inv:get_stack(from_list, from_i)
	if src:is_empty() then
		return false
	end
	if count <= 0 or count > src:get_count() then
		count = src:get_count()
	end
	local taken = src:take_item(count)
	local dst = to_inv:get_stack(to_list, to_i)
	local leftover = dst:add_item(taken)
	if leftover:get_count() == taken:get_count() and src:is_empty() and
			not dst:is_empty() then
		-- Nothing fitted and the whole source stack was moving: the two slots
		-- swap, which is what Luanti does with a stack put down on a
		-- different item
		from_inv:set_stack(from_list, from_i, dst)
		to_inv:set_stack(to_list, to_i, taken)
		return true
	end
	-- What did not fit goes back where it came from
	src:add_item(leftover)
	from_inv:set_stack(from_list, from_i, src)
	to_inv:set_stack(to_list, to_i, dst)
	return true
end

-- The round trip is the client's; what can be wrong here is the arithmetic,
-- which is checked at every start
function core.__check_inventory_move()
	local inv = core.__new_inventory({type = "player", name = "__check"})
	inv:set_size("main", 4)
	inv:set_stack("main", 1, ItemStack("__check_item 10"))
	inv:set_stack("main", 2, ItemStack("__check_other 1"))
	local function count_at(i)
		local s = inv:get_stack("main", i)
		return s:get_name(), s:get_count()
	end
	assert(move_stack(inv, "main", 1, inv, "main", 3, 4),
			"inventory move: half a stack onto an empty slot")
	local _, n = count_at(1)
	assert(n == 6, "inventory move: the source keeps the rest")
	local name3, n3 = count_at(3)
	assert(name3 == "__check_item" and n3 == 4,
			"inventory move: the destination gets what was taken")
	assert(move_stack(inv, "main", 3, inv, "main", 1, 0),
			"inventory move: onto the same item")
	local _, n1 = count_at(1)
	assert(n1 == 10 and inv:get_stack("main", 3):is_empty(),
			"inventory move: the same item merges")
	assert(move_stack(inv, "main", 1, inv, "main", 2, 0),
			"inventory move: onto a different item")
	local name1 = count_at(1)
	local name2, n2 = count_at(2)
	assert(name1 == "__check_other" and name2 == "__check_item" and n2 == 10,
			"inventory move: a different item swaps")
	assert(not move_stack(inv, "main", 2, inv, "main", 2, 0),
			"inventory move: onto itself is nothing")
	core.log("verbose", "check_inventory_move: the slots add up")
end

-- What the client sends when a stack is put down: the move, as strings.
-- The craft grid's answer, Luanti's own way (Server::... craftpreview):
-- after anything moves in or out of the player's craft list, the
-- craftpreview slot is what the grid would make, through the mods'
-- craft_predict; and a craft action takes it -- the grid's items one
-- each, the result into craftresult for the client to move from, the
-- on_craft callbacks run -- count times or until nothing fits. The
-- preview was never computed before 2026-09-19: the first driven run's
-- craft put a log in the grid and the preview stayed empty.
local function craft_input(inv)
	return {method = "normal", width = inv:get_width("craft"),
			items = inv:get_list("craft")}
end

local function update_craft_preview(ref)
	local inv = ref:get_inventory()
	if inv:get_size("craft") == 0 or inv:get_size("craftpreview") == 0 then
		return
	end
	local old = inv:get_list("craft")
	local out = core.get_craft_result(craft_input(inv))
	local item = core.craft_predict(out.item, ref, old, inv)
	inv:set_stack("craftpreview", 1, item)
end

local function do_craft(ref, count)
	local inv = ref:get_inventory()
	if inv:get_size("craft") == 0 or inv:get_size("craftresult") == 0 then
		return
	end
	for _ = 1, math.max(1, count) do
		local old = inv:get_list("craft")
		local out, left = core.get_craft_result(craft_input(inv))
		if out.item:is_empty() or not inv:room_for_item("craftresult", out.item) then
			break
		end
		local item = core.on_craft(out.item, ref, old, inv)
		inv:set_list("craft", left.items)
		inv:add_item("craftresult", item)
		-- simplified: a recipe's replacements (a bucket back from the
		-- milk) go to the main list rather than the grid's own slot
		for _, r in ipairs(out.replacements or {}) do
			inv:add_item("main", r)
		end
	end
	update_craft_preview(ref)
end

function core.__inventory_action(playername, a)
	local id = players[playername]
	local ref = id and core.object_refs[id]
	if not ref or type(a) ~= "table" then
		return
	end
	if a[1] == "craft" then
		if core.check_player_privs(playername, {interact = true}) then
			do_craft(ref, tonumber(a[2]) or 1)
		end
		return
	end
	if a[1] ~= "move" then
		return
	end
	local from_inv, from_pos, from_detached =
			inventory_at(ref, playername, a[2] or "")
	local to_inv, to_pos, to_detached =
			inventory_at(ref, playername, a[5] or "")
	if not from_inv or not to_inv then
		core.log("verbose", "inventory action: " .. tostring(a[2]) .. " -> " ..
				tostring(a[5]) .. " is not an inventory this player has")
		return
	end
	local from_list, from_i = a[3] or "", tonumber(a[4]) or 0
	local to_list, to_i = a[6] or "", tonumber(a[7]) or 0
	-- The grid's answer is taken by a craft action, never moved, and
	-- nothing is put into it or into craftresult (Luanti refuses the same)
	if from_list == "craftpreview" or to_list == "craftpreview" or
			to_list == "craftresult" then
		return
	end
	if not may_reach(ref, playername, from_pos, from_detached) or
			not may_reach(ref, playername, to_pos, to_detached) then
		core.log("action", playername .. " may not reach " ..
				tostring(a[2]) .. " -> " .. tostring(a[5]))
		return
	end
	local count = tonumber(a[8]) or 0
	local stack = from_inv:get_stack(from_list, from_i)
	if stack:is_empty() then
		return
	end
	if count <= 0 or count > stack:get_count() then
		count = stack:get_count()
	end
	if from_pos or to_pos or from_detached or to_detached then
		local moving = ItemStack(stack)
		moving:set_count(count)
		if from_pos or to_pos then
			count = allowed_count(ref, playername, from_pos, from_list,
					from_i, to_pos, to_list, to_i, count, moving)
		end
		if count > 0 and (from_detached or to_detached) then
			count = detached_allowed(ref, from_detached, from_inv, from_list,
					from_i, to_detached, to_inv, to_list, to_i, count, moving)
		end
		if count <= 0 then
			return
		end
	end
	local from_mine = not from_pos and not from_detached
	local to_mine = not to_pos and not to_detached
	if from_mine or to_mine then
		local moving = ItemStack(stack)
		moving:set_count(count)
		count = player_allowed(ref, player_actions(ref, from_mine, to_mine,
				from_list, from_i, to_list, to_i, count, moving), count)
		if count <= 0 then
			return
		end
	end
	if not move_stack(from_inv, from_list, from_i, to_inv, to_list, to_i,
			count) then
		return
	end
	if (from_inv == ref:get_inventory() and from_list == "craft") or
			(to_inv == ref:get_inventory() and to_list == "craft") then
		update_craft_preview(ref)
	end
	if from_pos or to_pos or from_detached or to_detached then
		local moved_stack = ItemStack(stack)
		moved_stack:set_count(count)
		if from_pos or to_pos then
			moved(ref, from_pos, from_list, from_i, to_pos, to_list, to_i,
					count, moved_stack)
		end
		if from_detached or to_detached then
			detached_moved(ref, from_detached, from_inv, from_list, from_i,
					to_detached, to_inv, to_list, to_i, count, moved_stack)
		end
	end
	if from_mine or to_mine then
		local moved_stack = ItemStack(stack)
		moved_stack:set_count(count)
		player_told(ref, player_actions(ref, from_mine, to_mine, from_list,
				from_i, to_list, to_i, count, moved_stack))
	end
end

-- The importer's way in: a player read out of a Luanti world's database.
-- What the save already knows about that name is kept, the way a mod's
-- storage is, so that importing the same world twice does not undo what has
-- happened since the first time. Returns whether the row was taken.
function core.__import_player(name, t)
	if type(name) ~= "string" or name == "" or type(t) ~= "table" then
		return false
	end
	if saved_players[name] or players[name] then
		return false
	end
	local fields = t.fields or {}
	-- A world whose players are files keeps their metadata as one JSON
	-- object rather than a row each, and the parser is here rather than in
	-- the importer. "null" is what Luanti writes for a player who has none.
	if type(t.extended_attributes) == "string" and
			t.extended_attributes ~= "" and t.extended_attributes ~= "null" then
		local decoded = core.parse_json(t.extended_attributes)
		if type(decoded) == "table" then
			for key, value in pairs(decoded) do
				fields[key] = tostring(value)
			end
		else
			core.log("warning", "__import_player(" .. name ..
					"): the extended attributes are not a JSON object")
		end
	end
	saved_players[name] = {
		pos = t.pos,
		look = t.look,
		hp = t.hp,
		breath = t.breath,
		wield_index = 1,
		fields = fields,
		inventory = t.inventory or {},
	}
	return true
end

-- The round trip, on a player made for it rather than on a live one: what
-- can be wrong here is a value that does not survive being written down, and
-- adding a real player would run every mod's join callback to find that out.
function core.__check_players()
	local made = function(fields)
		return {
			pos = {x = 0, y = 0, z = 0},
			look = {h = 0, v = 0},
			hp = 20,
			breath = 10,
			wield_index = 1,
			meta = core.__new_metadata(fields or {}),
			inventory = core.__new_inventory(
					{type = "player", name = "__check"}),
		}
	end
	local from = made({greeting = "hello"})
	from.pos = {x = 1, y = -2, z = 3}
	from.look = {h = 0.5, v = -0.25}
	from.hp = 7
	from.breath = 3
	from.wield_index = 4
	from.inventory:set_size("main", 2)
	from.inventory:set_stack("main", 1, ItemStack("__check_item 3"))
	local wrote = core.serialize(snapshot_player(from))
	local to = made()
	restore_player(to, core.deserialize(wrote))
	assert(to.pos.x == 1 and to.pos.y == -2 and to.pos.z == 3,
			"check_players: the position did not come back")
	assert(to.look.h == 0.5 and to.look.v == -0.25,
			"check_players: the look did not come back")
	assert(to.hp == 7 and to.breath == 3 and to.wield_index == 1,
			"check_players: hp or breath did not come back, or the slot did")
	assert(to.meta.fields.greeting == "hello",
			"check_players: the metadata did not come back")
	assert(to.inventory:get_stack("main", 1):to_string() == "__check_item 3",
			"check_players: the inventory did not come back")
	-- And the two angles mean what Luanti says they mean, which is the one
	-- thing about them that is easy to get backwards: the horizontal angle
	-- turns from +Z towards -X, and the vertical one is positive downwards.
	local looker = made()
	local check_id = "__check_look"
	objects[check_id] = looker
	local ref = new_ref(PlayerRef_proto, check_id)
	looker.look = {h = 0, v = 0}
	local d = ref:get_look_dir()
	assert(math.abs(d.z - 1) < 1e-6, "check_players: h=0 is not +Z")
	looker.look = {h = math.pi / 2, v = 0}
	d = ref:get_look_dir()
	assert(math.abs(d.x + 1) < 1e-6, "check_players: h=pi/2 is not -X")
	looker.look = {h = 0, v = math.pi / 2}
	d = ref:get_look_dir()
	assert(math.abs(d.y + 1) < 1e-6,
			"check_players: a positive vertical angle is not downwards")
	assert(math.abs(ref:get_look_pitch() + math.pi / 2) < 1e-6,
			"check_players: the deprecated pitch is not the other way round")
	objects[check_id] = nil
	core.log("verbose", "check_players: a player survived being written down")
end

-- Where a player who has never been here starts. Luanti's own findSpawnPos
-- takes the game's static_spawnpoint if it has one and otherwise stands the
-- player on the ground the mapgen says is there; this does the same with
-- the ground the map says is there. A world that has not generated around
-- the origin yet has no answer, and then the origin is what is left -- the
-- same place a player started before there was any terrain to stand on.
-- How many points the search looks at before it gives up, and how far out
-- it is allowed to walk. Luanti's numbers, except that its range limit is
-- the mapgen's own.
local SPAWN_TRIES = 4000
local SPAWN_RANGE_MAX = 31000
-- How many of those look at the map's whole column; see get_spawn_level()
local SPAWN_DEEP_TRIES = 8
-- The candidate points are the same sequence in every world, so that a
-- world always spawns a player in the same place: what makes one world's
-- spawn differ from another's is which candidates its mapgen accepts.
local SPAWN_SEQUENCE_SEED = 1337

-- 0...span, out of a generator whose own range is 0...32767
local function spawn_rand_to(pr, span)
	if span <= 32767 then
		return pr:next() % (span + 1)
	end
	return (pr:next() * 32768 + pr:next()) % (span + 1)
end

find_spawn_pos = function()
	local static = core.settings:get("static_spawnpoint")
	-- A string setting with nothing after its type in settingtypes.txt has
	-- "" for a default, not nothing, so an unset one is the empty string
	-- and not nil -- which is what Luanti's own findSpawnPos() tests with
	-- .empty(). minetest_game trips this.
	if static and static ~= "" then
		local x, y, z = string.match(static,
				"^%s*([%d.-]+)%s*,%s*([%d.-]+)%s*,%s*([%d.-]+)%s*$")
		if x then
			return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}, true
		end
		core.log("warning", "static_spawnpoint is not a position: " .. static)
	end
	-- Luanti's own search (Server::findSpawnPos): try a point, and if it is
	-- no good try another one a little further out, so that a spawn lands
	-- near the origin when the origin will do and walks outwards over an
	-- ocean when it will not. The points are random there and pseudo-random
	-- here, seeded from the world's own seed, so that a world always spawns
	-- a player in the same place.
	local pr = PseudoRandom(SPAWN_SEQUENCE_SEED)
	for i = 0, SPAWN_TRIES - 1 do
		local range = math.min(1 + i, SPAWN_RANGE_MAX)
		local x, z = 0, 0
		if i > 0 then
			x = -range + spawn_rand_to(pr, range * 2)
			z = -range + spawn_rand_to(pr, range * 2)
		end
		-- The first few points may have the map's whole column walked when
		-- the mapgen's answer does not match what is there; the rest are
		-- the mapgen's answer and a look at the nodes above it. Six hundred
		-- voxels of map read times four thousand points is half a minute of
		-- the module's thread, and a client waits for that thread.
		local level = core.get_spawn_level(x, z, i < SPAWN_DEEP_TRIES)
		if level ~= nil then
			return {x = x, y = level, z = z}, true
		end
	end
	-- Nowhere to stand yet: the world around the origin has not been
	-- generated deep enough to say. The player waits at the origin and is
	-- put down as soon as it can; see the placement in __step_objects().
	return {x = 0, y = 0, z = 0}, false
end

-- A player who arrives before the world around the spawn has been generated
-- cannot be put on the ground, because the map has no ground to answer with
-- yet. They start where a player with nowhere to be always started, and
-- this stands them on the surface as soon as there is one -- unless they
-- have moved in the meantime, in which case where they are is where they
-- want to be.
local unplaced = {}
local unplaced_timer = 0

local function place_the_unplaced(dtime)
	if next(unplaced) == nil then
		return
	end
	unplaced_timer = unplaced_timer + dtime
	if unplaced_timer < 1 then
		return
	end
	unplaced_timer = 0
	local spawn, known = find_spawn_pos()
	for name, was in pairs(unplaced) do
		local player = core.get_player_by_name(name)
		if player == nil then
			unplaced[name] = nil
		else
			local pos = player:get_pos()
			if math.abs(pos.x - was.x) > 0.5 or
					math.abs(pos.y - was.y) > 0.5 or
					math.abs(pos.z - was.z) > 0.5 then
				unplaced[name] = nil
			elseif known then
				player:set_pos(spawn)
				local o = state_of(player)
				if o then
					o.spawn_known = true
				end
				unplaced[name] = nil
				core.log("action", string.format(
						"Player %s was put on the ground at %.0f, %.0f, %.0f",
						name, spawn.x, spawn.y, spawn.z))
			end
		end
	end
end

-- Where a client that is still loading will be put ([JOIN_WHEN_LOADED]):
-- name -> {pos, look}, told to the client at once, while the player is not
-- in the world. __add_player() puts them there, without a second search for
-- the spawn.
local placing = {}

function core.__place_player(name)
	if players[name] or placing[name] then
		return
	end
	local saved = saved_players[name]
	local p = {look = {h = 0, v = 0}}
	if type(saved) == "table" and type(saved.pos) == "table" then
		p.pos = {x = tonumber(saved.pos.x) or 0,
				y = tonumber(saved.pos.y) or 0,
				z = tonumber(saved.pos.z) or 0}
		if type(saved.look) == "table" then
			p.look = {h = tonumber(saved.look.h) or 0,
					v = tonumber(saved.look.v) or 0}
		end
	elseif saved == nil then
		local pos, known = find_spawn_pos()
		-- Nowhere to stand yet: nothing said, as in __add_player()
		if not known then
			return
		end
		p.pos = pos
	else
		return
	end
	placing[name] = p
	if __send_player_pos then
		__send_player_pos(name, p.pos.x, p.pos.y, p.pos.z, 0, p.look.h, p.look.v)
	end
end

-- What the module calls when a client arrives and leaves. The name is the
-- client's, and it is what everything about a player is keyed by.
function core.__add_player(name)
	if players[name] then
		return
	end
	-- simplified: where the client was told it is, not where it says it
	-- went since: it stands still while it loads, and its word is not
	-- held down (hold_down()) until there is a player to hold
	local early = placing[name]
	placing[name] = nil
	local id = next_id
	next_id = id + 1
	local ref = new_ref(PlayerRef_proto, id)
	local o = {
		id = id,
		ref = ref,
		pos = {x = 0, y = 0, z = 0},
		vel = {x = 0, y = 0, z = 0},
		acc = {x = 0, y = 0, z = 0},
		rot = {x = 0, y = 0, z = 0},
		props = table.copy(DEFAULT_PROPERTIES),
		-- What PlayerSAO's constructor gives every player: a punch does
		-- damage through a group, and with none no player was ever hurt
		-- by one
		armor_groups = {fleshy = 100},
		hp = 20,
		player_name = name,
		meta = core.__new_metadata({}),
		inventory = core.__new_inventory({type = "player", name = name}),
		look = {h = 0, v = 0},
		wield_index = 1,
		hotbar = 8,
		breath = 10,
		-- Luanti's own defaults for what the client's movement is
		-- multiplied by; see send_physics() and PHYSICS_FIELDS
		physics = {speed = 1, jump = 1, gravity = 1, sneak = true,
				sneak_glitch = false, new_move = true},
		inventory_formspec = "",
		formspec_prepend = "",
		-- What the client says it is holding down, written by
		-- core.__set_player_pos() from the bits the client sends with its
		-- position. A mod reads it through get_player_control(), and
		-- Luanti's own item_place() reads sneak out of it to decide between
		-- a node's on_rightclick and putting something down against it.
		control = {up = false, down = false, left = false, right = false,
				jump = false, aux1 = false, sneak = false, dig = false,
				place = false, LMB = false, RMB = false, zoom = false},
	}
	-- What Luanti gives a player, from its own constants: a mod reads these
	-- off the properties, and so does the builtin's HUD -- the bubbles are
	-- drawn only while the breath is under its maximum, which is no maximum
	-- at all for an entity
	o.props.hp_max = core.PLAYER_MAX_HP_DEFAULT or 20
	o.props.breath_max = core.PLAYER_MAX_BREATH_DEFAULT or 10
	o.props.collisionbox = {-0.3, 0.0, -0.3, 0.3, 1.7, 0.3}
	objects[id] = o
	core.object_refs[id] = ref
	core.objects_by_guid[name] = ref
	players[name] = id
	-- The lists Luanti gives a player, so that a mod can put something in
	-- one without making it first
	o.inventory:set_size("main", 32)
	o.inventory:set_size("craft", 9)
	o.inventory:set_size("craftpreview", 1)
	-- And craftresult, which player.cpp adds beside them and which
	-- VoxeLibre's death drop reads without asking
	o.inventory:set_size("craftresult", 1)
	-- What the last run left, before on_joinplayer runs: a mod's join
	-- callback reads the player it is given, and in Luanti that player has
	-- come out of the database by then
	local new_here = saved_players[name] == nil
	if new_here and early then
		o.pos, o.spawn_known = early.pos, true
	elseif new_here then
		o.pos, o.spawn_known = find_spawn_pos()
	end
	restore_player(o, saved_players[name])
	-- Luanti's server makes the auth entry when a client logs in, and the
	-- builtin's own join callback expects to find one: here whoever
	-- connects is who they say they are -- a buildat server decided that
	-- one layer down -- so the entry is made with an empty password.
	local handler = core.get_auth_handler and core.get_auth_handler()
	if handler and handler.get_auth and handler.create_auth then
		local ok, entry = pcall(handler.get_auth, name)
		if ok and entry == nil then
			pcall(handler.create_auth, name, "")
		end
	end
	-- Luanti runs on_newplayer for a player with nothing saved, before
	-- on_joinplayer. A game that puts its newcomers somewhere (citadel's
	-- arena, a skyblock island) does it here, and where it put them is
	-- their spawn: the ground placement below leaves them alone.
	if new_here then
		local was = {x = o.pos.x, y = o.pos.y, z = o.pos.z}
		for _, cb in ipairs(core.registered_on_newplayers or {}) do
			local ok, err = xpcall(function() return cb(ref) end,
					function(e)
						return tostring(e) .. "\n" .. debug.traceback("", 2)
					end)
			if not ok then
				core.log("error", "on_newplayer: " .. tostring(err))
			end
		end
		if was.x ~= o.pos.x or was.y ~= o.pos.y or was.z ~= o.pos.z then
			o.spawn_known = true
		end
	end
	if new_here and not o.spawn_known then
		unplaced[name] = {x = o.pos.x, y = o.pos.y, z = o.pos.z}
	end
	-- A client that arrives is told the HUD the game had already put on it,
	-- which for a player who was here before is everything a mod added the
	-- last time they joined, and what their life and breath are
	send_whole_hud(o)
	send_stats(o)
	-- And whatever a mod had already done to how they move, which for a
	-- player who was here before is still on them
	send_physics(o)
	send_camera(o)
	send_day_night(o)
	-- The whole sky again, though it was sent before they left
	o.sky_sent = nil
	send_sky(o)
	core.__send_privs(o.player_name)
	send_modes(o)
	-- And what time it is. The module sends this to everyone every few
	-- seconds of the world's own clock, which under load is a good deal
	-- longer than a few seconds of anyone else's -- and a client with no
	-- clock at all draws the sky it started with. So the first one is here,
	-- where somebody has just arrived and has nothing.
	core.__send_time()
	-- Where the last run left them, or the spawn: either way it is the
	-- server's answer and the client starts there. A player whose spawn the
	-- map cannot answer for yet is not told anything -- a fallback position
	-- would start their client walking from a place the server does not
	-- believe in either -- and the placement below tells them once there is
	-- ground to stand on.
	if not new_here or o.spawn_known then
		tell_the_client(o)
	end
	core.log("action", "Player " .. name .. " joined")
	for _, cb in ipairs(core.registered_on_joinplayers or {}) do
		-- With the traceback, because a game the size of VoxeLibre has
		-- eighty of these and the message alone says nothing about which
		-- mod's it was
		local ok, err = xpcall(function() return cb(ref, nil) end,
				function(e)
					return tostring(e) .. "\n" .. debug.traceback("", 2)
				end)
		if not ok then
			core.log("error", "on_joinplayer: " .. tostring(err))
		end
	end
end

function core.__remove_player(name)
	-- An admin is one while connected (apps/vanilla says so at each join):
	-- kept after, the name was still an admin's to whoever registered it
	-- next ([SECURITY_RUN_1])
	if core.__admins then
		core.__admins[name] = nil
	end
	placing[name] = nil
	local id = players[name]
	if id == nil then
		return
	end
	local ref = core.object_refs[id]
	for _, cb in ipairs(core.registered_on_leaveplayers or {}) do
		local ok, err = pcall(cb, ref, false)
		if not ok then
			core.log("error", "on_leaveplayer: " .. tostring(err))
		end
	end
	local o = objects[id]
	if o then
		saved_players[name] = snapshot_player(o)
	end
	players[name] = nil
	objects[id] = nil
	core.object_refs[id] = nil
	core.objects_by_guid[name] = nil
	core.log("action", "Player " .. name .. " left")
end

-- Where a player is and which way they are looking is their client's to say
-- What a landing costs, which is Luanti's own arithmetic from its client
-- environment: one hit point per node a second over fourteen, rounded, and
-- nothing at or under it. The speed is the client's word and is bounded
-- before it gets here; see on_fell() in apps/vanilla/main/main.cpp.
--
-- simplified: no fall_damage_add_percent, from the node landed on or from
-- the player's own armour groups. Luanti multiplies the speed by both
-- before the tolerance is taken off; the upgrade path is those two group
-- lookups, the rest of the sum being this.
local FALL_TOLERANCE = 14

function core.__player_fell(name, speed)
	speed = tonumber(speed) or 0
	if speed <= FALL_TOLERANCE then
		return
	end
	if not core.settings:get_bool("enable_damage", true) then
		return
	end
	local id = players[name]
	local o = id and objects[id]
	if not (o and o.ref) or (o.hp or 0) <= 0 then
		return
	end
	local damage = math.floor(speed - FALL_TOLERANCE + 0.5)
	if damage <= 0 then
		return
	end
	o.ref:set_hp(o.hp - damage, {type = "fall"})
end

do
	-- The tolerance is the whole of it: a step off a kerb is free, and
	-- every node a second over it is a hit point
	local function cost(speed)
		return math.floor(speed - FALL_TOLERANCE + 0.5)
	end
	assert(cost(14) == 0, "fall: the tolerance itself is free")
	assert(cost(20) == 6, "fall: a node a second over is a hit point")
	assert(cost(23.9) == 10, "fall: it rounds rather than truncating")
end

-- Official's anticheat at its simplest ([FLY_MODES]): a player without
-- the fly privilege who is off the ground and not falling for a second
-- of updates, or without noclip whose body is inside a walkable node, is
-- put back at the last position that was fine. Water, ladders and the
-- like are not the ground but are not flying either.
-- Inside a walkable node: the body (the default player box, less a
-- margin a client's float leaves) in one of the node's collision boxes, so
-- that standing on a rail's plate, a slab or a stair is not
-- ([VL_RAIL_BOXES]); a node with no box of its own the whole cube
local BODY_R, BODY_H, BODY_M = 0.3, 1.7, 0.05
local function body_in_node(p, x, y, z)
	local n = core.get_node_or_nil(p)
	local def = n and core.registered_nodes[n.name]
	if def == nil or def.walkable == false then
		return false
	end
	local boxes = core.get_node_boxes("collision_box", p, n)
	if #boxes == 0 then
		boxes = {{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}}
	end
	for _, b in ipairs(boxes) do
		if x + BODY_R - BODY_M > p.x + b[1] and x - BODY_R + BODY_M < p.x + b[4] and
				y + BODY_H - BODY_M > p.y + b[2] and y + BODY_M < p.y + b[5] and
				z + BODY_R - BODY_M > p.z + b[3] and z - BODY_R + BODY_M < p.z + b[6] then
			return true
		end
	end
	return false
end
local function node_holds(p)
	local n = core.get_node_or_nil(p)
	local def = n and core.registered_nodes[n.name]
	return def == nil or def.walkable ~= false or def.liquidtype ~= "none" or
			def.climbable == true or def.liquid_move_physics == true
end
local function hold_down(o, x, y, z)
	-- The privileges once a second, not per update: the singleplayer's
	-- is a table of every one built each time
	local now = core.get_us_time()
	if not o.privs or now - (o.privs_at or 0) > 1000000 then
		o.privs = core.get_player_privs(o.player_name)
		o.privs_at = now
	end
	local privs = o.privs
	if privs.fly and privs.noclip then
		o.airborne = 0
		o.good_pos = {x = x, y = y, z = z}
		return false
	end
	local feet = {x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5)}
	local inside = body_in_node(feet, x, y, z) or
			body_in_node({x = feet.x, y = feet.y + 1, z = feet.z}, x, y, z)
	if not privs.noclip and inside and o.good_pos then
		return true
	end
	-- Off the ground: nothing holds under the feet (a fifth below), and
	-- the body is not falling
	local under = {x = feet.x, y = math.floor(y - 0.2 + 0.5), z = feet.z}
	local falling = o.pos and y < o.pos.y - 0.01
	if not privs.fly and not node_holds(under) and not node_holds(feet) and
			not falling then
		o.airborne = (o.airborne or 0) + 1
		if o.airborne > 10 and o.good_pos then
			return true
		end
	else
		o.airborne = 0
	end
	if not inside then
		o.good_pos = {x = x, y = y, z = z}
	end
	return false
end

function core.__set_player_pos(name, x, y, z, look_h, look_v, controls)
	local id = players[name]
	local o = id and objects[id]
	-- A dead player's reports are dropped, as Luanti's process_PlayerPos
	-- does: the ones from where they died, in flight over the respawn, put
	-- them back there (in lava, relit: [RESPAWN_EFFECTS])
	if not o or (o.player_name and o.hp <= 0) then
		return
	end
	-- A report from before the client had the position the server told it
	-- (a respawn, a set_pos) is dropped: it is far from that position.
	-- simplified: far is 8 nodes, and after 2 s the reports are taken
	-- anyway (a client that never applied it); a sequence number in the
	-- protocol would be exact.
	local told = o.told
	if told then
		if vector.distance(told, {x = x, y = y, z = z}) > 8 and
				core.get_us_time() - told.at < 2000000 then
			return
		end
		o.told = nil
	end
	if o.player_name and hold_down(o, x, y, z) then
		local g = o.good_pos
		o.airborne = 0
		core.log("action", name .. " is held down: put back at " ..
				core.pos_to_string(g))
		o.ref:set_pos(g)
		return
	end
	o.pos = {x = x, y = y, z = z}
	if look_h then
		o.look.h = look_h
		o.look.v = look_v or 0
	end
	if controls and o.control then
		set_control_bits(o, controls)
	end
end

-- Which slot the player is holding, as their client says. A mod reads it
-- through get_wield_index() and everything that asks what is in hand -- a
-- dig, a place, a craft -- goes through the same number.
function core.__set_wield_index(name, i)
	local id = players[name]
	local o = id and objects[id]
	if not o then
		return
	end
	local size = o.inventory and o.inventory:get_size("main") or 0
	i = math.floor(tonumber(i) or 1)
	if i < 1 then
		i = 1
	end
	if size > 0 and i > size then
		i = size
	end
	o.wield_index = i
end

function core.get_connected_players()
	local out = {}
	for _, id in pairs(players) do
		local o = objects[id]
		if o then
			out[#out + 1] = o.ref
		end
	end
	return out
end

function core.get_player_by_name(name)
	local id = players[name]
	local o = id and objects[id]
	return o and o.ref or nil
end

-- What the client on the other end is. Nothing here speaks Luanti's
-- protocol, so there is no true number to give -- but zero is not a
-- neutral answer, it is the answer "older than anything", and a game that
-- asks acts on it: **nodecore kicks every player who joins**, because
-- `pinfo.protocol_version < 39` is how it keeps clients that cannot draw
-- its world out. A game nobody can play is a worse wrong answer than a
-- number.
--
-- So what is reported is what the module's client half can actually do,
-- expressed in the only units a game asks in: Luanti 5.4's protocol 39 and
-- formspec version 4. Those are a claim about features -- meshes, the HUD
-- elements, particles, the formspec elements that version had -- and the
-- claim is why the number is not higher.
--
-- simplified: it is one number for every client, and the client half's own
-- capabilities are not asked. The upgrade path is for the client to say
-- what it supports when it joins, which is also what would let this rise
-- as the client half grows.
local PROTOCOL_VERSION = 39
local FORMSPEC_VERSION = 4

function core.get_player_information(name)
	if players[name] == nil then
		return nil
	end
	return {
		address = core.get_player_ip(name) or "",
		ip_version = 4,
		connection_uptime = 0,
		protocol_version = PROTOCOL_VERSION,
		formspec_version = FORMSPEC_VERSION,
		lang_code = "",
		version_string = "buildat",
		min_rtt = 0, max_rtt = 0, avg_rtt = 0,
		min_jitter = 0, max_jitter = 0, avg_jitter = 0,
	}
end

function core.get_player_window_information(name)
	return nil
end

--
-- The step
--

-- A voxel stops a box if its definition says walkable. An unknown one --
-- "ignore", which is what the void reads as -- does not, because a world
-- that has not been generated is not a floor.
--
-- **Asked by content id** ([CLIENT_FRAME], 2026-09-26). This was
-- `core.get_node()`, which builds a position table and a node table and
-- then looks the definition up by name -- for every voxel of every
-- collision box of every object of every step. A mob's box covers a
-- handful of voxels and is tested on three axes, and VoxeLibre keeps a
-- hundred objects active around a player: measured, the object walk was
-- 239 ms of one step, of which the mods' own `on_step` was 122 and the
-- rest was here, most of it making tables for the collector.
--
-- The raw read gives the id with no tables at all, and what the id means
-- is remembered the first time it is asked.
--
-- simplified: a definition that changes after a box has already met that
-- id keeps the old answer. Mods override at load, before any object is
-- stepped; a game that wants to change `walkable` at runtime would want
-- this cleared.
local walkable_by_id = {}
local function voxel_walkable(x, y, z)
	local id = core.get_node_raw(x, y, z)
	local w = walkable_by_id[id]
	if w == nil then
		local def = core.registered_nodes[core.get_name_from_content_id(id)]
		w = def ~= nil and def.walkable ~= false
		walkable_by_id[id] = w
	end
	return w
end

-- A node at p fills the voxel from p-0.5 to p+0.5, so the voxels a box
-- overlaps are the ones its corners round to. The shrink is what keeps a box
-- resting exactly on a surface from being inside it.
local SHRINK = 0.001

local function box_range(lo, hi)
	return math.floor(lo + SHRINK + 0.5), math.floor(hi - SHRINK + 0.5)
end

-- The voxel the box ran into, taken along axis i in direction dir so that
-- the one that stops it first is the one that answers
local function box_blocker(pos, box, i, dir)
	local x0, x1 = box_range(pos.x + box[1], pos.x + box[4])
	local y0, y1 = box_range(pos.y + box[2], pos.y + box[5])
	local z0, z1 = box_range(pos.z + box[3], pos.z + box[6])
	local best = nil
	for z = z0, z1 do
		for y = y0, y1 do
			for x = x0, x1 do
				if voxel_walkable(x, y, z) then
					local p = {x = x, y = y, z = z}
					if best == nil or (dir > 0 and p[i] < best[i]) or
							(dir < 0 and p[i] > best[i]) then
						best = p
					end
				end
			end
		end
	end
	return best
end

local TRACE_OBJECT = os.getenv and os.getenv("BUILDAT_LUANTI_TRACE_OBJECT") or nil
if TRACE_OBJECT == "" then TRACE_OBJECT = nil end

local AXIS_MIN = {x = 1, y = 2, z = 3}
local AXIS_MAX = {x = 4, y = 5, z = 6}

local function move_axis(o, i, d, box, result)
	if d == 0 then
		return
	end
	local was = o.pos[i]
	o.pos[i] = was + d
	local hit = box_blocker(o.pos, box, i, d)
	if hit == nil then
		return
	end
	-- Put it against the face it ran into rather than back where it was, so
	-- that a falling thing comes to rest on the floor and not above it
	if d > 0 then
		o.pos[i] = hit[i] - 0.5 - box[AXIS_MAX[i]] - SHRINK
	else
		o.pos[i] = hit[i] + 0.5 - box[AXIS_MIN[i]] + SHRINK
	end
	if (d > 0 and o.pos[i] < was) or (d < 0 and o.pos[i] > was) then
		-- It was already inside; leave it where it was rather than pushing
		-- it further in. The builtin's item entity looks for this and works
		-- itself out of a node it is stuck in.
		o.pos[i] = was
	end
	local old_v = vec(o.vel)
	o.vel[i] = 0
	result.collides = true
	if i == "y" and d < 0 then
		result.touching_ground = true
	end
	result.collisions[#result.collisions + 1] = {
		type = "node",
		axis = i,
		node_pos = hit,
		new_pos = vec(o.pos),
		old_velocity = old_v,
		new_velocity = vec(o.vel),
	}
end

-- How often an active object is asked for its static data, which is about
-- what Luanti's own deactivateFarObjects() comes to while an object stays
-- where it is.
local STATICDATA_INTERVAL = 2

-- Luanti asks an active object for its static data every couple of seconds,
-- because that is what it writes into the block the object is in. Nothing
-- here keeps an object in a block -- see the note in core.__step_objects()
-- -- so the string is only held, and this looks like a call made for its
-- side effects alone. It is not optional for all that: a mod is entitled to
-- do its own bookkeeping in get_staticdata(), and **VoxeLibre's mobs do
-- not move without it**. A freshly spawned mcl_mobs mob has no state until
-- something sets one, and the one thing that does is get_staticdata(); with
-- it never called, every mob in the game stood still for ever.
local function ask_for_staticdata(o, dtime)
	local le = o.le
	if le == nil or le.get_staticdata == nil then
		return
	end
	-- Spread over the interval rather than all on one step: the objects of
	-- a game the size of VoxeLibre are serialised here, one table each
	o.staticdata_in = (o.staticdata_in or
			math.random() * STATICDATA_INTERVAL) - dtime
	if o.staticdata_in > 0 then
		return
	end
	o.staticdata_in = STATICDATA_INTERVAL
	core.set_last_run_mod(le.mod_origin)
	local ok, data = pcall(le.get_staticdata, le)
	if ok then
		o.staticdata = data
	else
		core.log("error", "entity " .. tostring(le.name) ..
				" get_staticdata: " .. tostring(data))
	end
end

local function step_object(o, dtime)
	-- Where a player is is their client's to say, and nothing here has an
	-- opinion about it
	if o.player_name then
		return
	end
	-- An attached object is where its parent is, plus the attachment's
	-- offset turned by the parent's yaw -- Luanti's own rule, less the
	-- bone, which nothing here has a skeleton for. So a wielded-item
	-- entity rides with its player and a census near the player counts
	-- it, the way one does on Luanti. simplified: the bone's own
	-- transform is not applied; the offset is from the parent's origin.
	local a = o.attached_to
	if a then
		local p = a.ref and state_of(a.ref)
		if p then
			local off = a.position or {x = 0, y = 0, z = 0}
			local yaw = p.rot and p.rot.y or 0
			local c, sn = math.cos(yaw), math.sin(yaw)
			local ox, oz = off.x or 0, off.z or 0
			o.pos = {x = p.pos.x + ox * c - oz * sn,
					y = p.pos.y + (off.y or 0),
					z = p.pos.z + ox * sn + oz * c}
			o.vel = {x = 0, y = 0, z = 0}
		end
		if o.le and o.le.on_step then
			core.set_last_run_mod(o.le.mod_origin)
			local ok, err = pcall(o.le.on_step, o.le, dtime, nil)
			if not ok then
				core.log("error", "entity " .. tostring(o.le.name) .. ": " ..
						tostring(err))
			end
		end
		ask_for_staticdata(o, dtime)
		return
	end
	local props = o.props
	o.vel = {
		x = o.vel.x + o.acc.x * dtime,
		y = o.vel.y + o.acc.y * dtime,
		z = o.vel.z + o.acc.z * dtime,
	}
	local dx, dy, dz = o.vel.x * dtime, o.vel.y * dtime, o.vel.z * dtime
	local moveresult = nil
	if props.physical then
		local box = props.collisionbox or DEFAULT_PROPERTIES.collisionbox
		moveresult = {
			touching_ground = false,
			collides = false,
			standing_on_object = false,
			collisions = {},
		}
		-- Axis at a time, y last, so that a box sliding along the floor is
		-- not stopped by the floor it is already resting on
		move_axis(o, "x", dx, box, moveresult)
		move_axis(o, "z", dz, box, moveresult)
		move_axis(o, "y", dy, box, moveresult)
		-- BUILDAT_LUANTI_TRACE_OBJECT=<entity name>: every step of every
		-- object of that name, for reading a fall that stops ([DIG_PARITY])
		if TRACE_OBJECT and o.le and o.le.name == TRACE_OBJECT then
			core.log("warning", string.format(
					"trace %s: pos %.3f,%.3f,%.3f vel %.2f,%.2f,%.2f acc %.1f ground %s hits %d dt %.3f active %s",
					TRACE_OBJECT, o.pos.x, o.pos.y, o.pos.z, o.vel.x, o.vel.y,
					o.vel.z, o.acc.y, tostring(moveresult.touching_ground),
					#moveresult.collisions, dtime, tostring(core.__is_active(o.pos))))
		end
	else
		o.pos = {x = o.pos.x + dx, y = o.pos.y + dy, z = o.pos.z + dz}
	end
	if o.le and o.le.on_step then
		core.set_last_run_mod(o.le.mod_origin)
		local ok, err = pcall(o.le.on_step, o.le, dtime, moveresult)
		if not ok then
			core.log("error", "entity " .. tostring(o.le.name) .. ": " ..
					tostring(err))
		end
	end
	ask_for_staticdata(o, dtime)
end

-- Where every object is and how big it is, once per step: the module puts a
-- node in the scene for each, and the scene is what every client is already
-- being sent. A box the size of the collision box, because what an object
-- looks like is the client half's and this is what says where they are
-- until then.

-- What an object looks like, as much of it as the client half draws: a shape
-- and one texture. Luanti's visuals are more than these three, and the ones
-- that are not here fall back to the plain box they were before.
--
-- simplified: one texture rather than six for a cube, and a mesh is a cube
-- wearing its first texture. The upgrade path is the shapes themselves --
-- b3dmesh.lua and objmesh.lua in extensions/luanti_client read the two
-- formats Luanti ships -- and it is a milestone of its own.
local function appearance_of(o)
	local props = o.props
	local visual = props.visual or "sprite"
	local textures = props.textures or {}
	if visual == "cube" then
		return "cube", textures[1] or ""
	end
	if visual == "mesh" then
		-- A model: the mesh file, the size it is drawn at and the whole
		-- texture list -- one per material -- because none of that fits in
		-- a texture name. The client asks for the mesh itself by name, once,
		-- on a channel of its own; see core.__model_quads().
		local mesh = props.mesh or ""
		if mesh == "" then
			return "cube", textures[1] or ""
		end
		local v = props.visual_size or {}
		-- The size, and behind it the frame the model is posed at: the
		-- animation's first, or none for the bind pose
		local detail = {mesh,
				tostring(v.x or v[1] or 1) .. "," ..
				tostring(v.y or v[2] or 1) .. "," ..
				tostring(v.z or v[3] or v.x or v[1] or 1) ..
				(o.animation and ("," .. tostring(o.animation.x) .. "," ..
						tostring(o.animation.y) .. "," ..
						tostring(o.animation.speed) .. "," ..
						(o.animation.loop and "1" or "0")) or "")}
		for _, t in ipairs(textures) do
			detail[#detail + 1] = t
		end
		return "mesh", textures[1] or "", table.concat(detail, "\1")
	end
	if visual == "sprite" or visual == "upright_sprite" then
		-- The sheet's division and the frame shown, behind a \2 so the
		-- client tells it from an item's name
		local div = props.spritediv or {}
		local dx, dy = math.max(1, div.x or 1), math.max(1, div.y or 1)
		local f = o.sprite or props.initial_sprite_basepos or {}
		local detail = ""
		if dx > 1 or dy > 1 then
			detail = "\2" .. dx .. "," .. dy .. "," .. (f.x or 0) .. "," .. (f.y or 0)
		end
		return "sprite", textures[1] or "", detail
	end
	if visual == "wielditem" or visual == "item" then
		-- What the item looks like in an inventory is what it looks like
		-- lying on the ground, which is the same expression.
		--
		-- Which item it is, is in the first texture: that is where Luanti's
		-- own builtin item entity puts it and where VoxeLibre's does too.
		-- wield_item is the other spelling and is answered after it, since
		-- an object that sets that and no texture means the same thing.
		local name = textures[1] or ""
		if name == "" then
			name = props.wield_item or ""
		end
		if name == "" then
			return "box", ""
		end
		-- The item's name rides along, so a client can say "an item"
		-- rather than "a sprite" of it ([SCAN_EVENT])
		return "sprite", core.__item_image_of(name) or "", name
	end
	return "box", ""
end

-- id -> {kind, texture} as last sent, so that what is sent is what has
-- changed -- and so that a client that connects later can be told the lot
local sent_appearance = {}

-- Every object's look, flat, for a client that has just arrived: the props
-- are sent when they change and a client that was not there missed them.
function core.__object_appearances()
	local out = {}
	for id, look in pairs(sent_appearance) do
		out[#out + 1] = tostring(id)
		out[#out + 1] = look[1]
		out[#out + 1] = look[2]
		out[#out + 1] = look[3] or ""
		out[#out + 1] = look[4] or "1"
		out[#out + 1] = look[5] or ""
	end
	return out
end

-- Where an object is drawn, which is where it is unless it is riding
-- something: a child is at its parent's place plus the offset it was
-- attached with. Luanti's attachment offsets are in its own units, ten to
-- the node, and the chain can be more than one deep -- a player on a seat
-- on a cart -- so this follows it up, with a bound in case a mod makes a
-- ring of them.
-- Where a bone attachment is drawn ([WIELD_AT_FEET] (2)): the bone's own
-- transform is not read yet, so every bone lands at one place on the
-- model -- about the hand: halfway between the eyes and the feet, 0.3
-- nodes to the model's right and 0.2 forward, turned with its yaw. Real
-- bone transforms come with [OBJECT_MESH] step 1.
-- simplified: the fixed offsets and the yaw's right/forward signs are
-- tuned against a VoxeLibre shot (BUILDAT_LUANTI_TRACE_OBJECT).
local BONE_HAND_UP = 0.8
local BONE_HAND_RIGHT = 0.3
local BONE_HAND_FWD = 0.2

-- The yaw a bone attachment's offset is turned by: its parent's. nil for
-- an object on no bone.
local function bone_yaw_of(o)
	local a = o.attached_to
	local parent = a and state_of(a.ref) or nil
	if parent == nil or not a.bone or a.bone == "" then
		return nil
	end
	-- A player turns by its look (its rot stays 0); either is
	-- counter-clockwise from +Z, so forward is (-sin, cos) as in
	-- get_look_dir() and the right hand (cos, sin)
	return parent.look and parent.look.h or parent.rot and parent.rot.y or 0
end

local function drawn_pos_of(o, depth)
	local a = o.attached_to
	local parent = a and state_of(a.ref) or nil
	if parent == nil or (depth or 0) > 4 then
		return o.pos
	end
	local at = drawn_pos_of(parent, (depth or 0) + 1)
	local yaw = bone_yaw_of(o)
	if yaw then
		local s, c = math.sin(yaw), math.cos(yaw)
		return {
			x = at.x + BONE_HAND_RIGHT * c - BONE_HAND_FWD * s,
			y = at.y + BONE_HAND_UP,
			z = at.z + BONE_HAND_RIGHT * s + BONE_HAND_FWD * c,
		}
	end
	local offset = a.position or {x = 0, y = 0, z = 0}
	return {
		x = at.x + (offset.x or offset[1] or 0) / 10,
		y = at.y + (offset.y or offset[2] or 0) / 10,
		z = at.z + (offset.z or offset[3] or 0) / 10,
	}
end

-- The hand turns with its player: at each of four looks it is to the
-- right of and ahead of where that look faces (get_look_dir())
function core.__check_bone_hand()
	local pid, cid = "__check_holder", "__check_held"
	local holder = {pos = {x = 5, y = 0, z = -3}, rot = {x = 0, y = 0, z = 0},
			look = {h = 0, v = 0}}
	objects[pid] = holder
	local ref = new_ref(PlayerRef_proto, pid)
	objects[cid] = {pos = {x = 0, y = 0, z = 0}, attached_to = {ref = ref,
			bone = "Wield_Item"}}
	for i = 0, 3 do
		holder.look.h = i * math.pi / 2
		local d = ref:get_look_dir()
		local p = drawn_pos_of(objects[cid])
		local dx, dz = p.x - 5, p.z + 3
		-- Ahead: along the look; right: the look turned clockwise from
		-- above, (d.z, -d.x) with +X east and +Z north
		local fwd = dx * d.x + dz * d.z
		local right = dx * d.z - dz * d.x
		assert(math.abs(fwd - BONE_HAND_FWD) < 1e-6 and
				math.abs(right - BONE_HAND_RIGHT) < 1e-6,
				"check_bone_hand: at look "..i.." the hand is "..fwd..
				" ahead and "..right.." right")
	end
	objects[pid], objects[cid] = nil, nil
end

-- **How often the whole list goes out** ([PACKET_STALL] (2),
-- 2026-09-25): every step was several a second of a thousand doubles,
-- and the client spends 6 to 13 ms on each of them with a herd about.
-- Ten a second is the cap; a step that changes nothing sends nothing at
-- all.
--
-- **Why the whole list and not a delta**: `luanti:objects` is declared
-- LatestOnly (`luanti.cpp:1169`), so a queued packet is replaced by a
-- newer one -- which is safe exactly because every packet is complete.
-- A delta dropped that way is an update lost for good, so sending less
-- often is the half of (2) that does not need a second channel.
local OBJECTS_INTERVAL = 0.1
local objects_due = 0

local function same_list(a, b)
	if b == nil or #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

-- **Each client gets the objects within its send range** ([SERVER_PRESETS]
-- 1): Luanti's active_object_send_range_blocks, in sections of 64 nodes
-- as the world's two ranges are (luanti.cpp read_range_settings), 1 to
-- 16; Luanti's default of 8 blocks is 2 sections. A herd on the far side of the world costs a client
-- nothing, and the server a distance per object and player. Each list is
-- still whole for its range, so LatestOnly stays safe. A client forgets
-- the look of an object that leaves its list, so one coming back into
-- range is sent its look again.
local send_range = nil
local function object_send_range()
	if not send_range then
		local blocks = tonumber(core.settings:get(
				"active_object_send_range_blocks")) or 8
		local sections = math.max(1, math.min(16, math.floor(blocks * 16 / 64)))
		send_range = sections * 64
		core.log("action", "objects sent within " .. send_range ..
				" nodes (active_object_send_range_blocks)")
	end
	return send_range
end
-- player name -> {last = the list last sent, looks = id -> look sent}
local sent_to = {}

local function show_objects(dtime)
	objects_due = objects_due - (dtime or 0)
	if objects_due > 0 then
		return
	end
	objects_due = OBJECTS_INTERVAL
	local range = object_send_range()
	local here = {}
	for _, o in pairs(objects) do
		if o.player_name then
			here[o.player_name] = o.pos
		end
	end
	-- Within some player's range ([REWORK_1019_PERF] luanti 8): the rest
	-- cost a distance per player and nothing else
	local function wanted(at)
		for _, p in pairs(here) do
			local dx, dy, dz = at.x - p.x, at.y - p.y, at.z - p.z
			if dx * dx + dy * dy + dz * dz <= range * range then
				return true
			end
		end
		return false
	end
	-- Every wanted object's record and look once, then each player's share
	local recs = {}
	for id, o in pairs(objects) do
		local box = o.props.collisionbox or DEFAULT_PROPERTIES.collisionbox
		if o.props.is_visible == false then
			box = nil
		end
		local at = box and drawn_pos_of(o, 0)
		if at and wanted(at) then
			-- The node is at the middle of the box and scaled to its size,
			-- and a zero side would be a node nobody can see anyway
			local sx = math.max(box[4] - box[1], 0.05)
			local sy = math.max(box[5] - box[2], 0.05)
			local sz = math.max(box[6] - box[3], 0.05)
			local a = o.attached_to
			-- Whether a ray may hit it: Luanti's pointable. VoxeLibre's
			-- wieldview rides at its player's feet with pointable false,
			-- and a client that did not know stood punching it instead of
			-- digging the ground (2026-09-19)
			--
			-- And where its boxes are about its position
			-- ([OBJECT_SELECTION_BOX]): the collision box's middle, which
			-- the packet below places it at, and the selection box (the
			-- collision box when there is none, as Luanti's), which is what
			-- is aimed at and framed. A model and a sprite are drawn at
			-- the position itself, as Luanti draws them. In the look, which
			-- goes out when it changes, rather than in every packet.
			--
			-- Made again only when set_properties, set_sprite or an
			-- animation setter marked it dirty ([REWORK_1019_PERF] luanti
			-- 8). simplified: a property table a mod changes in place after
			-- handing it over is not seen until its next setter call
			local look = sent_appearance[id]
			if not look or o.look_dirty then
				o.look_dirty = false
				local kind, texture, detail = appearance_of(o)
				local sel = o.props.selectionbox or box
				look = {kind, texture, detail or "",
					(o.props.pointable ~= false) and "1" or "0",
					string.format("%g %g %g %g %g %g %g %g %g",
						(box[1] + box[4]) / 2, (box[2] + box[5]) / 2,
						(box[3] + box[6]) / 2, sel[1] or 0, sel[2] or 0,
						sel[3] or 0, sel[4] or 0, sel[5] or 0, sel[6] or 0)}
				local was = sent_appearance[id]
				if not was or was[1] ~= look[1] or was[2] ~= look[2] or
						was[3] ~= look[3] or was[4] ~= look[4] or
						was[5] ~= look[5] then
					sent_appearance[id] = look
				else
					look = was
				end
			end
			recs[#recs + 1] = {id = id, at = at, look = look, v = {id,
				at.x + (box[1] + box[4]) / 2,
				at.y + (box[2] + box[5]) / 2,
				at.z + (box[3] + box[6]) / 2,
				sx, sy, sz,
				o.rot and o.rot.y or 0,
				-- Pitch and roll too: a minecart shakes, a fish tilts, a
				-- dead mob lies down (lua_api.md "Coordinate System")
				o.rot and o.rot.x or 0,
				o.rot and o.rot.z or 0,
				-- Which object it rides and whether forced visible
				-- ([WIELD_AT_FEET] (1)): the client leaves a thing attached
				-- to its own player out of the first-person view unless
				-- forced. In the per-step list, not the props, so the
				-- client re-reads it every packet rather than missing it
				-- once the list settles.
				a and (ref_ids[a.ref] or 0) or 0,
				(a and a.forced_visible) and 1 or 0,
				-- The yaw a bone attachment was turned by, -1000 for none:
				-- the client turns it on to its own player's yaw every
				-- frame ([WIELD_AT_FEET])
				bone_yaw_of(o) or -1000}}
		end
	end
	for id, _ in pairs(sent_appearance) do
		if objects[id] == nil then
			sent_appearance[id] = nil
		end
	end
	for name in pairs(sent_to) do
		if not here[name] then
			sent_to[name] = nil
		end
	end
	for name, p in pairs(here) do
		local st = sent_to[name]
		if not st then
			st = {looks = {}}
			sent_to[name] = st
		end
		local v, props, seen = {}, {}, {}
		for _, rec in ipairs(recs) do
			local dx, dy, dz = rec.at.x - p.x, rec.at.y - p.y, rec.at.z - p.z
			if dx * dx + dy * dy + dz * dz <= range * range then
				local rv = rec.v
				for i = 1, #rv do
					v[#v + 1] = rv[i]
				end
				seen[rec.id] = true
				if st.looks[rec.id] ~= rec.look then
					st.looks[rec.id] = rec.look
					local look = rec.look
					props[#props + 1] = tostring(rec.id)
					props[#props + 1] = look[1]
					props[#props + 1] = look[2]
					props[#props + 1] = look[3]
					props[#props + 1] = look[4]
					props[#props + 1] = look[5]
				end
			end
		end
		-- Out of range or gone: the client forgot its look with it
		for id in pairs(st.looks) do
			if not seen[id] then
				st.looks[id] = nil
			end
		end
		if #props > 0 then
			__show_object_props_to(name, props)
		end
		-- Nothing moved, grew, turned or went: the client has this list
		if not (#v == 0 and not st.last) and not same_list(v, st.last) then
			st.last = #v > 0 and v or nil
			__show_objects_to(name, v)
		end
	end
end

-- What a player is carrying, to their own client and nobody else's. The
-- inventory counts its own changes, so this is the one that has changed since
-- the last step rather than all of them every step.
--
-- The lists go over flat: a name, how many slots it has, and then that many
-- item strings. What reads them is the module's client half.
local function flatten_lists(inv, flat)
	for list_name, stacks in pairs(inv:get_lists()) do
		flat[#flat + 1] = list_name
		flat[#flat + 1] = tostring(#stacks)
		for _, stack in ipairs(stacks) do
			flat[#flat + 1] = stack:to_string()
		end
	end
	return flat
end

local function send_inventories()
	for name, id in pairs(players) do
		local o = objects[id]
		local inv = o and o.inventory
		if inv and inv.gen ~= o.sent_inventory_gen then
			o.sent_inventory_gen = inv.gen
			__send_inventory(name, flatten_lists(inv, {}))
		end
		-- And the node the open form is about, which is a chest's slots.
		-- What is drawn is only ever the one form's node, so one is enough.
		local at = o and form_nodes[name]
		local node_inv = at and core.get_meta(at):get_inventory() or nil
		if node_inv then
			local key = pos_string(at)
			if o.sent_node_at ~= key or node_inv.gen ~= o.sent_node_gen then
				o.sent_node_at = key
				o.sent_node_gen = node_inv.gen
				__send_node_inventory(name, flatten_lists(node_inv, {key}))
			end
		elseif o then
			o.sent_node_at = nil
		end
		-- And the detached inventories the open form names, which belong to
		-- nobody: the same channel with the location for a key, because
		-- that is what a formspec's list[] says and what the client looks
		-- them up by.
		if o then
			o.sent_detached = o.sent_detached or {}
			-- The form a game showed, and the player's own inventory form,
			-- which the client opens by itself whenever it likes
			local wanted = {}
			for inv_name, _ in pairs(form_detached[name] or {}) do
				wanted[inv_name] = true
			end
			for inv_name, _ in pairs(o.own_detached or {}) do
				wanted[inv_name] = true
			end
			for inv_name, _ in pairs(wanted) do
				local inv = core.get_inventory({type = "detached",
						name = inv_name})
				if inv and o.sent_detached[inv_name] ~= inv.gen then
					o.sent_detached[inv_name] = inv.gen
					__send_node_inventory(name,
							flatten_lists(inv, {"detached:" .. inv_name}))
				end
			end
			for inv_name, _ in pairs(o.sent_detached) do
				if not wanted[inv_name] then
					o.sent_detached[inv_name] = nil
				end
			end
		end
		-- The form the player's own inventory key opens, when a mod has
		-- changed it. It is sent when it changes rather than when it is
		-- asked for, so that opening it costs no round trip.
		local inv_spec = o and prepended(name, o.inventory_formspec or "")
		if o and inv_spec ~= o.sent_inventory_formspec then
			o.sent_inventory_formspec = inv_spec
			o.own_detached = detached_in_spec(o.inventory_formspec)
			__player_formspec(name, inv_spec)
		end
	end
end

-- What the world does to somebody standing in it: a node with
-- damage_per_second hurts whoever is in it, once a second, which is what
-- makes lava, fire and a cactus dangerous. The worst of the node the feet
-- are in and the node the head is in, which is Luanti's own rule.
--
-- simplified: those two nodes and nothing else. There is no fall damage --
-- a fall happens in the client's own physics and nothing reports one -- and
-- no drowning. See "Nothing hurts" in doc/plan/luanti_module_plan.md.
-- Where a player's nose is, which Luanti approximates with the eyes. The
-- same number apps/vanilla's player.lua puts the camera at.
local EYE_HEIGHT = 1.625

local function eye_node(o)
	return {
		x = math.floor(o.pos.x + 0.5),
		y = math.floor(o.pos.y + EYE_HEIGHT + 0.5),
		z = math.floor(o.pos.z + 0.5),
	}
end

-- Nothing at all happens to a player a mod has made immortal, which is what
-- enable_damage being off does to everybody: Luanti gives every player the
-- immortal armour group when it is off, and then checks that one flag.
local function immortal(o)
	return (o.armor_groups and (tonumber(o.armor_groups.immortal) or 0) ~= 0)
			or not core.settings:get_bool("enable_damage", true)
end

-- A punched player, as Luanti's PlayerSAO::punch has it: nothing from
-- another player while this one is immortal or PvP is off; otherwise the
-- registered on_punchplayer callbacks hear it -- all of them, any one
-- saying it dealt with it -- and the damage is done if none did. It was
-- the entity's punch, which knows none of the three ([SECURITY_RUN_1]).
function PlayerRef:punch(puncher, time_from_last_punch, tool_capabilities,
		dir)
	local o = state_of(self)
	if not o then
		return
	end
	local by_player = puncher and puncher.is_player and puncher:is_player()
	if by_player and (immortal(o) or
			not core.settings:get_bool("enable_pvp", true)) then
		return
	end
	local hit = core.get_hit_params(o.armor_groups, tool_capabilities,
			time_from_last_punch)
	local handled = false
	for _, cb in ipairs(core.registered_on_punchplayers or {}) do
		local ok, r = pcall(cb, self, puncher, time_from_last_punch,
				tool_capabilities, dir, hit.hp)
		if not ok then
			core.log("error", "on_punchplayer: " .. tostring(r))
		elseif r then
			handled = true
		end
	end
	if not handled and hit.hp > 0 then
		self:set_hp((o.hp or 0) - hit.hp, {type = "punch", object = puncher})
	end
end

-- Air, and the want of it. Luanti's own intervals and its own order: the
-- node at the nose costs a breath every two seconds while it drowns, and
-- when there is no breath left it costs health instead; anywhere it does
-- not drown, half a second puts a breath back.
local drown_timer, breath_timer = 0, 0
local function breathe_players(dtime)
	drown_timer = drown_timer + dtime
	breath_timer = breath_timer + dtime
	local drown = drown_timer >= 2
	local breathe = breath_timer >= 0.5
	if not (drown or breathe) then
		return
	end
	if drown then
		drown_timer = drown_timer - 2
	end
	if breathe then
		breath_timer = breath_timer - 0.5
	end
	for _, id in pairs(players) do
		local o = objects[id]
		if o and o.ref and (o.hp or 0) > 0 and o.pos and not immortal(o) then
			local node = core.get_node(eye_node(o))
			local def = node and core.registered_nodes[node.name]
			local costs = def and tonumber(def.drowning) or 0
			if drown and costs > 0 then
				if (o.breath or 0) > 0 then
					o.ref:set_breath(o.breath - 1)
				end
				if (o.breath or 0) == 0 then
					o.ref:set_hp(o.hp - costs,
							{type = "drown", node = node.name})
				end
			end
			if breathe and costs == 0 then
				local most = (o.props and o.props.breath_max) or 10
				if (o.breath or 0) < most then
					o.ref:set_breath(o.breath + 1)
				end
			end
		end
	end
end

local damage_timer = 0
local function damage_players(dtime)
	damage_timer = damage_timer + dtime
	if damage_timer < 1 then
		return
	end
	-- Not reset to zero: a step longer than a second still costs one second
	-- of damage and not two, and the remainder is kept
	damage_timer = damage_timer - 1
	for _, id in pairs(players) do
		local o = objects[id]
		if o and o.ref and (o.hp or 0) > 0 and o.pos and not immortal(o) then
			local worst, worst_name = 0, nil
			for dy = 0, 1 do
				local node = core.get_node({
					x = math.floor(o.pos.x + 0.5),
					y = math.floor(o.pos.y + 0.5) + dy,
					z = math.floor(o.pos.z + 0.5)})
				local def = node and core.registered_nodes[node.name]
				local dps = def and tonumber(def.damage_per_second) or 0
				if dps > worst then
					worst, worst_name = dps, node.name
				end
			end
			if worst > 0 then
				o.ref:set_hp(o.hp - worst,
						{type = "node_damage", node = worst_name})
			end
		end
	end
end

function core.__step_objects(dtime)
	place_the_unplaced(dtime)
	damage_players(dtime)
	breathe_players(dtime)
	-- Over the ids taken first, because a step adds and removes objects
	local ids = {}
	for id, _ in pairs(objects) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local o = objects[id]
		-- Where a player is is their client's to say, and everything else
		-- steps while it is in the active range -- which is where a player
		-- is, so a player is always in one. Luanti takes an entity out of
		-- the world entirely when its block stops being active and puts it
		-- back when the block returns.
		--
		-- simplified: it stays in the world here and only stops moving, so
		-- nothing is written into the section it is in and nothing has to
		-- be read back out of it. What that costs is an entity per object
		-- forever; Luanti's static objects are the upgrade path.
		if o and (o.player_name or core.__is_active(o.pos)) then
			step_object(o, dtime)
		end
	end
	show_objects(dtime)
	send_inventories()
end

-- vim: set noet ts=4 sw=4:
