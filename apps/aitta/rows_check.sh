#!/bin/bash
# tier: full
# cost: 40s (2026-10-09)
# covers: apps/aitta/main/client_lua/init.lua
# [AITTA_ADMIN_ROWS]: the admin's release rows on Aitta's page. A release
# with a long name and home Hearth published to a local Aitta; the admin's
# client opens the page: the id, the state ("listed") and the Delist
# button are in columns of fixed widths, a long id wrapping in its own (the screenshots); Delist turns them to "delisted" and
# Relist. Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   apps/aitta/rows_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
b="$here/Build/bin/buildat"
t=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
pid=$SERVER_PID
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "no setup code"
name=a_rather_long_package_name_for_the_rows
mkdir -p "$t/app/main"
echo 'int x;' > "$t/app/main/main.cpp"
printf '{"author": "tester", "name": "%s", "version": "1.0.0",
	"engine_api": 2, "license_code": "MIT", "license_media": "CC0-1.0",
	"description": "a check",
	"home_hearth": "https://forum.example/a/very/long/path/to/the/thread/of/this/package"}\n' \
	"$name" > "$t/app/meta.json"
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"

# The admin binds tester to the key, then the release is published
admin(){ env BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin \
	BUILDAT_AITTA_PASSWORD=checkpass BUILDAT_AITTA_CODE=$code "$@"; }
printf 'wait_log 30000 ai: {"id":1,\nquit\n' > "$t/bind.cmds"
admin BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$P -c @"$t/bind.cmds" > "$t/bind.log" 2>&1 || fail "the bind's drive"
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind"
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack"
"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "listed: tester/$name" ||
	fail "publish"

# The ntfy question at the admin's second login, over the page
cat > "$t/rows.cmds" <<C
wait_log 30000 accounts: ntfy asked
delay 500
click Button "Later"
wait_log 30000 aitta: row
delay 1500
screenshot $t/listed.png
click Button "Delist"
wait_log 10000 aitta: row tester/$name/1.0.0: delisted
delay 1500
screenshot $t/delisted.png
quit
C
admin timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$P -c @"$t/rows.cmds" > "$t/rows.log" 2>&1
grep -aq "Command sequence complete" "$t/rows.log" ||
	fail "the drive ($(grep -a "Command seq\|click:\|aitta: row" "$t/rows.log" | tail -3))"
grep -aq "aitta: row tester/$name/1.0.0: listed, Delist" "$t/rows.log" ||
	fail "no listed row with Delist"
grep -aq "aitta: row tester/$name/1.0.0: delisted, Relist" "$t/rows.log" ||
	fail "Delist did not turn the row to delisted and Relist"
echo "PASS: the row's state and its own button, Delist turns them to delisted and Relist (see the screenshots for the fit)"
