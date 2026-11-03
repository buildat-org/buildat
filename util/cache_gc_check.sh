#!/bin/bash
# tier: quick
# cost: ~30 s (2026-11-03)
# covers: src/impl/linux/fs.cpp src/client/state.cpp src/client/app.cpp extensions/launch_menu/preferences.lua
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
#   5. [CACHE_PER_SERVER] cache_per_server=1 on a new cache: server a's
#      files fetched; server b's same files fetched again but stored
#      once; server a's next visit fetches nothing; the sweep dropped a
#      list's entry whose file is gone and a list unused past cache_keep
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

# 5.
c3=$t/c3
h4=0000000000000000000000000000000000000004 h5=0000000000000000000000000000000000000005
mkdir -p "$c3/remote/servers"; echo y > "$c3/remote/$h4"
printf '%s\n%s\n' $h4 $h5 > "$c3/remote/servers/server_example.org_1"
old "$c3/remote/servers/server_old"
asked() { grep -ao "announced files are cached, [0-9]* asked for" "$1" |
	awk '{s += $5} END {print s + 0}'; }
stored() { find "$c3/remote" -maxdepth 1 -type f | wc -l; }
visit() # <n> <address> [sweep]
{
	printf 'sync 60000\nidle 60000\n%bquit\n' \
		"${3:+wait_log_any 30000 Cache sweep:\n}" > "$t/p$1.cmds"
	run_client 60 "$t/p$1.log" timeout -k 5 120 "$here/Build/bin/buildat" \
		-s "$2" -C "$c3" -D "$t/u" -w 640x360 -l 3 \
		-o sound_mute=1,cache_keep=14,cache_per_server=1 -c @"$t/p$1.cmds" ||
		fail "per-server client $1 ($t/p$1.log): $(grep -a 'Command sequence failed' "$t/p$1.log" | head -1)"
}
visit 1 127.0.0.2:$pa sweep
a1=$(asked "$t/p1.log"); s1=$(stored)
[ "$a1" -gt 0 ] || fail "server a's files were not asked for ($t/p1.log)"
la=$c3/remote/servers/server_127.0.0.2_$pa
[ "$(sort -u "$la" | wc -l)" = "$(wc -l < "$la")" ] && [ -s "$la" ] ||
	fail "server a's list empty or repeated ($la)"
[ "$(cat "$c3/remote/servers/server_example.org_1")" = "$h4" ] ||
	fail "the sweep kept a list's entry whose file is gone"
[ ! -e "$c3/remote/servers/server_old" ] || fail "an unused list was kept"
visit 2 127.0.0.1:$pb
a2=$(asked "$t/p2.log"); s2=$(stored)
[ "$a2" = "$a1" ] || fail "server b asked for $a2 files, not server a's $a1 ($t/p2.log)"
[ "$s2" = "$s1" ] || fail "server b's same files stored again ($s1, then $s2)"
[ -s "$c3/remote/servers/local" ] || fail "no list for server b"
visit 3 127.0.0.2:$pa
a3=$(asked "$t/p3.log")
[ "$a3" = 0 ] || fail "server a's next visit asked for $a3 files ($t/p3.log)"

echo "PASS: old cache files swept and the rest kept (a link not followed), one remote/ for two servers ($n files), a hit marked used, forever kept all; per server: b asked for a's $a1 files again, stored once ($s1), a's next visit nothing, lists swept"
