#!/bin/bash
# apps/sample_ui: the client sandbox's UI, and the procedural texture and
# sound paths ([LAUNCH_WORLD]'s whitelist bill). The game's client_lua asserts as it
# loads, so what this does is run it and read whether the assert line came
# out; a whitelist entry that goes missing raises in the sandbox instead.
#
#   apps/sample_ui/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/sample_ui"; mkdir -p "$out"
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
bin/buildat_server -m ../apps/sample_ui -P 29793 -l 3 > "$out/srv.log" 2>&1 &
for i in $(seq 1 60); do
	grep -q "Server::start\|Mods loaded" "$out/srv.log" 2>/dev/null && break
	sleep 1
done
srv=$(check_pgrep buildat_server | head -1)
[ -n "$srv" ] || { echo "the server did not come up" >&2; exit 1; }
trap 'kill -INT "$srv" 2>/dev/null' EXIT
{ echo "delay 4000"; echo "screenshot $out/sample_ui.png"; echo "delay 500"
	echo "quit"; } > "$out/cmds.txt"
bin/buildat -o launch_ui=launch_menu -s localhost:29793 -w 640x480 -l 3 -c @"$out/cmds.txt" > "$out/cli.log" 2>&1
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
for what in texture sound; do
	if grep -aq "procedural $what ok" "$out/cli.log"; then
		grep -a "procedural $what ok" "$out/cli.log" | sed 's/.*sample_ui: //'
	else
		echo "FAIL: the procedural $what check did not run"
		grep -aiE "error|assert|raised" "$out/cli.log" | tail -5
		exit 1
	fi
done
# And it is on screen: the swatch's corner is not the background
python3 - "$out/sample_ui.png" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
# The swatch is at 8,8 and carries a red-green ramp, so two points in it
# differ from each other and from the background. How big it is drawn is
# the UI's business, not this check's, so both points sit near its corner.
a = im.getpixel((12, 12))
b = im.getpixel((26, 26))
bg = im.getpixel((300, 400))
print("the swatch reads %s and %s, the background %s" % (a, b, bg))
ok = a != bg and b != bg and a != b and a[2] > 20 and b[2] > 20
print("PASS: a texture the program built itself is drawn" if ok
		else "FAIL: the swatch is not on screen")
sys.exit(0 if ok else 1)
PY
