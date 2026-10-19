#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-11)
# covers: builtin/luanti/client_lua/client.lua apps/vanilla/main/client_lua/init.lua extensions/luanti_client/init.lua
# [DEBUG_INFO_PRIV]: the F5 info's position, look and seed as official
# Luanti shows them -- with the debug privilege or the basic_debug HUD
# flag. One fixture mod, four phases the client asks for in turn: the player's
# privileges cut to interact and shout and basic_debug turned off; debug
# granted; debug revoked; the flag back on. At each phase the client's
# F5 text, both levels, from its log: no place in 1 and 3, the place in
# 2 and 4. Vanilla on the minimal game, then luanti_client on official
# Luanti's devtest (skipped without luanti or devtest).
#   util/debug_info_priv_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp debug_info_priv; t=$CHECK_TMP
lsrv=
trap '[ -n "$lsrv" ] && kill $lsrv 2>/dev/null; check_cleanup' EXIT
cat > "$t/fixture.lua" <<'L'
-- A phase by chat, "/dp <n>", asked for by the client once it is in and
-- has read the last one; said a second on, after what it changed
local function priv(name, on)
	local privs = core.get_player_privs(name)
	privs.debug = on or nil
	core.set_player_privs(name, privs)
end
local phases = {
	function(name, p)
		-- Buildat's own admin has every privilege (bootstrap.lua)
		if core.__set_admin then core.__set_admin(name, false) end
		core.set_player_privs(name, {interact = true, shout = true})
		p:hud_set_flags({basic_debug = false})
	end,
	function(name) priv(name, true) end,
	function(name) priv(name, false) end,
	function(name, p) p:hud_set_flags({basic_debug = true}) end,
}
core.register_chatcommand("dp", {func = function(name, param)
	local n = tonumber(param)
	local p = core.get_player_by_name(name)
	if not (n and phases[n] and p) then
		return false, "dp: no phase " .. param
	end
	phases[n](name, p)
	core.after(1, function() core.chat_send_player(name, "dp: " .. n) end)
	return true
end})
L
# The client's F5 pressed once and twice at each phase, then back to off
{
	echo "wait_log_any 60000 the world is in"; echo "delay 500"
	for n in 1 2 3 4; do
		echo "keypress T"; echo "wait_log 5000 chat: the line opened"
		echo "text /dp $n"; echo "keypress Return"
		# A settle after the line: the phase's privileges in the frames after it
		echo "wait_log 10000 dp: $n"; echo "delay 300"
		for _ in 1 2 3; do echo "keypress F5"; echo "wait_log 5000 debug info:"; done
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
	-o sound_mute=1 -c @"$t/cmds" ||
	fail "vanilla's drive ($t/vc.log): $(grep -a "Command sequence failed\|run_client:" "$t/vc.log" | tail -1)"
judge "$t/vc.log" "vanilla : b/.*\| step:" "seed: |\| chunk |yaw: " ||
	fail "vanilla's F5 ($t/vc.log)"
echo "ok: vanilla"

# luanti_client
G="$BUILDAT_USER_PATH/shared/vanilla/games/devtest"
if ! command -v luanti > /dev/null || [ ! -d "$G" ]; then
	echo "PASS: (vanilla; luanti_client SKIPPED: no luanti or devtest)"
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
for _ in $(seq 150); do
	grep -q "listening on" "$t/l.log" && break
	kill -0 $lsrv 2>/dev/null || fail "luanti died ($(tail -3 "$t/l.log"))"
	sleep 0.2
done
grep -q "listening on" "$t/l.log" || fail "luanti did not come up ($t/l.log)"
mkdir -p "$t/lcl"
now=$(date +%s)
echo "\"true\",\"udp://127.0.0.1:$P\",\"\",\"$now\",\"$now\",\"\",\"\",\"\"" \
	> "$t/lcl/network_addresses.csv"
(cd "$here/Build" && BUILDAT_LUANTI_ADDRESS=127.0.0.1:$P BUILDAT_LUANTI_CONNECT=1 \
	BUILDAT_LUANTI_NAME=dpcheck timeout 240 bin/buildat -m luanti_client \
	-D "$t/lcl" -w 800x600 -l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/lc.log" 2>&1) ||
	fail "luanti_client's drive ($t/lc.log): $(grep -a "Command sequence failed" "$t/lc.log" | tail -1)"
judge "$t/lc.log" "luanti_c: F5: " "yaw: |looking " ||
	fail "luanti_client's F5 ($t/lc.log)"
echo "PASS: vanilla's and luanti_client's F5 hide the place without debug or basic_debug"
