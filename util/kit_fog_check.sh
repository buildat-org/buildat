#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-24)
# covers: builtin/kit/kit.cpp builtin/replicate/replicate.cpp builtin/kit/client_lua/rts.lua builtin/kit/client_lua/module.lua builtin/kit/client_data/KitVoxel.glsl builtin/kit/types/unit.lua builtin/kit/types/game_rules.lua
# [KIT_RTS] (kit_plan 4z37zzo) Fog of war on a Workbench save of the check's
# own: kit/game_rules' fog on, 30 Blue units (sight 8) at x -16..-6 and 30
# Red at x 6..16 (kit/part, kit/unit_walker, kit/unit), a kit/part under
# Red 40-44 (70-74) and under Blue 10 (75), Red 69 walking to and fro far
# off; the player joins Blue (a check type's on_join), kit/controls' camera
# "rts". One scripted client on a headless weston's Xwayland; the entities
# it has by "event kit_rts_nodes":
#   - at the start: Blue's 30 and 75, no Red one nor 70-74, at each look
#     from the join on; no Red one's kit:track ("a track for entity") before
#     the order (the join's window: a teamless peer sees all);
#   - the Blue units ordered next to Red (a box, a right click): Red 40 and
#     its part 70 come; 69 does not;
#   - ordered away again: 40-74 gone;
#   - no kit:track for 69 reached it ("a track for entity 69");
#   - the darkening (kit: rts: fog on, its circles), screenshot $t/fog.png.
# Then the same save with fog off, a second client: every Red one there,
# 69's track too. The server's meter: the fog's ms a tick (BUILDAT_KIT_METER)
# and the recorder's frames with it and without.
#   util/kit_fog_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_fog; t=$CHECK_TMP
cd "$here/Build"
check_build
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1 SDL_AUDIODRIVER=dummy
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1 BUILDAT_KIT_METER=1
export BUILDAT_WORKBENCH_TYPES=$t/user/apps/workbench/check_types
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
# The player joins Blue (entity 4) as they come in
cat > "$BUILDAT_WORKBENCH_TYPES/fog_join.lua" <<'EOF'
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
# Red 69 walks between x 13 and 19 at z 10, far from where Blue goes
cat > "$BUILDAT_WORKBENCH_TYPES/fog_patrol.lua" <<'EOF'
return {
	version = 1,
	about = {what = "A check's: walks to and fro."},
	component = true,
	creature = true,
	state = {leg = {default = 0}},
	on_start = function(c)
		c:after(0.5, "go")
	end,
	on_timer = function(c)
		c.state.leg = 1 - c.state.leg
		c:propose_move({to = {13 + 6 * c.state.leg, 1, 10}, range = 0.3})
		c:after(3, "go")
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
cp "$db" "$t/empty.sqlite"
# compose <fog: 1 or 0>: the save written
compose()
{
	cp "$t/empty.sqlite" "$db"
	python3 -I - "$db" "$1" <<'PY' || fail "the save ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
fog = sys.argv[2] == "1"
ents = [{"id": 2, "parent": 1, "name": "world", "kind": "scene"},
	{"id": 3, "parent": 2, "name": "start", "pos": [0, 1, 0],
		"components": [{"type": "kit/spawner", "params": {"players": True}}]},
	{"id": 9, "parent": 2, "name": "join",
		"components": [{"type": "workbench/fog_join"}]},
	{"id": 8, "parent": 2, "name": "rules",
		"components": [{"type": "kit/game_rules", "params": {"fog": fog}}]},
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
		unit = {"team": team}
		if team == "Blue":
			unit["sight"] = 8
		comps = [{"type": "kit/part", "params": {"size": [0.8, 0.6, 0.8], "color": color, "collision": False}},
			{"type": "kit/unit_walker"}]
		if nid == 69:
			comps.append({"type": "workbench/fog_patrol"})
		comps.append({"type": "kit/unit", "params": unit})
		x, z = x0 + 2 * (i % 6), -4 + 2 * (i // 6)
		if nid == 69:
			x, z = 16, 10
		ents.append({"id": nid, "parent": 2, "name": "%s%d" % (team, i),
			"pos": [x, 1, z], "components": comps})
		nid += 1
# The parts on top of Red 40-44 and Blue 10
for parent in (40, 41, 42, 43, 44, 10):
	ents.append({"id": nid, "parent": parent, "name": "cap%d" % parent, "pos": [0, 0.5, 0],
		"components": [{"type": "kit/part", "params": {"size": [0.3, 0.3, 0.3],
			"color": "#ffd020", "collision": False}}]})
	nid += 1
def put(k, v):
	db.execute("insert or replace into store (store, key, value) values (?, ?, ?)",
		("kit", k, json.dumps(v).encode()))
put("authored", {"kit": 1, "api": 1, "next_id": nid, "entities": ents})
put("session", {"by": "", "restore": [], "round": [], "running": True})
db.execute("delete from store where store = ? and key = ?", ("kit", "runtime"))
db.commit()
PY
}

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

sock=bfog-$$
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

# run <name> <server log>: the server on the save and a client joined as name
# (C, CL, CLI, FEED set)
run()
{
	start_server "$2" "Hosted: |Not hosted: " 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$U" -l 3 ||
		fail "the server did not come up ($2)"
	grep -aq "Not hosted: " "$2" && fail "not hosted ($2)"
	wait_for_log "$2" "setup code [A-Z0-9]+" 30
	local code
	code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$2" | head -1)
	[ -n "$code" ] || fail "no setup code ($2)"
	C=$t/$1.cmd CL=$t/$1.log
	mkfifo "$C"
	sleep 900 > "$C" &
	FEED=$!
	CHECK_PIDS+=($FEED)
	env DISPLAY="$d" WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=$1 \
		BUILDAT_JOIN_CODE="$code" bin/buildat -C "$t/cc" -D "$t/cu-$1" \
		-s localhost:$SERVER_PORT -w 960x600 -l 3 -o sound_mute=1 -c - < "$C" > "$CL" 2>&1 &
	CLI=$!
	CHECK_PIDS+=($CLI)
	wait_for_log "$CL" "Joined as $1" 120 || fail "the client did not join ($CL, $2)"
	echo 'wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don*"' > "$C"
	wait_for_log "$CL" "kit: rts: the camera on" 60 || fail "no rts camera ($CL)"
	wait_for_log "$2" "joins team Blue" 30 || fail "$1 did not join Blue ($2)"
}
stop()
{
	echo quit > "$C"
	kill "$FEED" 2>/dev/null
	wait "$CLI" 2>/dev/null
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
# nodes: "event kit_rts_nodes" sent and its line waited for; the ids in NODES
nodes()
{
	local n=$(($(lines "$CL" "kit: rts: nodes ") + 1)) i
	printf 'frames 2\nevent kit_rts_nodes\n' > "$C"
	for i in $(seq $((${1:-20} * 5))); do
		if [ "$(lines "$CL" "kit: rts: nodes ")" -ge "$n" ]; then
			NODES=" $(grep -a "kit: rts: nodes " "$CL" | tail -1 | sed 's/.*: //') "
			return 0
		fi
		sleep 0.2
	done
	fail "no kit_rts_nodes line ($CL)"
}
has() { case "$NODES" in *" $1 "*) return 0;; esac; return 1; }
# wait_nodes <shell test> <seconds>: nodes() until it holds
wait_nodes()
{
	local i
	for i in $(seq $(($2 * 2))); do
		nodes
		eval "$1" && return 0
		sleep 0.3
	done
	return 1
}
red_in() { local id; for id in $(seq 40 74); do has $id && echo -n "$id "; done; }
# some 10 s of frames for the recorder's perf rows (one each 5 s)
frames() { printf 'frames 600\n' > "$C"; nodes 120; }

# ---- Fog on
U=$t/user
compose 1

SL=$t/srv.log
run fogboss "$SL"
# (from the join on, each look: no Red one drawn; and no Red track ever came
# before the order below, which is what a teamless pass at the join sent)
red_tracks() { grep -aoE "a track for entity (4[0-9]|5[0-9]|6[0-9]|7[0-4])$" "$CL" | grep -o "[0-9]*$" | tr '\n' ' '; }
wait_nodes '[ -z "$(red_in)" ] || fail "Red ones on the client at the start: $(red_in)"
	has 39 && has 75' 20 || fail "Blue's units not all there: $NODES"
wait_for_log "$CL" "kit: rts: fog on" 30 || fail "the client's fog not on ($CL)"
wait_for_log "$CL" "kit: rts: fog: [0-9]+ sight circles" 30 || fail "no sight circles ($CL)"
nodes
for id in $(seq 10 39) 75; do has $id || fail "Blue's $id not on the client: $NODES"; done
[ -z "$(red_in)" ] || fail "Red ones on the client at the start: $(red_in)"
[ -z "$(red_tracks)" ] || fail "Red tracks reached the client at the start: $(red_tracks)($CL)"
echo "start: Blue's 31 there, no Red one"
printf 'frames 30\nscreenshot %s\n' "$t/fog_start.png" > "$C"
# The Blue units next to Red: a box over the view, an order at (0, 0.5, 0)
printf 'mouse_pos 4 4\nmouse_down left\nframes 3\nmouse_pos 956 596\nframes 3\nmouse_up left\n' > "$C"
wait_for_log "$CL" "kit: rts: selected 30 \(box" 20 || fail "the box did not select Blue's 30 ($CL)"
printf 'frames 3\nevent kit_click_at 0 0.5 0 right\n' > "$C"
wait_for_log "$SL" "Order by fogboss: 30 units to" 20 || fail "no order ($SL)"
wait_nodes 'has 40 && has 70' 40 || fail "Red 40 and its part 70 did not come: $NODES ($CL)"
echo "near: Red on the client: $(red_in)"
has 69 && fail "Red 69 (far off) came too: $NODES"
await_n "$SL" ": arrived" 20 40
printf 'frames 30\nscreenshot %s\n' "$t/fog.png" > "$C"
wait_nodes 'has 40' 10 || fail "Red 40 gone while Blue is next to it: $NODES"
grep -a "kit: rts: fog: [0-9]* sight circles" "$CL" | tail -1
# Away again
printf 'frames 3\nevent kit_click_at -12 0.5 0 right\n' > "$C"
a0=$(lines "$SL" ": arrived")
wait_for_log "$SL" "Order by fogboss: 30 units to -12" 20 || fail "no second order ($SL)"
wait_nodes '[ -z "$(red_in)" ]' 40 || fail "Red ones stayed: $(red_in) ($CL)"
echo "away: no Red one on the client"
grep -aq "a track for entity 69$" "$CL" && fail "69's track reached the client ($CL)"
grep -aE "Entity 69 stopped at" "$SL" | head -2
grep -aqE "Entity 69 stopped at" "$SL" || fail "69 did not walk ($SL)"
frames
stop
cp "$db" "$t/after_fog.sqlite"
fogms=$(grep -a "phases: ms a tick" "$SL" | grep -oP 'fog \K[0-9.]+' | tail -n +2)
[ -n "$fogms" ] || fail "no meter's phases with fog ($SL)"
echo "fog's ms a tick (5 s means): $(echo $fogms)"
grep -a "meter: " "$SL" | tail -2

# ---- Fog off: the same save, everything sent
# (a fresh user directory for a setup code; the check types under it)
U=$t/user2 db=$t/user2/apps/workbench/saves/world/save.sqlite
mkdir -p "$(dirname "$db")"
cp -r "$BUILDAT_WORKBENCH_TYPES" "$U/apps/workbench/check_types"
export BUILDAT_WORKBENCH_TYPES=$U/apps/workbench/check_types
compose 0
SL2=$t/srv_off.log
run fogoff "$SL2"
wait_nodes 'has 40 && has 69 && has 74' 30 || fail "with fog off not every Red one: $NODES ($CL)"
for id in $(seq 40 74); do has $id || fail "fog off: $id not on the client: $NODES"; done
grep -aq "kit: rts: fog on" "$CL" && fail "the fog on with game_rules' fog off ($CL)"
wait_for_log "$CL" "a track for entity 69$" 30 || fail "fog off: no track for 69 ($CL)"
printf 'frames 30\nscreenshot %s\n' "$t/nofog.png" > "$C"
frames
stop
offms=$(grep -a "phases: ms a tick" "$SL2" | grep -oP 'fog \K[0-9.]+' | tail -n +2)
echo "fog off: its ms a tick: $(echo $offms)"

# The recorder's frames (a report each 5 s), fog on and off
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
    for l in s.splitlines():
        try:
            j = json.loads(l)
        except ValueError:
            continue
        rows += j if isinstance(j, list) else [j]
pf = [r for r in rows if isinstance(r, dict) and r.get("kind") == "perf" and "draws" in r]
assert pf, "no perf rows"
print("%s: %s" % (sys.argv[2], ", ".join("%.0f fps, %d draws, Kit %.2f ms" %
    (r["fps"], r["draws"], r["kit_ms"]) for r in pf[-3:])))
PY
}
perf "$t/after_fog.sqlite" "fog on" > "$t/perf" || fail "no perf with fog ($t)"
perf "$db" "fog off" >> "$t/perf" || fail "no perf without fog ($t)"
cat "$t/perf"
echo "PASS: fog of war: Blue's own only at the start, Red 40 and its part sent as Blue came near and gone as it left, no track of a hidden walker, the darkening's circles; fog off: all sent ($t)"
