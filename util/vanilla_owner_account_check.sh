#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# needs: network
# cost: ~2 min (2026-11-03)
# covers: apps/vanilla/main/main.cpp apps/vanilla/main/game_start.h apps/vanilla/main/client_lua/join.lua apps/vanilla/main/client_lua/pause.lua builtin/luanti/lua/bootstrap.lua builtin/luanti/lua/entity.lua builtin/luanti/vendor/builtin/game/auth.lua
# [VANILLA_OWNER_ACCOUNT], [LUANTI_IMPORT_OWNER], [LUANTI_IS_SINGLEPLAYER]
# on vanilla's launcher game (minimal), one server:
#   1. Its owner ("owner", the default name) is logged in through
#      builtin/accounts with no dialog, and imports a Luanti world from
#      the import folder: the world's "singleplayer" row (a meta mark) is
#      the owner's player.
#   2. core.is_singleplayer() is true until the owner's pause menu opens
#      the game to the LAN, then false.
#   3. bob (a second local login, no admin) joins with interact and
#      shout; the owner's My account... > World privileges grants him fly:
#      his client has it, flies up 3 nodes; the owner revokes it and his
#      client loses it.
# A fixture mod (BUILDAT_LUANTI_LUA) logs "oac: ..." lines. KEEP_TMP=1
# keeps $t: o_privs.png, the owner's World privileges page.
#   util/vanilla_owner_account_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp vanilla_owner_account; t=$CHECK_TMP
trap check_cleanup EXIT

# The Luanti world to import: an empty map, a singleplayer with a mark
w="$t/v/shared/vanilla/import/worlds/spw"
mkdir -p "$w"
printf 'gameid = minimal\nbackend = sqlite3\n' > "$w/world.mt"
python3 - "$w" <<'PY'
import sqlite3, sys
d = sys.argv[1]
sqlite3.connect(d + "/map.sqlite").execute(
    "CREATE TABLE blocks (pos INT PRIMARY KEY, data BLOB)")
db = sqlite3.connect(d + "/players.sqlite")
db.executescript("""
CREATE TABLE player (name VARCHAR(50) PRIMARY KEY, pitch NUMERIC, yaw NUMERIC,
  posX NUMERIC, posY NUMERIC, posZ NUMERIC, hp INT, breath INT,
  creation_date DATETIME, modification_date DATETIME);
CREATE TABLE player_metadata (player VARCHAR(50), metadata VARCHAR(256), value TEXT);
CREATE TABLE player_inventories (player VARCHAR(50), inv_id INT, inv_width INT,
  inv_name TEXT, inv_size INT);
CREATE TABLE player_inventory_items (player VARCHAR(50), inv_id INT, slot_id INT, item TEXT);
INSERT INTO player VALUES ('singleplayer', 0, 0, 100, 200, 300, 20, 10, 0, 0);
INSERT INTO player_metadata VALUES ('singleplayer', 'oac_mark', 'sp');
""")
db.commit()
PY
mkdir -p "$t/v/shared"
cat > "$t/v/shared/fixture.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.log("action", "oac: " .. name .. " joined, mark '" ..
			player:get_meta():get_string("oac_mark") .. "'")
	if name ~= "bob" then
		return
	end
	core.chat_send_all("oac: bob is in")
	local start, said = nil, false
	local function tick()
		if not player:is_player() then
			return
		end
		local y = player:get_pos().y
		start = start or y
		if not said and y > start + 3 and
				core.check_player_privs("bob", {fly = true}) then
			said = true
			core.log("action", "oac: bob flew")
			core.chat_send_all("oac: bob flew")
		end
		core.after(1, tick)
	end
	core.after(1, tick)
end)
local last
local function isp()
	local v = core.is_singleplayer()
	if v ~= last then
		last = v
		core.log("action", "oac: is_singleplayer " .. tostring(v))
		core.chat_send_all("oac: is_singleplayer " .. tostring(v))
	end
	core.after(1, isp)
end
core.after(0, isp)
L

BUILDAT_LUANTI_LUA="$t/v/shared/fixture.lua" start_server "$t/srv.log" "STATUS Listening" \
	120 auto "$here/Build/bin/buildat_server" -u "launcher=1
menu=import_world" \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/v" -C "$t/vc" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)

cat > "$t/o.cmds" <<C
wait_log_any 60000 accounts: logged in as owner by local
wait_log_any 60000 worlds to import
delay 1500
click Button "spw*"
delay 800
click Button "Import"
wait_log 240000 load: the world is in
delay 1000
keypress Escape
wait_log 5000 pause: the menu shown
delay 500
click Button "Open to LAN"
wait_log_any 10000 Open to LAN: Open to the LAN
wait_log_any 10000 oac: is_singleplayer false
wait_log_any 180000 oac: bob is in
delay 500
click Button "My account..."
wait_log 5000 server window: the page account
delay 500
click Button "World privileges"
wait_log 5000 privileges: the page drawn
delay 500
screenshot $t/o_privs.png
click Button "priv bob fly"
wait_log 60000 oac: bob flew
# Past bob's held Space, whose end his drive then waits for the revoke
delay 4000
click Button "priv bob fly"
delay 3000
quit
C
run_client 60 "$t/o.log" timeout 400 "$here/Build/bin/buildat" \
	-C "$t/co" -D "$t/uo" -s 127.0.0.1:$SERVER_PORT -w 900x700 -l 3 \
	-o sound_mute=1 -o default_username=owner -c @"$t/o.cmds" &
opid=$!
for _ in $(seq 1500); do
	grep -aq "oac: is_singleplayer false" "$t/o.log" && break
	kill -0 $opid 2>/dev/null || break
	sleep 0.2
done
cat > "$t/b.cmds" <<C
wait_log_any 180000 load: the world is in
wait_log_any 60000 privileges: interact, shout
wait_log 120000 privileges: fly, interact, shout
delay 500
keypress K
wait_log 5000 Fly mode enabled
keydown Space
delay 2500
keyup Space
wait_log 60000 privileges: interact, shout
quit
C
BUILDAT_JOIN_NAME=bob run_client 60 "$t/b.log" timeout 400 "$here/Build/bin/buildat" \
	-C "$t/cb" -D "$t/ub" -s 127.0.0.1:$SERVER_PORT -w 640x400 -l 3 \
	-o sound_mute=1 -c @"$t/b.cmds" || bad="bob's drive"
wait $opid || bad="${bad:-} the owner's drive"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null

bad=${bad:-}
s="$t/srv.log"
grep -aq "Logging in as owner on this computer" "$t/o.log" ||
	bad="$bad; the owner not logged in without the dialog"
grep -aq "singleplayer imported as owner" "$s" ||
	bad="$bad; the import's singleplayer not the owner's"
grep -aq "oac: owner joined, mark 'sp'" "$s" ||
	bad="$bad; the owner's player is not the imported singleplayer"
# In order: true, the LAN opened, false
awk '/oac: is_singleplayer true/ { a = 1 } a && /Open to LAN: listening/ { b = 1 }
	b && /oac: is_singleplayer false/ { ok = 1 } END { exit !ok }' "$s" ||
	bad="$bad; is_singleplayer did not go from true to false at Open to LAN"
grep -aq "owner grants fly to bob" "$s" && grep -aq "owner revokes fly from bob" "$s" ||
	bad="$bad; no grant and revoke from the page"
grep -aq "oac: bob flew" "$s" || bad="$bad; bob did not fly"
awk '/privileges: fly, interact, shout/ { f = 1 } f && /privileges: interact, shout/ { ok = 1 }
	END { exit !ok }' "$t/b.log" || bad="$bad; bob's client did not lose fly"
[ -z "$bad" ] || fail "${bad#; } ($t: srv.log, o.log, b.log; $(grep -a "Command sequence failed" "$t/o.log" "$t/b.log" | head -2))"
echo "PASS: the owner logged in as owner through accounts, got the imported singleplayer; is_singleplayer true, false after Open to LAN; fly granted to bob in World privileges, flown, revoked"
# vim: set noet ts=4 sw=4:
