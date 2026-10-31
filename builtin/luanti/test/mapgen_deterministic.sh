#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-10-31)
# covers: builtin/luanti_mapgen/**
# [MCL_GEN_NONDETERMINISTIC]: the vendored mapgen makes the same chunk out
# of the same seed every time. A box of VoxeLibre (seed 5) is generated
# twice, each in a fresh save, with no player (mapgen_deterministic.lua);
# every chunk luanti_mapgen made logs a hash of what it came out as, and a
# chunk both runs made has the same hash in both, and the same each time
# one run made it again. Upstream Luanti rolls a schematic decoration's
# probabilities (a tree's leaves, VoxeLibre's fallen logs) from the
# process's one random generator, which made 82 of 352 chunks differ
# between two runs and 21 differ within one.
#
# Only the mapgen: what VoxeLibre's on_generated adds reads the chunks
# around it, which depends on which of them are in yet; see CLOUD_TASKS.md.
# Prints PASS or FAIL.
#
#   builtin/luanti/test/mapgen_deterministic.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
check_user
here=$(cd "$(dirname "$0")/../../.." && pwd)
[ -d "$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2" ] || skip "no VoxeLibre (mineclone2)"
check_tmp mapgen_deterministic; t=$CHECK_TMP
saves="$BUILDAT_USER_PATH/apps/vanilla/saves"
cd "$here/Build"
for run in 1 2; do
	save=buildat_test_mapgen_deterministic_$run
	rm -rf "${saves:?}/$save"
	mkdir -p "$saves/$save/luanti"
	printf 'fixed_map_seed = 5\nmax_forceloaded_blocks = 1000\n' \
		> "$saves/$save/luanti/world.mt"
	BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=$save \
		BUILDAT_LUANTI_LUA="$here/builtin/luanti/test/mapgen_deterministic.lua" \
		start_server "$t/srv$run.log" "Mods loaded" 120 auto \
		bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 4 ||
		fail "the server did not start ($t/srv$run.log)"
	CHECK_PIDS+=($SERVER_PID)
	wait_for_log "$t/srv$run.log" "det: the box is in" 180 ||
		fail "run $run: the box did not come in ($t/srv$run.log)"
	kill "$SERVER_PID"
	for i in $(seq 50); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.2; done
	rm -rf "${saves:?}/$save"
done
python3 - "$t/srv1.log" "$t/srv2.log" <<'PY'
import re, sys
runs = []
for path in sys.argv[1:]:
    made = {}
    for l in open(path, errors="replace"):
        m = re.search(r"Chunk (\(.*\)) made: hash (\w+)", l)
        if m:
            made.setdefault(m.group(1), set()).add(m.group(2))
    runs.append(made)
for i, made in enumerate(runs):
    again = [k for k, v in made.items() if len(v) > 1]
    assert not again, "run %d made %d chunks differently each time: %s" % (
            i + 1, len(again), again[:5])
both = sorted(set(runs[0]) & set(runs[1]))
assert len(both) >= 27, "only %d chunks made in both runs" % len(both)
differ = [k for k in both if runs[0][k] != runs[1][k]]
print("chunks made in both runs: %d, differing: %d" % (len(both), len(differ)))
assert not differ, "differing: %s" % differ[:8]
PY
verdict_keep
echo "logs in $t"
[ "$verdict_rc" = 0 ] || fail "the mapgen made a chunk differently ($t)"
echo "PASS: every chunk the two runs made came out the same"
