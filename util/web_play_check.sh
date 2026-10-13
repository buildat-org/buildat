#!/bin/bash
# tier: full
# cost: 150s (2026-10-04)
# covers: src/client/web/index.html builtin/network/network.cpp util/tls_proxy.py apps/play/** extensions/launch_menu/screens.lua
# [WEB_ID_TRUST] (d), [PLAY_PAGE] (a) and (b): the web client from a fixed
# origin with no game of its own (apps/play serving web/ as any server
# does, its page's server line null: [PLAY_OOTB]) lists a Starport's servers, joins the one behind TLS and
# shows the other as the native client's, and signs in there by the
# Starport's window. A TLS front (util/tls_proxy.py, a self-signed
# certificate the Starport is told to trust) serves the page and Hearth;
# Aitta is listed with no TLS; the Starport has the page's origin in
# web_clients. Headless Firefox opens the page on the launch menu.
# Needs web/ from util/build_web.sh.
#   util/web_play_check.sh [steps.json]   (default: the check's own)
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_webplay.XXXXXX")
SP=29691
AN=29692
AI=29693
PLAYSRV=29696
PLAY=29694
ANTLS=29695
export BUILDAT_CONNECT_PORTS="$SP,$AN,$AI,$ANTLS"
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "${tmp:?}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here"

BUILDAT_LUANTI_LIST=http://127.0.0.1:9 \
	Build/bin/buildat_server -m apps/play -D "$tmp/playsrv" -P $PLAYSRV \
	-l 3 > "$tmp/play.log" 2>&1 &
pids+=($!)
psrv=$!
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
	-addext subjectAltName=IP:127.0.0.1 -keyout "$tmp/key.pem" \
	-out "$tmp/cert.pem" 2> /dev/null || fail "openssl"
python3 util/tls_proxy.py "$tmp/cert.pem" "$tmp/key.pem" \
	"$PLAY:127.0.0.1:$PLAYSRV" "$ANTLS:127.0.0.1:$AN" > "$tmp/proxy.log" 2>&1 &
pids+=($!)
prx=$!
for _ in $(seq 50); do
	grep -q "up" "$tmp/proxy.log" && break
	kill -0 $prx 2>/dev/null || fail "the TLS front ($tmp/proxy.log)"
	sleep 0.2
done
for _ in $(seq 300); do
	page=$(curl -sfk -m 5 "https://127.0.0.1:$PLAY/") && break
	kill -0 $psrv 2>/dev/null || fail "the play server ($tmp/play.log)"
	sleep 0.2
done
grep -q "var server = null;" <<< "$page" ||
	fail "the page does not start on the launch menu ($tmp/play.log)"

# The Starport trusts the check's certificate when it verifies Hearth's
# https address; under shared/, which the confined server reads
mkdir -p "$tmp/sp/shared"
cp "$tmp/cert.pem" "$tmp/sp/shared/check_ca.pem"
BUILDAT_CA_FILE=$tmp/sp/shared/check_ca.pem \
start_server "$tmp/sp.log" "setup code" 60 $SP \
	Build/bin/buildat_server -m apps/starport -D "$tmp/sp" -l 3 ||
	fail "the Starport did not start"
pids+=($SERVER_PID)
code=$(grep -o "setup code [A-Z0-9]*" "$tmp/sp.log" | cut -d' ' -f3)
[ -n "$code" ] || fail "the Starport did not start"
listed() { # app port address
	mkdir -p "$tmp/$1/apps/$1"
	cat > "$tmp/$1/apps/$1/starport.json" <<J
{"starports": ["http://127.0.0.1:$SP"], "name": "Play $1", "ids": "anyone",
 "address": "$3", "kind": "app", "audience": "everyone", "access": "auto",
 "descriptors": {"violence": "none", "chat": "moderated", "ugc": "moderated",
  "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
  "gambling": "no", "personal_data": "no"}}
J
	Build/bin/buildat_server -m apps/$1 -D "$tmp/$1" -P $2 -l 3 \
		> "$tmp/$1.log" 2>&1 &
	pids+=($!)
}
listed hearth $AN "https://127.0.0.1:$ANTLS"
listed aitta $AI ""
for _ in $(seq 300); do
	[ "$(grep -c "verified ok" "$tmp/sp.log")" -ge 2 ] && break
	kill -0 $SERVER_PID 2>/dev/null || fail "the Starport ($tmp/sp.log)"
	sleep 0.2
done
[ "$(grep -c "verified ok" "$tmp/sp.log")" -ge 2 ] ||
	fail "no two verified listings ($tmp/sp.log)"
reqs="{\"cmd\":\"set_settings\",\"settings\":{\"email_confirmation\":false,\"web_clients\":[\"https://127.0.0.1:$PLAY\"]}}
{\"cmd\":\"set_email\",\"email\":\"op@example.org\"}"
for app in hearth aitta; do
	read -r _ _ id _ _ ccode < <(grep -v "^#" "$tmp/$app/apps/$app/starport_claim.txt")
	reqs="$reqs
{\"cmd\":\"claim\",\"listing\":\"$id\",\"code\":\"$ccode\"}"
done
# Until the four requests are answered
printf 'wait_log_any 30000 "id":4,\nquit\n' > "$tmp/cmds.txt"
BUILDAT_SP_NAME=admin BUILDAT_SP_PASSWORD=checkpass BUILDAT_SP_CODE=$code \
	BUILDAT_SP_CREATE=1 BUILDAT_SP_REQS="$reqs" \
	timeout 90 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 3 \
	-s 127.0.0.1:$SP -c @"$tmp/cmds.txt" > "$tmp/sp_admin.log" 2>&1 ||
	fail "the Starport admin ($tmp/sp_admin.log)"
list=$(curl -s -m 10 "localhost:$SP/api/v1/list")
echo "$list" | grep -q "Play hearth" && echo "$list" | grep -q "Play aitta" ||
	fail "the claims ($tmp/sp_admin.log)"
python3 - "$SP" <<'PY' || fail "the ID API"
import json, sys, time, urllib.request
B = "http://127.0.0.1:%s/api/v1/id/" % sys.argv[1]
r = json.loads(urllib.request.urlopen(B + "register", json.dumps(dict(
        name="playid", password="secret1",
        birth_year=time.gmtime().tm_year - 40)).encode()).read())
assert r["ok"], r
PY
setup=$(grep -ao "setup code [A-Z0-9]*" "$tmp/hearth.log" | tail -1 | cut -d' ' -f3)
printf 'wait_log_any 30000 Joined as admin\nquit\n' > "$tmp/cmds_admin.txt"
BUILDAT_HEARTH_NAME=admin BUILDAT_HEARTH_PASSWORD=adminpass1 \
	BUILDAT_HEARTH_CREATE=1 BUILDAT_HEARTH_CODE=$setup timeout 90 \
	Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" -w 800x600 -l 3 -s 127.0.0.1:$AN \
	-c @"$tmp/cmds_admin.txt" > "$tmp/admin.log" 2>&1
grep -v "command: \|wait_log" "$tmp/admin.log" | grep -q "Joined as admin" || fail "the admin's join ($tmp/admin.log)"

# simplified: web_play.json waits for Home, then goes by time between its
# clicks at fixed places; a waitlog for each screen once each has its line
WEB_DRIVE_INSECURE=1 WEB_DRIVE_URL="https://127.0.0.1:$PLAY/" \
	"$here/util/web_drive.sh" firefox hearth \
	"${1:-$here/util/web_play.json}" "$tmp/drive" > "$tmp/drive.txt" 2>&1 ||
	fail "the drive ($tmp/drive.txt, $tmp/drive)"
grep -q "connected (WebSocket)" "$tmp/aitta.log" &&
	fail "the listing with no TLS was joined from the web page"
grep -q "Client .* connected (WebSocket) through" "$tmp/hearth.log" ||
	fail "no join through the TLS front ($tmp/hearth.log)"
grep -aq "Joined as playname" "$tmp/drive/page.log" ||
	fail "the web client did not join by the ID ($tmp/drive/page.log)"
echo "PASS: the fixed-origin page lists the Starport's servers, joins the TLS one and signs in by the Starport's window"
