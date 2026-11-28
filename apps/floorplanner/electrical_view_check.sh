#!/bin/bash
# tier: full
# cost: ~1 min (2026-11-28)
# covers: apps/floorplanner/main/main.cpp apps/floorplanner/main/client_lua/electrical.lua apps/floorplanner/main/client_lua/tool_electrical.lua apps/floorplanner/main/client_lua/overlay.lua
# [FP_ELECTRICAL] (6) The Electrical view's View panel, on
# electrical_check.sh's case: every label kind turned on and counted (a
# run's conductors, cable, circuit and length, a box's height, name and
# inserts, the legend's rows); each run's conductors in the labels'
# notation against a hand count; a symbol unit in plan mm measured on two
# shots, twice the pixels at twice the zoom, and the screen's 16 px the
# same at both; an object hidden (white where it was) and back; the
# panel's own controls clicked (a label toggle, the fold); the settings
# exported with the plan and imported the same. Shots zoomed out and at
# one room (KEEP_TMP=1 keeps them).
#   apps/floorplanner/electrical_view_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp fp_elec_view; t=$CHECK_TMP
trap check_cleanup EXIT
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
event fp_elec object 3000 3200 2000 900 750
wait_log 5000 fp elec: object
sync 5000
event fp_elec view 4500 3500 9000 select
frames 10
event fp_elec probe default
screenshot $t/default.png
event fp_elec viewset el_labels 255
sync 5000
event fp_elec viewset el_sym 100
sync 5000
frames 5
event fp_elec probe all
event fp_elec notation
screenshot $t/all_out.png
event fp_elec view 3000 2000 4500 select
frames 10
screenshot $t/room.png
event fp_elec view 3000 5500 4000 select
frames 10
screenshot $t/study.png
event fp_elec viewset el_labels 0
sync 5000
event fp_elec view 2000 2000 6000 select
frames 10
event fp_elec probe z1
screenshot $t/z1.png
event fp_elec view 2000 2000 3000 select
frames 10
event fp_elec probe z2
screenshot $t/z2.png
event fp_elec viewset el_sym 0
sync 5000
frames 5
event fp_elec probe s2
event fp_elec view 2000 2000 6000 select
frames 10
event fp_elec probe s1
event fp_elec view 3000 3200 3000 select
frames 10
screenshot $t/obj_dim.png
event fp_elec viewset el_objects 3
sync 5000
frames 5
event fp_elec probe hidden
screenshot $t/obj_hidden.png
event fp_elec viewset el_objects 0
sync 5000
event fp_elec viewset el_walls 0
sync 5000
event fp_elec viewset el_outline 0
sync 5000
frames 5
event fp_elec probe normal
screenshot $t/obj_normal.png
click Button "Conductors"
wait_log 5000 fp elec: view el_labels 1
sync 5000
click Button "View"
frames 5
screenshot $t/folded.png
click Button "View"
frames 5
event fp_elec probe clicked
event fp_elec settings exported
event fp_elec export
wait_log 10000 Exported to
quit
C
} > "$t/cmds"
BUILDAT_FP_NAME=owner BUILDAT_FP_PLAN=elec timeout 240 "$here/Build/bin/buildat" \
	-o launch_ui=launch_menu -w 1600x900 -u 1 -l 3 -o sound_mute=1 \
	-C "$t/c" -D "$t/u" -a app/floorplanner/play -c @"$t/cmds" > "$t/f.log" 2>&1 ||
	fail "the drive ($t/f.log: $(grep -a "Command sequence failed" "$t/f.log" | tail -1))"
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
event fp_elec settings imported
quit
C
BUILDAT_FP_NAME=owner timeout 240 "$here/Build/bin/buildat" \
	-o launch_ui=launch_menu -w 1600x900 -u 1 -l 3 -o sound_mute=1 \
	-C "$t/c2" -D "$t/u2" -a app/floorplanner/play -c @"$t/cmds2" > "$t/f2.log" 2>&1 ||
	fail "the import ($t/f2.log: $(grep -a "Command sequence failed" "$t/f2.log" | tail -1))"
cat "$t/f.log" "$t/f2.log" > "$t/all.log"
python3 -I - "$t/all.log" "$t" <<'PY' || fail "the view's labels, sizes or dims ($t/f.log, $t/f2.log)"
import sys, re
from PIL import Image
log, t = open(sys.argv[1], errors="replace").read(), sys.argv[2]
def probe(tag):
	m = re.findall(r"fp elec probe " + tag + r": ([^\n]*)", log)
	assert m, ("no probe", tag)
	return m
def labels(tag):
	return dict((k, int(v)) for k, v in re.findall(r"(\w+) (\d+)", probe(tag)[0][len("labels "):]))
def sizes(tag):
	m = re.match(r"unit ([\d.]+) px, text ([\d.]+) px, walls dim ([\d.]+) (\w+), objects dim ([\d.]+) (\w+), outline (\d)", probe(tag)[1])
	assert m, probe(tag)
	return m.groups()
# The defaults: the circuit numbers only, the board's name (as before)
assert labels("default") == dict(conductors=0, cable=0, circuit=15, length=0, height=0, name=1, inserts=0, legend=0), labels("default")
assert sizes("default")[2:] == ("0.75", "true", "0.60", "true", "1"), sizes("default")
# Everything on: 15 runs, 17 boxes (10 on walls, 4 switches), the legend:
# a title, 7 symbols (board, junction, two outlets, 1-way and 2-way
# switches, lamp), 2 colours, 2 lines, ticks, 2 notation rows, 4 groups,
# 4 circuits
assert labels("all") == dict(conductors=15, cable=15, circuit=15, length=15, height=10, name=17, inserts=4, legend=23), labels("all")
# The notation by hand (electrical_check's derivation): A, B the living
# room's lamps, C the desks, D the kitchen's lamps (groups by their loads' ids)
nota = dict(re.findall(r"fp elec notation: ([^:\n]+): ([^\n]*)", log))
want = {"Main board-J1": "PE N L1", "J1-SW W": "L1 2T(A) 2T(B)",
	"J1-Living A": "PE N 2T(A) 2T(B)", "Living A-Living B": "PE N 2T(A) 2T(B) S(A)",
	"Living B-SW E": "2T(A) 2T(B) S(A) S(B)", "Main board-KJ": "PE N L1",
	"KJ-Kitchen 1": "PE N S(C)", "KJ-Kitchen 2": "PE N S(C)", "KJ-SW K": "L1 S(C)",
	"Main board-SJ": "PE N L1", "SJ-SW S": "L1 S(D)", "SJ-Desk 1": "PE N S(D)",
	"Desk 1-Desk 2": "PE N S(D)", "SJ-Outlet S": "PE N L1", "Data 1-Data 2": "data 1",
	"group A": "Living A", "group B": "Living B", "group C": "Kitchen 1 + Kitchen 2",
	"group D": "Desk 1 + Desk 2"}
for k in sorted(set(want) | set(nota)):
	if want.get(k) != nota.get(k):
		print("notation %s: got %r, want %r" % (k, nota.get(k), want.get(k)))
assert nota == want
# 100 mm a unit: 15 px at 6000 mm in 900 px, 30 at 3000; the screen's 16
# at both
u1, u2 = float(sizes("z1")[0]), float(sizes("z2")[0])
assert abs(u1 - 15) < 0.01 and abs(u2 - 30) < 0.01, (u1, u2)
assert float(sizes("s1")[0]) == 16 and float(sizes("s2")[0]) == 16, (sizes("s1"), sizes("s2"))
# On the shots: Living A's lamp at (2000, 2000), the view's middle; its
# circle's pixels' extent in the flush boxes' blue (25, 63, 191; circuit
# 3's run passes by in 25, 89, 216), 2.4 units across
def lamp(png):
	im = Image.open(png).convert("RGB")
	w, h = im.size
	xs = []
	for y in range(h // 2 - 60, h // 2 + 60):
		for x in range(w // 2 - 60, w // 2 + 60):
			r, g, b = im.getpixel((x, y))
			if abs(r - 25) < 12 and abs(g - 63) < 12 and abs(b - 191) < 12:
				xs.append(x)
	assert xs, png
	return max(xs) - min(xs) + 1
p1, p2 = lamp(t + "/z1.png"), lamp(t + "/z2.png")
print("the lamp %d px across at 6000 mm, %d at 3000 (%.2f)" % (p1, p2, p2 / p1))
assert 34 <= p1 <= 40 and 1.85 <= p2 / p1 <= 2.15, (p1, p2)
# Objects: dim (the walls' 0.75, then 0.6), hidden (white, no node lines
# over it), normal (no dims at all, no outlines)
assert sizes("hidden")[2:] == ("0.75", "true", "1.00", "true", "1"), sizes("hidden")
assert sizes("normal")[2:] == ("0.00", "false", "0.00", "false", "0"), sizes("normal")
obj = re.search(r"fp elec probe hidden: object at (-?\d+) (-?\d+)", log)
assert obj and abs(int(obj.group(1)) - 3000) < 1100 and abs(int(obj.group(2)) - 3200) < 1100, obj
# The shot's middle is (3000, 3200), the object's (the instance's x, z
# its corner or its middle: its own middle from the probe), 3000 mm tall
ox, oz = int(obj.group(1)), int(obj.group(2))
px, py = 800 + (ox - 3000) * 0.3, 450 - (oz - 3200) * 0.3
def at(png):
	return Image.open(png).convert("RGB").getpixel((int(px), int(py)))
hid, dim, nor = at(t + "/obj_hidden.png"), at(t + "/obj_dim.png"), at(t + "/obj_normal.png")
print("the object's middle: dim %s, hidden %s, normal %s" % (dim, hid, nor))
assert min(hid) >= 253 and min(dim) < min(hid) and sum(nor) < sum(dim), (dim, hid, nor)
# The panel's toggle: Conductors on, by the click; folded and opened
assert labels("clicked")["conductors"] == 15 and labels("clicked")["cable"] == 0, labels("clicked")
# The settings, exported and imported
ex = re.search(r"fp elec settings exported: ([^\n]*)", log).group(1)
im = re.search(r"fp elec settings imported: ([^\n]*)", log)
assert ex == "el_sym=0 el_text=100 el_objects=0 el_walls=0 el_outline=0 el_labels=1", ex
assert im and im.group(1) == ex, (ex, im and im.group(1))
print("labels counted by kind; the notation as by hand; a symbol twice the pixels at twice the zoom; objects hidden; the settings round trip")
PY
echo "PASS: the Electrical view's View panel: labels, notation, sizes, dims, the panel's clicks, export and import"
if [ -n "${KEEP_TMP:-}" ]; then echo "shots: $t/default.png $t/all_out.png $t/room.png $t/study.png $t/z1.png $t/z2.png $t/obj_dim.png $t/obj_hidden.png $t/obj_normal.png $t/folded.png"; fi
