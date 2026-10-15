#!/bin/bash
# tier: full
# cost: 3min (2026-10-09)
# covers: extensions/launch_menu/preferences.lua client/api.lua builtin/accounts/client_lua/accounts.lua apps/floorplanner/main/client_lua/pause.lua apps/vanilla/main/client_lua/pause.lua
# [GAME_SETTINGS]: buildat.show_game_settings{}, the client's settings
# window a game opens.
#   1. A client-only dev app made here opens it with a section of its own
#      and one whose draw fails: the failure is said in the section and the
#      rest is drawn. Its own row, the frame limit and its declared key
#      (on the keys' page, [SETTINGS_KEYS_PAGE]) are changed; Escape
#      closes it, the key is read again in on_close
#      and works in the game; after a restart the key and the row are as
#      set (a -c run saves no preferences, so the frame limit is not).
#   2. Floor planner's Client settings... is the window, its rows the first
#      section; Server... opens the Server window and Escape comes back;
#      Open to LAN opens it; Escape goes back to the pause menu.
#   3. Vanilla on the minimal game: the pause menu's Settings... has the
#      game's keys.
#   4. The web client (Firefox, util/web_drive.sh; skipped without it):
#      floorplanner's Client settings... with the web's rows.
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   util/game_settings_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
t=$(mktemp -d)
pids=
trap 'kill $pids 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here/Build"
client(){ timeout 240 bin/buildat -o launch_ui=launch_menu -w 1100x1000 -u 1 -l 3 -o sound_mute=1 "$@"; }
drove(){ grep -a "Command sequence failed\|run_client:" "$1" | tail -1; }
seen(){ grep -aq "$1" "$2" || fail "$3 (no \"$1\" in $2: $(grep -a "Command seq\|click:\|failed" "$2" | tail -2))"; }

a=$t/u/dev_apps/gscheck
mkdir -p "$a/launcher" "$a/main/client_lua"
echo '{"kind": "app", "name": "gscheck", "version": "0.1.0", "engine_api": 2}' > "$a/meta.json"
echo '{"engine_api": 2, "disable_cpp": true, "client_main": "init.lua", "dependencies": [{"module": "network"}, {"module": "client_lua"}, {"module": "client_data"}]}' > "$a/main/meta.json"
echo 'return function(ctx) return {{id = "play", label = "gscheck", run = function() ctx.launch{app = "gscheck"} end}} end' > "$a/launcher/init.lua"
cat > "$a/main/client_lua/init.lua" <<'L'
local log = buildat.Logger("gscheck")
local magic = require("buildat/core/urho3d")
local function keys()
	local k = buildat.declare_keys(nil, "gscheck",
			{{id = "jump", label = "Jump", default = "Space"}})
	return k and k.jump
end
local jump = keys()
log:info("gscheck: max_fps " .. tostring(buildat.get_preference("max_fps")) ..
		", jump " .. tostring(jump) .. ", own " .. tostring(buildat.storage_read("own")))
local function open()
	buildat.show_game_settings{on_close = function()
		jump = keys()
		log:info("gscheck: closed, jump " .. tostring(jump))
	end, sections = {{title = "Own", draw = function(w, ui)
		ui.dropdown("Own value", {{"one", "1"}, {"two", "2"}},
				buildat.storage_read("own") or "1", function(v)
			buildat.storage_write("own", v)
			log:info("gscheck: own " .. v)
		end)
	end}, {title = "Broken", draw = function() error("broken on purpose") end}}}
end
magic.SubscribeToEvent("KeyDown", function(_, d)
	local k = d:GetInt("Key")
	if k == magic.KEY_O then
		open()
	elseif jump and k == magic.input:GetKeyFromName(jump) then
		log:info("gscheck: jump pressed")
	end
end)
L
cat > "$t/g1.cmds" <<C
wait_log 60000 gscheck: max_fps
delay 1000
keypress O
wait_log 5000 Game settings shown
delay 1000
screenshot $t/g_window.png
click DropDownList "▼" 668 251
wait_log 5000 dropdown_
keypress Down
keypress Return
wait_log 5000 gscheck: own 2
click DropDownList "▼" 668 591
wait_log 5000 dropdown_
keypress Down
keypress Return
wait_log 5000 dropdown_
click Button "Key bindings..."
wait_log 5000 Game keys shown
delay 500
click Button "Jump"
wait_log 5000 Jump waits for a key
keypress J
wait_log 5000 Game keys: Jump = J
keypress Escape
wait_log 5000 Game keys closed
delay 500
keypress Escape
wait_log 5000 gscheck: closed
delay 500
keypress J
wait_log 5000 gscheck: jump pressed
quit
C
client -C "$t/cg" -D "$t/u" -a dev/gscheck/play -c @"$t/g1.cmds" > "$t/g1.log" 2>&1 ||
	fail "the gscheck drive ($t/g1.log: $(drove "$t/g1.log"))"
seen "Game settings shown: Own, Broken, Sound" "$t/g1.log" "the window did not show its sections"
seen "A settings section failed: .*broken on purpose" "$t/g1.log" "the broken section was not caught"
seen "gscheck: closed, jump J" "$t/g1.log" "the key was not rebound"
seen "gscheck: jump pressed" "$t/g1.log" "the rebound key did nothing"
printf 'wait_log 60000 gscheck: max_fps\nquit\n' > "$t/g2.cmds"
client -C "$t/cg" -D "$t/u" -a dev/gscheck/play -c @"$t/g2.cmds" > "$t/g2.log" 2>&1 ||
	fail "the gscheck restart ($t/g2.log: $(drove "$t/g2.log"))"
seen "gscheck: max_fps [0-9]*, jump J, own 2" "$t/g2.log" "the settings did not stay"

# The "dropdown_" waits above: ui_utils' "dropdown_<n> open" and
# "... closed", said as a popup opens and closes

# 2
cat > "$t/f.cmds" <<C
wait_log 60000 Plan picker:
delay 1000
text p1
keypress Return
wait_log 20000 Entered the plan p1
delay 2000
keypress Escape
wait_log 5000 Pause menu shown
click Button "Client settings..."
wait_log 5000 Game settings shown
delay 1000
screenshot $t/f_window.png
mouse_pos 550 500
$(for _ in $(seq 20); do echo "mouse_wheel -1"; done)
# the wheel's frames: the scrolls read before the click looks for its button
delay 500
click Button "Server..."
wait_log 5000 server window: Server Buildat
delay 1000
screenshot $t/f_server.png
keypress Escape
wait_log 5000 Game settings shown
delay 500
mouse_pos 550 500
$(for _ in $(seq 20); do echo "mouse_wheel -1"; done)
# the wheel's frames: the scrolls read before the click looks for its button
delay 500
click Button "Open to LAN"
wait_log 10000 Open to LAN: Open to the LAN at
delay 500
screenshot $t/f_lan.png
keypress Escape
wait_log 5000 Pause menu shown
delay 1000
screenshot $t/f_pause.png
click Button "Client settings..."
quit
C
BUILDAT_FP_NAME=owner client -C "$t/cf" -D "$t/uf" -a app/floorplanner/play \
	-c @"$t/f.cmds" > "$t/f.log" 2>&1 ||
	fail "floorplanner's drive failed ($t/f.log: $(drove "$t/f.log"))"
seen "Game settings shown: Floor planner, Sound" "$t/f.log" "floorplanner's window"
[ "$(grep -ac "Game settings shown: " "$t/f.log")" = 3 ] ||
	fail "Escape in the Server window did not come back to the settings"
seen "Open to LAN: listening at" "$t/f.log" "Open to LAN from the settings"

# 3
cat > "$t/v.cmds" <<C
wait_log 60000 the server put the player at
wait_log 60000 scene, 0 undrawn within 2
keypress Escape
wait_log 5000 pause: the menu shown
click Button "Settings..."
wait_log 5000 Game settings shown
delay 1000
screenshot $t/v_window.png
quit
C
# No damage: a fresh minimal world's player can fall to death before the
# Escape, which then only respawns
mkdir -p "$t/uv/apps/vanilla/saves/gsworld/luanti"
printf '%s\n' "enable_damage = false" "$WEB_WORLD_MT" > "$t/uv/apps/vanilla/saves/gsworld/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=gsworld start_server "$t/v.log" \
	"STATUS Listening" 120 auto bin/buildat_server -u launcher=1 -A 127.0.0.1 \
	-m ../apps/vanilla -D "$t/uv" -C "$t/cv" -l 3 ||
	fail "the vanilla server did not start"
pids="$SERVER_PID"
client -C "$t/cvc" -D "$t/uvc" -s 127.0.0.1:"$SERVER_PORT" \
	-c @"$t/v.cmds" > "$t/vc.log" 2>&1 ||
	fail "vanilla's drive ($t/vc.log: $(drove "$t/vc.log"))"
grep -aq "Game settings shown: View, Sound, .*, [1-9][0-9]* of the game's keys" "$t/vc.log" ||
	fail "vanilla's Settings... ($(grep -a "Game settings shown\|Command seq" "$t/vc.log" | tail -2))"
kill $pids; pids=

# 4
if command -v firefox > /dev/null && [ -f "$here/web/buildat.data" ]; then
	"$here/util/web_drive.sh" firefox floorplanner \
		"$here/util/game_settings_web.json" "$t/web" > "$t/web.log" 2>&1 ||
		fail "the web drive ($(tail -3 "$t/web.log"))"
	grep -aq "Game settings shown: Floor planner, Sound, .*web_address_bar, .*web_idle_fps" \
		"$t/web/page.log" || fail "the web's window has not the web's rows"
	web="; the web's has its rows"
else
	web="; the web skipped (no firefox or web build)"
fi
echo "PASS: the window with a game's sections, a failed one said, settings and a key kept; floorplanner's, with Server... and Open to LAN; vanilla's keys$web"
