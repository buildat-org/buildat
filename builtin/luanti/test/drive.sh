#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: long
# [SCAN_DRIVE]: a driven run. The same server and fixture as fuzz.sh, the
# client on its stdin (a fifo), and drive.py choosing every act from what
# `event scan` shows. The verdict is the fuzz run's, verbatim (verdict.sh),
# plus drive.py's own FAILED lines (a rule's expectation failed twice, a
# form that would not close, three unstickings in a row).
#
#   SEED=5 MINUTES=10 GOAL=3 GAME=mineclone2 builtin/luanti/test/drive.sh
#
# GOAL=<rung> is what the run is for and ends it ([DRIVE_GOAL]); MINUTES
# is the ceiling. The goal line is the pass; the minutes running out
# first is the stop to sort.
#
# Lands under local/drive/<seed>/ (the run before's pictures moved to
# previous/): both logs, drive.log (a line per turn
# naming the rule that fired), a screenshot every tenth turn beside the
# scan block of the same stem in cli.log. Never beside another
# buildat_server. LOG_LEVEL and CLIENT_LOG_LEVEL as in fuzz.sh.
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
# Seed 1 is no playtest world under mapgen v7, whatever the game: a sea at
# the spawn, sheer mountains, no trees (user, 2026-09-22); it is kept for
# [LIQUID_FLOW]'s sea-over-cave test only. So 5, the driver's proven seed.
SEED="${SEED:-5}"
[ "$SEED" = 1 ] && echo "seed 1: a sea with sheer mountains under mapgen v7; a drowning here is the seed, not a finding" >&2
MINUTES="${MINUTES:-10}"
GAME="${GAME:-mineclone2}"
# The buildat game the server runs: vanilla, or a variant of it
# ([GAME_BASE]) -- GAME_DIR=vanilla_voxel_physics
GAME_DIR="${GAME_DIR:-vanilla}"
GOAL="${GOAL:-}"
out="$here/local/drive/$SEED"
mkdir -p "$out"
# The logs are overwritten per run; the pictures go to previous/ (the
# one run before, for comparison; user), or an earlier run's
# higher-numbered ones sit beside this run's and read as its
if ls "$out"/d[0-9]*.png >/dev/null 2>&1; then
	rm -rf "$out/previous"; mkdir -p "$out/previous"
	mv "$out"/d[0-9]*.png "$out/previous/"
fi
save="buildat_test_drive_$SEED"

cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
# KEEP_SAVE=1 rejoins the run before's world: the player is a returning
# one, placed at join ([PLAYER_POS_RACE])
[ -n "${KEEP_SAVE:-}" ] || rm -rf "$BUILDAT_USER_PATH/apps/$GAME_DIR/saves/$save"
port=$(( 29800 + (SEED % 90) ))
srv=""; cli=""; drv=""; netsim=""
# The run's temp dir goes with it: 200 MB of game and cache a run, and
# an interrupted run's would stay ([FIRST_RUN]; /tmp filled once)
tmp=""
trap 'kill "$drv" 2>/dev/null; kill "$cli" 2>/dev/null; kill "${netsim:-}" 2>/dev/null; kill "${mirror:-}" 2>/dev/null; kill -INT "$srv" 2>/dev/null; [ -n "$tmp" ] && rm -rf "$tmp"' EXIT
# MENU_RUN=world|full ([FIRST_RUN]): no server here -- the client starts
# in the launch menu and starts its own, and drive.py's menu rules
# (menu_drive.py) take it to a new VoxeLibre world with this seed before
# the world rules run; the world is not the fixture's then, and the goal
# is read from the client's scans alone. world: VoxeLibre is installed
# and the run makes a new world in it (the save menu_run_<seed>, cleared
# here first). full: empty user and cache directories and ContentDB
# installs the game -- the next rung; it runs as world until then.
menu_env=""
mirror=""
cold=""
if [ -n "${MENU_RUN:-}" ]; then
	srv=""
	START_WAIT="${START_WAIT:-8}"
	rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/menu_run_$SEED"
	if [ "$MENU_RUN" = full ]; then
		# Empty user and cache directories, given to the client (-D, -C)
		# and by it to the server it starts, and ContentDB as a mirror of
		# the installed game served from a directory of the run's own
		tmp=$(mktemp -d /tmp/buildat_menu_run.XXXXXX)
		mkdir -p "$tmp/data" "$tmp/cache" "$tmp/mirror"
		"$here/util/contentdb_mirror.sh" "$tmp/mirror" \
			"$BUILDAT_USER_PATH/shared/vanilla/games/$GAME" Wuzzy "$GAME" VoxeLibre >/dev/null
		# A mirror left by an interrupted run answers 404 from a deleted
		# directory; exec, so the trap's kill reaches python itself
		pkill -f "http.server $((port + 200))" 2>/dev/null || true
		(cd "$tmp/mirror" && exec python3 -m http.server $((port + 200)) > "$out/mirror.log" 2>&1) &
		mirror=$!
		for i in $(seq 1 50); do port_taken $((port + 200)) && break; sleep 0.2; done
		menu_env="env BUILDAT_CONTENTDB_URL=http://localhost:$((port + 200))"
		cold="-D $tmp/data -C $tmp/cache"
		echo "empty paths under $tmp, the mirror on port $((port + 200))"
	fi
