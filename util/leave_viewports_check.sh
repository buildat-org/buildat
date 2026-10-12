#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-12)
# covers: src/client/app_lua.h
# [LEAVE_VIEWPORTS]: a game that leaves its viewports set when it is left.
#   1. A dev app drawing a red field through set_preferred_viewports(),
#      left by its Escape: the launch menu comes up with no red behind it
#      and "0 viewports" said by the leave; at render scale 1 unscripted
#      (the renderer's own viewports), scripted at 1 and 0.5 (the texture).
#   2. Vanilla's minimal game, left from its pause menu: "0 viewports".
#   util/leave_viewports_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp leave_viewports; t=$CHECK_TMP
a=$t/u/dev_apps/redfield
mkdir -p "$a/main/client_lua" "$a/launcher"
cat > "$a/meta.json" <<J
{"author": "tester", "name": "redfield", "version": "0.1.0", "engine_api": 2,
	"kind": "app", "license_code": "MIT", "license_media": "CC0-1.0",
	"description": "a red field"}
J
cat > "$a/main/meta.json" <<J
{"engine_api": 2, "disable_cpp": true, "client_main": "init.lua", "dependencies": [
	{"module": "network"}, {"module": "client_lua"}, {"module": "client_data"}]}
J
echo 'return function(ctx) return {{id = "play", label = "redfield",
	run = function() ctx.launch{app = "redfield"} end}} end' > "$a/launcher/init.lua"
# Kept in globals, as genvaders keeps them, and never handed back
cat > "$a/main/client_lua/init.lua" <<'L'
local magic = require("buildat/extension/urho3d")
scene = magic.Scene()
scene:CreateComponent("Octree")
local zone = scene:CreateComponent("Zone")
zone.boundingBox = magic.BoundingBox(magic.Vector3(-1000, -1000, -1000),
		magic.Vector3(1000, 1000, 1000))
zone.fogColor = magic.Color(1, 0, 0)
local camera = scene:CreateChild("Camera"):CreateComponent("Camera")
viewport = magic.Viewport:new(scene, camera)
magic.set_preferred_viewports({viewport})
buildat.Logger("redfield"):info("redfield drawn")
magic.SubscribeToEvent("KeyDown", function(_, data)
	if data:GetInt("Key") == magic.KEY_ESCAPE then
		buildat.leave()
	end
end)
-- Unscripted, it leaves on its own
if buildat.get_env("BUILDAT_REDFIELD_LEAVE") == "1" then
	local t = 0
	magic.SubscribeToEvent("Update", function(_, data)
		t = t + data:GetFloat("TimeStep")
		if t > 3 and t < 100 then
			t = 100
			buildat.leave()
		end
	end)
end
L
# red <png>: the share of pure red pixels
red(){ python3 -c '
import sys, zlib, struct
d = open(sys.argv[1], "rb").read(); p = 8; idat = b""
while p < len(d):
    n, k = struct.unpack(">I4s", d[p:p + 8])
    if k == b"IHDR": w, h, bd, ct = struct.unpack(">IIBB", d[p + 8:p + 18])
    if k == b"IDAT": idat += d[p + 8:p + 8 + n]
    p += 12 + n
bpp = 4 if ct == 6 else 3
raw = zlib.decompress(idat); s = w * bpp + 1
prev = bytearray(w * bpp); hits = 0
for y in range(h):
    f = raw[y * s]; row = bytearray(raw[y * s + 1:(y + 1) * s])
    for i in range(len(row)):
        a = row[i - bpp] if i >= bpp else 0; b = prev[i]; c = prev[i - bpp] if i >= bpp else 0
        if f == 1: row[i] = (row[i] + a) & 255
        elif f == 2: row[i] = (row[i] + b) & 255
        elif f == 3: row[i] = (row[i] + (a + b) // 2) & 255
        elif f == 4:
            pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
            row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    hits += sum(1 for x in range(0, len(row), bpp) if row[x] > 200 and row[x + 1] < 40 and row[x + 2] < 40)
    prev = row
print(hits * 100 // (w * h))' "$1"; }

# 1. A scripted run always draws onto a texture of its logical size; the
# renderer's own viewports, render scale 1, only unscripted, where the
# app leaves by itself and the leave's line is all there is to read
BUILDAT_REDFIELD_LEAVE=1 timeout 60 "$here/Build/bin/buildat" -o launch_ui=launch_menu \
	-a dev/redfield/play -D "$t/u" -C "$t/c" -w 800x600 -l 3 -o sound_mute=1 -o render_scale=1 \
	> "$t/plain.log" 2>&1 &
pid=$!
CHECK_PIDS+=($pid)
wait_for_log "$t/plain.log" "what is left after leave_to_menu" 50 || fail "no leave unscripted ($t/plain.log)"
kill $pid; wait $pid 2>/dev/null
grep -aq "redfield drawn" "$t/plain.log" || fail "redfield not run unscripted ($t/plain.log)"
grep -a "what is left after leave_to_menu" "$t/plain.log" | grep -q "; 0 viewports" ||
	fail "viewports left unscripted: $(grep -a "what is left after" "$t/plain.log")"
for scale in 1 0.5; do
	cat > "$t/$scale.cmds" <<C
wait_log_any 20000 rows in
delay 1500
text redfield
delay 1000
keypress Return
wait_log 30000 redfield drawn
delay 2000
screenshot $t/in_$scale.png
keypress Escape
wait_log 10000 what is left after leave_to_menu
delay 2000
screenshot $t/left_$scale.png
quit
C
	timeout 120 "$here/Build/bin/buildat" -o launch_ui=launch_menu -D "$t/u" -C "$t/c" \
		-w 800x600 -l 3 -o sound_mute=1 -o render_scale=$scale -c @"$t/$scale.cmds" \
		> "$t/$scale.log" 2>&1
	grep -aq "Command sequence complete" "$t/$scale.log" || fail "the drive at $scale ($t/$scale.log)"
	grep -a "what is left after leave_to_menu" "$t/$scale.log" | grep -q "; 0 viewports" ||
		fail "viewports left at $scale: $(grep -a "what is left after" "$t/$scale.log")"
	[ "$(red "$t/in_$scale.png")" -gt 50 ] || fail "no red field drawn at $scale ($t/in_$scale.png)"
	[ "$(red "$t/left_$scale.png")" = 0 ] || fail "red behind the menu at $scale ($t/left_$scale.png)"
done
echo "ok: a dev app's field gone with it at render scale 1 and 0.5"

# 2.
d=$t/v
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=lv start_server "$t/mk.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" -C "$t/vc" -l 3 || fail "lv ($t/mk.log)"
wait_for_log "$t/mk.log" "The world is up" 60 || fail "lv not up ($t/mk.log)"
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
echo "enable_damage = false" >> "$d/apps/vanilla/saves/lv/luanti/world.mt"
cat > "$t/v.cmds" <<C
wait_log_any 20000 , first lv
delay 1500
click Text "lv"
wait_log 120000 load: the world is in
delay 1500
keypress Escape
delay 1000
click Button "Leave the game"
wait_log 10000 what is left after leave_to_menu
delay 1000
quit
C
timeout 200 "$here/Build/bin/buildat" -o launch_ui=launch_menu -D "$d" -C "$t/vc1" \
	-w 1100x600 -l 3 -o sound_mute=1 -c @"$t/v.cmds" > "$t/v.log" 2>&1
for p in $(pgrep -f "[b]uildat_server .*-D $d"); do kill $p; done
grep -aq "Command sequence complete" "$t/v.log" || fail "the vanilla drive ($t/v.log)"
grep -a "what is left after leave_to_menu" "$t/v.log" | grep -q "; 0 viewports" ||
	fail "viewports left by vanilla: $(grep -a "what is left after" "$t/v.log")"
echo "PASS: a left game's viewports go with it: a dev app's at two render scales, vanilla's"
