#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: ~30s (2026-11-20)
# drives: builtin/*/*.cpp apps/*/main/*.cpp extensions/*/*.cpp extensions/*/main/*.cpp
# [WIN_KIT_BUILD] Every module the server compiles at run time (builtin/*,
# the apps' and extensions' main/) through the Windows cross compiler,
# -fsyntax-only: kit.cpp called POSIX read and write with <unistd.h> only
# under #ifndef _WIN32 and no Kit app started on Windows for 18 alphas,
# while every Linux check passed. The packaging image's mingw g++
# (buildat-package-windows, util/docker/windows); skipped where there is no
# docker or no such image. The "drives:" line is so that run_all --changed
# runs this beside the cheapest runner whenever a module's source changes,
# not instead of it.
# simplified: Urho3D's generated headers are the Linux build's
# (3rdparty/Urho3D/Build/include); a Windows-only difference in them is
# the package build's to find
#   util/mingw_modules_check.sh [module source...]
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
image=buildat-package-windows
command -v docker > /dev/null || skip "no docker"
docker image inspect "$image" > /dev/null 2>&1 || skip "no $image image (util/package_in_docker.sh windows builds it)"
[ -f "$here/3rdparty/Urho3D/Build/include/Urho3D/Urho3D.h" ] || skip "no 3rdparty/Urho3D/Build (Urho3D not built here)"
check_tmp mingw_modules; t=$CHECK_TMP
cd "$here"
[ $# -gt 0 ] || set -- $(ls builtin/*/*.cpp apps/*/main/*.cpp extensions/*/*.cpp \
	extensions/*/main/*.cpp 2>/dev/null | grep -v '_web\.cpp$')
# One line a module: its meta.json's cxxflags and cxxflags_windows, then
# its source (state.cpp's flags, the include directories as there)
python3 -I - "$@" > "$t/list" <<'PY' || fail "a module's meta.json"
import json, os, sys
for f in sys.argv[1:]:
    m = os.path.join(os.path.dirname(f), "meta.json")
    j = json.load(open(m)) if os.path.exists(m) else {}
    print(" ".join(x for x in (j.get("cxxflags", ""), j.get("cxxflags_windows", "")) if x) + "\t" + f)
PY
U=3rdparty/Urho3D
I="-Isrc -I3rdparty/cereal/include -I3rdparty/polyvox/library/PolyVoxCore/include -I3rdparty/sqlite/src -Ibuiltin -I$U/Source/Urho3D"
for s in Audio Container Core Engine Graphics IK Input IO LuaScript Math Navigation Network Physics Resource Scene UI Urho2D; do
	I="$I -I$U/Source/Urho3D/$s"
done
I="$I -I$U/Build/include -I$U/Build/include/Urho3D -I$U/Build/include/Urho3D/ThirdParty -I$U/Build/include/Urho3D/ThirdParty/Bullet -I$U/Build/include/Urho3D/ThirdParty/LuaJIT -I$U/Source/ThirdParty/SDL/include -I$U/Source/ThirdParty/Bullet/src"
cat > "$t/one.sh" <<EOF
f=\${1#*	} flags=\${1%%	*}
if x86_64-w64-mingw32-g++-posix -O1 -std=c++11 \$flags -DRCCPP -fsyntax-only $I -I"\$(dirname "\$f")" "\$f" > "$t/\$(echo "\$f" | tr / _).txt" 2>&1; then
	echo "ok \$f"
else
	echo "FAIL \$f"; grep -m5 "error" "$t/\$(echo "\$f" | tr / _).txt"
fi
EOF
# The tree mounted at its own path (3rdparty/Urho3D/Build's links are
# absolute), read-only and not relabelled
jobs=$(( $(nproc) / 2 )); [ "$jobs" -ge 1 ] || jobs=1
docker run --rm --security-opt label=disable -v "$here:$here:ro" -v "$t:$t" -w "$here" "$image" \
	bash -c "tr '\n' '\0' < '$t/list' | xargs -0 -n1 -P$jobs bash '$t/one.sh'" > "$t/out" 2>&1 ||
	fail "docker: $(tail -3 "$t/out")"
grep -v '^ok ' "$t/out"
n=$(grep -c '^ok ' "$t/out")
grep -q '^FAIL ' "$t/out" && fail "$(grep -c '^FAIL ' "$t/out") of $# modules do not build for Windows"
[ "$n" = $# ] || fail "$n of $# modules said ok ($t/out)"
echo "PASS: all $# runtime-compiled modules build for Windows (mingw -fsyntax-only)"
# vim: set noet ts=4 sw=4:
