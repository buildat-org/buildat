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
#   6. [KIT_PLANE] stage 3, kit/polygon: a slope from the ledge's end and an
#      overhang in the plane, a tree in front of it and a hill behind it
#      (kit/controls' side_clip 3 shows the tree): D walks up the slope
#      through the tree and the hill (not met) and stops under the overhang
#      (x 22.05, y 4.5, z 1), few corrections; the side view's screenshot.
#      Crossing edges and 129 points refused.
#   7. The Front view on a 1/4 grid: a concave polygon of 5 points drawn by
#      clicks and closed on its first; the server's points are the clicked
#      ones less its place (z 1); its second point dragged: a set of the
#      points with that one alone moved. The screenshot.
# The screenshots (side, front, side_ortho, side_polygons, front_polygon)
# are kept with KEEP_TMP=1; look at them.
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
keypress F6
wait_log 10000 kit editor: state:
EOF
	# Stage 3, kit/polygon (6...9): in the plane a slope up from the ledge's
	# end (9.5, 1.5) to a top at 4.5 (x 15.5...23.5) and an overhang over it
	# (its underside from (18.5, 7) down to (23.5, 6)); a tree in front of the
	# plane (z -1) and a hill behind it (z 5) across the walk
	poly() # <x> <y> <z> <points> [more params]
	{
		edit "{\"op\": \"place\", \"type\": \"kit/polygon\", \"pos\": [$1, $2, $3], \"params\": {\"points\": $4${5:+, $5}}}"
	}
	poly 16.5 2.5 1 '[[-7, -2], [-7, -1], [-1, 2], [7, 2], [7, -2]]'
	poly 23 7.5 1 '[[-4.5, -0.5], [0.5, -1.5], [4.5, -1.5], [4.5, 1.5], [-4.5, 1.5]]' '"color": "#8a7060"'
	poly 18 3.75 -1 '[[-0.5, -3.25], [-0.5, -0.75], [-2.5, -0.25], [-2, 2.25], [0, 3.25], [2, 2.25], [2.5, -0.25], [0.5, -0.75], [0.5, -3.25]]' '"color": "#2d5a2d"'
	poly 21.5 5.25 5 '[[-11.5, -4.75], [-5.5, 1.75], [-0.5, -0.25], [5.5, 4.75], [11.5, -4.75]]' '"color": "#56648a", "depth": 2'
	set_p 3 ortho false
	set_p 3 side_clip 3
	# Shapes refused: edges crossing, 129 points
	many=$(for i in $(seq 0 128); do printf '[%d, %d],' $((i % 30)) $((i / 30)); done)
	cat <<EOF
event kit_edit {"op": "place", "type": "kit/polygon", "pos": [0, 4, 1], "params": {"points": [[0, 0], [3, 2], [3, 0], [0, 1]]}}
wait_log 10000 a polygon whose edges do not cross (edges 1 and 3 meet)
event kit_edit {"op": "set", "id": 6, "comp": 0, "param": "points", "value": [${many%,}]}
wait_log 10000 a polygon: 3 to 128 points
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 a polygon of 9 points
frames 30
event kit_body
keydown D
delay 900
delay 900
delay 900
delay 900
keyup D
frames 30
event kit_body
screenshot @T@/side_polygons.png
keypress F6
wait_log 10000 kit editor: state:
keypress F7
wait_log 5000 kit editor: the view is Front
click Button "Grid*"
wait_log 5000 kit editor: grid 1/2
click Button "Grid*"
wait_log 5000 kit editor: grid 1/4
EOF
	# A concave polygon drawn by clicks, closed on its first point; then its
	# second point dragged
	pal_find kit/polygon
	cat <<'EOF'
click Button "kit/polygon"
wait_log 5000 kit editor: placing
mouse_pos 400 120
frames 3
mouse_click left
wait_log 5000 kit editor: polygon point 1 at
mouse_pos 640 120
frames 3
mouse_click left
wait_log 5000 kit editor: polygon point 2 at
mouse_pos 640 280
frames 3
mouse_click left
wait_log 5000 kit editor: polygon point 3 at
mouse_pos 520 200
frames 3
mouse_click left
wait_log 5000 kit editor: polygon point 4 at
mouse_pos 400 280
frames 3
mouse_click left
wait_log 5000 kit editor: polygon point 5 at
mouse_pos 400 120
frames 3
mouse_click left
wait_log 5000 kit editor: placed kit/polygon at
EOF
	n=$((n + 1))
	cat <<EOF
