#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min, more with a cold module cache (2026-11-03)
# covers: builtin/kit/** apps/sample_kit/** builtin/accounts/**
# [KIT] stage 3, Kit's editor, on apps/sample_kit and scripted clients
# logged in through builtin/accounts. sample_kit plays once its floor is
# laid ([KIT] stage 4c), so the edits are live: the start and the round.
#   1. The admin (kitboss, by the setup code) switches edit mode on,
#      places a button and a door, a marker (moved, deleted, the delete
#      undone), sets the door's "closed" to glass in the inspector and
#      tries the door's "toggle" twice in the inspector ([KIT_TRY_INPUTS]:
#      it opens and closes, "→ opened" shown), links the button's
#      "pressed" to the door's "toggle"; leaves edit
#      mode and uses the new button twice: the door opens and closes to
#      glass. Back in edit mode an undo removes the link, and the button
#      then moves no door.
#   2. A second player (kitbob) is refused edit mode, a packet of each
#      kind of edit, one that is no JSON, and the accounts' builder grant
#      of their own. The admin makes them a builder in the editor; they
#      are told, place a marker, and are refused a grant (only the admin
#      grants). (kitbob's refusals done, they open and close the door with
#      its button: the admin's drive waits for that before the grant.)
#   3. ([KIT] stage 4c) Two builders: kitbob, in edit mode, selects an
#      entity, which the admin's editor shows in kitbob's colour (its log
#      line), and opens the door. The admin stops the server: the round's
#      state is thrown away (the new button's presses 0, the door closed,
#      its voxel stone again), the edits stay (the start); a use is
#      refused while Stopped, and kitbob's edit then changes the start.
#      The origins: the admin's dig of the pillar in play (a build) is
#      discarded with the Stop notice to both builders (the door's own
#      voxel write, a game change, not offered), and kept from the notice
#      a moment later. The admin plays: a round from the start, the door
#      opened again, the button pressed once. The tools' bar Ended and
#      Running (its logged places): End where Run is, no other button
#      moved, Save as start the last.
#   4. A restart: the authored row has what was edited, the server is
#      still Running, and kitbob, alone, is still a builder.
#   5. ([KIT_ROUND_START]) kitbob's edits in play kept past what comes
#      after them: a kit/voxel_replace 22 (glass to stone) and a probe 23
#      (a kit/voxel_states) over (6, 1, 1) and the pillar (6, 1, 2), both
#      cells edited to glass; 22's toggle tried (a game write over the
#      first), and out of edit mode the pillar dug (a build over the
#      second). A restart, then End: both cells glass again (the edit, and
#      the edit under the discarded build), as the probe captures them.
#   6. ([KIT_SHUTDOWN_SAVE]) Part 5 again on its start, sample_kit stopping
#      the server right after the dig, before a tick: Kit saves the dig's
#      mark at the stop, and End after the restart discards the build.
#   7. ([KIT_GUEST_NO_LEAVE]) A guest in an arena's and a trigger zone's
#      zone logs in: on_leave runs knowing who left (c:name, c.player).
# KEEP_TMP=1 keeps the screenshots: edit mode with the inspector, a link
# line, the marker's gizmo, play with none of them, the admin's builders
# (kitbob's selection in their colour), and the Stopped server.
#
#   util/kit_editor_check.sh
#   util/kit_editor_check.sh web    the admin's part in headless Chrome
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = web ]; then
	# The admin's flow in the web client (web/), in headless Chrome at
	# 1200x800: log in ("l", the setup code), point at the stone, place a
	# button and a door on the floor (a palette button arms it, a click
	# places, a right click stops), the door's closed to glass, the link,
	# the door used twice, Stop and Play (Kit's top bar)
	check_tmp kit_editor_web; t=$CHECK_TMP
	cat > "$t/steps.json" <<'EOF'
[
	["nav", "${URL}"],
	["waitlog", "replicated: entity 4 open = false", 120],
	["key", "l"],
	["waitlog", "accounts: the login page shown", 60], ["wait", 1000],
	["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
	["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Enter"], ["waitlog", "Joined as webboss", 30],
	["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
	["click", "Button", "Don't add"], ["frames", 3],
	["key", "F6"], ["waitlog", "kit editor: state: 15 entities, 0 to undo", 20],
	["click", 1067, 243], ["waitlog", "kit editor: cursor at 6,2,2", 10],
	["click", "Button", "sample_kit/button"], ["waitlog", "kit editor: placing sample_kit/button", 10],
	["click", 723, 400], ["waitlog", "kit editor: state: 16 entities, 1 to undo", 10],
	["click", "Button", "sample_kit/door"], ["waitlog", "kit editor: placing sample_kit/door", 10],
	["click", 700, 310], ["waitlog", "kit editor: state: 17 entities, 2 to undo", 10],
	["click", 700, 310, 100, 2], ["waitlog", "kit editor: placing nothing", 10],
	["click", 706, 223], ["waitlog", "kit editor: selected 18", 10],
	["click", "LineEdit", "stone"], ["frames", 2], ["key", "End"],
	["key", "Backspace"], ["key", "Backspace"], ["key", "Backspace"],
	["key", "Backspace"], ["key", "Backspace"],
	["type", "glass"], ["waitlog", "kit editor: 18/1 closed = glass", 10],
	["click", "Button", "Apply"], ["waitlog", "kit editor: state: 17 entities, 3 to undo", 10],
	["click", 723, 414], ["waitlog", "kit editor: selected 17", 10],
	["click", "Button", "Link pressed"], ["waitlog", "kit editor: linking from 17 pressed", 10],
	["click", 706, 223], ["waitlog", "kit editor: selected 18", 10],
	["click", "Button", "To toggle"], ["waitlog", "kit editor: state: 17 entities, 4 to undo", 10],
	["click", 723, 414], ["waitlog", "kit editor: selected 17", 10],
	["frames", 3], ["shot", "${OUT}/linked.png"],
	["key", "u"], ["waitlog", "replicated: entity 18 open = true", 10],
	["waitlog_any", "kit editor: signal 17.pressed -> 18.toggle", 10],
	["key", "u"], ["waitlog", "replicated: entity 18 open = false", 10],
	["click", "Button", "End"], ["waitlog_any", "kit editor: the server is Ended .by webboss", 10],
	["frames", 3], ["shot", "${OUT}/stopped.png"],
	["click", "Button", "Run"], ["waitlog_any", "kit editor: the server is Running .by webboss", 10],
	["key", "b"], ["waitlog", "replicated: entity 4 open = true", 10],
	["frames", 10], ["shot", "${OUT}/play.png"]
]
EOF
	"$here/util/web_drive.sh" chrome sample_kit "$t/steps.json" "$t/out" ||
		fail "the web drive ($t/out)"
	for w in "sample_kit/door 18: opened by webboss to air" \
			"Stop by webboss: " "Play by webboss: a round from the start" \
			"sample_kit/door 4: opened by webboss"; do
		grep -aqF "$w" "$t/out/server.log" || fail "no \"$w\" in $t/out/server.log"
	done
	echo "PASS: Kit's editor in the web client: the admin logs in, places, sets a parameter, links, uses, stops and plays"
	exit 0
fi
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_editor; t=$CHECK_TMP
# The server's own user path: its accounts (_server) and the app's save
save="$t/user/apps/sample_kit/saves/world"
cd "$here/Build"

server() # <n>; USER_DIR another user path
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/sample_kit -D "${USER_DIR:-$t/user}" -l 3 ||
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

# The admin. At 1024x700 the pixel (921, 213) is the top of the stone at
# (6, 1, 2), the cell above it (6, 2, 2); (620, 350) is the top of the
# floor's (3, 0, 1), (600, 271) of its (3, 0, 3) (the door placed there),
# (605, 195) the top of the door's stone at (3, 1, 3) (600, 271 is
# behind the button's cell then), and (512, 570) is the ground's (2, 1,
# -2), off the floor; a click on an entity's cell selects it. A palette
# button arms placing, a click places, a right click stops
cat > "$t/boss.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 10000 admin script: done
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
frames 3
wait_log_any 60000 replicated: entity 4 open = false
wait_log_any 60000 kit editor: edit rights: yes
click Button "Edit"
wait_log 10000 kit editor: state: 15 entities, 0 to undo
mouse_pos 921 213
mouse_click left
wait_log 5000 kit editor: cursor at 6,2,2
frames 3
screenshot @T@/pillar.png
mouse_pos 620 350
mouse_click left
wait_log 5000 kit editor: cursor at 3,1,1
click Button "sample_kit/button"
wait_log 5000 kit editor: placing sample_kit/button
mouse_pos 620 350
frames 3
screenshot @T@/placing.png
mouse_click left
wait_log 10000 kit editor: state: 16 entities, 1 to undo
click Button "sample_kit/door"
wait_log 5000 kit editor: placing sample_kit/door
mouse_pos 600 271
mouse_click left
wait_log 10000 kit editor: state: 17 entities, 2 to undo
click Button "sample_kit/marker"
wait_log 5000 kit editor: placing sample_kit/marker
mouse_pos 512 570
mouse_click left
wait_log 10000 kit editor: state: 18 entities, 3 to undo
mouse_click right
wait_log 5000 kit editor: placing nothing
mouse_click left
wait_log 5000 kit editor: selected 19
keypress Right
wait_log 10000 kit editor: state: 18 entities, 4 to undo
keypress Delete
wait_log 10000 kit editor: state: 17 entities, 5 to undo
click Button "Undo"
wait_log 10000 kit editor: state: 18 entities, 4 to undo
mouse_pos 605 195
mouse_click left
wait_log 5000 kit editor: selected 18
click LineEdit "stone"
keypress End
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
text glass
wait_log 5000 kit editor: 18/1 closed = glass
click Button "Apply"
wait_log 10000 kit editor: state: 18 entities, 5 to undo
click Button "toggle"
wait_log_any 10000 kit editor: tried 18's toggle: → opened
wait_log_any 10000 replicated: entity 18 open = true
click Button "toggle"
wait_log_any 10000 kit editor: tried 18's toggle: → closed
frames 3
screenshot @T@/inspector.png
mouse_pos 620 350
mouse_click left
wait_log 5000 kit editor: selected 17
click Button "Link pressed"
wait_log 5000 kit editor: linking from 17 pressed
mouse_pos 605 195
mouse_click left
wait_log 5000 kit editor: selected 18
click Button "To toggle"
wait_log 10000 kit editor: state: 18 entities, 6 to undo
mouse_pos 620 350
mouse_click left
wait_log 5000 kit editor: selected 17
frames 3
screenshot @T@/link.png
click Button "Play mode"
wait_log 10000 kit editor: edit mode off
frames 3
screenshot @T@/play.png
keypress u
wait_log 10000 replicated: entity 18 open = true
keypress u
wait_log 10000 replicated: entity 18 open = false
click Button "Edit"
wait_log 10000 kit editor: state: 18 entities, 6 to undo
click Button "Undo"
wait_log 10000 kit editor: state: 18 entities, 5 to undo
click Button "Play mode"
wait_log 10000 kit editor: edit mode off
keypress u
wait_log 10000 replicated: entity 17 presses = 3
keypress p
frames 3
click Button "Edit"
wait_log 10000 kit editor: state: 18 entities, 5 to undo
wait_log 60000 kit editor: people: kitbob player
wait_log 60000 replicated: entity 4 open = true
wait_log 10000 replicated: entity 4 open = false
click Button "Builder: no"
wait_log 10000 kit editor: people: kitbob builder
wait_log 60000 kit editor: state: 19 entities
wait_log 30000 kit editor: builder kitbob (#4aa0ff) selects 3
wait_log 30000 replicated: entity 4 open = true
frames 3
screenshot @T@/builders.png
click Button "End"
wait_log 10000 kit editor: the server is Ended (by kitboss)
wait_log_any 10000 replicated: entity 17 presses = 0
wait_log_any 30000 kit editor: state: 20 entities
wait_log_any 10000 kit: builds discarded: Your builds while playing were discarded.
frames 3
screenshot @T@/stopped.png
delay 1000
click Button "Keep them" 1000 100
frames 3
click Button "Run"
wait_log 10000 kit editor: the server is Running (by kitboss)
wait_log 30000 replicated: entity 4 open = true
click Button "Play mode"
wait_log 10000 kit editor: edit mode off
keypress u
wait_log 10000 replicated: entity 17 presses = 1
quit
EOF
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
keypress F6
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
wait_log 10000 kit editor: state: 18 entities
event kit_edit {"op": "place", "type": "sample_kit/marker", "pos": [0, 1, 0]}
wait_log 10000 kit editor: state: 19 entities
keypress Tab
wait_log 10000 kit editor: selected 3
keypress b
wait_log 10000 replicated: entity 4 open = true
wait_log 60000 kit editor: the server is Ended (by kitboss)
wait_log_any 10000 kit: builds discarded: Builds while playing were discarded (kitboss 1).
event kit_edit {"op": "place", "type": "sample_kit/marker", "pos": [0, 1, 0]}
wait_log 10000 kit editor: state: 20 entities
keypress b
wait_log 60000 kit editor: the server is Running (by kitboss)
keypress b
wait_log 10000 replicated: entity 4 open = true
# (F6: the refusal's notification may still cover the bar's right end)
keypress F6
wait_log 10000 kit editor: edit mode off
quit
EOF
server 1
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss &
boss=$!
wait_for_log "$t/boss.log" "replicated: entity 17 presses = 3" 180 ||
	fail "the admin's edits did not get as far as play ($t/boss.log)"
# kitbob's own builder grant by the accounts' admin request: refused
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_ADMIN="priv kitbob builder" client bob
wait $boss || fail "the admin's client ($t/boss.log)"
stop
s=$t/srv1.log
grep -a " kit \| main \| accounts" "$s" | grep -v "A . call" | sed 's/^.*\(kit\|main\|accounts\) *: /  /' |
	grep -a "edit\|undo\|button 17\|door 18\|refused\|builder\|test" | cut -c1-140
want "$s" "kitboss is in edit mode" \
	"An edit by kitboss: placed sample_kit/button 17 at [3,1,1]" \
	"An edit by kitboss: placed sample_kit/door 18 at [3,1,3]" \
	"An edit by kitboss: placed sample_kit/marker 19 at [2,1,-2]" "An edit by kitboss: moved 19 to [3,1,-2]" \
	"An edit by kitboss: deleted 19" "An undo by kitboss: 1 entities put back" \
	"An edit by kitboss: set 18's sample_kit/door closed to \"glass\"" \
	"An edit by kitboss: linked 17.pressed -> 18.toggle" "kitboss left edit mode" \
	"sample_kit/button 17: pressed by kitboss times 1" \
	"sample_kit/door 18: opened by kitboss to air" \
	"kitboss tries entity 18's toggle null" "A try of entity 18's \"toggle\" emitted [[\"opened\"" \
	"A try of entity 18's \"toggle\" emitted [[\"closed\"" \
	"sample_kit/door 18: closed by kitboss to glass" \
	"sample_kit/button 17: pressed by kitboss times 3"
[ "$(grep -ac "sample_kit/door 18: opened" "$s")" = 2 ] ||
	fail "the door moved after the undo took the link away ($s)"
echo "ok: the admin edits: edit mode, place, move, delete, the inspector, the link, undo; the edit works in play"
for op in mode place move delete set link unlink undo builder restart save_prefab; do
	grep -aqE "An edit \($op\) by peer [0-9]+ refused: no edit rights here" "$s" ||
		fail "kitbob's $op was not refused ($s)"
done
want "$s" "An admin request (priv) by kitbob refused: not staff" \
	"kitboss granted builder kitbob" "kitboss made builder kitbob" \
	"refused: only the server's admin makes builders" \
	"An edit by kitbob: placed sample_kit/marker 20 at [0,1,0]"
grep -aE "An edit \(\?\) by peer [0-9]+ refused: not a JSON object" "$s" >/dev/null ||
	fail "kitbob's packet that is no JSON was not refused ($s)"
echo "ok: a player without edit rights is refused each kind of edit and the grant; the admin makes them a builder, who edits and grants nothing"

# Two builders, Stop and Play: the selection seen, the round thrown away
# and the start kept, a round from the start again
want "$s" "kitbob is in edit mode" "kitbob selects entity 3" \
	"sample_kit/door 4: opened by kitbob to air" \
	"Stop by kitboss: " "Play by kitboss: a round from the start" \
	"refused: the server is Stopped" \
	"An edit by kitbob: placed sample_kit/marker 21 at [0,1,0]" \
	"sample_kit/button 17: pressed by kitboss times 1"
want "$t/boss.log" "kit editor: builder kitbob (#4aa0ff) selects 3, cursor none"
# The origins: kitboss's dig of the pillar in play a build, discarded at
# Stop with the notice; the door's voxel kitbob's use opened the door's own
# write (a game change), not offered; kept from the notice a moment later,
# the pillar dug in the start (the next round's start)
want "$s" "sample_kit: a dig at the pillar: written" \
	"Stop by kitboss: 0 kept cells (edits, builds always kept) put back in, 1 builds discarded: kitboss 1" \
	"kitboss keeps the builds of kitboss 1: 1 cells put into the start, 0 entities made, 0 removed (0 discarded left)"
# The door's voxel: air in the round; none at Stop, as at the start (the
# app's floor alone: the door set its voxel first in the first round);
# stone as the next round starts (sample_kit's look once a tick may miss
# it), air as kitbob opens it again
v=$(grep -a "the door's voxel is" "$s" | sed 's/.*the door.s voxel is /v:/' |
	tr '\n' ' ')
echo "  the door's voxel: $v"
echo "$v" | grep -qE "v:air v: (v:stone )?v:air $" ||
	fail "the door's voxel was not put back at Stop and opened again in the next round ($s)"
db="$save/save.sqlite"
[ -f "$db" ] || fail "no database $db"
for k in authored runtime session; do
	sqlite3 "$db" "SELECT value FROM store WHERE store = 'kit' AND key = '$k'" > "$t/$k.json"
done
python3 -I - "$t/authored.json" "$t/runtime.json" "$t/session.json" "$t/boss.log" <<'EOF' || fail "the rows or the replicated state after Stop and Play ($t)"
import json, re, sys
aj, rj, sj, client = sys.argv[1:5]
a, r, s = [json.loads(open(p).read()) for p in (aj, rj, sj)]
e = {x["id"]: x for x in a["entities"]}
assert e[18]["components"][0]["params"]["closed"] == "glass", e[18]
assert e[17]["components"][0]["links"] == [], e[17]
for i in (19, 20, 21):
	assert e[i]["components"][0]["type"] == "sample_kit/marker", e[i]
assert a["next_id"] == 22, a["next_id"]
assert r["17"][0]["state"]["presses"] == 1, r["17"]
assert r["4"][0]["state"]["open"] is True, r["4"]
assert r["7"][0].get("disabled") is None, r["7"]
assert s["running"] is True and s["by"] == "kitboss", s
# What the admin's client saw from the grant on: the round's, then the
# start's at Stop, then the next round's
lines = open(client, errors="replace").read().split("\n")
at = next(i for i, l in enumerate(lines) if "people: kitbob builder" in l)
seen = [m.group(1, 2) for l in lines[at:] if " __app " not in l
		for m in [re.search(r"replicated: entity (4 open|17 presses) = (\S+)", l)] if m]
print("  replicated from the grant on:", seen)
assert seen == [("4 open", "true"), ("17 presses", "0"), ("4 open", "false"),
		("4 open", "true"), ("17 presses", "1")] or seen == [("4 open", "true"),
		("4 open", "false"), ("17 presses", "0"), ("4 open", "true"),
		("17 presses", "1")], seen
EOF
echo "ok: two builders, one's selection in the other's editor; Stop throws the round away and keeps the edits, a use refused and an edit to the start while Stopped; Play starts a round from the start"
# [KIT_WORLD_BAR_FIXES] The tools' bar Running and Ended: End where Run
# is, every other button in its place, Save as start the last (Running)
python3 -I - "$t/boss.log" <<'EOF' || fail "the bar's buttons moved between Run and End ($t/boss.log)"
import re, sys
bars = []
for l in open(sys.argv[1], errors="replace"):
	m = re.search(r"kit editor: bar: (.*)$", l)
	if m:
		bars.append([re.match(r"(.*) (\d+),(\d+)$", it).groups()
				for it in m.group(1).split("; ")])
names = lambda b: [n for n, x, y in b]
run = [b for b in bars if "Run" in names(b)]
end = [b for b in bars if "End" in names(b)]
assert run and end, (len(run), len(end))
for b in end:
	assert names(b)[-1] == "Save as start", names(b)
for b in run:
	assert "Save as start" not in names(b), names(b)
pairs = [(r, e) for r in run for e in end if
		[n if n != "Run" else "End" for n in names(r)] == names(e)[:-1]]
assert pairs, (names(run[-1]), names(end[-1]))
for r, e in pairs:
	assert [(x, y) for n, x, y in r] == [(x, y) for n, x, y in e[:-1]], (r, e)
print("  the bar Ended:", "; ".join(" ".join(i) for i in r))
print("  the bar Running:", "; ".join(" ".join(i) for i in e))
EOF
echo "ok: the bar's End in Run's place, Save as start last, no button moved"

cat > "$t/again.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 kit editor: edit rights: yes
click Button "Edit"
wait_log 10000 kit editor: state: 20 entities, 0 to undo
quit
EOF
server 2
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE= client again
stop
want "$t/srv2.log" "Hosted: 21 entities" "kitbob is in edit mode" \
	"The server is Running (by kitboss): "
grep -aq "the composition's first start" "$t/srv2.log" && fail "the composition was read again ($t/srv2.log)"

# 5. Edits under a game write and under a build, over a restart
ed() { echo "event kit_edit $1"; }
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 kit editor: edit rights: yes
click Button "Edit"
wait_log 10000 kit editor: state: 20 entities, 0 to undo
EOF
	n=0
	edit() { ed "$1"; n=$((n + 1)); echo "wait_log 10000 kit editor: state: $2 entities, $n to undo"; }
	edit '{"op": "place", "type": "kit/voxel_replace", "pos": [6, 1, 1]}' 21
	edit '{"op": "set", "id": 22, "comp": 0, "param": "size", "value": [1, 1, 1]}' 21
	edit '{"op": "set", "id": 22, "comp": 0, "param": "find", "value": "glass"}' 21
	edit '{"op": "set", "id": 22, "comp": 0, "param": "replace", "value": "stone"}' 21
	edit '{"op": "place", "type": "kit/voxel_states", "pos": [6, 1, 1]}' 22
	edit '{"op": "set", "id": 23, "comp": 0, "param": "size", "value": [1, 1, 2]}' 22
	edit '{"op": "set_voxel", "pos": [6, 1, 1], "voxel": "glass"}' 22
	edit '{"op": "set_voxel", "pos": [6, 1, 2], "voxel": "glass"}' 22
	ed '{"op": "try", "id": 22, "input": "toggle"}'
	echo "wait_log 10000 kit editor: tried 22's toggle"
	echo "keypress F6"
	echo "wait_log 10000 kit editor: edit mode off"
	echo "keypress p"
	echo "wait_log 10000 a dig at the pillar sent"
	echo "frames 10"
	echo "quit"
} > "$t/edits.cmds"
cat > "$t/end.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 kit editor: edit rights: yes
click Button "Edit"
wait_log 10000 kit editor: state: 22 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitbob)
event kit_edit {"op": "pattern", "id": 23, "comp": 0, "param": "a", "action": "capture"}
wait_log 10000 kit editor: state: 22 entities, 1 to undo
quit
EOF
# 6's save: part 5's start
cp -a "$t/user" "$t/user6"
server 3
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE= client edits
stop
want "$t/srv3.log" "kit/voxel_replace 22: on: 1 cells glass to stone by kitbob" \
	"sample_kit: a dig at the pillar: written"
server 4
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE= client end
stop
want "$t/srv4.log" "Stop by kitbob: 2 kept cells (edits, builds always kept) put back in, 1 builds discarded: kitbob 1"
sqlite3 "$db" "SELECT value FROM store WHERE store = 'kit' AND key = 'authored'" > "$t/authored5.json"
python3 -I - "$t/authored5.json" <<'EOF' || fail "the edits were not there after End ($t/srv4.log)"
import json, sys
e = {x["id"]: x for x in json.load(open(sys.argv[1]))["entities"]}
a = e[23]["components"][0]["params"]["a"]
print("  the probe after End:", a)
assert a == "1 1 2;glass;0*2", a
EOF
echo "ok: an edit in play kept over a game write, and over a build discarded at End, past a restart"

# 6. [KIT_SHUTDOWN_SAVE] Part 5 again on its start, the server stopped by
# sample_kit right after the dig (BUILDAT_SAMPLE_KIT_DIG_STOP), before a
# tick: Kit's core:shutdown saves the dig's mark, and End discards it
export USER_DIR="$t/user6"
BUILDAT_SAMPLE_KIT_DIG_STOP=1 server 5
sed -i "s|@T@|$t|g" "$t/edits.cmds"
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE= run_client 60 "$t/edits6.log" \
	timeout 180 bin/buildat -C "$t/client_cache" -D "$t/cu_kitbob6" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -c @"$t/edits.cmds"
wait "$SERVER_PID" 2>/dev/null
want "$t/srv5.log" "sample_kit: a dig at the pillar: written" \
	"sample_kit: dug, stopping" "Kit: saved at the stop"
server 6
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE= client end
stop
unset USER_DIR
want "$t/srv6.log" "Stop by kitbob: 2 kept cells (edits, builds always kept) put back in, 1 builds discarded: kitbob 1"
echo "ok: a dig's mark saved by a stop before the next tick"

# 7. [KIT_GUEST_NO_LEAVE] A guest in a zone logs in: the zones' on_leave
# for the guest's dropped entity knows who, with c.player (the arena's)
export USER_DIR="$t/user7"
server 7
wait_for_log "$t/srv7.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv7.log" | head -1)
cat > "$t/boss7.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 kit editor: edit rights: yes
click Button "Edit"
wait_log 10000 kit editor: state: 15 entities, 0 to undo
event kit_edit {"op": "place", "type": "kit/arena", "pos": [-2, 1, -2]}
wait_log 10000 entities, 1 to undo
event kit_edit {"op": "place", "type": "kit/trigger_zone", "pos": [-2, 1, -2]}
wait_log 10000 entities, 2 to undo
event kit_edit {"op": "set", "id": 17, "comp": 0, "param": "size", "value": [5, 3, 5]}
wait_log 10000 entities, 3 to undo
event kit_edit {"op": "set", "id": 18, "comp": 0, "param": "size", "value": [5, 3, 5]}
wait_log 10000 entities, 4 to undo
quit
EOF
cat > "$t/guest7.cmds" <<'EOF'
wait_log 60000 replicated: entity 4 open = false
keypress l
wait_log 30000 accounts: the login page shown
frames 3
click Button "Create a new account"
frames 3
text kitbob
keypress Tab
text checkpass12
keypress Tab
text checkpass12
keypress Tab
keypress Return
wait_log 20000 Joined as kitbob
sync 3000
quit
EOF
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss7
wait_for_log "$t/srv7.log" "kit/arena 17: kitboss left; 0 of 2 inside" 30 ||
	fail "the admin's leave not seen ($t/srv7.log)"
client guest7
stop
unset USER_DIR
want "$t/srv7.log" "Guest p2's entity 1000002 dropped" \
	"kit/arena 17: p2 entered; 1 of 2 inside" "kit/arena 17: p2 left; 1 of 2 inside" \
	"kit/trigger_zone 18: p2 left; 1 inside" "kit/arena 17: kitbob entered; 1 of 2 inside"
echo "ok: a guest in a zone logging in: on_leave knows who left"
echo "PASS: Kit's editor: the admin's edit rights and builders kept in the accounts, edit mode, place, move, delete, the inspector, links, undo, each edit and grant refused without rights, live edits while Running, two builders' selections, Stop and Play, the authored row and the server's state over a restart, edits in play kept under a game write and a discarded build, a mark saved at a stop before a tick, a guest's on_leave as they log in in a zone"
# vim: set noet ts=4 sw=4:
