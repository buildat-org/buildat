#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~5 min (2026-10-11)
# covers: builtin/voxelworld/voxelworld.cpp builtin/voxelworld/lighting.h builtin/luanti/lua_bindings.h
# [WIELDLIGHT_STALE]: VoxeLibre's wielded torch walked back and forth in
# a sealed tunnel underground at night, 118 voxels each way along chunks'
# and sections' edges, facing backwards, glowstone set and dug beside it,
# leaves the lamp light where core.fix_light() puts it:
# wieldlight_stale.lua says how many voxels of the tunnel, its walls
# included, differ, with the torch put away and again with the glowstone
# dug; and the client's lamp light around the player (scan_volume's
# "lamp") is the server's. The client's screenshots along the walk are
# kept for a person to look at, in $WS_SHOTS (default
# /tmp/wieldlight_stale_shots/<time>). The first run, a 22-voxel room in
# the air, passed on 2026-10-11, the user's glitch not reproduced.
# Needs mineclone2 in the desk's games.
#   builtin/luanti/test/wieldlight_stale.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || { echo "SKIP: no mineclone2"; exit 0; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp wieldlight_stale; t=$CHECK_TMP
trap check_cleanup EXIT
mkdir -p "$t/srv/shared/vanilla/games"
cp -r "$G" "$t/srv/shared/vanilla/games/"
{ echo 'core.settings:set("time_speed", "0")'; cat "$me/wieldlight_stale.lua"; } \
	> "$t/srv/shared/fixture.lua"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=ws \
BUILDAT_LUANTI_LUA="$t/srv/shared/fixture.lua" start_server "$t/srv.log" \
	"STATUS Listening" 120 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
shots=${WS_SHOTS:-/tmp/wieldlight_stale_shots/$(date +%Y%m%d_%H%M%S)}
mkdir -p "$shots"
# The first shot after the world's start and the tunnel's emerge; the
# others ~3 s apart (59 steps of 0.05 s), the last two 10 and 5 s. The
# 100 ms after a shot's line is the moved player drawn; the 2 s after
# "ws: done" is the dug glowstone's light reaching the client's voxels.
{
	first=180000
	for n in $(seq 59 59 708) away dug; do
		echo "wait_log $first chat: ws: shot $n"; echo "delay 100"
		echo "screenshot $shots/shot_$n.png"
		first=30000
	done
	# "ws: done" comes in the tick of "shot dug", before the shot is taken
	echo "wait_log_any 10000 chat: ws: done"; echo "delay 2000"
	# the scan is written before the event command returns
	echo "event scan_volume 8 ws lamp"
	echo quit
} > "$t/cmds"
run_client 60 "$t/client.log" timeout 300 "$here/Build/bin/buildat" -C "$t/nc" \
	-D "$t/nu" -s "127.0.0.1:$SERVER_PORT" -w 960x540 -l 3 -o sound_mute=1 \
	-c @"$t/cmds" || fail "the drive ($t/client.log)"
grep -a "ws: " "$t/srv.log" | grep -v "ws: lamp" | sed 's/.*ws: /ws: /'
grep -aq "ws: done" "$t/srv.log" || fail "the run never got to its end ($t/srv.log)"
bad=$(grep -a "ws: the .*: [1-9][0-9]* voxels differ" "$t/srv.log")
[ -z "$bad" ] || fail "the light differs from fix_light's ($t/srv.log)"
# **And the client has it**: its lamp light around the player against the
# server's, what the mesher draws from
python3 - "$t/srv.log" "$t/client.log" <<'PY' || fail "the client's light ($t/client.log)"
import re, sys
def rows(path, pat):
    out = {}
    for l in open(path, errors="replace"):
        m = re.search(pat + r" y=(-?\d+) z=(-?\d+) x=(-?\d+): (.*)", l)
        if m:
            out[m.group(1, 2, 3)] = m.group(4).split()
    return out
srv = rows(sys.argv[1], r"ws: lamp")
cli = rows(sys.argv[2], r"scan ws: light")
assert srv and cli, "no rows: server %d, client %d" % (len(srv), len(cli))
n, first = 0, None
for k, a in srv.items():
    b = cli.get(k)
    assert b, "the client has no row %s" % (k,)
    for i, (u, v) in enumerate(zip(a, b)):
        if v != "-" and u != v:
            n += 1
            first = first or "y=%s z=%s x=%d: server %s, client %s" % (k[0], k[1], int(k[2]) + i, u, v)
print("the client's lamp light: %d of %d voxels differ%s" % (n, 17 ** 3, first and ", first " + first or ""))
sys.exit(1 if n else 0)
PY
echo "the screenshots: $(ls "$shots" | wc -l) in $shots"
echo "PASS: the wielded torch walked and glowstone set and dug leave the light as fix_light makes it, and the client has it"
