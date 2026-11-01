#!/bin/bash
# tier: quick
# cost: ~3s (2026-11-01)
# covers: src/impl/fs.cpp src/impl/linux/fs.cpp util/fs_race
# [FS_TMP_SHARED]: interface::fs::write_file() from several processes at
# once, to one path with the same content (as clients sharing a cache
# write a file of the same hash): each reads back what it wrote, whole.
# With one temporary name for all, a writer's rename put another's
# truncated file in place, and a client read the voxel registry empty
# (VOXEL_REG_EMPTY_FLAKE). fs.cpp built on its own with c55's filesys and
# a log stub (util/fs_race).
#
#   util/fs_race_check.sh
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
g++ -std=c++17 -O1 -w -I"$here/src" -I"$here/3rdparty/c55lib" \
	"$here/util/fs_race/fs_race.cpp" "$here/util/fs_race/log_stub.cpp" \
	"$here/3rdparty/c55lib/c55/filesys.cpp" "$here/src/impl/linux/fs.cpp" \
	"$here/src/impl/fs.cpp" -o "$t/fs_race" ||
	{ echo "FAIL: fs_race did not build"; exit 1; }
mkdir "$t/dir"
"$t/fs_race" "$t/dir" || { echo "FAIL: a write read back not whole"; exit 1; }
left=$(ls "$t/dir" | grep -v '^shared.bin$')
[ -z "$left" ] || { echo "FAIL: temporary files left: $left"; exit 1; }
echo "PASS: fs::write_file from 4 processes at once to one path: each read back whole, no temporary left"
