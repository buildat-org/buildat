#!/bin/bash
# tier: full
# cost: ~70s (2026-10-30)
# covers: builtin/heightmap/** builtin/luanti_mapgen/**
# [HEIGHTMAP_TERRAIN], [HEIGHTMAP_REST]: builtin/heightmap through
# apps/sample_heightmap, a 1024x1024 map at a metre, five materials:
#   1. a fresh save generates seed 1234; the ball dropped on the pad comes
#      to rest its radius (1 m) over the ground, within 5 cm (Bullet's
#      heightfield where the map says); the map holds under MEM_MB (30)
#      of the server's memory (a Terrain's patches were ~87 MB), the
#      resident set before and after said;
#   2. a native client builds the terrain with five materials; C digs a
#      crater under the ball and the client's terrain reads the server's
#      new height there, the edit four rectangles of under EDIT_BYTES
#      (2000) bytes (whole chunks were ~26 KB); the screenshots show the
#      pad's gravel (material 4) before and the crater's dirt (3) after;
#      the frame time stays under LIMIT_MS (200) on average; the log has
#      the triangles and draw calls; the chunk hook saw the four chunks the
#      crater wrote once each;
#   3. the server started again on the save loads the map with the hash
#      it saved after the crater;
#   4. a second fresh save generates the same hash as the first;
#   5. with BUILDAT_HEIGHTMAP_SURFACE=valleys the map is Luanti's valleys
#      sampled (luanti_mapgen::surface_map, its rivers off), over 80 m of
#      relief; O's view over it is valleys.png, to look at.
#   apps/sample_heightmap/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
limit=${LIMIT_MS:-200}
check_tmp heightmap; t=$CHECK_TMP
serve(){
	start_server "$1" "STATUS Listening" 300 auto "$here/Build/bin/buildat_server" \
		-m "$here/apps/sample_heightmap" -D "$2" -l 3 || fail "the server ($1)"
	CHECK_PIDS+=($SERVER_PID)
}
stop(){ kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null; }
# The ground's colours in a screenshot: dirt (brown, skeldat's: lit, r/g
# 1.1-1.3 and g/b 1.05-1.2; sand's g/b is 1.35) and gravel (grey) pixels,
# "dirt grey"
ground(){
	python3 - "$1" <<'PY'
import sys
from PIL import Image
dirt = grey = 0
for r, g, b in Image.open(sys.argv[1]).convert("RGB").getdata():
	if r > 1.15 * g and 1.1 * b < g < 1.25 * b and r > 50:
		dirt += 1
	if abs(r - g) < 12 and abs(g - b) < 12 and r > 120:
		grey += 1
print(dirt, grey)
PY
}

# 1
serve "$t/s1.log" "$t/u1"
wait_for_log "$t/s1.log" "the ball rests" 60 || fail "the ball never rested ($t/s1.log)"
gen=$(grep -aoP "heightmap: generated 1024x1024 seed 1234 in [0-9]+ ms, hash \K[0-9a-f]+" "$t/s1.log")
[ -n "$gen" ] || fail "no generation ($t/s1.log)"
over=$(grep -aoP "the ball rests .*, \K[-0-9.]+(?= over the ground)" "$t/s1.log" | head -1)
echo "generated $gen; the ball rests $over over the ground"
awk -v o="$over" 'BEGIN{d = o - 1; exit !(d < 0.05 && d > -0.05)}' ||
	fail "the ball rests $over over the ground, not its radius 1 ($t/s1.log)"
held=$(grep -aoP "heightmap: the heightfield made: 1024x1024, 5 materials, \K[0-9.]+(?= MB held)" "$t/s1.log")
rss=$(grep -aoP "the server's memory: \K.*" "$t/s1.log")
# The resident set is said, not judged: network deflates web/ beside it
echo "the map holds $held MB; the server's resident set: $rss"
awk -v m="${held:-999}" -v l="${MEM_MB:-30}" 'BEGIN{exit !(m < l)}' ||
	fail "the map holds ${held:-?} MB, not under ${MEM_MB:-30} ($t/s1.log)"

# 2
printf '%s\n' "wait_log 60000 heightmap: terrain built" "delay 2500" \
	"screenshot $t/hills.png" "keypress C" "wait_log 20000 the crater reached this client" \
	"delay 4500" "screenshot $t/crater.png" "quit" > "$t/c.cmds"
run_client 60 "$t/c.log" timeout 180 "$here/Build/bin/buildat" \
	-s "127.0.0.1:$SERVER_PORT" -D "$t/cu" -w 1280x720 -l 3 \
	-o sound_mute=1 -c @"$t/c.cmds"
grep -a "heightmap: terrain built\|heightmap: terrain updated\|the crater\|frame .* ms average" "$t/c.log" | sed 's/^.*sample_heightmap: //;s/^.*heightmap: /heightmap: /'
grep -aq "heightmap: terrain built: 1024x1024 samples, 5 materials" "$t/c.log" ||
	fail "no terrain of five materials ($t/c.log)"
grep -aq "the crater reached this client" "$t/c.log" ||
	fail "the crater did not reach the client ($t/c.log)"
edit=$(grep -aoP "heightmap: terrain updated: \K[0-9]+ regions, [0-9]+ bytes, [0-9.]+ ms" "$t/c.log" | tail -1)
regions=$(echo "$edit" | awk '{print $1}')
bytes=$(echo "$edit" | awk '{print $3}')
[ "$regions" = 4 ] && [ "${bytes:-99999}" -lt "${EDIT_BYTES:-2000}" ] ||
	fail "the crater's edit: \"$edit\", not 4 regions under ${EDIT_BYTES:-2000} bytes ($t/c.log)"
read hills_dirt hills_grey < <(ground "$t/hills.png")
read crater_dirt crater_grey < <(ground "$t/crater.png")
echo "ground pixels (dirt grey): before the crater $hills_dirt $hills_grey, after $crater_dirt $crater_grey"
[ "${hills_grey:-0}" -ge 20000 ] || fail "no gravel pad drawn ($t/hills.png)"
[ "${hills_dirt:-1}" -lt 200 ] && [ "${crater_dirt:-0}" -ge 1000 ] ||
	fail "no dirt drawn in the crater ($t/hills.png, $t/crater.png)"
frame=$(grep -aoP "frame \K[0-9.]+(?= ms average)" "$t/c.log" | tail -1)
[ -n "$frame" ] || fail "no frame times ($t/c.log)"
awk -v f="$frame" -v l="$limit" 'BEGIN{exit !(f < l)}' ||
	fail "frames took $frame ms on average, not under $limit ($t/c.log)"
saved=$(grep -aoP "the map saved with hash \K[0-9a-f]+" "$t/s1.log" | tail -1)
# The pad's middle is a corner of four chunks: the hook saw each once
grep -aq "a crater at (512.00 512.00 [-0-9.]*): 4 chunks written" "$t/s1.log" ||
	fail "the crater's chunk hook: $(grep -ao "a crater at.*written" "$t/s1.log")"
stop

# 3
serve "$t/s2.log" "$t/u1"
wait_for_log "$t/s2.log" "heightmap: loaded" 30 || fail "no load ($t/s2.log)"
loaded=$(grep -aoP "heightmap: loaded \"main\": [0-9]+ chunks in [0-9]+ ms, hash \K[0-9a-f]+" "$t/s2.log")
echo "saved $saved, loaded $loaded"
[ -n "$saved" ] && [ "$saved" = "$loaded" ] ||
	fail "saved hash $saved, loaded $loaded ($t/s2.log)"
[ "$saved" != "$gen" ] || fail "the crater did not change the saved map"
stop

# 4
serve "$t/s3.log" "$t/u3"
wait_for_log "$t/s3.log" "heightmap: generated" 30 || fail "no generation ($t/s3.log)"
gen2=$(grep -aoP "heightmap: generated 1024x1024 seed 1234 in [0-9]+ ms, hash \K[0-9a-f]+" "$t/s3.log")
[ "$gen2" = "$gen" ] || fail "seed 1234 generated $gen, then $gen2"
stop

# 5
export BUILDAT_HEIGHTMAP_SURFACE=valleys
serve "$t/s5.log" "$t/u5"
unset BUILDAT_HEIGHTMAP_SURFACE
wait_for_log "$t/s5.log" "the ball rests" 60 || fail "no rest on the valleys ($t/s5.log)"
relief=$(grep -aoP "the valleys surface sampled in [0-9]+ ms: \K[-0-9.]+ to [-0-9.]+" "$t/s5.log")
echo "the valleys surface: $relief m"
echo "$relief" | awk '{exit !($3 - $1 > 80)}' ||
	fail "the valleys surface is \"$relief\" m, not 80 m of relief ($t/s5.log)"
printf '%s\n' "wait_log 60000 heightmap: terrain built" "keypress O" "delay 2000" \
	"screenshot $t/valleys.png" "quit" > "$t/v.cmds"
run_client 60 "$t/v.log" timeout 180 "$here/Build/bin/buildat" \
	-s "127.0.0.1:$SERVER_PORT" -D "$t/cu" -w 1280x720 -l 3 \
	-o sound_mute=1 -c @"$t/v.cmds"
[ -s "$t/valleys.png" ] || fail "no view of the valleys ($t/v.log)"
stop
echo "PASS: seed 1234 generated $gen twice; the ball rests $over over the ground; the map holds $held MB; five materials drawn; a crater reached the client in $edit; frames $frame ms on average; saved and loaded $saved; the valleys $relief m"
# vim: set noet ts=4 sw=4:
