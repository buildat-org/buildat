#!/bin/bash
# tier: quick
# cost: ~1 min (2026-10-30)
# covers: src/server/main.cpp src/impl/game_clock.cpp util/check_lib.sh apps/sim_rate_check/**
# [CHECK_TIME_SCALE]: the server's --sim-rate, on apps/sim_rate_check (no
# client; its module logs each game second its ticks, those misplaced on
# interface::os::game_us() and a state stepped by both, and takes 1.5 s
# of the wall's over the tick at game second 5). At 10x: the game's clock
# no faster than ten times the wall's, and as fast up to the machine's
# ceiling; the slowed tick runs late, no tick dropped or misplaced, no
# "Skipping"; the rate changed at run time through sim_clock's second
# number, to 1x and to as fast as it goes; check_lib's wait_for_log on
# the game's seconds. The state at game second 12 the same at 1x as at
# 10x. On the wall clock (no --sim-rate) the slowed tick misplaces ticks.
#   util/sim_rate_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp sim_rate; t=$CHECK_TMP
app="$here/apps/sim_rate_check"
srv() # <name> [args]: in the background, its PID in CHECK_PIDS
{
	local name=$1; shift
	[ -d "$t/a/c" ] && [ "$name" != a ] && cp -a "$t/a/c" "$t/$name/c"
	start_server "$t/$name.log" "game second 1:" 300 auto \
		"$here/Build/bin/buildat_server" -m "$app" -D "$t/$name/u" -C "$t/$name/c" \
		-l 3 "$@" || fail "the server $name ($t/$name.log)"
	CHECK_PIDS+=($SERVER_PID)
}
line() # <log> <game second>: that second's line, after "game second N: "
{
	grep -a "sim_rate_check: game second $2:" "$1" | head -1 | sed 's/.*game second [0-9]*: //'
}
now() { date +%s.%N; }
# gone <user path> <n>: the wall's seconds for the game's next n (whole
# seconds read: up to one either way)
gone()
{
	local g0 g w0 i=0
	g0=$(game_seconds "$1"); w0=$(now)
	# A hang's net: a minute
	while g=$(game_seconds "$1"); [ $((g - g0)) -lt "$2" ] && [ $i -lt 1200 ]; do
		sleep 0.05; i=$((i + 1))
	done
	awk -v a="$w0" -v b="$(now)" 'BEGIN { printf "%.2f", b - a }'
}

mkdir -p "$t/a" "$t/b" "$t/c"
srv a --sim-rate 10
A=$SERVER_PID
# The game's seconds: 30 of them, the clock's file read as they pass
wait_for_log "$t/a.log" "game second 7:" 60 "$t/a/u" || fail "no game second 7 ($t/a.log)"
w0=$(now); g0=$(game_seconds "$t/a/u")
wait_for_log "$t/a.log" "game second 27:" 30 "$t/a/u" || fail "no game second 27 in 30 of the game's ($t/a.log)"
w1=$(now); g1=$(game_seconds "$t/a/u")
fast=$(awk -v a="$w0" -v b="$w1" -v g="$((g1 - g0))" 'BEGIN { printf "%.1f", g / (b - a) }')
echo "  at 10x: $((g1 - g0)) game seconds in $(awk -v a="$w0" -v b="$w1" 'BEGIN { printf "%.2f", b - a }') s, ${fast}x"
# One second of the clock's file either side: its seconds are whole
awk -v r="$fast" -v g="$((g1 - g0))" 'BEGIN { exit !(r <= 10 * (g + 1) / (g - 1) && r >= 2) }' ||
	fail "the game's clock at ${fast}x for a rate of 10 ($t/a.log)"
s6=$(line "$t/a.log" 6) s27=$(line "$t/a.log" 27)
case "$s6" in "180 ticks, 0 misplaced on the clock, rate 10, "*) ;;
	*) fail "past the slowed tick: '$s6' ($t/a.log)" ;; esac
case "$s27" in "810 ticks, 0 misplaced on the clock, rate 10, "*) ;;
	*) fail "at game second 27: '$s27' ($t/a.log)" ;; esac
! grep -aq "Skipping" "$t/a.log" || fail "a tick skipped ($t/a.log)"
echo "  the slowed tick: game second 6 at $s6"
# 1x from now, through the file: three wall seconds, three game seconds
game_rate "$t/a/u" 1
wait_for_log "$t/a.log" "sim rate: 1x" 10 || fail "the rate not changed to 1x ($t/a.log)"
s=$(gone "$t/a/u" 3)
awk -v s="$s" 'BEGIN { exit !(s >= 2 && s <= 4.5) }' || fail "at 1x: 3 game seconds in $s s ($t/a.log)"
# As fast as it goes: well past 10x on a module this light
game_rate "$t/a/u" 0
wait_for_log "$t/a.log" "sim rate: 0x" 10 || fail "the rate not changed to 0 ($t/a.log)"
f=$(gone "$t/a/u" 300)
awk -v s="$f" 'BEGIN { exit !(s < 30) }' || fail "as fast as it goes: 300 game seconds in $f s ($t/a.log)"
echo "  changed at run time: 3 game seconds in $s s at 1x, then 300 in $f s as fast as it goes"
kill $A; wait $A 2>/dev/null
grep -a "sim_rate_check: game second" "$t/a.log" | tail -1 | grep -q " 0 misplaced" ||
	fail "a tick misplaced on the clock ($t/a.log)"
# At 1x, and on the wall clock (no --sim-rate), at once
srv b --sim-rate 1
B=$SERVER_PID
srv c
C=$SERVER_PID
wait_for_log "$t/b.log" "game second 12:" 30 "$t/b/u" || fail "1x: no game second 12 ($t/b.log)"
wait_for_log "$t/c.log" "game second 8:" 30 || fail "the wall clock: no game second 8 ($t/c.log)"
kill $B $C; wait $B $C 2>/dev/null
a12=$(line "$t/a.log" 12) b12=$(line "$t/b.log" 12)
[ "${a12%, rate *}" = "${b12%, rate *}" ] && [ "${a12##*state }" = "${b12##*state }" ] ||
	fail "game second 12 at 10x '$a12', at 1x '$b12'"
echo "  game second 12 at 1x as at 10x: ${b12##*, }"
c8=$(line "$t/c.log" 8)
case "$c8" in *", 0 misplaced"*) fail "the wall clock's slowed tick misplaced nothing: '$c8' ($t/c.log)" ;; esac
echo "  on the wall clock: game second 8 at $c8"
echo "PASS: --sim-rate: the game's clock at its rate, a slowed tick late but kept, the rate changed at run time, the same game at 1x and 10x"
# vim: set noet ts=4 sw=4:
