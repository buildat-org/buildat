#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~20 s, ~1 min with a cold module cache (2026-10-30)
# covers: apps/workbench/** builtin/kit/**
# [KIT] stages 4 and 4b, Workbench and Kit's starter set (kit/*), on
# scripted clients, the server's game clock at CHECK_RATE (the timer's
# seconds are the game's):
#   1. The admin (kitboss, by the setup code) builds a contraption in
#      Kit's editor, by its packets, the server Stopped ([KIT] stage 4c):
#      a spawner, a button, a gate, a lever, a timer, a door, a
#      teleporter, a trigger zone, a scoreboard, a counter, an NPC, an
#      item giver, a key door (taking the key), a dig zone and "Player
#      state between plays" (keeping positions: Play leaves the admin
#      where they are), their parameters set and linked (the button opens the
#      gate and starts the timer, the timer flips the
#      lever three times, the lever opens and shuts the door, the zone
#      scores the players who walk in and counts them, the counter at two
#      makes the NPC speak), and presses Play.
#   2. The admin plays it: looks at the button and presses E (the gate
#      opens, the timer ticks three times, the lever flips, the door
#      follows, the button comes up again), digs at the button (routed to
#      it, kept) and places a stone on the floor, talks to the NPC, takes
#      a key from the item giver (once), and uses the teleporter, which
#      puts them in the zone: scored, counted.
#   3. A second player (kitbob) joins mid-round and is put on the spawner, is
#      refused a dig (no edit rights) but digs in the dig zone, is refused
#      by the key door, takes a key from the item giver and opens the door
#      with it (the key taken), takes the teleporter into the zone
#      (scored, counted: the counter reaches two and the NPC speaks), and
#      walks out of it.
#   4. A restart mid-round: the authored row and the runtime row (the
#      scores, the lever, the door, the key) are the save's, the server
#      Running; the admin is put on the spawner and sees the scoreboard and
#      the key. Then, with "keep inventory" on and "keep position" off:
#      Stop puts back the cell kitbob dug before the restart (the admin
#      digs it again, in the start) and drops the key from play; Play
#      gives it back and the spawner places the admin. A cell dug before
#      "Save as start" stays dug past a Stop, one dug after is put back.
#      "keep inventory" off, the next Play resets the inventory.
# KEEP_TMP=1 keeps the screenshots: the contraption in edit mode, in play,
# after the restart, and after the Stop.
#
#   util/workbench_check.sh
#   util/workbench_check.sh web    the admin's part in headless Chrome
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = web ]; then
	# Workbench in the web client (web/), in headless Chrome at 1200x800:
	# the admin logs in (the setup code), points at the floor ahead in
	# edit mode, places an NPC there, lifts it a cell, leaves edit mode
	# and talks to it with E once Kit's top bar's Play starts a round
	check_tmp workbench_web; t=$CHECK_TMP
	cat > "$t/steps.json" <<'J'
[
	["nav", "${URL}"],
	["waitlog", "player physics enabled", 120],
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
	["key", "F6"], ["waitlog", "kit editor: state: 1 entities", 20],
	["frames", 3], ["click", 891, 217], ["frames", 3],
	["click", 600, 600], ["waitlog", "kit editor: cursor at 0,1,5", 10],
	["click", 372, 254], ["waitlog", "kit editor: state: 2 entities, 1 to undo", 10],
	["click", 600, 600], ["waitlog", "kit editor: selected 3", 10],
	["key", "PageUp"], ["waitlog", "kit editor: state: 2 entities, 2 to undo", 10],
	["frames", 3], ["shot", "${OUT}/edit.png"],
	["click", 656, 20, 100], ["waitlog_any", "kit editor: the server is Running .by webboss", 10],
	["key", "F6"], ["waitlog", "kit editor: edit mode off", 10],
	["key", "e"], ["waitlog", "kit: entity 3 shows .Bob: Hello!.", 10],
	["frames", 5], ["shot", "${OUT}/play.png"]
]
J
	"$here/util/web_drive.sh" chrome workbench "$t/steps.json" "$t/out" ||
		fail "the web drive ($t/out)"
	grep -aq "kit/npc 3: says to player:webboss" "$t/out/server.log" ||
		fail "the NPC said nothing to webboss ($t/out/server.log)"
	echo "PASS: Workbench in the web client: the admin places an NPC in Kit's editor and talks to it"
	exit 0
fi
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp workbench; t=$CHECK_TMP
save="$t/user/apps/workbench/saves/world"
cd "$here/Build"

server() # <n>
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
		--sim-rate "$CHECK_RATE" ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <name>: its commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
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
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

# Each edit as the editor sends it, and its answer: the undo count
n=0
edit() # <json>
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
EOF
	# 3 spawner, 4 button, 5 gate, 6 lever, 7 timer, 8 door, 9 teleporter,
	# 10 trigger zone, 11 scoreboard, 12 counter, 13 npc, 14 item giver,
	# 15 key door, 16 dig zone, 17 player state (on the app root)
	for p in 'kit/spawner [0, 1, -4]' 'kit/button [2, 1, 2]' 'kit/gate [4, 1, 6]' \
			'kit/lever [-2, 1, 2]' 'kit/timer [-3, 1, 2]' 'kit/door [-4, 1, 6]' \
			'kit/teleporter [0, 1, -1]' 'kit/trigger_zone [6, 1, -10]' \
			'kit/scoreboard [6, 1, -4]' 'kit/counter [5, 1, -4]' 'kit/npc [2, 1, -3]' \
			'kit/item_giver [-2, 1, -3]' 'kit/key_door [2, 1, -5]' \
			'kit/dig_zone [-1, 0, -7]' 'kit/player_state [0, 1, 0]'; do
		edit "{\"op\": \"place\", \"type\": \"${p%% *}\", \"pos\": ${p#* }}"
	done
	for s in '7 interval 1' '7 repeats 3' '9 to [8, 1, -8]' '10 size [5, 2, 5]' \
			'12 target 2' '13 name "Ada"' '13 lines "Welcome!|Two came through."' \
			'15 take true' '16 size [3, 1, 3]' '17 keep_position true'; do
		set -- $s
		v=${s#* * }
		edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $v}"
	done
	for l in '4 pressed 5 toggle' '4 pressed 7 start' '7 tick 6 toggle' \
			'6 on 8 open' '6 off 8 close' '10 entered 11 add' \
			'10 entered 12 count' '12 reached 13 say'; do
		set -- $l
		edit "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"$2\", \"to\": $3, \"input\": \"$4\"}"
	done
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
frames 5
screenshot @T@/edit.png
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir 1.5 -1.1 1.5
keypress e
wait_log 10000 kit: use 4
wait_log 10000 kit: entity 7 shows "3"
mouse_click left
frames 3
look_dir 0.4 -1 0
mouse_click right
look_dir 1.5 -1.1 -3.5
keypress e
wait_log 10000 kit: entity 13 shows "Ada: Welcome!"
event kit_use 14
wait_log 10000 kit: items: key x1
event kit_use 14
look_dir 1 -0.3 -1
frames 5
screenshot @T@/play.png
event kit_use 9
wait_log 10000 the server put the player at (8, 1.4, -8)
wait_log 10000 kit: the screen says "Score: kitboss 1 |
wait_log 60000 kit: the screen says "Score: kitbob 1, kitboss 1 |
wait_log_any 30000 kit: entity 13 shows "Ada: Two came through."
look_dir -1 -0.4 1
frames 5
screenshot @T@/scored.png
quit
EOF
} > "$t/boss.cmds"
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 the server put the player at (0, 1.4, -4)
wait_log_any 60000 player physics enabled
look_dir 0 -1 0.5
mouse_click left
look_dir 0 -1 -0.5
mouse_click left
event kit_use 15
frames 2
event kit_use 14
wait_log 10000 kit: items: key x1
event kit_use 15
frames 2
event kit_use 9
wait_log 10000 the server put the player at (8, 1.4, -8)
look_dir 1 0 1
keydown W
delay 1200
keyup W
sync 5000
quit
EOF
server 1
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss &
boss=$!
wait_for_log "$t/boss.log" 'the screen says "Score: kitboss 1 [|]' 240 ||
	fail "the admin did not get as far as the zone ($t/boss.log)"
BUILDAT_JOIN_NAME=kitbob client bob
wait $boss || fail "the admin's client ($t/boss.log)"
stop
s=$t/srv1.log
grep -a " kit \| main " "$s" | grep -v "A . call" | sed 's/^.*\(kit\|main\) *: /  /' |
	grep -a "Entity\|teleport\|gives\|workbench: [a-z]\|joined\|refused" | cut -c1-140
want "$s" "A fresh save: Stopped" "kitboss is in edit mode" \
	"An edit by kitboss: placed kit/spawner 3 at [0,1,-4]" \
	"An edit by kitboss: placed kit/item_giver 14 at [-2,1,-3]" \
	"An edit by kitboss: placed kit/player_state 17 on the app root" \
	"An edit by kitboss: set 9's kit/teleporter to to [8,1,-8]" \
	"An edit by kitboss: linked 12.reached -> 13.say" \
	"Play by kitboss: a round from the start" \
	"kitboss goes through the round's start: inventory reset"
# Play kept the admin where they were (keep position): no spawn
grep -a "spawner teleports kitboss\|kitboss to the app's default spawn" "$s" &&
	fail "Play moved the admin, with keep position on ($s)"
echo "ok: the admin builds the contraption in Kit's editor, Stopped, and plays it"
want "$s" "kit/button 4: pressed by player:kitboss times 1" \
	"kit/gate 5: opened by player:kitboss" \
	"kit/timer 7: started by player:kitboss" "kit/timer 7: tick 3" \
	"kit/timer 7: stopped: its repeats done after 3 ticks" \
	"kit/lever 6: flipped on by player:kitboss" "kit/lever 6: flipped off by player:kitboss" \
	"kit/door 8: opened by player:kitboss" "kit/door 8: shut by player:kitboss" \
	"kit/button 4: kept its cell from player:kitboss" \
	"workbench: kitboss placed stone" \
	"kit/npc 13: says to player:kitboss \"Welcome!\"" \
	"kit/item_giver 14: gives player:kitboss 1 key" \
	"kit/item_giver 14: player:kitboss has had theirs" \
	"Entity 14's kit/item_giver: kitboss has {\"key\":1}" \
	"kit/teleporter 9: used by player:kitboss to 8 1 -8" \
	"Entity 9's kit/teleporter teleports kitboss to (8, 1, -8)" \
	"kit/trigger_zone 10: player:kitboss entered; 1 inside" \
	"kit/scoreboard 11: Score: kitboss 1" "kit/counter 12: count 1 by player:kitboss"
[ "$(grep -ac "kit/lever 6: flipped" "$s")" = 3 ] || fail "the lever did not flip three times ($s)"
[ "$(grep -ac "kit/gate 5: opened" "$s")" = 1 ] || fail "the gate opened other than once ($s)"
grep -aq "kit/button 4: kept" "$s" && grep -aq "workbench: kitboss dug .* routed to its owner" "$s" ||
	fail "the dig at the button was not routed to it ($s)"
echo "ok: the admin plays it: the button opens the gate and starts the timer, which flips the lever, which moves the door; the NPC, the item giver, the teleporter into the zone"
want "$s" "kitbob goes through the round's start: inventory reset" \
	"kit/spawner 3: spawns player:kitbob" \
	"Entity 3's kit/spawner teleports kitbob to (0, 1, -4)" \
	"workbench: a build by kitbob refused: no edit rights and no grant at (0,0,-3)" \
	"kit/dig_zone 16: grants dig by its start" \
	"kit/key_door 15: locked to player:kitbob who has no key" \
	"kit/item_giver 14: gives player:kitbob 1 key" \
	"kit/key_door 15: opened by player:kitbob taking their key" \
	"Entity 15's kit/key_door: kitbob has {}" \
	"kit/trigger_zone 10: player:kitbob entered; 2 inside" \
	"kit/scoreboard 11: Score: kitbob 1, kitboss 1" \
	"kit/counter 12: count 2 by player:kitbob" "kit/counter 12: reached 2" \
	"kit/npc 13: says to player:kitbob \"Two came through.\"" \
	"kit/trigger_zone 10: player:kitbob left; "
[ "$(grep -ac "kit/trigger_zone 10: player:kitbob entered" "$s")" = 1 ] ||
	fail "kitbob entered the zone other than once ($s)"
[ "$(grep -ac "kit/trigger_zone 10: player:kitboss entered" "$s")" = 1 ] ||
	fail "kitboss entered the zone other than once ($s)"
grep -a "player:kitbob left; \|workbench: kitbob left" "$s" | head -1 | grep -q "zone" ||
	fail "kitbob did not walk out of the zone before leaving the server ($s)"
grep -aq "workbench: kitbob dug (0,0,-5): written" "$s" ||
	fail "kitbob did not dig in the dig zone ($s)"
echo "ok: a second player is put on the spawner, may not build but digs in the dig zone, opens the key door with a key from the item giver, which it takes, is teleported into the zone (scored, counted, the NPC speaks) and walks out"

db="$save/save.sqlite"
for k in authored runtime; do
	sqlite3 "$db" "SELECT value FROM store WHERE store = 'kit' AND key = '$k'" > "$t/$k.json"
done
# The restart mid-round, Stop, Play and Save as start. From the spawner
# (0, 1, -4): down and back is the dig zone's (0, 0, -5), which kitbob dug
# (a click there meets no voxel: no dig); down and on is (0, 0, -3), down
# and right (1, 0, -4)
cat > "$t/again.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 the server put the player at (0, 1.4, -4)
wait_log_any 30000 kit: the screen says "Score: kitbob 1, kitboss 1 | Items: key x1"
wait_log_any 60000 player physics enabled
look_dir 0.6 -0.25 1
frames 10
screenshot @T@/again.png
keypress F6
wait_log 10000 kit editor: state: 16 entities, 0 to undo
event kit_edit {"op": "set", "id": 17, "comp": 0, "param": "keep_inventory", "value": true}
wait_log 10000 kit editor: state: 16 entities, 1 to undo
event kit_edit {"op": "set", "id": 17, "comp": 0, "param": "keep_position", "value": false}
wait_log 10000 kit editor: state: 16 entities, 2 to undo
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir 0 -1 -0.5
mouse_click left
frames 3
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Stopped (by kitboss)
wait_log_any 10000 kit: items: none
frames 5
look_dir 0.6 -0.25 1
frames 10
screenshot @T@/stopped.png
look_dir 0 -1 -0.5
mouse_click left
frames 3
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
frames 10
look_dir 0 -1 0.5
mouse_click left
frames 3
keypress F6
wait_log 10000 kit editor: state: 16 entities, 2 to undo
event kit_edit {"op": "save_start"}
wait_log 10000 kit editor: state: 16 entities, 2 to undo
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir 0.5 -1 0
mouse_click left
frames 3
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Stopped (by kitboss)
frames 5
mouse_click left
frames 3
look_dir 0 -1 0.5
mouse_click left
frames 3
keypress F6
wait_log 10000 kit editor: state: 16 entities, 2 to undo
event kit_edit {"op": "set", "id": 17, "comp": 0, "param": "keep_inventory", "value": false}
wait_log 10000 kit editor: state: 16 entities, 3 to undo
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
frames 10
sync 5000
quit
EOF
server 2
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CREATE= client again
stop
s2=$t/srv2.log
grep -a " kit \| main " "$s2" | grep -v "A . call" | sed 's/^.*\(kit\|main\) *: /  /' |
	grep -a "Stop by\|Play by\|Saved\|round's start\|dug\|sections\|spawner\|Running" | cut -c1-140
want "$s2" "Hosted: 17 entities, 15 instances" \
	"The server is Running (by kitboss): " \
	"Entity 3's kit/spawner teleports kitboss to (0, 1, -4)" \
	"sections put back (0 wait for their load), each instance at its start, inventories put aside" \
	"workbench: kitboss dug (0,0,-5): written" \
	"kitboss goes through the round's start: inventory kept" \
	"Saved as the start by kitboss" \
	"workbench: kitboss dug (0,0,-3): written" \
	"kitboss goes through the round's start: inventory reset"
grep -aq "the composition's first start" "$s2" && fail "the composition was read again ($s2)"
# The dig at (0, 0, -5) before the Stop met nothing (kitbob's dig, in the
# round restored over the restart); after it, the cell put back, a dig.
# (1, 0, -4), dug after Save as start, was put back by the Stop: dug twice;
# (0, 0, -3), dug before it, stayed dug: once
[ "$(grep -ac "kitboss dug (0,0,-5)" "$s2")" = 1 ] ||
	fail "the cell kitbob dug was not there to dig once after the Stop ($s2)"
[ "$(grep -ac "kitboss dug (1,0,-4)" "$s2")" = 2 ] ||
	fail "the cell dug after Save as start was not put back by the Stop ($s2)"
[ "$(grep -ac "kitboss dug (0,0,-3)" "$s2")" = 1 ] ||
	fail "the cell dug before Save as start did not stay dug ($s2)"
# Play after the Stop: the spawner placed the admin (keep position off)
awk '/Play by kitboss/ { p = 1 } p && /spawner teleports kitboss/ { f = 1 } END { exit !f }' "$s2" ||
	fail "the spawner did not place the admin at Play ($s2)"
db="$save/save.sqlite"
sqlite3 "$db" "SELECT key FROM store WHERE store = 'kit' AND key LIKE 'start:%'" | grep -q . ||
	fail "no copies of the round's sections in the save ($db)"
# What the admin's client was told of their items as the state changed:
# none at each Stop, the key kept at the next Play, none at the last
python3 -I - "$t/again.log" <<'EOF' || fail "the items over Stop and Play ($t/again.log)"
import re, sys
seen = []
for l in open(sys.argv[1], errors="replace"):
	m = re.search(r"kit editor: the server is (\w+)|kit: items: (.*)", l)
	if m:
		seen.append(m.group(1) or "items " + m.group(2).strip())
at = seen.index("Stopped")
seen = seen[at:]
print("  from the first Stop:", seen)
want = ["Stopped", "items none", "Running", "items key x1", "Stopped",
	"items none", "Running", "items none"]
it = iter(seen)
assert all(w in it for w in want), seen
EOF
echo "ok: a restart mid-round, then Stop puts back what the round dug before it; inventory put aside and given back at Play, reset without keep; the spawner places at Play; Save as start keeps what was dug before it"
python3 -I - "$t/authored.json" "$t/runtime.json" <<'EOF' || fail "the rows ($t)"
import json, sys
a = json.loads(open(sys.argv[1]).read())
r = json.loads(open(sys.argv[2]).read())
e = {x["id"]: x for x in a["entities"]}
assert [x["components"][0]["type"] for x in a["entities"] if x["id"] > 2] == [
	"kit/" + t for t in ["spawner", "button", "gate", "lever", "timer", "door", "teleporter",
	"trigger_zone", "scoreboard", "counter", "npc", "item_giver", "key_door",
	"dig_zone", "player_state"]], a
assert e[17]["parent"] == 1 and "pos" not in e[17], e[17]
assert e[9]["components"][0]["params"]["to"] == [8, 1, -8], e[9]
assert len([l for x in a["entities"] for c in x["components"] for l in c["links"]]) == 8
st = lambda i: r[str(i)][0]["state"]
assert st(11)["text"] == "Score: kitbob 1, kitboss 1", st(11)
assert st(6)["on"] is True and st(8)["open"] is True, (st(6), st(8))
assert st(5)["open"] is True and st(12)["count"] == 2, (st(5), st(12))
assert st(7)["ticks"] == 3 and st(7)["running"] is False, st(7)
assert r["items"] == {"kitboss": {"key": 1}}, r["items"]
assert st(15)["open"] is True and st(16)["dig"] is True, (st(15), st(16))
print("  rows: 15 instances, 8 links, the scores, the lever on, the doors and the gate open, the key")
EOF
echo "PASS: Workbench: the admin builds a contraption of Kit's starter set in its editor, Stopped, and plays it, a second player joins the round, may build only in the dig zone and uses a key; a restart mid-round keeps the rows, Stop puts the start back, Play gives a kept inventory back and places players, Save as start keeps the round's voxels"
# vim: set noet ts=4 sw=4:
