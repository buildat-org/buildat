#!/bin/bash
# tier: full
# cost: ~1.5 min (2026-10-29)
# covers: apps/aitta/main/main.cpp src/client/main.cpp builtin/network/network.cpp
# A release bigger than a network's uploads a minute carry: Aitta names
# its piece (300000 bytes) at upload_begin, refuses past the 30 a minute,
# and `aitta publish` waits and sends again until it is listed. The wait
# is the Aitta's own minute. The launcher's publish page does the same in
# Lua (client/core/aitta/publish.lua's upload).
#
#   util/aitta_upload_rate_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
b="$here/Build/bin/buildat"
t=$(mktemp -d "/tmp/buildat_upload_rate.XXXXXX")
pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9

cd "$here/Build"
start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
pid=$SERVER_PID
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)

"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
printf 'wait_log_any 30000 "id":1,"ok":\nquit\n' > "$t/cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
BUILDAT_AITTA_CODE=$code \
BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}" \
	timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 -s 127.0.0.1:$P \
	-c @"$t/cmds" > "$t/cl.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/cl.log" || fail "the bind did not go through"

# 9.5 MB that does not compress: 32 pieces, 34 requests with begin and end
mkdir -p "$t/app/main"
echo 'int x;' > "$t/app/main/main.cpp"
head -c 9500000 /dev/urandom > "$t/app/big.bin"
printf '{"author": "tester", "name": "big", "version": "1.0.0",
	"engine_api": 2, "license_code": "MIT", "license_media": "CC0-1.0",
	"description": "a check"}\n' > "$t/app/meta.json"
zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack"
out=$(timeout 150 "$b" aitta publish "$zip" 127.0.0.1:$P 2>&1)
echo "$out" | grep -q "listed: tester/big/1.0.0" || fail "not listed: $(echo "$out" | tail -3)"
echo "$out" | grep -q "waiting for the Aitta's limit" ||
	fail "it never waited: the rate or the piece is not what this check assumes"
n=$(echo "$out" | grep -c "waiting for the Aitta's limit")
echo "PASS: a 9.5 MB release in 300000-byte pieces, past the uploads a minute after $n waits, listed"
