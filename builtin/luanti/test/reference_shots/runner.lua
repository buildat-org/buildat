-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- The reference shot set's viewpoints, hours and weather, for comparing this
-- module against official Luanti and against extensions/luanti_client.
--
-- **The same file serves all three clients**, because both buildat clients
-- run the game's code through this module and official Luanti runs it as a
-- worldmod. See [OFFICIAL_SHOTS] in doc/plan/rendering_plan.md, which
-- settles the set: mineclone2 only, one world, eight viewpoints,
-- twenty-three pictures a client.
--
-- As this module's fixture:
--
--   BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=refviews \
--   BUILDAT_LUANTI_IMPORT=~/projects/luanti/worlds/mc2_2026-09-15_0033 \
--   BUILDAT_LUANTI_LUA=<build.sh's fixture.lua> \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
-- As official Luanti's, build.sh's refviews/ dropped into <world>/worldmods.
--
-- **Which viewpoints run is decided by the world's seed**: the reference
-- world gets all eight, any other is refused when build.sh named the seed
-- and shot at one hour when it did not (a fixture concatenated by hand).
--
-- **Each state is announced in the log** as `REFSHOT <n> <name>`, and the
-- name is the file stem the shot is saved under. A script that drives the
-- shots waits for that line rather than counting seconds, so the two cannot
-- drift apart.
--
-- **The aim is re-asserted every second.** The official client's input is
-- not disabled and the machine is in use, so a stray mouse movement turns
-- the camera; the aim is server-side and authoritative, so it comes back.
-- See [OFFICIAL_SHOTS], "It runs on the user's own desktop".

-- The numbers -- viewpoints, hours, range, hold -- are set.lua's, which
-- build.sh concatenates in front of this file; this file is behaviour and
-- holds none of them. See [REFVIEWS_MOD].
local REFSET = rawget(_G, "REFSET")
local VIEWS = REFSET.views
local HOURS = REFSET.hours
-- The seed build.sh read out of map_meta.txt, or nil for a fixture
-- assembled by hand
local SEED_REFERENCE = rawget(_G, "REFSHOT_SEED")

-- The hold is set.lua's; REFSHOT_HOLD is the calibration ladder's override
local HOLD = tonumber(rawget(_G, "REFSHOT_HOLD")) or REFSET.hold
-- The moon's scale in the fixture: its light, no disc to see -- a
-- thousandth of its square, under a pixel at any of the views
local MOON_UNSEEN = 0.001
-- How often the aim is put back, which has to fit inside the hold: at a
-- second it is four re-aims of a six second state, and at a quarter of that
-- it is still four. The calibration ladder halves one thing at a time, and
-- this one follows the hold rather than being a second variable.
local REAIM = HOLD / 6

-- **The world is frozen while a set is taken** -- see [FROZEN_WORLD] in
-- doc/plan/rendering_plan.md. A set is meant to be of the world the file
-- holds, and a running game does not leave it that way: VoxeLibre's
-- `fix_grass_palette_indexes` repaints grass from the biome *this* version
-- of the game computes, which on a world five minor versions older is a
-- different green, and that was read as a rendering fault for two days. Snow
-- melts, grass spreads, mobs walk out of frame. And it is most of a run's
-- cost: 229 seconds of LBMs and 83 of ABMs out of 960.
--
-- **The hook is early enough in both engines, which is the point.** Luanti
-- reads `core.registered_abms` and `core.registered_lbms` into C++ in
-- `initializeEnvironment()` (`server.cpp:585`), after `loadMods()` (`:534`)
-- has fired this callback; the module reads the same two tables live in
-- `run_abms()` and `run_lbms()`. So one function freezes both, and a fixture
-- that froze only one of them would make the halves less comparable rather
-- than more.
--
-- Not the globalsteps: the weather states need mcl_weather alive, and the
-- fixture drives it deliberately.
--
-- Mobs are not spawned. Natural spawn is not repeatable across engines, so
-- a skeleton in one half and not the other reads as a lighting fault. Later
-- the fixture should place mobs and entities as static props to test their
-- lighting; until then they stay out. See [FROZEN_WORLD].
local LIVE = rawget(_G, "REFSHOT_LIVE")

local function freeze_world()
	if LIVE then
		core.log("action", "REFSHOT the world is left running (REFSHOT_LIVE)")
		return
	end
	core.settings:set("mobs_spawn", "false")
	local tuning = rawget(_G, "vl_tuning")
	local rule = tuning and tuning.setting and
			tuning.setting("gamerule:doMobSpawning")
	if rule and rule.set then
		rule:set(false)
	end
	local abms, lbms = core.registered_abms, core.registered_lbms
	local n_abm, n_lbm, n_ent = #abms, #lbms, 0
	-- Emptied rather than replaced: anything already holding the table keeps
	-- holding the one that is now empty
	for i = #abms, 1, -1 do
		abms[i] = nil
	end
	for i = #lbms, 1, -1 do
		lbms[i] = nil
	end
	for _, def in pairs(core.registered_entities) do
		if def.on_step then
			def.on_step = nil
			n_ent = n_ent + 1
		end
	end
	core.log("action", "REFSHOT froze the world: " .. n_abm .. " ABMs, " ..
			n_lbm .. " LBMs, " .. n_ent .. " entity steps, no mob spawn")
end

core.register_on_mods_loaded(freeze_world)

-- Anything already in the world is removed rather than stilled: a frozen
-- zombie is still a zombie in the frame, and spawn is not repeatable.
local function still_objects(pos)
	if LIVE then
		return
	end
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 80)) do
		if not obj:is_player() then
			obj:remove()
		end
	end
end

local function seed_now()
	local s = core.get_mapgen_setting and core.get_mapgen_setting("seed")
	return tostring(s or "")
end

-- The states, in order: every viewpoint at each of its hours, clear; then
-- the surface ones again in rain. A probe cycle (REFSHOT_PROBE) shoots only
-- what probes.sh reads -- "did that work" in seconds rather than the two
-- minutes twenty states cost -- and a path-trace run (REFSHOT_PATHTRACE)
-- one dump per viewpoint. Both come as a prelude build.sh writes in front
-- of this file rather than as a setting, because the three clients that run
-- it have three ways of being configured and none of a file. See
-- [PROBE_CYCLE] in doc/plan/rendering_plan.md.
local function states_of(seed)
	local picked = rawget(_G, "REFSHOT_STATES")
	if picked then
		local out = {}
		for v, h in picked:gmatch("(%d+):(%d+)") do
			out[#out + 1] = {view = tonumber(v), hour = h, weather = "none"}
		end
		return out
	end
	if rawget(_G, "REFSHOT_PROBE") then
		return REFSET.probe_states
	end
	if rawget(_G, "REFSHOT_PATHTRACE") then
		return REFSET.pathtrace_states
	end
	local out = {}
	local reference = seed == SEED_REFERENCE
	for v = 1, #VIEWS do
		local hours = reference and REFSET.hours_of_view[v] or
				{REFSET.hand_hour}
		for _, h in ipairs(hours) do
			out[#out + 1] = {view = v, hour = h, weather = "none"}
		end
	end
	if reference then
		for _, v in ipairs(REFSET.rain_views) do
			out[#out + 1] = {view = v, hour = REFSET.rain_hour,
					weather = "rain"}
		end
	end
	return out
end

-- mineclone2 changes the weather on a timer, which would otherwise be a
-- variable nobody recorded. Re-asserted at every state rather than once at
-- load, because the cycle's timer is not the only thing that can change it.
-- Not "thunder": it darkens the sky and is a second variable.
local function hold_weather(kind)
	core.settings:set("mcl_doWeatherCycle", "false")
	-- rawget because this file also runs in games that are not VoxeLibre,
	-- and the vendored builtin's strict.lua warns about reading a global
	-- that nobody declared
	local w = rawget(_G, "mcl_weather")
	if w and w.change_weather then
		w.change_weather(kind, 1000000)
	end
end

-- The three clients are compared at one viewing range and no fog.
-- REFSHOT_RANGE (RANGE= on the runners) moves it: a path-trace dump at 50
-- is a minute instead of ten million verts. fog_start 0.99 is as far as
-- set_sky's clamp lets it go, which fogs the last node and a half; official
-- Luanti has enable_fog = false on top, and Cycles draws no fog at all.
--
-- Read, edit, write, rather than a bare set_sky: the sky belongs to the game
-- and only the fog is ours to say. And after the weather rather than before,
-- because changing the weather sets a sky of its own.
local RANGE = tonumber(rawget(_G, "REFSHOT_RANGE")) or REFSET.range

-- The fixture's own status line; declared here because pin_view() spares it
local hud_id, hud_player, hud_said = nil, nil, nil

-- The set's lamps ([LAMP_REF]), placed once the world around the views
-- is in and before any state is shown, so every picture of that cave
-- has them. Set where set.lua says, whatever is there; what was there
-- goes in the log.
local lamps_placed = false
local function place_lamps()
	if lamps_placed or not REFSET.lamps then
		return
	end
	-- **A probe of the light has to be of the light** ([DARK_INVARIANT]:
	-- view 8 is where [LAMP_REF]'s glowstone sits, so a run measuring
	-- the sky term there would measure the lamp instead). NOLAMPS=1.
	if rawget(_G, "REFSHOT_NOLAMPS") then
		lamps_placed = true
		core.log("action", "REFSHOT lamps: not placed (REFSHOT_NOLAMPS)")
		return
	end
	lamps_placed = true
	for _, lamp in ipairs(REFSET.lamps) do
		local was = core.get_node_or_nil(lamp.pos)
		core.set_node(lamp.pos, {name = lamp.node})
		core.log("action", string.format("REFSHOT lamp %s at %d,%d,%d (vp%d), was %s",
				lamp.node, lamp.pos.x, lamp.pos.y, lamp.pos.z, lamp.view,
				was and was.name or "nothing loaded"))
	end
end

-- The set's bore ([STAIR_VIEW]), dug with the lamps: along the trace
-- set.lua gives, one voxel per step in X at the line's Y, from the first
-- solid one the trace meets, `depth` of them
local function dig_bore()
	local b = REFSET.bore
	if not b then
		return
	end
	-- Per column along X: `tall` voxels (three: what a player needs to
	-- walk a stair, user 2026-09-20), centred on the line -- the middle
	-- one the voxel whose centre is nearest it -- so the camera, whose
	-- eye the trace leaves, looks into the stairwell and not at its
	-- ceiling. The depth counts columns from the first that held
	-- anything solid.
	local tan = math.tan(math.rad(b.pitch))
	local tall = b.tall or 3
	local columns, first = 0, false
	for i = 1, 40 do
		if columns >= b.depth then
			break
		end
		local x = math.floor(b.from.x) + i
		local yl = b.from.y + (x - b.from.x) * tan
		local z = math.floor(b.from.z + 0.5)
		local y0 = math.floor(yl + 0.5) - math.floor(tall / 2)
		local solid = false
		for y = y0, y0 + tall - 1 do
			local node = core.get_node_or_nil({x = x, y = y, z = z})
			local name = node and node.name or "ignore"
			if name ~= "air" and name ~= "ignore" then
				solid = true
			end
		end
		if solid then
			first = true
		end
		if first then
			columns = columns + 1
			for y = y0, y0 + tall - 1 do
				local pos = {x = x, y = y, z = z}
				local node = core.get_node_or_nil(pos)
				local name = node and node.name or "ignore"
				if name ~= "air" and name ~= "ignore" then
					core.remove_node(pos)
					core.log("action", string.format("REFSHOT bore column %d at %d,%d,%d (vp%d), was %s",
							columns, pos.x, pos.y, pos.z, b.view, name))
				end
			end
		end
	end
end

local function pin_view(player)
	core.settings:set("viewing_range", tostring(RANGE))
	local sky = player:get_sky(true)
	sky.fog = sky.fog or {}
	sky.fog.fog_distance = RANGE
	sky.fog.fog_start = 0.99
	player:set_sky(sky)
	-- No clouds, no moon disc and no stars, on every client (user,
	-- 2026-09-18): the reference's Nishita sky has none, and rather than
	-- model them there or read around them the fixture turns them off.
	-- A fixture fact, not a rendering one; the moonlit ground stays,
	-- the disc goes: the moon is kept up at a scale too small to see,
	-- since a hidden moon lights nothing in either client
	-- ([VANILLA_WEATHER]). Re-asserted with the rest, since a game's weather
	-- puts clouds back.
	-- CLOUDS=1 leaves the game's clouds on: a set for looking at the
	-- clouds themselves ([CLOUD_LIGHT]), not for the probes
	local clouds_wanted = rawget(_G, "REFSHOT_CLOUDS") == true
	if not clouds_wanted then
		player:set_clouds({density = 0})
	end
	player:set_moon({visible = true, scale = MOON_UNSEEN})
	player:set_stars({visible = false})
	-- **And kept off against the game**: mcl_weather's sky update puts
	-- `moon = {visible = true}` on every player a few times a minute, and
	-- the moon's square -- 20 degrees wide at mcl_moon's scale of 3.75 --
	-- hung behind vp5's far trees at 02:00 as a white shape that was read
	-- as snow-topped canopies, and over vp1's hill by day as a grey one.
	-- Once is not enough, so the setters filter what the game asks for,
	-- for the fixture's life: on the player's class (the userdata's
	-- metatable index), once. Only this server runs the fixture, so
	-- every player here is the fixture's.
	local class = getmetatable(player) and getmetatable(player).__index
	if type(class) == "table" and not class.__refshot_keeps_off then
		class.__refshot_keeps_off = true
		local function keep_off(name, field, value, field2, value2)
			local orig = class[name]
			class[name] = function(self, params)
				params = type(params) == "table" and table.copy(params) or {}
				params[field] = value
				if field2 then
					params[field2] = value2
				end
				return orig(self, params)
			end
		end
		keep_off("set_moon", "visible", true, "scale", MOON_UNSEEN)
		keep_off("set_stars", "visible", false)
		if not clouds_wanted then
			keep_off("set_clouds", "density", 0)
		end
	end
	-- Not a HUD test: the F5 line and the fixture's own text are what a
	-- reference picture carries, and nothing else. See [REFVIEWS_HUD].
	player:hud_set_flags({hotbar = false, wielditem = false,
			healthbar = false, breathbar = false, crosshair = false,
			minimap = false})
	-- And every element the game put up -- VoxeLibre's hearts and hunger
	-- are statbars of its own, which no flag hides -- except this file's
	-- text. On every re-aim, since a game may add one back.
	for id, _ in pairs(player:hud_get_all()) do
		if id ~= hud_id then
			player:hud_remove(id)
		end
	end
end

-- **What the run photographs is kept loaded while it runs.** Moving between
-- viewpoints that are hundreds of nodes apart drops what the camera left, and
-- a section that has to be loaded, sent and meshed again is a hole in the
-- next picture of it -- which does not look like a missing chunk, it looks
-- like a rendering fault. So the fixture pins its own viewpoints. See
-- [KEEP_LOADED] in doc/plan/rendering_plan.md.
--
-- **Retention only**: what is ready changes, never what is drawn. The far
-- clip and the fog bound the picture exactly as before, so a shot taken this
-- way is comparable with one taken without it.
--
-- builtin/voxelworld loads by section -- 2x2x2 chunks of 32, so 64 voxels --
-- and one forceload anywhere in a section pins the whole of it, so the grid
-- steps by that. The radius follows RANGE: a dump at 50 should not generate
-- 128 nodes of world the camera cannot see. Capped at 128 so RANGE=200 is
-- the same pin as before.
local SECTION = 64
local KEEP_XZ = math.max(SECTION, math.ceil(RANGE / SECTION) * SECTION)
if KEEP_XZ > 128 then
	KEEP_XZ = 128
end
local KEEP_Y = math.min(64, KEEP_XZ)

-- Which blocks were pinned, so they can be let go again: a session that
-- inherits a fixture's pins is a session that never unloads anything.
local pinned = {}

-- And which positions say whether the run can start. **Pinned wide, checked
-- narrow**: the box around a viewpoint reaches above the sky and below the
-- world at the viewpoints near either, and a block that cannot exist never
-- loads -- 60 of 375 of them, which made "all loaded" unreachable. What has
-- to be there is the ground the camera stands on and what is next to it.
local probes = {}

-- The same probes, grouped by the viewpoint they belong to: the readiness of
-- a state is about the place that state looks at, not about the whole set.
local probes_of_view = {}

local function keep_loaded(pos, view)
	local mine = {}
	probes_of_view[view] = mine
	-- The camera's own section and its eight horizontal neighbours: these
	-- exist wherever a viewpoint does, because a viewpoint is somewhere a
	-- camera stands
	for dx = -SECTION, SECTION, SECTION do
		for dz = -SECTION, SECTION, SECTION do
			local p = {x = pos.x + dx, y = pos.y, z = pos.z + dz}
			probes[#probes + 1] = p
			mine[#mine + 1] = p
		end
	end
	for dx = -KEEP_XZ, KEEP_XZ, SECTION do
		for dy = -KEEP_Y, KEEP_Y, SECTION do
			for dz = -KEEP_XZ, KEEP_XZ, SECTION do
				-- **The raw door, deliberately.** core.forceload_block() goes
				-- through the vendored builtin's own bookkeeping, which caps
				-- a mod at max_forceloaded_blocks -- sixteen -- and five
				-- viewpoints want more than that. The cap would show up as a
				-- missing mesh rather than as an error.
				local bp = {x = math.floor((pos.x + dx) / 16),
						y = math.floor((pos.y + dy) / 16),
						z = math.floor((pos.z + dz) / 16)}
				-- The raw door is this module's. Official Luanti has
				-- forceload_block and a cap of sixteen, so it skips the
				-- pin and relies on the two timed cycles.
				if core.__forceload_block_raw then
					core.__forceload_block_raw(bp)
					pinned[#pinned + 1] = bp
				end
			end
		end
	end
end

-- How many of the pinned blocks are actually there. A section that has not
-- arrived answers "ignore", which is Luanti's own word for "not loaded".
local function loaded_count(list)
	local n = 0
	for _, p in ipairs(list or probes) do
		if core.get_node(p).name ~= "ignore" then
			n = n + 1
		end
	end
	return n
end

-- **Is this viewpoint complete as far as this server is concerned?** The
-- server half of [ONE_CYCLE]'s readiness rule: nothing around the viewpoint
-- is still missing, so there is nothing left for the server to send and the
-- marker that follows means what it says.
local function view_is_loaded(view)
	local list = probes_of_view[view]
	if list == nil then
		return true
	end
	return loaded_count(list) >= #list
end

-- **What the run is doing, on the HUD**, top right, a line at a time. It
-- costs nothing and it goes into every screenshot, so a picture says what the
-- fixture believed it was photographing and anybody watching the client can
-- see the run rather than guess at it. Updated about once a second; the
-- states themselves change far more slowly than that.

local function say(text)
	if text == hud_said then
		return
	end
	hud_said = text
	if not (hud_player and hud_player:is_player()) then
		return
	end
	if hud_id then
		hud_player:hud_change(hud_id, "text", text)
		return
	end
	hud_id = hud_player:hud_add({
		hud_elem_type = "text",
		-- Top right, and anchored by its own right edge so a longer line
		-- grows leftwards into the sky rather than off the screen
		position = {x = 1, y = 0},
		alignment = {x = -1, y = 1},
		offset = {x = -8, y = 8},
		text = text,
		number = 0xFFFF80,
	})
end

core.register_on_shutdown(function()
	if not core.__forceload_free_block_raw then
		return
	end
	for _, bp in ipairs(pinned) do
		core.__forceload_free_block_raw(bp)
	end
end)

core.register_on_joinplayer(function(player)
	local seed = seed_now()
	-- **The identity check.** The fixture is told the seed it was built for
	-- and refuses any other world: a world generated from the wrong
	-- parameters, or by a different VoxeLibre, has already cost rounds of
	-- pictures that looked fine. A hand-assembled fixture has no expected
	-- seed and shoots whatever it is in, at one hour.
	if SEED_REFERENCE and seed ~= SEED_REFERENCE then
		core.log("action", "REFSHOT failed: world seed " .. seed ..
				", the set is of " .. SEED_REFERENCE)
		core.request_shutdown("REFSHOT: wrong world")
		return
	end
	local states = states_of(seed)
	core.settings:set("time_speed", "0")
	core.log("action", "REFSHOT world seed " .. seed .. ", " ..
			#states .. " states")

	-- Pin what this run will photograph, and say when it is all there. **The
	-- readiness line is what the harness waits for**, in place of the timing
	-- guesswork a calibration ladder was trying to bound: a signal rather
	-- than a guess. Only the viewpoints this world's states use, so a probe
	-- cycle pins two and not five.
	local wanted = {}
	for _, st in ipairs(states) do
		wanted[st.view] = true
	end
	-- A second client on the same server finds the world pinned already
	-- (REFSHOT_KEEP below); the HUD line is the new player's
	hud_id = nil
	if #pinned > 0 then
		core.log("action", "REFSHOT already pinned " .. #pinned .. " blocks")
	elseif core.__forceload_block_raw then
		for v, _ in pairs(wanted) do
			keep_loaded(VIEWS[v].pos, v)
		end
		core.log("action", "REFSHOT pinned " .. #pinned .. " blocks around " ..
				"the viewpoints")
	else
		core.log("action", "REFSHOT no raw forceload, not pinning")
	end
	hud_player = player
	-- Gravity off, so a cave camera that is not on a voxel top stays put.
	-- Existing viewpoints already sit on a voxel; this is for the ones that
	-- cannot.
	player:set_physics_override({speed = 0, jump = 0, gravity = 0})
	say("refshot: pinned " .. #pinned .. " blocks, loading")

	-- **A state ends when the client says it has drawn it**, not when a
	-- timer says so -- see [ONE_CYCLE] in doc/plan/rendering_plan.md. The
	-- server marks the state once nothing around the viewpoint is missing,
	-- the client answers with the name of the picture it took, and this
	-- advances on that answer. One pass is then enough: the two extra passes
	-- existed because nothing could tell a cold picture from a warm one.
	--
	-- **Without the channel it is the old timed pass**, which is how this
	-- same file behaves as official Luanti's worldmod: that client is
	-- unmodified and cannot answer.
	local channel = rawget(_G, "__luanti_refshot_mark") ~= nil
	local passes = tonumber(rawget(_G, "REFSHOT_CYCLES")) or
			(channel and 1 or 2)
	-- What a state is allowed to take before the run is called failed. Under
	-- the channel the only ways to hang are real faults -- a section that
	-- will not load, a mesh that will not build -- so this is tens of
	-- seconds rather than the minutes a guessed hold needed.
	local cap = tonumber(rawget(_G, "REFSHOT_CAP")) or 90

	local token, marked, waited_shot = 0, false, 0
	local shots = {}

	-- The two call each other, so the name exists before either body does;
	-- a plain `function show()` here would be a global, which the vendored
	-- builtin's strict.lua warns about and which would leak into the game
	local show
	local function name_of(i)
		local st = states[(i - 1) % #states + 1]
		return seed .. "_vp" .. st.view .. "_" .. st.hour .. "_" .. st.weather
	end

	local function finish(why)
		core.log("action", "REFSHOT done: " .. #shots .. " of " ..
				(#states * passes) .. " pictures" .. (why and (", " .. why) or ""))
		for _, pair in ipairs(shots) do
			core.log("action", "REFSHOT shot " .. pair[1] .. " " .. pair[2])
		end
		say("refshot: done, " .. #shots .. " pictures")
		-- REFSHOT_KEEP: the server stays for the next client, which is how
		-- one server serves a client in each mode -- see [PROBE_CYCLE]
		if not rawget(_G, "REFSHOT_KEEP") then
			core.request_shutdown("REFSHOT: the set is taken")
		end
	end

	local function aim(i, left)
		if not (player and player:is_player()) then
			return
		end
		local st = states[(i - 1) % #states + 1]
		local v = VIEWS[st.view]
		player:set_physics_override({speed = 0, jump = 0, gravity = 0})
		player:set_look_horizontal(math.rad(v.yaw))
		player:set_look_vertical(math.rad(-v.pitch))
		player:set_pos(v.pos)
		player:set_velocity({x = 0, y = 0, z = 0})
		player:set_acceleration({x = 0, y = 0, z = 0})
		-- An hour not named in set.lua is read as its HHMM, for a STATES
		-- ladder at steps the set has no names for ([DUSK_SKY]'s five
		-- minutes)
		core.set_timeofday(HOURS[st.hour] or (tonumber(st.hour:sub(1, 2)) *
				60 + tonumber(st.hour:sub(3, 4))) / 1440)
		hold_weather(st.weather)
		still_objects(v.pos)
		pin_view(player)
		if not channel then
			if left > 0 then
				core.after(REAIM, function() aim(i, left - REAIM) end)
			else
				core.after(REAIM, function() show(i + 1) end)
			end
			return
		end
		-- A timer left over from a state that has already been answered
		if token ~= i then
			return
		end
		-- The server's half of the rule: nothing around this viewpoint is
		-- still missing, so there is nothing left to send and the marker
		-- that follows means what it says.
		--
		-- **Never in the step that set the state.** The marker's whole
		-- meaning is that it arrives after everything sent before it, and a
		-- state sets more than chunks: the hour goes out as the call is
		-- made, but the sky a weather change hangs on the player does not.
		-- Marking in the same step photographed three states with the
		-- previous one's sky -- a night viewpoint in daylight -- while the
		-- world in front of the camera was perfectly correct.
		-- Three seconds: one was photographing the previous state's camera.
		if not marked and waited_shot >= 3 and view_is_loaded(st.view) then
			marked = true
			-- **What the light is on the surface the camera is
			-- pointed at** ([DARK_INVARIANT]: "a probe that is not at
			-- nibble nought proves nothing, since the term is not
			-- asked there"). Not the air the eye sits in -- that is
			-- lit by whatever reaches it -- but the first solid node
			-- along the look, which is what the picture is mostly of.
			-- Said before the shot, so a reader of the set knows which
			-- pictures are evidence.
			local yr, pr = math.rad(v.yaw), math.rad(-v.pitch)
			local dir = {x = math.sin(yr) * math.cos(pr),
					y = math.sin(pr), z = math.cos(yr) * math.cos(pr)}
			local to = {x = v.pos.x + dir.x * 30, y = v.pos.y + dir.y * 30,
					z = v.pos.z + dir.z * 30}
			local hit = nil
			for pointed in core.raycast(v.pos, to, false, false) do
				if pointed.type == "node" then
					hit = pointed.under
					break
				end
			end
			if hit then
				core.log("action", string.format(
						"REFSHOT nibble %s at %d,%d,%d %s day=%s night=%s",
						name_of(i), hit.x, hit.y, hit.z,
						(core.get_node(hit) or {}).name or "?",
						tostring(core.get_node_light(hit, 0.5)),
						tostring(core.get_node_light(hit, 0))))
			else
				core.log("action", "REFSHOT nibble " .. name_of(i) ..
						" nothing within thirty nodes")
			end
			__luanti_refshot_mark(i, v.pos.x, v.pos.y, v.pos.z,
					rawget(_G, "REFSHOT_PATHTRACE") and true or false)
		end
		waited_shot = waited_shot + REAIM
		if waited_shot >= cap then
			local half = marked and "the client never drew it" or
					"the world never finished loading around it"
			core.log("action", "REFSHOT failed: " .. name_of(i) ..
					" after " .. math.floor(waited_shot) .. "s, " .. half)
			say("refshot: FAILED at " .. name_of(i))
			core.request_shutdown("REFSHOT: a state never became ready")
			return
		end
		core.after(REAIM, function() aim(i, 0) end)
	end

	-- What the client answers with, and the only thing it has to say: the
	-- name of the file it wrote. This set the state, so it pairs them.
	function core.__refshot_shot(t, name, mesh)
		if t ~= token then
			return
		end
		shots[#shots + 1] = {name_of(t), name}
		core.log("action", "REFSHOT shot " .. name_of(t) .. " " .. name)
		if mesh and mesh ~= "" then
			core.log("action", "REFSHOT mesh " .. name_of(t) .. " " .. mesh)
		end
		if t >= #states * passes then
			finish()
			return
		end
		show(t + 1)
	end

	function show(i)
		if i > #states * passes then
			finish()
			return
		end
		token, marked, waited_shot = i, false, 0
		local st = states[(i - 1) % #states + 1]
		core.log("action", "REFSHOT " .. ((i - 1) % #states + 1) .. " " ..
				name_of(i))
		say("refshot: " .. ((i - 1) % #states + 1) .. "/" .. #states ..
				" vp" .. st.view .. " " .. st.hour .. " " .. st.weather ..
				"  (pass " .. math.floor((i - 1) / #states) + 1 .. ")")
		aim(i, HOLD - REAIM)
	end

	-- The pinned sections are waited for before the first viewpoint, and
	-- **the camera parking at the spawn point while that happens is fine**
	-- (user, 2026-09-16) -- what is not fine is waiting forever. **So it
	-- bails**: if the count of loaded blocks stops rising, nothing more is
	-- coming and the run gets on with it. Two minutes is the outside, and a
	-- stall of twenty seconds ends it sooner.
	local waited, best, stuck = 0, -1, 0
	local function when_ready()
		local n = loaded_count()
		if n >= #probes then
			core.log("action", "REFSHOT ready after " .. waited .. "s, " ..
					n .. " of " .. #probes .. " places")
			say("refshot: loaded, starting")
			place_lamps()
			dig_bore()
			show(1)
			return
		end
		say("refshot: loading " .. n .. "/" .. #probes ..
				", " .. waited .. "s")
		-- **A run whose world did not load exits rather than shooting.**
		-- Pictures of a world with holes in it are worse than no pictures:
		-- they are not obviously wrong, they look like a rendering fault, and
		-- this project has already spent days reading numbers off them.
		local why = nil
		if stuck >= 20 then
			why = "it stopped loading"
		elseif waited >= 120 then
			why = "it is taking too long"
		end
		if why then
			core.log("action", "REFSHOT failed: " .. n .. " of " ..
					#probes .. " places loaded after " .. waited ..
					"s and " .. why)
			say("refshot: FAILED, " .. n .. "/" .. #probes .. " loaded")
			core.request_shutdown("REFSHOT: the world did not load")
			return
		end
		if n > best then
			best, stuck = n, 0
		else
			stuck = stuck + 2
		end
		waited = waited + 2
		core.after(2, when_ready)
	end
	core.after(8, when_ready)
end)
