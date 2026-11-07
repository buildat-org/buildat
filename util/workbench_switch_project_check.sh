#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min, more with a cold module cache (2026-11-07)
# covers: apps/workbench/main/** builtin/world_menu/** extensions/pause_menu/**
# [WORKBENCH_SWITCH_PROJECT] An admin switches Workbench's project from
# the pause menu, on a server no launcher started (no local user: the
# admin is kitboss by the setup code), BUILDAT_WORKBENCH_PROJECT=alpha:
#   1. kitboss in alpha: the pause menu has Projects...; in the editor a
#      lever placed and the floor cell (5,0,5) dug.
#   2. kitbob (no admin) joins alpha: no Projects... in the menu, and a
#      main:projects sent anyway refused.
#   3. kitboss again: Projects... lists alpha (running); New "beta":
#      both clients sent off with the switch's goodbye, beta starts.
#   4. kitbob joins again: in beta. kitboss: beta's own (1 entity, no
#      stone floor at the column), then alpha's Play switches back.
#   5. kitboss in alpha: its 2 entities and the dug cell kept; Close
#      project: no project runs, and the next join gets Manage.
# Screenshots: $t/menu_admin.png, menu_bob.png, list_running.png,
# alpha_back.png (KEEP_TMP=1 keeps them).
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp workbench_switch; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

BUILDAT_WORKBENCH_PROJECT=alpha start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
s=$t/srv.log
client() # <name> [env...]: its commands in $t/<name>.cmds; 0 when the drive ran to its quit
{
	local n=$1
	shift
	sed -i "s|@T@|$t|g" "$t/$n.cmds"
	env "$@" timeout 300 bin/buildat -C "$t/client_cache" -D "$t/cu_$n" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 \
		-c @"$t/$n.cmds" > "$t/$n.log" 2>&1
	# A client the server sends off exits with an error: the drive's end
	# says it went through
	! grep -aq "Command sequence failed" "$t/$n.log" &&
		grep -aq "command: quit" "$t/$n.log"
}
# After the switch's line in the server's log
after() # <line> <text>
{
	awk -v a="$1" -v w="$2" 'index($0, a) { s = 1 } s && index($0, w) { f = 1 }
		END { exit !f }' "$s"
}
column(){ grep -ao "workbench: column 5,5: .*" "$1" | sed -n "${2}p"; }
JOINED='wait_log_any 60000 player physics enabled
wait_log_any 30000 kit editor: edit rights:'

# 1.
cat > "$t/boss1.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
$JOINED
sync 5000
idle 20000
event wb_column
keypress Escape
wait_log 5000 pause: the menu shown
frames 3
screenshot @T@/menu_admin.png
click Button "Edit"
wait_log 10000 kit editor: state:
event kit_edit {"op": "place", "type": "kit/lever", "pos": [2, 1, 2]}
wait_log 10000 entities, 1 to undo
event workbench_build {"p": [5, 0, 5], "voxel": "air"}
# the change comes with voxelworld's next commit, after the sync
wait_log 10000 drawn again
idle 20000
event wb_column
quit
EOF
wait_for_log "$s" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$s" | head -1)
[ -n "$code" ] || fail "no setup code ($s)"
client boss1 BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" ||
	fail "kitboss in alpha ($t/boss1.log)"
grep -aq "pause: the items .*Projects\.\.\." "$t/boss1.log" ||
	fail "no Projects... in the admin's menu ($t/boss1.log)"
grep -aqF "workbench: kitboss dug (5,0,5): written" "$s" || fail "the dig ($s)"
a0=$(column "$t/boss1.log" 1) a1=$(column "$t/boss1.log" 2)
[ -n "$a1" ] && [ "$a0" != "$a1" ] || fail "the dig not seen at the column: \"$a0\", \"$a1\" ($t/boss1.log)"
echo "ok: kitboss in alpha, Projects... in the menu, a lever placed, (5,0,5) dug ($a0 -> $a1)"

# 2., held in alpha until the switch sends kitbob off
cat > "$t/bob1.cmds" <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
sync 5000
keypress Escape
wait_log 5000 pause: the menu shown
frames 3
screenshot @T@/menu_bob.png
keypress Escape
wait_log 5000 pause: the menu closed
event workbench_projects
expect_error Disconnected from server: The server switches
wait_log 300000 Disconnected from server: The server switches to the project beta
quit
EOF
client bob1 BUILDAT_JOIN_NAME=kitbob &
bob=$!
CHECK_PIDS+=($bob)
for _ in $(seq 900); do
	grep -aq "Projects... refused" "$s" && break
	kill -0 $bob 2>/dev/null || fail "kitbob's drive ended early ($t/bob1.log)"
	sleep 0.2
done
grep -aqF "workbench: kitbob's Projects... refused: not an admin" "$s" ||
	fail "kitbob's main:projects not refused ($s)"
grep -a "pause: the items " "$t/bob1.log" | grep -q "Projects" &&
	fail "kitbob has Projects... ($t/bob1.log)"
grep -aq "pause: the items Continue" "$t/bob1.log" || fail "kitbob's menu ($t/bob1.log)"
echo "ok: kitbob in alpha: no Projects..., the request refused"

# 3.
cat > "$t/boss2.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
$JOINED
keypress Escape
wait_log 5000 pause: the menu shown
frames 3
click Button "Projects..."
wait_log 10000 world_menu: the list shown, 1 worlds
frames 3
screenshot @T@/list_running.png
click Button "New project..."
wait_log 5000 world_menu: the name screen shown
text beta
expect_error Disconnected from server: The server switches
click Button "Create"
wait_log 60000 Disconnected from server: The server switches to the project beta
quit
EOF
client boss2 BUILDAT_JOIN_NAME=kitboss || fail "the switch to beta ($t/boss2.log)"
wait $bob || fail "kitbob not sent off by the switch ($t/bob1.log)"
wait_for_log "$s" 'workbench: switched to "beta"' 120 || fail "beta did not start ($s)"
want(){ grep -aqF -- "$1" "$s" || fail "no \"$1\" in $s"; }
want 'workbench: kitboss switches the project to beta'
want 'workbench: the project "alpha" closed for the switch'
echo "ok: kitboss made beta from Projects... and the server switched, kitbob sent off"

# 4.
cat > "$t/bob2.cmds" <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
sync 5000
quit
EOF
client bob2 BUILDAT_JOIN_NAME=kitbob || fail "kitbob in beta ($t/bob2.log)"
after 'switched to "beta"' "kitbob" || fail "kitbob not in beta ($s)"
cat > "$t/boss3.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
$JOINED
sync 5000
idle 20000
event wb_column
keypress Escape
wait_log 5000 pause: the menu shown
click Button "Edit"
wait_log 10000 kit editor: state:
keypress Escape
wait_log 5000 pause: the menu shown
frames 3
click Button "Projects..."
wait_log 10000 world_menu: the list shown, 2 worlds
frames 3
click Button "alpha"
wait_log 5000 world_menu: the list shown
frames 3
expect_error Disconnected from server: The server switches
click Button "Play"
wait_log 60000 Disconnected from server: The server switches to the project alpha
quit
EOF
client boss3 BUILDAT_JOIN_NAME=kitboss || fail "beta, and the switch back ($t/boss3.log)"
grep -aq "kit editor: state: 1 entities" "$t/boss3.log" ||
	fail "beta not beta's own: $(grep -ao 'kit editor: state: [0-9]* entities' "$t/boss3.log" | head -1) ($t/boss3.log)"
b=$(column "$t/boss3.log" 1)
[ -n "$b" ] && [ "$b" != "$a1" ] || fail "beta's column is alpha's: \"$b\" ($t/boss3.log)"
wait_for_log "$s" 'workbench: switched to "alpha"' 120 || fail "alpha did not start again ($s)"
echo "ok: kitbob followed into beta; beta's own (1 entity, column $b); back to alpha"

# 5.
cat > "$t/boss4.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
$JOINED
sync 5000
idle 20000
event wb_column
look_dir 0.5 -0.6 0.6
frames 10
screenshot @T@/alpha_back.png
keypress Escape
wait_log 5000 pause: the menu shown
click Button "Edit"
wait_log 10000 kit editor: state:
keypress Escape
wait_log 5000 pause: the menu shown
frames 3
click Button "Projects..."
wait_log 10000 world_menu: the list shown, 2 worlds
frames 3
expect_error Disconnected from server: The project alpha was closed
click Button "Close project"
wait_log 60000 Disconnected from server: The project alpha was closed
quit
EOF
client boss4 BUILDAT_JOIN_NAME=kitboss || fail "alpha again, and its close ($t/boss4.log)"
grep -aq "kit editor: state: 2 entities" "$t/boss4.log" ||
	fail "alpha's lever lost: $(grep -ao 'kit editor: state: [0-9]* entities' "$t/boss4.log" | head -1) ($t/boss4.log)"
a2=$(column "$t/boss4.log" 1)
[ "$a2" = "$a1" ] || fail "alpha's dug cell: \"$a2\", was \"$a1\" ($t/boss4.log)"
wait_for_log "$s" "workbench: no project runs: Manage" 120 || fail "alpha not closed ($s)"
cat > "$t/boss5.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 world_menu: the list shown, 2 worlds
quit
EOF
client boss5 BUILDAT_JOIN_NAME=kitboss || fail "Manage after the close ($t/boss5.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
echo "PASS: an admin switched Workbench from alpha to a new beta and back from the pause menu's Projects..., a second player followed into beta, beta's state its own and alpha's lever and dug cell kept; a non-admin had no Projects... and was refused; Close project left Manage"
# vim: set noet ts=4 sw=4:
