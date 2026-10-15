#!/bin/bash
# tier: full
# cost: 90s (2026-10-07)
# covers: client/core/starport/init.lua apps/starport/main/main.cpp
# [STARPORT_RECOMMENDS]: a Starport with a recommended Hearth and Aittas
# serves them in /api/v1/list and an ID's "me"; a launcher whose ID is logged
# in there is offered the Aittas it lacks at the start, and the answer
# lands: "Add" adds the checked one and ignores the unchecked one, and
# a restart offers neither again. "Discuss" on the ID's line joins the
# Hearth, listed on the Starport, and signs in with the ID by itself,
# the login dialog only when that is refused.
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_sprec.XXXXXX")
SP=29671
HE=29672
A1=http://127.0.0.1:29673
A2=http://127.0.0.1:29674
export BUILDAT_CONNECT_PORTS="$SP,$HE"
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
cd "$here"

start_server "$tmp/sp.log" "setup code" 60 $SP \
	Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -l 3
rc=$?; pids+=(${SERVER_PID:-}); [ $rc = 0 ] || fail "the Starport did not start (sp.log)"
mkdir -p "$tmp/he/apps/hearth"
cat > "$tmp/he/apps/hearth/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Check hearth", "ids": "anyone",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
start_server "$tmp/he.log" "STATUS Listening" 60 $HE \
	Build/bin/buildat_server -m apps/hearth -D "$tmp/he" -l 3
rc=$?; pids+=(${SERVER_PID:-}); [ $rc = 0 ] || fail "the Hearth did not start (he.log)"
code=$(grep -o "setup code [A-Z0-9]*" "$tmp/sp.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "the Starport did not start (sp.log)"
# The set_settings answer is logged as "sp: <json>"
printf 'wait_log_any 30000 sp: {\nquit\n' > "$tmp/cmds.txt"
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
BUILDAT_SP_CREATE=1 BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"recommended_hearth\":\"http://127.0.0.1:$HE\",\"recommended_aittas\":[\"$A1\",\"$A2\"]}}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/admin" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$SP -c @"$tmp/cmds.txt" > "$tmp/admin.log" 2>&1 ||
	fail "the admin's drive ($tmp/admin.log)"
curl -s -m 10 "localhost:$SP/api/v1/list" | grep -q "\"recommends\":.*$A2" ||
	fail "/api/v1/list has no recommends ($tmp/admin.log)"
echo "ok: /api/v1/list carries the recommendations"
wait_for_log "$tmp/sp.log" "verified ok" 60 || fail "the Hearth was not listed ($tmp/he.log)"

# An ID logged in on the launcher: its session in starport.json, the
# Starport's host accepted, the first Aitta known only by the old "aitta"
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
mkdir -p "$tmp/cl"
cat > "$tmp/cl/starport.json" <<EOF
{"starports": ["http://127.0.0.1:$SP"], "aittas": ["https://aitta.buildat.org"],
 "ids": {"http://127.0.0.1:$SP": {"session": "$session", "name": "reader"}}}
EOF
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","Starport","%s","%s","","",""\n' \
	$SP $(date +%s) $(date +%s) > "$tmp/cl/network_addresses.csv"
launcher() { # cmds log
	BUILDAT_STARPORT_OFFER=1 timeout 120 Build/bin/buildat \
		-o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 4 \
		-o sound_mute=1 -c @"$1" > "$2" 2>&1 || fail "the drive $1 ($2)"
}
# The dialog at 800x600: the second Aitta unchecked, then "Add"
cat > "$tmp/c1" <<C
wait_log_any 30000 Offering 2 Aitta
delay 1000
mouse_pos 400 337
mouse_click left
# The click's frames: the box unchecked before the next press
delay 300
mouse_pos 316 353
mouse_click left
wait_log 5000 Aittas offered
quit
C
launcher "$tmp/c1" "$tmp/cl1.log"
python3 - "$tmp/cl/starport.json" "$A1" "$A2" <<'PY' || fail "the answer did not land ($tmp/cl1.log)"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["aittas"] == ["https://aitta.buildat.org", sys.argv[2]], s["aittas"]
assert s["ignored_aittas"] == [sys.argv[3]], s["ignored_aittas"]
assert "aitta" not in s, s
PY
echo "ok: the checked Aitta added, the unchecked one ignored"

# A restart offers neither again; "Discuss" (the ID line's first button)
# joins the Hearth and signs in with the ID: the Starport's first-time
# "name to use in" prompt (Use it), and no login dialog before that
cat > "$tmp/c2" <<C
wait_log_any 30000 trusted overlay: 1 Starport ID line
wait_log_any 20000 servers listed
delay 500
mouse_pos 725 15
mouse_click left
wait_log 20000 ID name prompt:
delay 500
mouse_pos 330 335
mouse_click left
wait_log 20000 Login refused:
quit
C
launcher "$tmp/c2" "$tmp/cl2.log"
grep -q "Offering" "$tmp/cl2.log" && fail "offered again after a restart"
echo "ok: not offered again"
grep -q "Connect succeeded (127.0.0.1:$HE)" "$tmp/cl2.log" ||
	fail "Discuss did not join the Hearth ($tmp/cl2.log)"
# The Hearth has no admin yet, so it refuses the ID's login, and the
# login dialog comes up with the reason: both halves of it seen
grep -q "Signing in with the Starport ID" "$tmp/cl2.log" &&
	grep -q "Login of reader from" "$tmp/he.log" ||
	fail "Discuss did not sign in with the ID ($tmp/cl2.log)"
grep -q "Login refused: This server has no admin yet" "$tmp/cl2.log" ||
	fail "no login dialog after the refusal ($tmp/cl2.log)"
echo "ok: Discuss joined the Hearth, signed in with the ID; the refusal to the dialog"

# Taken back from the ignored list, offered again; closed, ignored again
python3 - "$tmp/cl/starport.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["ignored_aittas"] = []
json.dump(s, open(sys.argv[1], "w"))
PY
cat > "$tmp/c3" <<C
wait_log_any 30000 Offering 1 Aitta
delay 1000
keypress escape
wait_log 5000 Aittas offered
quit
C
launcher "$tmp/c3" "$tmp/cl3.log"
python3 - "$tmp/cl/starport.json" "$A2" <<'PY' || fail "a close did not ignore ($tmp/cl3.log)"
import json, sys
s = json.load(open(sys.argv[1]))
assert s["ignored_aittas"] == [sys.argv[2]], s["ignored_aittas"]
PY
echo "ok: closing the dialog ignores"
echo "PASS"
