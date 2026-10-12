#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-13)
# covers: builtin/accounts/accounts.cpp
# [SEC_ACCOUNT_UNREADABLE]: an auth/ record that does not decode is not a
# free name. Floor planner, a public server: the admin "boss" made with the
# setup code, then its record overwritten with a byte that does not
# unpack. Restarted:
#   1. no setup code (the unreadable record may be an admin's); a login
#      and a create as boss both refused, the bytes unchanged after.
#      The log says how to get back in.
#   2. Restarted as the launcher's: a local login makes an account that
#      is not admin.
# [COMPAT_CHECKS], cross-version (records as storage's pack() writes them,
# made here):
#   0. Another server's store as 0.6 wrote it (no "format", records with
#      no header, the save not stamped): migrated once (format 2), the
#      save stamped (user_version 1, its version row); its account logs
#      in with its password.
#   3. An account record of minor 1 with a field added at its end logs
#      in; one of major 2 is refused as unreadable, its bytes unchanged.
#   util/account_unreadable_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp account_unreadable; t=$CHECK_TMP
cd "$here/Build"

# srv <n> [args...]: the server on $t/$SRV, its log $t/srv<n>.log
SRV=srv
srv(){
	local n=$1; shift
	start_server "$t/srv$n.log" "STATUS Listening" 120 auto \
		bin/buildat_server -m ../apps/floorplanner -D "$t/$SRV" -l 3 "$@" ||
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
	f=$(find "$t/$SRV" -path '*_server*' -name save.sqlite | head -1)
	[ -n "$f" ] || fail "no _server save.sqlite under $t/$SRV"
	python3 -c "import hashlib, sqlite3, struct, sys
c = sqlite3.connect(sys.argv[1])
$REC
$1
c.commit()" "$f"
}
# Records as storage::pack() writes them: cereal's endianness byte, then
# the fields; a record is its major and minor, then its body (a pack of
# its fields) as a string. A password as accounts derives it.
REC='def s(b): return struct.pack("<Q", len(b)) + b
def acc(pw, privs, salt=b"0123456789abcdef"):
    h = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, 10000)
    return s(salt) + s(h) + struct.pack("<Q", len(privs)) + b"".join(s(p.encode()) for p in privs)
def rec(major, minor, body): return b"\x01" + bytes([major, minor]) + s(b"\x01" + body)
def acc10(pw, privs=()): return s(b"pbkdf2-sha256") + struct.pack("<I", 10000) + acc(pw, list(privs))
def put(key, v): c.execute("INSERT OR REPLACE INTO store VALUES(\"accounts\", ?, ?)", (key, v))
def get(key): return bytes(c.execute("SELECT value FROM store WHERE store = \"accounts\" AND key = ?", (key,)).fetchone()[0])'

# 0.
SRV=srv06
srv 0
stop
db "c.execute(\"DELETE FROM store WHERE store = 'accounts'\")
c.execute(\"DELETE FROM store WHERE store = '__save'\")
c.execute('PRAGMA user_version = 0')
put('auth/old', b'\x01' + acc('oldpass123', []))"
srv 06
grep -aq "The accounts are records now (format 2)" "$t/srv06.log" ||
	fail "0.6's store not migrated ($t/srv06.log)"
join o06 old oldpass123 0 "" | grep -aF "Joined as" | tail -1
grep -aqF "Joined as old" "$t/o06.log" || fail "0.6's account did not log in ($t/o06.log)"
stop
db "assert get('format') == b'2', get('format')
assert get('auth/old')[1:3] == b'\x01\x00', get('auth/old')
assert c.execute('PRAGMA user_version').fetchone()[0] == 1
assert c.execute(\"SELECT value FROM store WHERE store = '__save' AND key = 'version'\").fetchone()" ||
	fail "0.6's store not migrated and stamped"
srv 07
grep -aq "records now" "$t/srv07.log" && fail "migrated twice ($t/srv07.log)"
stop
echo "ok: 0.6's accounts migrated once and stamped; its account logs in"
SRV=srv

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
grep -aq "No admin account can be read, and boss, .*delete that row .*_server.*/save.sqlite" \
	"$t/srv2.log" || fail "how to get back in not said ($t/srv2.log)"
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

# 3.
db "put('auth/tail', rec(1, 1, acc10('tailpass123') + s(b'a newer field')))
put('auth/next', rec(2, 0, acc10('nextpass123')))"
next=$(db "print(get('auth/next').hex())")
srv 4
join tl tail tailpass123 0 "" | grep -aF "Joined as" | tail -1
grep -aqF "Joined as tail" "$t/tl.log" || fail "a newer minor's record did not log in ($t/tl.log)"
join nx next nextpass123 0 "" | grep -aF "Login refused" | tail -1
grep -aqF 'Login refused: The account "next" could not be read' "$t/nx.log" ||
	fail "a newer major's record not refused as unreadable ($t/nx.log)"
stop
[ "$(db "print(get('auth/next').hex())")" = "$next" ] || fail "auth/next written over"
echo "PASS: an unreadable account record is refused and kept; with it the only admin, no setup code, how to get back in said, and a local login is not admin; 0.6's store migrated and stamped; a newer minor's record read, a newer major's refused and kept"
