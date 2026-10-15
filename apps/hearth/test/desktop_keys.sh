#!/bin/bash
# tier: broken
# broken: back to long; the screenshot was not picked (dev)
#   (local/runs/dev_baseline)
# cost: ~60 s (2026-10-09)
# covers: client/core/network/init.lua src/client/app_lua.h extensions/ui_utils/init.lua
# [HEARTH_USABILITY] 2, **desktop, by keyboard only**: the case of
# desktop_mouse.sh with keys alone. Down to Help in the sidebar, Enter,
# Right to New thread..., Enter; the title, Down past the topic and the
# kind to the message; Tab to Start the thread, Down along the row to
# File..., Enter; Escape lets the picker go (the draft stays, the focus on
# File...), Enter again; the picker's focus starts on its first file, Up
# to the places, Screenshots, the shot; Tab, Enter starts the thread.
# The reader is trusted by the admin first ([TRUST_LADDER]).
#   apps/hearth/test/desktop_keys.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
t=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
P=29896
U=http://127.0.0.1:$P

cd "$here/Build"
start_server "$t/srv.log" "setup code" 60 $P \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
pid=$SERVER_PID
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "no setup code (srv.log: $(tail -3 "$t/srv.log"))"

client(){ # name password log cmds [env...]
	local n=$1 pw=$2 log=$3 cmds=$4
	shift 4
	env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=$pw BUILDAT_HEARTH_CREATE=1 \
		BUILDAT_HEARTH_CODE=$code "$@" \
		timeout 120 bin/buildat -o launch_ui=launch_menu -D "$t/cl_$n" -w 1280x720 \
		-l 3 -o sound_mute=1 -s 127.0.0.1:$P -c @"$cmds" > "$log" 2>&1
}
answer(){ # log id
	grep -ao "hr: {.*\"id\":$2,.*" "$1" | head -1
}

printf 'wait_log_any 30000 "id":1001,\nquit\n' > "$t/wait"
printf 'wait_log_any 30000 "id":1001,\nwait_log_any 30000 admin script: done\nquit\n' > "$t/wait_admin"
client admin checkpass12 "$t/admin.log" "$t/wait_admin" \
	BUILDAT_HEARTH_REQS='{"cmd":"new_topic","name":"Help","about":"Questions"}' \
	"BUILDAT_HEARTH_ADMIN=add reader readerpass12" ||
	fail "the admin's run: $(grep -a 'Command sequence failed\|^E' "$t/admin.log" | tail -2)"
answer "$t/admin.log" 1001 | grep -q '"ok":true' || fail "the topic: $(answer "$t/admin.log" 1001)"
client admin checkpass12 "$t/admin2.log" "$t/wait" \
	BUILDAT_HEARTH_REQS='{"cmd":"trust","name":"reader","on":true}' ||
	fail "the admin's run: $(grep -a 'Command sequence failed\|^E' "$t/admin2.log" | tail -2)"
answer "$t/admin2.log" 1001 | grep -q '"ok":true' || fail "the trust: $(answer "$t/admin2.log" 1001)"

# The shot the user took, where the client puts its own
mkdir -p "$t/cl_reader/screenshots"
cp "$here/3rdparty/Urho3D/bin/Data/Textures/LogoLarge.png" \
	"$t/cl_reader/screenshots/screenshot_lamp.png"
# A game's export, so that the picker opens on a file
mkdir -p "$t/cl_reader/exports"
cp "$here/3rdparty/Urho3D/bin/CoreData/Textures/Spot.png" "$t/cl_reader/exports/plan.png"
# The places above the list: Pictures only when the home has some
ups=3
[ -n "$(ls -A "$HOME/Pictures" 2>/dev/null)" ] && ups=4
# Each step waits for its page or the picker's line; the Escape that lets
# the picker go logs nothing, so a short delay is the frame for the shot
{
	echo "wait_log 30000 hearth: page Hearth"
	# Home, Search, Notifications, Following, Help
	for _ in 1 2 3 4 5; do echo "keypress Down"; done
	printf 'keypress Return\nwait_log 10000 hearth: page Help\n'
	printf 'keypress Right\nkeypress Return\nwait_log 10000 hearth: page A new thread\n'
	printf 'text The lamp draws black\nkeypress Down\nkeypress Down\nkeypress Down\n'
	printf 'text My lamp shows black in the corner, see the screenshot:\nkeypress Return\n'
	# Start the thread, Bold, List, Link, Image, Code, File...
	echo "keypress Tab"
	for _ in 1 2 3 4 5 6; do echo "keypress Down"; done
	printf 'keypress Return\nwait_log 5000 The file picker at\nkeypress Escape\ndelay 800\n'
	printf 'screenshot %s/escaped.png\nkeypress Return\nwait_log 5000 The file picker at\n' "$t"
	# The first file, Up, Pictures, Home folder, Screenshots
	for _ in $(seq $ups); do echo "keypress Up"; done
	printf 'keypress Return\nwait_log 5000 The file picker at\n'
	printf 'screenshot %s/screenshots.png\nkeypress Return\nwait_log 15000 hearth: the file screenshot_lamp.png linked\n' "$t"
	printf 'keypress Tab\nkeypress Return\nwait_log 15000 hearth: page The lamp draws black\nscreenshot %s/posted.png\nquit\n' "$t"
} > "$t/cmds"
client reader readerpass12 "$t/reader.log" "$t/cmds" BUILDAT_HEARTH_CREATE=
grep -aq "Command sequence complete" "$t/reader.log" ||
	fail "the drive stopped: $(grep -a "Command sequence\|rror" "$t/reader.log" | tail -2)"
grep -aq "The user picked .*/screenshots/screenshot_lamp.png" "$t/reader.log" ||
	fail "the screenshot was not picked"

curl -s "$U/t/1" > "$t/page"
grep -q "My lamp shows black in the corner" "$t/page" || fail "no thread with the message"
img=$(grep -o '/f/[0-9]*/screenshot_lamp.png' "$t/page" | head -1)
[ -n "$img" ] || fail "the thread has no image link"
[ "$(curl -s -o "$t/img" -w '%{http_code}' "$U$img")" = 200 ] &&
	[ "$(head -c 4 "$t/img" | tail -c 3)" = PNG ] || fail "$img is not served as a PNG"
echo "PASS: by keys: Escape kept the draft, the screenshot picked from the client's Screenshots, posted, $img served"
