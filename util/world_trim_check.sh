#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-11)
# covers: apps/vanilla/main/main.cpp apps/vanilla/main/client_lua/menu.lua apps/vanilla/main/client_lua/pause.lua builtin/storage/storage.cpp
# [WORLD_TRIM_MOVE] 1: trimming the running world from the launcher's own
# game (the pause menu's Worlds..., Trim...). Vanilla on the minimal
# game; a fixture emerges a strip x -1100..1100 and the client's chat
# command places a node at x 1000 (a player build), out of view.
#   1. To a size of 0 MB: sections go, the file shrinks, the build stays;
#      then the default box (round the build): nothing more of it goes.
#   2. A second client: the box edited to the origin's section, "Also
#      player builds outside" on: the build goes too.
#   util/world_trim_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp world_trim; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/s
mkdir -p "$d/apps/vanilla/saves/wt/luanti" "$d/shared"
echo "enable_damage = false" > "$d/apps/vanilla/saves/wt/luanti/world.mt"
cat > "$d/shared/fixture.lua" <<'L'
local M = {x = 1000, y = 2, z = 0}
local B = {x = math.floor(M.x / 16), y = 0, z = 0}
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0, speed = 0})
	core.after(2, function()
		-- The first join only: the second's trim takes the build
		if not core.get_player_by_name(name):get_meta():contains("wt") then
			core.__forceload_block_raw(B)
		end
		core.emerge_area({x = -1100, y = -16, z = -16}, {x = 1100, y = 15, z = 15},
				function(_, _, left)
			if left == 0 then core.chat_send_player(name, "wt: ready") end
		end)
	end)
end)
-- Out of view: kept loaded until marked, in the command (a player's doing
-- only while it runs), and let go to unload
core.register_chatcommand("mark", {func = function(name)
	core.set_node(M, {name = "floor:marker"})
	core.get_player_by_name(name):get_meta():set_string("wt", "1")
	core.__forceload_free_block_raw(B)
	return true, "wt: marked"
end})
-- Loaded again (forceloaded until read): a forgotten section is generated
-- again, air at the mark
core.register_chatcommand("look", {func = function(name)
	core.__forceload_block_raw(B)
	local function look(n)
		local at = core.get_node(M).name
		if at == "ignore" and n < 60 then return core.after(0.5, look, n + 1) end
		core.__forceload_free_block_raw(B)
		core.log("action", "wt: at the mark " .. at)
		core.chat_send_player(name, "wt: looked")
	end
	look(0)
	return true
end})
-- Until the strip's two far ends and the mark are not loaded any more:
-- a loaded section is not trimmed
core.register_chatcommand("unloaded", {func = function(name)
	local at = {{x = -1090, y = 0, z = 0}, {x = 1090, y = 0, z = 0}, M}
	local function poll(n)
		for _, p in ipairs(at) do
			if core.compare_block_status(p, "loaded") then
				if n < 240 then return core.after(0.5, poll, n + 1) end
				return core.chat_send_player(name, "wt: still loaded")
			end
		end
		core.log("action", "wt: unloaded")
		core.chat_send_player(name, "wt: unloaded")
	end
	poll(0)
	return true
end})
L
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=wt \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 3 || fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
# The delays of 300 ms put typed text and the key or click after it in
# frames of their own; the ones after a wait (up to 800 ms) are the page
# or the dialog laid out after its line.
chat(){ printf 'keypress T\nwait_log 5000 chat: the line opened\ntext %s\ndelay 300\nkeypress Return\nwait_log %s wt: %s\n' "$1" "${3:-20000}" "$2"; }
open_trim(){ printf 'keypress Escape\nwait_log 5000 pause: the menu shown\nclick Button "Worlds..."\nwait_log 10000 menu: the world wt shown\ndelay 500\nclick Button "Trim..."\nwait_log 10000 menu: trim \ndelay 800\n'; }
trim(){ printf 'delay 300\nclick Button "Trim to this %s..."\nwait_log 10000 menu: trim asks\ndelay 800\nclick Button "Trim"\nwait_log 60000 sections forgotten;\ndelay 800\n' "$1"; }
# Out of the trim page to the list, and out of the list to the game
leave(){ printf 'keypress Escape\nwait_log 5000 menu: the world wt shown\nkeypress Escape\nwait_log 5000 pause: back in the game from the worlds\n'; }
client(){ run_client 60 "$1" timeout 300 "$here/Build/bin/buildat" -C "$t/nc" \
	-D "$t/nu" -s 127.0.0.1:$SERVER_PORT -w 1000x600 -u 1 -l 3 -o sound_mute=1 -c @"$2"; }
# The strip's far ends unloaded before the trim: a loaded section is kept
{
	echo "wait_log 120000 wt: ready"; chat /mark marked; chat /look looked
	chat /unloaded unloaded 130000
	open_trim; printf 'click LineEdit "*"\ndelay 300\ntext 0\ndelay 300\n'; trim size
	trim box; echo "screenshot $t/trim.png"; echo "wait_log 20000 Wrote screenshot"
	leave; chat /look looked; echo quit
} > "$t/1.cmds"
client "$t/1.log" "$t/1.cmds" || fail "the first client's drive ($t/1.log)"
grep -a "menu: trim\|wt: at\|trims wt" "$t/1.log" "$t/srv.log" | sed 's/.*\(menu: \|main *: \|wt: \)/\1/' | cut -c 1-200
grep -a "trims wt:" "$t/srv.log" | head -1 | grep -aq ": [1-9][0-9]* sections forgotten" ||
	fail "the size trim forgot nothing ($t/srv.log)"
python3 - "$t/srv.log" <<'PY' || fail "the file did not shrink ($t/srv.log)"
import re, sys
m = [re.search(r"trims wt: (\d+) sections forgotten, (\d+) kB to (\d+) kB", l)
     for l in open(sys.argv[1], errors="replace")]
m = [x for x in m if x]
assert len(m) == 2, "%d trims" % len(m)
a, b = int(m[0].group(2)), int(m[0].group(3))
print("the size trim: %s sections, %d kB to %d kB" % (m[0].group(1), a, b))
assert b < a
assert m[1].group(1) == "0", "the default box forgot %s" % m[1].group(1)
PY
[ "$(grep -ac "wt: at the mark floor:marker" "$t/srv.log")" = 2 ] ||
	fail "the build did not stay ($t/srv.log)"
echo "ok: trimmed to a size, the build kept; the default box keeps it all"

# 2: the box's corners from the page's line: save | note | bytes |
# sections | altered | x y z | x y z
line=$(grep -a "menu: trim wt" "$t/1.log" | tail -1 | sed 's/.*menu: trim //')
c1=$(echo "$line" | awk -F' [|] ' '{ print $6 " " $7 " " $8 }')
c2=$(echo "$line" | awk -F' [|] ' '{ print $9 " " $10 " " $11 }')
[ -n "$c1" ] && [ -n "$c2" ] || fail "no box in: $line"
edit(){ printf 'click LineEdit "%s"\ndelay 300\nkeypress End\n' "$1"; for _ in $(seq 30); do echo "keypress Backspace"; done; printf 'text %s\ndelay 300\n' "$2"; }
# simplified: the 500 ms after the tick is for the box to be drawn
# ticked, which logs nothing; a line in the tick's handler would do
{
	echo "wait_log 120000 wt: ready"; chat /unloaded unloaded 130000
	open_trim; edit "$c1" "0 0 0"; edit "$c2" "1 1 1"
	echo 'click Button "[ ] Also player builds outside"'; echo "delay 500"
	trim box; leave; chat /look looked; echo quit
} > "$t/2.cmds"
client "$t/2.log" "$t/2.cmds" || fail "the second client's drive ($t/2.log)"
grep -a "menu: trim asks\|wt: at\|trims wt" "$t/2.log" "$t/srv.log" | tail -3 | sed 's/.*\(menu: \|main *: \|wt: \)/\1/' | cut -c 1-200
grep -a "menu: trim asks" "$t/2.log" | grep -aq "1 of them with player builds" ||
	fail "the box with builds did not take the build ($t/2.log)"
grep -a "wt: at the mark" "$t/srv.log" | tail -1 | grep -aq "mark air" ||
	fail "the build is still there ($t/srv.log)"
echo "PASS: the launcher's own game trims its world to a size and to a box, a player build kept unless asked"
