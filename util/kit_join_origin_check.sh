#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-08)
# covers: builtin/kit/kit.cpp builtin/kit/types/trigger_zone.lua
# [KIT_JOIN_ORIGIN_POSITION] A player joining is nowhere until the spawn puts
# them: on a fresh Workbench project (flat stone) a kit/trigger_zone over the
# origin's ground and a spawner away from it. kitboss, Running, walks into the
# zone (Walk here's op: it is entered) and out; kitbob joins, and kitboss
# again: neither enters it (the app's place before the spawner's was the
# origin's ground).
#   util/kit_join_origin_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_join_origin; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_JOIN_PASSWORD=checkpass12
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
native() # <name>
{
	run_client 60 "$t/$1.log" timeout 180 bin/buildat -C "$t/client_cache_$1" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" || fail "client $1 ($t/$1.log, $t/srv.log)"
}
ed() { printf 'event kit_edit %s\nsync 5000\n' "$1"; }
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
EOF
	# (kitboss away from the origin before the zone is there)
	ed '{"op": "walk_here", "pos": [10, 0.5, 10]}'
	ed '{"op": "place", "type": "kit/trigger_zone", "pos": [-1, 0, -1]}'
	ed '{"op": "set", "id": 3, "comp": 0, "param": "size", "value": [3, 3, 3]}'
	ed '{"op": "place", "type": "kit/spawner", "pos": [10, 1, 10]}'
	ed '{"op": "set", "id": 4, "comp": 0, "param": "players", "value": true}'
	ed '{"op": "walk_here", "pos": [0, 0.5, 0]}'
	ed '{"op": "walk_here", "pos": [10, 0.5, 10]}'
	printf 'sync 3000\nquit\n'
} > "$t/boss.cmds"
printf 'wait_log_any 60000 Joined as %s\nwait_log_any 60000 player physics enabled\nsync 3000\nquit\n' \
	kitbob > "$t/bob.cmds"
printf 'wait_log_any 60000 Joined as %s\nwait_log_any 60000 player physics enabled\nsync 3000\nquit\n' \
	kitboss > "$t/boss2.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" native boss
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 native bob
BUILDAT_JOIN_NAME=kitboss native boss2
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
grep -a "its zone at\|walks here\|put on spawner\|is Running" "$t/srv.log" | sed 's/^.*kit *: /  /'
n=$(grep -ac "Entity 3: kitboss enters its zone" "$t/srv.log")
[ "$n" = 1 ] || fail "kitboss entered the zone $n times, not once by the walk ($t/srv.log)"
grep -aq "Entity 3: kitbob enters its zone" "$t/srv.log" &&
	fail "kitbob entered the zone at the origin on joining ($t/srv.log)"
grep -aq "kitbob's\|kitbob .*spawn\|kitbob put" "$t/srv.log" ||
	fail "kitbob never put ($t/srv.log)"
echo "PASS: the zone over the origin's ground entered by a walk, not by a join"
# vim: set noet ts=4 sw=4:
