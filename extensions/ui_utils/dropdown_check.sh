#!/bin/bash
# tier: quick
# cost: ~10 s (2026-11-05)
# covers: extensions/ui_utils/init.lua extensions/launch_menu/screens.lua
# [UI_DROPDOWN]: ui_utils.dropdown, on launch_menu's Join by address (its
# Buildat or Luanti; [SERVERS_SCREEN] took the Servers filter this drove).
# The mouse opens it, Down and Enter pick Luanti; Enter opens it again,
# Up and Escape close it with Luanti kept, as Join says, and the screen
# stays up (its Escape not seen).
#
#   extensions/ui_utils/dropdown_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
check_tmp dropdown; t=$CHECK_TMP
mkdir -p "$t/cl"
# Home's Servers row, its Join by address, then the dropdown. Each step
# waits for its line: launch_menu's for a screen drawn, ui_utils's
# "dropdown_<n> open"/"closed" for the popup (the serial is not known
# here, so the word). The half seconds after a screen's line are its
# rows laid out in the next frames, before a click; the keys go in one
# frame, in order, to the popup's list that has the focus.
cat > "$t/cmds" <<CMDS
wait_log_any 30000 rows in
delay 500
keypress Down
keypress Return
wait_log 10000 Servers: shown
delay 500
click Button "Join by address..."
wait_log 5000 Join by address: shown
delay 500
click DropDownList "dropdown_*"
wait_log 5000 open
mouse_pos 900 600
keypress Down
keypress Return
wait_log 5000 closed
delay 100
keypress Return
wait_log 5000 open
keypress Up
keypress Escape
wait_log 5000 closed
delay 500
event scan
click Button "Join"
wait_log 5000 Join by address:
quit
CMDS
cd "$(dirname "$0")/../../Build"
timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -C "$t/cache" \
	-w 1024x640 -l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/cl.log" 2>&1 ||
	fail "the drive ($t/cl.log): $(grep -ao 'Command sequence failed.*' "$t/cl.log" | head -1)"
grep -aq 'scan: ui .*text "Join by address"' "$t/cl.log" ||
	fail "Escape closed the screen"
grep -aq "Join by address: Luanti " "$t/cl.log" ||
	fail "not Luanti after the pick and Escape: $(grep -a 'Join by address: [BL]' "$t/cl.log")"
echo "PASS: dropdown: opened by the mouse, picked by the keys, Escape kept the pick and the screen"
