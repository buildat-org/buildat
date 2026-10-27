#!/bin/bash
# tier: full
# cost: ~30 s (2026-10-27)
# covers: util/web_server.cmake src/server/web/** builtin/network/network_web.cpp
# [WEB_LOCAL_SERVER] step 1: hillclimb's server built for the web
# (util/build_web_server.sh) run headless under node: every module in the
# loader's order is loaded from the linked-in table, the car's drive
# (BUILDAT_HILLCLIMB_DRIVE, no client) climbs off the pad, and the server
# ends itself. --free-run, so the ticks' rate is the wasm's own.
# Needs Build-webserver/ from util/build_web_server.sh, and node.
#   util/web_server_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
js="$here/Build-webserver/bin/buildat_server.js"
[ -f "$js" ] || skip "no $js: run util/build_web_server.sh"
command -v node > /dev/null || skip "no node"
check_tmp web_server; t=$CHECK_TMP

# The paths are in the wasm's own file system (/buildat is packed in it);
# the .data is found beside the .js from the working directory
start=$(date +%s.%N)
(cd "$(dirname "$js")" && BUILDAT_HILLCLIMB_DRIVE="0:S 2:W2 32:Q" timeout 90 \
	node "$js" --unconfined --free-run -l 3 -m /buildat/apps/hillclimb \
	-S /buildat -U /urho -D /user -C /cache > "$t/server.log" 2>&1)
rc=$?
end=$(date +%s.%N)
grep -E 'Module load order|Loading module|network: the web' "$t/server.log" | cut -c 20-
grep -E 'car t=' "$t/server.log" | cut -c 20-90
[ $rc = 0 ] || fail "the server exited with $rc ($t/server.log: $(tail -3 "$t/server.log"))"
grep -q 'the drive is over' "$t/server.log" || fail "no end of the drive"
order=$(sed -n 's/.*Module load order: \[\(.*\)\]/\1/p' "$t/server.log" | tr -d ',')
[ -n "$order" ] || fail "no load order"
for m in loader $order; do
	grep -q "Loading module $m from" "$t/server.log" || fail "$m was not loaded"
done
grep -q 'Failed to construct\|not in this build' "$t/server.log" && fail "$(grep -m1 'Failed to construct\|not in this build' "$t/server.log")"
# The car off its pad: x from 16.9 m to past 25 m in 30 s of second gear
last=$(grep -E 'car t=' "$t/server.log" | tail -1 | sed 's/.*car t=\([0-9.]*\) pos=\([0-9.-]*\),.*/\1 \2/')
read -r secs x <<< "$last"
awk -v x="${x:-0}" 'BEGIN{exit !(x > 25)}' || fail "the car did not climb: $last"
ticks=$(awk -v s="$secs" 'BEGIN{printf "%d", s * 30}')
echo "$ticks ticks (to t=$secs s) in $(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.1f", b - a}') s of wall time, with the start"
echo "PASS: hillclimb's web server: $(echo loader $order | wc -w) modules, $ticks ticks, the car at x=$x"
