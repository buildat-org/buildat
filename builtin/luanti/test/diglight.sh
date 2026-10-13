#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [DIG_LIGHT]: diglight.lua's server beside a client that reads its own
# light at t=15 (the pit), t=70 (the stair) and t=115 (its third step, the player put there) -- the scan's eye light
# line and a scan_volume with light rows. Prints the two readings side
# by side; the log is under local/diglight/.
#
#   SEED=5 builtin/luanti/test/diglight.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
SEED="${SEED:-5}"
GAME="${GAME:-mineclone2}"
# The client's render mode: pbr, shadows or unlit ([STAIR_DARK]'s
# discriminator is the same stair in shadows against pbr)
MODE="${MODE:-pbr}"
out="$here/local/diglight"
mkdir -p "$out"
save="buildat_test_diglight"
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
{ echo "rawset(_G, \"FUZZ_SEED\", $SEED)"; cat "$me/diglight.lua"; } > "$out/fixture.lua"
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$out/srv.log" "Mods loaded" 180 29777 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l "${LOG_LEVEL:-4}" ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap 'kill "$srv" 2>/dev/null' EXIT
# Each read on the fixture's chat line for its moment; the half second after a
# look, the view turned drawn
cat > "$out/cmds.txt" <<CMDS
wait_log 120000 chat: diglight: t=15
event scan
event scan_volume 4 t15 light
wait_log 70000 chat: diglight: t=70
event scan
event scan_volume 4 t70 light
look_dir 1 -0.5 0
# a settle: first person is aimed at once, the view drawn after it
delay 500
screenshot $out/stair_${MODE}_t70.png
wait_log 60000 chat: diglight: t=115
event scan
event scan_volume 4 t115 light
wait_log 30000 chat: diglight: t=135
event scan
event scan_volume 4 t135 light
look_dir -1 0.3 0
# a settle: first person is aimed at once, the view drawn after it
delay 500
screenshot $out/stair_${MODE}_step3_up.png
look_dir 1 -0.3 0
# a settle: first person is aimed at once, the view drawn after it
delay 500
screenshot $out/stair_${MODE}_step3_down.png
wait_log 30000 chat: diglight: t=155
event scan
event scan_volume 4 t155 light
look_dir 1 -0.5 0
# a settle: first person is aimed at once, the view drawn after it
delay 500
screenshot $out/stair_${MODE}_t155.png
look_dir 1 -1.5 0
# a settle: first person is aimed at once, the view drawn after it
delay 500
screenshot $out/stair_${MODE}_t155_pit.png
quit
CMDS
BUILDAT_RENDER_MODE="$MODE" timeout 600 bin/buildat -s localhost:29777 -w 1280x720 -l "${CLIENT_LOG_LEVEL:-3}" \
	-c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	{ echo "FAIL: the drive ($out/cli.log): $(grep -a "Command sequence failed\|an error the drive" "$out/cli.log" | tail -1)"; exit 1; }
kill -INT "$srv" 2>/dev/null
# The server's exit, polled
for i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
grep "diglight:" "$out/srv.log" | sed 's/.*diglight: //' | grep -v "t=[0-9]*[1-46-9] " 
grep "light sky\|voxel names\|light y=" "$out/cli.log" | sed 's/.*scan /scan /'
# **The verdict is that the measurement happened**, not what the numbers
# are: what the light should be at the bottom of a fresh pit is the
# reading this runner exists to give a person, and a threshold invented
# here would be a number nobody picked. What can fail without anybody
# noticing is the drive -- a fixture that never dug, a client that never
# scanned -- and that is what this says. ([CI_RUNS]'s contract, and
# run_all.sh reads the last PASS:/FAIL: line.)
rows=$(grep -ac "diglight: t=" "$out/srv.log")
scans=$(grep -ac "light sky\|light y=" "$out/cli.log")
echo "the fixture reported $rows readings and the client scanned $scans times"
if [ "$rows" -lt 3 ] || [ "$scans" -lt 1 ]; then
	echo "FAIL: the run did not dig or did not scan, so there is nothing to read"
	exit 1
fi
echo "PASS: the pit and the stair were dug and their light read"
exit 0
# vim: set noet ts=4 sw=4:
