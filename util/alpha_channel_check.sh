#!/bin/bash
# tier: full
# cost: ~1 min (2026-11-06)
# covers: util/starport_version_github.py util/serve_latest_release.sh apps/starport/main/main.cpp client/core/starport/init.lua client/core/aitta/publish.lua util/release.sh .github/workflows/package.yml util/installer.nsi util/package.sh src/boot/autodetect.cpp src/impl/aitta.cpp src/client/main.cpp CMakeLists.txt
# [ALPHA_BUILDS]: the alpha channel, on nothing outside this machine.
#   1. The GitHub adapter on a canned list: version is the newest stable,
#      prerelease the newest alpha; hash tags and drafts count for neither.
#   2. serve_latest_release.sh on fake archives from a local list: stable takes
#      no alpha, also one left in its directory; CHANNEL=alpha takes the highest
#      alpha, moves to the next and never onto stable.
#   3. Starport's list: an alpha's listing only to who names that alpha, not
#      to an old client or the page at /; stable and hash-tagged ones to all.
#   4. A client's request and offer, by this tree's VERSION. On a stable build:
#      asks nothing, sees no alpha, is offered none. Built with an -alpha.N
#      VERSION (not committed): sees its own alpha's server, is offered the next.
#   5. release.sh in a throwaway repository with fake remotes and gh: tag,
#      tag-only push, prune; patch refused; a failed push says what is left.
#   6. package.yml's notes, the installer's names, the Windows resources'
#      numbers, the refusal to publish to the official Aitta (an alpha build
#      refuses, a stable one does not; a named other Aitta is never refused).
# The rules a client decides by (who is offered what, the user directory's
# name) are also asserted at every start: client/core/starport/init.lua,
# src/boot/autodetect.cpp.
#   util/alpha_channel_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"
check_tmp alpha_channel
t=$CHECK_TMP
HP=29801 GP=29802 SP=29803 F1=29804 F2=29805 F3=29806 F4=29807
export BUILDAT_CONNECT_PORTS="$SP,$F1,$F2,$F3,$F4"
own=$(tr -d '[:space:]' < VERSION)
case $own in *-alpha.*) own_alpha=1 ;; *) own_alpha= ;; esac

until_log() { # file pattern seconds
	local n
	for n in $(seq $(($3 * 5))); do
		grep -aq -- "$2" "$1" 2>/dev/null && return 0
		sleep 0.2
	done
	return 1
}

#
# 1. The adapter
#
asset() { # the archive's name
	echo "{\"name\": \"$1\", \"browser_download_url\": \"https://example.org/$1\"}"
}
rel_json() { # tag prerelease [draft]
	local v=${1#v}
	echo "{\"tag_name\": \"$1\", \"prerelease\": $2, \"draft\": ${3:-false},
		\"html_url\": \"https://example.org/$1\", \"assets\": [
		$(asset "buildat-$v-h1-linux-x86_64-portable.tar.gz"),
		$(asset "buildat-$v-h1-win64.zip"), $(asset "buildat-$v-h1-win64-setup.exe")]}"
}
cat > "$t/rel1.json" <<J
[$(rel_json v0.9.0-alpha.1 true true), $(rel_json v0.8.0-alpha.9 true),
 $(rel_json v0.8.0-alpha.10 true), $(rel_json v0.8.0-alpha.2 true),
 $(rel_json v0.7.100-abc1234 true), $(rel_json v0.7.101 true),
 $(rel_json v0.7.102 false true), $(rel_json v0.7.99 false),
 $(rel_json v0.7.100 false), $(rel_json v0.7.9 false), $(rel_json v0.6.90-abc1234 false)]
J
echo "[$(rel_json v0.7.99 false), $(rel_json v0.6.90-abc1234 true)]" > "$t/rel2.json"
echo "[$(rel_json v0.8.0-alpha.1 true)]" > "$t/rel3.json"
RELEASES_URL="file://$t/rel1.json" util/starport_version_github.py > "$t/a1.json" ||
	fail "the adapter on a canned list"
python3 -I - "$t/a1.json" <<'PY' || fail "the adapter's answer: $(cat "$t/a1.json")"
import json, sys
a = json.load(open(sys.argv[1]))
assert a["version"] == "0.7.100", a["version"]
assert a["url"] == "https://example.org/v0.7.100"
assert a["platforms"]["linux"]["url"].endswith("buildat-0.7.100-h1-linux-x86_64-portable.tar.gz")
p = a["prerelease"]
assert p["version"] == "0.8.0-alpha.10", p["version"]
assert p["url"] == "https://example.org/v0.8.0-alpha.10"
assert p["platforms"]["linux"]["url"].endswith("buildat-0.8.0-alpha.10-h1-linux-x86_64-portable.tar.gz")
assert p["platforms"]["win64"]["url"].endswith("-win64-setup.exe")
PY
RELEASES_URL="file://$t/rel2.json" util/starport_version_github.py > "$t/a2.json" ||
	fail "the adapter with no alpha"
python3 -I -c 'import json, sys
a = json.load(open(sys.argv[1]))
assert a["version"] == "0.7.99" and "prerelease" not in a, a' "$t/a2.json" ||
	fail "no alpha: $(cat "$t/a2.json")"
RELEASES_URL="file://$t/rel3.json" util/starport_version_github.py > "$t/a3.json" 2> "$t/a3.err" &&
	fail "alphas alone are no stable version: $(cat "$t/a3.json")"
echo "ok: the adapter: newest stable, newest alpha, no hash tag or draft"

#
# 2. The serve script
#
sed -n '/^release_version(){/,/^}/p' util/serve_latest_release.sh > "$t/rv.sh"
. "$t/rv.sh"
for pair in \
		"buildat-0.8.0-alpha.10-abc123-linux-x86_64-web-precompiled 0.8.0-alpha.10" \
		"buildat-0.8.0-alpha.1-unknown-linux-x86_64-web 0.8.0-alpha.1" \
		"buildat-0.7.99-abc123-linux-x86_64-web-precompiled 0.7.99" \
		"buildat-t1-linux-x86_64-web-precompiled t1"; do
	[ "$(release_version "${pair% *}")" = "${pair#* }" ] ||
		fail "release_version ${pair% *}: $(release_version "${pair% *}")"
done
mkdir -p "$t/rel"
archive() { # version
	local n="buildat-$1-abc123-linux-x86_64-web-precompiled"
	local d="$t/rel_src/$n"
	mkdir -p "$d/bin" "$d/apps/g"
	cat > "$d/bin/buildat_server" <<'S'
#!/bin/sh
case " $* " in *" --compile-only "*) exit 0 ;; esac
echo "Listening at fake"
exec sleep 300
S
	chmod +x "$d/bin/buildat_server"
	tar -C "$t/rel_src" -czf "$t/rel/$n.tar.gz" "$n"
}
list_of() { # versions, the order the list comes in
	local v
	{ echo "["
	for v in "$@"; do
		echo "{\"browser_download_url\": \"http://127.0.0.1:$HP/buildat-$v-abc123-linux-x86_64-web-precompiled.tar.gz\"},"
	done
	echo '{"browser_download_url": "http://127.0.0.1:9/x.txt"}]'
	} > "$t/rel/releases.json.tmp"
	mv "$t/rel/releases.json.tmp" "$t/rel/releases.json"
}
for v in 0.7.99 0.8.0-alpha.2 0.8.0-alpha.9 0.8.0-alpha.10 0.8.0-alpha.11; do archive "$v"; done
python3 -m http.server $HP --bind 127.0.0.1 --directory "$t/rel" > "$t/http.log" 2>&1 &
CHECK_PIDS+=($!)
until curl -s -m 1 -o /dev/null "http://127.0.0.1:$HP/"; do sleep 0.1; done
SERVE_PID=
serve() { # log, channel, serve dir
	mkdir -p "$t/u"
	CHANNEL=$2 BUILDAT_SERVE_DIR=$3 POLL_SECONDS=1 UPDATE_MAX_WAIT=1 \
		RELEASES_URL="http://127.0.0.1:$HP/releases.json" \
		setsid util/serve_latest_release.sh g $GP "$t/u" > "$1" 2>&1 &
	SERVE_PID=$!
	CHECK_PIDS+=($SERVE_PID)
}
serve_stop() {
	kill -- -"$SERVE_PID" 2>/dev/null
	wait "$SERVE_PID" 2>/dev/null
}
list_of 0.8.0-alpha.10 0.8.0-alpha.9 0.7.99
serve "$t/s1.log" "" "$t/s1"
until_log "$t/s1.log" "starting g on port $GP on buildat-0.7.99-" 30 ||
	fail "stable did not start on the stable one ($t/s1.log)"
serve_stop
grep -aq -- "-alpha\." "$t/s1.log" && fail "stable looked at an alpha ($t/s1.log)"
echo "ok: stable takes the stable one past alphas first in the list"

# An alpha left in its directory, as the one running: not started
mkdir -p "$t/s1/versions"
tar -C "$t/s1/versions" -xzf "$t/rel/buildat-0.8.0-alpha.9-abc123-linux-x86_64-web-precompiled.tar.gz"
echo "buildat-0.8.0-alpha.9-abc123-linux-x86_64-web-precompiled" > "$t/s1/current"
serve "$t/s1b.log" "" "$t/s1"
until_log "$t/s1b.log" "starting g on port $GP on buildat-0.7.99-" 30 ||
	fail "stable, an alpha as current ($t/s1b.log)"
serve_stop
grep -aq "on buildat-0.8.0" "$t/s1b.log" && fail "stable ran the alpha left there ($t/s1b.log)"
echo "ok: stable does not start an alpha left in its directory"

list_of 0.7.99 0.8.0-alpha.9 0.8.0-alpha.10 0.8.0-alpha.2
mkdir -p "$t/s2/versions"
tar -C "$t/s2/versions" -xzf "$t/rel/buildat-0.7.99-abc123-linux-x86_64-web-precompiled.tar.gz"
serve "$t/s2.log" alpha "$t/s2"
until_log "$t/s2.log" "starting g on port $GP on buildat-0.8.0-alpha.10-" 30 ||
	fail "CHANNEL=alpha did not take alpha.10 ($t/s2.log)"
grep -aq "on buildat-0.7.99" "$t/s2.log" && fail "CHANNEL=alpha ran the stable one ($t/s2.log)"
list_of 0.7.99 0.8.0-alpha.11 0.8.0-alpha.10
until_log "$t/s2.log" "starting g on port $GP on buildat-0.8.0-alpha.11-" 30 ||
	fail "CHANNEL=alpha did not move to alpha.11 ($t/s2.log)"
serve_stop
echo "ok: CHANNEL=alpha takes the highest by version and moves to the next"

list_of 0.7.99
serve "$t/s3.log" alpha "$t/s3"
until_log "$t/s3.log" "could not read the releases" 30 ||
	fail "CHANNEL=alpha with no alpha ($t/s3.log)"
serve_stop
grep -aq "downloading" "$t/s3.log" && fail "CHANNEL=alpha took a stable one ($t/s3.log)"
CHANNEL=bogus util/serve_latest_release.sh g $GP "$t/u" 2>&1 |
	grep -q "CHANNEL is stable or alpha" || fail "a bad CHANNEL"
grep -q 'releases/latest' util/serve_latest_release.sh || fail "stable does not read GitHub's latest"
echo "ok: CHANNEL=alpha with no alpha runs nothing; a bad CHANNEL refused"

#
# 3. Starport's list
#
if [ -n "$own_alpha" ]; then
	A=$own
else
	A=0.8.0-alpha.3
fi
B=${A%.*}.$((${A##*.} + 1))
mkdir -p "$t/sp/apps/starport"
cat > "$t/sp/apps/starport/version_adapter" <<A
#!/bin/sh
echo '{"version": "0.7.0", "url": "https://example.org/r", "platforms": {},
 "prerelease": {"version": "$B", "url": "https://example.org/a",
  "platforms": {"linux": {"url": "https://example.org/$B-linux.tar.gz"},
   "win64": {"url": "http://example.org/insecure"}}, "extra": 1}}'
A
chmod +x "$t/sp/apps/starport/version_adapter"
start_server "$t/sp.log" "setup code" 180 $SP \
	Build/bin/buildat_server -m apps/starport -D "$t/sp" -l 3 ||
	fail "the Starport did not start ($t/sp.log)"
CHECK_PIDS+=($SERVER_PID)
setup=$(grep -ao "setup code [A-Z0-9]*" "$t/sp.log" | head -1 | cut -d' ' -f3)
# Servers as far as Starport can tell: a challenge answered, a version claimed
cat > "$t/fake_servers.py" <<'PY'
import hashlib, hmac, http.server, json, sys, threading, time, urllib.parse, urllib.request
sp, out = sys.argv[1], sys.argv[2]
rows = [a.split("=") for a in sys.argv[3:]]
base = {"kind": "app", "audience": "everyone", "access": "open", "app": "g", "players": 0,
	"descriptors": {"violence": "none", "chat": "moderated", "ugc": "none", "language": "no",
		"sexual": "no", "drugs": "no", "purchases": "no", "gambling": "no", "personal_data": "no"}}
secrets = {}
class H(http.server.BaseHTTPRequestHandler):
	def do_GET(self):
		q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
		listing = q["listing"][0]
		# The challenge can come before the announce's answer has
		for _ in range(200):
			if listing in secrets:
				break
			time.sleep(0.02)
		body = json.dumps({"response": hmac.new(bytes.fromhex(secrets[listing]),
				("buildat-challenge-1\n" + q["nonce"][0]).encode(),
				hashlib.sha256).hexdigest()}).encode()
		self.send_response(200)
		self.send_header("Content-Length", str(len(body)))
		self.end_headers()
		self.wfile.write(body)
	def log_message(self, *a):
		pass
for name, port, version in rows:
	srv = http.server.ThreadingHTTPServer(("127.0.0.1", int(port)), H)
	threading.Thread(target=srv.serve_forever, daemon=True).start()
def announce(**k):
	return json.loads(urllib.request.urlopen("http://127.0.0.1:%s/api/v1/announce" % sp,
			json.dumps(dict(base, **k)).encode()).read())
over = announce(name="too long", port=1, version="1." * 21)
assert not over["ok"] and "version" in over["error"], over
reqs = []
for name, port, version in rows:
	r = announce(name=name, port=int(port), version=version)
	assert r["ok"], r
	secrets[r["id"]] = r["secret"]
	code = hmac.new(bytes.fromhex(r["secret"]), b"buildat-claim-1\n",
			hashlib.sha256).hexdigest()[:16]
	reqs.append(json.dumps({"cmd": "claim", "listing": r["id"], "code": code}))
open(out, "w").write("\n".join(reqs) + "\n")
print("announced", flush=True)
threading.Event().wait()
PY
python3 -I "$t/fake_servers.py" $SP "$t/reqs.txt" "Alpha three=$F1=$A" "Alpha four=$F2=$B" \
	"Stable one=$F3=0.7.99" "Hash tagged=$F4=0.6.90-abc1234" > "$t/fake.log" 2>&1 &
CHECK_PIDS+=($!)
until_log "$t/fake.log" "announced" 20 || fail "the announces: $(cat "$t/fake.log")"
for _ in $(seq 100); do
	[ "$(grep -ac "verified ok" "$t/sp.log")" -ge 4 ] && break
	sleep 0.1
done
[ "$(grep -ac "verified ok" "$t/sp.log")" -ge 4 ] || fail "not all verified ($t/sp.log)"
printf 'wait_log_any 30000 "id":6,"ok":\nquit\n' > "$t/claim.cmds"
BUILDAT_SP_CREATE=1 BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$setup \
BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false,\"page_delay\":0}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}
$(cat "$t/reqs.txt")" timeout 60 Build/bin/buildat -o launch_ui=launch_menu -D "$t/admin" \
	-w 800x600 -l 3 -s 127.0.0.1:$SP -c @"$t/claim.cmds" > "$t/admin.log" 2>&1 ||
	fail "the admin's claims ($t/admin.log)"
names() { # the body to post, or nothing for a GET: the names listed
	if [ -n "$1" ]; then
		curl -s -m 10 -d "$1" "http://127.0.0.1:$SP/api/v1/list"
	else
		curl -s -m 10 "http://127.0.0.1:$SP/api/v1/list"
	fi | python3 -I -c 'import json, sys
print(",".join(sorted(s["name"] for s in json.load(sys.stdin)["servers"])))'
}
expect() { # what, body, names
	local got
	got=$(names "$2")
	[ "$got" = "$3" ] || fail "$1: listed \"$got\", not \"$3\""
}
all="Hash tagged,Stable one"
expect "a GET, as an old client's" "" "$all"
expect "a POST with only a key" '{"key":"00"}' "$all"
expect "a stable version named" '{"version":"0.7.99"}' "$all"
expect "a bad version" '{"version":3}' "$all"
expect "a hash tag's version" '{"version":"0.6.90-abc1234"}' "$all"
expect "$A's client" "{\"version\":\"$A\"}" "Alpha three,$all"
expect "$B's client" "{\"version\":\"$B\"}" "Alpha four,$all"
page=$(curl -s -m 10 "http://127.0.0.1:$SP/")
case $page in
*"Alpha "*) fail "the page at / lists an alpha" ;;
*"Stable one"*) ;;
*) fail "the page at / does not list the stable one" ;;
esac
echo "ok: an alpha's listing only to that alpha, not to an old client or the page; others to all"
curl -s -m 10 "http://127.0.0.1:$SP/api/v1/list" | python3 -I -c '
import json, sys
p = json.load(sys.stdin)["version"]["prerelease"]
assert p == {"version": sys.argv[1], "url": "https://example.org/a",
	"platforms": {"linux": {"url": "https://example.org/%s-linux.tar.gz" % sys.argv[1]}}}, p
' "$B" || fail "/api/v1/list's prerelease not as filtered"
echo "ok: /api/v1/list carries the adapter's prerelease, filtered"

#
# 4. This build's client against that Starport
#
mkdir -p "$t/cl"
echo "{\"starports\": [\"http://127.0.0.1:$SP\"]}" > "$t/cl/starport.json"
now=$(date +%s)
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","Starport","%s","%s","","",""\n' \
	$SP "$now" "$now" > "$t/cl/network_addresses.csv"
if [ -n "$own_alpha" ]; then
	count=3
	printf 'wait_log_any 30000 Offering version %s\nquit\n' "$B" > "$t/cl.cmds"
else
	count=2
	printf 'wait_log_any 30000 servers listed\nwait_log_absent 1000 Offering version\nquit\n' > "$t/cl.cmds"
fi
BUILDAT_STARPORT_OFFER=1 timeout 120 Build/bin/buildat -o launch_ui=launch_menu -D "$t/cl" \
	-w 800x600 -l 4 -o sound_mute=1 -c @"$t/cl.cmds" > "$t/cl.log" 2>&1 ||
	fail "the client's drive ($t/cl.log)"
grep -aq "Starport http://127.0.0.1:$SP: $count servers listed" "$t/cl.log" ||
	fail "this build ($own) saw not $count servers: $(grep -a 'servers listed' "$t/cl.log" | tail -1)"
if [ -n "$own_alpha" ]; then
	grep -aq "Offering version $B (https://example.org/$B-linux.tar.gz" "$t/cl.log" ||
		fail "no offer of the next alpha, or not the platform's link ($t/cl.log)"
	echo "ok: an alpha client sees its alpha's server and is offered the next, its platform's file"
else
	echo "ok: a stable client sees no alpha's server and is offered none"
fi

