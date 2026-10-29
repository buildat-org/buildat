#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-29)
# covers: apps/hearth/main/main.cpp apps/hearth/main/commands.h extensions/launch_menu/init.lua client/core/aitta/init.lua client/core/starport/init.lua
# [LIVELY_MENU]: the launcher's "now" strip and an app's threads.
#   1. A Hearth: the admin names a topic "announcements" and starts a
#      thread there, a busy thread elsewhere and one about the package
#      tester/game; a new account (not a member) starts a busier one.
#      /api/v1/feed lists the announcement, the busy thread and the
#      package's thread with its posts, with CORS, and not the new
#      account's.
#   2. A stand-in Starport and Aitta (a few lines of Python): a server
#      with 5 players, and tester/game released today.
#   3. The native launcher with those in its settings: Home's "Now" has
#      the server, the package, the announcement and the busy thread; a
#      click on the announcement joins the Hearth at that thread.
#   4. The package's row opens Apps from Aitta, whose panel lists its
#      thread and its posts; a click on the thread opens it on the Hearth.
#   5. A launcher whose settings name no Hearth ("hearth": "") and whose
#      hosts are not accepted: no strip, and nothing asked.
#   5b. A fresh launcher whose built-in defaults (BUILDAT_STARPORT_DEFAULT,
#      _AITTA_, _HEARTH_DEFAULT) are the local ones: the whole strip with
#      no host accepted and no dialog; the developer console's sandboxed
#      http_get of that same default host is asked about. With the Hearth and the Aitta named
#      in its settings by another name (localhost), not a default: no
#      strip, and Apps from Aitta asks about that Aitta.
#   6. The web launcher (apps/play's page, headless Chrome) with the same
#      settings: the same strip; the package's row opens Apps from Aitta
#      with its thread; the announcement's row joins the Hearth at it.
#      Left out without web/ (util/build_web.sh), said on the PASS line.
#   util/lively_menu_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp lively_menu; t=$CHECK_TMP
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9

# 1.
cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/hearth -D "$t/srv" -l 3 ||
	fail "Hearth did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
H=http://127.0.0.1:$P
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
# hearth <name> <password> <log> <requests> [env...]: a scripted Hearth
# client, quitting once each request is answered
hearth(){
	local n=$1 pw=$2 log=$3 reqs=$4 i=0 w
	shift 4
	{
		echo "wait_log_any 20000 Joined as"
		while IFS= read -r w; do
			[ -n "$w" ] && i=$((i + 1)) && echo "wait_log_any 10000 \"id\":$((1000 + i)),"
		done <<< "$reqs"
		echo quit
	} > "$t/cmds_$n"
	run_client 60 "$log" env BUILDAT_HEARTH_NAME=$n BUILDAT_HEARTH_PASSWORD=$pw \
		BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$code \
		BUILDAT_HEARTH_REQS="$reqs" "$@" timeout 90 bin/buildat -o launch_ui=launch_menu \
		-D "$t/cl_$n" -w 800x600 -l 3 -o sound_mute=1 -s 127.0.0.1:$P \
		-c @"$t/cmds_$n" ||
		fail "the Hearth client $n ($log)"
	[ "$(grep -ac '"ok":true' "$log")" -ge "$i" ] ||
		fail "$n's requests: $(grep -a 'hr: ' "$log" | grep -v '"ok":true' | head -3)"
}
hearth admin checkpass12 "$t/admin.log" '{"cmd":"new_topic","name":"News","about":"From the makers"}
{"cmd":"topic_category","topic":1,"category":"announcements"}
{"cmd":"new_thread","topic":1,"title":"Release 9 is out","body":"Go get it"}
{"cmd":"new_topic","name":"Talk","about":"Anything"}
{"cmd":"new_thread","topic":2,"title":"Busy chat","body":"one"}
{"cmd":"reply","thread":2,"body":"two"}
{"cmd":"reply","thread":2,"body":"three"}
{"cmd":"new_thread","topic":2,"title":"Lamp trouble in game","body":"It is dark","subject":"tester/game abc123"}
{"cmd":"reply","thread":3,"body":"Turn it on"}' \
	"BUILDAT_HEARTH_ADMIN=add bob bobpass1234"
hearth bob bobpass1234 "$t/bob.log" '{"cmd":"new_thread","topic":2,"title":"Guest spam","body":"a"}
{"cmd":"reply","thread":4,"body":"b"}
{"cmd":"reply","thread":4,"body":"c"}
{"cmd":"reply","thread":4,"body":"d"}'
curl -s -D "$t/feed.head" "$H/api/v1/feed" > "$t/feed.json" || fail "no feed"
grep -qi "^Access-Control-Allow-Origin: \*" "$t/feed.head" || fail "the feed has no CORS"
python3 - "$t/feed.json" "$H" <<'PY' || fail "the feed ($t/feed.json)"
import json, sys
f = json.load(open(sys.argv[1]))
titles = lambda l: [t["title"] for t in l]
assert f["url"] == sys.argv[2], f["url"]
assert titles(f["announcements"]) == ["Release 9 is out"], f
assert titles(f["active"])[:1] == ["Busy chat"], f
assert "Guest spam" not in json.dumps(f), "a new account's thread"
p = f["packages"]["tester/game"]
assert p["posts"] == 2 and titles(p["threads"]) == ["Lamp trouble in game"], p
assert f["active"][0]["posts"] == 3, f["active"]
PY

# 2. One port answering as a Starport and an Aitta, with CORS
# Released two days ago: "2 days ago" on both screens, however long the
# run took to get there
now=$(($(date +%s) - 2 * 86400 - 600))
cat > "$t/fake.py" <<PY
import http.server, json, sys
lists = {
	"/api/v1/list": {"ok": True, "servers": [{"host": "127.0.0.1", "port": 9,
		"name": "Busy server", "players": 5, "audience": "everyone",
		"kind": "world", "access": "open"}]},
	"/api/v1/aitta/list": {"ok": True, "releases": [{"author": "tester",
		"name": "game", "version": "1.2.0", "kind": "app", "engine_api": 2,
		"review": "reviewed", "time": $now, "description": "A check's",
		"license_code": "MIT", "license_media": "CC0-1.0", "size": 1000,
		"sha256": "00" * 32, "serverless": True}]},
}
class H(http.server.BaseHTTPRequestHandler):
	def answer(self):
		body = json.dumps(lists.get(self.path.split("?")[0], {"ok": False})).encode()
		self.send_response(200)
		self.send_header("Content-Type", "application/json")
		self.send_header("Access-Control-Allow-Origin", "*")
		self.send_header("Content-Length", str(len(body)))
		self.end_headers()
		self.wfile.write(body)
	def do_GET(self): self.answer()
	def do_OPTIONS(self):
		self.send_response(204)
		self.send_header("Access-Control-Allow-Origin", "*")
		self.send_header("Access-Control-Allow-Headers", "*")
		self.send_header("Access-Control-Allow-Methods", "GET, POST")
		self.end_headers()
	def do_POST(self):
		self.rfile.read(int(self.headers.get("Content-Length") or 0))
		self.answer()
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print("port", s.server_address[1], flush=True)
s.serve_forever()
PY
python3 -I "$t/fake.py" > "$t/fake.log" 2>&1 &
CHECK_PIDS+=($!)
wait_for_log "$t/fake.log" "^port " 10 || fail "the stand-in ($t/fake.log)"
F=http://127.0.0.1:$(awk '/^port /{print $2}' "$t/fake.log")

# 3. The launcher, its hosts accepted as the user would have
mkdir -p "$t/cl"
printf '{"starports": ["%s"], "aittas": ["%s"], "hearth": "%s"}\n' "$F" "$F" "$H" \
	> "$t/cl/starport.json"
(BUILDAT_USER_PATH=$t/cl; check_allow "$F"; check_allow "$H")
launcher(){ # log cmds
	run_client 60 "$1" env BUILDAT_HEARTH_NAME=admin \
		BUILDAT_HEARTH_PASSWORD=checkpass12 timeout 90 bin/buildat -o launch_ui=launch_menu \
		-D "$t/cl" -C "$t/cl.cache" -w 1000x700 -l 3 -o sound_mute=1 -c @"$2" ||
		fail "the launcher ($1): $(grep -a "Command sequence failed" "$1" | tail -1)"
}
now_line='launch_menu: now: Busy server (5 playing); tester/game 1.2.0 (updated 2 days ago); Release 9 is out (News); Busy chat (3 posts); Lamp trouble in game (2 posts)'
printf '%s\n' "wait_log_any 30000 $now_line" "screenshot $t/home.png" 'click Text "Release 9 is out"' \
	'wait_log 30000 hearth: page Release 9 is out' quit > "$t/home.cmds"
launcher "$t/home.log" "$t/home.cmds"
grep -aq "Asking the user about" "$t/home.log" && fail "a permission dialog ($t/home.log)"

# 4.
printf '%s\n' "wait_log_any 30000 $now_line" 'click Text "tester/game 1.2.0"' \
	'wait_log 20000 aitta panel: thread 3 Lamp trouble in game' "screenshot $t/app.png" \
	'click Button "Lamp trouble in game"' \
	'wait_log 30000 hearth: page Lamp trouble in game' quit > "$t/app.cmds"
launcher "$t/app.log" "$t/app.cmds"

# 5.
mkdir -p "$t/cl0"
printf '{"starports": ["%s"], "aittas": ["%s"], "hearth": ""}\n' "$F" "$F" \
	> "$t/cl0/starport.json"
printf '%s\n' 'wait_log_any 30000 rows in' quit > "$t/none.cmds"
run_client 60 "$t/none.log" timeout 60 bin/buildat \
	-o launch_ui=launch_menu -D "$t/cl0" -C "$t/cl0.cache" -w 1000x700 -l 3 \
	-o sound_mute=1 -c @"$t/none.cmds" || fail "the bare launcher ($t/none.log)"
grep -aq "launch_menu: now:" "$t/none.log" && fail "a strip with nothing accepted"
grep -aq "Asking the user about" "$t/none.log" && fail "a permission dialog on Home"
grep -aq "hearth feed:" "$t/none.log" && fail "a feed fetched with no Hearth set"

# 5b.
# Then a sandboxed fetch of the same default host, from the launcher's
# console (on no server, no storage of its own): asked about
printf '%s\n' "wait_log_any 30000 $now_line" 'mouse_pos 2 2' 'delay 300' \
	'text developer c' 'wait_log 5000 rows for "developer c"' 'keypress Return' \
	'wait_log 10000 lines of the API document' \
	"text require[[buildat/core/network]].http_get([[$F/probe]], function() end)" \
	'keypress Return' "wait_log 10000 Asking the user about $F" quit > "$t/def.cmds"
run_client 60 "$t/def.log" env BUILDAT_STARPORT_DEFAULT=$F BUILDAT_AITTA_DEFAULT=$F \
	BUILDAT_HEARTH_DEFAULT=$H timeout 60 bin/buildat -o launch_ui=launch_menu \
	-D "$t/cl_def" -C "$t/cl_def.cache" -w 1000x700 -l 3 -o sound_mute=1 \
	-c @"$t/def.cmds" || fail "the strip from the defaults ($t/def.log)"
asks=$(grep -a "Asking the user about" "$t/def.log" | grep -v " __app   : ")
[ "$(echo "$asks" | grep -c .)" = 1 ] && echo "$asks" | grep -q "about $F for \"\"" ||
	fail "the client's own fetches asked, or the console's did not: $asks"
mkdir -p "$t/cl_other"
FL=${F/127.0.0.1/localhost}
printf '{"starports": [], "aittas": ["%s"], "hearth": "%s"}\n' "$FL" \
	"${H/127.0.0.1/localhost}" > "$t/cl_other/starport.json"
printf '%s\n' 'wait_log_any 30000 rows in' 'text apps from aitta' \
	'wait_log 10000 rows for "apps from aitta" in' 'keypress Return' \
	"wait_log 10000 Asking the user about $FL" quit > "$t/other.cmds"
run_client 60 "$t/other.log" env BUILDAT_STARPORT_DEFAULT=$F BUILDAT_AITTA_DEFAULT=$F \
	BUILDAT_HEARTH_DEFAULT=$H timeout 60 bin/buildat -o launch_ui=launch_menu \
	-D "$t/cl_other" -C "$t/cl_other.cache" -w 1000x700 -l 3 -o sound_mute=1 \
	-c @"$t/other.cmds" || fail "a host not a default was not asked about ($t/other.log)"
grep -aq "launch_menu: now:" "$t/other.log" && fail "a strip from hosts not accepted"

# 6.
if [ ! -s "$here/web/buildat.data" ]; then
	echo "PASS: the strip, the app's threads, and nothing unasked (natively; no web/)"
	exit 0
fi
BUILDAT_LUANTI_LIST=http://127.0.0.1:9 start_server "$t/play.log" "Listening at" 120 auto \
	bin/buildat_server -m ../apps/play -D "$t/play" -C "$t/play.cache" -W "$here/web" -l 3 ||
	fail "the play server did not start"
CHECK_PIDS+=($SERVER_PID)
PP=$SERVER_PORT
python3 - "$t/steps.json" "http://127.0.0.1:$PP" "$F" "$H" "$t" <<'PY'
import json, sys, time
steps, page, fake, hearth, t = sys.argv[1:]
now = int(time.time())
csv = "".join('"true","%s","","%d","%d","","",""\n' % (u, now, now)
		for u in (fake, hearth))
settings = json.dumps({"starports": [fake], "aittas": [fake], "hearth": hearth})
set_js = ("FS.writeFile('/buildat/user/starport.json', %s); "
		"FS.writeFile('/buildat/user/network_addresses.csv', %s); "
		"new Promise(r => Module.buildatSave(() => r('set')))") % (
		json.dumps(settings), json.dumps(csv))
strip = (r"launch_menu: now: Busy server \(5 playing\); tester/game 1\.2\.0 "
		r"\(updated 2 days ago\); Release 9 is out \(News\); Busy chat "
		r"\(3 posts\); Lamp trouble in game \(2 posts\)")
json.dump([
	["nav", page + "/"],
	["waitlog", "launch_menu", 90],
	["eval", set_js],
	["nav", page + "/?again"],
	["waitlog", strip, 60],
	["wait", 500],
	["shot", t + "/web_home.png"],
	["key", "Down"],
	["key", "Enter"],
	["waitlog", "aitta panel: thread 3 Lamp trouble in game", 30],
	["wait", 500],
	["shot", t + "/web_app.png"],
	["nav", page + "/?third"],
	["waitlog", strip, 60],
	["wait", 500],
	["key", "Down"],
	["key", "Down"],
	["key", "Enter"],
	["waitlog", "hearth: open /t/1 on " + hearth[7:], 30],
], open(steps, "w"), indent=1)
PY
WEB_DRIVE_URL=http://127.0.0.1:$PP timeout 300 "$here/util/web_drive.sh" chrome play \
	"$t/steps.json" "$t/web" > "$t/web.out" 2>&1 ||
	fail "the web drive ($(tail -3 "$t/web.out"); $t/web)"
echo "PASS: the strip, the app's threads, and nothing unasked, natively and in Chrome"
