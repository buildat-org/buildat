#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~30 s (2026-11-02)
# covers: builtin/kit/client_lua/editor.lua builtin/kit/kit.cpp apps/workbench/**
# [KIT_BOX_ADJUST] The Box tool's box adjusted after its two corners. A
# fresh save on Workbench, the admin Ended, a flat World, a sign placed
# and selected first (the selection and the box copy together):
#   - the Box tool on, a box from (6,1,4) to (8,2,10): the inspector's
#     Box fields typed (its depth 7 to 5, its x 6 to 9);
#   - its +y face's handle dragged up the screen (taller), the whole box
#     moved along x by Shift and its +x handle, its -z face dragged in;
#   - Ctrl+C: the server copies the sign and the box as adjusted.
#   A screenshot of the box and its handles.
#   util/kit_box_adjust_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_box_adjust; t=$CHECK_TMP
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
drag() # <handle> <shift 0/1> <x> <y> <dx> <dy>...: the pointer's steps
{
	local name=$1 sh=$2 x=$3 y=$4
	shift 4
	printf 'event kit_box_where %s\nwait_log_any 5000 kit editor: box handle %s on the screen at %d, %d\n' "$name" "$name" "$x" "$y"
	printf 'mouse_pos %d %d\nframes 2\n' "$x" "$y"
	[ "$sh" = 1 ] && echo "keydown shift"
	echo "mouse_down left"
	if [ "$sh" = 1 ]; then
		echo "wait_log 5000 kit editor: box handle $name, moving the box"
	else
		echo "wait_log 5000 kit editor: box handle $name"
	fi
	while [ $# -ge 2 ]; do
		printf 'mouse_pos %d %d\nframes 2\n' $((x + $1)) $((y + $2))
		shift 2
	done
	echo "mouse_up left"
	[ "$sh" = 1 ] && echo "keyup shift"
	return 0
}
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
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	edit '{"op": "set", "id": 3, "comp": 0, "param": "decorations", "value": false}'
	echo "wait_log_any 30000 kit: World: generated again"
	# 4: the sign, selected before the Box tool
	edit '{"op": "place", "type": "kit/sign", "pos": [7, 1, 6]}'
	cat <<EOF
event kit_select 4
event kit_cam3d 2 9 -4 13 1.5 4
wait_log_any 5000 kit editor: the view is 3D
frames 5
keypress b
wait_log 5000 kit editor: tool box
event kit_box 6 1 4 8 2 10
wait_log_any 5000 kit editor: box 6,1,4,8,2,10
frames 3
click LineEdit "7"
keypress End
keypress Backspace
text 5
wait_log 5000 kit editor: box 6,1,4,8,2,8 (typed size d)
click LineEdit "6"
keypress End
keypress Backspace
text 9
wait_log 5000 kit editor: box 9,1,4,11,2,8 (typed at x)
frames 3
EOF
	# Each handle where it was seen on the screen (the camera fixed): the
	# button pressed there, the pointer moved by the steps, let go
	drag +y 0 363 322 0 -40 0 -80
	echo 'wait_log 5000 (face +y by'
	drag +x 1 422 309 30 0 60 0
	echo 'wait_log 5000 (moved +x by'
	drag -z 0 518 339 0 40 0 80
	echo 'wait_log 5000 (face -z by'
	cat <<EOF
frames 10
screenshot $t/box.png
keydown ctrl
keypress c
keyup ctrl
wait_log 5000 kit editor: copy of 1 entities and the box
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
s=$t/srv1.log c=$t/boss1.log
grep -a ' I kit ' "$c" | grep -a "kit editor: box\|kit editor: copy" | sed 's/^.*kit editor: /  /'
grep -a "copied" "$s" | sed 's/^.*kit *: /  /'
box() # <n>: the n'th box line's six numbers
{
	grep -a ' I kit ' "$c" |
		grep -aoP 'kit editor: box \K-?\d+(,-?\d+){5}(?= \()' | sed -n "$1p" | tr , ' '
}
read -r x0 y0 z0 x1 y1 z1 <<<"$(box 3)"
[ "$x0 $y0 $z0 $x1 $z1" = "9 1 4 11 8" ] && [ "$y1" -gt 2 ] ||
	fail "the +y drag: $(box 3), not 9 1 4 11 >2 8 ($c)"
h=$y1
read -r x0 y0 z0 x1 y1 z1 <<<"$(box 4)"
d=$((x0 - 9))
[ "$d" -gt 0 ] && [ "$x1" = $((11 + d)) ] && [ "$y0 $y1 $z0 $z1" = "1 $h 4 8" ] ||
	fail "the moved box: $(box 4), not 9..11 moved along x alone ($c)"
read -r x0 y0 z0 x1 y1 z1 <<<"$(box 5)"
dz=$((z0 - 4))
[ "$dz" -ne 0 ] && [ "$z1" = 8 ] ||
	fail "the -z drag: $(box 5), its -z face not moved alone ($c)"
echo "ok: the box typed (depth, x), its +y face dragged up, moved along x, its -z face dragged ($(box 5))"
w=$((x1 - x0 + 1)) hh=$((y1 - y0 + 1)) dd=$((z1 - z0 + 1))
want "$s" "kitboss copied 1 entities and a box of [$w,$hh,$dd] voxels"
echo "ok: the sign selected first and the adjusted box copied together"
[ -s "$t/box.png" ] || fail "no screenshot ($t/box.png)"
echo "PASS: the Box tool's box adjusted: typed in the inspector, its faces' handles dragged, moved with Shift; copied with the selection"
# vim: set noet ts=4 sw=4:
