#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1.5 min (2026-11-06)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/box/box.c builtin/kit/types/effect.lua builtin/kit/types/explosive.lua builtin/kit/types/controls.lua builtin/kit/types/pickup.lua builtin/kit/client_lua/effects.lua builtin/kit/client_lua/players.lua builtin/kit/client_lua/controls.lua
# [KIT_PARTICLES], [KIT_FEEDBACK_EFFECTS] kit/effect on a fresh Workbench
# save, two clients. kitboss composes: a World, rules, a pvp region where
# all may dig and place, a knife, kit/controls with a distance on its shake
# and effects on hit (blood: along the hit, scaled by the damage, a tint, an
# arc), dig (the voxel's material), place, blast (debris, a ring, a light,
# linked to the shake), respawn and pickup, a fountain on a signal, a blinking
# explosive. Played: kitboss 2 m from kitbob (the check's keys teleport):
# a dig, a place, a knife hit (blood at half the count as half the health
# goes; the tint on kitboss's screen, the arc on kitbob's alone), the bomb
# (blinking faster; its blast hits kitbob, shakes both, the one further less),
# a kill and its respawn, a pickup. Then the check's type calls c:effect
# with values out of every range, 32 a run, again and again: clamped on the
# server, past its rate refused, the client's live particles capped.
# Screenshots (look at them): blood.png, fountain.png, blast.png, arc.png
#   util/kit_particles_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_particles; t=$CHECK_TMP
mkdir -p "$t/user/apps/workbench/check_types"
cat > "$t/user/apps/workbench/check_types/drive.lua" <<'EOF'
-- The check's keys. Y U I: who pressed them to their p<n> (`who`'s); J the
-- fountain; K the bomb; L c:effect out of range, 32 a run, 30 runs
local acts = {}
local params = {who = {type = "string", default = ""},
	fountain = {type = "entity", default = 0},
	bomb = {type = "entity", default = 0}}
for i, k in ipairs({"Y", "U", "I"}) do
	acts[i] = {name = "warp" .. i, key = k, label = "Warp " .. i}
	params["p" .. i] = {type = "position", default = {0, 1, 0}}
end
acts[4] = {name = "fountain", key = "J", label = "Fountain"}
acts[5] = {name = "bomb", key = "K", label = "Bomb"}
acts[6] = {name = "spam", key = "L", label = "Spam"}
local function spam(c)
	for i = 1, 32 do
		c:effect{count = 1e9, shape = "nonsense", colors = {"red", "#ff00ff"},
			at = {i, 3, 3}, dir = {0, 0, 0}, spread = 999, speed_min = 1e9,
			speed_max = -1, gravity = 1e9, ttl_min = 1e9, ttl_max = 0,
			size_min = 999, grow = 1e9, spin = 1e9, box = 1e9,
			light_color = "white", light_time = 1e9, flash_time = 1e9,
			player = 42, arc_time = 1e9}
	end
end
return {
	version = 1,
	actions = acts,
	params = params,
	state = {left = {default = 0}},
	on_timer = function(c)
		spam(c)
		c.state.left = c.state.left - 1
		if c.state.left > 0 then
			c:after(0.02)
		else
			c:log("spam done")
		end
	end,
	on_action = function(c, name, phase, value, by)
		if phase ~= "pressed" then
			return
		end
		if name == "fountain" then
			c:send(c.params.fountain, "burst")
		elseif name == "bomb" then
			c:send(c.params.bomb, "arm")
		elseif name == "spam" then
			c.state.left = 30
			c:after(0.02)
		else
			local p = c.params["p" .. name:sub(5)]
			if p and c.params.who == c:name(by) then
				c:teleport(p)
			end
		end
	end,
}
EOF
export BUILDAT_WORKBENCH_TYPES=$t/user/apps/workbench/check_types
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 4 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client() # <name>: its commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
{
	run_client 90 "$t/$1.log" timeout 300 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 4 \
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
id=2
edit() { printf 'event kit_edit %s\nwait_log 10000 kit editor: state:\n' "$1"; }
place() # <type> <x, y, z>: the next id
{
	id=$((id + 1))
	edit "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$2]}"
}
set_() # <param>=<json>...: of the entity just placed
{
	local a
	for a in "$@"; do
		edit "{\"op\": \"set\", \"id\": $id, \"comp\": 0, \"param\": \"${a%%=*}\", \"value\": ${a#*=}}"
	done
}
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
event kit_edit {"op": "item", "name": "knife", "preset": "kit/sword", "damage": 10, "knockback": 0, "crit": 1, "cooldown": 0.3}
wait_log 10000 kit: 8 item types
EOF
	place kit/world '0, 1, 0'
	set_ 'generator="flat"' 'decorations=false' 'biome="grassland"'
	place kit/game_rules '0, 1, 0'
	set_ 'respawn="at_once"'
	place kit/spawner '0, 1, 0'
	set_ 'players=true'
	place kit/region '-16, -4, -16'
	set_ 'size=[33, 16, 33]' 'pvp="all"' 'dig="all"' 'place="all"'
	place kit/item_giver '1, 1, -3'; GIVER=$id
	set_ 'item="kitboss/knife"'
	place kit/controls '0, 1, 0'; CONTROLS=$id
	set_ 'shake_amount=2' 'shake_near=2' 'shake_far=20'
	place kit/effect '5, 1, 5'
	set_ 'on="hit"' 'count=24' 'color="#d00000"' 'along_hit=true' 'spread=45' \
		'scale_by_damage=true' 'speed_min=0.5' 'speed_max=3' 'gravity=9' \
		'ttl_min=1' 'ttl_max=1.2' 'size_min=0.08' 'size_max=0.12' 'land=true' \
		'flash_time=0.15' 'flash_color="#ff2020"' 'arc_time=1.5'
	place kit/effect '5, 1, 6'
	set_ 'on="dig"' 'shape="voxel"' 'count=16' 'speed_min=1' 'speed_max=3' \
		'ttl_min=0.5' 'ttl_max=1' 'size_min=0.1' 'size_max=0.16' 'land=true' \
		'spread=70' 'offset=[0, 0.4, 0]'
	place kit/effect '5, 1, 7'
	set_ 'on="place"' 'shape="round"' 'count=8' 'color="#a09080"' 'gravity=0' \
		'speed_min=0.3' 'speed_max=0.8' 'ttl_min=0.4' 'ttl_max=0.6' 'grow=2' \
		'size_min=0.2' 'size_max=0.3'
	place kit/effect '5, 1, 8'; DEBRIS=$id
	set_ 'on="blast"' 'shape="voxel"' 'count=40' 'speed_min=3' 'speed_max=7' \
		'ttl_min=0.8' 'ttl_max=1.2' 'size_min=0.1' 'size_max=0.2' 'axis=[0, 1, 0]' \
		'spread=80' 'light_time=0.15' 'light_range=14' 'light_brightness=4'
	edit "{\"op\": \"link\", \"id\": $DEBRIS, \"comp\": 0, \"output\": \"fired\", \"to\": $CONTROLS, \"input\": \"shake\"}"
	place kit/effect '5, 1, 9'
	set_ 'on="blast"' 'shape="ring"' 'count=1' 'color="#ffe0a0"' 'speed_min=0' \
		'speed_max=0' 'gravity=0' 'ttl_min=0.25' 'ttl_max=0.25' 'size_min=1' \
		'size_max=1' 'grow=24' 'fade=0.6'
	place kit/effect '5, 1, 10'
	set_ 'on="respawn"' 'count=20' 'color="#80e0ff"' 'gravity=-1' 'offset=[0, 0.5, 0]'
	place kit/effect '5, 1, 11'
	set_ 'on="pickup"' 'count=14' 'color="#ffe060"' 'gravity=2'
	place kit/effect '1.5, 1, 0'; FOUNTAIN=$id
	set_ 'count=60' 'color="#ffd070"' 'color2="#ffffff"' 'spread=25' \
		'speed_min=2.5' 'speed_max=4.2' 'gravity=9' 'ttl_min=0.7' 'ttl_max=0.9'
	place kit/explosive '2, 1, 3'; BOMB=$id
	set_ 'fuse=2.5' 'radius=1' 'kill=0' 'hurt=5' 'share=0.25' 'sound_every=1' \
		'blink_color="#ff3010"' 'blink_slow=0.8' 'blink_fast=0.1'
	place kit/pickup '-4, 1, 0'
	set_ 'item="kit/planks"'
	place workbench/drive '-8, 1, -8'
	set_ 'who="kitboss"' 'p1=[0, 1, -2]' 'p2=[0, 1, -20]' \
		"fountain=$FOUNTAIN" "bomb=$BOMB"
	place workbench/drive '-8, 1, -9'
	set_ 'who="kitbob"' 'p2=[-4, 1, 0]'
	cat <<EOF
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode off
event kit_use $GIVER
wait_log 60000 kit: items: kitboss/knife
event kit_hold kitboss/knife
wait_log 10000 drawn in first person
wait_log_any 120000 kit: player $BOB's body drawn
keypress Y
sync 2000
delay 800
look_dir 0 -0.25 1
frames 10
keypress J
wait_log 5000 kit: effect 60 of 60 square
frames 8
screenshot $t/fountain.png
event workbench_build {"p": [-1, 0, 1], "voxel": "air"}
wait_log 5000 kit: digging
delay 1100
event workbench_build {"p": [-1, 0, 1], "voxel": "air"}
wait_log 5000 kit: effect 16 of 16 voxel
delay 150
screenshot $t/dig.png
event kit_hold kit/grass
sync 1000
event workbench_build {"p": [-2, 1, 1], "voxel": "kit/grass"}
wait_log 5000 kit: effect 8 of 8 round
event kit_hold kitboss/knife
sync 1000
delay 400
event kit_hit $BOB
wait_log 5000 kit: effect 12 of 12 square
frames 3
screenshot $t/blood.png
wait_log_any 5000 body flashes
screenshot $t/flash.png
delay 800
keypress K
wait_log 10000 kit: effect 1 of 1 ring
frames 2
screenshot $t/blast.png
wait_log_any 5000 kit: camera shake
delay 800
event kit_hit $BOB
wait_log 5000 kit: effect 20 of 20 square
wait_log_any 5000 kit: effect 14 of 14 square
delay 300
keypress L
wait_log 10000 kit: effect 0 of 256 square
sync 2000
delay 1000
quit
EOF
} > "$t/boss.cmds"
cat > "$t/bob.cmds" <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
sync 2000
look_dir 0 0 -1
frames 3
wait_log 300000 kit: a hit's arc
frames 5
screenshot $t/arc.png
wait_log 30000 kit: a hit's arc
wait_log 60000 kit: kill message
wait_log 30000 kit: effect 20 of 20 square
delay 300
keypress U
wait_log 10000 kit: effect 14 of 14 square
wait_log 60000 kit: effect 0 of 256 square
sync 1000
quit
EOF
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss &
boss=$!
until grep -aq "the server is Running (by kitboss)" "$t/boss.log" 2>/dev/null; do
	kill -0 $boss 2>/dev/null ||
		fail "kitboss did not build the game ($t/boss.log, $t/srv.log)"
	sleep 1
done
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 client bob &
bob=$!
wait $boss || fail "kitboss's client ($t/boss.log)"
wait $bob || fail "kitbob's client ($t/bob.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
! grep -a "edit refused\|kit:edit_refused\|attempt to\|does not have field or property" \
	"$s" "$t/boss.log" "$t/bob.log" | head -5 | grep . || fail "a fault in the logs ($t)"
# The bursts reach both: dig's and place's materials, blood's count by the
# damage (10 of 20: half of 24)
for l in boss bob; do
	want "$t/$l.log" "kit: effect 16 of 16 voxel" "kit: effect 8 of 8 round" \
		"kit: effect 12 of 12 square" "kit: effect 1 of 1 ring" ", a light" \
		"kit: camera shake from"
done
want "$s" "an effect of 12 square" "an effect of 256 square" \
	"effect refused: past 240 bursts a second" "a hit's arc to player $BOB"
# The tint seen by the other, the arc on the victim's screen alone
want "$t/boss.log" "kit: player $BOB's body flashes"
want "$t/bob.log" "kit: a hit's arc from"
! grep -aqF "kit: a hit's arc from" "$t/boss.log" || fail "the arc on the hitter's screen"
python3 - "$t/boss.log" "$t/bob.log" "$s" <<'PY' || fail "the numbers ($t)"
import re, sys
boss, bob, srv = (open(f, errors="replace").read() for f in sys.argv[1:4])
# The client's cap: live never past 1500, bursts dropped at it
for name, log in (("boss", boss), ("bob", bob)):
    lives = [int(x) for x in re.findall(r"kit: effect \d+ of \d+ .*?, (\d+) live", log)]
    assert lives and max(lives) <= 1500, (name, "live", max(lives))
    assert re.search(r"kit: effect 0 of 256", log), name + ": nothing dropped"
# Weaker further away: kitboss 5.4 m from the bomb, kitbob 3.6
def shake(log):
    d = float(re.search(r"camera shake from ([0-9.]+) m", log).group(1))
    a = float(re.search(r"camera shake from [0-9.]+ m\n.*kit: camera shake ([0-9.e-]+)", log).group(1))
    return d, a
bd, ba = shake(boss)
od, oa = shake(bob)
print("  shake: kitboss %.1f m %.3f, kitbob %.1f m %.3f" % (bd, ba, od, oa))
assert bd > od and ba < oa, "the further shakes less"
assert 0 < ba < 2 and 0 < oa <= 2
# Blinking faster: the periods logged go down
ps = [float(x) for x in re.findall(r"kit/explosive \d+: blink ([0-9.]+)", srv)]
print("  blink periods:", ps[:3], "...", ps[-3:])
assert len(ps) >= 4 and ps[-1] < ps[0], "not faster"
print("  ok")
PY
for f in fountain dig blood flash blast arc; do
	[ -s "$t/$f.png" ] || fail "no screenshot $f ($t)"
done
echo "PASS: [KIT_PARTICLES] effects by events and signals reach the clients, clamped and capped; screenshots in $t"
# vim: set noet ts=4 sw=4:
