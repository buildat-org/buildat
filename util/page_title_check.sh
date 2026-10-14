#!/bin/bash
# tier: full
# cost: 90s (2026-10-04)
# covers: builtin/network/network.cpp builtin/starport_announce/starport_announce.cpp apps/floorplanner/main/main.cpp src/client/app.cpp
# [PAGE_TITLE]: the web client's page is titled "<name> | Buildat" -- the
# admin's name from starport.json (IDs off, nothing announced), else the
# app's ("Floor planner"), else "Buildat" -- and the tab keeps it once the
# client has started (headless Firefox, document.title).
# Needs web/ from util/build_web.sh.
#   util/page_title_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_title.XXXXXX")
P=29772
pid=
cleanup() {
	[ -n "$pid" ] && kill $pid 2>/dev/null
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "${tmp:?}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here"
[ -s web/index.html ] || fail "no web/ (util/build_web.sh)"

start() { # app dir
	start_server "$tmp/$2.log" "STATUS Listening" 60 $P \
		Build/bin/buildat_server -m "apps/$1" -D "$tmp/$2" -l 3 ||
		fail "the server ($tmp/$2.log)"
	pid=$SERVER_PID
}
stop() { kill $pid; wait $pid 2>/dev/null; pid=; }
title() { # once the page is served
	local i
	for i in $(seq 50); do
		curl -s -m 5 "http://127.0.0.1:$P/index.html" | grep -o "<title>.*</title>" && return
		sleep 0.2
	done
}

start hearth plain
t=$(title); stop
[ "$t" = "<title>Buildat</title>" ] || fail "with no name: $t"
start floorplanner fp
t=$(title); stop
[ "$t" = "<title>Floor planner | Buildat</title>" ] || fail "the app's: $t"

mkdir -p "$tmp/named/apps/hearth"
echo '{"starports": [], "name": "Lamp <Corner>"}' > "$tmp/named/apps/hearth/starport.json"
start hearth named
t=$(title)
[ "$t" = "<title>Lamp &lt;Corner&gt; | Buildat</title>" ] || fail "the admin's: $t"
echo "ok: the admin's, the app's, none"
WEB_DRIVE_URL="http://127.0.0.1:$P/index.html" util/web_drive.sh firefox hearth \
	util/page_title.json "$tmp/drive" > "$tmp/drive.txt" 2>&1 ||
	fail "the drive ($tmp/drive.txt)"
grep -q 'eval: "Lamp <Corner> | Buildat"' "$tmp/drive.txt" "$tmp/drive/page.log" ||
	fail "the tab's title after the start: $(grep -h eval: "$tmp/drive.txt" "$tmp/drive/page.log")"
echo "PASS: the page's title is the admin's name, the app's or Buildat, and the started client keeps it"
