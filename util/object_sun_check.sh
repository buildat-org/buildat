#!/bin/bash
# tier: full
# needs: pixels
# cost: ~1 min (2026-10-15)
# covers: extensions/luanti_client/world.lua extensions/luanti_client/world_object_meshes.lua extensions/luanti_client/res/PBRLitAlphaMask.xml
# [OBJECT_SUN]: objects under pbr are lit by the sun's direction and its
# shadow map, and cast into it. luanti_client pbr on official Luanti's
# devtest, a stone floor in the morning sun with a roof over part of it,
# looked at from the east (the sun's side): two of devtest's sam, one in
# the sun and one under the roof, both lit by the sky.
#   - the floor where the sunlit sam's shadow falls is darker than the
#     floor beside it (before, an object cast nothing);
#   - the sunlit sam's arm toward the sun is lighter than the arm of the
#     one under the roof (before, both took the same fixed share of sun).
# simplified: luanti_client only; vanilla's and skelenti's models take the
# same path in builtin/luanti module.lua, checked by shots by hand
# (2026-10-15). The regions are fixed pixels of a fixed scene.
#   util/object_sun_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
G="$BUILDAT_USER_PATH/shared/vanilla/games/devtest"
command -v luanti > /dev/null && [ -d "$G" ] || skip "no luanti or devtest"
check_tmp object_sun; t=$CHECK_TMP
lsrv=
trap '[ -n "$lsrv" ] && kill $lsrv 2>/dev/null; check_cleanup' EXIT
mkdir -p "$t/games" "$t/w/worldmods/fx" "$t/lcl"
cp -r "$G" "$t/games/"
printf 'gameid = devtest\nbackend = sqlite3\n' > "$t/w/world.mt"
echo "name = fx" > "$t/w/worldmods/fx/mod.conf"
cat > "$t/w/worldmods/fx/init.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0})
	player:set_pos({x = 12, y = 201, z = 0})
	core.after(4, function()
		local p = core.get_player_by_name(name)
		core.set_timeofday(0.42)
		for x = -3, 12 do for z = -8, 8 do
			core.set_node({x = x, y = 200, z = z}, {name = "basenodes:stone"})
		end end
		for x = 3, 9 do for z = 1, 6 do
			core.set_node({x = x, y = 204, z = z}, {name = "basenodes:stone"})
		end end
		p:set_pos({x = 12, y = 201, z = 0})
		p:set_look_horizontal(math.pi / 2)
		p:set_look_vertical(0.3)
		core.add_entity({x = 6, y = 201, z = -3}, "testentities:sam")
		core.add_entity({x = 3.5, y = 201, z = 3.5}, "testentities:sam")
		core.after(3, function() core.chat_send_player(name, "fx: ready") end)
	end)
end)
L
P=$((30200 + RANDOM % 300))
LUANTI_GAME_PATH="$t/games" MINETEST_GAME_PATH="$t/games" \
	luanti --server --world "$t/w" --port $P > "$t/l.log" 2>&1 &
lsrv=$!
for _ in $(seq 60); do
	grep -q "listening on" "$t/l.log" && break
	kill -0 $lsrv 2>/dev/null || fail "luanti died ($(tail -3 "$t/l.log"))"
	sleep 0.5
done
now=$(date +%s)
echo "\"true\",\"udp://127.0.0.1:$P\",\"\",\"$now\",\"$now\",\"\",\"\",\"\"" \
	> "$t/lcl/network_addresses.csv"
# The wait after the line: the shadow map and the objects' light settle
printf 'wait_log 60000 loading done\nwait_log 30000 fx: ready\ndelay 6000\nscreenshot %s\nquit\n' \
	"$t/shot.png" > "$t/lc.cmds"
(cd "$here/Build" && BUILDAT_RENDER_MODE=pbr BUILDAT_LUANTI_ADDRESS=127.0.0.1:$P \
	BUILDAT_LUANTI_CONNECT=1 BUILDAT_LUANTI_NAME=oscheck timeout 150 \
	bin/buildat -m luanti_client -D "$t/lcl" -w 1000x600 -l 3 \
	-o sound_mute=1 -c @"$t/lc.cmds" > "$t/c.log" 2>&1) ||
	fail "the drive ($t/c.log): $(grep -a "Command sequence failed" "$t/c.log" | tail -1)"
python3 - "$t/shot.png" <<'P' || fail "($t/shot.png)"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('L')
def m(x0, y0, x1, y1):
	px = [im.getpixel((x, y)) for x in range(x0, x1) for y in range(y0, y1)]
	return sum(px) / len(px)
cast, floor = m(305, 298, 335, 310), m(360, 298, 390, 310)
lit, shaded = m(270, 226, 290, 245), m(674, 208, 686, 222)
print("cast shadow %.0f, floor beside %.0f; sunlit arm %.0f, roofed arm %.0f"
		% (cast, floor, lit, shaded))
ok = cast < floor * 0.8 and lit > shaded * 1.15
print("PASS: a sam lit by the sun and casting a shadow" if ok else
		"FAIL: no cast shadow or no sun on the sunlit sam")
sys.exit(0 if ok else 1)
P
# vim: set noet ts=4 sw=4:
