#!/bin/bash
# tier: full
# cost: ~30s (2026-10-04)
# covers: builtin/accounts/accounts.cpp builtin/accounts/client_lua/accounts.lua
# [ACCOUNT_CREATE]: making an account is its own action, not a side effect of
# a mistyped name at login. This drives the server end of it over a real
# network:
#   1. a plain login (create=0) of a name that does not exist is refused as
#      unknown -- the server does not make the account;
#   2. a create login (create=1) of a new name makes the account and joins;
#   3. a plain login of that name and password then joins.
# A server the launcher did not start is public ([VANILLA_PUBLIC]) and asks
# everyone to log in; loopback is non-local on it. Its registration is closed,
# so the first (admin) account needs the setup code from the server's log.
#
# The two-password-match of the Create window is client-only Lua (pw ~= pw2)
# and is not driven here; the scripted login carries one password.
#
#   util/account_create_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here/Build"
[ -x bin/buildat_server ] || { echo "FAIL: no bin/buildat_server"; exit 1; }
[ -x bin/buildat ] || { echo "FAIL: no bin/buildat"; exit 1; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }

t=$(mktemp -d)
srv=
trap '[ -n "$srv" ] && kill $srv 2>/dev/null; rm -rf "$t"' EXIT
nolog(){ cat "$1"; }
fail(){ echo "FAIL: $*"; exit 1; }

port=29590
# No launcher param: a public server that asks everyone to log in.
# The first start compiles the builtin modules (rccpp); allow for it
start_server "$t/srv.log" "STATUS Listening" 90 "$port" \
	bin/buildat_server -m ../apps/vanilla -D "$t/srv" -l 3 ||
	fail "server did not listen"
srv=$SERVER_PID
code=$(nolog "$t/srv.log" | grep -oP 'setup code \K[A-Z0-9]+' | head -1)
[ -n "$code" ] || fail "no setup code in the server log"

# join <userdir> <NAME> <PASSWORD> <CREATE> <CODE> <UNTIL>: one scripted
# client that logs in through builtin/accounts' env hook, then quits once
# <UNTIL> is logged
join(){
	printf 'wait_log_any 20000 %s\nquit\n' "$6" > "$t/seq"
	BUILDAT_JOIN_NAME="$2" BUILDAT_JOIN_PASSWORD="$3" \
		BUILDAT_JOIN_CREATE="$4" BUILDAT_JOIN_CODE="$5" \
		timeout 40 bin/buildat -o launch_ui=launch_menu -s "127.0.0.1:$port" -D "$t/$1" \
		-w 640x480 -u 1 -l 3 -o sound_mute=1 -c @"$t/seq" \
		> "$t/$1.log" 2>&1
	nolog "$t/$1.log"
}

# 1. a mistyped/unknown name at a plain login is refused, account not made
c1=$(join u1 ghost secret123 0 "" "Login refused: ")
echo "$c1" | grep -qF 'Login refused: There is no account named "ghost"' ||
	fail "an unknown name was not refused as unknown
$(echo "$c1" | grep -iE 'login|account' | tail -5)"
nolog "$t/srv.log" | grep -q "New account ghost" &&
	fail "the server made an account for a plain login of an unknown name"

# 2. a create login of a new name makes the account and joins
c2=$(join u2 alice secret123 1 "$code" "Joined as alice")
echo "$c2" | grep -qF "Joined as alice" ||
	fail "the create login did not join
$(echo "$c2" | grep -iE 'login|join|account|refused' | tail -5)"
nolog "$t/srv.log" | grep -q "New account alice" ||
	fail "the server did not make the account on a create login"

# 3. a plain login of that name and password joins
c3=$(join u3 alice secret123 0 "" "Joined as alice")
echo "$c3" | grep -qF "Joined as alice" ||
	fail "the account made could not log in
$(echo "$c3" | grep -iE 'login|join|refused' | tail -5)"
[ "$(nolog "$t/srv.log" | grep -c "New account alice")" = 1 ] ||
	fail "the account was made more than once"

echo "PASS: a plain login refuses an unknown name; a create login makes the account and it logs in"
