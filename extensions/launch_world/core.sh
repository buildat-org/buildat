#!/bin/bash
# extensions/launch_world: the room's **core** check -- the one to run
# after touching `world.lua`. One client, about a minute: the room boots,
# draws, moves between its stations, launches a game and comes back from it, and
# nothing in the sandbox raised while it did.
#
#   extensions/launch_world/core.sh
#
# **check.sh is the whole of it** -- fifteen clients and twenty minutes --
# and is what a push runs ([CHECK_COST], user 2026-09-25: "twenty minutes
# is never the right answer to a one-word change"). This is what covers
# an edit; the full one covers a release.
#
# tier: quick
# cost: 60s
# covers: apps/digger/**
# (it launches digger by name and leaves it again, which is that game's
# client Lua starting, drawing and answering Escape)
#
# It keeps util/check_lib.sh's contract ([CI_RUNS] (1)): exit 0
# passed, 1 failed, 2 could not run, and a last line saying which.
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/launch_world_core"; mkdir -p "$out"
rm -f "$out"/*.png
# The room's description asserts itself first, and costs nothing
lua "$here/extensions/launch_world/room.lua" || exit 1
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi

# **Waits, not delays**: the room says when it is up ("the room hums"),
# when a game has the view and when it is back, so nothing here is timed
# by guesswork -- which is what makes the same drive a minute on this
# desk and still right at one frame a second in a container.
{ echo "wait_log_any 60000 the room hums"
	echo "delay 500"
	echo "screenshot $out/stood.png"
	# Tab is the next station, the floor: the camera flies there
	echo "keypress Tab"
	echo "wait_log 10000 camera: landed"
	echo "screenshot $out/moved.png"
	# Back at the wall, typing a name flies to that orb and Return
	# launches it
	echo "event mode menu"
	echo "wait_log 10000 camera: landed"
	for c in D I G G E R; do echo "keypress $c"; done
	echo "wait_log 10000 camera: landed"
	echo "keypress Return"
	echo "wait_log 60000 game: the room stands down"
	# The room stands down on its own clock, and digger may still be
	# compiling: its player placed is the game up, Escape heard
	echo "wait_log_any 60000 player physics enabled"
	echo "delay 500"
	# **The way out is the game's own** ([NO_WAY_BACK]): Escape runs
	# buildat.leave(), which comes back here because there is a launcher
	echo "keypress Escape"
	echo "wait_log 20000 game: back in the room"
	echo "delay 500"  # a settle: the room drawn again
	echo "screenshot $out/back.png"
	# **And the room is moving again**: nothing in it is ever static, so
	# two frames apart say whether coming back left a screen on top of
	# it ([MENU_STUCK]) or an animation stood down ([LAUNCH_FROZEN])
	echo "delay 700"
	echo "screenshot $out/back2.png"
	# **The attract drift** ([LAUNCH_WORLD] section 12): started at once
	# rather than after 14 s of quiet, and stopped by a key
	echo "event room attract"
	echo "wait_log 10000 attract: over the wall"
	echo "keypress Down"
	echo "wait_log 5000 attract: back to the standing place"
	# **The 2D menu and back** ([LAUNCH_WORLD] stage 2's done-when): the
	# dialog's third row (launch_menu, the room closed), then its
	# Display and sound by the keyboard -- typed and taken, the Launch UI
	# row opened and the room picked from the list, which boots a new
	# one. One Tab afterwards is one station: a window of the menu's left
	# on top, or the old room still listening, makes it none or two.
	# A settle: the drift's camera on its way back to the standing place
	echo "delay 1500"
	echo "keypress Escape"
	echo "wait_log 5000 pause: open"
	echo "keypress Down"
	echo "keypress Down"
	echo "keypress Return"
	echo "wait_log 10000 room: closed"
	echo "wait_log_any 10000 rows in"
	echo "delay 300"
	echo "text dis"
	echo "wait_log 5000 rows for \"dis\""
	echo "keypress Return"
	echo "wait_log 5000 Engine settings shown"
	# Up twice, past Back: the Launch UI row, then in its list the room,
	# the last entry. The 200 ms are the menu's focus moving a key at a time
	for w in "Launch UIs shown" "has the screen again"; do
		echo "keypress Up"; echo "delay 200"; echo "keypress Up"; echo "delay 200"
		echo "keypress Return"; echo "wait_log 10000 $w"
	done
	# A settle: the new room's keys listened for in the ticks after
	echo "delay 1500"
	echo "keypress Tab"
	echo "wait_log 10000 camera: landed"
	echo "quit"
	} > "$out/cmds.txt"
# **A user directory of its own**: the desk's has saves and servers and
# a room somebody moved things in, and a check that reads "the room
# boots and launches" should not depend on any of it -- nor write its
# own state into the player's ([SMOKE_PICK]: a runner has to mean the
# same thing on another machine)
mkdir -p "$out/user"
run_client 40 "$out/cli.log" timeout 180 bin/buildat -m launch_world \
	-D "$out/user" -w 640x360 -l 3 -c @"$out/cmds.txt" > /dev/null 2>&1 ||
	{ echo "FAIL: the drive ($out/cli.log): $(grep -a 'Command sequence failed\|run_client:' "$out/cli.log" | head -1)"; exit 1; }

contents=$(grep -a "launch_w.*: contents: " "$out/cli.log" | head -1 |
	sed 's/.*contents: //')
echo "contents: ${contents:-(nothing)}"
# **Every game is on the wall** ([LAUNCH_WORLD] stage 1(b): twenty-nine
# and not seven). Four walls at a pitch of six hold forty-six pockets
# between them, so a tree's games fit and the spill branch is dead code
# on any desk with fewer than that -- which is the thing to notice if
# the pitch or a wall's span ever changes and they quietly start
# standing on the floor again.
wall=$(grep -a "launch_w.*: the wall holds " "$out/cli.log" | head -1 |
	sed 's/.*: the wall holds //')
echo "the wall: ${wall:-(said nothing)}"
case "$wall" in
	*"none on the floor"*) ;;
	*)
		echo "FAIL: not every game is on the wall -- \"${wall:-nothing said}\""
		exit 1
		;;
esac
# **A sandbox error is the way a room edit breaks**, and it is a line in
# the log rather than a missing picture
raised=$(grep -ac "Assignment to undeclared global\|pcall(): Runtime error" \
	"$out/cli.log")
launched=$(grep -ac "game: the room stands down" "$out/cli.log")
back=$(grep -ac "game: back in the room" "$out/cli.log")
# The launch animation began ([LAUNCH_WORLD] section 0): digger takes the
# view within a second, so the pull is all of it this run sees
pulled=$(grep -ac "launch: pull (" "$out/cli.log")
attract=$(grep -ac "attract: over the wall" "$out/cli.log")
attract_back=$(grep -ac "attract: back to the standing place" "$out/cli.log")
# After the switch back: the room was closed, a new one has the screen,
# and one Tab is one station
switched=$(sed -n '/launch_w.*: room: closed/,$p' "$out/cli.log" |
		grep -ac "launch_w.*: input: the room has the screen again")
tabs_after=$(sed -n '/launch_w.*: room: closed/,$p' "$out/cli.log" | grep -ac "station: floor")
# **The trust colour's sample after every leave** ([TRUST_OVERLAY_LEAVE]):
# shown at the start and again after each game, and shown last. It was
# gone for good after the first leave: the client kept the left
# server's address.
trust_shown=$(grep -ac "trust colour sample shown" "$out/cli.log")
# Hidden only by a connection: a launch cancelled while its server
# compiles (a cold cache, as on a runner) leaves without one
trust_hidden=$(grep -ac "trust colour sample hidden" "$out/cli.log")
# The room's own line: $back also counts the command file's wait_log
# lines, which name it
returns=$(grep -ac "launch_w.*: game: back in the room" "$out/cli.log")
trust_last=$(grep -a "trust colour sample" "$out/cli.log" | tail -1 |
		grep -c "sample shown")
python3 - "$out" <<'PY'
import sys, os
from PIL import Image, ImageChops
out = sys.argv[1]
def px(name):
	p = os.path.join(out, name)
	if not os.path.exists(p):
		print("no picture: " + name)
		return None
	return Image.open(p).convert("L")
a, b = px("stood.png"), px("moved.png")
if a is None or b is None:
	sys.exit(1)
def moved_between(x, y):
	if x is None or y is None:
		return 0.0
	hist = ImageChops.difference(x, y).histogram()
	return sum(i * n for i, n in enumerate(hist)) / float(x.width * x.height)
moved = moved_between(a, b)
lit = sum(i * n for i, n in enumerate(a.histogram())) / float(a.width * a.height)
drift = moved_between(px("back.png"), px("back2.png"))
print("the room is lit to %.1f of a level, Tab moved it by %.1f, and "
		"it drifts by %.1f after a game" % (lit, moved, drift))
# A black window is 0 either way; a frozen one moves by nothing
sys.exit(0 if lit > 5.0 and moved > 1.0 and drift > 0.5 else 1)
PY
verdict_keep
if [ "$verdict_rc" -ne 0 ] || [ "$raised" -gt 0 ] ||
		[ "$launched" -lt 1 ] || [ "$back" -lt 1 ] || [ "$pulled" -lt 1 ] ||
		[ "$attract" -lt 1 ] || [ "$attract_back" -lt 1 ] ||
		[ "$switched" -ne 1 ] || [ "$tabs_after" -ne 1 ] ||
		[ "$returns" -lt 1 ] || [ "$trust_shown" -lt $((trust_hidden + 1)) ] ||
		[ "$trust_last" -ne 1 ] ||
		[ -z "$contents" ]; then
	echo "the trust colour sample was shown $trust_shown times for" \
			"$returns games left, and is shown at the end: $trust_last"
	echo "the sandbox raised $raised times;" \
			"a game was launched $launched and left $back times;" \
			"the animation pulled $pulled times; the attract drift" \
			"started $attract and stopped $attract_back times;" \
			"the room had the screen back $switched times and one Tab" \
			"after it moved $tabs_after times"
	grep -a "Runtime error\|undeclared global" "$out/cli.log" | head -3
	echo "FAIL: the room does not boot, draw, launch and come back"
	exit 1
fi
echo "the trust colour sample was shown $trust_shown times for $returns games left"
echo "PASS: the room boots, moves between stations, launches a game with its animation and comes back, drifts until a key, and goes to the 2D menu and back"
exit 0
# vim: set noet ts=4 sw=4:
