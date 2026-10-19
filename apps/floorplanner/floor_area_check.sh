#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-17)
# covers: apps/floorplanner/main/client_lua/editor.lua apps/floorplanner/main/client_lua/rebuild.lua apps/floorplanner/main/client_lua/geom.lua
# [FP_FLOOR_AREA]: each layout's rooms' net floor summed on its button in
# the layouts menu. A local plan, editing: a 4000 x 3000 room with no
# walls (a drive event), the menu's button reads "(12.00 m2)"; a 2000 x
# 2000 room added while the menu is open makes it "(16.00 m2)". Then
# [FP_NET_WALLS]: a 100 mm partition 2000 long standing in the first
# room takes 0.2 m2 (15.80); one 1000 long in the second hung with its
# bottom at 1700 takes nothing, at 1500 its 0.1 m2 (15.70). The buttons
# are clicked by their labels, which is the assertion.
# simplified: one layout; another's sum is the same code over its rooms
# (rebuild() builds every layout)
#   apps/floorplanner/floor_area_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp fp_area; t=$CHECK_TMP
trap check_cleanup EXIT
cat > "$t/cmds" <<C
wait_log 60000 Entered the plan
delay 1500
click Button "Start editing"
delay 1000
event fp_room 0 0 4000 3000
delay 1500
click Button "Ground floor"
wait_log 3000 Layouts menu shown
delay 500
click Button "Building: Ground floor (12.00 m2)"
delay 1000
event fp_room 5000 0 7000 2000
delay 1500
click Button "Building: Ground floor (16.00 m2)"
delay 500
event fp_wall 2000 500 2000 2500
delay 1500
click Button "Building: Ground floor (15.80 m2)"
delay 500
event fp_wall 6000 500 6000 1500 1700
delay 1500
click Button "Building: Ground floor (15.80 m2)"
delay 500
event fp_wall 6500 500 6500 1500 1500
delay 1500
click Button "Building: Ground floor (15.70 m2)"
delay 500
quit
C
BUILDAT_FP_NAME=owner BUILDAT_FP_PLAN=area timeout 240 "$here/Build/bin/buildat" \
	-o launch_ui=launch_menu -w 1100x1000 -u 1 -l 3 -o sound_mute=1 \
	-C "$t/c" -D "$t/u" -a app/floorplanner/play -c @"$t/cmds" > "$t/f.log" 2>&1 ||
	fail "the drive ($t/f.log: $(grep -a "Command sequence failed" "$t/f.log" | tail -1))"
echo "PASS: a layout's button says its rooms' net area, and follows a change"
