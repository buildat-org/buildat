#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# needs: pixels
# [TUNNEL_SKY]: down a tunnel longer than the view range, what lies past the
# far clip is the sky; where the camera sees no skylight it is to be drawn
# dim, not as the noon sky. Three tunnels at noon in one rock mass high in
# the air, 3x3 inside, the near end sealed: one 130 long, open at the far
# end (past the view range); one 24 long, its mouth into a canyon open to
# the sky; one 130 long with a shaft to the top beside the camera. A frame
# looking down each and one up the shaft; printed is the mean luma of the
# far end (just above the crosshair; up the shaft, the centre) and of the
# wall beside it, then the client's gate log.
# Needs the Luanti checkout and its server binary for luanti_client.
#
#   builtin/luanti/test/tunnel_sky.sh [vanilla|ext|official] [range] [mode]
#   (vanilla, 40, pbr by default)
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
which=${1:-vanilla}; range=${2:-40}; mode=${3:-pbr}
out="$here/local/tunnel_sky/${which}_${mode}_r$range"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti}
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a client or a server is already running"; exit 77
fi
trap check_cleanup EXIT
fixture='core.settings:set("time_speed", "0")
core.settings:set("mobs_spawn", "false")
local Y = 100
-- x of each tunnel, its length, and whether a shaft opens above its start
local tunnels = {{x = 0, len = 130}, {x = 20, len = 24}, {x = 40, len = 130, shaft = true}}
-- One rock mass the tunnels are carved in, as a cave is, rather than
-- shells in the open air: the reading of Luanti samples from 0.6 of the
-- range out (up to 60) in a cone some 60 degrees wide, which past a thin
-- shell is the sunlit air. Through a VoxelManip, whole blocks with their
-- light.
local D = 50
local P1, P2 = {x = -D, y = Y - D, z = -D}, {x = 40 + D, y = Y + D, z = 130}
-- Two passes, the rock and then the tunnels: buildat_server relighting the
-- one write left the carved air lit from the open air that was there
-- (13 of 15 in the sealed tunnel; Luanti relights it to 0)
local function build(carve_too)
	local vm = core.get_voxel_manip()
	local e1, e2 = vm:read_from_map(P1, P2)
	local area = VoxelArea(e1, e2)
	local data = vm:get_data()
	local stone, air = core.get_content_id("mcl_core:stone"), core.CONTENT_AIR
	for i in area:iterp(P1, P2) do
		data[i] = stone
	end
	local function carve(x1, y1, z1, x2, y2, z2)
		for i in area:iter(x1, y1, z1, x2, y2, z2) do
			data[i] = air
		end
	end
	for _, t in ipairs(carve_too and tunnels or {}) do
		-- 3x3 inside, the near end sealed; the long ones run out of the
		-- far face of the mass
		carve(t.x - 1, Y, 0, t.x + 1, Y + 2, t.len)
		if t.shaft then
			-- 1x1 up from the roof over z = 3, to the top
			carve(t.x, Y + 3, 3, t.x, P2.y, 3)
		end
		if t.len < 100 then
			-- the short one opens into a canyon open to the sky
			carve(t.x - 6, Y, t.len + 1, t.x + 6, P2.y, t.len + 30)
		end
	end
	vm:set_data(data)
	vm:calc_lighting()
	vm:write_to_map(true)
	core.fix_light(P1, P2)
end
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.set_timeofday(0.5)
	core.emerge_area(P1, {x = P2.x, y = P2.y + 3, z = P2.z + 5},
			function(_, _, left)
		if left > 0 then return end
		build(false)
		core.after(10, function()
			build(true)
			core.log("action", "tunnel_sky: built")
		end)
		-- The first a while after the build: the relight of a
		-- box this size takes its time, and until it is done the carved
		-- air keeps the daylight of the air that was there
		for i, t in ipairs(tunnels) do
			core.after(40 + 15 * (i - 1), function()
				player:set_pos({x = t.x, y = Y, z = 0})
				player:set_look_horizontal(0)
				player:set_look_vertical(0)
			end)
			core.after(40 + 15 * (i - 1) + 10, function()
				core.chat_send_player(name, "tunnel_sky: step " .. i)
				core.log("action", "tunnel_sky: step " .. i)
			end)
		end
		-- And straight up the shaft from under it
		core.after(85, function()
			player:set_pos({x = 40, y = Y, z = 3})
			player:set_look_vertical(-math.pi / 2)
		end)
		core.after(95, function()
			core.chat_send_player(name, "tunnel_sky: step 4")
			core.log("action", "tunnel_sky: step 4")
		end)
	end)
end)'
cmds(){ # out-dir
	local i
	for i in 1 2 3 4; do
		echo "wait_log $([ $i = 1 ] && echo 420000 || echo 30000) chat: tunnel_sky: step $i"
		echo "delay 2000"; echo "screenshot $1/s$i.png"
	done
	echo quit
}

run_vanilla(){
	local save=buildat_test_tunnel_sky
	rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
	printf '%s\n' "$fixture" > "$out/fixture.lua"
	# The player's view range, kept per server ("View range" in the pause
	# menu): the client did not start this server, so it is the address's
	mkdir -p "$BUILDAT_USER_PATH/servers/localhost_29798"
	printf '%s' "$range" > "$BUILDAT_USER_PATH/servers/localhost_29798/view_range"
	cd "$here/Build"
	BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SEED=${SEED:-2} BUILDAT_LUANTI_SAVE="$save" \
		BUILDAT_LUANTI_LUA="$out/fixture.lua" \
		start_server "$out/srv.log" "Mods loaded" 150 29798 \
		bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3
	local rc=$? srv=${SERVER_PID:-}
	CHECK_PIDS+=($srv)
	[ $rc = 0 ] || { echo "FAIL: the server did not start"; exit 1; }
	cmds "$out" > "$out/cmds.txt"
	BUILDAT_LUANTI_LIGHT_LOG=1 BUILDAT_RENDER_MODE=$mode timeout 600 \
		bin/buildat -s localhost:29798 \
		-w 1280x720 -l 3 -o sound_mute=1 -c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
		{ echo "FAIL: the vanilla drive ($out/cli.log)"; exit 1; }
	kill -INT "$srv" 2>/dev/null
	for _i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
}

# The Luanti server, and in front of it luanti_client or (official=1)
# official Luanti's patched client (reference_shots/shoot_luanti_server.sh's,
# no pointer grab), its window photographed at each step
run_ext(){
	local official=${1:-} work="$out/world" port=30034
	[ -x "$bin" ] || { echo "SKIP: no Luanti server at $bin"; exit 77; }
	rm -rf "$work"; mkdir -p "$work/worldmods/tunnel_sky"
	printf 'gameid = mineclone2\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\nworld_name = tunnel_sky\ncreative_mode = false\nenable_damage = false\nserver_announce = false\n' \
		> "$work/world.mt"
	printf '%s\n' "$fixture" > "$work/worldmods/tunnel_sky/init.lua"
	printf 'name = tunnel_sky\n' > "$work/worldmods/tunnel_sky/mod.conf"
	printf 'fixed_map_seed = 2\nenable_damage = false\nmute_sound = true\n' \
		> "$out/luanti.conf"
	# The extension's own settings: the view range
	mkdir -p "$BUILDAT_USER_PATH/extensions/luanti_client"
	printf '{"view_range": %s}' "$range" \
		> "$BUILDAT_USER_PATH/extensions/luanti_client/settings.json"
	check_allow "udp://127.0.0.1:$port"
	"$bin" --server --world "$work" --port "$port" --config "$out/luanti.conf" \
		> "$out/luanti_srv.log" 2>&1 &
	local srv=$!
	CHECK_PIDS+=($srv)
	for _i in $(seq 1 600); do
		grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && break
		kill -0 "$srv" 2>/dev/null || break
		sleep 0.2
	done
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null ||
		{ echo "FAIL: the Luanti server did not start ($out/luanti_srv.log)"; exit 1; }
	if [ -n "$official" ]; then
		local ref="$here/builtin/luanti/test/reference_shots"
		{
			cat "$ref/luanti.conf"
			printf 'screen_w = 1280\nscreen_h = 720\nviewing_range = %s\nname = ts\n' "$range"
			[ "$mode" = unlit ] && echo "enable_dynamic_shadows = false"
		} > "$out/client.conf"
		(cd "$luanti" && exec "${LUANTI_CLIENT:-./bin/luanti-refshots}" --go \
			--address 127.0.0.1 --port "$port" --name ts \
			--config "$out/client.conf") > "$out/cli.log" 2>&1 &
		local cli=$! win="" i
		CHECK_PIDS+=($cli)
		for i in $(seq 1 60); do
			sleep 1
			win=$(wmctrl -lp 2>/dev/null | awk -v p="$cli" '$3 == p {print $1; exit}')
			[ -n "$win" ] && break
		done
		[ -n "$win" ] || { echo "FAIL: no window for the official client"; exit 1; }
		for i in 1 2 3 4; do
			for _j in $(seq 1 600); do
				grep -q "tunnel_sky: step $i" "$out/luanti_srv.log" && break
				sleep 0.5
			done
			sleep 2
			import -window "$win" "$out/s$i.png" 2>/dev/null ||
				echo "no picture of step $i"
		done
		kill "$cli" "$srv" 2>/dev/null
		for _i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
		return
	fi
	cmds "$out" > "$out/cmds.txt"
	BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=ts \
		BUILDAT_LUANTI_CONNECT=1 BUILDAT_RENDER_MODE=$mode timeout 600 \
		"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
		-o sound_mute=1 -c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
		{ echo "FAIL: the luanti_client drive ($out/cli.log)"; exit 1; }
	kill "$srv" 2>/dev/null
	for _i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
}

case "$which" in
	vanilla) run_vanilla ;;
	ext) run_ext ;;
	official) run_ext 1 ;;
	*) echo "usage: $0 [vanilla|ext|official] [range] [mode]"; exit 2 ;;
esac
python3 -I - "$out" <<'PY'
import os, sys
from PIL import Image, ImageStat
out = sys.argv[1]
for n, what in enumerate(["long", "mouth", "shaft", "up"], 1):
    p = "%s/s%d.png" % (out, n)
    if not os.path.exists(p):
        print("%-5s no shot" % what); continue
    im = Image.open(p).convert("L")
    w, h = im.size
    # Above the crosshair, inside the far end's square
    dy = 0 if what == "up" else 17
    end = ImageStat.Stat(im.crop((w // 2 - 10, h // 2 - 5 - dy, w // 2 + 10, h // 2 + 5 - dy))).mean[0]
    wall = ImageStat.Stat(im.crop((w // 2 - 300, h // 2 - 40, w // 2 - 200, h // 2 + 40))).mean[0]
    print("%-5s far end %5.1f  wall %5.1f" % (what, end, wall))
PY
rc=$?
grep -a "cave gate\|tunnel_sky: step" "$out/cli.log" 2>/dev/null | grep -o "tunnel_sky: step [0-9]$\|cave gate.*" | tail -50
[ $rc = 0 ] && echo "PASS: measured; the lumas above are the result"
# vim: set noet ts=4 sw=4:
