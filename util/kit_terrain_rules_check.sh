#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-09)
# covers: builtin/kit/kit.cpp builtin/kit/types/terrain.lua builtin/kit/client_lua/module.lua builtin/kit/client_lua/editor_input.lua apps/workbench/main/main.cpp
# [KIT_TERRAIN_PLAY_RULES] kit/terrain's dig and place outside every
# kit/region, on a fresh Workbench save: the admin (kitboss), Stopped,
# places an infinite flat World (3), a spawner of players at (3000, 1,
# 3000), past a region's 2048 a side (4), kit/game_rules' building
# "creative" (5) and a kit/region (6, its default dig and place none) at
# (3004, 0, 2996). Running, out of edit mode:
#   1. the World's default (all): his client points at the floor (dig and
#      place) and he places and digs there; a place inside the region is
#      refused ("Protected: no placing here");
#   2. Stopped, the World's dig and place set to none, Running again: his
#      client points at nothing and the same place and dig are refused.
#   util/kit_terrain_rules_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_terrain_rules; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
export BUILDAT_JOIN_PASSWORD=checkpass12
ed() { printf 'event kit_edit %s\n' "$1"; }
n=0
edit() # <json>
{
	n=$((n + 1))
	ed "$1"
	printf 'wait_log 10000 entities, %d to undo\n' "$n"
}
set_() # <id> <param> <value>
{
	edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
}
play()
{
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
wait_log 10000 the server put the player at (300
keypress F6
wait_log 10000 kit editor: edit mode off
EOF
}
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
	set_ 3 size '"infinite"'
	edit '{"op": "place", "type": "kit/spawner", "pos": [3000, 1, 3000]}'
	set_ 4 players true
	edit '{"op": "place", "type": "kit/game_rules", "pos": [0, 1, 0]}'
	set_ 5 building '"creative"'
	edit '{"op": "place", "type": "kit/region", "pos": [3004, 0, 2996]}'
	play
	cat <<'EOF'
look_dir 0 -1 -0.5
wait_log_any 30000 kit: points at dig 3000,0,
event workbench_build {"p": [3000, 1, 3002], "voxel": "kit/stone"}
event workbench_build {"p": [3000, 1, 3002], "voxel": "air"}
event workbench_build {"p": [3005, 1, 2997], "voxel": "kit/stone"}
wait_log 10000 kit: warning: Protected: no placing here
keypress F6
wait_log 10000 kit editor: edit mode on
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	set_ 3 dig '"none"'
	set_ 3 place '"none"'
	play
	cat <<'EOF'
look_dir 0 -1 -0.6
frames 10
wait_log_any 10000 kit: points at nothing
event workbench_build {"p": [3000, 1, 3003], "voxel": "kit/stone"}
wait_log 10000 kit: warning: Protected: no placing here
event workbench_build {"p": [3000, 0, 3003], "voxel": "air"}
wait_log 10000 kit: warning: Protected: no digging here
quit
EOF
} > "$t/boss.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
	run_client 90 "$t/boss.log" timeout 300 bin/buildat -C "$t/client_cache" \
	-D "$t/cu_boss" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
	-c @"$t/boss.cmds" ||
	fail "the client failed ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -a "workbench: kitboss\|workbench: a build" "$s" | sed 's/^.*workbench: /  /' |
	cut -c1-160
want "$s" "workbench: kitboss placed kit/stone (3000,1,3002): written" \
	"workbench: kitboss dug (3000,1,3002): written" \
	"workbench: a build by kitboss refused: not in edit mode and not allowed at (3005,1,2997): Protected: no placing here" \
	"workbench: a build by kitboss refused: not in edit mode and not allowed at (3000,1,3003): Protected: no placing here" \
	"workbench: a build by kitboss refused: not in edit mode and not allowed at (3000,0,3003): Protected: no digging here"
echo "PASS: an infinite World's dig and place: all lets a player build at 3000 from the origin, a region's none still refuses inside it, the World's none refuses (client and server)"
# vim: set noet ts=4 sw=4:
