#!/bin/bash
# tier: quick
# cost: ~1 min (2026-10-14)
# covers: apps/luanti_glue_test/** builtin/luanti/session.h builtin/luanti/client_lua/client.lua builtin/luanti/client_lua/module.lua builtin/luanti/lua/json.lua builtin/luanti/lua_bindings.h
# [LUANTI_APP_GLUE]: an app that is a Luanti game in a few dozen lines --
# apps/luanti_glue_test runs minimal_game and the module's client loop.
# A client joins, walks, digs the floor and places what it dug; the app's
# C++ sets the player's hp through the bridge's call and reads 5 back
# (7, less the 2 of the punch the call also gives), and hears the punch through
# on_punchplayer's emit; the loop's HUD stage is the app's stub.
#   apps/luanti_glue_test/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp luanti_glue; t=$CHECK_TMP
start_server "$t/srv.log" "glue: the world is up" 300 auto \
	"$here/Build/bin/buildat_server" -m "$here/apps/luanti_glue_test" \
	-D "$t/srv" -C "$t/srv.cache" -l 3 || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
printf '%s\n' "wait_log 120000 hud stub:" "delay 3000" "look 0 -30" \
	"keydown w" "delay 1200" "keyup w" "delay 500" \
	"mouse_down left" "delay 3000" "mouse_up left" "delay 500" \
	"look 0 -45" "delay 300" "mouse_click right" "delay 1500" "screenshot $t/shot.png" "quit" > "$t/cmds"
run_client 60 "$t/cli.log" timeout 300 "$here/Build/bin/buildat" -C "$t/c" \
	-D "$t/u" -w 800x500 -l 3 -o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" \
	-c @"$t/cmds" || fail "the drive ($t/cli.log)"
sleep 1
grep -aq "glue: set_hp 7 answered {\"hp\": *5}" "$t/srv.log" ||
	fail "the call: $(grep -a "set_hp" "$t/srv.log" | tail -1) ($t/srv.log)"
grep -aq "glue: punched .*\"damage\": *2" "$t/srv.log" ||
	fail "no punch event ($t/srv.log)"
first=$(grep -a "glue: at" "$t/srv.log" | head -1 | sed 's/.*glue: at //')
last=$(grep -a "glue: at" "$t/srv.log" | tail -1 | sed 's/.*glue: at //')
[ -n "$first" ] && [ "$first" != "$last" ] || fail "no walk: $first, $last ($t/srv.log)"
dug=$(grep -a "glue: dug " "$t/srv.log" | head -1 | sed 's/.*glue: dug //')
[ -n "$dug" ] || fail "nothing dug ($t/srv.log)"
grep -aq "glue: placed $dug" "$t/srv.log" || fail "$dug not placed back ($t/srv.log)"
grep -aq "hud stub: " "$t/cli.log" || fail "the HUD stage not the stub ($t/cli.log)"
echo "walked $first to $last, dug and placed $dug; $(grep -a "set_hp 7" "$t/srv.log" | tail -1 | sed 's/.*glue: //')"
echo "PASS: an app of a few dozen lines plays minimal_game through the module's loop and bridge"
# vim: set noet ts=4 sw=4:
