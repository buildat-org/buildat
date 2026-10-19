#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 38s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# [WATER_LIGHT]: how far the sky's light travels along water in a roofed
# passage. The fixture builds a tunnel with one opening to the sky and a
# water run under it, and reads every node of the run; official diminishes
# through water a level a node, so the far end must be darker than the near
# one and the flowing node must read as the source beside it.
#
#   builtin/luanti/test/water_light.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/water_light"; mkdir -p "$out"
save=buildat_test_water_light
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running"; exit 77
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
# A client is what makes the world around the player load, which is what
# the fixture builds into; it does nothing else here
fifo="$out/cmds.fifo"; rm -f "$fifo"; mkfifo "$fifo"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/water_light.lua" \
	start_server "$out/srv.log" "Mods loaded" 60 29787 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap 'kill -INT "$srv" 2>/dev/null' EXIT
printf 'wait_log 120000 chat: water_light: done\nquit\n' > "$out/cmds.txt"
bin/buildat -s localhost:29787 -w 640x480 -l 3 -c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	fail "the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
python3 - "$out/srv.log" <<'PY'
import re, sys
text = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
rows = [l for l in text.splitlines() if "water_light: first " in l or
		"water_light: second " in l]
if len(rows) < 2:
	print("FAIL: the fixture said %d of its two readings" % len(rows))
	sys.exit(1)
first = rows[-2].split("water_light: first ")[-1]
line = rows[-1].split("water_light: second ")[-1]
if first != line:
	print("FAIL: the light was still moving between the two readings")
	print("  " + first)
	print("  " + line)
	sys.exit(1)
cells = dict(p.split("=", 1) for p in line.split())
print(line)
def sky(name):
	return int(cells[name].split("/")[1])
near, far = sky("water0"), sky("water8")
col = [sky("column%d" % i) for i in range(1, 11)]
air = [sky("air%d" % i) for i in range(11)]
print("the run: near %d, far %d" % (near, far))
print("the column down through water: %s" % col)
print("the same shaft with nothing in it: %s" % air)
falls = near > far
# Official diminishes a level a node, so eight nodes in is eight levels down
steady = all(sky("water%d" % i) >= sky("water%d" % (i + 1)) for i in range(8))
same = True
# The column: water does not propagate the sunlight, so it falls a level a
# node; air does, so the control stays at the top of the range all the way
# down
column = col[0] > col[-1] and all(
		col[i] >= col[i + 1] for i in range(len(col) - 1))
control = all(v == air[0] for v in air)
ok = falls and steady and column and control
print("PASS: the light falls along the run and down the column, and an "
		"empty shaft still does not" if ok else
		"FAIL: falls %s, monotone %s, column %s, control %s" % (
		falls, steady, column, control))
sys.exit(0 if ok else 1)
PY
