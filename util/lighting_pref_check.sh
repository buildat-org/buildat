#!/bin/bash
# tier: full
# cost: ~30 s (2026-11-03)
# covers: src/client/app.cpp src/client/app_lua.h client/api.lua extensions/launch_menu/preferences.lua
# [LIGHTING_PREF_LABELS]: the `lighting` preference's values, top first
# "Automatic" (unset), "Don't override" (game), "Cartoon (lightweight)".
# A client-only dev app logs get_preference("lighting") and
# "lighting_auto": unset, -o lighting=cartoon and -o lighting=auto (unset
# again). The launch menu's Engine settings with -o lighting=cartoon: the
# row reads Cartoon; its dropdown's top entry picked, the screen opened
# again reads Automatic (a screenshot each, kept on a failure), and the
# dev app launched from the menu then logs it unset. The parser's "auto"
# is app.cpp's own self test.
#   util/lighting_pref_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp lighting_pref; t=$CHECK_TMP
cd "$here/Build"
client(){ timeout 120 bin/buildat -w 1100x1000 -u 1 -l 3 -o sound_mute=1 \
	-C "$t/c" -D "$t/u" "$@"; }

a=$t/u/dev_apps/lpc
mkdir -p "$a/launcher" "$a/main/client_lua"
echo '{"kind": "app", "name": "lpc", "version": "0.1.0", "engine_api": 2}' > "$a/meta.json"
echo '{"engine_api": 2, "disable_cpp": true, "client_main": "init.lua", "dependencies": [{"module": "network"}, {"module": "client_lua"}, {"module": "client_data"}]}' > "$a/main/meta.json"
echo 'return function(ctx) return {{id = "play", label = "lpc", run = function() ctx.launch{app = "lpc"} end}} end' > "$a/launcher/init.lua"
echo 'buildat.Logger("lpc"):info("lpc: lighting " .. tostring(buildat.get_preference("lighting")) .. ", auto " .. tostring(buildat.get_preference("lighting_auto")))' > "$a/main/client_lua/init.lua"
printf 'wait_log 60000 lpc: lighting\nquit\n' > "$t/q.cmds"
got(){ client "$@" -a dev/lpc/play -c @"$t/q.cmds" > "$t/q.log" 2>&1 ||
	fail "the dev app run $* ($t/q.log)"
	grep -ao 'lpc: lighting [a-z].*' "$t/q.log" | sed 's/^lpc: //'; }
# Unset: software GL's default is cartoon, a GPU's game
v=$(got); case "$v" in "lighting game, auto true"|"lighting cartoon, auto true") ;;
	*) fail "unset: $v";; esac
v=$(got -o lighting=cartoon); [ "$v" = "lighting cartoon, auto false" ] ||
	fail "-o lighting=cartoon: $v"
v=$(got -o lighting=auto); case "$v" in *", auto true") ;;
	*) fail "-o lighting=auto: $v";; esac
echo "ok: lighting_auto true unset and with auto, false with cartoon"

cat > "$t/e.cmds" <<C
wait_log_any 60000 rows in
delay 500
text dis
wait_log 5000 rows for "dis"
keypress Return
wait_log 5000 Engine settings shown
delay 800
screenshot $t/cartoon.png
click DropDownList "▼" 705 507
wait_log 5000 dropdown_
delay 300
screenshot $t/list.png
keypress Up
keypress Up
keypress Return
delay 500
keypress Escape
delay 500
keypress Return
wait_log 5000 Engine settings shown
delay 800
screenshot $t/automatic.png
keypress Escape
delay 500
keypress BackSpace
keypress BackSpace
keypress BackSpace
text lpc
wait_log 5000 rows for "lpc"
keypress Return
wait_log 60000 lpc: lighting
quit
C
client -o lighting=cartoon -c @"$t/e.cmds" > "$t/e.log" 2>&1 ||
	fail "the Engine settings drive ($t/e.log)"
[ "$(grep -ac "extensio: Engine settings shown" "$t/e.log")" = 2 ] ||
	fail "Engine settings not opened twice ($t/e.log)"
grep -aq "lpc: lighting [a-z]*, auto true" "$t/e.log" ||
	fail "Automatic did not unset it: $(grep -ao 'lpc: lighting [a-z].*' "$t/e.log")"
echo "ok: Engine settings' Lighting row from Cartoon to Automatic: the dev app launched from the menu then reads it unset"
echo "PASS: the lighting preference's Automatic is unset; its labels"
