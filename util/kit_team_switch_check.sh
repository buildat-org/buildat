#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~40 s (2026-11-08)
# covers: builtin/kit/kit.cpp builtin/kit/types/team.lua builtin/kit/types/health.lua
# [KIT_TEAM_JOIN_LEAVES_OTHERS] A join leaves the scene's other teams: on a
# fresh Workbench project (flat stone) Red (3) and Blue (4), a players'
# spawner (5) and a deadly kit/trigger_zone (6). kitboss, Running, joins Blue
# then Red (the inspector's Try), and walks into the zone (Walk here's op):
# out of Blue, and his respawn is on Red's pad, not Blue's.
#   util/kit_team_switch_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_team_switch; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
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
	ed '{"op": "place", "type": "kit/team", "pos": [5, 1, 0]}'
	ed '{"op": "place", "type": "kit/team", "pos": [-5, 1, 0]}'
	ed '{"op": "set", "id": 4, "comp": 0, "param": "name", "value": "Blue"}'
	ed '{"op": "place", "type": "kit/spawner", "pos": [0, 1, 8]}'
	ed '{"op": "set", "id": 5, "comp": 0, "param": "players", "value": true}'
	ed '{"op": "place", "type": "kit/trigger_zone", "pos": [0, 0, -10]}'
	ed '{"op": "set", "id": 6, "comp": 0, "param": "size", "value": [3, 3, 3]}'
	ed '{"op": "set", "id": 6, "comp": 0, "param": "deadly", "value": true}'
	# (Blue first: respawn_at takes the last team found, in id order)
	ed '{"op": "try", "id": 4, "input": "join", "value": null}'
	ed '{"op": "try", "id": 3, "input": "join", "value": null}'
	ed '{"op": "walk_here", "pos": [1, 0.5, -9]}'
	printf 'sync 3000\nquit\n'
} > "$t/boss.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 BUILDAT_JOIN_ADMIN="setting open_registration on" \
	run_client 60 "$t/boss.log" timeout 180 bin/buildat -C "$t/client_cache" -D "$t/cu" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -c @"$t/boss.cmds" ||
	fail "the client ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
grep -a "joins team\|left it for\|respawns at\|enters its zone\|died" "$t/srv.log" | sed 's/^.*kit *: /  /'
for w in "kitboss joins team Red" "kitboss joins team Blue" \
		"Entity 4's kit/team: player [0-9]* left it for entity 3" "kitboss respawns at entity 3"; do
	grep -aq "$w" "$t/srv.log" || fail "no \"$w\" ($t/srv.log)"
done
echo "PASS: a team's join leaves the other team; the respawn on the team joined"
# vim: set noet ts=4 sw=4:
