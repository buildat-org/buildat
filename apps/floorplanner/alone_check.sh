#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-19)
# covers: apps/floorplanner/main/client_lua/editor.lua apps/floorplanner/main/client_lua/rebuild.lua apps/floorplanner/main/client_lua/overlay.lua
# [FP_VOXEL_ALONE]: a voxel volume edited on its own. A local plan: a
# 4000 x 3000 room walled round, a 4 x 2 x 3 volume of 150 mm voxels in it
# (drive events). Asserted: its size "Size 600 x 300 x 450 mm (4 x 2 x 3
# voxels)", after a yaw of 90 "450 x 300 x 600"; in the plan wall gaps and
# no size lines; on its own "voxel alone: <id>, N nodes hidden", the size
# lines 600 x 300 x 450 and no gaps; a click at the window's middle (the
# camera looks at the volume's) places a voxel next to its cells, which
# grows it, and a dig takes it back off; the keys turn the camera (yaw
# and pitch), the wheel zooms within 0.6 and 6 times its size; overcast
# at noon; off again, the node count, the view, the camera and the sky as
# before. A shot of each view.
#   apps/floorplanner/alone_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp fp_alone; t=$CHECK_TMP
trap check_cleanup EXIT
cat > "$t/cmds" <<C
wait_log 60000 Entered the plan
delay 1500
click Button "Start editing"
delay 1000
event fp_room 0 0 4000 3000
delay 500
event fp_wall 0 0 4000 0
delay 300
event fp_wall 4000 0 4000 3000
delay 300
event fp_wall 4000 3000 0 3000
delay 300
event fp_wall 0 3000 0 0
delay 1000
event fp_volume 1000 1000 4 2 3 150
delay 2000
event fp_cells
event fp_yaw 90
delay 1000
event fp_cells
event fp_yaw -90
delay 1000
screenshot $t/plan.png
event fp_cells
event fp_alone on
wait_log 10000 voxel alone: size lines
event fp_cells
screenshot $t/alone.png
mouse_pos 550 500
delay 300
mouse_down left
delay 100
mouse_up left
delay 1500
event fp_cells
event fp_voxel_mode dig
mouse_pos 552 500
delay 300
mouse_down left
delay 100
mouse_up left
delay 1500
event fp_cells
keydown D
delay 300
keyup D
keydown S
delay 100
keyup S
delay 300
event fp_cells
mouse_wheel 20
delay 500
event fp_cells
mouse_wheel -10
delay 200
mouse_wheel -10
delay 200
mouse_wheel -10
delay 500
event fp_cells
event fp_alone off
delay 2000
event fp_cells
screenshot $t/back.png
quit
C
BUILDAT_FP_NAME=owner BUILDAT_FP_PLAN=alone timeout 240 "$here/Build/bin/buildat" \
	-o launch_ui=launch_menu -w 1100x1000 -u 1 -l 3 -o sound_mute=1 \
	-C "$t/c" -D "$t/u" -a app/floorplanner/play -c @"$t/cmds" > "$t/f.log" 2>&1 ||
	fail "the drive ($t/f.log: $(grep -a "Command sequence failed" "$t/f.log" | tail -1))"
grep -a "fp_cells: \|voxel alone: \|fp gaps: " "$t/f.log" | sed 's/.*\(fp_cells\|voxel alone\|fp gaps\)/\1/'
python3 -I - "$t/f.log" <<'PY' || fail "the volume on its own ($t/f.log)"
import sys, re
lines = open(sys.argv[1], errors="replace").read().split("\n")
c = [re.search(r"fp_cells: (.*?); (Size[^;]*); camera (\S+) (\S+) (\S+) (\S+) (\S+) dist (\S+); (\d+) nodes, (\w+); (\w+); sky (\S+) (\S+)", l)
        for l in lines if "fp_cells: " in l]
assert len(c) == 10 and all(c), c
cells = [set(tuple(int(v) for v in x.split(",")) for x in m.group(1).split()) for m in c]
size = [m.group(2) for m in c]
cam = [[float(m.group(i)) for i in range(3, 8)] for m in c]
dist = [m.group(8) for m in c]
nodes = [int(m.group(9)) for m in c]
view = [(m.group(10), m.group(11)) for m in c]
sky = [(m.group(12), m.group(13)) for m in c]
box = {(x, y, z) for x in range(4) for y in range(2) for z in range(3)}
assert cells[0] == box, cells[0]
assert size[0] == "Size 600 x 300 x 450 mm (4 x 2 x 3 voxels)", size[0]
assert size[1] == "Size 450 x 300 x 600 mm (4 x 2 x 3 voxels)", size[1]
assert view[2] == ("2d", "plan"), view[2]
assert view[3] == ("3d", "alone") and sky[3] == ("1", "720"), (view[3], sky[3])
# A voxel placed next to the cells, the volume grown; dug back off
new = cells[4] - box
assert len(new) == 1 and cells[4] >= box, cells[4]
(n,) = new
assert all(-1 <= n[a] <= (4, 2, 3)[a] for a in range(3)), n
assert size[4] != size[0], size[4]
assert cells[5] == box and size[5] == size[0], (cells[5], size[5])
# The keys turned it; the wheel within 0.6 and 6 times 0.6 m
assert cam[6][0] > cam[5][0] + 20 and cam[6][1] != cam[5][1], (cam[5], cam[6])
d = [float(x) for x in dist[6:9]]
assert d[1] < d[0] and abs(d[1] - 0.36) < 0.01 and abs(d[2] - 3.6) < 0.01, d
# Off again: as before
assert view[9] == view[2] and nodes[9] == nodes[2] and cam[9] == cam[2] and sky[9] == sky[2], (view, nodes, cam, sky)
log = "\n".join(lines)
m = re.search(r"voxel alone: (\d+), (\d+) nodes hidden", log)
assert m and int(m.group(2)) > 4, m
assert "voxel alone: size lines 600 x 300 x 450 mm" in log
# The gaps: shown in the plan, none on its own, again after
g = [(i, int(re.search(r"fp gaps: (\d+)", l).group(1))) for i, l in enumerate(lines) if "fp gaps: " in l]
on = next(i for i, l in enumerate(lines) if "command: event fp_alone on" in l)
off = next(i for i, l in enumerate(lines) if "command: event fp_alone off" in l)
assert any(n > 0 for i, n in g if i < on), g
assert [n for i, n in g if on < i < off][-1:] == [0], g
assert any(n > 0 for i, n in g if i > off), g
print("grown by %s, %s nodes hidden, zoom %s" % (n, m.group(2), d))
PY
echo "PASS: a volume on its own: its size, its lines, edited in place, the plan as before after"
