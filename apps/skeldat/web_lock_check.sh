#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-19)
# covers: apps/skeldat/main/client_lua/init.lua apps/skeldat/main/client_lua/pause.lua
# [SKELDAT_WEB_LOCK_LOST]: skeldat on the desktop web, the world with the
# mouse and no pointer lock opens the pause menu. Chrome at 1200x800, a
# flat world, the page's pointer lock the stand-in of
# util/web_lock_lost_check.sh (headless Chrome grants none): its
# requestPointerLock and exitPointerLock, and a request after an Escape
# refused until the next click, as a browser does.
#   - the opening dialog closed: the lock held;
#   - the lock let go: the pause menu (Urho3D gives the game the Escape
#     the browser kept, which opens it; the rule's own "lost" is for a
#     loss with no Escape), no lock;
#   - Continue clicked: the lock held again, nothing opened;
#   - the inventory opened and closed by its key: the lock held, no pause;
#   - opened and closed by Escape: the lock asked for is refused, and in
#     0.5 s "pause: the pointer lock not given" and the pause menu;
#   - [SKELDAT_PAUSE_CLOSE] Escape in it: it stays, "pause: Escape kept on
#     the web"; a click off it: closed, the lock held.
# Natively nothing changes (the rule is the web's).
#   apps/skeldat/web_lock_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null || { echo "SKIP: no Chrome"; exit 0; }
[ -f "$here/web/buildat.wasm" ] || { echo "SKIP: no web/ (util/build_web.sh)"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp sk_web_lock; t=$CHECK_TMP
trap check_cleanup EXIT
BUILDAT_SKELDAT_WORLD=wl BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_TIME=0.5 \
	BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SKELETONS=0 \
	start_server "$t/srv.log" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -u launcher=1 -A 127.0.0.1 \
	-m "$here/apps/skeldat" -D "$t/d" -C "$t/d.cache" -l 3 -W "$here/web" ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
stub="(function(){ var held = null, refuse = false;
 Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }});
 function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); }
 document.addEventListener('keydown', function(e){ if(e.key === 'Escape') refuse = true; }, true);
 document.addEventListener('mousedown', function(){ refuse = false; }, true);
 HTMLCanvasElement.prototype.requestPointerLock = function(){
  if(refuse){ document.dispatchEvent(new Event('pointerlockerror')); return Promise.reject(new Error('refused')); }
  if(held !== this) set(this); return Promise.resolve(); };
 document.exitPointerLock = function(){ if(held) set(null); };
 return 'stub'; })()"
lock='["eval", "'"'"'lock '"'"' + !!document.pointerLockElement"]'
cat > "$t/steps.json" <<J
[
 ["nav", "\${URL}"],
 ["waitlog", "pause: how to play shown", 180], ["wait", 1500],
 ["eval", "$(echo "$stub" | tr "\n" " ")"],
 ["click", 600, 761], ["waitlog", "mouse mode 1 ", 10], ["wait", 1500],
 $lock,
 ["eval", "document.exitPointerLock()"], ["waitlog", "pause: the menu shown", 10],
 ["wait", 1000], $lock,
 ["shot", "\${OUT}/paused.png"],
 ["click", 600, 256], ["waitlog", "pause: the menu closed", 10],
 ["waitlog", "mouse mode 1 ", 10], ["wait", 1500], $lock,
 ["key", "e"], ["waitlog", "inventory: .* opened", 10], ["wait", 1000],
 ["key", "e"], ["waitlog", "inventory: closed", 10], ["wait", 1500], $lock,
 ["key", "e"], ["waitlog", "inventory: .* opened", 10], ["wait", 1000],
 ["key", "Escape"], ["waitlog", "pause: the pointer lock not given", 10],
 ["wait", 1000], $lock,
 ["shot", "\${OUT}/not_given.png"],
 ["key", "Escape"], ["waitlog", "pause: Escape kept on the web", 10], ["wait", 500],
 ["click", 100, 700], ["waitlog", "pause: a click off the menu", 10],
 ["waitlog", "mouse mode 1 ", 10], ["wait", 1500], $lock
]
J
WEB_DRIVE_VIEWPORT=1200x800 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" chrome skeldat "$t/steps.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the drive ($(tail -2 "$t/drive.txt"))"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
locks=$(grep -ao '^eval: "lock [a-z]*"' "$t/drive.txt" | sed 's/eval: "lock //; s/"//' | tr '\n' ' ')
[ "$locks" = "true false true true false true " ] ||
	fail "the lock: \"$locks\", not \"true false true true false true\" ($t/drive.txt)"
# [SKELDAT_PAUSE_CLOSE] Escape kept the menu: after it, the pause's next
# lines the click off it and the close
after=$(sed -n '/pause: Escape kept on the web/,$p' "$t/drive/page.log" |
	grep -ao "pause: [a-z ]*" | sed -n '2,3p' | tr '\n' ',')
[ "$after" = "pause: a click off the menu,pause: the menu closed," ] ||
	fail "after the Escape kept: \"$after\" ($t/drive/page.log)"
# The pause menu twice, the lock lost and not given: none after Continue
# or the inventory closed by its key
shown=$(grep -ac "pause: the menu shown" "$t/drive/page.log")
[ "$shown" = 2 ] && [ "$(grep -ac "pause: the pointer lock" "$t/drive/page.log")" = 1 ] ||
	fail "the pause menu $shown times, or the lock's rule not once ($t/drive/page.log)"
echo "PASS: on the web a lost or refused pointer lock opens skeldat's pause menu, which Escape keeps and a click off closes"
