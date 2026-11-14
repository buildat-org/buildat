#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~15 s (2026-11-14)
# covers: 3rdparty/Urho3D/Source/Urho3D/UI/Text3D.cpp src/client/command_seq_run.h
# [KIT_RESIZE_CRASH] Kit's editor through a mode change: the touch mode
# (right-handed), edit mode on, a new project from the Capture the flag
# template (its signs are Text3D at 48 pt) in a 3390x1912 window, made
# 3840x2160, 3390x1912 and 3840x2160 again by the drive's window command
# (SetMode, as F11: every GPU object lost; the UI scale 1.77 and 2). The
# signs' faces reload at the new scale on fewer pages, and Text3D freed the
# geometries and materials of batches the view had queued: SIGSEGV in
# Batch::Prepare on the first. The client lives through the three and
# quits. On a headless weston of its own, as the user's screen is no
# bigger than the window (software GL). Skips without weston.
#   util/kit_resize_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
check_tmp kit_resize; t=$CHECK_TMP
# pixman: the compositor on no GPU (gl picks the discrete one)
weston --backend=headless --renderer=pixman --xwayland \
	--socket=buildat-resize-$$ --width=3840 --height=2160 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
d=
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 30000 world_menu: the list shown
frames 3
click Button "New project..."
wait_log 5000 world_menu: the name screen shown
frames 3
click DropDownList "▼"
frames 5
click Text "Capture the flag"
wait_log 5000 world_menu: template picked
frames 3
click Button "Create"
wait_log_any 60000 player physics enabled
wait_log_any 20000 kit editor: edit mode on
wait_log_any 20000 touch shell: pixels
frames 10
EOF
	for s in "3840 2160" "3390 1912" "3840 2160"; do
		printf 'window %s\nwait_log_any 20000 screen mode: %s\nframes 30\n' "$s" "${s/ /x}"
	done
	echo quit
} > "$t/cli.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_TEST_KIT_UI_MODE=2 BUILDAT_TEST_REAL_WINDOW=1 \
	run_client 60 "$t/cli.log" timeout 300 bin/buildat -C "$t/client_cache" -D "$t/cu" \
	-s localhost:$SERVER_PORT -w 3390x1912 -l 3 -c @"$t/cli.cmds" ||
	fail "the client ($t/cli.log, $t/srv.log)"
for w in "kit: entity [0-9]* shows" "UI scale 1\.77[0-9]* \(3390x1912\)" "UI scale 2 \(3840x2160\)"; do
	grep -aqE "$w" "$t/cli.log" || fail "no \"$w\" ($t/cli.log)"
done
echo "PASS: Kit's editor with signs lives through three mode changes across UI scales"
# vim: set noet ts=4 sw=4:
