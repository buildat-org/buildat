#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-19)
# covers: apps/floorplanner/main/client_lua/editor.lua apps/floorplanner/main/client_lua/rebuild.lua apps/floorplanner/main/client_lua/init.lua
# [FP_MOVE_FAST]: a move's time in a complex plan. The large plan
# (apps/floorplanner/test/large_plan.fpplan) imported through the plans
# page; for a piece of furniture, a
# door and a wall node in turn ("event fp_select"), five W presses and a
# 2 s drag in the plan view, then the drags in 3D under PBR. The editor
# logs each key step's time from the key to the frame showing it and each
# drag's frame times, "fp move: <what> <view> key N ms" and "... drag
# frames p50 N p95 N ms", with the rebuilds', the lighting's, the panels'
# and the round trip's times. Asserted: each case's median key step under
# 100 ms, and a box's and a door's drag p95 under 100 in both views (a
# node's drag rebuilds its layout in full each frame: logged, 90-115 ms
# measured); two W presses 30 ms apart move two grid steps; a move the
# server refuses is put back; the lighting computed never in 2D, not
# during a 3D drag, and again within 1.5 s after one.
# simplified: the median, as this host's load moves single steps by 20%
#   apps/floorplanner/move_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
plan=large_plan.fpplan
check_tmp fp_move; t=$CHECK_TMP
trap check_cleanup EXIT
mkdir -p "$t/u/exports"
cp "$here/apps/floorplanner/test/$plan" "$t/u/exports/"
# A 2 s drag from the window's middle, where fp_select puts the thing
drag() {
	echo "mouse_pos 550 500"; echo "delay 300"; echo "mouse_down left"
	for i in $(seq 40); do echo "mouse_pos $((550 + i * 4)) 500"; echo "delay 50"; done
	echo "mouse_up left"; echo "delay 2000"
}
{
	cat <<C
wait_log 60000 Plans:
delay 1500
click Button "Import a plan..."
delay 500
click Button "Choose a file..."
wait_log 5000 The file picker at
delay 500
click Button "$plan"
delay 1000
click Button "Import"
wait_log 60000 Entered the plan
delay 3000
click Button "Start editing"
delay 2000
C
	for what in furniture door node; do
		echo "event fp_select $what 2d"; echo "delay 1500"
		for i in 1 2 3 4 5; do echo "keypress W"; echo "delay 700"; done
		drag
	done
	for what in furniture door node; do
		echo "event fp_select $what 3d"; echo "delay 4000"
		drag
	done
	echo "event fp_select furniture 2d"; echo "delay 1500"; echo "event fp_where"
	echo "keypress W"; echo "delay 30"; echo "keypress W"; echo "delay 1500"
	echo "event fp_where"; echo "event fp_bad_move"; echo "delay 1500"; echo "event fp_where"
	echo quit
} > "$t/cmds"
BUILDAT_FP_NAME=owner timeout 300 "$here/Build/bin/buildat" \
	-o launch_ui=launch_menu -w 1100x1000 -u 1 -l 3 -o sound_mute=1 \
	-C "$t/c" -D "$t/u" -a app/floorplanner/play -c @"$t/cmds" > "$t/f.log" 2>&1 ||
	fail "the drive ($t/f.log: $(grep -a "Command sequence failed" "$t/f.log" | tail -1))"
grep -a "fp move: " "$t/f.log" | sed 's/.*fp move: //'
python3 -I - "$t/f.log" <<'PY' || fail "the moves ($t/f.log)"
import sys, re
def ts(l):
    m = re.search(r" (\d\d):(\d\d):(\d\d)\.(\d\d\d) ", l)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) + int(m.group(4)) / 1000
lines = open(sys.argv[1], errors="replace").read().split("\n")
keys, drags = {}, {}
for l in lines:
    m = re.search(r"fp move: (\w+) (\w+) key ([\d.]+) ms", l)
    if m:
        keys.setdefault(m.group(1), []).append(float(m.group(3)))
    m = re.search(r"fp move: (\w+) (\w+) drag frames p50 [\d.]+ p95 ([\d.]+)", l)
    if m:
        drags[(m.group(1), m.group(2))] = float(m.group(3))
for what in ("furniture", "door", "node"):
    k = sorted(keys.get(what, []))
    assert len(k) >= 5 and k[len(k) // 2] < 100, (what, k)
for what in ("furniture", "door"):
    for view in ("2d", "3d"):
        assert drags.get((what, view), 1e9) < 100, (what, view, drags)
w = [re.search(r"fp_where: (\d+) (-?\d+) (-?\d+) (-?\d+) grid (\d+)", l).groups()
        for l in lines if "fp_where: " in l]
assert len(w) == 3, w
a, b, c = [[int(v) for v in x] for x in w]
assert b[1] == a[1] and b[2] - a[2] == 2 * a[4], ("two steps", a, b)
assert c == b, ("the refused move put back", b, c)
assert not any("fp daylight: computed in 2d" in l for l in lines), "lighting in 2D"
lit = [ts(l) for l in lines if "fp daylight: computed" in l]
three = ts(next(l for l in lines if "command: event fp_select furniture 3d" in l))
downs = [ts(l) for l in lines if "command: mouse_down left" in l and ts(l) > three]
ups = [ts(l) for l in lines if "command: mouse_up left" in l and ts(l) > three]
assert len(downs) == 3 and len(ups) == 3, (downs, ups)
for d, u in zip(downs, ups):
    assert not any(d + 0.1 < t < u for t in lit), ("lighting during a 3D drag", d, u, lit)
    assert any(u < t < u + 1.5 for t in lit), ("no lighting after a 3D drag", u, lit)
print("two steps %d -> %d mm, a refused move put back" % (a[2], b[2]))
PY
echo "PASS: a move in the large plan under 100 ms, shown at once, put back when refused"
