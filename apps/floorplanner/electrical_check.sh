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
# kitchen's outer wall, which has no cavity, a wall cavity run to the
# surface box put there instead and one passing along that wall; a run
# drawn to that box by the Run tool's clicks, the box linked to a switch
# by the Controls tool's and unlinked; a lamp box deleted (its runs go
# with it) and undone, the same as before. Stage 2: the listing exported
# as CSV, line by line as counted by hand; with Select, a box dragged
# along its wall and undone, dragged onto the outer wall and refused, a
# run's point added from a segment's middle, dragged, undone and dropped
# on its neighbour to go; the Circuits window opened in the Layouts
# window's place. The plan exported, imported into another user directory
# and the same again; a switch box on the ceiling dragged onto a wall at
# its height, a box picked by its symbol, a switch clicked off a wall
# refused, the Box tool's drags moving boxes (along a wall, from the
# ceiling onto one and off it); then a riser to a floor above, drawn on it too.
# Shots of the Electrical view, of it off, of a run's handles, of the
# Circuits window's To buy page and of the riser (KEEP_TMP=1 keeps them).
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
# A drag from x0 y0 to x1 y1 with the left button, through its middle
drag() {
	echo "mouse_pos $1 $2"; echo "frames 3"; echo "mouse_down left"; echo "frames 2"
	echo "mouse_pos $((($1 + $3) / 2)) $((($2 + $4) / 2))"; echo "frames 2"
	echo "mouse_pos $3 $4"; echo "frames 3"; echo "mouse_up left"; echo "frames 2"
}
# The stage 2 part's view: (6000, 5000) at the middle, 6000 mm tall in 900
# px, so a plan point x z is at 800 + (x - 6000) * 0.15, 450 - (z - 5000) *
# 0.15. Outlet S's face (5950, 5500): 792 375; SJ (3000, 5500): 350 375.
stage2() {
	cat <<C
event fp_elec list
wait_log_any 5000 fp elec: listing
event fp_elec where before
event fp_elec view 6000 5000 6000 select
frames 5
C
	# Outlet S dragged 500 mm south along its wall, undone; dragged onto
	# the kitchen's outer wall (9000, 3000), which has no cavity: refused
	click_at 793 375; echo "frames 5"
	drag 793 375 793 450
	echo "sync 5000"
	echo "event fp_elec where box_moved"
	echo "event fp_elec undo"; echo "sync 5000"
	echo "event fp_elec where box_undone"
	drag 793 375 1250 750
	echo "sync 5000"
	echo "event fp_elec where box_refused"
	# SJ-Outlet S selected at x 3700; a point added from its middle (4475,
	# 5500) dragged to z 6500, moved to x 5000, undone, and dropped on SJ
	click_at 455 375; echo "frames 5"
	drag 571 375 571 225
	echo "sync 5000"
	echo "event fp_elec where pt_added"; echo "frames 3"
	echo "screenshot $t/handles.png"
	drag 575 225 650 225
	echo "sync 5000"
	echo "event fp_elec where pt_moved"
	echo "event fp_elec undo"; echo "sync 5000"
	echo "event fp_elec where pt_undone"
	drag 575 225 350 375
	echo "sync 5000"
	echo "event fp_elec where pt_deleted"
	# The Layouts window, closed by opening the Circuits window in its
	# place; its To buy page
	cat <<C
click Button "Ground floor"
wait_log 5000 Layouts menu shown
frames 3
click Button "Circuits"
frames 5
click Button "To buy"
frames 10
screenshot $t/circuits.png
event fp_elec windows
C
}
# A switch box on the ceiling 300 mm off the west wall (as a click beside a
# wall put one) and a run to it; view (1500, 3000), 3000 mm tall: x z at
# 800 + (x - 1500) * 0.3, 450 - (z - 3000) * 0.3. SW W picked by its lever,
# 100 mm into the room off its point; SW C dragged onto the wall; the Box
# tool's switch clicked in the room refused
ceiling_switch() {
	cat <<C
event fp_elec try ceiling_switch
wait_log 5000 fp elec: try ceiling_switch
sync 5000
event fp_elec view 1500 3000 3000 select
frames 5
event fp_elec where csw_before
C
	click_at 395 745; echo "frames 3"; echo "event fp_elec sel lever"
	click_at 440 450; echo "frames 3"
	drag 440 450 352 450; echo "sync 5000"
	echo "event fp_elec where csw_dragged"; echo "event fp_elec sel csw_dragged"
	echo "event fp_elec view 1500 3000 3000 ebox 1 0"; echo "frames 3"
	click_at 800 450; echo "frames 3"; echo "sync 5000"
	echo "event fp_elec where csw_placed"
	# With the Box tool: SW C dragged 500 mm north along its wall; J1 from
	# the ceiling onto the west wall at z 2500, and off it back to where it
	# was; no box added
	drag 368 450 368 300; echo "sync 5000"
	echo "event fp_elec where tool_along"
	drag 650 750 352 600; echo "sync 5000"
	echo "event fp_elec where tool_onto"
	drag 375 600 650 750; echo "sync 5000"
	echo "event fp_elec where tool_off"
}
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
event fp_elec try wall_along
wait_log 5000 fp elec: try wall_along
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
C
	stage2
	cat <<C
event fp_elec view 4500 3500 9000 select
mouse_pos 550 600
frames 10
screenshot $t/electrical.png
keypress J
frames 10
screenshot $t/plain.png
event fp_elec export
wait_log 10000 Exported to
C
	ceiling_switch
	cat <<C
event fp_elec riser
wait_log 5000 fp elec riser:
event fp_elec view 1500 2000 4000 select
frames 10
screenshot $t/riser.png
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
event fp_elec where imported
quit
C
BUILDAT_FP_NAME=owner timeout 240 "$here/Build/bin/buildat" \
	-o launch_ui=launch_menu -w 1600x900 -u 1 -l 3 -o sound_mute=1 \
	-C "$t/c2" -D "$t/u2" -a app/floorplanner/play -c @"$t/cmds2" > "$t/f2.log" 2>&1 ||
	fail "the import ($t/f2.log: $(grep -a "Command sequence failed" "$t/f2.log" | tail -1))"
cat "$t/f.log" "$t/f2.log" > "$t/all.log"
# **The listing, by hand**, of the case as the undo left it (the 15 runs
# and the one the Run tool drew; a box more, the surface outlet on the
# kitchen's outer wall). A run's cable: (length + 2 x 300 slack) x 1.1
# waste; a conduit: length x 1.1; each line's sum rounded up to metres.
# The lengths as the derivation's hand count above has them, the odd
# ones: Main board-KJ sqrt(6500^2 + 1950^2) + 1100 = 7886.20, KJ-SW K
# sqrt(1450^2 + 1500^2) + 1550 = 3636.27, Main board-SJ sqrt(2000^2 +
# 5450^2) + 1100 = 6905.39, SJ-Desk 1 sqrt(1000^2 + 1450^2) + 2300 =
# 4061.39 (the board at (1000, 50), SJ (3000, 5500), Desk 1 (2000, 6950)).
# Circuit 1 (MMJ, run 1 2.5 mm2):
#   Main board-J1 3050: (3050 + 600) x 1.1 = 4015, MMJ 3x2.5S -> 5 m
#   J1-SW W 2500: 3410, MMJ 4x + MMJ 3x
#   J1-Living A 1000: 1760, MMJ 4x + MMJ 3x
#   Living A-Living B 2000: 2860, MMJ 4x twice
#   Living B-SW E 3500: 4510, MMJ 4x twice
#   MMJ 4x1.5S: 3410 + 1760 + 2 x 2860 + 2 x 4510 = 19910 -> 20 m
# Circuit 2 (MMJ 3x1.5S): Main board-KJ 9335.82, KJ-Kitchen 1 and 2 1760
#   each, KJ-SW K 4659.90, KJ-the surface outlet 3750: 4785
#   MMJ 3x1.5S: 3410 + 1760 (circuit 1's) + 9335.82 + 2 x 1760 + 4659.90
#   + 4785 = 27470.72 -> 28 m
# Circuit 3 (in conduit: ML 2.5 mm2, one wire a conductor):
#   Main board-SJ 6905.39: 8255.93, PE N L1
#   SJ-SW S 4500: 5610, L1 and the switched live
#   SJ-Desk 1 4061.39: 5127.53, PE N switched
#   Desk 1-Desk 2 2000: 2860, PE N switched
#   SJ-Outlet S 5250: 6435, PE N L1
#   yellow-green and blue: 8255.93 + 5127.53 + 2860 + 6435 = 22678.46 -> 23
#   brown: 8255.93 + 5610 + 6435 = 20300.93 -> 21
#   grey: 5610 + 5127.53 + 2860 = 13597.53 -> 14
#   conduit 20 mm: (6905.39 + 4500 + 4061.39 + 2000 + 5250) x 1.1 =
#   24988.46 -> 25 m
# Circuit 4: Data 1-Data 2 2900: 3850, CAT5E -> 4 m
# Boxes: the board; J1, KJ, SJ junction; four lamps' ceiling boxes; four
# switch boxes; Desk 1, Desk 2, Outlet S, Data 1 and 2 flush outlet boxes
# and the one surface outlet box. Fuses: circuits 1-3, 4 is data.
cat > "$t/want.csv" <<'CSV'
kind,item,quantity,unit,notes
Board,"Main board, main fuse 25 A",1,pcs,"circuits 1, 2, 3"
Box,"Ceiling box, flush",4,pcs,"circuits 1, 2"
Box,"Junction box, flush",3,pcs,"circuits 1, 2, 3"
Box,"Outlet box, flush",5,pcs,"circuits 3, 4"
Box,"Outlet box, surface",1,pcs,circuit 2
Box,"Switch box, flush",4,pcs,"circuits 1, 2, 3"
Outlet,RJ45 x1,2,pcs,circuit 4
Outlet,Schuko x1,2,pcs,"circuits 2, 3"
Outlet,Schuko x2,2,pcs,circuit 3
Switch,single 1-way,2,pcs,"circuits 2, 3"
Switch,two-gang 2-way (vaihto) + 2-way (vaihto),2,pcs,circuit 1
Cable,CAT5E,4,m,circuit 4
Cable,MMJ 3x1.5S,28,m,"circuits 1, 2"
Cable,MMJ 3x2.5S,5,m,circuit 1
Cable,MMJ 4x1.5S,20,m,circuit 1
ML wire,ML 2.5 mm2 blue,23,m,circuit 3
ML wire,ML 2.5 mm2 brown,21,m,circuit 3
ML wire,ML 2.5 mm2 grey,14,m,circuit 3
ML wire,ML 2.5 mm2 yellow-green,23,m,circuit 3
Conduit,20 mm,25,m,circuit 3
Fuse,10 A,1,pcs,circuit 1: Living lights
Fuse,10 A,1,pcs,circuit 2: Kitchen lights
Fuse,16 A,1,pcs,circuit 3: Study outlets
CSV
diff "$t/want.csv" "$t/u/exports/elec-electrical.csv" ||
	fail "the listing: the export (+) against the hand count (-)"
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
		("wall_route", "has no installable cavity for the run: route it on the surface"),
		# Its walls' cavities at its ends, the outer wall's along its way
		("wall_along", "has no installable cavity for the run: route it on the surface"),
		("drag", "A flush box needs an installable cavity, and wall ")]
server = re.findall(r"Batch \d+ from owner refused: ([^\n]*)", log)
assert len(server) == len(tries) and all(w in s for (_, w), s in zip(tries, server)), server
for what, why in tries:
	if what not in ("flush", "drag"):
		m = re.search(r"fp elec: try " + what + r"(: [^\n]*| done)", log)
		assert m and why in m.group(1), (what, m and m.group(1))
placed = re.findall(r"fp elec: box placed(: [^\n]*| done)", log)
assert len(placed) == 2 and tries[4][1] in placed[0] and placed[1] == " done", placed
# **The drags** (stage 2), each as the client's copy of the plan has it
# after the server answered (sync), the last as the export imported has
# it: every box's place and every run's points
def where(tag):
	return dict(re.sub(r"(outlet box) \d+", r"\1 N", m.group(1)).split(": ", 1)
			for m in re.finditer(r"fp elec where " + tag + r": ([^\n]*)", log))
before = where("before")
assert before["box Outlet S"] == "at 5950 5500, wall 6000,0+7000 side 0", before
assert before["run SJ-Outlet S"] == "pts none", before
def changed(tag, key, value):
	w = where(tag)
	assert w == dict(before, **{key: value}), (tag, {k: v for k, v in w.items() if before.get(k) != v})
# Outlet S 500 mm south along its wall; undone; onto the outer wall, refused
changed("box_moved", "box Outlet S", "at 5950 5000, wall 6000,0+7000 side 0")
assert where("box_undone") == before and where("box_refused") == before
moved = re.findall(r"fp elec: box moved(: [^\n]*| done)", log)
assert moved == [" done", ": " + server[-1]] + [" done"] * 4 and tries[-1][1] in moved[1], moved
# SJ-Outlet S: a point from its middle at (4500, 6500) (4473 to the 100 mm
# grid), moved to x 5000, undone, dropped on SJ: none again
changed("pt_added", "run SJ-Outlet S", "pts 4500 6500")
changed("pt_moved", "run SJ-Outlet S", "pts 5000 6500")
changed("pt_undone", "run SJ-Outlet S", "pts 4500 6500")
assert where("pt_deleted") == before and where("imported") == before
assert re.findall(r"fp elec: run points(: [^\n]*| done)", log) == [" done"] * 3
# The Circuits window opened in the Layouts window's place
assert "fp elec windows: layouts false, circuits true" in log
# The ceiling switch: SW W picked by its symbol; SW C dragged onto the west
# wall at its role's height, its run kept; a switch clicked in the room
# refused, nothing placed
csw = where("csw_before")
assert csw["box SW C"] == "at 300 3000, wall none side 0" and csw["run J1-SW C"] == "pts none", csw
assert re.search(r"fp elec sel lever: SW W height 1050\n", log), "lever"
w = where("csw_dragged")
assert w == dict(csw, **{"box SW C": "at 50 3000, wall 0,0+7000 side 1"}), w
assert re.search(r"fp elec sel csw_dragged: SW C height 1050\n", log), "dragged"
assert where("csw_placed") == w and "A switch box goes on a wall: click one" in log
# The Box tool's drags: a box moved, not added
w = dict(w, **{"box SW C": "at 50 3500, wall 0,0+7000 side 1"})
assert where("tool_along") == w, where("tool_along")
assert where("tool_onto") == dict(w, **{"box J1": "at 50 2500, wall 0,0+7000 side 1"}), where("tool_onto")
assert where("tool_off") == w, where("tool_off")
# A riser from J1 to a ceiling box 1000 mm east on the floor above, after
# the export: drawn there too; 1000 along, 3000 up a floor
assert "fp elec riser: drawn on the upper floor: true, 4000 mm" in log
print("%d runs and %d switch boxes as counted by hand; the refusals' reasons; undo and import the same; a box and a run's point dragged, undone and refused" %
		(len(want), len(boxes)))
PY
echo "PASS: the electrical case derived and listed as counted by hand, the refusals, the drags, undo, export and import"
if [ -n "${KEEP_TMP:-}" ]; then echo "shots: $t/electrical.png, $t/plain.png, $t/handles.png, $t/circuits.png, $t/riser.png"; fi
