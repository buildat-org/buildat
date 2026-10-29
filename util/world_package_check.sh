#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-29)
# covers: src/impl/aitta.cpp src/interface/aitta.h src/client/app_lua.h client/core/aitta/init.lua client/core/aitta/publish.lua client/launch_grid.lua client/api.lua apps/aitta/main/main.cpp apps/vanilla/main/game_start.h apps/vanilla/main/game_settings.h apps/vanilla/launcher/init.lua
# [WORLD_PACKAGES]: a world published from one client and played on
# another, through a local Aitta, native. The minimal game's save wp has a
# marker node the fixture placed, a world mod, world.mt naming an admin and
# default privileges, and a player with the server privilege (the players
# row written in here, as a crafted save would have it):
#   1. Saves, wp's "Publish this world": copied into dev_apps/wp, its world
#      mod and its players row left out ([WORLD_PUBLISH_PLAYERS]); Next,
#      Pack and publish: listed as a world for vanilla;
#   2. a world package carrying a world mod (packed and published by the
#      command line) is refused by the client's install; wp 1.0.1, packed
#      by the command line from the save as it is -- its players row, and
#      world.mt with settings that cost the host (chunksize, the preset's,
#      secure.*) and a force_loaded.txt -- is published over it;
#   3. on a fresh user path, Apps from Aitta's wp "Install and play": a new
#      save wp of vanilla, played; the marker node is there in the world;
#      the first open took out the admin, privilege and cost settings, the
#      forceloads and the players ([WORLD_DATA_COST]), and the world mod
#      never came.
# simplified: the form's fields are the dev package's meta.json written
# here, as a second publish of the same world finds it; the form itself is
# util/aitta_publish_check.sh's, and its keys are that check's (Tab, Return:
# the publish screen is taller than the window)
#   util/world_package_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/Build/bin/buildat"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp world_package; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/aitta.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/aitta" -l 3 ||
	fail "Aitta did not start ($t/aitta.log)"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/aitta.log" | cut -d' ' -f3)

# A user path with only this Aitta, its address already allowed
user(){
	mkdir -p "$t/$1/shared"
	echo "{\"starports\": [], \"aittas\": [\"http://127.0.0.1:$P\"]}" \
		> "$t/$1/starport.json"
	local now; now=$(date +%s)
	printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","","%s","%s","","",""\n' \
		$P $now $now > "$t/$1/network_addresses.csv"
}
user u
user u2
mkdir -p "$t/u/aitta_keys"
"$b" aitta keygen "$t/u/aitta_keys/tester.key" > "$t/pub" 2>/dev/null || fail "keygen"
# The admin binds tester to the key, and lets / show a release at once
printf 'wait_log_any 30000 "id":2,"ok":\nquit\n' > "$t/admin.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
BUILDAT_AITTA_CODE=$code BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}
{\"cmd\":\"set_settings\",\"settings\":{\"page_delay\":0}}" \
	timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/admin" -C "$t/c_admin" \
	-w 800x600 -l 3 -o sound_mute=1 -s 127.0.0.1:$P -c @"$t/admin.cmds" > "$t/admin.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/admin.log" && grep -aq 'ai: {"id":2,"ok":true' "$t/admin.log" ||
	fail "the bind or the setting did not go through ($t/admin.log)"

# The publisher's save
s=$t/u/apps/vanilla/saves/wp
mkdir -p "$s/luanti/worldmods/wpmod"
printf 'name = publisher\ndefault_privs = server, privs\nenable_damage = false\n' > "$s/luanti/world.mt"
echo "name = wpmod" > "$s/luanti/worldmods/wpmod/mod.conf"
echo 'core.log("action", "wpmod: loaded")' > "$s/luanti/worldmods/wpmod/init.lua"
cat > "$t/u/shared/fixture.lua" <<'L'
core.after(0, function()
	core.emerge_area({x = 0, y = 0, z = 0}, {x = 8, y = 16, z = 8},
			function(_, _, left)
		if left > 0 then return end
		core.set_node({x = 3, y = 9, z = 3}, {name = "floor:marker"})
		core.log("action", "wp: placed " .. core.get_node({x = 3, y = 9, z = 3}).name)
	end)
end)
L
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=wp \
BUILDAT_LUANTI_LUA="$t/u/shared/fixture.lua" start_server "$t/mk.log" \
	"STATUS Listening" 120 auto bin/buildat_server -u launcher=1 \
	-A 127.0.0.1 -m ../apps/vanilla -D "$t/u" -C "$t/c_mk" -l 3 ||
	fail "the save wp ($t/mk.log)"
wait_for_log "$t/mk.log" "wp: placed floor:marker" 60 || fail "no marker placed ($t/mk.log)"
grep -aq "wpmod: loaded" "$t/mk.log" || fail "the publisher's world mod did not load ($t/mk.log)"
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
# A player with the server privilege, as Luanti's auth entries are kept
python3 - "$s/save.sqlite" <<'PY' || fail "the players row"
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("INSERT OR REPLACE INTO store VALUES ('luanti', 'players', ?)",
        (b'return {v = 1, players = {}, auth = {publisher = {name = "publisher", '
         b'password = "", privileges = {server = true}, last_login = 0}}}',))
db.commit()
PY

# 1. Published from the launcher's Saves
mkdir -p "$t/u/dev_apps/wp"
cat > "$t/u/dev_apps/wp/meta.json" <<'J'
{"kind": "world", "app": "vanilla", "author": "tester", "name": "wp",
 "version": "1.0.0", "engine_api": 2, "license_code": "MIT",
 "license_media": "CC-BY-SA-4.0", "description": "A marker on a floor"}
J
cat > "$t/pub.cmds" <<C
wait_log_any 60000 rows in
delay 1500
click Button "Saves*"
wait_log 5000 launch_menu: save,
delay 500
click Button "Publish this world"
wait_log 10000 aitta publish: the package page, wp
delay 500
$(for _ in $(seq 16); do echo "keypress Tab"; done)
keypress Return
wait_log 20000 aitta publish: the key page, The key is bound
delay 300
keypress Tab
keypress Tab
keypress Return
wait_log 20000 aitta publish: published tester/wp/1.0.0
screenshot $t/published.png
quit
C
run_client 60 "$t/pub.log" timeout 240 "$b" -o launch_ui=launch_menu -D "$t/u" \
	-C "$t/c_u" -w 1000x700 -l 3 -o sound_mute=1 -c @"$t/pub.cmds" ||
	fail "the publish drive ($t/pub.log)"
grep -aq "Listed tester/wp/1.0.0" "$t/aitta.log" || fail "wp not listed ($t/aitta.log)"
python3 - "$t/u/aitta_releases/tester-wp-1.0.0.zip" "$t/rel.sqlite" <<'PY' || fail "the release's files"
import json, os, sqlite3, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
assert "world/save.sqlite" in names and "world/luanti/world.mt" in names, names
assert not [n for n in names if "worldmods" in n], names
m = json.loads(z.read("meta.json"))
assert m["kind"] == "world" and m["app"] == "vanilla" and m["buildat_version"], m
db = z.read("world/save.sqlite")
assert b"privileges" not in db and b"publisher" not in db, "a player in save.sqlite"
p = sys.argv[2]
open(p, "wb").write(db)
c = sqlite3.connect(p)
assert c.execute("SELECT count(*) FROM store WHERE store = 'luanti' AND "
        "key = 'players'").fetchone()[0] == 0, "the players row"
assert c.execute("SELECT count(*) FROM store WHERE store = 'main' AND "
        "key = 'gameid'").fetchone()[0] == 1, "the save's other rows"
c.close()
os.remove(p)
print("ok: the release has the save, not its world mod or players:", len(names), "files")
PY
curl -s "http://127.0.0.1:$P/api/v1/aitta/list" | python3 -c 'import json, sys
r = [r for r in json.load(sys.stdin)["releases"] if r["name"] == "wp"][0]
assert r["kind"] == "world" and r["app"] == "vanilla", r' ||
	fail "the list does not say wp is a world for vanilla"
curl -s "http://127.0.0.1:$P/" | grep -q "world for vanilla" ||
	fail "Aitta's page does not say wp is a world for vanilla"
echo "ok: published from Saves as a world for vanilla, its world mod left out"

# 2. One with a world mod, packed and published by hand
e=$t/evil
mkdir -p "$e/world/luanti/worldmods/evil"
cp "$s/save.sqlite" "$e/world/"
echo 'core.log("action", "evil: loaded")' > "$e/world/luanti/worldmods/evil/init.lua"
echo '{"kind": "world", "app": "vanilla", "author": "tester", "name": "evilworld",
 "version": "1.0.0", "engine_api": 2, "license_code": "MIT",
 "license_media": "MIT"}' > "$e/meta.json"
zip=$("$b" aitta pack "$e" "$t/u/aitta_keys/tester.key" "$t/out" 2>"$t/pack.err") || fail "pack: $(cat "$t/pack.err")"
out=$("$b" aitta publish "$zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "listed: tester/evilworld/1.0.0" || fail "publish evilworld: $out"
# wp 1.0.1: the save as it is, players and all, and settings that cost
r=$t/raw
mkdir -p "$r/world/luanti"
cp "$s/save.sqlite" "$r/world/"
cp "$s/luanti/world.mt" "$r/world/luanti/"
printf 'chunksize = 80\nliquid_loop_max = 99999999\nbuildat_preset = Custom\nsecure.http_mods = wpmod\nbasic_privs = server\n' \
	>> "$r/world/luanti/world.mt"
echo 'return {}' > "$r/world/luanti/force_loaded.txt"
sed 's/"1.0.0"/"1.0.1"/' "$t/u/dev_apps/wp/meta.json" > "$r/meta.json"
zip=$("$b" aitta pack "$r" "$t/u/aitta_keys/tester.key" "$t/out" 2>"$t/pack.err") || fail "pack 1.0.1: $(cat "$t/pack.err")"
out=$("$b" aitta publish "$zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "listed: tester/wp/1.0.1" || fail "publish wp 1.0.1: $out"

# 3. Installed and played elsewhere; evilworld refused first
cat > "$t/u2/shared/fixture.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local p = {x = 3, y = 9, z = 3}
	core.emerge_area(p, p, function(_, _, left)
		if left > 0 then return end
		core.chat_send_player(name, "wp: the node is " .. core.get_node(p).name)
	end)
end)
L
cat > "$t/inst.cmds" <<C
wait_log_any 60000 rows in
delay 500
text aitta
wait_log 10000 rows for "aitta" in
keypress Return
wait_log 20000 aitta page: tester/wp
wait_log_any 5000 aitta panel: tester/evilworld 1.0.0
delay 500
click Button "Install and play"
wait_log 20000 aitta status: Not installed
delay 300
click Button "tester/wp"
wait_log 5000 aitta panel: tester/wp 1.0.1
delay 300
click Button "Install and play"
wait_log 120000 chat: wp: the node is
delay 500
screenshot $t/played.png
quit
C
BUILDAT_LUANTI_LUA="$t/u2/shared/fixture.lua" run_client 120 "$t/inst.log" \
	timeout 300 "$b" -o launch_ui=launch_menu -D "$t/u2" -C "$t/c_u2" \
	-w 1000x700 -l 3 -o sound_mute=1 -c @"$t/inst.cmds" ||
	fail "the install drive ($t/inst.log)"
for p in $(pgrep -f "[b]uildat_server .*-D $t/u2"); do kill $p; done
grep -aq "aitta status: Not installed: .*carries luanti/worldmods" "$t/inst.log" ||
	fail "evilworld's world mod was not refused ($t/inst.log)"
[ ! -e "$t/u2/apps/vanilla/saves/evilworld" ] || fail "evilworld was installed"
grep -aq "chat: wp: the node is floor:marker" "$t/inst.log" ||
	fail "the marker is not in the installed world ($t/inst.log, played.png)"
w=$t/u2/apps/vanilla/saves/wp
[ -f "$w/save.sqlite" ] && [ ! -e "$w/.world_package" ] ||
	fail "wp is not a save that was opened ($w)"
grep -qE '^(name|default_privs|basic_privs|chunksize|secure\.[a-z_]*) ' "$w/luanti/world.mt" &&
	fail "world.mt kept the admin, privileges or cost settings: $(cat "$w/luanti/world.mt")"
grep -q '^liquid_loop_max = 99999999' "$w/luanti/world.mt" &&
	fail "world.mt kept the world's liquid_loop_max"
grep -q '^buildat_preset = Custom' "$w/luanti/world.mt" &&
	fail "world.mt kept the world's preset"
[ ! -e "$w/luanti/force_loaded.txt" ] || fail "the forceloads were kept"
grep -q '^enable_damage = false' "$w/luanti/world.mt" ||
	fail "world.mt lost its other settings: $(cat "$w/luanti/world.mt")"
[ ! -e "$w/luanti/worldmods" ] || fail "wp has world mods"
python3 - "$w/save.sqlite" <<'PY' || fail "the players"
import sqlite3, sys
row = sqlite3.connect(sys.argv[1]).execute(
        "SELECT value FROM store WHERE store = 'luanti' AND key = 'players'").fetchone()
assert row is None or b"publisher" not in row[0], row
PY
echo "ok: a world mod refused; wp installed as a save of vanilla and played, its marker there, its admin, privileges, cost settings, forceloads and players gone"
echo "PASS: a world published from Saves, listed under vanilla, installed and played on a fresh user path"
