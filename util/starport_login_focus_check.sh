#!/bin/bash
# tier: full
# cost: 60s (2026-10-08)
# covers: builtin/accounts/client_lua/accounts.lua
# [STARPORT_LOGIN_FOCUS]: a server's login dialog, on a server that takes
# Starport IDs. With the client signed in to the Starport, Return alone
# presses "Sign in with your Starport ID" (which asks the user whether
# the server may have the ID, past what is checked); signed out, Return signs nothing in
# and what is typed goes to the name field (the shot, for the eye:
# local/starport_login_focus_out.png).
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_splf.XXXXXX")
SP=29681
HE=29682
export BUILDAT_CONNECT_PORTS="$SP,$HE"
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
cd "$here"

Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -P $SP -l 3 \
	> "$tmp/sp.log" 2>&1 &
pids+=($!)
mkdir -p "$tmp/he/apps/hearth"
cat > "$tmp/he/apps/hearth/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Check hearth", "ids": "anyone",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
Build/bin/buildat_server -m apps/hearth -D "$tmp/he" -P $HE -l 3 \
	> "$tmp/he.log" 2>&1 &
pids+=($!)
for _ in $(seq 120); do
	grep -q "setup code" "$tmp/sp.log" && grep -q "Listening at" "$tmp/he.log" && break
	sleep 1
done
grep -q "Listening at" "$tmp/he.log" || fail "the Hearth did not start ($tmp/he.log)"
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
join() { # dir cmds log
	timeout 60 Build/bin/buildat -D "$1" -w 800x600 -l 3 -o sound_mute=1 \
		-s 127.0.0.1:$HE -c @"$2" > "$3" 2>&1
}

# Signed in: Return alone
mkdir -p "$tmp/in"
cat > "$tmp/in/starport.json" <<EOF
{"starports": ["http://127.0.0.1:$SP"],
 "ids": {"http://127.0.0.1:$SP": {"session": "$session", "name": "reader"}}}
EOF
cat > "$tmp/c1" <<C
wait_log_any 30000 hello: Starport IDs
delay 3000
screenshot $tmp/in.png
keypress return
delay 5000
quit
C
join "$tmp/in" "$tmp/c1" "$tmp/in.log"
# The button's press asks the extension for a token, which asks the user
# first whether this server may have it
grep -q "Asking the user about http://127.0.0.1:$SP" "$tmp/in.log" ||
	fail "Return did not sign in with the ID ($tmp/in.log)"
echo "ok: signed in, Return signs in with the ID"

# Signed out: Return signs nothing in, and typing goes to the name
mkdir -p "$tmp/out"
printf '{"starports": ["http://127.0.0.1:%s"]}\n' $SP > "$tmp/out/starport.json"
cat > "$tmp/c2" <<C
wait_log_any 30000 hello: Starport IDs
delay 3000
text zqxname
delay 1000
screenshot $tmp/out.png
keypress return
delay 2000
quit
C
join "$tmp/out" "$tmp/c2" "$tmp/out.log"
grep -q "Asking the user about" "$tmp/out.log" &&
	fail "signed out, Return still signed in with an ID ($tmp/out.log)"
[ -f "$tmp/out.png" ] || fail "no shot ($tmp/out.log)"
cp "$tmp/out.png" "$here/local/starport_login_focus_out.png" 2>/dev/null
echo "ok: signed out, Return signs nothing in (typed name: local/starport_login_focus_out.png)"
echo "PASS"
