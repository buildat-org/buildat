#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-11)
# covers: extensions/luanti_client/res/touch.lua builtin/luanti/client_lua/client.lua apps/vanilla/main/client_lua/init.lua
# [TOUCH_LOOK_SETTING]: the look sensitivity on a touchscreen. Vanilla (the
# minimal game) natively with the touch controls, twice: the same 50 pixel
# finger drag turns the player 60 degrees at the default 0.2 and twice that
# at 0.4, which is in the game's storage from before (as a pick in the
# Touch settings leaves it), so the value is kept over a restart.
# simplified: luanti_client's row (settings.lua) is not driven; it sets
# the same touch.lua field.
#   util/touch_look_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp touch_look; t=$CHECK_TMP
trap check_cleanup EXIT
cat > "$t/fixture.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0})
	core.after(3, function()
		local p = core.get_player_by_name(name)
		if not p then return end
		p:set_pos({x = 0, y = 40, z = 0})
		p:set_look_horizontal(0)
		p:set_look_vertical(0)
		core.after(2, function() core.chat_send_player(name, "tl: ready") end)
	end)
end)
local next_at = 0
core.register_globalstep(function()
	if os.clock() < next_at then return end
	next_at = os.clock() + 0.25
	for _, p in ipairs(core.get_connected_players()) do
		core.log("action", string.format("tl yaw %.1f", math.deg(p:get_look_horizontal())))
	end
end)
L
# The yaw turned by a drag at sensitivity $1 ("" for none stored), in $got
turned(){
	local d=$t/$2
	mkdir -p "$d/apps/vanilla/saves/tl/luanti" "$d/shared"
	cp "$t/fixture.lua" "$d/shared/fixture.lua"
	echo "enable_damage = false" > "$d/apps/vanilla/saves/tl/luanti/world.mt"
	BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=tl \
	BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$d.log" \
		"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
		-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
		-C "$d.cache" -l 3 || fail "the server ($d.log)"
	CHECK_PIDS+=($SERVER_PID)
	# The game's storage: the server's address's directory
	local st=$d/nu/servers/127.0.0.1_$SERVER_PORT
	mkdir -p "$st"
	[ -z "$1" ] || printf '%s' "$1" > "$st/touch_sensitivity"
	# The drag's delays are its pace; the last 2 s let the server's yaw
	# line (every 0.25 s) catch up
	{
		echo "wait_log 60000 chat: tl: ready"; echo "delay 2000"
		echo "finger_down 1 700 250"; echo "delay 150"
		# A timing test: the drag's pace, a move every 60 ms
		for x in 710 720 730 740 750; do
			echo "finger_move 1 $x 250"; echo "delay 60"
		done
		# simplified: the server's yaw line (every 0.25 s) catching up; a
		# chat line from the fixture once the yaw stops changing would be
		# the event
		echo "finger_up 1"; echo "delay 2000"
		echo quit
	} > "$d.cmds"
	BUILDAT_TOUCH=1 run_client 60 "$d.client.log" timeout 240 "$here/Build/bin/buildat" \
		-C "$d/nc" -D "$d/nu" -s 127.0.0.1:$SERVER_PORT -w 1000x500 -u 1 -l 3 \
		-o sound_mute=1 -c @"$d.cmds" || fail "the drive ($d.client.log)"
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
	grep -aq "look sensitivity ${1:-0.2}$" "$d.client.log" ||
		fail "no \"look sensitivity ${1:-0.2}\" ($d.client.log)"
	# The yaw at "ready" and the last one
	got=$(awk '/tl: ready/ {r = 1} /tl yaw/ {y = $NF; if(r && y0 == "") y0 = y}
		END {d = y - y0; if(d < 0) d = -d; if(d > 180) d = 360 - d; printf "%.0f", d}' "$d.log")
}
turned "" a; a=$got
turned 0.4 b; b=$got
echo "turned $a at 0.2, $b at 0.4"
[ "$a" -ge 50 ] && [ "$a" -le 70 ] || fail "the drag at 0.2 turned $a, not about 60"
[ "$b" -ge $((a * 2 - 10)) ] && [ "$b" -le $((a * 2 + 10)) ] ||
	fail "the drag at 0.4 turned $b, not twice $a"
echo "PASS: the touch look sensitivity: twice the turn at 0.4, read from the game's storage"
