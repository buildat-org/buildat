-- Buildat: builtin/luanti/lua/sky_hud.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- A player's sky and HUD. Run by entity.lua with the five of its locals
-- this reads; hands back what entity.lua calls ([SPLITS]: moved out as it
-- was).

local PlayerRef, out_vec, player_event, state_of, vec = ...
local send_hotbar
local send_hud

--
-- The sky a game says it has
--
-- Luanti's set_sky and set_clouds. What crosses to the client is what a sky
-- is made of here: the colour overhead, the colour at the horizon and how
-- much of the sky is cloud. The rest of what a mod can say -- a skybox's six
-- textures, the sun's own texture, the stars -- is kept and answered but not
-- drawn.
local SKY_DEFAULT_DAY = "#8cb2e0"
local SKY_DEFAULT_ZENITH = "#215edb"
-- The colour the sun and the moon paint the band of sky around them at
-- dawn and dusk. Luanti's own defaults, and both of this project's clients
-- hardcoded the sun's because the module never sent it; see [SKY_KNOBS] in
-- doc/plan/rendering_plan.md.
local SKY_DEFAULT_SUN_TINT = "#f47d1d"
local SKY_DEFAULT_MOON_TINT = "#7f99cc"

-- "#rrggbb", a table or a name, as three numbers between zero and one
local function sky_rgb(spec)
	if spec == nil then
		return nil
	end
	local t = core.colorspec_to_table and core.colorspec_to_table(spec)
	if t == nil then
		return nil
	end
	return string.format("%.4f,%.4f,%.4f", (t.r or 0) / 255,
			(t.g or 0) / 255, (t.b or 0) / 255)
end

