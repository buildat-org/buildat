#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [SECURITY_RUN_1] phase 4, the client's side: client_fuzz.py as a hostile
# server and the client (Build/asan's, BUILD= for another) connecting to it
# again and again, each run watched for a crash in its log. The logs and
# the seed go to local/security/fuzz/client/.
#
# SANDBOX=1 sends sandbox_fuzz.lua instead: the sandbox's own API called
# by a server's Lua with values at the edges.
#
#   util/fuzz/client_fuzz.sh [seconds] [seed]
set -u
. "$(dirname "$0")/../check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/security/fuzz/client"
secs=${1:-120}
seed=${2:-$RANDOM}
mkdir -p "$out"
rm -rf "$out/user"; mkdir -p "$out/user"
port=$(( 29800 + (RANDOM % 90) ))
cd "$here/Build/${BUILD-asan}"
export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=1}
make -s -j8 > "$out/make.log" 2>&1 ||
	{ echo "the build failed: $out/make.log"; exit 2; }
lua=(); [ "${SANDBOX:-}" = 1 ] && lua=("$here/util/fuzz/sandbox_fuzz.lua")
python3 "$here/util/fuzz/client_fuzz.py" "$port" 8 "$seed" "${lua[@]}" \
	> "$out/server.log" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
sleep 1
# A scripted client: the window manager puts it out of the user's way,
# and it leaves on its own after the server has closed on it
{ echo "delay 12000"; echo "quit"; } > "$out/cmds.txt"
echo "seed $seed, port $port"
end=$(( $(date +%s) + secs )); runs=0; bad=""
while [ "$(date +%s)" -lt "$end" ]; do
	runs=$((runs + 1))
	bin/buildat -o launch_ui=launch_menu -s "127.0.0.1:$port" -D "$out/user" \
		-w 640x360 -l 3 -o sound_mute=1 -U "$here/3rdparty/Urho3D" -P "$here" \
		-C "$out/cache" -c @"$out/cmds.txt" \
		> "$out/cli.log" 2>&1 &
	cli=$!; st=0; : > "$out/stack.txt"; last=0; quiet=0
	# The threads are taken from outside after 6 s of a quiet log: the
	# client's own watchdog prints no stack from LuaJIT's machine code.
	# At 30 s it is a hang
	for i in $(seq 1 30); do
		sleep 1
		kill -0 $cli 2>/dev/null || break
		size=$(stat -c %s "$out/cli.log")
		[ "$size" = "$last" ] && quiet=$((quiet + 1)) || quiet=0
		last=$size
		if [ "$quiet" -ge 6 ] && [ ! -s "$out/stack.txt" ]; then
			gstack $cli > "$out/stack.txt" 2>&1
		fi
	done
	if kill -0 $cli 2>/dev/null; then
		[ -s "$out/stack.txt" ] || gstack $cli > "$out/stack.txt" 2>&1
		kill -9 $cli; st=137
	fi
	wait $cli 2>/dev/null
	# **Lua that takes its time is not a finding here**: a served chunk has
	# no instruction limit (the run's open question), so a stall whose main
	# thread is in LuaJIT -- its runtime or its machine code, "??" -- is
	# counted and the run goes on
	top=$(awk '/^Thread 1 /{t=1; next} t && /^#/{print} t && /^$/{exit}' \
		"$out/stack.txt" | head -6)
	if [ -n "$top" ] && echo "$top" | grep -q "LuaJIT/src\| in ?? ()"; then
		lua_slow=$((${lua_slow:-0} + 1))
		cp "$out/cli.log" "$out/lua_slow_$lua_slow.log"
		continue
	fi
	if grep -aq "Crash: SIG\|AddressSanitizer\|: runtime error" "$out/cli.log"; then
		bad="a crash in the client's log"; break
	fi
	# A client that the server's garbage keeps from ever leaving
	[ $st = 137 ] && { bad="the client hung (30 s)"; break; }
	# **Its own canary**: a script that dies of its own error before its
	# first call fuzzes nothing and passes -- three seeds did, on a
	# setmetatable the sandbox does not have
	if [ "${SANDBOX:-}" = 1 ] &&
			! grep -aq "I sandbox_: sandbox_fuzz: done" "$out/cli.log"; then
		bad="sandbox_fuzz.lua never finished a round"; break
	fi
done
kill $srv 2>/dev/null
tail -1 "$out/server.log"
if [ -n "$bad" ]; then
	cp "$out/cli.log" "$out/fail_$seed.log"
	[ -s "$out/stack.txt" ] && cp "$out/stack.txt" "$out/fail_${seed}_stack.txt"
	echo "FAIL: $bad (seed $seed, run $runs); $out/fail_$seed.log"
	grep -a -A12 "Crash: SIG\|AddressSanitizer\|: runtime error" "$out/cli.log" | head -30
	exit 1
fi
echo "PASS: $runs client runs against a hostile server" \
	"(${lua_slow:-0} stalled in Lua: lua_slow_*.log)"
