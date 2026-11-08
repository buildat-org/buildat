#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-02)
# covers: builtin/kit/** builtin/heightmap/** apps/workbench/**
# [KIT_PLAN_CAPS] Kit's 2D plan draws what its cut goes through, on
# Workbench, the admin (kitboss) Ended in edit mode: a World on a flat
# heightmap with a hill raised at (10,0), a wall of cobble one cell high at
# y 4 along x = 2 (z -3...3), the plan 24 cells high at (6,0):
#   1. the cut at 4.5: the wall's cells capped (it was not drawn at all,
#      its top clipped and its sides edge-on), the hill's
#      ground over the cut a patch (each one colour over its cells, darker
#      than the ground round it; the ground is textured);
#   2. (2,4,1) dug: that cell the ground, the wall's others capped;
#   3. the cut at 3.5, under the wall: the wall's cells the ground, the
#      hill still capped.
# The plan zoomed out to 400 high last: the caps' log says their cost.
# KEEP_TMP=1 keeps the screenshots (plan1.png ... plan3.png).
#   util/kit_plan_caps_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_plan_caps; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
n=1
set_w(){ # <param> <json value>
	n=$((n + 1))
	printf 'event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "%s", "value": %s}\nwait_log 20000 entities, %d to undo\n' "$1" "$2" "$n"
}
voxel(){ # <x> <y> <z> <voxel>
	n=$((n + 1))
	printf 'event kit_edit {"op": "set_voxel", "pos": [%s, %s, %s], "voxel": "%s"}\nwait_log 10000 entities, %d to undo\n' "$1" "$2" "$3" "$4" "$n"
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state:
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
event kit_edit {"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}
wait_log 10000 entities, 1 to undo
EOF
	set_w decorations false
	set_w surface '"heightmap"'
	echo "wait_log_any 20000 heightmap: terrain built"
	for i in 1 2 3 4 5 6 7 8; do
		printf 'event kit_edit {"op": "terrain", "tool": "raise", "x": 10, "y": 0, "z": 0, "size": 3, "strength": 5, "stroke": %d}\nwait_log 5000 kit editor: terrain: raise\n' "$i"
		n=$((n + 1))
	done
	printf 'event kit_edit {"op": "terrain", "tool": "column", "x": 10, "y": 0, "z": 0}\nwait_log 5000 kit editor: terrain: column at (10,\n'
	for z in -3 -2 -1 0 1 2 3; do voxel 2 4 "$z" kit/cobble; done
	# A door across the cut (its footprint, for the screenshots)
	n=$((n + 1))
	printf 'event kit_edit {"op": "place", "type": "kit/door", "pos": [6, 4, -3]}\nwait_log 10000 entities, %d to undo\n' "$n"
	cat <<'EOF'
idle 2000
event kit_plan 6 0 24 4.5
wait_log 10000 kit editor: caps at layer 4 (cut 4.5)
frames 10
screenshot @T@/plan1.png
EOF
	# The dig's remesh and the caps after it, before the editor's state
	n=$((n + 1))
	cat <<EOF
event kit_edit {"op": "set_voxel", "pos": [2, 4, 1], "voxel": "air"}
wait_log 10000 kit editor: caps at layer 4 (cut 4.5)
wait_log_any 10000 entities, $n to undo
EOF
	cat <<'EOF'
frames 10
screenshot @T@/plan2.png
event kit_plan 6 0 24 3.5
wait_log 10000 kit editor: caps at layer 3 (cut 3.5)
frames 10
screenshot @T@/plan3.png
event kit_plan 6 0 400 4.5
wait_log 10000 kit editor: caps at layer 4 (cut 4.5)
frames 10
screenshot @T@/plan_wide.png
quit
EOF
} > "$t/boss.cmds"
sed -i "s|@T@|$t|g" "$t/boss.cmds"
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 run_client 60 "$t/boss.log" \
	timeout 240 bin/buildat -C "$t/client_cache" -D "$t/cu" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -c @"$t/boss.cmds" ||
	fail "the client failed ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
grep -a "terrain: column at (10,\|kit editor: caps at" "$t/boss.log" "$t/srv.log" |
	sed 's/^.*kit[ a-z]*: /  /' | cut -c1-200
# The plan 24 high on 700 px, its middle (6,0) at (512,350), +z up
python3 -I - "$t" <<'PY2' || fail "the caps not as they should be ($t/plan*.png)"
import sys
from PIL import Image
t = sys.argv[1]
K = 700 / 24
def px(im, x, z):
	return im.getpixel((round(512 + (x - 6) * K), round(350 - z * K)))
def spots(im, x, z):
	return [px(im, x + dx, z + dz) for dx in (-0.3, 0, 0.3) for dz in (-0.3, 0, 0.3)]
def v(c):
	return max(c[:3])
# A cap: one flat colour over the cell (the ground's texture is not),
# darker than the ground round it
def capped(im, x, z):
	s = spots(im, x, z)
	flat = all(max(abs(a[i] - s[0][i]) for i in range(3)) <= 8 for a in s)
	g = spots(im, 6, 4) + spots(im, 6, 5)
	gv = sum(v(c) for c in g) / len(g)
	return flat and v(s[4]) < gv * 0.85
def hexs(c):
	return "%02x%02x%02x" % c[:3]
p1, p2, p3 = (Image.open("%s/plan%d.png" % (t, i)).convert("RGB") for i in (1, 2, 3))
wall = [(2, z) for z in (-3, -2, -1, 0, 2, 3)]
for i, im in ((1, p1), (2, p2), (3, p3)):
	print("  plan%d: the wall %s, (2,1) %s, the hill %s, the ground %s" % (i,
			" ".join(hexs(px(im, *w)) for w in wall), hexs(px(im, 2, 1)),
			hexs(px(im, 10, 0)), hexs(px(im, 6, 4))))
assert all(capped(p1, *w) for w in wall + [(2, 1)]), "the wall not capped at 4.5"
assert capped(p1, 10, 0), "no patch on the hill at 4.5"
assert all(capped(p2, *w) for w in wall), "the wall's caps gone after a dig"
assert not capped(p2, 2, 1), "the dug cell still capped"
assert not any(capped(p3, *w) for w in wall), "the wall capped with the cut under it"
assert capped(p3, 10, 0), "no patch on the hill at 3.5"
PY2
echo "PASS: the plan's caps: a wall the cut goes through drawn, a hill's patch, a dug cell and a cut moved under the wall followed"
