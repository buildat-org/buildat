#!/bin/bash
# tier: full
# cost: 70s (2026-10-09)
# covers: apps/aitta/main/main.cpp apps/aitta/main/client_lua/init.lua client/core/starport/init.lua client/core/aitta/init.lua client/launch_grid.lua src/client/app_lua.h src/impl/aitta.cpp
# [AITTA_REVIEW]: a local Aitta with an admin (a reviewer) and a plain
# account; tester/pt (apps/demo_board_game) published as 1.0.0, 1.0.1 (a file
# changed, one added) and 1.0.2.
#   1. The admin marks 1.0.0 reviewed and delists 1.0.2; 1.0.1's diff is
#      against 1.0.0. A ticket fetches the delisted 1.0.2 once, not twice,
#      and nothing without one; the plain account gets no ticket.
#   2. The admin's client, joined from the launcher: Review releases, 1.0.1's
#      page, Playtest; the launcher's dialog, its yes; installed under
#      <user>/review and launched.
#   3. The launcher again: the playtest's tile and its Remove; Aitta's page
#      with 1.0.0 reviewed and 1.0.1 unreviewed.
#   4. A client under a managed lock: Aitta's page with 1.0.0 only.
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   apps/aitta/review_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
b="$here/Build/bin/buildat"
t=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }

cd "$here/Build"
start_server "$t/srv.log" "setup code" 60 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
pid=$SERVER_PID
P=$SERVER_PORT
A=http://127.0.0.1:$P
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "no setup code"
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"

admin(){ env BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin \
	BUILDAT_AITTA_PASSWORD=checkpass BUILDAT_AITTA_CODE=$code "$@"; }
