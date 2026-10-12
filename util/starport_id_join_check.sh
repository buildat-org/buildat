#!/bin/bash
# tier: full
# cost: 60s (2026-10-04)
# covers: apps/hearth/main/meta.json apps/aitta/main/meta.json builtin/starport_announce/**
# [STARPORT_PAGE_WAITS]: Hearth and Aitta answer their admin's Starport page
# and take a Starport ID. For each: a Starport, the app listed on it by
# starport.json with IDs on ("ids": "anyone"), the listing claimed by the
# Starport's admin, an ID's token for it, and a join with that token and
# the app's setup code -- the ID becomes the app's first admin. The page's
# packet is starport_announce's; an app that does not depend on it waits
# for ever there, and refuses every ID.
#   util/starport_id_join_check.sh [app...]   (default: hearth aitta)
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_spid.XXXXXX")
SP=29651
AN=29652
export BUILDAT_CONNECT_PORTS="$SP,$AN"
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
cd "$here"

start_server "$tmp/sp.log" "setup code" 120 $SP \
	Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -l 3 ||
	fail "the Starport did not start (sp.log)"
pids+=($SERVER_PID)
code=$(grep -o "setup code [A-Z0-9]*" "$tmp/sp.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "the Starport did not start (sp.log)"
printf 'delay 8000\nquit\n' > "$tmp/cmds.txt"
n=0
for app in ${@:-hearth aitta}; do
	n=$((n + 1))
	prefix=BUILDAT_$(echo "$app" | tr a-z A-Z)
	d=$tmp/$app
	mkdir -p "$d/apps/$app"
	cat > "$d/apps/$app/starport.json" <<EOF
{"starports": ["http://127.0.0.1:$SP"], "name": "Check $app", "ids": "anyone",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
EOF
	Build/bin/buildat_server -m apps/$app -D "$d" -P $AN -l 3 \
		> "$tmp/$app.log" 2>&1 &
	pids+=($!)
	for _ in $(seq 180); do
		[ "$(grep -c "verified ok" "$tmp/sp.log")" -ge $n ] && break
		sleep 1
	done
	[ "$(grep -c "verified ok" "$tmp/sp.log")" -ge $n ] ||
		fail "$app: no verified listing ($tmp/$app.log)"
	read -r _ _ id _ _ ccode < <(grep -v "^#" "$d/apps/$app/starport_claim.txt")
	BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
	BUILDAT_SP_CREATE=1 BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}
{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}" \
		timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 3 \
		-s 127.0.0.1:$SP -c @"$tmp/cmds.txt" > "$tmp/sp_$app.log" 2>&1
	curl -s -m 10 "localhost:$SP/api/v1/list" | grep -q "\"$id\"" ||
		fail "$app: the claim ($tmp/sp_$app.log)"
	token=$(python3 - "$SP" "$id" "$app" <<'PY'
import json, sys, time, urllib.request
B = "http://127.0.0.1:%s/api/v1/" % sys.argv[1]
def call(w, **k):
    return json.loads(urllib.request.urlopen(B + w, json.dumps(k).encode()).read())
r = call("id/register", name="id" + sys.argv[3], password="secret1",
        birth_year=time.gmtime().tm_year - 40)
assert r["ok"], r
r = call("id/token", session=r["result"]["session"], listing=sys.argv[2],
        name="grown" + sys.argv[3])
assert r["ok"], r
print(r["result"]["token"])
PY
	) || fail "$app: the ID API"
	setup=$(grep -ao "setup code [A-Z0-9]*" "$tmp/$app.log" | tail -1 | cut -d' ' -f3)
	env "${prefix}_STARPORT=$token" "${prefix}_CODE=$setup" timeout 90 \
		Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 3 -s 127.0.0.1:$AN \
		-c @"$tmp/cmds.txt" > "$tmp/cl_$app.log" 2>&1
	grep -q "Joined as grown$app" "$tmp/cl_$app.log" &&
		grep -q "grown$app claimed the server with the setup code" "$tmp/$app.log" ||
		fail "$app: the ID did not join ($tmp/cl_$app.log, $tmp/$app.log)"
	echo "ok: $app listed, and a Starport ID joined as its first admin"
	kill "${pids[-1]}"
	sleep 1
done
echo "PASS: a Starport ID joins ${*:-hearth aitta}"
