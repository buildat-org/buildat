#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~40 s, ~1 min with a cold module cache (2026-10-30)
# covers: builtin/kit/** apps/sample_kit/** builtin/accounts/**
# [KIT] stage 3, Kit's editor, on apps/sample_kit and scripted clients
# logged in through builtin/accounts:
#   1. The admin (kitboss, by the setup code) switches edit mode on,
#      places a button and a door, a marker (moved, deleted, the delete
#      undone), sets the door's "closed" to glass in the inspector and
#      links the button's "pressed" to the door's "toggle"; leaves edit
#      mode and uses the new button twice: the door opens and closes to
#      glass. Back in edit mode an undo removes the link, and the button
#      then moves no door.
#   2. A second player (kitbob) is refused edit mode, a packet of each
#      kind of edit, one that is no JSON, and the accounts' builder grant
#      of their own. The admin makes them a builder in the editor; they
#      are told, place a marker, and are refused a grant (only the admin
#      grants). (kitbob's refusals done, they open and close the door with
#      its button: the admin's drive waits for that before the grant.)
#   3. A restart: the authored row has what was edited, and kitbob, alone,
#      is still a builder.
# KEEP_TMP=1 keeps the screenshots: edit mode with the inspector, a link
# line, the marker's gizmo, play with none of them, the admin's builders.
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_editor; t=$CHECK_TMP
# The server's own user path: its accounts (_server) and the app's save
save="$t/user/apps/sample_kit/saves/world"
cd "$here/Build"

server() # <n>
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/sample_kit -D "$t/user" -l 3 ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <name>: its commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
{
	sed -i "s|@T@|$t|g" "$t/$1.cmds"
	run_client 60 "$t/$1.log" timeout 180 bin/buildat -C "$t/client_cache" \
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
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

# The admin. At 1024x700 the pixel (400, 500) is the ground cell
# (1, 1, -2) and (600, 500) is (2, 1, -2); a click on an entity's cell
# selects it
cat > "$t/boss.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 10000 admin script: done
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
frames 3
wait_log_any 60000 replicated: entity 4 open = false
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
click Button "Edit"
wait_log 10000 kit editor: state: 13 entities, 5 to undo
wait_log 60000 kit editor: people: kitbob player
wait_log 60000 replicated: entity 4 open = true
wait_log 10000 replicated: entity 4 open = false
click Button "Builder: no"
wait_log 10000 kit editor: people: kitbob builder
wait_log 60000 kit editor: state: 14 entities
frames 3
screenshot @T@/builders.png
quit
EOF
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
click Button "Edit"
wait_log 10000 kit editor: refused: mode: no edit rights here
keypress x
wait_log 10000 kit editor: refused: ?: not a JSON object
keypress b
wait_log 10000 replicated: entity 4 open = true
keypress b
wait_log 10000 replicated: entity 4 open = false
wait_log_any 60000 kit editor: edit rights: yes
keypress g
wait_log 10000 kit editor: refused: builder: only the server's admin makes builders
click Button "Edit"
wait_log 10000 kit editor: state: 13 entities
click Button "Place marker"
wait_log 10000 kit editor: state: 14 entities
click Button "Leave edit mode"
wait_log 10000 kit editor: edit mode off
quit
EOF
server 1
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss &
boss=$!
wait_for_log "$t/boss.log" "replicated: entity 12 presses = 3" 180 ||
	fail "the admin's edits did not get as far as play ($t/boss.log)"
# kitbob's own builder grant by the accounts' admin request: refused
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_ADMIN="priv kitbob builder" client bob
wait $boss || fail "the admin's client ($t/boss.log)"
stop
s=$t/srv1.log
grep -a " kit \| main \| accounts" "$s" | grep -v "A . call" | sed 's/^.*\(kit\|main\|accounts\) *: /  /' |
	grep -a "edit\|undo\|button 12\|door 13\|refused\|builder" | cut -c1-140
want "$s" "kitboss is in edit mode" \
	"An edit by kitboss: placed button 12 at [1,1,-2]" \
	"An edit by kitboss: placed door 13 at [2,1,-2]" \
	"An edit by kitboss: placed marker 14 at" "An edit by kitboss: moved 14 to" \
	"An edit by kitboss: deleted 14" "An undo by kitboss: 1 entities put back" \
	"An edit by kitboss: set 13's door closed to \"glass\"" \
	"An edit by kitboss: linked 12.pressed -> 13.toggle" "kitboss left edit mode" \
	"button 12: pressed by player:kitboss times 1" \
	"door 13: opened by player:kitboss to air" \
	"door 13: closed by player:kitboss to glass" \
	"button 12: pressed by player:kitboss times 3"
[ "$(grep -ac "door 13: opened" "$s")" = 1 ] ||
	fail "the door moved after the undo took the link away ($s)"
echo "ok: the admin edits: edit mode, place, move, delete, the inspector, the link, undo; the edit works in play"
for op in mode place move delete set link unlink undo builder; do
	grep -aqE "An edit \($op\) by peer [0-9]+ refused: no edit rights here" "$s" ||
		fail "kitbob's $op was not refused ($s)"
done
want "$s" "An admin request (priv) by kitbob refused: not staff" \
	"kitboss granted builder kitbob" "kitboss made builder kitbob" \
	"refused: only the server's admin makes builders" \
	"An edit by kitbob: placed marker 15 at [0,1,0]"
grep -aE "An edit \(\?\) by peer [0-9]+ refused: not a JSON object" "$s" >/dev/null ||
	fail "kitbob's packet that is no JSON was not refused ($s)"
echo "ok: a player without edit rights is refused each kind of edit and the grant; the admin makes them a builder, who edits and grants nothing"

db="$save/save.sqlite"
[ -f "$db" ] || fail "no database $db"
sqlite3 "$db" "SELECT value FROM store WHERE store = 'kit' AND key = 'authored'" > "$t/authored.json"
python3 -I - "$t/authored.json" <<'EOF' || fail "the authored row ($t/authored.json)"
import json, sys
a = json.load(open(sys.argv[1]))
e = {x["id"]: x for x in a["entities"]}
assert e[13]["components"][0]["params"]["closed"] == "glass", e[13]
assert e[12]["components"][0]["links"] == [], e[12]
assert e[14]["components"][0]["type"] == "marker", e[14]
assert e[15]["components"][0]["type"] == "marker", e[15]
assert a["next_id"] == 16, a["next_id"]
EOF

cat > "$t/again.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
click Button "Edit"
wait_log 10000 kit editor: state: 14 entities, 0 to undo
quit
EOF
server 2
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE= client again
stop
want "$t/srv2.log" "Hosted: 15 entities" "kitbob is in edit mode"
grep -aq "the composition's first start" "$t/srv2.log" && fail "the composition was read again ($t/srv2.log)"
echo "PASS: Kit's editor: the admin's edit rights and builders kept in the accounts, edit mode, place, move, delete, the inspector, links, undo, each edit and grant refused without rights, the authored row over a restart"
# vim: set noet ts=4 sw=4:
