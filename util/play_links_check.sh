#!/bin/bash
# tier: full
# cost: 60s (2026-10-07)
# covers: apps/starport/main/main.cpp apps/hearth/main/main.cpp builtin/starport_announce/starport_announce.cpp builtin/network/network.cpp extensions/launch_menu/screens.lua src/client/app.cpp
# [PLAY_LINKS]: a Starport with a play_url hands it out in /api/v1/list and
# in its answer to an announce; the listed server then lets that page's
# WebSocket in, and no other page's. A client given BUILDAT_JOIN (the
# play page's ?server=) joins a server a Starport lists, not one it does
# not list, and nothing for an address of another shape.
# [HEARTH_VISITOR_FLOW]: the Hearth's thread pages say where each subject
# is had -- the Hearth itself, listed, by the play page's link; a server
# not listed, an unknown game, as text; a package by its place here, its
# Aitta page and the server running it (the Hearth again, run as an
# installed package); a ContentDB game by its ContentDB page and the
# vanilla world running it.
# Not here: the page at / links a TLS server only, and a local one has
# no TLS -- seen on the live Starport.
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_plinks.XXXXXX")
SP=29681
HE=29682
PLAY=http://127.0.0.1:29683
FA=29686 # an Aitta's list, static
PK=29687 # an app from Aitta
VA=29688 # a world of a game from ContentDB
export BUILDAT_CONNECT_PORTS="$SP,$HE,$FA,$PK,$VA"
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here"

start_server "$tmp/sp.log" "setup code" 60 $SP \
	Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -l 3 ||
	fail "the Starport did not start (sp.log)"
pids+=($SERVER_PID)
code=$(grep -o "setup code [A-Z0-9]*" "$tmp/sp.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "the Starport did not start (sp.log)"
# An admin's run ends at the answer to its last request ("sp: {...}",
# numbered from 1)
printf 'wait_log_any 30000 "id":1,\nquit\n' > "$tmp/sp1.txt"
printf 'wait_log_any 30000 "id":1,\nwait_log_any 30000 "id":2,\nquit\n' > "$tmp/sp2.txt"
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
BUILDAT_SP_CREATE=1 BUILDAT_SP_REQS="{\"cmd\":\"set_settings\",\"settings\":{\"play_url\":\"$PLAY/\",\"email_confirmation\":false}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/admin" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$SP -c @"$tmp/sp2.txt" > "$tmp/admin.log" 2>&1 ||
	fail "the admin's drive ($tmp/admin.log)"
curl -s -m 10 "localhost:$SP/api/v1/list" | grep -q "\"play\":\"$PLAY\"" ||
	fail "/api/v1/list has no play ($tmp/admin.log)"
echo "ok: /api/v1/list carries the play page"

# A Hearth listed there
mkdir -p "$tmp/he/apps/hearth"
cat > "$tmp/he/apps/hearth/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Linked hearth", "ids": "anyone",
 "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
Build/bin/buildat_server -m apps/hearth -D "$tmp/he" -P $HE -l 3 \
	> "$tmp/he.log" 2>&1 &
pids+=($!)
wait_for_log "$tmp/sp.log" "verified ok" 60 || fail "the Hearth was not verified (he.log)"
read -r _ _ id _ _ ccode < <(grep -v "^#" "$tmp/he/apps/hearth/starport_claim.txt")
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass \
BUILDAT_SP_REQS="{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/admin" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$SP -c @"$tmp/sp1.txt" > "$tmp/admin2.log" 2>&1 ||
	fail "the claim's drive ($tmp/admin2.log)"
curl -s -m 10 "localhost:$SP/api/v1/list" | grep -q "Linked hearth" ||
	fail "the claim ($tmp/admin2.log)"
ws() { # origin -> the status line
	curl -s -i -m 3 -H "Connection: Upgrade" -H "Upgrade: websocket" \
		-H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
		-H "Origin: $1" "http://127.0.0.1:$HE/" | head -1
}
ws "$PLAY" | grep -q " 101 " || fail "the play page's WebSocket refused ($tmp/he.log)"
echo "ok: the play page's WebSocket let in"
ws "http://127.0.0.1:29684" | grep -q " 101 " && fail "another page's WebSocket let in"
echo "ok: another page's WebSocket refused"

# An app from Aitta (the Hearth again, under installed/) and a world of a
# game from ContentDB, both listed
listed() { # dir app name kind
	mkdir -p "$1/apps/$2"
	cat > "$1/apps/$2/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "$3", "kind": "$4",
 "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
}
mkdir -p "$tmp/installed/someone/some_app"
ln -s "$here/apps/hearth" "$tmp/installed/someone/some_app/1.0"
listed "$tmp/pk" someone.some_app "Packaged app" app
Build/bin/buildat_server -m "$tmp/installed/someone/some_app/1.0" -D "$tmp/pk" \
	-P $PK -l 3 > "$tmp/pk.log" 2>&1 &
pids+=($!)
g="$tmp/va/shared/vanilla/games/tgame"
mkdir -p "$g/mods"
echo "title = Test game" > "$g/game.conf"
echo "contentdb:someone/tgame" > "$g/.buildat_source"
listed "$tmp/va" vanilla "Test world" world
BUILDAT_LUANTI_GAME=tgame BUILDAT_LUANTI_SAVE=visitor \
	Build/bin/buildat_server -u launcher=1 -m apps/vanilla -D "$tmp/va" -P $VA -l 3 \
	> "$tmp/va.log" 2>&1 &
pids+=($!)
both() { grep -q "(Packaged app): verified ok" "$tmp/sp.log" &&
	grep -q "(Test world): verified ok" "$tmp/sp.log"; }
# A poll, two minutes at most: both servers up and verified
for _ in $(seq 600); do both && break; sleep 0.2; done
both || fail "the app and the world were not verified (pk.log, va.log)"
reqs=
for f in "$tmp/pk/apps/someone.some_app" "$tmp/va/apps/vanilla"; do
	read -r _ _ id _ _ ccode < <(grep -v "^#" "$f/starport_claim.txt")
	reqs+="{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}"$'\n'
done
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_REQS="$reqs" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/admin" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$SP -c @"$tmp/sp2.txt" > "$tmp/admin3.log" 2>&1 ||
	fail "the claims' drive ($tmp/admin3.log)"
l=$(curl -s -m 10 "localhost:$SP/api/v1/list")
grep -q '"package":"someone/some_app"' <<< "$l" || fail "the app's package not listed: $l"
grep -q '"game":"contentdb:someone/tgame"' <<< "$l" || fail "the world's game not listed: $l"
echo "ok: an app's package and a world's game listed"
mkdir -p "$tmp/fa/api/v1/aitta"
echo '{"ok":true,"releases":[{"author":"someone","name":"some_app","version":"1.0","key":"abc","home_hearth":""}]}' \
	> "$tmp/fa/api/v1/aitta/list"
python3 -m http.server -b 127.0.0.1 -d "$tmp/fa" $FA > "$tmp/fa.log" 2>&1 &
pids+=($!)
# A poll for its port
for _ in $(seq 50); do port_taken $FA && break; sleep 0.2; done
port_taken $FA || fail "the Aitta list's server ($tmp/fa.log)"

# The Hearth's threads, one subject of each kind
hcode=$(grep -ao "setup code [A-Z0-9]*" "$tmp/he.log" | cut -d' ' -f3)
# Seven requests, the Hearth's numbered from 1001
printf 'wait_log_any 30000 "id":1007,\nquit\n' > "$tmp/hc"
BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=checkpass12 \
BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$hcode \
BUILDAT_HEARTH_REQS="{\"cmd\":\"new_topic\",\"name\":\"Main\",\"about\":\"x\"}
{\"cmd\":\"release_sources\",\"aittas\":[\"http://127.0.0.1:$FA\"]}
{\"cmd\":\"new_thread\",\"server\":true,\"subject\":\"server:127.0.0.1:$HE\",\"title\":\"S\",\"body\":\"s\"}
{\"cmd\":\"new_thread\",\"topic\":1,\"subject\":\"someone/some_app abc\",\"title\":\"A\",\"body\":\"a\"}
{\"cmd\":\"new_thread\",\"game\":true,\"subject\":\"game:contentdb:someone/tgame\",\"title\":\"G\",\"body\":\"g\"}
{\"cmd\":\"new_thread\",\"game\":true,\"subject\":\"game:unknown:mygame\",\"title\":\"U\",\"body\":\"u\"}
{\"cmd\":\"new_thread\",\"server\":true,\"subject\":\"server:127.0.0.1:29685\",\"title\":\"N\",\"body\":\"n\"}" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/hadmin" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$HE -c @"$tmp/hc" > "$tmp/hadmin.log" 2>&1 ||
	fail "the Hearth admin's drive ($tmp/hadmin.log)"
grep -aq '"ok":false' "$tmp/hadmin.log" &&
	fail "the threads: $(grep -ao '"error":"[^"]*"' "$tmp/hadmin.log" | head -1)"
about() { curl -s -m 5 "http://127.0.0.1:$HE/t/$1" | grep -o '<p class="meta">About.*</p>'; }
# The Hearth reads the list each minute
for _ in $(seq 90); do
	about 1 | grep -qF "<a href=\"$PLAY/?server=127.0.0.1:$HE\"" && break
	sleep 1
done
about 1 | grep -qF "<a href=\"$PLAY/?server=127.0.0.1:$HE\"" ||
	fail "the listed server's thread: $(about 1) ($tmp/he.log)"
for w in '<a href="/p/someone/some_app">' \
		"<a href=\"http://127.0.0.1:$FA/p/someone/some_app\">" \
		"<a href=\"$PLAY/?server=127.0.0.1:$PK\""; do
	about 2 | grep -qF "$w" || fail "the app's thread has no $w: $(about 2)"
done
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HE/p/someone/some_app")" = 200 ] ||
	fail "/p/someone/some_app is not there"
for w in '<a href="https://content.luanti.org/packages/someone/tgame/"' \
		"<a href=\"$PLAY/?server=127.0.0.1:$VA\""; do
	about 3 | grep -qF "$w" || fail "the ContentDB game's thread has no $w: $(about 3)"
done
[ "$(about 4)" = '<p class="meta">About the game mygame</p>' ] ||
	fail "the unknown game's thread: $(about 4)"
[ "$(about 5)" = '<p class="meta">About the server 127.0.0.1:29685</p>' ] ||
	fail "the unlisted server's thread: $(about 5)"
echo "ok: the Hearth's threads link where their subjects are had"

mkdir -p "$tmp/cl"
echo "{\"starports\": [\"http://127.0.0.1:$SP\"]}" > "$tmp/cl/starport.json"
printf 'accepted,address,description,created,last_attempt,name,icon,server\n"true","http://127.0.0.1:%s","Starport","%s","%s","","",""\n' \
	$SP $(date +%s) $(date +%s) > "$tmp/cl/network_addresses.csv"
client() { # BUILDAT_JOIN log line-that-ends-it
	printf 'wait_log_any 20000 %s\nquit\n' "$3" > "$tmp/c"
	BUILDAT_JOIN=$1 timeout 60 Build/bin/buildat -o launch_ui=launch_menu \
		-D "$tmp/cl" -w 800x600 -l 3 -o sound_mute=1 -c @"$tmp/c" > "$2" 2>&1
}
client "127.0.0.1:$HE" "$tmp/c1.log" "Connect succeeded"
grep -q "Connect succeeded (127.0.0.1:$HE)" "$tmp/c1.log" ||
	fail "a listed server not joined ($tmp/c1.log)"
echo "ok: a listed server joined"
client "127.0.0.1:29685" "$tmp/c2.log" "is not listed; not joined"
grep -q "is not listed; not joined" "$tmp/c2.log" ||
	fail "an unlisted one not said ($tmp/c2.log)"
grep -q "Connect succeeded" "$tmp/c2.log" && fail "an unlisted one joined"
echo "ok: an unlisted server not joined"
client "127.0.0.1:1');os.exit(3)--" "$tmp/c3.log" "BUILDAT_JOIN is not host:port"
grep -q "BUILDAT_JOIN is not host:port" "$tmp/c3.log" ||
	fail "a bad one not refused ($tmp/c3.log)"
grep -q "A link asks" "$tmp/c3.log" && fail "a bad one went into the script"
echo "ok: another shape refused"
echo "PASS: every step above held"
