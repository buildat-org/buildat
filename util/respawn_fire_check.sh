#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-15)
# covers: builtin/luanti/lua/entity.lua
# [RESPAWN_EFFECTS]: a death's fire is out after the respawn. Vanilla on
# VoxeLibre: the player set on fire (mcl_burning, as lava does), killed,
# and respawned as the death screen's button does. Then the player is not
# burning, the fire HUD is gone and no fire entity is attached. Every
# on_respawnplayer callback has to run; mcl_spawn's answers true before
# mcl_burning's extinguish is reached.
#   util/respawn_fire_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || skip "no VoxeLibre at $G"
check_tmp respawn_fire; t=$CHECK_TMP
d=$t/s
mkdir -p "$d/apps/vanilla/saves/rf/luanti" "$d/shared/vanilla/games"
cp -r "$G" "$d/shared/vanilla/games/"
cat > "$d/shared/fixture.lua" <<'L'
-- The player in a pool of lava till dead, respawned a second later as
-- the death screen's button does, and the fire sampled for 3 s after
core.register_on_dieplayer(function(player)
	core.log("action", "rf: died, burning " .. tostring(mcl_burning.is_burning(player) or false))
	core.after(1, function()
		player:respawn()
		local lit, samples = 0, 0
		local function sample()
			samples = samples + 1
			if mcl_burning.is_burning(player) then lit = lit + 1 end
			if samples < 12 then core.after(0.25, sample) return end
			local fires = 0
			for _, c in ipairs(player:get_children()) do
				local e = c:get_luaentity()
				if e and e.name == "mcl_burning:fire" then fires = fires + 1 end
			end
			local s = mcl_burning.storage[player] or {}
			core.log("action", string.format("rf: respawned at %s, burning in %d of 12 samples, hud %s, fire entities %d",
					core.pos_to_string(vector.round(player:get_pos())), lit,
					tostring(s.fire_hud_id), fires))
			core.chat_send_player(player:get_player_name(), "rf: done")
		end
		sample()
	end)
end)
core.register_on_joinplayer(function(player)
	core.after(5, function()
		-- Off the spawn point, which the respawn puts the player on
		local p = vector.offset(vector.round(player:get_pos()), 30, 0, 0)
		for x = -2, 2 do for z = -2, 2 do for y = -1, 1 do
			core.set_node(vector.offset(p, x, y, z), {name = y == -1 and "mcl_core:stone"
					or "mcl_core:lava_source"})
		end end end
		player:set_pos(p)
		core.log("action", "rf: lava at " .. core.pos_to_string(p))
	end)
end)
L
printf "mobs_spawn = false\n" > "$d/apps/vanilla/saves/rf/luanti/world.mt"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=rf \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "wait_log_any 240000 chat: rf: done" "quit" > "$t/cmds"
run_client 60 "$t/client.log" timeout 300 "$here/Build/bin/buildat" \
	-C "$t/nc" -D "$t/nu" -s 127.0.0.1:$SERVER_PORT -w 640x360 -u 1 -l 3 \
	-o sound_mute=1 -c @"$t/cmds" || fail "the drive ($t/client.log)"
grep -a "rf: " "$t/srv.log" | cut -c 30-
grep -aq "rf: died, burning [0-9]" "$t/srv.log" || fail "not burning at the death ($t/srv.log)"
grep -aq "rf: respawned at .*, burning in 0 of 12 samples, hud nil, fire entities 0" "$t/srv.log" ||
	fail "the fire goes on after the respawn ($t/srv.log)"
echo "PASS: the fire is out after the respawn"
# vim: set noet ts=4 sw=4:
