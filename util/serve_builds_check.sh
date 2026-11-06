#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-10)
# covers: util/serve_latest_release.sh
# [SERVE_BUILDS]: serve_latest_release.sh with BUILDS_URL, a release of
# this tree serving demo_board_game, and a build host of its own (python).
#   1. 0.0.1: the host answers 202 twice, then a tar of a --compile-only
#      made with another cache: the server starts compiling nothing ("No
#      need to recompile").
#   2. 0.0.2: 422, its log said; the server stays on 0.0.1, 0.0.2's directory
#      gone ([SERVE_REJECTED_KEEP]).
#   3. 0.0.3: a tar with ../x.so: refused, nothing written outside, on
#      0.0.1 still, 0.0.3's directory gone.
#   4. [AITTA_KIT_IN_RELEASE] 0.0.4 has an aitta_sdk/ (the host answers
#      404: compiled here): the server on it has BUILDAT_AITTA_CPP_SDK
#      naming that version's SDK; on 0.0.1, which has none, it had none.
#      The copy kept for a rollback is 0.0.1, not a refused one.
#   5. [SERVE_REJECTED_KEEP] 0.0.5: refused with 0.0.4 running: its directory
#      gone, 0.0.4 and 0.0.1 kept.
#   0. First: a BUILDS_URL that is http to a name, not a private address
#      (127.evil.com, 192.168.1.1.evil.com) or a path that looks like one,
#      stops the script at once ([SEC_RUN5_LEFTOVERS]).
#   0b. [SERVE_INSTALL_BACKOFF], archives with a stand-in for the server, so
#      no Build is needed and no compile waited for: an archive that is not
#      there is fetched after 1, 2, 4 s (POLL_SECONDS=1), the list read at every
#      poll meanwhile; another archive, one that does not unpack, one with no
#      server, are each fetched at the next poll with the wait back at 1 s; one
#      missing once installs at the next try; a wait stops at 3600 s. A release
#      refused: its directory gone, the running one kept, fetched once.
#
#   util/serve_builds_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp serve_builds; t=$CHECK_TMP
for u in http://127.evil.com/b http://192.168.1.1.evil.com http://evil.com/127.0/b; do
	BUILDAT_SERVE_DIR="$t/refused" BUILDS_URL=$u timeout 10 \
		"$here/util/serve_latest_release.sh" demo_board_game 1 "$t/refused_user" > "$t/refused.log" 2>&1
	rc=$?
	[ $rc = 2 ] && grep -q "BUILDS_URL is https" "$t/refused.log" ||
		fail "BUILDS_URL=$u: exit $rc, not refused ($t/refused.log)"
done
echo "ok: BUILDS_URL to a name that looks private refused"
groups=()
trap 'for g in "${groups[@]}"; do kill -- -"$g" 2>/dev/null; done; check_cleanup' EXIT

# 0b.
HP0=$((29700 + RANDOM % 200))
n0(){ echo "buildat-$1-check-linux-x86_64-web-precompiled"; }
fake(){ # <version> [compile's status]: an archive whose server only says it listens
	local d="$t/fake/$(n0 "$1")"
	mkdir -p "$d/bin" "$d/apps/demo_board_game"
	printf '#!/bin/sh\ncase "$*" in *--compile-only*) exit %s ;; esac\necho "Listening at fake"\nexec sleep 1000\n' \
		"${2:-0}" > "$d/bin/buildat_server"
	chmod +x "$d/bin/buildat_server"
	tar -C "$t/fake" -czf "$t/fake/$(n0 "$1").tar.gz" "$(n0 "$1")"
}
list0(){ # <version>: the list with it first
	echo "[{\"browser_download_url\": \"http://127.0.0.1:$HP0/$(n0 "$1").tar.gz\"}]" > "$t/b/l.tmp"
	mv "$t/b/l.tmp" "$t/b/releases.json"
}
gets0(){ grep -c "GET /$(n0 "$1").tar.gz" "$t/b.log"; }
mkdir -p "$t/b" "$t/fake"
list0 1.1.1
setsid python3 -m http.server $HP0 --bind 127.0.0.1 --directory "$t/b" > "$t/b.log" 2>&1 &
groups+=($!)
setsid env BUILDAT_SERVE_DIR="$t/s0" POLL_SECONDS=1 \
	RELEASES_URL="http://127.0.0.1:$HP0/releases.json" \
	"$here/util/serve_latest_release.sh" demo_board_game $((HP0 + 1)) "$t/u0" > "$t/s0.log" 2>&1 &
groups+=($!)
wait_for_log "$t/s0.log" "$(n0 1.1.1) did not install; trying it again in 8 s" 30 ||
	fail "no 1, 2, 4, 8 s of waits ($t/s0.log)"
for w in 1 2 4; do
	grep -q "$(n0 1.1.1) did not install; trying it again in $w s" "$t/s0.log" ||
		fail "no wait of $w s ($t/s0.log)"
done
[ "$(gets0 1.1.1)" = 4 ] || fail "1.1.1 fetched $(gets0 1.1.1) times, not 4 ($t/b.log)"
# The list read at the polls of the 4 s wait, the archive not
python3 - "$t/b.log" <<'PY' || fail "the polls in the 4 s wait ($t/b.log)"
import sys
gets = [l for l in open(sys.argv[1]) if "GET /" in l]
at = [i for i, l in enumerate(gets) if ".tar.gz" in l]
sys.exit(at[3] - at[2] - 1 < 3)
PY
echo "ok: an archive that is not there fetched after 1, 2, 4 s, the list read at every poll"
list0 1.1.2
echo junk > "$t/b/$(n0 1.1.2).tar.gz"
wait_for_log "$t/s0.log" "$(n0 1.1.2) did not install; trying it again in 1 s" 5 ||
	fail "another archive waited on ($t/s0.log)"
grep -q "the archive would not unpack" "$t/s0.log" || fail "not said it would not unpack"
mkdir -p "$t/fake/$(n0 1.1.3)/nothing"
tar -C "$t/fake" -czf "$t/b/$(n0 1.1.3).tar.gz" "$(n0 1.1.3)"
list0 1.1.3
wait_for_log "$t/s0.log" "$(n0 1.1.3) did not install; trying it again in 1 s" 5 ||
	fail "no server in the archive: remembered ($t/s0.log)"
grep -q "no bin/buildat_server in the archive" "$t/s0.log" || fail "not said it has no server"
echo "ok: another archive at the next poll, one that does not unpack and one with no server remembered too"
list0 1.1.4
wait_for_log "$t/s0.log" "$(n0 1.1.4) did not install; trying it again in 1 s" 5 ||
	fail "1.1.4 missing not said ($t/s0.log)"
fake 1.1.4
mv "$t/fake/$(n0 1.1.4).tar.gz" "$t/b/"
wait_for_log "$t/s0.log" "new version: $(n0 1.1.4)" 5 || fail "1.1.4 not retried ($t/s0.log)"
wait_for_log "$t/s0.log" "starting demo_board_game on port .* on $(n0 1.1.4)" 10 ||
	fail "1.1.4 not started ($t/s0.log)"
echo "ok: an archive missing once installs at the next try"
fake 1.1.6 1
mv "$t/fake/$(n0 1.1.6).tar.gz" "$t/b/"
list0 1.1.6
wait_for_log "$t/s0.log" "demo_board_game does not compile on $(n0 1.1.6)" 10 ||
	fail "1.1.6 not refused ($t/s0.log)"
[ ! -e "$t/s0/versions/$(n0 1.1.6)" ] || fail "1.1.6's directory kept"
[ -x "$t/s0/versions/$(n0 1.1.4)/bin/buildat_server" ] || fail "1.1.4 removed"
# Three more polls of the list, no fetch of it
from=$(grep -c "GET /releases.json" "$t/b.log")
for _ in $(seq 50); do
	[ "$(grep -c "GET /releases.json" "$t/b.log")" -ge $((from + 3)) ] && break
	sleep 0.2
done
[ "$(grep -c "GET /releases.json" "$t/b.log")" -ge $((from + 3)) ] || fail "the polls stopped ($t/b.log)"
[ "$(gets0 1.1.6)" = 1 ] || fail "1.1.6 fetched $(gets0 1.1.6) times ($t/b.log)"
echo "ok: a release refused: its directory gone, the running one kept, not fetched again"
kill -- -"${groups[-1]}"
unset 'groups[-1]'
list0 1.1.7
setsid env BUILDAT_SERVE_DIR="$t/s1" POLL_SECONDS=5000 \
	RELEASES_URL="http://127.0.0.1:$HP0/releases.json" \
	"$here/util/serve_latest_release.sh" demo_board_game $((HP0 + 1)) "$t/u1" > "$t/s1.log" 2>&1 &
groups+=($!)
wait_for_log "$t/s1.log" "$(n0 1.1.7) did not install; trying it again in 3600 s" 10 ||
	fail "the wait not at most 3600 s ($t/s1.log)"
kill -- -"${groups[-1]}"
unset 'groups[-1]'
echo "ok: a wait stops at 3600 s"

cd "$here/Build"

# The modules, built with a cache of their own
BUILDAT_CACHE_PATH="$t/tarcache" timeout 600 bin/buildat_server -m ../apps/demo_board_game \
	-D "$t/tu" -l 3 --compile-only > "$t/tar_compile.log" 2>&1 ||
	fail "the compile for the tar ($t/tar_compile.log)"
(cd "$t/tarcache/apps/demo_board_game/rccpp_build" && tar -cf "$t/modules.tar" *.so *.so.hash) ||
	fail "no modules to tar"
python3 -c '
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w") as t:
	i = tarfile.TarInfo("../x.so"); d = b"x"; i.size = len(d)
	t.addfile(i, io.BytesIO(d))
' "$t/evil.tar"

P=$((29700 + RANDOM % 200)) BP=$((P + 1)) HP=$((P + 2))
release(){ # <version> [sdk]: its tar, and the list with it first
	local r="$t/rel/buildat-$1-check-linux-x86_64-web-precompiled" e
	mkdir -p "$r"
	[ -n "${2:-}" ] && mkdir "$r/aitta_sdk" && echo '{}' > "$r/aitta_sdk/sdk.json"
	for e in 3rdparty Build builtin client extensions src VERSION web util apps; do
		ln -s "$here/$e" "$r/$e"
	done
	ln -s Build/bin "$r/bin"
	tar -C "$t/rel" -czf "$r.tar.gz" "$(basename "$r")"
	echo "[{\"browser_download_url\": \"http://127.0.0.1:$HP/$(basename "$r").tar.gz\"}]" \
		> "$t/rel/releases.json"
}
release 0.0.1
setsid python3 -m http.server $HP --bind 127.0.0.1 --directory "$t/rel" \
	> "$t/http.log" 2>&1 &
groups+=($!)
setsid python3 -c '
import sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
asked = {}
class H(BaseHTTPRequestHandler):
	def do_GET(self):
		q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(self.path).query))
		rel = q.get("release", "")
		n = asked[rel] = asked.get(rel, 0) + 1
		print("ask", n, q, flush=True)
		code, body = 404, b""
		if "-0.0.1-" in rel:
			code = 202 if n <= 2 else 200
			body = open(sys.argv[2], "rb").read() if code == 200 else b""
		elif "-0.0.2-" in rel or "-0.0.5-" in rel:
			code, body = 422, b"main.cpp:1: error: a check failing this\n"
		elif "-0.0.3-" in rel:
			code, body = 200, open(sys.argv[3], "rb").read()
		self.send_response(code)
		if code == 202:
			self.send_header("Retry-After", "1")
		self.send_header("Content-Length", str(len(body)))
		self.end_headers()
		self.wfile.write(body)
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
' $BP "$t/modules.tar" "$t/evil.tar" > "$t/builds.log" 2>&1 &
groups+=($!)
setsid env BUILDAT_CACHE_PATH="$t/servecache" BUILDAT_SERVE_DIR="$t/serve" \
	POLL_SECONDS=5 BUILDS_POLL=30 BUILDS_URL="http://127.0.0.1:$BP/build" \
	RELEASES_URL="http://127.0.0.1:$HP/releases.json" \
	"$here/util/serve_latest_release.sh" demo_board_game $P "$t/u" -l 4 > "$t/serve.log" 2>&1 &
groups+=($!)
slog="$t/serve/server-demo_board_game-$P.log"

# 1.
wait_for_log "$slog" "Listening at" 300 || fail "0.0.1 did not start ($t/serve.log)"
grep -q "asked BUILDS_URL for demo_board_game on buildat-0.0.1-.*: building" "$t/serve.log" &&
	grep -q "asked BUILDS_URL for demo_board_game on buildat-0.0.1-.*: ready" "$t/serve.log" ||
	fail "the asks ($t/serve.log)"
[ "$(grep -c "ask " "$t/builds.log")" = 3 ] || fail "asked $(grep -c "ask " "$t/builds.log") times, not 3"
grep -aq "No need to recompile" "$slog" && ! grep -aq "STATUS Compiling" "$slog" ||
	fail "compiled here ($slog)"
echo "ok: 202 twice, then the modules: nothing compiled here"
# The server's environment (its boxed child's is the same)
server_sdk(){
	local p
	p=$(pgrep -f "buildat_server -m .* -P $P -D " | head -1)
	[ -n "$p" ] || { echo "no server process"; return; }
	tr '\0' '\n' < "/proc/$p/environ" | grep "^BUILDAT_AITTA_CPP_SDK=" || true
}
[ -z "$(server_sdk)" ] || fail "an SDK named on 0.0.1, which has none: $(server_sdk)"

# 2.
release 0.0.2
wait_for_log "$t/serve.log" "does not compile on buildat-0.0.2" 120 ||
	fail "0.0.2's failure ($t/serve.log)"
grep -q "\[build demo_board_game\] main.cpp:1: error: a check failing this" "$t/serve.log" ||
	fail "the build log not said ($t/serve.log)"
grep -q "starting demo_board_game on port $P on buildat-0.0.2" "$t/serve.log" && fail "0.0.2 started"
vers="$t/serve/versions"
[ ! -e "$vers/buildat-0.0.2-check-linux-x86_64-web-precompiled" ] || fail "0.0.2's directory kept"
echo "ok: a failed build said, 0.0.1 kept"

# 3.
release 0.0.3
wait_for_log "$t/serve.log" "does not compile on buildat-0.0.3" 120 ||
	fail "0.0.3's tar taken ($t/serve.log)"
grep -q "0.0.3-.*: failed (not a tar of modules)" "$t/serve.log" || fail "the refusal ($t/serve.log)"
[ ! -e "$t/servecache/apps/x.so" ] || fail "../x.so written"
[ ! -e "$vers/buildat-0.0.3-check-linux-x86_64-web-precompiled" ] || fail "0.0.3's directory kept"
curl -s -m 5 "http://127.0.0.1:$P/health" | grep -q . || fail "not serving"
echo "ok: a tar reaching outside refused, 0.0.1 still serving"

# 4.
release 0.0.4 sdk
wait_for_log "$t/serve.log" "starting demo_board_game on port $P on buildat-0.0.4" 300 ||
	fail "0.0.4 did not start ($t/serve.log)"
want="BUILDAT_AITTA_CPP_SDK=$t/serve/versions/buildat-0.0.4-check-linux-x86_64-web-precompiled/aitta_sdk"
for _ in $(seq 50); do [ "$(server_sdk)" = "$want" ] && break; sleep 0.2; done
[ "$(server_sdk)" = "$want" ] || fail "on 0.0.4 the SDK is \"$(server_sdk)\", not $want"
echo "ok: on 0.0.4 the server's BUILDAT_AITTA_CPP_SDK is that version's SDK"
# The prune after the switch: the one before is the one that ran
[ -x "$vers/buildat-0.0.1-check-linux-x86_64-web-precompiled/bin/buildat_server" ] ||
	fail "the rollback copy, 0.0.1, is gone: $(ls "$vers")"

# 5.
release 0.0.5
wait_for_log "$t/serve.log" "does not compile on buildat-0.0.5" 120 ||
	fail "0.0.5's failure ($t/serve.log)"
[ ! -e "$vers/buildat-0.0.5-check-linux-x86_64-web-precompiled" ] || fail "0.0.5's directory kept"
[ -x "$vers/buildat-0.0.4-check-linux-x86_64-web-precompiled/bin/buildat_server" ] &&
	[ -x "$vers/buildat-0.0.1-check-linux-x86_64-web-precompiled/bin/buildat_server" ] ||
	fail "the running version or the rollback copy gone: $(ls "$vers")"
echo "ok: a refused release's directory gone, the running one and the rollback copy kept"
echo "PASS: every step above held"