reqs(){ # who log requests...
	local who=$1 log=$2 i; shift 2
	# Every request's answer, by its id; the admin script's, when there is one
	{
		[ -n "${BUILDAT_AITTA_ADMIN:-}" ] && echo "wait_log_any 30000 admin script: done"
		for i in $(seq $#); do echo "wait_log_any 30000 \"id\":$i,"; done
		echo quit
	} > "$t/reqs.cmds"
	$who BUILDAT_AITTA_REQS="$(printf '%s\n' "$@")" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$who" \
		-w 800x600 -l 3 -s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$log" 2>&1
}
plain(){ env BUILDAT_AITTA_NAME=plain \
	BUILDAT_AITTA_PASSWORD=checkpass2 "$@"; }

BUILDAT_AITTA_ADMIN="add plain checkpass2" reqs admin "$t/bind.log" \
	"{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}"
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind"
mkdir -p "$t/app"
cp -r ../apps/demo_board_game/main ../apps/demo_board_game/launcher "$t/app/"
publish(){
	printf '{"author": "tester", "name": "pt", "version": "%s",
		"engine_api": 2, "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "a review check"}\n' "$1" > "$t/app/meta.json"
	zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack $1"
	"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "listed: tester/pt" ||
		fail "publish $1"
}
publish 1.0.0
echo "// 1.0.1" >> "$t/app/main/main.cpp"
echo "added in 1.0.1" > "$t/app/main/extra.txt"
publish 1.0.1
publish 1.0.2

# 1. The marks, the diff and a ticket, by requests
reqs admin "$t/marks.log" \
	'{"cmd":"review_mark","release":"tester/pt/1.0.0","action":"reviewed"}' \
	'{"cmd":"review_mark","release":"tester/pt/1.0.2","action":"delist","note":"a check"}' \
	'{"cmd":"review_diff","release":"tester/pt/1.0.1"}' \
	'{"cmd":"playtest","release":"tester/pt/1.0.2"}'
for i in 1 2; do
	grep -aq "ai: {\"id\":$i,\"ok\":true" "$t/marks.log" ||
		fail "mark $i: $(grep -a 'ai: ' "$t/marks.log" | head -4)"
done
diff=$(grep -a 'ai: {"id":3,' "$t/marks.log")
echo "$diff" | grep -q '"base":"tester/pt/1.0.0"' || fail "the diff's base: $diff"
echo "$diff" | grep -q '"added":\["main/extra.txt"\]' || fail "the diff's added: $diff"
echo "$diff" | grep -q '"path":"main/main.cpp"' || fail "the diff's changed: $diff"
pt=$(grep -a 'ai: {"id":4,' "$t/marks.log")
ticket=$(echo "$pt" | grep -o '"ticket":"[0-9a-f]*"' | cut -d'"' -f4)
sha=$(echo "$pt" | grep -o '"sha256":"[0-9a-f]*"' | cut -d'"' -f4)
[ -n "$ticket" ] && [ -n "$sha" ] || fail "no ticket: $pt"
st(){ curl -s -o /dev/null -w '%{http_code}' "$1"; }
[ "$(st "$A/api/v1/aitta/archive/$sha.zip")" = 404 ] ||
	fail "the delisted release without a ticket"
[ "$(st "$A/api/v1/aitta/archive/$sha.zip?ticket=$ticket")" = 200 ] ||
	fail "the ticket's fetch"
[ "$(st "$A/api/v1/aitta/archive/$sha.zip?ticket=$ticket")" = 404 ] ||
	fail "the ticket's second fetch"
reqs plain "$t/plain.log" '{"cmd":"playtest","release":"tester/pt/1.0.1"}'
grep -aq 'ai: {"code":"refused","error":"for the reviewers[^"]*","id":1,"ok":false' "$t/plain.log" ||
	fail "the plain account's playtest: $(grep -a 'ai: ' "$t/plain.log" | head -2)"

# 2. The admin's playtest, joined from the launcher
cat > "$t/pt.cmds" <<C
wait_log_any 30000 rows in
event join 127.0.0.1:$P
wait_log 30000 accounts: ntfy asked
delay 500
click Button "Later"
wait_log 30000 aitta: row
wait_log_any 10000 aitta: waiting 1 unreviewed, 0 reports
delay 500
screenshot $t/home.png
click Button "Review releases (1)"
wait_log 10000 aitta: review list unreviewed: 1
click Button "Open"
wait_log 10000 aitta: review tester/pt/1.0.1: unreviewed,
delay 1000
screenshot $t/review.png
click Button "Playtest"
wait_log 10000 playtest: offered tester/pt/1.0.1
delay 2000
screenshot $t/dialog.png
click Button "Playtest"
wait_log 10000 Asking the user about $A
delay 1000
click Button "Accept"
wait_log 20000 playtest: installed review:tester.pt@1.0.1
wait_log 60000 demo_board_game/init.lua loaded
delay 2000
screenshot $t/running.png
quit
C
admin timeout 150 bin/buildat -m launch_menu -D "$t/cl_admin" -w 1024x700 \
	-l 3 -c @"$t/pt.cmds" > "$t/pt.log" 2>&1
grep -a "demo_board_game/init.lua loaded" "$t/pt.log" | grep -aqv "command: \\|wait_log: " ||
	fail "the playtest did not start ($(grep -a "playtest\|start_local" "$t/pt.log" | tail -2))"
grep -aq "Command sequence complete" "$t/pt.log" ||
	fail "the playtest drive ($(grep -a "Command seq\|click:\|aitta: \|playtest" "$t/pt.log" | tail -4))"
dir=$(find "$t/cl_admin" -path "*/review/tester__pt/1.0.1" -type d)
[ -n "$dir" ] || fail "nothing under <user>/review"
[ -f "$dir/.aitta_from" ] || fail "no .aitta_from"

# 3. The tile and its Remove; Aitta's page, its badges
echo "{\"aittas\": [\"$A\"]}" > "$t/managed.json"
cat > "$t/grid.cmds" <<C
wait_log_any 30000 rows in
text remove
wait_log 5000 rows for "remove"
delay 500
screenshot $t/tile.png
keypress Return
wait_log 10000 playtest: removed review:tester.pt@1.0.1: true
delay 1000
text apps from aitta
wait_log 5000 apps from aitta"
keypress Return
wait_log 15000 aitta page: tester/pt
delay 1500
screenshot $t/aitta.png
quit
C
BUILDAT_STARPORT_MANAGED="$t/managed.json" timeout 90 bin/buildat \
	-m launch_menu -D "$t/cl_admin" -w 1024x700 -l 3 -c @"$t/grid.cmds" \
	> "$t/grid.log" 2>&1
grep -aq "Command sequence complete" "$t/grid.log" ||
	fail "the grid drive ($(grep -a "Command seq\|launch_menu: \|playtest\|aitta page" "$t/grid.log" | tail -4))"
[ -d "$dir" ] && fail "Remove left $dir"
grep -aq "aitta page: tester/pt 1.0.0 reviewed" "$t/grid.log" ||
	fail "no reviewed 1.0.0 on Aitta's page"
grep -aq "aitta page: tester/pt 1.0.1 unreviewed" "$t/grid.log" ||
	fail "no unreviewed 1.0.1 on Aitta's page"

# 4. Under the lock, 1.0.0 only
echo "{\"aittas\": [\"$A\"], \"filters\": {\"unreviewed\": false}}" > "$t/managed.json"
cat > "$t/lock.cmds" <<C
wait_log_any 30000 rows in
text apps from aitta
wait_log 5000 apps from aitta"
keypress Return
wait_log 10000 Asking the user about $A
delay 1000
click Button "Accept"
wait_log 15000 aitta page: tester/pt
delay 1500
screenshot $t/locked.png
quit
C
BUILDAT_STARPORT_MANAGED="$t/managed.json" timeout 90 bin/buildat \
	-m launch_menu -D "$t/cl_lock" -w 1024x700 -l 3 -c @"$t/lock.cmds" \
	> "$t/lock.log" 2>&1
grep -aq "Command sequence complete" "$t/lock.log" || fail "the locked drive"
[ "$(grep -ac "aitta page: tester/pt [0-9]" "$t/lock.log")" = 1 ] &&
	grep -aq "aitta page: tester/pt 1.0.0 reviewed" "$t/lock.log" ||
	fail "the locked page: $(grep -a "aitta page: tester/pt [0-9]" "$t/lock.log")"
echo "PASS: review marks, the diff, tickets; the playtest's dialog, install, launch, tile and Remove; the badges; the lock's reviewed-only list (see the screenshots)"
