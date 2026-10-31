#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: long
# The verdict of a run, sourced by fuzz.sh and drive.sh so that a driven
# run reports an error or a slow step or frame in the fuzz's words
# ([SCAN_DRIVE]). Expects: out (the run's directory with srv.log and
# cli.log), SEED, MINUTES, hung (1 if the client had to be killed), limit
# (the seconds waited for it), cli_status. Sets status; the caller exits
# with it.
# Each line names the fault the plan lists it for; the fixture's own
# FAILED line carries its reason.
status=0
say() { echo "FAIL: $*" >&2; status=1; }
# **A slow frame or step while the process waited for a CPU is the
# machine's** ([FUZZ_FRAME_PEAK], 2026-10-31): the share of the SPAN
# seconds before a log time (HH:MM:SS.mmm) that a main thread spent
# runnable and not running, from fuzz.sh's cpu.log (column 3 the
# client's wait, 6 the server's); empty without one. At load 13-17 on
# this desk's 16 threads the client's main thread waited 50-150 ms of
# every 120, its frames stretched to 0.84 s and a server step to 2 s;
# a run's 5 s windows read 0.01-0.03 at the median, 0.16-0.41 at p90,
# 0.39-0.57 at the worst. A frame the game made slow is running, not
# waiting, so the share stays low and the fault stands.
# simplified: a run crossing midnight reads its windows wrong
CPU_WAIT_MAX=0.25
cpu_wait() # <column> <time> <span>
{
	[ -s "$out/cpu.log" ] || return 0
	awk -v col="$1" -v at="$2" -v span="$3" '
		function s(x, a) { split(x, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
		BEGIN { e = s(at) }
		NF >= col { t = s($1); if (t >= e - span && t <= e) {
			if (!n++) { t0 = t; w0 = $col } tl = t; wl = $col } }
		END { if (n > 1 && tl > t0) printf "%.2f", (wl - w0) / 1e9 / (tl - t0) }' \
		"$out/cpu.log"
}
machines() # <share>: whether it is over CPU_WAIT_MAX
{
	[ -n "$1" ] && awk -v w="$1" -v m="$CPU_WAIT_MAX" 'BEGIN {exit !(w >= m)}'
}
while read -r l; do
	[ -n "$l" ] || continue
	why=${l#*fuzz: }
	w=""
	case "$why" in
	"FAILED a step took"*) w=$(cpu_wait 6 "$(echo "$l" | awk '{print $3}')" 5) ;;
	esac
	if machines "$w"; then
		echo "note: $why, the server waiting for a CPU $w of the 5 s before it: the machine's, not a verdict" >&2
	else
		echo "FAIL: $why" >&2
		status=1
	fi
done <<< "$(grep -a "fuzz: FAILED" "$out/srv.log")"
# The world not settling in the start wait ([START_WAIT]) is a verdict
grep -a 'wait_log: ".*" not seen' "$out/cli.log" | grep -a "the world is in" | head -1 | sed 's/.*wait_log: /FAIL: the world did not come in: /' >&2
grep -aq 'wait_log: "load: the world is in" not seen' "$out/cli.log" && status=1
grep -a " E " "$out/srv.log" | grep -av "fuzz:" | head -5 | sed 's/^/FAIL: server error: /' >&2
grep -aq " E " "$out/srv.log" && status=1
grep -aq "not held" "$out/srv.log" "$out/cli.log" && say "a held key read as not held ([HELD_KEY_FLAKE])"
grep -aq "input focus lost" "$out/cli.log" && say "the client lost input focus ([MOUSE_FOCUS_LOST])"
grep -aq "Lua runtime error\|Crash:" "$out/cli.log" && say "the client crashed or hit a Lua error"
# A command that failed ends the client early with its exit at 0, so the
# reason is taken from the log (seed 1's look after a respawn, 2026-09-19)
grep -aq "Command sequence failed" "$out/cli.log" &&
	say "$(grep -a "Command sequence failed" "$out/cli.log" | head -1 | sed 's/^.*Command sequence failed: //')"
if [ "$hung" -eq 1 ]; then
	say "the client did not exit $((limit - MINUTES * 60)) s after its walk ([QUIT_HANG])"
else
	[ "$cli_status" -eq 0 ] || say "the client exited $cli_status"
fi
# The client's frame, from the launcher's rate-limited lines ([FRAME_PEAK]):
# the worst frame of every five seconds and the phase that set it, with the
# first such line skipped as the load's. Warn over 50 ms, fail over 250 ms,
# first-cut numbers argued with in doc/plan/performance_plan.md.
# Counted from t=90 like the step ([STEP_SLICE]): the load's mesh
# backlog (seed 3's rerun, 0.84 s in mesh with 3951 chunks queued at
# t=20) is the load's, and the ceiling is about play. By the wall clock
# of the fixture's t=90 line, the two logs sharing a clock.
from=$(grep -a -m1 "fuzz: t=90 " "$out/srv.log" | awk '{print $3}')
frames=$(grep -a "frame peak" "$out/cli.log" | tail -n +2 |
	awk -v from="${from:-00:00:00}" '$3 >= from' |
	sed 's/^\S* \S* \(\S*\) .*frame peak \([0-9.]*\) s in \(.*\), held.*$/\2 \1 \3/' |
	sort -rn)
# "0.308 rest", the time between left out
worst=$(echo "$frames" | head -1 | awk '{$2 = ""; print}' | tr -s ' ')
if [ -n "$worst" ]; then
	echo "$frames" | awk '$1 > 0.05 {n++} END {
		if (n) printf "warning: %d frame peaks over 50 ms\n", n}' >&2
	# **On CI a timing is a row, never a verdict** ([CI_RUNS] (3)):
	# these 50 and 250 ms were argued against this desk's GPU, and under
	# llvmpipe on a runner they would fail every time -- which teaches
	# everyone to ignore the result, and then a real failure goes by
	# with it. What CI asserts is behaviour; the number is still
	# printed, and the machine it was measured on is what decides
	# whether it means anything.
	if [ -n "${BUILDAT_CI:-}" ]; then
		awk -v w="${worst%% *}" 'BEGIN {exit !(w > 0.25)}' &&
			echo "note: a frame took $worst ([FRAME_PEAK]); not a" \
					"verdict under BUILDAT_CI" >&2
	else
		# Worst first; each over the ceiling the machine's or the game's
		while read -r secs at phase; do
			awk -v w="$secs" 'BEGIN {exit !(w > 0.25)}' || break
			w=$(cpu_wait 3 "$at" 5)
			if machines "$w"; then
				echo "note: a frame took $secs $phase at $at ([FRAME_PEAK])," \
						"the client waiting for a CPU $w of the 5 s before" \
						"it: the machine's, not a verdict" >&2
			else
				say "a frame took $secs $phase ([FRAME_PEAK])${w:+, the client waiting for a CPU $w of the 5 s before it}"
				break
			fi
		done <<< "$frames"
	fi
fi
last=$(grep -a "fuzz: t=" "$out/srv.log" | tail -1 | sed 's/^.*fuzz: //')
[ -n "$last" ] || say "the fixture never ticked"
echo "seed $SEED, $MINUTES min: ${last:-no ticks}"
echo "client frame: ${worst:-no frame peak lines}"
echo "logs and pictures in $out"
# **And one line either way** ([CI_RUNS]'s contract, 2026-09-25): the
# faults above are said as they are found, but a run that finds none
# said nothing at all, so run_all.sh read "(no verdict line)" off a
# green fuzz and a reader had to know that silence was the pass.
if [ "$status" -eq 0 ]; then
	echo "PASS: the run finished with no fault of the kinds this watches"
else
	echo "FAIL: the run hit one of the faults listed above"
fi
# The run's own verdict, which every line above only reported
exit "$status"
