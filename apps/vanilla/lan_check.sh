#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 30s
# [SECURITY_RUN_1], the user's three: a launcher's game listens on
# 127.0.0.1, its owner is whoever shows the token the launcher started it
# with (BUILDAT_OWNER_TOKEN), and only the owner opens it to the LAN.
# Started here as the launcher starts it; a raw client without the token
# asks for the LAN and is ignored, one with it asks and the server listens
# at the machine's LAN address too, announcing itself there; and it stops
# on SIGTERM after. Prints
# PASS or FAIL.
#
#   apps/vanilla/lan_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/lan_check"
mkdir -p "$out"
cd "$here/Build"
port=$(( 29600 + (RANDOM % 90) ))
token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
BUILDAT_OWNER_TOKEN=$token start_server "$out/srv.log" "STATUS Listening" 60 "$port" \
	bin/buildat_server -m ../apps/vanilla -A 127.0.0.1 -u launcher=1 ||
	{ echo "FAIL: the server did not start ($out/srv.log)"; exit 1; }
srv=$SERVER_PID
trap 'kill -9 $srv 2>/dev/null' EXIT
python3 - "$port" "$token" "$out/srv.log" > "$out/client.log" 2>&1 <<'PY'
import socket, struct, subprocess, sys, time
port, token, srv = int(sys.argv[1]), sys.argv[2].encode(), sys.argv[3]
# Until the server's log has <text> <n> times, up to <secs>
def until(text, n, secs=10):
    t0 = time.time()
    while time.time() - t0 < secs:
        if open(srv, "rb").read().decode("utf-8", "replace").count(text) >= n:
            return True
        time.sleep(0.2)
    return False
def listening():
    lines = subprocess.run(["ss", "-ltn"], capture_output=True,
            text=True).stdout.split("\n")
    return " ".join(l.split()[3] for l in lines[1:]
            if len(l.split()) > 3 and l.split()[3].endswith(":%d" % port))
# [u16 type][u8 flags][u32 size]; the first packet each way is core:hello
# (util/fuzz/proto_fuzz.py's)
def packet(t, data):
    return struct.pack("<HBI", t, 0, len(data)) + data
def hello():
    v = b"0.7.0"
    body = struct.pack("<IIQ", 1, 1, len(v)) + v + \
            struct.pack("<IQ", 2, 0)
    return packet(2, b"\1\1\0" + bytes([len(body)]) + body)  # its length a one-byte varint
def define(t, name):
    n = name.encode()
    return packet(0, bytes([t & 255, t >> 8]) +
            len(n).to_bytes(4, "little") + n)
def peer(send_token, said=None):
    s = socket.create_connection(("127.0.0.1", port))
    out = hello() + define(100, "accounts:owner_token") + define(101, "accounts:open_lan")
    if send_token is not None:
        out += packet(100, send_token)
    s.sendall(out)
    # accounts and vanilla read packets in threads of their own, so the
    # token lands before the ask, as the client's does: its menu asks
    # after the files, round trips after the token. The server says how
    # it took a token; none sent, there is nothing to wait for
    if said:
        until(said, 1)
    s.sendall(packet(101, b""))
    return s
a = peer(None)                                  # no token
b = peer(b"0" * 32, "wrong owner token")        # a wrong one
until("Open to LAN refused", 2)
print("without the owner's token:", listening())
c = peer(token, "is this server's owner")
# Listening at the LAN address too: polled until it is, up to 10 s
t0 = time.time()
while time.time() - t0 < 10 and \
        not [x for x in listening().split() if not x.startswith("127.0.0.1:")]:
    time.sleep(0.2)
print("with it:", listening())

PY
before=$(sed -n 's/^without the owner.s token: //p' "$out/client.log")
after=$(sed -n 's/^with it: //p' "$out/client.log")
# And it stops when asked (a shutdown that deadlocked once, 2026-10-03)
kill $srv 2>/dev/null
stopped=no
for i in $(seq 1 150); do
	kill -0 $srv 2>/dev/null || { stopped=yes; break; }
	sleep 0.2
done
owners=$(grep -ac "is this server's owner" "$out/srv.log")
wrong=$(grep -ac "wrong owner token" "$out/srv.log")
# [ACCOUNTS_LAN] builtin/accounts answers it now, and says whom it refused
refused=$(grep -ac "Open to LAN refused" "$out/srv.log")
# [LAN_DISCOVERY]: opened, it announces itself (util/lan_check.sh hears it)
announced=$(grep -ac "Announced to the LAN as" "$out/srv.log")
echo "listening without the token: $before, with it: $after; owners $owners, wrong tokens $wrong, refused $refused; announced $announced; stopped on SIGTERM: $stopped"
lan=$(echo "$after" | tr ' ' '\n' | grep -v "^127.0.0.1:" | head -1)
if [ "$before" = "127.0.0.1:$port" ] && echo "$after" | grep -q "127.0.0.1:$port" &&
		[ -n "$lan" ] &&
		[ "$owners" = 1 ] && [ "$wrong" = 1 ] && [ "$refused" = 2 ] &&
		[ "$announced" = 1 ] &&
		[ "$stopped" = yes ]; then
	echo PASS
else
	echo "logs in $out"
	echo FAIL
	exit 1
fi
