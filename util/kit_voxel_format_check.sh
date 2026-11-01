#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-01)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/world.h builtin/kit/types/world.lua builtin/kit/client_lua/module.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/move.lua builtin/kit/client_lua/controls.lua builtin/kit/client_data/KitVoxel* apps/workbench/**
# [KIT_VOXEL_FORMAT] (kit_plan 4g2) Kit's voxel format on Workbench: id,
# param (a shape's facing), tint and sky light in one word; shapes as
# voxels of their own ("kit/stone:stair"); the World's sky_light. A fresh
# save, the admin Ended, a World (flat grassland):
#   1. Placed by the editor's set_voxel: a stone stair facing 5 (upside
#      down) tinted 3, a planks slab; param 300 and tint 16 refused; a
#      slab tinted over by stone and the undo giving the slab back with
#      its facing and tint; a 2x2x2 room dug under the ground, closed.
#      Each read back (voxel_info). Sky light off: nothing computed (the
#      open air reads 0). A shot (sky_off).
#   2. sky_light on: no generation again, the loaded sections relit (the
#      time it took logged), the client remeshing with it; the open air
#      15, the closed room 0; a shaft dug down to it lets light in. In
#      play a slab placed by Workbench's own build packet (param, tint).
#      A shot (sky_on).
#   3. A restart: the shapes, facings and tints as they were (the ids
#      stable), the sky light on at the start and told to the client.
# An old save reads 0 in the new bits by construction: an id-only word
# has nothing above bit 16 (kit::voxel_format()).
# The shots are kept with KEEP_TMP=1; look at them.
#   util/kit_voxel_format_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_voxel_format; t=$CHECK_TMP
cd "$here/Build"

server() # <n>
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
		--sim-rate "$CHECK_RATE" ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <name>: its commands in $t/<name>.cmds
{
	sed -i "s|@T@|$t|g" "$t/$1.cmds"
	run_client 60 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/$1.log, $t/srv*.log)"
}
stop()
{
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
n=0
ed() { printf 'event kit_edit %s\n' "$1"; }
# An edit and the undo count it leaves
edit() # <json>
{
	n=$((n + 1))
	ed "$1"
	printf 'wait_log 10000 entities, %d to undo\n' "$n"
}
vox() # <x> <y> <z> <voxel> [param tint]
{
	if [ $# -gt 4 ]; then
		edit "{\"op\": \"set_voxel\", \"pos\": [$1, $2, $3], \"voxel\": \"$4\", \"param\": $5, \"tint\": $6}"
	else
		edit "{\"op\": \"set_voxel\", \"pos\": [$1, $2, $3], \"voxel\": \"$4\"}"
	fi
}
# A cell read back into the server's log; the sync orders it after what
# came before
info() # <x> <y> <z>
{
	ed "{\"op\": \"voxel_info\", \"pos\": [$1, $2, $3]}"
	echo "sync 5000"
}
refused() # <json> <reason>
{
	ed "$1"
	printf 'wait_log 10000 kit editor: refused: %s\n' "$2"
}
joined()
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
EOF
}
# Play, a look at the shapes, the shot, Ended again with the tools on
shot() # <name> [commands in play]
{
	cat <<EOF
keypress F6
wait_log 10000 the server put the player at
wait_log_any 10000 kit editor: edit mode off
idle 30000
${2:-}
look_dir 0.6 -0.35 0.6
frames 10
idle 30000
frames 5
screenshot @T@/$1.png
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
keypress F6
wait_log 10000 kit editor: state:
EOF
}
# The room: 2x2x2 at (6..7, -5..-4, 6..7), under grass, dirt and stone
ROOM="6 -5 6"
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
EOF
	joined
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	edit '{"op": "set", "id": 3, "comp": 0, "param": "biome", "value": "grassland"}'
	echo "wait_log_any 30000 kit: World: generated again"
	vox 3 1 3 kit/stone:stair 5 3
	vox 4 1 3 kit/planks:slab 0 0
	refused '{"op": "set_voxel", "pos": [4, 1, 4], "voxel": "kit/stone", "param": 300}' "set_voxel: param: a whole number 0..255"
	refused '{"op": "set_voxel", "pos": [4, 1, 4], "voxel": "kit/stone", "tint": 16}' "set_voxel: tint: a whole number 0..15"
	vox 5 1 3 kit/planks:slab 6 2
	vox 5 1 3 kit/stone
	n=$((n - 1))
	ed '{"op": "undo"}'
	printf 'wait_log 10000 entities, %d to undo\n' "$n"
	# The tint's ends side by side in the shots: none and 15
	vox 4 2 3 kit/stone 0 0
	vox 5 2 3 kit/stone 0 15
	for y in -5 -4; do for z in 6 7; do for x in 6 7; do
		vox $x $y $z air
	done; done; done
	info 3 1 3
	info 4 1 3
	info 5 1 3
	info 6 3 6
	info $ROOM
	shot sky_off
	edit '{"op": "set", "id": 3, "comp": 0, "param": "sky_light", "value": true}'
	echo "wait_log_any 10000 kit: sky light on"
	echo "wait_log_any 60000 kit: sky light: the loaded world relit"
	echo "idle 30000"
	info 6 3 6
	info $ROOM
	for y in 0 -1 -2 -3; do vox 6 $y 6 air; done
	echo "idle 30000"
	info $ROOM
	info 7 -5 7
	shot sky_on 'event workbench_build {"p": [2, 1, 3], "voxel": "kit/stone:slab", "param": 4, "tint": 2}
sync 5000
event kit_edit {"op": "voxel_info", "pos": [2, 1, 3]}
sync 5000'
	info 2 1 3
	echo quit
} > "$t/boss1.cmds"
server 1
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss1
stop
s=$t/srv1.log
grep -a "Voxel at\|sky light\|placed kit\|workbench: kitboss placed" "$s" | sed 's/^.*\(kit\|main\) *: /  /' | cut -c1-150
infos=$(grep -aoP 'Voxel at \K.*' "$s")
line() { echo "$infos" | sed -n "$1p"; }
want "$s" "placed kit/stone:stair (param 5, tint 3) at (3,1,3)" \
	"placed kit/planks:slab at (4,1,3)"
[ "$(line 1)" = "(3,1,3): kit/stone:stair, param 5, tint 3, sky light 0" ] &&
	[ "$(line 2)" = "(4,1,3): kit/planks:slab, param 0, tint 0, sky light 0" ] &&
	[ "$(line 3)" = "(5,1,3): kit/planks:slab, param 6, tint 2, sky light 0" ] ||
	fail "the shapes read back: $infos ($s)"
echo "ok: shapes placed with their facing and tint, read back; a bad param and tint refused; an undo gives a slab back with its facing and tint"
[ "$(line 4)" = "(6,3,6): air, param 0, tint 0, sky light 0" ] &&
	[ "$(line 5)" = "(6,-5,6): air, param 0, tint 0, sky light 0" ] ||
	fail "sky light off computed something: $infos ($s)"
want "$s" "World by kitboss: sky light on ("
grep -aA3 "World by kitboss: sky light on" "$s" | grep -aq "generated again" &&
	fail "the sky light generated the World again ($s)"
relit=$(grep -aoP 'World: sky light: \K.*' "$s" | head -1)
[ "$(line 6)" = "(6,3,6): air, param 0, tint 0, sky light 15" ] &&
	[ "$(line 7)" = "(6,-5,6): air, param 0, tint 0, sky light 0" ] ||
	fail "sky light on: the open air and the closed room: $infos ($s)"
r8=$(line 8 | grep -oP 'sky light \K\d+')
r9=$(line 9 | grep -oP 'sky light \K\d+')
[ "${r8:-0}" -gt 0 ] && [ "${r9:-0}" -gt 0 ] && [ "$r9" -lt 15 ] ||
	fail "the shaft let no light into the room: $(line 8); $(line 9) ($s)"
want "$t/boss1.log" "kit: sky light on"
echo "ok: sky light off computes nothing; on ($relit) generates nothing again, the open air 15, the closed room 0, a shaft lets light in (under it $r8, a corner $r9)"
want "$s" "workbench: kitboss placed kit/stone:slab (2,1,3): written"
# Read in play (sky light 15: a slab lets the light through), then the
# round's build discarded at End
[ "$(line 10)" = "(2,1,3): kit/stone:slab, param 4, tint 2, sky light 15" ] &&
	[ "$(line 11)" = "(2,1,3): air, param 0, tint 0, sky light 15" ] ||
	fail "Workbench's build packet: $(line 10); $(line 11) ($s)"
echo "ok: Workbench's own placing carries the shape's facing and the tint (a build: discarded at End)"

# 3. A restart: what was placed as it was, the sky light on at the start
{
	joined
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: state:
EOF
	info 3 1 3
	info 5 1 3
	info 2 1 3
	info 6 3 6
	# What the sky light costs a generation: a new seed, sky light on
	ed '{"op": "set", "id": 3, "comp": 0, "param": "seed", "value": 3}'
	echo "wait_log_any 30000 kit: World: generated again"
	echo quit
} > "$t/boss2.cmds"
server 2
client boss2
stop
s2=$t/srv2.log
infos=$(grep -aoP 'Voxel at \K.*' "$s2")
want "$s2" "World: sky light on ("
want "$t/boss2.log" "kit: sky light on"
# A shape lets the sky through (transmits_light): lit (the slab under
# the tinted stone a step less)
[ "$(line 1)" = "(3,1,3): kit/stone:stair, param 5, tint 3, sky light 15" ] &&
	[ "$(line 2)" = "(5,1,3): kit/planks:slab, param 6, tint 2, sky light 14" ] &&
	[ "$(line 3)" = "(2,1,3): air, param 0, tint 0, sky light 15" ] &&
	[ "$(line 4)" = "(6,3,6): air, param 0, tint 0, sky light 15" ] ||
	fail "after the restart: $infos ($s2)"
# The generation's time: from the World's line to the sections' count
gen_ms() # <log>
{
	awk '/World by kitboss: [0-9]+ sections generated again/ { split($3, a, ":"); t0 = a[1] * 3600 + a[2] * 60 + a[3]; n = $10 }
		t0 && /sections generated since the start/ { split($3, a, ":"); printf "%d sections in %.0f ms", n, (a[1] * 3600 + a[2] * 60 + a[3] - t0) * 1000; exit }' "$1"
}
echo "  generated again: sky light off $(gen_ms "$s"), on $(gen_ms "$s2")"
echo "PASS: Kit's voxel format: shapes with a facing and a tint placed (the editor's and Workbench's), undone and read back over a restart; the World's sky light off computing nothing, on relighting at once without generating, a closed room dark and a shaft lighting it"
# vim: set noet ts=4 sw=4:
