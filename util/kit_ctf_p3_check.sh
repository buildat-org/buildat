#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-04)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/world.h builtin/kit/materials.json builtin/kit/types/arena.lua builtin/kit/types/team.lua builtin/kit/types/timer.lua builtin/kit/types/game_rules.lua apps/workbench/**
# [KIT_CTF] (kit_plan 7b; the capture-the-flag work's rounds and digging)
# On a fresh Workbench save the admin (kitboss) builds a lobby in the
# scene "world" (kit/game_rules with hand_level 0, a spawner, a region to
# dig in, a giver of kit/pickaxe, kit/stone and kit/dirt to dig, a timer
# of 3 repeats whose "left" a ui text shows, a kit/arena placed away from
# the spawn: 1 player, no countdown, a 120 s round, time_up "most", map
# "map") and a scene "map" (its own kit/world, teams Red and Blue, a text
# the arena's status links into). Then,
# Running:
#   1. the timer's left (game seconds): 36, 24, 12, 0 on the screen
#   2. holding the pickaxe, kit/stone dug drops kit/cobble (its drop); a
#      bare hand on kit/stone refused (hand_level 0), on kit/dirt dug
#   3. the arena moved onto the spawn: session 1 in the map's copy, kitboss
#      in Red on its pad there; a point to Red; at time up Red wins (the
#      most), all back in the lobby's scene
#   4. back in the zone, session 2: nobody scores, time up tied 0 : 0 is
#      overtime, shown; a point to Blue: Blue wins; back in the lobby
#   util/kit_ctf_p3_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_ctf_p3; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" ||
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
dig() # <x, y, z>: asked, told to wait, asked again
{
	for _ in 1 2; do
		printf 'event workbench_build {"p": [%s], "voxel": "air"}\nsync 2000\ndelay 1000\n' "$1"
	done
}
# The ids: 3 the World, 4 game_rules, 5 the spawner, 6 the region, 7 the
# giver, 8 the timer, 9 its text, 10 the arena; 11 the scene "map", 12 its
# World, 13 Red, 14 Blue, 15 the text of the arena's status
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
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/game_rules", "pos": [0, 1, 0]}'
	set_ 4 hand_level 0
	edit '{"op": "place", "type": "kit/spawner", "pos": [0, 1, 0]}'
	set_ 5 players true
	edit '{"op": "place", "type": "kit/region", "pos": [-6, 0, -6]}'
	set_ 6 size '[13, 6, 13]'
	set_ 6 dig '"all"'
	edit '{"op": "place", "type": "kit/item_giver", "pos": [-1, 1, -2]}'
	set_ 7 item '"kit/pickaxe"'
	# 1 s real a tick at CHECK_RATE 12
	edit '{"op": "place", "type": "kit/timer", "pos": [3, 1, -3]}'
	set_ 8 interval 12
	set_ 8 repeats 3
	edit '{"op": "place", "type": "kit/ui_text", "pos": [4, 1, -3]}'
	set_ 9 text '"Left {value}"'
	edit '{"op": "link", "id": 8, "comp": 0, "output": "left", "to": 9, "input": "value"}'
	# Away from the spawn until the digs are done; 120 s of game time:
	# 10 s at CHECK_RATE 12, the results 2 s
	edit '{"op": "place", "type": "kit/arena", "pos": [30, 1, 30]}'
	set_ 10 size '[5, 3, 5]'
	set_ 10 players 1
	set_ 10 countdown 0
	set_ 10 duration 120
	set_ 10 results 24
	set_ 10 time_up '"most"'
	set_ 10 map '"map"'
	for v in '2, 1, 2] kit/stone' '3, 1, 2] kit/stone' '4, 1, 2] kit/dirt'; do
		edit "{\"op\": \"set_voxel\", \"pos\": [${v% *}, \"voxel\": \"${v##* }\"}"
	done
	edit '{"op": "new_scene", "name": "map"}'
	echo 'wait_log 30000 kit editor: in the scene map of world, map'
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/team", "pos": [7, 1, 3]}'
	edit '{"op": "place", "type": "kit/team", "pos": [-7, 1, -3]}'
	set_ 13 name '"Red"'
	set_ 14 name '"Blue"'
	# The arena's UI is its scene's: its status on a text in the map
	edit '{"op": "place", "type": "kit/ui_text", "pos": [0, 1, 4]}'
	set_ 15 text '"{value}"'
	edit '{"op": "link", "id": 10, "comp": 0, "output": "status", "to": 15, "input": "value"}'
	cat <<'EOF'
event kit_edit {"op": "scene", "name": "world"}
wait_log 30000 kit editor: in the scene world of world, map
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
event kit_edit {"op": "try", "id": 8, "comp": 0, "input": "start"}
wait_log 30000 : "Left 0"
keypress F6
wait_log 10000 kit editor: edit mode off
event kit_use 7
sync 2000
event kit_hold kit/pickaxe
sync 2000
EOF
	dig '2, 1, 2'
	printf 'event kit_hold\nsync 2000\n'
	dig '3, 1, 2'
	dig '4, 1, 2'
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode on
event kit_edit {"op": "move", "id": 10, "pos": [-2, 1, -2]}
wait_log 60000 kit editor: in session 1 game
wait_log 30000 left | Red 0 : Blue 0"
keypress F6
wait_log 10000 kit editor: edit mode on
event kit_edit {"op": "try", "id": 13, "comp": 0, "input": "add"}
wait_log 60000 Red wins!
wait_log 60000 kit editor: in session 0 default
wait_log 60000 kit editor: in session 2 game
wait_log 60000 Overtime
sync 3000
keypress F6
wait_log 10000 kit editor: edit mode on
event kit_edit {"op": "try", "id": 14, "comp": 0, "input": "add"}
wait_log 60000 Blue wins!
wait_log 60000 kit editor: in session 0 default
sync 2000
quit
EOF
} > "$t/boss.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
	run_client 90 "$t/boss.log" timeout 400 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_boss" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/boss.cmds" ||
	fail "the admin's client ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
b=$t/boss.log
grep -a "kit/arena\|kit/team\|Session\|refused\|put at\|digs \|dug \|Peer .* from session" "$s" |
	sed 's/^.*\(kit\|wasm\) *: /  /' | grep -v "^ *$" | cut -c1-160
# 1. The timer's left
want "$b" ': "Left 36"' ': "Left 24"' ': "Left 12"' ': "Left 0"'
echo "ok: kit/timer's left (3 repeats of 12 s of game time) on the screen, 36 to 0"
# 2. Digging
want "$s" "kitboss dug kit/stone (level 1) with kit/pickaxe (level 1): drops kit/cobble" \
	"A dig by kitboss refused: A hand does not dig kit/stone (level 1)" \
	"kitboss dug kit/dirt (level 0) with a hand (level 0): drops kit/dirt"
want "$b" "A hand does not dig kit/stone"
! grep -aq "kitboss dug kit/stone (level 1) with a hand" "$s" ||
	fail "a hand dug kit/stone under hand_level 0 ($s)"
echo "ok: the pickaxe's kit/stone drops kit/cobble; a hand refused on kit/stone (hand_level 0), told why; kit/dirt by hand dug"
# 3. and 4. The map, time_up "most", overtime
python3 - "$s" <<'PY' || fail "the rounds ($s)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
def part(n):
	return log.split("Session %d (a game)" % n)[1].split("Session %d ended" % n)[0]
s1, s2 = part(1), part(2)
assert re.search(r"Peer \d+ from session 0 to session 1 \(scene map~1\)", log), "into the map's copy"
assert re.search(r"Peer \d+ from session 1 to session 0 \(scene world\)", log), "back to the lobby"
assert re.search(r"Peer \d+ from session 2 to session 0 \(scene world\)", log), "back to the lobby (2)"
assert "kit/team 13: kitboss joins team Red" in s1, "the map's team"
assert "kitboss put at (7, 1, 3)" in s1, "on Red's pad"
assert "kit/arena 10: session 1 over: its time is up, Red has the most points" in s1
assert re.search(r"round over: Red wins! Red 1 : Blue 0 -- Round ended by kit/arena 10: time up, the most points", s1)
assert "kit/arena 10: time up, tied: Red 0 : Blue 0 -- overtime" in s2
assert "kit/arena 10: session 2 over: its time is up, Blue has the most points" in s2
assert re.search(r"round over: Blue wins! Red 0 : Blue 1", s2)
o = s2.split("-- overtime")[1].split("Blue has the most points")[0]
assert "score 1" in o, "Blue's point in the overtime"
print("  " + re.search(r"round over: Blue wins![^\n]*", s2).group(0))
PY
want "$b" '"Overtime | Red 0 : Blue 0"' '"Red wins! | Round ended by kit/arena 10: time up, the most points'
want "$b" '"Blue wins! | Round ended by kit/arena 10: time up, the most points'
echo "ok: the round in the map scene's copy, its teams and pads; time up: the most points win, a tie runs on as overtime until Blue's point; back in the lobby's scene after each"
echo "PASS: kit/arena's map and time_up \"most\", kit/timer's left, a material's drop, game_rules' hand_level"
# vim: set noet ts=4 sw=4:
