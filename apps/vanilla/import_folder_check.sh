#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-10)
# covers: apps/vanilla/main/main.cpp apps/vanilla/main/client_lua/menu.lua src/client/app_lua.h
# [LUANTI_IMPORT_FOLDER]: the Luanti imports read <user>/shared/vanilla/
# import, with the local server sandboxed as it is by default. In it: a
# game (minetest_game, a game.conf alone) and three worlds -- "oldmtg"
# made as gameid = minetest, "other" wanting a game nobody has, "bare"
# with no gameid.
#   1. "Import a Luanti game" lists minetest_game; a click selects it
#      (the panel says where it was found), Import copies it in.
#   2. "Import a Luanti world" lists oldmtg as minetest_game's (installed
#      now), other as needing its game, and says one world was left out;
#      selecting oldmtg and Import makes a save of it.
#   3. The "Open the import folder" button is there (not pressed: it
#      would open a file manager on the desk).
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   apps/vanilla/import_folder_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
[ -z "${BUILDAT_UNCONFINED:-}" ] || { echo "SKIP: BUILDAT_UNCONFINED is set; this is the sandboxed case"; exit 0; }
check_tmp import_folder; t=$CHECK_TMP
cd "$here/Build"

imp="$t/cl/shared/vanilla/import"
mkdir -p "$imp/games/minetest_game/mods" "$imp/worlds/oldmtg" \
	"$imp/worlds/other" "$imp/worlds/bare"
printf 'title = Minetest Game\nname = Minetest Game\n' > "$imp/games/minetest_game/game.conf"
printf 'gameid = minetest\nbackend = sqlite3\n' > "$imp/worlds/oldmtg/world.mt"
# An empty map, which the importer reads as a world with nothing in it yet
python3 -c 'import sqlite3, sys; sqlite3.connect(sys.argv[1]).execute("CREATE TABLE blocks (pos INT PRIMARY KEY, data BLOB)")' \
	"$imp/worlds/oldmtg/map.sqlite"
printf 'gameid = nosuchgame\n' > "$imp/worlds/other/world.mt"
printf 'backend = sqlite3\n' > "$imp/worlds/bare/world.mt"

drive(){ # name commands
	printf "$2" > "$t/$1.cmds"
	timeout 150 bin/buildat -m launch_menu -D "$t/cl" -w 1280x720 -l 3 \
		-o sound_mute=1 -c @"$t/$1.cmds" > "$t/$1.log" 2>&1
	grep -aq "Command sequence complete" "$t/$1.log" ||
		fail "the $1 drive ($(grep -a 'menu: \|Command seq' "$t/$1.log" | tail -3))"
	grep -aq "Lua runtime error\|error shown in a dialog" "$t/$1.log" &&
		fail "an error in $1: $(grep -a 'error shown\|runtime error' "$t/$1.log" | head -1)"
}
open(){ echo "wait_log_any 20000 launch_menu: \ndelay 1500\ntext $1\ndelay 800\nkeypress Return\nwait_log 90000 worlds to import\ndelay 1500\n"; }

# 1. The game
drive game "$(open "import a luanti game")event scan games\nclick Button \"minetest_game   Minetest Game\"\ndelay 800\nevent scan sel\nscreenshot $t/game.png\nclick Button \"Import\"\nwait_log 30000 imported\ndelay 1000\nquit\n"
grep -aq "menu: 1 games and 2 worlds to import, 1 without a gameid" "$t/game.log" ||
	fail "what was found: $(grep -a 'to import' "$t/game.log" | head -1)"
grep -a "scan sel: " "$t/game.log" | grep -aq "Found in: .*shared/vanilla/import" ||
	fail "the panel: $(grep -a 'scan sel: .*Text' "$t/game.log" | head -8)"
grep -a "scan games: " "$t/game.log" | grep -aq 'text "Open the import folder"' ||
	fail "no Open the import folder button"
[ -f "$t/cl/shared/vanilla/games/minetest_game/game.conf" ] || fail "the game not copied in"
echo "ok: the game listed from the import folder, its panel, imported"

# 2. The worlds
drive world "$(open "import a luanti world")event scan worlds\nscreenshot $t/worlds.png\nclick Button \"oldmtg   minetest_game\"\ndelay 800\nevent scan sel\nclick Button \"Import\"\ndelay 5000\nquit\n"
sc=$(grep -a "scan worlds: " "$t/world.log")
echo "$sc" | grep -aq 'text "needs nosuchgame' || fail "other's badge: $(echo "$sc" | grep -a other | head -3)"
echo "$sc" | grep -aq 'text "Not listed: 1 world with no gameid in world.mt"' ||
	fail "the skipped line"
echo "$sc" | grep -aq 'needs minetest' && fail "oldmtg reads as needing its game"
grep -a "scan sel: " "$t/world.log" | grep -aq 'text "Game: minetest_game"' ||
	fail "oldmtg's game: $(grep -a 'scan sel: .*Game' "$t/world.log" | head -2)"
# The server's log is not one wait_log sees
grep -aq "import_world(): .*worlds/oldmtg read into the world" "$t/world.log" ||
	fail "oldmtg not imported: $(grep -a 'Importing world\|import_world\|luanti: ' "$t/world.log" | head -3)"
echo "ok: the worlds, minetest as minetest_game, the needing one, the skipped count; oldmtg imported"
echo "PASS: the Luanti imports read the import folder under the sandboxed server, as a list and a panel (see $t/*.png)"
