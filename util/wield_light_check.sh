#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-11)
# covers: builtin/luanti/lua/buildat_api.lua builtin/luanti/mods/wield_light/init.lua builtin/luanti/lua/modloader.lua builtin/luanti/client_lua/module.lua
# [BUILDAT_WIELD_LIGHT]: a held torch is a light the client draws at the
# player, nothing written into the map. VoxeLibre with wield_light turned
# on in world.mt: a sealed stone room high up at night, the player walked
# a hundred steps through it with a torch in hand, then the torch put
# away. The map's lamp light over the room, walls included, the same
# voxel for voxel before the torch and after the walk (vl_wieldlight is
# off by the modloader's default); the client told of one light on the
# player at the torch's level, then of none; the room lit around the
# player with the torch and dark without.
# Needs mineclone2 in the desk's games.
#   util/wield_light_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || { echo "SKIP: no mineclone2"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp wield_light; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/s
mkdir -p "$d/apps/vanilla/saves/wl/luanti" "$d/shared/vanilla/games"
cp -r "$G" "$d/shared/vanilla/games/"
cat > "$d/shared/fixture.lua" <<'L'
local C = {x = 0, y = 155, z = 0}
local R = {x = 8, y = 4, z = 4} -- the inside: x -8..8, y 0..4, z -4..4
local P1 = vector.subtract(C, {x = R.x + 1, y = 1, z = R.z + 1})
local P2 = vector.add(C, {x = R.x + 1, y = R.y + 1, z = R.z + 1})
local function say(s) core.log("warning", "wl: " .. s) end
local function room()
	for z = P1.z, P2.z do for y = P1.y, P2.y do for x = P1.x, P2.x do
		local inside = x > P1.x and x < P2.x and y > P1.y and y < P2.y and
				z > P1.z and z < P2.z
		core.set_node({x = x, y = y, z = z},
				{name = inside and "air" or "mcl_core:stone"})
	end end end
end
local function lamp()
	local vm = VoxelManip(P1, P2)
	local area = VoxelArea(vm:get_emerged_area())
	local l = vm:get_light_data()
	local out = {}
	for z = P1.z, P2.z do for y = P1.y, P2.y do for x = P1.x, P2.x do
		out[#out + 1] = math.floor(l[area:index(x, y, z)] / 16)
	end end end
	return out
end
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0, speed = 0})
	core.after(2, function()
		core.emerge_area(P1, P2, function(_, _, left)
			if left > 0 then return end
			room()
			core.set_timeofday(0)
			local p = core.get_player_by_name(name)
			if not p then return end
			p:set_pos({x = C.x - 6, y = C.y, z = C.z})
			p:set_look_horizontal(3 * math.pi / 2)
			p:set_look_vertical(0.3)
			p:get_inventory():set_stack("main", 1, "")
			p:set_wield_index(1)
			core.after(3, function()
				local before = lamp()
				say("vl_wieldlight " .. tostring(core.settings:get("enable_vl_wieldlight")))
				core.chat_send_player(name, "wl: dark")
				core.after(2, function()
					p:get_inventory():set_stack("main", 1, "mcl_torches:torch")
					local step = 0
					local function walk()
						if not p:is_valid() then return end
						step = step + 1
						local k = step % 20
						local x = (k < 10 and k or 20 - k) - 5
						p:set_pos({x = C.x + x, y = C.y, z = C.z})
						if step < 100 then
							core.after(0.05, walk)
							return
						end
						p:set_pos({x = C.x - 6, y = C.y, z = C.z})
						core.after(2, function()
							local after, n = lamp(), 0
							for i = 1, #before do
								if before[i] ~= after[i] then n = n + 1 end
							end
							say("walked " .. step .. ", " .. n .. " of " ..
									#before .. " voxels' lamp light changed")
							core.chat_send_player(name, "wl: torch")
							core.after(3, function()
								p:get_inventory():set_stack("main", 1, "")
								core.after(3, function()
									core.chat_send_player(name, "wl: away")
								end)
							end)
						end)
					end
					walk()
				end)
			end)
		end)
	end)
end)
L
printf "load_mod_wield_light = true\n" > "$d/apps/vanilla/saves/wl/luanti/world.mt"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=wl \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 180 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
{
	for p in dark torch away; do
		echo "wait_log 300000 chat: wl: $p"; echo "delay 500"
		echo "screenshot $t/$p.png"
	done
	echo "delay 500"; echo quit
} > "$t/cmds"
run_client 60 "$t/cl.log" timeout 400 "$here/Build/bin/buildat" \
	-C "$t/nc" -D "$t/nu" -s 127.0.0.1:$SERVER_PORT -w 640x360 -u 1 -l 3 \
	-o sound_mute=1 -c @"$t/cmds"
grep -aq "wl: vl_wieldlight false" "$t/srv.log" ||
	fail "vl_wieldlight not turned off ($t/srv.log)"
w=$(grep -ao "wl: walked .*" "$t/srv.log" | tail -1)
echo "$w"
echo "$w" | grep -q "walked 100, 0 of" || fail "the map's light changed: $w ($t/srv.log)"
grep -a "luanti:lights:" "$t/cl.log" | sed 's/.*luanti:lights: //' > "$t/lights"
cat "$t/lights"
# The empty list a joining player is sent, the torch's light, none
[ "$(tr '\n' '|' < "$t/lights")" = "0: |1: o self 14|0: |" ] ||
	fail "not told of the light at 14 once and then of none ($t/cl.log)"
python3 - "$t" <<'PY' || fail "the pictures ($t)"
import sys
import numpy as np
from PIL import Image
t = sys.argv[1]
def lum(n):
    a = np.array(Image.open("%s/%s.png" % (t, n)).convert("L")).astype(float)
    # Above the hotbar
    return a[:int(a.shape[0] * 0.75)].mean()
d, l, a = lum("dark"), lum("torch"), lum("away")
print("dark %.1f, with the torch %.1f, put away %.1f" % (d, l, a))
assert l > d + 10, "the torch lights nothing"
# Not all the way: the eye's adaptation to the lit room takes longer
assert a < d + 0.3 * (l - d), "put away, the room is still lit"
PY
echo "PASS: the torch is the client's light at the player, and the map's light is untouched"
