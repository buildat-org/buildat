#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-12)
# covers: builtin/luanti/lua/entity.lua apps/vanilla/main/client_lua/init.lua
# [WIELD_SLOT_JOIN]: a join holds slot 1, on the server as on the screen.
# The minimal game, wield_light on, a fixture's lamp item (light 14) in
# slot 3. Join 1 holds slot 3 (key 3) and leaves; join 2: the server's
# slot 1 and no light on the player, then key 3: slot 3 and the lamp's
# light.
#   util/wield_slot_join_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp wield_slot_join; t=$CHECK_TMP
d=$t/srv
mkdir -p "$d/apps/vanilla/saves/wsj/luanti" "$d/shared/vanilla/games"
cp -r "$here/builtin/luanti/minimal_game" "$d/shared/vanilla/games/wsj"
printf "load_mod_wield_light = true\nenable_damage = false\n" > "$d/apps/vanilla/saves/wsj/luanti/world.mt"
cat > "$d/shared/fixture.lua" <<'L'
core.register_craftitem(":wsj:lamp", {description = "Lamp", light_source = 14})
core.register_on_joinplayer(function(player)
	player:get_inventory():set_stack("main", 3, "wsj:lamp")
end)
local said = {}
core.register_globalstep(function()
	for _, p in ipairs(core.get_connected_players()) do
		local name = p:get_player_name()
		local i = p:get_wield_index()
		if said[name] ~= i then
			said[name] = i
			core.log("warning", "wsj: wield " .. i .. " " .. p:get_wielded_item():get_name())
		end
	end
end)
core.register_on_leaveplayer(function(player) said[player:get_player_name()] = nil end)
L
BUILDAT_LUANTI_GAME=wsj BUILDAT_LUANTI_SAVE=wsj BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" \
	start_server "$t/srv.log" "STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" -C "$t/srv.cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
# join <n> <commands after the world is in>
join(){
	printf "wait_log 120000 load: the world is in\ndelay 5000\n%s\ndelay 500\nquit\n" "$2" > "$t/$1.cmds"
	run_client 60 "$t/$1.log" timeout 200 "$here/Build/bin/buildat" -C "$t/c" -D "$t/u" \
		-w 800x450 -l 3 -o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" -c @"$t/$1.cmds"
	grep -aq "Command sequence complete" "$t/$1.log" || fail "join $1 ($t/$1.log)"
}
join 1 "keypress 3
delay 2000"
grep -aq "wsj: wield 3 wsj:lamp" "$t/srv.log" || fail "join 1 not at slot 3 ($t/srv.log)"
n=$(wc -l < "$t/srv.log")
join 2 "keypress 3
delay 2000"
got=$(tail -n +$((n + 1)) "$t/srv.log" | grep -ao "wsj: wield .*" | tr '\n' ';')
echo "join 2, the server: $got"
[ "$got" = "wsj: wield 1 ;wsj: wield 3 wsj:lamp;" ] || fail "join 2's slots ($t/srv.log)"
# The client's lights: none on the player until the key, then the lamp's
python3 - "$t/2.log" <<'PY' || fail "join 2's lights ($t/2.log)"
import re, sys
log = open(sys.argv[1], errors="replace").read()
key = log.index("command: keypress 3")
before = re.findall(r"luanti:lights: .*", log[:key])
after = re.findall(r"luanti:lights: .*", log[key:])
print("before the key: %s; after: %s" % (before[-1:] or "none", after[-1:] or "none"))
assert not any("o self" in l for l in before), "a light on the player at the join"
assert after and "o self 14" in after[-1], "no lamp light after the key"
PY
echo "PASS: a join holds slot 1 on the server too, no light from last session's slot"
