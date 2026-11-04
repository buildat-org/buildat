#!/bin/bash
# tier: full
# cost: ~2 min (2026-11-04)
# covers: src/client/local_server.h extensions/launch_menu/screens.lua
# [LAN_KEEP_LOGIN]: a LAN game's kept login outlives the host's restart.
#   1. Floor planner launched and opened to the LAN; a second client finds
#      it under LAN in Servers, joins it by one click ([SERVERS_SCREEN])
#      and makes an account with "Keep me logged in".
#   2. The host closed and the app launched again: its server is on the
#      same port, and the second client, by the same click, logs in with
#      the kept login, no dialog.
#   3. The ports other apps remembered (all but one of the range, in
#      local_ports.txt) are skipped: an app with none of its own gets the
#      one left.
#   util/lan_keep_login_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp lan_keep_login; t=$CHECK_TMP
trap check_cleanup EXIT
cd "$here/Build"
client(){ timeout 240 bin/buildat -o launch_ui=launch_menu -w 1024x700 -l 3 -o sound_mute=1 "$@"; }

# host <log>: Floor planner opened to the LAN, held until killed; echoes
# the address
cat > "$t/h.cmds" <<C
wait_log 60000 Plan picker:
delay 1000
click Button "Menu..."
wait_log 5000 The plan picker's menu shown
click Button "My account..."
wait_log 5000 server window: the page account
delay 500
click Button "Open to LAN"
wait_log 5000 server window: the page lan
delay 1000
click Button "Open to LAN" 900 0
wait_log 10000 Open to LAN: Open to the LAN at
delay 240000
quit
C
host(){
	# timeout itself in the background, so that a kill reaches the client
	BUILDAT_FP_NAME=owner timeout 300 bin/buildat -o launch_ui=launch_menu \
		-w 1024x700 -l 3 -o sound_mute=1 -C "$t/ca" -D "$t/ua" \
		-a app/floorplanner/play -c @"$t/h.cmds" > "$t/$1" 2>&1 &
	HOST=$!
	CHECK_PIDS+=($HOST)
	for _ in $(seq 450); do
		grep -aq "Open to LAN: Open to the LAN at" "$t/$1" && break
		kill -0 $HOST 2>/dev/null ||
			fail "the host's drive ended ($(grep -a "Command sequence failed" "$t/$1" | tail -1))"
		sleep 0.2
	done
	AT=$(grep -ao "Open to the LAN at [0-9.]*:[0-9]*" "$t/$1" | head -1 | cut -d' ' -f6)
	[ -n "$AT" ] || fail "not opened ($t/$1)"
}
# The guest: Servers, the LAN's floorplanner clicked, in the plan picker
cat > "$t/g.cmds" <<C
wait_log_any 30000 Servers: shown
wait_log_any 10000 LAN: 1 heard
delay 300
click Button "floorplanner"
wait_log 60000 Plan picker:
quit
C
guest(){ # log, env...
	local log=$1; shift
	env "$@" timeout 240 bin/buildat -o launch_ui=launch_menu -w 1024x700 -l 3 \
		-o sound_mute=1 -C "$t/cb" -D "$t/ub" -a extension/launch_menu/servers \
		-c @"$t/g.cmds" > "$t/$log" 2>&1 ||
		fail "the guest's drive ($(grep -a "Command sequence failed" "$t/$log" | tail -1); $t/$log)"
}

# The host gone, and its server with it: the port free
stop_host(){
	kill $HOST; wait $HOST 2>/dev/null
	for _ in $(seq 100); do
		(echo > /dev/tcp/127.0.0.1/"${AT#*:}") 2>/dev/null || return 0
		sleep 0.2
	done
	fail "the server on ${AT#*:} did not stop with its client"
}

# 1
host h1.log
first=$AT
guest g1.log BUILDAT_FP_NAME=guest BUILDAT_FP_PASSWORD=guestpass12 \
	BUILDAT_FP_CREATE=1 BUILDAT_FP_KEEP=1
grep -aq "Servers: join floorplanner" "$t/g1.log" || fail "the click did not join ($t/g1.log)"
[ -s "$t/ub/servers/${first/:/_}/token" ] ||
	fail "no login kept for $first ($(ls "$t/ub/servers" 2>&1))"
echo "ok: joined $first from Servers by a click, the login kept"
stop_host

# 2
host h2.log
[ "$AT" = "$first" ] || fail "the restarted host is at $AT, not $first"
guest g2.log
grep -aq "Logging in as guest with the kept login" "$t/g2.log" ||
	fail "the kept login was not used ($t/g2.log)"
echo "ok: the restarted host on $AT took the kept login"
stop_host

# 3: every port of the range another app's but one
free=29777
for p in $(seq 29168 29999); do
	[ $p = $free ] || echo "$p other_$p"
done > "$t/ua/local_ports.txt"
printf 'wait_log 60000 Plan picker:\nquit\n' > "$t/p.cmds"
BUILDAT_FP_NAME=owner client -C "$t/ca" -D "$t/ua" -a app/floorplanner/play \
	-c @"$t/p.cmds" > "$t/h3.log" 2>&1 || fail "the third start ($t/h3.log)"
got=$(grep -ao "Starting local server on port [0-9]*" "$t/h3.log" | head -1 | awk '{print $NF}')
[ "$got" = $free ] || fail "picked ${got:-nothing}, not the one port no other app keeps ($free)"
grep -q "^$free floorplanner" "$t/ua/local_ports.txt" ||
	fail "not remembered: $(grep -v other_ "$t/ua/local_ports.txt")"
echo "PASS: the LAN host's port kept across a restart, the kept login used; other apps' ports skipped"
