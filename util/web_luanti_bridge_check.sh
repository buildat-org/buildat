#!/bin/bash
# tier: broken
# broken: back to full; the drive (dev); the Luanti server (the branch)
#   (local/runs/dev_baseline)
# cost: 120s (2026-10-04)
# covers: apps/play/** builtin/network/network.cpp client/extensions/network/init.lua
# [PLAY_PAGE] (c): the web client on apps/play's page reaches a Luanti
# server through the bridge. A Luanti server (~/projects/luanti, devtest)
# on 127.0.0.1, a served Luanti list (BUILDAT_LUANTI_LIST) without it,
# apps/play serving web/; headless Firefox opens the page on 127.0.0.1,
# picks "Join a Luanti server", connects and logs in: a local page
# reaches this machine's servers ([WEB_LUANTI_JOIN]). A page asked for by
# a public name is refused an unlisted address, and a listed one that is
# not public, with the reason in the close frame.
# Needs web/ from util/build_web.sh.
#   util/web_luanti_bridge_check.sh [steps.json]   (default: the check's own)
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_bridge.XXXXXX")
PLAY=29711
LIST=29713
LUANTI=30041
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti}
pids=()
cleanup() {
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "${tmp:?}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here"

mkdir -p "$tmp/world"
printf 'gameid = devtest\nbackend = sqlite3\nserver_announce = false\n' \
	> "$tmp/world/world.mt"
printf 'mute_sound = true\n' > "$tmp/luanti.conf"
"$bin" --server --world "$tmp/world" --port $LUANTI --config "$tmp/luanti.conf" \
	> "$tmp/luanti.log" 2>&1 &
pids+=($!)
mkdir -p "$tmp/list"
printf '{"list": [{"address": "127.0.0.1", "port": %d, "name": "Listed"}]}' \
	$((LUANTI + 1)) > "$tmp/list/list"
python3 -m http.server -b 127.0.0.1 -d "$tmp/list" $LIST > "$tmp/list.log" 2>&1 &
pids+=($!)
BUILDAT_CONNECT_PORTS=$LIST BUILDAT_LUANTI_LIST=http://127.0.0.1:$LIST \
start_server "$tmp/play.log" "Luanti's list: 1" 120 $PLAY \
	Build/bin/buildat_server -m apps/play -D "$tmp/playsrv" -l 3 ||
	fail "the list ($tmp/play.log)"
pids+=($SERVER_PID)
grep -q "Server for gameid" "$tmp/luanti.log" || fail "the Luanti server ($tmp/luanti.log)"

WEB_DRIVE_URL="http://127.0.0.1:$PLAY/" "$here/util/web_drive.sh" firefox play \
	"${1:-$here/util/web_luanti_bridge.json}" "$tmp/drive" > "$tmp/drive.txt" 2>&1 ||
	fail "the drive ($tmp/drive.txt, $tmp/drive)"
grep -aq "Logged in" "$tmp/drive/page.log" ||
	fail "no login through the bridge ($tmp/drive/page.log, $tmp/play.log)"
# As a public page's visitor's would, through the trusted proxy
# (loopback): ws <to> <host>. Prints the close frame's reason, or "open"
ws() {
	python3 -c '
import socket, sys
c = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
h = sys.argv[3]
c.sendall(("GET /luanti?to=%s HTTP/1.1\r\nHost: %s\r\n"
    "X-Forwarded-For: 203.0.113.5\r\n"
    "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    "Origin: http://%s\r\n\r\n" % (sys.argv[2], h, h)).encode())
c.settimeout(3)
d = b""
try:
    while True:
        b = c.recv(4096)
        if not b: break
        d += b
except socket.timeout:
    pass
f = d.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in d else b""
print(f[4:2 + f[1]].decode() if f[:1] == b"\x88" else "open")
' $PLAY "$1" "$2"
}
# Listed, but this machine's: a public page reaches public addresses
# only ([SECURITY_RUN_3]), so a listed one is past the list check and
# stopped at the next
listed=$(ws 127.0.0.1:$((LUANTI + 1)) play.example)
[ "$listed" = "not a public address" ] ||
	fail "a listed private address: $listed ($tmp/play.log)"
refused=$(ws 127.0.0.1:$LUANTI play.example)
grep -q "not on Luanti's list (127.0.0.1:$LUANTI)" "$tmp/play.log" ||
	fail "a public page reached this machine's server ($tmp/play.log)"
# A Host claiming the page is local does not make its visitor so
forged=$(ws 127.0.0.1:$LUANTI 127.0.0.1:$PLAY)
case "$forged" in *"public list"*) ;; *) fail "a forged local Host: $forged";; esac
case "$refused" in *"public list"*) ;; *) fail "the refusal said: $refused";; esac
echo "PASS: a local page reaches this machine's Luanti server through the bridge; a public one the listed servers only, told why otherwise"
