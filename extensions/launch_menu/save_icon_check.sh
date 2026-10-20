#!/bin/bash
# tier: quick
# cost: ~30 s (2026-10-15)
# covers: src/client/app_lua.h client/launch_grid.lua client/api.lua extensions/launch_menu/init.lua apps/vanilla/launcher/init.lua
# [SAVE_ICON]: each save shows its own game's picture. A user dir with
# three Luanti games installed for vanilla, each its own icon, and five
# saves: one of each game, one of a game not installed and one with no
# game id. A search for each save puts it first; its row's icon is its
# game's, and vanilla's grass block for the last two. A fourth game's
# icon a link out of its directory: not copied ([SECURITY_RUN_7]).
#
#   extensions/launch_menu/save_icon_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
check_tmp save_icon; t=$CHECK_TMP
cd "$(dirname "$0")/../../Build"
u="$t/cl"
for g in alpha beta gamma; do
	mkdir -p "$u/shared/vanilla/games/$g/menu"
	printf 'title = %s\n' "$g" > "$u/shared/vanilla/games/$g/game.conf"
	# A 1x1 PNG, a colour each so no two are the same file
	python3 -c "import zlib,struct,sys
def c(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d))
sys.stdout.buffer.write(b'\x89PNG\r\n\x1a\n'+c(b'IHDR',struct.pack('>IIBBBBB',1,1,8,2,0,0,0))+c(b'IDAT',zlib.compress(b'\0'+bytes([$RANDOM%256,10,20])))+c(b'IEND',b''))" \
		> "$u/shared/vanilla/games/$g/menu/icon.png"
done
# [SECURITY_RUN_7] A fourth game whose icon is a link to a picture of the
# user's own, outside its directory (an app's box writes there): not
# copied into the cache, where any script would read its pixels
mkdir -p "$u/shared/vanilla/games/delta/menu"
printf 'title = delta\n' > "$u/shared/vanilla/games/delta/game.conf"
cp "$u/shared/vanilla/games/alpha/menu/icon.png" "$t/private.png"
ln -s "$t/private.png" "$u/shared/vanilla/games/delta/menu/icon.png"
save() { # name gameid (empty: none)
	mkdir -p "$u/apps/vanilla/saves/$1"
	sqlite3 "$u/apps/vanilla/saves/$1/save.sqlite" \
		"CREATE TABLE store (store TEXT NOT NULL, key TEXT NOT NULL, value BLOB, PRIMARY KEY(store, key));" \
		${2:+"INSERT INTO store VALUES ('main', 'gameid', '$2');"}
}
save sv_alpha alpha; save sv_beta beta; save sv_gamma gamma
save sv_gone realtest; save sv_none ""
{
	echo "wait_log_any 30000 rows in"
	for s in alpha beta gamma gone none; do
		echo "text sv_$s"; echo "wait_log 5000 rows for \"sv_$s\""
		for _ in $(seq 8); do echo "keypress Backspace"; done
		echo "delay 300"
	done
	echo quit
} > "$t/cmds"
timeout 90 bin/buildat -o launch_ui=launch_menu -D "$u" -C "$t/cache" \
	-w 1024x640 -l 3 -o sound_mute=1 -c @"$t/cmds" > "$t/cl.log" 2>&1 ||
	fail "the menu's drive ($t/cl.log): $(grep -ao 'Command sequence failed.*' "$t/cl.log" | head -1)"
row() { grep -ao "rows for \"sv_$1\" in [0-9]* ms, first sv_$1 ([^)]*)" "$t/cl.log" |
	head -1 | sed 's/.*(\(.*\))$/\1/'; }
for g in alpha beta gamma; do
	i=$(row $g)
	echo "$i" | grep -q "$g" || fail "sv_$g shows \"$i\", not $g's icon"
done
for s in gone none; do
	i=$(row $s)
	[ "$i" = "vanilla/launcher/grass_block.png" ] ||
		fail "sv_$s shows \"$i\", not vanilla's grass block"
done
[ ! -e "$t/cache/installed_games/vanilla/delta.png" ] ||
	fail "a game's icon linked out of its directory was copied into the cache"
echo "PASS: each save shows its game's icon, the grass block without one; a linked icon not copied"
