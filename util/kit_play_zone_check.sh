#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~30 s (2026-11-09)
# covers: builtin/kit/kit.cpp builtin/kit/types/arena.lua builtin/kit/types/spawner.lua
# [KIT_TEMPLATE_ROUGH_EDGES] One standing in an arena's zone at Play whom a
# spawner puts elsewhere never enters it: kitboss (Workbench's admin)
# Ends the round, places a kit/arena 4 (a 20 m zone round him, 1 player)
# and a kit/spawner 5 of players 30 m off, and Plays. Before, the arena
# counted him in, started its countdown and cancelled it a tick later.
#   util/kit_play_zone_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_play_zone; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_JOIN_PASSWORD=checkpass12 \
	BUILDAT_JOIN_NAME=kitboss
cat > "$t/boss.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log_any 10000 kit editor: the server is Ended
event kit_edit {"op": "place", "type": "kit/arena", "pos": [-10, 0, -10]}
wait_log 10000 entities, 1 to undo
event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "size", "value": [20, 6, 20]}
wait_log 10000 entities, 2 to undo
event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "players", "value": 1}
wait_log 10000 entities, 3 to undo
event kit_edit {"op": "place", "type": "kit/spawner", "pos": [30, 1, 30]}
wait_log 10000 entities, 4 to undo
event kit_edit {"op": "set", "id": 4, "comp": 0, "param": "players", "value": true}
wait_log 10000 entities, 5 to undo
event kit_edit {"op": "play"}
wait_log_any 10000 kit editor: the server is Running
sync 3000
idle 500
sync 3000
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
	run_client 60 "$t/boss.log" timeout 120 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
	-c @"$t/boss.cmds" || fail "the client failed ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -aq "Entity 4's kit/spawner teleports kitboss to (30, 1, 30)" "$s" ||
	fail "the spawner did not put kitboss at Play ($s)"
awk '/Play by kitboss/ { p = 1 } p && /Entity 3: kitboss enters its zone|kit\/arena 3: countdown/ { bad = 1 }
	END { exit !p || bad }' "$s" ||
	fail "kitboss entered the arena's zone at Play, or no Play ($s)"
echo "PASS: one a spawner puts elsewhere at Play is not counted into the zone they stood in"
