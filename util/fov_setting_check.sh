#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-18)
# covers: src/client/app.cpp src/client/app_lua.h client/api.lua extensions/launch_menu/preferences.lua
# [FOV_SETTING]: fov.<app>, a field of view per app, and
# buildat.declare_fov. A client-only dev app declares "skeldat" (72 by
# default) and logs what it gets: 72 with no setting, and its own
# set_preference refused (a server's code); the game settings window's
# Video section's Field of view row (a scripted click) set to 90 calls its
# on_change, the preference 90 and "luanti" unset; -o fov.skeldat=80 gives
# 80, and the launch menu's Engine settings list it and reset it. A scripted run neither reads nor writes settings.json, so a last run
# has no command sequence and is stopped once it has logged: the file's
# "fov": {"skeldat": 90} read (90, "luanti" 72) and written back. The
# parser's range is app.cpp's own self test (500 refused).
#   util/fov_setting_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp fov; t=$CHECK_TMP
cd "$here/Build"
client(){ timeout 240 bin/buildat -w 1100x1000 -u 1 -l 3 -o sound_mute=1 "$@"; }
seen(){ grep -aq "$1" "$2" || fail "$3 (no \"$1\" in $2: $(grep -a "Command seq\|click:\|failed" "$2" | tail -2))"; }

a=$t/u/dev_apps/fovcheck
mkdir -p "$a/launcher" "$a/main/client_lua"
echo '{"kind": "app", "name": "fovcheck", "version": "0.1.0", "engine_api": 2}' > "$a/meta.json"
echo '{"engine_api": 2, "disable_cpp": true, "client_main": "init.lua", "dependencies": [{"module": "network"}, {"module": "client_lua"}, {"module": "client_data"}]}' > "$a/main/meta.json"
echo 'return function(ctx) return {{id = "play", label = "fovcheck", run = function() ctx.launch{app = "fovcheck"} end}} end' > "$a/launcher/init.lua"
cat > "$a/main/client_lua/init.lua" <<'L'
local log = buildat.Logger("fovcheck")
local magic = require("buildat/core/urho3d")
local fov = buildat.declare_fov("skeldat", 72, function(v)
	log:info("fovcheck: changed to " .. v)
end)
local ok = buildat.set_preference("fov.skeldat", 100)
log:info("fovcheck: skeldat " .. fov .. ", luanti " ..
		buildat.declare_fov("luanti", 72) .. ", set by the app " .. tostring(ok))
-- The window's row is the last declaration's
buildat.declare_fov("skeldat", 72, function(v)
	log:info("fovcheck: changed to " .. v .. ", the preference " ..
			tostring(buildat.get_preference("fov.skeldat")) .. ", luanti's " ..
			tostring(buildat.get_preference("fov.luanti")))
end)
magic.SubscribeToEvent("KeyDown", function(_, d)
	if d:GetInt("Key") == magic.KEY_O then
		buildat.show_game_settings{}
	end
end)
L
cat > "$t/f1.cmds" <<C
wait_log 60000 fovcheck: skeldat
delay 1000
keypress O
wait_log 5000 Game settings shown
delay 1000
screenshot $t/window.png
click DropDownList "▼" 668 535
wait_log 5000 dropdown_
keypress Down
keypress Down
keypress Return
wait_log 5000 fovcheck: changed to 90
delay 500
quit
C
client -C "$t/c" -D "$t/u" -a dev/fovcheck/play -c @"$t/f1.cmds" > "$t/f1.log" 2>&1 ||
	fail "the first drive ($t/f1.log)"
seen "fovcheck: skeldat 72, luanti 72, set by the app false" "$t/f1.log" "not 72 with no setting, or the app set it"
seen "Game settings shown: .*fov.skeldat" "$t/f1.log" "no Field of view row"
seen "fovcheck: changed to 90, the preference 90, luanti's nil" "$t/f1.log" "the row did not set 90"
printf 'wait_log 60000 fovcheck: skeldat\nquit\n' > "$t/f2.cmds"
client -o fov.skeldat=80 -C "$t/c" -D "$t/u" -a dev/fovcheck/play -c @"$t/f2.cmds" > "$t/f2.log" 2>&1 ||
	fail "the -o run ($t/f2.log)"
seen "fovcheck: skeldat 80," "$t/f2.log" "-o fov.skeldat=80 not 80"
# The launch menu's Engine settings list it, and reset it
cat > "$t/f4.cmds" <<C
wait_log_any 60000 rows in
delay 500
text dis
wait_log 5000 rows for "dis"
keypress Return
wait_log 5000 Engine settings shown
delay 500
screenshot $t/engine.png
click Button "Field of view, skeldat: 80*"
wait_log 5000 engine settings: fov.skeldat reset
quit
C
client -o fov.skeldat=80 -C "$t/c" -D "$t/u" -c @"$t/f4.cmds" > "$t/f4.log" 2>&1 ||
	fail "the Engine settings drive ($t/f4.log)"
echo '{"sound_mute": true, "fov": {"skeldat": 90}}' > "$t/u/settings.json"
timeout 120 bin/buildat -w 1100x1000 -l 3 -C "$t/c" -D "$t/u" -a dev/fovcheck/play > "$t/f3.log" 2>&1 &
CHECK_PIDS+=($!)
wait_for_log "$t/f3.log" "fovcheck: skeldat" 60 || fail "the run with the file ($t/f3.log)"
kill -INT $!; wait $! 2>/dev/null
seen "fovcheck: skeldat 90, luanti 72," "$t/f3.log" "the file's 90 not read, or luanti's changed"
grep -q '"fov":{"skeldat":90}' "$t/u/settings.json" ||
	fail "not written back: $(cat "$t/u/settings.json")"
echo "PASS: 72 unset, the row to 90, -o 80, Engine settings' reset, the file's 90 read and written back"
