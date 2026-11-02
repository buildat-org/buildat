#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min, more with a cold module cache (luanti_mapgen) (2026-10-31)
# covers: builtin/kit/** apps/workbench/** builtin/voxelworld/persistence.h builtin/luanti_mapgen/api.h builtin/heightmap/**
# [KIT] stage 4e, Kit's World (kit/world) on Workbench, the admin (kitboss,
# by the setup code) editing its parameters Stopped and playing each:
#   1. A fresh save: flat stone (Workbench's default, biome rock); the
#      World placed and set to grassland (generated again: grass); the
#      noise generator refused in biome rock (no water role, named), then
#      noise hills in grassland; seed 7 and back to 0 (the heights' hash
#      the same, 7's another); Luanti's valleys without rivers, 192 cells
#      a side with a water border.
#   2. A restart: the finite map baked (every section from the save, none
#      generated, the same hash); then infinite noise: generated round the
#      player; a cell dug while Stopped (an edit), and a new seed generates
#      again every section but that one, the warning naming its seams.
#   3. A restart: the save holds the one edited section and nothing else;
#      the surface set to a heightmap, which replaces the voxels at once
#      (the client builds it), back to voxels (the client drops it) and a
#      heightmap again (valleys, 512 a side: [KIT_HM_ORIGIN] centred on
#      the origin, over the cells part 5's brushes are tried on).
#   4. A restart: the save's heightmap, the admin standing on it and
#      walking a few metres each way ([KIT_HM_WALK]).
#   5. ([KIT] stage 4f) A restart: the heightmap's decorations (voxel
#      objects) the save's; the terrain brushes on it by their packets,
#      Stopped: a raise stroke (two dabs, one undo) steep enough that its
#      edge is stone, undone to the map's hash before it; lower, smooth,
#      flatten under the sea (the riverbed's layer), paint (desert's sand),
#      a fill up to a level, a water fill refused, a decorate stroke adding
#      decorations and its undo taking them; the World's seed changed and
#      back, the decorations' hash by it.
#   6. A fresh save: flat grassland without decorations; each brush on the
#      voxels by its packet, the column it leaves read back -- raise (the
#      grass on top, dirt to the biome's depth, stone under), the stroke's
#      undo, lower under the sea (sand under water), paint desert (sand to
#      its depth), fill grassland and water, smooth, flatten (the layers
#      exposed again); decorations and caves on (the edited section kept),
#      seed 3 and back to 0 (the decorations' and caves' counts and hashes,
#      and columns of an unedited section the same by the seed), a
#      decorate stroke and its undo; Kit's editor's terrain tool by mouse
#      in the plan (T, a dragged stroke, Ctrl+Z its undo) and the caves seen
#      through the plan's cut.
#   web: the heightmap's save in the web client (headless Chrome).
# The screenshots (flat, noise, valleys, heightmap_live, heightmap, heightmap_close,
# heightmap_edited, grass, decorated, brush, stroked, caves, web_heightmap)
# are kept with KEEP_TMP=1; look at them.
#   util/kit_world_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
# Workbench opens its project "world" at once, no Manage
# ([WORKBENCH_PROJECTS]: workbench_check.sh goes through Manage)
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_world; t=$CHECK_TMP
cd "$here/Build"

server() # <n> [user dir]
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "${2:-$t/user}" -l 3 \
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
# A World parameter set, and the edit's answer: the undo count
set_w() # <param> <json value>
{
	n=$((n + 1))
	printf 'event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "%s", "value": %s}\nwait_log 10000 entities, %d to undo\n' "$1" "$2" "$n"
}
# The surface set, and the client's line that says the heightmap's change
surface_w() # <surface> <client log text>
{
	n=$((n + 1))
	printf 'event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "surface", "value": "%s"}\nwait_log 10000 %s\nwait_log_any 10000 entities, %d to undo\n' "$1" "$2" "$n"
}
# One that regenerates the ground (Stopped), and the wait for its
# sections: a column read before them reads none
regen_w() # <param> <json value>
{
	printf 'event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "%s", "value": %s}\nwait_log 10000 kit: World: generated again\n' "$1" "$2"
}
# Play from the start (the app's spawn on the World's ground), a look over
# it, the shot, and Stopped again with the tools on
shot() # <name>
{
	cat <<EOF
keypress F6
wait_log 10000 the server put the player at
wait_log_any 10000 kit editor: edit mode off
idle 30000
look_dir 1 -0.3 1
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
joined()
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
EOF
}
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
event kit_edit {"op": "place", "type": "kit/world", "pos": [0, 1, 0]}
wait_log 10000 entities, 1 to undo
EOF
	n=1
	set_w biome '"grassland"'
	shot flat
	set_w biome '"rock"'
	set_w generator '"noise"'
	echo "wait_log_any 10000 kit: warning: World: not applied: the noise generator needs the role water"
	set_w biome '"grassland"'
	set_w seed 7
	set_w seed 0
	shot noise
	set_w generator '"valleys"'
	set_w seed 5
	set_w level -26
	set_w width 192
	set_w depth 192
	set_w border '"water"'
	shot valleys
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
grep -a " kit *: World" "$s" | sed 's/^.*kit *: /  /' | cut -c1-150
want "$s" "World: flat 64x64, seed 0, biome rock, voxels, border void; ground 0 to 0" \
	"World by kitboss: flat 64x64, seed 0, biome grassland" \
	"World: not applied: the noise generator needs the role water, which biome rock has none of" \
	"World by kitboss: noise 64x64, seed 7, biome grassland" \
	"World by kitboss: valleys 192x192, seed 5, biome grassland, voxels, border water" \
	"sections generated again, 0 edited kept"
# Deterministic by seed: noise seed 0 the same heights twice, 7 others
hashes=$(grep -aoP 'World by kitboss: noise 64x64, seed \d+, .*heights hash \K[0-9a-f]+' "$s")
h0=$(echo "$hashes" | sed -n 1p) h7=$(echo "$hashes" | sed -n 2p) h0b=$(echo "$hashes" | sed -n 3p)
[ -n "$h0" ] && [ "$h0" = "$h0b" ] && [ "$h0" != "$h7" ] ||
	fail "noise's heights by seed: $hashes ($s)"
# ([KIT] stage 4f) and its decorations
dh=$(grep -aoP 'World by kitboss: noise 64x64, seed \d+, .*decorations \d+ \(hash \K[0-9a-f]+' "$s")
[ "$(echo "$dh" | sed -n 1p)" = "$(echo "$dh" | sed -n 3p)" ] &&
	[ "$(echo "$dh" | sed -n 1p)" != "$(echo "$dh" | sed -n 2p)" ] ||
	fail "noise's decorations by seed: $dh ($s)"
vh=$(grep -aoP 'World by kitboss: valleys 192x192.*heights hash \K[0-9a-f]+' "$s" | tail -1)
[ -n "$vh" ] || fail "no valleys hash ($s)"
want "$t/boss1.log" "kit: warning: World: not applied: the noise generator needs the role water"
echo "ok: flat, a biome, a role missing refused by name, noise hills (by seed: $h0, $h7, $h0b), valleys without rivers with a water border"

# 2. The baked map, then infinite noise, an edit, a new seed (Stopped,
# as the save says); the admin digs the cell under it in edit mode (the
# editor's camera does not turn): Ended refuses a play dig
# ([KIT_BUILDER_PLAY_RULES], [KIT_PLAY_RULES_CHECKS_FAULT])
{
	joined
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: state: 2 entities, 0 to undo
EOF
	n=0
	set_w size '"infinite"'
	set_w generator '"noise"'
	set_w level 0
	cat <<'EOF'
keypress F6
wait_log 10000 the server put the player at
wait_log_any 10000 kit editor: edit mode off
idle 30000
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
keypress F6
wait_log 10000 kit editor: state:
event workbench_build {"p": [1, 6, 1], "voxel": "air"}
sync 5000
EOF
	set_w seed 9
	echo "wait_log_any 10000 kit: warning: World: 1 edited sections kept, seams where they meet the new ground"
	echo quit
} > "$t/boss2.cmds"
server 2
client boss2
stop
s2=$t/srv2.log
grep -a " kit *: World\|workbench: kitboss dug" "$s2" | sed 's/^.*\(kit\|main\) *: /  /' | cut -c1-150
want "$s2" "World: valleys 192x192, seed 5, biome grassland, voxels, border water" \
	"heights hash $vh" "(0 edited)" "World by kitboss: noise infinite, seed 5" \
	"World by kitboss: noise infinite, seed 9" "1 edited kept"
grep -aq "World: the save holds 0 sections" "$s2" && fail "the baked map was not in the save ($s2)"
# Baked: nothing generated before the World changed
awk '/World by kitboss/ { exit } /sections generated since the start/ { bad = 1 } END { exit bad }' "$s2" ||
	fail "the baked map was generated again at the start ($s2)"
grep -aq "workbench: kitboss dug .*: written" "$s2" || fail "the admin's dig ($s2)"
echo "ok: the finite map baked and read back (hash $vh), infinite noise generated round the player, an edited section kept over a new seed, its seams named"

# 3. The save holds the edited section alone; the heightmap at once
{
	joined
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: state: 2 entities, 0 to undo
EOF
	n=0
	set_w size '"finite"'
	# [KIT_WORLD_HEIGHTMAP] The surface at once: the heightmap built on
	# the client, the voxels gone; back to voxels (the map removed) and
	# to the heightmap again
	surface_w heightmap "heightmap: terrain built"
	shot heightmap_live
	surface_w voxels "heightmap: removed"
	surface_w heightmap "heightmap: terrain built"
	set_w width 512
	set_w depth 512
	set_w generator '"valleys"'
	set_w level -26
	echo quit
} > "$t/boss3.cmds"
server 3
client boss3
stop
s3=$t/srv3.log
want "$s3" "World: noise infinite, seed 9" "World: the save holds 1 sections (1 edited)" \
	"World by kitboss: noise 192x192, seed 9, biome grassland, a heightmap" \
	"World by kitboss: noise 192x192, seed 9, biome grassland, voxels" \
	"World by kitboss: valleys 512x512, seed 9, biome grassland, a heightmap"
grep -aq "warning: World: the surface" "$t/boss3.log" && fail "a surface change waits ($t/boss3.log)"
echo "ok: an infinite world's save holds its edited section and nothing it only generated; the surface a heightmap at once, voxels and a heightmap again"

# 4. The heightmap
{
	joined
	cat <<'EOF'
idle 30000
look_dir 1 -0.25 1
frames 10
screenshot @T@/heightmap.png
look_dir 0 0 1
frames 10
event kit_body
keydown w
frames 60
keyup w
event kit_body
keydown a
frames 60
keyup a
event kit_body
keydown s
frames 60
keyup s
event kit_body
keydown d
frames 60
keyup d
event kit_body
quit
EOF
} > "$t/boss4.cmds"
server 4
client boss4
stop
s4=$t/srv4.log
want "$s4" "World: valleys 512x512, seed 9, biome grassland, a heightmap"
# [KIT_HM_WALK] The admin walks on it: w, a, s and d each move the body
# metres its way (no voxel section was loaded over a heightmap, and an
# unloaded cell is solid to the movement: walled in a cell)
grep -a "kit: body at" "$t/boss4.log" |
	sed 's/.*body at \([^,]*\),[^,]*,\([^,]*\), .* \([0-9]*\) corrections.*/\1 \2 \3/' > "$t/walk4"
awk 'NR == 1 { x = $1; z = $2; c = $3; next }
	{ dx = $1 - x; dz = $2 - z; leg = NR - 1
	  if (leg == 1 && dz < 2 || leg == 2 && dx > -2 || leg == 3 && dz > -2 || leg == 4 && dx < 2) bad = bad " leg " leg
	  if ($3 != c) bad = bad " corrections in leg " leg
	  x = $1; z = $2; c = $3 }
	END { if (NR != 5) bad = bad " " NR " positions"; if (bad) { print bad; exit 1 } }' "$t/walk4" ||
	fail "walking on the heightmap: $(tr '\n' ';' < "$t/walk4") ($t/boss4.log)"
echo "ok: a heightmap surface, the admin on it walking each way"

# A brush's dab: terrain <tool> <x> <z> <size> <strength> <stroke> [more JSON]
terrain()
{
	printf 'event kit_edit {"op": "terrain", "tool": "%s", "x": %s, "y": 0, "z": %s, "size": %s, "strength": %s, "stroke": %s%s}\nwait_log 5000 kit editor: terrain: %s\n' \
		"$1" "$2" "$3" "$4" "$5" "$6" "${7:+, $7}" "$1"
}
column() # <x> <z>
{
	printf 'event kit_edit {"op": "terrain", "tool": "column", "x": %s, "y": 0, "z": %s}\nwait_log 5000 kit editor: terrain: column at (%s,\n' "$1" "$2" "$1"
}
undo()
{
	printf 'event kit_edit {"op": "undo"}\nwait_log 5000 kit editor: state:\n'
}

# 5. ([KIT] stage 4f) The brushes on the heightmap (its map from the
# origin, the admin at its middle), Stopped as part 4 saved it
{
	joined
	cat <<'EOF'
idle 3000
look_dir 1 -0.7 1
frames 10
screenshot @T@/heightmap_close.png
keypress F6
wait_log 10000 kit editor: state:
EOF
	column 150 150
	for i in 1 2; do terrain raise 150 150 3 5 1; done
	column 153 150
	undo
	for i in 1 2 3; do terrain raise 150 150 3 5 2; done
	terrain lower 140 160 3 5 3
	terrain smooth 150 150 4 4 4
	for i in $(seq 16); do terrain flatten 112 140 3 5 5 '"level": -3'; done
	column 112 140
	terrain paint 160 125 3 2 6 '"biome": "desert"'
	column 160 125
	terrain fill 120 160 3 2 7 '"x1": 126, "z1": 166, "level": 30'
	column 123 163
	echo 'event kit_edit {"op": "terrain", "tool": "fill", "x": 120, "y": 0, "z": 160, "x1": 126, "z1": 166, "level": 30, "biome": "water", "stroke": 8}'
	echo "wait_log 5000 kit editor: refused: terrain: no water on a heightmap yet"
	terrain decorate 135 110 8 5 9
	undo
	terrain decorate 135 110 8 5 10
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir 1 -0.35 1
frames 10
idle 2000
screenshot @T@/heightmap_edited.png
keypress F6
wait_log 10000 kit editor: state:
EOF
	for v in 4 9; do
		echo 'event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "seed", "value": '$v'}'
		echo "wait_log 10000 kit editor: state:"
	done
	echo quit
} > "$t/boss5.cmds"
server 5
client boss5
stop
s5=$t/srv5.log
grep -a "Terrain by kitboss\|An undo by kitboss\|World: .*decorations\|decorations on the heightmap" "$s5" | sed 's/^.*kit *: /  /' | cut -c1-200
want "$s5" "World: valleys 512x512, seed 9, biome grassland, a heightmap" \
	"decorations on the heightmap (the save's)" \
	"Terrain by kitboss: raise at (150,150) size 3 strength 5 on the heightmap" \
	"Terrain by kitboss: lower at (140,160)" "Terrain by kitboss: smooth at (150,150)" \
	"Terrain by kitboss: flatten at (112,140)" "(112,140) at -3.000000 layer 2" \
	"(160,125) at" "fill grassland (120,160) to (126,166) up to 30.000000" \
	"(123,163) at 30.000000 layer 0" "An edit (terrain) by peer 1 refused: no water on a heightmap yet"
# The decorations the save had are those generated at part 4
d4=$(grep -aoP 'World: valleys 512x512, seed 9, .*decorations \K\d+ \(hash [0-9a-f]+' "$s4" | head -1)
grep -aqF "decorations $d4" "$s5" || fail "the heightmap's decorations not the save's: $d4 ($s4, $s5)"
# The stroke's two dabs one undo, back to the map's hash; its edge steep:
# stone (layer 1)
h0=$(grep -aoP 'column at \(150,150\) .* map hash \K\d+' "$s5" | head -1)
grep -aq "An undo by kitboss: a terrain stroke, 0 cells, [0-9]* samples and 0 decorations put back, map hash $h0" "$s5" ||
	fail "the raise stroke's undo did not put the map back ($h0, $s5)"
grep -aq "column at (153,150) .*layer 1," "$s5" || fail "the raised hill's edge is not stone ($s5)"
grep -aq "Terrain by kitboss: paint at (160,125).*(160,125) at [0-9.-]* layer 2" "$s5" ||
	fail "the desert's paint ($s5)"
dec=$(grep -aoP 'decorate at \(135,110\) .*, \K\d+(?= decorations \()' "$s5" | head -1)
[ "${dec:-0}" -gt 0 ] || fail "the decorate stroke placed none ($s5)"
grep -aq "An undo by kitboss: a terrain stroke, 0 cells, 0 samples and $dec decorations put back" "$s5" ||
	fail "the decorate stroke's undo ($dec, $s5)"
# Its decorations by the seed: 4's and 9's differ, the decorate stroke's
# kept over both ([KIT_HEIGHTMAP_REGEN_LOSS]: a builder's decorations and
# edited samples stay over a regeneration)
dd=$(grep -aoP 'World by kitboss: valleys 512x512, seed \d+, .*decorations \K\d+ \(hash [0-9a-f]+' "$s5")
[ -n "$(echo "$dd" | sed -n 2p)" ] && [ "$(echo "$dd" | sed -n 2p)" != "$(echo "$dd" | sed -n 1p)" ] ||
	fail "the heightmap's decorations by the seed: $d4, then $dd ($s5)"
[ "$(grep -ac "decorations on the heightmap (generated), $dec of them a builder's" "$s5")" = 2 ] ||
	fail "the decorate stroke's $dec decorations not kept over the seed's changes ($s5)"
echo "ok: the brushes on the heightmap (raise a stroke undone to its hash, its edge stone; lower, smooth, flatten under the sea to the riverbed, paint, fill, water refused, decorate and its undo), its decorations the save's and by the seed ($d4)"

# 6. ([KIT] stage 4f) The brushes on voxels: a fresh save, flat grassland
# (top 0, sea 0), without decorations until they are tested
mkdir -p "$t/user6"
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
event kit_edit {"op": "place", "type": "kit/world", "pos": [0, 1, 0]}
wait_log 10000 entities, 1 to undo
EOF
	n=1
	regen_w decorations false
	regen_w biome '"grassland"'
	column 8 8
	for i in 1 2; do terrain raise 8 8 2 2 11; done
	undo
	column 8 8
	terrain raise 8 8 2 2 12
	terrain lower 20 8 3 3 13
	terrain paint 8 20 3 2 14 '"biome": "desert"'
	terrain fill 20 20 2 2 15 '"x1": 26, "z1": 26, "level": 3'
	terrain fill 4 26 2 2 16 '"x1": 8, "z1": 30, "level": 2, "biome": "water"'
	terrain smooth 20 20 3 3 17
	terrain flatten 23 23 2 5 18 '"level": 0'
	cat <<'EOF'
keypress F6
wait_log 10000 the server put the player at
wait_log_any 10000 kit editor: edit mode off
idle 2000
look_dir 1 -0.35 1
frames 10
idle 3000
screenshot @T@/grass.png
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
keypress F6
wait_log 10000 kit editor: state:
EOF
	regen_w decorations true
	regen_w caves true
	for c in "-20 -20" "-10 -25" "-25 -5" "-6 -14"; do column $c; done
	regen_w seed 3
	regen_w seed 0
	for c in "-20 -20" "-10 -25" "-25 -5" "-6 -14"; do column $c; done
	terrain decorate -12 -12 4 5 21
	undo
	terrain decorate -12 -12 4 5 22
	cat <<'EOF'
keypress F6
wait_log 10000 the server put the player at
wait_log_any 10000 kit editor: edit mode off
idle 2000
look_dir -1 -0.35 -1
frames 10
idle 3000
screenshot @T@/decorated.png
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
keypress F6
wait_log 10000 kit editor: state:
keypress F1
wait_log 5000 kit editor: the view is 2D
keypress T
wait_log 5000 kit editor: tool terrain
mouse_pos 500 380
frames 5
screenshot @T@/brush.png
mouse_down left
frames 2
mouse_pos 540 380
frames 2
mouse_pos 590 390
frames 2
mouse_up left
wait_log 5000 kit editor: the stroke ended
wait_log_any 5000 kit editor: terrain: raise
frames 10
screenshot @T@/stroked.png
keydown ctrl
keypress Z
keyup ctrl
wait_log 5000 kit editor: state:
keypress Escape
wait_log 5000 kit editor: tool select
EOF
	for i in $(seq 22); do echo 'click Button "Cut -"'; done
	cat <<'EOF'
frames 10
screenshot @T@/caves.png
quit
EOF
} > "$t/boss6.cmds"
server 6 "$t/user6"
wait_for_log "$t/srv6.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv6.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv6.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss6
stop
s6=$t/srv6.log
grep -a "Terrain by kitboss\|An undo by kitboss: a terrain\|World by kitboss" "$s6" | sed 's/^.*kit *: /  /' | cut -c1-220
# Each brush's column after it: the grass on top, the filler (dirt) to the
# biome's depth, stone under; under the sea the riverbed (sand) and water
want "$s6" "column (8,8): air 1..2, kit/grass 0, kit/dirt -3..-1, kit/stone -6..-4" \
	"raise at (8,0,8) size 2 strength 2: 13 columns, " \
	"column (8,8): air 3..4, kit/grass 2, kit/dirt -1..1, kit/stone -4..-2, stroke 11" \
	"column (8,8): air 5..6, kit/grass 4, kit/dirt 1..3, kit/stone -2..0, stroke 11" \
	"An undo by kitboss: a terrain stroke, " \
	"column (20,8): kit/water -2..-1, kit/sand -6..-3, kit/stone -9..-7, stroke 13" \
	"column (8,20): air 1..2, kit/sand -4..0, kit/stone -6..-5, stroke 14" \
	"fill grassland (20,20) to (26,26) up to 3: 49 columns, " \
	"column (20,20): air 4..5, kit/grass 3, kit/dirt 0..2, kit/stone -3..-1, stroke 15" \
	"fill water (4,26) to (8,30) up to 2: 25 columns, 50 cells; column (4,26): kit/water 1..2, kit/grass 0" \
	"column (23,23): air 1..2, kit/grass 0, kit/dirt -3..-1, kit/stone -6..-4, stroke 18"
# The undo put the column back as it was
[ "$(grep -aoP 'column at \(8,0,8\) .*; \Kcolumn \(8,8\): .*' "$s6" | sort -u | wc -l)" = 1 ] ||
	fail "the raise stroke's undo did not put column (8,8) back ($s6)"
grep -aqP "smooth at \(20,0,20\) size 3 strength 3: \d+ columns, [1-9]\d* cells" "$s6" ||
	fail "the smooth changed nothing ($s6)"
# Decorations and caves by the seed: 0's again after 3's, and the columns
# of a section nobody edited the same
w0=$(grep -aoP 'World by kitboss: flat 64x64, seed 0, .*caves \(\K.*' "$s6" | sed -n 1p)
w3=$(grep -aoP 'World by kitboss: flat 64x64, seed 3, .*caves \(\K.*' "$s6" | sed -n 1p)
w0b=$(grep -aoP 'World by kitboss: flat 64x64, seed 0, .*caves \(\K.*' "$s6" | sed -n 2p)
[ -n "$w0" ] && [ "$w0" = "$w0b" ] && [ "$w0" != "$w3" ] ||
	fail "decorations and caves by the seed: $w0 / $w3 / $w0b ($s6)"
echo "$w0" | grep -qP '^[1-9]\d* of \d+ sampled cells\), decorations [1-9]' ||
	fail "no caves or decorations: $w0 ($s6)"
grep -aq "[1-9][0-9]* edited sections kept" "$s6" || fail "the edited sections were not kept ($s6)"
for c in "-20,0,-20" "-10,0,-25" "-25,0,-5" "-6,0,-14"; do
	# at seed 0, and at seed 0 again after 3
	[ "$(grep -aP "column at \\($c\\)" "$s6" | sed 's/^.*; column/column/' | tail -2 | sort -u | wc -l)" = 1 ] ||
		fail "column ($c) not the same by the seed ($s6)"
done
grep -aqP "decorate at \(-12,0,-12\) size 4 strength 5: \d+ columns, [1-9]\d* cells" "$s6" ||
	fail "the decorate stroke placed nothing ($s6)"
want "$t/boss6.log" "kit editor: tool terrain" "kit editor: the stroke ended" "kit editor: tool select"
grep -aq "Terrain by kitboss: raise at .*stroke [0-9]\{6,\}" "$s6" || fail "the mouse's stroke ($s6)"
[ "$(grep -ac "An undo by kitboss: a terrain stroke" "$s6")" = 3 ] ||
	fail "Ctrl+Z, the undo of the mouse's stroke ($s6)"
echo "ok: the brushes on voxels (raise, its stroke undone, lower under the sea, paint, fill ground and water, smooth, flatten exposing the layers), decorations and caves by the seed ($w0), a decorate stroke and its undo, the terrain tool by mouse"

# 7. ([KIT_VOXEL_EDITS]) The voxel edits manager: a fresh save (stone,
# flat), a cell dug Ended; the terrain tool's list has its section with
# one changed cell; Regenerate clicked while Running is refused (the row
# hovered under the pointer), Ended it drops the section's writes (the
# cell stone again, the list empty), and the undo digs it again
mkdir -p "$t/user7"
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
	column 5 5
	cat <<'EOF'
event kit_edit {"op": "set_voxel", "pos": [5, 0, 5], "voxel": "air"}
wait_log 10000 entities, 1 to undo
EOF
	column 5 5
	cat <<'EOF'
keypress F1
wait_log 5000 kit editor: the view is 2D
keypress T
wait_log 5000 kit editor: tool terrain
event kit_edit {"op": "edited"}
wait_log 10000 kit editor: edited sections: 1 0,0,0=1
frames 5
screenshot @T@/edited.png
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running
click Button "Regenerate"
wait_log 5000 kit editor: section hovered: 0,0,0
wait_log 5000 kit editor: refused: regenerate: the game is Running
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended
event kit_edit {"op": "edited"}
wait_log 10000 kit editor: edited sections: 1 0,0,0=1
click Button "Regenerate"
wait_log 10000 kit editor: edited sections: 0
wait_log_any 30000 kit: World: generated again
EOF
	column 5 5
	undo
	echo 'event kit_edit {"op": "edited"}'
	echo "wait_log 10000 kit editor: edited sections: 1 0,0,0=1"
	column 5 5
	echo quit
} > "$t/boss7.cmds"
server 7 "$t/user7"
wait_for_log "$t/srv7.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv7.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv7.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss7
stop
s7=$t/srv7.log
want "$s7" "World by kitboss: 1 edited sections regenerated, 1 cells back to the generator's, 0 skipped (2 to undo)" \
	"An undo by kitboss: a regeneration, 1 cells"
# The column: stone, dug, stone again, dug again
cols=$(grep -aoP 'column at \(5,0,5\) .*; \Kcolumn \(5,5\): .*' "$s7")
[ "$(echo "$cols" | wc -l)" = 4 ] && [ "$(echo "$cols" | sed -n 1p)" = "$(echo "$cols" | sed -n 3p)" ] &&
	[ "$(echo "$cols" | sed -n 2p)" = "$(echo "$cols" | sed -n 4p)" ] &&
	[ "$(echo "$cols" | sed -n 1p)" != "$(echo "$cols" | sed -n 2p)" ] ||
	fail "the column through dig, regenerate and undo: $cols ($s7)"
echo "ok: the voxel edits manager: a dug cell's section listed with its one cell, Regenerate refused Running, Ended the cell generated again, the undo digging it again"

# web: the heightmap in the web client, a guest (as chat_top_check: with
# no Chrome or no web client built, the native part's pass)
if ! command -v "${CHROME:-google-chrome}" > /dev/null || [ ! -f "$here/web/buildat.wasm" ]; then
	echo "PASS: Kit's World natively (the web skipped: no Chrome or web/): flat, noise and valleys generated by seed, a missing role refused, a finite map baked, an infinite one saving only its edited section, an edit kept over a regeneration with its seams named, a heightmap surface; the terrain brushes on both surfaces, decorations and caves"
	exit 0
fi
mkdir -p "$t/web/user"
cp -a "$t/user/." "$t/web/user/"
stub="(function(){ var held = null;
 Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }});
 HTMLCanvasElement.prototype.requestPointerLock = function(){ held = this; document.dispatchEvent(new Event('pointerlockchange')); return Promise.resolve(); };
 document.exitPointerLock = function(){ held = null; document.dispatchEvent(new Event('pointerlockchange')); };
 return 'stub'; })()"
cat > "$t/web_steps.json" <<J
[
	["nav", "\${URL}"],
	["waitlog", "player physics enabled", 120],
	["waitlog_any", "pause: the menu shown", 10],
	["eval", "$(echo "$stub" | tr "\n" " ")"],
	["click", 100, 700], ["waitlog", "pause: the menu closed", 10],
	["frames", 30],
	["shot", "\${OUT}/web_heightmap.png"]
]
J
"$here/util/web_drive.sh" chrome workbench "$t/web_steps.json" "$t/web" ||
	fail "the web drive ($t/web)"
cp "$t/web/web_heightmap.png" "$t/" 2>/dev/null
want "$t/web/server.log" "World: valleys 512x512, seed 9, biome grassland, a heightmap"
echo "PASS: Kit's World: flat, noise and valleys generated by seed, a missing role refused, a finite map baked, an infinite one saving only its edited section, an edit kept over a regeneration with its seams named, a heightmap surface (native and web); the terrain brushes on both surfaces, decorations and caves"
# vim: set noet ts=4 sw=4:
