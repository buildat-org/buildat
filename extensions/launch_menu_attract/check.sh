#!/bin/bash
# tier: quick
# cost: 47s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [TWO_AUDIENCES]' third option: the menu stacked over the room in
# attract mode. What is asserted is that both halves came up, that the
# *menu* has the input while the room is behind it, and that the room
# is standing down rather than merely hidden -- it must take no key.
#
#   extensions/launch_menu_attract/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/launch_menu_attract"; mkdir -p "$out"
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "SKIP: SKIP: a buildat client is already running"; exit 77
fi
# A search typed and Escape to clear it, which is the menu's own
# keyboard: its "rows for" line proves the typing went there, and the
# room must not answer the Escape with its pause. Escape on a search
# draws Home again ("rows in"); the half second after it is the room's
# chance to answer the same key, which would be a pause line.
{ echo "wait_log_any 30000 the menu, over the room"
	echo "wait_log_any 30000 rows in"
	echo "text zq"
	echo 'wait_log 5000 rows for "zq"'
	echo "keypress Escape"
	echo "wait_log 5000 rows in"
	echo "delay 500"
	echo "screenshot $out/menu-over-room.png"
	echo "quit"; } > "$out/cmds.txt"
bin/buildat -m launch_menu_attract -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	fail "the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"
if grep -aq "Crash: SIG" "$out/cli.log"; then
	echo "FAIL: the client crashed --" \
			"$(grep -a "Crash: SIG" "$out/cli.log" | head -1)"
	exit 1
fi
room=$(grep -ac "launch_w.*: room: a backdrop" "$out/cli.log")
menu=$(grep -ac "launch_m.*: the menu, over the room" "$out/cli.log")
picked=$(grep -ac 'launch_menu: [0-9]* rows for "zq"' "$out/cli.log")
# The room's own answer to a key: it logs a mode change for Tab and a
# pause for Escape, and a backdrop must do neither
roomkeys=$(grep -acE "launch_w.*: (mode:|pause:)" "$out/cli.log")
echo "the room came up as a backdrop $room, the menu over it $menu," \
		"the menu took $picked search(es), the room answered $roomkeys keys"
if [ "$room" -lt 1 ] || [ "$menu" -lt 1 ]; then
	echo "FAIL: the composition did not come up"
	exit 1
fi
if [ "$picked" -lt 1 ]; then
	echo "FAIL: the menu over the room does not take the keyboard"
	exit 1
fi
# The room logs one "mode:" line at boot, before it is told it is a
# backdrop; anything past that is the room answering input it should not
# be getting
if [ "$roomkeys" -gt 1 ]; then
	echo "FAIL: the room answered $roomkeys keys while it was a backdrop"
	exit 1
fi
# **And a game launched from the composition can be left** -- which is
# not free, and nearly was not there: the composing extension's own
# module has none of the three the client asks a launcher for (it boots
# two others and that is all), so handing it over as the interface
# would wipe what the menu gave and leave a client with no server and
# no menu. They merge, last function wins, and the menu over the room
# is what a game comes back to (2026-09-24).
# ContentDB's page says its rows when drawn; Home is drawn by the time
# "back to Home" is said. The half seconds are the screen laid out in the
# frames after its line.
# simplified: offline, ContentDB's error is a "menu: <message>" and the
# wait for the rows fails the run; a line of the page's own (drawn,
# whatever came) would carry it through
{ echo "wait_log_any 60000 menu: ContentDB "; echo "delay 500"
	echo "event scan 8 a"
	# The row at the bottom of vanilla's menu panel, at this window size
	echo "mouse_pos 639 608"; echo "mouse_click left"
	echo "wait_log 20000 launch_menu: back to Home"; echo "delay 500"
	echo "event scan 8 b"
	echo "delay 500"; echo "quit"; } > "$out/cmds_back.txt"
rm -f "$out/back.log" "$out/back_server.log"
bin/buildat -o launch_ui=launch_menu_attract -a app/vanilla/contentdb \
 -w 1280x720 -l 3 -L "$out/back.log" \
	-c @"$out/cmds_back.txt" > /dev/null 2>&1 ||
	fail "the drive back ($out/back.log): $(grep -ao 'Command sequence failed.*' "$out/back.log" | head -1)"
home=$(grep -a "launch_menu: back to Home" "$out/back.log" | grep -vc wait_log)
lost=$(grep -ac "leave: no launcher to go back to" "$out/back.log")
alive=$(grep -ac "scan b: ui" "$out/back.log")
echo "a game launched from the composition: back to Home $home times," \
		"$alive elements drawn after it"
if [ "$home" -lt 1 ] || [ "$lost" -gt 0 ] || [ "$alive" -lt 10 ]; then
	echo "FAIL: a game launched from the composition cannot be left"
	grep -a "leave:" "$out/back.log" | head -2
	exit 1
fi

# vim: set noet ts=4 sw=4:
echo "PASS: the menu takes the input, the room is the view behind it," \
		"and a game can be left"
exit 0
