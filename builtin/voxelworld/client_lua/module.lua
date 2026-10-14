-- Buildat: builtin/voxelworld/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("voxelworld")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local cereal = require("buildat/extension/cereal")
local dump = buildat.dump
local M = {}
log:info("voxelworld loading")

-- Set by the game before the camera is set, if the defaults do not suit it.
-- LOD is off unless asked for ([API_DEFAULTS_07]): past lod_distance a chunk
-- is meshed from a downsampled volume, which loses shaped voxels and the
-- translucent and masked materials, so a game sets a number (infidigger's
-- 80) when it wants that trade. A scene with no player wants
-- physics_distance small so no collision shapes are built at all.
M.lod_distance = math.huge
M.physics_distance = 100
-- How much world this client wants sent to it, in voxels. Only the client
-- knows what its computer can draw, and what it is not going to draw is the
-- server's memory and this connection's bandwidth spent on nothing. The
-- server sends the smaller of this and what it keeps loaded, so asking for
-- more than the game has is not an error. Set it before the world arrives.
M.send_distance = 1000
-- Whether the world may be sent yet ([TEXMOD_RACE]). It may by default;
-- a game that composes textures before a chunk should mesh holds it back
-- at load (voxelworld.hold_streaming()) and allows it once they are there
-- (builtin/luanti). While held the client asks for nothing (a send
-- distance of nought), so no chunk is meshed before its textures are --
-- a chunk that wants a texture modifier not yet composed is not drawn.
M.streaming_allowed = true
local init_seen = false
-- Held back by a game not yet ready for the world (luanti until its
-- texture modifiers are composed); call before voxelworld:init arrives
function M.hold_streaming()
	M.streaming_allowed = false
end
function M.allow_streaming()
	if M.streaming_allowed then
		return
	end
	M.streaming_allowed = true
	if init_seen then
		buildat.send_packet("voxelworld:set_send_distance",
				tostring(math.floor(M.send_distance)))
	end
end

-- The distance changed by the game (a viewing range setting): sent at
-- once when the world is already being sent, else when it may be
function M.set_send_distance(n)
	M.send_distance = n
	if init_seen and M.streaming_allowed then
		buildat.send_packet("voxelworld:set_send_distance",
				tostring(math.floor(M.send_distance)))
	end
end

local stuck_checked_us, stuck_undrawn, stuck_seconds, stuck_said = 0, -1, 0, false
local stuck_pops = {n = 0, distinct = 0, seen = {}}
local UPDATE_TIME_FRACTION = 0.10
local MESH_BUDGET_CAP_US = 15000
-- And a floor: a tenth of the last frame is half a millisecond on an idle
-- client at 200 fps, one mesh a frame at most, and the faster the client
-- the less it meshed a second -- a reference shot at range 200 had 2300
-- chunks queued at 14 a second and its 90 s ran out ([MISSING_CHUNK]'s
-- "never drew", 2026-09-21). Five milliseconds a frame keeps 60 fps.
local MESH_BUDGET_FLOOR_US = 5000

local LOD_THRESHOLD = 0.2
-- How the update queue orders what it has: it sorts by distance divided by
-- these, so a bigger one is a chunk that goes first.
--
-- Raising the modified ones to a hundred -- which puts a changed chunk in
-- front of any new one that is not a hundred times closer -- was tried on
-- 2026-09-14 against a dug voxel that stays drawn, and changed nothing
-- measurable. Whatever that fault is, it is not the order of this queue.
local INITIAL_PHYSICS_NEAR_WEIGHT = 1.0
local MODIFIED_PHYSICS_NEAR_WEIGHT = 1.0

local INITIAL_GEOMETRY_NEAR_WEIGHT = 0.15
local MODIFIED_GEOMETRY_NEAR_WEIGHT = 1.0

local MAX_LOD = 4

-- A chunk that is not in the scene yet is only missing for now: the section
-- may still be streaming in. Anything that asks about it (a game reading
-- voxels ahead of itself, say) would otherwise get nil for the rest of the
-- session.
local NEGATIVE_CACHE_US = 200000

local camera_node = nil
local update_counter = -1

local camera_p = magic.Vector3(0, 0, 0)
local camera_dir = magic.Vector3(0, 0, 0)

local camera_last_p = camera_p
local camera_last_dir = camera_dir

local end_of_update_processing_us = 0

local voxel_reg = buildat.createVoxelRegistry()
local atlas_reg = buildat.createAtlasRegistry()

-- Opt-in per world: shade static chunk geometry by the skylight the server
-- stored in the voxel data. Off by default; a world that does not fill those
-- bits (and any dynamic voxel node) would come out uniformly dark.
M.use_skylight = false

-- **One chunk's mesh is one call, and a budget cannot slice it**
-- ([CLIENT_FRAME], 2026-09-26). The loop that spends the mesh budget
-- reads its deadline between chunks, so a call over the budget takes
-- what it takes. And the call is not only the queueing: the task's
-- constructor deserialises the volume and preloads its textures **on
-- this thread, on purpose** (mesh.cpp says so: "so that the calling
-- code can measure how long its execution takes"), which is where an
-- atlas segment for a voxel seen for the first time gets built.
--
-- Measured on a join into an already-made VoxeLibre world: the first
-- chunk 858 to 1265 ms, the next five 70 to 160 each, and then 5 to 33
-- ms a chunk for the rest of the session. Asking the registry once per
-- distinct voxel instead of once per sample (39 thousand of them a
-- chunk) was tried and changed nothing either way, so what costs is the
-- atlas work itself and not the lookups around it.
--
-- This line is what makes that visible without a debug run, the way
-- "slow packet" does for the network.
local SLOW_MESH_US = 25000
local slow_mesh_said = 0
local function note_slow_mesh(node, t1, data_n, lod)
	local took = buildat.get_time_us() - t1
	if took < SLOW_MESH_US or slow_mesh_said >= 16 then
		return
	end
	slow_mesh_said = slow_mesh_said + 1
	log:info(string.format("mesh: node %d lod %d took %.0f ms",
			node:GetID(), lod, took / 1000))
end
M.chunk_size_voxels = nil
-- Whether the mesher is handed a horizon map with each chunk, which also
-- packs the vertex alpha (see interface/mesh.h and voxel_shading's
-- set_packed_sky()); a game turns it on when its shader reads it
M.horizon = false
-- Microseconds this module spent since the caller last zeroed these: the
-- mesh commit (buildat.set_voxel_geometry and the LOD one) and the
-- horizon map's build and merge. The frame peak reads and zeroes them once
-- a frame ([FRAME_PEAK]); accumulated rather than reset here, since the
-- horizon work also runs from replicate's events outside the update.
-- `update` is the whole of this module's own Update handler, of which
-- the three above are parts: without it the frame peak could name only
-- the meshing inside it and the rest of the handler -- the queue walk,
-- the node updates, the LOD passes -- fell into "rest" with Urho3D's
-- own frame ([FRAME_PEAK], 2026-09-26: a settled client's every peak
-- read "rest", and this block was the largest single thing in it at
-- 7.3 ms of a 33 ms frame).
M.frame_us = {mesh = 0, horizon = 0, physics = 0, update = 0}
M.section_size_chunks = nil
M.section_size_voxels = nil
-- Start higher than any conceivable value because otherwise things will never
-- be triggered to reflect this value
M.camera_far_clip = 1000

-- client-side voxelworld is ready once the server tells it is
local is_ready = false
local on_ready_callbacks = {}

local geometry_update_cbs = {} -- function(node)
-- Called after a chunk's materials exist, so that a game can put its own
-- technique, cube maps and shader parameters on them
local material_update_cbs = {} -- function(node)

-- TODO: Implement unload by timeout
local node_volume_cache = {} -- {node_id: {volume:, last_access_us:}}
-- Set up by sub_events(), which is what runs once the world is there
local node_update_queue = nil
-- Where the queue measures from (the camera), for undrawn_around()
local queue_p = nil
-- node id -> {before =, after =}: the voxel data a predicted write
-- replaced and what it wrote, until the server answers; see
-- M.set_static_voxel()
local predicted = {}
-- Defined further down, next to remesh_all(), and used before that
local queue_modified_node_update

-- When a chunk that *changed* was queued, so that the wait until it is drawn
-- again can be said out loud. A dug voxel that is still drawn is the fault
-- this is about, and the number nobody had was how long the remesh waited;
-- see section 3 of doc/plan/master_plan.md. Declared up here because the
-- loop that reads it is written before the function that writes it.
local modified_queued_us = {}
-- When a chunk that changed was last drawn again, and the ones held back
-- because that was under a second ago (node id -> when they are due): a
-- flood's passes change the same chunks four times a second, and each
-- change re-meshed each chunk ([FLOOD_STEP] c). One mesh per chunk per
-- second while that goes on; a client's own predicted write is prompt
-- (set_static_voxel), as its dig should look.
local modified_drawn_us = {}
local modified_held = {}
local MODIFIED_COALESCE_US = 1000000
-- **And nothing the player is standing next to is ever held** (user,
-- 2026-09-26: "delayed lighting updates feel awful to the user as
-- response to the user's interactions; postponing them is a viable
-- method only when they're tens of voxels away from the player"). The
-- window above was applied to every chunk alike, so a dig in a chunk
-- that had been drawn within the second waited up to a second to
-- appear -- the client's own prediction included. Holding is a
-- distance rule now: inside this many voxels of the camera a change is
-- drawn as soon as the budget lets it, and beyond it the window still
-- coalesces the churn a world makes of itself.
local MODIFIED_PROMPT_D = 48
-- And which of those have been complained about, so that one that is never
-- drawn again says so once rather than every frame
local modified_warned = {}

-- NOTE: node can be nil, meaning that it was cached to be nil
local static_node_cache = {} -- {z: {y: {x: {node:, fetched:}}}} (chunk_p)
-- Chunk node id -> its geometry has been built at least once; see
-- M.is_chunk_drawn()
local geometry_done = {}

function on_ready()
	if is_ready then
		error("on_ready(): already ready")
	end
	is_ready = true
	for _, v in ipairs(on_ready_callbacks) do
		v()
	end
	on_ready_callbacks = nil
end

buildat.sub_packet("voxelworld:init", function(data)
	local values = cereal.binary_input(data, {"object",
		{"chunk_size_voxels", {"object",
			{"x", "int16_t"},
			{"y", "int16_t"},
			{"z", "int16_t"},
		}},
		{"section_size_chunks", {"object",
			{"x", "int16_t"},
			{"y", "int16_t"},
			{"z", "int16_t"},
		}},
	})
	log:info("voxelworld:init: "..dump(values))
	M.chunk_size_voxels = buildat.Vector3(values.chunk_size_voxels)
	M.section_size_chunks = buildat.Vector3(values.section_size_chunks)
	M.section_size_voxels =
			M.chunk_size_voxels:mul_components(M.section_size_chunks)

	-- Clear caches
	node_volume_cache = {}
	static_node_cache = {}

	-- What this client wants sent to it; see M.send_distance -- and
	-- nothing until the game says it may ([TEXMOD_RACE])
	init_seen = true
	buildat.send_packet("voxelworld:set_send_distance",
			M.streaming_allowed and tostring(math.floor(M.send_distance)) or "0")
end)

-- [REGISTRY_FILE] The registry from the file the server serves, by the
-- server's run_script: at join, ahead of voxelworld:ready, and again when
-- it changes. The script runs once the file is in.
function M.registry_from_file()
	local t0 = buildat.get_time_us()
	local data = buildat.get_file_content("voxelworld/voxel_registry.bin")
	local t1 = buildat.get_time_us()
	voxel_reg:deserialize(data)
	log:info(string.format("the voxel registry from the served file, %d bytes"..
			" (read %d ms, deserialized %d ms)", #data,
			math.floor((t1 - t0) / 1000),
			math.floor((buildat.get_time_us() - t1) / 1000)))
end

buildat.sub_packet("voxelworld:ready", function(data)
	sub_events()
	on_ready()
end)

-- The terrain's horizon around each chunk, for the mesher's sky share
-- ([PBR_FIT] 2c, the terrain scale). Per chunk column (x, z in chunks):
-- the heights of each chunk in it, out of buildat.column_heights(), and
-- their merged world-y maximum as a string of 32x32 int16 the map is cut
-- from. A column whose maximum moves -- a chunk arriving, a dig or a place
-- that moves a top -- dirties the 3x3 chunk columns around it, and a
-- flush a second later re-meshes the chunks in them that have geometry.
-- Only for chunks of 32: the map is three chunks a side.
local HORIZON_CHUNK = 32
local HORIZON_SIZE = 96
local HORIZON_NONE = -32768
local HORIZON_FLUSH_US = 5000000
local horizon_cols = {}   -- "x,z" -> {chunks = {cy = local string}, merged = string or nil, changed_us}
local horizon_dirty = {}  -- "x,z" -> time_us the column last moved
local horizon_meshed_us = {}  -- node id -> time_us its geometry was last made
local horizon_none_row = nil

local function horizon_key(cx, cz)
	return cx .. "," .. cz
end

local function int16_char(v)
	if v < 0 then v = v + 65536 end
	return string.char(v % 256, math.floor(v / 256) % 256)
end

local function int16_at(str, i)   -- 0-based entry
	local lo, hi = string.byte(str, i * 2 + 1, i * 2 + 2)
	local v = lo + hi * 256
	if v >= 32768 then v = v - 65536 end
	return v
end

local function horizon_merge(col)
	local out = {}
	local n = HORIZON_CHUNK * HORIZON_CHUNK
	for i = 0, n - 1 do
		local best = HORIZON_NONE
		for cy, str in pairs(col.chunks) do
			local h = int16_at(str, i)
			if h ~= HORIZON_NONE then
				local w = cy * HORIZON_CHUNK + h
				if w > best then best = w end
			end
		end
		out[i + 1] = int16_char(best)
	end
	return table.concat(out)
end

-- A chunk's heights have arrived or changed
local function horizon_note_chunk(chunk_p, heights, moved)
	local key = horizon_key(chunk_p.x, chunk_p.z)
	local col = horizon_cols[key]
	if not col then
		col = {chunks = {}}
		horizon_cols[key] = col
	end
	if col.chunks[chunk_p.y] == heights then
		return
	end
	col.chunks[chunk_p.y] = heights
	local merged = horizon_merge(col)
	if merged == col.merged then
		return
	end
	col.merged = merged
	-- The columns this one is in the map of, marked with when it moved;
	-- the flush re-meshes only what was meshed before that, once. Only
	-- for a change to a chunk that was here already -- a dig or a place
	-- that moves a top -- and not for a chunk arriving: a world loading
	-- arrives faster than it meshes, so a chunk is meshed with its
	-- neighbours already in its map, and re-meshing every chunk for
	-- each arriving neighbour starved the far ones out of the frame.
	if not moved then
		return
	end
	local now = buildat.get_time_us()
	for dz = -1, 1 do
		for dx = -1, 1 do
			horizon_dirty[horizon_key(chunk_p.x + dx, chunk_p.z + dz)] = now
		end
	end
end

local function horizon_forget_chunk(chunk_p)
	local col = horizon_cols[horizon_key(chunk_p.x, chunk_p.z)]
	if col and col.chunks[chunk_p.y] then
		col.chunks[chunk_p.y] = nil
		col.merged = horizon_merge(col)
	end
end

-- The map for a chunk: origin, then 96 rows of 96 int16 out of the 3x3
-- chunk columns' merged heights, HORIZON_NONE where a column is unknown
local function horizon_map_for(chunk_p)
	if not horizon_none_row then
		horizon_none_row = string.rep(int16_char(HORIZON_NONE), HORIZON_CHUNK)
	end
	local parts = {}
	local ox = (chunk_p.x - 1) * HORIZON_CHUNK
	local oy = chunk_p.y * HORIZON_CHUNK
	local oz = (chunk_p.z - 1) * HORIZON_CHUNK
	local function int32_char(v)
		if v < 0 then v = v + 4294967296 end
		return string.char(v % 256, math.floor(v / 256) % 256,
				math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
	end
	parts[1] = int32_char(ox) .. int32_char(oy) .. int32_char(oz)
	for dz = -1, 1 do
		local cols = {}
		for dx = -1, 1 do
			local col = horizon_cols[horizon_key(chunk_p.x + dx, chunk_p.z + dz)]
			cols[dx + 2] = col and col.merged or nil
		end
		for zz = 0, HORIZON_CHUNK - 1 do
			for dx = 1, 3 do
				local m = cols[dx]
				if m then
					local from = zz * HORIZON_CHUNK * 2 + 1
					parts[#parts + 1] = string.sub(m, from, from + HORIZON_CHUNK * 2 - 1)
				else
					parts[#parts + 1] = horizon_none_row
				end
			end
		end
	end
	-- A map with nothing known is still a map: the mesher packs the alpha
	-- for any map, and a chunk meshed without one -- the far ones, before
	-- their columns arrive -- came out in the plain layout with the
	-- constant bounce, lit like lamps at night
	return table.concat(parts)
end

function sub_events()
	node_update_queue = buildat.SpatialUpdateQueue()

	local function note_horizon(node, moved)
		if not M.horizon or not M.chunk_size_voxels or
				M.chunk_size_voxels.x ~= HORIZON_CHUNK or
				M.chunk_size_voxels.z ~= HORIZON_CHUNK then
			return
		end
		local data = node:GetVar("buildat_voxel_data"):GetBuffer()
		local chunk_p = buildat.Vector3(node:GetWorldPosition()):div_components(
				M.chunk_size_voxels):floor()
		local t0 = buildat.get_time_us()
		horizon_note_chunk(chunk_p, buildat.column_heights(data, voxel_reg),
				moved)
		M.frame_us.horizon = M.frame_us.horizon + buildat.get_time_us() - t0
	end


	local function queue_initial_node_update(node)
		-- A chunk arriving beside the player weighs as a changed one:
		-- at the initial weight its first draw sorted behind the
		-- flood's far changed chunks and the sky chunks two over the
		-- player stayed undrawn for a minute ([WIN_WORLD] c, 2026-09-22)
		local p = node:GetWorldPosition()
		local weight = INITIAL_GEOMETRY_NEAR_WEIGHT
		if M.chunk_size_voxels and (p - camera_p):Length() <
				5 * M.chunk_size_voxels.x then
			weight = MODIFIED_GEOMETRY_NEAR_WEIGHT
		end
		node_update_queue:put(p, weight, M.camera_far_clip * 1.2,
				nil, nil, {
			type = "geometry",
			current_lod = 0,
			node_id = node:GetID(),
		})
		node_update_queue:put(node:GetWorldPosition(),
				INITIAL_PHYSICS_NEAR_WEIGHT, M.physics_distance, nil, nil, {
			type = "physics",
			node_id = node:GetID(),
		})
	end


	buildat.sub_packet("voxelworld:node_volume_updated", function(data)
		local values = cereal.binary_input(data, {"object",
			{"node_id", "int32_t"},
		})
		log:info("voxelworld:node_volume_updated: "..dump(values))
		node_volume_cache[values.node_id] = nil -- Clear cache
		local node = replicate.main_scene:GetNode(values.node_id)
		-- The server's answer to a predicted write ([PREDICTION]): a
		-- chunk it changed comes replicated with its new data, and one it
		-- did not -- the dig or place was refused -- is not replicated at
		-- all, the attribute being what it was. So a chunk still holding
		-- the predicted data goes back to what it held before; a real
		-- change that has not arrived yet overwrites that when it does.
		local pred = node and predicted[values.node_id]
		if pred then
			-- The server's data, or what the chunk held before the
			-- predictions when the server did not replicate (a refusal)
			local data = buildat.get_voxel_data(node)
			if data == pred.after then
				data = pred.before
			end
			-- This answer is the oldest change's; the ones after it are
			-- not in it yet and go back on top ([BOX_PLAYTEST_2] 11)
			table.remove(pred.writes, 1)
			if #pred.writes > 0 then
				local volume = buildat.deserialize_volume(data)
				for _, w in ipairs(pred.writes) do
					volume:set_voxel_at(w[1], w[2], w[3], w[4])
				end
				pred.before = data
				pred.after = volume:serialize()
				buildat.set_voxel_data(node, pred.after)
			else
				predicted[values.node_id] = nil
				if data ~= buildat.get_voxel_data(node) then
					buildat.set_voxel_data(node, data)
				end
			end
		end
		if node and not node:GetVar("buildat_voxel_data"):IsEmpty() then
			note_horizon(node, true)
		end
		-- A chunk the player had predicted a write into is the answer to
		-- something they did, and it goes before the world's own churn
		queue_modified_node_update(node, nil, pred ~= nil)
	end)

	local function update_voxel_geometry(node)
		local data = node:GetVar("buildat_voxel_data"):GetBuffer()

		local node_p = node:GetWorldPosition()
		local d = (node_p - camera_p):Length()
		local lod_fraction = d / M.lod_distance
		local lod = math.floor(1 + lod_fraction)
		if lod > MAX_LOD then lod = MAX_LOD end

		log:debug("update_voxel_geometry(): lod="..lod..
				", d="..math.floor(d)..", #data="..data:GetSize()..
				", node="..node:GetID())

		for _, cb in ipairs(geometry_update_cbs) do
			cb(node)
		end

		local near_trigger_d = nil
		local near_weight = nil
		local far_trigger_d = nil
		local far_weight = nil

		local function set_up_materials()
			for _, cb in ipairs(material_update_cbs) do
				cb(node)
			end
		end

		if d >= M.camera_far_clip * 1.4 then
			log:debug("Clearing voxel geometry outside camera far clip ("
					..M.camera_far_clip..")")
			buildat.clear_voxel_geometry(node)

			-- clip out -> 4
			near_trigger_d = 1.2 * M.camera_far_clip
			near_weight = 0.4
		else
			-- The same map for every LOD: a far chunk meshed without one
			-- kept the constant bounce and the plain alpha layout under a
			-- shader reading the packed one ([LOD_LIGHT])
			local horizon = nil
			local t0 = buildat.get_time_us()
			if M.horizon and M.use_skylight and M.chunk_size_voxels and
					M.chunk_size_voxels.x == HORIZON_CHUNK then
				horizon = horizon_map_for(buildat.Vector3(node_p):div_components(
						M.chunk_size_voxels):floor())
			end
			local t1 = buildat.get_time_us()
			M.frame_us.horizon = M.frame_us.horizon + t1 - t0
			horizon_meshed_us[node:GetID()] = t1
			if lod == 1 then
				-- The chunk's origin, whatever horizon is: a voxel of
				-- uv_scale > 1 repeats across the chunk edges with it
				-- ([VOXEL_GEOMETRY_ORIGIN])
				local origin = nil
				if M.chunk_size_voxels then
					origin = buildat.Vector3(node_p):div_components(
							M.chunk_size_voxels):floor():mul_components(
							M.chunk_size_voxels)
				end
				buildat.set_voxel_geometry(
						node, data, voxel_reg, atlas_reg, M.use_skylight,
						set_up_materials, horizon, origin)
				M.frame_us.mesh = M.frame_us.mesh + buildat.get_time_us() - t1
				note_slow_mesh(node, t1, 0, 1)

				-- 1 -> 2, or clip out when LOD is off
				far_trigger_d = math.min(M.lod_distance * (1.0 + LOD_THRESHOLD),
						M.camera_far_clip * 1.4)
				far_weight = 0.5
			else
				buildat.set_voxel_lod_geometry(lod, node, data, voxel_reg,
						atlas_reg, M.use_skylight, set_up_materials, horizon)
				M.frame_us.mesh = M.frame_us.mesh + buildat.get_time_us() - t1
				note_slow_mesh(node, t1, 0, lod)

				if lod == 1 then
					-- Shouldn't go here
				elseif lod == 2 then
					-- 2 -> 1
					near_trigger_d = M.lod_distance * (1.0 - LOD_THRESHOLD)
					near_weight = 0.75
					-- 2 -> 3
					far_trigger_d = 2 * M.lod_distance * (1.0 + LOD_THRESHOLD)
					far_weight = 0.4
				elseif lod == 3 then
					-- 3 -> 2
					near_trigger_d = 2 * M.lod_distance * (1.0 - LOD_THRESHOLD)
					near_weight = 0.6
					-- 3 -> 4
					far_trigger_d = 3 * M.lod_distance * (1.0 + LOD_THRESHOLD)
					far_weight = 0.4
				elseif lod == 4 then
					-- 4 -> 3
					near_trigger_d = 3 * M.lod_distance * (1.0 - LOD_THRESHOLD)
					near_weight = 0.5
					-- 4 -> clip out
					far_trigger_d = M.camera_far_clip * 1.4
					far_weight = 0.4
				end
			end
		end
		node_update_queue:put(node_p,
				near_weight, near_trigger_d,
				far_weight, far_trigger_d, {
			type = "geometry",
			current_lod = lod,
			node_id = node:GetID(),
		})
	end

	local function update_voxel_physics(node)
		local data = node:GetVar("buildat_voxel_data"):GetBuffer()

		local node_p = node:GetWorldPosition()
		local d = (node_p - camera_p):Length()

		log:debug("update_voxel_physics(): d="..math.floor(d)..
				", #data="..data:GetSize()..", node="..node:GetID())

		local near_trigger_d = nil
		local near_weight = nil
		local far_trigger_d = nil
		local far_weight = nil

		if d > M.physics_distance then
			log:debug("Clearing physics boxes outside physics distance ("..
					M.physics_distance..")")
			buildat.clear_voxel_physics_boxes(node)

			near_trigger_d = M.physics_distance * 0.8
			near_weight = 1.0
		else
			buildat.set_voxel_physics_boxes(node, data, voxel_reg)

			far_trigger_d = M.physics_distance * 1.2
			far_weight = 0.2
		end
		node_update_queue:put(node_p,
				near_weight, near_trigger_d,
				far_weight, far_trigger_d, {
			type = "physics",
			node_id = node:GetID(),
		})
	end

	magic.SubscribeToEvent("Update", function(event_type, event_data)
		buildat.profiler_block_begin("Buildat|voxelworld:update")
		local update_t0 = buildat.get_time_us()

		-- Required for handling device resets (eg. fullscreen toggle)
		atlas_reg:update()

		--local t0 = buildat.get_time_us()
		--local dt = event_data:GetFloat("TimeStep")
		update_counter = update_counter + 1

		if camera_node then
			camera_dir = camera_node.direction
			camera_p = camera_node:GetWorldPosition()
			M.camera_far_clip = camera_node:GetComponent("Camera").farClip
		end

		-- Chunk columns whose horizon moved a while ago: re-mesh the chunks
		-- in them that were meshed before the move, once. A world loading
		-- moves every column as its chunks arrive, and a chunk meshed after
		-- its neighbours arrived already has them in its map; the wait is
		-- what keeps the load from re-meshing each chunk nine times over.
		if next(horizon_dirty) and update_counter % 60 == 0 then
			local now = buildat.get_time_us()
			for key, t in pairs(horizon_dirty) do
				if now - t >= HORIZON_FLUSH_US then
					horizon_dirty[key] = nil
					local cx, cz = key:match("^(-?%d+),(-?%d+)$")
					cx, cz = tonumber(cx), tonumber(cz)
					local ztable = static_node_cache[cz]
					if ztable then
						for _, ytable in pairs(ztable) do
							local c = ytable[cx]
							if c and c.node then
								local id = c.node:GetID()
								local meshed = horizon_meshed_us[id]
								if meshed and meshed < t then
									horizon_meshed_us[id] = now
									queue_modified_node_update(c.node)
								end
							end
						end
					end
				end
			end
		end

		if camera_node and M.section_size_voxels then
			-- TODO: How should position information be sent to the server?
			local p = camera_p
			if update_counter % 60 == 0 then
				local section_p = buildat.Vector3(p):div_components(
						M.section_size_voxels):floor()
				--log:info("p: "..p.x..", "..p.y..", "..p.z.." -> section_p: "..
				--		section_p.x..", "..section_p.y..", "..section_p.z)
				--[[send_get_section(section_p + buildat.Vector3( 0, 0, 0))
				send_get_section(section_p + buildat.Vector3(-1, 0, 0))
				send_get_section(section_p + buildat.Vector3( 1, 0, 0))
				send_get_section(section_p + buildat.Vector3( 0, 1, 0))
				send_get_section(section_p + buildat.Vector3( 0,-1, 0))
				send_get_section(section_p + buildat.Vector3( 0, 0, 1))
				send_get_section(section_p + buildat.Vector3( 0, 0,-1))]]
			end
		end

		-- Node updates: Handle one or a few per frame
		local current_us = buildat.get_time_us()
		-- Spend time doing this proportionate to the rest of the update cycle
		local last_outer_frame_us = (current_us - end_of_update_processing_us)
		-- Capped: a fraction of the last frame with no ceiling let a long
		-- frame buy a long budget, and the join's first frames meshed ten
		-- dense chunks in one frame -- 1.3 s ([FRAME_PEAK]'s mesh row).
		-- The worst frame is now one chunk's mesh over the cap.
		local max_handling_time_us = math.min(math.max(
				last_outer_frame_us * UPDATE_TIME_FRACTION, MESH_BUDGET_FLOOR_US),
				MESH_BUDGET_CAP_US)
		local stop_at_us = current_us + max_handling_time_us

		-- A chunk that changed and has still not been drawn again after two
		-- seconds: said once each, because "never" and "late" are different
		-- faults and only this tells them apart. See section 3 of
		-- doc/plan/master_plan.md.
		-- The held-back changes whose second is up
		for node_id, due_us in pairs(modified_held) do
			if current_us >= due_us then
				modified_held[node_id] = nil
				local node = replicate.main_scene:GetNode(node_id)
				if node then
					queue_modified_node_update(node, true)
				end
			end
		end
		for node_id, queued_us in pairs(modified_queued_us) do
			if not modified_warned[node_id] then
				local waited = (current_us - queued_us) / 1000000
				if waited >= 2.0 then
					modified_warned[node_id] = true
					log:warning(string.format(
							"chunk node %d has not been drawn again after" ..
							" %.1f s, with %d in the queue", node_id, waited,
							node_update_queue:get_length()))
				end
			end
		end

		node_update_queue:set_p(camera_p)
		queue_p = camera_p
		-- Which way they look is part of the order now: what is in front
		-- of them is what they are waiting to see
		node_update_queue:set_dir(camera_dir)
		-- Scale queue update operations according to the handling time of the
		-- rest of the processing
		node_update_queue:update(max_handling_time_us / 50 + 1)

		-- The count of undrawn chunks within 2 of the camera not moving
		-- for two seconds while the queue holds anything names the front
		-- and what popped ([MISSING_CHUNK]): a queue that pops nothing, one
		-- that pops the same chunk over and over, and one busy with far
		-- chunks while the near ones never come up freeze the settle line
		-- the same way and this tells them apart. Once a second; the count
		-- is 125 lookups.
		if current_us - stuck_checked_us >= 1000000 then
			stuck_checked_us = current_us
			local undrawn = M.undrawn_around(camera_p, 2)
			if undrawn > 0 and undrawn == stuck_undrawn and
					(node_update_queue:get_length() > 0 or
					node_update_queue:is_sorting()) then
				stuck_seconds = stuck_seconds + 1
			else
				stuck_seconds, stuck_said = 0, false
			end
			stuck_undrawn = undrawn
			if stuck_seconds >= 2 and not stuck_said then
				stuck_said = true
				local f0 = node_update_queue:peek_next_f()
				local v = node_update_queue:peek_next_value()
				local last = stuck_pops.last
				-- The nearest undrawn chunk, by node
				local near_id, near_d, near_state = "-", -1, ""
				local c0 = M.get_chunk_position(camera_p)
				if c0 then
					for dz = -2, 2 do for dy = -2, 2 do for dx = -2, 2 do
						local cp = buildat.Vector3(c0.x + dx, c0.y + dy, c0.z + dz)
						if not M.is_chunk_drawn(cp) then
							local node = M.get_static_node(cp)
							local d = node and (node:GetWorldPosition() -
									camera_p):Length() or -1
							if near_d < 0 or (d >= 0 and d < near_d) then
								near_id, near_d = node and node:GetID() or "none", d
								if node then
									local qf, qfw, qx, qy, qz = node_update_queue:find(
											"geometry", node:GetID())
									local np = node:GetWorldPosition()
									near_state = string.format(
											" (%s at %.0f,%.0f,%.0f; data %s, queued %s)",
											node:GetName(), np.x, np.y, np.z,
											node:GetVar("buildat_voxel_data"):IsEmpty()
													and "empty" or "there",
											qf and string.format(
													"f=%.2f fw=%.2f put at %.0f,%.0f,%.0f",
													qf, qfw, qx, qy, qz) or "no")
								end
							end
						end
					end end end
				end
				log:warning(string.format("mesh queue: %d undrawn within 2 " ..
						"for %d s: %d queued, sorting %s, front f=%s fw=%s %s " ..
						"node %s; %d pops in the window, %d distinct, last %s " ..
						"node %s f=%s at %.0f; nearest undrawn node %s at %.0f%s; " ..
						"camera %.0f,%.0f,%.0f", undrawn, stuck_seconds,
						node_update_queue:get_length(),
						tostring(node_update_queue:is_sorting()),
						tostring(f0), tostring(node_update_queue:peek_next_fw()),
						v and v.type or "-", tostring(v and v.node_id or "-"),
						stuck_pops.n, stuck_pops.distinct,
						last and last.type or "-",
						tostring(last and last.node_id or "-"),
						tostring(last and last.f or "-"), last and last.d or -1,
						tostring(near_id), near_d, near_state,
						camera_p.x, camera_p.y, camera_p.z))
			end
			if stuck_seconds == 0 then
				stuck_pops = {n = 0, distinct = 0, seen = {}}
			end
		end

		for i = 1, 10 do -- Usually there is time only for a few
			local f = node_update_queue:peek_next_f()
			local fw = node_update_queue:peek_next_fw()
			local did_update = false
			if f and f <= 1.0 then
				local node_update = node_update_queue:get()
				stuck_pops.n = stuck_pops.n + 1
				local pnode = replicate.main_scene:GetNode(node_update.node_id)
				stuck_pops.last = {type = node_update.type,
						node_id = node_update.node_id, f = math.floor(f*100)/100,
						d = pnode and (pnode:GetWorldPosition() - camera_p):Length()}
				if not stuck_pops.seen[node_update.node_id] then
					stuck_pops.seen[node_update.node_id] = true
					stuck_pops.distinct = stuck_pops.distinct + 1
				end
				local node = replicate.main_scene:GetNode(node_update.node_id)
				if node then
					log:debug("Node update #"..
							node_update_queue:get_length()..
							" (f="..(math.floor(f*100)/100)..""..
							", fw="..(math.floor(fw*100)/100)..")"..
							": "..node:GetName())
					if node_update.type == "geometry" then
						-- How long a chunk that changed waited to be drawn
						-- again, when that is long enough to see
						local queued_us = modified_queued_us[
								node_update.node_id]
						if queued_us then
							modified_queued_us[node_update.node_id] = nil
							modified_warned[node_update.node_id] = nil
							modified_drawn_us[node_update.node_id] =
									buildat.get_time_us()
							local waited = (buildat.get_time_us() -
									queued_us) / 1000000
							if waited >= 1.0 then
								log:warning(string.format(
										"chunk node %d waited %.1f s to be" ..
										" drawn again, with %d in the queue",
										node_update.node_id, waited,
										node_update_queue:get_length()))
							else
								-- The prompt case says so as well. The
								-- question section 3 of
								-- doc/plan/master_plan.md is about is
								-- whether a chunk that changed was drawn
								-- again at all, and a line that only
								-- appears when it was late cannot answer
								-- it: no line then means either "at once"
								-- or "never".
								log:info(string.format(
										"chunk node %d drawn again after" ..
										" %.2f s, with %d in the queue",
										node_update.node_id, waited,
										node_update_queue:get_length()))
							end
						end
						update_voxel_geometry(node)
						-- **That this ran is the only honest "it is
						-- drawn".** A chunk's scene node exists from the
						-- moment it is replicated, so its presence says
						-- nothing about whether there is anything to see;
						-- an empty chunk runs this too and is then as
						-- drawn as it will ever be. See M.is_chunk_drawn().
						geometry_done[node_update.node_id] = true
					end
					if node_update.type == "physics" then
						local t0 = buildat.get_time_us()
						update_voxel_physics(node)
						M.frame_us.physics = M.frame_us.physics +
								buildat.get_time_us() - t0
					end
				end
				did_update = true
			else
				log:debug("Poked update #"..
						node_update_queue:get_length()..
						" (f="..(math.floor((f or -1)*100)/100)..""..
						", fw="..(math.floor((fw or -1)*100)/100)..")")
				--node_update_queue.queue = {} -- For testing
			end
			-- Check this at the end of the loop so at least one is handled
			if not did_update or buildat.get_time_us() >= stop_at_us then
				log:debug("Handled "..i.." node updates")
				break
			end
		end
		end_of_update_processing_us = buildat.get_time_us()

		if camera_node then
			camera_last_dir = camera_dir
			camera_last_p = camera_p
		end
		--log:info(buildat.get_time_us()-t0)
		M.frame_us.update = M.frame_us.update +
				(buildat.get_time_us() - update_t0)
		buildat.profiler_block_end()
	end)

	replicate.sub_sync_node_added({}, function(node)
		if not node:GetVar("buildat_voxel_data"):IsEmpty() then
			note_horizon(node, false)
			queue_initial_node_update(node)
		end
		if node:GetVar("buildat_static"):GetBool() == true and
				M.chunk_size_voxels then
			local p = node:GetWorldPosition()
			local chunk_p = buildat.Vector3(p):div_components(
					M.chunk_size_voxels):floor()
			local cache = M.get_static_node_cache(chunk_p)
			cache.node = node
			cache.fetched = true
		end
	end)

	replicate.sub_sync_node_removed(function(node, node_id)
		node_volume_cache[node_id] = nil
		horizon_meshed_us[node_id] = nil
		modified_drawn_us[node_id] = nil
		modified_held[node_id] = nil
		if node and M.chunk_size_voxels then
			local p = node:GetWorldPosition()
			local chunk_p = buildat.Vector3(p):div_components(
					M.chunk_size_voxels):floor()
			local cache = M.get_static_node_cache(chunk_p)
			cache.node = nil
			cache.fetched = false
			horizon_forget_chunk(chunk_p)
		end
	end)
end

function M.set_camera(new_camera_node)
	camera_node = new_camera_node
end

function M.get_voxel_registry()
	return voxel_reg
end

function M.get_atlas_registry()
	return atlas_reg
end

function M.sub_ready(cb)
	if is_ready then
		cb()
	else
		table.insert(on_ready_callbacks, cb)
	end
end

function M.sub_geometry_update(cb)
	table.insert(geometry_update_cbs, cb)
end

function M.sub_material_update(cb)
	table.insert(material_update_cbs, cb)
end

function M.get_chunk_position(voxel_p)
	if M.chunk_size_voxels == nil then
		-- Not initialized
		log:debug("get_chunk_position(): Not initialized")
		return nil, nil
	end
	local p = buildat.Vector3(voxel_p):round()
	local chunk_p = p:div_components(M.chunk_size_voxels):floor()
	local in_chunk_p = p - M.chunk_size_voxels:mul_components(chunk_p)
	return chunk_p, in_chunk_p
end

-- `player` is "the player caused this" ([CLIENT_FRAME], user
-- 2026-09-26): it rides with the item into the update queue, which puts
-- it before the world's own churn at the same distance.
function queue_modified_node_update(node, prompt, player)
	if not node_update_queue then
		return
	end
	local id = node:GetID()
	local now = buildat.get_time_us()
	if not prompt and MODIFIED_PROMPT_D > 0 then
		-- The chunk's own middle: a 32-voxel chunk reaches some way
		-- past it, which is on the safe side of "near"
		local d = (node:GetWorldPosition() - camera_p):Length()
		if d <= MODIFIED_PROMPT_D then
			prompt = true
		end
	end
	if not prompt and not modified_queued_us[id] then
		local drawn = modified_drawn_us[id]
		if drawn and now - drawn < MODIFIED_COALESCE_US then
			if not modified_held[id] then
				modified_held[id] = drawn + MODIFIED_COALESCE_US
			end
			return
		end
	end
	modified_held[id] = nil
	modified_queued_us[id] = now
	node_update_queue:put(node:GetWorldPosition(),
			MODIFIED_GEOMETRY_NEAR_WEIGHT, M.camera_far_clip * 1.2,
			nil, nil, {
		type = "geometry",
		current_lod = 0,
		node_id = node:GetID(),
	}, player)
	node_update_queue:put(node:GetWorldPosition(),
			MODIFIED_PHYSICS_NEAR_WEIGHT, M.physics_distance, nil, nil, {
		type = "physics",
		node_id = node:GetID(),
	}, player)
end

-- Which registry the chunks are meshed with.
--
-- What wants to change it is a game that draws its world a second way out of
-- the same voxels -- a stress view, a heat map -- as a registry of its own
-- with the same voxel format and different definitions. Follow it with
-- remesh_all(); what a voxel looks like has changed even though the voxel has
-- not.
function M.set_voxel_registry(reg)
	voxel_reg = reg
end

function M.get_voxel_registry_used()
	return voxel_reg
end

-- What a line of detail wants to know about the world: how many chunks this
-- client holds, how many are waiting for a mesh, and how many voxel types
-- the registry it was sent has. A count that is not the server's is a fault
-- with a name; see doc/plan/luanti_module_plan.md, "The numbers before the
-- pixels".
function M.counts()
	local chunks = 0
	for _, ztable in pairs(static_node_cache) do
		for _, ytable in pairs(ztable) do
			for _, cache in pairs(ytable) do
				if cache.node then
					chunks = chunks + 1
				end
			end
		end
	end
	return {
		chunks = chunks,
		to_mesh = node_update_queue and node_update_queue:get_length() or 0,
		-- How near the front of the queue is to being due. The queue is
		-- spatial and this is distance over trigger distance, so the loop
		-- above meshes while it is at most 1 and leaves the rest for when
		-- the camera is closer: **nil or above 1 means the client will draw
		-- nothing more where it is standing**, which is a far more useful
		-- question than how long the queue is. A world pinned by a
		-- forceloading fixture keeps thousands of chunks queued that are
		-- nowhere near the camera. **After a jump the queue re-sorts over
		-- frames**, and until it has, its head says nothing: a picture taken
		-- on those frames had the far chunks of the new place still waiting.
		next_mesh_f = node_update_queue and
				(node_update_queue:is_sorting() and 0 or
				node_update_queue:peek_next_f()) or nil,
		voxel_types = voxel_reg and voxel_reg:get_count() or 0,
	}
end

-- Every chunk that is loaded, queued for a new mesh. The queue is spatial, so
-- what the camera is looking at is rebuilt first and the rest follows.
function M.remesh_all()
	local n = 0
	for _, ztable in pairs(static_node_cache) do
		for _, ytable in pairs(ztable) do
			for _, cache in pairs(ytable) do
				if cache.node then
					queue_modified_node_update(cache.node)
					n = n + 1
				end
			end
		end
	end
	log:info("voxelworld.remesh_all(): "..n.." chunks")
	return n
end

-- Whether this chunk's collision is actually there: the shapes are built and
-- the body is in the physics world.
--
-- Not the same as the chunk node having a RigidBody component. That is
-- created before the shapes exist and two main-thread steps before the body
-- is put in the world -- the steps are split because two of them are
-- expensive -- so a RigidBody on its own is the earliest moment at which
-- there is nothing to stand on. Anything that waits for solid ground before
-- letting a player fall has to wait for this instead.
function M.chunk_has_physics(chunk_p)
	local node = M.get_static_node(chunk_p)
	if not node then
		return false
	end
	return node:GetVar("buildat_physics_ready"):GetBool()
end

-- **How much of the world around a place is actually drawn.** Returns how
-- many chunks within `chunk_radius` of `p` have no scene node, which is the
-- positive question: "nothing is queued" is also true of a place whose
-- chunks have not been asked for yet, and a picture taken then is of an
-- empty sky. See [ONE_CYCLE] in doc/plan/rendering_plan.md, where exactly
-- that was photographed.
-- Whether this chunk has had its geometry built, rather than merely having
-- arrived. See the note where the flag is set.
function M.is_chunk_drawn(chunk_p)
	local node = M.get_static_node(chunk_p)
	if not node then
		return false
	end
	return geometry_done[node:GetID()] == true
end

function M.undrawn_around(p, chunk_radius)
	local c0 = M.get_chunk_position(p)
	if c0 == nil then
		return 0
	end
	-- A chunk past the queue's far (f > 1, M.camera_far_clip * 1.2 from
	-- the camera) is never meshed, so it is not waiting to be: at a view
	-- range of 60 (a touchscreen's) the corners within 2 are, and this
	-- never said 0
	local far = M.camera_far_clip * 1.2
	local q = queue_p or p
	local s = M.chunk_size_voxels
	local missing = 0
	for dz = -chunk_radius, chunk_radius do
		for dy = -chunk_radius, chunk_radius do
			for dx = -chunk_radius, chunk_radius do
				local cp = buildat.Vector3(c0.x + dx, c0.y + dy, c0.z + dz)
				local ex = (cp.x + 0.5) * s.x - q.x
				local ey = (cp.y + 0.5) * s.y - q.y
				local ez = (cp.z + 0.5) * s.z - q.z
				if math.sqrt(ex * ex + ey * ey + ez * ez) <= far and
						not M.is_chunk_drawn(cp) then
					missing = missing + 1
				end
			end
		end
	end
	return missing
end

function M.get_static_node_cache(chunk_p)
	local ztable = static_node_cache[chunk_p.z]
	if not ztable then
		ztable = {}
		static_node_cache[chunk_p.z] = ztable
	end
	local ytable = ztable[chunk_p.y]
	if not ytable then
		ytable = {}
		ztable[chunk_p.y] = ytable
	end
	local xtable = ytable[chunk_p.x]
	if not xtable then
		xtable = {fetched=false}
		ytable[chunk_p.x] = xtable
	end
	return xtable
end

-- TODO: Maybe comment out the trace logging from eating resources
function M.get_static_node(chunk_p)
	local cache = M.get_static_node_cache(chunk_p)
	if cache and cache.fetched then
		if cache.node then
			local live = replicate.main_scene:GetNode(cache.node:GetID())
			if live then
				log:trace("get_static_node(): chunk_p="..chunk_p:dump().." (cache)")
				return live
			end
			cache.node = nil
			cache.fetched = false
		elseif buildat.get_time_us() - (cache.fetched_us or 0) <
				NEGATIVE_CACHE_US then
			log:trace("get_static_node(): chunk_p="..chunk_p:dump().." (cache)")
			return nil
		end
	end
	log:trace("get_static_node(): chunk_p="..chunk_p:dump().." (no cache)")
	-- NOTE: Chunks are positioned by their center position, and chunks are
	--       aligned to a grid offset by half their size from global origin
	local chunk_center_p = chunk_p:mul_components(M.chunk_size_voxels) +
			M.chunk_size_voxels / 2
	log:trace("get_static_node(): chunk_center_p="..chunk_center_p:dump())

	-- Find the static node
	local scene = replicate.main_scene
	local octree = scene:GetComponent("Octree")
	local clearance = magic.Vector3(1,1,1)
	local find_lc = chunk_center_p - clearance
	local find_uc = chunk_center_p + clearance
	log:trace("get_static_node(): find_lc="..find_lc:dump())
	log:trace("get_static_node(): find_uc="..find_uc:dump())
	local result = octree:GetDrawables(magic.BoundingBox(
			magic.Vector3.from_buildat(find_lc),
			magic.Vector3.from_buildat(find_uc)))
	log:trace("get_static_node(): result="..dump(result))
	-- NOTE: The result will contain all kinds of global things like zones and
	--       lights
	-- NOTE: Static nodes can be distinguished by the user variable
	--       buildat_static=true
	local node = nil
	for _, v in ipairs(result) do
		--log:trace("get_static_node(): result node:GetName()="..v.node:GetName())
		local buildat_static_var = v.node:GetVar("buildat_static")
		if buildat_static_var:GetBool() == true then
			node = v.node
			break
		end
	end
	cache.node = node
	cache.fetched = true
	cache.fetched_us = buildat.get_time_us()
	if node == nil then
		log:trace("get_static_node(): static node "..chunk_p:dump()..
				" not found")
		for _, v in ipairs(result) do
			log:trace("get_static_node(): * not "..v.node:GetName())
		end
	end
	return node
end

function M.get_volume(node)
	local node_id = node:GetID()
	local cache = node_volume_cache[node_id]
	if not cache then
		log:verbose("Fetching node "..node_id.." volume into cache")
		local data = node:GetVar("buildat_voxel_data"):GetBuffer()
		if data == nil then
			log:warning("get_volume(): Node "..node_id..
					" does not contain buildat_voxel_data")
			return nil
		end
		cache = {
			volume = buildat.deserialize_volume(data),
			last_access_us = buildat.get_time_us(),
		}
		node_volume_cache[node_id] = cache
	end
	return cache.volume
end

-- Return value: VoxelInstance (found), VoxelInstance(0) (not found)
-- TODO: Maybe comment out the trace logging from eating resources
function M.get_static_voxel(p)
	p = buildat.Vector3(p):round()
	log:trace("get_static_voxel(): p="..p:dump())
	-- Calculate which chunk this voxel is in
	local chunk_p, in_chunk_p = M.get_chunk_position(p)
	if chunk_p == nil then
		log:trace("get_static_voxel(): Not initialized")
		return buildat.VoxelInstance(0)
	end
	log:trace("get_static_voxel(): chunk_p="..chunk_p:dump()..
			", in_chunk_p="..in_chunk_p:dump())
	-- Find the static node
	local node = M.get_static_node(chunk_p)
	if node == nil then
		return buildat.VoxelInstance(0)
	end
	-- Get voxel from volume
	local volume = M.get_volume(node)
	log:trace("get_static_voxel(): volume="..dump(volume))
	if volume == nil then
		log:warning("get_static_voxel(): volume is nil")
		return buildat.VoxelInstance(0)
	end
	local v = volume:get_voxel_at(in_chunk_p.x, in_chunk_p.y, in_chunk_p.z)
	log:trace("get_static_voxel(): v="..dump(v))
	return v
end

-- One plane of a voxel, for a world whose voxels are more than one plane.
-- get_static_voxel() is the first plane, as it always was; this is how a
-- game reads its own, and the value is a plain number because a plane other
-- than the first holds no role the engine knows about.
function M.get_static_voxel_plane(p, plane)
	p = buildat.Vector3(p):round()
	local chunk_p, in_chunk_p = M.get_chunk_position(p)
	if chunk_p == nil then
		return 0
	end
	local node = M.get_static_node(chunk_p)
	if node == nil then
		return 0
	end
	local volume = M.get_volume(node)
	if volume == nil then
		return 0
	end
	return volume:get_plane_at(plane, in_chunk_p.x, in_chunk_p.y, in_chunk_p.z)
end

-- A voxel written on this client alone: the chunk's cached volume, its node
-- var (what the mesher reads), and the chunk queued to be drawn and to
-- collide again; (x, y, z, v) or (p, v). Nothing goes to the server --
-- this is for what a game
-- predicts the server will do ([PREDICTION]), and the server's next update
-- of the chunk overwrites it. Returns whether there was a chunk to write.
function M.set_static_voxel(x, y, z, v)
	if type(x) == "table" then
		v = y
		z = x.z
		y = x.y
		x = x.x
	end
	local chunk_p, in_chunk_p = M.get_chunk_position(
			buildat.Vector3(x, y, z))
	if chunk_p == nil then
		return false
	end
	local node = M.get_static_node(chunk_p)
	if node == nil then
		return false
	end
	local volume = M.get_volume(node)
	if volume == nil then
		return false
	end
	volume:set_voxel_at(in_chunk_p.x, in_chunk_p.y, in_chunk_p.z, v)
	local id = node:GetID()
	local pred = predicted[id] or
			{before = buildat.get_voxel_data(node), writes = {}}
	-- Kept until the server has answered it: a second change to the
	-- chunk before the first's answer would be undone by that answer
	-- ([BOX_PLAYTEST_2] 11) -- so the answer has the changes it does not
	-- carry yet written on top of it, until their own answers come
	pred.writes[#pred.writes + 1] = {in_chunk_p.x, in_chunk_p.y,
			in_chunk_p.z, v}
	pred.after = volume:serialize()
	predicted[id] = pred
	buildat.set_voxel_data(node, pred.after)
	-- The player's own dig or place, and they are watching for it
	queue_modified_node_update(node, true, true)
	return true
end

function send_get_section(p)
	local data = cereal.binary_output({
		p = {
			x = p.x,
			y = p.y,
			z = p.z,
		},
	}, {"object",
		{"p", {"object",
			{"x", "int32_t"},
			{"y", "int32_t"},
			{"z", "int32_t"},
		}},
	})
	--log:info(dump(buildat.bytes(data)))
	buildat.send_packet("voxelworld:get_section", data)
end

return M
-- vim: set noet ts=4 sw=4:
