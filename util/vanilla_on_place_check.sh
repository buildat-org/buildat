#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-15)
# covers: builtin/luanti/lua/entity.lua
# [VANILLA_ON_PLACE]: a place calls the wielded item's on_place, as
# Luanti's server does. Vanilla on VoxeLibre (survival), the player
# floating, aimed by the fixture at each step's node, one right click a
# step; the fixture reads the map back:
#   flint and steel on planks and on leaves lights a fire above them;
#   the water bucket places water and the empty bucket takes it back;
#   a hoe makes dirt farmland, a torch on a wall is a wall torch, a door
#   stands on stone, a slab on a slab is a double slab.
# Before, every place was core.item_place(): a tool's did nothing.
#   util/vanilla_on_place_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || skip "no mineclone2"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp on_place; t=$CHECK_TMP
mkdir -p "$t/srv/apps/vanilla/saves/e/luanti" "$t/srv/shared/vanilla/games"
cp -r "$G" "$t/srv/shared/vanilla/games/"
printf "creative_mode = false\nenable_damage = false\n" > "$t/srv/apps/vanilla/saves/e/luanti/world.mt"
cat > "$t/srv/shared/fixture.lua" <<'L'
-- Each step: the nodes set, the item wielded, the player aimed at `aim`;
-- after the click, `check` names the node read back and what it must be
-- (a prefix), and `wield` the item left in the hand, if it matters
local T = {x = 0, y = 118, z = 2}
local function at(dy, dz) return {x = 0, y = T.y + dy, z = T.z + (dz or 0)} end
local STEPS = {
	{name = "fire on planks", set = {{T, "mcl_core:wood"}},
		item = "mcl_fire:flint_and_steel", aim = {0, 118.5, 2},
		check = {at(1), "mcl_fire:fire"}},
	{name = "fire on leaves", set = {{T, "mcl_core:leaves"}},
		item = "mcl_fire:flint_and_steel", aim = {0, 118.5, 2},
		check = {at(1), "mcl_fire:fire"}},
	{name = "water placed", set = {{T, "mcl_core:stone"}},
		item = "mcl_buckets:bucket_water", aim = {0, 118.5, 2},
		check = {at(1), "mcl_core:water_source"},
		wield = "mcl_buckets:bucket_empty"},
	{name = "water taken", keep = true,
		item = "mcl_buckets:bucket_empty", aim = {0, 118.5, 2},
		check = {at(1), "air"}, wield = "mcl_buckets:bucket_water"},
	{name = "hoe on dirt", set = {{T, "mcl_core:dirt"}},
		item = "mcl_farming:hoe_wood", aim = {0, 118.5, 2},
		check = {T, "mcl_farming:soil"}},
	-- The side of a node at eye level's reach, facing the player
	{name = "torch on a wall", set = {{at(1), "mcl_core:stone"}},
		item = "mcl_torches:torch", aim = {0, 119.2, 1.5},
		check = {at(1, -1), "mcl_torches:torch_wall"}},
	{name = "door on stone", set = {{T, "mcl_core:stone"}},
		item = "mcl_doors:wooden_door", aim = {0, 118.5, 2},
		check = {at(1), "mcl_doors:wooden_door"}},
	-- A bottom slab's top is the node's middle
	{name = "slab on a slab", set = {{T, "mcl_stairs:slab_stone"}},
		item = "mcl_stairs:slab_stone", aim = {0, 118.0, 2},
		check = {T, "mcl_stairs:slab_stone_double"}},
}
local function clear()
	for y = T.y - 1, T.y + 3 do
		for z = T.z - 2, T.z + 1 do
			core.set_node({x = 0, y = y, z = z}, {name = "air"})
		end
	end
end
local function step(name, i)
	local p = core.get_player_by_name(name)
	local s = STEPS[i]
	if not p then return end
	if not s then
		core.chat_send_player(name, "op: done")
		return
	end
	if not s.keep then
		clear()
		for _, n in ipairs(s.set) do core.set_node(n[1], {name = n[2]}) end
	end
	local inv = p:get_inventory()
	inv:set_list("main", {})
	inv:set_stack("main", 1, s.item)
	p:set_wield_index(1)
	local eye = p:get_pos().y + (p:get_properties().eye_height or 1.625)
	p:set_look_horizontal(0)
	p:set_look_vertical(math.atan2(eye - s.aim[2], s.aim[3]))
	core.after(1, function() core.chat_send_player(name, "op: step " .. i) end)
	-- The click comes within the next second (the drive waits for the line)
	core.after(3, function()
		local got = core.get_node(s.check[1]).name
		local stack = p:get_wielded_item()
		local w = stack:get_count() > 0 and stack:get_name() or ""
		local ok = got:sub(1, #s.check[2]) == s.check[2] and
				(not s.wield or w == s.wield)
		core.log("action", "op: " .. s.name .. ": " .. got .. ", wields " ..
				w .. (ok and " ok" or " WRONG"))
		step(name, i + 1)
	end)
end
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.after(3, function()
		local p = core.get_player_by_name(name)
		if not p then return end
		p:set_physics_override({gravity = 0})
		p:set_pos({x = 0, y = 120, z = 0})
		step(name, 1)
	end)
end)
L
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=e \
BUILDAT_LUANTI_LUA="$t/srv/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
{
	for i in 1 2 3 4 5 6 7 8; do
		echo "wait_log 120000 chat: op: step $i"
		echo "mouse_down right"; echo "delay 120"; echo "mouse_up right"
	done
	echo "wait_log 60000 chat: op: done"; echo quit
} > "$t/c.cmds"
run_client 60 "$t/c.log" timeout 300 "$here/Build/bin/buildat" \
	-C "$t/c" -D "$t/u" -w 1000x500 -l 3 -o sound_mute=1 \
	-s "127.0.0.1:$SERVER_PORT" -c @"$t/c.cmds" ||
	fail "the drive ($t/c.log: $(grep -a "Command sequence failed\|run_client:" "$t/c.log" | tail -1))"
sleep 1
grep -a "op: .*wields" "$t/srv.log" | sed 's/.*op: //'
[ "$(grep -ac "op: .* ok$" "$t/srv.log")" = 8 ] || fail "a step did not ($t/srv.log)"
echo "PASS: each item's on_place did what it does in Luanti"
# vim: set noet ts=4 sw=4:
