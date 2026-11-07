#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-07)
# covers: builtin/kit/kit.cpp builtin/kit/symmetry.h builtin/kit/types/symmetry.lua builtin/kit/types/door.lua builtin/kit/types/teleporter.lua builtin/kit/types/part.lua
# [KIT_SYMMETRY] (kit_plan 7c stage 1) kit/symmetry's entity copies, in
# Workbench's world project (its World, 3, finite 64 x 64); kitboss edits
# in Kit's editor:
#   1. kit/symmetry 4 placed off the middle, put at it. Under it a kit/part
#      5 (yaw 30) with a kit/sign 9 under it, a kit/trigger_zone 6 (3 x 2 x
#      2, linked to the door), a kit/teleporter 7 (its "to" a world point),
#      a kit/door 8 (yaw 90).
#   2. On: one copy each; one undo takes them all; on again. Then each of
#      halves straight mirrored +x and +z, halves at 45 mirrored, quadrants
#      straight rotational, quadrants at 45 mirrored (between them every
#      map: both axes' and both diagonals' mirrors, the three turns), and
#      in each the part moved: every copy where its source's image is
#      (places and facings, a box's and a door's cells, the world point,
#      the door's mirror, the link to the same slice's door).
#   3. Refused: a copy moved, deleted, given a child, linked to; a source
#      moved out of the authored slice; a second kit/symmetry. A parameter
#      set on a copy stays over a source's move (an override), reset gives
#      it the source's. kit/symmetry deleted: its copies go with it.
# The copies are read from the server's log (-l 4: each copy as made).
#
#   util/kit_symmetry_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_symmetry; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss

n=0
edit() # <json>
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
refused() # <json> <reason>
{
	printf 'event kit_edit %s\nwait_log 10000 kit editor: refused: %s\n' "$1" "$2"
}
sym() # <param> <value>
{
	edit "{\"op\": \"set\", \"id\": 4, \"comp\": 0, \"param\": \"$1\", \"value\": $2}"
}
config() # <slices> <angle> <mode> <slice>
{
	sym on false
	sym slices "\"$1\""
	sym angle "\"$2\""
	sym mode "\"$3\""
	sym slice "\"$4\""
	sym on true
}
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
	edit '{"op": "place", "type": "kit/symmetry", "pos": [5, 1, 7]}'
	edit '{"op": "place", "type": "kit/part", "pos": [3, 1, 2], "parent": 4}'
	edit '{"op": "move", "id": 5, "pos": [3, 1, 2], "yaw": 30}'
	edit '{"op": "place", "type": "kit/trigger_zone", "pos": [5.5, 1, 1], "parent": 4}'
	edit '{"op": "set", "id": 6, "comp": 0, "param": "size", "value": [3, 2, 2]}'
	edit '{"op": "place", "type": "kit/teleporter", "pos": [2, 1, 5], "parent": 4}'
	edit '{"op": "set", "id": 7, "comp": 0, "param": "to", "value": [6, 1, 3]}'
	edit '{"op": "place", "type": "kit/door", "pos": [4, 1, 4], "parent": 4}'
	edit '{"op": "move", "id": 8, "pos": [4, 1, 4], "yaw": 90}'
	edit '{"op": "link", "id": 6, "comp": 0, "output": "entered", "to": 8, "input": "open"}'
	edit '{"op": "place", "type": "kit/sign", "pos": [3, 2, 2], "parent": 5}'
	# halves straight mirrored +x (the defaults), one undo, on again
	sym on true
	echo 'event kit_edit {"op": "undo"}'
	n=$((n - 1))
	printf 'wait_log 10000 entities, %d to undo\n' $n
	sym on true
	edit '{"op": "move", "id": 5, "pos": [4, 1, 3]}'
	config halves straight mirrored +z
	edit '{"op": "move", "id": 5, "pos": [5, 1, 3]}'
	config halves 45 mirrored +x+z
	edit '{"op": "move", "id": 5, "pos": [3, 1, 4]}'
	config quadrants straight rotational +x+z
	edit '{"op": "move", "id": 5, "pos": [2, 1, 6]}'
	# quadrants at 45: x >= |z|, the teleporter and the part moved in first
	sym on false
	edit '{"op": "move", "id": 7, "pos": [6, 1, 2]}'
	edit '{"op": "move", "id": 5, "pos": [5, 1, 3]}'
	config quadrants 45 mirrored +x
	edit '{"op": "move", "id": 5, "pos": [5, 1, 1]}'
	# 45: the part's copy in slice 1, 48 the door's (ids from 10: five
	# copies a slice each time on)
	refused '{"op": "move", "id": 45, "pos": [-5, 1, 3]}' \
		"move: entity 45 is kit/symmetry 4's copy of entity 5: edit its source"
	refused '{"op": "delete", "id": 45}' \
		"delete: entity 45 is kit/symmetry 4's copy of entity 5"
	refused '{"op": "place", "type": "kit/sign", "pos": [3, 3, -5], "parent": 45}' \
		"place: entity 45 is a kit/symmetry copy: nothing goes under it"
	refused '{"op": "link", "id": 6, "comp": 0, "output": "left", "to": 48, "input": "close"}' \
		"link: entity 48 is a kit/symmetry copy: link to its source"
	refused '{"op": "move", "id": 5, "pos": [-3, 1, 2]}' \
		"move: entity 5 at -3, 2 is outside kit/symmetry 4's authored slice +x"
	refused '{"op": "place", "type": "kit/symmetry", "pos": [1, 1, 1]}' \
		"place: its scene has kit/symmetry 4 already: one a scene"
	edit '{"op": "set", "id": 45, "comp": 0, "param": "color", "value": "#ff0000"}'
	edit '{"op": "move", "id": 5, "pos": [6, 1, 3]}'
	edit '{"op": "prefab_reset", "id": 45, "comp": 0, "param": "color"}'
	edit '{"op": "delete", "id": 4}'
	echo 'quit'
} > "$t/boss1.cmds"
start_server "$t/srv1.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 4 ||
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
s=$t/srv1.log
grep -a "An edit by\|An undo by\|kit/symmetry: " "$s" | sed 's/^.* I [a-z_]* *: /  /' | cut -c1-150
python3 - "$s" <<'PY' || fail "the copies ($s)"
import json, math, re, sys
log = open(sys.argv[1], errors="replace").read().split("\n")
MX, MZ, R90, R180, R270, SWAP, ANTI = ((-1, 0, 0, 1), (1, 0, 0, -1),
		(0, 1, -1, 0), (-1, 0, 0, -1), (0, -1, 1, 0), (0, 1, 1, 0), (0, -1, -1, 0))
configs = [("halves straight mirrored +x", [MX]), ("halves straight mirrored +z", [MZ]),
		("halves 45 mirrored +x+z", [ANTI]), ("quadrants straight rotational +x+z", [R90, R180, R270]),
		("quadrants 45 mirrored +x", [SWAP, ANTI, R180])]
part_at = [(4, 1, 3), (5, 1, 3), (3, 1, 4), (2, 1, 6), (5, 1, 1)]
tele_at = [(2, 1, 5)] * 4 + [(6, 1, 2)]
part_before = [(3, 1, 2), (4, 1, 3), (5, 1, 3), (3, 1, 4), (5, 1, 3)]
def app(m, x, z):
	return (m[0] * x + m[1] * z, m[2] * x + m[3] * z)
def yaw_of(fx, fz):
	return math.degrees(math.atan2(fx, fz)) % 360
def facing(m, yaw, flip):
	a = math.radians(yaw)
	x, z = app(m, math.sin(a), math.cos(a))
	return yaw_of(-x if flip else x, -z if flip else z)
def det(m):
	return m[0] * m[3] - m[1] * m[2]
def cells(pos, yaw, n):
	a = math.radians(yaw)
	level = abs(math.sin(a)) < 1e-9 and math.cos(a) > 0
	o = [math.floor(v) for v in pos] if level else list(pos)
	out = set()
	for i in range(n[0]):
		for j in range(n[1]):
			for k in range(n[2]):
				x = o[0] + math.cos(a) * i + math.sin(a) * k
				z = o[2] - math.sin(a) * i + math.cos(a) * k
				out.add((round(x), round(o[1] + j), round(z)))
	return out
def near(a, b):
	return abs(((a - b + 180) % 360) - 180) < 1e-3
def image(M, cs):
	return {(app(M, x, z)[0], y, app(M, x, z)[1]) for x, y, z in cs}
# Segments: from each "on" to the next (an edit's copies logged before it)
edits = [i for i, l in enumerate(log) if "An edit by" in l or "An undo by" in l]
marks = [max(j for j in edits if j < i) + 1 for i in edits
		if "set 4's kit/symmetry on to true" in log[i]]
assert len(marks) == 6, marks
pat = re.compile(r"kit/symmetry 4: copy (\d+) of (\d+), slice (\d+): at ([-\d.]+),([-\d.]+),([-\d.]+) turned ([-\d.]+),([-\d.]+),([-\d.]+): (.*)$")
for k, (name, maps) in enumerate(configs):
	seg = log[marks[k + 1]:marks[k + 2] if k + 2 < len(marks) else len(log)]
	if k == 4:
		seg = seg[:next(i for i, l in enumerate(seg) if " refused: " in l)]
	now = {}
	for l in seg:
		m = pat.search(l)
		if m:
			now[int(m.group(1))] = (int(m.group(2)), int(m.group(3)),
					tuple(float(m.group(g)) for g in (4, 5, 6)), float(m.group(7)),
					json.loads(m.group(10)))
	by = {(v[0], v[1]): (cid, v) for cid, v in now.items()}
	assert len(by) == 5 * len(maps), (name, sorted(by))
	P = part_at[k]
	T = tele_at[k]
	for i, M in enumerate(maps, 1):
		flip = det(M) < 0
		def pos_ok(src, want):
			cid, v = by[(src, i)]
			x, z = app(M, want[0], want[2])
			assert abs(v[2][0] - x) < 1e-6 and abs(v[2][1] - want[1]) < 1e-6 and \
					abs(v[2][2] - z) < 1e-6, (name, i, src, v[2], (x, want[1], z))
			return cid, v
		cid, v = pos_ok(5, P)
		assert near(v[3], facing(M, 30, False)), (name, i, "part", v[3])
		# (logged as made: a move of its parent leaves its row as it is)
		B = part_before[k]
		cid, v = pos_ok(9, (B[0], B[1] + 1, B[2]))
		assert near(v[3], facing(M, 0, False)), (name, i, "sign", v[3])
		cid, v = pos_ok(7, T)
		to = v[4][0]["params"]["to"]
		assert (to[0], to[2]) == app(M, 6, 3) and to[1] == 1, (name, i, to)
		cid, v = by[(6, i)]
		got = cells(v[2], v[3], [int(x) for x in v[4][0]["params"]["size"]])
		want = image(M, cells((5.5, 1, 1), 0, (3, 2, 2)))
		assert got == want, (name, i, "zone", sorted(got), sorted(want))
		links = v[4][0]["links"]
		door = by[(8, i)][0]
		assert links == [{"output": "entered", "to": door, "input": "open"}], (name, i, links)
		cid, v = by[(8, i)]
		got = cells(v[2], v[3], (1, 2, 1))
		want = image(M, cells((4, 1, 4), 90, (1, 2, 1)))
		assert got == want, (name, i, "door", sorted(got), sorted(want))
		assert near(v[3], facing(M, 90, flip)), (name, i, "door facing", v[3])
		assert v[4][0]["params"]["mirror"] == flip, (name, i, "mirror", v[4][0]["params"])
	print("  %s: %d copies where their sources' images are" % (name, len(by)))
# The override over a source's move, and its reset
last = None
kept = False
for l in log[marks[5]:]:
	m = pat.search(l)
	if m and m.group(1) == "45":
		c = json.loads(m.group(10))[0]
		kept = kept or (c.get("overrides") == ["color"] and
				c["params"]["color"] == "#ff0000" and m.group(4) == "3.0000")
		last = c
assert kept, "45's color not kept over 5's move"
assert last["params"]["color"] == "#b0b0b0" and "overrides" not in last, last
print("  a copy's own color kept over its source's move, reset to the source's")
PY
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
want "$s" "kit/symmetry: 5 copies made or changed, 0 gone" "An undo by kitboss: 6 entities put back" \
	"kit/symmetry: 15 copies made or changed, 0 gone" "kit/symmetry: 0 copies made or changed, 15 gone"
grep -a "An edit by kitboss: .*deleted\|An edit by kitboss: delete" "$s" | tail -1
echo "ok: the copies made as their sources' images, for each map; one undo; a copy's own parameter"
echo "PASS: symmetry: kit/symmetry's copies follow their sources for each map, refuse their own edits but parameters, and go with it"
# vim: set noet ts=4 sw=4:
