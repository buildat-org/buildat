#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~20 s (2026-11-07)
# covers: builtin/kit/kit.cpp builtin/kit/symmetry.h
# [KIT_SYMMETRY] (kit_plan 7c stage 2) kit/symmetry's voxels and terrain, in
# Workbench's world project (its World, 3, finite 64 x 64, made a noise
# grassland);
# kitboss edits in Kit's editor:
#   1. kit/symmetry 4 on, halves straight mirrored +x: the slice copied
#      over the other. A stair (facing +x) and a raise stroke mirrored; a
#      cell past the seam refused; both undone; the World's height changed
#      (generated again, copied over again).
#   2. Quadrants straight rotational +x+z: a stair's three turned images.
#   3. The World made a heightmap: copied over; a raise stroke mirrored;
#      "Regenerate all" copied over again.
# Each slice's columns (the column tool's read) compared with their
# sources', the stairs' cells read back (voxel_info), and at each Play the
# server's count of cells, samples and decorations differing from their
# source's image is 0.
#
#   util/kit_symmetry_voxels_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_symmetry_voxels; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss

n=0
edit() # <json>
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 20000 entities, %d to undo\n' "$1" "$n"
}
set_w() # <param> <json value>
{
	edit "{\"op\": \"set\", \"id\": 3, \"comp\": 0, \"param\": \"$1\", \"value\": $2}"
}
sym() # <param> <value>
{
	edit "{\"op\": \"set\", \"id\": 4, \"comp\": 0, \"param\": \"$1\", \"value\": $2}"
}
undo()
{
	n=$((n - 1))
	printf 'event kit_edit {"op": "undo"}\nwait_log 20000 entities, %d to undo\n' "$n"
}
raise() # <x> <z> <stroke>
{
	n=$((n + 1))
	printf 'event kit_edit {"op": "terrain", "tool": "raise", "x": %s, "y": 0, "z": %s, "size": 3, "strength": 5, "stroke": %s}\nwait_log 5000 kit editor: terrain: raise\n' "$1" "$2" "$3"
}
# A group of columns, a source's and its images, compared after the run
cols() # <x z>...
{
	local c
	echo "$*" >> "$t/groups"
	for c in "$@"; do
		set -- $c
		printf 'event kit_edit {"op": "terrain", "tool": "column", "x": %s, "y": 0, "z": %s}\nwait_log 5000 kit editor: terrain: column at (%s,\n' "$1" "$2" "$1"
	done
}
info() # <x> <y> <z>
{
	printf 'event kit_edit {"op": "voxel_info", "pos": [%s, %s, %s]}\nsync 1000\n' "$1" "$2" "$3"
}
play()
{
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
}
: > "$t/groups"
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
event kit_edit {"op": "mode", "on": true}
wait_log_any 10000 kit editor: edit mode on
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	set_w biome '"grassland"'
	echo 'wait_log 30000 kit: World: generated again'
	set_w generator '"noise"'
	echo 'wait_log 30000 kit: World: generated again'
	edit '{"op": "place", "type": "kit/symmetry", "pos": [5, 1, 7]}'
	# 1. halves straight mirrored +x (the defaults)
	sym on true
	cols "7 9" "-7 9"
	cols "20 -13" "-20 -13"
	cols "30 25" "-30 25"
	edit '{"op": "set_voxel", "pos": [5, 12, 2], "voxel": "kit/stone:stair", "param": 1}'
	info 5 12 2
	info -5 12 2
	printf 'event kit_edit {"op": "set_voxel", "pos": [-5, 12, 3], "voxel": "kit/stone"}\nwait_log 10000 (-5,3) is outside kit/symmetry 4'"'"'s authored slice +x\n'
	raise 10 4 1
	cols "10 4" "-10 4"
	cols "12 5" "-12 5"
	play
	undo
	cols "10 4" "-10 4"
	undo
	info 5 12 2
	info -5 12 2
	set_w height 5
	echo 'wait_log 30000 kit: World: generated again'
	cols "7 9" "-7 9"
	cols "20 -13" "-20 -13"
	play
	# 2. quadrants straight rotational +x+z
	sym on false
	sym slices '"quadrants"'
	sym mode '"rotational"'
	sym slice '"+x+z"'
	sym on true
	edit '{"op": "set_voxel", "pos": [5, 12, 6], "voxel": "kit/stone:stair", "param": 0}'
	info 5 12 6
	info 6 12 -5
	info -5 12 -6
	info -6 12 5
	cols "10 4" "4 -10" "-10 -4" "-4 10"
	cols "25 3" "3 -25" "-25 -3" "-3 25"
	play
	# 3. a heightmap
	set_w surface '"heightmap"'
	echo 'wait_log_any 20000 heightmap: terrain built'
	cols "10 4" "4 -10" "-10 -4" "-4 10"
	raise 10 4 2
	cols "10 4" "4 -10" "-10 -4" "-4 10"
	cols "12 6" "6 -12" "-12 -6" "-6 12"
	play
	echo 'event kit_edit {"op": "hm_regenerate"}'
	echo 'wait_log 10000 kit editor: state:'
	echo 'sync 1000'
	cols "20 9" "9 -20" "-20 -9" "-9 20"
	play
	echo 'quit'
} > "$t/boss1.cmds"
start_server "$t/srv1.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv1.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	run_client 60 "$t/boss1.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/boss1.cmds" || fail "the client failed ($t/boss1.log, $t/srv1.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
grep -a "kit/symmetry\|An edit by .*images\|An undo by" "$t/srv1.log" |
	sed 's/^.* [IW] [a-z_]* *: /  /' | cut -c1-160
python3 - "$t/srv1.log" "$t/boss1.log" "$t/groups" <<'PY' || fail "the slices ($t/srv1.log, $t/boss1.log)"
import re, sys
srv = open(sys.argv[1], errors="replace").read()
cli = open(sys.argv[2], errors="replace").read()
groups = [l.split() for l in open(sys.argv[3]).read().split("\n") if l]
reads = []
for l in cli.split("\n"):
	m = re.search(r"terrain: column at \((-?\d+),-?\d+,(-?\d+)\).*?; column \(-?\d+,-?\d+\): (.*?)(?:; \d+ images)? \(\d+ to undo\)", l)
	if m:
		reads.append(((int(m[1]), int(m[2])), m[3]))
		continue
	m = re.search(r"terrain: column at \((-?\d+),(-?\d+)\).*?\(\1,\2\) at ([-0-9.]+ layer \d+)", l)
	if m:
		reads.append(((int(m[1]), int(m[2])), m[3]))
bad = 0
k = 0
for g in groups:
	pts = [(int(g[i]), int(g[i + 1])) for i in range(0, len(g), 2)]
	got = reads[k:k + len(pts)]
	k += len(pts)
	if [p for p, _ in got] != pts:
		print("FAIL: columns read", [p for p, _ in got], "for", pts); bad += 1
		continue
	if len(set(v for _, v in got)) != 1:
		print("FAIL: columns differ:", got); bad += 1
	else:
		print("  ", pts, got[0][1])
if k != len(reads):
	print("FAIL: %d column reads for %d asked" % (len(reads), k)); bad += 1
seq = re.findall(r"Voxel at \((-?\d+),(-?\d+),(-?\d+)\): ([^,]+, param \d+)", srv)
want = [((5, 12, 2), "kit/stone:stair, param 1"), ((-5, 12, 2), "kit/stone:stair, param 3"),
		((5, 12, 2), None), ((-5, 12, 2), None),
		((5, 12, 6), "kit/stone:stair, param 0"), ((6, 12, -5), "kit/stone:stair, param 1"),
		((-5, 12, -6), "kit/stone:stair, param 2"), ((-6, 12, 5), "kit/stone:stair, param 3")]
if len(seq) != len(want):
	print("FAIL: %d voxel reads, %d wanted" % (len(seq), len(want))); bad += 1
for (a, b, c, v), (p, w) in zip(seq, want):
	if (int(a), int(b), int(c)) != p or (w and v != w) or (not w and "stair" in v):
		print("FAIL: voxel at", p, ":", v, "wanted", w or "no stair"); bad += 1
plays = re.findall(r"kit/symmetry 4 at Play: (\d+) cells, (\d+) samples, (\d+) decorations differ[^\n]*", srv)
if len(plays) != 5:
	print("FAIL: %d parity reads at Play, 5 wanted" % len(plays)); bad += 1
for i, p in enumerate(plays):
	# (the heightmap's Plays: its voxels are unloaded, the samples count)
	if (p[0] != "0" and i < 3) or p[1] != "0" or p[2] != "0":
		print("FAIL: Play %d: %s cells, %s samples, %s decorations differ" % ((i,) + p)); bad += 1
print("  parity at Play:", plays)
for w in ["the slice +x copied over the others", "the slice +x+z copied over the others",
		"after the regeneration", "after the heightmap's generation"]:
	if w not in srv:
		print("FAIL: no \"%s\"" % w); bad += 1
sys.exit(1 if bad else 0)
PY
echo "PASS: kit/symmetry voxels: mirrored and turned edits, brushes, undo, regenerations and a heightmap, every slice its source's image"
# vim: set noet ts=4 sw=4:
