#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-17)
# covers: apps/floorplanner/main/client_lua/editor.lua apps/floorplanner/main/client_lua/pause.lua
# [FP_OUTSIDE_CLOSE]: a press on the background round the pause menu or
# the layouts menu closes it at the release; one on the window does not.
# A local plan at 1100x1000: the pause menu (Escape), a click on the plan
# at its left closes it; opened again, a click on its title keeps it.
# The layouts menu from the toolbar's "Ground floor", the same (a click
# on its title row).
#   apps/floorplanner/outside_close_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp fp_outside; t=$CHECK_TMP
trap check_cleanup EXIT
cat > "$t/cmds" <<C
wait_log 60000 Entered the plan
frames 3
keypress Escape
wait_log 5000 Pause menu shown
delay 500
mouse_pos 100 700
delay 200
mouse_click left
wait_log 3000 A press off the pause menu closes it
delay 500
keypress Escape
wait_log 5000 Pause menu shown
delay 500
mouse_pos 550 268
delay 200
mouse_click left
delay 800
keypress Escape
delay 500
click Button "Ground floor"
wait_log 3000 Layouts menu shown
delay 500
mouse_pos 100 700
delay 200
mouse_click left
wait_log 3000 A press off the layouts menu closes it
delay 500
click Button "Ground floor"
wait_log 3000 Layouts menu shown
delay 500
mouse_pos 550 85
delay 200
mouse_click left
delay 800
quit
C
BUILDAT_FP_NAME=owner BUILDAT_FP_PLAN=oc timeout 240 "$here/Build/bin/buildat" \
	-o launch_ui=launch_menu -w 1100x1000 -u 1 -l 3 -o sound_mute=1 \
	-C "$t/c" -D "$t/u" -a app/floorplanner/play -c @"$t/cmds" > "$t/f.log" 2>&1 ||
	fail "the drive ($t/f.log: $(grep -a "Command sequence failed" "$t/f.log" | tail -1))"
# The app's lines, not the drive's waits that quote them
said(){ grep -a "$1" "$t/f.log" | grep -avc " __app   : "; }
[ "$(said "A press off the pause menu closes it")" = 1 ] &&
	[ "$(said "A press off the layouts menu closes it")" = 1 ] ||
	fail "a press on a window closed it, or one off it did not ($t/f.log)"
echo "PASS: the pause menu and the layouts menu close on a press beside them, not on one on them"
