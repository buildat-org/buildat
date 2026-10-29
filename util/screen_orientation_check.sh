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
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null || skip "no Chrome"
[ -f "$here/web/buildat.wasm" ] || skip "no web/ (util/build_web.sh)"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
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
printf '%s\n' "enable_damage = false" "$WEB_WORLD_MT" > "$d/apps/vanilla/saves/so/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=so \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 -W "$here/web" || fail "the server"
CHECK_PIDS+=($SERVER_PID)
# The page is not the launcher's own client, so it joins by the login
# ([GUEST_NAME_REUSE]): an account made with the server's setup code, its
# first admin. By the keyboard, as a tap would take the page fullscreen
# (and unlock) before the first pick: from the name, Tab past the
# password and Join to "Create a new account"; the make page's fields in
# Tab order and "Create account" after them. The frames after the login
# line and the press are the page drawn and focused.
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | head -1 | cut -d' ' -f3)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
# The dropdown at (244, 466), below View range, an admin's menu with Who
# may talk above (2026-10-29); its Auto, Landscape and Portrait at y 481,
# 495 and 509. After a line, settles of up to 1 s: the popup
# placed in the frames after it says it is open; after a pick, the page's
# fullscreen, which the pick asks for and the browser enters a moment later
# (the menu's line and the start's "so: ready" the same: the frames after)
state='["eval", "Module.buildatOrientation + (document.fullscreenElement ? \" fullscreen\" : \" windowed\")"]'
cat > "$t/steps.json" <<J
[
 ["nav", "\${URL}"],
 ["waitlog", "accounts: the login page shown", 120], ["frames", 5],
 ["key", "Tab"], ["key", "Tab"], ["key", "Tab"], ["key", "Enter"], ["frames", 5],
 ["type", "soplayer"], ["key", "Tab"], ["type", "sopass12"], ["key", "Tab"],
 ["type", "sopass12"], ["key", "Tab"], ["type", "$code"], ["key", "Tab"],
 ["key", "Enter"], ["waitlog", "Joined as soplayer", 30],
 ["waitlog", "chat: so: ready", 120], ["wait", 1000],
 ["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["wait", 500],
 ["tap", 244, 466], ["waitlog", "dropdown_[0-9]+ open", 10], ["wait", 300], ["tap", 232, 495],
 ["waitlog", "pause: screen orientation landscape", 10], ["wait", 1000],
 $state,
 ["tap", 244, 466], ["waitlog", "dropdown_[0-9]+ open", 10], ["wait", 300], ["tap", 232, 509],
 ["waitlog", "pause: screen orientation portrait", 10], ["wait", 1000],
 $state,
 ["tap", 244, 466], ["waitlog", "dropdown_[0-9]+ open", 10], ["wait", 300], ["tap", 232, 481],
 ["waitlog", "pause: screen orientation auto", 10], ["wait", 1000],
 $state
]
J
TOUCH=1 WEB_DRIVE_VIEWPORT=400x800@2 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" chrome vanilla "$t/steps.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the drive: $(tail -2 "$t/drive.txt")"
got=$(grep -ao '^eval: "[a-z]* [a-z]*"' "$t/drive.txt" | sed 's/eval: "//; s/"//' | tr '\n' ',')
[ "$got" = "landscape fullscreen,portrait fullscreen,auto windowed," ] ||
	fail "the states \"$got\" ($t/drive.txt)"
# From the menu on: the world's start takes the page fullscreen (and so
# unlocks) when an input of the login's is still the page's activation
calls=$(sed -n '/pause: the menu shown/,$p' "$t/drive/page.log" |
	grep -ao "orientation: \(lock [a-z]*\|unlock\)" |
	sed 's/orientation: //' | uniq | tr '\n' ',')
[ "$calls" = "lock landscape,lock portrait,unlock," ] ||
	fail "the page's calls \"$calls\" ($t/drive/page.log)"
echo "PASS: the pause menu's pick sets the preference, the page locks it while fullscreen and keeps fullscreen with the menu up; Auto unlocks and leaves"