local function send_sky(o)
	if not o or not o.player_name or not __luanti_send_sky then
		return
	end
	local sky = o.sky or {}
	local clouds = o.clouds_params or {}
	local sky_color = sky.sky_color or {}
	local flat = {}
	local function put(k, v)
		if v ~= nil then
			flat[#flat + 1] = k
			flat[#flat + 1] = tostring(v)
		end
	end
	put("type", sky.type or "regular")
	-- A skybox's own six pictures, in Luanti's order: Y+, Y-, X+, X-, Z-,
	-- Z+. Numbered rather than joined, because a texture name is a modifier
	-- expression and can hold anything a separator would.
	if (sky.type or "regular") == "skybox" then
		for i = 1, 6 do
			put("texture" .. i, (sky.textures or {})[i])
		end
	end
	-- The hours of the sky, which is what makes a night sky dark: Luanti
	-- keeps a colour for the day, one for dawn and one for the night, and
	-- whoever draws it blends between them as the sun goes round
	put("night_zenith", sky_rgb(sky_color.night_sky))
	put("night_horizon", sky_rgb(sky_color.night_horizon))
	put("dawn_zenith", sky_rgb(sky_color.dawn_sky))
	put("dawn_horizon", sky_rgb(sky_color.dawn_horizon))
	-- A plain sky is one colour everywhere, which is what base_color means
	-- when the type says plain; a regular one has the two ends of a gradient
	if (sky.type or "regular") == "plain" then
		local c = sky_rgb(sky.base_color) or sky_rgb(SKY_DEFAULT_DAY)
		put("zenith", c)
		put("horizon", c)
	else
		put("zenith", sky_rgb(sky_color.day_sky) or
				sky_rgb(SKY_DEFAULT_ZENITH))
		put("horizon", sky_rgb(sky_color.day_horizon) or
				sky_rgb(SKY_DEFAULT_DAY))
	end
	-- What the sun and the moon paint the horizon with as they cross it.
	-- Luanti's fog_tint_type says whether the game means the two values or
	-- wants Luanti's classic tinting; it is sent as it stands, and the
	-- values are sent either way so that a client that does not do the
	-- classic tinting has something right to draw.
	put("fog_tint_type", sky_color.fog_tint_type or "default")
	-- What a player who cannot see the sky is under, and whether the game
	-- lets a client dim its sky for that at all. Luanti's own defaults; see
	-- [CAVE_SKY] in doc/plan/rendering_plan.md for what reads them.
	put("indoors", sky_rgb(sky_color.indoors) or sky_rgb("#646464"))
	put("auto_dim_skybox", (sky.auto_dim_skybox ~= false) and "1" or "0")
	-- A skybox's base_color is what Luanti fogs with, where a plain sky's is
	-- the sky itself; it was sent only for the second. Sent as itself now,
	-- so the client can use it for whichever the type says.
	put("base_color", sky_rgb(sky.base_color))
	-- How far the sun and the moon's orbit is tilted, in degrees about the
	-- axis they rise over. Luanti clamps it to [-60, 60]; a game that tilts
	-- its sky means it.
	if tonumber(sky.body_orbit_tilt) then
		put("body_orbit_tilt", math.max(-60, math.min(60,
				tonumber(sky.body_orbit_tilt))))
	end
	-- Luanti's fog table. fog_start is a fraction of the viewing range and
	-- not a distance; fog_distance is not a fog knob at all but an upper
	-- bound on the client's viewing range, and negative gives it back.
	local fog = sky.fog or {}
	put("fog_color", sky_rgb(fog.fog_color))
	if tonumber(fog.fog_start) then
		put("fog_start", math.max(0, math.min(0.99, tonumber(fog.fog_start))))
	end
	put("fog_distance", tonumber(fog.fog_distance))
	put("sun_tint", sky_rgb(sky_color.fog_sun_tint) or
			sky_rgb(SKY_DEFAULT_SUN_TINT))
	put("moon_tint", sky_rgb(sky_color.fog_moon_tint) or
			sky_rgb(SKY_DEFAULT_MOON_TINT))
	-- Luanti's clouds are on unless a sky says otherwise, and how much of
	-- the sky they cover is their density
	local on = sky.clouds
	if on == nil then
		on = true
	end
	put("clouds", on and "1" or "0")
	put("density", clouds.density)
	put("cloud_color", sky_rgb(clouds.color))
	-- And how opaque they are (the colour's alpha, VoxeLibre's weather
	-- sets it) and how fast they drift, nodes a second on x and z.
	-- simplified: height and thickness are kept, not sent; both clients
	-- draw the clouds on the dome, with no layer for them to place
	local ct = clouds.color and core.colorspec_to_table and
			core.colorspec_to_table(clouds.color)
	put("cloud_alpha", ct and ct.a and string.format("%.4f", ct.a / 255))
	local speed = clouds.speed
	if type(speed) == "table" then
		put("cloud_speed", string.format("%.4f,%.4f", tonumber(speed.x) or 0,
				tonumber(speed.z or speed.y) or 0))
	end
	-- What is up there besides the gradient: Luanti's set_sun, set_moon and
	-- set_stars. The pictures a game gives its sun and its moon cross too:
	-- the sky's own square is what is drawn when it gives none.
	local sun = o.sun_params or {}
	local moon = o.moon_params or {}
	local stars = o.star_params or {}
	put("sun_visible", (sun.visible ~= false) and "1" or "0")
	put("sun_scale", sun.scale)
	put("sun_texture", sun.texture or "sun.png")
	put("moon_visible", (moon.visible ~= false) and "1" or "0")
	put("moon_scale", moon.scale)
	put("moon_texture", moon.texture or "moon.png")
	put("stars_visible", (stars.visible ~= false) and "1" or "0")
	put("star_count", stars.count)
	put("star_color", sky_rgb(stars.star_color))
	put("star_scale", stars.scale)
	-- Sent only when it changed: VoxeLibre sets the rain's clouds and its
	-- sky every step for every player, and each send is the whole record
	local key = table.concat(flat, "\n")
	if key == o.sky_sent then
		return
	end
	o.sky_sent = key
	__luanti_send_sky(o.player_name, flat)
end

-- set_sky(params) and Luanti's older set_sky(bgcolor, type, textures,
-- clouds), which is still what a good many mods call
function PlayerRef:set_sky(params, sky_type, textures, clouds)
	local o = state_of(self)
	if not o then
		return
	end
	if type(params) ~= "table" or sky_type ~= nil then
		params = {base_color = params, type = sky_type,
				textures = textures, clouds = clouds}
	end
	o.sky = table.copy(params)
	send_sky(o)
end

function PlayerRef:get_sky(as_table)
	local o = state_of(self)
	local sky = (o and o.sky) or {}
	if as_table then
		-- The whole of what was set, so that set_sky(get_sky(true)) is a
		-- round trip. That is how a mod changes one field of a sky somebody
		-- else set -- read, edit, write back -- and answering five fields
		-- out of the dozen a sky has is how the other seven get dropped on
		-- the way through.
		local t = table.copy(sky)
		t.type = t.type or "regular"
		t.textures = t.textures or {}
		if t.clouds == nil then
			t.clouds = true
		end
		t.sky_color = t.sky_color or {}
		t.fog = t.fog or {}
		return t
	end
	return sky.base_color, sky.type or "regular", sky.textures or {},
			sky.clouds ~= false
end

function PlayerRef:get_sky_color()
	local o = state_of(self)
	return ((o and o.sky) or {}).sky_color or {}
end

function PlayerRef:set_clouds(params)
	local o = state_of(self)
	if not o or type(params) ~= "table" then
		return
	end
	-- Merged, as Luanti does: what is passed is set, the rest kept
	o.clouds_params = o.clouds_params or {}
	for k, v in pairs(params) do
		o.clouds_params[k] = v
	end
	send_sky(o)
end

-- Luanti's set_sun, set_moon and set_stars. What reaches the sky here is
-- whether each is there and how big it is; the rest is kept so that a mod
-- reads back what it set.
--
-- simplified: tonemap and sunrise are kept and not drawn. The game's own
-- picture of a sun or a moon **is** drawn -- see [SKY_LEFTOVERS] -- and this
-- note used to say it was not; what is still missing is the sunrise band
-- (sunrisebg.png) and the tonemaps, which this sky has nowhere to put.
local function sky_thing_setter(field)
	return function(self, params)
		local o = state_of(self)
		if not o or type(params) ~= "table" then
			return
		end
		-- Luanti's own rule: what is passed is set and what is not keeps
		-- its value. Replacing the table let a mod's set_moon({texture =
		-- ...}) -- mcl_moon, every phase -- bring back a moon the fixture
		-- had set invisible, which then hung in the reference pictures as
		-- a grey square by day and a white one at 02:00 ([LOD_LIGHT]'s
		-- finding: not the far chunks, the moon behind the far trees).
		o[field] = o[field] or {}
		for k, v in pairs(params) do
			o[field][k] = v
		end
		send_sky(o)
	end
