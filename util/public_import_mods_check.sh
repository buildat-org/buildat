#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-10-14)
# covers: apps/vanilla/main/main.cpp apps/vanilla/main/client_lua/menu.lua
# [SECURITY_RUN_5] finding 3, the user's call (2026-10-14): a public
# server's import of a world that brings mods of its own asks the admin.
#   1. A public vanilla server; a client takes the admin with the setup
#      code and imports a Luanti world zip with worldmods/ctest: the dialog
#      names ctest, "Keep the mods": the world has ctest, and it runs.
#   2. The first world moved out, the same zip again, "Leave them out":
#      the second world has none.
#   util/public_import_mods_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp public_import_mods; t=$CHECK_TMP
saves="$t/srv/apps/vanilla/saves"
serve(){
	start_server "$1" "STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
		-m "$here/apps/vanilla" -D "$t/srv" -C "$t/cache" -l 3 || fail "the server ($1)"
	CHECK_PIDS+=($SERVER_PID)
}
stop(){ kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }
mkdir -p "$t/cu/exports"
python3 - "$t/cu/exports/modded.zip" <<'PY'
import os, sqlite3, sys, tempfile, zipfile
db = tempfile.mktemp()
c = sqlite3.connect(db)
c.execute("CREATE TABLE blocks (pos INT PRIMARY KEY, data BLOB)")
c.commit(); c.close()
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("modded/world.mt", "gameid = minimal\nbackend = sqlite3\n")
    z.writestr("modded/map.sqlite", open(db, "rb").read())
    z.writestr("modded/worldmods/ctest/mod.conf", "name = ctest\n")
    z.writestr("modded/worldmods/ctest/init.lua", 'core.log("action", "ctest ran")\n')
os.remove(db)
PY
# drive <log> <button>
drive(){
	# The admin's first login asks about ntfy in a window over the menu
	{ [ -z "$code" ] || printf '%s\n' 'wait_log 30000 accounts: ntfy asked' \
		'wait_log_any 5000 server window: the page ntfy' 'delay 300' \
		"click Button \"Don't add\"" 'delay 500'
	printf '%s\n' 'wait_log_any 60000 saves' 'delay 1000' \
		'click Button "Import a world from a zip..."' \
		'wait_log 5000 The file picker at' 'delay 500' 'click Button "modded.zip"' \
		'wait_log 60000 brings mods: ctest' 'delay 500' "click Button \"$2\"" \
		'wait_log_any 120000 the world is up' 'delay 1000' quit; } > "$t/c.cmds"
	BUILDAT_JOIN_NAME=boss BUILDAT_JOIN_PASSWORD=secret123 BUILDAT_JOIN_CREATE=${code:+1} \
	BUILDAT_JOIN_CODE="$code" run_client 60 "$1" timeout 300 "$here/Build/bin/buildat" \
		-s "127.0.0.1:$SERVER_PORT" -D "$t/cu" -C "$t/cc" -w 1100x900 -u 1 \
		-l 3 -o sound_mute=1 -c @"$t/c.cmds" || fail "the drive ($1)"
}
# The imported world's mods, by the save the import made
mods_of(){ ls "$saves/$1/luanti/worldmods" 2>/dev/null | tr '\n' ' '; }

# 1
serve "$t/1.log"
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/1.log)"
drive "$t/1c.log" "Keep the mods"
grep -aq "world mods kept by the admin" "$t/1.log" || fail "not kept ($t/1.log)"
grep -aq "ctest ran" "$t/1.log" || fail "the kept mod did not run ($t/1.log)"
stop
first=$(ls "$saves" | grep '^modded' | head -1)
[ -n "$first" ] || fail "no imported save in $saves"
[ "$(mods_of "$first")" = "ctest " ] ||
	fail "kept: $first's world mods are '$(mods_of "$first")', not ctest"
echo "ok: kept, $first has ctest"
# Out of the saves: a public server with a world starts it, and the admin
# would join it rather than the menu
mv "$saves/$first" "$t/kept"

# 2
code=""
serve "$t/2.log"
drive "$t/2c.log" "Leave them out"
grep -aq "world mods left out" "$t/2.log" || fail "not left out ($t/2.log)"
grep -aq "ctest ran" "$t/2.log" && fail "the left-out mod ran ($t/2.log)"
stop
second=$(ls "$saves" | grep '^modded' | head -1)
[ -n "$second" ] || fail "no second imported save in $saves"
[ -z "$(mods_of "$second")" ] ||
	fail "left out: $second's world mods are '$(mods_of "$second")'"
echo "ok: left out, $second has none"
echo "PASS: a public server's import asks the admin about the world's mods; kept and left out as answered"
# vim: set noet ts=4 sw=4:
