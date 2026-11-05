#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: ~1 min (2026-11-05)
# covers: src/server/state.cpp
# [BUILTIN_PREBUILD_STALE] A boxed server loads a module from the shared
# build when the hash matches there, also when its app's own cache holds an
# older copy of that module: every app had one, so a changed builtin was
# compiled again for each app, make's prebuild unused.
#   util/builtin_prebuild_stale_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp prebuild_stale; t=$CHECK_TMP
app=sample_ui
c=$t/cache
own=$c/apps/$app/rccpp_build
mkdir -p "$c"
# A warm start if the tree has one; what is not current compiles here
cp -a "$here/cache/rccpp_build" "$c/rccpp_build" 2>/dev/null
cd "$here/Build" || fail "no Build/"
run() # <log> <flags...>
{
	local log=$1; shift
	timeout 300 bin/buildat_server --compile-only -m "../apps/$app" -C "$c" \
			-D "$t/user" -l 4 "$@" > "$log" 2>&1 ||
		fail "the server failed ($log)"
}
run "$t/shared.log" --unconfined
run "$t/first.log"
grep -aq "network: the shared build's is current" "$t/first.log" ||
	fail "no copy in the app's cache and the shared build not used ($t/first.log)"
mod=$c/rccpp_build/builtin_network.so
[ -f "$mod" ] || fail "no $mod"
cp "$mod" "$own/builtin_network.so"
echo stale > "$own/builtin_network.so.hash"
run "$t/stale.log"
grep -aq "network: the cached hash differs" "$t/stale.log" &&
	fail "compiled over a current shared build ($t/stale.log)"
grep -aq "network: the shared build's is current" "$t/stale.log" ||
	fail "an older copy in the app's cache hid the shared build ($t/stale.log)"
cmp -s "$own/builtin_network.so.hash" <(echo stale) ||
	fail "the app's own copy was rebuilt ($t/stale.log)"
echo "PASS: a current shared build beats an older copy in the app's cache"
