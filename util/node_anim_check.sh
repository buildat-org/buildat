#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-15)
# covers: src/impl/atlas.cpp builtin/luanti/registry.h builtin/luanti/lua/bootstrap.lua
# [NODE_ANIM]: a node's animated tile (vertical_frames) plays. Vanilla on
# VoxeLibre at noon, the player looking down at a pool, the left half
# lava and the right half water, on stone. Two shots 0.6 s apart: the
# lava differs between them, by over three times what the stone beside
# it does.
#   util/node_anim_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || skip "no VoxeLibre at $G"
check_tmp node_anim; t=$CHECK_TMP
d=$t/s
mkdir -p "$d/apps/vanilla/saves/na/luanti" "$d/shared/vanilla/games"
cp -r "$G" "$d/shared/vanilla/games/"
cat > "$d/shared/fixture.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0, speed = 0})
	core.after(3, function()
		local Y = 120
		core.emerge_area({x = -12, y = Y - 4, z = -12}, {x = 12, y = Y + 8, z = 12},
				function(_, _, left)
			if left > 0 then return end
			for x = -10, 10 do for z = -10, 10 do
				core.set_node({x = x, y = Y - 1, z = z}, {name = "mcl_core:stone"})
				local n = "mcl_core:stone"
				if math.abs(x) <= 4 and math.abs(z) <= 4 then
					n = x < 0 and "mcl_core:lava_source" or "mcl_core:water_source"
				end
				core.set_node({x = x, y = Y, z = z}, {name = n})
			end end
			core.set_timeofday(0.5)
			player:set_pos({x = 0, y = Y + 5, z = 0})
			player:set_look_horizontal(0)
			player:set_look_vertical(math.pi / 2)
			core.after(5, function() core.chat_send_player(name, "na: ready") end)
		end)
	end)
end)
L
printf "mobs_spawn = false\nenable_damage = false\n" > "$d/apps/vanilla/saves/na/luanti/world.mt"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=na \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "wait_log_any 240000 chat: na: ready" "screenshot $t/a.png" \
	"delay 600" "screenshot $t/b.png" "quit" > "$t/cmds"
run_client 60 "$t/client.log" timeout 300 "$here/Build/bin/buildat" \
	-C "$t/nc" -D "$t/nu" -s 127.0.0.1:$SERVER_PORT -w 640x400 -u 1 -l 3 \
	-o sound_mute=1 -c @"$t/cmds" || fail "the drive ($t/client.log)"
python3 - "$t/a.png" "$t/b.png" <<'PY' || fail "the lava did not animate ($t)"
import sys
from PIL import Image
a = Image.open(sys.argv[1]).convert("RGB")
b = Image.open(sys.argv[2]).convert("RGB")
w, h = a.size
def diff(x0, y0, x1, y1):
    n, s = 0, 0
    for y in range(y0, y1, 2):
        for x in range(x0, x1, 2):
            p, q = a.getpixel((x, y)), b.getpixel((x, y))
            s += sum(abs(p[i] - q[i]) for i in range(3))
            n += 1
    return s / n
# The lava is the left of the pool and fills the screen's left middle;
# the stone the strip left of it. The water is left out: its sparkles
# move with the shader's clock, animated tile or not.
lava = diff(w * 13 // 64, h // 5, w * 29 // 64, h * 7 // 10)
stone = diff(0, h // 5, w * 11 // 64, h * 7 // 10)
print("lava %.1f, stone %.1f per pixel" % (lava, stone))
sys.exit(0 if lava > 6 and lava > 3 * stone else 1)
PY
echo "PASS: the lava plays its frames"
# vim: set noet ts=4 sw=4:
