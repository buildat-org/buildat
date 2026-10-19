#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# needs: pixels
# [LC_PBR_PARITY]: the same scene in both clients' pbr -- a platform high
# in the air at noon, at dusk looking at the sun, at night, and a closed
# stone room lit by a torch, and [CAVE_EXPOSURE_FLOOR]'s two probes: a
# closed stone room with no light (a cave) and a snow
# field under the moon -- vanilla being the reference. One fixture
# builds the scene for both (vanilla's own server, a Luanti server for
# luanti_client). The shots land in local/pbr_pair/<client>/, each pair
# side by side in local/pbr_pair/side_<n>.png (vanilla left); printed per
# pair is the mean and the median luma of the frame and the mean of its
# top third (the sky and its clouds), and a pair whose frames' means
# differ by more than a fifth fails.
# Needs the Luanti checkout and its server binary for luanti_client.
#
#   builtin/luanti/test/pbr_pair.sh [vanilla|ext]   (both by default)
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
out="$here/local/pbr_pair"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti}
which=${1:-both}
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a client or a server is already running"; exit 77
fi
# The servers in CHECK_PIDS are stopped at the exit, a failed one's too
trap check_cleanup EXIT
fixture='core.settings:set("time_speed", "0")
core.settings:set("mobs_spawn", "false")
local P = {x = 0, y = 100, z = 0} -- the platform
local C = {x = 60, y = 100, z = 0} -- the room
local K = {x = 60, y = 100, z = 30} -- the cave: the room with no torch
local N = {x = 0, y = 100, z = 60} -- the snow field
local function build()
	for x = -20, 20 do
		for z = -20, 20 do
			core.set_node({x = P.x + x, y = P.y - 1, z = P.z + z},
					{name = "mcl_core:dirt_with_grass"})
		end
	end
	-- A column to give the frame something upright
	for y = 0, 4 do
		core.set_node({x = P.x, y = P.y + y, z = P.z + 6},
				{name = "mcl_core:stone"})
	end
	-- The rooms: stone all round, 7x5x7 inside, a torch on the floor of
	-- the room; the cave is closed
	for _, R in ipairs({C, K}) do
		for x = -4, 4 do
			for y = -1, 5 do
				for z = -4, 4 do
					local edge = math.abs(x) == 4 or math.abs(z) == 4 or
							y == -1 or y == 5
					core.set_node({x = R.x + x, y = R.y + y, z = R.z + z},
							{name = edge and "mcl_core:stone" or "air"})
				end
			end
		end
	end
	for x = -20, 20 do
		for z = -20, 20 do
			core.set_node({x = N.x + x, y = N.y - 1, z = N.z + z},
					{name = "mcl_core:snowblock"})
		end
	end
	core.set_node({x = C.x, y = C.y, z = C.z + 3}, {name = "mcl_torches:torch",
			param2 = 1})
	core.fix_light({x = P.x - 25, y = P.y - 5, z = P.z - 25},
			{x = C.x + 10, y = C.y + 10, z = N.z + 25})
end
-- step: time of day, where, yaw, pitch (Luanti: up is negative)
local steps = {
	{0.5, P, 0, -0.15},
	{0.77, P, math.pi / 2, -0.05},
	{0.0, P, 0, -0.15},
	{0.5, C, 0, 0.3},
	{0.5, K, 0, 0.3},
	{0.0, N, 0, 0.5},
	{0.0, K, 0, 0.3},
}
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.set_timeofday(0.5)
	core.emerge_area({x = -30, y = 90, z = -30}, {x = 80, y = 110, z = 90},
			function(_, _, left)
		if left > 0 then return end
		build()
		core.log("action", "pbr_pair: built")
		for i, s in ipairs(steps) do
			-- The hour a second before the move: Luanti sends a new time
			-- on its next step and a move at once, so set together the
			-- field showed under the cave hour (noon) for a few frames,
			-- and the meter, at 0.6 a second, was still coming down from
			-- that at the shot (the snow read 47 against 61 settled)
			core.after(14 + 15 * (i - 1), function()
				core.set_timeofday(s[1])
			end)
			core.after(15 + 15 * (i - 1), function()
				player:set_pos({x = s[2].x, y = s[2].y, z = s[2].z})
				player:set_look_horizontal(s[3])
				player:set_look_vertical(s[4])
			end)
			-- Time for the client to light it and its exposure to settle
			core.after(15 + 15 * (i - 1) + 8, function()
				core.chat_send_player(name, "pbr_pair: step " .. i)
			end)
		end
	end)
end)'
# The first step comes after a VoxeLibre join and the fixture's 23 s, each
# next one 15 s after; the fixture has already given the light and the
# exposure their 8 s, and the 2 s after the line are the frames after it
cmds(){ # out-dir
	local i
	for i in 1 2 3 4 5 6 7; do
		echo "wait_log $([ $i = 1 ] && echo 180000 || echo 30000) chat: pbr_pair: step $i"
		echo "delay 2000"; echo "screenshot $1/s$i.png"
	done
	echo quit
}

run_vanilla(){
	local o="$out/vanilla" save=buildat_test_pbr_pair
	rm -rf "$o"; mkdir -p "$o"
	rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
	printf '%s\n' "$fixture" > "$o/fixture.lua"
	cd "$here/Build"
	BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
		BUILDAT_LUANTI_LUA="$o/fixture.lua" \
		start_server "$o/srv.log" "Mods loaded" 150 29797 \
		bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3
	local rc=$? srv=${SERVER_PID:-}
	CHECK_PIDS+=($srv)
	[ $rc = 0 ] || { echo "FAIL: the server did not start"; exit 1; }
	cmds "$o" > "$o/cmds.txt"
	BUILDAT_VANILLA_LIGHT_LOG=1 BUILDAT_RENDER_MODE=pbr timeout 330 \
		bin/buildat -s localhost:29797 \
		-w 1280x720 -l 3 -o sound_mute=1 -c @"$o/cmds.txt" > "$o/cli.log" 2>&1 ||
		{ echo "FAIL: the vanilla drive ($o/cli.log)"; exit 1; }
	kill -INT "$srv" 2>/dev/null
	for _i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
}

run_ext(){
	local o="$out/ext" work="$out/ext/world" port=30033
	[ -x "$bin" ] || { echo "SKIP: no Luanti server at $bin"; exit 77; }
	rm -rf "$o"; mkdir -p "$work/worldmods/pbr_pair"
	printf 'gameid = mineclone2\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\nworld_name = pbr_pair\ncreative_mode = false\nenable_damage = false\nserver_announce = false\n' \
		> "$work/world.mt"
	printf '%s\n' "$fixture" > "$work/worldmods/pbr_pair/init.lua"
	printf 'name = pbr_pair\n' > "$work/worldmods/pbr_pair/mod.conf"
	printf 'fixed_map_seed = 1\nenable_damage = false\nmute_sound = true\n' \
		> "$o/luanti.conf"
	check_allow "udp://127.0.0.1:$port"
	"$bin" --server --world "$work" --port "$port" --config "$o/luanti.conf" \
		> "$o/luanti_srv.log" 2>&1 &
	local srv=$!
	CHECK_PIDS+=($srv)
	# "Server for gameid ... listening" is the server taking connections
	for _i in $(seq 1 600); do
		grep -q "Server for gameid" "$o/luanti_srv.log" 2>/dev/null && break
		kill -0 "$srv" 2>/dev/null || break
		sleep 0.2
	done
	grep -q "Server for gameid" "$o/luanti_srv.log" 2>/dev/null ||
		{ echo "FAIL: the Luanti server did not start ($o/luanti_srv.log)"; exit 1; }
	cmds "$o" > "$o/cmds.txt"
	BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=pp \
		BUILDAT_LUANTI_CONNECT=1 BUILDAT_RENDER_MODE=pbr timeout 330 \
		"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
		-o sound_mute=1 -c @"$o/cmds.txt" > "$o/cli.log" 2>&1 ||
		{ echo "FAIL: the luanti_client drive ($o/cli.log)"; exit 1; }
	kill "$srv" 2>/dev/null
	for _i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
}

[ "$which" = ext ] || run_vanilla
[ "$which" = vanilla ] || run_ext
python3 - "$out" <<'PY'
import os, sys
from PIL import Image, ImageStat
out = sys.argv[1]
names = ["noon", "dusk", "night", "room", "cave", "snow", "cave0"]
bad = []
for n in range(1, 8):
    shots = ["%s/%s/s%d.png" % (out, c, n) for c in ("vanilla", "ext")]
    if not all(os.path.exists(s) for s in shots):
        bad.append("%s: no shot" % names[n - 1]); continue
    ims = [Image.open(s).convert("L") for s in shots]
    w, h = ims[0].size
    whole = [ImageStat.Stat(i).mean[0] for i in ims]
    med = [ImageStat.Stat(i).median[0] for i in ims]
    top = [ImageStat.Stat(i.crop((0, 0, w, h // 3))).mean[0] for i in ims]
    print("%-5s  frame vanilla %5.1f ext %5.1f   median vanilla %3d ext %3d"
          "   top vanilla %5.1f ext %5.1f" % (names[n - 1], whole[0],
          whole[1], med[0], med[1], top[0], top[1]))
    if abs(whole[1] - whole[0]) > max(whole[0], 8) / 5:
        bad.append(names[n - 1])
    side = Image.new("RGB", (w * 2, h))
    for k, s in enumerate(shots):
        side.paste(Image.open(s).convert("RGB"), (w * k, 0))
    side.save("%s/side_%d.png" % (out, n))
for b in bad:
    print("FAIL: " + b)
print("FAIL: see above" if bad else "PASS: every step above held")
sys.exit(1 if bad else 0)
PY
