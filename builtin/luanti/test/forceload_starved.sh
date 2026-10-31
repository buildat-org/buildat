#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-10-31)
# covers: builtin/worldgen/worldgen.cpp builtin/voxelworld/voxelworld.cpp builtin/luanti/world.h
# [FORCELOAD_STARVED]: a forceloaded block and an emerge_area block far
# from the player are there within FL_LIMIT seconds (20) while the player
# keeps generating. Both used to stay unloaded for minutes behind the
# player's sections: the streamer's budget went to the player's point
# first and worldgen took the section nearest a player. The fixture
# (forceload_starved.lua) moves the player two sections a second, faster
# than anything here generates; worldgen's queue is still at 50 or more
# when the far ones are in, which is what makes it "while". Devtest.
# Prints PASS or FAIL.
#
#   builtin/luanti/test/forceload_starved.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
check_user
here=$(cd "$(dirname "$0")/../../.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
[ -d "$BUILDAT_USER_PATH/shared/vanilla/games/devtest" ] || skip "no devtest"
check_tmp forceload_starved; t=$CHECK_TMP
limit=${FL_LIMIT:-20}
cd "$here/Build"
BUILDAT_LUANTI_SEED=1 BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=buildat_test_forceload_starved \
	BUILDAT_LUANTI_LUA="$here/builtin/luanti/test/forceload_starved.lua" \
	start_server "$t/srv.log" "Mods loaded" 120 auto \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 4 ||
	fail "the server did not start ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
printf 'wait_log 120000 load: the world is in\ndelay 180000\nquit\n' > "$t/cmds.txt"
run_client 60 "$t/cli.log" timeout 300 bin/buildat -s "localhost:$SERVER_PORT" \
	-w 640x360 -l 3 -o sound_mute=1 -c @"$t/cmds.txt" &
CHECK_PIDS+=($!)
wait_for_log "$t/srv.log" "fl: asked" 150 || fail "the player did not join ($t/srv.log, $t/cli.log)"
wait_for_log "$t/srv.log" "fl: the walk stopped" 150 || fail "the walk did not stop ($t/srv.log)"
grep -ao "fl: .*" "$t/srv.log"
python3 - "$t/srv.log" "$limit" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read().splitlines()
limit = float(sys.argv[2])
took, at = {}, {}
for i, l in enumerate(log):
    m = re.search(r"fl: (forceloaded|emerged) block in after ([0-9.]+) s", l)
    if m:
        took[m.group(1)] = float(m.group(2))
        at[m.group(1)] = i
for k in ("forceloaded", "emerged"):
    assert k in took, "the %s block never came in" % k
    assert took[k] <= limit, "the %s block took %.1f s, over %.0f" % (k, took[k], limit)
# The player still had sections waiting when the last far one came in:
# worldgen's queue then, which is the player's backlog (the far ones are
# a handful of it)
last = max(at.values())
queued = [int(m.group(1)) for l in log[:last]
        for m in [re.search(r"Queued section .* queue size: ([0-9]+)", l)] if m]
print("worldgen's queue when the last far block came in: %d" % queued[-1])
assert queued[-1] >= 50, "the player was not generating"
PY
verdict_keep
echo "logs in $t"
[ "$verdict_rc" = 0 ] || fail "the far blocks waited for the player ($t/srv.log)"
echo "PASS: a forceloaded and an emerged block far away came in within $limit s while the player generated"
