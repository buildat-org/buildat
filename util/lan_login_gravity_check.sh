#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-29)
# covers: builtin/luanti/lua/entity.lua
# [LAN_LOGIN_GRAVITY]: a mod's set_physics_override({gravity = 0}) in
# on_joinplayer holds for a player without the fly privilege -- a LAN
# client on vanilla's launcher server, in by builtin/accounts' login. The
# player is put at y 40 and stays there: the client applies the override
# (no fall), and the server's anti-fly does not take the float for flying
# ("is held down", which it did every 2.5 s).
#   util/lan_login_gravity_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp lan_login_gravity; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/s
mkdir -p "$d/apps/vanilla/saves/g/luanti" "$d/shared"
# Placed at 2 s and again at 4 s (the spawn's own placement may come in
# between), then 6 s afloat -- more than twice the hold-down's 2 s
cat > "$d/shared/fixture.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0})
	local function put()
		local p = core.get_player_by_name(name)
		if p then p:set_pos({x = 0, y = 40, z = 0}) end
	end
	core.after(2, put)
	core.after(4, put)
	core.after(10, function()
		local p = core.get_player_by_name(name)
		if p then core.chat_send_player(name, "lg: y=" .. math.floor(p:get_pos().y + 0.5)) end
	end)
end)
L
printf '%s\n' "enable_damage = false" "$WEB_WORLD_MT" > "$d/apps/vanilla/saves/g/luanti/world.mt"
BUILDAT_OWNER_TOKEN=notthisclients BUILDAT_LUANTI_GAME=minimal \
BUILDAT_LUANTI_SAVE=g BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" \
	start_server "$t/srv.log" "STATUS Listening" 120 auto \
	"$here/Build/bin/buildat_server" -u launcher=1 -A 127.0.0.1 \
	-m "$here/apps/vanilla" -D "$d" -C "$t/cache" -l 3 || fail "the server"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30 || fail "no setup code"
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | head -1 | cut -d' ' -f3)
printf '%s\n' "wait_log_any 120000 chat: lg: y=" quit > "$t/c.cmds"
BUILDAT_JOIN_NAME=lanp BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1 \
BUILDAT_JOIN_CODE=$code run_client 60 "$t/c.log" timeout 200 \
	"$here/Build/bin/buildat" -C "$t/cc" -D "$t/cu" -s 127.0.0.1:$SERVER_PORT \
	-w 800x450 -u 1 -l 3 -o sound_mute=1 -c @"$t/c.cmds"
grep -aq "Player lanp joined" "$t/srv.log" || fail "lanp did not join"
y=$(grep -ao "chat: lg: y=-*[0-9][0-9]*" "$t/c.log" | head -1 | cut -d= -f2)
n=$(grep -ac "lanp is held down" "$t/srv.log")
echo "y=${y:-?}, held down $n times"
[ "${y:-}" = 40 ] || fail "lanp is not at y 40 (y=${y:-none}): the override did not hold"
[ "$n" = 0 ] || fail "lanp held down $n times"
echo "PASS: a login join's gravity override holds"
# vim: set noet ts=4 sw=4:
