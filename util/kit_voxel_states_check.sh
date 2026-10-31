#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-10-31)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/types/voxel_replace.lua builtin/kit/types/voxel_states.lua builtin/kit/client_lua/editor.lua
# [KIT_VOXEL_STATES] Kit's kit/voxel_replace and kit/voxel_states on
# apps/sample_kit, the server's admin driving Kit's editor (one server,
# one client). The admin places (kit:edit packets, as the editor sends
# them) a voxel_replace R over the box (5, 0, 1) + 3x2x3, finding stone
# and replacing it with glass; a voxel_states S over (3, 0, 5) + 2x2x2;
# probes (voxel_states whose patterns, captured, show a box as it is),
# and links button 3 to R's and S's toggle. Ended, the boxes' start is
# set as patterns ("set" a probe's pattern as text, Show it): R's nine
# floor stones, a stone pillar at (6, 1, 2) and a glass at (5, 1, 1); S's
# four stones under air. Then, with the inspector's buttons (S selected
# by Tab, Shift+Tab): Capture A, B filled with glass (the "pattern" op
# the Fill button sends), Show B (the box glass, an edit), Capture B,
# Show A. Run; in play (b: button 3):
#   1. On: R makes its ten stones glass (the glass before is not its), S
#      writes B: the probes see that.
#   2. The pillar dug (p, a player's build), off: R puts back the nine
#      still glass; the dug pillar stays air, the glass from before stays;
#      S writes A.
#   3. On again, then End: both boxes are the start again (the game's
#      changes put back; the dug pillar, a build, kept).
#   4. R's start_on, then Run: R is on at the start, its stones glass.
# The probes' patterns are read from the save's authored row.
# ([KIT_ROUND_START]) The first End is a fresh save's: sample_kit's floor
# is merged after the round copied its section, and the merge is made
# into the copy, so R's box (probe 20's b, captured then) has its floor
# and pillar after it.
#
#   util/kit_voxel_states_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_voxel_states; t=$CHECK_TMP
save="$t/user/apps/sample_kit/saves/world"
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

# Ids from 17: R 17; probes 18 (R's box, a: on, b: off), 19 (S's box, a:
# on, b: off), 20 (R's box, a: after End), 21 (S's box, a: after End);
# S 22, the last made: Tab goes on to 21, Shift+Tab back to it
ed() { echo "event kit_edit $1"; }
pat() { ed "{\"op\": \"pattern\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"action\": \"capture\"}"; }
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
	n=0
	edit() { ed "$1"; n=$((n + 1)); echo "wait_log 10000 kit editor: state: $2 entities, $n to undo"; }
	e=15
	for p in "kit/voxel_replace|[5, 0, 1]" "kit/voxel_states|[5, 0, 1]" \
			"kit/voxel_states|[3, 0, 5]" "kit/voxel_states|[5, 0, 1]" \
			"kit/voxel_states|[3, 0, 5]" "kit/voxel_states|[3, 0, 5]"; do
		e=$((e + 1))
		edit "{\"op\": \"place\", \"type\": \"${p%|*}\", \"pos\": ${p#*|}}" $e
	done
	set1() { edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}" 21; }
	set1 17 find '"stone"'
	set1 17 replace '"glass"'
	for id in 17 18 20; do set1 $id size '[3, 2, 3]'; done
	for id in 19 21 22; do set1 $id size '[2, 2, 2]'; done
	for id in 17 22; do
		edit "{\"op\": \"link\", \"id\": 3, \"comp\": 0, \"output\": \"pressed\", \"to\": $id, \"input\": \"toggle\"}" 21
	done
	echo "click Button \"End\""
	echo "wait_log 10000 kit editor: the server is Ended (by kitboss)"
	n=$((n + 1)); pat 20 b; echo "wait_log 10000 kit editor: state: 21 entities, $n to undo"
	show() { edit "{\"op\": \"pattern\", \"id\": $1, \"comp\": 0, \"param\": \"a\", \"action\": \"show\"}" 21; }
	set1 18 a '"3 2 3;stone glass air;0*9 1 2*3 0 2*4"'
	show 18
	set1 19 a '"2 2 2;stone air;0*4 1*4"'
	show 19
	echo "keypress Tab"
	echo "wait_log 5000 kit editor: selected 21"
	echo "keydown Shift"
	echo "keypress Tab"
	echo "keyup Shift"
	echo "wait_log 5000 kit editor: selected 22"
	echo "frames 3"
	echo "screenshot @T@/inspector.png"
	ui() { echo "click Button \"$1\""; n=$((n + 1)); echo "wait_log 10000 kit editor: state: 21 entities, $n to undo"; }
	ui "Capture A"
	edit '{"op": "pattern", "id": 22, "comp": 0, "param": "b", "action": "fill", "voxel": "glass"}' 21
	ui "Show B"
	ui "Capture B"
	ui "Show A"
	echo "click Button \"Run\""
	echo "wait_log 10000 kit editor: the server is Running (by kitboss)"
	echo "keypress b"
	echo "wait_log 10000 replicated: entity 3 presses = 1"
	n=$((n + 1)); pat 18 a; echo "wait_log 10000 kit editor: state: 21 entities, $n to undo"
	n=$((n + 1)); pat 19 a; echo "wait_log 10000 kit editor: state: 21 entities, $n to undo"
	echo "keypress p"
	echo "wait_log 10000 a dig at the pillar sent"
	echo "keypress b"
	echo "wait_log 10000 replicated: entity 3 presses = 2"
	n=$((n + 1)); pat 18 b; echo "wait_log 10000 kit editor: state: 21 entities, $n to undo"
	n=$((n + 1)); pat 19 b; echo "wait_log 10000 kit editor: state: 21 entities, $n to undo"
	echo "keypress b"
	echo "wait_log 10000 replicated: entity 3 presses = 3"
	echo "click Button \"End\""
	echo "wait_log 10000 kit editor: the server is Ended (by kitboss)"
	echo "frames 5"
	pat 20 a; echo "wait_log 10000 kit editor: state: 21 entities, $((n + 1)) to undo"
	pat 21 a; echo "wait_log 10000 kit editor: state: 21 entities, $((n + 2)) to undo"
	ed '{"op": "set", "id": 17, "comp": 0, "param": "start_on", "value": true}'
	echo "wait_log 10000 kit editor: state: 21 entities, $((n + 3)) to undo"
	echo "click Button \"Run\""
	echo "wait_log 10000 kit editor: the server is Running (by kitboss)"
	echo "frames 10"
	echo "quit"
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
s=$t/srv.log
grep -a "kit/voxel_\|captured\|filled\|showed\|set_voxels" "$s" |
	sed 's/^.*kit *: /  /' | cut -c1-150
boxes=ok
# The probes' patterns: each cell (x, y, z from the box's first) as the
# box held it
python3 - "$save/save.sqlite" <<'EOF' || boxes=bad
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
row = db.execute("select value from store where store='kit' and key='authored'").fetchone()
a = json.loads(row[0])
ents = {e["id"]: e for e in a["entities"]}
def cells(id, param):
	text = ents[id]["components"][0]["params"].get(param, "")
	size, names, runs = text.split(";")
	sx, sy, sz = map(int, size.split())
	names = names.split()
	out = []
	for r in runs.split():
		i, _, n = r.partition("*")
		out += [names[int(i)]] * int(n or 1)
	assert len(out) == sx * sy * sz, text
	return {(j % sx, j // (sx * sz), j // sx % sz): v for j, v in enumerate(out)}
def expect(what, got, want):
	bad = {k: (got[k], want(*k)) for k in got if got[k] != want(*k)}
	print("  %s: %s" % (what, "as expected" if not bad else "differs: " + repr(bad)))
	if bad:
		print("   ", " ".join("%d%d%d:%s" % (k + (got[k],)) for k in sorted(got, key=lambda k: (k[1], k[2], k[0]))))
	return not bad
# R's box from (5, 0, 1): the glass of the edit at (0, 1, 0), the pillar at (1, 1, 1)
def r_box(floor, glass, pillar):
	return lambda x, y, z: floor if y == 0 else glass if (x, z) == (0, 0) else \
		pillar if (x, z) == (1, 1) else "air"
ok = all([
	expect("R's box after the first End", cells(20, "b"), r_box("stone", "air", "stone")),
	expect("R's box on", cells(18, "a"), r_box("glass", "glass", "glass")),
	expect("R's box off, the pillar dug", cells(18, "b"), r_box("stone", "glass", "air")),
	expect("R's box after End", cells(20, "a"), r_box("stone", "glass", "air")),
	expect("S's box on (B)", cells(19, "a"), lambda x, y, z: "glass"),
	expect("S's box off (A)", cells(19, "b"), lambda x, y, z: "stone" if y == 0 else "air"),
	expect("S's box after End", cells(21, "a"), lambda x, y, z: "stone" if y == 0 else "air"),
	expect("S's A", cells(22, "a"), lambda x, y, z: "stone" if y == 0 else "air"),
	expect("S's B", cells(22, "b"), lambda x, y, z: "glass"),
])
sys.exit(0 if ok else 1)
EOF
want() # <text>...
{
	local w
	for w in "$@"; do
		grep -aqF -- "$w" "$s" || fail "no \"$w\" in $s"
	done
}
want "generator merges made into the copies" \
	"An edit by kitboss: captured 22's kit/voxel_states a, 8 cells in 2 voxels" \
	"An edit by kitboss: filled 22's kit/voxel_states b, 8 cells in 1 voxels" \
	"An edit by kitboss: showed 22's kit/voxel_states b, 8 cells written" \
	"An edit by kitboss: captured 22's kit/voxel_states b, 8 cells in 1 voxels" \
	"An edit by kitboss: showed 22's kit/voxel_states a, 8 cells written" \
	"kit/voxel_replace 17: on: 10 cells stone to glass by kitboss" \
	"kit/voxel_states 22: B: 8 cells written by kitboss" \
	"kit/voxel_replace 17: off: 9 cells glass to stone by kitboss" \
	"kit/voxel_states 22: A: 8 cells written by kitboss" \
	"kit/voxel_replace 17: on: 9 cells stone to glass by its start"
[ "$(grep -ac "kit/voxel_replace 17: on: 9 cells stone to glass by kitboss" "$s")" = 1 ] ||
	fail "the second On did not find the nine stones ($s)"
echo "ok: the inspector's Capture, Fill and Show; R on and off; S toggled; R on at the start"
[ $boxes = ok ] || fail "the boxes ($save)"
echo "PASS: kit/voxel_replace and kit/voxel_states: on, off, a dug cell, a cell of before, the patterns captured and shown, End puts the start back"