end

PlayerRef.set_sun = sky_thing_setter("sun_params")
PlayerRef.set_moon = sky_thing_setter("moon_params")
PlayerRef.set_stars = sky_thing_setter("star_params")

-- Luanti's own defaults, which is what a mod that never set one reads
function PlayerRef:get_sun()
	local o = state_of(self)
	local t = (o and o.sun_params) or {}
	return {visible = t.visible ~= false,
			texture = t.texture or "sun.png",
			tonemap = t.tonemap or "sun_tonemap.png",
			sunrise = t.sunrise or "sunrisebg.png",
			sunrise_visible = t.sunrise_visible ~= false,
			scale = t.scale or 1}
end

function PlayerRef:get_moon()
	local o = state_of(self)
	local t = (o and o.moon_params) or {}
	return {visible = t.visible ~= false,
			texture = t.texture or "moon.png",
			tonemap = t.tonemap or "moon_tonemap.png",
			scale = t.scale or 1}
end

function PlayerRef:get_stars()
	local o = state_of(self)
	local t = (o and o.star_params) or {}
	return {visible = t.visible ~= false,
			count = t.count or 1000,
			star_color = t.star_color or "#ebebff69",
			scale = t.scale or 1,
			day_opacity = t.day_opacity or 0}
end

function PlayerRef:get_clouds()
	local o = state_of(self)
	local c = (o and o.clouds_params) or {}
	return {density = c.density or 0.4, color = c.color or "#fff0f0e5",
			ambient = c.ambient or "#000000", height = c.height or 120,
			thickness = c.thickness or 16,
			speed = c.speed or {x = 0, z = -2}}
