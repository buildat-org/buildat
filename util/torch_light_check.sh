#!/bin/bash
# tier: full
# needs: pixels
# cost: ~2 min (2026-10-11)
# covers: src/impl/mesh.cpp extensions/luanti_client/res/PBRVoxel.glsl
# [TORCH_LIGHT]: a torch lights the dark around it on the pbr path. Vanilla
# (the minimal game) drawn pbr_debug_baked -- the lamp term alone, linear,
# the key pinned -- with a light_source 12 node as the torch:
#   - a sealed 5x4x5 chamber, and the same with a shaft to the sky, the
#     torch in the middle and the camera in the same corner: the two
#     pictures the same and lit (the mesher's rays read nought in a room
#     that small and put the torch out);
#   - a corridor sixteen long, the torch at the far end and the camera
#     thirteen nodes off looking down its floor: the floor's light rises
#     from nothing past the flood's reach to the torch, with no step a
#     node.
#   util/torch_light_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp torch_light; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/s
mkdir -p "$d/apps/vanilla/saves/tl/luanti" "$d/shared"
cat > "$d/shared/fixture.lua" <<'L'
-- Not pointable: the crosshair's frame on the floor would cross the
-- column the corridor is measured down
core.register_node(":tl:wall", {tiles = {"[fill:16x16:#808080"}, pointable = false})
core.register_node(":tl:torch", {drawtype = "airlike", paramtype = "light",
	sunlight_propagates = true, walkable = false, pointable = false,
	light_source = 12})
-- A box of wall from a to b with the inside air
local function box(a, b)
	for x = a.x, b.x do for y = a.y, b.y do for z = a.z, b.z do
		local edge = x == a.x or x == b.x or y == a.y or y == b.y or
				z == a.z or z == b.z
		core.set_node({x = x, y = y, z = z}, {name = edge and "tl:wall" or "air"})
	end end end
end
local Y = 100
local places = {
	-- name, the box, the torch, the feet, the yaw
	{"A", {x = -3, y = Y - 1, z = -3}, {x = 3, y = Y + 4, z = 3},
		{x = 0, y = Y + 1, z = 0}, {x = -2, y = Y - 0.5, z = -2}, 7 * math.pi / 4},
	{"B", {x = 37, y = Y - 1, z = -3}, {x = 43, y = Y + 4, z = 3},
		{x = 40, y = Y + 1, z = 0}, {x = 38, y = Y - 0.5, z = -2}, 7 * math.pi / 4},
	{"C", {x = 79, y = Y - 1, z = -1}, {x = 96, y = Y + 2, z = 1},
		{x = 80, y = Y + 1, z = 0}, {x = 93, y = Y - 0.5, z = 0}, math.pi / 2, 0.6},
}
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0, speed = 0})
	core.after(2, function()
		core.emerge_area({x = -10, y = Y - 10, z = -10}, {x = 100, y = Y + 40, z = 10},
				function(_, _, left)
			if left > 0 then return end
			for _, p in ipairs(places) do
				box(p[2], p[3])
				core.set_node(p[4], {name = "tl:torch"})
			end
			-- B's shaft, up through the roof to the open sky
			for y = Y + 4, Y + 30 do core.set_node({x = 40, y = y, z = 2}, {name = "air"}) end
			local function show(i)
				local p, pl = places[i], core.get_player_by_name(name)
				if not p or not pl then return end
				pl:set_pos(p[5])
				pl:set_look_horizontal(p[6])
				pl:set_look_vertical(p[7] or 0.25)
				core.after(4, function()
					core.chat_send_player(name, "tl: " .. p[1])
					core.after(4, function() show(i + 1) end)
				end)
			end
			show(1)
		end)
	end)
end)
L
echo "enable_damage = false" > "$d/apps/vanilla/saves/tl/luanti/world.mt"
BUILDAT_RENDER_MODE=pbr_debug_baked BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=tl \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
{
	# A's wait is the world's start; B and C come 8 s apart (the fixture's)
	echo "wait_log 180000 chat: tl: A"; echo "screenshot $t/A.png"
	for p in B C; do
		echo "wait_log 30000 chat: tl: $p"; echo "screenshot $t/$p.png"
	done
	echo "wait_log 10000 Wrote screenshot"; echo quit
} > "$t/cmds"
BUILDAT_RENDER_MODE=pbr_debug_baked BUILDAT_VOXEL_LINEAR=1 \
	run_client 60 "$t/client.log" timeout 240 "$here/Build/bin/buildat" \
	-C "$t/nc" -D "$t/nu" -s 127.0.0.1:$SERVER_PORT -w 640x360 -u 1 -l 3 \
	-o sound_mute=1 -c @"$t/cmds"
grep -aq "drawing the world pbr_debug_baked" "$t/client.log" ||
	fail "not drawn pbr_debug_baked ($t/client.log)"
python3 - "$t" <<'PY' || fail "the pictures ($t)"
import sys
import numpy as np
from PIL import Image
t = sys.argv[1]
def img(n):
    return np.array(Image.open("%s/%s.png" % (t, n)).convert("RGB")).astype(float)
a, b = img("A"), img("B")
la, lb = a.mean(), b.mean()
diff = np.abs(a - b).mean()
print("sealed %.1f, with a shaft %.1f, apart %.1f" % (la, lb, diff))
assert la > 30, "the sealed chamber is dark: %.1f" % la
assert diff < 0.1 * la, "the two chambers differ by %.1f of %.1f" % (diff, la)
# The corridor's floor down a column beside the crosshair (the green
# channel, so the far end's clipped red stays out of it), from under the
# hotbar's top -- the floor two nodes off, past the light's reach -- up to
# the far end at the torch
c = img("C")[..., 1]
h, w = c.shape
col = c[:, w // 2 + 12:w // 2 + 20].mean(axis=1)[60:h - 65][::-1]
print("the corridor's floor, near to far: " +
      " ".join("%.0f" % v for v in col[::15]))
assert col[0] < 3, "the floor out of reach is lit: %.0f" % col[0]
assert col[-1] > 40, "the floor at the torch is dark: %.0f" % col[-1]
# Rising toward the torch, and no step a node: a face of one level drew
# a jump of a level's worth between two rows of pixels
jump = np.abs(np.diff(col)).max()
print("the largest jump between two rows: %.1f of %.0f" % (jump, col[-1]))
assert jump < 0.1 * col[-1], "a step: %.1f" % jump
for i in range(15, len(col), 15):
    assert col[i] >= col[i - 15] - 2, "it falls toward the torch at row %d" % i
PY
echo "PASS: the torch lights a sealed chamber as it does one with a shaft, and its light falls smoothly to nothing down a corridor"
