#!/bin/bash
# tier: quick
# cost: 3s
# covers: util/run_all.sh
# [RUN_ALL_PICK]: run_all.sh --changed --list on fixed historical ranges.
#   1. The [LIVELY_MENU] merge, whose client Lua broke the web play while
#      its own check passed: serverless_check or aitta_web_check is picked,
#      and the merge's own check (it is in the diff).
#   2. A commit that edits only a full-tier check picks that check.
#   3. A change to the page and the network module picks a web runner (one
#      that uses util/web_drive) and a native one.
#   util/run_all_pick_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
git -C "$here" cat-file -e 667081416 2>/dev/null || skip "no git history"
pick(){ "$here/util/run_all.sh" --changed "$1^..$1" --list | grep -E '\.sh$'; }
# 1.
p=$(pick 667081416)
echo "$p" | grep -qxE 'util/(serverless|aitta_web)_check\.sh' ||
	fail "the merge picked neither serverless_check nor aitta_web_check: $(echo $p)"
echo "$p" | grep -qx util/lively_menu_check.sh ||
	fail "the merge did not pick its own check: $(echo $p)"
# 2. 170eead63 edits util/world_move_check.sh alone
p=$(pick 170eead63)
echo "$p" | grep -qx util/world_move_check.sh ||
	fail "an edit to a full check did not pick it: $(echo $p)"
# 3. 3b557982d: builtin/network/network.cpp, src/client/web/index.html
p=$(pick 3b557982d)
webs=0 natives=0
for r in $(echo "$p" | grep -v '^util/serverless_check.sh$'); do
	f=$here/$r; [ -f "$f" ] || f=$here/builtin/luanti/test/$r
	grep -q '^# always:' "$f" && continue
	if grep -q web_drive "$f"; then webs=$((webs + 1)); else natives=$((natives + 1)); fi
done
[ "$webs" -gt 0 ] && [ "$natives" -gt 0 ] ||
	fail "a shared file got $webs web and $natives native runners: $(echo $p)"
echo "PASS: --changed picks every tier, a changed runner, native and web"
