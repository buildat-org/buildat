#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [SECURITY_RUN_1] phase 4: sandbox_fuzz.lua from inside a loaded game,
# where the walk meets what a game builds -- its served modules (luanti,
# voxelworld), its scene, its UI -- and not only the bare API that
# client_fuzz.sh's empty connection offers. A copy of the app (vanilla
# on devtest; APP=, GAME=) gets the script among its client files and a
# command_seq receiver that runs it; the client (Build/asan's, BUILD=
# for another) joins, waits for the player to be placed and runs it
# <rounds> times. A crash in either log fails; so does a client that
# does not finish. The logs go to local/security/fuzz/game/.
#
#   util/fuzz/game_fuzz.sh [rounds] [seed]
set -u
. "$(dirname "$0")/../check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/security/fuzz/game"
rounds=${1:-5}
seed=${2:-$RANDOM}
app=${APP:-vanilla}
game=${GAME:-devtest}
mkdir -p "$out"
# Its own copy and user dir, both remade: nothing of the run's lingers
rm -rf "$out/$app" "$out/user"
mkdir -p "$out/user/shared/vanilla/games"
cp -r "$BUILDAT_USER_PATH/shared/vanilla/games/$game" "$out/user/shared/vanilla/games/"
cp -r "$here/apps/$app" "$out/$app"
# The script's body in the handler itself: a served file run on its own
# has an environment of its own, and SEED set here did not reach it
{
	echo '-- game_fuzz.sh: `event sandbox_fuzz <seed>` runs util/fuzz/sandbox_fuzz.lua'
	echo 'SEED = 1'
	echo 'require("buildat/extension/urho3d").SubscribeToEvent("command_seq:sandbox_fuzz",'
	echo '	function(event_type, event_data)'
	echo '		SEED = tonumber(event_data:GetString("Param")) or 1'
	cat "$here/util/fuzz/sandbox_fuzz.lua"
	echo '	end)'
} >> "$out/$app/main/client_lua/init.lua"
port=$(( 29600 + (RANDOM % 90) ))
export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=1}
cd "$here/Build"
make -s -j8 > "$out/make.log" 2>&1 &&
	make -s -j8 -C "$here/Build/${BUILD-asan}" >> "$out/make.log" 2>&1 ||
	{ echo "the build failed: $out/make.log"; exit 2; }
bin/buildat_server --compile-only -u launcher=1 -m "$out/$app" \
	-D "$out/user" > "$out/compile.log" 2>&1 ||
	{ echo "a module failed to compile: $out/compile.log"; exit 2; }
BUILDAT_LUANTI_GAME=$game BUILDAT_LUANTI_SAVE=fuzz_$game \
	bin/buildat_server -u launcher=1 -m "$out/$app" -D "$out/user" \
	-P "$port" > "$out/srv.log" 2>&1 &
srv=$!
cli=""
trap 'kill $cli 2>/dev/null; kill -9 $srv 2>/dev/null' EXIT
for i in $(seq 1 180); do
	grep -aq "Mods loaded\|world is running" "$out/srv.log" && break
	sleep 1
done
{
	echo "wait_log 120000 the server put the player"
	echo "delay 3000"
	for i in $(seq 1 "$rounds"); do
		# The event runs the round before the next command: nothing to wait for
		echo "event sandbox_fuzz $((seed * 1000 + i))"
		echo "delay 1000"
	done
	echo "quit"
} > "$out/cmds.txt"
echo "$app on $game, seed $seed, $rounds rounds, port $port"
cd "$here/Build/${BUILD-asan}"
bin/buildat -o launch_ui=launch_menu -s "127.0.0.1:$port" -D "$out/user" -w 640x360 -l 3 \
	-o sound_mute=1 -U "$here/3rdparty/Urho3D" -P "$here" -C "$out/cache" \
	-c @"$out/cmds.txt" > "$out/cli.log" 2>&1 &
cli=$!
# A round is 400 calls; the join and the world a few minutes under ASan
limit=$(( 300 + rounds * 90 ))
for i in $(seq 1 "$limit"); do
	kill -0 $cli 2>/dev/null || break
	sleep 1
done
hung=""
kill -0 $cli 2>/dev/null && { hung=1; gstack $cli > "$out/stack.txt" 2>&1; kill -9 $cli; }
wait $cli 2>/dev/null; st=$?
# The script's own line, not the sequence's wait for it
done_n=$(grep -ac "I sandbox_: sandbox_fuzz: done" "$out/cli.log")
echo "$done_n of $rounds rounds done; the client's exit $st"
for f in cli srv; do
	if grep -aq "Crash: SIG\|AddressSanitizer\|: runtime error" "$out/$f.log"; then
		cp "$out/$f.log" "$out/fail_${seed}_$f.log"
		echo "FAIL: a crash in the $f log (seed $seed); $out/fail_${seed}_$f.log"
		grep -a -B2 -A12 "Crash: SIG\|AddressSanitizer\|: runtime error" \
			"$out/$f.log" | head -30
		exit 1
	fi
done
if [ -n "$hung" ] || [ "$done_n" -lt "$rounds" ]; then
	cp "$out/cli.log" "$out/fail_${seed}_cli.log"
	echo "FAIL: the client did not finish (seed $seed);" \
		"$out/fail_${seed}_cli.log, the last call:"
	grep -a "sandbox_fuzz: \|Watchdog" "$out/cli.log" | tail -3
	exit 1
fi
echo "PASS: $rounds rounds of the sandbox's API from inside $app"
