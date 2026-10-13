#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 0s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [FOCUS_LOG]: the mouse's capture follows the window's focus. A client in
# devtest, the mouse hidden by the first placement; then ten times the
# window loses focus (minimized) and gets it back (activated) through
# xdotool, and after every regain the log has to say the cursor was
# hidden and captured again. Prints the count and PASS or FAIL.
#
#   builtin/luanti/test/focus.sh
#
# Wants a display of its own and xdotool; the window is found by the
# client's pid. See the skip below: it is not run on a display in use.
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
# **Never on a display someone is using** (user, 2026-09-23: this check
# injected alt+Tab into the session they were working in). It minimizes
# windows, activates them and sends keys through the X server, and no
# amount of --window keeps that to itself -- a window manager grabs
# alt+Tab globally, and an activate steals focus from whatever the
# person was typing in. So it runs on a display of its own and skips
# otherwise: BUILDAT_FOCUS_DISPLAY=:N names an Xephyr or Xvfb started
# for it, and BUILDAT_FOCUS_X11=1 says the session is nobody's.
if [ -n "${BUILDAT_FOCUS_DISPLAY:-}" ]; then
	export DISPLAY="$BUILDAT_FOCUS_DISPLAY"
elif [ -z "${BUILDAT_FOCUS_X11:-}" ]; then
	echo "SKIP: focus.sh drives a real X session (alt+Tab, minimize," \
			"activate); give it a display of its own with" \
			"BUILDAT_FOCUS_DISPLAY=:N, or say the session is nobody's" \
			"with BUILDAT_FOCUS_X11=1"
	exit 77
fi
here=$(cd "$(dirname "$0")/../../.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_focus.XXXXXX")
cd "$here/Build"
rm -rf $BUILDAT_USER_PATH/apps/vanilla/saves/buildat_test_focus
srv=""; cli=""
trap '[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"; kill "$cli" 2>/dev/null; kill -INT "$srv" 2>/dev/null' EXIT
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=buildat_test_focus \
	start_server "$tmp/srv.log" "Mods loaded" 60 auto \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla ||
	{ echo "FAIL: the server did not start"; exit 1; }
port=$SERVER_PORT
srv=$SERVER_PID
# Not a scripted client: one under -c keeps the cursor visible and its
# focus forced, which is the opposite of what is tested. Killed at the end.
bin/buildat -s "localhost:$port" -w 640x360 -l 3 \
	> "$tmp/cli.log" 2>&1 &
cli=$!
wait_for_log "$tmp/cli.log" "the first placement" 60 ||
	{ echo "FAIL: the client was not placed ($tmp/cli.log)"; exit 1; }
# This run's client and no other window: by the client's pid, never by a
# title, which another buildat or an editor may carry
pid=$(check_pgrep buildat | tail -1)
win=""
for i in $(seq 1 50); do
	win=$(xdotool search --pid "$pid" --onlyvisible 2>/dev/null | head -1)
	[ -n "$win" ] && break
	sleep 0.2
done
[ -n "$win" ] || { echo "FAIL: no window for the client pid $pid"; exit 1; }
# Each step waits for the client to log it, up to 5 s: the count of
# <text> in the log above <n>. A step not seen ends the loop, and the
# counts below say FAIL.
seen_more()
{
	local j
	for j in $(seq 1 25); do
		[ "$(grep -ac "$1" "$tmp/cli.log")" -gt "$2" ] && return 0
		kill -0 "$cli" 2>/dev/null || return 1
		sleep 0.2
	done
	return 1
}
flip()
{
	local n r=0
	n=$(grep -ac "mouse visible (focus lost)" "$tmp/cli.log")
	xdotool windowminimize "$win"
	seen_more "mouse visible (focus lost)" "$n" || r=1
	n=$(grep -ac "mouse hidden (focus regained)" "$tmp/cli.log")
	xdotool windowactivate --sync "$win" 2>/dev/null
	seen_more "mouse hidden (focus regained)" "$n" || r=1
	return $r
}
for i in $(seq 1 10); do
	flip || break
done
# And an alt+tab as the keys, to this window: the Tab under Alt reaches
# the client before the window manager acts, and it must not be taken
# as the game's mouse key (which is Tab). The 0.2 s are the keys' own
# timing; the second after is what a wrong "the mouse key" line would
# take to show, which nothing marks as not coming.
xdotool keydown --window "$win" alt; sleep 0.2
xdotool key --window "$win" Tab; sleep 0.2
xdotool keyup --window "$win" alt; sleep 1
flip
kill "$pid" 2>/dev/null
lost=$(grep -ac "mouse visible (focus lost)" "$tmp/cli.log")
regained=$(grep -ac "mouse hidden (focus regained)" "$tmp/cli.log")
last=$(grep -a "mouse hidden\|mouse visible" "$tmp/cli.log" | tail -1 | sed 's/^.*Urho3D INFO: //')
echo "focus: lost $lost, regained $regained; last: $last"
echo "logs in $tmp"
mouse_key=$(grep -ac "mouse visible (the mouse key)" "$tmp/cli.log")
echo "focus: the mouse key under alt+tab freed the mouse $mouse_key times"
if [ "$regained" -ge 11 ] && [ "$mouse_key" = 0 ] &&
		[ "$last" = "mouse hidden (focus regained)" ]; then
	echo PASS
else
	echo FAIL
	exit 1
fi
