#!/bin/bash
# tier: quick
# ci
# cost: 8s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [LAUNCH_CONSOLE]: the third launch UI -- the API document on the left
# and a Lua console on the right. What is asserted is what cannot be
# seen in a picture: that eval runs in the caller's own environment, so
# what one line leaves the next line sees; that a bad line is an answer
# rather than a crash; that the document was found and read; and that a
# line typed at the field is run.
#
#   extensions/launch_console/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/launch_console"; mkdir -p "$out"
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi
# **`text`, not `keypress`**: a LineEdit fills from SDL's text input
# rather than from key events, so a scripted keypress moves the focus
# and types nothing. The field has the keyboard from the start.
# A key and the text after it go in one frame, in order, and the
# handlers run as they come (the focus cycle is Urho3D's UI::HandleKeyDown),
# so nothing waits between them: each step waits for the console's answer.
{ echo "wait_log_any 30000 lines of the API document"
	echo "text buildat.version()"
	echo "keypress Return"
	echo "wait_log 5000 console: buildat.version() = "
	# **The slot, asked from inside the sandbox**: a launch UI can list
	# the others, which is what the menu's own switch is built on, and
	# the console is where anyone can check that by typing
	echo "text #buildat.list_launch_uis()"
	echo "keypress Return"
	echo "wait_log 5000 console: #buildat.list_launch_uis() = "
	# **The search on the left**, which a playtest found did nothing:
	# Tab moves the keyboard into it, a term is typed, and Enter has to
	# move the view to a line that has it.
	echo "keypress Tab"
	echo "text voxel"
	echo "keypress Return"
	echo "wait_log 5000 console: search voxel -> "
	echo "screenshot $out/console.png"
	# **And the line the search found copies out** (this screen's
	# done-when: text copies out of the document). A `Text` has a
	# selection and no copy of its own, so Ctrl+C takes the line the
	# selection is on -- the unit a person reading an API wants.
	echo "keydown CTRL"
	echo "keypress C"
	echo "keyup CTRL"
	echo "wait_log_any 5000 console: copied "
	# **And Tab comes back to the console** ([LAUNCH_WORLD], 2026-09-24:
	# whatever holds the screen owns the input). Tab is Urho3D's own
	# focus cycle now, which is what works whether this screen was
	# booted or drawn over a room; a line evaluated after a second Tab
	# is what says the keyboard came back rather than landing on the
	# document.
	echo "keypress Tab"
	echo "text 7*6"
	echo "keypress Return"
	echo "wait_log 5000 console: 7*6 = "
	echo "quit"; } > "$out/cmds.txt"
bin/buildat -m launch_console -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	fail "the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"
back=$(grep -ac "console: 7\*6 = 42" "$out/cli.log")
echo "the keyboard came back to the console $back times"
if [ "$back" -lt 1 ]; then
	echo "FAIL: Tab does not come back from the search to the console"
	grep -a "console: " "$out/cli.log" | tail -3
	exit 1
fi
if grep -aq "Crash: SIG" "$out/cli.log"; then
	echo "FAIL: the client crashed --" \
			"$(grep -a "Crash: SIG" "$out/cli.log" | head -1)"
	exit 1
fi
evalline=$(grep -a "launch_c.*: console: eval " "$out/cli.log" | head -1 |
	sed 's/.*launch_c[a-z]*: //')
doc=$(grep -a "launch_c.*: console: [0-9]* lines" "$out/cli.log" | head -1 |
	sed -n 's/.*console: \([0-9]*\) lines.*/\1/p')
typed=$(grep -ac "launch_c.*: console: buildat.version() = " "$out/cli.log")
copied=$(grep -a "launch_c.*: console: copied [0-9]* characters" "$out/cli.log" |
	head -1 | sed -n 's/.*copied \([0-9]*\) characters.*/\1/p')
echo "Ctrl+C put ${copied:-0} characters on the clipboard"
if [ "${copied:-0}" -lt 1 ]; then
	echo "FAIL: the line the search found does not copy out"
	exit 1
fi
echo "${evalline:-(eval said nothing)}"
echo "the document is ${doc:-0} lines, and a typed line ran $typed times"
if [ -z "$evalline" ] || echo "$evalline" | grep -q FAILED; then
	echo "FAIL: eval does not do what a console needs -- $evalline"
	exit 1
fi
if [ "${doc:-0}" -lt 1000 ]; then
	echo "FAIL: the API document was not read (${doc:-0} lines)"
	exit 1
fi
if [ "$typed" -lt 1 ]; then
	echo "FAIL: a line typed at the console did not run"
	exit 1
fi
found=$(grep -a "console: search voxel -> line " "$out/cli.log" | head -1 |
	sed 's/.*-> line \([0-9]*\).*/\1/')
echo "the search found 'voxel' at line ${found:-(nowhere)}, and it is"\
		"selected"
if [ -z "$found" ] || [ "$found" -lt 1 ]; then
	echo "FAIL: the search does not move the document"
	exit 1
fi

uis=$(grep -a "launch_c.*: console: #buildat.list_launch_uis() = " "$out/cli.log" |
	head -1 | sed 's/.*= //')
echo "the sandbox can see $uis launch UIs"
if [ -z "$uis" ] || [ "$uis" -lt 3 ]; then
	echo "FAIL: a launch UI cannot list the others (${uis:-none})"
	exit 1
fi
# vim: set noet ts=4 sw=4:
echo "PASS: the console reads the API and runs what is typed at it"
exit 0
