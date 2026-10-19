#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-11)
# covers: builtin/luanti/luanti.cpp builtin/voxelworld/voxelworld.cpp builtin/storage/storage.cpp
# [SAVE_CHECKPOINT]: vanilla on the minimal game with a client on. A
# fixture stands the player on the game's floor, places a node beside
# them with a metadata field and puts an item in their inventory; 7 s
# later, the player still on, the server is killed with SIGKILL. Started
# again on the save, the node, its field and the item are there.
#
#   util/save_checkpoint_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp save_checkpoint; t=$CHECK_TMP
trap check_cleanup EXIT
cd "$here/Build"
mkdir -p "$t/u/shared" "$t/u/apps/vanilla/saves/w/luanti"
echo "enable_damage = false" > "$t/u/apps/vanilla/saves/w/luanti/world.mt"
cat > "$t/u/shared/place.lua" <<'L'
core.register_on_joinplayer(function(player)
	-- On the floor at the origin, which every start places: land still
	-- being generated is saved as not generated and made again on load
	player:set_pos({x = -3, y = 1, z = -3})
	core.after(4, function()
		local q = {x = -5, y = 1, z = -5}
		core.set_node(q, {name = "floor:leaves"})
		core.get_meta(q):set_string("kept", "yes")
		player:get_inventory():add_item("main", "floor:glass 7")
		core.log("action", "checkpoint_check: placed at " ..
				core.pos_to_string(q))
	end)
end)
L
# The client stays on until the shell kills it: the 60 s is its time
# limit, not a wait
echo "wait_log 60000 the server put the player at
delay 60000
quit" > "$t/c.cmds"
run(){ # <log> <fixture>: the server and a client; the client's PID in CLIENT
	BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=w BUILDAT_LUANTI_LUA="$t/u/shared/$2" \
		start_server "$t/$1.log" "STATUS Listening" 60 auto bin/buildat_server \
		-u launcher=1 -A 127.0.0.1 -m ../apps/vanilla -D "$t/u" -C "$t/c" -l 4 ||
		fail "the server did not start ($t/$1.log)"
	CHECK_PIDS+=($SERVER_PID)
	timeout 120 bin/buildat -C "$t/cc" -D "$t/uc" -s 127.0.0.1:"$SERVER_PORT" \
		-w 640x400 -u 1 -l 3 -o sound_mute=1 -c @"$t/c.cmds" > "$t/$1_client.log" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
}

run a place.lua
wait_for_log "$t/a.log" "checkpoint_check: placed at" 60 || fail "nothing placed ($t/a.log)"
pos=$(grep -a "checkpoint_check: placed at" "$t/a.log" | sed 's/.*placed at //')
sleep 7 # what is checked: a kill this long after the change keeps it
kill -0 "$CLIENT" 2>/dev/null || fail "the client left before the kill ($t/a_client.log)"
kill -9 "$SERVER_PID"; kill "$CLIENT"; wait "$SERVER_PID" "$CLIENT" 2>/dev/null
grep -aq "checkpoint: " "$t/a.log" || fail "no checkpoint logged ($t/a.log)"
echo "ok: placed at $pos, killed 7 s later with the player on"

cat > "$t/u/shared/look.lua" <<L
core.register_on_joinplayer(function(player)
	core.after(3, function()
		local q = core.string_to_pos("$pos")
		local has = player:get_inventory():contains_item("main", "floor:glass 7")
		core.log("action", "checkpoint_check: " .. core.get_node(q).name ..
				", kept " .. core.get_meta(q):get_string("kept") ..
				", glass " .. tostring(has))
	end)
end)
L
run b look.lua
wait_for_log "$t/b.log" "checkpoint_check: " 60 || fail "nothing read ($t/b.log)"
grep -aq "checkpoint_check: floor:leaves, kept yes, glass true" "$t/b.log" ||
	fail "lost: $(grep -a "checkpoint_check: " "$t/b.log" | sed 's/.*check: //')"
echo "ok: the node, its field and the item are there after the restart"
echo "PASS: every step above held"
