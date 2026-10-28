#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-21)
# covers: src/impl/mesh.cpp src/lua_bindings/mesh.cpp src/impl/thread_pool.cpp
# [WEB_MAIN_THREAD]: a chunk's mesh made in slices (the web client's pool
# runs them on the frame's own thread, 2 ms at a time) is the mesh made in
# one go. hillclimb's client with BUILDAT_MESH_SLICE_CHECK=1 meshes each
# chunk again whole and in the smallest slices (a z layer or 64 faces a
# step) and compares the vertices byte for byte with what its task made,
# and its collision boxes whole and a box a step ([WEB_MESH_SLICES]);
# 300 chunks, none differing. (A LOD task checks itself the same way,
# "lod slice check", where a world has LOD: not hillclimb.)
#   util/mesh_slice_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp mesh_slice; t=$CHECK_TMP
trap check_cleanup EXIT
start_server "$t/s.log" "STATUS Listening" 300 auto "$here/Build/bin/buildat_server" \
	-m "$here/apps/hillclimb" -D "$t/s" -C "$t/s.cache" -l 3 -u launcher=1 ||
	fail "the server ($t/s.log)"
CHECK_PIDS+=($SERVER_PID)
printf 'wait_log 180000 mesh slice check: 300 the same\nquit\n' > "$t/seq"
BUILDAT_MESH_SLICE_CHECK=1 run_client 200 "$t/c.log" timeout 200 \
	"$here/Build/bin/buildat" -s 127.0.0.1:$SERVER_PORT -D "$t/c" \
	-C "$t/c.cache" -w 640x480 -l 3 -o sound_mute=1 -c @"$t/seq" ||
	fail "the client ($t/c.log): $(grep -a "mesh slice check" "$t/c.log" | tail -1)"
! grep -aq "mesh slice check: .*DIFFERS" "$t/c.log" ||
	fail "a sliced mesh differs: $(grep -a "DIFFERS" "$t/c.log" | head -1) ($t/c.log)"
echo "PASS: $(grep -ao "mesh slice check: [0-9]* the same, [0-9]* differ" "$t/c.log" | tail -1 | sed 's/mesh slice check: //'): a chunk's mesh in slices is the mesh in one go"
