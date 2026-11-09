#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-03)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/hands.lua
# [KIT_BROADCAST_SESSION] What is the whole server's (item types, voxel
# types, textures, packages, prefabs) reaches every session's players, not
# only the sender's session's. A fresh save on Workbench: the admin
# (kitboss) places a World, an arena (1 player) at (10,1,10) and a
# teleporter into it, plays and leaves. kitbob joins, uses the teleporter:
# the arena makes session 1 with kitbob in it. kitboss joins again (the
# default round) and makes the item type kitboss/blade: kitbob's client,
# in session 1, gets it (9 item types, the presets 8).
#   util/kit_broadcast_session_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_broadcast_session; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client() # <name> <cmds>
{
	run_client 90 "$t/$1.log" timeout 300 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$2.cmds" ||
		fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
export BUILDAT_JOIN_PASSWORD=checkpass12
n=0
edit() # <json>
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
set_() # <id> <param> <value>
{
	edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
}
# 3 the World, 4 the arena, 5 the teleporter
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
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	edit '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/arena", "pos": [10, 1, 10]}'
	set_ 4 players 1
	set_ 4 countdown 0
	set_ 4 duration 0
	set_ 4 results 0
	edit '{"op": "place", "type": "kit/teleporter", "pos": [1, 1, -2]}'
	set_ 5 to '[11, 1, 11]'
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
sync 3000
quit
EOF
} > "$t/boss1.cmds"
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 30000 kit: 8 item types
event kit_use 5
wait_log 120000 kit: 9 item types
sync 2000
quit
EOF
cat > "$t/boss2.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: edit mode on
event kit_edit {"op": "item", "name": "blade", "preset": "kit/sword"}
wait_log 10000 kit: 9 item types
sync 2000
quit
EOF
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss1 boss1
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 client bob bob &
bob=$!
wait_for_log "$t/srv.log" "from session 0 to session 1" 120 ||
	fail "kitbob did not get into the arena's session ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss client boss2 boss2
wait $bob || fail "kitbob's client: no 8th item type in session 1 ($t/bob.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -a "Session \|from session\|made item type" "$s" |
	sed 's/^.*\(kit\|wasm\) *: /  /' | cut -c1-160
grep -aq "kitboss made item type kitboss/blade version 1" "$s" ||
	fail "no item type made ($s)"
python3 - "$s" <<'PY' || fail "kitbob not in session 1 when the item type was made ($s)"
import sys
log = open(sys.argv[1], errors="replace").read()
i = log.index("from session 0 to session 1")
j = log.index("kitboss made item type kitboss/blade")
assert i < j and "Session 1 ended" not in log[i:j]
PY
echo "PASS: kit broadcast to sessions: an item type made in the default round reaches a player in a game session"
# vim: set noet ts=4 sw=4:
