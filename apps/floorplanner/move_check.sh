#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-19)
# covers: apps/floorplanner/main/client_lua/editor.lua apps/floorplanner/main/client_lua/rebuild.lua apps/floorplanner/main/client_lua/init.lua
# [FP_MOVE_FAST]: a move's time in a complex plan. The Torkkola plan
# (user/exports/Torkkola_suunnitelma1_2026-10-06.fpplan, the user's: SKIP
# without it) imported through the plans page; for a piece of furniture, a
# door and a wall node in turn ("event fp_select"), five W presses and a
# 2 s drag in the plan view, then the drags in 3D under PBR. The editor
# logs each key step's time from the key to the frame showing it and each
# drag's frame times, "fp move: <what> <view> key N ms" and "... drag
# frames p50 N p95 N ms", with the rebuilds', the lighting's, the panels'
# and the round trip's times.
#   apps/floorplanner/move_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
plan=Torkkola_suunnitelma1_2026-10-06.fpplan
[ -f "$here/user/exports/$plan" ] || { echo "SKIP: no $plan in user/exports"; exit 0; }
check_tmp fp_move; t=$CHECK_TMP
trap check_cleanup EXIT
mkdir -p "$t/u/exports"
cp "$here/user/exports/$plan" "$t/u/exports/"
# A 2 s drag from the window's middle, where fp_select puts the thing
drag() {
	echo "mouse_pos 550 500"; echo "delay 300"; echo "mouse_down left"
	for i in $(seq 40); do echo "mouse_pos $((550 + i * 4)) 500"; echo "delay 50"; done
	echo "mouse_up left"; echo "delay 2000"
}
{
	cat <<C
wait_log 60000 Plans:
delay 1500
click Button "Import a plan..."
delay 500
click Button "Choose a file..."
wait_log 5000 The file picker at
delay 500
click Button "$plan"
delay 1000
click Button "Import"
wait_log 60000 Entered the plan
delay 3000
click Button "Start editing"
delay 2000
C
	for what in furniture door node; do
		echo "event fp_select $what 2d"; echo "delay 1500"
		for i in 1 2 3 4 5; do echo "keypress W"; echo "delay 700"; done
		drag
	done
	for what in furniture door node; do
		echo "event fp_select $what 3d"; echo "delay 4000"
		drag
	done
	echo quit
} > "$t/cmds"
BUILDAT_FP_NAME=owner timeout 300 "$here/Build/bin/buildat" \
	-o launch_ui=launch_menu -w 1100x1000 -u 1 -l 3 -o sound_mute=1 \
	-C "$t/c" -D "$t/u" -a app/floorplanner/play -c @"$t/cmds" > "$t/f.log" 2>&1 ||
	fail "the drive ($t/f.log: $(grep -a "Command sequence failed" "$t/f.log" | tail -1))"
grep -a "fp move: " "$t/f.log" | sed 's/.*fp move: //'
echo "PASS: the moves measured"
