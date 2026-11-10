#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~25 s (2026-11-02)
# covers: builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua apps/workbench/**
# [KIT_CAM_MIN_MOVE] The editor's 3D camera under the surface: a fresh
# save on Workbench, a flat World, the camera put 3 cells under the
# ground looking level along +z:
#   - three wheel notches in move it at least 3 cells along the look,
#     one out at least 1 back (the wheel used to stop there);
#   - a middle drag of 200 pixels pans it at least as a point 6 away
#     grabbed would.
# [KIT_WEB_WHEEL_TENTHS] With "web", in headless Chrome: one notch of the wheel,
# 100 CSS pixels, which the web's SDL counts as 10, is one notch in the 2D plan
# (span 50 to 40) and in the 3D view (1 to 2 cells along the look, not 10).
# [KIT_WHEEL_TRACKPAD] Walking with the voxels tool, ten wheel events of 10 CSS
# pixels, a trackpad's notch: one step of the voxel in hand.
#   util/kit_cam_min_move_check.sh
#   util/kit_cam_min_move_check.sh web
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
if [ "${1:-}" = web ]; then
	check_tmp kit_cam_wheel_web; t=$CHECK_TMP
	cat > "$t/steps.json" <<J
[
	["nav", "\${URL}"],
	["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
	["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
	["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "\${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Enter"], ["waitlog", "Joined as webboss", 30],
	["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
	["click", "Button", "Don't add"], ["frames", 3],
	["waitlog", "player physics enabled", 120],
	["waitlog_any", "kit editor: edit rights: yes", 10],
	["waitlog_any", "pause: the menu shown", 10], ["frames", 3],
	["click", "Button", "Edit*"], ["waitlog", "kit editor: state: 1 entities", 20],
	["event", "kit_plan 0 0 50 0"], ["waitlog", "kit editor: the view is 2D", 10], ["frames", 3],
	["mouse", 500, 400], ["frames", 2],
	["event", "kit_cam_where 2d before"], ["sync", 5000],
	["wheel", 500, 400, -100], ["frames", 3],
	["event", "kit_cam_where 2d after"], ["sync", 5000],
	["event", "kit_cam3d 4 -3 0 4 -3 10"], ["waitlog", "kit editor: the view is 3D", 10], ["frames", 3],
	["mouse", 500, 400], ["frames", 2],
	["event", "kit_cam_where 3d before"], ["sync", 5000],
	["wheel", 500, 400, -100], ["frames", 3],
	["event", "kit_cam_where 3d after"], ["sync", 5000],
	["key", "F3"], ["waitlog", "kit editor: the view is Walk", 10], ["frames", 3],
	["key", "v"], ["waitlog", "kit editor: in hand", 10], ["frames", 3],
	["mouse", 500, 400], ["frames", 2],
	$(for _ in $(seq 10); do printf '["wheel", 500, 400, 10], ["frames", 1], '; done)
	["sync", 5000], ["frames", 3]
]
J
	WEB_DRIVE_VIEWPORT=1024x700@1 "$here/util/web_drive.sh" chrome workbench \
		"$t/steps.json" "$t/out" > "$t/drive.txt" 2>&1 ||
		fail "the web drive ($(tail -2 "$t/drive.txt"), $t/out)"
	c=$t/out/page.log
	grep -a 'kit editor: the plan .* across\|the 3D camera at' "$c" | grep -a '(.d ' |
		sed 's/^.*kit editor: /  /'
	span() { grep -aoP "the plan \K\S+(?= across \(2d $1\))" "$c" | tail -1; }
	z3d() { grep -aoP "the 3D camera at \S+ \S+ \K\S+(?= \(3d $1\))" "$c" | tail -1; }
	s0=$(span before) s1=$(span after) z0=$(z3d before) z1=$(z3d after)
	[ -n "$s0" ] && [ -n "$s1" ] && [ -n "$z0" ] && [ -n "$z1" ] ||
		fail "no plan spans or camera places ($c)"
	awk -v a="$s0" -v b="$s1" 'BEGIN { exit !(a == 50 && b > 39.9 && b < 40.1) }' ||
		fail "one notch in the plan: span $s0 -> $s1, not 50 -> 40"
	# 0.8 ^ 1 of 10 ahead (nothing hit) or a cell's least; ten notches went 8.9 or 10
	awk -v a="$z0" -v b="$z1" 'BEGIN { d = b - a; exit !(d >= 0.9 && d <= 2.1) }' ||
		fail "one notch in 3D: z $z0 -> $z1, not 1 to 2 cells"
	# [KIT_WHEEL_TRACKPAD] Ten events of a tenth each, as a trackpad sends a
	# notch: the voxel in hand steps once (it stepped at each)
	hand=$(grep -ac "kit editor: in hand" "$c")
	[ "$hand" = 2 ] ||
		fail "a notch in ten small wheel events: $((hand - 1)) steps of the voxel in hand, not 1 ($c)"
	echo "PASS: in the web client a notch of the wheel zooms the plan and moves the 3D camera by one notch; a notch in ten small events steps the voxel in hand once"
	exit 0
fi
check_tmp kit_cam_min_move; t=$CHECK_TMP
cd "$here/Build"

server() # <n>
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
		--sim-rate "$CHECK_RATE" ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <name>: its commands in $t/<name>.cmds
{
	run_client 60 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/$1.log, $t/srv*.log)"
}
stop()
{
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
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
ed() { printf 'event kit_edit %s\n' "$1"; }
edit() # <json>
{
	n=$((n + 1))
	ed "$1"
	printf 'wait_log 10000 entities, %d to undo\n' "$n"
}
vox() # <x> <y> <z> <voxel>
{
	edit "{\"op\": \"set_voxel\", \"pos\": [$1, $2, $3], \"voxel\": \"$4\"}"
}
info() # <x> <y> <z>
{
	ed "{\"op\": \"voxel_info\", \"pos\": [$1, $2, $3]}"
	echo "sync 5000"
}
refused() # <json> <reason>
{
	ed "$1"
	printf 'wait_log 10000 kit editor: refused: %s\n' "$2"
}
in_scene() # <scene> <scenes>
{
	printf 'wait_log 30000 kit editor: in the scene %s of %s\n' "$1" "$2"
}
joined()
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
EOF
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
EOF
	joined
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	edit '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
	edit '{"op": "set", "id": 3, "comp": 0, "param": "decorations", "value": false}'
	echo "wait_log_any 30000 kit: World: generated again"
	# Under the ground, looking along +z and level: the wheel and a middle
	# drag move the camera even there
	cat <<EOF
event kit_cam3d 4 -3 0 4 -3 10
wait_log_any 5000 kit editor: the view is 3D
frames 3
mouse_pos 512 400
frames 2
event kit_cam_where start
mouse_wheel 1
frames 2
mouse_wheel 1
frames 2
mouse_wheel 1
frames 2
event kit_cam_where wheeled in
mouse_wheel -1
frames 2
event kit_cam_where wheeled out
mouse_down middle
frames 2
mouse_pos 612 400
frames 2
mouse_pos 712 400
frames 2
mouse_up middle
frames 2
event kit_cam_where panned
frames 3
screenshot $t/under.png
sync 5000
quit
EOF
} > "$t/boss1.cmds"
server 1
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss1
stop
c=$t/boss1.log
grep -a ' I kit .*the 3D camera at' "$c" | sed 's/^.*kit editor: /  /'
at() # <what>: x y z
{
	grep -a ' I kit ' "$c" | grep -aoP "the 3D camera at \K\S+ \S+ \S+(?= \($1\))" | tail -1
}
read -r x0 y0 z0 <<<"$(at start)"
read -r x1 y1 z1 <<<"$(at "wheeled in")"
read -r x2 y2 z2 <<<"$(at "wheeled out")"
read -r x3 y3 z3 <<<"$(at panned)"
[ -n "${z0:-}" ] && [ -n "${z3:-}" ] || fail "no camera positions ($c)"
awk -v a="$z0" -v b="$z1" -v c="$z2" 'BEGIN { exit !(b - a >= 2.9 && c - b <= -0.9) }' ||
	fail "the wheel under the ground: z $z0 -> $z1 -> $z2, not 3 in and 1 back ($c)"
echo "ok: under the ground the wheel moved the camera $z0 -> $z1 (3 notches in), -> $z2 (1 out)"
awk -v a="$x2" -v b="$x3" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d >= 0.5) }' ||
	fail "the middle drag under the ground: x $x2 -> $x3, not at least 0.5 ($c)"
echo "ok: the middle drag panned it x $x2 -> $x3"
[ -s "$t/under.png" ] || fail "no screenshot ($t/under.png)"
echo "PASS: the 3D camera under the ground: the wheel moves it a cell a notch at least, a middle drag pans it at least as if 6 away"
# vim: set noet ts=4 sw=4:
