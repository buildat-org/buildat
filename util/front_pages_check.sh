#!/bin/bash
# tier: full
# cost: ~1.5 min (2026-10-06)
# covers: apps/starport/main/main.cpp apps/aitta/main/main.cpp src/interface/web_brand.h
# [FRONT_PAGES]: a Starport and an Aitta answer / with a read-only page and
# leave /index.html to the web client. Aitta's says nothing is published,
# then lists a release whose description has a <script> in it, as text,
# and /p/<author>/<name> lists its versions. The Aitta is announced to the
# Starport under a name with a <script> in it: the Starport's page shows
# it as text, "Native client only" (no TLS), and the kind filter keeps it
# or leaves it out. Nothing offers to show what does not suit a teen.
# Both pages hold back what is new for an hour: the check sets that to 0
# after seeing it hold the release back. An adult release stays off.
# [AITTA_PAGE_TEXT]: Aitta's pages without the sandbox, signature and
# commands sentences and the Report form's note, their footer link
# "Manage your published apps"; the Starport's footer as it was.
#   util/front_pages_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
pids=()
trap 'kill ${pids[@]} 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
SP=29871 AI=29872
# The boxed servers reach each other: the announce and its check
export BUILDAT_CONNECT_PORTS="$SP,$AI"
cd "$here"
page(){ curl -s -m 10 "http://127.0.0.1:$1"; }

start_server "$t/sp.log" "setup code" 60 $SP \
	Build/bin/buildat_server -m apps/starport -D "$t/sp" -l 3 ||
	fail "the Starport did not start ($t/sp.log)"
pids+=($SERVER_PID)
code=$(grep -ao "setup code [A-Z0-9]*" "$t/sp.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "the Starport did not start ($t/sp.log)"
mkdir -p "$t/ai/apps/aitta"
cat > "$t/ai/apps/aitta/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Shop <script>alert(1)</script>",
 "ids": "anyone", "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
Build/bin/buildat_server -m apps/aitta -D "$t/ai" -P $AI -l 3 \
	> "$t/ai.log" 2>&1 &
pids+=($!)
ai=$!
for _ in $(seq 300); do
	grep -q "verified ok" "$t/sp.log" && break
	kill -0 $ai 2>/dev/null || fail "the Aitta ($t/ai.log)"
	sleep 0.2
done
grep -q "verified ok" "$t/sp.log" || fail "the Aitta's listing ($t/sp.log)"

# Aitta's page before anything is published, and the web client's
p=$(page $AI/)
grep -q "Nothing is published here yet" <<< "$p" || fail "Aitta's / before a release: $p"
grep -q 'href="/index.html"' <<< "$p" || fail "Aitta's / has no way into the client"
grep -q "Nothing is published" <<< "$(page $AI/index.html)" &&
	fail "Aitta's /index.html is the page, not the web client"
[ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$AI/brand/logo.png")" = 200 ] ||
	fail "Aitta does not serve /brand/"

# The Aitta's listing claimed, so the Starport lists it; tester bound to a
# key on the Aitta
read -r _ _ id _ _ ccode < <(grep -v "^#" "$t/ai/apps/aitta/starport_claim.txt")
# Until the last request is answered
printf 'wait_log_any 30000 "id":3,\nquit\n' > "$t/cmds"
printf 'wait_log_any 30000 "id":1,\nquit\n' > "$t/cmds1"
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
	BUILDAT_SP_CREATE=1 BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false,\"page_delay\":0}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}
{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$SP -c @"$t/cmds" > "$t/sp_admin.log" 2>&1 ||
	fail "the Starport admin's run ($t/sp_admin.log)"
page $SP/api/v1/list | grep -q "Shop <script>" || fail "the claim ($t/sp_admin.log)"
Build/bin/buildat aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
ca=$(grep -ao "setup code [A-Z0-9]*" "$t/ai.log" | cut -d' ' -f3)
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$ca \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$t/cl_a" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$AI -c @"$t/cmds1" > "$t/cl_a.log" 2>&1 ||
	fail "the Aitta admin's run ($t/cl_a.log)"
grep -aq 'ai: {"id":1,"ok":true' "$t/cl_a.log" || fail "the bind ($t/cl_a.log)"
mkdir -p "$t/demo/main" "$t/demo/launcher"
echo 'int x;' > "$t/demo/main/main.cpp"
echo "return function(ctx) return {} end" > "$t/demo/launcher/init.lua"
printf '{"author": "tester", "name": "demo", "version": "1.0.0", "engine_api": 2,
	"license_code": "MIT", "license_media": "CC0-1.0",
	"description": "a <script>alert(2)</script> check", "audience": "teen",
	"home_hearth": "http://127.0.0.1:1/"}\n' > "$t/demo/meta.json"
zip=$(Build/bin/buildat aitta pack "$t/demo" "$t/key" "$t/out" 2>/dev/null) || fail "pack"
Build/bin/buildat aitta publish "$zip" 127.0.0.1:$AI 2>&1 | grep -q "listed: tester/demo/1.0.0" ||
	fail "publish"
sed -i 's/"demo"/"grown"/; s/"teen"/"adult"/' "$t/demo/meta.json"
zip=$(Build/bin/buildat aitta pack "$t/demo" "$t/key" "$t/out" 2>/dev/null) || fail "pack grown"
Build/bin/buildat aitta publish "$zip" 127.0.0.1:$AI 2>&1 | grep -q "listed: tester/grown/1.0.0" ||
	fail "publish grown"
grep -q "Nothing is published here yet" <<< "$(page $AI/)" ||
	fail "Aitta's / shows a release listed less than an hour ago"
BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_REQS='{"cmd":"set_settings","settings":{"page_delay":0}}' \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$t/cl_a" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$AI -c @"$t/cmds1" > "$t/cl_a2.log" 2>&1 ||
	fail "the Aitta admin's second run ($t/cl_a2.log)"
grep -aq '"page_delay":0' "$t/cl_a2.log" || fail "set_settings ($t/cl_a2.log)"

p=$(page $AI/)
grep -q "<script>" <<< "$p" && fail "Aitta's / runs a release's <script>"
grep -q "a &lt;script&gt;alert(2)&lt;/script&gt; check" <<< "$p" ||
	fail "Aitta's / does not show the release as text: $p"
grep -q 'href="/p/tester/demo"' <<< "$p" || fail "no link to the package's page"
grep -q '/api/v1/aitta/archive/[0-9a-f]*\.zip' <<< "$p" || fail "no .zip link"
grep -q 'http://127.0.0.1:1/p/tester/demo" rel="nofollow noopener">Discuss' <<< "$p" ||
	fail "no Discuss link to the home Hearth"
grep -q "tester/grown" <<< "$p" && fail "Aitta's / lists an adult release"
grep -q "<h1>tester/demo</h1>" <<< "$(page $AI/p/tester/demo)" || fail "the package's page"
[ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$AI/p/tester/grown")" = 404 ] ||
	fail "Aitta's /p/ shows an adult release"
for u in / /p/tester/demo; do
	p=$(page $AI$u)
	for x in "reaches only its own" "checks the signature before" \
			"finds the commands" "weighs little alone"; do
		grep -q "$x" <<< "$p" && fail "Aitta's $u still says \"$x\""
	done
	grep -q '<a href="/index.html">Manage your published apps</a>' <<< "$p" ||
		fail "Aitta's $u footer"
done
echo "ok: Aitta's / and /p/, the release's text escaped, the shorter text"

p=$(page $SP/)
grep -q "<script>" <<< "$p" && fail "the Starport's / runs a listing's <script>"
grep -q "Shop &lt;script&gt;alert(1)&lt;/script&gt;" <<< "$p" ||
	fail "the Starport's / does not show the listing: $p"
grep -q "Native client only" <<< "$p" || fail "no Native client only"
grep -q 'href="/id"' <<< "$p" || fail "no link to the ID page"
grep -q '<a href="/index.html">Open in the Buildat client</a> (in the browser)' <<< "$p" ||
	fail "the Starport's footer"
grep -q "Shop &lt;" <<< "$(page "$SP/?kind=app")" || fail "?kind=app lost it"
grep -q "Shop &lt;" <<< "$(page "$SP/?kind=world")" && fail "?kind=world kept it"
grep -qi "adult" <<< "$p" && fail "the Starport's / offers adult listings"
grep -q "A Starport:" <<< "$(page $SP/index.html)" &&
	fail "the Starport's /index.html is the page, not the web client"
echo "PASS: Aitta and the Starport answer / with their pages, untrusted text as text, the web client at /index.html"
