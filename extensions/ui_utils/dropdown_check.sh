#!/bin/bash
# tier: broken
# broken: back to quick; the filter went: All Starport; the same on dev
#   (local/runs/dev_baseline)
# cost: ~25 s (2026-10-09)
# covers: extensions/ui_utils/init.lua extensions/launch_menu/init.lua
# [UI_DROPDOWN]: ui_utils.dropdown, on launch_menu's Servers filter.
# The mouse opens it, Down twice and Enter pick LAN; Enter opens it again,
# Down and Escape close it with LAN kept, and the screen stays up (its
# Escape not seen). The Luanti server list's consent is declined ahead.
#
#   extensions/ui_utils/dropdown_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
check_tmp dropdown; t=$CHECK_TMP
mkdir -p "$t/cl"
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"false","https://servers.luanti.org","the server list","1791497098","1791497098","","",""\n' \
	> "$t/cl/network_addresses.csv"
# Home's Servers row, then the filter at the list's top left. Each step
# waits for its line: launch_menu's for a list drawn, ui_utils's
# "dropdown_<n> open"/"closed" for the popup (the serial is not known
# here, so the word). The half seconds after a list's line are its rows
# laid out in the next frames, before a click at their pixels; the keys
# go in one frame, in order, to the popup's list that has the focus.
cat > "$t/cmds" <<CMDS
wait_log_any 30000 rows in
delay 500
mouse_pos 360 316
mouse_click left
wait_log 10000 launch_menu: server, 
delay 500
mouse_pos 280 276
mouse_click left
wait_log 5000 open
mouse_pos 900 600
keypress Down
keypress Down
keypress Return
wait_log 10000 launch_menu: server, 
keypress Return
wait_log 5000 open
keypress Down
keypress Escape
wait_log 5000 closed
delay 500
event scan
quit
CMDS
cd "$(dirname "$0")/../../Build"
timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -C "$t/cache" \
	-w 1024x640 -l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/cl.log" 2>&1 ||
	fail "the drive ($t/cl.log): $(grep -ao 'Command sequence failed.*' "$t/cl.log" | head -1)"
lists=$(grep -ao "launch_menu: server, [0-9]* rows, by recent, .*" "$t/cl.log" |
	sed 's/.*, //')
[ "$lists" = "All
LAN" ] || fail "the filter went: $(echo $lists) ($t/cl.log)"
grep -aq 'scan: ui .*text "Servers   (type' "$t/cl.log" ||
	fail "Escape closed the screen with the list"
echo "PASS: dropdown: opened by the mouse, picked by the keys, Escape kept the pick and the screen"
