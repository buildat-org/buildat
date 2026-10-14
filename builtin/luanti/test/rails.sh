#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-10-11)
# covers: builtin/luanti/lua/entity.lua builtin/luanti/lua/raycast.lua builtin/luanti/registry.h builtin/luanti/client_lua/client.lua apps/vanilla/main/client_lua/init.lua
# [VL_RAIL_BOXES]: vanilla on VoxeLibre, rails.lua's stage, the player
# with interact and shout only:
#   1. rails walked along z, across, along x both ways, off the tee, up a
#      slope and sideways: each walk gets as far as it should, and the
#      server puts the player back nowhere ("is held down");
#   2. the crosshair down on a rail's plate points at the rail, and level
#      over a rail on a pillar at the wall behind it;
#   3. the frame on a slab, a torch and a rail: local/rails/slab.png,
#      torch.png, rail.png, to be looked at.
#
#   builtin/luanti/test/rails.sh
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
. "$me/../../../util/check_lib.sh"
out="$here/local/rails"
mkdir -p "$out"
rm -f "$out"/*.png
save=buildat_test_rails
cd "$here/Build"
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
mkdir -p "$BUILDAT_USER_PATH/apps/vanilla/saves/$save/luanti"
# The slope's far end drops back to the floor
echo "enable_damage = false" > "$BUILDAT_USER_PATH/apps/vanilla/saves/$save/luanti/world.mt"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" BUILDAT_LUANTI_SEED=5 \
	BUILDAT_LUANTI_LUA="$me/rails.lua" \
	start_server "$out/srv.log" "Mods loaded" 400 auto \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
	fail "the server did not start ($out/srv.log)"
CHECK_PIDS+=($SERVER_PID)
trap check_cleanup EXIT
phase(){ printf 'keypress T\ndelay 800\ntext rails %s\nkeypress Return\nwait_log 30000 chat: rails: %s ready\ndelay 1500\n' "$1" "$1"; }
walk(){ printf 'keydown %s\ndelay %s\nkeyup %s\ndelay 300\n' "$1" "$2" "$1"; }
{
	echo "wait_log 120000 load: the world is in"
	echo "wait_log 60000 chat: rails: the stage is laid"
	phase along_z; walk W 1500
	phase across; walk W 1500
	phase along_x; walk W 1500
	phase back_x; walk W 1500
	phase off; walk W 1000; walk D 1500
	phase slope; walk W 2000
	phase side; walk W 1000; walk A 1000; walk D 1000
	phase frames
	for s in "slab -1 -1.3 2.5" "torch 0 -1.2 2.5" "rail 1 -1.55 2.5"; do
		set -- $s
		printf 'look_dir %s %s %s\ndelay 1200\nevent scan 4 %s\nscreenshot %s\n' "$2" "$3" "$4" "$1" "$out/$1.png"
	done
	phase over
	printf 'look_dir 0 0 1\ndelay 1200\nevent scan 4 over\nscreenshot %s\n' "$out/over.png"
	phase done
	echo quit
} > "$out/cmds.txt"
run_client 60 "$out/cli.log" timeout 300 bin/buildat -s "localhost:$SERVER_PORT" \
	-w 800x450 -o sound_mute=1 -l 3 -c @"$out/cmds.txt"
grep -a "rails: node" "$out/srv.log" | sed 's/.*rails: //'
held=$(grep -ac "is held down" "$out/srv.log")
python3 - "$out" <<'PY' || fail "the rails ($out/srv.log, $out/cli.log)"
import re, sys
out = sys.argv[1]
srv = open(out + "/srv.log", errors="replace").read()
ends = {m.group(1): tuple(float(v) for v in m.groups()[1:])
        for m in re.finditer(r"rails: (\w+) ended at ([-\d.]+),([-\d.]+),([-\d.]+)", srv)}
# Where each walk starts (rails.lua's PHASES) and how far it has to get,
# by axis: W at about 4.3 nodes a second
want = {
    "along_z": ((0, 199.5, -2), 2, 4),
    "across": ((-2, 199.5, 3), 0, 4),
    "along_x": ((-3, 199.5, 8), 0, 4),
    "back_x": ((4, 199.5, 8), 0, -4),
    "off": ((0, 199.6, 8), 2, 2.5),
    "slope": ((-6, 199.5, -2), 2, 6),
    "side": ((-1, 199.6, 8), 0, 2),
}
bad = []
for phase, (start, axis, far) in want.items():
    end = ends.get(phase)
    if end is None:
        bad.append(phase + ": no end")
        continue
    moved = end[axis] - start[axis]
    print("%s: from %s to %s, %.1f along %s" % (phase, start, end, moved, "xyz"[axis]))
    if moved * far < far * far:
        bad.append("%s: %.1f, wanted %s" % (phase, moved, far))
# Up the slope onto the rails on the step
if ends.get("slope") and ends["slope"][1] < 200.4:
    bad.append("slope: ended at y %.2f, not on the step" % ends["slope"][1])
cli = open(out + "/cli.log", errors="replace").read()
for label, want_hit in (("rail", "mcl_minecarts:rail_v2 at 6,200,2"),
                        ("over", "mcl_core:stone at 8,201,4")):
    m = re.search(r"scan %s: crosshair (.*)" % label, cli)
    got = m.group(1).strip() if m else "no scan"
    print("crosshair %s: %s" % (label, got))
    if not got.startswith(want_hit):
        bad.append("crosshair %s: %s, wanted %s" % (label, got, want_hit))
assert not bad, "; ".join(bad)
PY
[ "$held" = 0 ] || fail "the server put the player back $held times ($out/srv.log)"
echo "PASS: rails walked along, across and off with nothing putting the player back; the crosshair on a rail's plate and over one; frames in $out"
