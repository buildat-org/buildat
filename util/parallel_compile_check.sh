#!/bin/bash
# tier: quick
# cost: ~60s (2026-10-04)
# covers: src/server/state.cpp src/server/rccpp.cpp builtin/loader/loader.cpp
# [PARALLEL_COMPILE]: apps/sample_module_calls's modules, from an empty build cache,
# compiled side by side; with the memory reserve raised past what any
# machine has, one at a time, said so; and a module that does not compile
# fails the start, naming it.
#
#   util/parallel_compile_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/Build/bin/buildat_server"
[ -x "$b" ] || { echo "FAIL: no $b"; exit 1; }
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }
cd "$here/Build"
run(){ # build dir, app, log
	BUILDAT_UNCONFINED=1 timeout 300 "$b" --compile-only -m "$2" \
		-D "$t/user" -r "$1" > "$3" 2>&1
	local s=$?
	return $s
}

run "$t/b1" "$here/apps/sample_module_calls" "$t/1.log" || fail "the start failed
$(tail -5 "$t/1.log")"
n=$(grep -o "Compiled [0-9]* of [0-9]* modules, at most [0-9]*" "$t/1.log" |
	awk '{print $NF}')
[ "${n:-0}" -ge 2 ] || fail "not side by side: $(grep "Compil" "$t/1.log")"
grep -q "STATUS Compiling [a-z_]*, " "$t/1.log" ||
	fail "no progress line names several"

BUILDAT_COMPILE_RESERVE_MB=100000000 run "$t/b2" "$here/apps/sample_module_calls" \
	"$t/2.log" || fail "the start failed under the reserve"
grep -q "at most 1 at once, no more for memory" "$t/2.log" ||
	fail "not one at a time under the reserve: $(grep "Compiled" "$t/2.log")"

cp -r "$here/apps/sample_module_calls" "$t/app"
echo "this does not compile" >> "$t/app/test2/test2.cpp"
run "$t/b3" "$t/app" "$t/3.log" && fail "a broken module started"
grep -q "Error compiling module test2" "$t/3.log" ||
	fail "the failure does not name test2: $(grep -i "fail\|error" "$t/3.log" | tail -3)"
echo "PASS: $n at once; one under the reserve; test2's error named"
