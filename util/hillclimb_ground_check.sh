#!/bin/bash
# tier: quick
# cost: ~15 s (2026-10-29)
# covers: apps/hillclimb/main/main.cpp builtin/worldgen/worldgen.cpp builtin/voxelworld/voxelworld.cpp src/impl/mesh.cpp
# [HC_GROUND_SPEED]: native hillclimb's server makes its ground (every
# section of the default circuit generated: "the ground generated in N s")
# in under LIMIT seconds (10). A player waits for it; 124 s in the page
# and 30 s native on a 4-core check machine was too long (user,
# 2026-10-29). 2026-10-29, after: 3.1-3.5 s on a 16-thread desktop,
# 4.2-4.6 s on the 4 vCPU check machine (before: 12.7 s and 30.5 s);
# the in-page server in headless Firefox there 19-21 s (before 124.5 s;
# 62 s in some runs while the machine's other slot was busy).
#   util/hillclimb_ground_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
limit=${LIMIT:-10}
check_tmp hc_ground; t=$CHECK_TMP
start_server "$t/s.log" "STATUS Listening" 300 auto "$here/Build/bin/buildat_server" \
	-m "$here/apps/hillclimb" -D "$t/s" -l 3 ||
	fail "the server ($t/s.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/s.log" "the ground generated in" 120 ||
	fail "no ground in 120 s ($t/s.log)"
s=$(grep -aoP "the ground generated in \K[0-9.]+" "$t/s.log" | head -1)
awk -v s="$s" -v l="$limit" 'BEGIN{exit !(s < l)}' ||
	fail "the ground generated in $s s, not under $limit"
echo "PASS: the ground generated in $s s (under $limit)"