else
{ echo "rawset(_G, \"FUZZ_SEED\", $SEED)"; echo "rawset(_G, \"FUZZ_DRIVEN\", true)"; cat "${FUZZ_LUA:-$me/fuzz.lua}"; } > "$out/fixture.lua"
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	bin/buildat_server -u launcher=1 -m "../apps/$GAME_DIR" -P "$port" \
	-l "${LOG_LEVEL:-4}" \
	> "$out/srv.log" 2>&1 &
srv=$!
# Until the mods are loaded and the port is listened on, or the server is
# gone
for i in $(seq 1 600); do
	grep -q "Mods loaded" "$out/srv.log" 2>/dev/null &&
		grep -q "STATUS Listening" "$out/srv.log" 2>/dev/null && break
	kill -0 "$srv" 2>/dev/null || break
	sleep 0.2
done
grep -q "STATUS Listening" "$out/srv.log" 2>/dev/null && kill -0 "$srv" 2>/dev/null ||
	{ echo "the server did not come up" >&2; tail -3 "$out/srv.log" >&2; exit 1; }
fi

# The client reads the fifo, and its run ends at the fifo's end: this
# shell holds a writing end open for the whole run, drive.py opens its
# own and writes quit last
fifo="$out/cmds.fifo"
rm -f "$fifo"; mkfifo "$fifo"
: > "$out/cli.log"
# NETSIM="--delay 80 --rate 2000 --loss 2": the client goes through
# util/netsim.py's lossy link to the server ([NET_SIM]); the proxy's port
# is the server's plus a hundred
cport=$port
if [ -n "${NETSIM:-}" ]; then
	cport=$((port + 100))
	python3 "$here/util/netsim.py" --listen "$cport" --to "localhost:$port" \
		$NETSIM > "$out/netsim.log" 2>&1 &
	netsim=$!
	for i in $(seq 1 50); do
		port_taken "$cport" && break
		kill -0 "$netsim" 2>/dev/null || break
		sleep 0.2
	done
fi
# COLD=1: the client starts with an empty cache of its own, so every file
# the server has is fetched at join ([PLAYER_POS_RACE]: the race is between
# that bulk and the first player_pos)
if [ -n "${COLD:-}" ]; then
	rm -rf "$out/cache"; cold="-C $out/cache"
fi
server_arg="-s localhost:$cport"
[ -n "${MENU_RUN:-}" ] && server_arg=""
$menu_env bin/buildat $server_arg -w 1280x720 -l "${CLIENT_LOG_LEVEL:-3}" $cold \
	-c - < "$fifo" \
	> "$out/cli.log" 2>&1 &
cli=$!
exec 3> "$fifo"
# The world loading around the player is waited for, not guessed
# ([START_WAIT]): the client logs the placement and then the settle
# line once the near chunks are drawn, and the sequence holds on each
# (wait_log) with START_WAIT as the ceiling -- 60 s, 300 over a capped
# link ([NET_SIM]) -- after which the run fails as one whose world did
# not settle. Two seconds of grace after.
START_WAIT="${START_WAIT:-$([ -n "${NETSIM:-}" ] && echo 300 || echo 60)}"
echo "wait_log $((START_WAIT * 1000)) the server put the player" >&3
echo "wait_log $((START_WAIT * 1000)) scene, 0 undrawn within 2" >&3
echo "delay 2000" >&3
# A client that leaves during the wait -- disconnected, crashed -- ends
# the run there (user, 2026-09-21): a driver started after it would open
# the fifo for a reader that is gone and wait for nothing. The wait is
# over when the client says the settle line was seen, or not seen.
settled=0
for i in $(seq 1 $((START_WAIT * 10 + 50))); do
	kill -0 "$cli" 2>/dev/null || break
	if grep -aq 'wait_log: "scene, 0 undrawn within 2" seen' "$out/cli.log"; then
		# The drive's own 2 s settle after the line, so drive.py's
		# minutes start after it
		settled=1; sleep 2; break
	fi
	if grep -aq 'wait_log: "scene, 0 undrawn within 2" not seen\|wait_log: "the server put the player" not seen' "$out/cli.log"; then
		break
	fi
	sleep 0.2
