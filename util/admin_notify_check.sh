#!/bin/bash
# tier: full
# cost: ~4 min (2026-10-11)
# covers: builtin/accounts/accounts.cpp builtin/accounts/client_lua/accounts.lua builtin/moderation/moderation.cpp apps/hearth/main/main.cpp
# [ADMIN_NOTIFY]: reports pushed to a moderator's ntfy topic. A local
# HTTPS stand-in for ntfy (the check's own CA) records each POST.
# Hearth, its pushes' window 20 s:
#   - the admin is asked after logging in: Later, asked again; Don't add,
#     not asked again;
#   - a moderator is asked, Add now: the page with a fresh ntfy.sh topic
#     of 128 bits; an http:// address refused, an https one saved, Test
#     one POST;
#   - a plain user is not asked and may not set one;
#   - the user's two reports: one POST at once, one more at the window's
#     end saying 1 more and 2 open; neither has the user's name or the
#     reason in it; nothing to the user's topic.
# Aitta: its admin's suggested topic not the Hearth moderator's; a report
# on a release one POST to the admin's topic.
#   util/admin_notify_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp admin_notify; t=$CHECK_TMP
trap check_cleanup EXIT
b="$here/Build/bin/buildat"
cd "$here/Build"

# The ntfy stand-in: each POST a JSON line {path, body}
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
	-addext subjectAltName=IP:127.0.0.1 -keyout "$t/key.pem" \
	-out "$t/cert.pem" 2> /dev/null || fail "openssl"
cat > "$t/ntfy.py" <<'PY'
import http.server, json, ssl, sys
out = open(sys.argv[3], "a")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        out.write(json.dumps({"path": self.path,
            "body": self.rfile.read(n).decode()}) + "\n")
        out.flush()
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
c.load_cert_chain(sys.argv[1], sys.argv[2])
s.socket = c.wrap_socket(s.socket, server_side=True)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
: > "$t/posts"
python3 "$t/ntfy.py" "$t/cert.pem" "$t/key.pem" "$t/posts" > "$t/ntfy.port" 2> "$t/ntfy.log" &
ntfy=$!
CHECK_PIDS+=($ntfy)
for _ in $(seq 50); do [ -s "$t/ntfy.port" ] && break; kill -0 $ntfy 2>/dev/null || break; sleep 0.1; done
N=https://127.0.0.1:$(cat "$t/ntfy.port")
posts(){ python3 -c 'import json,sys
print("\n".join(json.loads(l)["body"].replace("\n", " | ") for l in open(sys.argv[1])
    if json.loads(l)["path"] == sys.argv[2]))' "$t/posts" "$1"; }

# Hearth
mkdir -p "$t/h/shared"
cp "$t/cert.pem" "$t/h/shared/check_ca.pem"
BUILDAT_CA_FILE=$t/h/shared/check_ca.pem BUILDAT_NTFY_BATCH_S=20 \
BUILDAT_CONNECT_PORTS=$(cat "$t/ntfy.port") \
start_server "$t/h.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/hearth -D "$t/h" -l 3 ||
	fail "Hearth did not start ($t/h.log)"
CHECK_PIDS+=($SERVER_PID)
HP=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/h.log" | cut -d' ' -f3)
hearth(){ # name password log commands [env...]
	local n=$1 pw=$2 log=$3
	printf "$4" > "$t/cmds"
	shift 4
	env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=$pw BUILDAT_HEARTH_CREATE=1 \
		BUILDAT_HEARTH_CODE=$code "$@" \
		timeout 90 "$b" -o launch_ui=launch_menu -D "$t/cl_$n" -w 800x600 -l 3 \
		-o sound_mute=1 -s 127.0.0.1:$HP -c @"$t/cmds" > "$log" 2>&1 ||
		fail "the $n drive ($log): $(grep -ao 'Command sequence failed.*' "$log" | head -1)"
}
# The question's window, a button clicked. Later and Don't add get no
# answer back: the second after the click is the packet sent before quit
# The app's line, not the drive's commands that quote it
asked() { grep -a "accounts: ntfy asked" "$1" | grep -aqv " __app   : "; }
ASK='wait_log 30000 accounts: ntfy asked\nwait_log_any 5000 server window: the page ntfy\ndelay 300\nclick Button "%s"\ndelay 1000\nquit\n'
hearth admin checkpass12 "$t/admin1.log" "$(printf "$ASK" Later)" \
	BUILDAT_HEARTH_ADMIN="$(printf 'add mod modpass1234\nlevel mod 30\nadd bob bobpass1234')" \
	BUILDAT_HEARTH_REQS='{"cmd":"new_topic","name":"Help"}
{"cmd":"new_thread","topic":1,"title":"Lamps","body":"one"}
{"cmd":"reply","thread":1,"body":"two"}'
grep -aq "accounts: ntfy asked: https://ntfy.sh/buildat-" "$t/admin1.log" ||
	fail "the admin not asked ($t/admin1.log)"
grep -aq "answered the ntfy question: later" "$t/h.log" || fail "Later not taken ($t/h.log)"
hearth admin checkpass12 "$t/admin2.log" "$(printf "$ASK" "Don't add")"
asked "$t/admin2.log" || fail "Later did not ask again ($t/admin2.log)"
grep -aq "answered the ntfy question: never" "$t/h.log" || fail "Don't add not taken ($t/h.log)"
hearth admin checkpass12 "$t/admin3.log" 'wait_log_any 30000 Joined as\nwait_log_absent 2000 accounts: ntfy asked\nquit\n'
grep -aq "Joined as admin" "$t/admin3.log" || fail "the admin's third login ($t/admin3.log)"
asked "$t/admin3.log" && fail "asked after Don't add ($t/admin3.log)"
echo "ok: the admin asked; Later asks again, Don't add does not"

hearth mod modpass1234 "$t/mod1.log" "$(printf 'wait_log 30000 accounts: ntfy asked\nwait_log_any 5000 server window: the page ntfy\ndelay 300\nclick Button "Add now"\nwait_log 5000 the address page after Add now\ndelay 500\nscreenshot %s\nquit\n' "$t/add_now.png")"
sug=$(grep -ao "accounts: ntfy asked: .*" "$t/mod1.log" | head -1 | cut -d' ' -f4)
echo "$sug" | grep -Eq '^https://ntfy.sh/buildat-[0-9a-f]{32}$' ||
	fail "the moderator's suggestion: '$sug' ($t/mod1.log)"
hearth mod modpass1234 "$t/mod2.log" 'wait_log_any 30000 note=Sent\nquit\n' \
	BUILDAT_HEARTH_NTFY="$(printf 'set http://127.0.0.1:1/mod\nset %s/mod\ntest' "$N")"
grep -aq "note=An https:// address" "$t/mod2.log" || fail "http:// not refused ($t/mod2.log)"
grep -aq "note=Saved" "$t/mod2.log" || fail "not saved ($t/mod2.log)"
grep -aq "note=Sent" "$t/mod2.log" || fail "the test not sent ($t/mod2.log)"
echo "ok: the moderator asked with a fresh topic; http:// refused, https saved, Test sent"

hearth bob bobpass1234 "$t/bob.log" 'wait_log_any 30000 note=Only for a\nwait_log_any 20000 "id":1002,\nquit\n' \
	BUILDAT_HEARTH_NTFY="set $N/bob" \
	BUILDAT_HEARTH_REQS='{"cmd":"report","message":1,"reason":"zzsecretreason"}
{"cmd":"report","message":2,"reason":"zzsecretreason"}'
grep -aq "note=Only for a" "$t/bob.log" || fail "bob set an address ($t/bob.log)"
grep -aq "accounts: ntfy asked" "$t/bob.log" && fail "bob asked ($t/bob.log)"
grep -aq 'hr: {.*"id":1002,.*"result"' "$t/bob.log" ||
	fail "bob's reports: $(grep -a 'hr: ' "$t/bob.log" | tail -2)"
# The window's end: the held one
for _ in $(seq 150); do [ "$(posts /mod | wc -l)" -ge 3 ] && break; sleep 0.2; done
posts /mod > "$t/mod.posts"; cat "$t/mod.posts"
[ "$(sed -n 1p "$t/mod.posts")" = "hearth: a test push for mod" ] || fail "the test push"
[ "$(sed -n 2p "$t/mod.posts")" = "Hearth: a new report, 1 open" ] || fail "the first report's push"
[ "$(sed -n 3p "$t/mod.posts")" = "1 more since the last push; the latest: Hearth: a new report, 2 open" ] ||
	fail "the window's push"
[ "$(wc -l < "$t/mod.posts")" = 3 ] || fail "more than three pushes"
grep -q "bob\|zzsecret\|Lamps" "$t/mod.posts" && fail "content in a push"
[ -z "$(posts /bob)" ] || fail "a push to bob"
echo "ok: two reports, one push at once and one at the window's end, no content"

# Aitta
mkdir -p "$t/a/shared"
cp "$t/cert.pem" "$t/a/shared/check_ca.pem"
BUILDAT_CA_FILE=$t/a/shared/check_ca.pem BUILDAT_CONNECT_PORTS=$(cat "$t/ntfy.port") \
start_server "$t/a.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/a" -l 3 ||
	fail "Aitta did not start ($t/a.log)"
CHECK_PIDS+=($SERVER_PID)
AP=$SERVER_PORT
acode=$(grep -ao "setup code [A-Z0-9]*" "$t/a.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/akey" > "$t/apub" 2>/dev/null || fail "keygen"
printf 'wait_log_any 30000 accounts: ntfy asked\nwait_log_any 20000 note=Saved\nquit\n' > "$t/acmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$acode BUILDAT_AITTA_NTFY="set $N/aitta" \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/apub")\"}" \
	timeout 90 "$b" -o launch_ui=launch_menu -D "$t/cl_aitta" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$AP -c @"$t/acmds" > "$t/aadmin.log" 2>&1 ||
	fail "the Aitta admin's drive ($t/aadmin.log): $(grep -ao 'Command sequence failed.*' "$t/aadmin.log" | head -1)"
asug=$(grep -ao "accounts: ntfy asked: .*" "$t/aadmin.log" | head -1 | cut -d' ' -f4)
echo "$asug" | grep -Eq '^https://ntfy.sh/buildat-[0-9a-f]{32}$' && [ "$asug" != "$sug" ] ||
	fail "Aitta's suggestion '$asug' beside Hearth's '$sug' ($t/aadmin.log)"
grep -aq "note=Saved" "$t/aadmin.log" || fail "Aitta's admin's address ($t/aadmin.log)"
mkdir -p "$t/app"
cp -r ../apps/demo_board_game/main ../apps/demo_board_game/launcher "$t/app/"
printf '{"author": "tester", "name": "pk", "version": "1.0.0",
	"engine_api": 2, "license_code": "MIT", "license_media": "CC0-1.0",
	"description": "an ntfy check"}\n' > "$t/app/meta.json"
zip=$("$b" aitta pack "$t/app" "$t/akey" "$t/out" 2>/dev/null) || fail "pack"
"$b" aitta publish "$zip" 127.0.0.1:$AP > "$t/publish.log" 2>&1
grep -q "listed: tester/pk" "$t/publish.log" || fail "publish ($t/publish.log)"
curl -s -X POST -d '{"release":"tester/pk/1.0.0","reason":"broken","text":"zzsecrettext"}' \
	"http://127.0.0.1:$AP/api/v1/aitta/report" | grep -q '"ok":true' || fail "the report"
for _ in $(seq 50); do [ -n "$(posts /aitta)" ] && break; sleep 0.2; done
[ "$(posts /aitta)" = "Aitta: a new report, 1 open" ] || fail "Aitta's push: '$(posts /aitta)'"
echo "PASS: reports pushed to the moderators' ntfy topics, batched, without content; the login's question"
