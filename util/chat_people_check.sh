#!/bin/bash
# tier: full
# cost: ~2 min (2026-10-30)
# covers: builtin/chat/client_lua/module.lua builtin/accounts/client_lua/accounts.lua apps/hillclimb/main/client_lua/init.lua
# [CHAT_PEOPLE_BUTTON]: builtin/chat's people page from the chat console's
# People..., in hillclimb, which has no code of its own for it. Natively,
# on a public server: an admin (the setup code's) and a guest; the guest
# says a line; the admin's T, People..., reports the guest, mutes it, and
# sets who may talk to Residents and up; the page's Back is the console
# again, whose Back closes the chat. In Chrome: a guest's console's
# People... opens the page and its Back the console. skeldat's are
# apps/skeldat/check.sh's sections 1 and 2.
#   util/chat_people_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp chat_people; t=$CHECK_TMP
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9
server(){ # <log> [args]: a public hillclimb
	local log=$1
	shift
	BUILDAT_HILLCLIMB_FEATURES=0 start_server "$log" "STATUS Listening" 300 auto \
		"$here/Build/bin/buildat_server" -m "$here/apps/hillclimb" \
		-D "$t/srv" -C "$t/srv.cache" -l 3 "$@" || fail "the server ($log)"
	CHECK_PIDS+=($SERVER_PID)
}
client(){ # <name> <cmds>, in the background: its PID in $CLIENT
	timeout 300 "$here/Build/bin/buildat" -C "$t/c_$1" -D "$t/u_$1" -w 800x500 \
		-l 3 -o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" -c @"$2" \
		> "$t/$1.log" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
}
server "$t/srv.log" -W "$here/web"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30 || fail "no setup code ($t/srv.log)"
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
car="wait_log 120000 hillclimb: this client's car is"
# A new admin is asked about ntfy pushes first: Later
cat > "$t/adm.cmds" <<C
wait_log 120000 server window: the page ntfy
delay 500
click Button "Later"
wait_log_any 120000 hillclimb: this client's car is
wait_log 120000 chat: <guest1> hello from the guest
keypress T
wait_log 5000 hillclimb: the chat shown
delay 500
screenshot $t/console_open.png
click Button "People..."
wait_log 5000 chat: the people shown
delay 1000
screenshot $t/people.png
click Button "Report guest1"
delay 1000
click Button "Mute guest1"
wait_log 5000 chat: the people shown
delay 500
click DropDownList "▼"
delay 500
keypress Down
keypress Return
delay 1000
screenshot $t/people_after.png
click Button "Back"
wait_log 5000 chat page: y
delay 500
screenshot $t/console.png
text people done
keypress Return
delay 500
click Button "Back"
wait_log 5000 hillclimb: the chat closed
quit
C
cat > "$t/guest.cmds" <<C
wait_log 120000 accounts: the login page shown
click Button "Play as a guest"
$car
delay 1000
keypress T
wait_log 5000 hillclimb: the chat shown
delay 800
text hello from the guest
keypress Return
delay 300
click Button "Back"
wait_log 60000 chat: <adm> people done
quit
C
BUILDAT_JOIN_NAME=adm BUILDAT_JOIN_PASSWORD=admpass123 BUILDAT_JOIN_CREATE=1 \
BUILDAT_JOIN_CODE=$code client adm "$t/adm.cmds"; a=$CLIENT
wait_for_log "$t/srv.log" "hillclimb: adm's car" 150 || fail "the admin has no car ($t/srv.log, $t/adm.log)"
client guest "$t/guest.cmds"; g=$CLIENT
wait $a || fail "the admin's drive ($t/adm.log)"
wait $g || fail "the guest's drive ($t/guest.log)"
s="$t/srv.log"
grep -aq "adm reports guest1" "$s" || fail "no report ($s)"
grep -aq "adm mutes guest1" "$s" || fail "no mute ($s)"
grep -aq "the lowest level that may talk is member" "$s" || fail "who may talk not set ($s)"
# The page, then the console again (its line a frame on), then closed
awk '/chat: the people shown/ { p = 1 } p && /chat page: y/ { c = 1 }
	c && /hillclimb: the chat closed/ { ok = 1 } END { exit !ok }' "$t/adm.log" ||
	fail "the people page not back to the console, or the chat not closed ($t/adm.log)"
echo "ok: natively, the admin reported and muted the guest and set who may talk from People..., back to the console"
if ! command -v "${CHROME:-google-chrome}" > /dev/null || [ ! -f "$here/web/buildat.wasm" ]; then
	echo "PASS: native; the web skipped (no Chrome or web/)"
	exit 0
fi
# A guest, by the login page's keys: Play as a guest is the fourth item
cat > "$t/web.json" <<'J'
[
 ["nav", "${URL}?log=4"],
 ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Tab"], ["frames", 2], ["key", "Enter"], ["waitlog", "Joined as guest", 30],
 ["waitlog", "hillclimb: this client's car is", 120], ["wait", 1000],
 ["key", "t"], ["waitlog", "hillclimb: the chat shown", 10], ["wait", 500],
 ["shot", "${OUT}/console.png"],
 ["click", 600, 334], ["waitlog", "chat: the people shown", 10], ["wait", 500],
 ["shot", "${OUT}/people.png"],
 ["click", 600, 459], ["waitlog", "chat page: y", 10], ["wait", 500],
 ["shot", "${OUT}/back.png"],
 ["eval", "'done'"]
]
J
WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
	"$here/util/web_drive.sh" chrome hillclimb "$t/web.json" "$t/drive" \
	> "$t/drive.txt" 2>&1 || fail "the web drive ($(tail -2 "$t/drive.txt"); $t/drive/page.log)"
awk '/chat: the people shown/ { p = 1 } p && /chat page: y/ { ok = 1 } END { exit !ok }' \
	"$t/drive/page.log" || fail "web: People... not back to the console ($t/drive/page.log)"
echo "PASS: People... in hillclimb's chat console: the page, its report, mute and who may talk, and Back to the console, natively and in Chrome"
