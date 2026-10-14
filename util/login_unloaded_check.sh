#!/bin/bash
# tier: broken
# broken: back to full; no "Login refused: TOTP: enter"; the same on dev
#   (local/runs/dev_baseline)
# cost: ~3 min (2026-10-11)
# covers: builtin/accounts/accounts.cpp builtin/accounts/client_lua/accounts.lua src/client/web/index.html
# [LOGIN_UNLOADED]: a web login outlives the page being reloaded, as a
# phone's browser does to a tab while its user is in a password manager or
# an authenticator app. On a public floorplanner server, an account with
# TOTP (the RFC 6238 test secret put in the store) and a code wait of 20 s
# (BUILDAT_TOTP_WAIT_S), in Chrome:
#   - the name field's stand-in is "username", the password's
#     "current-password" in a form whose name input holds the name typed,
#     the TOTP field's "one-time-code";
#   - the password right, the page reloaded at once at the code page comes
#     back to the code page;
#   - after the wait it comes back to the login page with the name in it;
#   - logged in again to the code page and reloaded, a wrong code is
#     refused and the right one joins, with no password sent again.
#   util/login_unloaded_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v "${CHROME:-google-chrome}" > /dev/null || { echo "SKIP: no Chrome"; exit 0; }
[ -f "$here/web/buildat.wasm" ] || { echo "SKIP: no web/ (util/build_web.sh)"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp login_unloaded; t=$CHECK_TMP
trap check_cleanup EXIT
server(){ # log, extra args...
	local l=$1; shift
	start_server "$l" "STATUS Listening" 90 auto "$here/Build/bin/buildat_server" \
		-m "$here/apps/floorplanner" -D "$t/s" -C "$t/s.cache" -l 3 "$@" ||
		fail "the server ($l)"
	CHECK_PIDS+=($SERVER_PID)
}
# The account, made by a scripted client with the setup code
server "$t/s1.log"
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/s1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/s1.log)"
printf 'wait_log_any 20000 Joined as erin\nquit\n' > "$t/seq"
BUILDAT_FP_NAME=erin BUILDAT_FP_PASSWORD=rightpass123 BUILDAT_FP_CREATE=1 \
BUILDAT_FP_CODE=$code run_client 40 "$t/mk.log" timeout 40 \
	"$here/Build/bin/buildat" -o launch_ui=launch_menu -s 127.0.0.1:$SERVER_PORT \
	-D "$t/mk" -C "$t/mk.cache" -w 640x480 -u 1 -l 3 -o sound_mute=1 -c @"$t/seq" ||
	fail "the account's client ($t/mk.log): $(grep -a "Command sequence failed" "$t/mk.log" | tail -1)"
grep -aqF "Joined as erin" "$t/mk.log" || fail "the account ($t/mk.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
db=$(find "$t/s" -path '*_server*' -name save.sqlite | head -1)
[ -n "$db" ] || fail "no _server save.sqlite under $t/s"
python3 - "$db" <<'PY' || fail "the TOTP secret"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO store(store, key, value) VALUES('accounts', 'totp/erin', ?)",
        (b"12345678901234567890",))
c.commit()
PY
# The codes: 30 s on, which the server takes from now until a minute and
# more on (one step either side), and one that is not
totp(){
	python3 - "$1" <<'PY'
import hmac, hashlib, struct, sys, time
h = hmac.new(b"12345678901234567890", struct.pack(">Q", int(time.time() + 30) // 30),
        hashlib.sha1).digest()
o = h[19] & 15
v = (struct.unpack(">I", h[o:o + 4])[0] & 0x7fffffff) % 1000000
print("%06d" % ((v + int(sys.argv[1])) % 1000000))
PY
}
BUILDAT_TOTP_WAIT_S=20 server "$t/s2.log" -W "$here/web"
# CSS pixels in web_drive's 1200x800: the name field at (600, 326), the
# password at (600, 399); with an error line the window is taller, and
# they are at y 291 and 364. The 25 s: the code wait of 20 s running out
# (a timing test). The waits after a click or a typed name are the click's
# frames: the field takes the focus and its stand-in input (synced each
# frame) a frame or two later, and an eval or a click right away would read
# the old one. Those after a waitlog are settles after the line: the code
# page's field focused in the frames after the refusal is logged.
cat > "$t/steps.json" <<J
[
 ["nav", "\${URL}"],
 ["waitlog", "hello: Starport", 60], ["wait", 2000],
 ["click", 600, 326], ["wait", 500],
 ["eval", "'field ' + document.activeElement.id + ' ' + document.activeElement.getAttribute('autocomplete')"],
 ["type", "erin"], ["wait", 300],
 ["click", 600, 399], ["wait", 500],
 ["eval", "'field ' + document.activeElement.id + ' ' + document.activeElement.getAttribute('autocomplete') + ' in a form with ' + document.getElementById('username').value"],
 ["type", "rightpass123"], ["key", "Enter"],
 ["waitlog", "Login refused: TOTP: enter", 30], ["wait", 500],
 ["eval", "'field ' + document.activeElement.id + ' ' + document.activeElement.getAttribute('autocomplete')"],
 ["nav", "\${URL}"],
 ["waitlog", "Login refused: TOTP: enter", 60], ["wait", 1000],
 ["eval", "'field ' + document.activeElement.id + ' ' + document.activeElement.getAttribute('autocomplete') + ' after the reload'"],
 ["wait", 25000],
 ["nav", "\${URL}"],
 ["waitlog", "Login refused: The wait for the code has ended", 60], ["wait", 1000],
 ["click", 600, 291], ["wait", 500],
 ["eval", "'name ' + document.activeElement.value"],
 ["click", 600, 364], ["wait", 500],
 ["type", "rightpass123"], ["key", "Enter"],
 ["waitlog", "Login refused: TOTP: enter", 30],
 ["nav", "\${URL}"],
 ["waitlog", "Login refused: TOTP: enter", 60], ["wait", 1000],
 ["type", "$(totp 500000)"], ["key", "Enter"],
 ["waitlog", "Login refused: TOTP: wrong code", 30], ["wait", 1000],
 ["type", "$(totp 0)"], ["key", "Enter"],
 ["waitlog", "Joined as erin", 30]
]
J
WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" "$here/util/web_drive.sh" chrome \
	floorplanner "$t/steps.json" "$t/drive" > "$t/drive.txt" 2>&1 ||
	fail "the drive: $(tail -2 "$t/drive.txt")"
fields=$(grep -ao '^eval: ".*"' "$t/drive.txt" | sed 's/^eval: "//; s/"$//')
for want in "field text username" \
		"field password current-password in a form with erin" \
		"field text one-time-code" "field text one-time-code after the reload" \
		"name erin"; do
	echo "$fields" | grep -qxF "$want" || fail "no \"$want\" ($t/drive.txt)"
done
# No password with the codes: the server saw the token's logins
grep -aq "erin joined" "$t/s2.log" || fail "no join in the server's log ($t/s2.log)"
echo "PASS: the fields' purposes for a password manager; a reload at the code page comes back to it, after the wait to the login page with the name; a wrong code refused and the right one joins with the token"
