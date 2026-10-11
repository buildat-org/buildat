#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~4 min (2026-10-11)
# covers: builtin/voxelworld/voxelworld.cpp builtin/voxelworld/lighting.h builtin/luanti/lua_bindings.h
# [WIELDLIGHT_STALE]: VoxeLibre's wielded torch walked back and forth in
# a sealed room at night, glowstone set and dug beside it, leaves the lamp
# light where core.fix_light() puts it: wieldlight_stale.lua says how many
# voxels of the room, its walls included, differ, with the torch put away
# and again with the glowstone dug; and the client's lamp light around
# the player (scan_volume's "lamp") is the server's. It passed on
# 2026-10-11, the user's glitch not reproduced this way.
# Needs mineclone2 in the desk's games.
#   builtin/luanti/test/wieldlight_stale.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
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
{ echo "wait_log 300000 chat: ws: done"; echo "delay 3000"
	echo "event scan_volume 8 ws lamp"; echo "delay 3000"; echo quit; } > "$t/cmds"
run_client 60 "$t/client.log" timeout 300 "$here/Build/bin/buildat" -C "$t/nc" \
	-D "$t/nu" -s "127.0.0.1:$SERVER_PORT" -w 640x360 -l 3 -o sound_mute=1 \
	-c @"$t/cmds"
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
echo "PASS: the wielded torch walked and glowstone set and dug leave the light as fix_light makes it, and the client has it"
