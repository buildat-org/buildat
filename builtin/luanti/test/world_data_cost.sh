#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: ~15 s (2026-10-29)
# covers: builtin/luanti/vendor/builtin/common/serialize.lua
# [WORLD_DATA_COST]: a world's saved data cannot make the server hold more
# memory than it is big. A crafted save of the minimal game whose
# force_loaded.txt (read by core.deserialize as the game loads) grows a
# 128 MiB string in one instruction, ("x"):rep(2^27); the fixture then
# deserializes a string doubled by .. 27 times, and an honest table. Each
# big one is refused ("not enough memory"), the honest one reads, and Lua
# holds well under 128 MiB. The server runs under ulimit -v, so a
# regression fails without taking the machine's memory.
#   builtin/luanti/test/world_data_cost.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
check_tmp world_data_cost; t=$CHECK_TMP
cd "$here/Build"
s=$t/u/apps/vanilla/saves/wdc
mkdir -p "$s/luanti" "$t/u/shared"
echo 'enable_damage = false' > "$s/luanti/world.mt"
echo 'return {("x"):rep(2^27)}' > "$s/luanti/force_loaded.txt"
cat > "$t/u/shared/fixture.lua" <<'L'
core.after(0, function()
	local v, err = core.deserialize(
			'local a = "x" for i = 1, 27 do a = a .. a end return {a}')
	core.log("action", "wdc: doubled " .. tostring(v) .. " " .. tostring(err))
	local t = core.deserialize(core.serialize({a = 1, b = {"c", 2}}))
	core.log("action", "wdc: honest " .. tostring(t and t.b[1]))
	collectgarbage("collect")
	core.log("action", "wdc: lua memory " ..
			math.floor(collectgarbage("count") / 1024) .. " MiB")
end)
L
# simplified: virtual memory, which the server reserves far more of than
# it uses; 12 GB keeps a 2^30 regression from swapping the machine
ulimit -v 12000000
BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9 BUILDAT_LUANTI_GAME=minimal \
BUILDAT_LUANTI_SAVE=wdc BUILDAT_LUANTI_LUA="$t/u/shared/fixture.lua" \
	start_server "$t/s.log" "wdc: lua memory" 180 auto \
	bin/buildat_server -u launcher=1 -A 127.0.0.1 -m ../apps/vanilla \
	-D "$t/u" -l 3 || fail "the server ($t/s.log)"
CHECK_PIDS+=($SERVER_PID)
grep -a "wdc:" "$t/s.log"
grep -aq "wdc: doubled nil .*not enough memory" "$t/s.log" ||
	fail "the doubled string was not refused ($t/s.log)"
grep -aq "wdc: honest c" "$t/s.log" || fail "an honest table did not read"
mib=$(grep -ao "wdc: lua memory [0-9]*" "$t/s.log" | grep -o "[0-9]*$")
[ "$mib" -lt 64 ] || fail "Lua holds $mib MiB: force_loaded.txt's string was made"
echo "PASS: a world's saved data refused past its memory cap; honest data reads"
