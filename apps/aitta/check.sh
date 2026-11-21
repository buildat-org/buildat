#!/bin/bash
# tier: quick
# cost: ~35 s (2026-11-16)
# covers: apps/aitta/** src/impl/aitta.cpp src/client/main.cpp client/core/aitta/init.lua
# [AITTA_MVP] step 2: **Aitta takes a signed release and serves it**. The
# admin joins (the setup code), binds the author name "tester" to a key;
#   1. a key bound to nobody cannot start an upload;
#   2. tester's release is published, listed (with its home Hearth and
#      changelog), downloaded and installed; a key a newer Buildat added
#      is kept, and a kind it added (zipped and signed by the check, as
#      pack refuses one) is listed as "other" with its manifest whole;
#      [ALPHA_KIT_PACKAGES_PUBLIC] an alpha's scene and app are listed
#      whole too; the pages list them apart, marked, with no Install,
#      tester/demo as before; the launcher's Apps from Aitta lists them
#      not;
#   3. a licence the instance does not take, and a manifest whose author
#      is not the key's, are refused;
#   4. the admin delists it: off the list, and its archive not served;
#   5. [AITTA_AUTHORS] the admin's account binds seven more author names,
#      a key each, a ninth refused; me lists the eight, and
#      tester2 publishes with its key;
#   6. an account an older Aitta bound (its owners row one plain name,
#      written in while the Aitta is down) is listed by me, publishes,
#      and binds a second name;
#   7. a network's reads past 240 a minute are refused.
#
#   apps/aitta/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
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
		"audience": "everyone",
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

