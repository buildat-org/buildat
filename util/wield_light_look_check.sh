#!/bin/bash
# tier: full
# cost: ~6 min (2026-10-12)
# covers: builtin/luanti/client_lua/module.lua extensions/luanti_client/res/VoxelUnlitShadow.glsl extensions/luanti_client/res/PBRVoxel.glsl extensions/luanti_client/res/LuantiVoxelUnlit.xml
# [WIELD_LIGHT_LOOK]: the held light as a placed one. VoxeLibre at night,
# a sealed stone room high up, wield_light on; in each of pbr, shadows and
# unlit (the key pinned under pbr):
#   1. The wall ahead at 1, 4, 8 and 12 nodes, a torch held, then the
#      hand empty and a torch placed beside the player: the wall's level
#      in the middle of the picture said for both. Held, the wall darkens
#      with the distance and is lit still at 8 (no edge before the reach);
#      held and placed within a factor of two up to 8.
#   2. A cobblestone in the hand, a dropped item and a pig 2 to 3 nodes
#      ahead: a torch in the offhand lights the hand's corner of the
#      picture, and the objects by their lamp level in the client's log;
#      20 nodes off, the objects at lamp 0 again.
# Needs mineclone2 in the desk's games.
#   util/wield_light_look_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || skip "no mineclone2"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp wield_light_look; t=$CHECK_TMP
STEPS="dark h1 p1 h4 p4 h8 p8 h12 p12 o_dark o_lit o_far"
cat > "$t/fixture.lua" <<'L'
local C = {x = 0, y = 155, z = 0}
-- The inside: x -30..1 (the wall at 2, its face at 1.5), y 0..4, z -3..3
local P1 = vector.add(C, {x = -31, y = -1, z = -4})
local P2 = vector.add(C, {x = 2, y = 5, z = 4})
local function say(s) core.log("warning", "wll: " .. s) end
local function room()
	for z = P1.z, P2.z do for y = P1.y, P2.y do for x = P1.x, P2.x do
		local inside = x > P1.x and x < P2.x and y > P1.y and y < P2.y and
				z > P1.z and z < P2.z
		core.set_node({x = x, y = y, z = z},
				{name = inside and "air" or "mcl_core:stone"})
	end end end
end
local torch = nil
local function unplace()
	if torch then core.remove_node(torch); torch = nil end
end
-- Eye D from the wall's face; a placed torch beside the head, a node
-- nearer the wall, so the flood's path to the wall is D long as well
local function at(p, d)
	p:set_pos({x = C.x + 1.5 - d, y = C.y, z = C.z})
	p:set_look_horizontal(3 * math.pi / 2)
	p:set_look_vertical(0)
end
local function hold(p, item) p:get_inventory():set_stack("main", 1, item or "") end
local function place(d)
	torch = {x = C.x + math.floor(2.5 - d), y = C.y + 1, z = C.z + 1}
	core.set_node(torch, {name = "mcl_torches:torch", param2 = 1})
end
local steps = {
	{"dark", function(p) at(p, 4) end},
}
for _, d in ipairs({1, 4, 8, 12}) do
	steps[#steps + 1] = {"h" .. d, function(p)
		unplace(); at(p, d); hold(p, "mcl_torches:torch") end}
	steps[#steps + 1] = {"p" .. d, function(p) hold(p); place(d) end}
end
steps[#steps + 1] = {"o_dark", function(p)
	unplace(); at(p, 6); hold(p, "mcl_core:cobble")
	-- Out of the player's pick-up reach (1.9 nodes was picked up)
	core.add_item({x = C.x - 1.5, y = C.y + 0.3, z = C.z}, "mcl_core:apple")
	local pig = core.add_entity({x = C.x - 2.5, y = C.y, z = C.z + 1.5}, "mobs_mc:pig")
	say("pig " .. tostring(pig ~= nil))
end}
steps[#steps + 1] = {"o_lit", function(p)
	p:get_inventory():set_stack("offhand", 1, "mcl_torches:torch") end}
steps[#steps + 1] = {"o_far", function(p)
	p:set_pos({x = C.x - 25, y = C.y, z = C.z}) end}
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0, speed = 0})
	core.after(2, function()
		core.emerge_area(P1, P2, function(_, _, left)
			if left > 0 then return end
			room()
			core.set_timeofday(0)
			local i = 0
			local function step()
				local p = core.get_player_by_name(name)
				if not p then return end
				i = i + 1
				if not steps[i] then return end
				steps[i][2](p)
				-- The placed torch's light is the server's to flood and
				-- send; the held one's is the client's at the next lights
				core.after(2.5, function()
					core.chat_send_player(name, "wll: " .. steps[i][1])
					core.after(2, step)
				end)
			end
			core.after(3, step)
		end)
	end)
end)
L
for mode in pbr shadows unlit; do
	d=$t/$mode
	mkdir -p "$d/apps/vanilla/saves/wll/luanti" "$d/shared/vanilla/games"
	cp -r "$G" "$d/shared/vanilla/games/"
	printf "load_mod_wield_light = true\nenable_damage = false\n" > "$d/apps/vanilla/saves/wll/luanti/world.mt"
	echo "{\"render_mode\": \"$mode\"}" > "$d/shared/vanilla/settings.json"
	cp "$t/fixture.lua" "$d/shared/"
	BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=wll \
	BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/$mode.srv.log" \
		"STATUS Listening" 180 auto "$here/Build/bin/buildat_server" \
		-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
		-C "$d.cache" -l 3 || fail "the $mode server ($t/$mode.srv.log)"
	CHECK_PIDS+=($SERVER_PID)
	{
		for s in $STEPS; do
			echo "wait_log 300000 chat: wll: $s"; echo "delay 1000"
			echo "screenshot $t/${mode}_$s.png"
		done
		echo "delay 500"; echo quit
	} > "$t/$mode.cmds"
	BUILDAT_LUANTI_KEY=0.05 run_client 60 "$t/$mode.log" timeout 400 \
		"$here/Build/bin/buildat" -C "$t/c" -D "$t/u_$mode" \
		-s 127.0.0.1:$SERVER_PORT -w 640x360 -u 1 -l 4 -o sound_mute=1 \
		-c @"$t/$mode.cmds"
	kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
	grep -aq "luanti:world_info: .*, $mode$" "$t/$mode.log" || fail "not drawn $mode ($t/$mode.log)"
	grep -aq "Command sequence complete" "$t/$mode.log" || fail "the $mode drive ($t/$mode.log)"
done
python3 - "$t" <<'PY' || fail "the pictures and the objects ($t)"
import re, sys
import numpy as np
from PIL import Image
t = sys.argv[1]
def crop(mode, s, box):
    a = np.array(Image.open("%s/%s_%s.png" % (t, mode, s)).convert("L")).astype(float)
    h, w = a.shape
    return a[int(h * box[1]):int(h * box[3]), int(w * box[0]):int(w * box[2])].mean()
MID = (0.4, 0.35, 0.6, 0.55)
HAND = (0.65, 0.55, 1.0, 0.85)
bad = []
for mode in ("pbr", "shadows", "unlit"):
    w = lambda s: crop(mode, s, MID)
    dark = w("dark")
    held = [w("h%d" % d) - dark for d in (1, 4, 8, 12)]
    placed = [w("p%d" % d) - dark for d in (1, 4, 8, 12)]
    print("%-7s wall over the dark %.1f, held %s, placed %s" % (mode, dark,
            " ".join("%.1f" % v for v in held), " ".join("%.1f" % v for v in placed)))
    if not (held[0] >= held[1] >= held[2] >= held[3]):
        bad.append("%s: held not darker with distance" % mode)
    if held[2] < 1:
        bad.append("%s: held, nothing at 8" % mode)
    for i, d in enumerate((1, 4, 8)):
        if not (placed[i] / 2 <= held[i] <= placed[i] * 2):
            bad.append("%s: held %.1f against placed %.1f at %d" % (mode, held[i], placed[i], d))
    hd, hl = crop(mode, "o_dark", HAND), crop(mode, "o_lit", HAND)
    print("%-7s the hand's corner %.1f, the offhand torch lit %.1f" % (mode, hd, hl))
    if hl < hd + 10:
        bad.append("%s: the hand not lit" % mode)
    # The objects' lamp level, each the last before a step's chat: what
    # the step's picture has
    lamps, seg = {}, {}
    for l in open("%s/%s.log" % (t, mode), errors="replace"):
        m = re.search(r"chat: wll: (\S+)", l)
        if m:
            lamps[m.group(1)] = dict(seg)
        m = re.search(r"luanti: object (\S+) lit at .* lamp (\d+)", l)
        if m:
            seg[m.group(1)] = int(m.group(2))
    # The two the step added; the world has mobs of its own
    new = set(lamps.get("o_dark", {})) - set(lamps.get("p12", {}))
    o = {k: {i: v for i, v in lamps.get(k, {}).items() if i in new}
         for k in ("o_dark", "o_lit", "o_far")}
    print("%-7s the objects' lamp: until lit %s, lit %s, far %s" % (mode,
            o["o_dark"], o["o_lit"], o["o_far"]))
    lit = o["o_lit"]
    if len([v for v in lit.values() if v >= 8]) < 2:
        bad.append("%s: not two objects lit by the torch" % mode)
    far = o["o_far"]
    if not far or any(v != 0 for v in far.values()):
        bad.append("%s: the objects not dark at 20 nodes" % mode)
for b in bad:
    print("FAIL: " + b)
sys.exit(1 if bad else 0)
PY
echo "PASS: a held torch lights the wall as a placed one does, in pbr, shadows and unlit, and the hand and the objects with it"
