#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-11)
# covers: apps/vanilla/main/main.cpp apps/vanilla/main/client_lua/menu.lua builtin/luanti/media.h
# [WORLD_TXP]: a texture pack chosen per world. Vanilla on the minimal
# game, worlds w1 and w2, a local pack "magenta" of one recoloured
# floor_stone.png under texture_packs/:
#   1. The menu, driven: w1's Texture pack... lists None and magenta;
#      magenta chosen; Remove refused while w1 has it; Play: the client's
#      cache gets the pack's floor_stone.png.
#   2. w2 starts without it.
#   3. The menu: w1 back to None, then magenta removed to the trash; w1
#      starts without it.
#   4. With the network: ContentDB's texture packs listed.
# simplified: the ContentDB install itself is not driven (a real pack's
# download); it is the mods' install with another directory.
#   util/world_txp_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp world_txp; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/u
mkdir -p "$d/shared/vanilla/texture_packs/magenta"
python3 - "$d/shared/vanilla/texture_packs/magenta" <<'PY'
import sys
from PIL import Image
Image.new("RGB", (16, 16), (255, 0, 255)).save(sys.argv[1] + "/floor_stone.png")
open(sys.argv[1] + "/texture_pack.conf", "w").write("name = magenta\n")
PY
sum=$(md5sum < "$d/shared/vanilla/texture_packs/magenta/floor_stone.png" | cut -d' ' -f1)
serve(){
	local log=$1 kv rc; shift
	for kv in "$@"; do export "$kv"; done
	start_server "$log" "STATUS Listening" 60 auto "$here/Build/bin/buildat_server" \
		-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" -C "$t/c" -l 3
	rc=$?
	CHECK_PIDS+=($SERVER_PID)
	for kv in "$@"; do unset "${kv%%=*}"; done
	[ $rc = 0 ] || fail "the server ($log)"
}
stop(){ kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }
# client <log> <cmds> <cache>
client(){
	run_client 60 "$1" timeout 300 "$here/Build/bin/buildat" -C "$3" \
		-D "$t/nu" -s 127.0.0.1:$SERVER_PORT -w 1100x900 -u 1 -l 3 \
		-o sound_mute=1 -c @"$2" ||
		fail "the drive ($1: $(grep -a "Command sequence failed\|run_client:" "$1" | tail -1))"
}
# has_pack <cache>: the pack's picture somewhere in the client's cache
has_pack(){
	find "$1" -type f -size -2k -print0 2>/dev/null | xargs -0 -r md5sum |
		grep -q "^$sum "
}
printf "wait_log 60000 vanilla client ready\nquit\n" > "$t/play.cmds"
# The two worlds, made by a start each
for w in w1 w2; do
	serve "$t/$w.0.log" BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=$w
	wait_for_log "$t/$w.0.log" "Mods loaded" 60 || fail "$w at first ($t/$w.0.log)"
	stop
done

# 1
# The delays: a settle after a line
cat > "$t/1.cmds" <<C
wait_log_any 60000 menu: 2 saves
delay 1000
click Button "w1*"
wait_log 10000 menu: the world w1 shown
click Button "Texture pack..."
wait_log 10000 menu: world texture pack of w1
delay 500
click Button "( ) magenta"
wait_log 10000 magenta from the world's next start
delay 500
screenshot $t/1_chosen.png
click Button "Remove"
wait_log 5000 confirm dialog: Move magenta
click Button "Remove"
wait_log 10000 magenta is not removed: the texture pack of w1
delay 500
click Button "< back"
# The list comes back with w1 still selected (a click on it would play it)
wait_log 10000 menu: the world w1 shown
click Button "Play"
wait_log 60000 vanilla client ready
quit
C
serve "$t/m1.log"
client "$t/1.log" "$t/1.cmds" "$t/c1"
stop
grep -a "menu: world texture pack" "$t/1.log" | sed 's/.*menu: /  /'
grep -aq "menu: world texture pack of w1: magenta | magenta is not removed" "$t/1.log" ||
	fail "the menu ($t/1.log)"
grep -aq "texture pack: magenta" "$t/m1.log" || fail "w1 did not serve the pack ($t/m1.log)"
has_pack "$t/c1" || fail "the client did not get the pack's picture ($t/c1)"
echo "ok: w1 with magenta"

# 2
serve "$t/w2.log" BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=w2
client "$t/2.log" "$t/play.cmds" "$t/c2"
stop
grep -aq "texture pack:" "$t/w2.log" && fail "w2 served a pack ($t/w2.log)"
has_pack "$t/c2" && fail "w2's client got the pack's picture"
echo "ok: w2 without it"

# 3
cat > "$t/3.cmds" <<C
wait_log_any 60000 menu: 2 saves
delay 1000
click Button "w1*"
wait_log 10000 menu: the world w1 shown
click Button "Texture pack..."
wait_log 10000 menu: world texture pack of w1
delay 500
click Button "( ) None*"
wait_log 10000 No texture pack from the world's next start
delay 500
click Button "Remove"
wait_log 5000 confirm dialog: Move magenta
click Button "Remove"
wait_log 10000 magenta moved to the trash
delay 500
click Button "< back"
# The list comes back with w1 still selected (a click on it would play it)
wait_log 10000 menu: the world w1 shown
click Button "Play"
wait_log 60000 vanilla client ready
quit
C
serve "$t/m3.log"
client "$t/3.log" "$t/3.cmds" "$t/c3"
stop
grep -a "menu: world texture pack" "$t/3.log" | sed 's/.*menu: /  /'
grep -aq "menu: world texture pack of w1:  | magenta moved to the trash" "$t/3.log" ||
	fail "the menu ($t/3.log)"
[ -d "$d/shared/vanilla/texture_packs/magenta" ] && fail "magenta still installed"
ls -d "$d/shared/vanilla/trash/txp_magenta-"* > /dev/null || fail "magenta not in the trash"
grep -aq "texture pack:" "$t/m3.log" && fail "w1 still served a pack ($t/m3.log)"
has_pack "$t/c3" && fail "w1's client still got the pack's picture"
echo "ok: w1 back to None, magenta removed"

# 4
if curl -s -m 10 -o /dev/null https://content.luanti.org/api/packages/?limit=1; then
	cat > "$t/4.cmds" <<C
wait_log_any 60000 menu: 2 saves
delay 1000
click Button "w1*"
wait_log 10000 menu: the world w1 shown
click Button "Texture pack..."
wait_log 10000 menu: world texture pack of w1
delay 500
click Button "Get texture packs from ContentDB..."
wait_log 60000 menu: ContentDB txps:
delay 500
screenshot $t/4_contentdb.png
quit
C
	serve "$t/m4.log"
	client "$t/4.log" "$t/4.cmds" "$t/c4"
	stop
	grep -a "menu: ContentDB txps:" "$t/4.log" | sed 's/.*menu: /  /'
	grep -aq "menu: ContentDB txps: [1-9][0-9]* rows" "$t/4.log" ||
		fail "no texture packs from ContentDB ($t/4.log)"
else
	echo "(no network: ContentDB not asked)"
fi
echo "PASS: a texture pack chosen for one world is served there alone, kept while used, removed once not"
