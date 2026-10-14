#!/bin/bash
# tier: long
# cost: ~60 s (2026-10-10)
# covers: apps/hearth/main/client_lua/init.lua src/client/web/index.html client/api.lua
# [HEARTH_WEB_BACK]: the browser's Back in Hearth on the web, in headless
# Chrome as a phone (390x844, touch). From a thread's HTML page to
# /app#open=/t/1 and a login; then Backs with no input between them go
# thread, Home, sidebar and "Leave Hearth?" (each on the page, the depth
# falling), a Back in the dialog cancels it, and Leave (Enter) lands on
# the thread's HTML page. Chrome skipping entries as far as headless
# Chrome does; a phone is a test by hand. Needs web/ from
# util/build_web.sh.
#   apps/hearth/test/web_back.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
[ -f "$here/web/index.html" ] || { echo "SKIP: no web/ (util/build_web.sh)"; exit 77; }
check_tmp hearth_web_back; t=$CHECK_TMP

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -W ../web -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
U=http://127.0.0.1:$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "no setup code"

admin(){ # log reqs [env...]
	local log=$1 reqs=$2
	shift 2
	env BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 120 bin/buildat -o launch_ui=launch_menu -D "$t/cl_admin" \
		-w 1280x720 -l 3 -o sound_mute=1 -s 127.0.0.1:$SERVER_PORT \
		-c @"$t/wait" > "$log" 2>&1 ||
		fail "the admin drive ($log): $(grep -ao 'Command sequence failed.*' "$log" | head -1)"
	grep -ao "hr: {.*\"id\":1001,.*" "$log" | head -1 | grep -q '"ok":true' ||
		fail "$reqs: $(grep -ao "hr: {.*\"id\":1001,.*" "$log" | head -1)"
}
# The request's answer; the first run's admin script answered too
printf 'wait_log_any 20000 admin script: done\nwait_log_any 20000 "id":1001,\nquit\n' > "$t/wait"
admin "$t/admin.log" '{"cmd":"new_topic","name":"Help","about":"Questions"}' \
	"BUILDAT_HEARTH_ADMIN=add reader readerpass12"
printf 'wait_log_any 20000 "id":1001,\nquit\n' > "$t/wait"
admin "$t/admin2.log" '{"cmd":"new_thread","topic":1,"title":"Lamps","body":"A lamp"}'

depth='["eval", "'"'depth '"' + Module.buildatBackDepth + '"' '"' + location.pathname"]'
back='["eval", "history.back(), '"'back'"'"]'
# The frames after a page's line: its layout, and the depth the next
# Update sets from it
drawn='["wait", 300]'
# simplified: the 2 s after Leave are the page before loading; the steps
# have no wait for a navigation the page starts itself. A ["waitnav"]
# step in util/web_drive.js would be the event
cat > "$t/steps.json" <<J
[
	["nav", "\${URL}t/1"],
	["nav", "\${URL}app#open=/t/1"],
	["waitlog", "accounts: hello", 120],
	["waitlog", "accounts: the login page shown", 20],
	$drawn,
	["type", "reader"], ["key", "Tab"], ["type", "readerpass12"],
	["tap", 195, 548],
	["waitlog", "hearth: frame", 30],
	["waitlog", "hearth: page Lamps", 20],
	$drawn,
	["shot", "\${OUT}/thread.png"],
	$depth,
	$back,
	["waitlog", "hearth: Escape, back\$", 5],
	$drawn,
	["shot", "\${OUT}/home.png"],
	$depth,
	$back,
	["waitlog", "hearth: Escape, back to the sidebar", 5],
	$drawn,
	["shot", "\${OUT}/sidebar.png"],
	$depth,
	$back,
	["waitlog", "hearth: exit dialog\$", 5],
	$drawn,
	["shot", "\${OUT}/dialog.png"],
	$depth,
	$back,
	["waitlog", "hearth: exit dialog cancelled", 5],
	$drawn,
	["shot", "\${OUT}/cancelled.png"],
	$depth,
	$back,
	["waitlog", "hearth: exit dialog\$", 5],
	$drawn,
	["key", "Enter"],
	["wait", 2000],
	["eval", "'left to ' + location.pathname"]
]
J
WEB_DRIVE_URL=$U/ WEB_DRIVE_VIEWPORT=390x844@3 TOUCH=1 timeout 300 \
	"$here/util/web_drive.sh" chrome hearth "$t/steps.json" "$t/d" > "$t/d.txt" 2>&1 ||
	fail "the drive: $(tail -3 "$t/d.txt")"
got=$(grep -ao '^eval: "\(depth\|left\).*' "$t/d.txt" | tr -d '"' | cut -c7- | tr '\n' ',')
# Hearth's 1 over the launcher's own screen everywhere, the dialog too
want="depth 2 /app,depth 2 /app,depth 2 /app,depth 2 /app,depth 2 /app,left to /t/1,"
[ "$got" = "$want" ] || fail "got $got, want $want (shots in $t/d)"
echo "PASS: Back went thread, Home, sidebar, \"Leave Hearth?\", cancelled it, and Leave to the page before"
