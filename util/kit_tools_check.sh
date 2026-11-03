#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-03)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/world.h builtin/kit/box/box.c builtin/kit/types/health.lua builtin/kit/types/health.client.lua builtin/kit/types/equipment.lua builtin/kit/types/game_rules.lua builtin/kit/types/team.lua builtin/kit/types/*.item.json builtin/kit/client_lua/hands.lua builtin/kit/client_lua/module.lua apps/workbench/**
# [KIT_TOOLS_1] (kit_plan stage 7c, its first part) Tools and weapons on
# a fresh Workbench save. The admin (kitboss), Stopped, in edit mode:
# makes the item type kitboss/blade from the kit/sword preset (damage 8,
# 5 uses, knockback 1) and two voxel types of the group stone, rock
# (level 1) and ore (level 3), one of each placed; places kit/game_rules,
# a spawner of players, a region round it (dig all, pvp none), item
# givers of the blade and of kit/pickaxe (the blade's linked to a counter
# both players' takes reach), and a dummy with kit/health (max 10) whose
# damaged and died go to counters. Running, kitboss and kitbob each take
# a blade; then kitboss, holding it:
#   1. hits kitbob: refused, the region's pvp none; again under
#      game_rules' peaceful (pvp all): refused; nothing worn
#   2. pvp all, not peaceful: hits the dummy twice -- 8, then dead: its
#      damaged and died reach the counters -- and kitbob three times: 20
#      to 12 and 4 with a knockback each, then dead and respawned at the
#      spawner at 20; the blade's uses go 4, 3, 2, 1 and the fifth breaks
#      it: the hands empty, a hit after (on the dummy) refused
#   3. holding kit/pickaxe (dig stone 4, level 1): rock takes its 0.25 s
#      (asked again) and drops kitboss/rock; ore (level 3) digs without a
#      drop
#   util/kit_tools_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_tools; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client() # <name>: its commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
{
	run_client 90 "$t/$1.log" timeout 400 bin/buildat -C "$t/client_cache" \
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
tools() # <on|off>: edit mode
{
	printf 'keypress F6\nwait_log 10000 kit editor: edit mode %s\n' "$1"
}
# The ids: 3 the World, 4 game_rules, 5 the spawner, 6 the region, 7 and 8
# the givers, 9 the dummy, 10 and 11 its counters, 12 the givers' counter;
# kitboss's entity 1000000, kitbob's 1000001
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
event kit_edit {"op": "item", "name": "blade", "preset": "kit/sword", "damage": 8, "uses": 5, "knockback": 1}
wait_log 10000 kit: 3 item types
EOF
	ed '{"op": "voxel", "name": "rock", "texture": "kit/stone.png", "group": "stone", "level": 1}'
	ed '{"op": "voxel", "name": "ore", "texture": "kit/sand.png", "group": "stone", "level": 3}'
	echo "sync 3000"
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/game_rules", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/spawner", "pos": [0, 1, 0]}'
	set_ 5 players true
	edit '{"op": "place", "type": "kit/region", "pos": [-6, 0, -6]}'
	set_ 6 size '[13, 6, 13]'
	set_ 6 dig '"all"'
	set_ 6 pvp '"none"'
	edit '{"op": "place", "type": "kit/item_giver", "pos": [1, 1, -2]}'
	set_ 7 item '"kitboss/blade"'
	edit '{"op": "place", "type": "kit/item_giver", "pos": [-1, 1, -2]}'
	set_ 8 item '"kit/pickaxe"'
	edit '{"op": "place", "type": "kit/health", "pos": [-2, 1, 2]}'
	set_ 9 max 10
	edit '{"op": "place", "type": "kit/counter", "pos": [-3, 1, 2]}'
	edit '{"op": "place", "type": "kit/counter", "pos": [-4, 1, 2]}'
	edit '{"op": "link", "id": 9, "comp": 0, "output": "damaged", "to": 10, "input": "add"}'
	edit '{"op": "link", "id": 9, "comp": 0, "output": "died", "to": 11, "input": "count"}'
	edit '{"op": "place", "type": "kit/counter", "pos": [4, 1, -4]}'
	edit '{"op": "link", "id": 7, "comp": 0, "output": "given", "to": 12, "input": "count"}'
	edit '{"op": "set_voxel", "pos": [2, 1, 2], "voxel": "kitboss/rock"}'
	edit '{"op": "set_voxel", "pos": [3, 1, 2], "voxel": "kitboss/ore"}'
	cat <<EOF
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
EOF
	tools off
	cat <<EOF
event kit_use 7
event kit_use 8
wait_log 300000 kit: entity 12 shows "2
event kit_hold kitboss/blade
sync 2000
event kit_hit $BOB
sync 2000
EOF
	tools on
	set_ 6 pvp '"all"'
	set_ 4 peaceful true
	tools off
	cat <<EOF
