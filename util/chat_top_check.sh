#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-11)
# covers: builtin/accounts/client_lua/accounts.lua src/client/web/index.html
# [CHAT_FIELD_TOUCH]: the chat is a console over the screen's top half. In
# vanilla's world (the minimal game), the chat page logs where it is and
# where its field row is, and ui_utils's keyboard_page line marks the
# focused item:
#   - natively by finger at 1000x500 (the touch controls' Chat) and by
#     mouse at 600x800 (the pause menu's Chat...): the message field is
#     focused and the window ends at or above the screen's middle;
#   - in Chrome as a phone (400x800, density 2, touch): the same by the
#     touch Chat; the page turned to 800x400 makes it again at the new
#     size; a stand-in keyboard (buildatKeyboard.test) taller than half the
#     screen puts the field row first with its text kept, and one of half
#     or less puts it back last; [TOUCH_CHAT_KEYBOARD] the page's stand-in
#     field is never read-only over those remakes (a phone takes its
#     keyboard down for a read-only field, and no tap brings it back).
# simplified: the phone's own keyboard is not driven; the stand-in is
# what the page's reader returns.
#   util/chat_top_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp chat_top; t=$CHECK_TMP
trap check_cleanup EXIT
cat > "$t/fixture.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0})
	core.after(3, function() core.chat_send_player(name, "chat_top: ready") end)
end)
L
d=$t/s
mkdir -p "$d/apps/vanilla/saves/ct/luanti" "$d/shared"
cp "$t/fixture.lua" "$d/shared/"
printf '%s\n' "enable_damage = false" "$WEB_WORLD_MT" > "$d/apps/vanilla/saves/ct/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=ct \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 60 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 -W "$here/web" || fail "the server"
CHECK_PIDS+=($SERVER_PID)
# The chat page's lines in a log: "<top> <bottom> <screen> first|last", and
# the keyboard_page lines of it
pages(){ grep -aoP 'chat page: y \K\d+ to \d+ of \d+, the field row \w+' "$1" |
	sed 's/ to / /; s/ of / /; s/, the field row / /'; }
# A chat page at the top half with the field focused
top_half(){ # name, log
	local p
	p=$(pages "$2" | head -1)
	read -r y0 y1 h row <<< "$p"
	[ -n "$p" ] && [ "$y1" -le $((h / 2)) ] && [ "$row" = last ] ||
		fail "$1: the page at \"$p\" ($2)"
	grep -aqE "keyboard_page: (.*\|)?\*LineEdit\|Send\|Back" "$2" ||
		fail "$1: the field not focused: $(grep -a keyboard_page: "$2" | tail -1) ($2)"
}
client(){ # name, size, env..., then the sequence on stdin
	local n=$1 s=$2; shift 2
	cat > "$t/$n.cmds"
	env "$@" timeout 200 "$here/Build/bin/buildat" -C "$t/${n}c" -D "$t/${n}u" \
		-s 127.0.0.1:$SERVER_PORT -w "$s" -u 1 -l 4 -o sound_mute=1 \
		-c @"$t/$n.cmds" > "$t/$n.log" 2>&1
	grep -a "Command sequence failed" "$t/$n.log" && fail "$n: the drive ($t/$n.log)"
}
# The touch controls' Chat at (850, 94). The delay after the chat page's
# line: the focus line keyboard_page logs in the frames after it
client touch 1000x500 BUILDAT_TOUCH=1 <<C
wait_log 60000 chat: chat_top: ready
delay 2000
tap 850 94
wait_log 10000 chat page: y
delay 500
quit
C
top_half touch "$t/touch.log"
client mouse 600x800 <<C
wait_log 60000 chat: chat_top: ready
delay 2000
keypress Escape
wait_log 5000 pause: the menu shown
click Button "Chat..."
wait_log 10000 chat page: y
delay 500
quit
C
top_half mouse "$t/mouse.log"
echo "ok: natively by finger at 1000x500 and by mouse at 600x800"
if ! command -v "${CHROME:-google-chrome}" > /dev/null || [ ! -f "$here/web/buildat.wasm" ]; then
	echo "PASS: native; the web skipped (no Chrome or web/)"
	exit 0
fi
# 400x800 CSS pixels: the touch controls' Chat at (325, 47). The waits
# are settles: the 2 s after the ready line the world drawn, the 500 ms
# after the typed "hello" the field drawn with it, the 500 ms after the
# keyboard's line the page drawn above it
cat > "$t/web.json" <<'J'
[
 ["nav", "${URL}?log=4"],
 ["waitlog", "chat: chat_top: ready", 120], ["wait", 2000],
 ["tap", 325, 47], ["waitlog", "chat page: y", 10],
 ["type", "hello"], ["wait", 500],
 ["shot", "${OUT}/upright.png"],
 ["viewport", 800, 400], ["waitlog", "chat page: y", 10],
 ["eval", "window.ro = 0, new MutationObserver(function(){ if(document.getElementById('text').readOnly) ro++; }).observe(document.getElementById('text'), {attributes: true, attributeFilter: ['readonly']}), 'watching'"],
 ["eval", "buildatKeyboard.test = 300"], ["waitlog", "chat page: y", 10],
 ["wait", 500],
 ["shot", "${OUT}/keyboard.png"],
 ["eval", "buildatKeyboard.test = 150"], ["waitlog", "chat page: y", 10],
 ["eval", "'text ' + document.getElementById('text').value"],
 ["eval", "'readonly ' + ro"]
]
J
TOUCH=1 WEB_DRIVE_VIEWPORT=400x800@2 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" chrome vanilla "$t/web.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the web drive ($(tail -2 "$t/drive.txt"))"
top_half web "$t/drive/page.log"
got=$(pages "$t/drive/page.log" | awk '{print $3, $4}' | tr '\n' ' ')
# Upright, turned, a tall keyboard, a short one
[[ "$got" =~ ^([0-9]+)\ last\ ([0-9]+)\ last\ ([0-9]+)\ first\ ([0-9]+)\ last\ $ ]] &&
	[ "${BASH_REMATCH[2]}" -lt "${BASH_REMATCH[1]}" ] ||
	fail "web: the pages \"$got\" ($t/drive/page.log)"
grep -aq '^eval: "text hello"' "$t/drive.txt" || fail "web: the text not kept ($t/drive.txt)"
# [TOUCH_CHAT_KEYBOARD] The page made again under the keyboard: its field
# never read-only, which takes a phone's keyboard down
grep -aq '^eval: "readonly 0"' "$t/drive.txt" ||
	fail "web: the field read-only in a remake: $(grep -a '^eval: "readonly' "$t/drive.txt") ($t/drive.txt)"
echo "PASS: the chat at the screen's top half with its field focused, natively and in Chrome; it follows the screen turning, and a keyboard over more than half puts the field row first"
