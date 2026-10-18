#!/bin/bash
# tier: full
# cost: ~180s (2026-10-04)
# covers: builtin/accounts/accounts.cpp on_login's non-local wiring and is_local
# [SECURITY_RUN_2]: the login rate limit end-to-end over a real network, the
# residual that accounts.cpp's rate_limit_self_check() leaves (the self-check
# drives note_failure/failure_wait with its own clock; this drives on_login
# itself through a client). A server the launcher did not start is public
# ([VANILLA_PUBLIC]) and loopback is non-local on it, so is_local is false and
# the password is checked.
#   1. a wrong password is refused as "Wrong password" (the fail() path) and
#      the server counts it (note_failure);
#   2. the accumulated failures lock the address's /24 ("Too many failed
#      logins"), the login rate limit working end-to-end.
#   3. on the launcher's server (floorplanner) started with an owner token, a
#      loopback client without the token is not local: a new account needs
#      the setup code ("no admin yet"), and nobody is made the owner;
#   4. the other counted fail() paths of a new account: a wrong setup code,
#      and an invite code that does not exist;
#   5. the same server without a token takes the loopback client as local
#      (no password, no code): the contrast that gives 3 its teeth;
#   6. a kept login logs in by its token, said so ("by kept login", the
#      client's and the server's), and an admin's password reset ends it
#      ("The saved login has ended"); [ACCOUNT_WHO] Log out ends it too:
#      its token, sent again by a copy of the client's storage, is
#      refused;
#   7. with TOTP on (the secret put in the store), a wrong code is refused
#      and counted, and the right one joins.
# That a correct password is refused while the wait is non-zero (on_login
# checks the wait before the password) is covered by accounts.cpp's
# rate_limit_self_check(); it is not driven here because catching a client
# inside a short wait window across process starts is not deterministic.
#
#   util/login_gating_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
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

# start <dir> <port> [server args...]: a server, its log in $t/<dir>.log;
# sets $srv and $code
start(){
	local d=$1 p=$2; shift 2
	start_server "$t/$d.log" "STATUS Listening" 60 "$p" \
		bin/buildat_server -m "../apps/$app" -D "$t/$d" -l 3 "$@" ||
		fail "server did not listen"
	srv=$SERVER_PID
	code=$(nolog "$t/$d.log" | grep -oP 'setup code \K[A-Z0-9]+' | head -1)
}

app=vanilla jp=BUILDAT_JOIN
port=29591
# No launcher param: a public server where loopback is non-local.
start srv "$port"
srv_log=$t/srv.log
[ -n "$code" ] || fail "no setup code in the server log"

# join <userdir> <NAME> <PASSWORD> <CREATE> <CODE> [<line>]: one scripted
# client, until the server's answer (a line with "Joined as" by default,
# "Login refused" for a refusal). Its status is not checked: the caller
# reads the log and says what it lacks.
join(){
	printf 'wait_log_any 15000 %s\nquit\n' "${6:-Joined as}" > "$t/seq"
	env "${jp}_NAME=$2" "${jp}_PASSWORD=$3" "${jp}_CREATE=$4" "${jp}_CODE=$5" \
		timeout 30 bin/buildat -o launch_ui=launch_menu -s "127.0.0.1:$port" -D "$t/$1" \
		-w 640x480 -u 1 -l 3 -o sound_mute=1 -c @"$t/seq" \
		> "$t/$1.log" 2>&1
	nolog "$t/$1.log"
}

# The account to attack
c=$(join mk alice rightpass123 1 "$code")
echo "$c" | grep -qF "Joined as alice" ||
	fail "could not create the account to drive
$(echo "$c" | grep -iE 'login|join|refused' | tail -5)"

# 1. a wrong password is refused as such, and the server counts it
c1=$(join w1 alice wrongpass000 0 "" "Login refused")
echo "$c1" | grep -qF 'Login refused: Wrong password' ||
	fail "a wrong password was not refused as Wrong password
$(echo "$c1" | grep -iE 'login|refused' | tail -5)"
nolog "$srv_log" | grep -q "failed: Wrong password" ||
	fail "the server did not log the wrong password as a counted failure"

# 2. the accumulated failures lock the address's /24
locked=0
for i in $(seq 2 11); do
	ci=$(join "w$i" alice wrongpass000 0 "" "Login refused")
	if echo "$ci" | grep -qF 'Login refused: Too many failed logins'; then
		locked=1
		break
	fi
done
[ "$locked" = 1 ] ||
	fail "repeated wrong logins did not lock the address (no 'Too many failed logins')
$(nolog "$srv_log" | grep -iE 'failed|refused' | tail -8)"

kill $srv; wait $srv 2>/dev/null

# 3. The owner token gates is_local: on the launcher's server started with
# one, a loopback client that did not send it is a stranger (it gets the
# setup-code path), and without a token the same client is the local user.
# A scripted client cannot send the right token (only a client that started
# the server has it), so the owner's side is the launcher's, not this check's.
# Floorplanner, as vanilla on the launcher's server has no login to gate.
app=floorplanner jp=BUILDAT_FP
BUILDAT_OWNER_TOKEN=check-owner-token start tok $((port+1)) -u launcher=1
srv_log=$t/tok.log
port=$((port+1))
[ -n "$code" ] || fail "the token server has no setup code"
c=$(join t1 bob rightpass123 1 "" "Login refused")
echo "$c" | grep -qF 'Login refused: This server has no admin yet' ||
	fail "a loopback client without the owner token was taken as local
$(echo "$c" | grep -iE 'login|joined|refused' | tail -5)"
nolog "$srv_log" | grep -q "is this server's owner" &&
	fail "a peer without the token was made the owner"
sleep 2 # each counted failure makes the address wait (1, 2, 4 s)

# 4. The other counted fail() paths of a new account: a wrong setup code,
# and once the server has an admin, an invite code that does not exist
c=$(join t2 bob rightpass123 1 WRONGCODE "Login refused")
echo "$c" | grep -qF 'Login refused: Wrong setup code' ||
	fail "a wrong setup code was not refused
$(echo "$c" | grep -iE 'login|joined|refused' | tail -5)"
sleep 3 # the second counted failure's wait
c=$(join t3 bob rightpass123 1 "$code")
echo "$c" | grep -qF "Joined as bob" ||
	fail "the setup code did not make the admin
$(echo "$c" | grep -iE 'login|joined|refused' | tail -5)"
c=$(join t4 carol rightpass123 1 NOSUCHINVITE "Login refused")
echo "$c" | grep -qF 'Login refused: No such invite code' ||
	fail "a made-up invite code was not refused
$(echo "$c" | grep -iE 'login|joined|refused' | tail -5)"
n=$(nolog "$srv_log" | grep -cE 'failed: (This server has no admin|Wrong setup code|No such invite code)')
[ "$n" = 3 ] || fail "the server counted $n of the 3 failures"
kill $srv; wait $srv 2>/dev/null

# 5. The same launcher server without a token: loopback is local, and joins
# with no password or setup code
start loc $((port+1)) -u launcher=1
srv_log=$t/loc.log
port=$((port+1))
c=$(join l1 dave "" 0 "")
echo "$c" | grep -qF "Joined as dave" ||
	fail "without a token a loopback client was not local
$(echo "$c" | grep -iE 'login|joined|refused' | tail -5)"
kill $srv; wait $srv 2>/dev/null

# 6. A kept login ([ACC_KEEP]) ends with the password: the client that kept
# it is told so, and the token is gone
app=vanilla jp=BUILDAT_JOIN
port=29597
start keep $port
srv_log=$t/keep.log
c=$(BUILDAT_JOIN_KEEP=1 join k1 erin rightpass123 1 "$code")
echo "$c" | grep -qF "Joined as erin" || fail "the kept login's account
$(echo "$c" | grep -iE 'login|joined|refused' | tail -5)"
# rejoin <userdir>: the stored token only, as a client with no name set
rejoin(){
	printf 'wait_log_any 15000 %s\nquit\n' "${2:-Joined as}" > "$t/seq"
	timeout 30 bin/buildat -o launch_ui=launch_menu -s "127.0.0.1:$port" -D "$t/$1" -w 640x480 -u 1 \
		-l 3 -o sound_mute=1 -c @"$t/seq" > "$t/$1.re.log" 2>&1
	nolog "$t/$1.re.log"
}
cp -r "$t/k1" "$t/k1out"; cp -r "$t/k1" "$t/k1old"
c=$(rejoin k1)
echo "$c" | grep -qF "Joined as erin" || fail "the kept login did not log in
$(echo "$c" | grep -iE 'login|joined|refused' | tail -5)"
echo "$c" | grep -qF "accounts: logged in as erin by kept login" &&
	nolog "$srv_log" | grep -q "erin joined from .* by kept login" ||
	fail "the kept login's way not said
$(echo "$c" | grep -iE 'logged in|joined' | tail -3)"
# erin is the admin: the Server window opens at the ntfy question; its
# Account page has Log out
printf '%s\n' "wait_log_any 15000 Joined as" \
	"wait_log_any 10000 server window: the page ntfy" "delay 500" \
	'click Button "Account"' "wait_log 5000 server window: the page account" \
	"delay 500" 'click Button "Log out"' "wait_log_any 5000 accounts: logged out" \
	quit > "$t/seq"
timeout 30 bin/buildat -o launch_ui=launch_menu -s "127.0.0.1:$port" -D "$t/k1out" \
	-w 640x480 -u 1 -l 3 -o sound_mute=1 -c @"$t/seq" > "$t/k1out.log" 2>&1
# Log out leaves the game, so the client's status is not the drive's
grep -aq "accounts: logged out" "$t/k1out.log" || fail "Log out not answered
$(grep -aiE 'logged|log out|server window' "$t/k1out.log" | tail -5)"
nolog "$srv_log" | grep -q "erin logged out" || fail "the server did not end the token"
c=$(rejoin k1old "Login refused")
echo "$c" | grep -qF 'Login refused: The saved login has ended: log in again' ||
	fail "a kept login outlived Log out
$(echo "$c" | grep -iE 'login|joined|refused' | tail -5)"
c=$(BUILDAT_JOIN_ADMIN="password erin otherpass123" join k2 erin rightpass123 0 "" \
	"admin script: done")
nolog "$srv_log" | grep -q "reset the password of erin" || fail "the reset
$(echo "$c" | grep -iE 'login|joined|refused|admin' | tail -5)"
c=$(rejoin k1 "Login refused")
echo "$c" | grep -qF 'Login refused: The saved login has ended: log in again' ||
	fail "a kept login outlived the password
$(echo "$c" | grep -iE 'login|joined|refused' | tail -5)"
kill $srv; wait $srv 2>/dev/null

# 7. TOTP: a wrong code is refused and counted, the right one joins. The
# secret goes into the store directly (turning it on is the UI's).
db=$(find "$t/keep" -path '*_server*' -name save.sqlite | head -1)
[ -n "$db" ] || fail "no _server save.sqlite under $t/keep"
python3 - "$db" <<'PY' || fail "the TOTP secret"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO store(store, key, value) VALUES('accounts', 'totp/erin', ?)",
        (b"12345678901234567890",))
c.commit()
PY
totp(){ # the code of the RFC 6238 test secret now, or one that is not
	python3 - "$1" <<'PY'
import hmac, hashlib, struct, sys, time
h = hmac.new(b"12345678901234567890", struct.pack(">Q", int(time.time()) // 30),
        hashlib.sha1).digest()
o = h[19] & 15
v = (struct.unpack(">I", h[o:o + 4])[0] & 0x7fffffff) % 1000000
print("%06d" % ((v + int(sys.argv[1])) % 1000000))
PY
}
port=$((port+1))
start keep $port # the same save, the secret in it
srv_log=$t/keep.log
c=$(BUILDAT_JOIN_TOTP=$(totp 500000) join o1 erin otherpass123 0 "" "Login refused")
echo "$c" | grep -qF 'Login refused: TOTP: wrong code' ||
	fail "a wrong TOTP code was not refused
$(echo "$c" | grep -iE 'login|joined|refused' | tail -5)"
nolog "$srv_log" | grep -q "failed: TOTP: wrong code" ||
	fail "the server did not count the wrong TOTP code"
sleep 2 # the counted failure's wait
c=$(BUILDAT_JOIN_TOTP=$(totp 0) join o2 erin otherpass123 0 "")
echo "$c" | grep -qF "Joined as erin" || fail "the right TOTP code did not join
$(echo "$c" | grep -iE 'login|joined|refused' | tail -5)"

echo "PASS: wrong passwords counted and locked; the owner token gates is_local; wrong setup and invite codes refused and counted; a kept login said so and ended by the password and by Log out; a wrong TOTP code refused and counted"
