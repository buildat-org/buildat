#!/bin/bash
# tier: quick
# cost: ~30 s (2026-10-09)
# covers: client/extensions/network/init.lua client/extensions/starport/init.lua client/extensions/aitta/publish.lua
# [AITTA_NET_DESC]: a fresh client (no network permissions) opens "Apps
# from Aitta" against a local Aitta. The permission dialog's field reads
# "Aitta (app list)" (a ui scan); Return in the field accepts: the entry
# saved accepted with that description, no "no description" warning. A
# screenshot of the dialog.
#
#   apps/aitta/net_desc_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp aitta_net_desc; t=$CHECK_TMP

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
A=http://127.0.0.1:$SERVER_PORT
echo "{\"aittas\": [\"$A\"]}" > "$t/managed.json"
cat > "$t/cmds" <<C
delay 4000
text apps from aitta
delay 1000
keypress Return
wait_log 10000 Asking the user about $A
delay 1000
event scan dialog
screenshot $t/dialog.png
click LineEdit "Aitta (app list)"
delay 300
keypress Return
delay 3000
quit
C
BUILDAT_STARPORT_MANAGED="$t/managed.json" timeout 90 bin/buildat \
	-m launch_menu -D "$t/cl" -w 1024x700 -l 3 -o sound_mute=1 -c @"$t/cmds" \
	> "$t/cl.log" 2>&1
grep -aq "Command sequence complete" "$t/cl.log" ||
	fail "the drive ($(grep -a "Command seq\|Asking" "$t/cl.log" | tail -3))"
grep -a "scan dialog: " "$t/cl.log" | grep -aq 'LineEdit.*"Aitta (app list)"' ||
	fail "the field: $(grep -a 'scan dialog: .*LineEdit' "$t/cl.log" | head -2)"
grep -a "$A" "$t/cl/network_addresses.csv" | grep -q '^"true",.*"Aitta (app list)"' ||
	fail "not accepted by Return: $(cat "$t/cl/network_addresses.csv")"
grep -aq "no description from the caller" "$t/cl.log" &&
	fail "a fetch without a description: $(grep -a 'no description' "$t/cl.log" | head -2)"
echo "PASS: the dialog's field reads \"Aitta (app list)\", Return in it accepts (see $t/dialog.png)"
