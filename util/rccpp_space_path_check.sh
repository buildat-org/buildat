#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: ~30 s (2026-11-14)
# covers: src/server/rccpp.cpp src/impl/linux/process.cpp src/boot/autodetect.cpp
# [WIN_INSTALL_SPACE] A module compiles when every path on the compiler's
# command line has a space in it: the tree's (-S, -i, -U: an install under
# "Buildat Alpha", or a user's name with a space), the compiler's, the
# module's, its wasm/ source's and the cache's. Unquoted, each was split in
# two and no module built. This is the quoting's Linux half; the Windows
# half is util/package.sh's Wine smoke, which unpacks the archive under a
# directory with a space.
#   util/rccpp_space_path_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp rccpp_space_path; t=$CHECK_TMP
s="$t/with space"
real=$(command -v c++) || skip "no c++ in PATH"
mod="$s/an app/probe/main"
mkdir -p "$s/bin" "$mod/wasm"
ln -s "$here" "$s/the tree"
ln -s "$real" "$s/bin/c++"
echo '{"engine_api": 2, "kind": "check", "dependencies": []}' > "$mod/meta.json"
echo 'int toy(int a){ return a + 1; }' > "$mod/wasm/toy.c"
cat > "$mod/main.cpp" <<'EOF'
#include "interface/module.h"
#include "interface/server.h"
struct Module: public interface::Module
{
	Module(): interface::Module("main") {}
	void init() {}
};
extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module());
	}
}
EOF
cd "$here/Build" || fail "no Build/"
tree="$s/the tree"
timeout 600 nice -n 10 bin/buildat_server --unconfined --compile-only \
	-S "$tree" -i "$tree/src/interface" -U "$tree/3rdparty/Urho3D" \
	-c "$s/bin/c++" -m "$s/an app/probe" -C "$s/cache" -r "$s/cache/rccpp_build" \
	-D "$s/user" -l 4 > "$t/log" 2>&1 ||
	fail "the build under paths with spaces ($t/log): $(grep -a -A3 "Compile failed" "$t/log" | cut -c1-300)"
grep -aq "STATUS Compiling main" "$t/log" || fail "main was not compiled ($t/log)"
grep -aq "Compiler command: \[$s/bin/c++\]" "$t/log" ||
	fail "the compiler's probe did not take $s/bin/c++ ($t/log)"
echo "PASS: the loader and a module with wasm/ compiled with a space in every path"
