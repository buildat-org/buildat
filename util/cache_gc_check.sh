#!/bin/bash
# tier: quick
# cost: ~30 s (2026-11-03)
# covers: src/impl/linux/fs.cpp src/client/state.cpp src/client/app.cpp
# [CACHE_GC]: the client's start sweeps what went unused longer than
# cache_keep from the cache's own directories, and keeps the rest; a cache
# hit marks a file used; remote/ is one store for every server.
#   1. a cache with old and fresh files: the old ones in remote/ (and an
#      old per-server directory's), tmp/, luanti_client/, wasm2c/,
#      apps/*/tmp and apps/*/rccpp_build gone; the fresh one,
#      installed_games/, the shared rccpp_build/ and what a link in
#      apps/*/tmp points at outside the cache kept
#   2. the client on 127.0.0.2 to one server: its files in remote/ itself
#   3. another server of the same app on 127.0.0.1: nothing more stored,
#      and a file made old is used and marked so
#   4. cache_keep=0 (forever): nothing removed, no sweep
#   util/cache_gc_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp cache_gc; t=$CHECK_TMP
c=$t/c
old() { mkdir -p "$(dirname "$1")"; echo x > "$1"; touch -d '30 days ago' "$1"; }
seed() # <cache>
{
	old "$1/remote/0000000000000000000000000000000000000001"
	old "$1/remote/server_example.org_29500/0000000000000000000000000000000000000002"
	old "$1/tmp/0000000000000000000000000000000000000003.png"
	old "$1/luanti_client/example.org_30000/a.png"
	old "$1/wasm2c/0123/module.so"
	old "$1/apps/foo/tmp/cc1.tmp"
	old "$1/apps/foo/rccpp_build/foo_main.so"
	old "$1/installed_games/luanti/minimal.png"
	old "$1/rccpp_build/builtin_network.so"
	mkdir -p "$1/remote"; echo y > "$1/remote/0000000000000000000000000000000000000004"
}
seed "$c"
old "$t/outside/keep.txt"
ln -s "$t/outside" "$c/apps/foo/tmp/link"

start_server "$t/a.log" "STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-m "$here/apps/sample_ui" -D "$t/sa" -C "$t/sa.cache" -l 3 -u launcher=1 ||
	fail "server a ($t/a.log)"
CHECK_PIDS+=($SERVER_PID); pa=$SERVER_PORT
start_server "$t/b.log" "STATUS Listening" 120 auto "$here/Build/bin/buildat_server" \
	-m "$here/apps/sample_ui" -D "$t/sb" -C "$t/sb.cache" -l 3 -u launcher=1 ||
	fail "server b ($t/b.log)"
CHECK_PIDS+=($SERVER_PID); pb=$SERVER_PORT

printf 'sync 60000\nidle 60000\nwait_log_any 30000 Cache sweep:\nquit\n' > "$t/1.cmds"
run_client 60 "$t/c1.log" timeout -k 5 120 "$here/Build/bin/buildat" \
	-s 127.0.0.2:$pa -C "$c" -D "$t/u" -w 640x360 -l 3 \
	-o sound_mute=1,cache_keep=14 -c @"$t/1.cmds" ||
	fail "client 1 ($t/c1.log): $(grep -a 'Command sequence failed' "$t/c1.log" | head -1)"

# 1.
for f in remote/0000000000000000000000000000000000000001 \
		remote/server_example.org_29500/0000000000000000000000000000000000000002 \
		tmp/0000000000000000000000000000000000000003.png \
		luanti_client/example.org_30000/a.png wasm2c/0123/module.so \
		apps/foo/tmp/cc1.tmp apps/foo/rccpp_build/foo_main.so; do
	[ ! -e "$c/$f" ] || fail "an old $f was kept"
done
for f in remote/0000000000000000000000000000000000000004 \
		installed_games/luanti/minimal.png rccpp_build/builtin_network.so; do
	[ -e "$c/$f" ] || fail "$f was removed"
done
[ -e "$t/outside/keep.txt" ] || fail "the sweep followed a link out of the cache"
grep -aq "Cache sweep: [1-9]" "$t/c1.log" || fail "no sweep logged ($t/c1.log)"

# 2.
ls -d "$c"/remote/server_127* "$c/remote/local" 2>/dev/null &&
	fail "a per-server directory was made"
n=$(find "$c/remote" -maxdepth 1 -type f | wc -l)
[ "$n" -gt 2 ] || fail "nothing of server a's in remote/ ($n files)"

# 3.
f=$(find "$c/remote" -maxdepth 1 -type f -newer "$c/remote/0000000000000000000000000000000000000004" | head -1)
touch -d '30 days ago' "$f"
printf 'sync 60000\nidle 60000\nquit\n' > "$t/2.cmds"
run_client 60 "$t/c2.log" timeout -k 5 120 "$here/Build/bin/buildat" \
	-s 127.0.0.1:$pb -C "$c" -D "$t/u" -w 640x360 -l 3 \
	-o sound_mute=1,cache_keep=14 -c @"$t/2.cmds" ||
	fail "client 2 ($t/c2.log): $(grep -a 'Command sequence failed' "$t/c2.log" | head -1)"
n2=$(find "$c/remote" -maxdepth 1 -type f | wc -l)
[ "$n2" = "$n" ] || fail "server b's same files stored again ($n, then $n2)"
[ -n "$(find "$f" -mtime -1)" ] || fail "a cache hit did not mark $f used"

# 4.
c2=$t/c2
seed "$c2"
printf 'frames 10\nquit\n' > "$t/3.cmds"
run_client 60 "$t/c3.log" timeout -k 5 60 "$here/Build/bin/buildat" \
	-C "$c2" -D "$t/u" -w 640x360 -l 3 -o sound_mute=1,cache_keep=0 \
	-c @"$t/3.cmds" || fail "client 3 ($t/c3.log)"
[ -e "$c2/remote/0000000000000000000000000000000000000001" ] &&
	[ ! -e "$c2/cache_sweep" ] || fail "cache_keep=0 swept"

echo "PASS: old cache files swept and the rest kept (a link not followed), one remote/ for two servers ($n files), a hit marked used, forever kept all"
