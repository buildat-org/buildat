#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-12)
# covers: builtin/accounts/accounts.cpp
# [SEC_ACCOUNT_UNREADABLE]: an auth/ record that does not decode is not a
# free name. Floor planner, a public server: the admin "boss" made with the
# setup code, then its record overwritten with a byte that does not
# unpack. Restarted:
#   1. no setup code (the unreadable record may be an admin's); a login
#      and a create as boss both refused, the bytes unchanged after.
#   2. Restarted as the launcher's: a local login makes an account that
#      is not admin.
#   util/account_unreadable_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp account_unreadable; t=$CHECK_TMP
cd "$here/Build"

# srv <n> [args...]: the server on $t/srv, its log $t/srv<n>.log
srv(){
	local n=$1; shift
	start_server "$t/srv$n.log" "STATUS Listening" 120 auto \
		bin/buildat_server -m ../apps/floorplanner -D "$t/srv" -l 3 "$@" ||
		fail "the server ($t/srv$n.log)"
	CHECK_PIDS+=($SERVER_PID)
}
stop(){ kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null; }
# join <dir> <NAME> <PASSWORD> <CREATE> <CODE>
join(){
	printf 'delay 1500\nquit\n' > "$t/seq"
	BUILDAT_FP_NAME="$2" BUILDAT_FP_PASSWORD="$3" \
		BUILDAT_FP_CREATE="$4" BUILDAT_FP_CODE="$5" \
		timeout 60 bin/buildat -o launch_ui=launch_menu -s "127.0.0.1:$SERVER_PORT" \
		-D "$t/$1" -w 640x480 -u 1 -l 3 -o sound_mute=1 -c @"$t/seq" \
		> "$t/$1.log" 2>&1
	cat "$t/$1.log"
}
# db <python>: the accounts store as c
db(){
	local f
	f=$(find "$t/srv" -path '*_server*' -name save.sqlite | head -1)
	[ -n "$f" ] || fail "no _server save.sqlite under $t/srv"
	python3 -c "import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
$1
c.commit()" "$f"
}

srv 1
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
join mk boss rightpass123 1 "$code" | grep -qF "Joined as boss" ||
	fail "boss not made ($t/mk.log)"
stop
db "c.execute(\"UPDATE store SET value = x'01' WHERE store = 'accounts' AND key = 'auth/boss'\")
assert c.total_changes == 1"

# 1.
srv 2
grep -aq "setup code" "$t/srv2.log" && fail "a setup code with an unreadable admin ($t/srv2.log)"
for c in 0 1; do
	join "b$c" boss rightpass123 $c "" | grep -aF "Login refused" | tail -1
	grep -aqF 'Login refused: The account "boss" could not be read' "$t/b$c.log" ||
		fail "boss, create=$c, not refused as unreadable ($t/b$c.log)"
done
grep -aq "auth/boss does not decode" "$t/srv2.log" || fail "not logged ($t/srv2.log)"
stop
[ "$(db "print(c.execute(\"SELECT hex(value) FROM store WHERE store = 'accounts' AND key = 'auth/boss'\").fetchone()[0])")" = 01 ] ||
	fail "auth/boss written over"

# 2.
srv 3 -u launcher=1 -A 127.0.0.1
join l newbie "" 0 "" | grep -aF "Joined as" | tail -1
grep -a "New account" "$t/srv3.log" | sed 's/.*accounts: //'
grep -aq "New account" "$t/srv3.log" || fail "no local account made ($t/srv3.log)"
stop
db "rows = c.execute(\"SELECT key, value FROM store WHERE store = 'accounts' AND key LIKE 'auth/%' AND key != 'auth/boss'\").fetchall()
assert rows, 'no local account'
for k, v in rows:
    print(k, 'admin' if b'admin' in v else 'not admin')
    assert b'admin' not in v" || fail "the local login made admin"
echo "PASS: an unreadable account record is refused and kept; with it the only admin, no setup code and a local login is not admin"
