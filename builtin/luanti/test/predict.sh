#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: broken
# broken: back to full; look: the camera does not follow the mouse; dev's
#   reruns fail too (predict_reruns.txt) (local/runs/dev_baseline)
# [PREDICTION]: the vanilla client writes a dug or placed node before the
# server answers, and the server's answer overwrites it. A player on the
# episode fixture's platform, dirt in hand, clicking on the platform
# diagonally down: a place, a dig, and then the same two with everything
# protected -- refused by the server, so the predicted node has to snap
# back. The client's cube of voxels is read on the click's own frame
# (the prediction) and again after the round trip (the server's word);
# the dirt count in it is what is compared, and the last two lines are
# the verdict. The log is under local/predict/.
#
#   GAME=mineclone2 builtin/luanti/test/predict.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
GAME="${GAME:-mineclone2}"
out="$here/local/predict"
mkdir -p "$out"
save="buildat_test_predict"
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running"; exit 77
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
cat > "$out/fixture.lua" <<'LUA'
local ORIGIN = {x = 0, y = 120, z = 0}
core.settings:set("time_speed", "0")
core.settings:set("mobs_spawn", "false")
local function node_named(word)
	local found = {}
	for name, def in pairs(core.registered_nodes) do
		if name:find(word, 1, true) and not name:find("with", 1, true)
				and def.drawtype == "normal" then
			found[#found + 1] = name
		end
	end
	table.sort(found)
	return found[1]
end
local dirt = nil
core.register_on_mods_loaded(function()
	dirt = node_named("dirt")
	core.log("action", "predict: dirt is " .. tostring(dirt))
end)
-- Everything protected once a place and a dig have gone through: the
-- second pair is refused, which is what the snap-back needs
local placed, dug = 0, 0
local old_is_protected = core.is_protected
function core.is_protected(pos, name)
	if placed >= 1 and dug >= 1 then
		return true
	end
	return old_is_protected(pos, name)
end
-- By the player: a mod placing and digging at load (mcl_amethyst does)
-- is not the click
core.register_on_placenode(function(pos, node, placer)
	if not (placer and placer:is_player()) then return end
	placed = placed + 1
	core.log("action", "predict: placed " .. node.name .. " at " ..
			core.pos_to_string(pos))
end)
core.register_on_dignode(function(pos, node, digger)
	if not (digger and digger:is_player()) then return end
	dug = dug + 1
	core.log("action", "predict: dug " .. node.name .. " at " ..
			core.pos_to_string(pos))
end)
core.register_on_joinplayer(function(player)
	local air = core.get_content_id("air")
	local cid = core.get_content_id(dirt)
	local p1 = vector.subtract(ORIGIN, 3)
	local p2 = vector.add(ORIGIN, 3)
	local vm = VoxelManip(p1, p2)
	local emin, emax = vm:get_emerged_area()
	local area = VoxelArea(emin, emax)
	local data = vm:get_data()
	for i in area:iterp(p1, p2) do
		data[i] = air
	end
	for x = -2, 2 do
		for z = -2, 2 do
			data[area:index(ORIGIN.x + x, ORIGIN.y, ORIGIN.z + z)] = cid
		end
	end
	vm:set_data(data)
	vm:write_to_map()
	player:set_pos({x = ORIGIN.x, y = ORIGIN.y + 1, z = ORIGIN.z})
	-- No fall for a client that has not got the platform yet (2026-10-13:
	-- one fell to y -35 before it came). Through VoxeLibre's playerphysics
	-- where it is there: its elytra code sets the product of the gravity
	-- factors every step, which put a plain override back to 1
	if playerphysics then
		playerphysics.add_physics_factor(player, "gravity", "predict", 0)
	else
		player:set_physics_override({gravity = 0})
	end
	player:get_inventory():set_stack("main", 1, dirt .. " 10")
	player:set_wield_index(1)
	core.log("action", "predict: player on the platform with " .. dirt)
end)
LUA
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$out/srv.log" "Mods loaded" 400 29778 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l "${LOG_LEVEL:-3}" ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap 'kill -INT "$srv" 2>/dev/null' EXIT
# Each act: the click, the cube a frame or two after it (before the
# server can have answered) and the cube after the round trip. A dig
# completes inside the hold, so its "now" is the log's order instead:
# the predicted line before the chunk's next update from the server. The
# hold is let go at that predicted line.
# simplified: the server's answer is waited for by time (2 s, 1 s after a
# dig): node updates stream in all through the run, and nothing on the
# client says which one is the answer to the click. A line where a
# predicted voxel is written over by the server's would be the event
# The fixture's move onto the platform waited for, not the spawn: after
# the spawn's settle the platform was not there yet and the player fell
cat > "$out/cmds.txt" <<CMDS
wait_log_any 60000 the server put the player at 0.0, 121.0, 0.0
wait_log 60000 scene, 0 undrawn within 2
# a settle after the line: the player lands on the platform
delay 2000
look_dir 1 -1 0
# the pointed node follows the aim on the frames after it (here and below)
delay 300
event scan_volume 2 t0
mouse_click right
wait_log 5000 predicted
event scan_volume 2 place_now
# simplified: the server's answer, by time (see above)
delay 2000
event scan_volume 2 place_after
look_dir 1 -1 0
delay 300
mouse_down left
wait_log 10000 predicted air at
mouse_up left
# simplified: the server's answer, by time
delay 1000
event scan_volume 2 dig_after
look_dir 1 -1 0
delay 300
mouse_click right
wait_log 5000 predicted
event scan_volume 2 refused_place_now
# simplified: the server's refusal, by time
delay 2000
event scan_volume 2 refused_place_after
look_dir 1 -1 0
delay 300
mouse_down left
wait_log 10000 predicted air at
mouse_up left
# simplified: the server's refusal, by time
delay 1000
event scan_volume 2 refused_dig_after
quit
CMDS
bin/buildat -s localhost:29778 -w 1280x720 -l "${CLIENT_LOG_LEVEL:-4}" \
	-c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	{ echo "FAIL: the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"; exit 1; }
kill -INT "$srv" 2>/dev/null
# a poll: the server's exit
for i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
grep "predict:" "$out/srv.log" | sed 's/.*predict: /server: /'
grep "predicted " "$out/cli.log" | grep -v wait_log | sed 's/.*vanilla *: /client: /'
# The dirt count per cube: the platform's 25, the placed one on top; and
# for the digs, the predicted line ahead of the server's answer
python3 - "$out/cli.log" <<'PY'
import re, sys
counts = {}
names = {}
order = []
for line in open(sys.argv[1]):
    m = re.search(r"scan (\S+): voxel names (.*)", line)
    if m:
        names[m.group(1)] = {int(k): v for k, v in re.findall(r"(\d+)=(\S+)", m.group(2))}
    m = re.search(r"scan (\S+): voxels y=-?\d+ z=-?\d+ x=-?\d+: (.*)", line)
    if m:
        label = m.group(1)
        dirt = [i for i, n in names.get(label, {}).items() if "dirt" in n]
        counts[label] = counts.get(label, 0) + sum(1 for w in m.group(2).split() if int(w) in dirt)
    # Not the drive's own waits for it
    if "wait_log" in line:
        continue
    if "predicted air at" in line:
        order.append("dig")
    elif "voxelworld:node_volume_updated" in line:
        order.append("update")
labels = ["t0", "place_now", "place_after", "dig_after",
          "refused_place_now", "refused_place_after", "refused_dig_after"]
print("dirt in the cube: " + ", ".join("%s=%s" % (k, counts.get(k, "-")) for k in labels))
base = counts.get("t0", 0)
want = {"place_now": base + 1, "place_after": base + 1, "dig_after": base,
        "refused_place_now": base + 1, "refused_place_after": base,
        "refused_dig_after": base}
bad = [k for k, v in want.items() if counts.get(k) != v]
digs = sum(1 for i, w in enumerate(order) if w == "dig" and i + 1 < len(order) and order[i + 1] == "update")
print("digs predicted ahead of the server's answer: %d of 2" % digs)
if digs != 2:
    bad.append("digs")
# **The contract's own words and its own status** ([CI_RUNS] (1)):
# "PASSED"/"FAILED" is not what run_all.sh reads, so this run had no
# verdict anybody could see and its exit status was the python's
# (2026-09-25)
if bad or base <= 0:
    print("FAIL: " + (", ".join(
        k == "digs" and "digs predicted ahead of the answer wanted 2"
        or "%s wanted %d" % (k, want[k]) for k in bad)
        or "no dirt in the cube at all, so nothing was measured"))
    raise SystemExit(1)
print("PASS: a place and a dig are predicted, and a refusal snaps back")
PY
