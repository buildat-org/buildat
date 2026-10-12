#!/bin/bash
# tier: full
# cost: 4min (2026-10-09)
# covers: util/serve_latest_release.sh builtin/network/network.cpp src/client/state.cpp src/client/app.cpp client/api.lua client/packet.lua extensions/launch_menu/screens.lua src/client/web/index.html builtin/starport_announce/starport_announce.cpp apps/starport/main/main.cpp
# [SERVE_UPDATE_SMOOTH]: util/serve_latest_release.sh with floorplanner and
# vanilla, fed "releases" made from this tree (its binaries, each with an
# apps/ of its own) from a local list in place of GitHub's. A user
# directory given twice is refused. A new release is compiled for both
# before either stops; one server restarts at a time, its start compiling
# nothing; a native client (joined through the launcher) and a web client
# in floorplanner are told why and are back in their plan without a
# click. A release whose module does not compile leaves both on the old
# one, and is not tried again.
# [SERVE_UPDATE_POLITE] (UPDATE_MAX_WAIT 100 s): with the clients on, t2
# waits; 40 s in both are told "The server updates to t2 in 60 s" and
# floorplanner's Starport listing says updating; the restart comes 60 s
# after that, and the listing stops saying it. t4 waits while a client is
# on and goes once it leaves.
# Not checked: a real release archive (each version's own cache: here the
# checks' cache is shared, so t2's floorplanner is changed to make its
# compile real).
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d "/tmp/buildat_serveupd.XXXXXX")
FP=29711 VA=29712 HP=29790 SP=29791
export BUILDAT_CONNECT_PORTS=$SP,$FP
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill -- -"$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "$t"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; exit 1; }
until_log() { # file pattern seconds
	local n
	for n in $(seq "$3"); do
		grep -aq "$2" "$1" 2>/dev/null && return 0
		sleep 1
	done
	return 1
}
cd "$here"

# A release: the tree's binaries and engine by symlink, apps/ its own
rel() { # name [main.cpp line for floorplanner]
	local d="$t/rel/buildat-$1-linux-x86_64-web-precompiled" e
	mkdir -p "$d/apps"
	for e in 3rdparty Build builtin client extensions src VERSION web util; do
		ln -s "$here/$e" "$d/$e"
	done
	ln -s Build/bin "$d/bin"
	cp -r apps/floorplanner apps/vanilla "$d/apps/"
	[ -n "${2:-}" ] && echo "$2" >> "$d/apps/floorplanner/main/main.cpp"
	tar -C "$t/rel" -czf "$d.tar.gz" "$(basename "$d")"
	echo "[{\"browser_download_url\": \"http://127.0.0.1:$HP/$(basename "$d").tar.gz\"}]" \
		> "$t/rel/releases.json"
}
mkdir -p "$t/rel" "$t/u1" "$t/u2/shared/vanilla"
cp -al "$BUILDAT_USER_PATH/shared/vanilla/games" "$t/u2/shared/vanilla/" 2>/dev/null
ln -s "$t/u1" "$t/u1link"

serve=(env BUILDAT_SERVE_DIR="$t/serve" POLL_SECONDS=5 UPDATE_MAX_WAIT=100
	RELEASES_URL="http://127.0.0.1:$HP/releases.json" util/serve_latest_release.sh)
out=$("${serve[@]}" floorplanner $FP "$t/u1" -- vanilla $VA "$t/u1link" 2>&1)
[ $? = 2 ] && echo "$out" | grep -q "floorplanner on port $FP and vanilla on port $VA are given the same user directory" ||
	fail "one user directory twice not refused: $out"
echo "ok: one user directory given twice (once by a symlink) is refused"

# A Starport floorplanner announces to, its listing claimed by its admin
setsid Build/bin/buildat_server -m apps/starport -D "$t/sp" -P $SP -l 3 \
	> "$t/sp.log" 2>&1 &
pids+=($!)
until_log "$t/sp.log" "setup code" 120 || fail "the Starport did not start"
spcode=$(grep -ao "setup code [A-Z0-9]*" "$t/sp.log" | head -1 | cut -d' ' -f3)
printf 'delay 8000\nquit\n' > "$t/spcmds"
spadmin() { # requests
	BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$spcode \
	BUILDAT_SP_CREATE=1 BUILDAT_SP_REQS="$1" timeout 90 Build/bin/buildat \
		-o launch_ui=launch_menu -D "$t/spadmin" -w 800x600 -l 3 -o sound_mute=1 \
		-s 127.0.0.1:$SP -c @"$t/spcmds" >> "$t/spadmin.log" 2>&1
}
spadmin '{"cmd":"set_settings","settings":{"email_confirmation":false}}
{"cmd":"set_email","email":"op@example.org"}'
mkdir -p "$t/u1/apps/floorplanner"
cat > "$t/u1/apps/floorplanner/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Checked planner", "ids": "off",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
listing() { curl -s -m 10 "localhost:$SP/api/v1/list"; }

rel t1
setsid python3 -m http.server $HP --bind 127.0.0.1 --directory "$t/rel" \
	> "$t/http.log" 2>&1 &
