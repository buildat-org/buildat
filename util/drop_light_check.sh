#!/bin/bash
# tier: broken
# broken: back to full; the drops' light; the same on dev
#   (local/runs/dev_baseline)
# cost: ~2 min (2026-10-11)
# covers: builtin/luanti/client_lua/module.lua
# [DROP_LIGHT_FIRST]: an item dropped by a dug node is lit right from its
# first frame. Vanilla on VoxeLibre, a tunnel in a block of stone with
# a torch in it: the client digs the column under the player, held, so
# a drop pops up into the voxel dug a moment before (which arrives as air
# with no light and is relit a second or more later), at noon and at
# midnight; and at noon the same on a block of stone in the open. Each
# drop's first light, from the client's log, against the last within
# three seconds while in the same voxel: at most a level apart (a neighbour's reading is a
# gradient's step off); the tunnel's lit by the torch, the open one by
# the sun from the first.
#   util/drop_light_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || { echo "SKIP: no VoxeLibre at $G"; exit 0; }
check_tmp drop_light; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/s
mkdir -p "$d/apps/vanilla/saves/dl/luanti" "$d/shared/vanilla/games"
cp -r "$G" "$d/shared/vanilla/games/"
cat > "$d/shared/fixture.lua" <<'L'
local Y = -30
local T = {x = 3, y = Y, z = 0}
local function say(s) core.log("warning", "dl: " .. s) end
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0, speed = 0})
	core.after(2, function()
		core.emerge_area({x = -6, y = Y - 6, z = -6}, {x = 6, y = 106, z = 6},
				function(_, _, left)
			if left > 0 then return end
			-- The tunnel, x -2..3 and three high, in a block of stone
			for x = -3, 4 do for y = Y - 3, Y + 3 do for z = -2, 2 do
				local air = z == 0 and x >= -2 and x <= 3 and y >= Y and y <= Y + 2
				core.set_node({x = x, y = y, z = z}, {name = air and "air" or "mcl_core:stone"})
			end end end
			core.set_node(T, {name = "mcl_torches:torch", param2 = 1})
			for x = -2, 2 do for y = 99, 101 do for z = -2, 2 do
				core.set_node({x = x, y = y, z = z}, {name = "mcl_core:stone"})
			end end end
			local p = core.get_player_by_name(name)
			p:get_inventory():set_stack("main", 1, "mcl_tools:pick_diamond")
			p:set_wield_index(1)
			-- name, time of day, where the player stands, looking down
			local phases = {
				{"noon", 0.5, {x = 2, y = Y, z = 0}},
				{"night", 0, {x = 1, y = Y, z = 0}},
				{"open", 0.5, {x = 0, y = 102, z = 0}},
			}
			local function phase(i)
				local ph = phases[i]
				if not ph then
					core.chat_send_player(name, "dl: done")
					return
				end
				core.set_timeofday(ph[2])
				p:set_pos(ph[3])
				p:set_look_vertical(math.pi / 2)
				core.after(4, function()
					core.chat_send_player(name, "dl: dig " .. ph[1])
					core.after(6, function() phase(i + 1) end)
				end)
			end
			phase(1)
		end)
	end)
end)
L
printf "load_mod_wield_light = false\nenable_damage = false\nmobs_spawn = false\n" \
	> "$d/apps/vanilla/saves/dl/luanti/world.mt"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=dl \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
# The column under the player dug by hand, held: the second drop pops up
# into the voxel dug a moment before. The 1.5 s is the dig's hold; the
# first line comes after the world's start and the emerge, the others
# 10 s apart (the fixture's phases).
{
	first=180000
	for ph in noon night open; do
		echo "wait_log $first chat: dl: dig $ph"; echo "mouse_down left"
		echo "delay 1500"; echo "mouse_up left"
		first=20000
	done
	echo "wait_log 20000 chat: dl: done"; echo quit
} > "$t/cmds"
run_client 60 "$t/client.log" timeout 300 "$here/Build/bin/buildat" \
	-C "$t/nc" -D "$t/nu" -s 127.0.0.1:$SERVER_PORT -w 640x360 -u 1 -l 4 \
	-o sound_mute=1 -c @"$t/cmds" || fail "the drive ($t/client.log)"
grep -a "dl: " "$t/srv.log" | cut -c 30-
python3 - "$t/client.log" <<'PY' || fail "the drops' light ($t/client.log)"
import re, sys
from datetime import datetime
def when(l):
    return datetime.strptime(l.split()[2], "%H:%M:%S.%f").timestamp()
phase, at, drops = None, 0, {}
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"luanti +: chat: dl: dig (\w+)", l)
    if m:
        phase, at = m.group(1), when(l)
        continue
    m = re.search(r"luanti: object (\S+) lit at (\S+),(\S+),(\S+) sky (\d+) lamp (\d+)", l)
    if not m or phase is None:
        continue
    x, y, z = (float(v) for v in m.group(2, 3, 4))
    near = (abs(x) < 3 and abs(z) < 3 and y > 99) if phase == "open" else \
        (abs(x - 1.5) < 2 and abs(z) < 2 and -33 < y < -28)
    if not near or when(l) - at > 3:
        continue
    seen = drops.setdefault(m.group(1), {"phase": phase, "lit": [], "at": []})
    seen["lit"].append((int(m.group(5)), int(m.group(6))))
    seen["at"].append(tuple(round(v) for v in (x, y + 0.2, z)))
want = {"noon": 2, "night": 2, "open": 1}
for ph, n in want.items():
    got = [k for k, v in drops.items() if v["phase"] == ph]
    assert len(got) >= n, "%s: %d drops seen, not %d" % (ph, len(got), n)
for k, v in drops.items():
    # The last reading in the voxel it was first lit in: one that falls
    # on into a hole dug under it is lit by where it goes
    first = v["lit"][0]
    last = [s for s, a in zip(v["lit"], v["at"]) if a == v["at"][0]][-1]
    print("%s drop %s: first sky %d lamp %d, then %s" % (v["phase"], k,
        first[0], first[1], " ".join("%d/%d" % s for s in v["lit"][1:]) or "unchanged"))
    assert abs(first[0] - last[0]) <= 1 and abs(first[1] - last[1]) <= 1, \
        "drop %s first %s, settled %s" % (k, first, last)
    if v["phase"] == "open":
        assert first[0] >= 14, "the open drop not sunlit at first: %s" % (first,)
    else:
        assert max(first) >= 9, "the tunnel drop dark at first: %s" % (first,)
PY
echo "PASS: the drops are lit from their first frame within a level of what they settle at, in a tunnel at noon and midnight and in the open"
