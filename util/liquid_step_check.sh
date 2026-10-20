#!/bin/bash
# tier: quick
# ci
# cost: 1 s (2026-10-20)
# covers: src/impl/liquid_corner.h src/impl/mesh.cpp
# [SKELDAT_WATER_STEP] 1: where a river's water steps down a voxel, the
# upper voxel's corner and the lower's meet (within 0.01), straight across,
# on a diagonal and at a point; a spill's edge and a source as before.
# liquid_corner.h's own main, no Urho3D.
#   util/liquid_step_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
g++ -std=c++11 -x c++ -Wno-pragma-once-outside-header \
	-DLIQUID_CORNER_SELF_TEST -o "$t/lc" "$here/src/impl/liquid_corner.h" ||
	{ echo "FAIL: liquid_corner.h does not build"; exit 1; }
"$t/lc" || { echo "FAIL: the corners at a step"; exit 1; }
echo "PASS: a liquid's corners at a step down meet"
