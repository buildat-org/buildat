#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: 120s (this desk, 2026-09-28; local/run_all/costs corrects it per machine)
# [UNDERGROUND_LIGHT]: **/fixlight's radius forms, and the daylight they put
# back.** Two things nothing else in the tree held:
#
#   * a world has daylight in it -- open air over the surface reads 15 at
#     noon. A played world that had lost its light drew every canopy shadow
#     and every cave mouth black and gray, and no runner would have said so
#     (the playtest fault, 2026-09-28);
#   * /fixlight takes a bare radius (user, 2026-09-28): none is 32, a number
#     on its own is that radius, and Luanti's own forms still answer -- so a
#     patch of world that went dark can be asked for by the ground the
#     player is standing on.
#
# The world is made fresh and the command is called as a player would type
# it. Prints PASS or FAIL; the log is under local/fixlight_check/.
#
# simplified: that /fixlight *repairs* a dark world is not staged here. A
# VoxelManip set_lighting()/write_to_map(false) does not leave the light
# zeroed -- read back at once it is already 15 again -- so there is no way
# in Lua to make the damage this is about. It was measured by hand on the
# world that reported it (the plan, [UNDERGROUND_LIGHT]); staging it wants
# a way to stop the flood, which is the upgrade path.
#
#   builtin/luanti/test/fixlight.sh
#
# covers: builtin/luanti/lua/chatcommands.lua builtin/voxelworld/voxelworld.cpp
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
. "$me/lib.sh"
out="$here/local/fixlight_check"; mkdir -p "$out"
save=buildat_test_fixlight
port=29793
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running" >&2; exit "$SKIP"
fi
# A world of its own, made fresh: what is measured is the light a made world
# has, so a save from an earlier run would be measuring that run instead
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
trap 'check_pkill -INT buildat_server 2>/dev/null; true' EXIT
{ echo 'core.settings:set("time_speed", "0")'
  echo 'core.after(0, function() core.set_timeofday(0.5) end)'
  cat "$me/fixlight.lua"; } > "$out/fixture.lua"
BUILDAT_LUANTI_GAME="${GAME:-mineclone2}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$out/srv.log" "Mods loaded" 120 "$port" \
	timeout 400 bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
# A player has to join for the fixture to have one to stand on; the
# fixture's work starts 25 s after the join
{ echo "wait_log 120000 the server put the player"
	echo "wait_log_any 60000 chat: fixcheck: done"
	echo "quit"; } > "$out/cmds.txt"
timeout 250 bin/buildat -s "localhost:$port" -w 640x480 -l 3 -c @"$out/cmds.txt" \
	> "$out/cli.log" 2>&1
check_pkill -INT buildat_server 2>/dev/null
if ! grep -aq "fixcheck: done" "$out/srv.log"; then
	echo "SKIP: the run never got to its end; see $out/srv.log" >&2
	exit "$SKIP"
fi
say(){ grep -a "fixcheck: $1" "$out/srv.log" | tail -1 | sed 's/.*fixcheck: //'; }
grep -a "fixcheck:" "$out/srv.log" | sed 's/.*fixcheck: //'
# The boxes. The player's position is not known here, so what is checked is
# the box's own extent: 64 across for the default 32, 96 for 48, 16 for 8
box_span(){
	grep -a "fixcheck: box \[$1\]" "$out/srv.log" | tail -1 |
		sed -n 's/.*(\(-\?[0-9.]*\),\(-\?[0-9.]*\),\(-\?[0-9.]*\))(\(-\?[0-9.]*\),.*/\1 \4/p' |
		awk '{ printf "%d", $2 - $1 }'
}
for pair in ":64" "48:96" " 8 :16"; do
	param="${pair%:*}"; want="${pair##*:}"
	got=$(box_span "$param")
	if [ "$got" != "$want" ]; then
		echo "FAIL: /fixlight [$param] covered $got voxels across, wanted $want"
		exit 1
	fi
done
if ! grep -aq "fixcheck: box \[nonsense\] false" "$out/srv.log"; then
	echo "FAIL: /fixlight nonsense was not refused"
	exit 1
fi
# **And the world has daylight in it.** Nothing in the tier held this, and a
# played world that had lost its light drew every canopy shadow black
# ([UNDERGROUND_LIGHT], the playtest fault): open air over the surface is 15
# at noon or the world is not lit.
made=$(say "made" | sed -n 's/.*light=\([0-9]*\).*/\1/p')
if [ "${made:-0}" != "15" ]; then
	echo "FAIL: a made world's open air over the surface reads ${made:-nothing} at noon, not 15"
	exit 1
fi
echo "PASS: a made world's open air reads 15 at noon, and /fixlight's radius" \
	"forms cover 64, 96 and 16 voxels across"
exit 0
# vim: set noet ts=4 sw=4:
