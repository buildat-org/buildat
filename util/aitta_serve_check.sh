#!/bin/bash
# tier: full
# cost: ~4 min (2026-11-06)
# covers: util/serve_latest_release.sh src/client/main.cpp apps/aitta/main/main.cpp src/interface/web_brand.h
# [AITTA_SERVE]: a local Aitta with tester/pt (apps/demo_board_game) 1.0.0.
#   1. buildat aitta install by name: the newest, @1.0.0 said installed
#      already, an unknown version refused with the versions listed, an
#      unknown package refused.
#   2. The package's web page has the commands.
#   3. serve_latest_release.sh tester/pt with neither AITTA nor an install:
#      refused with the install command.
#   4. With AITTA, from a release made from this tree: installs and serves
#      it as tester.pt (/health); 1.0.1 published, it is installed,
#      compiled and the server restarted onto it, a save under
#      apps/tester.pt kept. A build host that offers nothing (404) is
#      asked for the release's build with aitta= and version=1.0.0, the
#      install before it, and for 1.0.1's ([BUILDS_AITTA_ASK]); the
#      stand-ins started with no log yet print no error.
#   5. Restarted without AITTA, 1.0.2 published: stays on 1.0.1.
#   6. The page with the three ([AITTA_INSTALL_HELP]): 1.0.2 outside a
#      fold, the two others in a closed "Older releases (2)"; Install
#      after the releases and before Report, "On the client" (unreviewed:
#      the setting named) then "On a dedicated server" with the commands,
#      neither open.
#   7. [SERVE_APP_ON_NEW_RELEASE] 1.0.2 installed, on a release whose
#      bin/buildat cannot install (said, and it starts on 1.0.2). 1.0.3
#      published, and a release that can install: it installs 1.0.3 once while
#      the build host keeps it waiting, the server that dies meanwhile comes
#      back on 1.0.2, then it compiles and switches, not called an app update.
#      A release that does not compile: its directory and the 1.0.4 it
#      installed gone, fetched once; the running release then installs 1.0.4 as
#      an app update.
#
#   util/aitta_serve_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp aitta_serve; t=$CHECK_TMP
b="$here/Build/bin/buildat"
groups=()
trap 'for g in "${groups[@]}"; do kill -- -"$g" 2>/dev/null; done; check_cleanup' EXIT

cd "$here/Build"
start_server "$t/srv.log" "setup code" 60 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
printf 'wait_log_any 20000 ai: {"id":2,\nquit\n' > "$t/reqs.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$code \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}
{\"cmd\":\"set_settings\",\"settings\":{\"page_delay\":0}}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$t/bind.log" 2>&1 ||
	fail "the bind's client ($t/bind.log)"
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind"
mkdir -p "$t/app"
cp -r ../apps/demo_board_game/main ../apps/demo_board_game/launcher "$t/app/"
publish(){
	printf '{"author": "tester", "name": "pt", "version": "%s",
		"engine_api": 2, "audience": "everyone", "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "a serve check"}\n' "$1" > "$t/app/meta.json"
	# A change, so that each version's compile is real
	echo "// $1" >> "$t/app/main/main.cpp"
	zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack $1"
	"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "listed: tester/pt" ||
		fail "publish $1"
	sleep 1 # the list's newest is by time, in seconds
}
publish 1.0.0

# 1. By name
d=$("$b" aitta install 127.0.0.1:$P tester/pt "$t/u0" 2>"$t/err") &&
	[ "$d" = "$t/u0/installed/tester/pt/1.0.0" ] && [ -f "$d/main/main.cpp" ] ||
	fail "install by name: $d $(cat "$t/err")"
ls "$t/u0" | grep -q "^\.aitta" && fail "the download left behind"
d=$("$b" aitta install 127.0.0.1:$P tester/pt@1.0.0 "$t/u0" 2>"$t/err") &&
	grep -q "installed already" "$t/err" || fail "installed again: $(cat "$t/err")"
"$b" aitta install 127.0.0.1:$P tester/pt@2.0 "$t/u0" > /dev/null 2>"$t/err" &&
	fail "an unknown version installed"
grep -q "lists no tester/pt@2.0; its versions of tester/pt: 1.0.0" "$t/err" ||
	fail "an unknown version: $(cat "$t/err")"
"$b" aitta install 127.0.0.1:$P tester/nope "$t/u0" > /dev/null 2>"$t/err" &&
	fail "an unknown package installed"
grep -q "lists no tester/nope" "$t/err" || fail "an unknown package: $(cat "$t/err")"
echo "ok: installed by name, by version, refusals"

# 2. The page
curl -s "http://127.0.0.1:$P/p/tester/pt" > "$t/page"
grep -q "bin/buildat aitta install http://127.0.0.1:$P tester/pt " "$t/page" &&
	grep -q "util/serve_latest_release.sh tester/pt " "$t/page" &&
	grep -q "tester/pt@1.0.0" "$t/page" || fail "the page's commands ($t/page)"
echo "ok: the page's commands"

# A release of this tree, served as GitHub's list would be
HP=$((P + 1)) SP=$((P + 2)) BP=$((P + 3))
r="$t/rel/buildat-0.0.1-check-linux-x86_64-web-precompiled"
mkdir -p "$r/apps"
for e in 3rdparty Build builtin client extensions src VERSION web util; do
	ln -s "$here/$e" "$r/$e"
done
ln -s Build/bin "$r/bin"
tar -C "$t/rel" -czf "$r.tar.gz" "$(basename "$r")"
echo "[{\"browser_download_url\": \"http://127.0.0.1:$HP/$(basename "$r").tar.gz\"}]" \
	> "$t/rel/releases.json"
setsid python3 -m http.server $HP --bind 127.0.0.1 --directory "$t/rel" \
	> "$t/http.log" 2>&1 &
groups+=($!)
serve=(env BUILDAT_SERVE_DIR="$t/serve" POLL_SECONDS=5 UPDATE_MAX_WAIT=60
	RELEASES_URL="http://127.0.0.1:$HP/releases.json"
	"$here/util/serve_latest_release.sh" tester/pt $SP "$t/u1")
slog="$t/serve/server-tester.pt-$SP.log"

# 3. Neither AITTA nor installed
out=$("${serve[@]}" 2>&1)
[ $? = 2 ] && echo "$out" | grep -q "bin/buildat aitta install <Aitta> tester/pt $t/u1" ||
	fail "not refused: $out"
echo "ok: refused with the install command"

# 4. Following the Aitta, with a build host that logs its asks and
# offers nothing
setsid python3 -c '
import os, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
	def do_GET(self):
		q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(self.path).query))
		print("ask", sorted(q.items()), flush=True)
		# Step 7: 0.0.3 is building until the check says otherwise
		wait = "-0.0.3-" in q.get("release", "") and not os.path.exists(sys.argv[2])
		self.send_response(202 if wait else 404)
		if wait:
			self.send_header("Retry-After", "1")
		self.send_header("Content-Length", "0")
		self.end_headers()
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
' $BP "$t/built" > "$t/builds.log" 2>&1 &
groups+=($!)
setsid env AITTA=127.0.0.1:$P BUILDS_URL="http://127.0.0.1:$BP/build" \
	"${serve[@]}" > "$t/serve.log" 2>&1 &
groups+=($!)
wait_for_log "$slog" "Listening at" 180 || fail "1.0.0 did not start ($t/serve.log)"
curl -s -m 5 "http://127.0.0.1:$SP/health" | grep -q . || fail "no /health"
[ -d "$t/u1/installed/tester/pt/1.0.0" ] || fail "not installed by the script"
echo kept > "$t/u1/apps/tester.pt/save.txt"
echo "ok: installed and serving 1.0.0"
publish 1.0.1
wait_for_log "$t/serve.log" "tester/pt 1.0.1 is ready" 180 ||
	fail "no update to 1.0.1 ($t/serve.log)"
for _i in $(seq 300); do
	[ "$(grep -ac "Listening at" "$slog")" -ge 2 ] && break
	kill -0 "${groups[-1]}" 2>/dev/null || break
	sleep 0.2
done
[ "$(grep -ac "Listening at" "$slog")" -ge 2 ] || fail "1.0.1 did not start ($slog)"
pgrep -f "installed/tester/pt/1.0.1" > /dev/null || fail "not on 1.0.1"
[ "$(cat "$t/u1/apps/tester.pt/save.txt")" = kept ] || fail "the save lost"
echo "ok: 1.0.1 installed, compiled and restarted onto, the save kept"
grep -q "('aitta', '127.0.0.1:$P').*('release', 'buildat-0.0.1-.*('version', '1.0.0')" \
	"$t/builds.log" || fail "the release's ask without the version ($t/builds.log)"
grep -q "('version', '1.0.1')" "$t/builds.log" || fail "1.0.1's ask ($t/builds.log)"
grep -q "No such file" "$t/serve.log" && fail "an error said ($t/serve.log)"
[ "$(grep -n "installing tester/pt" "$t/serve.log" | head -1 | cut -d: -f1)" -lt \
	"$(grep -n "asked BUILDS_URL for tester/pt 1.0.0" "$t/serve.log" | head -1 | cut -d: -f1)" ] ||
	fail "asked before the install ($t/serve.log)"
echo "ok: the build host asked with the Aitta and the version, the install first"

# 5. Without AITTA
kill -- -"${groups[-1]}"
g=${groups[-1]}
unset 'groups[-1]'
# Its server let go of the port before the next one takes it
for _i in $(seq 50); do
	kill -0 -- -"$g" 2>/dev/null || break
	sleep 0.2
done
setsid "${serve[@]}" > "$t/serve2.log" 2>&1 &
groups+=($!)
for _i in $(seq 300); do
	[ "$(grep -ac "Listening at" "$slog")" -ge 3 ] && break
	kill -0 "${groups[-1]}" 2>/dev/null || break
	sleep 0.2
done
[ "$(grep -ac "Listening at" "$slog")" -ge 3 ] || fail "no start without AITTA ($t/serve2.log)"
publish 1.0.2
# A wait for nothing to happen: three of the script's 5 s polls
sleep 15
[ -d "$t/u1/installed/tester/pt/1.0.2" ] && fail "1.0.2 installed without AITTA"
grep -aq "tester/pt 1.0.2" "$t/serve2.log" && fail "updated without AITTA"

# 6. The page's order
curl -s "http://127.0.0.1:$P/p/tester/pt" > "$t/page3"
python3 - "$t/page3" "http://127.0.0.1:$P" <<'PY' || fail "the page's order ($t/page3)"
import sys
s, self = open(sys.argv[1]).read(), sys.argv[2]
order = ["</b> 1.0.2 ", "<details><summary>Older releases (2)</summary>",
	"</b> 1.0.1 ", "</b> 1.0.0 ", "</details>", "<h2>Install</h2>",
	"<details><summary>On the client</summary>", "<code>" + self + "</code>",
	"Apps from Aitta (unreviewed): shown", "</details>",
	"<details><summary>On a dedicated server</summary>",
	"bin/buildat aitta install " + self + " tester/pt &lt;user dir&gt;",
	"tester/pt@1.0.0", "</details>", "<details><summary>Report</summary><form", "</form></details>"]
at = 0
for x in order:
	i = s.find(x, at)
	if i < 0:
		sys.exit("not in order: " + x)
	at = i + len(x)
if "<details open" in s:
	sys.exit("a fold open")
PY
echo "ok: the page's order"

# 7.
kill -- -"${groups[-1]}"
g=${groups[-1]}
unset 'groups[-1]'
for _i in $(seq 50); do
	kill -0 -- -"$g" 2>/dev/null || break
	sleep 0.2
done
release7(){ # <version>: a release of the binaries one by one, each a file of bin/
	r="$t/rel/buildat-$1-check-linux-x86_64-web-precompiled"
	mkdir -p "$r/apps" "$r/bin"
	for e in 3rdparty Build builtin client extensions src VERSION web util; do
		ln -s "$here/$e" "$r/$e"
	done
	ln -s "$here/Build/bin/buildat_server" "$here/Build/bin/buildat" "$r/bin/"
}
publish7(){ # the list, the release first
	tar -C "$t/rel" -czf "$r.tar.gz" "$(basename "$r")"
	echo "[{\"browser_download_url\": \"http://127.0.0.1:$HP/$(basename "$r").tar.gz\"}]" \
		> "$t/rel/l.tmp"
	mv "$t/rel/l.tmp" "$t/rel/releases7.json"
}
n7(){ echo "buildat-$1-check-linux-x86_64-web-precompiled"; }
release7 0.0.2
rm "$r/bin/buildat"
printf '#!/bin/sh\n[ "$1" = aitta ] && { echo "this release cannot" >&2; exit 1; }\nexec "%s" "$@"\n' "$b" > "$r/bin/buildat"
chmod +x "$r/bin/buildat"
publish7
"$b" aitta install 127.0.0.1:$P tester/pt@1.0.2 "$t/u2" > /dev/null 2>&1 || fail "the install of 1.0.2"
SP2=$((P + 4))
setsid env BUILDAT_SERVE_DIR="$t/serve7" POLL_SECONDS=5 UPDATE_MAX_WAIT=60 AITTA=127.0.0.1:$P \
	BUILDS_URL="http://127.0.0.1:$BP/build" RELEASES_URL="http://127.0.0.1:$HP/releases7.json" \
	"$here/util/serve_latest_release.sh" tester/pt $SP2 "$t/u2" > "$t/serve7.log" 2>&1 &
groups+=($!)
s7="$t/serve7.log"
slog7="$t/serve7/server-tester.pt-$SP2.log"
wait_for_log "$slog7" "Listening at" 180 || fail "1.0.2 did not start ($s7)"
grep -q "warning: $(n7 0.0.2) could not install tester/pt from 127.0.0.1:$P; going on with .*/1.0.2" "$s7" ||
	fail "the failed install not said ($s7)"
pgrep -f "installed/tester/pt/1.0.2" > /dev/null || fail "not on 1.0.2"
echo "ok: a release that cannot install goes on with what is installed"
publish 1.0.3
wait_for_log "$s7" "could not read tester/pt's releases" 30 || fail "the old release's install ($s7)"
release7 0.0.3
publish7
wait_for_log "$s7" "tester/pt 1.0.3 installed for $(n7 0.0.3); the server stays on 1.0.2" 30 ||
	fail "0.0.3 did not install 1.0.3 ($s7)"
# Passes of build_release while the host says building, and a server that dies
wait_for_log "$t/builds.log" "0.0.3-.*'version', '1.0.3'" 30 || fail "not asked for 1.0.3 ($t/builds.log)"
from=$(grep -ac "Listening at" "$slog7")
kill "$(pgrep -f "installed/tester/pt/1.0.2" | head -1)" || fail "no server to stop"
for _i in $(seq 150); do
	[ "$(grep -ac "Listening at" "$slog7")" -gt "$from" ] && break
	sleep 0.2
done
[ "$(grep -ac "Listening at" "$slog7")" -gt "$from" ] || fail "not back after it died ($s7)"
pgrep -f "installed/tester/pt/1.0.2" > /dev/null && ! pgrep -f "installed/tester/pt/1.0.3" > /dev/null ||
	fail "not back on 1.0.2 before the switch ($s7)"
echo "ok: 1.0.3 installed by the new release; a server that died meanwhile back on 1.0.2"
lis7=$(grep -ac "Listening at" "$slog7")
: > "$t/built"
wait_for_log "$s7" "starting tester/pt on port $SP2 on $(n7 0.0.3)" 180 || fail "no switch to 0.0.3 ($s7)"
for _i in $(seq 300); do
	pgrep -f "installed/tester/pt/1.0.3" > /dev/null && break
	sleep 0.2
done
pgrep -f "installed/tester/pt/1.0.3" > /dev/null || fail "not on 1.0.3 ($s7)"
[ "$(grep -c "installing tester/pt's newest from .* for $(n7 0.0.3)" "$s7")" = 1 ] ||
	fail "installed other than once ($s7)"
c=$(grep -n "compiling tester/pt on $(n7 0.0.3)" "$s7" | head -1 | cut -d: -f1)
st=$(grep -n "stopping tester/pt" "$s7" | tail -1 | cut -d: -f1)
[ -n "$c" ] && [ -n "$st" ] && [ "$c" -lt "$st" ] || fail "not compiled before it stopped ($s7)"
# Its process is up before it listens: the count below starts from that line
for _i in $(seq 300); do
	[ "$(grep -ac "Listening at" "$slog7")" -gt "$lis7" ] && break
	sleep 0.2
done
# Two polls after the switch: no second restart, no app update of what it runs
polls7(){
	local from n
	from=$(grep -c "GET /releases7.json" "$t/http.log")
	for n in $(seq 100); do
		[ "$(grep -c "GET /releases7.json" "$t/http.log")" -ge $((from + $1)) ] && return 0
		sleep 0.2
	done
	return 1
}
n=$(grep -ac "Listening at" "$slog7")
polls7 2 || fail "the polls stopped"
[ "$(grep -ac "Listening at" "$slog7")" = "$n" ] || fail "restarted again ($s7)"
grep -q "tester/pt 1.0.3 is ready\|does not compile\|tester/pt 1.0.3 removed" "$s7" && fail "misreported ($s7)"
echo "ok: compiled, then switched to 1.0.3 on 0.0.3, once"
publish 1.0.4
release7 0.0.4
rm "$r/bin/buildat_server"
printf '#!/bin/sh\ncase "$*" in *--compile-only*) exit 1 ;; esac\nexec "%s_server" "$@"\n' "$b" > "$r/bin/buildat_server"
chmod +x "$r/bin/buildat_server"
publish7
wait_for_log "$s7" "tester/pt does not compile on $(n7 0.0.4)" 60 || fail "0.0.4 not refused ($s7)"
grep -q "tester/pt 1.0.4 removed with $(n7 0.0.4)" "$s7" || fail "1.0.4 not removed ($s7)"
[ ! -e "$t/serve7/versions/$(n7 0.0.4)" ] || fail "0.0.4's directory kept"
[ -d "$t/serve7/versions/$(n7 0.0.3)" ] && [ -d "$t/serve7/versions/$(n7 0.0.2)" ] ||
	fail "the running version or the rollback copy gone: $(ls "$t/serve7/versions")"
pgrep -f "installed/tester/pt/1.0.3" > /dev/null || fail "1.0.3 stopped by the refusal"
wait_for_log "$s7" "tester/pt 1.0.4 is ready" 60 || fail "1.0.4 not followed after the refusal ($s7)"
[ "$(grep -c "GET /$(n7 0.0.4).tar.gz" "$t/http.log")" = 1 ] || fail "0.0.4 fetched again ($t/http.log)"
echo "ok: a release that does not compile leaves with what it installed, then the app follows on the running one"
echo "PASS: install by name and version, refusals listing the versions, the page's commands; the script refuses without an install, installs with AITTA, follows 1.0.1 keeping the save, stays without AITTA; the page's newest, older folded, Install's two folds before Report; a new release installs the newest app itself, once, keeping the server on its own until the switch"
