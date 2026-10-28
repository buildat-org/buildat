#!/bin/bash
# tier: quick
# cost: ~6 s (2026-10-28)
# covers: client/core/urho3d/init.lua extensions/ui_utils/init.lua
# [CLIENT_CALLBACK_LEAK]: a closed screen's event callbacks, and the
# screen they hold, are let go. Home's type-to-search pops its screen and
# draws a new one per letter; after 40 letters and after 60 (each past the
# second a "Nothing matches" screen like the last), `event luamem` gives
# Lua's memory after a full collect, the __buildat_sandbox_callback_
# globals and the object subscriptions' callbacks held. The 20 screens
# between leave the globals and the callbacks held as they were and the
# memory within 60 KB: before, each screen kept ~35 KB and 11 globals.
# (The first 40 are the warm-up: 2 to 20 letters grows ~200 KB either way,
# 20 to 40 ~50-60, 40 to 60 and 60 to 80 under 5; 2026-10-28.)
#
#   util/callback_leak_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
check_tmp callback_leak; t=$CHECK_TMP
cd "$(dirname "$0")/../Build"
{
	echo "wait_log_any 30000 rows in"; echo "delay 300"
	q=""
	for i in $(seq 60); do
		q="${q}x"
		echo "text x"; echo "wait_log 5000 rows for \"$q\""
		case $i in 40|60) echo "delay 200"; echo "event luamem"
			echo "delay 100";; esac
	done
	echo quit
} > "$t/cmds"
run_client 30 "$t/cl.log" timeout 90 bin/buildat -o launch_ui=launch_menu \
	-D "$t/cl" -C "$t/cache" -w 1024x640 -l 3 -o sound_mute=1 -c @"$t/cmds" ||
	fail "the drive ($t/cl.log): $(grep -ao 'Command sequence failed.*' "$t/cl.log" | head -1)"
m=$(grep -ao 'luamem: [0-9]* KB, [0-9]* callback globals, [0-9]* object callbacks held' "$t/cl.log" |
	awk '{print $2, $4, $7}')
[ "$(echo "$m" | wc -l)" = 2 ] || fail "no two luamem lines ($t/cl.log)"
read -r kb1 g1 h1 <<< "$(echo "$m" | head -1)"
read -r kb2 g2 h2 <<< "$(echo "$m" | tail -1)"
echo "after 40 letters: $kb1 KB, $g1 globals, $h1 held; after 60: $kb2 KB, $g2 globals, $h2 held"
[ "$g2" -le "$g1" ] || fail "the callback globals grew: $g1 to $g2"
[ "$h2" -le "$h1" ] || fail "the object callbacks held grew: $h1 to $h2"
[ "$kb2" -le "$((kb1 + 60))" ] || fail "Lua's memory grew $((kb2 - kb1)) KB over 20 screens"
echo "PASS: 20 closed screens let go: the globals $g1 to $g2, the callbacks held $h1 to $h2, Lua's memory $kb1 to $kb2 KB"
