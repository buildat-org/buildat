#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~40 s (2026-11-07)
# covers: builtin/kit/kit.cpp
# [KIT_TEMPLATE_ROUGH_EDGES] In Workbench's world project, Stopped: a
# kit/spawner of players 3 at 8, 1, 8 and a kit/part 4 wearing a voxel no
# scene has (kit/nonsense):
#   - Play warns the builder of the voxel's name;
#   - leaving a draft made in play, kitboss is put on the spawner (a
#     Stopped leave: kit_templates_check's logs, "joins Stopped");
#   - kitboss joining again with the server Stopped is put on the spawner,
#     not at the World's middle.
#   util/kit_stopped_join_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_stopped_join; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss

n=0
edit() # <json>
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
event kit_edit {"op": "mode", "on": true}
wait_log_any 10000 kit editor: edit mode on
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	edit '{"op": "place", "type": "kit/spawner", "pos": [8, 1, 8]}'
	edit '{"op": "set", "id": 3, "comp": 0, "param": "players", "value": true}'
	edit '{"op": "place", "type": "kit/part", "pos": [4, 1, 4]}'
	edit '{"op": "set", "id": 4, "comp": 0, "param": "voxel", "value": "kit/nonsense"}'
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit: warning: World: entity 4's kit/part voxel: no voxel kit/nonsense
event kit_edit {"op": "draft"}
wait_log_any 30000 kit editor: in session 1 draft
sync 2000
event kit_edit {"op": "leave_draft"}
wait_log 30000 kit editor: in session 0 default
sync 2000
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
sync 2000
quit
EOF
} > "$t/boss.cmds"
cat > "$t/again.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
sync 2000
quit
EOF
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	run_client 60 "$t/boss.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/boss.cmds" || fail "the client failed ($t/boss.log, $t/srv.log)"
run_client 60 "$t/again.log" timeout 120 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
	-c @"$t/again.cmds" || fail "the second join failed ($t/again.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
grep -a "no voxel kit/nonsense\|joins Stopped" "$t/srv.log" | sed 's/^.*kit     : /  /'
[ "$(grep -ac "joins Stopped" "$t/srv.log")" = 1 ] ||
	fail "not one Stopped join on a spawner ($t/srv.log)"
grep -aq "kitboss joins Stopped: put on spawner 3 at (8, 1, 8)" "$t/srv.log" ||
	fail "the second join not put on spawner 3 ($t/srv.log)"
grep -aA12 "from session 1 to session 0" "$t/srv.log" |
	grep -aq "spawner teleports kitboss to (8, 1, 8)" ||
	fail "leaving the draft not put on spawner 3 ($t/srv.log)"
echo "PASS: stopped join: an unknown voxel name warned at Play, a join while Stopped put on the spawner"
# vim: set noet ts=4 sw=4:
