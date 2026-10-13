#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: 190s
# covers: builtin/luanti/vendor/builtin/game/item.lua builtin/luanti/lua/sound.lua
# **Does digging make a noise** ([NO_SOUND], the user's bar of 2026-09-24:
# "a mod that never mentions sound still sounds right in Luanti"). Unlike
# the footstep, this one is not the engine's: the vendored builtin's
# node_dig calls core.sound_play with the node's own `dug` group
# (vendor/builtin/game/item.lua:566), and item_place does the same with
# `place` (:289), so what this proves is that the call reaches the
# client's mixer rather than falling down a hole between the two halves.
#
#   builtin/luanti/test/dig_sound.sh
#
# The plan said for a day that digging and placing were "still silent".
# They are not, and this is the check that says so rather than a reading
# of the source.
#
# minetest_game, because its nodes carry sounds; devtest's do not, which
# is why footstep.sh does not ask devtest either. The client runs at -l 4
# because the sound the module plays is a debug line -- a game's own
# sounds are many and an info line a piece would drown the log.
#
# **No device is opened**: SDL_AUDIODRIVER=disk writes the mix to a file,
# which is the user's rule of 2026-09-24 (no default script may put audio
# on the system's hardware). What is read here is the module's own line,
# not the mix; sound.sh is the one that measures the samples.
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
. "$me/lib.sh"
out="$here/local/dig_sound"; mkdir -p "$out"
save=buildat_test_digsound
port=31996
GAME="${GAME:-minetest_game}"
cd "$here/Build"
[ -d "$BUILDAT_USER_PATH/shared/vanilla/games/$GAME" ] || {
	echo "SKIP: $GAME is not installed" >&2; exit "$SKIP"; }
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running" >&2
	exit "$SKIP"
fi
cat > "$out/fixture.lua" <<'LUA'
-- A flat platform of one node with the player standing on it, the same
-- shape footstep.sh uses, and the player looking straight down at it so
-- that what the crosshair points at is the node under their feet.
local ORIGIN = {x = 8, y = 10, z = 8}
core.register_on_joinplayer(function(player)
	-- **Asked here and not at the file's scope**: this file is loaded
	-- before the game's mods are, so a lookup up there finds nothing
	-- whatever the game carries (the first cut of this said "no dirt to
	-- dig" against 439 loaded nodes).
	local dirt = core.registered_nodes["default:dirt"] and "default:dirt" or
			core.registered_nodes["mcl_core:dirt"] and "mcl_core:dirt" or nil
	if dirt == nil then
		core.log("action", "dig_sound: this game has no dirt to dig")
		return
	end
	local def = core.registered_nodes[dirt]
	local dug = def.sounds and def.sounds.dug
	local dug_name = dug and (type(dug) == "table" and
			(dug.name or dug[1]) or dug) or nil
	-- And what the module resolves that group to, since sound_play drops
	-- a sound it has no file for before any packet is sent
	local file = dug_name and __luanti_sound_file and
			__luanti_sound_file(dug_name) or nil
	core.log("action", "dig_sound: " .. dirt .. " is dug as " ..
			tostring(dug_name or "nothing") .. ", which resolves to " ..
			tostring(file or "no file"))
	local air = core.get_content_id("air")
	local cid = core.get_content_id(dirt)
	local p1 = {x = ORIGIN.x - 6, y = ORIGIN.y - 2, z = ORIGIN.z - 6}
	local p2 = {x = ORIGIN.x + 6, y = ORIGIN.y + 6, z = ORIGIN.z + 6}
	local vm = VoxelManip(p1, p2)
	local emin, emax = vm:get_emerged_area()
	local area = VoxelArea(emin, emax)
	local data = vm:get_data()
	for i in area:iterp(p1, p2) do data[i] = air end
	for x = -6, 6 do
		for z = -6, 6 do
			data[area:index(ORIGIN.x + x, ORIGIN.y, ORIGIN.z + z)] = cid
		end
	end
	vm:set_data(data)
	vm:write_to_map()
	player:set_pos({x = ORIGIN.x, y = ORIGIN.y + 1, z = ORIGIN.z})
	core.log("action", "dig_sound: the player stands on " .. dirt)
	-- And to the client, whose log the drive waits on
	core.chat_send_player(player:get_player_name(),
			"dig_sound: the player stands on " .. dirt)
end)
-- What the server actually asked the client to play, so a silent run can
-- be told apart from a run where nothing was dug at all.
--
-- **Wrapped at the first join and not at this file's scope**: this file
-- is loaded before lua/sound.lua defines core.sound_play, so a wrapper
-- up there captures nothing and replaces the real one with a call into
-- nil -- which is how the first cut of this check reported a dig that
-- asked for a sound and a client that never got a packet.
-- **Watched and not wrapped**: on_dignode says the dig went through and
-- leaves core.sound_play alone, which a wrapper cannot be trusted to do
-- -- the first cut of this replaced it with a call into a nil captured
-- before lua/sound.lua had defined it.
core.register_on_dignode(function(pos, node, digger)
	if not (digger and digger.is_player and digger:is_player()) then
		return -- a mod tidying up at load is not the dig this asks about
	end
	core.log("action", "dig_sound: dug " .. (node and node.name or "?") ..
			" at " .. core.pos_to_string(pos) .. "; " ..
			#core.get_connected_players() .. " players, send_sound is " ..
			type(__luanti_send_sound))
end)
LUA
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$out/srv.log" "Mods loaded" 120 "$port" \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
	[ $? = 1 ] || exit 1 # its own verdict below
srv=$SERVER_PID
trap 'kill -INT "$srv" 2>/dev/null' EXIT
if ! grep -aq "Mods loaded" "$out/srv.log"; then
	kill -9 "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
	echo "SKIP: the server did not come up" >&2; exit "$SKIP"
fi
# **Twice: once digging and once not**, because a mix with sound in it
# says only that something played. What the dig is worth is the
# difference between the two, and the still run is also what says the
# game is not playing ambience over the answer.
# The 2 s after the stage's line: the platform drawn and the player landed
# on it in the frames after. The rest are lengths of time: the hold, the
# sound played out into the mix, and the still run's mix to compare with.
{ echo "wait_log_any 60000 chat: dig_sound: the player stands on"
	echo "delay 2000"
	# **Diagonally down, as predict.sh points**: straight down puts the ray
	# in the player's own feet and nothing is pointed at, which is how the
	# first cut of this held the button for three seconds and dug nothing.
	echo "look_dir 1 -1 0"
	echo "delay 500"
	# The hand on dirt takes about a second; three for the machine's sake,
	# and the node is dug once whatever is left of the hold
	echo "mouse_down left"
	echo "delay 3000"
	echo "mouse_up left"
	echo "delay 1500"
	echo "quit"; } > "$out/cmds.txt"
{ echo "wait_log_any 60000 chat: dig_sound: the player stands on"
	echo "delay 2000"
	echo "look_dir 1 -1 0"
	# a timing: the still run's mix, as long as the dig run's from here
	echo "delay 5000"
	echo "quit"; } > "$out/cmds_still.txt"
SDL_AUDIODRIVER=disk SDL_DISKAUDIOFILE="$out/mix.raw" \
	run_client 60 "$out/cli.log" timeout 240 bin/buildat -s "localhost:$port" \
	-w 640x400 -l 4 -o sound_mute=0 -c @"$out/cmds.txt" > /dev/null 2>&1 ||
	{ echo "FAIL: the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*\|run_client:.*' "$out/cli.log" | head -1)"; exit 1; }
SDL_AUDIODRIVER=disk SDL_DISKAUDIOFILE="$out/mix_still.raw" \
	run_client 60 "$out/cli_still.log" timeout 240 bin/buildat -s "localhost:$port" \
	-w 640x400 -l 4 -o sound_mute=0 -c @"$out/cmds_still.txt" > /dev/null 2>&1 ||
	{ echo "FAIL: the still drive ($out/cli_still.log): $(grep -ao 'Command sequence failed.*\|run_client:.*' "$out/cli_still.log" | head -1)"; exit 1; }
kill -INT "$srv" 2>/dev/null
# The server's exit, polled
for i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
asked=$(grep -ac "dig_sound: dug " "$out/srv.log")
name=$(grep -a "dig_sound: dug " "$out/srv.log" | head -1 |
	sed 's/.*dug //')
heard=$(grep -ac "luanti: dug " "$out/cli.log")
first=$(grep -a "luanti: dug " "$out/cli.log" | head -1 |
	sed 's/.*luanti: //')
none=$(grep -ac "luanti: no dug sound" "$out/cli.log")
# What the mixer wrote, loud samples against the whole: the disk driver
# writes 16-bit frames in real time, so this is "how much of the run had
# a sound in it" and not a measurement of anything finer.
loud() {   # $1 raw file -> loud samples, then total, on one line
	python3 - "$1" <<'PY'
import array, sys
try:
	d = open(sys.argv[1], "rb").read()
except OSError:
	print("0 0"); raise SystemExit
n = len(d) // 2
a = array.array("h"); a.frombytes(d[:n * 2])
print("%d %d" % (sum(1 for v in a if abs(v) > 200), n))
PY
}
set -- $(loud "$out/mix.raw"); dug_loud=$1; dug_n=$2
set -- $(loud "$out/mix_still.raw"); still_loud=$1; still_n=$2
echo "the player dug $asked nodes (first: ${name:-none});" \
		"the client played $heard kinds: ${first:-(nothing)};" \
		"the mix has $dug_loud loud samples of $dug_n against" \
		"$still_loud of $still_n when nothing is dug"
if [ "$asked" -lt 1 ]; then
	echo "FAIL: nothing was dug, so the sound was never asked for"
	grep -a "dig_sound:" "$out/srv.log" | head -3
	exit 1
fi
if [ "$heard" -lt 1 ]; then
	echo "FAIL: a node was dug and the client played nothing"
	[ "$none" -gt 0 ] && grep -a "luanti: no dug sound" "$out/cli.log" | head -2
	exit 1
fi
# Ten times the still run's, which on a silent game is ten times nothing
# and on a noisy one is the dig standing out of it
if [ "$dug_loud" -lt $((still_loud * 10 + 1000)) ]; then
	echo "FAIL: the mix is no louder for digging than for standing still"
	exit 1
fi
echo "PASS: digging plays the node's own sound, and the mixer has it"
exit 0
# vim: set noet ts=4 sw=4:
