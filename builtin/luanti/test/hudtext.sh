#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# ci
# cost: ~15s (estimated from a run's log, 2026-10-13; local/run_all/costs corrects it per machine)
# [UI_PARITY]: a HUD text element's size.X multiplies the font, as Luanti's
# hud.cpp does it (`font_size *= e->size.X`). The fixture adds the same word
# at size 1 and size 3 and the scan measures what was drawn.
#
#   builtin/luanti/test/hudtext.sh
#
# The fixture says in the chat when its elements are added, which is
# the client's own log; the second after it is them drawn in the frames
# after the packets.
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/hudtext"; mkdir -p "$out"
save=buildat_test_hudtext
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running"; exit 77
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/hudtext.lua" \
	start_server "$out/srv.log" "Mods loaded" 60 29791 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap 'kill -INT "$srv" 2>/dev/null' EXIT
{ echo "wait_log 60000 chat: hud text check: the elements added"
	echo "delay 1000"
	echo "event scan"
	echo "quit"; } > "$out/cmds.txt"
# A run that has stopped logging is taken down rather than waited out
run_client 60 "$out/cli.log" bin/buildat -s localhost:29791 -w 1280x720 \
	-l 3 -c @"$out/cmds.txt" ||
	fail "the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
python3 - "$out/cli.log" <<'PY'
import re, sys
log = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
found = {}
for m in re.finditer(r'hud text "(sized\d)" size "([^"]*)" at (-?\d+),(-?\d+) '
		r'size (\d+)x(\d+)', log):
	found[m.group(1)] = (int(m.group(5)), int(m.group(6)), m.group(2))
if len(found) < 2:
	print("FAIL: the scan found %s" % sorted(found))
	sys.exit(1)
one, three = found["sized1"], found["sized3"]
print("size %r drew %dx%d, size %r drew %dx%d" % (one[2], one[0], one[1],
		three[2], three[0], three[1]))
ratio = three[1] / float(one[1])
print("three times the size is %.2f times the height" % ratio)
ok = 2.5 < ratio < 3.5
print("PASS: a HUD text element's size multiplies the font" if ok else
		"FAIL: size.X is not what the font is scaled by")
sys.exit(0 if ok else 1)
PY
