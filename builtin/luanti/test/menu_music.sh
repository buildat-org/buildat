#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: 60s
# covers: src/client/app.cpp builtin/luanti/client_lua/module.lua
# [MENU_MUSIC]: **does a game's music stop when the player leaves to the
# launch menu**. The launcher's own path (-a, the client starting the
# server), devtest with menu_music.lua looping one sound at the player and
# never stopping it, then the pause menu's "Leave the game" and six seconds
# in the launch menu. The mix goes to a file (SDL_AUDIODRIVER=disk, as
# sound.sh, which has the why of it); its size is taken when the client
# logs leave_to_menu(), and the peak of the second before is held against
# the peak from two seconds after it to the end.
#
#   builtin/luanti/test/menu_music.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/menu_music"; mkdir -p "$out"
save=menu_music_check
cd "$here/Build"
[ -d "$BUILDAT_USER_PATH/shared/vanilla/games/devtest" ] || {
	echo "SKIP: devtest is not installed" >&2; exit 77; }
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running" >&2; exit 77
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
rm -f "$out/mix.raw" "$out/cli.log" "$out/cli_server.log"
# The pause menu's last button at 1000x700 and UI scale 1. The second
# after the loop starts is the "before" the mix is measured on; the 300 ms
# after the pause menu's line its layout's frames; the six seconds in the
# launch menu the "after" measured
cat > "$out/cmds.txt" <<EOF
wait_log 120000 the server put the player
wait_log 20000 luanti:sound: soundstuff_mono
delay 1000
keypress escape
wait_log 5000 pause: the menu shown
delay 300
mouse_pos 500 515
mouse_click left
wait_log 10000 leave_to_menu()
# a timing test: the six seconds in the launch menu measured
delay 6000
quit
EOF
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=$save \
	BUILDAT_LUANTI_LUA="$me/menu_music.lua" \
	SDL_AUDIODRIVER=disk SDL_DISKAUDIOFILE="$out/mix.raw" \
	timeout 200 bin/buildat -a builtin/luanti/devtest -w 1000x700 -u 1 -l 4 \
	-o sound_mute=0 -L "$out/cli.log" -c @"$out/cmds.txt" > /dev/null 2>&1 &
cli=$!
at_leave=
while kill -0 $cli 2>/dev/null; do
	# Not the drive's own wait for it
	if [ -z "$at_leave" ] && grep -a "leave_to_menu()" "$out/cli.log" 2>/dev/null |
		grep -qv wait_log
	then
		at_leave=$(stat -c %s "$out/mix.raw")
		# A timing: the two seconds after the leave that are not measured
		sleep 2
		after_from=$(stat -c %s "$out/mix.raw")
	fi
	sleep 0.1 # a poll
done
wait $cli; st=$?
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
[ $st = 0 ] ||
	{ echo "FAIL: the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"; exit 1; }
grep -aq "menu music: looping" "$out/cli_server.log" ||
	{ echo "FAIL: the fixture never started its loop"; exit 1; }
[ -n "$at_leave" ] ||
	{ echo "FAIL: no leave_to_menu() (the click on Leave the game missed)"; exit 1; }
[ -s "$out/mix.raw" ] ||
	{ echo "SKIP: the client wrote no mix; this SDL has no disk driver"; exit 77; }
# peak <from> <to>: the largest sample of the raw 16-bit mix in that range
peak(){
	python3 - "$out/mix.raw" "$1" "$2" <<'PYEOF'
import sys, array
start, end = int(sys.argv[2]) // 2 * 2, int(sys.argv[3]) // 2 * 2
with open(sys.argv[1], "rb") as f:
    f.seek(start)
    a = array.array("h")
    a.frombytes(f.read(max(0, end - start)))
print(max(max(a), -min(a)) if a else 0)
PYEOF
}
size=$(stat -c %s "$out/mix.raw")
# A second of the mix is what grew in the two seconds after the leave, halved
second=$(( (after_from - at_leave) / 2 ))
before=$(peak $((at_leave - second)) "$at_leave")
after=$(peak "$after_from" "$size")
echo "the second before the leave peaked at $before; the menu after it at" \
	"$after ($(( (size - after_from) / (second > 0 ? second : 1) )) s)"
[ "$before" -ge 200 ] ||
	{ echo "FAIL: the loop was not heard in the game"; exit 1; }
if [ "$after" -ge 200 ]; then
	echo "FAIL: the game's loop goes on playing in the launch menu"
	exit 1
fi
echo "PASS: a game's looped sound stops when the player leaves to the menu"
