#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: 60s (this desk, 2026-09-26; local/run_all/costs corrects it per machine)
# [CLIENT_FRAME]: **a client with no cache at all.** Every announced file
# has to be asked for, and the scripts that follow the announce -- a
# module's client half, which requires the modules whose files are still
# on the way -- must not be run until they have arrived. The client checks
# the cache on a worker now, and the first shape of that let the scripts
# past: `modules.lua:23: attempt to concatenate local 'err'`, and the
# world never drew. devtest, so it is six hundred files rather than five
# thousand. Prints PASS or FAIL.
#
#   builtin/luanti/test/cold_cache.sh
#
# covers: src/client/state.cpp
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
. "$me/lib.sh"
out="$here/local/cold_cache"
rm -rf "$out"; mkdir -p "$out/cache"
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running" >&2; exit "$SKIP"
fi
trap 'check_pkill -INT buildat_server 2>/dev/null; true' EXIT
echo 'core.settings:set("time_speed", "0")' > "$out/fixture.lua"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE=buildat_test_cold \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$out/srv.log" "Mods loaded" 60 29825 \
	timeout 400 bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 || [ $? = 1 ] || exit 1 # its own verdict below
if ! grep -aq "Mods loaded" "$out/srv.log" 2>/dev/null; then
	echo "SKIP: the server did not load its mods" >&2; exit "$SKIP"
fi
# The port taken, up to 10 s
for _ in $(seq 50); do port_taken 29825 && break; sleep 0.2; done
{ echo "wait_log 120000 the server put the player"
	echo "wait_log 60000 scene, 0 undrawn within 2"
	echo "quit"; } > "$out/cmds.txt"
# -C: a cache path of its own, empty, so nothing is there to be reused
timeout 300 bin/buildat -s "localhost:29825" -C "$out/cache" -w 1280x720 \
	-l 3 -c @"$out/cmds.txt" > "$out/cli.log" 2>&1
rc=$?
cached=$(sed -n 's/.*\([0-9][0-9]*\) of \([0-9][0-9]*\) announced files are cached.*/\1 \2/p' \
		"$out/cli.log" | sort -n -k2 | tail -1) # the game's, not a later one-file announce
if [ -z "$cached" ]; then
	echo "FAIL: the client never said what it made of the announced files"
	exit 1
fi
set -- $cached
if [ "$1" != "0" ]; then
	echo "FAIL: $1 files were already cached, so nothing was transferred"
	exit 1
fi
if [ "$2" -lt 100 ]; then
	echo "FAIL: only $2 files were announced; this is not the game it should be"
	exit 1
fi
if ! grep -aq "the server put the player" "$out/cli.log"; then
	echo "FAIL: the player never arrived with a cold cache"
	exit 1
fi
if grep -aq "Failed to run script\|attempt to concatenate" "$out/cli.log"; then
	echo "FAIL: a script ran before the files it needs had arrived:"
	grep -a -m 2 -A 2 "Failed to run script\|attempt to concatenate" "$out/cli.log" >&2
	exit 1
fi
if [ "$rc" != 0 ]; then
	echo "FAIL: the client's drive: $(grep -a "Command sequence failed" "$out/cli.log" | tail -1)"
	exit 1
fi
echo "PASS: $2 files transferred into an empty cache and the world came up"
exit 0
# vim: set noet ts=4 sw=4:
