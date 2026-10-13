#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 45s (this desk, 2026-09-28)
# covers: builtin/voxelworld/** builtin/luanti/lua/bootstrap.lua
# [UNDERGROUND_LIGHT] (3)'s own assertion: **open air over a surface
# reads 15 at noon**, which nothing asserted, and again after the light
# in the box has been worked out.
#
# **What this does and does not catch.** The first reading is the
# assertion and it is real. The second -- after `core.fix_light` over a
# box whose top is under the loaded column, which is the shape
# [SKY_COLUMN_CAVE]'s fault had -- **has not been seen to fail**: run
# with the broken rule put back (`BUILDAT_SKY_COLUMN=0`, removed since),
# this world still read 15 across the board. devtest's world is small and
# flat and its region top is near the player, so the relight finds a sky
# source either way. Reproducing the fault wants a played VoxeLibre
# world, which is [SKY_COLUMN_CAVE]'s own drive and not a quick check.
# So the fix_light half is kept for the day it does catch something and
# is not counted as cover.
#
#   builtin/luanti/test/surface_light.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/surface_light"; mkdir -p "$out"
save=buildat_test_surface_light
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running" >&2; exit 77
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-devtest}" BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$me/surface_light.lua" \
	start_server "$out/srv.log" "Mods loaded" 60 29788 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla \
	-l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap 'kill -INT "$srv" 2>/dev/null' EXIT
# A client is what makes the world around the player load, which is what
# the fixture reads; it does nothing else here
printf 'wait_log 60000 chat: surface_light: done\nquit\n' \
		> "$out/cmds.txt"
bin/buildat -s localhost:29788 -w 640x480 -l 3 -c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	fail "the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"
kill -INT "$srv" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
python3 - "$out/srv.log" <<'PY'
import sys
text = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
def row(tag):
	rows = [l for l in text.splitlines() if "surface_light: " + tag + " " in l]
	return rows[-1].split("surface_light: " + tag + " ")[-1] if rows else None
before, after = row("before"), row("after")
if before is None or after is None:
	print("FAIL: the fixture did not say both readings")
	sys.exit(1)
def cells(line):
	out = {}
	for p in line.split():
		k, v = p.split("=", 1)
		out[k] = v
	return out
b, a = cells(before), cells(after)
print("before " + before)
print("after  " + after)
named = [k for k in sorted(b) if b[k] != "none"]
if len(named) < 5:
	print("FAIL: only %d of the %d columns found a surface; the world "
			"around the player did not load" % (len(named), len(b)))
	sys.exit(1)
bad_b = [k for k in named if b[k] != "15"]
bad_a = [k for k in named if a.get(k) != "15"]
print("%d columns read, %d not 15 before, %d not 15 after"
		% (len(named), len(bad_b), len(bad_a)))
if bad_b:
	print("FAIL: open air over the surface does not read 15 at noon: " +
			" ".join("%s=%s" % (k, b[k]) for k in bad_b))
	sys.exit(1)
if bad_a:
	print("FAIL: working the light out again took the surface off 15: " +
			" ".join("%s=%s" % (k, a.get(k)) for k in bad_a))
	sys.exit(1)
print("PASS: open air over the surface reads 15 at noon, and a fix_light "
		"over the box leaves it there")
sys.exit(0)
PY
