#!/bin/bash
# tier: quick
# cost: ~25 s (2026-10-07)
# covers: src/impl/tcpsocket.cpp src/server/config.cpp
# [DUAL_STACK]: a server on the default address answers on ::1 and on
# 127.0.0.1, and an IPv4 peer reads as plain 127.0.0.1, not
# ::ffff:127.0.0.1. Skips where the machine has no IPv6 loopback.
#   util/dual_stack_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
cd "$(dirname "$0")/.."
ip -6 addr show lo 2>/dev/null | grep -q "::1" || { echo "SKIP: no ::1"; exit 0; }
t=$(mktemp -d)
trap 'kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; tail -20 "$t/log"; exit 1; }
start_server "$t/log" "setup code" 120 ${PORT:-auto} \
	Build/bin/buildat_server -m apps/floorplanner -D "$t" -l 3 || fail "the server"
P=$SERVER_PORT
grep -q "Listening at any:$P" "$t/log" || fail "not listening at any:$P"
curl -s -4 -m 5 -o /dev/null "http://127.0.0.1:$P/" || fail "no HTTP answer on 127.0.0.1"
curl -s -6 -m 5 -o /dev/null "http://[::1]:$P/" || fail "no HTTP answer on ::1"
# A client each way: "localhost" is ::1 first where getaddrinfo says so,
# and the client takes the first that answers
printf 'wait_log_any 20000 Connect succeeded\nquit\n' > "$t/c"
for a in 127.0.0.1 localhost; do
	timeout 60 Build/bin/buildat -D "$t/cl" -w 640x480 -l 3 -o sound_mute=1 \
		-s $a:$P -c @"$t/c" > "$t/cl_$a.log" 2>&1
done
wait_for_log "$t/log" "from 127.0.0.1 connected" 5 || fail "the IPv4 peer is not 127.0.0.1"
if getent ahosts localhost | head -1 | grep -q "^::1"; then
	wait_for_log "$t/log" "from ::1 connected" 5 || fail "the IPv6 peer is not ::1"
fi
grep -q "self-check failed" "$t/log" && fail "ipv6_text's self-check"
echo "PASS: the default address takes IPv6 and IPv4, each peer by its plain address"
