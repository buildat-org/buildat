#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: ~2 s (2026-11-05)
# covers: util/check_lib.sh
# [CHECK_STOP_STATUS] check_lib fails a passing check whose server's log shows
# a crash, with a fake server, in a temp directory or not; never a failing or
# skipping check's status, nor a clean server, nor CHECK_CRASH_OK; a subshell's
# start_server leaves the parent's temp directory alone.
here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/util/check_lib.sh"
check_tmp crash_status; t=$CHECK_TMP

run() # <wanted status> <script body after the check's sourcing>
{
	local got
	bash -c ". '$here/util/check_lib.sh'; cd '$t'
		ok() { start_server \"\$PWD/o.log\" Listening 5 auto sh -c 'echo Listening'; wait; }
		bad() { start_server \"\$PWD/b.log\" Listening 5 auto sh -c 'echo Listening; echo \"Crash: SIGSEGV: Address 0x0\"; echo frame1'; wait; }
		asan() { start_server \"\$PWD/a.log\" Listening 5 auto sh -c 'echo Listening; echo \"==1==ERROR: AddressSanitizer: heap-use-after-free\"'; wait; }
		$2" > "$t/out.log" 2>&1
	got=$?
	[ "$got" = "$1" ] || { cat "$t/out.log"; fail "wanted status $1, got $got: $2"; }
}
run 0 'ok; exit 0'
run 1 'bad; exit 0'
grep -q 'FAIL: a server crashed' "$t/out.log" || fail "no FAIL line"
grep -q 'frame1' "$t/out.log" || fail "no backtrace"
run 1 'asan; exit 0'
run 1 'check_tmp cs2; bad; echo "$CHECK_TMP" > tmpdir; exit 0'
[ ! -e "$(cat "$t/tmpdir")" ] || fail "the failed check's temp directory stayed"
run 0 'CHECK_CRASH_OK=1; bad; exit 0'
run 3 'bad; exit 3'
run $SKIP "bad; exit $SKIP"
# A subshell's server: its own exit cleans nothing of the parent's
run 0 'check_tmp cs3; d=$CHECK_TMP; ( ok ); [ -d "$d" ] || exit 9; exit 0'
echo "PASS: check_lib fails a passing check whose server crashed"
# vim: set noet ts=4 sw=4:
