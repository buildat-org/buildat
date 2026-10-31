#!/bin/bash
# tier: quick
# cost: ~2 s (2026-10-19)
# covers: util/run_all.sh
# [RUN_ALL_VERDICT]: run_all decides by the status and the verdict line
# both. Over five throwaway runners in a tree of their own -- a SKIP: line
# with 0, a syntax error (bash's 2), 0 with no verdict line, a plain PASS,
# a PASS: with 3 -- it counts a skip, three fails (the last shown its
# status, [RUN_ALL_PASS_THEN_FAIL]) and a pass. And ([REWORK_1019_FIXES]
# build 2) it prunes that tree's local/check first: a scripted cache file
# and a vanilla save 8 days old go, a fresh one of each stays.
#   util/run_all_verdict_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp run_all_verdict; t=$CHECK_TMP
mkdir -p "$t/util"
cp "$here/util/run_all.sh" "$here/util/check_lib.sh" "$t/util/"
r() { printf '#!/bin/bash\n# tier: quick\n%s\n' "$2" > "$t/util/$1_check.sh"
	chmod +x "$t/util/$1_check.sh"; }
c=$t/local/check
mkdir -p "$c/cache/scripted/remote/old" "$c/user/apps/vanilla/saves/old" \
	"$c/user/apps/vanilla/saves/new"
touch "$c/cache/scripted/remote/new" "$c/cache/scripted/remote/old/f"
touch -d '8 days ago' "$c/cache/scripted/remote/old/f" "$c/user/apps/vanilla/saves/old"
r a_skip 'echo "SKIP: no display"; exit 0'
r b_syntax 'if then fi'
r c_silent 'exit 0'
r d_pass 'echo "PASS: fine"'
r e_pass_then_fail 'echo "PASS: said"; exit 3'
(cd "$t" && env -u ONLY -u REMOTE bash util/run_all.sh quick) > "$t/out.txt" 2>&1
sum=$(grep -a "passed, " "$t/out.txt")
echo "$sum"
for want in "a_skip_check.sh:skip" "b_syntax_check.sh:FAIL" "c_silent_check.sh:FAIL" \
		"d_pass_check.sh:pass" "e_pass_then_fail_check.sh:FAIL"; do
	n=${want%:*}; s=${want#*:}
	grep -aq "^util/$n  *$s " "$t/out.txt" || fail "$n not counted $s ($t/out.txt)"
done
grep -aq "^util/e_pass_then_fail_check.sh .*PASS: said (exit status 3)$" "$t/out.txt" ||
	fail "a PASS: with 3 not shown its status ($t/out.txt)"
case "$sum" in "1 passed, 3 failed, 1 skipped,"*) ;; *) fail "the counts: $sum ($t/out.txt)";; esac
[ ! -e "$c/cache/scripted/remote/old" ] && [ ! -e "$c/user/apps/vanilla/saves/old" ] &&
	[ -e "$c/cache/scripted/remote/new" ] && [ -e "$c/user/apps/vanilla/saves/new" ] ||
	fail "the prune: $(cd "$c" && find . | tr '\n' ' ')"
grep -aq "^local/check: .* after pruning what is over 7 days old" "$t/out.txt" ||
	fail "the prune said nothing ($t/out.txt)"
echo "PASS: a SKIP: with 0 a skip, a syntax error and a silent 0 fails, a PASS: a pass, a PASS: with 3 a fail shown its status; local/check pruned of what is over 7 days old"
