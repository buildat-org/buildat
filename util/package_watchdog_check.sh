#!/bin/bash
# tier: full
# cost: ~70s (2026-10-05)
# covers: util/package.sh tree_cpu wait_for_line
# [WIN_PREBUILD_STALL]: the prebuild's watchdog fails a server whose log
# and CPU are both still for 30 s. Under Wine the server is reparented
# out of the waited process's tree and its comm is cut to
# "buildat_server.", so its own work before the first compile read as no
# CPU and a slow runner failed 0.6.32's package as a hang.
#
# Two cases, no Wine needed: a process outside the tree whose command
# line is a Windows one keeps the CPU moving while the log is silent for
# 35 s -- the line it waits for comes, and the wait passes; and a real
# hang -- nothing moving -- is still failed at 30 s.
#
#   util/package_watchdog_check.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
busy=
trap '[ -n "$busy" ] && kill $busy 2>/dev/null; rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
eval "$(sed -n '/^tree_cpu() {/,/^}/p;/^wait_for_line() {/,/^}/p' "$here/util/package.sh")"
type wait_for_line > /dev/null 2>&1 || fail "no wait_for_line in util/package.sh"

# Busy outside the tree: a CPU loop named as Wine names the server,
# orphaned the way Wine's processes are
(exec -a 'Z:\stage\bin\buildat_server.exe' bash -c 'while :; do :; done' &)
for i in $(seq 25); do
	busy=$(pgrep -f 'buildat_server\.exe' | head -1)
	[ -n "$busy" ] && break
	sleep 0.2
done
[ -n "$busy" ] || fail "the busy loop did not start"
: > "$t/busy.log"
# The sleeps are the case itself: a server held up 35 s, a watchdog of 30
sleep 45 & srv=$!
(sleep 35; echo "Listening at any4:1" >> "$t/busy.log") &
wait_for_line "$t/busy.log" $srv "Listening at" 60 > /dev/null 2>&1 ||
	fail "a silent log with a busy Windows process was failed as a hang"
kill $busy $srv 2>/dev/null; busy=

# A real hang: nothing moves
: > "$t/hang.log"
sleep 60 & srv=$!
start=$SECONDS
wait_for_line "$t/hang.log" $srv "Listening at" 60 > /dev/null 2>&1 &&
	fail "a hang was waited out"
kill $srv 2>/dev/null
[ $((SECONDS - start)) -le 40 ] || fail "a hang was failed only at the ceiling"
echo "PASS: a silent log with a busy Windows process is waited for; a hang is failed at 30 s"
