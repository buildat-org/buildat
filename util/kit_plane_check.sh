#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min, more with a cold module cache (2026-11-15)
# covers: builtin/kit/** apps/workbench/** util/kit_plane_check.lua
# [KIT_PLANE] stage 2, gameplay in a vertical plane, on Workbench, the admin
# (kitboss, by the setup code) playing:
#   0. util/kit_plane_check.lua: kit/walker held to the plane as the box steps
#      it (the same bits twice), w:circle and w:segment against voxels, a
#      voxel off the plane and a heightmap's slope.
#   1. kit/controls' plane vertical and the side camera: the plane at the
#      spawn's depth (z 1, the server's log); W goes nowhere, D walks along x
#      past a wall in front of the plane and one behind it (neither met) to a
#      ledge in the plane, D and Space jump onto it; z 1 in every body line,
#      no more than two corrections. The side view's screenshot.
#   2. The pointer at a ledge cell with a clipped voxel in front of it: the
#      ledge's cell is pointed at, not the clipped one.
#   3. The editor's Front view (F7): its screenshot; kit/button placed from the
#      palette lands at the plane's depth.
#   4. kit/controls' movement refused as a course's (kit/course) and as a
#      type that is none.
#   5. The side camera ortho: its screenshot, the clipped voxel not pointed
#      at either.
# The screenshots (side, front, side_ortho) are kept with KEEP_TMP=1; look
# at them.
#   util/kit_plane_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
for lua in luajit lua5.1; do
	command -v $lua >/dev/null && break
done
(cd "$here" && $lua util/kit_plane_check.lua) || fail "util/kit_plane_check.lua"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_plane; t=$CHECK_TMP
cd "$here/Build"

export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
n=0
edit() # <op json>: an edit and its answer
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
set_p() # <id> <param> <json value>
{
	edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
}
voxel() # <x> <y> <z>
{
	edit "{\"op\": \"set_voxel\", \"pos\": [$1, $2, $3], \"voxel\": \"kit/stone\"}"
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
EOF
	# The controls (3) and a region (4) where the admin digs and places in play
	edit '{"op": "place", "type": "kit/controls", "pos": [0, 1, 0]}'
	set_p 3 plane '"vertical"'
	set_p 3 camera '"side"'
	set_p 3 distance 10
	edit '{"op": "place", "type": "kit/region", "pos": [-10, -5, -10]}'
	set_p 4 size '[40, 14, 20]'
	set_p 4 dig '"all"'
	set_p 4 place '"all"'
	# The ledge in the plane (z 1), x 3...9, top 1.5; walls at x 2 in front
	# of the plane (z 0) and behind it (z 2); a voxel in front of the ledge's
	# end (9, 1, 0)
	for x in 3 4 5 6 7 8 9; do
		voxel $x 1 1
	done
	voxel 2 1 0
	voxel 2 2 0
	voxel 2 1 2
	voxel 2 2 2
	voxel 9 1 0
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: controls: camera side, pointer cursor, movement kit/walker, plane z 1
frames 30
event kit_body
keydown W
delay 400
keyup W
frames 10
event kit_body
keydown D
delay 500
event kit_body
keydown Space
delay 400
keyup Space
delay 500
keyup D
frames 60
event kit_body
frames 30
event kit_body
screenshot @T@/side.png
event kit_point_at 9 1 1
wait_log 5000 kit: points at dig 9,1,1
event kit_point_at
keypress F6
wait_log 10000 kit editor: state:
keypress F7
wait_log 5000 kit editor: the view is Front
frames 10
screenshot @T@/front.png
EOF
	pal_find kit/button
	n=$((n + 1))
	cat <<EOF
click Button "kit/button"
wait_log 5000 kit editor: placing
mouse_pos 337 350
frames 3
mouse_click left
wait_log 5000 kit editor: placed
wait_log 10000 entities, $n to undo
mouse_click right
wait_log 5000 kit editor: placing nothing
event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "movement", "value": "kit/course"}
wait_log 10000 kit editor: refused: set: kit/controls's movement is a players' movement
event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "movement", "value": "kit/nothing_here"}
wait_log 10000 kit editor: refused: set: kit/controls's movement is none or a movement
EOF
	set_p 3 ortho true
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
frames 30
screenshot @T@/side_ortho.png
event kit_point_at 9 1 1
wait_log 5000 kit: points at dig 9,1,1
quit
EOF
} > "$t/boss.cmds"
sed -i "s|@T@|$t|g" "$t/boss.cmds"
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
	run_client 60 "$t/boss.log" timeout 180 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
	-c @"$t/boss.cmds" || fail "the client failed ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
c=$t/boss.log s=$t/srv.log
grep -a "kit: body at\|kit: controls:\|points at\|corrected\|placed\|refused" "$c" |
	sed 's/^.*kit *: //' | cut -c1-150
grep -aq "kitboss's plane: z 1" "$s" || fail "the server put no plane at z 1 ($s)"
body() # <n>: the nth "body at" line
{
	grep -aoP 'kit: body at \K.*' "$c" | sed -n "$1p"
}
fields() # <line> -> x y z acks corrections pending jumps arrivals
{
	echo "$1" | sed -E 's/([-0-9.]+),([-0-9.]+),([-0-9.]+), ([0-9]+) acks, ([0-9]+) corrections, ([0-9]+) pending, ([0-9]+) jumps, ([0-9]+) arrivals/\1 \2 \3 \4 \5 \6 \7 \8/'
}
[ "$(grep -ac 'kit: body at' "$c")" = 5 ] || fail "not 5 body lines ($c)"
for k in 1 2 3 4 5; do
	read -r x y z acks corr rest <<< "$(fields "$(body $k)")"
	[ "$z" = 1.00 ] || fail "off the plane (z 1): $(body $k)"
done
read -r x1 y1 z1 rest <<< "$(fields "$(body 1)")"
read -r x2 y2 z2 rest <<< "$(fields "$(body 2)")"
awk -v a="$x1" -v b="$x2" 'BEGIN { exit !((a - b) ^ 2 < 0.0001) }' ||
	fail "W moved along x: $(body 1) -> $(body 2)"
read -r x3 y3 rest <<< "$(fields "$(body 3)")"
awk -v x="$x3" -v y="$y3" 'BEGIN { exit !(x > 2 && x < 2.1 && y < 0.6) }' ||
	fail "not walked past the walls off the plane to the ledge's side: $(body 3)"
read -r x5 y5 z5 acks corr pend jumps rest <<< "$(fields "$(body 5)")"
awk -v x="$x5" -v y="$y5" 'BEGIN { exit !(x > 3 && x < 9.5 && y > 1.48 && y < 1.52) }' ||
	fail "not on the ledge (top 1.5): $(body 5)"
[ "$jumps" -ge 1 ] || fail "no jump: $(body 5)"
[ "$corr" -le 2 ] || fail "$corr corrections: $(body 5)"
echo "ok: the plane at the spawn's depth (z 1): W nowhere, walked past walls off the plane, jumped onto the ledge in it, z 1 throughout, $corr corrections"
echo "ok: the side camera's pointer met the ledge's cell, not the clipped one in front of it (perspective and ortho)"
grep -aP 'kit editor: placed .* at -?[0-9]+,-?[0-9]+,1$' "$c" >/dev/null ||
	fail "the Front view placed off the plane: $(grep -a 'kit editor: placed' "$c")"
echo "ok: the Front view placed $(grep -aoP 'kit editor: placed \K.*' "$c") (the plane's depth)"
echo "ok: the movement refused as a course's and as none"
echo "PASS: kit/controls' vertical plane: kit/walker held to it on both sides, the side camera and its pointer, the editor's Front view placing at its depth, the movement list checked; the 2D queries (util/kit_plane_check.lua)"
# vim: set noet ts=4 sw=4:
