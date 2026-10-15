#!/bin/bash
# tier: quick
# cost: 104s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# covers: extensions/ui_utils/** client/core/uistack/** extensions/launch_menu/** apps/vanilla/main/client_lua/**
# (this is the runner that drives them: every launch UI booted by name,
# a game of vanilla's left through the stack, a screen pushed over the
# menu, and a dead server's dialog)
# [MENU_FALLBACK]: **every launch UI boots**. Nothing started
# `launch_menu` in any check, so the quick tier signed off version one
# while `-m launch_menu` was aborting the client (user, 2026-09-23) --
# a launcher nobody drives is a launcher nobody notices breaking.
#
#   extensions/launch_menu/check.sh
#
# Every extension that ships a launch_ui.txt is booted by name.
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/launch_uis"; mkdir -p "$out"
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi
names=""
for f in "$here"/extensions/*/launch_ui.txt; do
	[ -e "$f" ] || continue
	n=$(basename "$(dirname "$f")")
	# The hostile one is a launch UI on purpose and reaches nothing; it
	# has its own check and boots no screen
	[ "$n" = sandbox_test ] && continue
	names="$names $n"
done
bad=0
for n in $names; do
	# Each UI's own line for being up; one not listed here gets the old
	# 2.5 s. The 500 ms after it is for a raise in the frames after
	case $n in
		launch_console) ready="lines of the API document" ;;
		launch_menu) ready="rows in" ;;
		launch_menu_attract|launch_world) ready="the room hums" ;;
		*) ready="" ;;
	esac
	if [ -n "$ready" ]; then
		printf 'wait_log_any 30000 %s\ndelay 500\nquit\n' "$ready"
	else
		printf 'delay 2500\nquit\n'
	fi > "$out/cmds.txt"
	# **Under a timeout** (2026-09-24, twice in one hour): a client can
	# hang in X11_ShowWindow waiting for the window manager to map its
	# window, and a boot check that waits forever on the desk's weather
	# reports nothing at all
	timeout 60 bin/buildat -m "$n" -w 640x360 -l 3 \
		-c @"$out/cmds.txt" > "$out/$n.log" 2>&1
	why=""
	grep -aq "Crash: SIG" "$out/$n.log" && why="crashed"
	grep -aq "did not load; falling back" "$out/$n.log" &&
		why="${why:+$why, }raised and fell back"
	grep -aq "could not start a launch UI" "$out/$n.log" &&
		why="${why:+$why, }left the client with no launcher"
	grep -aq "Command sequence complete" "$out/$n.log" ||
		why="${why:+$why, }never got to the end of its sequence"
	if [ -n "$why" ]; then
		echo "  $n: $why"
		bad=$((bad + 1))
	else
		echo "  $n: up"
	fi
done
echo "$(echo "$names" | wc -w) launch UIs booted, $bad of them badly"

# **And a game can be left.** A launcher that cannot be gone back to
# leaves a client with no server and no menu, and nothing short of
# [FIRST_RUN]'s twenty minutes was driving it: the menu had no
# `leave_app` at all, so a game started from the default launcher was
# a one-way trip (2026-09-24). This boots the menu straight into a
# game's own screen (-a runs one launch action), presses Escape there (its
# "< back to the launcher"), and asks the client to describe itself
# afterwards -- a dead client answers nothing.
# The 1500 ms before Escape is also the time a second run of menu.lua
# (below) would take to show; the 500 ms after Home are its rows drawn.
{ echo "wait_log_any 60000 menu: ContentDB "; echo "event scan 8 a"
	echo "delay 1500"
	echo "keypress Escape"
	echo "wait_log 20000 launch_menu: back to Home"; echo "delay 500"
	echo "event scan 8 b"; echo "quit"; } > "$out/cmds_back.txt"
timeout 120 bin/buildat -o launch_ui=launch_menu -a app/vanilla/contentdb 	-w 1280x720 -l 3 -L "$out/back.log" -c @"$out/cmds_back.txt" 	> /dev/null 2>&1
back_rc=$?
# **A dead client is not a leave that did not work** ([CONTENTDB_SCAN]):
# the scan below answers nothing when the client has taken a signal, and
# the leave's own verdict then named the wrong fault
if grep -aq "Crash: SIG" "$out/back.log"; then
	echo "FAIL: the client died on the contentdb screen, before the leave"
	grep -a "Crash: SIG" -A 6 "$out/back.log" | head -8
	exit 1
fi
[ "$back_rc" = 0 ] || fail "the leave's drive ($out/back.log):" \
	"$(grep -a 'Command sequence failed' "$out/back.log" | head -1)"
home=$(grep -ac "launch_menu: back to Home" "$out/back.log")
lost=$(grep -ac "leave: no launcher to go back to" "$out/back.log")
alive=$(grep -ac "scan b: ui" "$out/back.log")
echo "leaving a game: back to Home $home times, $alive elements" 		"drawn after it"
# **And the launch was remembered** ([LAUNCH_API]): the history is the
# API's, so "recently played" is one list every launch UI reads rather
# than one per launcher that disagrees with the next
hist="$BUILDAT_USER_PATH/launch_history.csv"
if ! grep -aq " app/vanilla/contentdb$" "$hist" 2>/dev/null; then
	echo "FAIL: the launch history does not hold the action that was run"
	tail -3 "$hist" 2>/dev/null
	exit 1
fi
runs=$(grep -ac 'run_script_file("main/menu.lua")' "$out/back.log")
echo "the game's menu script was run $runs times"
if [ "$runs" -gt 1 ]; then
	echo "FAIL: main/menu.lua is run once per batch of announced files --" \
			"the whole menu is drawn again over the one on the screen"
	exit 1
fi
if [ "$home" -lt 1 ] || [ "$lost" -gt 0 ] || [ "$alive" -lt 10 ]; then
	echo "FAIL: a game started from the menu cannot be left -- the client" 			"is left with no server and no menu"
	grep -a "leave:\|Failed to run function" "$out/back.log" | head -3
	exit 1
fi
# **And the console opens over the menu** ([LAUNCH_CONSOLE] offers its
# screen to every launch UI, and the room had it first). A search for it
# leaves its row the only one and selected; Return opens it and Escape
# hands the menu back.
# **The pointer goes to a corner first**: a row under the mouse takes the
# selection as the menu appears (HoverBegin).
# The 300 ms are the hover let go in the frames after the move.
{ echo "wait_log_any 20000 rows in"; echo "mouse_pos 2 2"
	echo "delay 300"; echo "text developer c"
	echo "wait_log 5000 rows for \"developer c\""
	echo "keypress Return"; echo "wait_log 10000 lines of the API document"
	echo "keypress Escape"; echo "wait_log 5000 console: closed"; echo "quit"; } \
	> "$out/cmds_console.txt"
rm -f "$out/console.log"
timeout 60 bin/buildat -m launch_menu -w 1024x640 -l 3 \
	-L "$out/console.log" -c @"$out/cmds_console.txt" > /dev/null 2>&1 ||
	fail "the console's drive ($out/console.log):" \
		"$(grep -a 'Command sequence failed' "$out/console.log" | head -1)"
copened=$(grep -ac "console: .* lines of the API document" "$out/console.log")
cclosed=$(grep -ac "console: closed" "$out/console.log")
echo "the menu's console opened $copened times, closed $cclosed"
if [ "$copened" -lt 1 ] || [ "$cclosed" -lt 1 ]; then
	echo "FAIL: the menu cannot open the developer console"
	grep -a "launch_menu: \|console:" "$out/console.log" | tail -3
	exit 1
fi

if [ "$bad" -gt 0 ]; then
	echo "FAIL: a launch UI does not start"
	exit 1
fi
# **And a server that dies is shown, not swallowed** ([START_PROGRESS]).
# When the local server goes, the client asks the launcher to say so --
# the last lines of its log and where the whole of it is, so a crash's
# backtrace is on the screen rather than gone. That path reads the
# launcher through the same lookup that had nothing in it for a
# sandboxed launch UI, so it is worth driving beside the one above.
# The server is killed by this script, so the drop is the drive's own;
# the 300 ms are the dialog drawn in the frames after its line
{ echo "expect_error Disconnected from server"
	echo "wait_log_any 60000 menu: ContentDB "
	echo "wait_log 20000 dead server shown"; echo "delay 300"
	echo "event scan 8 d"; echo "quit"; } > "$out/cmds_dead.txt"
# **Last run's log is not this run's** (2026-09-24: the pid read out of
# it was the run before's, so the kill took nothing and the assertion
# failed on a server that was never touched)
rm -f "$out/dead.log" "$out/dead_server.log"
timeout 120 bin/buildat -o launch_ui=launch_menu -a app/vanilla/contentdb \
	-w 1280x720 -l 3 -L "$out/dead.log" -c @"$out/cmds_dead.txt" \
	> /dev/null 2>&1 &
client=$!
# The server the client started, by the pid it logged: pkill would take
# any server on this desk with it
srv=""
trap 'kill $client $srv 2>/dev/null' EXIT
for i in $(seq 1 200); do
	srv=$(grep -a "Started pid [0-9]*: .*buildat_server" "$out/dead.log" 2>/dev/null |
		tail -1 | sed -n 's/.*Started pid \([0-9]*\):.*/\1/p')
	[ -n "$srv" ] && break
	kill -0 $client 2>/dev/null || break
	sleep 0.2
done
if [ -n "$srv" ]; then
	# Once the screen it serves is drawn: what is being driven is a
	# server that goes away under a client that is using it, not one
	# that fails to start
	wait_for_log "$out/dead.log" "menu: ContentDB " 60 &&
		kill -9 "$srv" 2>/dev/null
fi
wait "$client" 2>/dev/null
said=$(grep -ac 'scan d: .*text "The server exited' "$out/dead.log")
cannot=$(grep -ac "the launcher cannot show a dead server" "$out/dead.log")
echo "a server that died (pid ${srv:-none}): the launcher said so" \
		"$said times"
if [ -z "$srv" ] || [ "$said" -lt 1 ] || [ "$cannot" -gt 0 ]; then
	echo "FAIL: a local server that dies is not shown by the launcher"
	grep -a "cannot show a dead server\|Disconnected" "$out/dead.log" |
		head -3
	exit 1
fi

# vim: set noet ts=4 sw=4:
echo "PASS: every launch UI this tree ships starts, a game can be left," \
		"and a dead server is shown"
exit 0