done
# A menu run has no world to settle yet: the client starts in the launch
# menu and the driver's own menu rules are what make one, so the start wait
# above can only time out there. The gate is the client still being alive.
settle_fail=""
if [ -z "${MENU_RUN:-}" ] && [ "$settled" != 1 ]; then
	settle_fail="FAIL: the world did not settle in $START_WAIT s"
fi
drv=
if kill -0 "$cli" 2>/dev/null &&
		{ [ "$settled" = 1 ] || [ -n "${MENU_RUN:-}" ]; }; then
	MENU_RUN="${MENU_RUN:-}" python3 "$me/drive.py" "$out/cli.log" "$fifo" "$MINUTES" "$out" "$SEED" $GOAL \
		> "$out/drive.log" 2>&1 &
	drv=$!
else
	echo "drive: FAILED disconnected: the client left, or the world did not settle, during the start wait" > "$out/drive.log"
fi

limit=$((MINUTES * 60 + 300))
for i in $(seq 1 $((limit * 5))); do
	kill -0 "$cli" 2>/dev/null || break
	sleep 0.2
done
hung=0
if kill -0 "$cli" 2>/dev/null; then
	hung=1
	kill -KILL "$cli" 2>/dev/null
fi
wait "$cli"
cli_status=$?
# The driver ends itself on a disconnect it sees; one blocked on the fifo
# with the client gone is ended here
if [ -n "$drv" ]; then
	for i in $(seq 1 10); do kill -0 "$drv" 2>/dev/null || break; sleep 0.2; done
	kill "$drv" 2>/dev/null
	wait "$drv" 2>/dev/null
fi
exec 3>&-
# simplified: a guessed two seconds for the server to log the client's
# leave before it is stopped; a poll for that line when it is known
sleep 2
if [ -n "${MENU_RUN:-}" ]; then
	# The client's own server: it ends with the client; its log is the
	# verdict's srv.log
	for i in $(seq 1 30); do check_pgrep buildat_server >/dev/null || break; sleep 1; done
	check_pkill -INT buildat_server 2>/dev/null || true
	local_log=$(grep -o "server log: .*" "$out/cli.log" | head -1 | sed 's/server log: //')
	cp "$local_log" "$out/srv.log" 2>/dev/null || : > "$out/srv.log"
else
	kill -INT "$srv" 2>/dev/null
	for i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
fi

# The fuzz verdict reads the fixture's ticks and the frame peaks of a
# scripted client, neither of which a menu run has; its verdict is
# drive.py's lines below
if [ -z "${MENU_RUN:-}" ]; then
	. "$me/verdict.sh"
else
	status=0
fi
grep "^drive: FAILED" "$out/drive.log" | sed 's/^drive: /FAIL: drive: /' >&2
grep -q "^drive: FAILED" "$out/drive.log" && status=1
if [ -n "$settle_fail" ]; then echo "$settle_fail" >&2; status=1; fi
# The chunks around the player must get drawn ([WIN_WORLD]): the client's
# settle line, once a second while anything is queued, must not read the
# same "N undrawn within 2" above zero for thirty lines running. Not "to
# mesh": that count holds every chunk's LOD trigger for good and reads
# thousands on an idle client by design.
frozen=$(grep -a "settle: .* undrawn within 2" "$out/cli.log" | sed 's/.*, \([0-9]*\) undrawn within 2.*/\1/' |
	awk '$1 > 0 && $1 == last {run++; if (run >= 30 && !said) {print $1; said=1}} $1 != last {run=1; last=$1}')
if [ -n "$frozen" ]; then
	echo "FAIL: $frozen chunks around the player stayed undrawn for thirty seconds" >&2
	status=1
fi
grep "^drive: GOAL" "$out/drive.log" | sed 's/^drive: //'
grep -q "^drive: GOAL .* not met" "$out/drive.log" && status=1
echo "turns: $(grep -c "^drive: turn .* rule" "$out/drive.log"), rules: $(
	grep -o "rule [a-z_]*" "$out/drive.log" | sort | uniq -c | sort -rn |
	awk '{printf "%s %s, ", $3, $1}' | sed 's/, $//')"
exit $status
