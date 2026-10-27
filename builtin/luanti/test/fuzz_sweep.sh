#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: long
# [FUZZ_SWEEP]: the campaign, one fuzz.sh run after another, each run's
# directory kept whole under local/fuzz_sweep/<game>_<seed>_<min>/ and one
# row per run appended to local/fuzz_sweep/table.md in the module plan's
# columns: seed, game, minutes, verdict, worst step and worst frame with
# their phases. The finding column is filled by the reader, not here.
#
#   builtin/luanti/test/fuzz_sweep.sh            # the whole campaign
#   RUNS="mineclone2:4:5 devtest:1:5" builtin/luanti/test/fuzz_sweep.sh
#
# A run is game:seed:minutes. Hours of machine time; never beside another
# buildat_server (fuzz.sh refuses), and the binaries are not rebuilt while
# it runs, or the rows are of different builds.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
sweep="${SWEEP:-$here/local/fuzz_sweep}"
mkdir -p "$sweep"
table="$sweep/table.md"
[ -f "$table" ] || echo "| seed | game | min | verdict | worst step | worst frame | finding |
| --- | --- | --- | --- | --- | --- | --- |" > "$table"

# The campaign, cut to a third on 2026-09-19 (user: "excessive"): seven
# VoxeLibre seeds at five minutes, one at twenty, one seed a game --
# eighty minutes of walk
if [ -z "${RUNS:-}" ]; then
	RUNS=""
	# Seeds 2-8, not 1-7: v7's seed 1 is a sea with sheer mountains in
	# every game, and its drownings are the seed (user, 2026-09-22)
	for s in $(seq 2 8); do RUNS="$RUNS mineclone2:$s:5"; done
	RUNS="$RUNS mineclone2:5:20"
	for g in devtest minetest_game nodecore repixture exile; do
		RUNS="$RUNS $g:5:5"
	done
fi

for run in $RUNS; do
	game=${run%%:*}; rest=${run#*:}; seed=${rest%%:*}; min=${rest#*:}
	out="$sweep/${game}_${seed}_${min}"
	if [ -f "$out/verdict.txt" ]; then
		echo "skipping $run: done" >&2
		continue
	fi
	echo "=== $run $(date '+%H:%M')" >&2
	SEED=$seed MINUTES=$min GAME=$game "$me/fuzz.sh" > "$sweep/run.log" 2>&1
	status=$?
	rm -rf "$out"
	mv "$here/local/fuzz/$seed" "$out"
	cp "$sweep/run.log" "$out/fuzz.log"
	# The verdict: fuzz.sh's exit, its FAIL lines and its warnings
	if [ "$status" -eq 0 ]; then
		if grep -q "^warning:" "$out/fuzz.log"; then verdict=warn; else verdict=ok; fi
	else
		verdict=FAIL; failed="$failed $seed"
	fi
	{ echo "$verdict"; grep "^FAIL:\|^warning:" "$out/fuzz.log"; } > "$out/verdict.txt"
	# The worst step: the server's rate-limited lines carry the phase.
	# Counted from t=90 like fuzz.lua's `over` (the start-up load's spike
	# is accepted), by the wall clock of the t=90 line
	from=$(grep -a -m1 "fuzz: t=90 " "$out/srv.log" | awk '{print $3}')
	step=$(grep -a "a step took" "$out/srv.log" |
		awk -v from="${from:-00:00:00}" '$3 >= from' |
		sed 's/^.*a step took \([0-9.]*\) s, \([^;]*\);.*$/\1 \2/' |
		sort -rn | head -1)
	frame=$(grep "^client frame:" "$out/fuzz.log" | sed 's/^client frame: //')
	what=$(grep "^FAIL:\|^warning:" "$out/fuzz.log" | head -1 | cut -c1-60)
	echo "| $seed | $game | $min | $verdict${what:+ ($what)} | ${step:-<0.25 s} | ${frame:-?} | |" >> "$table"
	tail -1 "$table" >&2
done
if [ -n "${failed:-}" ]; then
	echo "FAIL: seeds$failed failed; each run's verdict is its row in $table"
	exit 1
fi
echo "PASS: the campaign ran; each run's verdict is its row in $table"
