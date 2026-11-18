#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min, more with a cold module cache (2026-11-18)
# covers: builtin/kit/** apps/workbench/** util/kit_plane_check.lua
# [KIT_TOP_DOWN] A top-down game on Workbench, the admin (kitboss, by the setup
# code) playing; the scene built by edits:
#   kit/controls' plane horizontal, camera top_down (straight down, ortho,
#   dead_zone 3); kit/polygons lying flat (pitch 90): a wall across z 6 (x
#   0...16), a zone (x 5...7, z -1...3, collision off) with a local type's
#   component, zone = "look", whose client part logs its on_enter, and an ice
#   floor patch (x 11...21, floor on, collision off, surface ice, friction
#   0.1); a kit/parallax layer (follow 1, follow_y 0.5) with a part under it.
#   0. util/kit_plane_check.lua (the 2D queries in a level plane, flat
#      polygons, their zones).
#   1. The plane at the spawn cell's middle y on both sides; every body line
#      at its bottom (the feet held there), few corrections.
#   2. D a little: the camera's followed point kept (the dead zone); D on:
#      through the zone (the client part's on_enter, the server's enter after
#      it), the camera dead_zone behind the body.
#   3. W: the flat wall stops the body (its edge at z 5.5, the body's r 0.45).
#   4. D onto the ice: the step's surface ice and friction 0.1 (the client's
#      prediction, the server agreeing: few corrections); let go, it slides
#      on.
#   5. kit/parallax: what is under the layer drawn moved half the camera's
#      travel along z, none along x or y.
#   6. The editor's plan view: a kit/polygon drawn by clicks lies flat at the
#      plane's height (one place op, pitch 90), its point dragged; the
#      inspector's "Edit in 2D view" shows it in the plan view.
#   7. [RACER_FEEL] (4) In the plan a right drag and a middle drag pan it,
#      neither into 3D (kit_racer_web_check: the editor first in the plan).
#   8. [RACER_FEEL] (2), (3) The zone's client part: kit.shake(2) in the
#      frame it asked; 100 kit.effect bursts at once (a burst cap dropping
#      some), 1100 kit.mark (1024 kept).
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
check_tmp kit_top_down; t=$CHECK_TMP
cd "$here/Build"

export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
n=0
edit() # <op json>: an edit and its answer
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" $n
}
set_p() # <id> <param> <json value>
{
	edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
}
flat() # <x> <y> <z> <points> [more params]: a kit/polygon lying flat
{
	edit "{\"op\": \"place\", \"type\": \"kit/polygon\", \"pos\": [$1, $2, $3], \"pitch\": 90, \"params\": {\"points\": $4${5:+, $5}}}"
}
hold() # <key> <ms...>: held that long (delays of 1 s at most)
{
	local k=$1
	shift
	echo "keydown $k"
	for d in "$@"; do echo "delay $d"; done
	echo "keyup $k"
}
# The zone's type: on_enter on the server and in its client part
python3 -I - > "$t/type.cmd" <<'PY'
import json
src = '''return {
	version = 1,
	component = true,
	zone = "look",
	about = {group = "Game", what = "kit_top_down_check's zone"},
	on_enter = function(c, by)
		c:log("entered by", c:name(by))
	end,
}'''
cl = '''local kit = require("buildat/module/kit")
return {
	on_enter = function(e)
		e:log("tdzone on_enter")
		kit.shake(2)
		local p = e.node.position
		for i = 1, 100 do
			kit.effect{at = {p.x, p.y + 0.5, p.z}, count = 4, shape = "round",
				colors = {"#808080"}, speed_min = 1, ttl_min = 0.5, size_min = 0.2}
		end
		for i = 1, 1100 do
			kit.mark(p.x + i * 0.01, p.y, p.z, i, {0.25, 0.5}, "#202020")
		end
		e:log("tdzone effects asked")
	end,
}'''
print("event kit_type " + json.dumps({"op": "put", "name": "tdzone", "source": src,
	"client": cl}))
PY
WALL=5 ICE=6 ZONE=7 LAYER=8 UNDER=9 DRAWN=10
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
	edit '{"op": "place", "type": "kit/controls", "pos": [0, 1, 0]}'
	set_p 3 plane '"horizontal"'
	set_p 3 camera '"top_down"'
	set_p 3 angle 90
	set_p 3 height 12
	set_p 3 ortho true
	set_p 3 dead_zone 3
	# (4: nothing; the ids from 5 on as named above)
	edit '{"op": "place", "type": "kit/part", "pos": [-30, 1, -30]}'
	flat 8 1 6 '[[-8, -0.5], [8, -0.5], [8, 0.5], [-8, 0.5]]' '"depth": 2'
	flat 16 0.5 3 '[[-5, -5], [5, -5], [5, 5], [-5, 5]]' '"depth": 0.1, "collision": false, "floor": true, "surface": "ice", "friction": 0.1, "color": "#c0e8ff"'
	flat 6 1 1 '[[-1, -2], [1, -2], [1, 2], [-1, 2]]' '"depth": 2, "collision": false, "color": "#e0c040"'
	cat "$t/type.cmd"
	echo "wait_log 10000 tdzone: Saved"
	n=$((n + 1))
	edit "{\"op\": \"add_component\", \"id\": $ZONE, \"type\": \"local/tdzone\"}"
	edit '{"op": "place", "type": "kit/parallax", "pos": [0, 1, 0], "params": {"follow": 1, "follow_y": 0.5}}'
	edit "{\"op\": \"place\", \"type\": \"kit/part\", \"pos\": [0, -2, 12], \"parent\": $LAYER}"
	cat <<EOF
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: controls: camera top_down, pointer cursor, movement kit/walker, plane y
wait_log_any 10000 kit: entity $UNDER under parallax layer $LAYER
frames 30
event kit_body
event kit_parallax $UNDER
EOF
	hold D 300
	echo "frames 20"
	echo "event kit_body"
	hold D 700 700
	cat <<EOF
wait_log_any 5000 kit: entity $ZONE's client part: tdzone on_enter
wait_log_any 5000 kit: entity $ZONE's client part: tdzone effects asked
frames 2
event kit_effects
frames 20
event kit_body
EOF
	hold W 800 800
	cat <<EOF
frames 30
event kit_body
event kit_parallax $UNDER
EOF
	hold D 600
	cat <<EOF
event kit_body
frames 90
event kit_body
screenshot $t/top.png
keypress F6
wait_log 10000 kit editor: state:
keypress F1
wait_log_any 5000 kit editor: the view is 2D
click Button "Grid*"
wait_log 5000 kit editor: grid 1/2
click Button "Grid*"
wait_log 5000 kit editor: grid 1/4
EOF
	# 6. A polygon drawn in the plan view by clicks, closed on its first point;
	# its second point dragged
	pal_find kit/polygon
	cat <<'EOF'
click Button "kit/polygon"
wait_log 5000 kit editor: placing
mouse_pos 400 200
frames 3
mouse_click left
wait_log 5000 kit editor: polygon point 1 at
mouse_pos 600 200
frames 3
mouse_click left
wait_log 5000 kit editor: polygon point 2 at
mouse_pos 600 400
frames 3
mouse_click left
wait_log 5000 kit editor: polygon point 3 at
mouse_pos 400 400
frames 3
mouse_click left
wait_log 5000 kit editor: polygon point 4 at
mouse_pos 400 200
frames 3
mouse_click left
wait_log 5000 kit editor: placed kit/polygon at
EOF
	n=$((n + 1))
	cat <<EOF
wait_log_any 10000 entities, $n to undo
frames 10
mouse_pos 600 200
frames 3
mouse_down left
frames 3
mouse_pos 620 190
frames 3
mouse_pos 650 180
frames 3
mouse_up left
wait_log 5000 point 2 moved, 4 points
wait_log_any 10000 entities, $((n + 1)) to undo
frames 10
screenshot $t/plan.png
keypress F2
wait_log 5000 kit editor: the view is 3D
event kit_select $DRAWN
wait_log 5000 kit editor: the inspector
frames 3
click Button "Edit in 2D view"
wait_log 5000 kit editor: polygon $DRAWN in the plan view at
frames 3
mouse_pos 500 350
frames 3
mouse_down right
frames 3
mouse_pos 560 380
frames 3
mouse_pos 620 400
frames 3
mouse_up right
wait_log 5000 kit editor: panned the plan to
mouse_down middle
frames 3
mouse_pos 500 300
frames 3
mouse_up middle
wait_log 5000 kit editor: panned the plan to
frames 3
quit
EOF
} > "$t/boss.cmds"
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
grep -a "kit: body \|kit: controls:\|top_down camera\|parallax: entity\|tdzone\|placed\|refused\|moved" "$c" |
	sed 's/^.*kit *: //' | cut -c1-150
near() { awk -v a="$1" -v b="$2" -v e="$3" 'BEGIN { exit !((a - b) ^ 2 <= e * e) }'; }
body() # <n>: the nth "body at" line as x y z acks corrections
{
	grep -aoP 'kit: body at \K.*' "$c" | sed -n "$1p" |
		sed -E 's/([-0-9.]+),([-0-9.]+),([-0-9.]+), ([0-9]+) acks, ([0-9]+) corrections.*/\1 \2 \3 \4 \5/'
}
on() # <n>: the nth "body on" line's surface and friction
{
	grep -aoP 'kit: body on \K.*' "$c" | sed -n "$1p" | sed -E 's/, friction / /'
}
cam() # <n>: the nth top_down camera's followed x z
{
	grep -aoP 'kit: top_down camera at \K[-0-9.]+,[-0-9.]+' "$c" | sed -n "$1p" | tr ',' ' '
}
# 1. The plane
py=$(grep -aoP "kitboss's plane: y \K[-0-9.]+" "$s" | tail -1)
[ -n "$py" ] || fail "the server put no level plane ($s)"
grep -aq "plane y $py" "$c" || fail "the client's controls not at plane y $py ($c)"
feet=$(awk -v p="$py" 'BEGIN { printf "%.2f", p - 0.5 }')
[ "$(grep -ac 'kit: body at' "$c")" = 6 ] || fail "not 6 body lines ($c)"
for k in 1 2 3 4 5 6; do
	read -r x y z acks corr <<< "$(body $k)"
	[ "$y" = "$feet" ] || fail "off the plane's floor ($feet): $(body $k)"
done
[ "$corr" -le 2 ] || fail "$corr corrections: $(body 6)"
echo "ok: the level plane at y $py on both sides, the feet held at $feet throughout, $corr corrections"
# 2. The dead zone, the zone
read -r x1 y z1 rest <<< "$(body 1)"
read -r x2 y z2 rest <<< "$(body 2)"
read -r x3 y z3 rest <<< "$(body 3)"
read -r cx1 cz1 <<< "$(cam 1)"
read -r cx2 cz2 <<< "$(cam 2)"
read -r cx3 cz3 <<< "$(cam 3)"
awk -v a="$x1" -v b="$x2" 'BEGIN { exit !(b - a > 0.5 && b - a < 2.8) }' ||
	fail "D a little not 0.5...2.8 along x: $x1 -> $x2"
near "$cx2" "$cx1" 0.01 || fail "the camera moved within its dead zone: $cx1 -> $cx2 (the body $x1 -> $x2)"
near "$cx3" "$(awk -v x="$x3" 'BEGIN { print x - 3 }')" 0.1 ||
	fail "the camera not dead_zone (3) behind the body: $cx3 for $x3"
echo "ok: the top_down camera kept its point while the body went $x1 -> $x2 (dead zone 3), then followed 3 behind: $cx3 for $x3"
ct=$(grep -am1 "kit: entity $ZONE's client part: tdzone on_enter" "$c" | awk '{ print $3 }')
st=$(grep -am1 "Entity $ZONE: kitboss enters its zone" "$s" | awk '{ print $3 }')
[ -n "$ct" ] && [ -n "$st" ] || fail "the flat zone not entered: client '$ct', server '$st' ($c, $s)"
grep -aq "kit: entity $ZONE's zone entered (this client)" "$c" || fail "no client zone line ($c)"
echo "ok: the flat polygon's zone: the client part's on_enter at $ct, the server's enter at $st"
# 3. The wall
read -r x4 y z4 rest <<< "$(body 4)"
near "$z4" 5.05 0.01 || fail "not stopped by the flat wall at z 5.05: $(body 4)"
echo "ok: the flat wall stopped the body at z $z4"
# 4. The ice
read -r x5 y z5 rest <<< "$(body 5)"
read -r x6 y z6 rest <<< "$(body 6)"
read -r sf5 fr5 <<< "$(on 5)"
read -r sf6 fr6 <<< "$(on 6)"
[ "$sf6" = ice ] && [ "$fr6" = 0.1 ] || fail "not on the ice: $(on 6) at $(body 6)"
awk -v a="$x5" -v b="$x6" 'BEGIN { exit !(a > 11 && b - a > 2 && b < 21) }' ||
	fail "not slid on the ice after letting go: $x5 -> $x6"
