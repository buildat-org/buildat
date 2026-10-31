#!/bin/bash
# tier: quick
# cost: ~1 s (2026-10-19)
# [BUILD_IS_TREE]: check_lib's check_build over made-up builds. One of the
# commit before src last changed fails, naming a changed path; HEAD's
# passes; one with no hash (built before the tag) fails; the old one with
# BUILDAT_STALE_OK=1 passes, said; a hash git does not know passes.
# A web build ([STALE_GUARD_BUILTIN]): one of the commit before
# builtin/luanti/client_data last changed fails (the bundle packs it); one
# of the last commit the bundle's paths changed in passes, though builtin/
# changed after it -- when it did, else that half is said not run.
#   util/build_is_tree_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
git -C "$here" rev-parse -q --verify HEAD > /dev/null || skip "no git checkout"
check_tmp build_is_tree; t=$CHECK_TMP
old=$(git -C "$here" rev-parse --short "$(git -C "$here" rev-list -1 HEAD -- src)~1")
head=$(git -C "$here" rev-parse --short HEAD)
printf 'x\0buildat-git-hash:%s\0y' "$old" > "$t/old"
printf 'x\0buildat-git-hash:%s-dirty\0y' "$head" > "$t/head"
printf 'x\0y' > "$t/none"
printf 'x\0buildat-git-hash:0123456789ab\0y' > "$t/unknown"
# by <file> [env...]: check_build's status and output over it
by(){ local f=$1; shift; env "$@" bash -c '. "$1/util/check_lib.sh"; check_build ${KIND:-native} "$2"' _ \
	"$here" "$f" 2>&1; }
o=$(by "$t/old") && fail "an old build passed"
echo "$o" | grep -q "^FAIL: the build is older than the tree: rebuild (.* is of $old; changed since: .*src/" ||
	fail "the old build's line: $o"
o=$(by "$t/head") || fail "HEAD's build failed: $o"
o=$(by "$t/none") && fail "a build with no hash passed"
echo "$o" | grep -q "built before \[BUILD_IS_TREE\]" || fail "the hashless build's line: $o"
o=$(by "$t/old" BUILDAT_STALE_OK=1) || fail "BUILDAT_STALE_OK failed: $o"
echo "$o" | grep -q "^check_build: BUILDAT_STALE_OK: .* is of $old" || fail "BUILDAT_STALE_OK said: $o"
o=$(by "$t/unknown") || fail "an unknown hash failed: $o"
# The web bundle's paths: CMakeLists.txt's WEB_PRELOAD's and the native's
packed="src 3rdparty CMakeLists.txt client extensions builtin/luanti/client_data
	builtin/voxel_shading/client_data builtin/client_lua/client_lua/wasm_main.lua"
grep -q 'builtin/luanti/client_data@' "$here/CMakeLists.txt" ||
	fail "CMakeLists.txt's WEB_PRELOAD no longer packs builtin/luanti/client_data"
wold=$(git -C "$here" rev-parse --short "$(git -C "$here" rev-list -1 HEAD -- builtin/luanti/client_data)~1")
printf 'x\0buildat-git-hash:%s\0y' "$wold" > "$t/wold"
o=$(KIND=web by "$t/wold") && fail "a web build before client_data's change passed"
# shellcheck disable=SC2086
wlast=$(git -C "$here" rev-parse --short "$(git -C "$here" rev-list -1 HEAD -- $packed)")
printf 'x\0buildat-git-hash:%s\0y' "$wlast" > "$t/wlast"
o=$(KIND=web by "$t/wlast") || fail "a web build of the bundle's last change failed: $o"
if [ -n "$(git -C "$here" diff --name-only "$wlast" HEAD -- builtin)" ]; then
	echo "ok: a web build of $wlast passes, builtin/ changed since outside the bundle"
else
	echo "ok: (builtin/ unchanged since $wlast: the pass over a server-side change not run)"
fi
echo "PASS: a build of $old (before src's last change) fails, HEAD's passes, a hashless one fails, BUILDAT_STALE_OK lets the old through; a web build is stale by what the bundle packs"
