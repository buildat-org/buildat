#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-11)
# covers: apps/vanilla/main/client_lua/init.lua extensions/luanti_client/init.lua
# [DEBUG_INFO_PRIV]: the F5 info's position, look and seed as official
# Luanti shows them -- with the debug privilege or the basic_debug HUD
# flag. One fixture mod, four phases a few seconds apart: the player's
# privileges cut to interact and shout and basic_debug turned off; debug
# granted; debug revoked; the flag back on. At each phase the client's
# F5 text, both levels, from its log: no place in 1 and 3, the place in
# 2 and 4. Vanilla on the minimal game, then luanti_client on official
# Luanti's devtest (skipped without luanti or devtest).
#   util/debug_info_priv_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp debug_info_priv; t=$CHECK_TMP
lsrv=
trap '[ -n "$lsrv" ] && kill $lsrv 2>/dev/null; check_cleanup' EXIT
cat > "$t/fixture.lua" <<'L'
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local function phase(n, at, f)
		core.after(at, function()
			local p = core.get_player_by_name(name)
			if not p then return end
			f(p)
			core.after(1, function() core.chat_send_player(name, "dp: " .. n) end)
		end)
	end
	local function priv(on)
		local privs = core.get_player_privs(name)
		privs.debug = on or nil
		core.set_player_privs(name, privs)
	end
	-- Late enough that the client is in: a phase sent while it loads
	-- arrives with the next
	phase(1, 15, function(p)
		-- Buildat's own admin has every privilege (bootstrap.lua)
		if core.__set_admin then core.__set_admin(name, false) end
		core.set_player_privs(name, {interact = true, shout = true})
		p:hud_set_flags({basic_debug = false})
	end)
	phase(2, 21, function() priv(true) end)
	phase(3, 27, function() priv(false) end)
	phase(4, 33, function(p) p:hud_set_flags({basic_debug = true}) end)
end)
L
# The client's F5 pressed once and twice at each phase, then back to off
{
	for n in 1 2 3 4; do
		echo "wait_log 120000 dp: $n"; echo "delay 1000"
		echo "keypress F5"; echo "delay 600"; echo "keypress F5"; echo "delay 600"
		echo "keypress F5"; echo "delay 300"
	done
	echo quit
} > "$t/cmds"
# judge <log> <the F5 lines' pattern> <a place's pattern>: two lines a
# phase, the place in phases 2 and 4 only
judge(){
	python3 - "$1" "$2" "$3" <<'PY'
import re, sys
lines = [l for l in open(sys.argv[1], errors="replace") if re.search(sys.argv[2], l)]
assert len(lines) == 8, "%d F5 lines, not 8" % len(lines)
for i, l in enumerate(lines):
    n = i // 2 + 1
    has = re.search(sys.argv[3], l) is not None
    assert has == (n in (2, 4)), "phase %d: %s" % (n, l.strip()[:300])
print("the place hidden in phases 1 and 3, shown in 2 and 4")
PY
}

# Vanilla
d=$t/v
mkdir -p "$d/apps/vanilla/saves/dp/luanti" "$d/shared"
cp "$t/fixture.lua" "$d/shared/fixture.lua"
# Not singleplayer, whose name has every privilege (bootstrap.lua)
printf "enable_damage = false\nsingleplayer = false\n" > "$d/apps/vanilla/saves/dp/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=dp \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/v.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 || fail "the server ($t/v.log)"
CHECK_PIDS+=($SERVER_PID)
run_client 60 "$t/vc.log" timeout 240 "$here/Build/bin/buildat" \
	-C "$t/vnc" -D "$t/vnu" -s 127.0.0.1:$SERVER_PORT -w 800x450 -u 1 -l 3 \
	-o sound_mute=1 -c @"$t/cmds"
judge "$t/vc.log" "vanilla : b/.*\| step:" "seed: |\| chunk |yaw: " ||
	fail "vanilla's F5 ($t/vc.log)"
echo "ok: vanilla"

# luanti_client
G="$BUILDAT_USER_PATH/shared/vanilla/games/devtest"
if ! command -v luanti > /dev/null || [ ! -d "$G" ]; then
	echo "PASS (vanilla; luanti_client SKIPPED: no luanti or devtest)"
	exit 0
fi
mkdir -p "$t/games" "$t/w/worldmods/dp"
cp -r "$G" "$t/games/"
cp "$t/fixture.lua" "$t/w/worldmods/dp/init.lua"
echo "name = dp" > "$t/w/worldmods/dp/mod.conf"
printf 'gameid = devtest\nbackend = sqlite3\n' > "$t/w/world.mt"
P=$((30200 + RANDOM % 300))
LUANTI_GAME_PATH="$t/games" MINETEST_GAME_PATH="$t/games" \
	luanti --server --world "$t/w" --port $P > "$t/l.log" 2>&1 &
lsrv=$!
for _ in $(seq 60); do
	grep -q "listening on" "$t/l.log" && break
	kill -0 $lsrv 2>/dev/null || fail "luanti died ($(tail -3 "$t/l.log"))"
	sleep 0.5
done
mkdir -p "$t/lcl"
now=$(date +%s)
echo "\"true\",\"udp://127.0.0.1:$P\",\"\",\"$now\",\"$now\",\"\",\"\",\"\"" \
	> "$t/lcl/network_addresses.csv"
(cd "$here/Build" && BUILDAT_LUANTI_ADDRESS=127.0.0.1:$P BUILDAT_LUANTI_CONNECT=1 \
	BUILDAT_LUANTI_NAME=dpcheck timeout 240 bin/buildat -m luanti_client \
	-D "$t/lcl" -w 800x600 -l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/lc.log" 2>&1)
judge "$t/lc.log" "luanti_c: F5: " "yaw: |looking " ||
	fail "luanti_client's F5 ($t/lc.log)"
echo "PASS: vanilla's and luanti_client's F5 hide the place without debug or basic_debug"
