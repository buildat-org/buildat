#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min, more with a cold module cache (2026-10-31)
# covers: builtin/kit/** apps/workbench/** util/kit_move_check.lua
# [KIT] stage 4h, Kit's controls on Workbench, the admin (kitboss, by the
# setup code) playing:
#   0. util/kit_move_check.lua: the movements stepped as the box does.
#   1. kit/walker (Kit's default): a walk and a jump (a keypress: down and
#      up in one frame, [KIT_TEMPLATE_ROUGH_EDGES]), the client's
#      prediction agreeing with the server's steps (no correction); a
#      kit/walker on the root with jump_height 0: no jump.
#   2. kit/controls on the root, a button linked to its shake: the button
#      used, the client shakes the camera; a vignette turns the effects on.
#   3. The top-down camera with kit/click_to_move: the cursor points (at
#      the floor), a click on the floor walks there (arrived), a click on
#      the button walks to it and uses it; then first person with
#      click_to_move, a click at the crosshair walks there.
#   4. A hull with kit/car and kit/seat ([KIT_COMPONENTS]): used, the player is in its
#      seat (the chase camera), W drives it forward, F leaves it (put beside it);
#      kit/ball the same.
#      ([KIT_TRIGGER_DIG]) The car driven into a trigger zone linked to a
#      dig zone's dig: the dig zone's box dug out.
#   5. ([KIT_SLAB_WALK]) Stop and Play, then from the spawn along -z a
#      slab, a cube and slabs on cubes (wide stairs): walked up holding W
#      only, y never going down, settled at 2.0 with no correction; Space
#      jumps from the slab.
#   6. ([WB_HOVER_OUT_OF_REACH]) The chase camera 20 behind, from the
#      spawn: a button within the use range pointed out as used, one out
#      of it (7.1 away) not, though the camera's reach covers it.
# The screenshots (walk, shake, vignette, top_down, first_click, car, ball,
# slabs, slab_top, reach_near, reach_far)
# are kept with KEEP_TMP=1; look at them.
#   util/kit_controls_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
# Workbench opens its project "world" at once, no Manage
# ([WORKBENCH_PROJECTS]: workbench_check.sh goes through Manage)
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
for lua in luajit lua5.1; do
	command -v $lua >/dev/null && break
done
(cd "$here" && $lua util/kit_move_check.lua) || fail "util/kit_move_check.lua"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_controls; t=$CHECK_TMP
cd "$here/Build"

want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
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
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
look 0 -10
keydown W
delay 1000
keyup W
keypress Space
frames 90
screenshot @T@/walk.png
event kit_body
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
EOF
	edit '{"op": "place", "type": "kit/walker", "pos": [0, 1, 0]}'
	set_p 3 jump_height 0
	edit '{"op": "place", "type": "kit/controls", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/button", "pos": [3, 1, 6]}'
	edit '{"op": "link", "id": 5, "comp": 0, "output": "pressed", "to": 4, "input": "shake"}'
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: controls: camera first_person
keydown Space
delay 300
keyup Space
frames 60
event kit_body
event kit_use 5
wait_log 10000 kit: camera shake 1
frames 2
screenshot @T@/shake.png
keypress F6
wait_log 10000 kit editor: state:
EOF
	set_p 4 vignette 0.7
	set_p 4 tint_amount 0.25
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: effects on
frames 5
screenshot @T@/vignette.png
keypress F6
wait_log 10000 kit editor: state:
EOF
	set_p 4 vignette 0
	set_p 4 tint_amount 0
	set_p 4 camera '"top_down"'
	set_p 4 movement '"kit/click_to_move"'
	# [KIT_PLAY_RULES_CHECKS_FAULT] the round is Running: out of edit mode
	# the admin digs and places by the play rules ([KIT_BUILDER_PLAY_RULES]),
	# so a region allows both around the area (entity 6)
	edit '{"op": "place", "type": "kit/region", "pos": [-20, -5, -20]}'
	set_p 6 size '[40, 12, 40]'
	set_p 6 dig '"all"'
	set_p 6 place '"all"'
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: controls: camera top_down, pointer cursor, movement kit/click_to_move
frames 20
mouse_pos 700 300
wait_log 10000 kit: points at dig
screenshot @T@/top_down.png
event kit_click_at -2 0.5 -4
wait_log 10000 kit: stopped at
event kit_body
event kit_click_at 3 1 6
wait_log 10000 kit: arrived at 5
wait_log 10000 kit: camera shake 1
event kit_body
keypress F6
wait_log 10000 kit editor: state:
EOF
	set_p 4 camera '"first_person"'
	set_p 4 pointer '"crosshair"'
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: controls: camera first_person, pointer crosshair, movement kit/click_to_move
look 180 -45
mouse_click left
wait_log 10000 kit: going to
frames 5
screenshot @T@/first_click.png
wait_log 10000 kit: stopped at
event kit_body
keypress F6
wait_log 10000 kit editor: state:
EOF
	set_p 4 movement '"kit/walker"'
	edit '{"op": "place", "type": "kit/part", "pos": [-1, 1, 2], "params": {"size": [1.8, 0.7, 3.6], "color": "#3060c0"}}'
	edit '{"op": "add_component", "id": 7, "type": "kit/car"}'
	edit '{"op": "add_component", "id": 7, "type": "kit/seat"}'
	edit '{"op": "place", "type": "kit/ball", "pos": [3, 1, 9]}'
	# [KIT_TRIGGER_DIG] a trigger zone on the car's way, its "entered" to a
	# region's dig_out ([KIT] 4j: the dig zone's dig)
	edit '{"op": "place", "type": "kit/trigger_zone", "pos": [-2, 1, 5]}'
	set_p 9 size '[3, 2, 4]'
	edit '{"op": "place", "type": "kit/region", "pos": [6, -1, 2]}'
	set_p 10 size '[2, 2, 2]'
	set_p 10 dig '"all"'
	edit '{"op": "link", "id": 9, "comp": 0, "output": "entered", "to": 10, "input": "dig_out"}'
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: controls: camera first_person, pointer crosshair, movement kit/walker
event kit_use 7
wait_log 10000 kit: controls: camera chase, pointer crosshair, movement kit/car, seat 7
frames 30
event kit_body
keydown W
delay 1000
keyup W
frames 10
screenshot @T@/car.png
event kit_body
keypress F
wait_log 10000 kit: controls: camera first_person, pointer crosshair, movement kit/walker
frames 5
event kit_use 8
wait_log 10000 kit: controls: camera chase, pointer crosshair, movement kit/ball, seat 8
frames 10
event kit_body
keydown W
delay 1000
keyup W
frames 10
screenshot @T@/ball.png
event kit_body
keypress F
wait_log 10000 kit: controls: camera first_person, pointer crosshair, movement kit/walker
frames 10
event kit_body
keypress F6
wait_log 10000 kit editor: state:
EOF
	# [KIT_SLAB_WALK] Wide stairs along -z from the spawn, x 0...1: a slab
	# (top 1.0), a cube (1.5), then a cube under a slab (2.0) for three
	# cells; Stop and Play put the player at the spawn
	set_p 3 jump_height 1.25
	for x in 0 1; do
		edit "{\"op\": \"set_voxel\", \"pos\": [$x, 1, -3], \"voxel\": \"kit/stone:slab\"}"
		edit "{\"op\": \"set_voxel\", \"pos\": [$x, 1, -4], \"voxel\": \"kit/stone\"}"
		for z in -5 -6 -7; do
			edit "{\"op\": \"set_voxel\", \"pos\": [$x, 1, $z], \"voxel\": \"kit/stone\"}"
			edit "{\"op\": \"set_voxel\", \"pos\": [$x, 2, $z], \"voxel\": \"kit/stone:slab\"}"
		done
	done
	cat <<'EOF'
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode off
frames 60
look_dir 0 -0.3 -1
frames 10
event kit_body
keydown W
EOF
	for i in 1 2 3 4 5 6 7 8; do
		printf 'delay 150\nevent kit_body\n'
		[ $i = 4 ] && echo "screenshot @T@/slabs.png"
	done
	cat <<'EOF'
keyup W
frames 30
event kit_body
frames 30
event kit_body
screenshot @T@/slab_top.png
keydown Space
delay 200
keyup Space
frames 120
event kit_body
keypress F6
wait_log 10000 kit editor: state:
EOF
	# [WB_HOVER_OUT_OF_REACH] The chase camera 20 behind; a button (11)
	# within the use range of the spawn, one (12) 7.1 from it: from the
	# spawn, pointed at, 11 is pointed out as used, 12 not
	set_p 4 camera '"chase"'
	set_p 4 distance 20
	edit '{"op": "place", "type": "kit/button", "pos": [2, 1, 3]}'
	edit '{"op": "place", "type": "kit/button", "pos": [5, 1, 6]}'
	cat <<'EOF'
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: controls: camera chase
frames 60
look_dir 0 -0.3 1
frames 30
event kit_body
event kit_point_at 2 1 3
wait_log 5000 kit: points at use 11
frames 5
screenshot @T@/reach_near.png
event kit_point_at 5 1 6
wait_log 5000 kit: points at
frames 30
screenshot @T@/reach_far.png
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
	run_client 60 "$t/boss.log" timeout 240 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
	-c @"$t/boss.cmds" || fail "the client failed ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
c=$t/boss.log s=$t/srv.log
grep -a "kit: body at\|kit: controls:\|kit: going to\|arrived\|camera shake\|corrected" "$c" |
	sed 's/^.*kit *: //' | cut -c1-150
# The body lines, in order
body() # <n>: the nth "body at" line's field <k> (x y z acks corrections jumps arrivals)
{
	grep -aoP 'kit: body at \K.*' "$c" | sed -n "$1p"
}
fields() # <line> -> x y z acks corrections pending jumps arrivals
{
	echo "$1" | sed -E 's/([-0-9.]+),([-0-9.]+),([-0-9.]+), ([0-9]+) acks, ([0-9]+) corrections, ([0-9]+) pending, ([0-9]+) jumps, ([0-9]+) arrivals/\1 \2 \3 \4 \5 \6 \7 \8/'
}
read -r x y z acks corr pend jumps arr <<< "$(fields "$(body 1)")"
awk -v z="$z" 'BEGIN { exit !(z > 3) }' || fail "the walk did not go forward: $(body 1)"
[ "$jumps" = 1 ] || fail "no jump: $(body 1)"
[ "$corr" = 0 ] || fail "the prediction was corrected: $(body 1)"
read -r x y z acks corr pend jumps2 arr <<< "$(fields "$(body 2)")"
[ "$jumps2" = 1 ] || fail "a jump with jump_height 0: $(body 2)"
echo "ok: kit/walker walked and jumped, no correction; jump_height 0: no jump"
want "$c" "kit: camera shake 1" "kit: effects on"
echo "ok: a button's signal shook the camera; a vignette"
dist() # <body line a> <body line b>: the horizontal distance
{
	read -r xa ya za rest <<< "$(fields "$(body $1)")"
	read -r xb yb zb rest <<< "$(fields "$(body $2)")"
	awk -v a="$xa" -v b="$za" -v c="$xb" -v d="$zb" \
		'BEGIN { printf "%.2f", sqrt((c - a) ^ 2 + (d - b) ^ 2) }'
}
read -r x y z acks corr pend jumps arr3 <<< "$(fields "$(body 3)")"
[ "$arr3" -gt 0 ] || fail "click_to_move did not arrive: $(body 3)"
awk -v x="$x" -v z="$z" 'BEGIN { exit !((x + 2) ^ 2 + (z + 4) ^ 2 < 1) }' ||
	fail "click_to_move arrived elsewhere: $(body 3)"
want "$c" "kit: arrived at 5"
[ "$(grep -ac 'Entity 5 used by kitboss' "$s")" = 2 ] ||
	fail "the button was not used on arrival ($s)"
read -r x y z acks corr pend jumps arr4 <<< "$(fields "$(body 4)")"
read -r x y z acks corr pend jumps arr5 <<< "$(fields "$(body 5)")"
[ "$arr5" -gt "$arr4" ] || fail "the first-person click did not arrive: $(body 5)"
echo "ok: top-down cursor pointed, click_to_move walked to a floor click and to the button (used); a first-person click walked"
d=$(dist 6 7)
awk -v d="$d" 'BEGIN { exit !(d > 2) }' ||
	fail "the car did not drive ($d m): $(body 6) -> $(body 7)"
want "$s" "kitboss takes the seat of entity 7" "kitboss leaves the seat of entity 7" \
	"kitboss takes the seat of entity 8" "kitboss leaves the seat of entity 8"
want "$s" "kit/trigger_zone 9: kitboss entered; 1 inside" \
	"kit/region 10: digs its box out by kitboss"
grep -a "kitboss takes the seat of entity 7" -A1000 "$s" |
	grep -aq "kit/trigger_zone 9: kitboss entered" ||
	fail "the zone was not entered by car ($s)"
grep -aq "sets a voxel it does not own\|sets [0-9]* cells, past" "$s" &&
	fail "the dig zone's dig was not made ($s)"
echo "ok: the car drove into a trigger zone, whose entered dug a dig zone's box out"
d2=$(dist 8 9)
awk -v d="$d2" 'BEGIN { exit !(d > 1) }' ||
	fail "the ball did not roll ($d2 m): $(body 8) -> $(body 9)"
n_corr=$(grep -ac "kit: the body corrected" "$c")
echo "ok: the car drove $d m and was left, the ball rolled $d2 m and was left ($n_corr corrections in all)"
# [KIT_SLAB_WALK] bodies 11 (the spawn), 12-19 (walking up), 20 and 21
# (settled on the top slab), 22 (after a jump from it)
read -r x0 y0 z0 a0 corr0 p0 j0 r0 <<< "$(fields "$(body 11)")"
grep -aoP 'kit: body at \K[-0-9.]+,[-0-9.]+,[-0-9.]+' "$c" | sed -n '11,22p' |
	tr '\n' ' '; echo
prev=$y0
for n in $(seq 12 19); do
	read -r x y z rest <<< "$(fields "$(body $n)")"
	awk -v a="$prev" -v b="$y" 'BEGIN { exit !(b >= a - 0.02) }' ||
		fail "down on the way up the slabs: y $prev -> $y (body $n)"
	prev=$y
done
read -r xa ya za aa corra pa ja ra <<< "$(fields "$(body 20)")"
read -r xb yb zb ab corrb pb jb rb <<< "$(fields "$(body 21)")"
awk -v a="$ya" -v b="$yb" -v z="$zb" 'BEGIN { exit !(a > 1.98 && a < 2.02 &&
	(b - a) ^ 2 < 0.0004 && z < -4.5) }' ||
	fail "not settled on the top slab (2.0): $(body 20) / $(body 21)"
[ "$corrb" = "$corr0" ] ||
	fail "the prediction was corrected on the slabs: $corr0 -> $corrb"
read -r xc yc zc ac corrc pc jc rc <<< "$(fields "$(body 22)")"
[ "$jc" -gt "$jb" ] || fail "no jump from the slab: $(body 21) -> $(body 22)"
awk -v a="$yc" 'BEGIN { exit !(a > 1.98 && a < 2.02) }' ||
	fail "not back on the slab after the jump: $(body 22)"
echo "ok: walked up slab, cube, slabs on cubes holding forward (y never down, settled at 2.0, no correction); a jump from the slab"
# [WB_HOVER_OUT_OF_REACH] body 23: at the spawn, 12 out of the use range
read -r x y z rest <<< "$(fields "$(body 23)")"
awk -v x="$x" -v y="$y" -v z="$z" 'BEGIN { y = y + 0.5 - 1
	d = sqrt((x - 5) ^ 2 + y ^ 2 + (z - 6) ^ 2)
	e = sqrt((x - 2) ^ 2 + y ^ 2 + (z - 3) ^ 2)
	exit !(d > 6.5 && e < 5.5) }' || fail "not at the spawn for the reach: $(body 23)"
grep -a "kit: points at [a-z]" "$c" | tail -1 | sed 's/^.*kit:/  kit:/'
grep -a "kit: points at use 11" -A1000 "$c" | grep -aq "kit: points at use 12" &&
	fail "a button out of the use range pointed out as used ($c)"
echo "ok: the chase camera 20 behind: a button in the use range pointed out as used, one out of it not"
echo "PASS: Kit's controls on Workbench: kit/walker's walk and jump (prediction agreeing), jump off, a camera shake by a signal, effects, top-down click_to_move to the floor and to an object, first-person click_to_move, a car and a ball seated, driven and left"
# vim: set noet ts=4 sw=4:
