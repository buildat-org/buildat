#!/bin/bash
# extensions/launch_world: [LAUNCH_WORLD]'s own check. One picture of each
# of the four lighting presets from the one viewpoint, into
# local/options_for_LAUNCH_WORLD/, which is what settles the palette, and
# then the room's features one at a time.
#
# **No server.** The room is an extension: it is the launcher, and
# starting a game is `ctx.launch` on the trusted side. So this runs the
# client alone with -m launch_world.
#
#   extensions/launch_world/check.sh
#
# **core.sh beside this is what an edit runs** -- one client, a quarter
# of a minute, the paths a room edit breaks ([CHECK_COST], user
# 2026-09-25). This is the whole of it, and it is what a push runs.
#
# **Before you run this, it is probably the wrong thing** (user,
# 2026-09-25, having said it three times). It is twenty minutes, and it
# is a push's job. A session runs core.sh after touching the room, or
# writes the six-line drive that aims at what it changed.
#
# **And read what it asserts before trusting it about your change.** It
# checks the presets, the pointing (which orb is selected), the
# slot, the saves, the ornament and the sounds. It says **nothing**
# about whether an orb's name is drawn or where it sits -- a session
# once ran the whole thing after moving the labels, having already seen
# a screenshot of them. A check with no assertion about your change
# proves nothing about your change; run_all.sh selects by path, and a
# path is not an assertion.
#
# tier: broken
# needs: pixels
# broken: back to full; clicking an orb does nothing (dev); no "pause: hover
#   on" (the branch) (local/runs/dev_baseline)
# cost: 392s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
#
# It keeps util/check_lib.sh's contract ([CI_RUNS] (1)): exit 0
# passed, 1 failed, 2 could not run, and a last line saying which.
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
# run_client: a drive that has stopped logging is taken down rather than
# waited out (user, 2026-09-24)
out="$here/local/options_for_LAUNCH_WORLD"; mkdir -p "$out"
# **Last run's pictures are not this run's.** The client crashed halfway
# through a run and every check still reported PASS, off the shots left
# behind by the run before (2026-09-23).
rm -f "$out"/*.png
# The player's own voxels are a save, so a run starts from none
rm -f "$BUILDAT_USER_PATH/launch_world/room.txt"
# The room's description asserts itself first: it is a function of
# (x, y, z), and a wall with no slabs in it fails here rather than in a
# picture nobody reads
lua "$here/extensions/launch_world/room.lua" || exit 1
# What it starts in the background (CHECK_PIDS) is stopped at its exit
trap check_cleanup EXIT
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi

# **An empty lobby shows one sensible pick, said as one** ([LAUNCH_WORLD]
# stage 1(b), 2026-09-28: the proof's nine invented hostnames are gone).
# A first-time player learns what the room is by trying one, and props
# that read as joinable teach the wrong thing; localhost is a real thing
# to try and says where its name is read out that it is the room's
# suggestion. This desk's client has addresses of its own, so the
# assertion needs a client with no history, which is an empty user path
# of its own.
mkdir -p "$out/emptyuser"
{ echo "wait_log_any 30000 on the floor"; echo "quit"
	} > "$out/cmds_cold.txt"
examples=$(bin/buildat -m launch_world -D "$out/emptyuser" -w 640x360 -l 3 \
	-c @"$out/cmds_cold.txt" 2>&1 |
	grep -a "launch_w.*: servers: .* on the floor" | head -1 |
	sed -n 's/.*floor, \([0-9]*\) of them the room.*/\1/p')
echo "a client with no history draws ${examples:-0} suggested servers"
if [ "${examples:-0}" != "1" ]; then
	echo "FAIL: an empty lobby should show exactly one server, the room's" \
			"own suggestion, and say that it is one"
	exit 1
fi

# **The room's sound levels are the room's, and they are kept**
# ([ROOM_SOUND]: the design is to be played against and iterated on by
# ear, which wants the levels reachable without an edit). Two rows on
# the terminal, two numbers in the room's own save; a written save is
# read back here, which is the half a listening session depends on.
mkdir -p "$out/tieruser/launch_world"
# **In decibels since [VOLUME_LAW]** (2026-09-28): the row is
# !sound_db and the levels are steps below full, which is what every
# volume in the tree is now. An old !sound row of fader positions is
# still read, once, and turned into the nearest steps.
printf '!sound_db -9 -6\n' > "$out/tieruser/launch_world/room.txt"
# **Every client run is under a timeout** (2026-09-24): a client can
# hang in X11_ShowWindow waiting for the window manager to map its
# window -- seen here on a `delay 2500; quit` sequence that sat for
# twenty-two minutes -- and a check that waits forever on the desk's
# own weather is a check nobody can read.
{ echo "wait_log_any 30000 sound: the orbs at"; echo "quit"
	} > "$out/cmds_snd.txt"
timeout 120 bin/buildat -m launch_world -D "$out/tieruser" -w 640x360 -l 3 \
	-L "$out/snd.log" -c @"$out/cmds_snd.txt" > /dev/null 2>&1
snd=$(grep -a "launch_w.*: sound: the orbs at " "$out/snd.log" | head -1 |
	sed 's/.*sound: //')
echo "a saved room came up with $snd"
rm -f "$out/tieruser/launch_world/room.txt"
if [ "$snd" != "the orbs at -9 dB, the bed at -6 dB" ]; then
	echo "FAIL: the room does not keep the levels it was left at"
	exit 1
fi

# **The room is a launch UI the setting can name** ([LAUNCH_SANDBOX]:
# the launch UI is a slot). Two short runs before the long one: the
# preference picks the room, and a name that is not there falls back to
# the menu rather than leaving the client with no launcher. -o is used
# so that a check never writes the user's preferences.
# Each waits for the line it is read by, and a run that never says it
# waits out the timeout rather than a delay nobody sized
{ echo "wait_log_any 30000 contents: "; echo "quit"; } > "$out/cmds_slot.txt"
{ echo "wait_log_any 30000 the launch UI is launch_menu"; echo "quit"
	} > "$out/cmds_back.txt"
# The last resort's two error lines are this run's own doing
{ echo "expect_error the fallback launch UI launch_menu raised"
	echo "expect_error buildat could not start"
	echo "wait_log_any 30000 could not start a launch UI"; echo "quit"
	} > "$out/cmds_nolauncher.txt"
slot=$(bin/buildat -w 640x360 -l 3 -o launch_ui=launch_world 	-c @"$out/cmds_slot.txt" 2>&1 | grep -ac "launch_w.*: contents: ")
back=$(bin/buildat -w 640x360 -l 3 -o launch_ui=nosuchthing 	-c @"$out/cmds_back.txt" 2>&1 | grep -av "wait_log" |
	grep -ac "the launch UI is launch_menu")
# **And the room runs in the sandbox** ([LAUNCH_SANDBOX]), which is what
# its launch_ui.txt asks for: the marker is what the client reads, so a
# room that quietly went back to running trusted would still pass every
# assertion below. This is the one that would not.
sandboxed=$(grep -c "^sandboxed$" "$here/extensions/launch_world/launch_ui.txt")
if [ "$sandboxed" -lt 1 ]; then
	echo "FAIL: launch_world no longer asks to be run in the sandbox"
	exit 1
fi
# **And a launcher that cannot be left with no launcher** ([MENU_FALLBACK]):
# with the chosen one missing *and* the fallback failing, the client says
# so in its own window and keeps running -- it used to abort, which is
# the one failure a slot anybody can fill must not have.
last=$(BUILDAT_TEST_NO_LAUNCHER=1 bin/buildat -w 640x360 -l 3 \
	-o launch_ui=nosuchthing -c @"$out/cmds_nolauncher.txt" 2>&1 | grep -av "wait_log" |
	grep -acE "could not start a launch UI|Crash: SIG")
echo "the slot: picked by name $slot, fell back to the menu $back, sandboxed"
if [ "$last" -ne 1 ]; then
	echo "FAIL: with no launcher at all the client does not say so," \
			"or it crashes"
	exit 1
fi
if [ "$slot" -lt 1 ] || [ "$back" -lt 1 ]; then
	echo "FAIL: the launch UI setting does not pick the room," \
			"or a missing one does not fall back to the menu"
	exit 1
fi
# **A game to go into** ([CI_RUNS]): the drive goes into demo_digger by name
# where the tree has games installed, and leaves that block out where it
# has none -- a container -- and the assertions below say so.
games_installed=$(ls "$BUILDAT_USER_PATH/shared/vanilla/games" 2>/dev/null | wc -l)

# **The modules are compiled before any drive starts.** A server whose
# rccpp cache is cold spends seven seconds compiling `main`, and in this
# check -- and only in this check -- that compile is killed: the raw
# wait status is 15, a SIGTERM to its process group, and no client logs
# sending one. The drive then reports "ContentDB does not open" for a
# server that never came up. That fault is its own item; warming the
# cache here keeps it from being reported as something else.
if [ ! -f "$here/cache/rccpp_build/main.so" ] ||
		[ "$here/apps/vanilla/main/main.cpp" -nt \
		"$here/cache/rccpp_build/main.so" ]; then
	echo "warming the module cache (a cold compile is seven seconds)"
	# Best effort: a warm that did not come up leaves the drives to say so
	BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=zz_warm \
		start_server "$out/warm.log" "STATUS Listening|Running world" 120 \
		auto bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 || true
	kill -9 "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
	rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/zz_warm"
fi

# **wait_log_any, not wait_log**: the room says it is humming once, at
# the end of a boot that takes eleven seconds here, and the sequence
# starts before that -- but by twenty milliseconds either way. A wait
# that only sees what comes after it then sat out its ninety seconds
# and every step ran that much late (2026-09-24). wait_log_any counts
# the line wherever it appeared in the run.
#
# **The drive moves on the room's own lines** ([CHECKS_EVENT_WAITS]):
# "camera: landed", "browse: ", "prompt: ", "pause: open" and the
# screenshot's "Wrote screenshot". An `event` is answered while it is
# sent, before a wait after it starts, so its line is read with
# wait_log_any where it is said once and not waited for at all where it
# is said again. A delay left is a settle of a few frames after a line,
# or a length of time the step is about.
{ echo "wait_log_any 90000 the room hums"
	echo "delay 1200"
	# **It starts at the wall, and Tab moves between the stations**
	# ([LAUNCH_WORLD] section 11): the floor, the desk, and the wall
	# again. The first two shots are what says the camera moved.
	echo "screenshot $out/stood.png"
	echo "wait_log 20000 Wrote screenshot $out/stood.png"
	echo "keypress Tab"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	echo "screenshot $out/station-floor.png"
	echo "wait_log 20000 Wrote screenshot $out/station-floor.png"
	echo "keypress Tab"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	echo "keypress Tab"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	# **A server is connected to, and says so when it cannot be.**
	# "localhost" is always in the list and nothing listens on its port
	# in a check run, so this is the failure path: a notice line, the
	# room still standing, no dialog and no crash.
	echo "keypress H"
	echo "keypress O"
	echo "keypress S"
	echo "keypress T"
	echo "wait_log 5000 prompt: \"host\" matches"
	echo "keypress Return"
	# The room says when the attempt has failed ("connect: <name> failed:
	# ..."), which is what the notice is drawn from, so the wait is on
	# that rather than on how long a refused connection takes
	echo "wait_log 20000 failed:"
	echo "delay 500"
	echo "screenshot $out/connect-failed.png"
	echo "wait_log 20000 Wrote screenshot $out/connect-failed.png"
	# Whatever Escape opens or closes here, the mode event below puts
	# right; the delay is the frames for the key to be read before it
	echo "keypress Escape"
	echo "delay 300"
	echo "event mode menu"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	# **The arrows browse the room** with the prompt empty: along a row
	# and between the rows, the wall first and the floor's ranks after
	echo "keypress Right"
	echo "wait_log 5000 browse: row"
	echo "keypress Down"
	echo "wait_log 5000 browse: row"
	echo "keypress Left"
	echo "wait_log 5000 browse: row"
	# Back to the standing place, so every frame below has the same
	# viewpoint as the one Escape returns to
	echo "event mode menu"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	# **The room is never static** -- the era reference's own rule, and
	# the reason every comparison below freezes it first. Two frames a
	# second apart, then F7.
	echo "screenshot $out/drift-a.png"
	echo "wait_log 20000 Wrote screenshot $out/drift-a.png"
	echo "screenshot $out/drift-b.png"
	echo "wait_log 20000 Wrote screenshot $out/drift-b.png"
	echo "event room still"
	echo "wait_log_any 5000 idle drift frozen"
	# The dissolve: a bay opens and closes again. What is checked is that
	# the wall moves and comes back -- states being configurations of one
	# scene, the closed picture has to be the picture it was.
	#
	# **Through the prompt, not through Enter alone.** Enter takes what
	# is browsed now ("Enter launches, always"), and what is browsed is
	# whatever the arrows above left selected -- which may be a game with
	# a server to start. Three letters name the empty pocket and Enter
	# opens that one, every run.
	echo "event room preset 1"
	echo "wait_log_any 5000 palette preset 1:"
	# **The standing place first, and before the reference picture**
	# ([CMD_EVENT]): the reopened picture is taken from there too, or
	# "it comes back" compares two cameras rather than two walls
	# (2026-09-23).
	echo "event mode menu"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	echo "screenshot $out/dissolve-closed.png"
	# A screenshot lands a frame or two after the command, so the next
	# key has to wait or it is in the picture (2026-09-23)
	echo "wait_log 20000 Wrote screenshot $out/dissolve-closed.png"
	# **By the room's own switch** ([LAUNCH_WORLD] stage 2): a launch is
	# the animation now, and the dissolve is kept for stage 3 as an effect.
	# The delay is the cubes' flight out, 0.9 s, and the frames after it
	echo "event room dissolve"
	echo "delay 1600"
	echo "screenshot $out/dissolve-open.png"
	echo "wait_log 20000 Wrote screenshot $out/dissolve-open.png"
	echo "event room dissolve"
	# The cubes land in 0.9 s, but the voxels coming back have to be
	# remeshed and relit before the picture is the picture it was.
	# **The room does say when a bay is back** -- "dissolve: bay N
	# rebuilt", as the voxels are put back -- so this waits for that and
	# spends only the remesh after it. (It was a flat five seconds while
	# nobody had looked for a line; waiting for one the room printed at
	# boot returns at once and shoots the frame mid-rebuild, which is why
	# the comment here used to say there was none.)
	echo "wait_log 20000 rebuilt"
	echo "delay 900"
	echo "screenshot $out/dissolve-closed-again.png"
	echo "wait_log 20000 Wrote screenshot $out/dissolve-closed-again.png"
	# The typing path: three letters fuzzy-match a name, Enter takes it
	# and the camera flies in; Escape brings the room back.
	#
	# **The empty pocket, not a game.** This typed "und" and launched
	# demo_undermine for real: a local server that has to compile its modules
	# first, and when that ran long the connect failed and the game's own
	# Escape exited the client -- taking the other 55 commands of this
	# sequence with it, so half the assertions below read missing files
	# (2026-09-23). What is being checked here is the prompt, the flight
	# and the way back, and the empty pocket exercises all three with
	# nothing to start.
	echo "event mode menu"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	echo "keypress I"
	echo "keypress N"
	echo "keypress S"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	echo "screenshot $out/typed.png"
	echo "wait_log 20000 Wrote screenshot $out/typed.png"
	# The typing has already hopped the camera to the match; Enter on the
	# empty pocket launches nothing (it has no action yet) and says so
	echo "keypress Return"
	echo "wait_log 20000 launch: install a game"
	echo "delay 400"
	echo "screenshot $out/launched.png"
	echo "wait_log 20000 Wrote screenshot $out/launched.png"
	echo "event mode menu"
	echo "wait_log 20000 camera: landed"
	echo "delay 400"
	echo "screenshot $out/back-home.png"
	echo "wait_log 20000 Wrote screenshot $out/back-home.png"
	# The terminal: found by name like anything else, the camera square
	# on to it and the panel flat over it.
	echo "event mode menu"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	echo "keypress S"
	echo "keypress E"
	echo "keypress T"
	echo "wait_log 5000 prompt: \"set\" matches"
	echo "keypress Return"
	echo "wait_log 10000 terminal: sat down"
	echo "wait_log 20000 camera: landed"
	echo "delay 400"
	echo "screenshot $out/terminal.png"
	echo "wait_log 20000 Wrote screenshot $out/terminal.png"
	# **A setting changed and changed back.** A -w run never writes the
	# preferences file (save_preferences stands down when the size is
	# forced), so this asserts the change, not the file -- and the
	# user's own settings are safe from a check.
	echo "keypress Down"
	echo "keypress Right"
	echo "wait_log 5000 setting: "
	echo "delay 400"
	echo "screenshot $out/terminal-changed.png"
	echo "wait_log 20000 Wrote screenshot $out/terminal-changed.png"
	echo "keypress Right"
	echo "wait_log 5000 setting: "
	echo "keypress Escape"
	echo "wait_log 20000 camera: landed"
	echo "delay 400"
	# The ornament, stripped: the friezes go plain and the frame has to
	# change. The generator's own check passed for a day while nothing in
	# the room wore what it made.
	# **The ornament's toggle re-meshes the whole room**, the ornament
	# being voxels now, and
	# a shot 900 ms later sometimes landed before the mesh did -- which
	# read as "nothing wears the generated maps" (2026-09-23). The room
	# says which way the toggle went once it has rebuilt
	# (set_8bit_voxel_geometry is done when rebuild_room returns), so the
	# wait is on that and the delay after it is the frame's.
	# (Said inside the event, so a wait that starts after it is
	# wait_log_any; each of the two is said once a run.)
	echo "event room ornament"
	echo "wait_log_any 5000 ornament off"
	echo "delay 500"
	echo "screenshot $out/no-ornament.png"
	echo "wait_log 20000 Wrote screenshot $out/no-ornament.png"
	echo "event room ornament"
	echo "wait_log_any 5000 ornament on"
	echo "delay 500"
	# The room as it is, and then the same frame with the reflection
	# probe taken off the zone, which is what says the probe reaches the
	# metals
	echo "screenshot $out/room.png"
	echo "wait_log 20000 Wrote screenshot $out/room.png"
	# The probe is off the zone when the event returns; the delay is the
	# frames that draw it
	echo "event room probe"
	echo "wait_log_any 5000 reflection probe off"
	echo "delay 300"
	echo "screenshot $out/room-noprobe.png"
	echo "wait_log 20000 Wrote screenshot $out/room-noprobe.png"
	# The attract mode: left alone the room shows itself off. The drift
	# is unfrozen for it and BUILDAT_LAUNCH_ATTRACT makes the wait short.
	echo "event room still"
	echo "wait_log_any 5000 idle drift running"
	# **Where the camera is, said rather than assumed** (2026-09-24):
	# this step compares "home" against "back from the attract mode",
	# and the room flies back to the standing place -- so if the shot
	# called home was taken anywhere else, the two differ by the flight
	# and the step fails on its own setup. Every step before this one
	# leaves the camera somewhere of its own.
	echo "event mode menu"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	echo "screenshot $out/attract-home.png"
	echo "wait_log 20000 Wrote screenshot $out/attract-home.png"
	echo "event room attract"
	# The sweep says when it starts and which wall it is showing; the
	# delay after it is the camera's own flight, not a guess at when the
	# room noticed the key
	echo "wait_log 20000 attract: over the wall"
	echo "delay 1800"
	echo "screenshot $out/attract-away.png"
	echo "wait_log 20000 Wrote screenshot $out/attract-away.png"
	echo "keypress Space"
	echo "wait_log 20000 attract: back to the standing place"
	echo "wait_log 20000 camera: landed"
	echo "delay 300"
	echo "screenshot $out/attract-back.png"
	echo "wait_log 20000 Wrote screenshot $out/attract-back.png"
	# **The pause dialog**, which is the room's own way out of the
	# program: at the standing place with nothing open, Escape comes up
	# with it; Escape again takes it away.
	#
	# **The mode is said** ([CMD_EVENT]), so the Escape below is the one
	# that pauses rather than the one that pops a level.
	echo "event mode menu"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	echo "screenshot $out/prepause.png"
	echo "wait_log 20000 Wrote screenshot $out/prepause.png"
	echo "keypress Escape"
	echo "wait_log 5000 pause: open"
	echo "delay 300"
	echo "screenshot $out/paused.png"
	echo "wait_log 20000 Wrote screenshot $out/paused.png"
	# **The mouse does not turn the camera while a screen is up**
	# (user, 2026-09-23: the pause menu turned it into yaw and pitch).
	# A quarter turn's worth of movement, and the frame behind the
	# dialog has to be the frame it was. **This goes first**, before
	# anything that moves the pointer: once the dialog is gone the
	# mouse turns the camera again, which is the point of it.
	# Half a second for the movement to have turned the camera, if it did
	echo "mouse_move 220 40"
	echo "delay 500"
	echo "keypress Escape"
	echo "wait_log 5000 pause: closed"
	echo "delay 300"
	echo "screenshot $out/unpaused.png"
	echo "wait_log 20000 Wrote screenshot $out/unpaused.png"
	# **And the dialog answers the mouse** (the third playtest, 1):
	# hovering a row selects it, and a click on the first row is "back
	# to the room", which closes the dialog. Every menu this room draws
	# has to do both; the desk's rows are the same machinery.
	echo "keypress Escape"
	echo "wait_log 5000 pause: open"
	echo "mouse_pos 640 400"
	echo "wait_log 5000 pause: hover on "
	echo "delay 300"
	echo "screenshot $out/pause-hover.png"
	echo "wait_log 20000 Wrote screenshot $out/pause-hover.png"
	echo "mouse_pos 640 263"
	echo "wait_log 5000 pause: hover on "
	echo "mouse_click left"
	echo "wait_log 5000 pause: clicked"
	echo "delay 300"
	echo "screenshot $out/pause-clicked.png"
	echo "wait_log 20000 Wrote screenshot $out/pause-clicked.png"
	# **The search walks its matches and the camera follows** (the
	# second playtest, 5 and 6): a term with many matches, then the
	# arrows, and each one has to be a different picture.
	echo "event mode menu"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	echo "keypress T"
	echo "keypress E"
	echo "keypress S"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	echo "screenshot $out/search1.png"
	echo "wait_log 20000 Wrote screenshot $out/search1.png"
	echo "keypress Down"
	echo "wait_log 5000 prompt: match "
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	echo "screenshot $out/search2.png"
	echo "wait_log 20000 Wrote screenshot $out/search2.png"
	echo "keypress Down"
	echo "wait_log 5000 prompt: match "
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	echo "screenshot $out/search3.png"
	echo "wait_log 20000 Wrote screenshot $out/search3.png"
	echo "event mode menu"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	echo "event mode menu"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	# **The developer console, over the room** ([LAUNCH_CONSOLE] offers
	# its screen and the room takes it): the pause dialog's fourth item,
	# a line typed at it, and Escape to put the room back.
	echo "keypress Escape"
	echo "wait_log 5000 pause: open"
	echo "keypress Down"
	echo "keypress Down"
	echo "keypress Down"
	echo "keypress Return"
	echo "wait_log 5000 console: over the room"
	echo "delay 500"
	echo "screenshot $out/room-console.png"
	echo "wait_log 20000 Wrote screenshot $out/room-console.png"
	echo "text buildat.version()"
	echo "keypress Return"
	echo "wait_log 5000 console: buildat.version() = "
	echo "keypress Escape"
	echo "wait_log 5000 console: closed"
	echo "delay 400"
	# **A game launched by name** -- demo_digger, which every tree has. Last
	# but one, because it starts a server and takes the client into the
	# game.
	if [ "${games_installed:-0}" -gt 0 ]; then
	# **Home first** (2026-09-24): fourteen seconds of quiet starts the
	# attract mode and the camera leaves the standing place; the event
	# puts it back and resets the idle clock.
	echo "event mode menu"
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	for c in D I G G E R; do echo "keypress $c"; done
	echo "wait_log 5000 prompt: \"digger\" matches"
	echo "keypress Return"
	# **Wait for the launch rather than guessing at it**: on a slow
	# machine -- a container under llvmpipe is one -- nine seconds was
	# not enough, and the key went before the game had started, so the room
	# was asked to come back from a game it had not gone into yet
	# (2026-09-24, the first container run of the quick tier).
	# Two minutes: starting a game is starting a server and loading a
	# world, and in a container that took fifty seconds where this desk
	# takes five
	echo "wait_log 150000 game: the room stands down"
	echo "delay 2000"
	echo "screenshot $out/in-game.png"
	echo "wait_log 20000 Wrote screenshot $out/in-game.png"
	# **And back out of it** ([MENU_CONTEXT]): the room stands behind the
	# game the whole time, so the way back is the client's own
	# leave_to_menu plus a viewport. Escape is what drives it -- the
	# game's own key, which every game in the tree binds to
	# buildat.leave() ([NO_WAY_BACK]); the room has no key of its own
	# for leaving a game any more.
	echo "keypress Escape"
	echo "wait_log 30000 game: back in the room"
	echo "delay 1500"
	echo "screenshot $out/back-from-game.png"
	echo "wait_log 20000 Wrote screenshot $out/back-from-game.png"
	fi
	# **And an orb answers the mouse** (the third playtest's rule, in
	# the room rather than in a dialog): a click on one launches it, the
	# way Enter launches what is browsed. Last, because it starts
	# something -- the same reason the game above is last.
	# **Tab, not the mode event**: the room answering a key at all after
	# a game is half of what this step proves -- its own handlers used
	# to go with the game's ([LAUNCH_SANDBOX]'s reset dropped every
	# sandboxed handler, and the room is sandboxed now)
	echo "keypress Tab"
	echo "wait_log 15000 camera: landed"
	# **An orb the room was asked for, in the middle of the screen**
	# (2026-09-24): a fixed pixel was an orb only while the room held
	# the number of orbs it held the day the pixel was written down --
	# and this check's own launches add saves, which move every one of
	# them. Browsing flies the camera to a *row*, which need not put an
	# orb under the middle; typing a name flies it to that orb and
	# stops in front of it, which is what the mark sheet uses to frame
	# one.
	for c in D I G G E R; do echo "keypress $c"; done
	echo "wait_log 15000 camera: landed"
	echo "delay 250"
	# **And the prompt out of the way before the click**: the panel the
	# typing opened is over the middle of the screen, so the click
	# landed on it and the orb behind it never heard (2026-09-24).
	# Escape hides the prompt and leaves the camera where the search
	# flew it.
	# (Escape closing the prompt says nothing; a few frames for it, and
	# for the pointer to be read where it was put before the click.)
	echo "keypress Escape"
	echo "delay 300"
	echo "mouse_pos 640 360"
	echo "delay 300"
	echo "mouse_click left"
	echo "wait_log 5000 : click: "
	echo "quit"; } > "$out/cmds.txt"
