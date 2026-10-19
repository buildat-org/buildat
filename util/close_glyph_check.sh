#!/bin/bash
# tier: quick
# cost: ~1 min (2026-10-10)
# covers: extensions/ui_utils/init.lua extensions/launch_menu/init.lua client/core/starport/init.lua
# [CLOSE_GLYPH]: launch_menu at a phone's size in the touch mode
# (BUILDAT_TOUCH=1, 400x760), and at a desktop's:
#   1. Home, the first screen, has no ×.
#   2. Apps has one, inside its window's top right corner (ui scan).
#   3. A tap on it closes Apps as Escape does: Home is back.
#   4. Starport settings (open_window) has one too, and a click on it
#      closes it.
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   util/close_glyph_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp close_glyph; t=$CHECK_TMP
cd "$here/Build"

drive(){ # name size commands [env...]
	local name=$1 size=$2
	printf "$3" > "$t/$name.cmds"
	shift 3
	# A phone's UI scale given; a desktop's the automatic one, which keeps
	# a window off the screen's top, where the Starport overlay is
	local scale=""
	[ "$size" = 400x760 ] && scale="-u 1"
	env "$@" timeout 40 bin/buildat -m launch_menu -D "$t/cl" -w "$size" $scale \
		-l 3 -o sound_mute=1 -c @"$t/$name.cmds" > "$t/$name.log" 2>&1
	grep -aq "Command sequence complete" "$t/$name.log" || fail "the $name drive"
	grep -aq "Lua runtime error\|error shown in a dialog" "$t/$name.log" &&
		fail "an error in $name: $(grep -a 'error shown' "$t/$name.log" | head -1)"
}
# The ×'s centre, if inside the top right of the top window: "x y"
glyph(){ # log label
	grep -a "scan $2: " "$1" | python3 -c '
import re, sys
win = None
for l in sys.stdin:
	m = re.search(r"ui( +)(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)(.*)", l)
	if not m:
		continue
	x, y, w, h = map(int, m.groups()[2:6])
	if m.group(2) == "Window" and win is None:
		win = (x, y, w, h)
	if "text \"×\"" in m.group(7):
		cx, cy = x + w // 2, y + h // 2
		wx, wy, ww, wh = win
		if wx + ww - 50 <= cx <= wx + ww and wy <= cy <= wy + 50:
			print(cx, cy)
		else:
			print("outside", (cx, cy), win)
		break'
}
# The delays: 300-500 ms for the screen drawn after its line (or after
# Escape, which logs nothing at -l 3), 300 ms for the pointer's hover;
# "close_glyph: closing" is logged before the window goes
home='wait_log_any 20000 rows in\ndelay 500\nevent scan home\n'
apps="${home}keypress Return\nwait_log 5000 rows, by\ndelay 300\nevent scan apps\n"

# 1, 2: at a phone's size
drive phone 400x760 "${apps}screenshot $t/phone.png\nquit\n" BUILDAT_TOUCH=1
grep -a "scan home: " "$t/phone.log" | grep -aq '"×"' && fail "Home has a ×"
grep -a "scan apps: " "$t/phone.log" | grep -aq 'menu ".*launch_menu app"' ||
	fail "Apps did not open"
at=$(glyph "$t/phone.log" apps)
case "$at" in [0-9]*) ;; *) fail "the × on Apps: '$at'" ;; esac
echo "ok: none on Home, Apps' at $at, its window's top right"

# 3: a tap on it
drive tap 400x760 "${apps}mouse_pos $at\ndelay 300\nmouse_click left\nwait_log 5000 close_glyph: closing\ndelay 500\nevent scan after\nquit\n" BUILDAT_TOUCH=1
grep -aq "close_glyph: closing" "$t/tap.log" || fail "the tap did not reach the ×"
grep -a "scan after: " "$t/tap.log" | grep -aq 'menu ".*: launch_menu"' ||
	fail "not Home after the tap: $(grep -a 'scan after: menu' "$t/tap.log")"
echo "ok: the tap closed Apps"

# 4: at a desktop's size, Apps and Starport settings
drive desk 1280x720 "${apps}screenshot $t/desk.png\nkeypress Escape\ndelay 300\nclick Button \"Starport settings...\"\nwait_log 5000 starport: the settings shown\ndelay 300\nevent scan sp\nscreenshot $t/starport.png\nquit\n"
glyph "$t/desk.log" apps | grep -q '^[0-9]' || fail "no × on Apps at a desktop's size"
at=$(glyph "$t/desk.log" sp)
case "$at" in [0-9]*) ;; *) fail "the × on Starport settings: '$at'" ;; esac
drive spclose 1280x720 "${home}click Button \"Starport settings...\"\nwait_log 5000 starport: the settings shown\ndelay 300\nmouse_pos $at\ndelay 300\nmouse_click left\nwait_log 5000 close_glyph: closing\ndelay 500\nevent scan after\nquit\n"
grep -a "scan after: " "$t/spclose.log" | grep -aq 'menu ".*: launch_menu"' ||
	fail "Starport settings not closed: $(grep -a 'scan after: menu' "$t/spclose.log")"
echo "PASS: no × on Home; Apps' and Starport settings' in their top right, a tap or click closes them (see $t/*.png)"
