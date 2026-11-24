#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-24)
# covers: builtin/kit/terrain.h builtin/kit/kit.cpp builtin/kit/box/box.c src/server/wasm_module.cpp builtin/kit/materials.json builtin/kit/types/terrain.lua
# [KIT_RTS] (kit_plan 4z37zzo) The underground generator and the world voxel
# API (c:voxel_at, c:voxels_at, c:set_voxels_at) on a Workbench save of the
# check's own: a World "underground" (64x64, level 0, height 24, caves,
# biome underground), two kit/terrain_region rooms (flat, level 0) placed
# point-symmetric, a check type with world_voxels and a native unit
# (kit/part, kit/unit_walker, kit/unit) in room A told to go to room B.
#   - the scan (c:voxels_at, a layer of 64x64 a call): y 1-2 all air, the
#     top (0) all ground, the floor (-24 down) all hard rock; soil, rock,
#     hard rock and ore in their proportions in the ground, caverns (air
#     under the top past the rooms' own) with gravel floors; every layer
#     point-symmetric ((x, z) as (-x - 1, -z - 1));
#   - a write with one bad name refused whole (its good cell kept);
#   - the unit's first way is short of room B (no way through); a 2x2
#     tunnel dug from room A to room B (c:set_voxels_at, read back by
#     c:voxels_at as air), then the unit arrives in room B through it;
#   - a client (headless weston) with kit/controls' rts camera and
#     kit/environment's fill: screenshots cut at -3.5 and -9.5 ($t/cut_*.png,
#     KEEP_TMP=1), then Stop and Play: the tunnel's cells are as before the
#     dig again (game changes put back).
#   util/kit_world_voxels_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_world_voxels; t=$CHECK_TMP
cd "$here/Build"
check_build
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1 SDL_AUDIODRIVER=dummy
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_WORKBENCH_TYPES=$t/user/apps/workbench/check_types
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
# The scanner and digger: the layers y 2 to -26 four a run, then (3 s on,
# the unit's first way made) the bad write, the dig and its read back
cat > "$BUILDAT_WORKBENCH_TYPES/wv_dig.lua" <<'EOF'
local function tunnel(c)
	local t, n = {}, {}
	for x = -16, 15 do
		for y = -5, -4 do
			for z = 0, 1 do
				local v = c:voxel_at(x, y, z) or "?"
				n[v] = (n[v] or 0) + 1
				t[#t + 1] = v:sub(5, 6)
			end
		end
	end
	local s = {}
	for k, v in pairs(n) do s[#s + 1] = k .. "=" .. v end
	table.sort(s)
	return table.concat(s, " ") .. " | " .. table.concat(t, ",")
end
return {
	version = 1,
	about = {what = "A check's: scans, digs and logs the World's cells."},
	component = true,
	world_voxels = true,
	state = {y = {default = 2}},
	on_start = function(c)
		c:after(0.5, "scan")
	end,
	on_timer = function(c, name)
		if name == "scan" then
			if not c:voxel_at(0, 0, 0) then
				c:after(0.5, "scan")
				return
			end
			if c.state.y == 2 then
				c:log("wv before tunnel: " .. tunnel(c))
			end
			for i = 1, 4 do
				local y = c.state.y
				if y < -26 then
					c:log("wv scanned")
					c:after(3, "bad")
					return
				end
				local cells = c:voxels_at({-32, y, -32}, {64, 1, 64})
				local n, asym = {}, 0
				for k = 1, 4096 do
					local v = cells[k]
					n[v] = (n[v] or 0) + 1
					local x, z = (k - 1) % 64, math.floor((k - 1) / 64)
					if v ~= cells[1 + (63 - x) + 64 * (63 - z)] then
						asym = asym + 1
					end
				end
				local s = {}
				for k, v in pairs(n) do s[#s + 1] = k .. "=" .. v end
				table.sort(s)
				c:log("wv layer " .. y .. ": asym " .. asym .. " " .. table.concat(s, " "))
				c.state.y = y - 1
			end
			c:after(0.05, "scan")
		elseif name == "bad" then
			c.state.kept = c:voxel_at(-10, -5, 0)
			c:set_voxels_at({{-10, -5, 0, "air"}, {-9, -5, 0, "kit/nonesuch"}})
			c:after(0.2, "dig")
		elseif name == "dig" then
			c:log("wv bad write: (-10, -5, 0) " .. tostring(c.state.kept) .. " -> " ..
				tostring(c:voxel_at(-10, -5, 0)))
			local v = {}
			for x = -16, 15 do
				for z = 0, 1 do
					v[#v + 1] = {x, -6, z, "kit/gravel"}
					v[#v + 1] = {x + 0.2, -5, z - 0.3, "air"}
					v[#v + 1] = {x, -4, z, "air"}
				end
			end
			c:set_voxels_at(v)
			c:after(0.2, "read")
		elseif name == "read" then
			local cells = c:voxels_at({-16, -5, 0}, {32, 2, 2})
			local air = 0
			for _, v in ipairs(cells) do
				if v == "air" then air = air + 1 end
			end
			c:log("wv dug: " .. air .. " of " .. #cells .. " air")
		end
	end,
}
EOF
cat > "$BUILDAT_WORKBENCH_TYPES/wv_go.lua" <<'EOF'
return {
	version = 1,
	about = {what = "A check's: its unit walks to room B."},
	component = true,
	on_start = function(c)
		c:after(1, "go")
	end,
	on_timer = function(c)
		c:propose_move({to = {19, -5.5, 0.5}, range = 1})
		c:log("wv go")
	end,
}
EOF

start_server "$t/srv0.log" "Hosted: |Not hosted: " 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv0.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
db=$t/user/apps/workbench/saves/world/save.sqlite
[ -f "$db" ] || fail "no save ($t/user)"
python3 -I - "$db" <<'PY' || fail "the save ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
room = lambda x: {"type": "kit/terrain_region", "params": {"size": [8, 4, 8],
	"generator": "flat", "level": 0, "biome": "underground", "decorations": False}}
ents = [{"id": 2, "parent": 1, "name": "world", "kind": "scene"},
	{"id": 3, "parent": 2, "name": "start", "pos": [0, 1, 0],
		"components": [{"type": "kit/spawner", "params": {"players": True}}]},
	{"id": 4, "parent": 2, "name": "terrain", "components": [{"type": "kit/terrain",
		"params": {"generator": "underground", "biome": "underground", "seed": 7,
			"level": 0, "height": 24, "caves": True, "width": 64, "depth": 64}}]},
	{"id": 5, "parent": 2, "name": "room_a", "pos": [-24, -6, -4], "components": [room(0)]},
	{"id": 6, "parent": 2, "name": "room_b", "pos": [16, -6, -4], "components": [room(1)]},
	{"id": 7, "parent": 2, "name": "digger", "pos": [0, 1, 0],
		"components": [{"type": "workbench/wv_dig"}]},
	{"id": 8, "parent": 2, "name": "controls",
		"components": [{"type": "kit/controls", "params": {"camera": "rts", "height": 40, "angle": 60}}]},
	{"id": 9, "parent": 2, "name": "env",
		"components": [{"type": "kit/environment", "params": {"sun": False, "moon": False,
			"stars": False, "fill": 0.8}}]},
	{"id": 10, "parent": 2, "name": "unit", "pos": [-20, -5, 0.5], "components": [
		{"type": "kit/part", "params": {"size": [0.8, 0.6, 0.8], "color": "#3060d0", "collision": False}},
		{"type": "kit/unit_walker"}, {"type": "kit/unit"}, {"type": "workbench/wv_go"}]}]
def put(k, v):
	db.execute("insert or replace into store (store, key, value) values (?, ?, ?)",
		("kit", k, json.dumps(v).encode()))
put("authored", {"kit": 1, "api": 1, "next_id": 11, "entities": ents})
put("session", {"by": "", "restore": [], "round": [], "running": True})
db.execute("delete from store where store = ? and key = ?", ("kit", "runtime"))
db.commit()
PY

sock=bwv-$$
XDG_RUNTIME_DIR=/run/user/$(id -u) weston --backend=headless --renderer=pixman \
	--xwayland --socket=$sock --width=960 --height=600 --idle-time=0 \
	> "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
d=
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"

SL=$t/srv.log
start_server "$SL" "Hosted: |Not hosted: " 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($SL)"
grep -aq "Not hosted: " "$SL" && fail "not hosted ($SL)"
wait_for_log "$SL" "wv scanned" 60 || fail "no scan ($SL)"
wait_for_log "$SL" "wv dug: " 30 || fail "no dig ($SL)"
wait_for_log "$SL" "Entity 10 stopped at .*: arrived" 60 || fail "the unit did not arrive ($SL)"

# The client: screenshots cut through the ground, then Stop and Play
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
C=$t/c1.cmd CL=$t/c1.log
mkfifo "$C"
sleep 900 > "$C" &
FEED=$!
CHECK_PIDS+=($FEED)
env DISPLAY="$d" WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=wvboss \
	BUILDAT_JOIN_CODE="$code" bin/buildat -C "$t/cc" -D "$t/cu" -s localhost:$SERVER_PORT \
	-w 960x600 -l 3 -o sound_mute=1 -c - < "$C" > "$CL" 2>&1 &
CLI=$!
CHECK_PIDS+=($CLI)
wait_for_log "$CL" "Joined as wvboss" 120 || fail "the client did not join ($CL, $SL)"
echo 'wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don*"' > "$C"
wait_for_log "$CL" "kit: rts: the camera on" 60 || fail "no rts camera ($CL)"
shot() # <file> <cut log>
{
	printf 'frames 60\nscreenshot %s\nevent kit_rts\n' "$1" > "$C"
	wait_for_log "$CL" "$2" 30 || fail "no cut \"$2\" ($CL)"
	for i in $(seq 100); do [ -s "$1" ] && return 0; sleep 0.2; done
	fail "no screenshot $1 ($CL)"
}
echo 'event kit_rts_focus 0 -6 0
keypress PageUp' > "$C"
shot "$t/cut_high.png" "kit: rts: the cut at -3.5"
# (a wheel event moves the cut a metre, whatever its size)
{
	echo 'keydown shift'
	for i in 1 2 3 4 5 6; do printf 'frames 2\nmouse_wheel -1\n'; done
	echo 'frames 2
keyup shift'
} > "$C"
shot "$t/cut_low.png" "kit: rts: the cut at -9.5"
echo 'keypress F6
wait_log 10000 kit editor: edit rights: yes
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by wvboss)
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by wvboss)' > "$C"
for i in $(seq 300); do
	[ "$(grep -ac "wv before tunnel: " "$SL")" -ge 2 ] && break
	kill -0 "$SERVER_PID" 2>/dev/null || fail "the server is gone ($SL)"
	sleep 0.2
done
[ "$(grep -ac "wv before tunnel: " "$SL")" -ge 2 ] || fail "no second round ($SL, $CL)"
echo quit > "$C"
kill "$FEED" 2>/dev/null
wait "$CLI" 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null

python3 -I - "$SL" <<'PY' || fail "the run ($SL)"
import re, sys
s = open(sys.argv[1], errors="replace").read()
layers = {}
for m in re.finditer(r"wv layer (-?\d+): asym (\d+) (.*)", s):
	y = int(m.group(1))
	if y in layers:
		continue
	n = dict((k, int(v)) for k, v in (kv.rsplit("=", 1) for kv in m.group(3).split()))
	layers[y] = (int(m.group(2)), n)
assert sorted(layers) == list(range(-26, 3)), sorted(layers)
for y, (asym, n) in sorted(layers.items()):
	assert asym == 0, ("not point-symmetric", y, asym)
	assert sum(n.values()) == 4096, (y, n)
	if y >= 1:
		assert n == {"air": 4096}, (y, n)
	elif y == 0:
		assert "air" not in n and "" not in n, ("the top not solid", n)
	elif y <= -24:
		assert n == {"kit/hard_rock": 4096}, ("the floor", y, n)
tot = {}
for y in range(-23, 1):
	for k, v in layers[y][1].items():
		tot[k] = tot.get(k, 0) + v
ground = sum(v for k, v in tot.items() if k != "air")
share = lambda k: tot.get(k, 0) / ground
print("the ground y -23..0: %d cells, %s" % (ground, ", ".join("%s %.1f%%" % (k, 100 * share(k))
	for k in sorted(tot) if k != "air")))
rooms = 2 * 8 * 3 * 8
caves = tot.get("air", 0) - rooms
print("caverns: %d air cells past the rooms' %d" % (caves, rooms))
assert 0.15 < share("kit/dirt") < 0.55, "soil"
assert 0.30 < share("kit/stone") < 0.70, "rock"
assert 0.03 < share("kit/hard_rock") < 0.25, "hard rock"
assert 0.005 < share("kit/ore") < 0.06, "ore"
assert caves > 0.01 * 64 * 64 * 24 and share("kit/gravel") > 0.005, "caverns"
# soil commoner near the top than deep
top = sum(layers[y][1].get("kit/dirt", 0) for y in range(-5, 1))
deep = sum(layers[y][1].get("kit/dirt", 0) for y in range(-23, -17))
assert top > deep * 1.3, ("soil near the top", top, deep)
m = re.search(r"wv bad write: \(-10, -5, 0\) (\S+) -> (\S+)", s)
assert m and m.group(1) == m.group(2) and m.group(1) != "air", ("the bad write", m and m.groups())
assert re.search(r"set_voxels_at refused: cell 2: a voxel's name|set_voxels_at refused: no voxel kit/nonesuch", s), "no refusal"
assert "wv dug: 128 of 128 air" in s, "the tunnel"
assert re.search(r"Entity 7's workbench/wv_dig set 192 cells of the World", s), "the dig's write"
# The unit: short of room B first, then through the tunnel
ways = re.findall(r"Entity 10: workbench/wv_go's way to [^\n]*", s)
assert ways and ways[0].endswith("(towards it)"), ("a way before the dig", ways[:2])
dig = s.index("wv dug: ")
arr = re.search(r"Entity 10 stopped at \(([-\d.]+), ([-\d.]+), ([-\d.]+)\): arrived", s[dig:])
assert arr and float(arr.group(1)) > 16, ("arrived in room B", arr and arr.groups())
print("the unit's ways: %s ... %s; arrived at (%s)" % (ways[0][-60:], ways[-1][-40:],
	", ".join(arr.groups())))
b = re.findall(r"wv before tunnel: ([^\n]*)", s)
assert len(b) >= 2 and b[0] == b[1], ("the cells after Stop", b[:2])
air = re.search(r"\bair=(\d+)", b[0].split("|")[0])
assert not air or int(air.group(1)) <= 8, ("the tunnel's cells before (the rooms' ends only)", b[0])
print("before the dig and after Stop: " + b[0].split("|")[0])
PY
verdict_keep
ls "$t"/cut_*.png
[ "$verdict_rc" = 0 ] && echo "PASS: the underground World (its top, floor, three hardnesses, ore, caverns, point symmetry) read by c:voxels_at; a bad write refused whole; a tunnel dug by c:set_voxels_at and walked by a native unit; Stop put it back ($t)"
verdict_exit
