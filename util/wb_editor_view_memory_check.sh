#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~40 s (2026-11-04)
# covers: builtin/kit/client_lua/editor.lua apps/workbench/**
# [WB_EDITOR_VIEW_MEMORY] Workbench remembers how the user left the editor
# in a project, on the user's machine: kitboss on a fresh project goes to
# edit mode, stops the game, goes to 3D with the camera put somewhere and
# wheeled, picks the palette's Favourites tab, the panel's Entities tab
# and the list's Positioned tab, and quits. The server restarts on the
# same port (the client's storage is the address's); kitboss joins again
# and is in edit mode, the game Ended, the view 3D with the camera where
# it was left, the same tabs. The memory is in the client's user
# directory and nowhere in the server's (the project's save), so a
# published or exported project carries none of it.
# [KIT_TABS_TWO_ROWS] KEEP_TMP=1 keeps left.png (the panel's tabs in two
# rows: Components, Terrain, Voxels; Box, Entities).
#   util/wb_editor_view_memory_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp wb_editor_view_memory; t=$CHECK_TMP
cd "$here/Build"

server() # <n> <port>
{
	start_server "$t/srv$1.log" "Listening at" 300 "$2" \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <name>: its commands in $t/<name>.cmds
{
	run_client 60 "$t/$1.log" timeout 180 bin/buildat -C "$t/client_cache" \
		-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/$1.log, $t/srv*.log)"
}
stop()
{
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss

cat > "$t/boss1.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
wait_log_any 10000 kit editor: remembered for workbench_world: nothing
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
event kit_cam3d 6 8 -6 0 1 0
wait_log_any 5000 kit editor: the view is 3D
frames 3
mouse_pos 512 400
frames 2
mouse_wheel 1
frames 3
click Button "Favourites"
wait_log 5000 kit editor: the palette's Favourites tab
frames 3
click Button "Entities"
wait_log 5000 kit editor: the panel's Entities tab
frames 3
click Button "Positioned*"
frames 5
screenshot $t/left.png
event kit_tabs left
event kit_cam_where left
delay 2500
quit
EOF
server 1 auto
port=$SERVER_PORT
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 client boss1
stop

cat > "$t/boss2.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: remembered for workbench_world: edit, 3d, Entities
wait_log_any 10000 kit editor: edit mode on
wait_log_any 10000 kit editor: the view is 3D
frames 5
screenshot $t/back.png
event kit_tabs back
event kit_cam_where back
quit
EOF
wait_quiet
server 2 "$port"
client boss2
stop

l1=$t/boss1.log l2=$t/boss2.log
grep -a ' I kit .*kit editor: \(remembered\|the view\|the 3D camera at\|edit mode\|the server is\)' \
	"$l1" "$l2" | sed 's/^.*kit editor: /  /'
tabs() { grep -aoP "kit editor: the view \K.*(?= \($2\))" "$1" | tail -1; }
cam() { grep -aoP "the 3D camera at \K\S+ \S+ \S+(?= \($2\))" "$1" | tail -1; }
want_tabs="3d, the tabs Entities, Positioned, Favourites"
[ "$(tabs "$l1" left)" = "$want_tabs" ] ||
	fail "left with \"$(tabs "$l1" left)\", not \"$want_tabs\" ($l1)"
[ "$(tabs "$l2" back)" = "$want_tabs" ] ||
	fail "back to \"$(tabs "$l2" back)\", not \"$want_tabs\" ($l2)"
c1=$(cam "$l1" left) c2=$(cam "$l2" back)
[ -n "$c1" ] && [ "$c1" = "$c2" ] ||
	fail "the 3D camera left at \"$c1\", back at \"$c2\" ($l1, $l2)"
[ "$c1" != "6.00 8.00 -6.00" ] || fail "the wheel did not move the camera ($l1)"
grep -aq "kit editor: the server is Ended" "$l2" ||
	fail "the game not Stopped after the restart ($l2)"
grep -aq "kit editor: the server is Running" "$l2" &&
	fail "the game Running after the restart ($l2)"
echo "ok: edit mode, Ended, 3D at $c1, the tabs Entities, Positioned, Favourites: all back"
mem=$t/cu/servers/localhost_$port/kit_editor_workbench_world
[ -s "$mem" ] || fail "no memory at $mem ($(find "$t/cu" -name 'kit_editor*'))"
sed 's/^/  /' "$mem"
found=$(grep -rlaF -e kit_editor -e "$(sed -n 's/^x //p' "$mem")" "$t/user" 2>/dev/null)
[ -z "$found" ] || fail "the memory in the server's directory too: $found"
echo "PASS: Workbench's editor as left in the project: edit mode, the game stopped, the 3D view and camera, the tabs; kept on the client only"
# vim: set noet ts=4 sw=4:
