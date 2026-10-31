#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min, more with a cold module cache (2026-10-31)
# covers: builtin/kit/** apps/workbench/** util/kit_move_check.lua
# [KIT] stage 4h, Kit's controls on Workbench, the admin (kitboss, by the
# setup code) playing:
#   0. util/kit_move_check.lua: the movements stepped as the box does.
#   1. kit/walker (Kit's default): a walk and a jump, the client's
#      prediction agreeing with the server's steps (no correction); a
#      kit/walker on the root with jump_height 0: no jump.
#   2. kit/controls on the root, a button linked to its shake: the button
#      used, the client shakes the camera; a vignette turns the effects on.
#   3. The top-down camera with kit/click_to_move: the cursor points (at
#      the floor), a click on the floor walks there (arrived), a click on
#      the button walks to it and uses it; then first person with
#      click_to_move, a click at the crosshair walks there.
#   4. kit/car: used, the player is in its seat (the chase camera), W
#      drives it forward, F leaves it (put beside it); kit/ball the same.
#      ([KIT_TRIGGER_DIG]) The car driven into a trigger zone linked to a
#      dig zone's dig: the dig zone's box dug out.
# The screenshots (walk, shake, vignette, top_down, first_click, car, ball)
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
keydown Space
delay 200
keyup Space
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
	edit '{"op": "place", "type": "kit/car", "pos": [-1, 1, 2]}'
	edit '{"op": "place", "type": "kit/ball", "pos": [3, 1, 9]}'
	# [KIT_TRIGGER_DIG] a trigger zone on the car's way, its "entered" to a
	# dig zone's dig
	edit '{"op": "place", "type": "kit/trigger_zone", "pos": [-2, 1, 5]}'
	set_p 8 size '[3, 2, 4]'
	edit '{"op": "place", "type": "kit/dig_zone", "pos": [6, -1, 2]}'
	set_p 9 size '[2, 2, 2]'
	edit '{"op": "link", "id": 8, "comp": 0, "output": "entered", "to": 9, "input": "dig"}'
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: controls: camera first_person, pointer crosshair, movement kit/walker
event kit_use 6
wait_log 10000 kit: controls: camera chase, pointer crosshair, movement kit/car, seat 6
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
event kit_use 7
wait_log 10000 kit: controls: camera chase, pointer crosshair, movement kit/ball, seat 7
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
want "$s" "kitboss takes the seat of entity 6" "kitboss leaves the seat of entity 6" \
	"kitboss takes the seat of entity 7" "kitboss leaves the seat of entity 7"
want "$s" "kit/trigger_zone 8: kitboss entered; 1 inside" \
	"kit/dig_zone 9: digs its box out by kitboss"
grep -a "kitboss takes the seat of entity 6" -A1000 "$s" |
	grep -aq "kit/trigger_zone 8: kitboss entered" ||
	fail "the zone was not entered by car ($s)"
grep -aq "sets a voxel it does not own\|sets [0-9]* cells, past" "$s" &&
	fail "the dig zone's dig was not made ($s)"
echo "ok: the car drove into a trigger zone, whose entered dug a dig zone's box out"
d2=$(dist 8 9)
awk -v d="$d2" 'BEGIN { exit !(d > 1) }' ||
	fail "the ball did not roll ($d2 m): $(body 8) -> $(body 9)"
n_corr=$(grep -ac "kit: the body corrected" "$c")
echo "ok: the car drove $d m and was left, the ball rolled $d2 m and was left ($n_corr corrections in all)"
echo "PASS: Kit's controls on Workbench: kit/walker's walk and jump (prediction agreeing), jump off, a camera shake by a signal, effects, top-down click_to_move to the floor and to an object, first-person click_to_move, a car and a ball seated, driven and left"
# vim: set noet ts=4 sw=4:
