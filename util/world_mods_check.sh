#!/bin/bash
# tier: full
# cost: ~4 min (2026-10-11)
# covers: apps/vanilla/main/main.cpp apps/vanilla/main/client_lua/menu.lua builtin/luanti/lua/modloader.lua
# [WORLD_MODS]: mods from ContentDB, chosen per world. Needs the network
# (the real ContentDB). Vanilla on the minimal game, worlds w1 and w2;
# w1's world.mt turns on mobs_animal, not installed:
#   1. The menu, driven: w1's Mods... shows mobs_animal missing; its Get
#      from ContentDB finds it, Install asks once about the mod it needs
#      (mobs) and installs both; mobs_animal turned off and on again
#      turns mobs on with it; Play: w1 starts with both loaded (their
#      modpaths, nodes of theirs).
#   2. w2 starts without them.
#   3. w1 with both turned off in the menu starts without them.
#   4. An imported Luanti world with a worldmods/ mod loads it.
#   util/world_mods_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
curl -s -m 10 -o /dev/null https://content.luanti.org/api/packages/?limit=1 ||
	{ echo "SKIP: no network"; exit 0; }
check_tmp world_mods; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/u
mkdir -p "$d/shared"
# What a world has loaded, once its mods are in
cat > "$d/shared/fixture.lua" <<'L'
core.register_on_mods_loaded(function()
	local n = 0
	for name in pairs(core.registered_nodes) do
		if name:match("^mobs:") or name:match("^mobs_animal:") or
				name:match("^wm:") then
			n = n + 1
		end
	end
	core.log("action", "wmcheck: mobs " .. tostring(core.get_modpath("mobs")) ..
			", mobs_animal " .. tostring(core.get_modpath("mobs_animal")) ..
			", wm " .. tostring(core.get_modpath("wm")) .. ", nodes " .. n)
end)
L
# serve <log> [env...]: a server, up until its world has loaded its mods
# or, with no world, until it listens
serve(){
	local log=$1 kv rc; shift
	for kv in "$@"; do export "$kv"; done
	BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$log" \
		"wmcheck:|STATUS Listening" 180 auto "$here/Build/bin/buildat_server" \
		-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
		-C "$t/c" -l 3
	rc=$?
	for kv in "$@"; do unset "${kv%%=*}"; done
	[ $rc = 0 ] || fail "the server ($log)"
}
stop(){ kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }
# A world's run: what it loaded
world(){
	local log=$1; shift
	serve "$log" BUILDAT_LUANTI_GAME=minimal "$@"
	wait_for_log "$log" "wmcheck:" 60
	stop
	grep -a "wmcheck:" "$log" | head -1 | sed 's/.*wmcheck: //'
}
client(){
	run_client 60 "$1" timeout 300 "$here/Build/bin/buildat" -C "$t/nc" \
		-D "$t/nu" -s 127.0.0.1:$SERVER_PORT -w 1100x900 -u 1 -l 3 \
		-o sound_mute=1 -c @"$2" || fail "the drive ($1)"
}

# The two worlds, made by a start each
for w in w1 w2; do
	got=$(world "$t/$w.log" BUILDAT_LUANTI_SAVE=$w)
	echo "$w at first: $got"
	case $got in "mobs nil, mobs_animal nil, wm nil, nodes 0") ;;
		*) fail "$w at first ($t/$w.log)" ;; esac
done
echo "load_mod_mobs_animal = true" >> "$d/apps/vanilla/saves/w1/luanti/world.mt"

# 1
# The delays of 2 s at most: the menu a click or a line opens, laid out in
# the frames after it
cat > "$t/1.cmds" <<C
wait_log_any 60000 menu: 2 saves
delay 1000
click Button "w1*"
wait_log 10000 menu: the world w1 shown
click Button "Mods..."
wait_log 10000 menu: world mods of w1
delay 500
screenshot $t/1_missing.png
click Button "Get from ContentDB"
wait_log 60000 menu: ContentDB mods:
delay 500
screenshot $t/1_contentdb.png
click Button "Install"
wait_log 60000 menu: mobs_animal needs
delay 500
click Button "Install all"
wait_log 180000 menu: mobs_animal installed from ContentDB
delay 2000
click Button "Play"
wait_log 10000 w1: its mods cannot load: mobs_animal needs mobs
delay 500
click Button "Ok"
# the click's frames: the dialog gone before the next click
delay 1000
click Button "Mods..."
wait_log 10000 menu: world mods of w1
delay 500
click Button "[x] mobs_animal*"
wait_log 10000 Off: mobs_animal
delay 500
click Button "[ ] mobs_animal*"
wait_log 10000 On: mobs_animal, with mobs
delay 500
screenshot $t/1_on.png
click Button "< back"
# The list comes back with w1 still selected (a click on it would play it)
wait_log 10000 menu: the world w1 shown
click Button "Play"
wait_log 120000 vanilla client ready
quit
C
serve "$t/m1.log"
client "$t/1.log" "$t/1.cmds"
stop
grep -a "menu: mobs_animal needs\|installed from\|cannot load" "$t/1.log" | sed 's/.*menu: /  /' | head -5
grep -aq "menu: mobs installed from ContentDB" "$t/1.log" || fail "mobs not installed ($t/1.log)"
got=$(grep -a "wmcheck:" "$t/m1.log" | head -1 | sed 's/.*wmcheck: //')
echo "w1 with the mods: $got"
case $got in "mobs $d/"*", mobs_animal $d/"*", wm nil, nodes "[1-9]*) ;;
	*) fail "w1 without its mods ($t/m1.log, $t/1.log)" ;; esac

# 2
got=$(world "$t/w2b.log" BUILDAT_LUANTI_SAVE=w2)
echo "w2: $got"
[ "$got" = "mobs nil, mobs_animal nil, wm nil, nodes 0" ] || fail "w2 has them ($t/w2b.log)"

# 3 (the delays as in 1)
cat > "$t/3.cmds" <<C
wait_log_any 60000 menu: 2 saves
delay 1000
click Button "w1*"
wait_log 10000 menu: the world w1 shown
click Button "Mods..."
wait_log 10000 menu: world mods of w1
delay 500
click Button "[x] mobs_animal*"
wait_log 10000 Off: mobs_animal
delay 500
click Button "[x] mobs"
wait_log 10000 Off: mobs.
delay 500
click Button "< back"
# The list comes back with w1 still selected (a click on it would play it)
wait_log 10000 menu: the world w1 shown
click Button "Play"
wait_log 120000 vanilla client ready
quit
C
serve "$t/m3.log"
client "$t/3.log" "$t/3.cmds"
stop
got=$(grep -a "wmcheck:" "$t/m3.log" | head -1 | sed 's/.*wmcheck: //')
echo "w1 with them off: $got"
[ "$got" = "mobs nil, mobs_animal nil, wm nil, nodes 0" ] || fail "w1 still has them ($t/m3.log)"

# 4
# Where the menu's import puts a world: a boxed server reads its user path alone
lw=$d/apps/vanilla/worlds/lw
mkdir -p "$lw/worldmods/wm"
printf 'gameid = minimal\nbackend = sqlite3\n' > "$lw/world.mt"
echo "name = wm" > "$lw/worldmods/wm/mod.conf"
echo 'core.register_node("wm:node", {})' > "$lw/worldmods/wm/init.lua"
got=$(world "$t/w3.log" BUILDAT_LUANTI_SAVE=w3 BUILDAT_LUANTI_IMPORT="$lw")
echo "the imported world: $got"
case $got in "mobs nil, mobs_animal nil, wm $d/"*", nodes 1") ;;
	*) fail "the imported world's mod ($t/w3.log)" ;; esac
echo "PASS: a ContentDB mod and what it needs installed from a world's Mods, on in that world alone and off again; an imported world's worldmods/ loaded"
