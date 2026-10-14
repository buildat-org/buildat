#!/bin/bash
# tier: long
# cost: ~60 s (2026-10-09)
# covers: client/extensions/network/init.lua src/client/app_lua.h
# [HEARTH_USABILITY] 1, **desktop, by mouse**: a user posts about an issue a
# screenshot shows. The native client at 1280x720 opens Help, New thread...,
# types a title and a message, opens File... and lets it go with Escape
# (the picker closes, the draft stays), opens it again, goes to the
# client's Screenshots, picks the shot, and starts the thread. The thread's
# page draws the uploaded image's thumbnail and lists the file
# ([HEARTH_ATTACHMENTS]), and the image is served.
# The reader is trusted by the admin first: a new account uploads no files
# ([TRUST_LADDER]).
#   apps/hearth/test/desktop_mouse.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
t=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
P=29895
U=http://127.0.0.1:$P

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 $P \
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
		-l 3 -o sound_mute=1 -s 127.0.0.1:$P -c @"$cmds" > "$log" 2>&1 ||
		fail "the client $n ($log): $(grep -a "Command sequence failed\|an error the drive" "$log" | tail -2)"
}
answer(){ # log id
	grep -ao "hr: {.*\"id\":$2,.*" "$1" | head -1
}

# Done when the request (numbered 1001) and the admin line are answered
printf 'wait_log_any 20000 "id":1001,\nwait_log_any 10000 admin script: done\nquit\n' > "$t/wait"
client admin checkpass12 "$t/admin.log" "$t/wait" \
	BUILDAT_HEARTH_REQS='{"cmd":"new_topic","name":"Help","about":"Questions"}' \
	"BUILDAT_HEARTH_ADMIN=add reader readerpass12"
answer "$t/admin.log" 1001 | grep -q '"ok":true' || fail "the topic: $(answer "$t/admin.log" 1001)"
printf 'wait_log_any 20000 "id":1001,\nquit\n' > "$t/wait2"
client admin checkpass12 "$t/admin2.log" "$t/wait2" \
	BUILDAT_HEARTH_REQS='{"cmd":"trust","name":"reader","on":true}'
answer "$t/admin2.log" 1001 | grep -q '"ok":true' || fail "the trust: $(answer "$t/admin2.log" 1001)"

# The shot the user took, where the client puts its own
mkdir -p "$t/cl_reader/screenshots"
cp "$here/3rdparty/Urho3D/bin/Data/Textures/LogoLarge.png" \
	"$t/cl_reader/screenshots/screenshot_lamp.png"
# BUILDAT_HEARTH_RESUME=1 below: the pages and the answers logged, as a
# scripted client's are. The short delays: a field's focus, or the page or
# picker a line says is up, laid out in the frames after it.
cat > "$t/cmds" <<C
wait_log_any 30000 hearth: page Hearth
delay 500
click Button "Help"
wait_log 10000 hearth: page Help
delay 500
click Button "New thread..."
wait_log 10000 hearth: page A new thread
delay 500
text The lamp draws black
mouse_pos 700 240
mouse_click left
# the click's frames: the field takes the focus in the frames after it
delay 300
text My lamp shows black in the corner, see the screenshot:
keypress Return
# the typing's frames: the field reads the text and the Return first
delay 300
click Button "File..."
wait_log 10000 The file picker at
delay 300
keypress Escape
wait_log 10000 The file picker closed; nothing picked
delay 500
screenshot $t/escaped.png
click Button "File..."
wait_log 10000 The file picker at
delay 300
click Button "Screenshots"
wait_log 10000 The file picker at
delay 300
click Button "screenshot_lamp.png"
wait_log 10000 "image":
delay 500
screenshot $t/picked.png
click Button "Start the thread"
wait_log 10000 hearth: page The lamp draws black
delay 1000
screenshot $t/posted.png
quit
C
client reader readerpass12 "$t/reader.log" "$t/cmds" BUILDAT_HEARTH_CREATE= \
	BUILDAT_HEARTH_RESUME=1
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
# [HEARTH_ATTACHMENTS]: the upload went in as its thumbnail, drawn, and
# the file is listed at the message's end
id=$(echo "$img" | cut -d/ -f3)
grep -q "<img src=\"/f/$id/thumb\"" "$t/page" &&
	grep -q '<ul class="files"><li><a href="/f/'"$id"'/screenshot_lamp.png">screenshot_lamp.png</a> <span class="meta">PNG image' "$t/page" ||
	fail "no thumbnail or no file list on the page"
[ "$(curl -s -o "$t/thumb" -w '%{http_code}' "$U/f/$id/thumb")" = 200 ] &&
	[ "$(python3 -c 'import sys; from PIL import Image; print("%dx%d" % Image.open(sys.argv[1]).size)' "$t/thumb")" = 320x160 ] ||
	fail "the thumbnail is not served at 320x160"
echo "PASS: by mouse: Escape kept the draft, the screenshot picked from the client's Screenshots, posted, $img served, its thumbnail drawn and the file listed"
