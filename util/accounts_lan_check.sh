#!/bin/bash
# tier: full
# cost: 2min (2026-10-09)
# covers: builtin/accounts/accounts.cpp builtin/accounts/client_lua/accounts.lua apps/vanilla/main/client_lua/pause.lua
# [ACCOUNTS_LAN]: "Open to LAN" is builtin/accounts' Server window's.
#   1. Floor planner launched from the launcher: its owner opens the Server
#      window, Mine > Open to LAN, and its button; the server listens at
#      the LAN address too and is announced as "floorplanner".
#   2. A raw peer at the LAN address, and one on a server the launcher
#      did not start, ask with accounts:open_lan and are refused.
#   3. A second client finds it under "This network", joins and
#      registers; its Server window has no Open to LAN.
#   4. Vanilla on the bundled minimal game: the pause menu's Open to LAN
#      opens it, announced under the world's name.
# Screenshots in $t (KEEP_TMP=1 keeps it): a_before, a_after, b_window,
# v_after.
#
#   util/accounts_lan_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
t=$(mktemp -d)
pids=
trap 'kill $pids 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here/Build"
client(){ timeout 240 bin/buildat -o launch_ui=launch_menu -w 1024x700 -l 3 -o sound_mute=1 "$@"; }

# ask_lan <host> <port>: a raw peer with no owner token asks to open it
ask_lan(){
	python3 - "$1" "$2" <<'PY'
import socket, struct, sys, time
def packet(t, data):
    return struct.pack("<HBI", t, 0, len(data)) + data
def hello():
    v = b"0.7.0"
    body = struct.pack("<IIQ", 1, 1, len(v)) + v + struct.pack("<IQ", 2, 0)
    return packet(2, b"\1\1\0" + bytes([len(body)]) + body)  # its length a one-byte varint
n = b"accounts:open_lan"
s = socket.create_connection((sys.argv[1], int(sys.argv[2])))
s.sendall(hello() + packet(0, bytes([101, 0]) + len(n).to_bytes(4, "little") + n) +
        packet(101, b""))
# The connection held while the server reads the request
time.sleep(1)
PY
}

# 1
# The last delay keeps the host up while 2 and 3 run; it is killed after 3
cat > "$t/a.cmds" <<C
wait_log 60000 Plan picker:
delay 1000
click Button "Menu..."
wait_log 5000 The plan picker's menu shown
click Button "My account..."
wait_log 5000 server window: the page account
delay 500
click Button "Open to LAN"
wait_log 5000 server window: the page lan
delay 1000
screenshot $t/a_before.png
click Button "Open to LAN" 900 0
wait_log 10000 Open to LAN: Open to the LAN at
delay 500
screenshot $t/a_after.png
# The host held up while 2 and 3 run: a ceiling, as it is killed after 3
delay 180000
quit
C
BUILDAT_FP_NAME=owner client -C "$t/ca" -D "$t/ua" -a app/floorplanner/play \
	-c @"$t/a.cmds" > "$t/a.log" 2>&1 &
apid=$!
pids="$pids $apid"
for _ in $(seq 450); do
	grep -aq "Open to LAN: Open to the LAN at" "$t/a.log" && break
	kill -0 $apid 2>/dev/null ||
		fail "the host's drive ended ($(grep -a "Command sequence failed" "$t/a.log" | tail -1))"
	sleep 0.2
done
at=$(grep -ao "Open to the LAN at [0-9.]*:[0-9]*" "$t/a.log" | head -1 | cut -d' ' -f6)
[ -n "$at" ] || fail "not opened ($(grep -a "Open to LAN\|rror" "$t/a.log" | tail -3))"
grep -aq 'Announced to the LAN as "floorplanner"' "$t/a.log" ||
	fail "not announced as floorplanner"

# 2
ask_lan "${at%:*}" "${at#*:}"
wait_for_log "$t/a.log" "Open to LAN refused" 10 || fail "a peer on the LAN was not refused"
start_server "$t/d.log" "STATUS Listening" 60 auto \
	bin/buildat_server -m ../apps/floorplanner -A 127.0.0.1 -D "$t/ud" -C "$t/cd" ||
	fail "the dedicated server did not start"
pids="$pids $SERVER_PID"
ask_lan 127.0.0.1 "$SERVER_PORT"
wait_for_log "$t/d.log" "Open to LAN refused" 10 || fail "the dedicated server did not refuse"

# 3: the last click is to fail, there being no such button
# The delays of 300 ms: the list drawn again, and a row picked, in the
# frames after the line and the click
cat > "$t/b.cmds" <<C
wait_log_any 30000 Join a Buildat server: shown
click Button "This network"
wait_log_any 10000 This network: 1 heard
delay 300
click Button "floorplanner"
# The click's frames: the row picked before Join is looked for
delay 300
click Button "Join"
wait_log 60000 Plan picker:
delay 1000
click Button "Menu..."
wait_log 5000 The plan picker's menu shown
click Button "My account..."
wait_log 5000 server window: the page account
delay 1000
screenshot $t/b_window.png
click Button "Open to LAN"
quit
C
BUILDAT_FP_NAME=guest BUILDAT_FP_PASSWORD=guestpass12 BUILDAT_FP_CREATE=1 \
	client -C "$t/cb" -D "$t/ub" -a extension/launch_menu/connect \
	-c @"$t/b.cmds" > "$t/b.log" 2>&1
grep -aq "guest joined from ${at%:*}" "$t/a.log" ||
	fail "the second client did not join over the LAN ($(grep -a "Command seq\|click:" "$t/b.log" | tail -3))"
grep -aq 'click: no visible, uncovered Button "Open to LAN"' "$t/b.log" ||
	fail "the second client has Open to LAN"
kill $pids 2>/dev/null; pids=

# 4
cat > "$t/v.cmds" <<C
wait_log 60000 the server put the player at
wait_log 60000 scene, 0 undrawn within 2
keypress Escape
wait_log 5000 pause: the menu shown
click Button "Open to LAN"
wait_log 10000 Open to LAN: Open to the LAN
delay 500
screenshot $t/v_after.png
quit
C
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=lanworld start_server "$t/v.log" \
	"STATUS Listening" 60 auto bin/buildat_server -u launcher=1 -A 127.0.0.1 \
	-m ../apps/vanilla -D "$t/uv" -C "$t/cv" -l 3 ||
	fail "the vanilla server did not start"
pids="$SERVER_PID"
client -C "$t/cvc" -D "$t/uvc" -s 127.0.0.1:"$SERVER_PORT" -u 1 \
	-c @"$t/v.cmds" > "$t/vc.log" 2>&1 ||
	fail "vanilla's drive ($(grep -a "Command sequence failed" "$t/vc.log" | tail -1))"
grep -aq "Open to LAN: listening at" "$t/v.log" ||
	fail "vanilla's pause menu did not open it ($(grep -a "Command seq\|click:" "$t/vc.log" | tail -3))"
grep -aq 'Announced to the LAN as "lanworld"' "$t/v.log" ||
	fail "vanilla not announced as its world ($(grep -a "Announced" "$t/v.log"))"
echo "PASS: opened at $at from the Server window, refused to others, joined over the LAN; vanilla's pause menu opens it as lanworld"
