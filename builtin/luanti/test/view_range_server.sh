#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: 60s (this desk, 2026-09-26; local/run_all/costs corrects it per machine)
# [CLIENT_FRAME]: **how far out the world is kept is the server's to
# decide.** A player asking for a view range of four hundred is asking
# the machine to keep and to make that much world, and a public server
# has to be able to say no -- so the two radii come from Luanti's own
# `max_block_send_distance` and `max_block_generate_distance` rather than
# from a constant, and the client's request is capped by them. This runs
# a server twice, with the settings left alone and with them widened, and
# reads back what the world was built with. No client. Prints PASS/FAIL.
#
#   builtin/luanti/test/view_range_server.sh
#
# covers: builtin/luanti/luanti.cpp
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/view_range_server"; mkdir -p "$out"
save="buildat_test_view_range"
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running" >&2; exit "$SKIP"
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
trap 'check_pkill -INT buildat_server 2>/dev/null; true' EXIT

# A world of its own and no player: what is measured is what the server
# builds the world with, which it says at create_world()
run_one() {
	name="$1"; settings="$2"
	{ echo 'core.settings:set("time_speed", "0")'
		echo "$settings"; } > "$out/fixture_$name.lua"
	BUILDAT_LUANTI_GAME="${GAME:-devtest}" \
		BUILDAT_LUANTI_SAVE="$save" BUILDAT_LUANTI_LUA="$out/fixture_$name.lua" \
		start_server "$out/srv_$name.log" "world kept" 60 29822 \
		timeout 300 bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
		{ echo "FAIL: the server did not start"; exit 1; }
	kill -INT "$SERVER_PID" 2>/dev/null
	for i in $(seq 1 300); do
		kill -0 "$SERVER_PID" 2>/dev/null || break
		sleep 0.2
	done
	sed -n 's/.*world kept \([0-9]*\) sections out and generated \([0-9]*\).*/\1 \2/p' \
			"$out/srv_$name.log" | head -1
}

# Luanti's defaults, which are the 3 and 2 sections this carried as
# constants: 12 blocks of sixteen nodes sent, 10 generated, 64 nodes to a
# section
got=$(run_one default "")
if [ "$got" != "3 2" ]; then
	echo "FAIL: with the settings alone the world was kept at \"$got\", not \"3 2\""
	exit 1
fi
# And a server that wants to serve a long view says so
got=$(run_one wide 'core.settings:set("max_block_send_distance", "20")
core.settings:set("max_block_generate_distance", "20")')
if [ "$got" != "5 5" ]; then
	echo "FAIL: at 20 blocks the world was kept at \"$got\", not \"5 5\""
	exit 1
fi
echo "PASS: the world's radii are the server's own settings (3/2 by default, 5/5 at 20 blocks)"
exit 0
# vim: set noet ts=4 sw=4:
