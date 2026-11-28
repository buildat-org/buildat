#!/bin/bash
# tier: full
# cost: ~1 min (2026-11-28)
# covers: apps/floorplanner/main/main.cpp apps/floorplanner/main/client_lua/electrical.lua apps/floorplanner/main/client_lua/tool_electrical.lua
# [FP_ELECTRICAL] stage 1: the user's case, built by a drive event in a
# local plan with walls: a living room's two lamps each switched two-way
# from two-gang boxes at both ends, a kitchen's two lamps in parallel on
# one switch, a study whose switch controls the two desk outlets and an
# unswitched outlet, a data circuit between two RJ45 boxes. Asserted:
# every run's derived conductors, cable and length against a hand count,
# the switch boxes' inserts; the server refusing a loop in a circuit, a
# data run to a Schuko box, a second data run, a floor cavity route where
# the floor has none, a flush box (placed by the Box tool's click) on the
# kitchen's outer wall, which has no cavity, and a wall cavity run to the
# surface box put there instead; a run drawn to that box by the Run
# tool's clicks, the box linked to a switch by the Controls tool's and
# unlinked; a lamp box deleted (its runs go with it) and undone, the same
# as before; the plan exported, imported into
# another user directory and the same again. A shot of the Electrical
# view and one with it off (KEEP_TMP=1 keeps them).
#   apps/floorplanner/electrical_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp fp_electrical; t=$CHECK_TMP
trap check_cleanup EXIT
# A click at x y; click_mid at the window's middle, 4 px west
click_at() {
	echo "mouse_pos $1 $2"; echo "frames 3"; echo "mouse_down left"
	echo "frames 2"; echo "mouse_up left"
}
click_mid() { click_at 796 450; }
{
	cat <<C
wait_log 60000 Entered the plan
frames 3
click Button "Start editing"
sync 5000
C
	for w in "0 0 9000 0" "0 0 0 7000" "6000 0 6000 7000" "9000 0 9000 4000" \
			"0 7000 6000 7000" "0 4000 9000 4000"; do
		echo "event fp_wall $w"; echo "sync 5000"
	done
	cat <<C
event fp_elec case
wait_log 10000 fp elec: case
sync 5000
event fp_elec dump first
event fp_elec try loop
wait_log 5000 fp elec: try loop
event fp_elec try data_schuko
wait_log 5000 fp elec: try data_schuko
event fp_elec try data_two
wait_log 5000 fp elec: try data_two
event fp_elec try floor_route
wait_log 5000 fp elec: try floor_route
event fp_elec view 9000 2000 6000 ebox 2 0
frames 5
C
	click_mid
	echo "wait_log 5000 fp elec: box placed"
	echo "event fp_elec view 9000 2000 6000 ebox 2 1"
	echo "frames 5"
	click_mid
	cat <<C
wait_log 5000 fp elec: box placed
sync 5000
event fp_elec try wall_route
wait_log 5000 fp elec: try wall_route
event fp_elec view 7500 2000 6000 erun 2
frames 5
C
	# The Run tool: KJ at the middle, the surface box 1450 mm east; the
	# Controls tool: SW K 1450 west and 1500 north, the box linked to its
	# gang and unlinked again
	click_at 800 450; click_at 1017 450
	echo "wait_log 5000 fp elec: run drawn"
	echo "sync 5000"
	echo "event fp_elec view 7500 2000 6000 elink"
	echo "frames 5"
	click_at 582 225; echo "frames 5"; click_at 1017 450
	echo "wait_log 5000 fp elec: linked"
	echo "sync 5000"
	echo "event fp_elec dump linked"
	click_at 1017 450
	echo "wait_log 5000 fp elec: unlinked"
	cat <<C
sync 5000
event fp_elec dump drawn
event fp_elec delete Living B
wait_log 5000 fp elec: delete Living B
event fp_elec dump deleted
event fp_elec undo
sync 5000
event fp_elec dump undone
event fp_elec view 4500 3500 9000 select
mouse_pos 550 600
frames 10
screenshot $t/electrical.png
keypress J
frames 10
screenshot $t/plain.png
event fp_elec export
wait_log 10000 Exported to
quit
C
} > "$t/cmds"
BUILDAT_FP_NAME=owner BUILDAT_FP_PLAN=elec timeout 240 "$here/Build/bin/buildat" \
	-o launch_ui=launch_menu -w 1600x900 -u 1 -l 3 -o sound_mute=1 \
	-C "$t/c" -D "$t/u" -a app/floorplanner/play -c @"$t/cmds" > "$t/f.log" 2>&1 ||
	fail "the drive ($t/f.log: $(grep -a "Command sequence failed" "$t/f.log" | tail -1))"
# The export, imported by another user directory's plans page
mkdir -p "$t/u2/exports"
cp "$t/u/exports/elec.fpplan" "$t/u2/exports/" || fail "no export ($t/f.log)"
cat > "$t/cmds2" <<C
wait_log 60000 Plans:
frames 10
click Button "Import a plan..."
frames 5
click Button "Choose a file..."
wait_log 5000 The file picker at
frames 5
click Button "elec.fpplan"
frames 5
click Button "Import"
wait_log 60000 Entered the plan
sync 5000
event fp_elec dump imported
quit
C
BUILDAT_FP_NAME=owner timeout 240 "$here/Build/bin/buildat" \
	-o launch_ui=launch_menu -w 1600x900 -u 1 -l 3 -o sound_mute=1 \
	-C "$t/c2" -D "$t/u2" -a app/floorplanner/play -c @"$t/cmds2" > "$t/f2.log" 2>&1 ||
	fail "the import ($t/f2.log: $(grep -a "Command sequence failed" "$t/f2.log" | tail -1))"
cat "$t/f.log" "$t/f2.log" > "$t/all.log"
python3 -I - "$t/all.log" <<'PY' || fail "the derivation or the refusals ($t/f.log, $t/f2.log)"
import sys, re
log = open(sys.argv[1], errors="replace").read()
# An unnamed box by its role, not its id, which an import renumbers
def dump(tag):
	return sorted(re.sub(r"(outlet box) \d+", r"\1 N", m.group(1))
			for m in re.finditer(r"fp elec " + tag + r": ((?:run|box) [^\n]*)", log))
first = dump("first")
A, B, K, D = "(group 'Living A')", "(group 'Living B')", "(group 'Kitchen 1 + Kitchen 2')", "(group 'Desk 1 + Desk 2')"
# By hand: {run: (conductors, cable, cross section, length)}; the board
# at 1500, switches 1050, outlets 300, the ceiling 2600, 100 mm walls
want = {
	"Main board-J1": ("PE, N, L1", "MMJ 3x2.5S", "2.5 mm2", 3050),
	"J1-SW W": ("L1, L1 travellers x2 %s, L1 travellers x2 %s" % (A, B), "MMJ 4x1.5S + MMJ 3x1.5S", "1.5 mm2", 2500),
	"J1-Living A": ("PE, N, L1 travellers x2 %s, L1 travellers x2 %s" % (A, B), "MMJ 4x1.5S + MMJ 3x1.5S", "1.5 mm2", 1000),
	"Living A-Living B": ("PE, N, L1 travellers x2 %s, L1 travellers x2 %s, L1 switched %s" % (A, B, A), "MMJ 4x1.5S + MMJ 4x1.5S", "1.5 mm2", 2000),
	"Living B-SW E": ("L1 travellers x2 %s, L1 travellers x2 %s, L1 switched %s, L1 switched %s" % (A, B, A, B), "MMJ 4x1.5S + MMJ 4x1.5S", "1.5 mm2", 3500),
	"Main board-KJ": ("PE, N, L1", "MMJ 3x1.5S", "1.5 mm2", 7886),
	"KJ-Kitchen 1": ("PE, N, L1 switched " + K, "MMJ 3x1.5S", "1.5 mm2", 1000),
	"KJ-Kitchen 2": ("PE, N, L1 switched " + K, "MMJ 3x1.5S", "1.5 mm2", 1000),
	"KJ-SW K": ("L1, L1 switched " + K, "MMJ 3x1.5S", "1.5 mm2", 3636),
	"Main board-SJ": ("PE, N, L1", "ML 2.5 mm2 x3", "2.5 mm2", 6905),
	"SJ-SW S": ("L1, L1 switched " + D, "ML 2.5 mm2 x2", "2.5 mm2", 4500),
	"SJ-Desk 1": ("PE, N, L1 switched " + D, "ML 2.5 mm2 x3", "2.5 mm2", 4061),
	"Desk 1-Desk 2": ("PE, N, L1 switched " + D, "ML 2.5 mm2 x3", "2.5 mm2", 2000),
	"SJ-Outlet S": ("PE, N, L1", "ML 2.5 mm2 x3", "2.5 mm2", 5250),
	"Data 1-Data 2": ("data 1", "CAT5E", "CAT5E", 2900),
}
two = "two-gang: 2-way (vaihto) + 2-way (vaihto)"
boxes = {"SW W": two, "SW E": two, "SW K": "single: 1-way", "SW S": "single: 1-way"}
expect = sorted(["run %s: %s | %s | %s | %d mm" % ((k,) + v) for k, v in want.items()] +
		["box %s: %s" % kv for kv in boxes.items()])
for a, b in zip(first + [""] * len(expect), expect):
	if a != b:
		print("got:  " + a + "\nwant: " + b)
assert first == expect, "the case's derivation"
# The Run tool's run from KJ to the surface outlet box: unswitched, 1450
# along the ceiling, 2300 down to the box; switched by SW K while linked
drawn = dump("drawn")
new = [l for l in drawn if l not in first]
assert len(new) == 1 and new[0] == "run KJ-outlet box N: PE, N, L1 | MMJ 3x1.5S | 1.5 mm2 | 3750 mm", new
assert len(drawn) == len(first) + 1, drawn
assert new[0].replace("PE, N, L1 |", "PE, N, L1 switched (group 'Kitchen 1 + Kitchen 2 + outlet box N') |") in dump("linked"), dump("linked")
# Living B deleted: its two runs gone, with the one to SW E; the B gangs
# control nothing, and Living A is switched one-way from SW W alone
deleted = dump("deleted")
assert not [l for l in deleted if "Living B" in l and l.startswith("run")], deleted
assert "box SW W: two-gang: 1-way + 1-way (controls nothing)" in deleted, deleted
assert "box SW E: two-gang: 1-way (not on its circuit) + 1-way (controls nothing)" in deleted, deleted
assert "run J1-Living A: PE, N, L1 switched %s | MMJ 3x1.5S | 1.5 mm2 | 1000 mm" % A in deleted, deleted
assert len([l for l in deleted if l.startswith("run")]) == len(want) + 1 - 2, deleted
assert dump("undone") == drawn, ("undo", dump("undone"))
assert dump("imported") == drawn, ("import", dump("imported"))
# The refusals: the server's log lines, these and no others, in order,
# and each edit the client tried answered with its own
tries = [("loop", "would make a loop: a circuit's runs are a tree"),
		("data_schuko", "A data circuit runs between two RJ45 boxes"),
		("data_two", "A data circuit is one run, point to point"),
		("floor_route", "The floor has no installable cavity along the run"),
		("flush", "A flush box needs an installable cavity, and wall "),
		("wall_route", "has no installable cavity for the run: route it on the surface")]
server = re.findall(r"Batch \d+ from owner refused: ([^\n]*)", log)
assert len(server) == len(tries) and all(w in s for (_, w), s in zip(tries, server)), server
for what, why in tries:
	if what != "flush":
		m = re.search(r"fp elec: try " + what + r"(: [^\n]*| done)", log)
		assert m and why in m.group(1), (what, m and m.group(1))
placed = re.findall(r"fp elec: box placed(: [^\n]*| done)", log)
assert len(placed) == 2 and tries[4][1] in placed[0] and placed[1] == " done", placed
print("%d runs and %d switch boxes as counted by hand; the refusals' reasons; undo and import the same" %
		(len(want), len(boxes)))
PY
echo "PASS: the electrical case derived as counted by hand, the refusals, undo, export and import"
if [ -n "${KEEP_TMP:-}" ]; then echo "shots: $t/electrical.png, $t/plain.png"; fi
