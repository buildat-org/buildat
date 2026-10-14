#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-14)
# covers: apps/vanilla/main/main.cpp builtin/luanti/client_lua/client.lua apps/vanilla/main/client_lua/init.lua builtin/luanti/lua/entity.lua builtin/luanti/session.h
# [TOUCH_EAT]: food eaten with nothing pointed at. Vanilla on VoxeLibre
# (survival), the player hungry (10) with five carrots wielded, floating
# and looking at the sky:
#   1. the touch controls: a tap and a held finger at the sky eat one
#      carrot (four left, hunger 13);
#   2. the desktop: the right button held at the sky eats another.
# Before, a place at nothing sent nothing and no food could be eaten.
# simplified: the eating sound and "no food wielded does nothing" are not
# asserted (an item without on_secondary_use is not called); a tap at a
# node is the place path, which is unchanged and touch_parity_check's.
#   util/touch_eat_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || skip "no mineclone2"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp touch_eat; t=$CHECK_TMP
mkdir -p "$t/srv/apps/vanilla/saves/e/luanti" "$t/srv/shared/vanilla/games"
cp -r "$G" "$t/srv/shared/vanilla/games/"
printf "creative_mode = false\nenable_damage = false\n" > "$t/srv/apps/vanilla/saves/e/luanti/world.mt"
cat > "$t/srv/shared/fixture.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.after(3, function()
		local p = core.get_player_by_name(name)
		if not p then return end
		p:set_physics_override({gravity = 0})
		p:set_pos({x = 0, y = 120, z = 0})
		p:set_look_vertical(-math.pi / 2)
		local inv = p:get_inventory()
		inv:set_list("main", {})
		inv:set_stack("main", 1, "mcl_farming:carrot_item 5")
		p:set_wield_index(1)
		mcl_hunger.set_hunger(p, 10, true)
		core.after(2, function() core.chat_send_player(name, "te: ready") end)
	end)
end)
local next_at = 0
core.register_globalstep(function()
	if os.clock() < next_at then return end
	next_at = os.clock() + 0.25
	for _, p in ipairs(core.get_connected_players()) do
		core.log("action", "te: carrots " ..
				p:get_inventory():get_stack("main", 1):get_count() ..
				" hunger " .. mcl_hunger.get_hunger(p))
	end
end)
L
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=e \
BUILDAT_LUANTI_LUA="$t/srv/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
# drive <n> <commands>: a client's join, the commands once the fixture is
# ready, then the last carrots line
drive(){
	{
		echo "wait_log 120000 chat: te: ready"; echo "delay 1000"
		printf '%b\n' "$2"
		echo "delay 1500"; echo quit
	} > "$t/$1.cmds"
	local touch=; [ "$1" = touch ] && touch=1
	BUILDAT_TOUCH=$touch run_client 60 "$t/$1.log" timeout 300 "$here/Build/bin/buildat" \
		-C "$t/c$1" -D "$t/u$1" -w 1000x500 -l 3 -o sound_mute=1 \
		-s "127.0.0.1:$SERVER_PORT" -c @"$t/$1.cmds" ||
		fail "the drive ($t/$1.log: $(grep -a "Command sequence failed\|run_client:" "$t/$1.log" | tail -1))"
	sleep 1
	got=$(grep -a "te: carrots" "$t/srv.log" | tail -1 | sed 's/.*te: //')
	echo "$1: $got"
}
# 1. A tap, then within VoxeLibre's 0.75 s padding a finger held past the
# 1.61 s eating delay (the long press holds the dig button from 0.4 s)
drive touch "finger_down 1 500 250\ndelay 60\nfinger_up 1\ndelay 100\nfinger_down 1 500 250\ndelay 2600\nfinger_up 1"
[ "$got" = "carrots 4 hunger 13" ] || fail "touch: $got, not 4 and 13 ($t/srv.log)"
# 2.
drive desktop "mouse_down right\ndelay 2600\nmouse_up right"
[ "$got" = "carrots 4 hunger 13" ] || fail "desktop: $got, not 4 and 13 ($t/srv.log)"
echo "PASS: a carrot eaten at the sky by a tap and a held finger, and by the right button held"
# vim: set noet ts=4 sw=4:
