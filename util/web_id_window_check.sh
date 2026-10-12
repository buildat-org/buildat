#!/bin/bash
# tier: full
# cost: 120s (2026-10-04)
# covers: apps/starport/main/main.cpp client/extensions/starport/init.lua builtin/starport_announce/** src/client/app.cpp
# [WEB_ID_TRUST] (a): a web client signs in with a Starport ID in the
# Starport's own window. A Starport, Hearth listed on it with IDs on and
# serving the web client, and an ID made by the API; headless Firefox
# (the window step is Firefox's) opens Hearth's page, clicks "Sign in with
# your Starport ID" (its window opens at once), and in the Starport's
# /authorize window logs in,
# allows, names itself and allows; the token comes back to Hearth's page
# by postMessage and the join is by it. Also by the API: /authorize is
# never framed, the API answers any origin, a token for an origin that is
# neither the listing's nor in web_clients is refused, and so is a password
# login from any page but the Starport's own (an Origin header not its
# Host). Then the ID's own page, /id, in the same browser: logged in still,
# its sessions, and "Log out everywhere else" leaving this one. Then an ID
# whose name in the community is a local account's: the refusal logged,
# the reason shown, another name picked in the Starport's window; and
# another such ID's "That's my account" with the account's password,
# which joins as the account and links the ID ([ID_CLAIM_ACCOUNT]).
# Needs web/ from util/build_web.sh.
#   util/web_id_window_check.sh [steps.json [rename_steps.json [claim_steps.json]]]
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_webid.XXXXXX")
SP=29671
AN=29672
export BUILDAT_CONNECT_PORTS="$SP,$AN"
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "${tmp:?}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here"

start_server "$tmp/sp.log" "setup code" 120 $SP \
	Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -l 3 ||
	fail "the Starport did not start"
pids+=($SERVER_PID)
mkdir -p "$tmp/h/apps/hearth"
cat > "$tmp/h/apps/hearth/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Web hearth", "ids": "anyone",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
Build/bin/buildat_server -m apps/hearth -D "$tmp/h" -P $AN -W "$here/web" -l 3 \
	> "$tmp/h.log" 2>&1 &
pids+=($!)
for _ in $(seq 180); do grep -q "verified ok" "$tmp/sp.log" && break; sleep 1; done
grep -q "verified ok" "$tmp/sp.log" || fail "no verified listing ($tmp/h.log)"
read -r _ _ id _ < <(grep -v "^#" "$tmp/h/apps/hearth/starport_claim.txt")

curl -si "localhost:$SP/authorize?listing=$id" | grep -qi "^X-Frame-Options: DENY" ||
	fail "/authorize may be framed"
curl -si -X POST -d '{}' "localhost:$SP/api/v1/list" |
	grep -qi "^Access-Control-Allow-Origin: \*" || fail "no CORS on the API"
python3 - "$SP" "$id" "$AN" <<'PY' || fail "the ID API"
import json, sys, time, urllib.request
B = "http://127.0.0.1:%s/api/v1/id/" % sys.argv[1]
def call(w, **k):
    return json.loads(urllib.request.urlopen(B + w, json.dumps(k).encode()).read())
own = "http://127.0.0.1:" + sys.argv[3]
r = call("authorize_info", listing=sys.argv[2], web=True)
assert r["ok"] and r["result"]["origin"] == own, r
r = call("register", name="webid", password="secret1",
        birth_year=time.gmtime().tm_year - 40)
assert r["ok"], r
s = r["result"]["session"]
r = call("token", session=s, listing=sys.argv[2], web=True,
        origin="https://evil.example", name="x")
assert not r["ok"] and "sends no tokens" in r["error"], r
print("ok: a token for another origin is refused")
def from_page(origin, w, **k):
    q = urllib.request.Request(B + w, json.dumps(k).encode(),
            {"Origin": origin})
    return json.loads(urllib.request.urlopen(q).read())
r = from_page(own, "login", name="webid", password="secret1")
assert not r["ok"] and "own page" in r["error"], r
r = from_page("http://127.0.0.1:" + sys.argv[1], "login", name="webid",
        password="secret1")
assert r["ok"], r
print("ok: a password login from a game server's page is refused")
# (b): sessions, logging out the others, and TOTP over the changes
s2 = call("login", name="webid", password="secret1")["result"]["session"]
r = call("sessions", session=s2)["result"]
assert len(r["sessions"]) >= 3 and len(r["recent"]) >= 3, r
assert sum(1 for x in r["sessions"] if x["this"]) == 1, r
assert r["recent"][-1]["address"] == "127.0.0.1", r
assert r["recent"][-1]["how"] == "login in a client", r
r = call("logout_others", session=s2)
assert r["ok"] and r["result"] >= 2, r
r = call("sessions", session=s2)["result"]["sessions"]
assert len(r) == 1 and r[0]["this"], r
assert call("me", session=s)["error"] == "session"
import base64, hashlib, hmac, struct
def code(secret, step):
    k = base64.b32decode(secret + "=" * (-len(secret) % 8))
    h = hmac.new(k, struct.pack(">Q", step), hashlib.sha1).digest()
    o = h[-1] & 15
    return "%06d" % ((struct.unpack(">I", h[o:o + 4])[0] & 0x7fffffff) % 1000000)
t = call("register", name="totpid", password="secret1",
        birth_year=time.gmtime().tm_year - 40)["result"]["session"]
sec = call("totp", session=t, cmd="begin")["result"]["secret"]
now = int(time.time()) // 30
assert call("totp", session=t, cmd="confirm", code=code(sec, now))["ok"]
r = call("password", session=t, old="secret1", new="secret2")
assert r["error"] == "totp", r
r = call("email", session=t, email="x@example.org")
assert r["error"] == "totp", r
r = call("password", session=t, old="secret1", new="secret2",
        totp=code(sec, now + 1))
assert r["ok"], r
print("ok: sessions, logging out the others, and TOTP over a change")
PY

# The first admin, natively, so the web join is an ID's ordinary one
setup=$(grep -ao "setup code [A-Z0-9]*" "$tmp/h.log" | tail -1 | cut -d' ' -f3)
printf 'delay 6000\nquit\n' > "$tmp/cmds.txt"
BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=adminpass1 \
	BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$setup timeout 90 \
	Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 3 -s 127.0.0.1:$AN \
	-c @"$tmp/cmds.txt" > "$tmp/admin.log" 2>&1
grep -q "Joined as admin" "$tmp/admin.log" || fail "the admin's join ($tmp/admin.log)"

WEB_DRIVE_URL="http://127.0.0.1:$AN/" "$here/util/web_drive.sh" firefox hearth \
	"${1:-$here/util/web_id_window.json}" "$tmp/drive" > "$tmp/drive.txt" 2>&1 ||
	fail "the drive ($tmp/drive.txt, $tmp/drive)"
grep -aq "Settings of webid: 1 sessions" "$tmp/drive/page.log" ||
	fail "Starport's /id page ($tmp/drive/page.log)"
grep -aq "Joined as webname" "$tmp/drive/page.log" ||
	fail "the web client did not join by the ID ($tmp/drive/page.log)"

# The name the ID has in this community is a local account's here: the
# refusal is logged, the client's dialog says why above Open, and the
# Starport's window asks for another name, which joins (the local account
# is the admin's)
python3 - "$SP" "$id" <<'PY' || fail "the second ID"
import json, sys, time, urllib.request
B = "http://127.0.0.1:%s/api/v1/id/" % sys.argv[1]
def call(w, **k):
    return json.loads(urllib.request.urlopen(B + w, json.dumps(k).encode()).read())
s = call("register", name="webid2", password="secret1",
        birth_year=time.gmtime().tm_year - 40)["result"]["session"]
r = call("token", session=s, listing=sys.argv[2], name="admin")
assert r["ok"], r
PY
WEB_DRIVE_URL="http://127.0.0.1:$AN/" "$here/util/web_drive.sh" firefox hearth \
	"${2:-$here/util/web_id_rename.json}" "$tmp/drive2" > "$tmp/drive2.txt" 2>&1 ||
	fail "the rename drive ($tmp/drive2.txt, $tmp/drive2)"
grep -q "Starport ID login of admin from .* refused: The name admin is taken" \
	"$tmp/h.log" || fail "the refusal is not logged ($tmp/h.log)"
grep -aq "Joined as other" "$tmp/drive2/page.log" ||
	fail "the ID did not join by another name ($tmp/drive2/page.log)"
# A third ID by the admin's name: "That's my account" and the admin's
# password
python3 - "$SP" "$id" <<'PY' || fail "the third ID"
import json, sys, time, urllib.request
B = "http://127.0.0.1:%s/api/v1/id/" % sys.argv[1]
def call(w, **k):
    return json.loads(urllib.request.urlopen(B + w, json.dumps(k).encode()).read())
s = call("register", name="webid3", password="secret1",
        birth_year=time.gmtime().tm_year - 40)["result"]["session"]
r = call("token", session=s, listing=sys.argv[2], name="admin")
assert r["ok"], r
PY
WEB_DRIVE_URL="http://127.0.0.1:$AN/" "$here/util/web_drive.sh" firefox hearth \
	"${3:-$here/util/web_id_claim.json}" "$tmp/drive3" > "$tmp/drive3.txt" 2>&1 ||
	fail "the claim drive ($tmp/drive3.txt, $tmp/drive3)"
grep -aq "Joined as admin" "$tmp/drive3/page.log" ||
	fail "\"That's my account\" did not join ($tmp/drive3/page.log)"
grep -q "admin linked a Starport ID of 127.0.0.1" "$tmp/h.log" ||
	fail "the ID not linked ($tmp/h.log)"
echo "PASS: a web client signs in by the Starport's window, by another name where its own is taken, and by \"That's my account\" with the account's password"
