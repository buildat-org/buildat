#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 12s (this machine, 2026-10-30)
# covers: builtin/worldgen/worldgen.cpp
# [FAR_SPAWN_SLOW_JOIN]: a first join far from the origin has its world
# within 10 s of the placing. A devtest world of seed 1 spawns at
# 380,18,259; worldgen used to generate the origin's hundred queued
# sections before the player's, and "load: the world is in" came 21-28 s
# after the placing on this machine. Generated nearest a player first it
# is 1-1.5 s here. Prints PASS or FAIL.
#
#   builtin/luanti/test/far_spawn.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
check_user
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_far_spawn.XXXXXX")
cd "$here/Build"
rm -rf $BUILDAT_USER_PATH/apps/vanilla/saves/buildat_test_far_spawn
srv=""; cli=""
trap 'kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null;
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"' EXIT
BUILDAT_LUANTI_SEED=1 BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=buildat_test_far_spawn \
	start_server "$tmp/srv.log" "Mods loaded" 120 auto \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
{ echo "wait_log 60000 the server put the player at 380"
	echo "wait_log 10000 load: the world is in"; echo "quit"; } > "$tmp/cmds.txt"
timeout 120 bin/buildat -s "localhost:$SERVER_PORT" -w 640x360 -l 3 -c @"$tmp/cmds.txt" \
	> "$tmp/cli.log" 2>&1 &
cli=$!
wait $cli; ok=$?
grep -a "I vanilla : the server put the player\|I vanilla : load: the world is in" "$tmp/cli.log" | head -2
echo "logs in $tmp"
[ $ok = 0 ] ||
	fail "the drive ($tmp/cli.log): $(grep -ao 'Command sequence failed.*' "$tmp/cli.log" | head -1)"
echo "PASS: the world was in within 10 s of a placing at 380,18,259"
