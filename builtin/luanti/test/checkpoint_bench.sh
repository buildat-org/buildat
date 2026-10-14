#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: long
# [SAVE_CHECKPOINT]'s benchmark: what a checkpoint costs the step. A
# headless vanilla server on GAME (mineclone2, VoxeLibre) with POINTS
# load points standing in for players -- each a forceloaded 80x48x80 area
# walking its own lane at 4 m/s, digging and placing a node a second --
# for MINUTES, with --save-interval INTERVAL (0: off). BUSY=1 keeps the
# disk busy beside it (dd writing and syncing 256 MB at a time; fio is not
# assumed). Prints the gaps between globalsteps (p50, p99, max: what a
# checkpoint on the step adds to) and the checkpoints' own lines.
#
#   POINTS=20 INTERVAL=5.3 MINUTES=5 builtin/luanti/test/checkpoint_bench.sh
#
# The save is under DIR (local/checkpoint_bench), on the disk being
# measured: /tmp is often memory. simplified: forceloaded areas and not
# players, so the game's active range (ABMs, liquids, a farm's growth)
# runs only around the spawn; a client per point is the upgrade, at the
# cost of rendering on the same machine.
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
GAME="${GAME:-mineclone2}" POINTS="${POINTS:-20}" INTERVAL="${INTERVAL:-5.3}"
MINUTES="${MINUTES:-5}" BUSY="${BUSY:-0}" DIR="${DIR:-$here/local/checkpoint_bench}"
game=""
for g in "$BUILDAT_USER_PATH" "$here/user"; do
	[ -d "$g/shared/vanilla/games/$GAME" ] && { game="$g/shared/vanilla/games/$GAME"; break; }
done
[ -n "$game" ] || { echo "SKIP: $GAME is not installed"; exit "$SKIP"; }
run="$DIR/p${POINTS}_i${INTERVAL}_b${BUSY}"
rm -rf "$run"; mkdir -p "$run/u/shared/vanilla/games" "$run/u/apps/vanilla/saves/bench/luanti"
cp -a "$game" "$run/u/shared/vanilla/games/"
echo "enable_damage = false" > "$run/u/apps/vanilla/saves/bench/luanti/world.mt"
cat > "$run/u/shared/bench.lua" <<L
local POINTS, SECONDS = $POINTS, $MINUTES * 60
local gaps, last, t0 = {}, nil, nil
local pos = {}
for i = 1, POINTS do pos[i] = {x = 0, y = 16, z = (i - 1) * 300} end
local function area(p, on)
	local bx, by, bz = math.floor(p.x / 16), math.floor(p.y / 16), math.floor(p.z / 16)
	for x = bx - 2, bx + 2 do for y = by - 1, by + 1 do for z = bz - 2, bz + 2 do
		if on then core.__forceload_block_raw({x = x, y = y, z = z})
		else core.__forceload_free_block_raw({x = x, y = y, z = z}) end
	end end end
end
local acc, done = 0, false
core.register_globalstep(function(dtime)
	local now = core.get_us_time()
	if t0 == nil then
		t0 = now
		for i = 1, POINTS do area(pos[i], true) end
	end
	if last then gaps[#gaps + 1] = (now - last) / 1000 end
	last = now
	if done then return end
	acc = acc + dtime
	if acc >= 1 then
		acc = 0
		for i = 1, POINTS do
			local p = pos[i]
			area(p, false)
			p.x = p.x + 4
			area(p, true)
			core.set_node({x = p.x, y = p.y + 2, z = p.z + 3}, {name = "mcl_core:cobble"})
			core.set_node({x = p.x - 4, y = p.y + 2, z = p.z + 3}, {name = "air"})
		end
	end
	if (now - t0) / 1e6 >= SECONDS then
		done = true
		table.sort(gaps)
		local n = #gaps
		core.log("action", string.format("bench: %d steps, gap p50 %.1f ms, p99 %.1f ms, max %.1f ms",
				n, gaps[math.ceil(n * 0.5)], gaps[math.ceil(n * 0.99)], gaps[n]))
		core.log("action", "bench: done")
	end
end)
L
cd "$here/Build"
busy=""
if [ "$BUSY" = 1 ]; then
	( while :; do dd if=/dev/zero of="$DIR/busy.bin" bs=1M count=256 conv=fsync status=none; done ) &
	busy=$!
fi
trap '[ -n "$busy" ] && kill "$busy" 2>/dev/null; rm -f "$DIR/busy.bin"; check_cleanup' EXIT
BUILDAT_LUANTI_GAME="$GAME" BUILDAT_LUANTI_SAVE=bench BUILDAT_LUANTI_SEED=5 \
	BUILDAT_LUANTI_LUA="$run/u/shared/bench.lua" \
	start_server "$run/srv.log" "Mods loaded" 300 auto bin/buildat_server -u launcher=1 \
	-A 127.0.0.1 -m ../apps/vanilla -D "$run/u" -C "$run/c" -l 4 --save-interval "$INTERVAL" ||
	fail "the server did not start ($run/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$run/srv.log" "bench: done" $((MINUTES * 60 + 300)) || fail "no end ($run/srv.log)"
kill -INT "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
grep -a "bench: [0-9]" "$run/srv.log" | sed 's/.*bench: //'
# The checkpoints: total ms, then the parts voxelworld's line names
grep -a "voxelwor: save: " "$run/srv.log" | sed 's/.*save: //; s/[^0-9 ]//g' |
	awk '$2 + 0 > 0 || $1 > 0 { n++; ms[n] = $1; s += $2; kb += $3;
		for (i = 4; i <= 8; i++) part[i] += $i }
	END { if (!n) { print "no checkpoints"; exit }
		asort(ms); printf "checkpoints: %d, ms p50 %d p99 %d max %d; %d sections, %d kB in all; " \
			"waiting %d, copy %d, renumber %d, rows %d, commit %d ms in all\n", n,
			ms[int((n + 1) / 2)], ms[int(n * 0.99 + 0.999)], ms[n], s, kb, part[4], part[5], part[6], part[7], part[8] }'
echo "PASS: $run"
