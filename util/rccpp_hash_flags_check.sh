#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: ~1 min cold, seconds warm (2026-11-06)
# covers: src/server/state.cpp src/server/rccpp.cpp util/package.sh
# [RCCPP_HASH_FLAGS] What a module is built with is in its build's cache
# check, so changing it rebuilds: a meta.json's flags and the compiler's
# version. What does not change the build does not rebuild it: another run,
# the module's directory moved (wasm/ sources on the flags, by absolute
# path), the same compiler under another name. And a build made to travel,
# its .hash cut as util/package.sh cuts it, loads under any compiler, as
# does any build where there is no compiler to compare.
# The fixed flags are not driven here: changing them takes a server build.
#   util/rccpp_hash_flags_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp rccpp_hash_flags; t=$CHECK_TMP
c=$t/cache
mod=$t/a/probe/main
mkdir -p "$mod/wasm" "$t/fake" "$t/other"
meta() # <the flags' json fields, each with its comma>
{
	echo "{\"engine_api\": 2, \"kind\": \"check\", $1 \"dependencies\": []}" \
		> "$mod/meta.json"
}
meta ""
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
# The real compiler, answering another version. Only the loader and main are
# ever at stake here, so the rebuilds are seconds.
real=$(command -v c++) || skip "no c++ in PATH"
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "c++ (GCC) 99.9.9"; exit 0; }\nexec %s "$@"\n' "$real" \
	> "$t/fake/c++"
chmod +x "$t/fake/c++"
cd "$here/Build" || fail "no Build/"
bin=$PWD/bin/buildat_server

run() # <log> <app dir> [flags...]
{
	local log=$t/$1 app=$2; shift 2
	timeout 600 nice -n 10 env ${run_path:+PATH=$run_path} "$bin" --unconfined --compile-only -m "$app" -C "$c" -r "$c/rccpp_build" \
			-D "$t/user" -l 4 "$@" > "$log" 2>&1
}
current() # <log>: nothing was compiled, main looked at and found current
{
	grep -aq "No need to recompile main" "$t/$1" ||
		fail "$1: main not found current ($t/$1)"
	grep -aq "the cached hash differs\|STATUS Compiling" "$t/$1" &&
		fail "$1: a rebuild ($t/$1)"
	[ -z "$(find "$c/rccpp_build" -maxdepth 1 -name 'compiler_version.*')" ] ||
		fail "$1: the compiler's version file was left behind"
}
main_rebuilt() # <log>: main only, and it compiled
{
	grep -aq "main: the cached hash differs" "$t/$1" ||
		fail "$1: main was not rebuilt ($t/$1)"
	grep -a "the cached hash differs" "$t/$1" | grep -avq "main: the cached" &&
		fail "$1: more than main was rebuilt ($t/$1)"
	return 0
}

run first.log "$t/a/probe" || fail "the first build ($t/first.log)"
hash=$c/rccpp_build/probe_main.so.hash
[ -f "$hash" ] || fail "no $hash"
sed -n 2p "$hash" | grep -q . || fail "no compiler's line in $hash"
echo "ok: built, the .hash says by what: $(sed -n 2p "$hash")"

run again.log "$t/a/probe" || fail "the second run ($t/again.log)"
current again.log
echo "ok: another run reuses the cache"

mkdir -p "$t/moved/deeper"
cp -a "$t/a/probe" "$t/moved/deeper/probe"
run moved.log "$t/moved/deeper/probe" || fail "the moved run ($t/moved.log)"
current moved.log
echo "ok: the module's directory moved (wasm/ sources included) reuses the cache"

n=0
for f in cxxflags ldflags cxxflags_linux ldflags_linux; do
	n=$((n + 1))
	case $f in
		cxx*) v=-DRCCPP_HASH_FLAGS_CHECK ;;
		*) v=-lm ;;
	esac
	meta "\"$f\": \"$v\","
	run "$f.log" "$t/a/probe" || fail "$f changed ($t/$f.log)"
	main_rebuilt "$f.log"
	run "$f.again.log" "$t/a/probe" || fail "$f again ($t/$f.again.log)"
	current "$f.again.log"
	echo "ok: meta.json's $f changed rebuilds main, and only once"
done
meta ""
run reset.log "$t/a/probe" || fail "the flags taken off ($t/reset.log)"
main_rebuilt reset.log

# The same compiler, by another path and name: gcc prints the name it was run
# by first on its --version line
if gxx=$(command -v g++); then
	ln -s "$gxx" "$t/other/g++"
	run renamed.log "$t/a/probe" -c "$t/other/g++" || fail "renamed ($t/renamed.log)"
	current renamed.log
	echo "ok: the same compiler by another path and name reuses the cache"
fi

run version.log "$t/a/probe" -c "$t/fake/c++" ||
	fail "another compiler version ($t/version.log)"
grep -aq "main: the cached hash differs" "$t/version.log" ||
	fail "another compiler version did not rebuild main ($t/version.log)"
grep -aq "loader: the cached hash differs" "$t/version.log" ||
	fail "another compiler version did not rebuild the loader ($t/version.log)"
sed -n 2p "$hash" | grep -q 99.9.9 || fail "the .hash does not say the new compiler"
run version2.log "$t/a/probe" -c "$t/fake/c++" || fail "it again ($t/version2.log)"
current version2.log
run back.log "$t/a/probe" || fail "the compiler back ($t/back.log)"
grep -aq "main: the cached hash differs" "$t/back.log" ||
	fail "the older compiler did not rebuild main ($t/back.log)"
echo "ok: another compiler version rebuilds every module, once"

# No compiler at all: what the cache holds is what there is
mkdir "$t/nopath"
run_path=$t/nopath run nocompiler.log "$t/a/probe" ||
	fail "no compiler, a whole cache ($t/nocompiler.log)"
grep -aq "No C++ compiler" "$t/nocompiler.log" ||
	fail "that run found a compiler after all ($t/nocompiler.log)"
current nocompiler.log
echo "ok: no compiler, a build of a known compiler loads"

# As util/package.sh leaves an archive's cache
sed -i 2d "$c"/rccpp_build/*.hash 2>/dev/null || true
run archive.log "$t/a/probe" -c "$t/fake/c++" ||
	fail "an archive's cache under another compiler ($t/archive.log)"
current archive.log
echo "ok: a .hash with the compiler's line cut loads under another compiler"

# And a source still counts
echo '// changed' >> "$mod/main.cpp"
run source.log "$t/a/probe" || fail "the source changed ($t/source.log)"
main_rebuilt source.log
echo "PASS: a module's flags and the compiler's version rebuild it, another run, path or a traveling build do not"
