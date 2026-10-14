#!/bin/bash
# tier: full
# cost: ~45 s (2026-10-10)
# covers: apps/aitta/main/main.cpp src/client/main.cpp
# [AITTA_SERVERLESS] [AITTA_LUA51] [AITTA_HOSTING_LINK]: a local Aitta with
# play_url set.
#   1. A "serverless": true release with a goto in its client_lua, and one
#      with a \x escape, are refused with the file and line.
#   2. The goto in a release that is not serverless: listed, with a
#      warning naming the file and line.
#   3. A clean serverless release is listed; the list's ?serverless=1
#      has it and not the other.
#   4. The list page: its box says "runs in the browser" and links
#      <play_url>/#run=tester/sl, the other's neither; its package page
#      links it under the heading and under Install.
#   5. An extension published too: no "Host at" on any page;
#      app_hosting_provider = https://host.example/new set, the apps'
#      boxes and pages link "Host at host.example" with this Aitta's
#      address and the package, URL-encoded, nofollow, after Play in the
#      browser on a line of its own; the extension's do not. The package
#      page's Report folded in a closed <details> ([AITTA_HTML_FOLDS]).
#
#   util/aitta_serverless_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp aitta_serverless; t=$CHECK_TMP
b="$here/Build/bin/buildat"
trap check_cleanup EXIT

cd "$here/Build"
start_server "$t/srv.log" "setup code" 60 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
printf 'wait_log_any 30000 ai: {"id":2,\nquit\n' > "$t/reqs.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$code \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}
{\"cmd\":\"set_settings\",\"settings\":{\"page_delay\":0,\"play_url\":\"https://play.example/\"}}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$t/bind.log" 2>&1 ||
	fail "the bind's run: $(grep -a 'Command sequence failed\|^E' "$t/bind.log" | tail -2)"
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind"

# publish <name> <version> <serverless> <extra client_lua line>
publish(){
	rm -rf "$t/app"; mkdir -p "$t/app"
	cp -r ../apps/demo_board_game/main ../apps/demo_board_game/launcher "$t/app/"
	printf 'local a = 1\n%s\n' "$4" > "$t/app/main/client_lua/extra.lua"
	printf '{"author": "tester", "name": "%s", "version": "%s", "serverless": %s,
		"engine_api": 2, "audience": "everyone", "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "a serverless check"}\n' "$1" "$2" "$3" > "$t/app/meta.json"
	zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack $1 $2"
	"$b" aitta publish "$zip" 127.0.0.1:$P > "$t/pub.out" 2>&1
}

# 1.
publish sl 1.0.0 true 'goto x'
grep -q "main/client_lua/extra.lua:2:" "$t/pub.out" && ! grep -q "listed:" "$t/pub.out" ||
	fail "goto in a serverless release: $(cat "$t/pub.out")"
publish sl 1.0.0 true 'local s = "\x41"'
grep -q "main/client_lua/extra.lua:2: \\\\x is LuaJIT's escape" "$t/pub.out" &&
	! grep -q "listed:" "$t/pub.out" ||
	fail "\\x in a serverless release: $(cat "$t/pub.out")"
echo "ok: a serverless release that the web cannot load is refused"

# 2.
publish other 1.0.0 false 'goto x'
grep -q "listed: tester/other/1.0.0" "$t/pub.out" &&
	grep -q "^warning: " "$t/pub.out" &&
	grep -q "^main/client_lua/extra.lua:2:" "$t/pub.out" ||
	fail "goto in a release with a server: $(cat "$t/pub.out")"
echo "ok: in one with a server, listed with a warning"

# 3.
publish sl 1.0.0 true '-- clean'
grep -q "listed: tester/sl/1.0.0" "$t/pub.out" && ! grep -q warning "$t/pub.out" ||
	fail "a clean serverless release: $(cat "$t/pub.out")"
curl -s "http://127.0.0.1:$P/api/v1/aitta/list?serverless=1" > "$t/list"
grep -q '"name": *"sl"' "$t/list" && ! grep -q '"name": *"other"' "$t/list" ||
	fail "?serverless=1: $(cat "$t/list")"
echo "ok: listed; ?serverless=1 has it alone"

# 4.
curl -s "http://127.0.0.1:$P/" > "$t/front"
python3 - "$t/front" <<'EOF' || fail "the list page ($t/front)"
import sys
s = open(sys.argv[1]).read()
boxes = {b.split("</a>")[0].split(">")[-1]: b for b in s.split('<div class="box">')[1:]}
sl, other = boxes["tester/sl"], boxes["tester/other"]
link = 'href="https://play.example/#run=tester/sl">Play in the browser</a>'
assert "runs in the browser" in sl and link in sl, sl
assert "runs in the browser" not in other and "Play in the browser" not in other, other
EOF
curl -s "http://127.0.0.1:$P/p/tester/sl" > "$t/page"
python3 - "$t/page" <<'EOF' || fail "the package page ($t/page)"
import sys
s = open(sys.argv[1]).read()
link = 'href="https://play.example/#run=tester/sl">Play in the browser</a>'
h, i = s.index("</h1>"), s.index("<h2>Install</h2>")
assert 0 <= s.find(link, h) < s.index('<div class="box">'), "not under the heading"
assert 0 <= s.find(link, i) < s.index("<details>", i), "not first under Install"
EOF
curl -s "http://127.0.0.1:$P/p/tester/other" | grep -q "Play in the browser" &&
	fail "a link on the package with a server"
echo "ok: the pages' links"

# 5.
mkdir -p "$t/ext"
echo 'local M = {}; return M' > "$t/ext/init.lua"
printf '{"author": "tester", "name": "ext", "version": "1.0.0", "kind": "extension",
	"engine_api": 2, "audience": "everyone", "license_code": "MIT", "license_media": "CC0-1.0",
	"description": "an extension"}\n' > "$t/ext/meta.json"
zip=$("$b" aitta pack "$t/ext" "$t/key" "$t/out" 2>/dev/null) || fail "pack ext"
"$b" aitta publish "$zip" 127.0.0.1:$P | grep -q "listed: tester/ext" || fail "publish ext"
for u in / /p/tester/sl /p/tester/ext; do
	curl -s "http://127.0.0.1:$P$u" | grep -q "Host at" && fail "a Host at link unset ($u)"
done
printf 'wait_log_any 30000 ai: {"id":1,\nquit\n' > "$t/set.cmds"
BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_REQS='{"cmd":"set_settings","settings":{"app_hosting_provider":"https://host.example/new"}}' \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$P -c @"$t/set.cmds" > "$t/set.log" 2>&1 ||
	fail "the setting's run: $(grep -a 'Command sequence failed\|^E' "$t/set.log" | tail -2)"
grep -aq 'ai: {"id":1,"ok":true' "$t/set.log" || fail "the setting"
curl -s "http://127.0.0.1:$P/" > "$t/front"
curl -s "http://127.0.0.1:$P/p/tester/other" > "$t/page"
curl -s "http://127.0.0.1:$P/p/tester/ext" > "$t/epage"
python3 - "$t/front" "$t/page" "$t/epage" "$P" <<'EOF' || fail "the Host at links ($t/front, $t/page)"
import sys
front, page, epage = (open(f).read() for f in sys.argv[1:4])
link = ('<a href="https://host.example/new?aitta=http%%3A%%2F%%2F127.0.0.1%%3A%s'
	'&amp;package=tester%%2F%s" rel="nofollow noopener">Host at host.example</a>')
boxes = {b.split("</a>")[0].split(">")[-1]: b for b in front.split('<div class="box">')[1:]}
for name in ("sl", "other"):
	assert link % (sys.argv[4], name) in boxes["tester/" + name], name
assert "Host at" not in boxes["tester/ext"]
sl = boxes["tester/sl"]
assert sl.index("Play in the browser") < sl.index("Host at"), "not after Play"
# [AITTA_HTML_FOLDS] A line each, the first under the files' links
assert "Play in the browser</a><br><a href=\"https://host.example/" in sl, sl
assert ".sig</a><br><a" in sl, sl
h, i = page.index("</h1>"), page.index("<h2>Install</h2>")
l = link % (sys.argv[4], "other")
assert 0 <= page.find(l, h) < page.index('<div class="box">'), "not under the heading"
assert 0 <= page.find(l, i) < page.index("<details>", i), "not first under Install"
assert "Host at" not in epage
# The Report form folded, closed
r = page.index("<details><summary>Report</summary><form")
assert page.index("</form></details>", r) > r
EOF
echo "ok: Host at, on the apps only, only when set"
echo "PASS"