event kit_hold kitboss/blade
sync 2000
event kit_hit $BOB
sync 2000
EOF
	tools on
	set_ 4 peaceful false
	tools off
	# Each hit a second after the last (the blade's 0.5 s cooldown is game
	# time: CHECK_RATE times that)
	printf 'event kit_hold kitboss/blade\nsync 2000\n'
	for id in 9 9 $BOB $BOB $BOB 9; do
		printf 'event kit_hit %s\nsync 2000\ndelay 1000\n' "$id"
	done
	# The dig: asked, told to wait, asked again
	printf 'event kit_hold kit/pickaxe\nsync 2000\n'
	for p in '2, 1, 2' '3, 1, 2'; do
		for _ in 1 2; do
			printf 'event workbench_build {"p": [%s], "voxel": "air"}\nsync 2000\ndelay 1000\n' "$p"
		done
	done
	printf 'sync 3000\nquit\n'
} > "$t/boss.cmds"
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
event kit_use 7
wait_log 300000 your health 12/20
wait_log 60000 your health 4/20
wait_log 60000 your health 20/20
sync 3000
quit
EOF
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss &
boss=$!
wait_for_log "$t/srv.log" "kitboss holds nothing|gives kitboss 1 kitboss/blade" 300 ||
	fail "kitboss did not get to play ($t/srv.log)"
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 client bob
wait $boss || fail "the admin's client ($t/boss.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -a "item type\|Item types\|kit/health\|kit/equipment\|kit/counter\|hits entity\|A hit on\|knocked\|respawns\|digs \|dug \|holds\|hands empty\|joined" "$s" |
	sed 's/^.*\(kit\|wasm\) *: /  /' | grep -v "^ *$" | cut -c1-160
want "$s" "kitbob joined world as entity $BOB"
# The item type and the voxel types
want "$s" "Item types: kit/pickaxe kit/sword" \
	"kitboss made item type kitboss/blade version 1:" \
	'"damage":8' '"preset":"kit/sword"' '"uses":5'
want "$s" "kit/item_giver 7: gives kitboss 1 kitboss/blade" \
	"kit/item_giver 7: gives kitbob 1 kitboss/blade" \
	"kit/item_giver 8: gives kitboss 1 kit/pickaxe"
echo "ok: an item type from the sword preset, given to two players"
# 1. Refused by the rules, nothing worn
python3 - "$s" <<PY || fail "the refused hits ($s)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
refused = re.findall(r"A hit on entity $BOB by kitboss refused: (.*)", log)
assert len(refused) >= 2, refused
assert refused[0] == "Protected: no fighting players here", refused
assert refused[1] == "Peaceful: players take no damage", refused
first = log.index("kitboss hits entity")
assert all(log.index(l) < first for l in re.findall(r"A hit on entity $BOB by kitboss refused: .*", log)[:2])
assert "uses left" not in log[:first]
print("  " + " / ".join(refused[:2]))
PY
echo "ok: a hit refused in a region with pvp none and under peaceful, nothing worn"
# 2. The dummy, kitbob, wear and breaking
want "$s" "kitboss hits entity 9 with kitboss/blade: 8 normal" \
	"kit/health 9: hit 8 normal by kitboss hp 2" \
	"kit/counter 10: count 8" "kit/health 9: died" "kit/counter 11: count 1"
echo "ok: health on an entity: the hit lowers it, damaged and died signal (counters)"
want "$s" "kitboss hits entity $BOB with kitboss/blade: 8 normal" \
	"hp 12" "hp 4" "kitbob knocked back" "respawns at entity 5"
want "$t/bob.log" "your health 12/20" "your health 4/20" "your health 20/20"
echo "ok: a player hit in a pvp region: health 20, 12, 4 shown, a knockback each, dead and respawned at the spawner"
python3 - "$s" <<'PY' || fail "the blade's wear ($s)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
left = re.findall(r"kit/equipment \d+: kitboss/blade uses left (\d+)", log)
assert left[:4] == ["4", "3", "2", "1"], left
assert "kitboss/blade breaks" in log
assert "kitboss has no kitboss/blade: the hands empty" in log
after = log.split("kitboss/blade breaks")[1]
assert "nothing in hand" in after, "no refusal after the break"
print("  uses left " + ", ".join(left[:4]) + ", then it breaks")
PY
echo "ok: the blade wears a use a hit, breaks at 0: taken, the hands empty, a hit after refused"
# 3. Digging by group and level
want "$s" "kitboss digs kitboss/rock (stone, level 1) with kit/pickaxe: 0.25 s" \
	"kitboss dug kitboss/rock (level 1) with kit/pickaxe (level 1): drops kitboss/rock" \
	"kitboss dug kitboss/ore (level 3) with kit/pickaxe (level 1): no drop"
grep -aqE "kitboss has \{[^}]*\"kitboss/rock\":1" "$s" ||
	fail "kitboss/rock not in kitboss's items ($s)"
echo "ok: a pickaxe digs its group at its speed: rock (level 1) drops, ore (level 3) does not"
echo "PASS: tools: an item type from a preset, health on players and entities, the hit through Kit's rules (region pvp, peaceful), knockback, wear and breaking, a respawn; digging by material group and level"
# vim: set noet ts=4 sw=4:
