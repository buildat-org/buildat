#!/bin/bash
# tier: quick
# cost: ~20 s (2026-10-13)
# covers: client/api.lua extensions/serverlist/init.lua
# [COMPAT_CHECKS], [COMPAT_BREAK_07] 8i: a launch extension's storage at
# 0.6's user/<extension>/ moves to user/extensions/<extension>/ on its
# first use, its contents intact and said in the log; a second start
# moves nothing; with both there, the new one is used and kept, the old
# one left as it is, with a log line. The launcher's Home reads
# serverlist's cache (serverlist.csv) at start.
#   util/storage_move_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp storage_move; t=$CHECK_TMP
u=$t/u
old=$u/serverlist/serverlist.csv
new=$u/extensions/serverlist/serverlist.csv
run(){ # log
	# Home's rows are read from serverlist's cache: the move is before them
	printf 'wait_log_any 20000 rows in\nquit\n' > "$t/cmds"
	(cd "$here/Build" && timeout 40 bin/buildat -o launch_ui=launch_menu \
		-D "$u" -w 800x600 -l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/$1" 2>&1) ||
		fail "the client ($t/$1)"
}
mkdir -p "$u/serverlist"
printf '127.0.0.1:30000|Old one|0|devtest\n' > "$old"
run first.log
[ ! -e "$u/serverlist" ] || fail "0.6's user/serverlist/ is still there ($t/first.log)"
[ "$(cat "$new" 2>/dev/null)" = "127.0.0.1:30000|Old one|0|devtest" ] ||
	fail "the moved cache is not as it was: $(cat "$new" 2>&1)"
grep -aq "storage: moved 0.6's .*/serverlist to .*/extensions/serverlist" "$t/first.log" ||
	fail "the move was not said ($t/first.log)"
run second.log
grep -aq "storage: \(moved\|could not move\)\|is 0.6's and" "$t/second.log" &&
	fail "a second start did something ($t/second.log)"
mkdir -p "$u/serverlist"
printf '127.0.0.1:30001|Another|0|devtest\n' > "$old"
run both.log
[ "$(cat "$new")" = "127.0.0.1:30000|Old one|0|devtest" ] ||
	fail "with both there the new one changed: $(cat "$new")"
[ "$(cat "$old")" = "127.0.0.1:30001|Another|0|devtest" ] ||
	fail "with both there the old one was not left as it is"
grep -aq "storage: .*/serverlist is 0.6's and .*/extensions/serverlist is there too" "$t/both.log" ||
	fail "both there was not said ($t/both.log)"
echo "PASS: 0.6's launcher storage moved once with its contents and said; with both, the new one used and the old one left, said"
