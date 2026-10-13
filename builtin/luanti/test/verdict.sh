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
grep -a "fuzz: FAILED" "$out/srv.log" | sed 's/^.*fuzz: //' | while read -r l; do echo "FAIL: $l" >&2; done
grep -aq "fuzz: FAILED" "$out/srv.log" && status=1
# The world not settling in the start wait ([START_WAIT]) is a verdict
grep -a 'wait_log: ".*" not seen' "$out/cli.log" | grep -a "undrawn\|put the player" | head -1 | sed 's/.*wait_log: /FAIL: the world did not settle: /' >&2
grep -aq 'wait_log: "scene, 0 undrawn within 2" not seen\|wait_log: "the server put the player" not seen' "$out/cli.log" && status=1
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
	sed 's/^.*frame peak \([0-9.]*\) s in \(.*\), held.*$/\1 \2/')
worst=$(echo "$frames" | sort -rn | head -1)
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
		awk -v w="${worst%% *}" 'BEGIN {exit !(w > 0.25)}' &&
			say "a frame took $worst ([FRAME_PEAK])"
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
