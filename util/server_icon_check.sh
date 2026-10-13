#!/bin/bash
# tier: full
# cost: 40s (2026-10-04)
# covers: builtin/network/network.cpp builtin/client_file/client_file.cpp src/impl/fs.cpp
# [FAVICON_SERVER_ICON]: the admin's <user>/apps/<app>/server_icon.png is
# the server's favicon and its icon in the client's list; without it the
# favicon is what it was (the app's or the logo), and a file that is not a
# PNG of 64 KB or less is neither, with a warning.
#   util/server_icon_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "/tmp/buildat_icon.XXXXXX")
P=29771
pid=
cleanup() {
	[ -n "$pid" ] && kill $pid 2>/dev/null
	[ -n "${KEEP_TMP:-}" ] && echo "kept $tmp" || rm -rf "${tmp:?}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
cd "$here"

start() { # log
	start_server "$tmp/$1" "STATUS Listening" 60 $P \
		Build/bin/buildat_server -m apps/hearth -D "$tmp/srv" -l 3 ||
		fail "the server ($tmp/$1)"
	pid=$SERVER_PID
}
stop() { kill $pid; wait $pid 2>/dev/null; pid=; }
icon() { curl -s -m 10 -o "$tmp/$1" "http://127.0.0.1:$P/favicon.ico"; }

start srv1.log
icon default.png
stop
[ -s "$tmp/default.png" ] || fail "no favicon without the file"

python3 - "$tmp/srv/apps/hearth/server_icon.png" <<'PY'
import struct, sys, zlib
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
raw = b"".join(b"\0" + b"\xff\x80\x00" * 4 for _ in range(4))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" +
    chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0)) +
    chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
PY
start srv2.log
icon admin.png
cmp -s "$tmp/admin.png" "$tmp/srv/apps/hearth/server_icon.png" ||
	fail "the favicon is not the admin's server_icon.png"
printf 'wait_log_any 20000 announced files are cached\nquit\n' > "$tmp/cmds"
timeout 60 Build/bin/buildat -o launch_ui=launch_menu -D "$tmp/cl" -w 640x480 -l 3 -o sound_mute=1 \
	-s 127.0.0.1:$P -c @"$tmp/cmds" > "$tmp/cl.log" 2>&1 ||
	fail "the client ($tmp/cl.log): $(grep -a "Command sequence failed" "$tmp/cl.log" | tail -1)"
grep -q "The server's icon: .*server_icon.png" "$tmp/srv2.log" ||
	fail "the list's icon is not the admin's ($tmp/srv2.log)"
stop
echo "ok: the admin's icon is the favicon and the list's"

head -c 70000 /dev/zero | tr '\0' 'x' > "$tmp/srv/apps/hearth/server_icon.png"
start srv3.log
icon bad.png
cmp -s "$tmp/bad.png" "$tmp/default.png" || fail "a bad file changed the favicon"
grep -q "server_icon.png is not a PNG of 64 KB or less" "$tmp/srv3.log" ||
	fail "no warning for a bad file"
echo "PASS: server_icon.png is the favicon and the list's icon; without it, or a bad one, the favicon is as before"
