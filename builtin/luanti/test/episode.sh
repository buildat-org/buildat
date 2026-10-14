#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: long
# [AUTO_PLAYTEST] part 2: a compared episode. episode.lua builds one state
# on official Luanti's server and on this module, the client does one
# scripted thing, and the census the fixture logs is diffed between the
# two. The Luanti server's client is extensions/luanti_client, which is a
# scripted Luanti client; the module's is the launcher.
#
#   EPISODE=dig GAME=mineclone2 builtin/luanti/test/episode.sh
#
# What lands under local/episode/<episode>/: both servers' logs, both
# clients' logs, and the two census lines. Needs the Luanti checkout and
# its server binary the way reference_shots/shoot_luanti_server.sh does,
# and nothing else running.
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
EPISODE="${EPISODE:-dig}"
GAME="${GAME:-mineclone2}"
# The client is driven over its stdin (`-c -`): the runner waits for the
# fixture's `episode: ready` in the server log and only then writes the
# action, and the fixture takes the census this many seconds after ready.
# Timed by delays instead, the module under VoxeLibre missed every window
# -- its steps are seconds long while the world emerges around a player
# put in the sky.
SECONDS_GIVEN="${SECONDS_GIVEN:-20}"
out="$here/local/episode/$EPISODE"
mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}

# The client's part: what the episode is, written to its stdin at ready
case "$EPISODE" in
dig)
	# Straight down for three seconds: the dirt underfoot, by hand
	{ echo "look 0 -89"; echo "mouse_down left"
		echo "delay 3000"; echo "mouse_up left"; } > "$out/cmds.txt" ;;
place)
	# Ten of the game's dirt in the first slot (the fixture puts them
	# there for this episode), one placed on the platform by a right
	# click straight down: the census gains a dirt and the stack loses one
	{ echo "look 0 -89"; echo "mouse_click right"; } > "$out/cmds.txt" ;;
seaplace)
	# Ten dirt in the first slot, one placed by a right click straight down
	# from over the pool: the ray goes through the water (pointable false
	# in VoxeLibre) to the floor, and the dirt lands in the water node over
	# it ([POINTABLE]); the census gains a dirt where the water was
	{ echo "look 0 -89"; echo "mouse_click right"; } > "$out/cmds.txt" ;;
sink)
	# Nothing pressed: the body sinks in the pool and the census says how
	# far in EPISODE_SECONDS, and what the breath is by then
	{ echo "look 0 0"; } > "$out/cmds.txt" ;;
swim)
	# Jump held through the census: swimming up against the sink, held
	# at the surface
	{ echo "look 0 0"; echo "keydown Space"; echo "delay 30000"; echo "keyup Space"; } > "$out/cmds.txt" ;;
fall)
	# Nothing pressed, from four nodes above the surface: the fall into
	# the water, its entry and where the body is by the census
	{ echo "look 0 0"; } > "$out/cmds.txt" ;;
dive)
	# Sneak held through the census: swimming down, and where the body is
	# held against the floor
	{ echo "look 0 0"; echo "keydown Shift"; echo "delay 30000"; echo "keyup Shift"; } > "$out/cmds.txt" ;;
pour)
	# Nothing pressed: the fixture puts a water source on the platform at
	# ready and the census counts what it flowed to, by level
	{ echo "look 0 -89"; } > "$out/cmds.txt" ;;
flood)
	# Nothing pressed: the fixture digs from the sea floor into the cave
	# under it on seed 1 and the census counts the cave's water by level
	{ echo "look 0 -89"; } > "$out/cmds.txt" ;;
*) echo "unknown episode $EPISODE (dig, place, seaplace, sink, swim, fall, dive, pour, flood)" >&2; exit 2 ;;
esac

{ echo "rawset(_G, \"EPISODE_NAME\", \"$EPISODE\")"
	[ -n "${SPOT:-}" ] && echo "rawset(_G, \"EPISODE_SPOT\", \"$SPOT\")"
	echo "rawset(_G, \"EPISODE_SECONDS\", $SECONDS_GIVEN)"
	cat "$me/episode.lua"; } > "$out/fixture.lua"

if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null ||
		pgrep -x luanti-refshots >/dev/null; then
	echo "a server or client is already running" >&2; exit 2
fi
srv=""; cli=""
trap 'kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT

# Wait for ready, write the action into the client, wait for the census.
# The client's stdin is a fifo the runner holds open; closing it is what
# ends the client. Both waits are bounded by the emerge time seen so far.
# And the client's own readiness: the extension builds its voxel registry
# for seconds after it joins (its pointable table is not there until
# then), so its line is waited for too; the module's client says "vanilla
# client ready".
drive() {   # log fifo clilog cliready -> the census line, or nothing
	local log="$1" fifo="$2" clilog="$3" cliready="$4" i
	# Two and a half minutes: a VoxeLibre world and its client are up in
	# two at the most
	for i in $(seq 1 750); do
		grep -aq "episode: ready\|episode: FAILED" "$log" &&
				grep -aq "$cliready" "$clilog" && break
		kill -0 "$cli" 2>/dev/null || break
		sleep 0.2 # a poll
	done
	if grep -aq "episode: ready" "$log"; then
		cat "$out/cmds.txt" > "$fifo"
	else
		echo "the fixture never said ready" >&2
	fi
	# Ten minutes: the module under VoxeLibre has had steps of 47 seconds
	# while it emerged the world around a player put in the sky, and the
	# fixture's timer only fires between them
	for i in $(seq 1 3000); do
		grep -aq "episode: census\|episode: FAILED" "$log" && break
		kill -0 "$cli" 2>/dev/null || break
		sleep 0.2
	done
	grep -a "episode: census" "$log" | sed 's/^.*episode: census //' | head -1
}

# --- the Luanti server, with the extension in front of it
work="$out/luanti_world"
rm -rf "$work"; mkdir -p "$work/worldmods/episode"
cat > "$work/world.mt" <<EOF
gameid = $GAME
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
world_name = episode
creative_mode = false
server_announce = false
EOF
cp "$out/fixture.lua" "$work/worldmods/episode/init.lua"
printf 'name = episode\n' > "$work/worldmods/episode/mod.conf"
# Damage off on the official side only: with it on, VoxeLibre's vl_hudbars
# is active and its globalstep indexes the HUD layers the fixture removed
# (init.lua:99, hud_get nil), and the server dies before the census. The
# module keeps its default (on), so the breath column compares nothing:
# official counts breath only under damage.
{ echo "fixed_map_seed = 1"; echo "time_speed = 0"; echo "enable_damage = false"
	echo "mute_sound = true"; } > "$out/luanti.conf"
port=30030
( cd "$luanti" && exec "$bin" --server --world "$work" --port "$port" \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
srv=$!
# "Server for gameid ... listening" is the server taking connections
for i in $(seq 1 600); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && break
	kill -0 "$srv" 2>/dev/null || break
	sleep 0.2
done
grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null ||
	{ echo "the Luanti server did not come up" >&2; exit 1; }
fifo="$out/extension_stdin"; rm -f "$fifo"; mkfifo "$fifo"
BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=ep \
	BUILDAT_LUANTI_CONNECT=1 \
	"$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
	-c - < "$fifo" > "$out/extension_cli.log" 2>&1 &
cli=$!
exec 3>"$fifo"
luanti_census=$(drive "$out/luanti_srv.log" "$fifo" "$out/extension_cli.log" \
	"voxel types have their own textures")
exec 3>&-
kill "$cli" 2>/dev/null; wait "$cli" 2>/dev/null
kill "$srv" 2>/dev/null
# A poll: the server's exit
for i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
kill -9 "$srv" 2>/dev/null; wait "$srv" 2>/dev/null

# --- the module, with the launcher in front of it
cd "$here/Build"
save=buildat_test_episode
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
# A VoxeLibre world's mods are loaded in two minutes at the most
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" BUILDAT_LUANTI_SEED=1 \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$out/module_srv.log" "Mods loaded" 150 auto \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla ||
	{ srv=${SERVER_PID:-}; echo "the module's server did not come up" >&2; exit 1; }
srv=$SERVER_PID port=$SERVER_PORT
fifo="$out/module_stdin"; rm -f "$fifo"; mkfifo "$fifo"
bin/buildat -s "localhost:$port" -w 1280x720 -l 3 -c - < "$fifo" \
	> "$out/module_cli.log" 2>&1 &
cli=$!
exec 3>"$fifo"
module_census=$(drive "$out/module_srv.log" "$fifo" "$out/module_cli.log" \
	"vanilla client ready")
exec 3>&-
kill "$cli" 2>/dev/null; wait "$cli" 2>/dev/null
kill -INT "$srv" 2>/dev/null
# A poll: the server's exit
for i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done

echo "luanti: ${luanti_census:-no census}"
echo "module: ${module_census:-no census}"
printf '%s\n%s\n' "$luanti_census" "$module_census" > "$out/census.txt"
if [ -z "$luanti_census" ] || [ -z "$module_census" ]; then
	echo "FAIL: a side gave no census" >&2; exit 1
fi
if [ "$luanti_census" != "$module_census" ]; then
	echo "FAIL: the censuses differ" >&2; exit 1
fi
echo "PASS: the two censuses are the same"
