#!/bin/bash
# tier: full
# cost: 60s a run, seven runs (2026-10-02)
# covers: client/core/starport/** apps/starport/main/** builtin/starport_announce/**
# [REPORT_HERE]: "Report this server..." finds the listing of the server
# a native client is on. A local Starport, a floorplanner listed and
# claimed on it, and a player's client with only that Starport, which
# opens the report from the plan picker's menu by the keyboard. Each run is
# one combination of the public address in starport.json (with the port,
# without it, none) and the address the client joined by (with the port,
# without it); and one where the listing is under another name for the
# same host, which must offer the listing to pick.
#
# An address without the port means 29500, so those runs need the
# server there; with 29500 taken (a server of the desk's) the server is on
# 29643 and they are skipped, said as such.
#
#   apps/starport/report_here.sh            all of them
#   apps/starport/report_here.sh ADDR JOIN  one: the public address
#                                           ("" for none) and -s
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
if [ -z "${AN:-}" ]; then
	AN=29500
	ss -ltn | grep -q ":29500 " && AN=29643
	export AN
fi
if [ $# -lt 2 ]; then
	fail=0
	for combo in "127.0.0.1:$AN|127.0.0.1:$AN" "127.0.0.1:$AN|127.0.0.1" \
			"127.0.0.1|127.0.0.1:$AN" "127.0.0.1|127.0.0.1" \
			"|127.0.0.1:$AN" "|127.0.0.1"; do
		a=${combo%%|*} c=${combo##*|}
		if [ $AN != 29500 ] && { [ -n "$a" ] && [ "${a#*:}" = "$a" ] ||
				[ "${c#*:}" = "$c" ]; }; then
			echo "public '$a', joined '$c': SKIP, 29500 is taken"
			continue
		fi
		r=$("$0" "$a" "$c" | grep "report here: connected")
		echo "public '$a', joined '$c': ${r##*; }"
		echo "$r" | grep -q "; found$" || fail=1
	done
	r=$("$0" "localhost:$AN" "127.0.0.1:$AN" | grep "report here:")
	echo "listed as localhost, joined as 127.0.0.1: $(echo "$r" | tail -1 | sed 's/.*report here: //')"
	echo "$r" | grep -q "NOT FOUND" && echo "$r" | grep -q " 1 listings offered" || fail=1
	[ $fail = 0 ] && echo "PASS: the report finds the listing however the address was written" ||
		echo "FAIL: a listing was not found, or not offered (local/report_here/)"
	exit $fail
fi
tmp=$here/local/report_here; rm -rf $tmp; mkdir -p $tmp/sp $tmp/an/apps/floorplanner $tmp/cl $tmp/fc
SP=29641
pids=()
stop() { for p in "${pids[@]}"; do kill -INT $p 2>/dev/null; done
	for _ in $(seq 150); do ss -ltn | grep -qE ":($AN|$SP) " || break; sleep 0.2; done; }
trap stop EXIT
# A line in a log, while its process lives
upto() { # log text seconds pid
	local i
	for i in $(seq $(($3 * 5))); do
		grep -aq "$2" "$1" && return 0
		kill -0 "$4" 2>/dev/null || return 1
		sleep 0.2
	done
	return 1
}
addr=""
[ -n "$1" ] && addr="\"address\": \"$1\","
cat > $tmp/an/apps/floorplanner/starport.json <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Check house", $addr
 "kind": "app", "audience": "everyone", "access": "open",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "none",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
cd "$here"
# Its box lets it verify the listing on 29500 only, unless told
BUILDAT_CONNECT_PORTS=$AN Build/bin/buildat_server -m apps/starport -D $tmp/sp -P $SP -l 3 > $tmp/sp.log 2>&1 & pids+=($!)
upto $tmp/sp.log "setup code" 60 $! || { echo "FAIL: the Starport did not start ($tmp/sp.log)"; exit 1; }
code=$(grep -o "setup code [A-Z0-9]*" $tmp/sp.log | cut -d' ' -f3)
# The announce is to a Starport on a port of the moment, which the
# server's box refuses unless told ([PROCESS_SANDBOX])
BUILDAT_CONNECT_PORTS=$SP Build/bin/buildat_server -m apps/floorplanner -D $tmp/an -P $AN -l 3 > $tmp/an.log 2>&1 & pids+=($!)
upto $tmp/sp.log "verified ok" 90 $! || { echo "FAIL: the listing was not verified ($tmp/sp.log, $tmp/an.log)"; exit 1; }
read -r _ _ id _ _ ccode < <(grep -v "^#" $tmp/an/apps/floorplanner/starport_claim.txt)
# Done when the third request is answered
printf 'wait_log 30000 "id":3,"ok"\nquit\n' > $tmp/cmds.txt
BUILDAT_SP_CREATE=1 BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}
{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D $tmp/cl -w 800x600 -l 3 -s 127.0.0.1:$SP -c @$tmp/cmds.txt > $tmp/cl.log 2>&1 ||
	{ echo "FAIL: the admin's requests ($tmp/cl.log)"; exit 1; }
curl -s 127.0.0.1:$SP/api/v1/list | python3 -c "import json,sys; print('listed:', [(s['host'],s['port'],s.get('tls')) for s in json.load(sys.stdin)['servers']])"
# The player's client: this Starport only, accepted
now=$(date +%s)
echo "{\"starports\": [\"http://127.0.0.1:$SP\"]}" > $tmp/fc/starport.json
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","","%s","%s","","",""\n' $SP $now $now > $tmp/fc/network_addresses.csv
fpcode=$(grep -ao "setup code [A-Z0-9]*" $tmp/an.log | tail -1 | awk '{print $3}')
# The delays: the picker and its menu laid out in the frames after their
# lines, and the report's window drawn
cat > $tmp/fcmds.txt <<C
wait_log_any 30000 Plan picker:
delay 500
keypress up
keypress return
wait_log 10000 The plan picker's menu shown
delay 500
keypress down
keypress down
keypress down
keypress return
wait_log 20000 report here: connected to
delay 1500
screenshot $tmp/report.png
quit
C
BUILDAT_FP_CREATE=1 BUILDAT_FP_NAME=op BUILDAT_FP_PASSWORD=pw123456 BUILDAT_FP_CODE=$fpcode \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D $tmp/fc -w 800x500 -l 3 -s "$2" -c @$tmp/fcmds.txt > $tmp/fc.log 2>&1
grep -a "report here" $tmp/fc.log | sed 's/.*extensio: //'
# One run's lines, which the runner above reads for its verdict
exit 0
