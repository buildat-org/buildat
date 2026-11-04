#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-03)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/types/equipment.lua builtin/kit/types/inventory.lua builtin/kit/types/item_box.lua builtin/kit/types/team.lua builtin/kit/types/*.item.json builtin/kit/types/paintball_look.prefab.json builtin/kit/client_lua/hands.lua builtin/kit/client_lua/module.lua builtin/kit/client_lua/controls.lua builtin/kit/client_lua/input.lua apps/workbench/**
# [KIT_TOOLS_2] (kit_plan stage 7c, its second part) Ranged items,
# loading, item instances and the held item in first person, on a fresh
# Workbench save. The admin (kitboss), Stopped, in edit mode, makes the
# item types kitboss/paint (kit/paintball's: spread 0, range 8, a
# magazine of 2, reload 1 s from "pellet" items, 10 uses) and
# kitboss/blade (kit/sword's, 5 uses), and places a spawner, a region
# (pvp none), team Red (friendly fire off) with a join button, a
# teleporter to (3, 1, -3), givers (paint, 4 pellets, kit/bow, 10
# kit/arrow, 2 blades), kit/item_box, dummies with health: D1 at 5 m, D2
# past the range, D3 behind a stone wall, D4 and D5 for the blades.
# Running, both join Red; kitbob goes to (3, 1, -3). kitboss:
#   1. paint: D1 hit (2); D2 missed out of range; the magazine empty, a
#      shot refused; a reload: a shot during it refused, then 2 loaded
#      from the pellets; D3 missed at the wall; kitbob refused (pvp none);
#      a reload; pvp all: kitbob refused (friendly fire off); the blades;
#      friendly fire on: kitbob hit (2); a reload with no pellets loads
#      nothing. wear_shot: uses left 9...4
#   2. the blades: two hits on D4 wear the first (4, 3), it goes into the
#      box, a hit with the second wears it alone (4); kitbob takes the
#      worn one out and his hit on D5 leaves it at 2
#   3. kit/bow: a tap (a tenth of the charge, damage 0.8) flies at 4 m/s
#      and falls to the ground within 3 m; a full draw (8) hits D1; an
#      arrow taken each
#   4. kitboss/paint held: its look (kit/paintball_look, four parts) drawn
#      in first person, a screenshot ($t/held.png)
#   util/kit_tools2_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_tools2; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client() # <name>: its commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
{
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
place() # <type> <x, y, z>
{
	edit "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$2]}"
}
tools() # <on|off>: edit mode
{
	printf 'keypress F6\nwait_log 10000 kit editor: edit mode %s\n' "$1"
}
step() # <command>: a second after it (cooldowns, the refusals' log)
{
	printf '%s\nsync 2000\ndelay 1000\n' "$1"
}
# The ids: 3 the World, 4 the spawner, 5 the region, 6 the team, 7 its
# button, 8 the teleporter, 9 its counter, 10-14 the givers, 15 the box,
# 16-20 the dummies D1-D5; kitboss's entity 1000000, kitbob's 1000001
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
event kit_edit {"op": "item", "name": "paint", "preset": "kit/paintball", "spread": 0, "range": 8, "magazine": 2, "reload": 1, "ammo": "pellet", "uses": 10, "wear_shot": 1}
wait_log 10000 kit: 8 item types
event kit_edit {"op": "item", "name": "blade", "preset": "kit/sword", "uses": 5, "knockback": 0}
wait_log 10000 kit: 9 item types
EOF
	place kit/world '0, 1, 0'
	place kit/spawner '0, 1, 0'
	set_ 4 players true
	place kit/region '-12, 0, -12'
	set_ 5 size '[25, 6, 25]'
	set_ 5 pvp '"none"'
	place kit/team '0, 1, 0'
	place kit/button '1, 1, -1'
	edit '{"op": "link", "id": 7, "comp": 0, "output": "pressed", "to": 6, "input": "join"}'
	place kit/teleporter '-1, 1, -2'
	set_ 8 to '[3, 1, -3]'
	place kit/counter '5, 1, -5'
	edit '{"op": "link", "id": 8, "comp": 0, "output": "teleported", "to": 9, "input": "count"}'
	place kit/item_giver '2, 1, 0'
	set_ 10 item '"kitboss/paint"'
	place kit/item_giver '2, 1, 1'
	set_ 11 item '"pellet"'
	set_ 11 count 4
	place kit/item_giver '-2, 1, -1'
	set_ 12 item '"kit/bow"'
	place kit/item_giver '-2, 1, 0'
	set_ 13 item '"kit/arrow"'
	set_ 13 count 10
	place kit/item_giver '1, 1, 1'
	set_ 14 item '"kitboss/blade"'
	set_ 14 count 2
	place kit/item_box '1.5, 1, -1.5'
	set_ 15 item '"kitboss/blade"'
	for p in '0, 1, 5' '7, 1, 7' '-5, 1, 0' '-1, 1, 1.5' '4, 1, -4'; do
		place kit/health "$p"
	done
	for y in 1 2 3; do
		for z in -1 0 1; do
			edit "{\"op\": \"set_voxel\", \"pos\": [-3, $y, $z], \"voxel\": \"kit/stone\"}"
		done
	done
	cat <<EOF
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
EOF
	tools off
	for g in 10 11 12 13 14 7; do
		step "event kit_use $g"
	done
	cat <<'EOF'
wait_log_any 300000 kit: entity 9 shows "1
event kit_hold kitboss/paint
sync 2000
EOF
	# 1. paint
	step "event kit_shoot 16"
	step "event kit_shoot 17"
	step "event kit_shoot 16"
	# The shot in the reload's frame; then the client's hotbar says 2/2
	printf 'event kit_reload\nevent kit_shoot 16\nwait_log 60000 2/2 uses 8\ndelay 1000\n'
	step "event kit_shoot 18"
	step "event kit_shoot $BOB"
	printf 'event kit_reload\nwait_log 60000 2/2 uses 6\ndelay 1000\n'

	tools on
	set_ 5 pvp '"all"'
	tools off
	printf 'event kit_hold kitboss/paint\nsync 2000\n'
	step "event kit_shoot $BOB"
	# 2. the blades, before kitbob's turn
	printf 'event kit_hold kitboss/blade\nsync 2000\n'
	step "event kit_hit 19"
	step "event kit_hit 19"
	step "event kit_use 15"
	# [KIT_INVENTORY_PLAY] the hands held its slot, empty now: the other
	printf 'event kit_hold kitboss/blade\nsync 2000\n'
	step "event kit_hit 19"
	tools on
	set_ 6 friendly_fire true
	tools off
	printf 'event kit_hold kitboss/paint\nsync 2000\n'
	step "event kit_shoot $BOB"
	step "event kit_reload"
	step "event kit_shoot 16"
	# 3. the bow: a tap along -z, then a full draw at D1
	printf 'event kit_hold kit/bow\nsync 2000\n'
	step "event kit_shoot 0,0,-1"
	printf 'event kit_draw\nsync 1000\ndelay 2000\n'
	step "event kit_shoot 16"
	# 4. the held item in first person
	cat <<EOF
event kit_hold kitboss/paint
wait_log 10000 drawn in first person
frames 10
screenshot $t/held.png
sync 3000
quit
EOF
} > "$t/boss.cmds"
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
event kit_use 7
sync 2000
delay 1000
event kit_use 8
wait_log 300000 your health 18/20
delay 1000
event kit_use 15
wait_log 30000 kit: items: kitboss/blade
event kit_hold kitboss/blade
sync 2000
event kit_hit 20
sync 3000
quit
EOF
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss &
boss=$!
wait_for_log "$t/srv.log" "gives kitboss 1 kitboss/paint" 300 ||
	fail "kitboss did not get to play ($t/srv.log)"
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 client bob
wait $boss || fail "the admin's client ($t/boss.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -a "made item type\|kit/equipment\|kit/item_box\|kit/team\|shoots\|shot \|A shot\|hits entity\|A hit on\|projectile\|reload\|holds" "$s" |
	sed 's/^.*\(kit\|wasm\) *: /  /' | grep -v "^ *$" | cut -c1-160
want "$s" "kitbob joined world as entity $BOB" \
	"kitboss made item type kitboss/paint version 1:" '"magazine":2' \
	"kit/team 6: kitboss joins team Red" "kit/team 6: kitbob joins team Red"
# 1. Hitscan, loading, the rules
want "$s" "kitboss hits entity 16 with kitboss/paint: 2 paint" \
	"kitboss's shot with kitboss/paint misses: out of range" \
	"A shot by kitboss refused: kitboss/paint is empty: reload" \
	"kitboss reloads kitboss/paint: 1 s" "A shot by kitboss refused: reloading" \
	"kitboss/paint loaded 2 of 2" \
	"kitboss's shot with kitboss/paint misses: a wall" \
	"A hit on entity $BOB by kitboss refused: Protected: no fighting players here" \
	"A hit on entity $BOB by kitboss refused: Friendly fire is off in team Red" \
	"kitboss hits entity $BOB with kitboss/paint: 2 paint"
want "$t/bob.log" "your health 18/20"
want "$t/boss.log" "kit: a shot of kitboss/paint: 1 splats" \
	"kit: a shot of kitboss/paint: 0 splats"
python3 - "$s" <<'PY' || fail "the paint's loading and wear ($s)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
left = re.findall(r"kit/equipment \d+: kitboss/paint uses left (\d+)", log)
assert left == ["9", "8", "7", "6", "5", "4"], left
loads = re.findall(r"kitboss/paint loaded (\d+) of 2", log)
assert loads == ["2", "2", "0"], loads
# Four pellets: two a reload, then none
pel = re.findall(r'kitboss has \{[^}]*?"pellet":(\d)', log)
assert pel[0] == "4" and "2" in pel, pel
assert not re.search(r'kitboss has \{[^}]*"pellet"', log.split("loaded 2 of 2")[-1]), "pellets left after the second reload"
# Friendly fire off before on, both after pvp none
a = log.index("refused: Protected: no fighting players here")
b = log.index("refused: Friendly fire is off in team Red")
c = log.index("kitboss hits entity 1000001 with kitboss/paint")
assert a < b < c
# After the last reload (nothing loaded) the shot is refused again
assert "is empty: reload" in log.split("loaded 0 of 2")[-1]
print("  uses left " + ", ".join(left) + "; loaded " + ", ".join(loads))
PY
echo "ok: hitscan paint: a hit in range, a miss past it and at a wall; the magazine empties, a shot refused, a reload takes its time and loads from pellets; wear_shot"
echo "ok: a hit on a player refused by the region's pvp, then by the team's friendly fire off, landing with it on"
# 2. Item instances
python3 - "$s" <<'PY' || fail "the blades' instances ($s)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
boss = re.findall(r"kit/equipment 1000000: kitboss/blade uses left (\d+)", log)
bob = re.findall(r"kit/equipment 1000001: kitboss/blade uses left (\d+)", log)
assert boss == ["4", "3", "4"], boss
assert bob == ["2"], bob
assert "kit/item_box 15: kitboss puts in kitboss/blade" in log
assert "kit/item_box 15: kitbob takes kitboss/blade" in log
print("  kitboss's: 4, 3, then the other 4; kitbob's (the first, moved): 2")
PY
echo "ok: two blades wear apart; a worn one moved to another player through kit/item_box keeps its wear"
# 3. The bow
python3 - "$s" <<'PY' || fail "the bow ($s)"
import re, sys, math
log = open(sys.argv[1], errors="replace").read()
shots = re.findall(r"kitboss shoots kit/bow: a projectile, 1 pellet, charge ([\d.]+), damage ([\d.]+)", log)
assert len(shots) == 2 and float(shots[0][0]) == 0.1 and float(shots[1][0]) == 1, shots
assert abs(float(shots[0][1]) - 0.8) < 1e-6 and float(shots[1][1]) == 8, shots
land = re.search(r"kitboss's projectile \d+ lands at \(([-\d.]+), ([-\d.]+), ([-\d.]+)\)", log)
assert land, "the tap did not land"
x, y, z = map(float, land.groups())
d = math.hypot(x, z)
assert 1 < d < 3.5 and 0.3 < y < 0.8, (x, y, z)
assert re.search(r"kitboss's projectile \d+ hits entity 16", log)
assert "kitboss hits entity 16 with kit/bow: 8 normal" in log
arrows = re.findall(r'kitboss has \{[^}]*?"kit/arrow":(\d+)', log)
assert arrows[0] == "10" and arrows[-1] == "8", arrows
print("  the tap lands %.2f m off at y %.2f; the full draw hits for 8; arrows %s" % (d, y, arrows[-1]))
PY
echo "ok: a bow's projectile falls with gravity and hits; its charge scales its damage and speed; an arrow a shot"
# 4. In first person
want "$t/boss.log" "kit: kitboss/paint drawn in first person: look kit/paintball_look, 4 parts, 0 voxels"
[ -s "$t/held.png" ] || fail "no screenshot ($t/held.png)"
echo "ok: the paint gun's look of parts drawn in first person ($t/held.png)"
echo "PASS: tools 2: hitscan and projectiles through Kit's rules, a charge, loading, wear_shot, friendly fire, item instances, the held item in first person"
# vim: set noet ts=4 sw=4:
