#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-15)
# covers: src/impl/mesh.cpp
# [LEAF_SOLID_FACES]: the face of a solid voxel against leaves (allfaces)
# is drawn. Vanilla on the minimal game: a wall of floor:leaves against a
# block of floor:stone, open sky behind the stone, the player looking at
# the leaves from 3 nodes off at noon. Through the leaves' holes the
# stone, not the sky: the shot's middle is under 1% sky pixels (blue or
# white); without the fix, 8.1%.
#   util/leaf_face_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp leaf_face; t=$CHECK_TMP
d=$t/v
mkdir -p "$d/apps/vanilla/saves/lf/luanti" "$d/shared"
cat > "$d/shared/fixture.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0, speed = 0})
	core.after(1, function()
		core.emerge_area({x = -12, y = 40, z = -4}, {x = 12, y = 64, z = 16},
				function(_, _, left)
			if left > 0 then return end
			for x = -10, 10 do for y = 42, 62 do for z = -2, 14 do
				local n = "air"
				if z == 3 then n = "floor:leaves"
				elseif z >= 4 and z <= 5 then n = "floor:stone" end
				core.set_node({x = x, y = y, z = z}, {name = n})
			end end end
			core.set_timeofday(0.5)
			local p = core.get_player_by_name(name)
			p:set_pos({x = 0, y = 50.5, z = 0})
			p:set_look_horizontal(0)
			p:set_look_vertical(0)
			core.after(4, function() core.chat_send_player(name, "lf: ready") end)
		end)
	end)
end)
L
printf "enable_damage = false\n" > "$d/apps/vanilla/saves/lf/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=lf \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/s.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 || fail "the server ($t/s.log)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "wait_log_any 120000 lf: ready" "idle 10000" \
	"screenshot $t/shot.png" "quit" > "$t/cmds"
run_client 60 "$t/c.log" timeout 240 "$here/Build/bin/buildat" \
	-C "$t/cc" -D "$t/cu" -s 127.0.0.1:$SERVER_PORT -w 640x400 -u 1 -l 3 \
	-o sound_mute=1 -c @"$t/cmds" || fail "the drive ($t/c.log)"
python3 - "$t/shot.png" <<'PY' || fail "sky through the leaves' wall ($t/shot.png)"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
px = [im.getpixel((x, y)) for x in range(w // 4, 3 * w // 4, 2)
	for y in range(h // 4, 3 * h // 4, 2)]
sky = sum(1 for r, g, b in px if (b > r + 40 and b > 120) or r + g + b > 600)
share = 100.0 * sky / len(px)
print("sky in the middle: %.1f%%" % share)
sys.exit(0 if share < 1 else 1)
PY
echo "PASS: the stone's face behind the leaves is drawn"
# vim: set noet ts=4 sw=4:
