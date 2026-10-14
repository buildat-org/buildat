#!/bin/bash
# tier: full
# cost: 40s (2026-10-04)
# covers: src/client/app.cpp src/client/main.cpp
# [SERVER_ADOPTED]: a client stops only a local server it started, or one
# whose client is gone; a scripted client keeps out of the default cache.
#   1. Client A plays demo_digger (-a app/demo_digger/play) on a local server, with a cache given by -C
#      as a person's launcher has; client B, on the same cache, starts and
#      quits beside it: A's server is still running.
#   2. A scripted client with no -C leaves the default cache's
#      buildat.log as it was.
#
#   util/local_server_pid_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
a=
o=
trap '[ -n "$a" ] && kill $a 2>/dev/null; [ -n "$o" ] && kill $o 2>/dev/null; rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
cd "$here/Build"

# 1
# A's delay is its staying up while B runs (the shell kills A after); B
# quits once its launcher is up, where the pidfile is read on the quit (its
# rows line is logged before the drive starts)
printf 'delay 60000\nquit\n' > "$t/long"
printf 'wait_log_any 30000 launch_menu: \nquit\n' > "$t/short"
timeout 90 bin/buildat -o launch_ui=launch_menu -C "$t/cache" -D "$t/ua" -a app/demo_digger/play -w 640x360 -l 3 \
	-o sound_mute=1 -c @"$t/long" > "$t/a.log" 2>&1 &
a=$!
for _ in $(seq 300); do
	[ -s "$t/cache/local_server.pid" ] && break
	kill -0 "$a" 2>/dev/null || break
	sleep 0.2
done
pf=$t/cache/local_server.pid
server=$(sed -n 's/^server=//p' "$pf"); client=$(sed -n 's/^client=//p' "$pf")
[ -n "$server" ] && [ -n "$client" ] && grep -q '^v=1$' "$pf" ||
	fail "A wrote no pidfile ($(tail -3 "$t/a.log"))"
# $a is timeout's; the client is its child
[ "$(ps -o ppid= -p "$client" | tr -d ' ')" = "$a" ] ||
	fail "the pidfile names client $client, not A"
kill -0 "$server" || fail "A's server is not running"
timeout 60 bin/buildat -o launch_ui=launch_menu -C "$t/cache" -D "$t/ub" -w 640x360 -l 3 \
	-o sound_mute=1 -c @"$t/short" > "$t/b.log" 2>&1 ||
	fail "b: $(grep -a 'Command sequence failed\|^E' "$t/b.log" | tail -2)"
grep -q "Adopted leftover" "$t/b.log" && fail "B adopted A's server"
kill -0 "$server" || fail "B's quit stopped A's server"

# 1b. An orphaned server ([COMPAT_BREAK_07] 8i) is adopted by a client of
# its own version only. A client's own dies with it here (PDEATHSIG), so
# the orphan is a server started apart and the pidfile is written for it
kill "$a" 2>/dev/null; wait "$a" 2>/dev/null; a=
start_server "$t/o.log" "STATUS Listening" 60 29866 \
	setsid bin/buildat_server -m ../apps/demo_digger -D "$t/uo" -C "$t/co" -l 3 ||
	fail "the orphan did not start ($(tail -3 "$t/o.log"))"
server=$SERVER_PID; o=$server
printf 'v=1\nversion=0.0.1\nserver=%s\nclient=0\napp=demo_digger\nport=29866\n' \
	"$server" > "$pf"
timeout 60 bin/buildat -o launch_ui=launch_menu -C "$t/cache" -D "$t/ub" -w 640x360 -l 3 \
	-o sound_mute=1 -c @"$t/short" > "$t/b2.log" 2>&1 ||
	fail "b2: $(grep -a 'Command sequence failed\|^E' "$t/b2.log" | tail -2)"
grep -q "Adopted leftover" "$t/b2.log" && fail "another version's server was adopted"
kill -0 "$server" || fail "another version's server was stopped"
sed -i "s/^version=.*/version=$(sed -n 's/.*buildat \([^ ]*\) (.*/\1/p' "$t/b2.log" | head -1)/" "$pf"
timeout 60 bin/buildat -o launch_ui=launch_menu -C "$t/cache" -D "$t/ub" -w 640x360 -l 3 \
	-o sound_mute=1 -c @"$t/short" > "$t/b3.log" 2>&1 ||
	fail "b3: $(grep -a 'Command sequence failed\|^E' "$t/b3.log" | tail -2)"
grep -q "Adopted leftover local server pid $server" "$t/b3.log" ||
	fail "its own version's orphaned server was not adopted (b3.log)"
kill "$server" 2>/dev/null

# 2
log=$(ls -d "$here"/Build/cache 2>/dev/null || echo "${XDG_CACHE_HOME:-$HOME/.cache}/buildat")/buildat.log
before=$(stat -c %Y "$log" 2>/dev/null)
timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/uc" -w 640x360 -l 3 -o sound_mute=1 \
	-c @"$t/short" > "$t/c.log" 2>&1 ||
	fail "c: $(grep -a 'Command sequence failed\|^E' "$t/c.log" | tail -2)"
[ "$(stat -c %Y "$log" 2>/dev/null)" = "$before" ] ||
	fail "a scripted client wrote $log"
echo "PASS: B left A's server running; an orphaned one adopted by its own version only; a scripted client kept out of the default cache"
