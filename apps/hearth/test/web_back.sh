#!/bin/bash
# tier: long
# cost: ~2 min (2026-11-25)
# covers: apps/hearth/main/client_lua/init.lua src/client/web/index.html client/api.lua
# [HEARTH_WEB_BACK]: the browser's Back in Hearth on the web, in headless
# Chrome as a phone (390x844, touch). From a thread's HTML page to
# /app#open=/t/1 and a login; then Backs with no input between them go
# thread, Home, sidebar and "Leave Hearth?" (each on the page, the depth
# falling), a Back in the dialog cancels it, and Leave (Enter) lands on
# the thread's HTML page. Then under the web launcher (apps/play's page):
# its Now row's thread, Back to "Exit to launcher?", the × and Exit, and
# the launcher back on the same page. Chrome skipping entries as far as
# headless Chrome does; a phone is a test by hand. Needs web/ from
# util/build_web.sh.
#   apps/hearth/test/web_back.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
[ -f "$here/web/index.html" ] || { echo "SKIP: no web/ (util/build_web.sh)"; exit 77; }
check_tmp hearth_web_back; t=$CHECK_TMP
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9 BUILDAT_AITTA_DEFAULT=https://127.0.0.1:9

# For 2.: the play page's port, and a stand-in Starport whose answer to
# the Hearth's announce names that page, which lets its WebSocket in
# ([PLAY_LINKS], as play.buildat.org's into forum.buildat.org)
for _ in $(seq 50); do PP=$((29700 + RANDOM % 300)); port_taken $PP || break; done
cat > "$t/sp.py" <<PY
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
	def do_POST(self):
		self.rfile.read(int(self.headers.get("Content-Length") or 0))
		ok = self.path == "/api/v1/announce"
		body = json.dumps({"ok": ok, "play": "http://127.0.0.1:$PP"} if ok else
				{"ok": False}).encode()
		self.send_response(200)
		self.send_header("Content-Type", "application/json")
		self.send_header("Content-Length", str(len(body)))
		self.end_headers()
		self.wfile.write(body)
	do_GET = do_POST
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print("port", s.server_address[1], flush=True)
s.serve_forever()
PY
python3 -I "$t/sp.py" > "$t/sp.log" 2>&1 &
CHECK_PIDS+=($!)
wait_for_log "$t/sp.log" "^port " 10 || fail "the stand-in Starport ($t/sp.log)"
SPP=$(awk '/^port /{print $2}' "$t/sp.log")
mkdir -p "$t/srv/apps/hearth"
cat > "$t/srv/apps/hearth/starport.json" <<J
{"starports": ["http://127.0.0.1:$SPP"],
 "name": "Back hearth", "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J

cd "$here/Build"
BUILDAT_CONNECT_PORTS=$SPP start_server "$t/srv.log" "setup code" 120 auto \
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
echo "ok: Back went thread, Home, sidebar, \"Leave Hearth?\", cancelled it, and Leave to the page before"

# 2. Under the web launcher (apps/play's page, as play.buildat.org's): the
# Now row's thread joins Hearth on the same page; Back at the top opens
# "Exit to launcher?" and cancels it, the × opens it, and Exit is the
# launcher again with the page not left (its window variable kept)
admin "$t/admin3.log" '{"cmd":"topic_category","topic":1,"category":"announcements"}'
BUILDAT_LUANTI_LIST=http://127.0.0.1:9 BUILDAT_HEARTH_DEFAULT=$U \
	start_server "$t/play.log" "Listening at" 120 $PP \
	bin/buildat_server -m ../apps/play -D "$t/play" -C "$t/play.cache" -W ../web -l 3 ||
	fail "the play server did not start"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/sp.log" "POST /api/v1/announce" 30 || fail "no announce ($t/sp.log)"
cat > "$t/steps2.json" <<J
[
	["nav", "\${URL}"],
	["waitlog", "launch_menu: now: Lamps \\\\(News\\\\)", 120],
	["eval", "window.hleave = 'kept'"],
	$drawn,
	["tap", "Text", "Lamps"],
	["waitlog", "hearth: open /t/1 on", 20],
	["waitlog", "accounts: the login page shown", 60],
	$drawn,
	["type", "reader"], ["key", "Tab"], ["type", "readerpass12"],
	["tap", 195, 548],
	["waitlog", "hearth: page Lamps", 30],
	$drawn,
	$back,
	["waitlog", "hearth: Escape, back\$", 5],
	$drawn,
	$back,
	["waitlog", "hearth: Escape, back to the sidebar", 5],
	$drawn,
	$back,
	["waitlog", "hearth: exit dialog\$", 5],
	$drawn,
	["shot", "\${OUT}/launcher_dialog.png"],
	$back,
	["waitlog", "hearth: exit dialog cancelled", 5],
	$drawn,
	["tap", "Button", "×"],
	["waitlog", "hearth: exit dialog\$", 5],
	$drawn,
	["tap", "Button", "Exit"],
	["waitlog", "hearth: exit to the launcher, the login kept", 5],
	["waitlog", "launch_menu: back to Home", 10],
	$drawn,
	["shot", "\${OUT}/launcher_home.png"],
	["eval", "'page ' + window.hleave + ' ' + location.pathname"]
]
J
WEB_DRIVE_URL=http://127.0.0.1:$SERVER_PORT/ WEB_DRIVE_VIEWPORT=390x844@3 TOUCH=1 \
	timeout 300 "$here/util/web_drive.sh" chrome play "$t/steps2.json" "$t/d2" > "$t/d2.txt" 2>&1 ||
	fail "the launcher drive: $(tail -3 "$t/d2.txt")"
grep -aq '^eval: "page kept /"' "$t/d2.txt" ||
	fail "the page was left: $(grep -a '^eval: "page' "$t/d2.txt") (shots in $t/d2)"
echo "PASS: Back went thread, Home, sidebar, \"Leave Hearth?\", cancelled it, and Leave to the page before; under the web launcher, \"Exit to launcher?\" by Back and the ×, and Exit to the launcher on the same page"
