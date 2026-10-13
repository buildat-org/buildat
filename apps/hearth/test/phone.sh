#!/bin/bash
# tier: long
# cost: ~150 s (2026-10-09)
# covers: apps/hearth/main/client_lua/init.lua builtin/accounts/client_lua/accounts.lua util/web_drive.js client/extensions/network/json.lua
# [HEARTH_USABILITY] 1, **phone**: the same post as desktop_mouse.sh, from
# the web client in headless Chrome as a phone (390x844 at 3 device pixels,
# touch), held upright and then turned (844x390). Each time by taps: log in,
# Help, New thread..., a title and a message, File... (the browser's picker,
# given the shot), a finger's drag to the page's end (the field has grown
# with the link, [HEARTH_PAGE_SCROLL]) and Start the thread. The two threads carry the uploaded
# image's link and draw its thumbnail ([HEARTH_ATTACHMENTS]), and the image
# is served. What a phone does and Chrome here does not (the on-screen
# keyboard over the page, the real picker) is for a test by hand. Needs
# web/ from util/build_web.sh.
#   apps/hearth/test/phone.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
[ -f "$here/web/index.html" ] || { echo "SKIP: no web/ (util/build_web.sh)"; exit 77; }
t=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
P=29898
U=http://127.0.0.1:$P

cd "$here/Build"
start_server "$t/srv.log" "setup code" 60 $P \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -W ../web -l 3 ||
	fail "Hearth did not start"
pid=$SERVER_PID
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "no setup code (srv.log: $(tail -3 "$t/srv.log"))"

# The admin's topic and the reader, trusted (a new account uploads no
# files, [TRUST_LADDER]), by the native client
admin(){ # log reqs cmds [env...]
	local log=$1 reqs=$2 cmds=$3
	shift 3
	env BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 120 bin/buildat -o launch_ui=launch_menu -D "$t/cl_admin" \
		-w 1280x720 -l 3 -o sound_mute=1 -s 127.0.0.1:$P -c @"$cmds" > "$log" 2>&1 ||
		fail "$reqs: the drive ($log)"
	grep -ao "hr: {.*\"id\":1001,.*" "$log" | head -1 | grep -q '"ok":true' ||
		fail "$reqs: $(grep -ao "hr: {.*\"id\":1001,.*" "$log" | head -1)"
}
# The request's answer ("hr: {...}", the first request's id 1001), and
# with an _ADMIN script, all of that answered too
printf 'wait_log_any 20000 "id":1001,\nquit\n' > "$t/wait"
printf 'wait_log_any 20000 "id":1001,\nwait_log_any 20000 admin script: done\nquit\n' \
	> "$t/wait_admin"
admin "$t/admin.log" '{"cmd":"new_topic","name":"Help","about":"Questions"}' \
	"$t/wait_admin" "BUILDAT_HEARTH_ADMIN=add reader readerpass12"
admin "$t/admin2.log" '{"cmd":"trust","name":"reader","on":true}' "$t/wait"
cp "$here/3rdparty/Urho3D/bin/Data/Textures/LogoLarge.png" "$t/screenshot_lamp.png"

# The taps are in CSS pixels, where the page puts the buttons at that size.
# Each page the hearth opens says so ("hearth: page <title>"), and the
# uploaded file once its link is in the message; the waits left are a
# field taking the focus a tap gave it (the tap on the message field) and
# settles of up to 2 s after a line (the login page's name field focused,
# the page drawn).
# simplified: the 1 s after the drag waits for the page's scroll to come to
# rest (ScrollView's touch inertia) before the shot and the tap on Start; a
# line from the hearth when a page scroll ends would replace it.
drive(){ # name viewport join help new message file start title drag
	local n=$1 vp=$2
	cat > "$t/$n.json" <<J
[
	["nav", "\${URL}app"],
	["waitlog", "accounts: hello", 60],
	["wait", 2000],
	["type", "reader"], ["key", "Tab"], ["type", "readerpass12"],
	["tap", $3],
	["waitlog", "hearth: frame", 20],
	["wait", 1000],
	["tap", $4], ["waitlog", "hearth: page Help", 10], ["wait", 500],
	["tap", $5], ["waitlog", "hearth: page A new thread", 10], ["wait", 500],
	["type", "${9}"],
	["tap", $6], ["wait", 500],
	["type", "My lamp shows black in the corner"],
	["file", "$t/screenshot_lamp.png"],
	["tap", $7],
	["waitlog", "the file picker opened", 10],
	["waitlog", "hearth: the file .* linked", 20],
	["wait", 500],
	["shot", "\${OUT}/picked.png"],
	["drag", ${10}, "touch"], ["wait", 1000],
	["shot", "\${OUT}/dragged.png"],
	["tap", $8],
	["waitlog", "hearth: page ${9}", 20],
	["wait", 1000],
	["shot", "\${OUT}/posted.png"]
]
J
	WEB_DRIVE_URL=$U/ WEB_DRIVE_VIEWPORT=$vp TOUCH=1 timeout 300 \
		"$here/util/web_drive.sh" chrome hearth "$t/$n.json" "$t/$n" > "$t/$n.txt" 2>&1 ||
		fail "$n: the drive: $(tail -3 "$t/$n.txt")"
	# [HEARTH_ATTACHMENTS]: the thumbnail fetched and read by the page
	# (the web's JSON once cut a file id to 32 bits, and asked for another)
	! grep -a "the thumbnail of file" "$t/$n/page.log" ||
		fail "$n: a thumbnail not shown"
}
drive upright 390x844@3 "195, 548" "194, 184" "80, 159" "194, 304" "197, 417" \
	"97, 439" "Upright lamp" "200, 300, 200, 100"
drive turned 844x390@3 "422, 320" "512, 150" "264, 125" "500, 245" "751, 338" \
	"281, 306" "Turned lamp" "600, 180, 600, 20"

for n in 1 2; do
	curl -s "$U/t/$n" > "$t/page$n"
	grep -q "My lamp shows black in the corner" "$t/page$n" || fail "thread $n: no message"
	img=$(grep -o '/f/[0-9]*/screenshot_lamp.png' "$t/page$n" | head -1)
	[ -n "$img" ] || fail "thread $n has no image link"
	grep -q "<img src=\"/f/$(echo "$img" | cut -d/ -f3)/thumb\"" "$t/page$n" ||
		fail "thread $n draws no thumbnail"
	[ "$(curl -s -o "$t/img" -w '%{http_code}' "$U$img")" = 200 ] &&
		[ "$(head -c 4 "$t/img" | tail -c 3)" = PNG ] || fail "$img is not served as a PNG"
done
grep -q "Upright lamp" "$t/page1" && grep -q "Turned lamp" "$t/page2" ||
	fail "the threads' titles"
echo "PASS: on a phone, upright and turned: logged in, File... gave the shot, posted, the image served"
