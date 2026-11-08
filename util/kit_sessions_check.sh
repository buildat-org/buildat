#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-03)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/box/box.c builtin/kit/types/arena.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/module.lua builtin/voxelworld/** apps/workbench/**
# [KIT_SESSIONS_1] (kit_plan stage 7, slice 1) Sessions beside the
# default round. A fresh save on Workbench, the admin:
#   1. Ended: a World, a stone at (3,1,3), a kit/voxel_replace on that
#      cell, a kit/arena (1 player) and a teleporter into it. Played: the
#      teleporter takes the admin into the arena, which starts session 1
#      and takes them there; the voxel_replace turned on there: the cell
#      air in the session (the server's and the client's), stone in the
#      default and in the sessions made after; the arena's "end" from
#      inside ends it, the admin back in the default round. The stats:
#      the session's clock and runtime its own, its sections the start's
#      (sourced) but the one it changed.
#   2. A draft (2): a plank and a sign there; left unpublished, neither in
#      the default. Another draft (3), from the start (no plank): a plank
#      and a sign, Published: both in the default; refusals in a draft.
#      ([KIT_DRAFT_LEAVE_PLAY]) Publish, Leave draft and the game's end
#      keep the builder in edit mode.
#   3. The arena with a duration: session 4 ends by itself. Session 5 left
#      running, a cell changed there; a restart drops it and its voxels'
#      rows, its arena told (back to its lobby); the default round as before. The World a heightmap: a draft
#      (6) of it.
#   util/kit_sessions_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_sessions; t=$CHECK_TMP
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
	run_client 60 "$t/$1.log" timeout 300 bin/buildat -C "$t/client_cache" \
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
ed() { printf 'event kit_edit %s\n' "$1"; }
edit() # <json> <undo count after>
{
	ed "$1"
	printf 'wait_log 10000 entities, %d to undo\n' "$2"
}
vox() # <x> <y> <z> <voxel> <undo count after>
{
	edit "{\"op\": \"set_voxel\", \"pos\": [$1, $2, $3], \"voxel\": \"$4\"}" "$5"
}
info() # <x> <y> <z>
{
	ed "{\"op\": \"voxel_info\", \"pos\": [$1, $2, $3]}"
	echo "sync 5000"
}
probe() # <x> <y> <z>
{
	printf 'event kit_probe %s %s %s\nsync 3000\n' "$1" "$2" "$3"
}
stats()
{
	ed '{"op": "sessions"}'
	echo "sync 3000"
}
refused() # <json> <reason>
{
	ed "$1"
	printf 'wait_log 10000 kit editor: refused: %s\n' "$2"
}
in_session() # <id> <kind>
{
	printf 'wait_log 30000 kit editor: in session %s %s\n' "$1" "$2"
}
tools_on()
{
	printf 'keypress F6\nwait_log 10000 kit editor: edit mode on\n'
	settle
}
# [KIT_DRAFT_LEAVE_PLAY] Back in the default from a session the tools were
# on in: on again by themselves, and staying on
tools_back() # <label>
{
	printf 'sync 5000\nevent kit_mode %s\n' "$1"
	printf 'wait_log_any 5000 kit editor: the mode: edit (%s)\n' "$1"
	printf 'wait_log_absent 2000 kit editor: edit mode off\n'
	settle
}
settle() # a session's sections (the start's: none generated) in
{
	echo "delay 5000"
}
try() # <id> <input>
{
	ed "{\"op\": \"try\", \"id\": $1, \"comp\": 0, \"input\": \"$2\"}"
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
EOF
	# 3: the World; the stone; 4: a voxel_replace on it; 5: the arena; 6:
	# a teleporter into it
	edit '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}' 1
	edit '{"op": "set", "id": 3, "comp": 0, "param": "biome", "value": "grassland"}' 2
	echo "wait_log_any 30000 kit: World: generated again"
	# 320 x 320: more sections than a session's player has round them
	edit '{"op": "set", "id": 3, "comp": 0, "param": "width", "value": 320}' 3
	edit '{"op": "set", "id": 3, "comp": 0, "param": "depth", "value": 320}' 4
	echo "wait_log 60000 kit: World: generated again"
	vox 3 1 3 kit/stone 5
	edit '{"op": "place", "type": "kit/voxel_replace", "pos": [3, 1, 3]}' 6
	edit '{"op": "set", "id": 4, "comp": 0, "param": "size", "value": [1, 1, 1]}' 7
	edit '{"op": "place", "type": "kit/arena", "pos": [10, 1, 10]}' 8
	edit '{"op": "set", "id": 5, "comp": 0, "param": "players", "value": 1}' 9
	# At once, no time limit, no results shown ([KIT_MINIGAMES_1]'s
	# defaults are a lobby's)
	edit '{"op": "set", "id": 5, "comp": 0, "param": "countdown", "value": 0}' 10
	edit '{"op": "set", "id": 5, "comp": 0, "param": "duration", "value": 0}' 11
	edit '{"op": "set", "id": 5, "comp": 0, "param": "results", "value": 0}' 12
	edit '{"op": "place", "type": "kit/teleporter", "pos": [2, 1, -3]}' 13
	edit '{"op": "set", "id": 6, "comp": 0, "param": "to", "value": [11, 1, 11]}' 14
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
EOF
	info 3 1 3
	probe 3 1 3
	# 1. Into the arena: session 1
	try 6 teleport
	in_session 1 game
	tools_on
	# [KIT_PLAYTEST_WARNINGS] a shape in a session: its scene's registry has
	# them
	echo 'event workbench_build {"p": [5, 1, 5], "voxel": "kit/stone:slab", "param": 0, "tint": 0}'
	echo "sync 5000"
	info 3 1 3
	try 4 on
	echo "sync 5000"
	info 3 1 3
	probe 3 1 3
	stats
	refused '{"op": "place", "type": "kit/sign", "pos": [1, 1, 1]}' \
		"place: in a game session: the tools edit nothing here"
	refused '{"op": "draft"}' "draft: in a game session: the tools edit nothing here"
	try 5 end
	in_session 0 default
	tools_back "the game ended"
	info 3 1 3
	probe 3 1 3
	# 2. A draft (2), left: its plank and sign (7) not in the default
	ed '{"op": "draft"}'
	in_session 2 draft
	echo "wait_log_any 10000 kit editor: edit mode on"
	settle
	info 3 1 3
	vox 7 1 7 kit/planks 1
	edit '{"op": "place", "type": "kit/sign", "pos": [8, 1, 8]}' 2
	stats
	refused '{"op": "stop"}' "stop: in a draft: the default round's"
	refused '{"op": "set", "id": 3, "comp": 0, "param": "level", "value": 3}' \
		"set: in a draft: the World and the environment are the default round's"
	ed '{"op": "leave_draft"}'
	in_session 0 default
	tools_back "draft 2 left"
	info 7 1 7
	# Another (3), Published: its plank and sign (8) in the default
	ed '{"op": "draft"}'
	in_session 3 draft
	echo "wait_log_any 10000 kit editor: edit mode on"
	settle
	info 7 1 7
	vox 7 1 7 kit/planks 1
	edit '{"op": "place", "type": "kit/sign", "pos": [8, 1, 8]}' 2
	ed '{"op": "publish"}'
	echo "sync 5000"
	# Publish keeps the tools on too
	printf 'event kit_mode published\n'
	printf 'wait_log_any 5000 kit editor: the mode: edit (published)\n'
	ed '{"op": "leave_draft"}'
	in_session 0 default
	tools_back "draft 3 left"
	echo "sync 3000"
	info 7 1 7
	# 3. The arena with a duration: session 4 ends by itself
	ed '{"op": "set", "id": 5, "comp": 0, "param": "duration", "value": 3}'
	echo "sync 3000"
	try 6 teleport
	in_session 4 game
	in_session 0 default
	tools_on
	ed '{"op": "set", "id": 5, "comp": 0, "param": "duration", "value": 0}'
	echo "sync 3000"
	try 6 teleport
	in_session 5 game
	tools_on
	try 4 on
	echo "sync 5000"
	info 3 1 3
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
c=$t/boss1.log
grep -a "Voxel at\|Session\|session\|publishes\|arena" "$s" |
	sed 's/^.*\(kit\|main\) *: /  /' | cut -c1-200
infos=$(grep -aoP 'Voxel at \K.*' "$s")
line() { echo "$infos" | sed -n "$1p"; }
expect() # <n> <cell> <voxel>
{
	[ "$(line "$1")" = "($2): $3, param 0, tint 0, sky light 0" ] ||
		fail "voxel_info $1: \"$(line "$1")\", not $2 $3 ($s)"
}
probes=$(grep -aoP 'kit probe: \K.*' "$c")
probe_line() { echo "$probes" | sed -n "$1p"; }
expect 1 3,1,3 kit/stone
expect 2 3,1,3 kit/stone
expect 3 3,1,3 air
expect 4 3,1,3 kit/stone
want "$s" "kit/arena 5: session 1 started" "Session 1 (a game) by player:"
case "$(probe_line 1)" in "voxel kit/stone,"*) ;; *)
	fail "the client's (3,1,3) in the default: $(probe_line 1)";; esac
case "$(probe_line 2)" in "voxel air,"*) ;; *)
	fail "the client's (3,1,3) in session 1: $(probe_line 2)";; esac
case "$(probe_line 3)" in "voxel kit/stone,"*) ;; *)
	fail "the client's (3,1,3) back in the default: $(probe_line 3)";; esac
# The player's entity: the default's in the default, the session's in it
p1=$(probe_line 1 | grep -oP 'entities \K.*'); p2=$(probe_line 2 | grep -oP 'entities \K.*')
me=$(echo "$p1" | tr , '\n' | awk '$1 >= 1000000' | tail -1)
[ -n "$me" ] || fail "no player entity in the default: $p1"
echo ",$p2," | grep -q ",$me," && fail "the default's player entity $me in session 1: $p2"
echo ",$p2," | grep -q ",4,5,6," || fail "not the session's entities in it: $p2"
echo "ok: the arena makes session 1; a dig there is the session's: not in the default (the server's and the client's)"
want "$s" "kit/arena 5: session 1 ended from inside" "Session 1 ended"
want "$c" "kit editor: in session 0 default"
echo "ok: the arena's end from inside ends the session, its player back in the default"
stats1=$(grep -aoP 'Sessions: \K.*' "$s" | sed -n 1p)
stats2=$(grep -aoP 'Sessions: \K.*' "$s" | sed -n 2p)
python3 - "$stats1" "$stats2" <<'PY' || fail "the sessions' stats ($s)"
import json, sys
a = {s["id"]: s for s in json.loads(sys.argv[1])}
d, g = a[0], a[1]
assert g["kind"] == "game" and g["players"] == ["kitboss"], g
assert d["players"] == [], d
assert g["clock"] < d["clock"], (g["clock"], d["clock"])
assert g["runtime"] != d["runtime"], (g, d)
assert g["sourced"] > 0, g
assert 1 <= g["altered"] <= 2, g
# Its sections: round its player and those it wrote; the rest the start's
# alone (shared, no copy of its own)
assert g["shared"] > 0 and g["loaded"] < d["loaded"], (g, d)
assert 1 <= g["written"] <= 2, g
b = {s["id"]: s for s in json.loads(sys.argv[2])}
assert b[2]["kind"] == "draft" and b[2]["entities"] == b[0]["entities"] + 1, b
print("  session 1: clock %s s (the default's %s), %s sections copied from the start, %s its own, %s shared (the default holds %s)" % (
	g["clock"], d["clock"], g["sourced"], g["written"], g["shared"], d["loaded"]))
PY
echo "ok: a session's clock and runtime its own; its sections the start's but those it changed"
expect 5 3,1,3 kit/stone
case "$(line 6)" in "(7,1,7): kit/planks"*|"") fail "the unpublished draft's plank in the default: $(line 6)";; esac
[ "$(line 7)" = "$(line 6)" ] || fail "a draft not from the start: $(line 7), not $(line 6)"
expect 8 7,1,7 kit/planks
want "$s" "kitboss publishes draft 3: 1 entities, 1 cells" "Session 2 ended by kitboss"
want "$c" "kit editor: refused: stop: in a draft: the default round's"
echo "ok: a draft from the start; its edits in the default only by Publish"
echo "ok: Publish, Leave draft and a game's end from inside keep the tools on"
want "$s" "kit/arena 5: session 4 over: its time is up" "Session 4 ended"
echo "ok: the arena's duration ends its session"
db=$(find "$t/user" -name save.sqlite -path "*/saves/world/*" | head -1)
[ -n "$db" ] || fail "no save.sqlite under $t/user"
python3 - "$db" <<'PY' || fail "the save after the sessions ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
row = lambda k: json.loads(db.execute("select value from store where store='kit' and key=?", (k,)).fetchone()[0])
ents = {e["id"]: e for e in row("authored")["entities"]}
assert 7 not in ents, "the unpublished draft's sign"
assert ents[8]["components"][0]["type"] == "kit/sign", ents[8]
assert row("sessions")["live"] == ["world~5"], row("sessions")
n = db.execute("select count(*) from store where store='voxelworld' and key like 'scene_world~5/%'").fetchone()[0]
assert n > 0, "session 5's voxels not saved"
print("  session 5 live at the stop, %d of its voxels' rows" % n)
PY

# A restart: session 5 dropped, its rows with it; the default as it was
{
	joined
	cat <<'EOF'
wait_log_any 10000 kit editor: in session 0 default
keypress F6
wait_log 10000 kit editor: edit mode on
EOF
	info 3 1 3
	info 7 1 7
	stats
	# A heightmap World: a draft (6) has its own
	edit '{"op": "set", "id": 3, "comp": 0, "param": "size", "value": "finite"}' 1
	edit '{"op": "set", "id": 3, "comp": 0, "param": "surface", "value": "heightmap"}' 2
	echo "wait_log_any 30000 heightmap: terrain built"
	ed '{"op": "draft"}'
	in_session 6 draft
	echo "wait_log_any 10000 kit editor: edit mode on"
	settle
	vox 2 3 2 kit/planks 1
	info 2 3 2
	stats
	ed '{"op": "leave_draft"}'
	in_session 0 default
	echo quit
} > "$t/boss2.cmds"
server 2
BUILDAT_JOIN_CREATE= client boss2
stop
s=$t/srv2.log
want "$s" "Sessions: 1 scenes of sessions before the restart dropped" \
	"workbench: scene world~5 dropped" "Session 5 ended by the restart" \
	"session 5 ended stopped|the server restarted"
infos=$(grep -aoP 'Voxel at \K.*' "$s")
expect 1 3,1,3 kit/stone
expect 2 7,1,7 kit/planks
expect 3 2,3,2 kit/planks
want "$s" "Session 6 (a draft) by kitboss" "Session 6 ended by kitboss"
sed -n '/sent {"op": "draft"}/,$p' "$t/boss2.log" | grep -aq 'heightmap: terrain built' ||
	fail "the draft's heightmap not built by the client ($t/boss2.log)"
echo "ok: a draft of a heightmap World"
python3 - "$db" "$(grep -aoP 'Sessions: \K\[.*' "$s" | head -1)" <<'PY' || fail "the save after the restart ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
n = db.execute("select count(*) from store where store='voxelworld' and key like 'scene_world~5/%'").fetchone()[0]
assert n == 0, "%d rows of session 5's voxels" % n
assert [s["id"] for s in json.loads(sys.argv[2])] == [0], sys.argv[2]
PY
echo "ok: a restart drops the sessions and their voxels, their arena told; the default round as before"
# [KIT_PLAYTEST_WARNINGS] A session's scene registered quietly (a "not
# found" for each voxel and shape it then added, 406 a round); a scene
# switch meshed no other scene's node by a reused id (the client's "not
# meshed: Failed to read 1 bytes", 360 at the draft here)
want "$t/srv1.log" "workbench: kitboss placed kit/stone:slab (5,1,5): written"
grep -a "CVoxelRegistry::get(): name=" "$t"/srv*.log | head -3 | grep . &&
	fail "the server asked for voxels not registered ($t/srv*.log)"
grep -a "A voxel volume not meshed" "$t"/boss*.log | head -3 | grep . &&
	fail "the client meshed what is not a chunk ($t/boss*.log)"
echo "ok: a slab placed in a session; no voxel looked for in vain, no volume that does not read"
echo "PASS: sessions: an arena's game session diverging from the start and the default, its clock, runtime and player its own, its sections shared until written, ended from inside or by time; drafts from the start, reaching the start only by Publish; a restart drops them"
# vim: set noet ts=4 sw=4:
