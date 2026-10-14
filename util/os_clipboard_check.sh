#!/bin/bash
# tier: quick
# cost: ~1 min (2026-10-11)
# covers: src/client/app.cpp 3rdparty/Urho3D/Source/ThirdParty/SDL/src/video/x11/SDL_x11clipboard.c
# [OS_CLIPBOARD]: a text field's Ctrl+V reads the OS clipboard and its
# Ctrl+C writes it. On a headless weston of its own (the user's clipboard
# is not touched), through its Xwayland: xclip puts "A1" on the
# clipboard, the client pastes it into the launcher's port field, types
# Z, selects all and copies, and the clipboard then reads "A1Z". Skips without weston and xclip.
# [PASTE_PRIMARY]: with the clipboard empty (no owner, or owned with "")
# the primary selection is pasted; with both holding text, the
# clipboard's; with neither, nothing and no hang; and the copy is on both.
# simplified: X11 only. Headless weston has no seat, so on its Wayland
# neither wl-copy nor SDL gets a clipboard; a Wayland leg wants a
# compositor with one (weston's x11 backend, or the user's session).
#   util/os_clipboard_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
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
# The 300 ms are the field's focus after the click. The 6 s at the end
# are the client holding the clipboard while the shell reads it; the shell
# ends the client as soon as it has
cat > "$t/cmds" <<C
wait_log_any 20000 Join a Buildat server: shown
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
# The copy is read while the client still owns the clipboard; each drive
# starts with neither selection owned (the last client owned both, and
# left)
drive(){ # name, the text the copy should be, get command, env...
	local name=$1 want=$2 get=$3; shift 3
	env "$@" timeout 60 Build/bin/buildat -D "$t/cl_$name" -w 800x600 -l 3 \
		-o sound_mute=1 -o launch_ui=launch_menu \
		-a extension/launch_menu/connect -c @"$t/cmds" > "$t/$name.log" 2>&1 &
	local pid=$! got= primary=
	CHECK_PIDS+=($pid)
	for i in $(seq 100); do
		got=$($get 2>/dev/null)
		if [ "$got" = "$want" ]; then
			primary=$(DISPLAY=$d xclip -selection primary -o 2>/dev/null)
			break
		fi
		sleep 0.1
		kill -0 $pid 2>/dev/null || break
	done
	kill $pid 2>/dev/null
	wait $pid
	[ "$got" = "$want" ] || fail "$name: the clipboard reads \"$got\", not $want ($t/$name.log)"
	[ "$primary" = "$want" ] || fail "$name: the primary selection reads \"$primary\" ($t/$name.log)"
	echo "ok: $name"
}
x11(){ drive "$@" "env DISPLAY=$d xclip -selection clipboard -o" DISPLAY=$d \
	WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11; }
clip(){ DISPLAY=$d xclip -selection "$1" <<< "$2" -r; }
clip clipboard A1
x11 x11 A1Z
x11 neither Z
clip primary P1
x11 primary P1Z
printf "" | DISPLAY=$d xclip -selection clipboard
clip primary P2
x11 empty_clipboard P2Z
clip clipboard A3
clip primary P3
x11 both A3Z
echo "PASS: Ctrl+V pastes the OS clipboard in, else the primary selection, and Ctrl+C copies out (X11)"
