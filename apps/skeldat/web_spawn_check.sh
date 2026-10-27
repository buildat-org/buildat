#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-26)
# covers: apps/skeldat/main/players.h apps/skeldat/main/client_lua/init.lua apps/skeldat/main/client_lua/player.lua
# [SKELDAT_WEB_SPAWN_STUCK]: a spawn built over since it was found (here
# BUILDAT_SKELDAT_SPAWN one voxel into the ground) does not leave the
# player inside a voxel. Firefox at 1200x800 (its held keys), the page's
# pointer lock web_lock_check.sh's stand-in: the server lifts the place
# out of the wall, the client stands in no voxel once the voxels around
# have arrived, W held walks it 2 voxels off, and the server pulls it back
# into no wall. Before, it stood inside the ground voxel, pulled back to
# it once a second. The how-to-play closed by its Escape, as
# edge_walk_check.sh's: a click at Close's place missed it once the
# dialog grew ([SKELDAT_WEB_CLICKS]).
#   apps/skeldat/web_spawn_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
command -v "${FIREFOX:-firefox}" > /dev/null || skip "no Firefox"
[ -f "$here/web/buildat.wasm" ] || skip "no web/ (util/build_web.sh)"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp sk_web_spawn; t=$CHECK_TMP
trap check_cleanup EXIT
BUILDAT_SKELDAT_WORLD=sp BUILDAT_SKELDAT_SEED=2 BUILDAT_SKELDAT_SIZE="4 -1 0" \
	BUILDAT_SKELDAT_TIME=0.4 BUILDAT_SKELDAT_SPAWN="0 13 0" \
	start_server "$t/srv.log" "STATUS Listening" 300 auto \
	"$here/Build/bin/buildat_server" -u launcher=1 -A 127.0.0.1 \
	-m "$here/apps/skeldat" -D "$t/d" -C "$t/d.cache" -l 3 -W "$here/web" ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
stub="(function(){ var held = null;
 Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }});
 function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); }
 HTMLCanvasElement.prototype.requestPointerLock = function(){ if(held !== this) set(this); return Promise.resolve(); };
 document.exitPointerLock = function(){ if(held) set(null); };
 return 'stub'; })()"
cat > "$t/steps.json" <<J
[
 ["nav", "\${URL}"],
 ["eval", "$(echo "$stub" | tr "\n" " ")"],
 ["waitlog", "pause: how to play shown", 240], ["wait", 1000],
 ["key", "Escape"], ["waitlog", "pause: the menu closed", 10],
 ["holdkey", "w", 3000], ["waitlog", "skeldat: walked 2 from the placing", 10]
]
J
WEB_DRIVE_VIEWPORT=1200x800 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" firefox skeldat "$t/steps.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the drive ($(tail -2 "$t/drive.txt"))"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
lift=$(grep -ao "place (0.0, 13.0, 0.0) in a wall, lifted to y [0-9]*" "$t/srv.log")
stood=$(grep -ao "the voxels around arrived .*" "$t/drive/page.log" | head -1)
[ -n "$lift" ] || fail "the spawn in the ground not lifted ($t/srv.log)"
case "$stood" in *"inside no voxel") ;; *) fail "the player: '$stood' ($t/drive/page.log)" ;; esac
! grep -aq "pulled back .*in a wall" "$t/srv.log" ||
	fail "pulled back in a wall: $(grep -a "pulled back" "$t/srv.log" | head -1) ($t/srv.log)"
echo "PASS: a spawn in the ground: $lift; $stood; $(grep -ao "walked 2 from the placing.*" "$t/drive/page.log")"