end

--
-- The HUD a game draws itself
--
-- Luanti's HUD is a list of elements per player -- an image, a line of
-- text, a bar of icons -- that the server adds, changes and takes away, and
-- a set of flags saying which of the client's own the game wants drawn.
-- What goes over the wire here is the element as a flat list of strings,
-- under the names Luanti's own HUDADD carries rather than the ones a mod
-- writes: pos, align, dir and the rest. The client half keeps them and
-- whoever is drawing draws them.

local HUD_FLAG = {
	hotbar = 1, healthbar = 2, crosshair = 4, wielditem = 8, breathbar = 16,
	minimap = 32, minimap_radar = 64, basic_debug = 128, chat = 256,
}
local HUD_FLAGS_ALL = 511

local function v2_string(v)
	if type(v) ~= "table" then
		return nil
	end
	return tostring(v.x or 0) .. "," .. tostring(v.y or 0)
end

local function v3_string(v)
	if type(v) ~= "table" then
		return nil
	end
	return tostring(v.x or 0) .. "," .. tostring(v.y or 0) .. "," ..
			tostring(v.z or 0)
end

-- A mod's element as the names the wire carries; nil is left out
local function hud_fields(def)
	local kind = tostring(def.type or def.hud_elem_type or "text")
	-- A waypoint keeps its precision in the item field, which is what
	-- Luanti's own read_hud_element does with it: item is precision plus
	-- one, and an item of zero means ten
	local item = def.item
	if kind == "waypoint" and def.precision ~= nil then
		item = (tonumber(def.precision) or 0) + 1
	end
	return {
		type = kind,
		pos = v2_string(def.position),
		name = def.name and tostring(def.name) or nil,
		scale = v2_string(def.scale),
		text = def.text and tostring(def.text) or nil,
		text2 = def.text2 and tostring(def.text2) or nil,
		number = def.number and tostring(def.number) or nil,
		item = item and tostring(item) or nil,
		dir = def.direction and tostring(def.direction) or nil,
		align = v2_string(def.alignment),
		offset = v2_string(def.offset),
		world_pos = v3_string(def.world_pos),
		size = v2_string(def.size),
		z_index = def.z_index and tostring(def.z_index) or nil,
		style = def.style and tostring(def.style) or nil,
	}
end

-- What a game said the light should be whatever the hour, or nothing
local function send_day_night(o)
	if o and o.player_name and __luanti_send_day_night then
		__luanti_send_day_night(o.player_name,
				o.day_night_ratio and tostring(o.day_night_ratio) or "")
	end
end

send_hud = function(o, flat)
	if o and o.player_name and __luanti_send_hud then
		__luanti_send_hud(o.player_name, flat)
	end
end

-- The hotbar is the client's own and not one of the elements, so it travels
-- as one line of its own rather than through hud_add()
send_hotbar = function(o)
	send_hud(o, {"hotbar", tostring(o.hotbar or 8),
			tostring(o.hotbar_image or ""),
			tostring(o.hotbar_selected_image or "")})
end

-- What a client that arrives is told: every element the game had already
-- added for this player, and the flags
local function send_whole_hud(o)
	if not o then
		return
	end
	send_hud(o, {"clear"})
	for id, def in pairs(o.hud or {}) do
		local flat = {"add", tostring(id)}
		for k, v in pairs(hud_fields(def)) do
			flat[#flat + 1] = k
			flat[#flat + 1] = v
		end
		send_hud(o, flat)
	end
	send_hud(o, {"flags", tostring(o.hud_flags or HUD_FLAGS_ALL)})
	send_hotbar(o)
end

function PlayerRef:hud_add(def)
	local o = state_of(self)
	if not o or type(def) ~= "table" then
		return nil
	end
	o.hud = o.hud or {}
	o.hud_next = (o.hud_next or 0) + 1
	local id = o.hud_next
	o.hud[id] = table.copy(def)
	local flat = {"add", tostring(id)}
	for k, v in pairs(hud_fields(def)) do
		flat[#flat + 1] = k
		flat[#flat + 1] = v
	end
	send_hud(o, flat)
	return id
end

function PlayerRef:hud_remove(id)
	local o = state_of(self)
	if not o or o.hud == nil or o.hud[id] == nil then
		return
	end
	o.hud[id] = nil
	send_hud(o, {"remove", tostring(id)})
end

-- Luanti's own: every element by id, as the definitions a mod gave
function PlayerRef:hud_get_all()
	local o = state_of(self)
	local out = {}
	for id, def in pairs((o and o.hud) or {}) do
		out[id] = table.copy(def)
	end
	return out
end

function PlayerRef:hud_change(id, stat, value)
	local o = state_of(self)
	local def = o and o.hud and o.hud[id]
	if not def then
		return nil
	end
	-- A mod names the field the way it wrote it in the definition, and the
	-- wire carries Luanti's own name for it
	local WIRE = {position = "pos", alignment = "align", direction = "dir",
			hud_elem_type = "type"}
	def[stat] = value
	local key = WIRE[stat] or stat
	local fields = hud_fields(def)
	local v = fields[key]
	if v == nil then
		return nil
	end
	send_hud(o, {"change", tostring(id), key, v})
	return id
end

function PlayerRef:hud_get(id)
	local o = state_of(self)
	return o and o.hud and o.hud[id] or nil
end

function PlayerRef:hud_set_flags(flags)
	local o = state_of(self)
	if not o or type(flags) ~= "table" then
		return
	end
	local value = o.hud_flags or HUD_FLAGS_ALL
	for name, bit in pairs(HUD_FLAG) do
		if flags[name] ~= nil then
			local has = math.floor(value / bit) % 2 == 1
			if flags[name] and not has then
				value = value + bit
			elseif not flags[name] and has then
				value = value - bit
			end
		end
	end
	o.hud_flags = value
	core.log("action", "hud_set_flags " .. o.player_name .. " -> " .. value)
	send_hud(o, {"flags", tostring(value)})
	player_event(o, "hud_changed")
end

function PlayerRef:hud_get_flags()
	local o = state_of(self)
	local value = (o and o.hud_flags) or HUD_FLAGS_ALL
	local out = {}
	for name, bit in pairs(HUD_FLAG) do
		out[name] = math.floor(value / bit) % 2 == 1
	end
	return out
end
function PlayerRef:get_lighting() return {shadows = {intensity = 0}} end
-- How much of the day's light the player gets whatever the hour: Luanti's
-- own way for a game to say "this place is always dark" or "always bright",
-- and nil gives the clock back. What it moves is the light, not the sun --
-- the sun goes where the time says either way, which is what Luanti does.
function PlayerRef:override_day_night_ratio(ratio)
	local o = state_of(self)
	if not o then
		return
	end
	if ratio == nil then
		o.day_night_ratio = nil
	else
		o.day_night_ratio = math.max(0, math.min(1, tonumber(ratio) or 1))
	end
	send_day_night(o)
end

function PlayerRef:get_day_night_ratio()
	local o = state_of(self)
	return o and o.day_night_ratio or nil
end
-- How wide the view is and where the eyes are, which are the client's to
-- draw and the game's to decide: a scope narrows the field of view, a
-- vehicle moves the eyes. Both go over as luanti:camera, the whole of it
-- each time, the way the physics override does.
--
-- simplified: the transition time is carried and not used -- the client
-- changes the field of view at once. Luanti eases it over that many
-- seconds; the upgrade path is the client easing it, since the number is
-- already there.
-- The modes the player left on in this world, back to their client on
-- join ([FLY_STATE_SAVE]); it says each toggle as fields of MODES_FORM
local MODES_FORM = "__buildat:modes"
local function send_modes(o)
	if not (o and o.player_name and __luanti_send_modes) then
		return
	end
	local list = {}
	for m in string.gmatch(o.meta:get_string("buildat:modes"), "[^,]+") do
		list[#list + 1] = m
	end
	__luanti_send_modes(o.player_name, list)
end

local function send_camera(o)
	if not (o and o.player_name and __luanti_send_camera) then
		return
	end
	local eye = o.eye_offset or {x = 0, y = 0, z = 0}
	__luanti_send_camera(o.player_name, {
		tostring(tonumber(o.fov) or 0),
		o.fov_is_multiplier and "1" or "0",
		tostring(tonumber(o.fov_transition) or 0),
		tostring(tonumber(eye.x) or 0),
		tostring(tonumber(eye.y) or 0),
		tostring(tonumber(eye.z) or 0),
		-- The seventh: which camera modes the player may reach
		-- ([THIRD_PERSON]); "any" unless a game said
		(o.camera and o.camera.mode) or "any",
	})
end

-- set_camera({mode = "any" | "first" | "third" | "third_front"}) and
-- get_camera(): Luanti's TOCLIENT_CAMERA, the restriction on what the
-- camera key may cycle to ([THIRD_PERSON])
function PlayerRef:set_camera(params)
	local o = state_of(self)
	if not o or type(params) ~= "table" then
		return
	end
	o.camera = o.camera or {}
	if params.mode ~= nil then
		o.camera.mode = tostring(params.mode)
	end
	send_camera(o)
end

function PlayerRef:get_camera()
	local o = state_of(self)
	return {mode = (o and o.camera and o.camera.mode) or "any"}
end

-- fov 0 is "the client's own"; is_multiplier makes it a factor of that
-- rather than degrees, which is how a game writes a zoom that does not have
-- to know what the player set.
function PlayerRef:set_fov(fov, is_multiplier, transition_time)
	local o = state_of(self)
	if not o then
		return
	end
	o.fov = tonumber(fov) or 0
	o.fov_is_multiplier = is_multiplier and true or false
	o.fov_transition = tonumber(transition_time) or 0
	send_camera(o)
end

function PlayerRef:get_fov()
	local o = state_of(self)
	if not o then
		return 0, false, 0
	end
	return o.fov or 0, o.fov_is_multiplier or false, o.fov_transition or 0
end

-- simplified: the first-person offset is the one that is used, because the
-- launcher draws a first-person view and nothing else. The other two are
-- kept so that a mod reads back what it set.
function PlayerRef:set_eye_offset(firstperson, thirdperson, thirdperson_front)
	local o = state_of(self)
	if not o then
		return
	end
	o.eye_offset = vec(firstperson or {x = 0, y = 0, z = 0})
	o.eye_offset_third = vec(thirdperson or {x = 0, y = 0, z = 0})
	o.eye_offset_third_front = vec(thirdperson_front or
			{x = 0, y = 0, z = 0})
	send_camera(o)
end

function PlayerRef:get_eye_offset()
	local o = state_of(self)
	if not o then
		return {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}
	end
	return out_vec(o.eye_offset or {x = 0, y = 0, z = 0}),
			out_vec(o.eye_offset_third or {x = 0, y = 0, z = 0}),
			out_vec(o.eye_offset_third_front or {x = 0, y = 0, z = 0})
end

return MODES_FORM, send_camera, send_day_night, send_modes, send_sky, send_whole_hud,
		send_hud, send_hotbar
-- vim: set noet ts=4 sw=4:
