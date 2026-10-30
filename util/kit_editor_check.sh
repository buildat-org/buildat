#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~20 s, ~1 min with a cold module cache (2026-10-30)
# covers: builtin/kit/** apps/sample_kit/**
# [KIT] stage 3, Kit's editor, on apps/sample_kit and scripted clients:
#   1. The owner (the first to join, whom sample_kit gives edit rights)
#      switches edit mode on, places a button and a door, a marker
#      (moved, deleted, the delete undone), sets the door's "closed" to
#      glass in the inspector and links the button's "pressed" to the
#      door's "toggle"; leaves edit mode and uses the new button twice: the
#      door opens and closes to glass. Back in edit mode an undo removes
#      the link, and the button then moves no door.
#   2. A second player, without edit rights, is refused edit mode and a
#      packet of each kind of edit, and a packet that is no JSON.
#   3. A restart: the authored row has what was edited (the door's glass,
#      no link, the marker) and the owner's editor shows it.
# KEEP_TMP=1 keeps the screenshots: edit mode with the inspector, a link
# line, the marker's gizmo, and play with none of them.
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_editor; t=$CHECK_TMP
save="$BUILDAT_USER_PATH/apps/sample_kit/saves/world"
rm -rf "$save"
cd "$here/Build"

server() # <n>
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/sample_kit -l 3 ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <name>: its commands in $t/<name>.cmds
{
	sed -i "s|@T@|$t|g" "$t/$1.cmds"
	run_client 60 "$t/$1.log" timeout 120 bin/buildat -C "$t/client_cache" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -c @"$t/$1.cmds" ||
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

# The owner. At 1024x700 the pixel (400, 500) is the ground cell
# (1, 1, -2) and (600, 500) is (2, 1, -2); a click on an entity's cell
# selects it
cat > "$t/owner.cmds" <<'EOF'
wait_log 60000 replicated: entity 4 open = false
click Button "Edit"
wait_log 10000 kit editor: state: 10 entities, 0 to undo
mouse_pos 400 500
mouse_click left
wait_log 5000 kit editor: cursor at 1,1,-2
click Button "Place button"
wait_log 10000 kit editor: state: 11 entities, 1 to undo
mouse_pos 600 500
mouse_click left
wait_log 5000 kit editor: cursor at 2,1,-2
click Button "Place door"
wait_log 10000 kit editor: state: 12 entities, 2 to undo
mouse_pos 500 640
mouse_click left
wait_log 5000 kit editor: cursor at
click Button "Place marker"
wait_log 10000 kit editor: state: 13 entities, 3 to undo
mouse_pos 500 640
mouse_click left
wait_log 5000 kit editor: selected 14
keypress Right
wait_log 10000 kit editor: state: 13 entities, 4 to undo
keypress Delete
wait_log 10000 kit editor: state: 12 entities, 5 to undo
click Button "Undo"
wait_log 10000 kit editor: state: 13 entities, 4 to undo
mouse_pos 600 500
mouse_click left
wait_log 5000 kit editor: selected 13
click LineEdit "stone"
keypress End
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
text glass
wait_log 5000 kit editor: 13/1 closed = glass
click Button "Apply"
wait_log 10000 kit editor: state: 13 entities, 5 to undo
frames 3
screenshot @T@/inspector.png
mouse_pos 400 500
mouse_click left
wait_log 5000 kit editor: selected 12
click Button "Link pressed"
wait_log 5000 kit editor: linking from 12 pressed
mouse_pos 600 500
mouse_click left
wait_log 5000 kit editor: selected 13
click Button "To toggle"
wait_log 10000 kit editor: state: 13 entities, 6 to undo
mouse_pos 400 500
mouse_click left
wait_log 5000 kit editor: selected 12
frames 3
screenshot @T@/link.png
click Button "Leave edit mode"
wait_log 10000 kit editor: edit mode off
frames 3
screenshot @T@/play.png
keypress u
wait_log 10000 replicated: entity 13 open = true
keypress u
wait_log 10000 replicated: entity 13 open = false
click Button "Edit"
wait_log 10000 kit editor: state: 13 entities, 6 to undo
click Button "Undo"
wait_log 10000 kit editor: state: 13 entities, 5 to undo
click Button "Leave edit mode"
wait_log 10000 kit editor: edit mode off
keypress u
wait_log 10000 replicated: entity 12 presses = 3
frames 10
quit
EOF
cat > "$t/other.cmds" <<'EOF'
wait_log 60000 replicated: entity 4 open = false
click Button "Edit"
wait_log 10000 kit editor: refused: mode: no edit rights here
keypress x
wait_log 10000 sent the edit packets
wait_log 10000 kit editor: refused: ?: not a JSON object
quit
EOF
server 1
client owner
client other
stop
s=$t/srv1.log
grep -a " kit \| main " "$s" | grep -v "A . call" | sed 's/^.*\(kit\|main\) *: /  /' |
	grep -a "edit\|undo\|button 12\|door 13\|refused" | cut -c1-140
want "$s" "p1 has edit rights" "p1 is in edit mode" \
	"An edit by p1: placed button 12 at [1,1,-2]" \
	"An edit by p1: placed door 13 at [2,1,-2]" \
	"An edit by p1: placed marker 14 at" "An edit by p1: moved 14 to" \
	"An edit by p1: deleted 14" "An undo by p1: 1 entities put back" \
	"An edit by p1: set 13's door closed to \"glass\"" \
	"An edit by p1: linked 12.pressed -> 13.toggle" "p1 left edit mode" \
	"button 12: pressed by player:p1 times 1" \
	"door 13: opened by player:p1 to air" \
	"door 13: closed by player:p1 to glass" \
	"button 12: pressed by player:p1 times 3"
[ "$(grep -ac "door 13: opened" "$s")" = 1 ] ||
	fail "the door moved after the undo took the link away ($s)"
echo "ok: edit mode, place, move, delete, the inspector, the link, undo; the edit works in play"
for op in mode place move delete set link unlink undo; do
	want "$s" "An edit ($op) by peer 2 refused: no edit rights here"
done
want "$s" "An edit (?) by peer 2 refused: not a JSON object"
grep -aq "An edit by p2" "$s" && fail "an edit of p2's was made ($s)"
echo "ok: a player without edit rights is refused each kind of edit"

db=$(ls "$save"/*.sqlite 2>/dev/null | head -1)
[ -n "$db" ] || fail "no database in $save"
sqlite3 "$db" "SELECT value FROM store WHERE store = 'kit' AND key = 'authored'" > "$t/authored.json"
python3 -I - "$t/authored.json" <<'EOF' || fail "the authored row ($t/authored.json)"
import json, sys
a = json.load(open(sys.argv[1]))
e = {x["id"]: x for x in a["entities"]}
assert e[13]["components"][0]["params"]["closed"] == "glass", e[13]
assert e[12]["components"][0]["links"] == [], e[12]
assert e[14]["components"][0]["type"] == "marker", e[14]
assert a["next_id"] == 15, a["next_id"]
EOF

cat > "$t/again.cmds" <<'EOF'
wait_log 60000 replicated: entity 4 open = false
click Button "Edit"
wait_log 10000 kit editor: state: 13 entities, 0 to undo
quit
EOF
server 2
client again
stop
want "$t/srv2.log" "Hosted: 14 entities"
grep -aq "the composition's first start" "$t/srv2.log" && fail "the composition was read again ($t/srv2.log)"
echo "PASS: Kit's editor: edit rights, edit mode, place, move, delete, the inspector, links, undo, each edit refused without rights, the authored row over a restart"
# vim: set noet ts=4 sw=4:
