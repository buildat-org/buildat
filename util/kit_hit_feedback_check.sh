#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-04)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/hands.lua apps/workbench/**
# [KIT_HIT_FEEDBACK] What a fight shows, on a fresh Workbench save. The
# admin (kitboss), Stopped, in edit mode: an item type kitboss/knife
# (kit/sword's preset, damage 10), kit/game_rules, a spawner of players,
# a region (pvp all) and a giver of the knife. Running, both take a
# knife; kitboss, holding it in first person, hits kitbob twice: each
# hit swings the knife once and marks kitboss's crosshair (the hit
# landed); kitbob's screen flashes red as his health drops (20 to 10);
# the second kills him, and both see the line "kitboss killed kitbob
# with knife". Screenshots: kitboss's just after a hit ($t/marker.png),
# kitbob's as hurt ($t/hurt.png)
#   util/kit_hit_feedback_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_hit_feedback; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client() # <name>: its commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
{
	run_client 90 "$t/$1.log" timeout 300 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
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
# The ids: 3 the World, 4 game_rules, 5 the spawner, 6 the region, 7 the
# giver, 8 a counter of its gifts; kitbob's entity 1000001
BOB=1000001
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
event kit_edit {"op": "item", "name": "knife", "preset": "kit/sword", "damage": 10, "knockback": 0, "crit": 1}
wait_log 10000 kit: 9 item types
EOF
	edit '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/game_rules", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/spawner", "pos": [0, 1, 0]}'
	set_ 5 players true
	edit '{"op": "place", "type": "kit/region", "pos": [-6, 0, -6]}'
	set_ 6 size '[13, 6, 13]'
	set_ 6 pvp '"all"'
	edit '{"op": "place", "type": "kit/item_giver", "pos": [1, 1, -2]}'
	set_ 7 item '"kitboss/knife"'
	edit '{"op": "place", "type": "kit/counter", "pos": [4, 1, -4]}'
	edit '{"op": "link", "id": 7, "comp": 0, "output": "given", "to": 8, "input": "count"}'
	cat <<EOF
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode off
event kit_use 7
wait_log 60000 kit: items: kitboss/knife
event kit_hold kitboss/knife
wait_log 10000 drawn in first person
wait_log 300000 kit: entity 8 shows "2
sync 3000
delay 2000
event kit_hit $BOB
wait_log 10000 the hit marker
screenshot $t/marker.png
delay 1500
event kit_hit $BOB
wait_log 10000 kit: kill message: kitboss killed kitbob with knife
sync 3000
quit
EOF
} > "$t/boss.cmds"
cat > "$t/bob.cmds" <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
event kit_use 7
wait_log 60000 kit: items: kitboss/knife
wait_log 300000 the red flash
screenshot $t/hurt.png
wait_log 60000 kit: kill message: kitboss killed kitbob with knife
sync 3000
quit
EOF
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss &
boss=$!
wait_for_log "$t/srv.log" "kitboss holds nothing|gives kitboss 1 kitboss/knife" 300 ||
	fail "kitboss did not get to play ($t/srv.log)"
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 client bob
wait $boss || fail "the admin's client ($t/boss.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -a "hits entity\|Kill message\|died" "$s" | sed 's/^.*kit *: /  /' | cut -c1-160
grep -a "swings once\|hit marker\|red flash\|kill message" "$t/boss.log" "$t/bob.log" |
	sed 's/^\([^:]*\):.*kit: /  \1: /' | sed "s|$t/||" | cut -c1-160
want "$s" "kitboss hits entity $BOB with kitboss/knife: 10 normal" \
	'Kill message: {"by":"kitboss","item":"kitboss/knife","type":"normal","victim":"kitbob"}'
python3 - "$t/boss.log" "$t/bob.log" <<PY || fail "the feedback ($t/boss.log, $t/bob.log)"
import re, sys
boss = open(sys.argv[1], errors="replace").read()
bob = open(sys.argv[2], errors="replace").read()
assert boss.count("kit: kitboss/knife swings once in first person") == 2, "two swings"
assert boss.count("kit: the hit landed on $BOB: the hit marker") == 2, "two markers"
assert "kit: hurt (20 to 10): the red flash" in bob, "no flash"
assert "the red flash" not in boss, "kitboss flashed"
for log in (boss, bob):
	assert len(re.findall(r"I kit +: kit: kill message: kitboss killed kitbob with knife", log)) == 1
PY
echo "ok: two hits: a swing and a hit marker each for kitboss, a red flash for kitbob, the kill line for both"
[ -s "$t/marker.png" ] && [ -s "$t/hurt.png" ] || fail "no screenshots ($t)"
echo "PASS: hit feedback: the melee swing once a hit, the hit marker, the red flash when hurt, the kill message to the session ($t/marker.png, $t/hurt.png)"
# vim: set noet ts=4 sw=4:
