#!/bin/bash
# tier: full
# cost: 120s (2026-10-04)
# covers: src/client/app.cpp client/extensions/network/init.lua client/extensions/starport/init.lua apps/starport/main/main.cpp
# [WEB_ID_TRUST] (c): the web client's HTTP is the browser's fetch(), to a
# Starport that answers with CORS -- no relay through the game server. A
# Starport and floorplanner listed on it, serving the web client; the
# player's account made natively; headless Firefox logs in on the page and
# opens "Report this server..." from the plan picker's menu, which fetches
# the Starport's list (the server said where it is listed) and finds the
# listing.
# Needs web/ from util/build_web.sh.
#   util/web_fetch_check.sh [steps.json]
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_webfetch.XXXXXX")
SP=29681
AN=29682
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
mkdir -p "$tmp/f/apps/floorplanner"
cat > "$tmp/f/apps/floorplanner/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Web house", "ids": "anyone",
 "kind": "app", "audience": "everyone", "access": "open",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "none",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
Build/bin/buildat_server -m apps/floorplanner -D "$tmp/f" -P $AN -W "$here/web" \
	-l 3 > "$tmp/f.log" 2>&1 &
pids+=($!)
for _ in $(seq 180); do grep -q "verified ok" "$tmp/sp.log" && break; sleep 1; done
grep -q "verified ok" "$tmp/sp.log" || fail "no verified listing ($tmp/f.log)"

printf 'delay 6000\nquit\n' > "$tmp/cmds.txt"
# Claimed, as a listing is only served then
code=$(grep -o "setup code [A-Z0-9]*" "$tmp/sp.log" | cut -d' ' -f3)
read -r _ _ id _ _ ccode < <(grep -v "^#" "$tmp/f/apps/floorplanner/starport_claim.txt")
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
BUILDAT_SP_CREATE=1 BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}
{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$SP -c @"$tmp/cmds.txt" > "$tmp/sp_admin.log" 2>&1
curl -s -m 10 "localhost:$SP/api/v1/list" | grep -q "\"$id\"" ||
	fail "the claim ($tmp/sp_admin.log)"
setup=$(grep -ao "setup code [A-Z0-9]*" "$tmp/f.log" | tail -1 | cut -d' ' -f3)
BUILDAT_FP_NAME=webop BUILDAT_FP_PASSWORD=webpass123 BUILDAT_FP_CREATE=1 \
	BUILDAT_FP_CODE=$setup timeout 90 \
	Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 3 -s 127.0.0.1:$AN \
	-c @"$tmp/cmds.txt" > "$tmp/op.log" 2>&1
grep -q "Joined as webop" "$tmp/op.log" || fail "the account ($tmp/op.log)"

WEB_DRIVE_URL="http://127.0.0.1:$AN/" "$here/util/web_drive.sh" firefox floorplanner \
	"${1:-$here/util/web_fetch.json}" "$tmp/drive" > "$tmp/drive.txt" 2>&1 ||
	fail "the drive ($tmp/drive.txt, $tmp/drive)"
grep -a "report here:" "$tmp/drive/page.log" | sed 's/.*report here: /report here: /'
grep -aq "report here: .*; found" "$tmp/drive/page.log" ||
	fail "the web client did not find the listing ($tmp/drive/page.log)"
echo "PASS: the web client fetches from the Starport itself"