wait_quiet 40 || true
# **Sixty seconds of silence ends it** (user, 2026-09-24): this drive is
# six minutes of client and its every step says so in the log -- each
# command as it runs, and a heartbeat while a wait_log waits -- so a
# minute with nothing in the log is a client that is not coming back,
# and waiting out the rest of the ten is ten minutes to learn what a
# minute already said.
run_client 60 "$out/cli.log" timeout 600 bin/buildat -m launch_world \
 -w 1280x720 -l 3 -c @"$out/cmds.txt" ||
	fail "the room's drive stopped:" \
		"$(grep -a "Command sequence failed\|run_client\|Crash: SIG" "$out/cli.log" | tail -1)"
# And the client has to have got to the end of the sequence
if grep -aq "Crash: SIG" "$out/cli.log"; then
	echo "FAIL: the client crashed --" \
			"$(grep -a "Crash: SIG" "$out/cli.log" | head -1)"
	exit 1
fi
grep -aE "palette preset|ornament ok|synth ok|orb sizes|the room hums" "$out/cli.log" |
	sed 's/.*launch_w[a-z]*: //'
# **The room hums, and the pattern answers what the player is doing**
# ([ROOM_SOUND]): six voices take the nearest orbs and the beat rises
# from barely-there when something is being looked at.
hums=$(grep -a "launch_w.*: the room hums" "$out/cli.log" | head -1 |
	sed 's/.*launch_w[a-z]*: //')
if [ -z "$hums" ]; then
	echo "FAIL: the room says nothing about its own sound"
	exit 1
fi

# The ornament generator asserts its own patterns as it builds them
# (ornament.lua's self_check); a generator that quietly returned a flat
# field would pass an eye on a dark slab and fail there
# The room is described in room.lua and nowhere else now, so what the
# room says out loud is checked against itself rather than against a
# second copy on a server
grep -a "launch_w.*: room " "$out/cli.log" | head -1 | sed 's/.*: //'
grep -a "launch_w.*: bays " "$out/cli.log" | head -1 | sed 's/.*: //'
# **The room holds what the tree offers**, not a list written here: the
# pockets are the launch grid's games and the floor is everything else
# that launches. A room that found nothing would still draw, and would
# still pass every picture check above.
# **The arrows walk the room's own grid**: a row along the wall and the
# floor's ranks after it, read off where the things are rather than off a
# second list. Four different things for four presses.
browsed=$(grep -a "launch_w.*: browse: " "$out/cli.log" | sed 's/.*browse: //' |
	sort -u | wc -l)
echo "the arrows browsed $browsed different places"
if [ "$browsed" -lt 3 ]; then
	echo "FAIL: the arrows do not browse the room"
	exit 1
fi

# **The terminal changes a setting**, rather than showing one
changes=$(grep -a "launch_w.*: setting: " "$out/cli.log" | wc -l)
first=$(grep -a "launch_w.*: setting: " "$out/cli.log" | head -1 | sed 's/.*setting: //')
last=$(grep -a "launch_w.*: setting: " "$out/cli.log" | tail -1 | sed 's/.*setting: //')
echo "the terminal changed $changes settings: $first then $last"
if [ "$changes" -lt 2 ] || [ "$first" = "$last" ]; then
	echo "FAIL: the terminal's rows do not change anything"
	exit 1
fi

# **Each step of the sequence says it did its own thing**, so a mode
# that drifted cannot pass on another step's picture: the dissolve was
# typing into FPS for a while and its assertion was satisfied by the
# terminal opening instead (2026-09-23).
for want in "dissolve: bay" "launch: " "terminal: sat down"; do
	if ! grep -aq "launch_w.*: $want" "$out/cli.log"; then
		echo "FAIL: the sequence never got to \"$want\" -- a step typed" \
				"into the wrong mode"
		exit 1
	fi
done

# **Every orb has a mark and they are not all the same one** (the
# playtests asked for this three times and no check covered it): the
# room says how many pixels of each mark are the mark, so an empty one
# and a shared one are both visible from the log.
inks=$(grep -a "launch_w.*: mark: " "$out/cli.log" | sed 's/.*ink //' |
	sort -u | wc -l)
blank=$(grep -ac "launch_w.*: mark: .* ink 0$" "$out/cli.log")
echo "the room drew marks of $inks different weights, $blank of them empty"
if [ "$inks" -lt 3 ] || [ "$blank" -gt 0 ]; then
	echo "FAIL: the orbs share a mark, or one of them has none"
	exit 1
fi

# **Every orb about two voxels across** ([LAUNCH_SIGNIFY]): the sizes
# come from what a launch action says about itself, ranked within its
# own category, so a server is no longer the largest thing in the room
# for want of anything saying otherwise. The band is asserted, and that
# more than one category answered -- a room where nothing had an
# opinion would draw every orb the same and still look right.
sizes=$(grep -a "launch_w.*: orb sizes: " "$out/cli.log" | head -1 |
	sed 's/.*orb sizes: //')
echo "orb sizes: ${sizes:-(none)}"
band=$(echo "$sizes" | sed -n 's/.*, \([0-9.]*\) to \([0-9.]*\) voxels.*/\1 \2/p')
ranked=$(echo "$sizes" | sed -n 's/.*ranked within //p')
if [ -z "$band" ] || [ "$ranked" = "nothing" ]; then
	echo "FAIL: the room does not size its orbs by what they say about" \
			"themselves"
	exit 1
fi
python3 - "$band" <<'PYSZ' || exit 1
import sys
lo, hi = (float(v) for v in sys.argv[1].split())
if not (1.6 <= lo <= hi <= 2.4):
	print("FAIL: an orb is outside the band around two voxels: %.2f to %.2f"
			% (lo, hi))
	raise SystemExit(1)
if hi - lo < 0.1:
	print("FAIL: every orb is the same size -- nothing is ranked")
	raise SystemExit(1)
PYSZ

walked=$(grep -ac "launch_w.*: prompt: match [0-9]* of " "$out/cli.log")
matched=$(grep -a "launch_w.*: prompt: \"tes\" matches " "$out/cli.log" |
	head -1 | sed 's/.*matches \([0-9]*\).*/\1/')
echo "the search found ${matched:-0} matches and the arrows walked $walked"
if [ "${matched:-0}" -lt 3 ] || [ "$walked" -lt 2 ]; then
	echo "FAIL: the search does not find several matches, or the arrows" \
			"do not walk them"
	exit 1
fi

conn=$(grep -a "launch_w.*: connect: " "$out/cli.log" | head -1 |
	sed 's/.*launch_w[a-z]*: //')
echo "a server was asked for: ${conn:-(nothing)}"
if [ -z "$conn" ]; then
	echo "FAIL: Enter on a server does not connect to it"
	exit 1
fi

clicked=$(grep -a "launch_w.*: click: " "$out/cli.log" | head -1 |
	sed 's/.*click: //')
echo "a click on an orb took ${clicked:-(nothing)}"
if [ -z "$clicked" ]; then
	echo "FAIL: clicking an orb does nothing"
	exit 1
fi

console=$(grep -ac "launch_w.*: console: over the room" "$out/cli.log")
console_ran=$(grep -ac "launch_c.*: console: buildat.version() = " "$out/cli.log")
console_shut=$(grep -ac "launch_c.*: console: closed" "$out/cli.log")
echo "the console opened $console times, ran a line $console_ran, closed $console_shut"
if [ "$console" -lt 1 ] || [ "$console_ran" -lt 1 ] || [ "$console_shut" -lt 1 ]; then
	echo "FAIL: the room's developer console does not open, run or close"
	exit 1
fi
# **And the room is up in under two seconds** ([ROOM_BOOT], 2026-09-24:
# eight seconds of black window is what a first run of buildat looked
# like, and 6.46 s of it was seventy orb marks at 92 ms each). The
# measurement is the one the fault was found with: the gap between the
# room's first line and its last mark. The bar here is three seconds
# rather than two, against a desk that is busy with something else --
# what this catches is a return to seconds, not a tenth of drift.
boot=$(grep -a "I launch_w" "$out/cli.log" | awk '
	{ split($3, t, ":"); s = t[1] * 3600 + t[2] * 60 + t[3] }
	NR == 1 { first = s }
	/mark: / { last = s }
	END { if (first != "" && last != "") printf "%.2f", last - first;
			else printf "-1" }')
echo "the room was up in $boot s (its first line to its last mark)"
case "$boot" in
-1) echo "note: the room said nothing to measure";;
*) if [ "${boot%%.*}" -ge 3 ] 2>/dev/null; then
		echo "FAIL: the room takes $boot s to build itself; it was 1.5"
		exit 1
	fi;;
esac

# **And the room can be heard** ([NO_SOUND], 2026-09-24): every sound
# here is a SoundSource3D and positional audio with no listener is
# silent without being an error -- the room had no listener at all and
# said nothing about it. The line carries the three facts that are each
# silent when wrong.
hums=$(grep -a "launch_w.*: the room hums" "$out/cli.log" | tail -1)
echo "${hums##*: }"
# **What is the room's and what is the machine's** ([CI_RUNS]): a
# listener that is not placed and a voice that is not playing are the
# room's own faults and are silent when wrong, so they are asserted. An
# audio subsystem that is not playing is a box with no sound device --
# which is what a container is -- and that is a row, not a verdict.
case "$hums" in
*"listener placed, first voice playing true"*) ;;
*)
	echo "FAIL: the room's sound has nowhere to be heard from"
	exit 1;;
esac
case "$hums" in
*"audio playing"*) ;;
*) echo "note: this machine's audio is not playing; the room's own"\
		"rows are what was checked";;
esac

# **And the room hands the input over while it is up** (user,
# 2026-09-24: the console opened with the mouse still moving the camera
# and no cursor). One gate, asked once a frame, and it says both ways.
gave=$(grep -ac "launch_w.*: input: handed to whatever holds the screen" \
	"$out/cli.log")
took=$(grep -ac "launch_w.*: input: the room has the screen again" \
	"$out/cli.log")
echo "the room handed the input over $gave times and took it back $took"
if [ "$gave" -lt 1 ] || [ "$took" -lt 1 ]; then
	echo "FAIL: the room keeps the mouse while somebody else holds the screen"
	exit 1
fi

# **Coming back from a game, where a game could be gone into.** On a
# machine whose drive leaves the game out -- a container -- there is
# nothing to start, so the room standing down is the condition, not the
# assertion: where it happened, coming back is asserted; where it did
# not, the run says so and the desk's own run is what covers it.
went=$(grep -ac "launch_w.*: game: the room stands down" "$out/cli.log")
back=$(grep -ac "launch_w.*: game: back in the room" "$out/cli.log")
swept=$(grep -a "forget_game_ui" "$out/cli.log" | tail -1 |
	sed 's/.*forget_game_ui(): //')
echo "the room went into a game $went times and came back $back," \
	"sweeping ${swept:-nothing}"
if [ "$went" -ge 1 ] && [ "$back" -lt 1 ]; then
	echo "FAIL: the room does not come back from a game"
	exit 1
fi
if [ "$went" -lt 1 ]; then
	if [ "${games_installed:-0}" -gt 0 ]; then
		echo "FAIL: launching demo_digger by name started nothing"
		exit 1
	fi
	echo "note: no game is installed here, so the game and the way back"\
		"were not driven"
fi

# **The opening hint**, which is the room's whole answer to a first-time
# user: one line naming Tab and typing, and the first key takes it away
# again. A line that stayed would be a HUD.
hint_up=$(grep -ac "launch_w.*: hint: Tab and typing" "$out/cli.log")
hint_gone=$(grep -ac "launch_w.*: hint: taken away" "$out/cli.log")
echo "the hint was shown $hint_up and taken away $hint_gone"
if [ "$hint_up" -lt 1 ] || [ "$hint_gone" -lt 1 ]; then
	echo "FAIL: the hint does not appear, or does not leave at the" \
			"first key"
	exit 1
fi

# **And ContentDB opens from the room** ([LAUNCH_WORLD]'s version one
# asks for it, and nothing was checking it). The room's job is to get a
# player there: the action is the launch grid's, vanilla starts with
# menu=contentdb and draws its games screen with a row to install.
#
# **Against a mirror of this tree's own**, the one [FIRST_RUN] uses, so
# the check neither needs the network nor asks content.luanti.org for a
# listing on every run. Without one the screen is an error dialog, so
# this would otherwise be a check that fails when the tree is offline.
# The drive before this one ends by launching a game, so its client and
# its server are on their way out while this one starts
wait_quiet 40 || true
cdb_game=$(ls "$BUILDAT_USER_PATH/shared/vanilla/games" 2>/dev/null | head -1)
if [ -z "$cdb_game" ]; then
	echo "SKIP: no installed Luanti game to mirror for ContentDB" >&2
	exit 2
fi
rm -rf "$out/cdb_mirror"; mkdir -p "$out/cdb_mirror"
"$here/util/contentdb_mirror.sh" "$out/cdb_mirror" \
	"$BUILDAT_USER_PATH/shared/vanilla/games/$cdb_game" Wuzzy "$cdb_game" "$cdb_game" \
	> /dev/null || { echo "SKIP: no ContentDB mirror" >&2; exit 2; }
port_taken 30211 && fail "port 30211, the ContentDB mirror's, is taken"
(cd "$out/cdb_mirror" && exec python3 -m http.server 30211 \
	> "$out/cdb_mirror.log" 2>&1) &
mirror=$!
CHECK_PIDS+=($mirror)
for i in $(seq 50); do
	port_taken 30211 && break
	kill -0 "$mirror" 2>/dev/null || fail "the ContentDB mirror exited ($out/cdb_mirror.log)"
	sleep 0.2
done
port_taken 30211 || fail "the ContentDB mirror is not listening ($out/cdb_mirror.log)"
{ echo "wait_log_any 60000 the room hums"
	echo "event mode menu"; echo "wait_log 15000 camera: landed"
	for k in C O N T E N T D B; do echo "keypress $k"; done
	echo "wait_log 5000 prompt: \"contentdb\" matches"; echo "keypress Return"
	# **Wait for the game to say it has the list, not for a guess**: the
	# server behind this screen took thirty-three seconds to listen on
	# one run here, where the wait was twenty-five (2026-09-24)
	echo "wait_log 90000 vanilla : menu:"
	# Two seconds for the screen's rows to be laid out after the line
	echo "delay 2000"; echo "event scan 8 cdb"
	# **And the game's own way back reaches the room** ([MENU_CONTEXT]:
	# a game's menu offers "back to the launcher", and `buildat.leave()`
	# is what it calls). A sandboxed launch UI is not in the trusted
	# table of loaded extensions, so that call found no launcher and
	# disconnected into nothing -- the client sat with no server and no
	# room (2026-09-24). The row is at the bottom of vanilla's menu
	# panel, which at this window size puts it here; a miss fails the
	# assertion below rather than passing quietly.
	# (The pointer is read a few frames before the click.)
	echo "mouse_pos 480 457"
	echo "delay 300"; echo "mouse_click left"
	# The room says when it has the screen again, which is what the six
	# seconds here were waiting for
	echo "wait_log 30000 game: back in the room"
	echo "quit"; } > "$out/cmds_cdb.txt"
rm -f "$out/cdb_cli.log" "$out/cdb_cli_server.log"
# The mirror's port is not one the server's box connects to by default
# ([PROCESS_SANDBOX] A); the local server inherits this from the client
BUILDAT_CONNECT_PORTS=30211 BUILDAT_CONTENTDB_URL=http://localhost:30211 \
	timeout 150 bin/buildat -m launch_world -w 960x540 -l 3 \
	-L "$out/cdb_cli.log" -c @"$out/cmds_cdb.txt" > /dev/null 2>&1
cdb_rc=$?
kill "$mirror" 2>/dev/null; wait "$mirror" 2>/dev/null
[ "$cdb_rc" = 0 ] || fail "the ContentDB drive stopped (exit $cdb_rc):" \
	"$(grep -a "Command sequence failed" "$out/cdb_cli.log" | tail -1)"
asked=$(grep -ac "launch_w.*: launch: ContentDB" "$out/cdb_cli.log")
drew=$(grep -ac 'scan cdb: .*text "ContentDB: games"' "$out/cdb_cli.log")
rows=$(grep -ac 'scan cdb: .*text "Install"' "$out/cdb_cli.log")
back=$(grep -ac "launch_w.*: game: back in the room" "$out/cdb_cli.log")
lost=$(grep -ac "leave: no launcher to go back to" "$out/cdb_cli.log")
echo "the room asked for ContentDB $asked times; the screen drew $drew" \
		"with $rows rows to install, and came back $back times"
if [ "$asked" -lt 1 ] || [ "$drew" -lt 1 ] || [ "$rows" -lt 1 ]; then
	echo "FAIL: ContentDB does not open from the room"
	grep -a "launch_w.*: launch: " "$out/cdb_cli.log" | tail -3
	exit 1
fi
if [ "$back" -lt 1 ] || [ "$lost" -gt 0 ]; then
	echo "FAIL: a game's own way back does not reach the room -- it" \
			"disconnects into nothing"
	exit 1
fi

# **The formation's rows are browsed and launched like the first**
# ([LAUNCH_WORLD] stage 2: one wall, the games in rows). Down is the
# next row, and Enter launches what is browsed there; and every pocket
# is on the one wall ("f" in the bays line), the three others being cut.
{ echo "wait_log_any 90000 the room hums"; echo "delay 900"
	# (The delay after the browse line is the camera's hop to the row.)
	echo "keypress Down"; echo "wait_log 5000 browse: row"; echo "delay 700"
	echo "screenshot $out/second-row.png"
	echo "wait_log 20000 Wrote screenshot $out/second-row.png"
	echo "keypress Return"
	echo "wait_log 120000 game: the room stands down"
	echo "delay 1200"
	echo "keypress Escape"
	echo "wait_log 30000 game: back in the room"
	echo "quit"; } > "$out/cmds_rows.txt"
wait_quiet 40 || true
run_client 60 "$out/rows_cli.log" \
	timeout 300 bin/buildat -m launch_world -w 640x400 -l 3 \
	-c @"$out/cmds_rows.txt" > /dev/null 2>&1 ||
	fail "the second row's drive stopped:" \
		"$(grep -a "Command sequence failed\|run_client" "$out/rows_cli.log" | tail -1)"
bays=$(grep -a "launch_w.*: bays " "$out/rows_cli.log" | head -1 |
	sed 's/.*bays //')
kinds=$(echo "$bays" | tr ' ' '\n' | grep "^[flrb]$" | sort -u | tr -d '\n')
row=$(grep -a "launch_w.*: browse: row " "$out/rows_cli.log" | tail -1 |
	sed 's/.*browse: row \([0-9]*\).*/\1/')
stood=$(grep -ac "launch_w.*: game: the room stands down" "$out/rows_cli.log")
came=$(grep -ac "launch_w.*: game: back in the room" "$out/rows_cli.log")
echo "the pockets are on the walls \"$kinds\"; Down browsed row" \
		"${row:-none}; the game started $stood and was left $came times"
if [ "$kinds" != "f" ]; then
	echo "FAIL: pockets on a wall other than the one formation wall"
	exit 1
fi
if [ "${row:-0}" -lt 2 ] || [ "$stood" -lt 1 ] || [ "$came" -lt 1 ]; then
	echo "FAIL: a game in the formation's second row does not launch," \
			"or the room does not come back from it"
	exit 1
fi

# **The mark is on the face, not at the limb** ([LAUNCH_WORLD]'s mark
# round failed twice on presentation rather than on the mark: once with
# every orb turned away, once with the sphere a quarter out, and both
# times the sheets showed nothing and the fault took a person to spot).
# So this is the assertion that ends that class: fly to an orb the way
# the room's own search does, and read **the middle of its disc against
# the ring around it**. A mark presented on the face darkens the middle;
# a mark at the limb leaves it the colour of the ball.
#
# The control is the same frame with the presentation turned a quarter
# out, which is exactly the fault that shipped -- so the check knows the
# difference between "a mark is there" and "the sphere is shaded".
for yaw in own 0; do
	extra=""
	[ "$yaw" = "0" ] && extra="BUILDAT_LAUNCH_FACE_YAW=0"
	# **A glowing orb**, because the measurement below is how much of
	# the disc is dark: a chrome sphere is dark all over and says
	# nothing, and this room -- a client with no history -- has no
	# logo-marked orb in it at all, every one of its twenty-five
	# wearing the room's own sigil.
	{ echo "wait_log_any 90000 the room hums"
		echo "event mode menu"; echo "wait_log 15000 camera: landed"
		for c in D I G G; do echo "keypress $c"; done
		echo "wait_log 15000 camera: landed"
		echo "delay 250"
		echo "screenshot $out/mark_face_$yaw.png"
		echo "wait_log 20000 Wrote screenshot $out/mark_face_$yaw.png"
		echo "quit"; } > "$out/cmds_face_$yaw.txt"
	env $extra BUILDAT_LAUNCH_HOP=2.0 timeout 120 bin/buildat -m launch_world \
		-D "$out/emptyuser" -w 1280x720 -l 3 -L "$out/face_$yaw.log" \
		-c @"$out/cmds_face_$yaw.txt" > /dev/null 2>&1 ||
		fail "the mark's face drive ($yaw) stopped:" \
			"$(grep -a "Command sequence failed" "$out/face_$yaw.log" | tail -1)"
done
python3 - "$out" <<'PYMARK' || exit 1
import sys, os
from PIL import Image

out = sys.argv[1]

def disc_radius(path):
	"""**How big the ball is in the frame**, walked out from the middle
	while it stays bright. The camera aims at the orb, so the middle is
	the orb; what changes is how far back the camera had to stand --
	a pocket with a slab beside it pushes it back, and a crop of a
	fixed 120 pixels then holds as much wall as ball and reads the same
	for a marked orb and a turned one (2026-09-25). Measured on the
	*control*, whose disc has no mark at its middle to cut the walk
	short, and used for both.
	"""
	im = Image.open(path).convert("L")
	w, h = im.size
	cx, cy = w // 2, int(h * 0.52)
	px = im.load()
	out = []
	for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
		d = 0
		while d < min(w, h) // 2:
			x, y = cx + dx * d, cy + dy * d
			if not (0 <= x < w and 0 <= y < h) or px[x, y] < 100:
				break
			d += 1
		out.append(d)
	return min(out)

def dark_share(path, r):
	"""**A mark is the dimmer part of a lit ball**, and that is what to
	measure -- against the ball's own brightness rather than against a
	fixed level. The earlier reading was colourfulness, because the
	mark was then a game's own logo in the diffuse; then it was pixels
	under 120, because the mark cut the emission to black. It does not
	any more: [GLOW_MARK] settled at 0.04 of the emissive left under
	it, which reads as a darker orange and never comes near 120.

	So: the share of the disc that is dimmer than the disc's own
	brightest. That survives the cut moving, which it does with the
	emissive multiplier, and the disc being any size in the frame.
	"""
	im = Image.open(path).convert("RGB")
	w, h = im.size
	cx, cy = w // 2, int(h * 0.52)
	px = list(im.crop((cx - r, cy - r, cx + r, cy + r)).getdata())
	lum = sorted(0.3 * r0 + 0.6 * g + 0.1 * b for r0, g, b in px)
	bright = lum[int(len(lum) * 0.95)]
	if bright <= 0:
		return 0.0
	return 100.0 * sum(1 for v in lum if v < bright * 0.8) / float(len(lum))

own = "%s/mark_face_own.png" % out
turned = "%s/mark_face_0.png" % out
for p in (own, turned):
	if not os.path.exists(p):
		print("FAIL: the mark's face was not shot (%s)" % p)
		raise SystemExit(1)
radius = disc_radius(turned)
if radius < 12:
	print("the orb is %d pixels across in the control, which is not a "
			"framing this can read" % (radius * 2))
	print("FAIL: the orb was not framed")
	raise SystemExit(1)
crop = max(12, int(radius * 0.7))
print("the disc is %d pixels across; reading its middle %d"
		% (radius * 2, crop * 2))
a, b = dark_share(own, crop), dark_share(turned, crop)
print("the disc is %.1f%% dark with the mark presented, and %.1f%% with "
		"it a quarter out" % (a, b))
# Measured 36.1 against 0.0 in this room; the bar is the gap
ok = a > 12.0 and b < a * 0.5
if not ok:
	print("FAIL: the orb does not present its mark" if a <= 6.0 else
			"FAIL: the control shows as much mark as the presentation")
raise SystemExit(0 if ok else 1)
PYMARK

# **A save opens by name, end to end** ([LAUNCH_WORLD]: the saves are the
# floor's, and a save is the one launch the grid has no tile for). This
# had only ever been demonstrated as far as the desk's data allowed: every
# save here old enough to try has an empty save.sqlite, so the server
# answered "save X does not say which game it needs" and the round trip
# was never run. The check makes its own save instead of hoping for one.
# The name starts with three letters nothing else here does: the prompt
# finds a save by the start of its name, and this desk has other saves
# beginning "zz" from a session's own driving
save=zza_launch_world_test
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
# What this run is for is the save's own record of which game it needs,
# which is written as the world starts -- so that line is what it waits
# for rather than the whole load
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE="$save" \
	start_server "$out/save_server.log" "Running world $save " 60 auto \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 || true
maker=$SERVER_PID
# **SIGKILL, and it is not laziness**: asked to shut down this early the
# server aborts inside its own shutdown ("corrupted size vs. prev_size",
# 2026-09-24) and sits in the crash handler, which hung this check for
# half an hour. The save is on disk by now and nothing here needs a
# clean exit; the abort itself wants chasing where the server is, not
# worked around by waiting longer.
kill -9 "$maker" 2>/dev/null; wait "$maker" 2>/dev/null
if ! grep -aq "Running world $save (game devtest)" "$out/save_server.log"; then
	echo "SKIP: could not make a save to open (no devtest?)" >&2
	tail -3 "$out/save_server.log" >&2
	exit 2
fi
# Two letters name it and nothing else in the room, Enter opens it, and
# what is asserted is the far end: the server the room started took the
# save's own path and drew no menu on the way.
{ echo "wait_log_any 60000 the room hums"
	echo "event mode menu"; echo "wait_log 15000 camera: landed"
	echo "keypress Z"; echo "keypress Z"; echo "keypress A"
	echo "wait_log 5000 prompt: \"zza\" matches"; echo "keypress Return"
	# **The room says when the game has the view**, which is what the ten
	# seconds here were waiting for; the rest of a world coming up is
	# devtest's business, not this check's
	echo "wait_log 40000 game: the room stands down"
	# 1.5 s for a second main:get_saves to have come and been answered,
	# which is what the dialog assertion below reads
	echo "delay 1500"; echo "quit"; } > "$out/cmds_save.txt"
rm -f "$out/save_cli.log" "$out/save_cli_server.log"
# A client that entered a game does not always get to its own quit
# quickly; the tier's minute is not spent waiting for one that will not
timeout 120 bin/buildat -m launch_world -w 640x400 -l 3 \
	-L "$out/save_cli.log" -c @"$out/cmds_save.txt" > /dev/null 2>&1
# **And a save the floor has no room for opens the same way**: the cap
# is about what is drawn, not about what can be reached, and a client
# with 239 saves that can open twelve of them has lost the rest. With
# the cap at nothing, every save is the prompt's to find.
{ echo "wait_log_any 60000 the room hums"
	echo "event mode menu"; echo "wait_log 15000 camera: landed"
	echo "keypress Z"; echo "keypress Z"; echo "keypress A"
	echo "wait_log 5000 prompt: \"zza\" matches"; echo "keypress Return"
	echo "wait_log 40000 game: the room stands down"
	echo "delay 1500"; echo "quit"; } > "$out/cmds_hidden.txt"  # as above
rm -f "$out/hidden_cli.log" "$out/hidden_cli_server.log"
BUILDAT_LAUNCH_SAVES=0 timeout 120 bin/buildat -m launch_world \
	-w 640x400 -l 3 -L "$out/hidden_cli.log" \
	-c @"$out/cmds_hidden.txt" > /dev/null 2>&1
hidden=$(grep -ac "launch_w.*: launch: save $save of vanilla (not on the floor)" \
	"$out/hidden_cli.log")
hopened=$(grep -ac "untrusted_launch: opening save $save" \
	"$out/hidden_cli_server.log")
echo "a save the floor does not show: asked $hidden, opened $hopened"
if [ "$hidden" -lt 1 ] || [ "$hopened" -lt 1 ]; then
	echo "FAIL: a save past the floor's cap cannot be opened by name"
	grep -a "launch_w.*: saves: \|launch_w.*: launch: " "$out/hidden_cli.log" |
		tail -3
	exit 1
fi

asked=$(grep -ac "launch_w.*: launch: save $save of vanilla" "$out/save_cli.log")
opened=$(grep -ac "untrusted_launch: opening save $save" "$out/save_cli_server.log")
echo "the save orb asked $asked times, the server opened it $opened times"
# **And no dialog over a world that started fine** (user, 2026-09-24):
# main:get_saves arrives more than once, so the save branch used to open
# the save on the first packet and answer "A world is already starting"
# on the second, which the client draws over the loading world. The
# branch fires once now, and an automatic launch logs rather than
# reaching menu_error at all.
# awk rather than bc, which the packaging image does not carry
dialog=$(grep -ac "A world is already starting" \
	"$out/save_cli_server.log" "$out/hidden_cli_server.log" 2>/dev/null |
	sed 's/.*://' | awk '{n += $1} END {print n + 0}')
echo "\"already starting\" said to the client: ${dialog:-0} times"
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
if [ "${dialog:-0}" -gt 0 ]; then
	echo "FAIL: opening a save by name puts a dialog over the world"
	grep -a "already starting\|opening save " "$out/save_cli_server.log" |
		tail -4
	exit 1
fi
if [ "$asked" -lt 1 ] || [ "$opened" -lt 1 ]; then
	echo "FAIL: a save on the floor does not open its own game by name"
	grep -a "launch_w.*: launch: " "$out/save_cli.log" | tail -3
	tail -3 "$out/save_cli_server.log" 2>/dev/null
	exit 1
fi

contents=$(grep -a "launch_w.*: contents: " "$out/cli.log" | head -1 |
	sed 's/.*contents: //')
echo "contents: ${contents:-(none)}"
games=$(echo "$contents" | sed -n 's/^\([0-9]*\) games.*/\1/p')
floor=$(echo "$contents" | sed -n 's/.* \([0-9]*\) other.*/\1/p')
if [ "${games:-0}" -lt 1 ] || [ "${floor:-0}" -lt 1 ]; then
	echo "FAIL: the room found no launch actions in the tree"
	exit 1
fi
# The orb being pointed at says its name; it was drawn inside the stone
# above its niche for a while, which is the kind of thing a log line
# does not catch and a shot does
if ! grep -aq "pointing at orb" "$out/cli.log"; then
	echo "FAIL: no orb is ever pointed at"
	exit 1
fi
grep -a "pointing at orb" "$out/cli.log" | head -1 | sed 's/.*launch_w[a-z]*: //'
for what in "ornament" "synth"; do
	if ! grep -aq "$what ok" "$out/cli.log"; then
		echo "FAIL: the $what did not pass its own check"
		grep -aiE "error|assert" "$out/cli.log" | tail -3
		exit 1
	fi
done
# A -c run is muted, so what can be checked here is the data path and the
# pattern, which is what the two self-checks assert; whether it sounds
# like anything is a listen.
python3 - "$out" <<'PY'
import sys, os, itertools
from PIL import Image, ImageChops

# **The world, not the HUD.** Every check here compares whole frames, so
# anything that changes any pixel can satisfy one -- and the preset
# label and the typing prompt both live along the bottom and both change
# with what is being checked. Two checks were already passing on the
# prompt's own text (2026-09-23), so the comparisons take the frame
# above the strip and nothing else.
HUD_STRIP = 70

def world(im):
	w, h = im.size
	return im.crop((0, 0, w, h - HUD_STRIP))
out = sys.argv[1]
# **The palette comparison is gone** (user, 2026-09-23: the right
# colours are already known). This shot four presets from one viewpoint
# and asserted they differed, which was how the palette was to be picked;
# it is picked. The presets are still in the room, on F1 to F4 and in the
# terminal's rows.
# The probe: the same frame with it and with an environment of nothing
# in its place. What is asserted is that some part of the picture moves a
# lot -- the search is over blocks rather than a fixed crop, because the
# room gets recomposed and a crop that was on a mirror ends up on a wall
# (it read 61.4 against 60.4 on a sphere's dark side while another block
# moved 86 levels, 2026-09-23).
a = world(Image.open("%s/room.png" % out).convert("L"))
b = world(Image.open("%s/room-noprobe.png" % out).convert("L"))
pa, pb = a.load(), b.load()
w, h = a.size
best, bx, by = 0.0, 0, 0
for y in range(0, h - 60, 30):
	for x in range(0, w - 60, 30):
		m = sum(abs(pa[xx, yy] - pb[xx, yy])
				for yy in range(y, y + 60) for xx in range(x, x + 60)) / 3600.0
		if m > best:
			best, bx, by = m, x, y
print("the probe moves a 60x60 block by %.2f of a level at its most, "
		"at %d,%d" % (best, bx, by))
# **15.** The threshold went down to 5 on a reading of 8.92 that was not
# the probe at all: the key that toggles it was a letter, the prompt ate
# it, and what moved was the prompt's own text at the bottom of the
# frame. On a function key the probe moves a sphere by 46 levels
# (2026-09-23).
probe_ok = best > 15.0
print("PASS: the probe reaches the metals" if probe_ok
		else "FAIL: the probe changes nothing on a metal")

# The dissolve: the wall has to move, and the closed picture has to be
# the picture it was
def mean_of(name):
	im = world(Image.open("%s/%s.png" % (out, name)).convert("L"))
	return im, list(im.getdata())

closed, dc = mean_of("dissolve-closed")
opened, do = mean_of("dissolve-open")
again, da = mean_of("dissolve-closed-again")
moved = sum(abs(p - q) for p, q in zip(dc, do)) / float(len(dc))
back = sum(abs(p - q) for p, q in zip(dc, da)) / float(len(dc))
print("the dissolve moves the frame by %.2f of a level and comes back "
		"to within %.2f" % (moved, back))
dissolve_ok = moved > 2.0 and back < moved / 3.0
print("PASS: a bay opens and closes again" if dissolve_ok
		else "FAIL: the dissolve does not open, or does not come back")

# **And the camera goes to each match**: three pictures of three
# different places, so the arrows are not just relabelling a line
s1, d1 = mean_of("search1")
s2, d2 = mean_of("search2")
s3, d3 = mean_of("search3")
hop1 = sum(abs(p - q) for p, q in zip(d1, d2)) / float(len(d1))
hop2 = sum(abs(p - q) for p, q in zip(d2, d3)) / float(len(d2))
print("the search's arrows moved the camera by %.2f and %.2f of a level"
		% (hop1, hop2))
# Six, where the room's own drift over the same second and a half is
# three to five: a hop between two dark corners of the room moves fewer
# levels than one across the lit wall, and 7.8 was a real move read by
# an insensitive measure (2026-09-23)
# Three, not the six of the four-wall room: in the one wall's formation
# two matches can be neighbouring pockets, which look alike -- devtest,
# realtest and Minetest Game read 11.0 and 4.9 (2026-10-03) -- and a
# room left still drifts by about 0.9 between two frames (core.sh)
search_ok = hop1 > 3.0 and hop2 > 3.0
print("PASS: the search walks its matches and the camera follows"
		if search_ok
		else "FAIL: the arrows do not move the camera between matches")

# **A screen on the stack takes the mouse**: with the pause dialog up,
# 220 pixels of mouse movement must not turn the camera, so the frame
# after it closes is the frame before it opened -- within the room's own
# drift, which is a few levels a second and is what the two seconds
# between these shots allow for.
# **The dialog's rows answer the mouse**: hovering one moves the
# selection, and clicking "back to the room" closes the dialog -- so the
# hovered picture differs from the plain one, and the clicked picture
# has no dialog in it
paused_plain, dpp = mean_of("paused")
hovered, dho = mean_of("pause-hover")
clicked, dcl = mean_of("pause-clicked")
hover_moved = sum(abs(p - q) for p, q in zip(dpp, dho)) / float(len(dpp))
closed = sum(abs(p - q) for p, q in zip(dpp, dcl)) / float(len(dpp))
print("hovering a row changed the dialog by %.2f, and clicking one "
		"changed the frame by %.2f" % (hover_moved, closed))
mouse_menu_ok = hover_moved > 0.05 and closed > 1.0
print("PASS: the dialog answers the mouse as well as the keyboard"
		if mouse_menu_ok
		else "FAIL: hovering or clicking a row does nothing")

before_pause, dbp = mean_of("prepause")
after_pause, dap = mean_of("unpaused")
turned = sum(abs(p - q) for p, q in zip(dbp, dap)) / float(len(dbp))
print("the mouse under the pause dialog moved the frame by %.2f of a "
		"level" % turned)
look_ok = turned < 8.0
print("PASS: a screen on the stack takes the mouse" if look_ok
		else "FAIL: the mouse still turns the camera under a menu")

# The typing path: the prompt has to show the match it found, the launch
# has to move the camera, and Escape has to bring the room back to the
# picture it was
typed, _ = mean_of("typed")
launched, dl = mean_of("launched")
home, dh = mean_of("back-home")
flew = sum(abs(p - q) for p, q in zip(dc, dl)) / float(len(dc))
came_back = sum(abs(p - q) for p, q in zip(dc, dh)) / float(len(dc))
print("the launch moves the frame by %.2f of a level and Escape comes "
		"back to within %.2f" % (flew, came_back))
typing_ok = flew > 8.0 and came_back < flew / 2.0
print("PASS: typing a name flies the camera in, and the room comes back"
		if typing_ok else
		"FAIL: the typing path does not launch, or does not come back")

# The terminal: what says it is readable is that the panel covers the
# middle of the frame and has text's contrast in it, not the room's
term, dt = mean_of("terminal")
w, h = term.size
mid = term.crop((w // 2 - 320, h // 2 - 170, w // 2 + 320, h // 2 + 170))
# Text is a few per cent of a panel's area, so a percentile lands on
# the background whatever the rows say: what is counted is how many
# pixels are text-bright against a panel that is dark
px = sorted(mid.getdata())
n = len(px)
dark = px[int(n * 0.30)]
bright = sum(1 for v in px if v > 120)
print("the terminal panel is %d at its third and has %d text-bright "
		"pixels" % (dark, bright))
terminal_ok = dark < 40 and bright > 1500
print("PASS: the terminal is flat, dark and readable" if terminal_ok
		else "FAIL: the terminal panel is not on screen")

# **The stations**: Tab has to move the camera from the wall to the
# floor ([LAUNCH_WORLD] section 11)
stood, ds = mean_of("stood")
walked, dw = mean_of("station-floor")
walk = sum(abs(p - q) for p, q in zip(ds, dw)) / float(len(ds))
print("Tab to the floor moves the frame by %.2f of a level" % walk)
walk_ok = walk > 3.0
print("PASS: Tab moves between the stations" if walk_ok
		else "FAIL: Tab moves nothing")

# **The pause dialog**: it has to appear over the room and go away
# again. A room whose only way out is killing the process is not a
# launcher.
paused, dpa = mean_of("paused")
unpaused, dup = mean_of("unpaused")
came_up = sum(abs(p - q) for p, q in zip(dpa, dup)) / float(len(dpa))
print("the pause dialog moves the frame by %.2f of a level" % came_up)
pause_ok = came_up > 1.0
print("PASS: Escape pauses and Escape comes back" if pause_ok
		else "FAIL: no pause dialog")

# The drift: two frames a second apart, before anything was frozen
drift_a, da2 = mean_of("drift-a")
drift_b, db2 = mean_of("drift-b")
drift = sum(abs(p - q) for p, q in zip(da2, db2)) / float(len(da2))
print("the room drifts by %.2f of a level in a second" % drift)
drift_ok = drift > 0.20
print("PASS: nothing in the room is static" if drift_ok
		else "FAIL: the room is a still frame")

# The attract mode: the camera has to leave its standing place when the
# room is left alone, and come back when it is touched
ah, dah = mean_of("attract-home")
aw, daw = mean_of("attract-away")
ab, dab = mean_of("attract-back")
went = sum(abs(p - q) for p, q in zip(dah, daw)) / float(len(dah))
came = sum(abs(p - q) for p, q in zip(dah, dab)) / float(len(dah))
print("the attract mode moves the frame by %.2f of a level and a key "
		"brings it back to within %.2f" % (went, came))
attract_ok = went > 10.0 and came < went / 2.0
print("PASS: the room shows itself off when left alone" if attract_ok
		else "FAIL: the attract mode does not run, or does not come back")

# The ornament: the friezes stripped to plain stone have to change the
# frame, or the generated maps are not reaching anything
plain, dp = mean_of("no-ornament")
ornamented = sum(abs(p - q) for p, q in zip(dc, dp)) / float(len(dc))
print("stripping the ornament moves the frame by %.2f of a level"
		% ornamented)
ornament_ok = ornamented > 1.5
print("PASS: the generated ornament is on something" if ornament_ok
		else "FAIL: nothing in the room wears the generated maps")
# **The top of the picture** ([PBR_HDR]): a renderer that clips every
# radiance at 1.0 before the tonemap has nothing above its shoulder to
# roll off, and a source then cannot be brighter than a fully-lit wall.
#
# **The 99.9th and not the 99th.** The 99th was the measure while the
# orbs were 8-voxel pockets filling much of the frame; at 3 voxels and
# at a standing eye they are half a per cent of it, and the 99th then
# reads the wall (128) however bright the sources are -- it measured the
# composition, not the range (2026-09-23).
shot = sorted(Image.open("%s/room.png" % out)
		.convert("L").crop((0, 0, 1280, 720 - HUD_STRIP)).getdata())
top = shot[int(len(shot) * 0.999)]
lit = sum(1 for v in shot if v >= 248) / float(len(shot))
print("the room's 99.9th percentile is %d and %.2f%% of it is a source"
		% (top, lit * 100))
hdr_ok = top >= 240 and lit > 0.002
print("PASS: a source is brighter than a lit wall" if hdr_ok
		else "FAIL: the picture clips before its shoulder -- HDR is off")
every = (probe_ok and dissolve_ok and typing_ok and terminal_ok
		and ornament_ok and drift_ok and attract_ok and hdr_ok and walk_ok
		and pause_ok and look_ok and search_ok and mouse_menu_ok)
# The one line a machine reads, after the ones a person does
print("PASS: the room is what it says it is" if every
		else "FAIL: the room is not what it says it is")
sys.exit(0 if every else 1)
PY
