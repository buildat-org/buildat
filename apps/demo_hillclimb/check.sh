#!/bin/bash
# tier: full
# cost: ~15 s (2026-10-16)
# covers: apps/demo_hillclimb/** extensions/physical_sky/init.lua
# demo_hillclimb ([HILLCLIMB], doc/plan/hillclimb_plan.md's Check), no
# pixels. Stage 1: the generator's own self test (main/hill.h: the same
# seed the same hill, the slope's angle, the pads flat and long enough,
# the track 8 m, sand with stones), the client Lua parsing, and the
# server starting with the module compiled and the hill made. Later
# stages add the car, the time trial and the ground.
#   apps/demo_hillclimb/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp hillclimb; t=$CHECK_TMP
app="$here/apps/demo_hillclimb"

g++ -std=c++11 -O1 -DHILL_TEST -x c++ "$app/main/hill.h" -o "$t/hill_test" \
	2> "$t/hill_build.log" || fail "hill.h self test did not build: $(head -3 "$t/hill_build.log")"
"$t/hill_test" || fail "hill.h self test"

for f in "$app"/main/client_lua/*.lua "$app"/launcher/*.lua; do
	luajit -b "$f" /dev/null || fail "$f does not parse"
done

cd "$here/Build"
start_server "$t/s.log" "STATUS Listening" 120 auto \
	bin/buildat_server -m "$app" -D "$t/u" -C "$t/c" -l 3
rc=$?
[ "$rc" = 2 ] && skip "no free port"
CHECK_PIDS+=($SERVER_PID)
[ "$rc" = 0 ] || fail "the server did not come up ($t/s.log)"
grep -a "hillclimb: the hill" "$t/s.log" | sed 's/.*hillclimb: /  /'
grep -aq "hillclimb: the hill, seed 1, 22 degrees, 50 m long" "$t/s.log" ||
	fail "no hill made ($t/s.log)"
echo "PASS: the hill's generator and the server's module"
# vim: set noet ts=4 sw=4:
