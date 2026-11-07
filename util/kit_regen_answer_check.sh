#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~30 s (2026-11-07)
# covers: builtin/kit/kit.cpp
# [KIT_REGEN_ANSWER_LOST] Two World edits at once in Workbench's world
# project: the biome (its sections generated again) and right after it
# decorations (none generated again while the first's are under way). The
# builder is still told the regeneration is done. (--sim-rate 2: both
# edits in one tick, no section loaded again between them.)
#
#   util/kit_regen_answer_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_regen_answer; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
cat > "$t/boss1.cmds" <<'EOF'
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
event kit_edit {"op": "place", "type": "kit/world", "pos": [0, 1, 0]}
wait_log 10000 entities, 1 to undo
event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "biome", "value": "grassland"}
event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "decorations", "value": false}
wait_log 10000 entities, 3 to undo
wait_log 30000 kit: World: generated again
quit
EOF
start_server "$t/srv1.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 --sim-rate 2 ||
	fail "the server did not come up ($t/srv1.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	run_client 60 "$t/boss1.log" timeout 120 bin/buildat -C "$t/client_cache" \
		-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/boss1.cmds" ||
	fail "no \"generated again\" after the two edits ($t/boss1.log, $t/srv1.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
grep -a "World by kitboss: .* sections generated again" "$t/srv1.log" | sed 's/^.* I [a-z_]* *: /  /'
echo "PASS: regen answer: two World edits at once, the builder told the regeneration is done"
# vim: set noet ts=4 sw=4:
