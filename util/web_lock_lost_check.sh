#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-11)
# covers: apps/vanilla/main/client_lua/init.lua extensions/luanti_client/init.lua
# [WEB_LOCK_LOST]: on the desktop web, the world with the mouse and no
# pointer lock opens the pause menu, and the mouse turns the view only
# while the lock is held. Vanilla (the minimal game) in Chrome at
# 1200x800 by mouse, a fixture logging the look as it changes. Headless
# Chrome grants no pointer lock, so the page's is a stand-in: the
# canvas's requestPointerLock and the document's exitPointerLock set
# document.pointerLockElement and send pointerlockchange, and a request
# after an Escape is refused until the next click, as a browser does.
#   - a click off the pause menu the web starts with: the lock held, a
#     mouse move turns the view;
#   - the inventory opened and closed by Escape: the pause menu opens;
#     mouse moves turn nothing;
#   - a click off the menu: the lock held again, a move turns the view;
#   - the lock let go (as a browser's Escape does): the pause menu at once
#     (Urho3D gives the game the Escape the browser kept).
# simplified: luanti_client's same rule is not driven; a real browser's
# lock is read by hand.
#   util/web_lock_lost_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null || { echo "SKIP: no Chrome"; exit 0; }
[ -f "$here/web/buildat.wasm" ] || { echo "SKIP: no web/ (util/build_web.sh)"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp web_lock_lost; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/s
mkdir -p "$d/apps/vanilla/saves/wl/luanti" "$d/shared"
cat > "$d/shared/fixture.lua" <<'L'
local last
core.register_globalstep(function()
	for _, player in ipairs(core.get_connected_players()) do
		local look = string.format("%.2f %.2f", player:get_look_horizontal(),
				player:get_look_vertical())
		if look ~= last then
			last = look
			core.log("action", "lock_check: look " .. look)
		end
	end
end)
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0})
	player:set_inventory_formspec("size[8,4]list[current_player;main;0,0;8,4;]")
	core.after(3, function() core.chat_send_player(name, "lock_check: ready") end)
end)
L
printf '%s\n' "enable_damage = false" "$WEB_WORLD_MT" > "$d/apps/vanilla/saves/wl/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=wl \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 60 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 -W "$here/web" || fail "the server"
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
# A move every 200 ms, the last given a second for its look to reach the
# server; the other waits are settles after a line: the world and the
# pause menu up after the ready, the lock asked for in the frames after
# the mouse mode changes
moves='["mouse", 600, 400], ["wait", 200], ["mouse", 700, 420], ["wait", 200],
 ["mouse", 800, 440], ["wait", 200], ["mouse", 900, 460], ["wait", 1000]'
cat > "$t/steps.json" <<J
[
 ["nav", "\${URL}"],
 ["waitlog", "lock_check: ready", 120], ["wait", 2000],
 ["eval", "$(echo "$stub" | tr "\n" " ")"],
 ["click", 100, 700], ["waitlog", "pause: a press off the menu", 10],
 ["waitlog", "mouse mode 1 ", 10], ["wait", 500],
 ["eval", "'lock ' + !!document.pointerLockElement"],
 $moves,
 ["key", "i"], ["waitlog", "mouse visible .a form opened", 10],
 ["key", "Escape"], ["waitlog", "the pointer lock is not held: paused .not given", 10],
 ["eval", "'lock ' + !!document.pointerLockElement"],
 $moves,
 ["shot", "\${OUT}/paused.png"],
 ["click", 100, 700], ["waitlog", "pause: a press off the menu", 10],
 ["waitlog", "mouse mode 1 ", 10], ["wait", 500],
 ["eval", "'lock ' + !!document.pointerLockElement"],
 $moves,
 ["eval", "document.exitPointerLock()"], ["waitlog", "mouse visible .a form opened", 10]
]
J
WEB_DRIVE_VIEWPORT=1200x800 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" chrome vanilla "$t/steps.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the drive ($(tail -2 "$t/drive.txt"))"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
locks=$(grep -ao '^eval: "lock [a-z]*"' "$t/drive.txt" | sed 's/eval: "lock //; s/"//' | tr '\n' ' ')
[ "$locks" = "true false true " ] || fail "the lock: \"$locks\", not \"true false true\" ($t/drive.txt)"
grep -aq "the pointer lock is not held: paused (not given)" "$t/drive/page.log" ||
	fail "no pause on the lock not given ($t/drive/page.log)"
# Lost: Urho3D gives the game the Escape the browser kept, which opens
# the menu; this rule's own "(lost)" is for a loss with no Escape
sed -n "/$(grep -a "pause: a press off the menu" "$t/drive/page.log" | tail -1 | cut -c1-19)/,\$p" \
	"$t/drive/page.log" | grep -aq "mouse visible (a form opened)" ||
	fail "no pause on the lock lost ($t/drive/page.log)"
# The times, as seconds of the day: the pause, the click off it after, and
# each look the server got
secs(){ awk '{split($3, a, ":"); print a[1] * 3600 + a[2] * 60 + a[3], $0}'; }
paused=$(grep -a "the pointer lock is not held: paused (not given)" "$t/drive/page.log" | tail -1 | secs | cut -d' ' -f1)
off=$(grep -a "pause: a press off the menu" "$t/drive/page.log" | tail -1 | secs | cut -d' ' -f1)
grep -a "lock_check: look" "$t/srv.log" | secs | cut -d' ' -f1 > "$t/looks.txt"
python3 - "$paused" "$off" "$t/looks.txt" <<'PY' || fail "the looks ($t/srv.log, $t/drive/page.log)"
import sys
paused, off = float(sys.argv[1]), float(sys.argv[2])
looks = [float(l) for l in open(sys.argv[3]) if l.strip()]
before = [x for x in looks if x < paused]
between = [x for x in looks if paused + 0.5 < x < off]
after = [x for x in looks if off < x]
print("looks: %d before the pause, %d while paused, %d after" % (len(before) - 1, len(between), len(after)))
assert len(before) > 1 and not between and after
PY
echo "PASS: on the web a lock not held pauses, the view turns only with the lock"