pids+=($!)
setsid "${serve[@]}" floorplanner $FP "$t/u1" -- vanilla $VA "$t/u2" \
	> "$t/serve.log" 2>&1 &
pids+=($!)
fplog="$t/serve/server-floorplanner-$FP.log"
until_log "$fplog" "Listening at" 300 && until_log "$t/serve/server-vanilla-$VA.log" "Listening at" 300 ||
	fail "t1 did not start ($t/serve.log)"
code=$(grep -ao "setup code [A-Z0-9]*" "$fplog" | tail -1 | awk '{print $3}')
echo "ok: both up on t1"
until_log "$t/sp.log" "verified ok" 120 || fail "floorplanner not verified by the Starport"
read -r _ _ id _ _ ccode < <(grep -v "^#" "$t/u1/apps/floorplanner/starport_claim.txt")
spadmin "{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}"
listing | grep -q "Checked planner" || fail "the claim ($t/spadmin.log)"
listing | grep -q '"updating"' && fail "listed as updating before any update"
echo "ok: floorplanner listed on the Starport"

# The native client: the launcher's connect screen, the port typed, in
# plan p1; then the restart, a screenshot while it waits, and back
cat > "$t/c1" <<C
delay 4000
click LineEdit "29500"
delay 300
keypress End
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
text $FP
delay 300
click Button "Join"
wait_log 60000 Entered the plan p1
wait_log 300000 Notice from the server
delay 500
screenshot $t/warned.png
wait_log 300000 leave: The server is restarting
delay 1000
screenshot $t/reconnecting.png
wait_log 300000 reconnect: joined
wait_log 60000 Entered the plan p1
delay 2000
screenshot $t/back.png
quit
C
mkdir -p "$t/cl"
BUILDAT_FP_NAME=adm BUILDAT_FP_PASSWORD=adminpass12 BUILDAT_FP_CODE=$code \
	BUILDAT_FP_CREATE=1 BUILDAT_FP_PLAN=p1 setsid timeout 600 Build/bin/buildat \
	-o launch_ui=launch_menu -D "$t/cl" -w 1000x700 -l 3 -o sound_mute=1 \
	-a extension/launch_menu/connect -c @"$t/c1" > "$t/c1.log" 2>&1 &
pids+=($!)
until_log "$t/c1.log" "floorpla: Entered the plan p1" 90 || fail "the native client did not join ($t/c1.log)"

# The web client: logged in as the same account, kept, in a plan w1 it
# makes
cat > "$t/w.json" <<J
[
	["nav", "\${URL}"],
	["waitlog", "run_script_file\\\\(accounts/accounts.lua\\\\)", 120],
	["wait", 3000],
	["type", "adm"], ["key", "Tab"], ["type", "adminpass12"],
	["click", 600, 505],
	["click", 600, 543],
	["waitlog", "Joined as adm", 30],
	["wait", 2000],
	["type", "w1"], ["key", "Enter"],
	["waitlog", "Entered the plan w1", 30],
	["waitlog", "Disconnected from server", 300],
	["wait", 1000],
	["shot", "\${OUT}/web_reconnecting.png"],
	["waitlog", "Entered the plan w1", 300],
	["wait", 2000],
	["shot", "\${OUT}/web_back.png"]
]
J
WEB_DRIVE_URL="http://127.0.0.1:$FP/" setsid util/web_drive.sh firefox floorplanner \
	"$t/w.json" "$t/web" > "$t/web.log" 2>&1 &
wpid=$!
pids+=($wpid)
until_log "$t/web/page.log" "Entered the plan w1" 180 || fail "the web client did not join ($t/web.log)"
echo "ok: a native and a web client in floorplanner, in p1 and w1"

# t2, with floorplanner's module changed so that its compile is real. The
# clients are on: it waits, and warns 40 s in
from=$(wc -l < "$t/serve.log")
rel t2 "// t2"
until_log "$t/serve.log" "buildat-t2-linux-x86_64-web-precompiled is ready" 120 ||
	fail "t2 not ready ($t/serve.log)"
until_log "$t/c1.log" "Notice from the server: The server updates to t2 in 60 s" 70 ||
	fail "the native client not warned ($t/c1.log)"
warned=$(date +%s)
tail -n +"$from" "$t/serve.log" | grep -q "stopping" && fail "stopped before the warning"
until_log "$t/web/page.log" "Notice from the server: The server updates to t2 in 60 s" 5 ||
	fail "the web client not warned"
for _ in $(seq 20); do listing | grep -q '"updating":true' && break; sleep 1; done
listing | python3 -c '
import json, sys
s = [x for x in json.load(sys.stdin)["servers"] if x["name"] == "Checked planner"]
assert s and s[0].get("updating") is True, s
' || fail "the Starport listing does not say updating"
echo "ok: with the clients on, t2 waited; they were warned, and the listing says updating"
until_log "$t/serve.log" "stopping floorplanner" 90 || fail "t2 never restarted"
stopped=$(date +%s)
[ $((stopped - warned)) -ge 50 ] || fail "restarted $((stopped - warned)) s after the warning"
until_log "$t/c1.log" "Command sequence complete\|Command sequence failed" 400
wait "$wpid"; wstatus=$?
s=$(tail -n +"$from" "$t/serve.log")
line() { echo "$s" | grep -n "$1" | head -1 | cut -d: -f1; }
cf=$(line "compiling floorplanner on buildat-t2") cv=$(line "compiling vanilla on buildat-t2")
sf=$(line "stopping floorplanner") sv=$(line "stopping vanilla")
lf=$(line "\[floorplanner:$FP\] .*Listening at")
[ -n "$cf" ] && [ -n "$cv" ] && [ -n "$sf" ] && [ -n "$sv" ] && [ -n "$lf" ] &&
	[ "$cf" -lt "$sf" ] && [ "$cv" -lt "$sf" ] && [ "$lf" -lt "$sv" ] ||
	fail "not compiled first, or not one at a time ($t/serve.log)"
echo "$s" | grep -q "\[floorplanner:$FP compile\] .*STATUS Compiling" ||
	fail "t2's floorplanner compile compiled nothing: the check proves nothing ($t/serve.log)"
echo "$s" | grep -q "\[floorplanner:$FP\] .*STATUS Compiling\|\[vanilla:$VA\] .*STATUS Compiling" &&
	fail "a start on t2 compiled again ($t/serve.log)"
echo "ok: both compiled before either stopped; one at a time; the starts compiled nothing"
[ -e "$t/u1/apps/floorplanner/shutdown_reason" ] && fail "shutdown_reason left behind"
grep -aq "extensio: reconnect: joined" "$t/c1.log" &&
	[ "$(grep -ac "floorpla: Entered the plan p1" "$t/c1.log")" -ge 2 ] ||
	fail "the native client was not back in p1 ($t/c1.log)"
grep -aq "Disconnected from server: The server is restarting: updating to t2$" "$t/c1.log" ||
	fail "the native client was not told why ($t/c1.log)"
[ "$wstatus" = 0 ] || fail "the web client was not back in w1 ($t/web.log)"
echo "ok: both clients told \"updating to t2\" and back in their plans without a click"

# t3 does not compile: both stay on t2, and it is not tried again
from=$(wc -l < "$t/serve.log")
rel t3 "#error broken"
until_log "$t/serve.log" "floorplanner does not compile on buildat-t3" 300 ||
	fail "the broken t3 was not refused ($t/serve.log)"
sleep 15
s=$(tail -n +"$from" "$t/serve.log")
echo "$s" | grep -q "stopping" && fail "a server stopped for the broken t3 ($t/serve.log)"
[ "$(echo "$s" | grep -c "compiling floorplanner on buildat-t3")" = 1 ] ||
	fail "t3 tried again ($t/serve.log)"
grep -q t2 "$t/serve/current" || fail "current is not t2"
curl -s -o /dev/null -m 5 "http://127.0.0.1:$FP/" && curl -s -o /dev/null -m 5 "http://127.0.0.1:$VA/" ||
	fail "a server is not answering after t3"
echo "ok: a release that does not compile leaves both on t2, and is not tried again"
for _ in $(seq 30); do listing | grep -q '"updating":true' || break; sleep 1; done
listing | grep -q '"updating":true' && fail "still listed as updating after the restart"
echo "ok: the listing no longer says updating"

# t4 with a client on: it waits; the client leaves, and it goes
cat > "$t/c2" <<C
delay 4000
click LineEdit "29500"
delay 300
keypress End
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
text $FP
delay 300
click Button "Join"
delay 600000
C
mkdir -p "$t/cl2"
BUILDAT_FP_NAME=adm BUILDAT_FP_PASSWORD=adminpass12 BUILDAT_FP_PLAN=p1 \
	setsid timeout 600 Build/bin/buildat -o launch_ui=launch_menu -D "$t/cl2" \
	-w 1000x700 -l 3 -o sound_mute=1 -a extension/launch_menu/connect \
	-c @"$t/c2" > "$t/c2.log" 2>&1 &
c2=$!
pids+=($c2)
until_log "$t/c2.log" "floorpla: Entered the plan p1" 90 || fail "the client did not join for t4 ($t/c2.log)"
from=$(wc -l < "$t/serve.log")
rel t4
until_log "$t/serve.log" "buildat-t4-linux-x86_64-web-precompiled is ready" 120 ||
	fail "t4 not ready ($t/serve.log)"
sleep 10
tail -n +"$from" "$t/serve.log" | grep -q "stopping" && fail "t4 did not wait for the client"
kill -- -"$c2"
for _ in $(seq 20); do
	tail -n +"$from" "$t/serve.log" | grep -q "stopping floorplanner" && break
	sleep 1
done
tail -n +"$from" "$t/serve.log" | grep -q "stopping floorplanner" ||
	fail "t4 did not go once the client left ($t/serve.log)"
tail -n +"$from" "$t/serve.log" | grep -q "warning" && fail "warned with nobody on"
echo "ok: t4 waited while a client was on, and went once it left"
echo "PASS"
