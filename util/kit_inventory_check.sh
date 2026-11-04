#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-04)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/types/inventory.lua builtin/kit/types/equipment.lua builtin/kit/types/game_rules.lua builtin/kit/types/arena.lua builtin/kit/types/pickup.lua builtin/kit/types/chest.lua builtin/kit/types/starting_kit.lua builtin/kit/types/player_state.lua builtin/kit/types/health.client.lua builtin/kit/client_lua/inventory.lua builtin/kit/client_lua/hands.lua builtin/kit/client_lua/input.lua builtin/kit/client_lua/module.lua apps/workbench/**
# [KIT_INVENTORY_PLAY] [KIT_HUD] Inventory play on a fresh Workbench
# save. The admin (kitboss), Stopped, in edit mode: the item type
# kitboss/blade (the sword's, damage 20, no knockback); kit/game_rules
# (5 slots, stack 10, hotbar 3, on_death drop), a spawner of players, a
# region round it (dig, place, pvp all), two starting kits ("kit/stone 25,
# kitboss/blade" at the round's start; "kit/arrow 3" at each spawn), a
# chest holding 3 kit/dirt, an arena on the spawn (2 players, no
# countdown, at_end living), and voxels to dig. Running, kitboss alone:
#   1. the starting kits: stone in stacks of 10, 10 and 5, the blade, the
#      arrows: the 5 slots full; the HUD: the hotbar of 3, the health bar
#   2. holding slot 1, a place of kit/stone takes one from it; kit/dirt
#      (not in hand) refused; a dig of dirt with the inventory full drops
#      it as a pickup
#   3. the chest: its screen beside the player's, 5 stone moved into it
#      and its 3 dirt out; the drop key drops one dirt as a pickup, then
#      the held last slot's 3 arrows (the slots' trailing empty dropped:
#      the server hung there before)
#   4. hotbar 0 and show_health off: no hotbar, no health bar
#   5. placed_only: the terrain's dirt refused, the placed stone dug;
#      creative: a place takes nothing
# Then kitbob joins: the arena's round (session 1): the starting kits
# again, kitboss's blade kills kitbob: their stacks dropped as pickups,
# the spawn kit at the respawn; the round's end (after the results):
# kitboss (alive) keeps the round's, kitbob (died) has nothing.
# Screenshots: hud.png, chest.png (the screen with the chest), hud_off.png
#   util/kit_inventory_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_inventory; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client() # <name>: its commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
{
	sed -i "s|@T@|$t|g" "$t/$1.cmds"
	run_client 90 "$t/$1.log" timeout 500 bin/buildat -C "$t/client_cache" \
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
build() # <x, y, z> <voxel>: a dig asked twice (it waits)
{
	local k=1
	[ "$2" = air ] && k=2
	for _ in $(seq $k); do
		printf 'event workbench_build {"p": [%s], "voxel": "%s"}\nsync 2000\ndelay 1500\n' "$1" "$2"
	done
}
# The ids: 3 the World, 4 game_rules, 5 the spawner, 6 the region, 7 and 8
# the starting kits, 9 the chest, 10 the arena
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
event kit_edit {"op": "item", "name": "blade", "preset": "kit/sword", "damage": 20, "knockback": 0}
wait_log 10000 kit: 8 item types
sync 3000
EOF
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/game_rules", "pos": [0, 1, 0]}'
	set_ 4 slots 5
	set_ 4 stack 10
	set_ 4 hotbar 3
	set_ 4 on_death '"drop"'
	edit '{"op": "place", "type": "kit/spawner", "pos": [0, 1, 0]}'
	set_ 5 players true
	edit '{"op": "place", "type": "kit/region", "pos": [-8, 0, -8]}'
	set_ 6 size '[17, 6, 17]'
	set_ 6 dig '"all"'
	set_ 6 place '"all"'
	set_ 6 pvp '"all"'
	edit '{"op": "place", "type": "kit/starting_kit", "pos": [-3, 1, 4]}'
	set_ 7 items '"kit/stone 25, kitboss/blade"'
	edit '{"op": "place", "type": "kit/starting_kit", "pos": [-4, 1, 4]}'
	set_ 8 items '"kit/arrow 3"'
	set_ 8 when '"spawn"'
	edit '{"op": "place", "type": "kit/chest", "pos": [2, 1, 0]}'
	set_ 9 size 9
	set_ 9 items '"kit/dirt 3"'
	edit '{"op": "place", "type": "kit/arena", "pos": [-2, 1, -2]}'
	set_ 10 size '[5, 3, 5]'
	set_ 10 countdown 0
	set_ 10 duration 120
	set_ 10 results 3
	set_ 10 at_end '"living"'
	edit '{"op": "set_voxel", "pos": [0, 1, 3], "voxel": "kit/dirt"}'
	edit '{"op": "set_voxel", "pos": [1, 1, 3], "voxel": "kit/dirt"}'
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
EOF
	tools off
	# 1. The starting kits, the HUD
	cat <<'EOF'
wait_log_any 30000 kit: slots: 1:kit/stone x10, 2:kit/stone x10, 3:kit/stone x5, 4:kitboss/blade x1, 5:kit/arrow x3
event kit_slot 1
wait_log 10000 kit: hud: hotbar 3 slots, held 1 kit/stone, health 20/20
frames 10
screenshot @T@/hud.png
EOF
	# 2. A place from the held slot, one not in hand, a dig into a full
	# inventory
	build '-1, 1, 3' kit/stone
	build '-1, 2, 3' kit/dirt
	build '0, 1, 3' air
	# 3. The chest: 5 stone in, its 3 dirt out; one dirt dropped
	cat <<'EOF'
event kit_use 9
wait_log 10000 kit: inventory screen opened (14 slots, chest 9)
event kit_inv_click p 3
event kit_inv_click c 2
wait_log 10000 kit: slots: 1:kit/stone x9, 2:kit/stone x10, 4:
event kit_inv_click c 1
event kit_inv_click p 3
sync 2000
frames 10
screenshot @T@/chest.png
event kit_inventory
wait_log_any 10000 kit: inventory screen closed
event kit_slot 3
sync 2000
event kit_drop
sync 2000
event kit_slot 5
sync 2000
event kit_drop all
wait_log 10000 kit: slots: 1:kit/stone x9, 2:kit/stone x10, 3:kit/dirt x2, 4:kitboss/blade x1 (held 5
EOF
	# 4. No hotbar, no health bar
	tools on
	set_ 4 hotbar 0
	set_ 4 show_health false
	tools off
	cat <<'EOF'
wait_log_any 10000 kit: hud: hotbar none, health none
frames 10
screenshot @T@/hud_off.png
EOF
	# 5. placed_only; creative
	tools on
	set_ 4 hotbar 3
	set_ 4 show_health true
	set_ 4 placed_only true
	tools off
	build '1, 1, 3' air
	build '-1, 1, 3' air
	tools on
	set_ 4 placed_only false
	set_ 4 building '"creative"'
	tools off
	build '-2, 1, 3' kit/sand
	tools on
	set_ 4 building '"inventory"'
	tools off
	# The round: kitbob joins
	cat <<'EOF'
wait_log 300000 kit editor: in session 1 game
sync 3000
event kit_slot 4
sync 2000
event kit_hit nearest
sync 3000
wait_log 300000 kit editor: in session 0 default
sync 5000
quit
EOF
} > "$t/boss.cmds"
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log 300000 Last round:
sync 5000
quit
EOF
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss &
boss=$!
wait_for_log "$t/srv.log" "set 4's kit/game_rules building to \"inventory\"" 400 ||
	fail "kitboss's part alone did not end ($t/srv.log, $t/boss.log)"
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 client bob
wait $boss || fail "the admin's client ($t/boss.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
b=$t/boss.log
grep -a "starting_kit\|pickup\|kit/chest\|placed\|dug\|refused\|drops\|moves\|opens\|died\|round ends\|holds\|Session" "$s" |
	sed 's/^.*\(kit\|wasm\|workbench\) *: /  /' | grep -v "^ *$" | cut -c1-160
grep -a "kit: hud\|kit: slots\|kit: inventory\|kit: chest" "$b" | cut -c1-160
# 1.
want "$s" "kit/starting_kit 7: gives kitboss 25 kit/stone, 1 kitboss/blade" \
	"kit/starting_kit 8: gives kitboss 3 kit/arrow"
want "$b" "kit: hud: hotbar 3 slots, held 1 kit/stone, health 20/20"
echo "ok: the starting kits at the round's start: stacks of 10 (the rule), the blade a slot; the HUD's hotbar and health"
# 2.
want "$s" "kitboss placed kit/stone at (-1,1,3): one taken from slot 1" \
	"workbench: a build by kitboss refused: not in edit mode and not allowed at (-1,2,3): Not in hand: kit/dirt" \
	"kitboss dug kit/dirt" "kit/dirt 1 do not fit: dropped" "A pickup of 1 kit/dirt"
want "$b" "kit: slots: 1:kit/stone x9,"
echo "ok: a place takes one from the held slot, one not in hand refused, a dig into a full inventory drops a pickup"
# 3.
want "$s" "kitboss opens entity 9" "kitboss moves 5 from p:3 to c:2" \
	"kitboss moves 3 from c:1 to p:3" "kitboss drops 1 kit/dirt" \
	"kitboss drops 3 kit/arrow" "A pickup of 3 kit/arrow"
grep -aqE "A pickup of 1 kit/dirt.*" "$s" && [ "$(grep -ac 'A pickup of 1 kit/dirt' "$s")" -ge 2 ] ||
	fail "no pickup of the dropped dirt ($s)"
echo "ok: the chest's stacks moved both ways on the screen; the drop key drops a pickup, the last slot's whole stack too"
# 4.
want "$b" "kit: hud: hotbar none, health none"
echo "ok: hotbar 0 and show_health off: no hotbar, no health bar"
# 5.
want "$s" "Only what players placed can be dug" "workbench: kitboss dug (-1,1,3): written" \
	"workbench: kitboss placed kit/sand (-2,1,3): written"
! grep -aq "kitboss placed kit/sand at" "$s" || fail "a creative place took an item ($s)"
echo "ok: placed_only: terrain refused, a placed voxel dug; creative: a place free"
# The round
python3 - "$s" <<'PY' || fail "the round ($s)"
import sys
log = open(sys.argv[1], errors="replace").read()
r = log.split("Session 1 (a game)", 1)[1]
for w in ["kit/starting_kit 7: gives kitboss 25 kit/stone, 1 kitboss/blade",
		"kit/starting_kit 7: gives kitbob 25 kit/stone, 1 kitboss/blade",
		"kitbob died: on_death drop:", "kit/starting_kit 8: gives kitbob 3 kit/arrow",
		"kitboss's round ends (at_end living): 5 stacks kept, 0 gone",
		"kitbob's round ends (at_end living, died in it): 0 stacks kept"]:
	assert w in r, w
d = r.split("kitbob died: on_death drop:", 1)[1]
assert "A pickup of" in d.split("kit/starting_kit 8: gives kitbob")[0], "no drop at the death"
PY
echo "ok: a round: the kits at its start, a death drops the stacks, the spawn kit at the respawn; its end keeps the living's and clears the dead's"
for p in hud chest hud_off; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
echo "PASS: inventory play: slots and stacks, the held slot placing, a full inventory's drop, the chest, the drop key, the HUD (hotbar, health, both off), placed_only, creative, starting kits, a death's drop and a round's ends; screenshots $t/hud.png $t/chest.png $t/hud_off.png"
# vim: set noet ts=4 sw=4:
