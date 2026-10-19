#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-19)
# covers: extensions/luanti_client/res/particle_draw.lua builtin/luanti/client_lua/module.lua extensions/luanti_client/world.lua
# [LUANTI_SHARED_1019]: both Luanti clients draw particles through one
# res/particle_draw.lua. devtest, the player held 300 nodes up looking +z
# at a spawner on the left and a single particle on the right, both
# magenta; a shot of each client has magenta on both sides:
#   - vanilla, the buildat server running devtest;
#   - luanti_client against official Luanti's server (camera_ext.sh's way).
#   util/particle_draw_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
[ -f "$luanti/games/devtest/game.conf" ] || skip "no $luanti/games/devtest"
if check_pgrep buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	skip "a client or a Luanti server is already running"
fi
check_build
check_tmp particle_draw; t=$CHECK_TMP
trap check_cleanup EXIT
cat > "$t/fixture.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.after(2, function()
		core.set_timeofday(0.5)
		player:set_physics_override({gravity = 0, speed = 0})
		player:set_pos({x = 0, y = 300, z = 0})
		core.after(2, function()
			local tex = "basenodes_dirt_with_snow.png^[colorize:#ff00ff:255"
			local still = {x = 0, y = 0, z = 0}
			core.add_particlespawner({amount = 100, time = 0,
				minpos = {x = -2.5, y = 300.5, z = 5},
				maxpos = {x = -1.5, y = 302, z = 5},
				minvel = still, maxvel = still, minacc = still, maxacc = still,
				minexptime = 3, maxexptime = 3, minsize = 8, maxsize = 8,
				texture = tex, glow = 14})
			core.add_particle({pos = {x = 2, y = 301.5, z = 5},
				velocity = still, acceleration = still, expirationtime = 60,
				size = 30, texture = tex, glow = 14})
			core.chat_send_player(name, "particles: ready")
		end)
	end)
end)
L
# "left right" magenta pixel counts of a shot
magenta(){ python3 - "$1" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
n = [0, 0]
for y in range(0, h, 2):
	for x in range(0, w, 2):
		r, g, b = im.getpixel((x, y))
		if r > 150 and b > 150 and g < 100:
			n[0 if x < w // 2 else 1] += 1
print(n[0], n[1])
PY
}
both(){ # name, shot
	read -r l r <<< "$(magenta "$2")"
	[ "${l:-0}" -ge 50 ] && [ "${r:-0}" -ge 50 ] ||
		fail "$1: magenta ${l:-?} left, ${r:-?} right of 50 each ($2)"
	echo "ok: $1 drew the spawner ($l) and the single particle ($r) ($2)"
}
cmds(){ cat <<C
wait_log 120000 chat: particles: ready
look_dir 0 0 1
delay 1500
screenshot $1
quit
C
}

# vanilla
d=$t/s
mkdir -p "$d/apps/vanilla/saves/pd/luanti" "$d/shared/vanilla/games"
cp -r "$luanti/games/devtest" "$d/shared/vanilla/games/"
cp "$t/fixture.lua" "$d/shared/"
printf '%s\n' "enable_damage = false" > "$d/apps/vanilla/saves/pd/luanti/world.mt"
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=pd \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 180 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
cmds "$t/vanilla.png" > "$t/vanilla.cmds"
timeout 200 "$here/Build/bin/buildat" -C "$t/vc" -D "$t/vu" \
	-s 127.0.0.1:$SERVER_PORT -w 1000x600 -u 1 -l 3 -o sound_mute=1 \
	-c @"$t/vanilla.cmds" > "$t/vanilla.log" 2>&1
grep -a "Command sequence failed" "$t/vanilla.log" && fail "vanilla: the drive ($t/vanilla.log)"
kill -INT "$SERVER_PID" 2>/dev/null
for i in $(seq 1 150); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.2; done
both vanilla "$t/vanilla.png"

# luanti_client against official Luanti
work=$t/world
mkdir -p "$work/worldmods/pd"
printf '%s\n' "gameid = devtest" "backend = sqlite3" "player_backend = sqlite3" \
	"auth_backend = sqlite3" "mod_storage_backend = sqlite3" \
	"server_announce = false" > "$work/world.mt"
cp "$t/fixture.lua" "$work/worldmods/pd/init.lua"
printf 'name = pd\n' > "$work/worldmods/pd/mod.conf"
printf '%s\n' "enable_damage = false" "mute_sound = true" > "$t/luanti.conf"
port=30031
( cd "$luanti" && exec "$bin" --server --world "$work" --port "$port" \
	--config "$t/luanti.conf" > "$t/luanti_srv.log" 2>&1 ) &
CHECK_PIDS+=($!)
wait_for_log "$t/luanti_srv.log" "Server for gameid" 120 ||
	fail "the Luanti server did not come up ($t/luanti_srv.log)"
cmds "$t/ext.png" > "$t/ext.cmds"
BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=pd \
	BUILDAT_LUANTI_CONNECT=1 timeout 200 \
	"$here/Build/bin/buildat" -m luanti_client -w 1000x600 -l 3 \
	-c @"$t/ext.cmds" > "$t/ext.log" 2>&1
grep -a "Command sequence failed" "$t/ext.log" && fail "luanti_client: the drive ($t/ext.log)"
both luanti_client "$t/ext.png"
echo "PASS: vanilla and luanti_client draw particles through res/particle_draw.lua: a spawner and a single particle each"
