#!/bin/bash
# tier: full
# needs: pixels
# cost: ~2 min (2026-10-11)
# covers: src/client/web/index.html
# [ROTATE_ASPECT]: the 3D view follows the screen turning. Vanilla (the
# minimal game) in Chrome as a phone (873x393 CSS pixels at 2.75), the
# player facing a magenta node 4 ahead; each step reads the canvas's
# drawing size and measures the node's face, square within 5 % (a stale
# aspect is 4 times off):
#   - sideways, turned upright, turned back (Chrome's own resize);
#   - a phone's order: the canvas laid out at another size with no resize
#     event, then only an orientationchange, and back the same way: the
#     drawing buffer follows.
#   util/rotate_aspect_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null || { echo "SKIP: no Chrome"; exit 0; }
[ -f "$here/web/buildat.wasm" ] || { echo "SKIP: no web/ (util/build_web.sh)"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp rotate_aspect; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/s
mkdir -p "$d/apps/vanilla/saves/ra/luanti" "$d/shared"
cat > "$d/shared/fixture.lua" <<'L'
core.register_node(":rot:square", {tiles = {"[fill:16x16:#ff00ff"}, light_source = 14})
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0})
	local function put()
		local p = core.get_player_by_name(name)
		if not p then return end
		p:set_pos({x = 0, y = 40, z = 0})
		p:set_look_horizontal(0)
		p:set_look_vertical(0)
		core.set_node({x = 0, y = 41, z = 4}, {name = "rot:square"})
	end
	core.after(2, put)
	core.after(4, function() put(); core.chat_send_player(name, "ra: ready") end)
end)
L
printf '%s\n' "enable_damage = false" "$WEB_WORLD_MT" > "$d/apps/vanilla/saves/ra/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=ra \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 -W "$here/web" || fail "the server"
CHECK_PIDS+=($SERVER_PID)
cv='["eval", "\"cv \" + Module.canvas.width + \"x\" + Module.canvas.height"]'
# The canvas laid out at w x h CSS pixels with no resize, then a turn's
# event alone (a rule, as emscripten clears the canvas's inline size)
lay(){ echo "[\"eval\", \"var e = document.getElementById('lag') || document.head.appendChild(document.createElement('style')); e.id = 'lag'; e.textContent = '${1:-}' ? 'canvas { width: ${1:-}px !important; height: ${2:-}px !important }' : ''; window.dispatchEvent(new Event('orientationchange')); 'laid'\"]"; }
# A resize or a layout is waited for by the client's "screen mode: WxH"
# (its ScreenMode, the canvas at its new size); the half second after it
# and the 2 s after the world's settle line are settles, the frames at the
# new size drawn
cat > "$t/steps.json" <<J
[
 ["nav", "\${URL}"],
 ["waitlog", "chat: ra: ready", 120],
 ["waitlog", "settle: 0 to mesh, [0-9]+ chunks in scene, 0 undrawn within 2", 60], ["wait", 2000],
 $cv, ["shot", "\${OUT}/1.png"],
 ["viewport", 393, 873], ["waitlog", "screen mode: ", 10], ["wait", 500],
 $cv, ["shot", "\${OUT}/2.png"],
 ["viewport", 873, 393], ["waitlog", "screen mode: ", 10], ["wait", 500],
 $cv, ["shot", "\${OUT}/3.png"],
 $(lay 300 600), ["waitlog", "screen mode: ", 10], ["wait", 500],
 $cv, ["shot", "\${OUT}/4.png"],
 $(lay), ["waitlog", "screen mode: ", 10], ["wait", 500],
 $cv, ["shot", "\${OUT}/5.png"]
]
J
WEB_DRIVE_VIEWPORT=873x393@2.75 TOUCH=1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" chrome vanilla "$t/steps.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the drive: $(tail -2 "$t/drive.txt")"
got=$(grep -ao '^eval: "cv [0-9x]*"' "$t/drive.txt" | sed 's/eval: "cv //; s/"//' | tr '\n' ' ')
[ "$got" = "2400x1080 1080x2400 2400x1080 825x1650 2400x1080 " ] ||
	fail "the drawing sizes \"$got\" ($t/drive.txt)"
python3 - "$t/drive" <<'PY' || fail "the node's face ($t/drive)"
import sys
from PIL import Image
import numpy as np
for n in range(1, 6):
    a = np.array(Image.open("%s/%d.png" % (sys.argv[1], n)).convert("RGB")).astype(int)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    # The face toward the player, not the brighter top
    ys, xs = np.nonzero((r > 100) & (r < 200) & (b > 80) & (g < 50))
    assert len(xs), "%d: no face" % n
    w, h = xs.max() - xs.min() + 1, ys.max() - ys.min() + 1
    print("%d: the face %dx%d" % (n, w, h))
    assert abs(w / h - 1) < 0.05, "%d: the face %dx%d" % (n, w, h)
PY
echo "PASS: the drawing buffer follows a turn, also one whose resize came before the layout, and the 3D stays unstretched"
