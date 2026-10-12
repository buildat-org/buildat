#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-12)
# covers: apps/vanilla/main/client_lua/init.lua src/lua_bindings/misc_urho3d.cpp client/extensions/urho3d/init.lua
# [LOADING_PIC_DECODE]: vanilla's loading picture is decoded once into a
# texture, with no file written. The minimal game copied as "pic", with a
# menu/background.png:
#   1. VoxeLibre's largest (2.1 MB, 1920x1080): shown in under 0.2 s by
#      the handler's own count (1.1 s through compose_image, 2026-10-12);
#      nothing written under vanilla_loading/ but glyphs.
#   2. A 5000x10 PNG: refused with a warning, the world loaded without it.
# The picture as drawn is loading_screen_check's.
# Needs mineclone2 in the desk's games.
#   util/loading_pic_decode_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || skip "no mineclone2"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp loading_pic_decode; t=$CHECK_TMP
P=$t/srv/shared/vanilla/games/pic
mkdir -p "$t/srv/apps/vanilla/saves/pd/luanti" "$(dirname "$P")"
cp -r "$here/builtin/luanti/minimal_game" "$P"
mkdir -p "$P/menu"
echo "enable_damage = false" > "$t/srv/apps/vanilla/saves/pd/luanti/world.mt"
printf "wait_log 120000 load: the world is in\nquit\n" > "$t/cmds"
# join <n>: a server and a client on the picture there is now
join(){
	BUILDAT_LUANTI_GAME=pic BUILDAT_LUANTI_SAVE=pd start_server "$t/srv$1.log" \
		"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
		-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 ||
		fail "the server ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
	run_client 60 "$t/$1.log" timeout 200 "$here/Build/bin/buildat" -C "$t/c$1" \
		-D "$t/u$1" -w 800x450 -l 3 -o sound_mute=1 \
		-s "127.0.0.1:$SERVER_PORT" -c @"$t/cmds"
	kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
	grep -aq "load: the world is in" "$t/$1.log" || fail "join $1 not loaded ($t/$1.log)"
}

# 1.
cp "$(ls -S "$G"/menu/background*.png | head -1)" "$P/menu/background.png"
join 1
line=$(grep -a "vanilla : load: the picture background.png" "$t/1.log" | sed 's/.*load: //')
echo "$line"
ms=$(echo "$line" | grep -oP "1920x1080 in \K[0-9]+(?= ms)") || fail "no picture shown ($t/1.log)"
[ "$ms" -lt 200 ] || fail "the picture took $ms ms"
# Anywhere in the run's files; the glyphs are drawn on a slow join only
other=$(find "$t" -path "*vanilla_loading/*" ! -name "glyph_*")
[ -z "$other" ] || fail "files besides the glyphs: $other"

# 2.
python3 -c 'import sys; from PIL import Image; Image.new("RGB", (5000, 10)).save(sys.argv[1])' \
	"$P/menu/background.png"
join 2
grep -a "load: the picture background.png not read" "$t/2.log" | sed 's/.*load: //'
grep -aq "W vanilla : load: the picture background.png not read" "$t/2.log" ||
	fail "the 5000x10 picture not refused ($t/2.log)"
echo "PASS: the loading picture decoded once in $ms ms, no file; a 5000x10 one refused"
