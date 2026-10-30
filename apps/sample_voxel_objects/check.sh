#!/bin/bash
# tier: full
# cost: ~40s (2026-10-30)
# covers: builtin/voxel_objects/** apps/sample_voxel_objects/**
# [VOXEL_OBJECTS]: builtin/voxel_objects through apps/sample_voxel_objects
# (a 16^3 house shown by 100 objects on a heightmap, a keep of four
# chunks, a beam turned 45 degrees with a ball dropped on its far end):
#   1. a fresh save builds the models; the ball comes to rest on the turned
#      beam, its radius (0.5 m) over the beam's top within 5 cm (the
#      beam's boxes turned with it: unturned, the drop point is 11 m off);
#   2. a native client meshes six chunks for 102 objects (105 chunk nodes:
#      copies share a mesh) and draws the hundred houses in under
#      DRAWS_MAX (200) draw calls (instanced: a batch each was ~240-340);
#      E's edit (a chimney on the house, the beam's end gone) reaches the
#      client as the house's rev 2, shared to the 100 houses, and the ball
#      falls to the pad and rests its radius over it; the frames take
#      under LIMIT_MS (200) on average; houses.png and edited.png to look
#      at;
#   3. the server started again on the save loads each model with the hash
#      it saved after the edit, and the ball rests on the pad (the loaded
#      beam has no end).
#   apps/sample_voxel_objects/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
limit=${LIMIT_MS:-200}
draws_max=${DRAWS_MAX:-200}
check_tmp voxel_objects; t=$CHECK_TMP
serve(){
	start_server "$1" "STATUS Listening" 300 auto "$here/Build/bin/buildat_server" \
		-m "$here/apps/sample_voxel_objects" -D "$2" -l 3 || fail "the server ($1)"
	CHECK_PIDS+=($SERVER_PID)
}
stop(){ kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null; }
# "<a> over <what>" of the last rest line, and whether it is the radius
rest(){ grep -a "the ball rests" "$1" | grep -aoP "[-0-9.]+(?= over $2)" | tail -1; }
near_radius(){ awk -v o="$1" 'BEGIN{d = o - 0.5; exit !(o != "" && d < 0.05 && d > -0.05)}'; }
# Each model's hash as the log last says it ("committed" or "loaded")
hashes(){
	local m
	for m in beam house keep; do
		echo "$m $(grep -aoP "model \"$m\" (rev [0-9]+ committed|loaded): .*hash \K[0-9a-f]+" "$1" | tail -1)"
	done
}

# 1
serve "$t/s1.log" "$t/u1"
wait_for_log "$t/s1.log" "the ball rests" 60 || fail "the ball never rested ($t/s1.log)"
grep -aq "sample_voxel_objects: models built" "$t/s1.log" || fail "no models built ($t/s1.log)"
on_beam=$(rest "$t/s1.log" "the beam's top")
echo "the ball rests $on_beam over the turned beam's top"
near_radius "$on_beam" || fail "the ball rests ${on_beam:-?} over the beam, not its radius 0.5 ($t/s1.log)"

# 2
printf '%s\n' "wait_log 60000 shared to 100 objects" "delay 2500" \
	"screenshot $t/houses.png" "wait_log 10000 draw calls; 3 models" \
	"keypress E" "wait_log 20000 model house rev 2 chunk (0,0,0) meshed" \
	"delay 2500" "screenshot $t/edited.png" "quit" > "$t/c.cmds"
run_client 60 "$t/c.log" timeout 180 "$here/Build/bin/buildat" \
	-s "127.0.0.1:$SERVER_PORT" -D "$t/cu" -w 1280x720 -l 3 \
	-o sound_mute=1 -c @"$t/c.cmds"
grep -a "voxel_objects: model\|frame .* ms average" "$t/c.log" | sed 's/^.*voxel_objects: //'
counts=$(grep -aoP "draw calls; \K.*" "$t/c.log" | head -1)
[ "$counts" = "3 models, 6 meshes, 102 objects, 105 chunk nodes" ] ||
	fail "voxel_objects' counts: \"$counts\", not 6 meshes for 102 objects ($t/c.log)"
draws=$(grep -aoP "[0-9]+(?= draw calls; 3 models)" "$t/c.log" | head -1)
[ "${draws:-999}" -lt "$draws_max" ] ||
	fail "the houses took ${draws:-?} draw calls, not under $draws_max ($t/c.log)"
grep -aq "model house rev 2 chunk (0,0,0) meshed in [0-9.]* ms, shared to 100 objects" "$t/c.log" ||
	fail "the edit did not reach the client's houses ($t/c.log)"
frame=$(grep -aoP "frame \K[0-9.]+(?= ms average)" "$t/c.log" | tail -1)
[ -n "$frame" ] || fail "no frame times ($t/c.log)"
awk -v f="$frame" -v l="$limit" 'BEGIN{exit !(f < l)}' ||
	fail "frames took $frame ms on average, not under $limit ($t/c.log)"
for i in $(seq 100); do
	[ "$(grep -ac "the ball rests" "$t/s1.log")" -ge 2 ] && break
	sleep 0.2
done
[ "$(grep -ac "the ball rests" "$t/s1.log")" -ge 2 ] ||
	fail "the ball did not come to rest after the edit ($t/s1.log)"
on_pad=$(rest "$t/s1.log" "the pad")
echo "after the edit the ball rests $on_pad over the pad"
near_radius "$on_pad" || fail "after the edit the ball rests ${on_pad:-?} over the pad, not 0.5 ($t/s1.log)"
saved=$(hashes "$t/s1.log")
stop

# 3
serve "$t/s2.log" "$t/u1"
wait_for_log "$t/s2.log" "the ball rests" 60 || fail "the ball never rested on the loaded models ($t/s2.log)"
loaded=$(hashes "$t/s2.log")
echo "saved:" $saved "; loaded:" $loaded
grep -aq "models loaded" "$t/s2.log" && [ "$saved" = "$loaded" ] &&
	! echo "$saved" | grep -q " $" ||
	fail "saved \"$saved\", loaded \"$loaded\" ($t/s1.log, $t/s2.log)"
loaded_pad=$(rest "$t/s2.log" "the pad")
near_radius "$loaded_pad" ||
	fail "on the loaded models the ball rests ${loaded_pad:-?} over the pad, not 0.5 ($t/s2.log)"
stop
echo "PASS: the ball rests $on_beam over the turned beam; 6 meshes for 102 objects in $draws draw calls; the edit reached the client's 100 houses and the ball fell to $on_pad over the pad; frames $frame ms on average; saved and loaded" $loaded
# vim: set noet ts=4 sw=4:
