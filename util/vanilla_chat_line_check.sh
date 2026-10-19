#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-19)
# covers: extensions/luanti_client/res/chat_line.lua builtin/luanti/client_lua/client.lua
# [VANILLA_CHAT_TOUCH]: vanilla's Luanti chat line is luanti_client's
# (res/chat_line.lua). In vanilla's world (the minimal game), T opens it:
#   - natively with the mouse at 1000x600: in the screen's lower half,
#     above the hotbar; Return sends;
#   - natively on a touchscreen at 1000x600: at the top; a tap on its Send
#     sends (where Send is, the line says as it opens: a first run reads
#     it, a second taps it);
#   - in Chrome as a phone (400x800, density 2, touch) under a stand-in
#     keyboard of half the screen (buildatKeyboard.test, [CHAT_FIELD_TOUCH]'s
#     way): the line ends above the keyboard.
# The server's on_chat_message logs what reached it.
#   util/vanilla_chat_line_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp vanilla_chat_line; t=$CHECK_TMP
trap check_cleanup EXIT
cat > "$t/fixture.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0})
	core.after(3, function() core.chat_send_player(name, "chat_line: ready") end)
end)
core.register_on_chat_message(function(name, message)
	core.log("action", "chat_line: got " .. message)
end)
L
d=$t/s
mkdir -p "$d/apps/vanilla/saves/cl/luanti" "$d/shared"
cp "$t/fixture.lua" "$d/shared/"
printf '%s\n' "enable_damage = false" "$WEB_WORLD_MT" > "$d/apps/vanilla/saves/cl/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=cl \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 180 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 -W "$here/web" || fail "the server"
CHECK_PIDS+=($SERVER_PID)
client(){ # name, env..., then the sequence on stdin
	local n=$1; shift
	cat > "$t/$n.cmds"
	env "$@" timeout 200 "$here/Build/bin/buildat" -C "$t/${n}c" -D "$t/${n}u" \
		-s 127.0.0.1:$SERVER_PORT -w 1000x600 -u 1 -l 3 -o sound_mute=1 \
		-c @"$t/$n.cmds" > "$t/$n.log" 2>&1
	grep -a "Command sequence failed" "$t/$n.log" && fail "$n: the drive ($t/$n.log)"
}
# "y0 y1 h sx sy" of the line's last opening in a log
line_at(){ grep -aoP 'chat: the line opened, y \K\d+ to \d+ of \d+; Send at \d+, \d+' "$1" |
	tail -1 | sed 's/ to / /; s/ of / /; s/; Send at / /; s/,//'; }
got(){ grep -aq "chat_line: got $1" "$t/srv.log" || fail "the server did not get \"$1\" ($t/srv.log)"; }

# The desktop's: in the lower half, Return sends
client desk <<C
wait_log 60000 chat: chat_line: ready
delay 1000
keypress T
wait_log 5000 chat: the line opened
delay 300
text hello desk
keypress Return
delay 1000
quit
C
read -r y0 y1 h _ _ <<< "$(line_at "$t/desk.log")"
[ -n "${h:-}" ] && [ "$y0" -gt $((h / 2)) ] || fail "desk: the line at y ${y0:-?} of ${h:-?} ($t/desk.log)"
got "hello desk"
echo "ok: the desktop's line in the lower half (y $y0 to $y1 of $h), Return sent"

# A touchscreen's: at the top; Send where the line says it is
client touch1 BUILDAT_TOUCH=1 <<C
wait_log 60000 chat: chat_line: ready
delay 1000
keypress T
wait_log 5000 chat: the line opened
delay 300
quit
C
read -r y0 y1 h sx sy <<< "$(line_at "$t/touch1.log")"
[ -n "${h:-}" ] && [ "$y0" -lt 20 ] || fail "touch: the line at y ${y0:-?} of ${h:-?} ($t/touch1.log)"
client touch2 BUILDAT_TOUCH=1 <<C
wait_log 60000 chat: chat_line: ready
delay 1000
keypress T
wait_log 5000 chat: the line opened
delay 300
text hello finger
tap $sx $sy
wait_log 5000 chat: Send
delay 1000
quit
C
got "hello finger"
echo "ok: a touchscreen's line at the top (y $y0 to $y1 of $h), its Send tapped at $sx, $sy sent"

if ! command -v "${CHROME:-google-chrome}" > /dev/null || [ ! -f "$here/web/buildat.wasm" ]; then
	echo "PASS: native; the web skipped (no Chrome or web/)"
	exit 0
fi
check_build web
# 400x800 CSS pixels, a stand-in keyboard of 400 over the bottom half; the
# 2 s after the ready line the world drawn, the 500 ms after the keyboard
# the page laid out under it
cat > "$t/web.json" <<'J'
[
 ["nav", "${URL}?log=3"],
 ["waitlog", "chat: chat_line: ready", 120], ["wait", 2000],
 ["eval", "buildatKeyboard.test = 400"], ["wait", 500],
 ["key", "t"], ["waitlog", "chat: the line opened", 10],
 ["wait", 500],
 ["shot", "${OUT}/keyboard.png"]
]
J
TOUCH=1 WEB_DRIVE_VIEWPORT=400x800@2 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" chrome vanilla "$t/web.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the web drive ($(tail -2 "$t/drive.txt"))"
read -r y0 y1 h _ _ <<< "$(line_at "$t/drive/page.log")"
# The keyboard's top is at half the page: the line's bottom at or above it
[ -n "${h:-}" ] && [ "$((y1 * 2))" -le "$h" ] ||
	fail "web: the line at y ${y0:-?} to ${y1:-?} of ${h:-?}, under the keyboard ($t/drive/page.log)"
echo "PASS: vanilla's chat line is luanti_client's: the desktop's above the hotbar, Return sends; a touchscreen's at the top, its Send sends; on a phone above a keyboard of half the screen (y $y0 to $y1 of $h; $t/drive/keyboard.png)"
