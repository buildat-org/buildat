#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~30 s (2026-11-06)
# covers: builtin/kit/** apps/workbench/** client/core/aitta/**
# [KIT_MATERIAL_SETS] Material set packages on a local Aitta and Workbench:
#   1. alice's key bound on the Aitta; alice/redland 1.0.0 (a set: its
#      own voxel alice/red_grass, its texture in the archive, biomes
#      grassland and meadow, meadow without stone) and alice/blueland
#      1.0.0 (depends on redland and extends it: alice/blue_grass, its
#      grassland only the top role) packed and published.
#   2. The admin installs blueland from the New tab (redland with it,
#      first); places a World (flat grassland, Kit's set), a cobble voxel
#      at (-20,1,-20), away from the spawn's section; switches the World to redland: the sections nobody
#      wrote generated again, red_grass on top and redland's filler
#      (gravel) under it, the cobble's section kept (the seams warned;
#      its Kit grass at y 0 too; the section under it, y < 0, generated
#      again: gravel);
#      biome meadow refused naming the role stone; blueland: blue_grass on
#      top over redland's gravel (the later set winning per role), the
#      cobble still there.
#   3. [KIT_SET_ORPHAN_TEXTURES] alice/badland (a texture, and a decoration
#      naming no structure) refused at its install; [KIT_SET_UPGRADE_BREAKS]
#      alice/redland 2.0.0 (grassland without stone) refused as an upgrade,
#      naming the World it would break; at a restart the save still has 2
#      uploaded textures and redland 1.0.0.
#   4. [KIT_SET_MISSING_NO_HOST] A copy of the save with blueland's package
#      row deleted: Kit hosts, the World on the app's set with a warning
#      naming blueland.
# KEEP_TMP=1 keeps the screenshots: kit.png (Kit's set), red.png (redland),
# blue.png (blueland).
#   util/kit_material_sets_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_material_sets; t=$CHECK_TMP
b="$here/Build/bin/buildat"
cd "$here/Build"

# 1. The Aitta, alice's key, the two sets
start_server "$t/aitta.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/aitta" -l 3 ||
	fail "Aitta did not start ($t/aitta.log)"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
acode=$(grep -ao "setup code [A-Z0-9]*" "$t/aitta.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
fp=$(aitta_fp "$t/pub")
printf 'wait_log_any 20000 ai: {"id":1,\nquit\n' > "$t/bind.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$acode \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"alice\",\"key\":\"$(cat "$t/pub")\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$P -c @"$t/bind.cmds" > "$t/bind.log" 2>&1 ||
	fail "the bind's client ($t/bind.log)"
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind ($t/bind.log)"

# A 16x16 PNG of one colour: <file> <r> <g> <b>
png(){
	python3 -I -c '
import struct, sys, zlib
r, g, b = (int(x) for x in sys.argv[2:5])
def chunk(t, d):
	return struct.pack(">I", len(d)) + t + d + struct.pack(">I",
		zlib.crc32(t + d) & 0xffffffff)
raw = b"".join(b"\0" + bytes([r, g, b]) * 16 for _ in range(16))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" +
	chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0)) +
	chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))' "$@"
}
manifest(){ # <dir> <name> [deps]
	printf '{"kind": "kit", "author": "alice", "name": "%s", "version": "1.0.0",
		"engine_api": 2, "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "%s, a material set", "dependencies": [%s]}\n' \
		"$2" "$2" "${3:-}" > "$1/meta.json"
}
publish(){ # <dir>
	local zip
	zip=$("$b" aitta pack "$1" "$t/key" "$t/out" 2>"$t/pack.err") ||
		fail "pack $1: $(cat "$t/pack.err")"
	"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "listed: alice/" ||
		fail "publish $1"
	sleep 1 # the list's newest is by time, in seconds
}
mkdir -p "$t/redland/textures" "$t/blueland/textures"
png "$t/redland/textures/red_grass.png" 190 40 30
png "$t/blueland/textures/blue_grass.png" 40 70 200
cat > "$t/redland/materials.json" <<'EOF'
{"format": "kit_materials",
 "voxels": {"alice/red_grass": {"texture": "textures/red_grass.png",
	"heightmap": 0}},
 "biomes": {
	"grassland": {"top": "alice/red_grass", "filler": "kit/gravel",
		"filler_depth": 3, "stone": "kit/stone", "water": "kit/water",
		"riverbed": "kit/sand"},
	"meadow": {"top": "alice/red_grass", "filler": "kit/dirt"}}}
EOF
manifest "$t/redland" redland
cat > "$t/blueland/materials.json" <<'EOF'
{"format": "kit_materials", "extends": "alice/redland",
 "voxels": {"alice/blue_grass": {"texture": "textures/blue_grass.png"}},
 "biomes": {"grassland": {"top": "alice/blue_grass"}}}
EOF
manifest "$t/blueland" blueland '{"kit": "alice/redland", "version": "1.0.0"}'
publish "$t/redland"
publish "$t/blueland"
echo "ok: alice/redland and alice/blueland (extending it) published"

# 2. Workbench: installed, a World switched between the sets
mkdir -p "$t/cu"
now=$(date +%s)
echo "{\"starports\": [], \"aittas\": [\"http://127.0.0.1:$P\"]}" > "$t/cu/starport.json"
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","","%s","%s","","","",""\n' \
	"$P" "$now" "$now" > "$t/cu/network_addresses.csv"
export BUILDAT_CONNECT_PORTS=$P
n=0
set_w(){ # <param> <json value>: the edit's answer
	n=$((n + 1))
	printf 'event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "%s", "value": %s}\nwait_log 10000 entities, %d to undo\n' "$1" "$2" "$n"
}
regen_w(){ # <param> <json value>: and the ground generated again
	n=$((n + 1))
	printf 'event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "%s", "value": %s}\nwait_log 20000 kit: World: generated again\nwait_log_any 10000 entities, %d to undo\n' "$1" "$2" "$n"
}
column(){ # <x> <z>
	printf 'event kit_edit {"op": "terrain", "tool": "column", "x": %s, "y": 0, "z": %s}\nwait_log 5000 kit editor: terrain: column at (%s,\n' "$1" "$2" "$1"
}
shot(){ # <name>: played from the start, looked over, Ended again
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
{
	cat <<EOF
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
click Button "New"
wait_log_any 20000 kit editor: package alice/blueland 1.0.0
frames 3
click Button "Install"
wait_log_any 20000 kit editor: installed alice/redland as $fp/redland
wait_log_any 20000 kit editor: installed alice/blueland as $fp/blueland
event kit_edit {"op": "place", "type": "kit/world", "pos": [0, 1, 0]}
wait_log 10000 entities, 1 to undo
EOF
	n=1
	regen_w biome '"grassland"'
	echo 'event workbench_build {"p": [-20, 1, -20], "voxel": "kit/cobble"}'
	echo 'sync 5000'
	column 20 20
	shot kit
	regen_w materials "\"$fp/redland\""
	echo "wait_log_any 10000 kit: warning: World: 1 edited sections kept"
	column 20 20
	column -20 -20
	shot red
	set_w biome '"meadow"'
	echo "wait_log_any 10000 kit: warning: World: not applied: the flat generator needs the role stone"
	set_w biome '"grassland"'
	regen_w materials "\"$fp/blueland\""
	column 20 20
	column -20 -20
	shot blue
	echo quit
} > "$t/boss.cmds"
sed -i "s|@T@|$t|g" "$t/boss.cmds"
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss \
	BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	run_client 60 "$t/boss.log" timeout 300 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -c @"$t/boss.cmds" ||
	fail "the client failed ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -a " kit *: World\|column (" "$s" | sed 's/^.*kit *: /  /' | cut -c1-250
want(){ # <log> <text>...
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
want "$s" "installed alice/redland 1.0.0: 0 types, 0 prefabs, 1 voxel types, a material set" \
	"installed alice/blueland 1.0.0: 0 types, 0 prefabs, 1 voxel types, a material set" \
	"; materials kit/default" "; materials alice/redland" "; materials alice/blueland" \
	"column (20,20): air 1..2, kit/grass 0, kit/dirt -3..-1" \
	"column (20,20): air 1..2, $fp/red_grass 0, kit/gravel -3..-1" \
	"column (20,20): air 1..2, $fp/blue_grass 0, kit/gravel -3..-1" \
	"World: not applied: the flat generator needs the role stone, which biome meadow has none of (material set alice/redland"
# The cobble's section (y 0...63, the grass at 0 in it) kept, the one
# under it (y -64...-1) generated again: the set's filler there
[ "$(grep -ac "column (-20,-20): kit/cobble 1, kit/grass 0, kit/gravel -3..-1" "$s")" = 2 ] ||
	fail "the placed cobble's section not kept, or the one under it not generated again ($s)"
[ "$(grep -an "installed alice/redland" "$s" | head -1 | cut -d: -f1)" -lt \
	"$(grep -an "installed alice/blueland" "$s" | head -1 | cut -d: -f1)" ] ||
	fail "the base set not first ($s)"
want "$t/boss.log" "kit: warning: World: 1 edited sections kept" \
	"kit: warning: World: not applied: the flat generator needs the role stone"
echo "ok: installed, a World switched between sets"

# 3. A set refused at its install keeps no texture; an upgrade breaking
# the World refused
mkdir -p "$t/badland/textures" "$t/redland2/textures"
png "$t/badland/textures/bad.png" 200 200 0
cat > "$t/badland/materials.json" <<'EOF2'
{"format": "kit_materials",
 "voxels": {"alice/bad": {"texture": "textures/bad.png"}},
 "biomes": {"bad": {"top": "alice/bad", "decorations": [
	{"structure": "nothing", "on": "top", "density": 0.1}]}}}
EOF2
manifest "$t/badland" badland
publish "$t/badland"
cp "$t/redland/textures/red_grass.png" "$t/redland2/textures/"
sed 's/"stone": "kit\/stone", //' "$t/redland/materials.json" > "$t/redland2/materials.json"
grep -q stone "$t/redland2/materials.json" && fail "redland 2.0.0 still has stone"
manifest "$t/redland2" redland
sed -i 's/"1.0.0"/"2.0.0"/' "$t/redland2/meta.json"
publish "$t/redland2"
cat > "$t/boss2.cmds" <<EOF2
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state:
click Button "New"
wait_log_any 20000 kit editor: package alice/badland 1.0.0
wait_log_any 20000 kit editor: package alice/redland 2.0.0
frames 3
click Button "Install"
wait_log 20000 kit editor: Package refused: materials.json: biome bad
frames 3
click Button "Upgrade"
wait_log 20000 kit editor: Package refused: it would break the World of scene world
quit
EOF2
start_server "$t/srv2.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up again ($t/srv2.log)"
CHECK_PIDS+=($SERVER_PID)
BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss \
	run_client 60 "$t/boss2.log" timeout 200 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -c @"$t/boss2.cmds" ||
	fail "the second client failed ($t/boss2.log, $t/srv2.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
want "$t/srv2.log" "uploaded textures: 2" \
	"refused: materials.json: biome bad: decoration 0" \
	"refused: it would break the World of scene world: the flat generator needs the role stone"
echo "ok: a refused set package stored no texture; an upgrade breaking the World refused"

# 4. A copy of the save without blueland's package: hosted on the app's set
cp -a "$t/user" "$t/user_copy"
db=
for f in $(find "$t/user_copy" -name save.sqlite); do
	[ "$(sqlite3 "$f" "SELECT count(*) FROM store WHERE store = 'kit' AND key = 'package:$fp/blueland'")" = 1 ] && db=$f
done
[ -n "$db" ] || fail "no save with blueland's package row in $t/user_copy"
sqlite3 "$db" "DELETE FROM store WHERE store = 'kit' AND key = 'package:$fp/blueland'"
start_server "$t/srv3.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user_copy" -l 3 ||
	fail "the copy's server did not come up ($t/srv3.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv3.log" "; materials " 60 ||
	fail "no World applied on the copy ($t/srv3.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
want "$t/srv3.log" "Kit packages: 1" "uploaded textures: 2" \
	"World: material set alice/blueland" \
	"the app's set used until it is installed" "; materials kit/default"
grep -aq "Kit is not hosted" "$t/srv3.log" && fail "Kit not hosted ($t/srv3.log)"
echo "PASS: a set package installed from a local Aitta, a World switched to it generated again with its voxels (a placed voxel's section kept), an extending set winning per role, a missing role refused by name; a refused set storing no texture, an upgrade breaking a World refused, a missing set hosted on the app's"
