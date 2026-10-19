#!/bin/bash
# tier: quick
# ci
# cost: ~2 s (2026-10-19)
# luanti_client's engine-free checks, test.lua: the serialization, the
# connection over a fake socket, the inventory and its dig rules
# ([REWORK_1019_FIXES] luanti 2), the forms, the light.
#   extensions/luanti_client/lua_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
lua=$(command -v luajit || command -v lua) || skip "no luajit or lua"
out=$("$lua" "$here/extensions/luanti_client/test.lua" 2>&1) ||
	fail "test.lua: $(echo "$out" | tail -3)"
echo "$out" | tail -1 | grep -q "luanti_client/test.lua: ok" || fail "test.lua said no ok: $(echo "$out" | tail -1)"
echo "PASS: luanti_client's test.lua, $(echo "$out" | grep -c ': ok$') parts ok"
