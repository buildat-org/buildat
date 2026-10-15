-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- The particles a game spawns
--
-- core.add_particle(), core.add_particlespawner() and
-- core.delete_particlespawner(). What reaches the client is a flat record on
-- the luanti:particles channel and the client makes an Urho3D
-- ParticleEmitter of it; the shape is this module's own, because there is no
-- wire here to be compatible with.
--
-- The records, by index:
--
--   "spawner" id texture amount time vertical attached
--       posmin(3) posmax(3) velmin(3) velmax(3) accmin(3) accmax(3)
--       expmin expmax sizemin sizemax
--       anim_type aspect_w aspect_h length frames_w frames_h
--       glow collisiondetection collision_removal
--   "particle" 0 texture 1 0 vertical attached
--       pos(3) pos(3) vel(3) vel(3) acc(3) acc(3)
--       exptime exptime size size
--       anim_type aspect_w aspect_h length frames_w frames_h
--       glow collisiondetection collision_removal
--   "delete" id
--
-- A single particle is a spawner of one that fires once, so the two share
-- their layout and the client has one reader.
--
-- simplified, and each one is what Luanti added after 5.6: no tweens -- a
-- range that changes over the spawner's life is drawn as the range it
-- started with -- and none of radius, drag, jitter, bounce or attract. The
-- deprecated positional form of add_particlespawner() is not taken either;
-- every game written this decade passes the table.

local function number_or(v, default)
	local n = tonumber(v)
	return n or default
end

-- A vector from what a game wrote: a table with x,y,z or 1,2,3 in it, or one
-- number for all three, which is what Luanti's own readers take
local function to_v3(v, default)
	if type(v) == "table" then
		return {number_or(v.x or v[1], default),
				number_or(v.y or v[2], default),
				number_or(v.z or v[3], default)}
	end
	local n = tonumber(v)
	if n then
		return {n, n, n}
	end
	return {default, default, default}
end

-- The range a field covers, under either of the two names Luanti has for it:
-- minpos/maxpos, or pos = {min =, max =} -- and a plain value for a range
-- that is one value wide
local function range_v3(def, name, default)
	local v = def[name]
	if type(v) == "table" and (v.min ~= nil or v.max ~= nil) then
		return to_v3(v.min, default), to_v3(v.max, default)
	end
	if v ~= nil then
		local one = to_v3(v, default)
		return one, one
	end
	return to_v3(def["min" .. name], default), to_v3(def["max" .. name],
			default)
end

local function range_number(def, name, default)
	local v = def[name]
	if type(v) == "table" then
		return number_or(v.min, default), number_or(v.max, default)
	end
	local n = tonumber(v)
	if n then
		return n, n
	end
	return number_or(def["min" .. name], default),
			number_or(def["max" .. name], default)
end

-- Luanti's two kinds of animated texture, as the numbers the client reads:
-- a vertical strip, and a sheet counted left to right and then down
local function animation_fields(animation)
	if type(animation) ~= "table" then
		return {"0", "1", "1", "0", "1", "1"}
	end
	if animation.type == "vertical_frames" then
		return {"1", tostring(number_or(animation.aspect_w, 16)),
				tostring(number_or(animation.aspect_h, 16)),
				tostring(number_or(animation.length, 1)), "1", "1"}
	end
	if animation.type == "sheet_2d" then
		return {"2", "1", "1",
				tostring(number_or(animation.frame_length, 0.1)),
				tostring(number_or(animation.frames_w, 1)),
				tostring(number_or(animation.frames_h, 1))}
	end
	return {"0", "1", "1", "0", "1", "1"}
end

-- A texture is a name, or a table with the name in it and the tween fields
-- around it that are not read here
local function texture_name(def)
	local t = def.texture
	if type(t) == "table" then
		t = t.name
	end
	if type(t) ~= "string" then
		return ""
	end
	return t
end

local function listeners(def)
	local to = def.playername
	if type(to) == "string" and to ~= "" then
		return {to}
	end
	local out = {}
	for _, player in ipairs(core.get_connected_players()) do
		out[#out + 1] = player:get_player_name()
	end
	return out
end

-- self_name is the player the spawner is attached to, if it is attached to a
-- player at all: their own object is not one their client draws, so what it
-- is told instead is "self" and it uses where its own eyes are. Everyone
-- else gets the object id, and follows it the way they follow any other
-- object.
local function send(names, flat, self_name)
	if __luanti_send_particles == nil then
		return
	end
	for _, name in ipairs(names) do
		if name == self_name then
			local mine = {}
			for i, v in ipairs(flat) do
				mine[i] = v
			end
			mine[7] = "self"
			__luanti_send_particles(name, mine)
		else
			__luanti_send_particles(name, flat)
		end
	end
end

-- The name of the player a spawner is attached to, or nil
local function attached_player(def)
	local o = def.attached
	if type(o) == "table" and o.is_player and o:is_player() then
		return o:get_player_name()
	end
	return nil
end

local function append(flat, values)
	for _, v in ipairs(values) do
		flat[#flat + 1] = tostring(v)
	end
end

local function spawner_record(kind, id, def, pos_min, pos_max, vel_min,
		vel_max, acc_min, acc_max, exp_min, exp_max, size_min, size_max)
	local attached = 0
	if type(def.attached) == "table" then
		attached = tonumber(core.__ref_id(def.attached)) or 0
	end
	local flat = {kind, tostring(id), texture_name(def),
			tostring(math.floor(number_or(def.amount, 1))),
			tostring(number_or(def.time, 0)),
			def.vertical and "1" or "0", tostring(attached)}
	append(flat, pos_min)
	append(flat, pos_max)
	append(flat, vel_min)
	append(flat, vel_max)
	append(flat, acc_min)
	append(flat, acc_max)
	append(flat, {exp_min, exp_max, size_min, size_max})
	append(flat, animation_fields(def.animation))
	-- The light it is raised to (0..14) and what it does at a node
	append(flat, {math.max(0, math.min(14, math.floor(number_or(def.glow, 0)))),
			def.collisiondetection and "1" or "0",
			def.collision_removal and "1" or "0"})
	return flat
end

local next_spawner = 1
-- id -> who was told, so that a delete reaches the same clients
local spawners = {}

function core.add_particlespawner(def)
	if type(def) ~= "table" then
		return nil
	end
	if type(def.pos) == "table" and def.pos.y ~= nil then
		def.pos = core.__region_to_world_pos(def.pos)
	end
	if type(def.minpos) == "table" then
		def.minpos = core.__region_to_world_pos(def.minpos)
	end
	if type(def.maxpos) == "table" then
		def.maxpos = core.__region_to_world_pos(def.maxpos)
	end
	local pos_min, pos_max = range_v3(def, "pos", 0)
	local vel_min, vel_max = range_v3(def, "vel", 0)
	local acc_min, acc_max = range_v3(def, "acc", 0)
	local exp_min, exp_max = range_number(def, "exptime", 1)
	local size_min, size_max = range_number(def, "size", 1)
	local id = next_spawner
	next_spawner = next_spawner + 1
	local names = listeners(def)
	send(names, spawner_record("spawner", id, def, pos_min, pos_max, vel_min,
			vel_max, acc_min, acc_max, exp_min, exp_max, size_min, size_max),
			attached_player(def))
	spawners[id] = names
	return id
end

function core.delete_particlespawner(id, player)
	id = tonumber(id)
	local names = id and spawners[id] or nil
	if names == nil then
		return
	end
	spawners[id] = nil
	-- A delete for one player only still takes the spawner away here: a
	-- spawner is one player's or everyone's, and Luanti's own second
	-- argument is for the everyone case
	if type(player) == "string" and player ~= "" then
		names = {player}
	end
	send(names, {"delete", tostring(id)})
end

function core.add_particle(def)
	if type(def) ~= "table" then
		return
	end
	-- A body's region position is where the body is ([BODY_INTERACT])
	local pos = to_v3(core.__region_to_world_pos(def.pos), 0)
	local vel = to_v3(def.velocity or def.vel, 0)
	local acc = to_v3(def.acceleration or def.acc, 0)
	local exptime = number_or(def.expirationtime, 1)
	local size = number_or(def.size, 1)
	send(listeners(def), spawner_record("particle", 0, {
		texture = def.texture,
		amount = 1,
		time = 0,
		vertical = def.vertical,
		attached = def.attached,
		animation = def.animation,
		glow = def.glow,
		collisiondetection = def.collisiondetection,
		collision_removal = def.collision_removal,
	}, pos, pos, vel, vel, acc, acc, exptime, exptime, size, size))
end
