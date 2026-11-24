#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-24)
# covers: builtin/kit/client_lua/rts.lua builtin/kit/client_lua/controls.lua builtin/kit/types/unit.lua builtin/kit/kit.cpp builtin/kit/client_data/KitVoxel.glsl builtin/kit/client_lua/environment.lua
# [KIT_RTS] (kit_plan 4z37zzn) kit/controls' rts camera on a Workbench save of
# the check's own: 30 Blue and 30 Red native units (kit/part, kit/unit_walker,
# kit/unit with kit/bow, kit/health), a stone hut with a roof, no sun nor
# moon and kit/environment's fill; the player joins Blue (a check type's
# on_join). One scripted client on a headless weston's Xwayland:
#   - a camera alone: the client sends no steps, the server's pose says 16;
#   - a box over the whole view selects the 30 Blue units and no Red one;
#   - an order to a point (a right click on the ground): most of them
#     arrive at their spots about it;
#   - Ctrl+1 keeps them as group 1, a click on nothing clears the selection,
#     1 takes the group again;
#   - a right click on a Red unit: the Blue ones go to it and shoot it
#     (c:fire: hits with hit.unit);
#   - the camera zooms (the wheel), turns (a right drag), pans (a middle
#     drag, W) and cuts (PageDown, Shift and the wheel, Home), each logged
#     and screenshot ($t/*.png, KEEP_TMP=1);
#   - the recorder's perf (draws, Kit ms) with the 60 units in view.
# Then the web client in headless Firefox (skipped without it or web/): the
# same save, box select, an order, the recorder's perf.
#   util/kit_rts_controls_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_rts_controls; t=$CHECK_TMP
cd "$here/Build"
check_build
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1 SDL_AUDIODRIVER=dummy
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_WORKBENCH_TYPES=$t/user/apps/workbench/check_types
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
# The player joins Blue (entity 4) as they come in
cat > "$BUILDAT_WORKBENCH_TYPES/rts_join.lua" <<'EOF'
return {
	version = 1,
	about = {what = "A check's: the player joins Blue."},
	component = true,
	params = {team = {type = "entity", default = 4}},
	on_join = function(c, by)
		c:send(c.params.team, "join", nil, by)
	end,
}
EOF
# A stone hut with a plank roof (y 1-3 walls, 4 the roof), a door in its
# south: a box of cells from its entity's (-4, 1, -18)
cat > "$BUILDAT_WORKBENCH_TYPES/rts_hut.lua" <<'EOF'
return {
	version = 1,
	about = {what = "A check's hut."},
	component = true,
	voxel_box = "size",
	params = {size = {type = "position", default = {9, 4, 7}}},
	on_start = function(c)
		local v = {}
		for x = 0, 8 do
			for z = 0, 6 do
				for y = 0, 2 do
					local wall = x == 0 or x == 8 or z == 0 or z == 6
					if wall and not (z == 6 and x == 4 and y <= 1) then
						v[#v + 1] = {x, y, z, "kit/stone"}
					end
				end
				v[#v + 1] = {x, 3, z, "kit/planks"}
			end
		end
		c:set_voxels(v)
		c:log("hut built: " .. #v)
	end,
}
EOF
# A Red unit's hits logged with the shooter
cat > "$BUILDAT_WORKBENCH_TYPES/rts_target.lua" <<'EOF'
return {
	version = 1,
	about = {what = "A check's: its hits logged."},
	component = true,
	modify_hit = function(c, hit, by)
		if hit.unit then
			c:log("hit by unit " .. hit.unit)
		end
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
# Blue 10-39 at x -16..-6, Red 40-69 at x 6..16, 6 columns 2 m apart, 5 rows
# along z -4..4; the hut north of the spawn (z -18..-12)
python3 -I - "$db" <<'PY' || fail "the save ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
ents = [{"id": 2, "parent": 1, "name": "world", "kind": "scene"},
	{"id": 3, "parent": 2, "name": "start", "pos": [0, 1, 0],
		"components": [{"type": "kit/spawner", "params": {"players": True}}]},
	{"id": 8, "parent": 2, "name": "hut", "pos": [-4, 1, -18],
		"components": [{"type": "workbench/rts_hut"}]},
	{"id": 9, "parent": 2, "name": "join",
		"components": [{"type": "workbench/rts_join"}]},
	{"id": 4, "parent": 2, "name": "blue", "pos": [0, 1, 2],
		"components": [{"type": "kit/team", "params": {"name": "Blue", "color": "#3060d0"}}]},
	{"id": 5, "parent": 2, "name": "red", "pos": [0, 1, 4],
		"components": [{"type": "kit/team", "params": {"name": "Red", "color": "#d03030"}}]},
	{"id": 6, "parent": 2, "name": "controls",
		"components": [{"type": "kit/controls", "params": {"camera": "rts", "height": 30, "angle": 55}}]},
	{"id": 7, "parent": 2, "name": "env",
		"components": [{"type": "kit/environment", "params": {"sun": False, "moon": False,
			"stars": False, "fill": 0.8}}]}]
nid = 10
for team, x0, color in (("Blue", -16, "#3060d0"), ("Red", 6, "#d03030")):
	for i in range(30):
		comps = [{"type": "kit/part", "params": {"size": [0.8, 0.6, 0.8], "color": color, "collision": False}},
			{"type": "kit/unit_walker"},
			{"type": "kit/unit", "params": {"team": team, "weapon": "kit/bow", "range": 8}},
			{"type": "kit/health", "params": {"max": 1000000}}]
		if team == "Red":
			comps.append({"type": "workbench/rts_target"})
		ents.append({"id": nid, "parent": 2, "name": "%s%d" % (team, i),
			"pos": [x0 + 2 * (i % 6), 1, -4 + 2 * (i // 6)], "components": comps})
		nid += 1
def put(k, v):
	db.execute("insert or replace into store (store, key, value) values (?, ?, ?)",
		("kit", k, json.dumps(v).encode()))
put("authored", {"kit": 1, "api": 1, "next_id": nid, "entities": ents})
put("session", {"by": "", "restore": [], "round": [], "running": True})
db.execute("delete from store where store = ? and key = ?", ("kit", "runtime"))
db.commit()
PY
cp "$db" "$t/save0.sqlite"

lines() { grep -ac "$2" "$1" 2>/dev/null; }
await_n() # <log> <regex> <n> <seconds>
{
	local i
	for i in $(seq $(($4 * 5))); do
		[ "$(lines "$1" "$2")" -ge "$3" ] && return 0
		kill -0 "$SERVER_PID" 2>/dev/null || fail "the server is gone ($1)"
		sleep 0.2
	done
	fail "no $3 lines \"$2\" in $1 in $4 s"
}

sock=brts-$$
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
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
C=$t/c1.cmd CL=$t/c1.log
mkfifo "$C"
sleep 900 > "$C" &
FEED=$!
CHECK_PIDS+=($FEED)
env DISPLAY="$d" WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=rtsboss \
	BUILDAT_JOIN_CODE="$code" bin/buildat -C "$t/cc" -D "$t/cu" -s localhost:$SERVER_PORT \
	-w 960x600 -l 3 -o sound_mute=1 -c - < "$C" > "$CL" 2>&1 &
CLI=$!
CHECK_PIDS+=($CLI)
wait_for_log "$CL" "Joined as rtsboss" 120 || fail "the client did not join ($CL, $SL)"
echo 'wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don*"' > "$C"
wait_for_log "$CL" "kit: rts: the camera on" 60 || fail "no rts camera ($CL)"
wait_for_log "$SL" "joins team Blue" 30 || fail "rtsboss did not join Blue ($SL)"
wait_for_log "$SL" "hut built: " 30 || fail "no hut ($SL)"
# say <command lines>: sent, then an "event kit_rts" and its line waited for
nlog=0
say()
{
	nlog=$(($(lines "$CL" "kit: rts: camera at") + 1))
	printf '%s\nframes 5\nevent kit_rts\n' "$1" > "$C"
	local i
	for i in $(seq 300); do
		[ "$(lines "$CL" "kit: rts: camera at")" -ge "$nlog" ] && return 0
		sleep 0.2
	done
	fail "no kit_rts line after: $1 ($CL)"
}
last_rts() { grep -a "kit: rts: camera at" "$CL" | tail -1; }
say "frames 30
screenshot $t/start.png"
r0=$(last_rts)
echo "start: $r0"

# ---- Selection and orders
n0=$(lines "$CL" "kit: rts: selected")
say "mouse_pos 4 4
mouse_down left
frames 3
mouse_pos 956 596
frames 3
mouse_up left"
grep -a "kit: rts: selected" "$CL" | tail -1
grep -a "kit: rts: selected" "$CL" | tail -1 | grep -q "selected 30 (box" ||
	fail "the box did not select the 30 Blue units ($CL)"
sel=$(last_rts | grep -oP 'selected 30: \K.*')
for id in $sel; do
	[ "$id" -ge 10 ] && [ "$id" -le 39 ] || fail "entity $id selected, not a Blue unit ($CL)"
done
a0=$(lines "$SL" ": arrived")
say "event kit_click_at -10 0.5 16 right"
grep -a "kit: rts: 30 ordered to" "$CL" | tail -1 || fail "no order sent ($CL)"
wait_for_log "$SL" "Order by rtsboss: 30 units to" 10 || fail "the server took no order ($SL)"
await_n "$SL" ": arrived" $((a0 + 24)) 40
say "screenshot $t/arrived.png"
# Group 1, cleared, recalled
say "keydown ctrl
frames 2
keypress 1
frames 2
keyup ctrl"
grep -aq "kit: rts: group 1 set (30)" "$CL" || fail "group 1 not set ($CL)"
say "event kit_click_at 0 0.5 30"
grep -a "kit: rts: selected" "$CL" | tail -1 | grep -q "selected 0 (click on none)" ||
	fail "a click on nothing did not clear the selection ($CL)"
say "keypress 1"
grep -a "kit: rts: selected" "$CL" | tail -1 | grep -q "selected 30 (group 1)" ||
	fail "group 1 not recalled ($CL)"
# A Red unit (40, at 6, 1, -4) as the target
h0=$(lines "$SL" "hit by unit")
say "event kit_click_at 6 1 -4 right"
grep -aq "kit: rts: 30 ordered at entity 40" "$CL" || fail "no target order ($CL)"
wait_for_log "$SL" "Order by rtsboss: 30 units at entity 40" 10 || fail "the server took no target ($SL)"
await_n "$SL" "hit by unit" $((h0 + 3)) 40
grep -aqE "Entity [0-9]+ hits entity 40 with kit/bow" "$SL" || fail "no kit/bow hit on 40 ($SL)"
# ---- Bodyless
last_rts | grep -q "steps 0," || fail "the client sent steps: $(last_rts)"
grep -aq "rtsboss's body" "$CL" && fail "a body drawn for rtsboss ($CL)"

# ---- The camera
say "mouse_pos 480 300
mouse_wheel 3"
r1=$(last_rts)
python3 -I - "$r0" "$r1" <<'PY' || fail "the wheel did not zoom"
import re, sys
d = [float(re.search(r"distance ([0-9.]+)", s).group(1)) for s in sys.argv[1:]]
assert d[1] < d[0] * 0.8, d
print("zoom: distance %.1f -> %.1f" % tuple(d))
PY
say "screenshot $t/zoomed.png
mouse_pos 480 300
mouse_down right
frames 2
mouse_move 60 0
frames 2
mouse_move 60 20
frames 2
mouse_move 60 20
frames 2
mouse_up right"
r2=$(last_rts)
say "screenshot $t/turned.png
mouse_pos 480 300
mouse_down middle
frames 2
mouse_move 0 80
frames 2
mouse_move 0 80
frames 2
mouse_up middle"
r3=$(last_rts)
say "keydown w
delay 700
keyup w"
r4=$(last_rts)
python3 -I - "$r1" "$r2" "$r3" "$r4" <<'PY' || fail "the camera did not turn and pan"
import re, sys
def f(s):
    m = re.search(r"camera at (\S+),(\S+),(\S+), yaw (\S+), pitch (\S+),", s)
    return [float(x) for x in m.groups()]
a, b, c, d = [f(s) for s in sys.argv[1:]]
dy = (b[3] - a[3] + 180) % 360 - 180
assert abs(dy) > 20, ("no turn", a, b)
mv = lambda p, q: ((p[0] - q[0]) ** 2 + (p[2] - q[2]) ** 2) ** 0.5
assert mv(b, c) > 1, ("no middle drag pan", b, c)
assert mv(c, d) > 1, ("W did not pan", c, d)
print("turned %.0f degrees, panned %.1f m by the drag, %.1f m by W" % (dy, mv(b, c), mv(c, d)))
PY
# The cut: round the hut (its floor 0.5, walls to 3.5, the roof to 4.5),
# PageUp (1.5 m over the point and one more: 3.0), a Shift and wheel notch
# down (2.0): the walls cut, the roof gone; Home off and on
say "event kit_rts_focus 0 0.55 -15
keypress PageUp"
last_rts | grep -q "cut 3.0," || fail "PageUp: not the cut at 3.0: $(last_rts)"
say "keydown shift
frames 2
mouse_wheel -1
frames 2
keyup shift
frames 10
screenshot $t/cut.png"
last_rts | grep -q "cut 2.0," || fail "Shift and the wheel: not the cut at 2.0: $(last_rts)"
say "keypress Home
frames 10
screenshot $t/uncut.png"
last_rts | grep -q "cut off" || fail "Home did not take the cut off: $(last_rts)"
say "keypress Home"
last_rts | grep -q "cut 2.0," || fail "Home did not put the cut back: $(last_rts)"
grep -a "kit: rts: the cut" "$CL" | tail -4
# ---- The recorder's perf (a report each 5 s), the 60 units in view: the
# start's point and zoom, the cut off, some 10 s of frames
say "keypress Home
event kit_rts_focus 0 0.55 0
mouse_pos 480 300
mouse_wheel -3
frames 600"
echo quit > "$C"
kill "$FEED" 2>/dev/null
wait "$CLI" 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
perf()
{
	python3 -I - "$1" "$2" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
rows = []
for k, v in db.execute("select key, value from store where store = 'playtest'"):
    if not k.startswith("r/"):
        continue
    s = v.decode(errors="replace") if isinstance(v, bytes) else v
    try:
        j = json.loads(s)
        rows += j if isinstance(j, list) else [j]
    except ValueError:
        rows += [json.loads(l) for l in s.splitlines() if l.strip()]
pf = [r for r in rows if isinstance(r, dict) and r.get("kind") == "perf" and "draws" in r]
assert pf, "no perf rows with draws"
# the last two: the units in view
pf = pf[-2:]
print("%s: %s" % (sys.argv[2], ", ".join("%.0f fps, %d draws, %d tris, Kit %.2f ms" %
    (r["fps"], r["draws"], r["tris"], r["kit_ms"]) for r in pf)))
PY
}
perf "$db" native > "$t/perf" || fail "no native perf ($db)"
cat "$t/perf"

# ---- The web client: the same save, box select, an order, its perf
web="skipped (no Firefox or web/)"
if command -v "${FIREFOX:-firefox}" > /dev/null && [ -f "$here/web/buildat.wasm" ]; then
	w=$t/web
	mkdir -p "$w/user/apps/workbench/saves/world"
	cp "$t/save0.sqlite" "$w/user/apps/workbench/saves/world/save.sqlite"
	cp -r "$BUILDAT_WORKBENCH_TYPES" "$w/user/apps/workbench/"
	export BUILDAT_WORKBENCH_TYPES=$w/user/apps/workbench/check_types
	cat > "$t/steps.json" <<'J'
[
 ["nav", "${URL}"],
 ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "webrts"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Enter"], ["waitlog", "Joined as webrts", 30],
 ["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
 ["click", "Button", "Don't add"], ["frames", 3],
 ["waitlog_any", "kit: rts: the camera on", 60], ["frames", 60],
 ["shot", "${OUT}/start.png"],
 ["drag", 2, 2, 1200, 700],
 ["waitlog_any", "kit: rts: selected 30 \\(box", 10], ["frames", 3],
 ["event", "kit_click_at -10 0.5 16 right"],
 ["waitlog_any", "kit: rts: 30 ordered to", 10],
 ["frames", 600],
 ["event", "kit_rts"], ["waitlog_any", "kit: rts: camera at", 10],
 ["shot", "${OUT}/ordered.png"]
]
J
	"$here/util/web_drive.sh" firefox workbench "$t/steps.json" "$w" ||
		fail "the web drive ($w)"
	grep -aq "Order by webrts: 30 units to" "$w/server.log" || fail "no web order ($w/server.log)"
	perf "$w/user/apps/workbench/saves/world/save.sqlite" web >> "$t/perf" ||
		fail "no web perf ($w)"
	web=$(tail -1 "$t/perf")
fi
cat "$t/perf"
echo "PASS: the rts camera alone (no steps), box select of the 30 Blue units only, an order to a point (arrived), group 1 set and recalled, a Red unit targeted and shot, zoom, turn, pan and the cut; $(head -1 "$t/perf"); $web ($t)"
