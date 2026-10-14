#!/bin/bash
# tier: quick
# cost: ~1 min (2026-10-14)
# covers: src/impl/aitta.cpp builtin/loader/loader.cpp builtin/client_lua/client_lua.cpp src/server/confine.cpp
# [LUANTI_APP_PACKAGES]: a variant of vanilla as a package. vanilla_voxel_physics
# with a manifest naming "base": "vanilla" is packed, signed and installed
# into a fresh user dir, where nothing is beside it: its base is found among
# the apps Buildat ships. One client_lua file of vanilla's main module,
# init.lua, is the variant's own (main/ with no meta.json): the server
# serves that one file of it and vanilla's for the rest. A client plays
# minimal on it; the save is the variant's.
# simplified: installed from the zip, not fetched from an Aitta (the
# fetch is apps/aitta/check.sh's)
#   util/base_install_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
b=$here/Build/bin/buildat
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp base_install; t=$CHECK_TMP
trap check_cleanup EXIT

# The package: the variant, a manifest, vanilla's init.lua with a line of
# its own
cp -r "$here/apps/vanilla_voxel_physics" "$t/app"
rm -rf "$t/app/test"
cat > "$t/app/meta.json" <<'J'
{"author": "tester", "name": "vvp", "version": "1.0.0", "engine_api": 2,
	"license_code": "MIT", "license_media": "CC0-1.0", "base": "vanilla"}
J
mkdir -p "$t/app/main/client_lua"
{ cat "$here/apps/vanilla/main/client_lua/init.lua"
	echo 'log:info("init.lua: the variant'"'"'s own")'; } \
	> "$t/app/main/client_lua/init.lua"
"$b" aitta keygen "$t/key" > /dev/null 2>&1 || fail "keygen"
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>"$t/pack.log") ||
	fail "pack: $(cat "$t/pack.log")"
d=$t/u
mkdir -p "$d"
dir=$("$b" aitta install "$zip" "$d" 2>"$t/install.log") ||
	fail "install: $(cat "$t/install.log")"
[ "$dir" = "$d/installed/tester/vvp/1.0.0" ] || fail "installed at $dir"

BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=bi start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$dir" -D "$d" -C "$t/cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
grep -aq "A variant of .*/apps/vanilla" "$t/srv.log" ||
	fail "no base found: $(grep -a "loader" "$t/srv.log" | tail -2) ($t/srv.log)"
printf '%s\n' "wait_log 120000 load: the world is in" "delay 1000" "quit" > "$t/cmds"
run_client 60 "$t/cli.log" timeout 300 "$b" -C "$t/c" -D "$t/cu" -w 800x500 \
	-l 3 -o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" -c @"$t/cmds" ||
	fail "the drive ($t/cli.log)"
grep -aq "client_lua: main: .*init.lua (the variant's)" "$t/srv.log" ||
	fail "the server did not serve the variant's init.lua ($t/srv.log)"
grep -aq "init.lua: the variant's own" "$t/cli.log" ||
	fail "the client did not run the variant's init.lua ($t/cli.log)"
grep -aq "menu.lua\|pause.lua" "$t/srv.log" ||
	fail "vanilla's other client_lua files not served ($t/srv.log)"
ls -d "$d"/apps/tester.vvp/saves/bi > /dev/null 2>&1 ||
	fail "the save is not the variant's: $(ls "$d/apps" 2>&1)"
echo "PASS: an installed variant finds vanilla among the shipped apps, plays with one client_lua file of its own, and keeps its own save"
# vim: set noet ts=4 sw=4:
