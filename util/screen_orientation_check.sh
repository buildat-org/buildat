#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-11)
# covers: src/client/web/index.html apps/vanilla/main/client_lua/pause.lua extensions/launch_menu/preferences.lua
# [SCREEN_ORIENTATION]: the screen orientation preference, picked in
# vanilla's pause menu on a touchscreen. Vanilla (the minimal game) in
# Chrome as a phone (400x800, density 2, touch), the pause menu by
# Escape, its "Screen orientation" dropdown tapped and a choice tapped:
#   - Landscape: the page fullscreen with the menu up (a lock held through
#     it), its lock("landscape") logged and buildatOrientation landscape;
#   - Portrait: lock("portrait");
#   - Auto: unlock(), and the page out of fullscreen with the menu up.
# simplified: headless Chrome refuses the lock itself; the turn is read on
# a phone.
#   util/screen_orientation_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null || { echo "SKIP: no Chrome"; exit 0; }
[ -f "$here/web/buildat.wasm" ] || { echo "SKIP: no web/ (util/build_web.sh)"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp screen_orientation; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/s
mkdir -p "$d/apps/vanilla/saves/so/luanti" "$d/shared"
cat > "$d/shared/fixture.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0})
	core.after(3, function() core.chat_send_player(name, "so: ready") end)
end)
L
echo "enable_damage = false" > "$d/apps/vanilla/saves/so/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=so \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 -W "$here/web" || fail "the server"
CHECK_PIDS+=($SERVER_PID)
# CSS pixels: the dropdown at (244, 465), its Auto, Landscape and Portrait
# at y 480, 494 and 508
state='["eval", "Module.buildatOrientation + (document.fullscreenElement ? \" fullscreen\" : \" windowed\")"]'
cat > "$t/steps.json" <<J
[
 ["nav", "\${URL}"],
 ["waitlog", "chat: so: ready", 240], ["wait", 2000],
 ["key", "Escape"], ["wait", 2000],
 ["tap", 244, 465], ["wait", 1000], ["tap", 232, 494], ["wait", 2000],
 $state,
 ["tap", 244, 465], ["wait", 1000], ["tap", 232, 508], ["wait", 2000],
 $state,
 ["tap", 244, 465], ["wait", 1000], ["tap", 232, 480], ["wait", 2000],
 $state
]
J
TOUCH=1 WEB_DRIVE_VIEWPORT=400x800@2 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" chrome vanilla "$t/steps.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the drive: $(tail -2 "$t/drive.txt")"
got=$(grep -ao '^eval: "[a-z]* [a-z]*"' "$t/drive.txt" | sed 's/eval: "//; s/"//' | tr '\n' ',')
[ "$got" = "landscape fullscreen,portrait fullscreen,auto windowed," ] ||
	fail "the states \"$got\" ($t/drive.txt)"
calls=$(grep -ao "orientation: \(lock [a-z]*\|unlock\)" "$t/drive/page.log" |
	sed 's/orientation: //' | uniq | tr '\n' ',')
[ "$calls" = "lock landscape,lock portrait,unlock," ] ||
	fail "the page's calls \"$calls\" ($t/drive/page.log)"
echo "PASS: the pause menu's pick sets the preference, the page locks it while fullscreen and keeps fullscreen with the menu up; Auto unlocks and leaves"
