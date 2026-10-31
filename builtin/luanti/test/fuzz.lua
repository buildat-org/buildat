-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [AUTO_PLAYTEST] part 1: the server half of a fuzz run. The client walks
-- at random (fuzz.sh writes the command file from a seed); this asserts
-- what must hold whatever it does, once a second, and logs one line per
-- second for the runner to read afterwards:
--
--   fuzz: t=12 pos=(1,8,-3) moved=14.2 hp=20 dug=3 placed=1 picked=2 trees=17 objs=4 step=0.08 over=0 deaths=0
--
-- and `fuzz: FAILED <why>` on the first invariant that breaks. No oracle:
-- the two engines diverge within seconds under physics at the frame rate,
-- so a long run is comparable to nothing but its own invariants.
--
--   BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=fuzz \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/fuzz.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
-- The world is left running -- ABMs, LBMs, the clock, mobs -- because a
-- long run is what meets the faults a frozen one cannot.

-- The world is the seed's: fuzz.sh prepends `rawset(_G, "FUZZ_SEED", n)`
-- and this file runs before the module reads the seed, so fixed_map_seed
-- is what a new save takes. A save that has a seed keeps it.
local seed = rawget(_G, "FUZZ_SEED")
if seed then
	core.settings:set("fixed_map_seed", tostring(seed))
end

local dug, placed, picked = 0, 0, 0
local pickup_test_at, dropped_name = nil, nil
-- The step ceiling ([STEP_PEAK]): warned over the first, failed over the
-- second. `over` counts the seconds the peak was over the ceiling, from
-- STEP_COUNT_FROM_T on: the ceiling is about play, not the start-up
-- load, whose one emerge spike is accepted (user, 2026-09-19).
-- **A timing is a row on CI, never a verdict** ([CI_RUNS] (3)): these
-- were argued against this desk's hardware, and on a runner -- llvmpipe,
-- a shared core, a cold cache -- a step over a second says the machine
-- is slow rather than that the server is wrong. A run that failed every
-- time would teach everyone to ignore it, and a real fault would go by
-- with the noise. So under BUILDAT_CI the peak is still printed and
-- counted; it just stops deciding. What CI asserts is behaviour.
local ON_CI = os.getenv and os.getenv("BUILDAT_CI") ~= nil and
		os.getenv("BUILDAT_CI") ~= ""
local STEP_CEILING_S, STEP_FAIL_S = 0.25, ON_CI and math.huge or 1.0
local STEP_COUNT_FROM_T = 90
local over = 0
-- Deaths, and when the current one began
local deaths, dead_since = 0, nil
local moved_at_minute = 0
local said_no_trees = false
-- How many seconds each nearby section has been loaded and ungenerated
local ungenerated_for = {}

-- Every hit point lost, with its reason: seed 1's rerun drowned twelve
-- times, 20 to 2 inside a second, which no interval in the module adds
-- up to; the line says what did it (2026-09-19)
core.register_on_player_hpchange(function(player, change, reason)
	if change < 0 then
		core.log("action", string.format("fuzz: hp %d %+d %s%s%s",
				player:get_hp(), change, tostring(reason.type),
				reason.node and (" " .. reason.node) or "",
				reason.from and (" from " .. tostring(reason.from)) or ""))
	end
end, false)

-- Only the player's own digs, and only of nodes that drop something by
-- hand: mapgen mods dig with no digger (the count was 119 with the
-- player's share 7 on seed 8), and a fern dug by hand drops nothing
local dropping = 0
core.register_on_dignode(function(pos, node, digger)
	if not (digger and digger:is_player()) then
		return
	end
	dug = dug + 1
	-- What actually dropped, not what get_node_drops() says would: a game
	-- with harvest rules (VoxeLibre's can_harvest -- stone by hand drops
	-- nothing) or a creative inventory hands the drops over differently,
	-- and the drops are made before this callback runs, so an item entity
	-- beside the node is the fact ([DUG_NOT_HELD], seed 13: nine digs of
	-- nodes the engine's table says drop, nothing in hand, nothing wrong)
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 1.5)) do
		local le = obj:get_luaentity()
		if le and le.name == "__builtin:item" then
			dropping = dropping + 1
			-- and what it was, for the pickup check below
			dropped_name = le.itemstring or dropped_name
			break
		end
	end
end)
core.register_on_placenode(function(pos, node, placer)
	-- The player's own: a structure's placements came through here as
	-- eighteen in a second (seed 7's rerun)
	if placer and placer:is_player() then
		placed = placed + 1
	end
end)
core.register_on_item_pickup(function(itemstack, picker)
	picked = picked + 1
end)

-- An entity within reach that was healthy a second ago is not gone now:
-- [PUNCH_VANISH]. Punches are not hooked -- a mob's on_punch is its own --
-- so the sample is every object within four nodes, remembered with the
-- health it had. A mob killed by punching runs its health down first; one
-- removed at full health vanished. VoxeLibre keeps health on the
-- luaentity; a game without one is read through the engine's hp.
local watched = {}
local function health_of(obj)
	local le = obj:get_luaentity()
	return (le and tonumber(le.health)) or obj:get_hp()
end
local function punch_watch(player)
	local near = {}
	for _, obj in ipairs(core.get_objects_inside_radius(player:get_pos(), 4)) do
		-- Not item entities: a death drops the inventory as those and
		-- they merge and get picked up, which is a removal at full
		-- health by this test's letter ([FUZZ_DEATH_WATCH], seed 11)
		local le = obj:get_luaentity()
		if not obj:is_player() and not (le and le.name == "__builtin:item") then
			near[obj] = health_of(obj)
		end
	end
	local why
	for obj, health in pairs(watched) do
		-- get_pos() is nil for a removed object and a position for one
		-- that walked away
		if near[obj] == nil and obj:get_pos() == nil and health > 2 then
			why = "an entity within reach was removed at health " .. health
		end
	end
	watched = near
	return why
end

core.register_on_joinplayer(function(player)
	local t = 0
	local start = player:get_pos()
	local moved = 0
	local last = start
	local failed, step_failed = false, false
	local function fail(why)
		if failed then
			return
		end
		failed = true
		core.log("action", "fuzz: FAILED " .. why)
	end
	local function tick()
		if not player:is_player() then
			return
		end
		t = t + 1
		local pos = player:get_pos()
		moved = moved + vector.distance(last, pos)
		last = pos
		local trees = 0
		if t % 10 == 0 then
			-- [NO_TREES]: a VoxeLibre world with grass and no trees. A
			-- mushroom island has huge mushrooms where a forest has trees
			-- (seed 3 spawns on one), and both are schematic decorations,
			-- which is the mechanism the fault was in.
			-- And only where there is grass: a desert or an ocean spawn
			-- has no trees and is not the fault (seed 6 had neither).
			local _, counts = core.find_nodes_in_area(
					vector.subtract(start, 40), vector.add(start, 40),
					{"group:tree", "group:huge_mushroom", "group:grass_block"})
			local grass = 0
			for name, n in pairs(counts) do
				if core.get_item_group(name, "grass_block") > 0 then
					grass = grass + n
				else
					trees = trees + n
				end
			end
			-- A warning and not a failure: seed 6 spawns on a plain with
			-- 1039 grass nodes and no tree in the box, and VoxeLibre's
			-- plains oaks are sparse enough that a box of that size has
			-- none once in a dozen worlds. The failure [NO_TREES] was is
			-- caught by test/vltree.lua on the chunks it generates.
			if trees == 0 and grass > 20 and core.get_modpath("mcl_core") and
					not said_no_trees then
				said_no_trees = true
				core.log("warning", "fuzz: grass and no group:tree or huge " ..
						"mushroom within 40 nodes of spawn")
			end
		end
		-- A death is the game working -- a fall, lava, a mob -- and the
		-- run goes on: the fixture presses the button the death screen
		-- would, two seconds later, and counts. What would be a fault is
		-- a death nothing explains, which is what the count and the
		-- pictures are for.
		local hp = player:get_hp()
		if hp <= 0 and not dead_since then
			dead_since = t
			deaths = deaths + 1
			-- The inventory went with the death (VoxeLibre drops it), so
			-- what was dug before it says nothing about pickup now
			dropping = 0
			core.log("action", "fuzz: died at t=" .. t .. " (" .. deaths ..
					" so far)")
		elseif hp <= 0 and t - dead_since >= 2 then
			-- What the Respawn button does, both halves: the client's
			-- form closes and the server respawns. respawn() alone left
			-- the death form open on the client, and a client with a form
			-- open reads no keys -- every walk with a death in it stood
			-- still from the respawn on ([RESPAWN_STUCK], seeds 1, 4, 11)
			core.close_formspec(player:get_player_name(), "__builtin:death")
			player:respawn()
			dead_since = nil
		elseif hp > 0 then
			dead_since = nil
		end
		-- After a minute a random walk has gone somewhere; a player who
		-- has not is a client whose keys never arrived ([HELD_KEY_FLAKE]).
		-- Not for a driven run (FUZZ_DRIVEN): the driver crafts its
		-- first minute at a tree beside the spawn and has stuck rules of
		-- its own (2026-09-22, a GOAL 2 run standing on 237,10,236)
		if t == 60 and moved < 5 and not rawget(_G, "FUZZ_DRIVEN") then
			fail("the player did not move in a minute")
		end
		-- And a still minute later on, alive, is a walk that something
		-- holds: a pause menu the scripted Escape opened when there was
		-- no form to close, a hole ([FUZZ_STUCK]). Warned with the
		-- position; the scan block beside the next screenshot says which
		-- form is up. Freed by a lift of three nodes: a hole is left, a
		-- menu is not, and the next minute says which it was.
		if t % 60 == 0 and t > 60 and hp > 0 and moved - moved_at_minute < 2 then
			core.log("warning", string.format(
					"fuzz: still for a minute at %s, lifted ([FUZZ_STUCK])",
					core.pos_to_string(vector.round(pos))))
			player:set_pos(vector.add(pos, {x = 0, y = 3, z = 0}))
		end
		if t % 60 == 0 then
			moved_at_minute = moved
		end
		if t >= 20 and dug == 0 and t % 60 == 0 then
			core.log("warning", "fuzz: nothing dug yet at t=" .. t)
		end
		-- A dug node became an item the player holds. handle_node_drops
		-- puts it straight into the inventory when there is room, so the
		-- pickup hook is for what was dropped and the inventory is the
		-- check: two dug and an empty inventory a minute later is the
		-- drop path
		-- An empty inventory is not the verdict by itself: the walk digs
		-- looking down and moves on, and what dropped lies where it was
		-- dug, out of reach (seed 7's rerun, seven dug, none held). The
		-- verdict is the pickup path itself: an item put at the feet
		-- is in the inventory three seconds later, or is not.
		if dropping >= 3 and t % 60 == 0 and pickup_test_at == nil then
			local inv = player:get_inventory()
			if inv and inv:is_empty("main") then
				core.add_item(pos, dropped_name)
				pickup_test_at = t
				core.log("action", string.format(
						"fuzz: dug %d that drop and holds nothing at t=%d; " ..
						"a %s put at the feet", dropping, t, dropped_name))
			end
		elseif pickup_test_at and t >= pickup_test_at + 3 then
			local inv = player:get_inventory()
			if inv and inv:is_empty("main") then
				fail("dug " .. dropping .. " nodes that drop something and " ..
						"holds nothing, and an item put at the feet was not " ..
						"picked up in 3 s")
			else
				core.log("action", "fuzz: the item at the feet was picked up")
			end
			pickup_test_at = nil
		end
		local why = punch_watch(player)
		if why then
			fail(why)
		end
		-- No loaded section near the player stays ungenerated: one that
		-- does is a hole in the world ([UNGENERATED_SAVED]). Thirty
		-- seconds is longer than any emerge seen; the sections within
		-- two of the player's are read once a second.
		local ps = vector.round(pos)
		for dx = -128, 128, 64 do
			for dy = -64, 64, 64 do
				for dz = -128, 128, 64 do
					local x, y, z = ps.x + dx, ps.y + dy, ps.z + dz
					local key = math.floor(x / 64) .. "," ..
							math.floor(y / 64) .. "," .. math.floor(z / 64)
					if __luanti_section_state(x, y, z) == "ungenerated" then
						ungenerated_for[key] = (ungenerated_for[key] or 0) + 1
						if ungenerated_for[key] > 30 then
							fail("section " .. key .. " has been loaded and " ..
									"ungenerated for " .. ungenerated_for[key] ..
									" s")
						end
					else
						ungenerated_for[key] = nil
					end
				end
			end
		end
		-- The server answers inside a second, and normally well inside
		-- it: the step peak since the last check is under STEP_CEILING_S
		-- while the walk interacts, and no step at all is over
		-- STEP_FAIL_S. First cut, argued with in doc/plan/performance_plan.md
		-- under [STEP_PEAK]. The peak is read fresh each tick -- decay
		-- barely moves it in a second -- and a stall is named with its
		-- phase.
		-- The worst step of the last second, not the decaying peak: the
		-- peak counted one step eighty times as it came down
		local peak, phase = core.get_server_step_worst()
		-- A game's own generation is not this engine's to answer for
		-- ([MAPGEN_STEP]): VoxeLibre's on_generated runs 0.2-3.9 s a
		-- section of its own Lua -- timed to the mod, the bindings under
		-- it milliseconds -- and it is a server-thread callback on
		-- official as well. It is counted and said, never a FAIL.
		if peak > STEP_CEILING_S and (phase or ""):match("^on_generated") then
			core.log("warning", string.format(
					"fuzz: step peak %.2f s in %s at t=%d (a game's own "..
					"generation, not counted)", peak, phase, t))
		elseif peak > STEP_FAIL_S and t < STEP_COUNT_FROM_T then
			-- The start-up load is not play: the first sections' emerge
			-- and the lbms of the blocks they bring were failing a run at
			-- t=0 while the ceiling's own tally starts at
			-- STEP_COUNT_FROM_T, which is the rule this follows now
			-- (user, 2026-09-19; read again 2026-09-22 when a fresh world
			-- under the physics variant failed on emerge 6.11 s at t=0)
			core.log("warning", string.format(
					"fuzz: step peak %.2f s in %s at t=%d (the start-up "..
					"load, not counted)", peak, phase, t))
		elseif peak > STEP_FAIL_S and not step_failed then
			-- Latched on its own: verdict.sh may find the step the
			-- machine's (the server waiting for a CPU), and a fault found
			-- after it must still be said ([FUZZ_FRAME_PEAK])
			step_failed = true
			core.log("action", string.format("fuzz: FAILED a step took " ..
					"%.2f s in %s", peak, phase))
		elseif ON_CI and peak > 1.0 then
			core.log("warning", string.format(
					"fuzz: step peak %.2f s in %s at t=%d (BUILDAT_CI: a "..
					"row, not a verdict)", peak, phase, t))
		elseif peak > STEP_CEILING_S and t >= STEP_COUNT_FROM_T then
			core.log("warning", string.format(
					"fuzz: step peak %.2f s in %s at t=%d", peak, phase, t))
			over = over + 1
		end
		local objs = #core.get_objects_inside_radius(pos, 16)
		core.log("action", string.format(
				"fuzz: t=%d pos=%s moved=%.1f hp=%d dug=%d placed=%d " ..
				"picked=%d trees=%d objs=%d step=%.2f over=%d deaths=%d", t,
				core.pos_to_string(vector.round(pos)), moved, hp, dug, placed,
				picked, trees, objs, peak, over, deaths))
		core.after(1, tick)
	end
	core.after(5, tick)
end)
