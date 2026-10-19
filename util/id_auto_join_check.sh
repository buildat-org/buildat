#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-10)
# covers: client/core/starport/init.lua builtin/accounts/client_lua/accounts.lua
# [ID_AUTO_JOIN]: a local Starport and a Hearth listed on it, an admin
# made there first; a client with a Starport ID signed in.
#   1. The first join shows the dialog; Return signs in with the ID (the
#      community's name asked once), and the client marks the server.
#   2. The second join signs in with the ID by itself: no key pressed.
#   3. Log out drops the mark; the third join shows the dialog again (no
#      "Signing in with the Starport ID").
#   4. Signed in by the ID again, then a password login there drops the
#      mark too; the next join shows the dialog.
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   util/id_auto_join_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp id_auto_join; t=$CHECK_TMP
cd "$here"

# The Starport verifies the Hearth by connecting to it: its port known first
while HE=$((29700 + RANDOM % 300)); port_taken $HE; do :; done
export BUILDAT_CONNECT_PORTS="$HE"
start_server "$t/sp.log" "setup code" 120 auto \
	Build/bin/buildat_server -m apps/starport -D "$t/sp" -l 3 ||
	fail "the Starport did not start"
CHECK_PIDS+=($SERVER_PID)
SP=$SERVER_PORT
sppid=$SERVER_PID
mkdir -p "$t/he/apps/hearth"
cat > "$t/he/apps/hearth/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Check hearth", "ids": "anyone",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
export BUILDAT_CONNECT_PORTS="$SP,$HE"
start_server "$t/he.log" "setup code" 120 $HE \
	Build/bin/buildat_server -m apps/hearth -D "$t/he" -l 3 ||
	fail "the Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
code=$(grep -ao "setup code [A-Z0-9]*" "$t/he.log" | cut -d' ' -f3)
for _ in $(seq 300); do
	grep -aq "verified ok" "$t/sp.log" && break
	kill -0 $sppid 2>/dev/null || break
	sleep 0.2
done
grep -aq "verified ok" "$t/sp.log" || fail "the Hearth was not listed"

join(){ # dir log commands [env...]
	local dir=$1 log=$2
	printf "$3" > "$t/cmds"
	shift 3
	env "$@" timeout 90 Build/bin/buildat -D "$dir" -w 800x600 -l 3 \
		-o sound_mute=1 -s 127.0.0.1:$HE -c @"$t/cmds" > "$log" 2>&1
}
marked(){
	python3 -c 'import json, sys; print(sys.argv[2] in (json.load(open(sys.argv[1])).get("id_used") or {}))' \
		"$t/u/starport.json" "127.0.0.1:$HE"
}
by_itself(){ grep -aq "Signing in with the Starport ID" "$1"; }

# The Hearth's admin, by password, from a client of its own
join "$t/adm" "$t/adm.log" 'wait_log 30000 Joined as\ndelay 500\nquit\n' \
	BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
	BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code
grep -aq "Joined as admin" "$t/adm.log" ||
	fail "the admin: $(grep -a 'Login\|refused' "$t/adm.log" | head -2)"

# The user's client: an ID signed in, the Starport's address accepted
session=$(python3 - "$SP" <<'PY'
import json, sys, time, urllib.request
B = "http://127.0.0.1:%s/api/v1/" % sys.argv[1]
r = json.loads(urllib.request.urlopen(B + "id/register", json.dumps(dict(
    name="reader", password="secret1",
    birth_year=time.gmtime().tm_year - 40)).encode()).read())
assert r["ok"], r
print(r["result"]["session"])
PY
) || fail "the ID API"
mkdir -p "$t/u"
printf '{"starports": ["http://127.0.0.1:%s"],\n "ids": {"http://127.0.0.1:%s": {"session": "%s", "name": "reader"}}}\n' \
	$SP $SP "$session" > "$t/u/starport.json"
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","Starport","%s","%s","","",""\n' \
	$SP $(date +%s) $(date +%s) > "$t/u/network_addresses.csv"

# 1. The dialog, Return, the name asked once. The 2 s after a join
# are the screenshot's settle
join "$t/u" "$t/j1.log" "wait_log_any 30000 accounts: the login page shown\ndelay 500\nscreenshot $t/j1.png\nkeypress Return\nwait_log 20000 ID name prompt:\ndelay 500\nscreenshot $t/name.png\nclick Button \"Use it\"\nwait_log 20000 Joined as\ndelay 500\nquit\n" ||
	fail "the drive ($t/j1.log)"
by_itself "$t/j1.log" && fail "the first join signed in by itself"
grep -aq "Joined as reader" "$t/j1.log" ||
	fail "the first join: $(grep -a 'Joined\|refused' "$t/j1.log" | head -2)"
[ "$(marked)" = True ] || fail "the server not marked: $(cat "$t/u/starport.json")"
echo "ok: the first join by the dialog's ID button, the server marked"

# 2. By itself
join "$t/u" "$t/j2.log" 'wait_log 30000 Joined as\ndelay 2000\nscreenshot '"$t"'/j2.png\nquit\n'
by_itself "$t/j2.log" && grep -aq "Joined as reader" "$t/j2.log" ||
	fail "the second join did not sign in by itself: $(grep -a 'Joined\|refused\|Signing' "$t/j2.log" | head -2)"
echo "ok: the second join signed in with the ID by itself"

# 3. Log out from the Server window; the next join asks. Log out leaves
# the server, so that drive's own end is not asked for
join "$t/u" "$t/j3.log" 'wait_log 30000 Joined as\ndelay 2000\nclick Button "Server"\nwait_log 5000 server window: the page\ndelay 500\nclick Button "Log out"\nwait_log_any 10000 the ID is not used on\ndelay 500\nquit\n'
[ "$(marked)" = False ] || fail "log out kept the mark: $(grep -a 'not used\|Log out' "$t/j3.log" | head -2)"
join "$t/u" "$t/j4.log" "wait_log_any 30000 accounts: the login page shown\ndelay 500\nscreenshot $t/j4.png\nkeypress Return\nwait_log 20000 Joined as\ndelay 500\nquit\n"
by_itself "$t/j4.log" && fail "after log out the join signed in by itself"
grep -aq "Joined as reader" "$t/j4.log" && [ "$(marked)" = True ] ||
	fail "the ID by the dialog again: $(grep -a 'Joined\|refused' "$t/j4.log" | head -2)"
echo "ok: log out dropped the mark; the next join asked"

# 4. A password login drops it too
join "$t/u" "$t/j5.log" 'wait_log 30000 Joined as\ndelay 1000\nquit\n' \
	BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12
grep -aq "Joined as admin" "$t/j5.log" || fail "the password login: $(grep -a 'Joined\|refused' "$t/j5.log" | head -2)"
[ "$(marked)" = False ] || fail "a password login kept the mark"
join "$t/u" "$t/j6.log" "wait_log_any 30000 accounts: the login page shown\ndelay 2000\nscreenshot $t/j6.png\nquit\n" ||
	fail "the drive ($t/j6.log)"
by_itself "$t/j6.log" && fail "after a password login the join signed in by itself"
grep -aq "Joined as" "$t/j6.log" && fail "the join after a password login joined: $(grep -a 'Joined' "$t/j6.log")"
echo "ok: a password login dropped the mark; the next join asked"
echo "PASS: every step above held"
