#!/bin/bash
# tier: quick
# cost: ~40 s (2026-10-09)
# covers: src/client/app.cpp client/extensions/network/init.lua extensions/launch_menu/init.lua
# [JOINED_TLS_SERVERS]: a server joined is on launch_menu's start
# screen whether or not it sends an icon, and one behind TLS by its https
# address. A digger server with no icon is joined once; its row is
# written, with no icon. The store then gets an https row joined later,
# as a TLS join writes it (the join itself needs a certificate the
# client trusts, so it is tried against a real server by hand); the
# menu's first row is it, and a search for "tls" finds it.
#
#   extensions/launch_menu/joined_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
check_tmp joined; t=$CHECK_TMP
P=29887
cd "$(dirname "$0")/../../Build"
start_server "$t/srv.log" "Listening at" 60 $P \
	bin/buildat_server -m ../apps/digger -D "$t/srv" -l 3 ||
	fail "digger did not start"
CHECK_PIDS+=($SERVER_PID)
grep -aq "The server's icon:" "$t/srv.log" && fail "the server has an icon"
# The network extension says when the joined server's row is written
printf 'wait_log_any 30000 network: the server tcp://localhost:%s remembered\nquit\n' $P \
	> "$t/cmds"
timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -C "$t/cache" \
	-s localhost:$P -w 640x360 -l 3 -o sound_mute=1 -c @"$t/cmds" \
	> "$t/cl1.log" 2>&1 ||
	fail "the join's drive ($t/cl1.log): $(grep -ao 'Command sequence failed.*' "$t/cl1.log" | head -1)"
grep -q "\"tcp://localhost:$P\",\"\",\"[0-9]*\",\"[0-9]*\",\"\",\"\",\"\"" \
	"$t/cl/network_addresses.csv" ||
	fail "no row for the server joined: $(cat "$t/cl/network_addresses.csv")"
echo "\"true\",\"https://tls.example.org:443\",\"\",\"0\",\"$(($(date +%s) + 60))\",\"\",\"\",\"\"" \
	>> "$t/cl/network_addresses.csv"
# Home's list, then the search's
printf 'wait_log_any 30000 rows in\ntext tls\nwait_log 5000 rows for "tls"\nquit\n' > "$t/cmds"
timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -C "$t/cache" \
	-w 1024x640 -l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/cl2.log" 2>&1 ||
	fail "the menu's drive ($t/cl2.log): $(grep -ao 'Command sequence failed.*' "$t/cl2.log" | head -1)"
grep -aq "launch_menu: [0-9]* rows in [0-9]* ms, first https://tls.example.org:443" \
	"$t/cl2.log" || fail "the TLS row is not first: $(grep -a "rows in" "$t/cl2.log")"
grep -aq "rows for \"tls\" in [0-9]* ms, first https://tls.example.org:443" \
	"$t/cl2.log" || fail "the search does not find it: $(grep -a "rows for" "$t/cl2.log")"
echo "PASS: joined: a server with no icon has its row, an https row is the start screen's first and found"
