#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~6 min (2026-11-04)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/types/flag.lua builtin/kit/types/explosive.lua builtin/kit/types/placer.lua builtin/kit/types/part.lua builtin/kit/types/hut.prefab.json builtin/kit/types/bomb_look.prefab.json builtin/kit/sounds.json builtin/kit/types/arena.lua builtin/kit/types/region.lua builtin/kit/client_lua/hands.lua apps/workbench/**
# [KIT_CTF] Capture the flag composed on a fresh Workbench save with the
# editor's ops alone (kitboss, the admin, Stopped), then played by three
# clients. The composition (compose() below; the game's numbers in
# game_values, the check's shorter ones over them):
#   the lobby (scene "world"): a flat World, kit/game_rules (inventory
#     building, hand_level 0, on_death keep, respawn on_signal), a
#     spawner of players, a kit/arena off it (map "map", time_up "most");
#     the items kitboss/knife (kit/sword: damage 1000, reach 3, cooldown
#     5, no knockback) and kitboss/bomb (use "use", the look kit/bomb_look)
#   the map (scene "map"): a flat 96x96 grassland World (grass 1, dirt 1,
#     stone: soil_depth 1), huts (kit/hut), teams Red (+x) and Blue (-x) with their zones
#     (regions under them), a map-wide region allowing dig and place, a
#     prep region over the map (enter none) a prep kit/timer disables, the
#     flag (kit/flag, a pole kit/part under it) at the middle in a
#     protected column region to the bottom, its timer, scoring bar,
#     immunity and holder texts, the arena's status in a text, a starting
#     kit of 10 kit/planks, a kit/placer of kitboss/bomb copies (a saved
#     prefab of a kit/explosive), spawners of pickaxe (by each zone),
#     bomb and knife pickups (saved prefabs of kit/pickup)
# Played (the check's own type workbench/warp: keys teleporting their
# presser to set places, as walking there would): kitboss (Red), kitbob
# (Blue), kitcat (Red) queue in that order;
#   1. prep: kitbob's warp out of his zone put back; the flag disabled
#   2. kitboss takes the flag at home by touch (x1.3 speed); kitcat, his
#      teammate, beside him past the immunity takes nothing; kitbob does
#      (immune 5 s after), places it in Blue's zone: a point after the
#      interval; his click takes it back (the count starts over), placed
#      again: the next point a whole interval after
#   3. kitcat: stone by hand refused, with a pickaxe from the spawner dug,
#      kit/cobble dropped
#   4. kitboss with the knife kills kitbob carrying it: the flag home, he
#      respawns at once (waiting on the flag's home); killed again with
#      the flag home: back at once
#   5. kitcat takes it, places it by the bomb spawner, puts a bomb ahead:
#      it hisses, explodes, the flag falls into the hole; the return
#      timer sends it home
#   6. time up: Blue wins by the most points; all back in the lobby
#   7. a second round 0:0 at its time up runs on as overtime; kitboss
#      walks with the flag (a screenshot sequence), places it in Red's
#      zone: Red wins; all back in the lobby
# Screenshots (look at them): kitboss's first person and kitcat's third
# person of the carried flag, a walking sequence, the bomb held and lying.
#   util/kit_ctf_check.sh
# **To play it** without building it by hand: KIT_CTF_SAVE=<dir> builds
# the game alone (its own values) into a new Workbench save and copies the
# project there; put it under your user/apps/workbench/saves/<name>
# (or give that directly) and open <name> in Workbench's Manage:
#   KIT_CTF_SAVE=user/apps/workbench/saves/ctf util/kit_ctf_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
build_only=${KIT_CTF_SAVE:-}
if [ -n "$build_only" ]; then
	case "$build_only" in /*) ;; *) build_only=$PWD/$build_only ;; esac
	[ -e "$build_only" ] && { echo "$build_only exists"; exit 1; }
fi
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_ctf; t=$CHECK_TMP
# The game's own values, then the check's: shorter, three players
PREP=60 IMMUNITY=5 INTERVAL=10 RETURN=120 DURATION=600 EVERY=60 PLAYERS=2
COUNTDOWN=10 RESULTS=8
if [ -z "$build_only" ]; then
	PREP=6 INTERVAL=4 RETURN=30 DURATION=90 EVERY=3 PLAYERS=3 COUNTDOWN=3
	RESULTS=3
	# (in its app directory: the sandboxed server reads nothing else of
	# the run's)
	mkdir -p "$t/user/apps/workbench/check_types"
	cat > "$t/user/apps/workbench/check_types/warp.lua" <<'EOF'
-- The check's warps: each action teleports who pressed it (`who` alone,
-- "" anyone) to its p<n>. Five
local acts, params = {}, {who = {type = "string", default = ""}}
for i, k in ipairs({"Y", "U", "I", "O", "P"}) do
	acts[i] = {name = "warp" .. i, key = k, label = "Warp " .. i}
	params["p" .. i] = {type = "position", default = {0, 1, 0}}
end
return {
	version = 1,
	actions = acts,
	params = params,
	on_action = function(c, name, phase, value, by)
		local p = c.params["p" .. name:sub(5)]
		if phase == "pressed" and p and not c.player_away and
				(c.params.who == "" or c.params.who == c:name(by)) then
			c:log(c:name(by), name, "to", p[1], p[2], p[3])
			c:teleport(p)
		end
	end,
}
EOF
	export BUILDAT_WORKBENCH_TYPES=$t/user/apps/workbench/check_types
fi
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client() # <name>: its commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
{
	run_client 120 "$t/$1.log" timeout 900 bin/buildat -C "$t/client_cache" \
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
# An edit and the editor's state after it; one with no entity's id
ed() { printf 'event kit_edit %s\nwait_log 10000 kit editor: state:\n' "$1"; }
id=2
place() # <type> <x, y, z> [parent]: the next id
{
	id=$((id + 1))
	ed "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$2]${3:+, \"parent\": $3}}"
}
set_() # <id> <param> <value>
{
	ed "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
}
link() # <from> <output> <to> <input>
{
	ed "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"$2\", \"to\": $3, \"input\": \"$4\"}"
}
text() # <x, y, z> <text> <anchor> <y> [shown]: a kit/ui_text
{
	place kit/ui_text "$1"
	set_ $id text "\"$2\""
	set_ $id anchor "\"$3\""
	set_ $id y "$4"
	[ -z "${5:-}" ] || set_ $id shown "$5"
}
prefab_of() # <id> <name>: the entity saved as the builder's prefab, gone
{
	printf 'event kit_edit {"op": "save_prefab", "ids": [%s], "name": "%s"}\nsync 3000\n' "$1" "$2"
	ed "{\"op\": \"delete\", \"id\": $1}"
}
region() # <x, y, z> <size> <dig> <place> <enter> [parent]
{
	place kit/region "$1" "${6:-}"
	set_ $id size "[$2]"
	set_ $id dig "\"$3\""
	set_ $id place "\"$4\""
	set_ $id enter "\"$5\""
}
world() # <width>: the scene's World, flat grassland
{
	place kit/world '0, 1, 0'
	set_ $id surface '"voxels"'
	set_ $id generator '"flat"'
	set_ $id biome '"grassland"'
	set_ $id decorations false
	set_ $id border '"wall"'
	set_ $id width "$1"
	set_ $id depth "$1"
}
# The composition, by the editor's ops. Ids: 2 the lobby's scene, the rest
# as placed (the names below)
compose()
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
event kit_edit {"op": "item", "name": "knife", "preset": "kit/sword", "damage": 1000, "reach": 3, "cooldown": 5, "knockback": 0}
wait_log 10000 kit: 8 item types
event kit_edit {"op": "item", "name": "bomb", "preset": "kit/arrow", "use": "use", "stack": 16, "cooldown": 1, "look": "kit/bomb_look", "color": "#101010", "grip": [0.15, -0.15, 0.25]}
wait_log 10000 kit: 9 item types
EOF
	# The lobby
	world 32; LOBBY_WORLD=$id
	place kit/game_rules '0, 1, 0'; RULES=$id
	set_ $id hand_level 0
	set_ $id on_death '"keep"'
	set_ $id respawn '"on_signal"'
	place kit/spawner '0, 1, 0'
	set_ $id players true
	place kit/arena '8, 1, 0'; ARENA=$id
	set_ $id size '[3, 3, 3]'
	set_ $id players $PLAYERS
	set_ $id max_players 16
	set_ $id countdown $COUNTDOWN
	set_ $id duration $DURATION
	set_ $id results $RESULTS
	set_ $id time_up '"most"'
	set_ $id map '"map"'
	# The map
	id=$((id + 1))
	printf 'event kit_edit {"op": "new_scene", "name": "map"}\nwait_log 30000 kit editor: in the scene map of world, map\n'
	world 96
	# [KIT_SOIL_DEPTH] grass 1 over dirt 1 over stone: a tunnel needs a
	# pickaxe
	set_ $id soil_depth 1
	place kit/team '30, 1, 0'; RED=$id
	set_ $id name '"Red"'
	set_ $id color '"#d03030"'
	place kit/team '-30, 1, 0'; BLUE=$id
	set_ $id name '"Blue"'
	set_ $id color '"#3050e0"'
	region '24, -2, -6' '13, 12, 13' all all all $RED
	set_ $id owner '"team"'
	region '-36, -2, -6' '13, 12, 13' all all all $BLUE
	set_ $id owner '"team"'
	region '-50, -128, -50' '100, 384, 100' all all all
	region '-48, -128, -48' '96, 384, 96' all all none; PREP_REGION=$id
	region '-1, -128, -1' '3, 384, 3' none none all
	place kit/flag '0, 1, 0'; FLAG=$id
	set_ $id enabled false
	set_ $id take_home '"near"'
	set_ $id home_range 1
	set_ $id take_placed '"click"'
	set_ $id steal '"opponents"'
	set_ $id steal_range 2
	set_ $id immunity $IMMUNITY
	set_ $id speed 1.3
	set_ $id score_interval $INTERVAL
	set_ $id score_points 1
	set_ $id score_to '"region"'
	set_ $id return_time $RETURN
	set_ $id lift 1.4
	place kit/part '0, 1.2, 0' $FLAG
	set_ $id size '[0.06, 1.4, 0.06]'
	set_ $id color '"#c0a070"'
	set_ $id collision false
	place kit/timer '2, 1, 6'; PREP_TIMER=$id
	set_ $id interval 1
	set_ $id repeats $PREP
	set_ $id autostart true
	text '3, 1, 6' 'Prep {value} s: stay in your zone' center -120; PREP_TEXT=$id
	text '4, 1, 6' '{value}' top 10; STATUS=$id
	text '5, 1, 6' 'Flag home in {value} s' top_right 40 false; LEFT_TEXT=$id
	set_ $id x -12
	place kit/ui_bar '6, 1, 6'; BAR=$id
	set_ $id label '"Scoring {value}%"'
	set_ $id min 0
	set_ $id max 100
	set_ $id start 0
	set_ $id anchor '"top_right"'
	set_ $id x -12
	set_ $id y 70
	set_ $id color '"#40c040"'
	set_ $id shown false
	text '7, 1, 6' 'Immune {value} s' top_right 100 false; IMMUNE_TEXT=$id
	set_ $id x -12
	text '8, 1, 6' 'Flag carried by {value}' top 95 false; HOLDER_TEXT=$id
	link $PREP_TIMER left $PREP_TEXT value
	link $PREP_TIMER done $PREP_TEXT hide
	link $PREP_TIMER done $PREP_REGION disable
	link $PREP_TIMER done $FLAG enable
	link $ARENA status $STATUS value
	link $FLAG left $LEFT_TEXT value
	link $FLAG taken $LEFT_TEXT show
	link $FLAG home $LEFT_TEXT hide
	link $FLAG progress $BAR value
	link $FLAG placed $BAR show
	link $FLAG taken $BAR hide
	link $FLAG home $BAR hide
	link $FLAG immune $IMMUNE_TEXT value
	link $FLAG taken $IMMUNE_TEXT show
	link $FLAG placed $IMMUNE_TEXT hide
	link $FLAG home $IMMUNE_TEXT hide
	link $FLAG holder_team $HOLDER_TEXT value
	link $FLAG taken $HOLDER_TEXT show
	link $FLAG placed $HOLDER_TEXT hide
	link $FLAG home $HOLDER_TEXT hide
	link $FLAG home $RULES respawn
	place kit/starting_kit '9, 1, 6'
	set_ $id items '"kit/planks 10"'
	# The bomb: a kit/explosive saved as kitboss/bomb, put down by the
	# placer from the item kitboss/bomb
	place kit/explosive '10, 1, 6'
	set_ $id fuse 7
	set_ $id sound '"kit/hiss"'
	set_ $id sound_every 1
	set_ $id radius 3.5
	set_ $id kill 3.5
	set_ $id hurt 7
	set_ $id share 0.5
	set_ $id friendly_fire true
	prefab_of $id bomb
	place kit/placer '11, 1, 6'
	set_ $id item '"kitboss/bomb"'
	set_ $id prefab '"kitboss/bomb"'
	set_ $id signal '"arm"'
	set_ $id distance 1.5
	local p
	for p in kit/pickaxe:pickaxe kitboss/bomb:bomb kitboss/knife:knife; do
		place kit/pickup '12, 1, 6'
		set_ $id item "\"${p%%:*}\""
		prefab_of $id "${p##*:}_pickup"
	done
	for p in '21, 1, 0:pickaxe' '-21, 1, 0:pickaxe' '0, 1, 20:bomb' \
			'0, 1, -20:knife'; do
		place kit/spawner "${p%%:*}"
		set_ $id prefab "\"kitboss/${p##*:}_pickup\""
		set_ $id every $EVERY
		set_ $id max 1
	done
}
SCENE_MAP='event kit_edit {"op": "scene", "name": "map"}
wait_log 30000 kit editor: in the scene map of world, map'
SCENE_LOBBY='event kit_edit {"op": "scene", "name": "world"}
wait_log 30000 kit editor: in the scene world of world, map'
# Last (a prefab of voxels alone may take no id): huts in the map
huts()
{
	[ -n "$build_only" ] || echo "$SCENE_MAP"
	local p
	for p in '12, 1, 12' '-12, 1, -12' '12, 1, -14' '-12, 1, 14'; do
		printf 'event kit_edit {"op": "place", "prefab": "kit/hut", "pos": [%s]}\nsync 2000\n' "$p"
	done
	echo "$SCENE_LOBBY"
}
warps() # <who> <p1>..<p5>: a map warp of theirs
{
	place workbench/warp '-4, 1, 6'
	set_ $id who "\"$1\""
	shift
	local i=1 p
	for p in "$@"; do
		set_ $id p$i "[$p]"
		i=$((i + 1))
	done
}
# The check's own: the warps (the map's, the lobby's into the queue) and
# a stone to dig; then Play
extras()
{
	# Each one's: Y U I O P to p1..p5
	warps kitboss '0, 1, 0' '0, 1, -20' '0, 1, 0' '30, 1, 4' '-30, 1, 2'
	warps kitbob '0, 1, 20' '1, 1, 1' '0, 1, 0' '0, 1, 0' '-30, 1, 2'
	warps kitcat '0, 1, 0' '21, 1, 0' '-1, 1, 0' '0, 1, 20' '3, 1, 5'
	ed '{"op": "set_voxel", "pos": [21, 1, 2], "voxel": "kit/stone"}'
	printf 'event kit_edit {"op": "terrain", "tool": "column", "x": 20, "y": 0, "z": 20}\nwait_log 5000 kit editor: terrain: column at (20,\n'
	echo "$SCENE_LOBBY"
	place workbench/warp '-4, 1, 4'
	set_ $id p1 '[9, 1, 1]'
}
{
	compose
	[ -n "$build_only" ] || extras
	huts
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
sync 3000
EOF
} > "$t/build.cmds"
echo "FLAG=$FLAG RULES=$RULES ARENA=$ARENA RED=$RED BLUE=$BLUE"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
export BUILDAT_JOIN_CREATE=1
boss() # kitboss's client, the admin
{
	BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
		BUILDAT_JOIN_ADMIN="setting open_registration on" client boss
}
if [ -n "$build_only" ]; then
	{ cat "$t/build.cmds"; echo quit; } > "$t/boss.cmds"
	boss
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	! grep -a "kit:edit_refused\|edit refused" "$t/boss.log" "$t/srv.log" | head -5 | grep . ||
		fail "an edit was refused ($t/boss.log)"
	mkdir -p "$(dirname "$build_only")"
	cp -r "$t/user/apps/workbench/saves/world" "$build_only" ||
		fail "no save to copy ($t/user/apps/workbench/saves)"
	echo "Built: $build_only (open it in Workbench's Manage as $(basename "$build_only"))"
	exit 0
fi

# ---- The drives. Each waits for the HUD the others' acts change (its own
# client's log of the texts), so they keep in step
SHOWN='shown: "'
lobby() # <how many in the queue first> <wait_log_any|wait_log>: into it
{
	[ "$1" = 0 ] || printf '%s 200000 Waiting for players: %s of\n' "$2" "$1"
	printf 'delay 500\nkeypress Y\n'
}
{
	cat "$t/build.cmds"
	cat <<EOF
keypress F6
wait_log 10000 kit editor: edit mode off
EOF
	lobby 0 wait_log_any
	cat <<EOF
wait_log 60000 Prep 0 s
delay 500
keypress Y
wait_log_any 10000 ${SHOWN}Flag carried by Red
look_dir 1 1.2 0.3
frames 10
screenshot $t/boss_carry_fp.png
look_dir -1 0 0
wait_log 30000 ${SHOWN}Flag carried by Blue
keypress U
delay 1500
event kit_hold kitboss/knife
wait_log 60000 Red 0 : Blue 2
delay 300
keypress P
delay 800
event kit_hit nearest
delay 6500
event kit_hit nearest
wait_log 200000 Blue wins!
wait_log 60000 kit editor: in session 0
delay 2000
keypress F6
wait_log 10000 kit editor: edit mode on
EOF
	ed "{\"op\": \"set\", \"id\": $ARENA, \"comp\": 0, \"param\": \"duration\", \"value\": 12}"
	cat <<EOF
keypress F6
wait_log 10000 kit editor: edit mode off
EOF
	lobby 0 wait_log
	cat <<EOF
wait_log 60000 Overtime
delay 500
keypress Y
wait_log 10000 ${SHOWN}Flag carried by Red
look_dir 1 0 0
frames 5
keydown W
delay 400
screenshot $t/boss_walk_fp1.png
look_dir 1 0.8 0
delay 300
screenshot $t/boss_walk_fp2.png
delay 600
keyup W
look_dir 1 0 0
frames 10
keypress O
delay 800
keypress G
wait_log 60000 Red wins!
wait_log 60000 kit editor: in session 0
sync 2000
quit
EOF
} > "$t/boss.cmds"
{
	cat <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
EOF
	lobby 1 wait_log_any
	cat <<EOF
wait_log 60000 Prep 3 s
keypress Y
delay 500
wait_log 60000 Prep 0 s
wait_log 10000 ${SHOWN}Flag carried by Red
delay 9000
keypress U
wait_log 10000 ${SHOWN}Flag carried by Blue
keypress P
delay 800
keypress G
wait_log 30000 Red 0 : Blue 1
delay 2000
event kit_use $FLAG
delay 500
keypress G
wait_log 30000 Red 0 : Blue 2
event kit_use $FLAG
wait_log 30000 your health 0/
wait_log 30000 your health 20/20
wait_log 30000 your health 0/
wait_log 30000 your health 20/20
wait_log 200000 Blue wins!
EOF
	lobby 1 wait_log
	cat <<EOF
wait_log 60000 Red wins!
wait_log 60000 Last round: Red won
sync 2000
quit
EOF
} > "$t/bob.cmds"
{
	cat <<EOF
wait_log_any 60000 Joined as kitcat
wait_log_any 60000 player physics enabled
EOF
	lobby 2 wait_log_any
	cat <<EOF
wait_log 60000 Prep 0 s
wait_log 10000 ${SHOWN}Flag carried by Red
delay 300
keypress I
delay 1000
look_dir 1 1 0
frames 10
screenshot $t/cat_carry_3p.png
delay 6500
keypress U
delay 1500
EOF
	printf 'event workbench_build {"p": [21, 1, 2], "voxel": "air"}\nsync 2000\n'
	printf 'event kit_hold kit/pickaxe\nsync 1000\n'
	for _ in 1 2; do
		printf 'event workbench_build {"p": [21, 1, 2], "voxel": "air"}\nsync 2000\ndelay 1000\n'
	done
	cat <<EOF
wait_log 60000 Red 0 : Blue 2
delay 14000
keypress Y
wait_log 10000 ${SHOWN}Flag carried by Red
keypress O
delay 1000
keypress G
delay 500
event kit_hold kitboss/bomb
look_dir 0 -0.4 1
frames 10
screenshot $t/cat_bomb_held.png
event kit_click_at 0 1 22
delay 800
frames 5
screenshot $t/cat_bomb_lying.png
keypress U
delay 1000
look_dir -1 -0.2 1
wait_log 200000 Blue wins!
EOF
	lobby 2 wait_log
	cat <<EOF
wait_log 60000 Overtime
keypress P
delay 300
look_dir 0 0.25 -1
wait_log 60000 ${SHOWN}Flag carried by Red
delay 900
screenshot $t/cat_walk_1.png
delay 200
screenshot $t/cat_walk_2.png
delay 200
screenshot $t/cat_walk_3.png
delay 200
screenshot $t/cat_walk_4.png
wait_log 60000 Red wins!
wait_log 60000 Last round: Red won
sync 2000
quit
EOF
} > "$t/cat.cmds"
boss &
boss=$!
until grep -aq "the server is Running (by kitboss)" "$t/boss.log" 2>/dev/null; do
	kill -0 $boss 2>/dev/null ||
		fail "kitboss did not build the game ($t/boss.log, $t/srv.log)"
	sleep 1
done
BUILDAT_JOIN_NAME=kitbob client bob &
bob=$!
sleep 2
BUILDAT_JOIN_NAME=kitcat client cat
wait $bob || fail "kitbob's client ($t/bob.log)"
wait $boss || fail "kitboss's client ($t/boss.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -a "kit/flag\|kit/explosive\|kit/placer\|joins team\|died\|respawn\|may not enter\|speed x\|wins\|overtime\|dug kit/stone\|A dig by\|explodes" "$s" |
	grep -v "moves to" | sed 's/^.*\(kit\|wasm\) *: /  /' | cut -c1-170 | head -120
! grep -a "edit refused\|kit:edit_refused" "$s" "$t/boss.log" | head -5 | grep . ||
	fail "an edit was refused ($s)"
python3 - "$s" "$FLAG" <<'PY' || fail "the game ($s)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
F = "kit/flag " + sys.argv[2] + ": "
def after(a, text, what):
	i = log.find(text, a)
	assert i >= 0, what + ": no " + repr(text)
	return i
def part(n):
	return log.split("Session %d (a game)" % n)[1].split("Session %d ended" % n)[0]
s1, s2 = part(1), part(2)
for who, team in [("kitboss", "Red"), ("kitbob", "Blue"), ("kitcat", "Red")]:
	assert "%s joins team %s" % (who, team) in s1, who + " in " + team
# 1. prep
assert re.search(r"kitbob may not enter \(0,1,20\): [^\n]*; put back", s1), "prep"
# 2. takes, steals, places, points
i = s1.index(F + "enabled")
j = s1.index(F + "taken by kitboss from home (Red)")
assert i < j
assert "kitboss's speed x1.3" in s1[j:]
k = s1.index(F + "taken by kitbob from carried (Blue)")
assert "taken by kitcat" not in s1[:k], "a teammate took it"
mid = s1[j:k]
assert "kitcat warp3" in mid, "kitcat not beside kitboss"
assert "kitboss's speed x1" in s1[k:], "kitboss's speed not reset"
p1 = s1.index(F + "placed by kitbob", k)
sc1 = s1.index(F + "scores 1 for Blue", p1)
c1 = s1.index(F + "taken by kitbob from placed", sc1)
p2 = s1.index(F + "placed by kitbob", c1)
sc2 = s1.index(F + "scores 1 for Blue", p2)
assert F + "scores" not in s1[sc1 + 10:p2], "a point while carried"
# 4. the knife: home on the carrier's death, the waiting respawned
d1 = s1.index("kitbob died (normal by kitboss): waiting to respawn", sc2)
h1 = s1.index(F + "home: died", d1)
r1 = s1.index("respawns 1 waiting players", h1)
d2 = s1.index("kitbob died (normal by kitboss): waiting to respawn", r1)
r2 = s1.index("respawns 1 waiting players", d2)
# 5. the bomb
t2 = s1.index(F + "taken by kitcat from home (Red)", r2)
pl = s1.index(F + "placed by kitcat", t2)
pb = s1.index("kitcat places kitboss/bomb", pl)
ex = s1.index("explodes", pb)
fa = s1.index(F + "a blast drops it", ex)
ht = s1.index(F + "home: timer", fa)
m = re.search(r"Entity %s's kit/flag moves to \(([-0-9.]+), ([-0-9.]+), ([-0-9.]+)\)" % sys.argv[2], s1[fa:])
assert m and float(m.group(2)) < 1, "the flag did not fall: " + (m.group(0) if m else "no move")
# 6. the round's end
assert "has the most points" in s1 and "Blue wins!" in s1
# 7. overtime
assert "time up, tied: Red 0 : Blue 0 -- overtime" in s2
assert F + "taken by kitboss from home (Red)" in s2
assert "Red wins!" in s2
print("  ok")
PY
want "$s" "column (20,20): air 1..2, kit/grass 0, kit/dirt -1, kit/stone -6..-2" \
	"kitcat dug kit/stone (level 1) with kit/pickaxe (level 1): drops kit/cobble" \
	"A dig by kitcat refused: A hand does not dig kit/stone (level 1)"
for f in boss_carry_fp boss_walk_fp1 boss_walk_fp2 cat_carry_3p cat_bomb_held cat_bomb_lying cat_walk_1 cat_walk_4; do
	[ -s "$t/$f.png" ] || fail "no screenshot $f ($t)"
done
echo "PASS: [KIT_CTF] capture the flag composed by edit ops and played by three clients; screenshots in $t"
# vim: set noet ts=4 sw=4:
