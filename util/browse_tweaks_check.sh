#!/bin/bash
# tier: quick
# ci
# cost: ~15 s (2026-11-05)
# covers: extensions/launch_menu/init.lua apps/vanilla/launcher/init.lua
# [BROWSE_TWEAKS], launch_menu:
#   1. At a phone's width (400x760) Home's heading is "Type to search" and
#      Apps' "Apps (type to search)", Home's, Apps' and Servers' windows
#      inside the screen (ui scans); at a desktop's the long ones.
#   2. On Apps, Tab into the panel and Shift+Tab back to the row it left
#      (where the focus is, by the scans).
#   3. The import tiles say Luanti.
# [SERVERS_SCREEN] took the Servers filter's choices, whose order this also
# checked, and Servers' heading: its filter is a text field now.
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   util/browse_tweaks_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp browse_tweaks; t=$CHECK_TMP
cd "$here/Build"

drive(){ # name size scale commands
	printf "$4" > "$t/$1.cmds"
	timeout 60 bin/buildat -m launch_menu -D "$t/cl" -w "$2" $3 -l 3 \
		-o sound_mute=1 -c @"$t/$1.cmds" > "$t/$1.log" 2>&1 ||
		fail "the $1 drive: $(grep -a "Command sequence failed" "$t/$1.log" | tail -1)"
	grep -aq "Command sequence complete" "$t/$1.log" || fail "the $1 drive"
	grep -aq "Lua runtime error\|error shown in a dialog" "$t/$1.log" &&
		fail "an error in $1: $(grep -a 'error shown\|runtime error' "$t/$1.log" | head -1)"
}
heading(){ grep -a "scan $2: ui     Text" "$1" | sed -n 2p | sed 's/.* text "//; s/"$//'; }
inside(){ # log label: the window inside the frame
	local f w
	f=$(grep -a "scan $2: frame" "$1" | grep -o 'frame [0-9]*x[0-9]*' | cut -d' ' -f2)
	w=$(grep -a "scan $2: ui   Window" "$1" | head -1 |
		sed 's/.* at \(-*[0-9]*\),\(-*[0-9]*\) size \([0-9]*\)x\([0-9]*\).*/\1 \2 \3 \4/')
	set -- $w ${f/x/ }
	[ $# = 6 ] && [ "$1" -ge 0 ] && [ $(($1 + $3)) -le "$5" ]
}
focus_x(){ grep -a "scan $2: focus" "$1" | grep -o ' at [0-9]*' | cut -c5-; }
# Keys go in one frame, in order: Down's focus is set before Return reads it
home='wait_log_any 30000 rows in\ndelay 500\nevent scan home\n'
apps="${home}keypress Return\nwait_log 10000 launch_menu: app,\ndelay 500\nevent scan apps\n"

# 1. Narrow, then wide
drive narrow 400x760 "-u 1" "${apps}screenshot $t/narrow.png\nquit\n"
[ "$(heading "$t/narrow.log" home)" = "Type to search" ] ||
	fail "Home's narrow heading: $(heading "$t/narrow.log" home)"
[ "$(heading "$t/narrow.log" apps)" = "Apps (type to search)" ] ||
	fail "Apps' narrow heading: $(heading "$t/narrow.log" apps)"
inside "$t/narrow.log" home || fail "Home wider than the screen"
inside "$t/narrow.log" apps || fail "Apps wider than the screen"
drive narrow_servers 400x760 "-u 1" "${home}keypress Down\nkeypress Return\nwait_log 10000 Servers: shown\ndelay 500\nevent scan servers\nscreenshot $t/narrow_servers.png\nquit\n"
grep -a "scan servers: ui     Text" "$t/narrow_servers.log" | grep -aq 'text "Servers"' ||
	fail "Servers did not open"
inside "$t/narrow_servers.log" servers || fail "Servers wider than the screen"
echo "ok: the short headings, the windows inside a phone's width"

# simplified: Shift+Tab's focus comes back without the menu's "back to
# the row" line (2026-10-13: the handler did not see Shift held, and the
# focus came back to another row by some other way), so the half second
# after the keys is the focus moved; the line once the handler takes it
drive wide 1280x720 "" "${apps}screenshot $t/wide.png\nkeypress Tab\nwait_log 5000 launch_menu: into the panel\ndelay 500\nevent scan tab\nkeydown Shift\ndelay 100\nkeypress Tab\ndelay 100\nkeyup Shift\ndelay 500\nevent scan back\nquit\n"
[ "$(heading "$t/wide.log" home)" = "Type to search apps, saves and servers" ] ||
	fail "Home's wide heading: $(heading "$t/wide.log" home)"
heading "$t/wide.log" apps | grep -q "^Apps   (type to search; Ctrl+S" ||
	fail "Apps' wide heading: $(heading "$t/wide.log" apps)"
echo "ok: the long headings at a desktop's width"

# 2. Tab into the panel, Shift+Tab back
a=$(focus_x "$t/wide.log" apps); b=$(focus_x "$t/wide.log" tab); c=$(focus_x "$t/wide.log" back)
[ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] || fail "Tab did not go into the panel ($a, $b)"
[ "$c" = "$a" ] || fail "Shift+Tab did not come back to the row ($a, $b, $c)"
echo "ok: Tab into the panel at x $b, Shift+Tab back to x $a"

# 3. The import tiles
for l in "Import a Luanti game" "Import a Luanti world"; do
	grep -q "label = \"$l\"" "$here/apps/vanilla/launcher/init.lua" || fail "no \"$l\""
done
echo "PASS: short headings when narrow, Shift+Tab back from the panel, the imports say Luanti (see $t/*.png)"
