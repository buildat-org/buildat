#!/bin/bash
# tier: quick
# cost: ~15 s (2026-10-11)
# covers: src/client/app.cpp
# [OS_CLIPBOARD]: a text field's Ctrl+V reads the OS clipboard and its
# Ctrl+C writes it. On a headless weston of its own (the user's clipboard
# is not touched), through its Xwayland: xclip puts "A1" on the
# clipboard, the client pastes it into the launcher's port field, types
# Z, selects all and copies, and the clipboard then reads "A1Z". Skips without weston and xclip.
# simplified: X11 only. Headless weston has no seat, so on its Wayland
# neither wl-copy nor SDL gets a clipboard; a Wayland leg wants a
# compositor with one (weston's x11 backend, or the user's session).
#   util/os_clipboard_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
cd "$(dirname "$0")/.."
for c in weston xclip; do
	command -v $c > /dev/null || { echo "SKIP: no $c"; exit 0; }
done
check_tmp os_clipboard; t=$CHECK_TMP
trap check_cleanup EXIT
sock=buildat-clip-$$
weston --backend=headless --xwayland --socket=$sock --width=1024 \
	--height=768 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
cat > "$t/cmds" <<C
delay 4000
click LineEdit "29500"
delay 300
keypress End
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keydown ctrl
keypress v
keyup ctrl
text Z
keydown ctrl
keypress a
keypress c
keyup ctrl
delay 6000
quit
C
# The copy is read while the client still owns the clipboard
drive(){ # name, get command, env...
	local name=$1 get=$2; shift 2
	env "$@" timeout 60 Build/bin/buildat -D "$t/cl_$name" -w 800x600 -l 3 \
		-o sound_mute=1 -o launch_ui=launch_menu \
		-a extension/launch_menu/connect -c @"$t/cmds" > "$t/$name.log" 2>&1 &
	local pid=$! got=
	CHECK_PIDS+=($pid)
	for i in $(seq 100); do
		got=$($get 2>/dev/null)
		[ "$got" = A1Z ] && break
		sleep 0.1
		kill -0 $pid 2>/dev/null || break
	done
	wait $pid
	[ "$got" = A1Z ] || fail "$name: the clipboard reads \"$got\", not A1Z ($t/$name.log)"
	echo "ok: $name"
}
DISPLAY=$d xclip -selection clipboard <<< "A1" -r
drive x11 "env DISPLAY=$d xclip -selection clipboard -o" DISPLAY=$d \
	WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11
echo "PASS: Ctrl+V pastes the OS clipboard in and Ctrl+C copies out (X11)"
