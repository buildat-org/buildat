#!/bin/bash
# tier: full
# cost: 40s (2026-10-04)
# covers: client/extensions/network/init.lua apps/sample_ui/**
# [CONSENT_PER_SERVER]: a script's network consent is the asking server's.
# Two sample_ui servers; the client's store holds an accepted row for
# tcp://localhost:9 given to the first.
#   1. Connected to the first: its script's connect takes the row, no
#      dialog.
#   2. Connected to the second: the same connect asks the user, and the
#      dialog names that server.
#
#   util/consent_check.sh    (SHOT=x.png keeps the second's dialog)
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
pids=
trap 'kill $pids 2>/dev/null; rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
cd "$here/Build"
A=29811; B=29812
for p in $A $B; do
	start_server "$t/srv$p.log" "STATUS Listening" 60 $p \
		bin/buildat_server -m ../apps/sample_ui -D "$t/srv$p" -l 3 ||
		fail "server $p did not start"
	pids="$pids $SERVER_PID"
done
mkdir -p "$t/u"
now=$(date +%s)
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","tcp://localhost:9","","%s","%s","","","localhost:%s"\n' \
	$now $now $A > "$t/u/network_addresses.csv"
client(){   # port, sequence -> $t/c$port.log
	printf "$2" > "$t/seq$1"
	timeout 60 bin/buildat -o launch_ui=launch_menu -s localhost:$1 -D "$t/u" -w 800x600 -l 3 \
		-o sound_mute=1 -c @"$t/seq$1" > "$t/c$1.log" 2>&1 ||
		fail "the drive on $1 ($t/c$1.log): $(grep -ao 'Command sequence failed.*' "$t/c$1.log" | head -1)"
}
# 1
client $A 'wait_log 30000 sample_ui: tcp_connect\nquit\n'
# Not the drive's own wait for it
grep "sample_ui: tcp_connect" "$t/c$A.log" | grep -qv wait_log ||
	fail "the first server's script did not connect ($(tail -3 "$t/c$A.log"))"
grep -q "Asking the user about tcp://localhost:9" "$t/c$A.log" &&
	fail "asked again for the server the row was given to"
# 2: the dialog drawn in the frames after the line
client $B "wait_log 30000 Asking the user about\ndelay 500\nscreenshot $t/b.png\nquit\n"
grep -q "Asking the user about tcp://localhost:9 for \"localhost:$B\"" "$t/c$B.log" ||
	fail "the second server's script was not asked about ($(grep -a 'Asking\|tcp_connect' "$t/c$B.log" | tail -3))"
[ -n "${SHOT:-}" ] && cp "$t/b.png" "$SHOT"
echo "PASS: the row given to one server's scripts was not the other's"