# The admin binds tester to the key, and has the pages show a release at
# once (for the alpha's below)
# Each admin run is one request; done at its answer ("ai: {"id":1,...")
printf 'wait_log_any 30000 "id":1,"ok":\nquit\n' > "$t/cmds"
printf 'wait_log_any 30000 "id":2,"ok":\nquit\n' > "$t/cmds2"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
BUILDAT_AITTA_CODE=$code \
BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}
{\"cmd\":\"set_settings\",\"settings\":{\"page_delay\":0}}" \
	timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 -s 127.0.0.1:$P \
	-c @"$t/cmds2" > "$t/cl.log" 2>&1
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

# A key a newer Buildat added is kept in the release's manifest
manifest tester 1.3.0 MIT ' "colour": "blue",'
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack 1.3.0"
out=$("$b" aitta publish "$zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "listed: tester/demo/1.3.0" || fail "publish 1.3.0: $out"
curl -s "http://127.0.0.1:$P/api/v1/aitta/list" | python3 -c 'import json,sys
r = [r for r in json.load(sys.stdin)["releases"] if r["version"] == "1.3.0"][0]
assert r["manifest"]["colour"] == "blue", r' ||
	fail "the newer key was not kept"
# A newer Buildat's kind, with a key of its own ([COMPAT_CHECKS]): pack
# refuses a kind it does not know, so the archive is zipped and signed
# here (the .sig as write_signed() makes it) and sent by publish, which
# checks nothing: taken, listed as "other", the manifest passed on whole
rawsign(){ # app key base [empty entries added]
python3 - "$@" <<'PY'
import hashlib, io, json, os, sys, zipfile
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
app, keyfile, base = sys.argv[1:4]
z = io.BytesIO()
with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as f:
    for d, _, names in os.walk(app):
        for n in names:
            p = os.path.join(d, n)
            f.write(p, os.path.relpath(p, app))
    for i in range(int(sys.argv[4]) if len(sys.argv) > 4 else 0):
        f.writestr("pad/%d" % i, "", zipfile.ZIP_STORED)
z = z.getvalue()
k = ec.derive_private_key(int(open(keyfile).read().split()[1], 16), ec.SECP256R1())
sha = hashlib.sha256(z).hexdigest()
h = hashlib.sha256(("aitta-release-1\n" + sha).encode()).digest()
pub = k.public_key().public_bytes(serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint).hex()
sig = k.sign(h, ec.ECDSA(utils.Prehashed(hashes.SHA256()))).hex()
os.makedirs(os.path.dirname(base), exist_ok=True)
open(base + ".zip", "wb").write(z)
open(base + ".sig", "w").write(json.dumps({"format": "aitta-release-1",
        "sha256": sha, "key": pub, "signature": sig}) + "\n")
PY
}
manifest tester 1.4.0 MIT ' "kind": "warp", "warp_speed": 9,'
rawsign "$t/app" "$t/key" "$t/raw/tester-demo-1.4.0" || fail "the raw release"
out=$("$b" aitta publish "$t/raw/tester-demo-1.4.0.zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "listed: tester/demo/1.4.0" || fail "publish 1.4.0 (kind warp): $out"
curl -s "http://127.0.0.1:$P/api/v1/aitta/list" | python3 -c 'import json,sys
r = [r for r in json.load(sys.stdin)["releases"] if r["version"] == "1.4.0"][0]
assert r["kind"] == "other", r
assert r["manifest"]["kind"] == "warp" and r["manifest"]["warp_speed"] == 9, r' ||
	fail "the unknown kind is not listed as \"other\" with its manifest whole"

# [ALPHA_KIT_PACKAGES_PUBLIC] A Buildat alpha's packages, zipped and signed
# here as the warp one: a scene (a Kit kind) made with 0.8.0-alpha.26, and
# an app whose buildat_version alone is an alpha's, with a stranger's <i>
mkdir -p "$t/alpha"
cp "$t/app/CHANGELOG.md" "$t/alpha/"
for n in crag early; do
	if [ $n = crag ]; then
		x='"kind": "scene", "buildat_version": "0.8.0-alpha.26", "game": "tester/trial", "title": "Crag",
		"description": "a <script>alert(3)</script> scene",'
	else
		x='"buildat_version": "0.8.0-alpha.26<i>", "description": "an early app",'
	fi
	printf '{"author": "tester", "name": "%s", "version": "1.0.0", %s
		"engine_api": 2, "license_code": "MIT", "license_media": "CC0-1.0",
		"audience": "everyone", "changelog": "CHANGELOG.md"}\n' $n "$x" > "$t/alpha/meta.json"
	rawsign "$t/alpha" "$t/key" "$t/raw/tester-$n-1.0.0" || fail "the raw $n"
	out=$("$b" aitta publish "$t/raw/tester-$n-1.0.0.zip" 127.0.0.1:$P 2>&1)
	echo "$out" | grep -q "listed: tester/$n/1.0.0" || fail "publish $n: $out"
done
# The list has them as it had the warp one
curl -s "http://127.0.0.1:$P/api/v1/aitta/list" | python3 -c 'import json,sys
rs = {r["name"]: r for r in json.load(sys.stdin)["releases"]}
c, e = rs["crag"], rs["early"]
assert c["kind"] == "other" and c["manifest"]["kind"] == "scene", c
assert c["manifest"]["buildat_version"] == "0.8.0-alpha.26", c
assert c["manifest"]["game"] == "tester/trial", c
assert e["kind"] == "app" and e["manifest"]["buildat_version"] == "0.8.0-alpha.26<i>", e' ||
	fail "the alpha releases are not listed with their manifests whole"
# / lists them apart after tester/demo (as before), marked, the kind named,
# the stranger's text as text
p=$(curl -s "http://127.0.0.1:$P/")
h='<h2>Alpha packages</h2>'
grep -qF "$h" <<< "$p" || fail "no Alpha packages on /: $p"
st=${p%%"$h"*} al=${p#*"$h"}
grep -q 'href="/p/tester/demo"' <<< "$st" && ! grep -q 'href="/p/tester/demo"' <<< "$al" ||
	fail "tester/demo is not among the stable packages on /: $p"
for n in crag early; do
	grep -q "href=\"/p/tester/$n\"" <<< "$al" && ! grep -q "href=\"/p/tester/$n\"" <<< "$st" ||
		fail "tester/$n is not listed apart on /: $p"
done
grep -q '<span class="meta">scene, ' <<< "$al" || fail "the scene's kind is not named on /: $al"
grep -qF 'Alpha: for Buildat 0.8 alpha</b>, made with 0.8.0-alpha.26;' <<< "$al" ||
	fail "the scene is not marked on /: $al"
grep -qF 'made with 0.8.0-alpha.26&lt;i&gt;;' <<< "$al" ||
	fail "the app's buildat_version is not shown as text on /: $al"
grep -qF 'a &lt;script&gt;alert(3)&lt;/script&gt; scene' <<< "$al" ||
	fail "the scene's description is not shown as text on /: $al"
grep -q '<script>\|alpha\.26<i>' <<< "$p" && fail "/ has a stranger's markup: $p"
grep -q '/api/v1/aitta/archive/[0-9a-f]*\.zip' <<< "$al" || fail "no .zip for an alpha's on /"
# Their pages: marked, no Install; tester/demo's as before
for n in crag early; do
	q=$(curl -s "http://127.0.0.1:$P/p/tester/$n")
	grep -qF "<h1>tester/$n</h1>" <<< "$q" && grep -qF "<h2>Alpha releases</h2>" <<< "$q" &&
		grep -qF "Alpha: for Buildat 0.8 alpha" <<< "$q" || fail "/p/tester/$n is not marked: $q"
	grep -q "<h2>Install</h2>\|aitta install\|<b>Install\|Play in the browser" <<< "$q" &&
		fail "/p/tester/$n offers an install: $q"
done
q=$(curl -s "http://127.0.0.1:$P/p/tester/demo")
grep -qF "<h2>Install</h2>" <<< "$q" && grep -qF "bin/buildat aitta install" <<< "$q" ||
	fail "/p/tester/demo lost its Install: $q"
grep -q "Alpha" <<< "$q" && fail "/p/tester/demo is marked an alpha's: $q"
# A stable client's Apps from Aitta lists tester/demo and not them
echo "{\"aittas\": [\"http://127.0.0.1:$P\"]}" > "$t/managed.json"
cat > "$t/page.cmds" <<C
wait_log_any 30000 rows in
text apps from aitta
wait_log 5000 apps from aitta"
keypress Return
wait_log 10000 Asking the user about http://127.0.0.1:$P
delay 1000
click Button "Accept"
wait_log 15000 aitta page: tester/demo 1.3.0
quit
C
BUILDAT_STARPORT_MANAGED="$t/managed.json" timeout 90 bin/buildat -m launch_menu \
	-D "$t/cl_lnch" -w 1024x700 -l 3 -o sound_mute=1 -c @"$t/page.cmds" > "$t/page.log" 2>&1
# Not the wait_log's own echo of the line
mine(){ grep -a "$1" "$2" | grep -av "command: \|wait_log: "; }
mine "aitta page: tester/demo 1.3.0" "$t/page.log" > /dev/null ||
	fail "Apps from Aitta did not list tester/demo ($(grep -a "aitta page\|Command seq" "$t/page.log" | tail -3))"
# (an alpha's own client lists them: looked for on a stable build only)
if ! grep -q -- -alpha. "$here/VERSION"; then
mine "aitta page: tester/crag\|aitta page: tester/early" "$t/page.log" &&
	fail "Apps from Aitta lists an alpha's package"
fi

# A manifest over 16 KiB is refused: it is kept whole and handed out in
# every list ([SECURITY_RUN_5])
manifest tester 1.5.0 MIT " \"pad\": \"$(head -c 17000 /dev/zero | tr '\0' x)\","
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack 1.5.0"
out=$("$b" aitta publish "$zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "more than 16 KiB" || fail "a 17 KB manifest: $out"

# [AITTA_UPLOAD_FILES] An app of 25000 empty files is refused from the
# archive's directory: nothing of it unpacked in Aitta's tmp
manifest tester 1.8.0 MIT
rawsign "$t/app" "$t/key" "$t/raw/tester-demo-1.8.0" 25000 || fail "the padded release"
# By curl, each piece from a network of its own (127.0.<n>.1): its ~40
# pieces would pass a network's uploads a minute
psha=$(sha256sum "$t/raw/tester-demo-1.8.0.zip" | cut -d' ' -f1)
u="http://127.0.0.1:$P/api/v1/aitta"
post(){ # net body url
	curl -s --interface 127.0.$1.1 -H 'Content-Type: application/octet-stream' \
		--data-binary @"$2" "$u/$3"
}
post 1 "$t/raw/tester-demo-1.8.0.sig" \
	"upload_begin?size=$(stat -c %s "$t/raw/tester-demo-1.8.0.zip")" > /dev/null
mkdir "$t/pieces"
split -b 60000 -a 3 -d "$t/raw/tester-demo-1.8.0.zip" "$t/pieces/"
n=2; at=0
for f in "$t/pieces/"*; do
	post $n "$f" "upload_part?sha256=$psha&offset=$at" | grep -q '"ok":true' ||
		fail "piece $n of the padded release"
	n=$((n + 1)); at=$((at + $(stat -c %s "$f")))
done
: > "$t/empty"
out=$(post $n "$t/empty" "upload_end?sha256=$psha")
echo "$out" | grep -q "files; a release has 20000 at most" ||
	fail "an app of 25000 files: $out"
[ ! -e "$BUILDAT_CACHE_PATH/apps/aitta/tmp/$psha" ] ||
	fail "the refused archive was unpacked into Aitta's tmp"

# 3. A licence not taken; an author not the key's
manifest tester 1.1.0 Proprietary
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack 1.1.0"
"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "does not take" ||
	fail "a proprietary licence was not refused"
# An SPDX expression of free ids is taken, one naming another refused
# ([LUANTI_APP_PACKAGES]: a Luanti game's mods come under several)
manifest tester 1.6.0 "MIT AND (CC-BY-SA-4.0 OR LGPL-2.1-or-later)"
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack 1.6.0"
out=$("$b" aitta publish "$zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "listed: tester/demo/1.6.0" || fail "an SPDX expression: $out"
manifest tester 1.7.0 "MIT OR Proprietary"
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack 1.7.0"
"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "does not take" ||
	fail "an expression naming a non-free licence was not refused"
manifest someone 1.2.0 MIT
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack 1.2.0"
"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "bound to the author" ||
	fail "another author's manifest was not refused"

# 4. Delisted
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
BUILDAT_AITTA_REQS='{"cmd":"delist","release":"tester/demo/1.0.0"}' \
	timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 -s 127.0.0.1:$P \
	-c @"$t/cmds" > "$t/cl2.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/cl2.log" || fail "the delist did not go through"
# The releases, not the "delisted" beside them ([AITTA_REPORTS])
curl -s "http://127.0.0.1:$P/api/v1/aitta/list" | python3 -c 'import json,sys
sys.exit(0 if any(r["name"] == "demo" and r["version"] == "1.0.0"
	for r in json.load(sys.stdin)["releases"]) else 1)' &&
	fail "a delisted release is listed"
[ "$(curl -s -o /dev/null -w '%{http_code}' \
	"http://127.0.0.1:$P/api/v1/aitta/archive/$sha.zip")" = 404 ] ||
	fail "a delisted release's archive is served"

# Each "ai: {...}" answer in a client's log, by its id, as JSON
answers(){ # log -> python's res
python3 -c 'import json, sys
res = {}
for line in open(sys.argv[1], errors="replace"):
	i = line.find("ai: {")
	if i >= 0:
		r = json.JSONDecoder().raw_decode(line[i + 4:])[0]
		res[r["id"]] = r
print(json.dumps(res))' "$1"
}
fake(){ printf '04%0128d' "$1"; } # a key's form, for a bind only

# 5. [AITTA_AUTHORS] One account binds up to 8 author names, a key each:
# tester2 (with its own key) beside tester, then six more; a ninth is
# refused. "me" lists them, first bound first, and each publishes with
# its own key. The admin adds olduser for 6.
"$b" aitta keygen "$t/key2" > "$t/pub2" 2>/dev/null || fail "keygen tester2"
reqs="{\"cmd\":\"bind\",\"author\":\"tester2\",\"key\":\"$(cat "$t/pub2")\"}"
for i in 3 4 5 6 7 8 9; do
	reqs="$reqs
{\"cmd\":\"bind\",\"author\":\"tester$i\",\"key\":\"$(fake $i)\"}"
done
reqs="$reqs
{\"cmd\":\"me\"}"
printf 'wait_log_any 30000 admin script: done\nwait_log_any 30000 "id":9,"ok":\nquit\n' > "$t/cmds5"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
BUILDAT_AITTA_CODE=$code BUILDAT_AITTA_ADMIN="add olduser oldpass1234" \
BUILDAT_AITTA_REQS="$reqs" \
	timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 -s 127.0.0.1:$P \
	-c @"$t/cmds5" > "$t/cl5.log" 2>&1
answers "$t/cl5.log" | python3 -c 'import json, sys
res = json.load(sys.stdin)
k1, k2 = sys.argv[1:]
for i in range(1, 8):
	assert res[str(i)]["ok"], res[str(i)]
assert not res["8"]["ok"] and "8 author names" in res["8"]["error"], res["8"]
a = res["9"]["result"]
assert a["authors_max"] == 8, a
want = [["tester", k1], ["tester2", k2]] + [["tester%d" % i, "04%0128d" % i] for i in range(3, 9)]
assert [[x["author"], x["key"]] for x in a["authors"]] == want, a["authors"]' \
	"$(cat "$t/pub")" "$(cat "$t/pub2")" ||
	fail "eight names bound, the ninth refused, me listing them ($(grep -a 'ai: ' "$t/cl5.log" | cut -c1-300))"
manifest tester2 1.0.0 MIT
zip=$("$b" aitta pack "$t/app" "$t/key2" "$t/out" 2>/dev/null) || fail "pack tester2"
out=$("$b" aitta publish "$zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "listed: tester2/demo/1.0.0" || fail "publish as tester2: $out"
manifest tester 2.0.0 MIT
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack 2.0.0"
out=$("$b" aitta publish "$zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "listed: tester/demo/2.0.0" || fail "publish as tester beside tester2: $out"

# 6. An account an older Aitta bound: its owners row the name alone,
# written into the save while the Aitta is down. "me" lists the name, it
# publishes, and the account binds a second name beside it.
"$b" aitta keygen "$t/oldkey" > "$t/oldpub" 2>/dev/null || fail "keygen oldie"
kill $pid
for _ in $(seq 100); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
python3 - "$t/srv/apps/aitta/saves/aitta/save.sqlite" "$(cat "$t/oldpub")" <<'PY' ||
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
key = sys.argv[2]
rows = [("owners", "olduser", "oldie"), ("keys", key, "oldie"),
	("authors", "oldie", json.dumps({"author": "oldie", "key": key,
	"account": "olduser", "time": 1760000000}))]
for s, k, v in rows:
	db.execute("insert into store (store, key, value) values (?, ?, ?)",
		(s, k, v.encode()))
db.commit()
PY
	fail "the old rows"
start_server "$t/srv2.log" "setup code|Listening at" 120 $P \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start again"
pid=$SERVER_PID
printf 'wait_log_any 30000 "id":3,"ok":\nquit\n' > "$t/cmds6"
BUILDAT_AITTA_NAME=olduser BUILDAT_AITTA_PASSWORD=oldpass1234 \
BUILDAT_AITTA_REQS="{\"cmd\":\"me\"}
{\"cmd\":\"bind\",\"author\":\"oldie2\",\"key\":\"$(fake 10)\"}
{\"cmd\":\"me\"}" \
	timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl_old" -w 800x600 -l 3 -s 127.0.0.1:$P \
	-c @"$t/cmds6" > "$t/cl6.log" 2>&1
answers "$t/cl6.log" | python3 -c 'import json, sys
res = json.load(sys.stdin)
k = sys.argv[1]
names = lambda i: [[x["author"], x["key"]] for x in res[i]["result"]["authors"]]
assert names("1") == [["oldie", k]], res["1"]
assert res["2"]["ok"], res["2"]
assert names("3") == [["oldie", k], ["oldie2", "04%0128d" % 10]], res["3"]' "$(cat "$t/oldpub")" ||
	fail "the old row's account in me and its second bind ($(grep -a 'ai: ' "$t/cl6.log" | cut -c1-300))"
manifest oldie 1.0.0 MIT
zip=$("$b" aitta pack "$t/app" "$t/oldkey" "$t/out" 2>/dev/null) || fail "pack oldie"
out=$("$b" aitta publish "$zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "listed: oldie/demo/1.0.0" || fail "publish as oldie: $out"

# 7. 240 reads a minute a network ([REWORK_FIXES]): 490 cannot all fit in
# the minutes they span, whichever minute boundary falls among them
curl -s $(for i in $(seq 490); do echo "http://127.0.0.1:$P/api/v1/aitta/info"; done) |
	grep -q "too many requests from your network" ||
	fail "490 reads in a row were not limited"
echo "PASS: bound, published, listed, installed; a newer key kept; an alpha's packages listed whole, apart on the pages and not in Apps from Aitta; an unbound key, an app of 25000 files, a licence, another author refused; delisted; eight names an account, the ninth refused, an old one-name account kept; reads limited"
