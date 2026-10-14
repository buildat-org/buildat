#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-14)
# covers: builtin/voxelworld/voxelworld.cpp
# [SECTION_EDGE_FACES]: a voxel dug at a chunk's edge makes the chunk
# across that edge commit again, so its copy of the edge (the padding the
# mesher culls against) has the hole in it. Vanilla on the minimal game, no
# client: a fixture fills a block of stone across y -32 (chunks are 32
# high) and digs (2,-32,2), the bottom of chunk y -1; after the dig the
# server commits chunk (0,-2,0) too. A dig inside a chunk commits no
# neighbour.
#   util/chunk_edge_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp chunk_edge; t=$CHECK_TMP
d=$t/v
mkdir -p "$d/apps/vanilla/saves/ce/luanti" "$d/shared"
cat > "$d/shared/fixture.lua" <<'L'
local function say(s) core.log("warning", "ce: " .. s) end
core.after(3, function()
	core.emerge_area({x = -8, y = -48, z = -8}, {x = 8, y = -16, z = 8},
			function(_, _, left)
		if left > 0 then return end
		for x = -4, 4 do for y = -40, -24 do for z = -4, 4 do
			core.set_node({x = x, y = y, z = z}, {name = "floor:stone"})
		end end end
		say("built")
		core.after(3, function()
			core.remove_node({x = 2, y = -28, z = 2})
			say("dug inside")
			core.after(3, function()
				core.remove_node({x = 2, y = -32, z = 2})
				say("dug at the edge")
				core.after(3, function() say("done") end)
			end)
		end)
	end)
end)
L
printf "enable_damage = false\n" > "$d/apps/vanilla/saves/ce/luanti/world.mt"
BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=ce \
BUILDAT_LUANTI_LUA="$d/shared/fixture.lua" start_server "$t/s.log" \
	"ce: done" 180 auto "$here/Build/bin/buildat_server" \
	-u launcher=1 -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" \
	-C "$d.cache" -l 5 || fail "the server ($t/s.log)"
CHECK_PIDS+=($SERVER_PID)
# The chunks committed between one fixture line and the next
between(){ sed -n "/ce: $1/,/ce: $2/p" "$t/s.log" | grep -ao 'Committing chunk ([-0-9, ]*)' | sort -u; }
inside=$(between "dug inside" "dug at the edge")
edge=$(between "dug at the edge" "done")
echo "inside: $(echo $inside | grep -o "(0, -[12], 0)" | tr "\n" " ")"
echo "edge: $(echo $edge | grep -o "(0, -[12], 0)" | tr "\n" " ")"
grep -q "(0, -1, 0)" <<< "$inside" || fail "the inside dig committed no chunk (0,-1,0)"
grep -q "(0, -2, 0)" <<< "$inside" && fail "the inside dig committed the chunk below too"
grep -q "(0, -1, 0)" <<< "$edge" || fail "the edge dig committed no chunk (0,-1,0)"
grep -q "(0, -2, 0)" <<< "$edge" || fail "the edge dig left chunk (0,-2,0)'s copy of the edge stale"
echo "PASS: a dig at a chunk edge commits the chunk across it, a dig inside does not"
# vim: set noet ts=4 sw=4:
