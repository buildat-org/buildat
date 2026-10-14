#!/bin/bash
# tier: broken
# broken: back to long; hearth: no frame 120 (dev) (local/runs/dev_baseline)
# cost: ~3 min (2026-10-10)
# covers: src/client/web/index.html apps/hearth/main/client_lua/init.lua apps/starport/main/client_lua/init.lua apps/aitta/main/client_lua/init.lua
# [WEB_RELOAD_APPS]: Hearth, Starport and Aitta on the web load again by
# themselves when the connection went while the page was away, as a
# phone's browser drops it in the background. In headless Chrome as a
# phone, each joined: the page away (blur), the server killed and started
# again on its port, the page back (focus); it reloads and joins again.
# Hearth logged in with "Keep me logged in", on Home after a link's #open=/t/1 and a Back: back on
# Home with the login kept, not on the link's thread (a Back from there
# goes to the sidebar). Needs web/ from util/build_web.sh.
# simplified: Starport and Aitta only join again, at their login; the kept
# login is accounts.lua's, the same as Hearth's
#   util/web_reload_apps_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$here/web/index.html" ] || { echo "SKIP: no web/ (util/build_web.sh)"; exit 77; }
check_tmp web_reload_apps; t=$CHECK_TMP
cd "$here/Build"

serve(){ # app port|auto
	start_server "$t/$1.srv.log" "Listening at" 60 $2 \
		bin/buildat_server -m ../apps/$1 -D "$t/$1.srv" -W ../web -l 3 ||
		fail "$1 did not start"
	CHECK_PIDS+=($SERVER_PID)
}
# drive app steps: the steps' 'away' eval kills the server and starts it
# again, before their wait is over
drive(){
	local app=$1
	WEB_DRIVE_URL=http://127.0.0.1:$SERVER_PORT/ WEB_DRIVE_VIEWPORT=390x844@3 \
		TOUCH=1 timeout 300 "$here/util/web_drive.sh" chrome $app \
		"$t/$app.json" "$t/$app" > "$t/$app.txt" 2>&1 &
	local dp=$!
	for _ in $(seq 600); do
		grep -q '^eval: "away"' "$t/$app.txt" 2>/dev/null && break
		kill -0 $dp 2>/dev/null || break
		sleep 0.2
	done
	grep -q '^eval: "away"' "$t/$app.txt" || fail "$app: never away: $(tail -3 "$t/$app.txt")"
	kill -9 $SERVER_PID
	wait $SERVER_PID 2>/dev/null
	cp "$t/$app.srv.log" "$t/$app.srv1.log"
	serve $app $SERVER_PORT
	wait $dp || fail "$app: the drive: $(tail -3 "$t/$app.txt")"
	grep -q '^eval: "reload' "$t/$app.txt" || fail "$app: not reloaded: $(grep '^eval' "$t/$app.txt" | tail -3)"
}
# Away, and held there until the page has seen the server go (a fetch of
# its own address failing) and come back (one answered)
away='["eval", "dispatchEvent(new Event('"'blur'"')), '"'away'"'"], ["eval", "(async () => { const up = () => fetch(location.href, {cache: \"no-store\"}).then(() => true, () => false); const pause = () => new Promise(r => setTimeout(r, 200)); for (let i = 0; i < 300 \u0026\u0026 await up(); i++) await pause(); for (let i = 0; i < 600 \u0026\u0026 !await up(); i++) await pause(); return \"the server back\"; })()"]'
# Headless Chrome's page never has the focus: document.hasFocus() said so
back='["eval", "document.hasFocus = function(){ return true; }, dispatchEvent(new Event('"'focus'"')), '"'back'"'"]'
kind='["eval", "performance.getEntriesByType('"'navigation'"')[0].type"]'

# The two seconds after the hello: the app's page set up in the frames
# after it
for app in starport aitta; do
	serve $app auto
	cat > "$t/$app.json" <<J
[
	["nav", "\${URL}app"],
	["waitlog", "accounts: hello", 120],
	["wait", 2000],
	$away,
	$back,
	["waitlog", "accounts: hello", 120],
	$kind
]
J
	drive $app
done

serve hearth auto
code=$(grep -ao "setup code [A-Z0-9]*" "$t/hearth.srv.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "hearth: no setup code"
# Until the first request's answer, and the admin script's with one
printf '%s\n' 'wait_log_any 20000 "id":1001,' quit > "$t/wait"
printf '%s\n' 'wait_log_any 20000 "id":1001,' 'wait_log_any 20000 admin script: done' quit > "$t/wait_admin"
admin(){ # log reqs wait [env...]
	local log=$1 reqs=$2 wait=$3
	shift 3
	env BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		BUILDAT_HEARTH_REQS="$reqs" "$@" \
		timeout 120 bin/buildat -o launch_ui=launch_menu -D "$t/cl_admin" \
		-w 1280x720 -l 3 -o sound_mute=1 -s 127.0.0.1:$SERVER_PORT \
		-c @"$wait" > "$log" 2>&1 || fail "$reqs: the drive ($log)"
	grep -ao "hr: {.*\"id\":1001,.*" "$log" | head -1 | grep -q '"ok":true' ||
		fail "$reqs: $(grep -ao "hr: {.*\"id\":1001,.*" "$log" | head -1)"
}
admin "$t/admin.log" '{"cmd":"new_topic","name":"Help","about":"Questions"}' "$t/wait_admin" \
	"BUILDAT_HEARTH_ADMIN=add reader readerpass12"
admin "$t/admin2.log" '{"cmd":"new_thread","topic":1,"title":"Lamps","body":"A lamp"}' "$t/wait"
# Two taps 300 ms apart, Keep me logged in and Log in, are not a double
# tap
cat > "$t/hearth.json" <<J
[
	["nav", "\${URL}app#open=/t/1"],
	["waitlog", "accounts: the login page shown", 120],
	["type", "reader"], ["key", "Tab"], ["type", "readerpass12"],
	["tap", 195, 511], ["wait", 300],
	["tap", 195, 548],
	["waitlog", "hearth: frame", 30],
	["waitlog", "hearth: page Lamps", 20],
	["eval", "history.back(), 'to Home'"],
	["waitlog", "hearth: Escape, back\$", 5],
	["waitlog", "hearth: page Hearth", 10],
	$away,
	$back,
	["waitlog", "hearth: frame", 120],
	["waitlog", "hearth: page Hearth", 30],
	$kind,
	["shot", "\${OUT}/reloaded.png"],
	["eval", "history.back(), 'Back'"],
	["waitlog", "hearth: Escape, back to the sidebar", 5]
]
J
drive hearth
echo "PASS: Starport, Aitta and Hearth loaded again by themselves on the return, Hearth logged in and on the page it was on"
