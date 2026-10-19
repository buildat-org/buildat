#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-19)
# covers: client/api.lua client/core/network/init.lua
# [USER_FILES_ATOMIC]: the client's user files written whole or not at all,
# and the network consent store not rewritten on every request. A client
# with no server, its store one accepted row, made 20 touches of it at the
# start (BUILDAT_TEST_CONSENT_TOUCH, as 20 icon fetches):
#   1. the row's last attempt now: the store not written, the file as it
#      was;
#   2. two days old: written once, the last attempt now;
#   3. two days old again, the write stopped after its .tmp
#      (BUILDAT_TEST_ATOMIC_STOP, as a crash there): the file as it was,
#      whole, the new text in the .tmp.
#   util/user_files_atomic_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp user_files_atomic; t=$CHECK_TMP
trap check_cleanup EXIT
u=$t/u
csv=$u/network_addresses.csv
uri=https://example.invalid
mkdir -p "$u"
# row <last attempt>
row() {
	printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","%s","","%s","%s","","",""\n' \
		"$uri" "$1" "$1" > "$csv"
}
# run <n> [env...]: the client, its log $t/c<n>.log
run() {
	local n=$1; shift
	# The touches are at the network module's load, before a sequence runs
	printf '%s\n' "delay 500" quit > "$t/seq"
	run_client 40 "$t/c$n.log" env BUILDAT_TEST_CONSENT_TOUCH="$uri 20" "$@" \
		timeout 40 "$here/Build/bin/buildat" -D "$u" -C "$t/c" -w 640x480 -l 3 \
		-o sound_mute=1 -c @"$t/seq" || fail "the client $n ($t/c$n.log)"
	grep -aq "network: 20 touches of $uri done" "$t/c$n.log" ||
		fail "the client $n made no touches ($t/c$n.log)"
}
writes() { grep -ac "network: the consent store written" "$t/c$1.log"; }
attempt() { grep -a "$uri" "$csv" | awk -F'","' '{ print $5 }'; }

now=$(date +%s)
row $now
before=$(md5sum < "$csv")
run 1
[ "$(writes 1)" = 0 ] && [ "$(md5sum < "$csv")" = "$before" ] ||
	fail "a fresh row rewritten: $(writes 1) writes ($t/c1.log)"

old=$((now - 2 * 86400))
row $old
run 2
a=$(attempt)
[ "$(writes 2)" = 1 ] && [ "$a" -ge "$now" ] ||
	fail "a day-old row: $(writes 2) writes, last attempt $a ($t/c2.log)"

row $old
before=$(md5sum < "$csv")
run 3 BUILDAT_TEST_ATOMIC_STOP=network_addresses.csv
grep -aq "write_file_atomic: stopped after .*network_addresses.csv.tmp" "$t/c3.log" &&
	[ "$(md5sum < "$csv")" = "$before" ] && grep -q "$uri" "$csv.tmp" ||
	fail "the stopped write left the file changed, or no .tmp ($t/c3.log)"
echo "PASS: 20 touches of a fresh row write nothing, of a day-old one once; a write stopped after its .tmp leaves the file whole"