echo "ok: the ice floor's surface and friction in the step ($sf6, $fr6), slid $x5 -> $x6 let go"
# 5. kit/parallax: follow 1 along x, follow_y 0.5 along z
par() # <k>: the kth parallax line: drawn x y z, authored x y z, camera z
{
	grep -aoP "kit: parallax: entity $UNDER drawn at \\K.*" "$c" | sed -n "$1p" | sed -E \
		's/^([-0-9.]+),([-0-9.]+),([-0-9.]+), authored ([-0-9.]+),([-0-9.]+),([-0-9.]+), [0-9]+ copies, the camera [-0-9.]+,[-0-9.]+,([-0-9.]+).*/\1 \2 \3 \4 \5 \6 \7/'
}
for k in 1 2; do
	read -r dx dy dz ax ay az pcz <<< "$(par $k)"
	[ -n "$pcz" ] && [ "$dx" = "$ax" ] && [ "$dy" = "$ay" ] &&
		near "$(awk -v d="$dz" -v a="$az" -v c="$pcz" 'BEGIN { print (d - a) - 0.5 * c }')" 0 0.01 ||
		fail "parallax $k: not half the camera's z (follow_y 0.5) and none along x, y: $(par $k)"
done
near "$pcz" 0 2 && fail "the camera did not move along z for the parallax: $(par 2)"
echo "ok: kit/parallax in a level plane: drawn half the camera's travel along z, none along x, y: $(par 2)"
# 6. The editor
at=$(grep -aoP 'kit editor: placed kit/polygon at \K[-0-9.]+,[-0-9.]+,[-0-9.]+(?= lying flat, 4 points)' "$c")
[ -n "$at" ] || fail "no flat polygon of 4 points placed in the plan view ($c)"
[ "$(echo "$at" | cut -d, -f2)" = "$py" ] || fail "the drawn polygon not at the plane's y ($py): $at"
grep -aq "An edit by kitboss: placed kit/polygon $DRAWN at " "$s" || fail "polygon $DRAWN not placed ($s)"
grep -aq "set $DRAWN's kit/polygon points to" "$s" || fail "polygon $DRAWN's point not dragged ($s)"
grep -aq "kit editor: polygon $DRAWN in the plan view at" "$c" || fail "the points row's plan view ($c)"
echo "ok: a polygon drawn in the plan view lying flat at $at, its point dragged, the inspector's row back to the plan view"
# 7. [RACER_FEEL] (4) A right drag and a middle one pan the plan, not into 3D
pans=$(grep -aoP 'kit editor: panned the plan to \K[-0-9.]+,[-0-9.]+' "$c" | tr '\n' ' ')
read -r p1 p2 <<< "$pans"
[ -n "${p2:-}" ] && [ "$p1" != "$p2" ] || fail "not panned twice in the plan: $pans ($c)"
sed -n "/polygon $DRAWN in the plan view at/,\$p" "$c" | grep -aq "the view is 3D" &&
	fail "a drag in the plan went into 3D ($c)"
echo "ok: a right drag panned the plan to $p1, a middle one to $p2"
# 8. [RACER_FEEL] (2), (3) The zone's client part on_enter: kit.shake(2) the
# frame it was asked; 100 kit.effect bursts (the rate's cap dropping the rest),
# 1100 kit.mark (the ring keeps 1024)
f=$(grep -aoP "kit: a client part's shake 2 in frame \K[0-9]+" "$c" | head -1)
if [ -n "$f" ]; then
	grep -aq "kit: the camera placed shaken [0-9.]* in frame $f (asked in frame $f)" "$c" ||
		fail "the shake asked in frame $f not placed in it ($c)"
else
	f=$(grep -aoP "kit: a client part's shake 2, the camera moved in frame \K[0-9]+" "$c" | head -1)
	[ -n "$f" ] || fail "no client part's shake ($c)"
fi
fx=$(grep -aoP 'kit: effects: \K.*' "$c" | head -1)
echo "$fx" | grep -qP '^\d+ particles live in \d+ bursts \((\d|[1-5]\d|6[0-4]) a client part.s\); client parts made ([1-9]\d+) particles, ([1-9]\d*) bursts dropped; 1024 marks kept of 1100 made' ||
	fail "the client part's effects and marks: $fx ($c)"
echo "ok: a client part's shake in its own frame ($f); its effects and marks: $fx"
echo "PASS: kit/controls' horizontal plane: the body held at one height, flat polygon walls, a floor's surface, a flat look zone on the client and the server, the top_down camera's dead zone, kit/parallax along z, the plan view's polygon editing, the plan panned by a right or middle drag; a client part's shake, effects and marks"
# vim: set noet ts=4 sw=4:
