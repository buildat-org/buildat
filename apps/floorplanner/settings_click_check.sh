#!/bin/bash
# tier: full
# cost: ~1 min (2026-11-14)
# covers: apps/floorplanner/main/client_lua/editor.lua apps/floorplanner/main/client_lua/pause.lua extensions/launch_menu/preferences.lua
# [FP_SETTINGS_MOUSE_GRAB]: the planner stays paused under the client's
# settings window (Client settings...), so a click on the window is the
# window's: walking's crosshair took the mouse at the first one. A local
# plan walked (F3) at 1100x1000: the pause menu, Client settings..., the
# Angle dropdown's "45 deg" picked (the section drawn again) and picked
# again (only closed), Key bindings... and its Escape, Key bindings...
# again, Escape back to the pause menu; Continue, and a click on the view,
# which is the one time the crosshair takes the mouse. The editor logs its
# crosshair's hold, as a -c run's mouse mode stays absolute.
#   apps/floorplanner/settings_click_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp fp_settings_click; t=$CHECK_TMP
trap check_cleanup EXIT
wheel=$(for _ in $(seq 20); do echo "mouse_wheel -1"; done)
cat > "$t/cmds" <<C
wait_log 60000 Entered the plan
frames 3
keypress F3
frames 3
keypress Escape
wait_log 5000 Pause menu shown
click Button "Client settings..."
wait_log 5000 Game settings shown
delay 500
click DropDownList "▼" 668 150
wait_log 3000 dropdown_
frames 3
click Text "45 deg"
frames 3
click DropDownList "▼" 668 150
wait_log 3000 dropdown_
frames 3
click Text "45 deg"
wait_log 3000 dropdown_
mouse_pos 550 500
$wheel
# the wheel's frames: the scrolls read before the click looks for its button
delay 500
click Button "Key bindings..."
wait_log 3000 Game keys shown
keypress Escape
wait_log 3000 Game keys closed
delay 300
click Button "Key bindings..."
wait_log 3000 Game keys shown
keypress Escape
wait_log 3000 Game keys closed
delay 300
keypress Escape
wait_log 3000 Pause menu shown
delay 300
keypress Escape
frames 3
mouse_pos 550 500
mouse_click left
wait_log 3000 The crosshair holds the mouse
keypress Escape
wait_log 3000 The pointer is free
quit
C
BUILDAT_FP_NAME=owner BUILDAT_FP_PLAN=sc timeout 240 "$here/Build/bin/buildat" \
	-o launch_ui=launch_menu -w 1100x1000 -u 1 -l 3 -o sound_mute=1 \
	-C "$t/c" -D "$t/u" -a app/floorplanner/play -c @"$t/cmds" > "$t/f.log" 2>&1 ||
	fail "the drive ($t/f.log: $(grep -a "Command sequence failed" "$t/f.log" | tail -1))"
# The app's lines, not the drive's waits that quote them
said(){ grep -a "$1" "$t/f.log" | grep -avc " __app   : "; }
[ "$(said "The crosshair holds the mouse")" = 1 ] ||
	fail "a click on the settings window went into the crosshair ($t/f.log)"
[ "$(said "Pause menu shown")" = 2 ] ||
	fail "the pause menu not shown once before the window and once after ($t/f.log)"
# The pick drew the section again, a new dropdown; the same choice picked
# in that one closed it
[ "$(grep -ao "dropdown_[0-9]* open" "$t/f.log" | sort -u | wc -l)" = 2 ] &&
	[ "$(said "dropdown_[0-9]* closed")" = 1 ] ||
	fail "the angle dropdown did not take the pick ($t/f.log)"
echo "PASS: a click on the client's settings window is the window's, not the crosshair's"
