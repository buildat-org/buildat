#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-10)
# covers: util/serve_latest_release.sh apps/aitta/main/main.cpp
# [SERVE_DELISTED]: a local Aitta (its admin by first_admin) with
# tester/pt (apps/demo_board_game) 1.0.0, served by serve_latest_release.sh with
# AITTA.
#   1. 1.0.0 delisted for licence: one warning over two checks, the
#      server still up.
#   2. Delisted for malware: stopped, the stand-in on its port saying it
#      was withdrawn and why, and the server not started again.
#   3. 1.0.1 published: installed and served, the stand-in gone.
#   4. The Aitta stopped: its list unreadable is said, and 1.0.1 runs on
#      (fail open, the user's call 2026-10-14).
#
#   util/serve_delisted_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp serve_delisted; t=$CHECK_TMP
b="$here/Build/bin/buildat"
groups=()
trap 'for g in "${groups[@]}"; do kill -- -"$g" 2>/dev/null; done; check_cleanup' EXIT

cd "$here/Build"
mkdir -p "$t/srv"
echo "name admin checkpass1" > "$t/srv/first_admin"
start_server "$t/srv.log" "Listening at" 60 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
req(){ # <log> <requests>
	# The run ends at the request's answer, "ai: {...}"
	printf 'wait_log_any 30000 ai: {"id":1,\nquit\n' > "$t/reqs.cmds"
	BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass1 BUILDAT_AITTA_REQS="$2" \
		timeout 90 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
		-s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$1" 2>&1 || fail "the drive ($1)"
	grep -aq 'ai: {"id":1,"ok":true' "$1" || fail "the requests ($1)"
}
req "$t/bind.log" "{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}"
mkdir -p "$t/app"
cp -r ../apps/demo_board_game/main ../apps/demo_board_game/launcher "$t/app/"
publish(){
	printf '{"author": "tester", "name": "pt", "version": "%s",
		"engine_api": 2, "audience": "everyone", "license_code": "MIT", "license_media": "CC0-1.0",
		"description": "a delist check"}\n' "$1" > "$t/app/meta.json"
	echo "// $1" >> "$t/app/main/main.cpp"
	zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack $1"
	"$b" aitta publish "$zip" 127.0.0.1:$P > "$t/pub.out" 2>&1
	grep -q "listed: tester/pt" "$t/pub.out" || fail "publish $1: $(cat "$t/pub.out")"
	# simplified: kept; nothing found says what the second after a
	# publish is for (a release's time is whole seconds)
	sleep 1
}
publish 1.0.0

# A release of this tree, served as GitHub's list would be
HP=$((P + 1)) SP=$((P + 2))
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
slog="$t/serve/server-tester.pt-$SP.log"
setsid env AITTA=127.0.0.1:$P BUILDAT_SERVE_DIR="$t/serve" POLL_SECONDS=5 \
	UPDATE_MAX_WAIT=60 RELEASES_URL="http://127.0.0.1:$HP/releases.json" \
	"$here/util/serve_latest_release.sh" tester/pt $SP "$t/u" > "$t/serve.log" 2>&1 &
groups+=($!)
wait_for_log "$slog" "Listening at" 120 || fail "1.0.0 did not start ($t/serve.log)"

# 1.
req "$t/d1.log" '{"cmd":"delist","release":"tester/pt/1.0.0","reason":"licence","text":"not MIT"}'
wait_for_log "$t/serve.log" "is delisted by" 60 || fail "no warning ($t/serve.log)"
# Two more checks (POLL_SECONDS=5), to see the warning is not said again
sleep 12
[ "$(grep -c "is delisted by" "$t/serve.log")" = 1 ] &&
	grep -q "tester/pt 1.0.0 is delisted by 127.0.0.1:$P: licence: not MIT; it runs on" "$t/serve.log" ||
	fail "the warning ($(grep "delisted" "$t/serve.log"))"
curl -s -m 5 "http://127.0.0.1:$SP/health" | grep -q . || fail "not serving after a licence delist"
echo "ok: delisted for licence, said once, still serving"

# 2.
n=$(grep -ac "Listening at" "$slog")
req "$t/d2.log" '{"cmd":"delist","release":"tester/pt/1.0.0","reason":"malware","text":"<steals>"}'
wait_for_log "$t/serve.log" "stopped until a newer release is listed" 60 ||
	fail "not stopped ($t/serve.log)"
# Two more checks, to see the server is not started again
sleep 12
curl -s -m 5 "http://127.0.0.1:$SP/" | grep -q "withdrawn by the Aitta it came from (malware: &lt;steals&gt;)" ||
	fail "the stand-in's page: $(curl -s -m 5 "http://127.0.0.1:$SP/")"
[ "$(grep -ac "Listening at" "$slog")" = "$n" ] && ! pgrep -f "installed/tester/pt/1.0.0" > /dev/null ||
	fail "started again ($slog)"
echo "ok: delisted for malware, stopped, the stand-in says why"

# 3.
publish 1.0.1
for _i in $(seq 600); do
	[ "$(grep -ac "Listening at" "$slog")" -gt "$n" ] && break
	sleep 0.2
done
[ "$(grep -ac "Listening at" "$slog")" -gt "$n" ] || fail "1.0.1 did not start ($t/serve.log)"
pgrep -f "installed/tester/pt/1.0.1" > /dev/null || fail "not on 1.0.1"
for _i in $(seq 50); do
	curl -s -m 2 "http://127.0.0.1:$SP/health" | grep -q . && break
	sleep 0.2
done
curl -s -m 5 "http://127.0.0.1:$SP/health" | grep -q . || fail "no /health on 1.0.1"
echo "ok: 1.0.1 served"

# 4.
grep -q "could not read 127.0.0.1:$P's list" "$t/serve.log" && fail "a readable list said unreadable ($t/serve.log)"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
wait_for_log "$t/serve.log" "could not read 127.0.0.1:$P's list" 60 ||
	fail "an unreadable list not said ($t/serve.log)"
curl -s -m 5 "http://127.0.0.1:$SP/health" | grep -q . ||
	fail "not serving with the list unreadable"
pgrep -f "installed/tester/pt/1.0.1" > /dev/null || fail "1.0.1 stopped"
echo "ok: the list unreadable said, 1.0.1 runs on"
echo "PASS: every step above held"
