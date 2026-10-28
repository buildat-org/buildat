#!/bin/bash
# tier: full
# cost: ~4 min (2026-10-28)
# covers: extensions/ui_utils/init.lua apps/demo_aggregate/main/client_lua/init.lua apps/demo_digger/main/client_lua/init.lua
# [WEB_MOUSE_CAPTURE]: ui_utils.mouse_look on the desktop web, in
# demo_aggregate and demo_digger, each in Firefox and Chrome at 1200x800.
# The page's pointer lock is util/web_lock_lost_check.sh's stand-in
# (headless browsers grant none): requestPointerLock and exitPointerLock
# set document.pointerLockElement and send pointerlockchange.
#   - the start: the lock asked for with no click is not given, and in
#     0.5 s "Click to continue";
#   - a click: the lock held, a mouse move turns the view;
#   - the lock let go (as a browser's Escape does): paused at once, the
#     Escape Urho3D hands the game not taken as the game's (both leave on
#     it), moves turn nothing;
#   - a click: the lock again, the view turns;
#   - demo_aggregate's B menu: no lock while it is up, the lock again as
#     it closes.
#   util/web_mouse_look_check.sh [firefox|chrome ...]
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
browsers=${*:-firefox chrome}
for b in $browsers; do
	case $b in
	firefox) command -v "${FIREFOX:-firefox}" > /dev/null || skip "no Firefox" ;;
	chrome) command -v "${CHROME:-google-chrome}" > /dev/null || skip "no Chrome" ;;
	*) fail "unknown browser $b" ;;
	esac
done
[ -f "$here/web/buildat.wasm" ] || skip "no web/ (util/build_web.sh)"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp web_mouse_look; t=$CHECK_TMP
trap check_cleanup EXIT
stub="(function(){ var held = null;
 Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }});
 function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); }
 HTMLCanvasElement.prototype.requestPointerLock = function(){ if(held !== this) set(this); return Promise.resolve(); };
 document.exitPointerLock = function(){ if(held) set(null); };
 return 'stub'; })()"
lock='["eval", "'"'"'lock '"'"' + !!document.pointerLockElement"]'
moves='["mouse", 600, 400], ["wait", 100], ["mouse", 700, 420], ["wait", 100],
 ["mouse", 800, 440], ["wait", 100], ["mouse", 900, 460], ["wait", 300]'
for app in demo_aggregate demo_digger; do
	start_server "$t/$app.srv.log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -u launcher=1 -A 127.0.0.1 \
		-m "$here/apps/$app" -D "$t/$app.d" -C "$t/$app.cache" -l 3 \
		-W "$here/web" || fail "$app's server ($t/$app.srv.log)"
	CHECK_PIDS+=($SERVER_PID)
	menu=""
	want="true false true"
	if [ $app = demo_aggregate ]; then
		menu=', ["key", "b"], ["waitlog", "mouse mode 0 ", 10], ["wait", 300], '"$lock"',
 ["key", "b"], ["waitlog", "mouse mode 1 ", 10], ["wait", 300], '"$lock"
		want="$want false true"
	fi
	cat > "$t/$app.json" <<J
[
 ["nav", "\${URL}"],
 ["waitlog", "mouse look: paused, the pointer lock not given", 300],
 ["eval", "$(echo "$stub" | tr "\n" " ")"],
 ["click", 600, 400], ["waitlog", "mouse look: continued", 10], $lock,
 $moves, ["waitlog", "mouse look: turning", 10],
 ["eval", "document.exitPointerLock()"],
 ["waitlog", "mouse look: paused, the pointer lock lost", 10], $lock,
 $moves, ["shot", "\${OUT}/paused.png"],
 ["click", 600, 400], ["waitlog", "mouse look: continued", 10], $lock,
 $moves, ["waitlog", "mouse look: turning", 10]$menu
]
J
	for b in $browsers; do
		WEB_DRIVE_VIEWPORT=1200x800 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
			"$here/util/web_drive.sh" $b $app "$t/$app.json" "$t/$app.$b" \
			> "$t/$app.$b.txt" 2>&1 ||
			fail "$app in $b: the drive ($t/$app.$b.txt: $(tail -2 "$t/$app.$b.txt" | tr '\n' ' '))"
		locks=$(grep -ao '^eval: "lock [a-z]*"' "$t/$app.$b.txt" |
			sed 's/eval: "lock //; s/"//' | tr '\n' ' ')
		[ "$locks" = "$want " ] ||
			fail "$app in $b: the lock \"$locks\", not \"$want\" ($t/$app.$b.txt)"
		log=$t/$app.$b/page.log
		# The Escape of the lock let go is not the game's: both leave on it
		! grep -aq "KEY_ESCAPE pressed" "$log" ||
			fail "$app in $b: the lock's Escape reached the game ($log)"
		# Nothing turned while paused: no "turning" between the lost
		# lock's pause and the continue after it
		[ -z "$(sed -n '/pointer lock lost/,/mouse look: continued/p' "$log" |
				grep -a "mouse look: turning")" ] ||
			fail "$app in $b: the view turned while paused ($log)"
		echo "$app in $b: ok"
	done
	kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
done
echo "PASS: mouse_look on the web: paused with the lock not given or lost, a click takes it back and the view turns ($browsers; demo_aggregate, demo_digger)"
