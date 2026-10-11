#!/bin/bash
# tier: full
# cost: ~90 s (2026-10-11)
# covers: builtin/accounts/accounts.cpp src/server/main.cpp
# [FIRST_ADMIN]: a server's first admin named in <user>/first_admin, on an
# Aitta (its set_settings is the admin's).
#   1. "name admin <password>": left by a --compile-only run
#      ([FIRST_ADMIN_KEPT]), removed at start, the log has no setup code;
#      that name and password log in and set a setting.
#   2. A first_admin on a server with an admin: removed, ignored, said so.
#   3. "code <code>": left by --compile-only; the log has no code; kept
#      over a restart before anyone joins; a new account with it is the
#      admin; the next start has no code and the store none.
#   4. A malformed one: an error naming the forms, the setup code logged.
#
#   util/first_admin_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp first_admin; t=$CHECK_TMP
trap check_cleanup EXIT
cd "$here/Build"

# serve <dir> <log>: an Aitta on <dir>, its PID in CHECK_PIDS
serve(){
	start_server "$2" "Listening at" 120 auto \
		bin/buildat_server -m ../apps/aitta -D "$1" -l 3 || fail "Aitta did not start ($2)"
	CHECK_PIDS+=($SERVER_PID)
	P=$SERVER_PORT
	# The accounts module's word comes after the network's
	for i in $(seq 100); do grep -aq "first_admin\|setup code" "$2" && break; sleep 0.1; done
}
stop(){ kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null; }
# compile_only <dir>: --compile-only on <dir>, first_admin left
compile_only(){
	timeout 300 bin/buildat_server -m ../apps/aitta -D "$1" -l 3 --compile-only \
		> "$1.compile.log" 2>&1 || fail "--compile-only ($1.compile.log)"
	[ -e "$1/first_admin" ] || fail "first_admin used up by --compile-only"
}
# settle <log> [env...]: a client's set_settings, answered ok
settle(){
	local log=$1; shift
	printf 'delay 8000\nquit\n' > "$t/c.cmds"
	env "$@" BUILDAT_AITTA_REQS='{"cmd":"set_settings","settings":{"page_delay":0}}' \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
		-s 127.0.0.1:$P -c @"$t/c.cmds" > "$log" 2>&1
	grep -aq 'ai: {"id":1,"ok":true' "$log"
}

# 1.
mkdir -p "$t/a"
echo "name admin checkpass1" > "$t/a/first_admin"
compile_only "$t/a"
serve "$t/a" "$t/a.log"
[ ! -e "$t/a/first_admin" ] || fail "first_admin not removed"
grep -aq "first_admin: admin is the admin" "$t/a.log" || fail "not applied ($t/a.log)"
grep -aq "setup code" "$t/a.log" && fail "a setup code logged"
settle "$t/a1.log" BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass1 ||
	fail "the named admin's setting ($t/a1.log)"
echo "ok: a named admin, the file removed, no setup code"

# 2.
stop
echo "name other checkpass2" > "$t/a/first_admin"
serve "$t/a" "$t/a3.log"
[ ! -e "$t/a/first_admin" ] && grep -aq "first_admin ignored: the server has an admin" "$t/a3.log" ||
	fail "a second first_admin ($t/a3.log)"
stop

# 3.
mkdir -p "$t/b"
echo "code Script0Code" > "$t/b/first_admin"
compile_only "$t/b"
serve "$t/b" "$t/b.log"
[ ! -e "$t/b/first_admin" ] || fail "first_admin not removed"
grep -aq "setup code from first_admin" "$t/b.log" && ! grep -aqi "script0code" "$t/b.log" ||
	fail "the code's log ($t/b.log)"
stop
# A restart before anyone joins: the code kept, not the log's
serve "$t/b" "$t/b2.log"
grep -aq "setup code from first_admin" "$t/b2.log" && ! grep -aq "setup code [A-Z0-9]" "$t/b2.log" ||
	fail "the code after a restart ($t/b2.log)"
settle "$t/b1.log" BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=boss \
	BUILDAT_AITTA_PASSWORD=checkpass3 BUILDAT_AITTA_CODE=script0code ||
	fail "the code's admin ($t/b1.log)"
stop
serve "$t/b" "$t/b3.log"
grep -aqi "setup code" "$t/b3.log" && fail "a setup code with an admin ($t/b3.log)"
stop
grep -raqi "script0code" "$t/b" && fail "the code left in the store"
echo "ok: the script's setup code, kept over --compile-only and a restart, gone with the admin; on a server with an admin, ignored"

# 4.
mkdir -p "$t/c"
echo "name x" > "$t/c/first_admin"
serve "$t/c" "$t/c.log"
grep -aq 'first_admin: expected "name' "$t/c.log" &&
	grep -aq "setup code [A-Z0-9]" "$t/c.log" || fail "a malformed one ($t/c.log)"
echo "ok: a malformed one said, the log's code instead"
echo "PASS"