wait_log_any 10000 entities, $n to undo
frames 10
mouse_pos 640 120
frames 3
mouse_down left
frames 3
mouse_pos 660 110
frames 3
mouse_pos 690 100
frames 3
mouse_up left
wait_log 5000 point 2 moved, 5 points
wait_log_any 10000 entities, $((n + 1)) to undo
frames 10
screenshot @T@/front_polygon.png
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
[ "$(grep -ac 'kit: body at' "$c")" = 7 ] || fail "not 7 body lines ($c)"
for k in 1 2 3 4 5 6 7; do
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
grep -aP 'kit editor: placed kit/button at -?[0-9]+,-?[0-9]+,1$' "$c" >/dev/null ||
	fail "the Front view placed off the plane: $(grep -a 'kit editor: placed kit/button' "$c")"
echo "ok: the Front view placed $(grep -aoP 'kit editor: placed \Kkit/button at .*' "$c") (the plane's depth)"
echo "ok: the movement refused as a course's and as none"
# Stage 3: up the slope, stopped under the overhang (x 22.05: the body's
# corner, 0.45, where the underside is 1.7 over the top), the tree and the
# hill off the plane not met
read -r x7 y7 z7 acks7 corr7 rest <<< "$(fields "$(body 7)")"
awk -v x="$x7" -v y="$y7" 'BEGIN { exit !(x > 22 && x < 22.1 && y > 4.48 && y < 4.52) }' ||
	fail "not up the polygon slope and stopped under the overhang (22.05, 4.5): $(body 7)"
[ $((corr7 - corr)) -le 2 ] || fail "$((corr7 - corr)) corrections on the polygons: $(body 7)"
echo "ok: kit/walker up a polygon slope, stopped under a polygon overhang at $x7,$y7, through a tree and a hill off the plane, $((corr7 - corr)) corrections"
# The drawn polygon: its points (the client's, on the 1/4 grid, less the place
# it got, their box's middle) in the server's state, then its second point moved
drawn=$(grep -aoP 'kit editor: polygon point [0-9]+ at \K\S+' "$c" | tr ',' ' ')
[ "$(echo "$drawn" | wc -l)" = 5 ] || fail "not 5 points drawn ($c)"
at=$(grep -aoP 'kit editor: placed kit/polygon at \K[-0-9.]+,[-0-9.]+,[-0-9.]+(?=, 5 points)' "$c")
[ -n "$at" ] || fail "no polygon of 5 points placed ($c)"
[ "${at##*,}" = 1 ] || fail "the polygon placed off the plane (z 1): $at"
placed=$(grep -aP 'placed kit/polygon [0-9]+ at ' "$s" | tail -1)
pid=$(echo "$placed" | grep -oP 'placed kit/polygon \K[0-9]+')
nums() { sed -E 's/.*( with |points to )//' | grep -oE -- '-?[0-9.]+'; }
got=$(echo "$placed" | nums)
want=$(echo "$drawn" | awk -v at="$at" 'BEGIN { split(at, a, ",") }
	{ print $1 - a[1]; print $2 - a[2] }')
[ "$(echo "$got" | wc -l)" = 10 ] && paste <(echo "$got") <(echo "$want") |
	awk '$1 != $2 { exit 1 }' ||
	fail "the server's points ($(echo $got)) are not the drawn ones less $at ($(echo $want))"
set_l=$(grep -a "set $pid's kit/polygon points to" "$s" | tail -1)
[ -n "$set_l" ] || fail "no set of polygon $pid's points ($s)"
moved=$(echo "$set_l" | nums)
paste <(echo "$got") <(echo "$moved") | awk 'NR != 3 && NR != 4 && $1 != $2 { bad = 1 }
	(NR == 3 || NR == 4) && $1 != $2 { m = 1 } END { exit bad || !m }' ||
	fail "not point 2 alone moved: $(echo $got) -> $(echo $moved)"
echo "ok: a polygon drawn in the Front view, its points [$(echo $got)] at $at in the server's state; point 2 dragged: [$(echo $moved)]"
echo "ok: a polygon's crossing edges and 129 points refused"
echo "PASS: kit/controls' vertical plane: kit/walker held to it on both sides, the side camera and its pointer, the editor's Front view placing at its depth, the movement list checked; kit/polygon's slope and overhang met, others off the plane not, one drawn and edited in the Front view; the 2D queries (util/kit_plane_check.lua)"
# vim: set noet ts=4 sw=4:
