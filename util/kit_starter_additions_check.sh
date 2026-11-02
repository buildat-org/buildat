#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-01)
# covers: builtin/kit/kit.cpp builtin/kit/types/logic.lua builtin/kit/types/sign.lua builtin/kit/types/mover.lua builtin/kit/types/pressure_plate.prefab.json builtin/kit/client_lua/module.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/move.lua
# [KIT] stage 4l's starter additions on apps/sample_kit, the server's
# admin driving Kit's editor (one server, one client). Placed: a kit/logic
# L (17, a latch), a kit/sign S (18, "Out: {value}, ..." long enough to wrap), a kit/mover M (19,
# 0.5 s up 2) and a kit/pressure_plate P (20, its zone made big round the
# player). Button 3's pressed to L's a (that link shown in play), L's out
# to S's value, L's on to M's go, P's entered to L's b. The inspector
# shows the selection's cost. End, Run, edit mode off: walking a step,
# the plate's zone sees kitboss in (L's b: off), a press (b) latches L on:
# the sign shows "Out: true, ...", wrapped and made smaller inside its board ([KIT_SIGN_WRAP]), M slides 2 up and signals arrived, and the
# link 3>17 is drawn and lit for the player in play. Screenshot of the
# sign; the sign's board, the mover and a wedge kit/part (21) in the
# stone voxel's texture
# ([KIT_LOOK_MATERIAL]). Read back from the save: the link's "visible".
#
#   util/kit_starter_additions_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_starter_additions; t=$CHECK_TMP
save="$t/user/apps/sample_kit/saves/world"
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

ed() { echo "event kit_edit $1"; }
{
	cat <<'EOF'
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
EOF
	n=0; c=15
	edit() { ed "$1"; n=$((n + 1)); echo "wait_log 10000 kit editor: state: $c entities, $n to undo"; }
	place() { c=$((c + 1)); edit "$1"; }
	setp() { edit "{\"op\": \"set\", \"id\": $1, \"comp\": ${4:-0}, \"param\": \"$2\", \"value\": $3}"; }
	link() { edit "{\"op\": \"link\", \"id\": $1, \"comp\": ${5:-0}, \"output\": \"$2\", \"to\": $3, \"input\": \"$4\"}"; }
	place '{"op": "place", "type": "kit/logic", "pos": [2, 0, 2]}'
	setp 17 mode '"latch"'
	place '{"op": "place", "type": "kit/sign", "pos": [0, 2, 6]}'
	# [KIT_SIGN_WRAP] long enough to wrap on its board and be made smaller
	setp 18 text '"Out: {value}, a line long enough to run past the board unless it is wrapped to its width"'
	place '{"op": "place", "type": "kit/mover", "pos": [4, 0, 4]}'
	setp 19 time 0.5
	# [KIT_LOOK_MATERIAL] The sign's board and the mover in voxel materials
	setp 18 material '"stone"'
	setp 19 material '"stone"'
	place '{"op": "place", "prefab": "kit/pressure_plate", "pos": [-30, -10, -30]}'
	setp 20 size '[60, 40, 60]' 1
	# [KIT_LOOK_MATERIAL] A wedge kit/part W (21) in stone, its slope
	# towards the player
	place '{"op": "place", "type": "kit/part", "pos": [-2, 0, 3]}'
	setp 21 shape '"wedge"'
	setp 21 size '[2, 1, 2]'
	setp 21 voxel '"stone"'
	link 3 pressed 17 a
	edit '{"op": "link_visible", "id": 3, "comp": 0, "output": "pressed", "to": 17, "input": "a", "visible": true}'
	link 17 out 18 value
	link 17 on 19 go
	link 20 entered 17 b 1
	cat <<'EOF'
event kit_select 17
wait_log_any 5000 kit editor: selected 17
wait_log 12000 kit editor: entity 17: Cost:
click Button "End"
wait_log 10000 kit editor: the server is Ended (by kitboss)
click Button "Run"
wait_log 10000 kit editor: the server is Running (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: link 3>17 drawn in play
keydown W
delay 400
keyup W
frames 10
keypress b
wait_log 10000 replicated: entity 3 presses = 1
wait_log_any 10000 kit: link 3>17 lit in play
wait_log_any 10000 kit: entity 18 shows "Out: true,
wait_log_any 10000 kit: entity 19 slid to
frames 10
look_dir 0 -0.15 1
frames 10
screenshot @T@/sign.png
quit
EOF
} > "$t/boss.cmds"
sed -i "s|@T@|$t|g" "$t/boss.cmds"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/sample_kit -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
	run_client 60 "$t/boss.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_boss" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/boss.cmds" ||
	fail "the admin's client ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log b=$t/boss.log
grep -aE "kit/(logic|sign|mover|trigger_zone) (17|18|19|20)" "$s" |
	sed 's/^.* I [a-z_]* *: /  /' | cut -c1-150 | tail -10
grep -a "kit editor: entity 17: Cost" "$b" | head -1 | sed 's/^.*kit editor/  kit editor/'
grep -a "kit: entity 19 slid to" "$b" | head -1 | sed 's/^.*kit:/  kit:/'
grep -aq "kit/trigger_zone 20: kitboss entered" "$s" ||
	fail "the plate's zone did not see kitboss in ($s)"
grep -aq "kit/logic 17: latch on by kitboss" "$s" ||
	fail "the press did not latch the logic on ($s)"
grep -aq 'kit/sign 18: shows "Out: true,' "$s" ||
	fail "the sign was not sent the logic's out ($s)"
grep -aq "kit/mover 19: going out" "$s" ||
	fail "the mover did not go ($s)"
grep -aq "kit/mover 19: arrived out" "$s" ||
	fail "the mover did not signal arrived ($s)"
grep -aq "kit: entity 19 slid to 0,2,0" "$b" ||
	fail "the client did not slide the mover 2 up ($b)"
grep -aqE "kit editor: entity 17: Cost(s|:)" "$b" ||
	fail "the inspector did not show the cost ($b)"
[ -s "$t/sign.png" ] || fail "no screenshot of the sign ($t)"
# [KIT_SIGN_WRAP] The long text wrapped and inside its board's height
grep -a "kit: entity 18's text wrapped" "$b" | tail -1 | sed 's/^.*kit:/  kit:/'
grep -a "kit: entity 18's text wrapped" "$b" | tail -1 |
	awk '{ h = $(NF - 4) + 0; bh = $(NF - 2) + 0; exit !(h > 0 && h <= bh) }' ||
	fail "the sign's text is not inside its board ($b)"
grep -aq 'kit: entity 18 wears stone' "$b" && grep -aq 'kit: entity 19 wears stone' "$b" &&
	grep -aq 'kit: entity 21 wears stone' "$b" ||
	fail "the sign, the mover and the wedge do not wear the stone voxel ($b)"
python3 - "$save/save.sqlite" <<'EOF' || fail "the save's visible link ($save)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
rows = db.execute("select key, value from store where store='kit'").fetchall()
found = False
for k, v in rows:
	try:
		j = json.loads(v)
	except Exception:
		continue
	def walk(x):
		global found
		if isinstance(x, dict):
			if x.get("output") == "pressed" and x.get("to") == 17:
				assert x.get("visible") is True, x
				found = True
			for y in x.values():
				walk(y)
		elif isinstance(x, list):
			for y in x:
				walk(y)
	walk(j)
assert found, "no link 3.pressed -> 17"
EOF
echo "PASS: Kit's starter additions: a logic latch, a sign showing its out, a mover sliding and arriving, a pressure plate seeing the player in, a link shown and lit in play, the inspector's cost; screenshot $t/sign.png"