#
# 5. release.sh
#
export GIT_AUTHOR_NAME=c GIT_AUTHOR_EMAIL=c@example.org GIT_COMMITTER_NAME=c GIT_COMMITTER_EMAIL=c@example.org
mkdir -p "$t/bin"
cat > "$t/bin/gh" <<G
#!/bin/sh
echo "\$*" >> "$t/gh.log"
exit \$(cat "$t/gh.status" 2>/dev/null || echo 0)
G
chmod +x "$t/bin/gh"
fresh() { # a repository at version $1 with bare remotes
	rm -rf "$t/repo" "$t/gh.git" "$t/bb.git" "$t/gh.log" "$t/gh.status"
	git init -q --bare "$t/gh.git"
	git init -q --bare "$t/bb.git"
	git init -q -b dev "$t/repo"
	mkdir "$t/repo/util"
	cp util/release.sh "$t/repo/util/"
	echo "$1" > "$t/repo/VERSION"
	git -C "$t/repo" add -A
	git -C "$t/repo" commit -q -m init
	git -C "$t/repo" remote add github "$t/gh.git"
	git -C "$t/repo" remote add bitbucket "$t/bb.git"
}
r() { PATH="$t/bin:$PATH" GITHUB_REPO=o/r "$t/repo/util/release.sh" "$@"; }
ver() { cat "$t/repo/VERSION"; }
refused() { # what the message has, then the arguments
	local want=$1 out before
	shift
	before=$(ver)
	out=$(r "$@" 2>&1) && fail "release.sh $*: not refused"
	echo "$out" | grep -q "$want" || fail "release.sh $*: said: $out"
	[ "$(ver)" = "$before" ] || fail "release.sh $*: changed VERSION"
}
fresh 0.7.99
refused "names the version it leads to" alpha
refused "not above VERSION" alpha 0.7.5
refused "not above VERSION" alpha 0.7.99
refused "is not <major>" alpha 0.8
r alpha 0.8.0 > "$t/r1.log" 2>&1 || fail "alpha 0.8.0: $(cat "$t/r1.log")"
[ "$(ver)" = 0.8.0-alpha.1 ] || fail "alpha 0.8.0 made $(ver)"
[ "$(git -C "$t/gh.git" tag)" = v0.8.0-alpha.1 ] || fail "github's tags: $(git -C "$t/gh.git" tag)"
[ -z "$(git -C "$t/gh.git" for-each-ref refs/heads)" ] ||
	fail "the branch went to github: $(git -C "$t/gh.git" for-each-ref refs/heads)"
[ "$(git -C "$t/bb.git" rev-parse dev)" = "$(git -C "$t/repo" rev-parse HEAD)" ] ||
	fail "the branch did not go to bitbucket"
[ -z "$(git -C "$t/bb.git" tag)" ] || fail "the tag went to bitbucket"
[ "$(git -C "$t/repo" log -1 --format=%s)" = "version: 0.8.0-alpha.1" ] || fail "the version commit"
[ ! -e "$t/gh.log" ] || fail "pruned with one alpha: $(cat "$t/gh.log")"
for part in patch minor major; do refused "an alpha or other pre-release" "$part"; done
echo "ok: alpha 0.8.0 tags and pushes the tag alone; a bad base and patch, minor, major refused"

PUSH=0 r alpha > "$t/r2.log" 2>&1 || fail "PUSH=0 alpha: $(cat "$t/r2.log")"
[ "$(ver)" = 0.8.0-alpha.2 ] || fail "the next alpha is $(ver)"
[ "$(git -C "$t/gh.git" tag)" = v0.8.0-alpha.1 ] || fail "PUSH=0 pushed"
[ ! -e "$t/gh.log" ] || fail "PUSH=0 pruned"

# The prune: by number across bases, nothing not exactly an alpha's tag
for x in v0.8.0-alpha.5 v0.8.0-alpha.6 v0.8.0-alpha.7 v0.8.0-alpha.8 v0.8.0-alpha.9 \
		v0.8.0-alpha.10 v0.8.0-alpha.11 v0.7.0-alpha.20 v0.7.99 v0.6.90-abc1234 \
		v0.8.0-alpha.3-abc v0.8.0-alpha.x; do
	git -C "$t/repo" tag "$x"
	git -C "$t/repo" push -q github "refs/tags/$x"
done
echo 0.8.0-alpha.11 > "$t/repo/VERSION"
git -C "$t/repo" commit -q -m set -- VERSION
r alpha > "$t/r3.log" 2>&1 || fail "alpha.12: $(cat "$t/r3.log")"
[ "$(ver)" = 0.8.0-alpha.12 ] || fail "after alpha.11 came $(ver)"
want="release delete v0.7.0-alpha.20 --repo o/r --cleanup-tag --yes
release delete v0.8.0-alpha.1 --repo o/r --cleanup-tag --yes
release delete v0.8.0-alpha.5 --repo o/r --cleanup-tag --yes
release delete v0.8.0-alpha.6 --repo o/r --cleanup-tag --yes
release delete v0.8.0-alpha.7 --repo o/r --cleanup-tag --yes"
[ "$(cat "$t/gh.log")" = "$want" ] || fail "the prune: $(cat "$t/gh.log")"
rm -f "$t/gh.log"
echo 1 > "$t/gh.status"
r alpha > "$t/r4.log" 2>&1 || fail "gh failing failed the release: $(cat "$t/r4.log")"
grep -q "warning: old alphas not pruned" "$t/r4.log" || fail "gh failing, no warning: $(cat "$t/r4.log")"
git -C "$t/gh.git" rev-parse -q --verify refs/tags/v0.8.0-alpha.13 > /dev/null || fail "alpha.13 not pushed"
echo "ok: the prune keeps the last 5 by number and only alphas' tags; gh failing is a warning"

rm -f "$t/gh.log"
git -C "$t/repo" remote set-url github "$t/nowhere.git"
r alpha > "$t/r5.log" 2>&1 && fail "a failed push passed"
grep -q "do not run this again" "$t/r5.log" &&
	grep -q "git push github refs/tags/v0.8.0-alpha.14" "$t/r5.log" ||
	fail "a failed push's message: $(cat "$t/r5.log")"
[ ! -e "$t/gh.log" ] || fail "pruned after a failed push"
echo "ok: a failed push says what is left, and does not prune"

fresh 0.7.99
r > "$t/r6.log" 2>&1 || fail "patch: $(cat "$t/r6.log")"
[ "$(ver)" = 0.7.100 ] && [ "$(git -C "$t/gh.git" tag)" = v0.7.100 ] &&
	[ -n "$(git -C "$t/gh.git" for-each-ref refs/heads/dev)" ] ||
	fail "a stable release: $(cat "$t/r6.log")"
echo "ok: a stable release still pushes the branch and the tag"

#
# 6. The rest
#
sed -n '/- name: Notes/,/^      - uses:/p' .github/workflows/package.yml | sed '1,2d;$d;s/^          //' > "$t/notes.sh"
git init -q -b kit "$t/n"
c() { git -C "$t/n" commit -q --allow-empty -m "$1"; }
c old; git -C "$t/n" tag v0.7.98
c stable; git -C "$t/n" tag v0.7.99
c one; c "version: 0.8.0-alpha.1"; git -C "$t/n" tag v0.8.0-alpha.1
c two; c "version: 0.8.0-alpha.2"; git -C "$t/n" tag v0.8.0-alpha.2
c three; c "version: 0.8.0"; git -C "$t/n" tag v0.8.0
notes() { # tag: its notes
	git -C "$t/n" checkout -q "$1"
	(cd "$t/n" && GITHUB_REF_NAME=$1 RUNNER_TEMP=$t bash -e "$t/notes.sh")
	cat "$t/notes.md"
}
notes v0.8.0-alpha.1 > "$t/n1"
grep -q "^Since v0.7.99:" "$t/n1" && grep -q "^- one" "$t/n1" && ! grep -q "version:" "$t/n1" ||
	fail "the first alpha's notes: $(cat "$t/n1")"
notes v0.8.0-alpha.2 > "$t/n2"
grep -q "^Since v0.8.0-alpha.1:" "$t/n2" && grep -q "^- two" "$t/n2" && ! grep -q "^- one" "$t/n2" ||
	fail "an alpha's notes: $(cat "$t/n2")"
notes v0.8.0 > "$t/n3"
grep -q "^Since v0.7.99:" "$t/n3" && grep -q "^- one" "$t/n3" ||
	fail "a stable one's notes: $(cat "$t/n3")"
echo "ok: an alpha's notes are since the previous alpha, a stable one's since the previous stable"

sed -n '/^make_installer() {/,/^}/p' util/package.sh > "$t/mi.sh"
. "$t/mi.sh"
mkdir -p "$t/mi/stage/n" "$t/mi/bin" "$t/mi/out"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/mi/args"\n' "$t" > "$t/mi/bin/makensis"
chmod +x "$t/mi/bin/makensis"
root=$t/mi out=$t/mi/out
PATH="$t/mi/bin:$PATH" version=0.8.0-alpha.1-abc123 make_installer n > /dev/null || fail "make_installer, alpha"
grep -qx -- "-DPRODUCT=Buildat Alpha" "$t/mi/args" && grep -qx -- "-DDATA_DIR=buildat-alpha" "$t/mi/args" ||
	fail "an alpha's makensis: $(cat "$t/mi/args")"
PATH="$t/mi/bin:$PATH" version=0.6.90-abc123 make_installer n > /dev/null || fail "make_installer, a hash"
grep -q -- "-DPRODUCT\|-DDATA_DIR" "$t/mi/args" && fail "a stable one's makensis: $(cat "$t/mi/args")"
# What package.sh does not give stays stable's name, in every place it is used
for w in 'Name "${PRODUCT} ${VERSION}"' 'InstallDir "$LOCALAPPDATA\Programs\${PRODUCT}"' \
		'Uninstall\${PRODUCT}"' '$SMPROGRAMS\${PRODUCT} logs.lnk" "$LOCALAPPDATA\${DATA_DIR}\cache"' \
		'!define PRODUCT "Buildat"' '!define DATA_DIR "buildat"'; do
	grep -qF -- "$w" util/installer.nsi || fail "installer.nsi has no $w"
done
if grep -n 'Buildat\.lnk\|buildat\\cache\|Programs\\Buildat' util/installer.nsi | grep -v '^[0-9]*:;'; then
	fail "installer.nsi names stable's place directly"
fi
echo "ok: the installer's names"

for pair in "0.8.0-alpha.1 0,8,0" "0.7.99 0,7,99"; do
	{ echo "set(BUILDAT_VERSION_TEXT ${pair% *})"
	grep 'string(.*BUILDAT_RC_VERSION' CMakeLists.txt
	echo 'message(STATUS "${BUILDAT_RC_VERSION}")'; } > "$t/rc.cmake"
	[ "$(cmake -P "$t/rc.cmake" 2>&1)" = "-- ${pair#* }" ] ||
		fail "the Windows resources' version of ${pair% *}: $(cmake -P "$t/rc.cmake" 2>&1)"
done
echo "ok: the Windows resources' version is numbers"

grep -q '"https://aitta.buildat.org"' client/core/starport/init.lua &&
	grep -q 'OFFICIAL = "aitta.buildat.org"' src/impl/aitta.cpp ||
	fail "the client's default Aitta and the refusal's differ"
pub() { # address: what buildat aitta publish says; all stop before any request
	Build/bin/buildat aitta publish "$t/none.zip" "$1" 2>&1
}
if [ -n "$own_alpha" ]; then
	for a in https://aitta.buildat.org aitta.buildat.org:443 HTTP://AITTA.BUILDAT.ORG/; do
		pub "$a" | grep -q "does not publish to the official Aitta" || fail "alpha, $a: $(pub "$a")"
	done
else
	pub https://aitta.buildat.org | grep -q "cannot read" ||
		fail "a stable build, the official Aitta: $(pub https://aitta.buildat.org)"
fi
pub https://127.0.0.1:9 | grep -q "cannot read" || fail "a named other Aitta: $(pub https://127.0.0.1:9)"
echo "ok: this build ($own) and the official Aitta; a named other is not refused"
echo "PASS: every step above held"
