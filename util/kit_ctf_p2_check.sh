#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-04)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/terrain.h builtin/kit/box/box.c builtin/kit/types/health.lua builtin/kit/types/game_rules.lua builtin/kit/client_lua/controls.lua builtin/kit/client_lua/inventory.lua apps/workbench/**
# [KIT_CTF] P2: death, respawn, hurts and blasts on a fresh Workbench
# save, with a check's own type workbench/probe (BUILDAT_WORKBENCH_TYPES:
# its on_died and on_blast logged; used: c:hurt by a fraction or
# c:explode, its numbers its parameters). The admin (kitboss), Stopped:
# kit/game_rules' respawn "on_signal", a blade (kit/sword, damage 20, no
# knockback), a voxel type kitboss/hard (blast_resist 5), a big region
# (dig and pvp all) and a small one (dig none) at the blast's edge, a
# team (friendly_fire off) and buttons to join it and to respawn
# (game_rules' input). Running:
#   1. kitboss kills kitbob with the blade: the scene's probe sees
#      on_died (kitbob, by kitboss, normal); kitbob waits: his hit, use
#      and dig refused ("waiting to respawn"), his HUD says so, until the
#      respawn button: back at the spawner at 20
#   2. kitboss's c:hurt by fraction 0.25: 20 to 15
#   3. both join the team; kitboss stands 5 m from the blast, kitbob at
#      its middle: c:explode{radius 3.5, kill 3.5, hurt 7, share 0.5}
#      kills kitbob (a teammate, friendly_fire off: a blast ignores it)
#      and takes kitboss 15 to 5 (half his max); a probe within the
#      radius gets on_blast; a plain kit/stone in the radius goes to air,
#      kitboss/hard (resist 5 > the strength) and the small region's
#      kit/stone stay
#   util/kit_ctf_p2_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_ctf_p2; t=$CHECK_TMP
# (in its app directory: the sandboxed server reads nothing else of the run's)
mkdir -p "$t/user/apps/workbench/check_types"
cat > "$t/user/apps/workbench/check_types/probe.lua" <<'EOF'
-- The check's probe: logs on_died and on_blast; used, it does its act
return {
	version = 1,
	usable = true,
	look = {shape = "box", size = {0.4, 0.4, 0.4}, color = "#808080"},
	params = {
		act = {type = "string", default = "none"},
		fraction = {type = "number", default = 0.25, min = 0, max = 1},
		at = {type = "position", default = {0, 0, 0}},
		radius = {type = "number", default = 0, min = 0, max = 9},
		kill = {type = "number", default = 0, min = 0, max = 32},
		hurt = {type = "number", default = 0, min = 0, max = 32},
		share = {type = "number", default = 0.5, min = 0, max = 1},
		friendly_fire = {type = "bool", default = true},
	},
	on_use = function(c, by)
		local p = c.params
		c:log("used:", p.act, "by", c:name(by))
		if p.act == "hurt" then
			c:hurt(c.player, {fraction = p.fraction})
		elseif p.act == "explode" then
			c:explode{at = p.at, radius = p.radius, kill = p.kill,
				hurt = p.hurt, share = p.share,
				friendly_fire = p.friendly_fire}
		end
	end,
	on_died = function(c, player, by, kind)
		c:log("on_died", player, "by", c:name(by), kind)
	end,
	on_blast = function(c, pos, by)
		c:log("on_blast", pos[1], pos[2], pos[3], "by", c:name(by))
	end,
}
EOF
export BUILDAT_WORKBENCH_TYPES=$t/user/apps/workbench/check_types
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
place() # <type> <x, y, z>
{
	edit "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$2]}"
}
# The ids: 3 the World, 4 game_rules, 5 the spawner, 6 the big region, 7
# the small one, 8 the blade's giver, 9 the listening probe, 10 the hurt
# probe, 11 the bomb probe, 12 the respawn button, 13 the join button, 14
# the team, 15 a teleporter, 16 the givings' counter; kitboss's entity
# 1000000, kitbob's 1000001. The blast at (0, 1.5, -4), the team's pad
# (0, 1, -4)
BOSS=1000000 BOB=1000001
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
EOF
	ed '{"op": "voxel", "name": "hard", "texture": "kit/stone.png", "blast_resist": 5}'
	echo "sync 3000"
	place kit/terrain '0, 1, 0'
	place kit/game_rules '0, 1, 0'
	set_ 4 respawn '"on_signal"'
	place kit/spawner '0, 1, 0'
	set_ 5 players true
	place kit/region '-8, 0, -10'
	set_ 6 size '[17, 6, 17]'
	set_ 6 dig '"all"'
	set_ 6 pvp '"all"'
	place kit/region '-3, 0, -5'
	set_ 7 size '[1, 3, 3]'
	set_ 7 dig '"none"'
	set_ 7 enter '"all"'
	place kit/item_giver '1, 1, -1'
	set_ 8 item '"kitboss/blade"'
	place workbench/probe '0, 1, -2'
	place workbench/probe '-1, 1, 1'
	set_ 10 act '"hurt"'
	place workbench/probe '6, 1, -4'
	set_ 11 act '"explode"'
	set_ 11 at '[0, 1.5, -4]'
	set_ 11 radius 3.5
	set_ 11 kill 3.5
	set_ 11 hurt 7
	set_ 11 share 0.5
	place kit/button '1, 1, 1'
	place kit/button '-1, 1, -1'
	place kit/team '0, 1, -4'
	place kit/teleporter '2, 1, -3'
	set_ 15 to '[5, 1, -4]'
	place kit/counter '3, 1, 3'
	edit '{"op": "link", "id": 12, "comp": 0, "output": "pressed", "to": 4, "input": "respawn"}'
	edit '{"op": "link", "id": 13, "comp": 0, "output": "pressed", "to": 14, "input": "join"}'
	edit '{"op": "link", "id": 8, "comp": 0, "output": "given", "to": 16, "input": "count"}'
	for v in '2, 1, -4] kit/stone' '-2, 1, -4] kitboss/hard' \
			'-3, 1, -4] kit/stone'; do
		edit "{\"op\": \"set_voxel\", \"pos\": [${v% *}, \"voxel\": \"${v##* }\"}"
	done
	cat <<EOF
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
EOF
	tools off
	cat <<EOF
event kit_use 8
wait_log 300000 kit: entity 16 shows "2
event kit_hold kitboss/blade
sync 2000
event kit_hit $BOB
sync 2000
delay 8000
event kit_use 12
sync 2000
delay 2000
event kit_use 10
sync 2000
delay 6000
event kit_use 13
sync 2000
delay 2000
event kit_use 15
sync 2000
delay 1000
event kit_use 11
sync 3000
EOF
	tools on
	for p in '2, 1, -4' '-2, 1, -4' '-3, 1, -4'; do
		printf 'event kit_edit {"op": "voxel_info", "pos": [%s]}\nsync 1000\n' "$p"
	done
	printf 'sync 3000\nquit\n'
} > "$t/boss.cmds"
cat > "$t/bob.cmds" <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
event kit_use 8
wait_log 300000 your health 0/20
event kit_hit $BOSS
sync 1000
event kit_use 8
sync 1000
event workbench_build {"p": [3, 0, 3], "voxel": "air"}
sync 1000
wait_log 60000 your health 20/20
event kit_use 13
sync 2000
wait_log 120000 your health 0/20
sync 2000
quit
EOF
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss &
boss=$!
wait_for_log "$t/srv.log" "gives kitboss 1 kitboss/blade" 300 ||
	fail "kitboss did not get to play ($t/srv.log)"
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 client bob
wait $boss || fail "the admin's client ($t/boss.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -a "died\|waiting\|respawn\|hurt\|blast\|explode\|on_died\|Voxel at\|joins team\|hits entity" "$s" |
	sed 's/^.*\(kit\|wasm\) *: /  /' | grep -v "^ *$" | cut -c1-200
want "$s" "kitbob joined world as entity $BOB"
# 1. A death, waiting, refusals, the respawn by the signal
python3 - "$s" "$t/bob.log" <<PY || fail "the death and the wait ($s)"
import sys
log = open(sys.argv[1], errors="replace").read()
bob = open(sys.argv[2], errors="replace").read()
died = log.index("kitbob died (normal by kitboss): waiting to respawn")
seen = log.index("workbench/probe 9: on_died $BOB by kitboss normal")
back = log.index("respawns 1 waiting players")
assert died < back, "respawned before the death"
mid = log[died:back]
for w in ["kitbob's hit refused: waiting to respawn",
		"kitbob's use refused: waiting to respawn",
		"a build by kitbob refused: not in edit mode and not allowed at (3,0,3): Waiting to respawn"]:
	assert w in mid, w
assert "kitbob respawns at entity 5" in log[died:back + 200]
assert "waiting to respawn" in bob, "no HUD line"
print("  died, on_died seen, refused while waiting, respawned by the signal")
PY
want "$t/bob.log" "your health 0/20" "your health 20/20"
echo "ok: kitbob killed: on_died seen by a scene probe; waiting (hit, use, dig refused, the HUD says so) until game_rules' respawn input"
# 2. c:hurt by fraction
want "$s" "hurts kitboss: 5 hurt" "hit 5 hurt by kitboss hp 15"
echo "ok: c:hurt {fraction = 0.25}: kitboss 20 to 15"
# 3. The blast
python3 - "$s" <<'PY' || fail "the blast ($s)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
b = log.index("explodes at (0.00,1.50,-4.00) radius 3.5")
after = log[b:]
assert "kitbob joins team" in log[:b] and "kitboss joins team" in log[:b]
assert "blast hits kitbob: 20 blast" in after, "no kill"
assert "blast hits kitboss: 10 blast" in after, "no 50%"
assert "hit 10 blast by kitboss hp 5" in after
assert "kitbob died (blast by kitboss): waiting to respawn" in after
assert re.search(r"workbench/probe 9: on_blast 0 1.5 -4 by kitboss", after), "no on_blast"
assert "probe 10: on_blast" not in after, "on_blast out of the radius"
assert "Voxel at (2,1,-4): air" in after, "the plain cell stands"
assert "Voxel at (-2,1,-4): kitboss/hard" in after, "the resistant cell gone"
assert "Voxel at (-3,1,-4): kit/stone" in after, "the protected cell gone"
m = re.search(r"explodes at .*: (\d+) cells to air, (\d+) protected", after)
assert int(m.group(1)) > 0 and int(m.group(2)) >= 1, m.group(0)
print("  " + m.group(0).split(": ", 1)[1])
PY
echo "ok: c:explode: kitbob (a teammate, friendly_fire off) killed within 3.5, kitboss 50% at 5 m; on_blast within the radius; plain cell to air, a blast_resist 5 cell and a dig-none region's cell kept"
echo "PASS: [KIT_CTF] P2: on_died, respawn on_signal, a waiting player's actions refused, c:hurt by fraction, c:explode (cells, resistance, protection, kill, share, friendly fire, on_blast)"
# vim: set noet ts=4 sw=4:
