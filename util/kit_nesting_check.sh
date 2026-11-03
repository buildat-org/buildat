#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-03)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/types/mover.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/module.lua apps/workbench/**
# [KIT_NESTING] (kit_plan 4p) Child entities, on a fresh Workbench save:
#   1. A kit/mover M (4, offset 4 cells along its x) at (10, 1, 10)
#      turned 90; under it a sign S (5) placed at (11, 1, 10) and a button
#      B (7) at (11, 1, 12), each "parent": 4 with its place given in the
#      world. M moved to (12, 1, 10) and turned 180, a trigger zone Z (8,
#      3x2x3) placed under it at (15, 1, 8): S is at (12, 1, 9) -- a teleporter (6)
#      onto S says so -- B is used from there (its use range the
#      world's); M goes out: Z comes to the player (entered), S is at (8,
#      1, 9) (the teleport again), B used there; M back.
#   2. Ended: S under the scene and back under M by the inspector's
#      Un-parent and Switch parent (cancelled by Escape and by the button
#      first; the parent picked in the list) -- its place in the world
#      kept: its row (12, 1, 9) under the scene, (0, 0, 1) under M;
#      refused: M under S (a loop), S under the World (no position), under
#      an entity that is not there. A duplicate of M (9...) carries its
#      three; one of S alone (13) stays under M; a delete of the copy
#      takes its four, its undo brings them back under it; M saved as a
#      prefab (its five, their parents and S's own place) and placed
#      (14...18, S's copy under the copy); a copy and paste of M (19...);
#      a sign placed under the prefab's copy (24).
#   3. A restart, an old row (60, under the scene, as saves before
#      nesting have them) added to the save: it loads where it was, the
#      editor's rows the world's (S at 12,1,9 turned 90 under 4), its
#      Positioned list each one under its parent (">" a level).
#      [KIT_GROUP_TURN_JUMP] M and the teleporter selected, turned 90 by a
#      drag of the knob in the 2D plan: the preview at the release (M,
#      what is under it, the teleporter) is where the server puts them.
#      [KIT_REPARENT_BUTTONS] 60 under M's copy (9) by Switch parent and a
#      click on 9 in the plan.
#   4. A loop put in the save (M under S): Kit refuses the composition,
#      naming it.
#   util/kit_nesting_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_nesting; t=$CHECK_TMP
cd "$here/Build"

server() # <n>
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -C "$t/cache" \
		-l 3 --sim-rate "$CHECK_RATE" ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <name> <log level>: its commands in $t/<name>.cmds
{
	run_client 60 "$t/$1.log" timeout 300 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l "$2" \
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
edit() # <json>
{
	n=$((n + 1))
	ed "$1"
	printf 'wait_log 10000 entities, %d to undo\n' "$n"
}
refused() # <json> <reason>
{
	ed "$1"
	printf 'wait_log 10000 kit editor: refused: %s\n' "$2"
}
try() # <id> <input>
{
	printf 'event kit_edit {"op": "try", "id": %d, "input": "%s"}\nsync 5000\n' \
		"$1" "$2"
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
	# 3: the World (the floor)
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	echo "sync 5000"
	# 4: M, turned 90; under it 5 S, 7 B, 8 Z; 6 the teleporter onto S
	edit '{"op": "place", "type": "kit/mover", "pos": [10, 1, 10]}'
	edit '{"op": "set", "id": 4, "comp": 0, "param": "offset", "value": [4, 0, 0]}'
	edit '{"op": "set", "id": 4, "comp": 0, "param": "time", "value": 0.5}'
	edit '{"op": "set", "id": 4, "comp": 0, "param": "solid", "value": false}'
	edit '{"op": "move", "id": 4, "pos": [10, 1, 10], "yaw": 90}'
	edit '{"op": "place", "type": "kit/sign", "pos": [11, 1, 10], "parent": 4}'
	edit '{"op": "place", "type": "kit/teleporter", "pos": [20, 1, 20]}'
	edit '{"op": "set", "id": 6, "comp": 0, "param": "target", "value": 5}'
	edit '{"op": "place", "type": "kit/button", "pos": [11, 1, 12], "parent": 4}'
	# M moved and turned: what is under it goes with it
	edit '{"op": "move", "id": 4, "pos": [12, 1, 10], "yaw": 180}'
	edit '{"op": "place", "type": "kit/trigger_zone", "pos": [15, 1, 8], "parent": 4}'
	edit '{"op": "set", "id": 8, "comp": 0, "param": "size", "value": [3, 2, 3]}'
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
EOF
	try 6 teleport
	echo "event kit_use 7"
	echo "sync 5000"
	try 4 go
	echo "frames 30"
	echo "sync 5000"
	try 6 teleport
	echo "event kit_use 7"
	echo "sync 5000"
	try 4 back
	cat <<'EOF'
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	# 2. Re-parenting by the inspector's buttons ([KIT_REPARENT_BUTTONS]):
	# S under the scene (Un-parent); Switch parent cancelled by Escape and
	# by the button; then S under M, picked in the list; refusals, the
	# subtree carried
	cat <<'EOF'
event kit_select 5
frames 3
click Button "Un-parent"
EOF
	n=$((n + 1))
	printf 'wait_log 10000 entities, %d to undo\nframes 3\n' "$n"
	cat <<'EOF'
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of 5: armed
keypress Escape
wait_log 5000 kit editor: switch parent cancelled
frames 3
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of 5: armed
frames 3
click Button "Switch parent: Cancel"
wait_log 5000 kit editor: switch parent cancelled
frames 3
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of 5: armed
frames 3
click Button "Positioned (*"
frames 3
click Button "select 4"
EOF
	n=$((n + 1))
	printf 'wait_log 10000 entities, %d to undo\n' "$n"
	refused '{"op": "parent", "id": 4, "parent": 5}' "parent: parent: entity 5 is under it"
	refused '{"op": "parent", "id": 5, "parent": 3}' "parent: parent: entity 3 has no position"
	refused '{"op": "parent", "id": 5, "parent": 999}' "parent: parent: no entity 999"
	refused '{"op": "place", "type": "kit/sign", "pos": [1, 1, 1], "parent": 3}' "place: parent: entity 3 has no position"
	# 9...12: a copy of M with its three; 13: one of S alone, under M
	edit '{"op": "duplicate", "ids": [4], "by": [0, 0, 10]}'
	edit '{"op": "duplicate", "ids": [5], "by": [1, 0, 0]}'
	edit '{"op": "delete", "id": 9}'
	n=$((n - 2))
	edit '{"op": "undo"}'
	# 14...18: M (and 5, 7, 8, 13) as a prefab, placed
	edit '{"op": "save_prefab", "ids": [4], "name": "lift"}'
	edit '{"op": "place", "prefab": "kitboss/lift", "pos": [30, 1, 30]}'
	# 19...23: a copy pasted; 24 a sign under the prefab's copy
	ed '{"op": "copy", "ids": [4]}'
	echo "sync 5000"
	edit '{"op": "place", "clipboard": true, "pos": [40, 1, 40]}'
	edit '{"op": "place", "type": "kit/sign", "pos": [30, 1, 33], "parent": 14}'
	echo quit
} > "$t/boss1.cmds"
server 1
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss1 3
stop
s=$t/srv1.log
grep -a "An edit by\|teleports\|kit/button 7\|kit/trigger_zone 8\|kit/mover 4\|refused" "$s" |
	sed 's/^.*\(kit\|main\) *: /  /' | cut -c1-170
want "$s" "Entity 6's kit/teleporter teleports kitboss to (12, 1, 9)" \
	"Entity 6's kit/teleporter teleports kitboss to (8, 1, 9)" \
	"An edit by kitboss: placed kit/sign 5 at [11,1,10] under 4"
[ "$(grep -ac "kit/button 7: pressed by kitboss" "$s")" = 2 ] ||
	fail "button 7 not used twice from beside it ($s)"
echo "ok: a child moves and turns with its parent (and its slide), its use range the world's"
want "$s" "kit/trigger_zone 8: kitboss entered" "kit/trigger_zone 8: kitboss left"
echo "ok: a zone under a mover triggers where the mover takes it"
want "$t/boss1.log" "kit editor: refused: parent: parent: entity 5 is under it" \
	"kit editor: refused: parent: parent: entity 3 has no position" \
	"kit editor: refused: parent: parent: no entity 999"
want "$t/boss1.log" "kit editor: un-parent 5" "kit editor: switch parent of 5 to 4"
want "$s" "An edit by kitboss: put 5 under the scene world" \
	"An edit by kitboss: put 5 under 4" "An edit by kitboss: deleted 9 and 3 under it"
db=$(find "$t/user" -name save.sqlite -path "*/saves/world/*" | head -1)
[ -n "$db" ] || fail "no save.sqlite under $t/user"
python3 - "$db" <<'PY' || fail "the tree in the save ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
row = lambda k: json.loads(db.execute("select value from store where store='kit' and key=?", (k,)).fetchone()[0])
au = row("authored")
ents = {e["id"]: e for e in au["entities"]}
def near(a, b):
    return all(abs(x - y) < 1e-6 for x, y in zip(a, b))
def at(i, parent, pos, yaw=None):
    e = ents[i]
    assert e["parent"] == parent and near(e["pos"], pos), (i, e)
    if yaw is not None:
        assert abs(e.get("yaw", 0) - yaw) < 1e-6, (i, e)
at(4, 2, [12, 1, 10], 180)
# placed facing the world's 0 under M turned 90: its own turn 270
at(5, 4, [0, 0, 1], 270)
at(7, 4, [-2, 0, 1])
at(8, 4, [-3, 0, 2])
# the duplicate's, back by the undo, under its own copy of M
at(9, 2, [12, 1, 20], 180)
for i in (10, 11, 12):
    assert ents[i]["parent"] == 9, ents[i]
at(10, 9, [0, 0, 1])
# S's copy alone: beside S, under M
at(13, 4, [-1, 0, 1])
# the prefab's copy and its members
at(14, 2, [30, 1, 30], 180)
at(15, 14, [0, 0, 1])
assert ents[15]["prefab"]["of"] == "kitboss/lift", ents[15]
pf = row("prefab:kitboss/lift")
m = {e["id"]: e for e in pf["entities"]}
assert len(m) == 5 and m[2]["parent"] == 1 and near(m[2]["pos"], [0, 0, 1]), pf
# the paste, and the sign under the prefab's copy
at(19, 2, [40, 1, 40], 180)
at(20, 19, [0, 0, 1])
at(24, 14, [0, 0, -3])
# 3: an old row, as before nesting
au["entities"].append({"id": 60, "parent": 2, "name": "old sign",
    "pos": [5, 1, 5], "components": [{"type": "kit/sign"}]})
au["next_id"] = 61
db.execute("update store set value=? where store='kit' and key='authored'", (json.dumps(au),))
db.commit()
print("  the save's tree as placed; an old row 60 added")
PY
echo "ok: re-parent keeps the world position; duplicate, delete, undo, prefab and paste carry the subtree; a loop, no position and none there refused"

# 3. A restart: the save loads as it was, the editor's rows the world's
n=0
{
	joined
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: state:
sync 5000
frames 10
click Button "Positioned (*"
wait_log 5000 kit editor: list Positioned
event kit_select 6 4
event kit_plan 12 10 20 3
wait_log_any 5000 kit editor: the view is 2D
frames 5
event kit_knob_where
mouse_pos 512 391
frames 2
mouse_down left
frames 2
mouse_pos 480 380
frames 2
mouse_pos 412 350
frames 3
mouse_up left
wait_log 5000 kit editor: turned 2 by 90
sync 5000
frames 10
sync 5000
event kit_select 60
frames 3
click Button "Switch parent"
wait_log 5000 kit editor: switch parent of 60: armed
event kit_plan 12 20 20 3
frames 5
mouse_pos 512 350
frames 2
mouse_click left
frames 3
sync 5000
quit
EOF
} > "$t/boss2.cmds"
server 2
BUILDAT_JOIN_CREATE= client boss2 4
stop
b=$t/boss2.log
grep -a "kit editor: entity \(4\|5\|60\) " "$b" | tail -3 | sed 's/^.*kit editor/  kit editor/'
grep -aqE "kit editor: entity 60 old sign at 5,1,5 links" "$b" ||
	fail "the old row 60 not where it was ($b)"
grep -aqE "kit editor: entity 5 [^ ]+ [0-9]+ at 12,1,9 yaw 90 under 4 links" "$b" ||
	fail "no entity 5 at 12,1,9 under 4 in the editor's rows ($b)"
w="kit editor: list Positioned (22): 4, >5, >7, >8, >13, 6, 9, >10, >11, >12, 14, >15, >16, >17, >18, >24, 19, >20, >21, >22, >23, 60"
grep -aqF "$w" "$b" || fail "no \"$w\" in $b"
echo "ok: an old save loads as it was; the editor's rows are in the world, its list in the tree's order"
# [KIT_GROUP_TURN_JUMP] 4 (with 5, 7, 8, 13 under it) and 6 turned 90 by
# the knob: what the preview showed at the release is where the server put
# them (turned about their middle), in the state after it
grep -aqF "kit editor: the knob on the screen at 512, 391" "$b" ||
	fail "the knob not at 512, 391, where the drive presses ($b)"
python3 - "$b" <<'PY' || fail "the turn's preview is not where the server put them ($b)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
pv = {int(m[0]): (tuple(map(float, m[1].split(","))), float(m[2])) for m in
    re.findall(r"kit editor: turn preview (\d+) at ([-\d.,]+) yaw ([-\d.]+)", log)}
after = log[log.rindex("kit editor: turned 2 by 90"):]
rows = {}
for m in re.findall(r"kit editor: entity (\d+) .*? at ([-\d.,]+)( yaw [-\d.]+)? .*?links", after):
    rows[int(m[0])] = (tuple(map(float, m[1].split(","))), float(m[2][5:] or 0))
assert set(pv) == {4, 5, 6, 7, 8, 13}, pv
for i, (p, yaw) in sorted(pv.items()):
    q, ry = rows[i]
    assert all(abs(a - b) < 1e-3 for a, b in zip(p, q)), (i, p, q)
    assert abs((yaw - ry + 180) % 360 - 180) < 1e-3, (i, yaw, ry)
    print("  %d previewed at %s yaw %g, put there" % (i, ",".join("%g" % v for v in p), yaw % 360))
PY
echo "ok: a group turned by the knob is previewed where the server puts it, about the group's middle, with what is under it"
want "$t/boss2.log" "kit editor: switch parent of 60 to 9"
want "$t/srv2.log" "An edit by kitboss: put 60 under 9"
echo "ok: Switch parent: the parent clicked in the 2D plan"

# 4. A loop in the save: the composition refused
python3 - "$db" <<'PY' || fail "the loop put in the save ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
au = json.loads(db.execute("select value from store where store='kit' and key='authored'").fetchone()[0])
for e in au["entities"]:
    if e["id"] == 4:
        e["parent"] = 5
db.execute("update store set value=? where store='kit' and key='authored'", (json.dumps(au),))
db.commit()
PY
start_server "$t/srv3.log" "entity 4's parent 5 is under it" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -C "$t/cache" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "a loop in the save not refused ($t/srv3.log)"
CHECK_PIDS+=($SERVER_PID)
stop
grep -a "under it" "$t/srv3.log" | head -2 | sed 's/^.*\(kit\|main\) *: /  /'
echo "ok: a loop in the save is refused"
echo "PASS: nesting: children move and turn with their parent and its slide, a zone and a use range in the world, re-parenting keeps the world place, the subtree carried by duplicate, delete, undo, prefabs and paste; loops and parents with no position refused; old saves load unchanged"
# vim: set noet ts=4 sw=4:
