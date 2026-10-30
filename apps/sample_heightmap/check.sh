#!/bin/bash
# tier: full
# cost: ~70s (2026-10-30)
# covers: builtin/heightmap/**
# [HEIGHTMAP_TERRAIN]: builtin/heightmap through apps/sample_heightmap, a
# 1024x1024 map at a metre:
#   1. a fresh save generates seed 1234; the ball dropped on the pad comes
#      to rest its radius (1 m) over the ground, within 5 cm (Bullet's
#      heightfield where the map says);
#   2. a native client builds the terrain; C digs a crater under the ball
#      and the client's terrain reads the server's new height there; the
#      frame time stays under LIMIT_MS (200) on average; the log has the
#      triangles and draw calls; the chunk hook saw the four chunks the
#      crater wrote once each;
#   3. the server started again on the save loads the map with the hash
#      it saved after the crater;
#   4. a second fresh save generates the same hash as the first.
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

# 1
serve "$t/s1.log" "$t/u1"
wait_for_log "$t/s1.log" "the ball rests" 60 || fail "the ball never rested ($t/s1.log)"
gen=$(grep -aoP "heightmap: generated 1024x1024 seed 1234 in [0-9]+ ms, hash \K[0-9a-f]+" "$t/s1.log")
[ -n "$gen" ] || fail "no generation ($t/s1.log)"
over=$(grep -aoP "the ball rests .*, \K[-0-9.]+(?= over the ground)" "$t/s1.log" | head -1)
echo "generated $gen; the ball rests $over over the ground"
awk -v o="$over" 'BEGIN{d = o - 1; exit !(d < 0.05 && d > -0.05)}' ||
	fail "the ball rests $over over the ground, not its radius 1 ($t/s1.log)"

# 2
printf '%s\n' "wait_log 60000 heightmap: terrain built" "delay 2500" \
	"screenshot $t/hills.png" "keypress C" "wait_log 20000 the crater reached this client" \
	"delay 4500" "screenshot $t/crater.png" "quit" > "$t/c.cmds"
run_client 60 "$t/c.log" timeout 180 "$here/Build/bin/buildat" \
	-s "127.0.0.1:$SERVER_PORT" -D "$t/cu" -w 1280x720 -l 3 \
	-o sound_mute=1 -c @"$t/c.cmds"
grep -a "heightmap: terrain built\|the crater\|frame .* ms average" "$t/c.log" | sed 's/^.*sample_heightmap: //;s/^.*heightmap: /heightmap: /'
grep -aq "the crater reached this client" "$t/c.log" ||
	fail "the crater did not reach the client ($t/c.log)"
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
echo "PASS: seed 1234 generated $gen twice; the ball rests $over over the ground; a crater reached the client; frames $frame ms on average; saved and loaded $saved"
# vim: set noet ts=4 sw=4:
