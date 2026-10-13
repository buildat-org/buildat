#!/bin/bash
# extensions/launch_world: the room left running and worked at, for the
# two faults a one-shot check cannot see -- a leak and a slow crash.
#
#   extensions/launch_world/soak.sh
#
# tier: long
#
# **Why the launcher and not a game**: this is the process a player
# leaves open while they decide what to play, and it is the first thing
# every run of buildat draws. A room that grows a megabyte a minute is a
# room nobody notices until the machine is out of memory, and every
# picture check here would still pass.
#
# What it does: boots the room and works it -- browsing, searching,
# opening and shutting bays, walking, digging, placing, the terminal,
# the pause dialog -- around a loop for MINUTES minutes (3 by default),
# reading the client's resident size every ten seconds.
#
# What it asserts: the client is alive at the end and never crashed, and
# its resident size after the first minute has not grown by more than
# GROW per cent (25 by default). The first minute is warmup: the
# textures, the meshes and the ornament are all generated at boot and
# the reflection probe renders its ninety frames after that.
#
# It keeps builtin/luanti/test/lib.sh's contract ([CI_RUNS] (1)): exit 0
# passed, 1 failed, 2 could not run, and a last line saying which.
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/launch_world_soak"; mkdir -p "$out"
rm -f "$out"/*.log "$out"/*.txt
MINUTES="${MINUTES:-3}"
GROW="${GROW:-25}"
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi
# The room's own save is left alone: this places and digs a great many
# voxels and the player's room is not the place for them
user="$out/user"; rm -rf "$user"; mkdir -p "$user"
{
	echo "wait_log_any 60000 the room hums"
	# One turn of the loop is about twenty seconds; enough turns to
	# cover the minutes asked for, and the sequence ends by itself. Its
	# delays are the soak's pace, the room worked for the minutes asked
	# for, and not waits for anything
	turns=$(( MINUTES * 3 + 2 ))
	for i in $(seq 1 "$turns"); do
		# Menu mode: browse and search
		echo "event mode menu"
		echo "delay 500"
		echo "keypress Down"; echo "keypress Right"; echo "keypress Up"
		echo "delay 400"
		# **The prompt is typed at and cleared, never entered.** A
		# launch from here is not worth what it costs to keep
		# deterministic: Enter launches whatever the arrows had browsed
		# -- a game, after which this measured a world loading rather
		# than the room (2026-09-24). The dissolve and the launch are the room's own
		# check's to drive, where the state is known at every step.
		for c in I N S T A L L; do echo "keypress $c"; done
		echo "delay 600"
		echo "keypress Escape"
		echo "delay 500"
		# The stations: the floor, the desk and back to the wall
		echo "keypress Tab"
		echo "delay 1800"
		echo "keypress Tab"
		echo "delay 1800"
		echo "keypress Tab"
		# the soak's pace, as above
		echo "delay 1800"
		# The desk through the dialog's Settings, and out again
		echo "keypress Escape"
		echo "delay 600"
		echo "keypress Down"
		echo "keypress Return"
		# the soak's pace, as above
		echo "delay 1500"
		echo "keypress Escape"
		# the soak's pace, as above
		echo "delay 1200"
		# The pause dialog, and out again
		echo "keypress Escape"
		echo "delay 800"
		echo "keypress Escape"
		echo "delay 600"
		# The attract mode, which runs the camera and the sound
		echo "event room attract"
		echo "delay 2500"
	done
	echo "quit"
} > "$out/cmds.txt"
bin/buildat -m launch_world -D "$user" -w 800x500 -l 3 \
	-L "$out/cli.log" -c @"$out/cmds.txt" > /dev/null 2>&1 &
run=$!
trap 'kill "$run" 2>/dev/null' EXIT
# The room up: its first line, up to a minute
for _ in $(seq 300); do
	grep -aq "the room hums" "$out/cli.log" 2>/dev/null && break
	kill -0 "$run" 2>/dev/null || break
	sleep 0.2
done
pid=$run
if ! grep -aq "the room hums" "$out/cli.log" 2>/dev/null; then
	kill "$run" 2>/dev/null
	echo "SKIP: the client did not come up" >&2; exit 2
fi
: > "$out/rss.txt"
while kill -0 "$run" 2>/dev/null; do
	rss=$(awk '/VmRSS/ {print $2}' "/proc/$pid/status" 2>/dev/null)
	[ -n "$rss" ] && echo "$(date +%s) $rss" >> "$out/rss.txt"
	# The sampling interval, ten seconds: a timing, not a wait
	sleep 10
done
wait "$run" 2>/dev/null
# **A soak that left the room measured something else.** Nothing here
# should start a server: the bay it opens is the empty one.
if grep -aq "Starting local server" "$out/cli.log"; then
	echo "FAIL: the soak launched a game -- what it measured after that" \
			"is a world loading, not the room"
	grep -a "launch_w.*: launch: " "$out/cli.log" | tail -3
	exit 1
fi
if grep -aq "Crash: SIG" "$out/cli.log"; then
	echo "FAIL: the room crashed while it was being worked --" \
			"$(grep -a "Crash: SIG" "$out/cli.log" | head -1)"
	exit 1
fi
# A Lua error in a handler is a dialog rather than a crash, and the room
# goes on drawing behind it; a soak that ignored those would pass a room
# that stopped answering the keyboard ten seconds in
errors=$(grep -ac "error shown in a dialog" "$out/cli.log")
python3 - "$out/rss.txt" "$GROW" "$errors" <<'PY' || exit 1
import sys
rows = [l.split() for l in open(sys.argv[1]) if l.strip()]
grow, errors = float(sys.argv[2]), int(sys.argv[3])
if len(rows) < 8:
	print("FAIL: the room did not run long enough to read (%d samples)"
			% len(rows))
	raise SystemExit(1)
t0 = int(rows[0][0])
after = [(int(t) - t0, int(k)) for t, k in rows]
warm = [k for t, k in after if t >= 60]
if not warm:
	print("FAIL: no samples after the first minute")
	raise SystemExit(1)
base, last, peak = warm[0], warm[-1], max(warm)
print("resident: %.1f MB at a minute, %.1f MB at the end, %.1f MB at its "
		"most, over %d samples" % (base / 1024.0, last / 1024.0,
		peak / 1024.0, len(after)))
print("%d handler errors" % errors)
ok = peak <= base * (1.0 + grow / 100.0) and errors == 0
if not ok and peak > base * (1.0 + grow / 100.0):
	print("FAIL: the room grew %.1f per cent after warming up"
			% ((peak - base) * 100.0 / base))
elif not ok:
	print("FAIL: a handler raised while the room was being worked")
print("PASS: the room holds its size and its handlers while it is worked"
		if ok else "FAIL: the room does not hold up to being left open")
raise SystemExit(0 if ok else 1)
PY
