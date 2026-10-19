#!/bin/bash
# tier: quick
# cost: ~2 s (2026-10-19)
# covers: util/run_all.sh
# [RUN_ALL_VERDICT]: run_all decides by the status and the verdict line
# both. Over four throwaway runners in a tree of their own -- a SKIP: line
# with 0, a syntax error (bash's 2), 0 with no verdict line, a plain PASS --
# it counts a skip, two fails and a pass.
#   util/run_all_verdict_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp run_all_verdict; t=$CHECK_TMP
mkdir -p "$t/util"
cp "$here/util/run_all.sh" "$here/util/check_lib.sh" "$t/util/"
r() { printf '#!/bin/bash\n# tier: quick\n%s\n' "$2" > "$t/util/$1_check.sh"
	chmod +x "$t/util/$1_check.sh"; }
r a_skip 'echo "SKIP: no display"; exit 0'
r b_syntax 'if then fi'
r c_silent 'exit 0'
r d_pass 'echo "PASS: fine"'
(cd "$t" && bash util/run_all.sh quick) > "$t/out.txt" 2>&1
sum=$(grep -a "passed, " "$t/out.txt")
echo "$sum"
for want in "a_skip_check.sh:skip" "b_syntax_check.sh:FAIL" "c_silent_check.sh:FAIL" \
		"d_pass_check.sh:pass"; do
	n=${want%:*}; s=${want#*:}
	grep -aq "^util/$n  *$s " "$t/out.txt" || fail "$n not counted $s ($t/out.txt)"
done
case "$sum" in "1 passed, 2 failed, 1 skipped,"*) ;; *) fail "the counts: $sum ($t/out.txt)";; esac
echo "PASS: a SKIP: with 0 a skip, a syntax error and a silent 0 fails, a PASS: a pass"
