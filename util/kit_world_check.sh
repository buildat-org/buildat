#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min, more with a cold module cache (luanti_mapgen) (2026-10-30)
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
#      the surface set to a heightmap (valleys, 256 a side), which waits
#      for the next start.
#   4. A restart: the heightmap generated, the admin standing on it.
#   web: the heightmap's save in the web client (headless Chrome).
# The screenshots (flat, noise, valleys, heightmap, web_heightmap) are kept
# with KEEP_TMP=1; look at them.
#   util/kit_world_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_world; t=$CHECK_TMP
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
# A World parameter set, and the edit's answer: the undo count
set_w() # <param> <json value>
{
	n=$((n + 1))
	printf 'event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "%s", "value": %s}\nwait_log 10000 entities, %d to undo\n' "$1" "$2" "$n"
}
# Play from the start (the app's spawn on the World's ground), a look over
# it, the shot, and Stopped again with the tools on
shot() # <name>
{
	cat <<EOF
keypress F6
wait_log 10000 kit editor: edit mode off
event kit_edit {"op": "play"}
wait_log 10000 the server put the player at
idle 30000
look_dir 1 -0.3 1
frames 10
idle 30000
frames 5
screenshot @T@/$1.png
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Stopped (by kitboss)
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
wait_log 10000 kit editor: the server is Stopped (by kitboss)
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
vh=$(grep -aoP 'World by kitboss: valleys 192x192.*heights hash \K[0-9a-f]+' "$s" | tail -1)
[ -n "$vh" ] || fail "no valleys hash ($s)"
want "$t/boss1.log" "kit: warning: World: not applied: the noise generator needs the role water"
echo "ok: flat, a biome, a role missing refused by name, noise hills (by seed: $h0, $h7, $h0b), valleys without rivers with a water border"

# 2. The baked map, then infinite noise, an edit, a new seed (Stopped,
# as the save says)
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
wait_log 10000 kit editor: edit mode off
event kit_edit {"op": "play"}
wait_log 10000 the server put the player at
idle 30000
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Stopped (by kitboss)
look_dir 0.01 -1 0.01
frames 3
mouse_click left
frames 3
sync 5000
keypress F6
wait_log 10000 kit editor: state:
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

# 3. The save holds the edited section alone; the heightmap waits
{
	joined
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: state: 2 entities, 0 to undo
EOF
	n=0
	set_w size '"finite"'
	set_w surface '"heightmap"'
	echo "wait_log_any 10000 kit: warning: World: the surface and a heightmap's size apply at the next start"
	set_w width 256
	set_w depth 256
	set_w generator '"valleys"'
	set_w level -26
	echo quit
} > "$t/boss3.cmds"
server 3
client boss3
stop
s3=$t/srv3.log
want "$s3" "World: noise infinite, seed 9" "World: the save holds 1 sections (1 edited)"
echo "ok: an infinite world's save holds its edited section and nothing it only generated"

# 4. The heightmap
{
	joined
	cat <<'EOF'
idle 30000
look_dir 1 -0.25 1
frames 10
screenshot @T@/heightmap.png
quit
EOF
} > "$t/boss4.cmds"
server 4
client boss4
stop
s4=$t/srv4.log
want "$s4" "World: valleys 256x256, seed 9, biome grassland, a heightmap"
echo "ok: a heightmap surface, the admin on it"

# web: the heightmap in the web client, a guest
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
want "$t/web/server.log" "World: valleys 256x256, seed 9, biome grassland, a heightmap"
echo "PASS: Kit's World: flat, noise and valleys generated by seed, a missing role refused, a finite map baked, an infinite one saving only its edited section, an edit kept over a regeneration with its seams named, a heightmap surface (native and web)"
# vim: set noet ts=4 sw=4:
