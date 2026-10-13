#!/bin/bash
# tier: full
# cost: ~120s (2026-10-04)
# covers: apps/vanilla/main/client_lua/pause.lua close() clearing the UI focus
# [PAUSE_VOLUME_KEYS]: a pause-menu button clicked here stayed the UI's focus
# element after its window was gone, and then Space (jump) and Enter worked it
# from the world -- a jump cycled the view range and the volume. close() now
# calls magic.ui:SetFocusElement(nil).
#
# Driven in a minimal world: open the pause menu, pick a view range from its
# dropdown, which leaves it focused (logs "view range: N"), close the menu
# with Escape, then jump five times with Space. With the focus cleared the
# jumps reach the world and the range is unchanged; with the bug the detached
# control fires, logging more "view range:" lines.
#
# Scripted keypresses are dropped now and then (a known flake of the driver),
# so a run only counts when it is conclusive: the click registered AND the menu
# is confirmed closed afterwards. F5 (the detail line) is the probe -- while the
# menu holds input a world key is swallowed, so a status line printed after the
# jumps means the menu really closed. Inconclusive runs are retried.
#
#   util/pause_keys_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here/Build"
[ -x bin/buildat_server ] || { echo "FAIL: no bin/buildat_server"; exit 1; }
[ -x bin/buildat ] || { echo "FAIL: no bin/buildat"; exit 1; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }

t=$(mktemp -d)
srv=
trap '[ -n "$srv" ] && kill $srv 2>/dev/null; rm -rf "$t"' EXIT
nolog(){ cat "$1"; }
fail(){ echo "FAIL: $*"; exit 1; }

port=29592
# A launcher-started server is local ([VANILLA_PUBLIC]) and auto-starts the
# bundled minimal game (no ContentDB), so the client lands in a world.
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=pausekeys \
start_server "$t/srv.log" "STATUS Listening" 60 "$port" \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -D "$t/srv" -l 3 ||
	fail "server did not listen"
srv=$SERVER_PID

# A line logged by sky_now.set_range alone, not the F5 status line (which has
# the range mid-string): "<ts> I vanilla : view range: N" and nothing after.
vr_changes(){ nolog "$1" | grep -cE 'vanilla : view range: [0-9]+$'; }
# The F5 status line, printed only when the menu is not holding input.
menu_closed(){ nolog "$1" | grep -qE 'vanilla : .*FPS:.*view range:'; }

run_drive(){
	{
		echo "wait_log 60000 the server put the player"
		# Past the server's reposition of a spawned player onto meshed
		# ground (a second "put the player"), which eats a key pressed too
		# soon and leaves the menu unopened: the world settled, and the
		# two seconds after it for the reposition, which the client does
		# not tell apart from the first
		echo "wait_log 60000 scene, 0 undrawn within 2"
		echo "delay 2000"
		echo "keypress Escape"
		echo "wait_log 5000 pause: the menu shown"
		# The view range is the pause menu's one dropdown; its popup opens
		# in the frames after the click
		echo 'click DropDownList "▼"'
		echo "delay 500"
		echo "keypress Up"
		echo "delay 200"
		echo "keypress Return"
		echo "wait_log 5000 view range: "
		echo "keypress Escape"
		echo "wait_log 5000 pause: the menu closed"
		# Five jumps, apart
		printf 'keypress Space\ndelay 300\n%.0s' 1 2 3 4 5
		echo "keypress F5"
		echo "wait_log 5000 FPS:"
		echo "quit"
	} > "$t/seq.$1"
	timeout 90 bin/buildat -o launch_ui=launch_menu -s "127.0.0.1:$port" -D "$t/$1" \
		-w 1000x700 -u 1 -l 3 -o sound_mute=1 -c @"$t/seq.$1" \
		> "$t/$1.log" 2>&1
}

conclusive=0
for a in 1 2 3 4 5; do
	run_drive "a$a"
	log="$t/a$a.log"
	grep -qF "the server put the player" "$log" ||
		fail "client did not reach the world
$(nolog "$log" | grep -iE 'error|refused|luanti' | tail -5)"
	vr=$(vr_changes "$log")
	# The pick must have changed the range once, or the menu/button was not
	# where expected; and F5 afterwards must prove the menu actually closed.
	if [ "$vr" -ge 1 ] && menu_closed "$log"; then
		conclusive=1
		break
	fi
done
[ "$conclusive" = 1 ] ||
	fail "no conclusive run in 5 tries (a dropped keypress every time, or no view-range dropdown)"

# Menu confirmed closed. Exactly one change (the click) means the Space jumps
# did not reach the focused button; more means the button fired from the world.
if [ "$vr" -gt 1 ]; then
	fail "after the pause menu closed, Space still worked the focused view-range \
dropdown ($vr range changes, expected 1) -- the UI focus is not being cleared in \
pause.lua close()"
fi

echo "PASS: a focused pause-menu button does not fire from the world after the menu is closed"
