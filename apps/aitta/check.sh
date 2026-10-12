#!/bin/bash
# tier: full
# cost: 1 min (a first run compiles the app, 2026-10-03)
# covers: apps/aitta/** src/impl/aitta.cpp src/client/main.cpp
# [AITTA_MVP] step 2: **Aitta takes a signed release and serves it**. The
# admin joins (the setup code), binds the author name "tester" to a key;
#   1. a key bound to nobody cannot start an upload;
#   2. tester's release is published, listed (with its home Hearth and
#      changelog), downloaded and installed;
#   3. a licence the instance does not take, and a manifest whose author
#      is not the key's, are refused;
#   4. the admin delists it: off the list, and its archive not served;
#   5. a network's reads past 240 a minute are refused.
#
#   apps/aitta/check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
b="$here/Build/bin/buildat"
t=$(mktemp -d)
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
P=29874

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 $P \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
pid=$SERVER_PID
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "Aitta did not start (srv.log: $(tail -3 "$t/srv.log"))"

mkdir -p "$t/app/main"
echo 'int x;' > "$t/app/main/main.cpp"
echo "the changes" > "$t/app/CHANGELOG.md"
manifest(){ # author version licence [more keys]
	printf '{"author": "%s", "name": "demo", "version": "%s",%s
		"engine_api": 2, "license_code": "%s", "license_media": "CC0-1.0",
		"description": "a check", "home_hearth": "https://forum.example",
		"changelog": "CHANGELOG.md"}\n' "$1" "$2" "${4:-}" "$3" > "$t/app/meta.json"
}
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
"$b" aitta keygen "$t/stranger" > /dev/null 2>&1 || fail "keygen 2"

# 1. Before any key is bound
manifest tester 1.0.0 MIT
zip=$("$b" aitta pack "$t/app" "$t/stranger" "$t/s" 2>/dev/null) || fail "pack"
out=$("$b" aitta publish "$zip" 127.0.0.1:$P 2>&1) &&
	fail "an unbound key published: $out"
echo "$out" | grep -q "not bound" || fail "the unbound key's refusal: $out"

# The admin binds tester to the key
printf 'delay 8000\nquit\n' > "$t/cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
BUILDAT_AITTA_CODE=$code \
BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}" \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 -s 127.0.0.1:$P \
	-c @"$t/cmds" > "$t/cl.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/cl.log" ||
	fail "the bind did not go through ($(grep -a 'ai:' "$t/cl.log" | head -2))"

# 2. Published, listed, downloaded, installed
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack 1.0.0"
out=$("$b" aitta publish "$zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "listed: tester/demo/1.0.0" || fail "publish 1.0.0: $out"
list=$(curl -s "http://127.0.0.1:$P/api/v1/aitta/list")
echo "$list" | grep -q '"version":"1.0.0"' || fail "1.0.0 is not listed: $list"
echo "$list" | grep -q '"changelog":"CHANGELOG.md","delisted":false,.*"home_hearth":"https://forum.example"' ||
	fail "the home Hearth and the changelog are not listed: $list"
sha=$(sha256sum "$zip" | cut -d' ' -f1)
curl -s -o "$t/dl.zip" "http://127.0.0.1:$P/api/v1/aitta/archive/$sha.zip"
curl -s -o "$t/dl.sig" "http://127.0.0.1:$P/api/v1/aitta/archive/$sha.sig"
cmp -s "$t/dl.zip" "$zip" || fail "the archive served is not the one published"
"$b" aitta install "$t/dl.zip" "$t/user" > /dev/null 2>&1 ||
	fail "the downloaded release did not install"

# A key a newer Buildat added is kept in the release's manifest.
# simplified: a newer kind ("other" in the list) is not driven: pack
# refuses a kind it does not know
manifest tester 1.3.0 MIT ' "colour": "blue",'
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack 1.3.0"
out=$("$b" aitta publish "$zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "listed: tester/demo/1.3.0" || fail "publish 1.3.0: $out"
curl -s "http://127.0.0.1:$P/api/v1/aitta/list" | python3 -c 'import json,sys
r = [r for r in json.load(sys.stdin)["releases"] if r["version"] == "1.3.0"][0]
assert r["manifest"]["colour"] == "blue", r' ||
	fail "the newer key was not kept"

# 3. A licence not taken; an author not the key's
manifest tester 1.1.0 Proprietary
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack 1.1.0"
"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "not one this instance takes" ||
	fail "a proprietary licence was not refused"
manifest someone 1.2.0 MIT
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack 1.2.0"
"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "bound to the author" ||
	fail "another author's manifest was not refused"

# 4. Delisted
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
BUILDAT_AITTA_REQS='{"cmd":"delist","release":"tester/demo/1.0.0"}' \
	timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 -s 127.0.0.1:$P \
	-c @"$t/cmds" > "$t/cl2.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/cl2.log" || fail "the delist did not go through"
# The releases, not the "delisted" beside them ([AITTA_REPORTS])
curl -s "http://127.0.0.1:$P/api/v1/aitta/list" | python3 -c 'import json,sys
sys.exit(0 if any(r["version"] == "1.0.0" for r in json.load(sys.stdin)["releases"]) else 1)' &&
	fail "a delisted release is listed"
[ "$(curl -s -o /dev/null -w '%{http_code}' \
	"http://127.0.0.1:$P/api/v1/aitta/archive/$sha.zip")" = 404 ] ||
	fail "a delisted release's archive is served"

# 5. 240 reads a minute a network ([REWORK_FIXES]): 490 cannot all fit in
# the minutes they span, whichever minute boundary falls among them
curl -s $(for i in $(seq 490); do echo "http://127.0.0.1:$P/api/v1/aitta/info"; done) |
	grep -q "too many requests from your network" ||
	fail "490 reads in a row were not limited"
echo "PASS: bound, published, listed, installed; a newer key kept; an unbound key, a licence, another author refused; delisted; reads limited"
