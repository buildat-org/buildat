#!/bin/bash
# tier: quick
# ci
# cost: ~60s (2026-10-04)
# covers: src/server/state.cpp src/server/rccpp.cpp builtin/loader/loader.cpp
# [PARALLEL_COMPILE]: apps/sample_module_calls's modules, from an empty build cache,
# compiled side by side; with the memory reserve raised past what any
# machine has, one at a time, said so; and a module that does not compile
# fails the start, naming it; a compiler's "cannot execute" is tried once
# more ([WIN_PACKAGE_052]). [COMPILE_SLOTS]: with every shared slot held
# by another process, one at a time; with a slot directory that is not
# the user's own, one at a time and said so.
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
# The check's own slots, not the other servers' on this desk
mkdir -m 0700 "$t/slots"
export BUILDAT_COMPILE_SLOTS="$t/slots"
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
# [WIN_PACKAGE_052] A compiler that could not start a program of its own
# once is run once more: the first compile says what Wine's gcc said
cat > "$t/cxx" <<SH
#!/bin/sh
case "\$*" in *" -shared "*) mkdir "$t/cxx.once" 2>/dev/null && { echo "c++: fatal error: cannot execute 'cc1plus': CreateProcess: No such file or directory"; exit 1; } ;; esac
exec c++ "\$@"
SH
chmod +x "$t/cxx"
BUILDAT_UNCONFINED=1 timeout 300 "$b" --compile-only -m "$here/apps/sample_module_calls" \
	-D "$t/user" -r "$t/b4" -c "$t/cxx" > "$t/4.log" 2>&1 ||
	fail "a compiler's one failed start failed the start: $(grep -a "W " "$t/4.log" | tail -3)"
grep -q "could not start a program of its own; once more" "$t/4.log" ||
	fail "no retry said: $(grep -a "W " "$t/4.log" | tail -3)"
# [COMPILE_SLOTS] Every slot held by another process: the server's first
# compile needs none, the rest wait for one
holders=""
for i in $(seq 0 $(( $(nproc) / 2 > 1 ? $(nproc) / 2 - 1 : 0 ))); do
	flock -n "$t/slots/slot$i" sleep 300 &
	holders="$holders $!"
done
run "$t/b5" "$here/apps/sample_module_calls" "$t/5.log"
s=$?
# shellcheck disable=SC2086 # the PIDs, split
kill $holders 2>/dev/null
[ $s = 0 ] || fail "the start failed with the slots held: $(tail -3 "$t/5.log")"
grep -q "at most 1 at once, no more for the slots other servers' compiles share" "$t/5.log" ||
	fail "not one at a time with the slots held: $(grep "Compiled" "$t/5.log")"
# A slot directory others may read: not used, one at a time
mkdir -m 0755 "$t/open"
BUILDAT_COMPILE_SLOTS="$t/open" run "$t/b6" "$here/apps/sample_module_calls" "$t/6.log" ||
	fail "the start failed with no slots: $(tail -3 "$t/6.log")"
grep -q "is not this user's own directory; compiling one module at a time" "$t/6.log" &&
	grep -q "at most 1 at once, no more for no compile slots" "$t/6.log" ||
	fail "no slots: not one at a time, or not said: $(grep "slot\|Compiled" "$t/6.log")"
echo "PASS: $n at once; one under the reserve; test2's error named; a failed start retried; one at a time with the slots held or none"
