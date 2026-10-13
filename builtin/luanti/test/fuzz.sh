#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: long
# [AUTO_PLAYTEST] part 1: a fuzz run. A fresh world, a client that walks at
# random for MINUTES from a seeded RNG, and fuzz.lua asserting invariants on
# the server once a second. The runner reads both logs afterwards.
#
#   SEED=7 MINUTES=5 GAME=mineclone2 builtin/luanti/test/fuzz.sh
#
# The same SEED replays the same walk: it seeds both the world and the
# command file. What is written per run lands under local/fuzz/<seed>/:
# the command file, both logs, and a screenshot every thirty seconds for a
# person to look through when the run fails.
#
# LOG_LEVEL=6 has every slow step at trace with the emerge phase broken
# down ([STEP_PEAK]); the default 4 is verbose. CLIENT_LOG_LEVEL=5 has the
# client's frames over 50 ms with their phases and Urho's profiler table
# beside every frame peak line over the ceiling ([FRAME_PEAK]).
# Never beside another buildat_server: the save's sqlite and the desktop
# are one each.
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
# Seed 1 is no playtest world under mapgen v7, whatever the game: a sea at
# the spawn, sheer mountains, no trees (user, 2026-09-22); it is kept for
# [LIQUID_FLOW]'s sea-over-cave test only. So 5, the driver's proven seed.
SEED="${SEED:-5}"
[ "$SEED" = 1 ] && echo "seed 1: a sea with sheer mountains under mapgen v7; a drowning here is the seed, not a finding" >&2
MINUTES="${MINUTES:-3}"
GAME="${GAME:-mineclone2}"
# The buildat game the server runs: vanilla, or a variant of it
# ([GAME_BASE]) -- GAME_DIR=vanilla_voxel_physics
GAME_DIR="${GAME_DIR:-vanilla}"
out="$here/local/fuzz/$SEED"
mkdir -p "$out"
save="buildat_test_fuzz_$SEED"

# The walk. Every step is one of a dozen actions with a random duration,
# each a discrete thing the invariants can see: turn, walk, jump, dig what
# is in front, place it, punch what is near, cycle the hotbar, open and
# close the inventory. awk's rand() is seeded, so the file is the seed's.
# A screenshot every thirty seconds of walk, and the mouse is never moved
# in absolute terms -- look sets the aim, which is all the fixture reads.
# The world loading around the player is waited for ([START_WAIT]): the
# placement, then the settle line, START_WAIT the ceiling (60 s). The
# delays are the walk's own: how long a key or a button is held, the
# inventory open, and the pause after a step, all from the seed.
START_WAIT="${START_WAIT:-60}"
awk -v seed="$SEED" -v secs="$((MINUTES * 60))" -v out="$out" -v wait="$((START_WAIT * 1000))" 'BEGIN {
	srand(seed)
	print "wait_log " wait " the server put the player"
	print "wait_log " wait " scene, 0 undrawn within 2"
	print "delay 2000"
	t = 0; shot = 0; yaw = 0
	while (t < secs) {
		r = rand()
		if (r < 0.25) {
			# turn, a little or a lot, mostly level
			yaw = (yaw + int(rand() * 120) - 60 + 360) % 360
			pitch = int(rand() * 60) - 30
			print "look " yaw " " pitch
			d = 0.2
		} else if (r < 0.50) {
			# A walk of 2-8 s that jumps every 1-5 s while W is held: a
			# voxel world is nothing but one-node steps, and a walk that
			# does not jump stands at the first rise for the rest of the
			# run with the invariants happy (user, 2026-09-17)
			d = 2 + rand() * 6
			print "keydown W"
			left = d
			while (left > 0) {
				gap = 1 + rand() * 4
				if (gap > left) gap = left
				print "delay " int(gap * 1000)
				left -= gap
				# Held, not pressed: keypress is down and up in one
				# frame, and the launcher polls GetKeyDown once a frame
				if (left > 0) {
					print "keydown Space"; print "delay 150"; print "keyup Space"
					left -= 0.15
				}
			}
			print "keyup W"
			waited = 1
		} else if (r < 0.58) {
			# a timing: a jump held 150 ms, then a walk of d s
			d = 1 + rand() * 2
			print "keydown W"; print "keydown Space"; print "delay 150"
			print "keyup Space"; print "delay " int(d * 1000); print "keyup W"
		} else if (r < 0.72) {
			# dig what is in front: a hold on the left button, looking a
			# little down so the ground is within reach
			# 2-5 s (user, 2026-09-17): dirt by hand is under a second in
			# VoxeLibre and wood three; stone by hand is not the walk
			# business
			print "look " yaw " " (-35 + int(rand() * 30))
			d = 2 + rand() * 3
			print "mouse_down left"; print "delay " int(d * 1000); print "mouse_up left"
		} else if (r < 0.80) {
			print "look " yaw " " (-50 + int(rand() * 20))
			print "mouse_click right"; d = 0.3
		} else if (r < 0.86) {
			# punch what is near: a click, not a hold
			print "look " yaw " " (int(rand() * 20) - 10)
			print "mouse_click left"; d = 0.3
		} else if (r < 0.94) {
			print "keypress " (1 + int(rand() * 9)); d = 0.2
		} else {
			# a timing: the inventory up 0.8 s, the pace of the walk; a wait
			# for its line would fail the walk where a random state
			# (a form already up) keeps it shut, which is not a finding
			print "keypress I"; print "delay 800"; print "keypress Escape"; d = 1
		}
		# The walk has spent its time already; everything else waits here
		if (!waited) print "delay " int(d * 1000)
		waited = 0
		t += d
		if (t - shot >= 30) {
			shot = t
			printf "screenshot %s/t%04d.png\n", out, int(t)
			# and what the client sees, under the same stem ([SCAN_EVENT])
			printf "event scan 8 t%04d\n", int(t)
		}
	}
	print "quit"
}' > "$out/cmds.txt"
# CMDS=<file> plays that command file instead of the walk: the same
# server, fixture and verdict around one scripted thing, for reading a
# scan of a form or a place by hand
[ -n "${CMDS:-}" ] && cp "$CMDS" "$out/cmds.txt"

cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
# KEEP_SAVE=1 walks the save that is there: one an older Buildat wrote, or
# the last run's reopened
[ -n "${KEEP_SAVE:-}" ] || rm -rf "$BUILDAT_USER_PATH/apps/$GAME_DIR/saves/$save"
port=$(( 29800 + (SEED % 90) ))
srv=""; cli=""; netsim=""
trap 'kill "$cli" 2>/dev/null; kill "${netsim:-}" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
# launcher=1: a launcher's own server, which its client joins without an
# account; without it the server is a public one ([VANILLA_PUBLIC]) and
# the walk waits at the login
{ echo "rawset(_G, \"FUZZ_SEED\", $SEED)"; cat "${FUZZ_LUA:-$me/fuzz.lua}"; } > "$out/fixture.lua"
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$out/srv.log" "Mods loaded" 180 "$port" \
	bin/buildat_server -u launcher=1 -m "../apps/$GAME_DIR" \
	-l "${LOG_LEVEL:-4}"
rc=$?
srv=${SERVER_PID:-}
[ $rc = 0 ] || { echo "the server did not come up" >&2; exit 1; }

# NETSIM="--delay 80 --rate 2000 --loss 2": the client goes through
# util/netsim.py's lossy link to the server ([NET_SIM]); the proxy's port
# is the server's plus a hundred
cport=$port
if [ -n "${NETSIM:-}" ]; then
	cport=$((port + 100))
	python3 "$here/util/netsim.py" --listen "$cport" --to "localhost:$port" \
		$NETSIM > "$out/netsim.log" 2>&1 &
	netsim=$!
	# The proxy's port, polled
	for _ in $(seq 25); do port_taken "$cport" && break; sleep 0.2; done
fi
bin/buildat -s "localhost:$cport" -w 1280x720 -l "${CLIENT_LOG_LEVEL:-3}" \
	-c @"$out/cmds.txt" \
	> "$out/cli.log" 2>&1 &
cli=$!
# The walk plus the load, and then some: a client that has not exited by
# then is hung, which is a finding of its own ([QUIT_HANG], seed 15 sat
# twelve minutes in Urho3D's FileWatcher at exit) and not a reason for
# the campaign to stop
limit=$((MINUTES * 60 + 300))
for i in $(seq 1 "$limit"); do
	kill -0 "$cli" 2>/dev/null || break
	sleep 1
done
hung=0
if kill -0 "$cli" 2>/dev/null; then
	hung=1
	kill -KILL "$cli" 2>/dev/null
fi
wait "$cli"
cli_status=$?
# The server's ticks after the player left, for the fixture's last lines
sleep 2
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done

. "$me/verdict.sh"
exit $status
