#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-20)
# covers: src/client/web/index.html src/client/app.cpp
# [WEB_TAP_KEYBOARD]: a tap on a field focuses its stand-in input inside
# the tap's own touchend, which is when a phone's browser opens its
# on-screen keyboard. On a floorplanner server with an account, in Chrome
# as a phone (TOUCH=1): a listener the drive puts on the canvas reads
# document.activeElement right after each touchend's handlers ("after the
# tap: <id>"); the name field tapped is "text", the password "password";
# each tapped twice in a row, three rounds ([WEB_TAP_KEYBOARD_IOS]): a
# focus() inside every tap, the focused one's too, and each still focused
# and shown 10 frames on, not blurred in between;
# the page logs "a field focused in the tap" for both; the name and the
# password typed into the stand-ins log in.
#   util/web_tap_keyboard_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null || skip "no Chrome"
[ -f "$here/web/buildat.wasm" ] || skip "no web/ (util/build_web.sh)"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp web_tap_keyboard; t=$CHECK_TMP
trap check_cleanup EXIT
server(){ # log, extra args...
	local l=$1; shift
	start_server "$l" "STATUS Listening" 90 auto "$here/Build/bin/buildat_server" \
		-m "$here/apps/floorplanner" -D "$t/s" -C "$t/s.cache" -l 3 "$@" ||
		fail "the server ($l)"
	CHECK_PIDS+=($SERVER_PID)
}
# The account, made by a scripted client with the setup code
server "$t/s1.log"
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/s1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/s1.log)"
printf 'wait_log_any 20000 Joined as erin\nquit\n' > "$t/seq"
BUILDAT_FP_NAME=erin BUILDAT_FP_PASSWORD=rightpass123 BUILDAT_FP_CREATE=1 \
BUILDAT_FP_CODE=$code run_client 40 "$t/mk.log" timeout 40 \
	"$here/Build/bin/buildat" -o launch_ui=launch_menu -s 127.0.0.1:$SERVER_PORT \
	-D "$t/mk" -C "$t/mk.cache" -w 640x480 -u 1 -l 3 -o sound_mute=1 -c @"$t/seq" ||
	fail "the account's client ($t/mk.log): $(grep -a "Command sequence failed" "$t/mk.log" | tail -1)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
server "$t/s2.log" -W "$here/web"
# CSS pixels in web_drive's 1200x800 as a phone: the name field and the
# password (FIELD_NAME, FIELD_PASS, "x y")
read nx ny <<< "${FIELD_NAME:-600 345}"
read px py <<< "${FIELD_PASS:-600 454}"
# [WEB_TAP_KEYBOARD_IOS] And 10 frames on: what has the focus, whether the
# tapped stand-in is still shown, and its blurs in between (iOS closes the
# keyboard on a blur, and opens none for the engine's later focus)
watch="document.querySelector('canvas').addEventListener('touchend', function(){ var e = document.activeElement, b = 0, n = 0, h = function(){ b++; }; window.inTap = 0; console.log('in the tap: ' + (e.id || e.tagName)); if(!window.tenOn) return; e.addEventListener('blur', h); (function f(){ if(++n < 10) return requestAnimationFrame(f); e.removeEventListener('blur', h); console.log('ten frames on: ' + (document.activeElement.id || document.activeElement.tagName) + ' ' + e.style.display + ', ' + b + ' blurs'); })(); }); 'watching'"
# And a focus() inside each tap, also on a stand-in that has the focus
# already: iOS opens its keyboard only for a focus in the tap, and the
# login window's own focus on the name came from a frame
watch="window.inTap = 0; document.addEventListener('touchend', function(){ window.inTap = 1; }, true); var fo = HTMLElement.prototype.focus; HTMLElement.prototype.focus = function(o){ if(window.inTap && window.tenOn) console.log('focus() in the tap: ' + this.id); return fo.call(this, o); }; $watch"
# The tester got a keyboard after tapping for a while: each field tapped
# twice in a row, three rounds
taps=""
for i in 1 2 3; do
	for xy in "$nx, $ny" "$nx, $ny" "$px, $py" "$px, $py"; do
		taps="$taps [\"tap\", $xy], [\"waitlog\", \"ten frames on: \", 5], [\"wait\", 200],"
	done
done
cat > "$t/steps.json" <<J
[
 ["nav", "\${URL}"],
 ["waitlog", "hello: Starport", 60], ["wait", 2000],
 ["eval", "$watch"],
 ["tap", 20, 780], ["wait", 500],
 ["shot", "$t/login.png"],
 ["eval", "window.tenOn = true; 'on'"],
$taps
 ["tap", $nx, $ny], ["waitlog", "in the tap: ", 5], ["wait", 500],
 ["type", "erin"], ["wait", 300],
 ["tap", $px, $py], ["waitlog", "in the tap: ", 5], ["wait", 500],
 ["type", "rightpass123"], ["key", "Enter"],
 ["waitlog", "Joined as erin", 30]
]
J
TOUCH=1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" "$here/util/web_drive.sh" chrome \
	floorplanner "$t/steps.json" "$t/drive" > "$t/drive.txt" 2>&1 ||
	fail "the drive: $(tail -2 "$t/drive.txt") ($t/drive/page.log)"
after=$(grep -ao "^in the tap: [A-Za-z]*" "$t/drive/page.log" | sed 's/in the tap: //' | tail -2 | tr '\n' ' ')
echo "focused in the taps: $after"
on=$(grep -a "^ten frames on: " "$t/drive/page.log" | sed 's/ten frames on: //' | head -12 | sort | uniq -c | tr -s ' ' | tr '\n' ';')
echo "10 frames on: $on"
[ "$on" = " 6 password block, 0 blurs; 6 text block, 0 blurs;" ] ||
	fail "a tapped stand-in not kept 10 frames: $on ($t/drive/page.log)"
in=$(grep -a "^focus() in the tap: " "$t/drive/page.log" | sed 's/focus() in the tap: //' | head -12 | tr '\n' ' ')
echo "focus() in the taps: $in"
[ "$in" = "$(printf 'text text password password %.0s' 1 2 3)" ] ||
	fail "a tap without a focus() in it: $in ($t/drive/page.log)"
[ "$after" = "text password " ] || fail "the stand-ins not focused in the taps: $after ($t/drive/page.log)"
[ $(grep -ac "a field focused in the tap: \(text\|password\)" "$t/drive/page.log") -ge 2 ] ||
	fail "no \"a field focused in the tap\" ($t/drive/page.log)"
echo "PASS: a tap on a field focuses its stand-in in the tap's own event and keeps it 10 frames on, unblurred; the login typed through them"
