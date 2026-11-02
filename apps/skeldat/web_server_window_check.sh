#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-30)
# covers: builtin/accounts/client_lua/accounts.lua extensions/ui_utils/init.lua
# [WEB_LOCKED_CLICKS_ACCOUNTS]: a window that wants clicks frees the
# pointer lock. skeldat on the desktop web (Chrome at 1200x800, a flat
# world, a server no launcher started, so its admin is asked about ntfy
# pushes after each login until they answer for good; web_lock_check's
# pointer lock stand-in in the page): the admin made with the setup code
# answers Later and closes the how-to-play; the page loaded again and the
# same admin logged in, the game takes the lock under the Server window's
# question, which lets it go, and a click on its "Don't add" is the
# button's (it closed the window as a click off it, unanswered, while the
# lock was held). The window closed: the lock back, no pause menu.
#   apps/skeldat/web_server_window_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null || skip "no Chrome"
[ -f "$here/web/buildat.wasm" ] || skip "no web/ (util/build_web.sh)"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp sk_web_sw; t=$CHECK_TMP
trap check_cleanup EXIT
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
stub=$(echo "$stub" | tr "\n" " ")
lock='["eval", "'"'"'lock '"'"' + !!document.pointerLockElement"]'
# The window's buttons at 1200x800: Later 667,217, Don't add 891,217; the
# how-to-play's Close 600,756 (web_lock_check's)
cat > "$t/steps.json" <<J
[
 ["nav", "\${URL}"], ["eval", "$stub"],
 ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "\${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Enter"], ["waitlog", "Joined as webboss", 30],
 ["waitlog", "server window: the page ntfy", 30],
 ["waitlog_any", "pause: how to play shown", 60], ["wait", 1500],
 ["click", 667, 217], ["waitlog", "server window: closed", 10], ["wait", 500],
 ["click", 600, 756], ["waitlog", "pause: the menu closed", 10], ["wait", 1500],
 ["nav", "\${URL}"], ["eval", "$stub"],
 ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Enter"],
 ["waitlog", "Joined as webboss", 30], ["waitlog", "server window: the page ntfy", 30],
 ["waitlog", "mouse mode 1 ", 30], ["waitlog", "mouse mode 0 .the Server window.", 10],
 ["wait", 1500], $lock,
 ["click", 891, 217], ["waitlog", "server window: closed", 10],
 ["waitlog", "mouse mode 1 ", 10], ["wait", 1500], $lock
]
J
BUILDAT_SKELDAT_WORLD=sw BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_TIME=0.5 \
	BUILDAT_SKELDAT_SIZE="1 -1 0" BUILDAT_SKELDAT_TERRAIN=flat BUILDAT_SKELDAT_SKELETONS=0 \
	WEB_DRIVE_VIEWPORT=1200x800 \
	"$here/util/web_drive.sh" chrome skeldat "$t/steps.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the drive ($(tail -2 "$t/drive.txt"))"
locks=$(grep -ao '^eval: "lock [a-z]*"' "$t/drive.txt" | sed 's/eval: "lock //; s/"//' | tr '\n' ' ')
[ "$locks" = "false true " ] ||
	fail "the lock: \"$locks\", not \"false true\" ($t/drive.txt)"
grep -aq "webboss answered the ntfy question: never" "$t/drive/server.log" ||
	fail "the click missed \"Don't add\" ($t/drive/server.log)"
# The second login's: no pause for the lock the window let go
awk '/accounts: ntfy asked/ { b = "" } { b = b $0 "\n" } END { printf "%s", b }' "$t/drive/page.log" |
	grep -aq "pause: the menu shown\|pause: the pointer lock" &&
	fail "the pause menu under the window ($t/drive/page.log)"
echo "PASS: on the web the Server window over skeldat's mouse look lets the pointer lock go, its button takes the click, and the lock comes back after it"
