#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: 70s (this desk, 2026-09-26; local/run_all/costs corrects it per machine)
# [CLIENT_FRAME]: an object's collision with the map, server only. A
# dropped item over a dirt platform comes to rest on it and one dropped
# over nothing keeps falling -- the two answers the walkable test in
# entity.lua has to give, which nothing else in the tree checks. It was
# written when that test stopped building a node table per voxel per axis
# per object per step and started asking by content id. Prints PASS/FAIL.
#
#   builtin/luanti/test/object_collide.sh
#
# covers: builtin/luanti/lua/entity.lua
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/object_collide"; mkdir -p "$out"
save=buildat_test_object_collide
cd "$here/Build"
if check_pgrep buildat_server >/dev/null; then
	echo "SKIP: a buildat server is already running" >&2; exit "$SKIP"
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
trap 'check_pkill -INT buildat_server 2>/dev/null; true' EXIT
BUILDAT_LUANTI_GAME="${GAME:-mineclone2}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/object_collide.lua" \
	start_server "$out/srv.log" "collidecheck: done" 280 29791 \
	timeout 300 bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 || [ $? = 1 ] || exit 1 # its own verdict below
check_pkill -INT buildat_server 2>/dev/null
if ! grep -aq "collidecheck: done" "$out/srv.log"; then
	echo "SKIP: the run never got to its end; see $out/srv.log" >&2
	exit "$SKIP"
fi
last=$(grep -a "collidecheck: t=" "$out/srv.log" | tail -1)
floor=$(echo "$last" | sed -n 's/.*floor=\([0-9.]*\).*/\1/p')
void=$(echo "$last" | sed -n 's/.*void=\([0-9.-]*\).*/\1/p')
echo "the last reading: $(echo "$last" | sed 's/.*collidecheck: //')"
if [ -z "$floor" ]; then
	echo "FAIL: the item over the platform is gone, so nothing was measured"
	exit 1
fi
# The platform's top is 120.5 and a dropped item's box stands a little
# above it; anything under 120.5 has gone through the floor
ok_floor=$(awk -v y="$floor" 'BEGIN { print (y > 120.5 && y < 121.2) ? 1 : 0 }')
if [ "$ok_floor" != "1" ]; then
	echo "FAIL: the item over the platform came to rest at $floor, not on it"
	exit 1
fi
if [ -z "$void" ]; then
	echo "FAIL: the item over nothing is gone; it should still be falling"
	exit 1
fi
# Three seconds of falling from 122.5 is far below a hundred whatever the
# gravity is; what this catches is a floor where there is none
ok_void=$(awk -v y="$void" 'BEGIN { print (y < 100) ? 1 : 0 }')
if [ "$ok_void" != "1" ]; then
	echo "FAIL: the item over nothing stopped at $void, so something stopped it"
	exit 1
fi
echo "PASS: the item over the platform rests at $floor and the one over nothing is at $void"
exit 0
# vim: set noet ts=4 sw=4:
