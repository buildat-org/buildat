#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-12)
# covers: builtin/luanti/client_lua/module.lua builtin/luanti/client_lua/client.lua apps/vanilla/main/client_lua/init.lua
# [SOUND_GAIN_LUANTI]: positioned sounds at Luanti's gain, min(1, 3 g /
# max(d, 1)) by the distance from the ear. The minimal game with a mod
# of one sound; a fixture, the player held still looking +z:
#   1. the sound at gain 1 played 1, 3 and 10 nodes aside from the eye,
#      and at gain 0.5 10 nodes off: heard at 1, 1, 0.3 and 0.15;
#   2. a node of the fixture's with a dug sound of gain 0.4 in front of
#      the player, dug: the player's own, in the head at 0.4.
# By the client's debug log of the gain each sound is started at; the
# user listens once to VoxeLibre's music against its digging.
#   util/sound_gain_luanti_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp sound_gain_luanti; t=$CHECK_TMP
d=$t/srv
g=$d/shared/vanilla/games/sg
mkdir -p "$d/apps/vanilla/saves/sg/luanti" "$(dirname "$g")"
cp -r "$here/builtin/luanti/minimal_game" "$g"
mkdir -p "$g/mods/sg/sounds"
echo "name = sg" > "$g/mods/sg/mod.conf"
cp "$here/apps/featuretest/main/client_data/fire_small.ogg" "$g/mods/sg/sounds/sg_test.ogg"
cat > "$g/mods/sg/init.lua" <<'L'
-- The minimal game has no hand: one that digs the box
core.register_item(":", {type = "none", tool_capabilities = {
	groupcaps = {cracky = {times = {[3] = 0.3}, uses = 0}}}})
core.register_node("sg:box", {description = "Box", tiles = {"floor.png"},
	groups = {cracky = 3}, sounds = {dug = {name = "sg_test", gain = 0.4}}})
L
printf "enable_damage = false\n" > "$d/apps/vanilla/saves/sg/luanti/world.mt"
cat > "$d/shared/fixture.lua" <<'L'
local EYE = 1.625
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0, speed = 0})
	core.after(6, function()
		local p = core.get_player_by_name(name)
		if not p then return end
		local at = vector.round(p:get_pos())
		at.y = at.y + 20
		p:set_pos(at)
		p:set_look_horizontal(0)
		p:set_look_vertical(0)
		core.after(2, function()
			local steps = {{1, 1}, {3, 1}, {10, 1}, {10, 0.5}}
			for i, s in ipairs(steps) do
				core.after(i, function()
					core.sound_play("sg_test", {gain = s[2],
						pos = {x = at.x + s[1], y = at.y + EYE, z = at.z}})
					core.log("warning", "sg: played at " .. s[1] .. " gain " .. s[2])
				end)
			end
			core.after(#steps + 1, function()
				core.set_node({x = at.x, y = at.y + 2, z = at.z + 1}, {name = "sg:box"})
				core.chat_send_player(name, "sg: dig")
			end)
		end)
	end)
end)
L
BUILDAT_LUANTI_GAME=sg BUILDAT_LUANTI_SAVE=sg BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" \
	start_server "$t/srv.log" "STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" -C "$t/srv.cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
printf "wait_log 120000 chat: sg: dig\ndelay 1500\nevent scan 1 dig\nmouse_down left\ndelay 4000\nmouse_up left\ndelay 1000\nquit\n" > "$t/cmds"
run_client 60 "$t/c.log" timeout 200 "$here/Build/bin/buildat" -C "$t/c" -D "$t/u" \
	-w 800x450 -l 5 -o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" -c @"$t/cmds"
grep -aq "Command sequence complete" "$t/c.log" || fail "the drive ($t/c.log)"
python3 - "$t/c.log" <<'PY' || fail "the gains ($t/c.log)"
import re, sys
got = re.findall(r"luanti:sound: \S*sg_test\S* gain ([\d.]+) (\w+) heard at ([\d.]+)",
        open(sys.argv[1], errors="replace").read())
print("gain, where, heard: %s" % got)
want = [("1.000", "pos", 1.0), ("1.000", "pos", 1.0), ("1.000", "pos", 0.3),
        ("0.500", "pos", 0.15), ("0.400", "local", 0.4)]
assert len(got) == len(want), "%d sounds, not %d" % (len(got), len(want))
for (g, w, h), (wg, ww, wh) in zip(got, want):
    assert g == wg and w == ww and abs(float(h) - wh) < 0.01, (g, w, h)
PY
echo "PASS: positioned sounds at Luanti's gain by the distance, the player's own dig in the head at its gain"
