#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: 60s (this desk, 2026-10-10)
# [FEATURE_SWEEP_1009]: a node name list with an alias in it matches the node
# the alias names, as Luanti's getIds() resolves it -- an ABM, an LBM or a
# find_nodes_* call a game wrote against an old name. The fixture places a
# node and finds it by an alias of its name; the log lists the game's ABMs
# and LBMs that name an alias (VoxeLibre has three LBMs). Then a save after
# a rename: one run saves a node, the next registers it under a new name
# with the old one an alias, and reads the node back as the new one -- as
# Luanti remaps a stored block's names.
#
#   GAME=mineclone2 builtin/luanti/test/alias.sh
#
# covers: builtin/luanti/lua/bootstrap.lua builtin/voxelworld/voxelworld.cpp builtin/luanti/mapgen_params.h
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/alias_check"; mkdir -p "$out"
save=buildat_test_alias
cd "$here/Build"
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME="${GAME:-minetest_game}" BUILDAT_LUANTI_SAVE=$save \
	BUILDAT_LUANTI_LUA="$me/alias.lua" \
	start_server "$out/srv.log" "aliascheck: done" 120 auto \
	timeout 150 bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
	skip "the run never got to its end; see $out/srv.log"
kill -INT $SERVER_PID 2>/dev/null
# A poll: the server's exit
for _ in $(seq 150); do kill -0 $SERVER_PID 2>/dev/null || break; sleep 0.2; done
grep -a "aliascheck:" "$out/srv.log" | sed 's/.*aliascheck: //'
grep -aq "aliascheck: find by alias 1, by name 1" "$out/srv.log" ||
	fail "find_nodes_in_area by an alias did not find the node"

# The rename, over two runs of the same save. r1's 1 s after the set is a
# settle: the write lands at the end of the step, before the stop saves it
P='{x = 3, y = 2001, z = 0}'
cat > "$out/r1.lua" <<L
core.register_node(":aliascheck:old", {description = "old"})
core.register_on_mods_loaded(function()
	core.emerge_area($P, $P, function(_, _, left)
		if left > 0 then return end
		core.set_node($P, {name = "aliascheck:old"})
		core.after(1, function() core.log("warning", "aliascheck: set") end)
	end)
end)
L
cat > "$out/r2.lua" <<L
core.register_node(":aliascheck:new", {description = "new"})
core.register_alias("aliascheck:old", "aliascheck:new")
core.register_on_mods_loaded(function()
	core.emerge_area($P, $P, function(_, _, left)
		if left > 0 then return end
		core.log("warning", "aliascheck: read " .. core.get_node($P).name)
	end)
end)
L
# And register_alias_force over a node still registered: the old node read
# back as the new one, and one placed by the old name now is the new one
cat > "$out/r3.lua" <<L
core.register_node(":aliascheck:old", {description = "old"})
core.register_node(":aliascheck:new", {description = "new"})
core.register_alias_force("aliascheck:old", "aliascheck:new")
core.register_on_mods_loaded(function()
	core.emerge_area($P, $P, function(_, _, left)
		if left > 0 then return end
		local saved = core.get_node($P).name
		local q = {x = 4, y = 2001, z = 0}
		core.set_node(q, {name = "aliascheck:old"})
		core.log("warning", "aliascheck: forced " .. saved .. " " .. core.get_node(q).name)
	end)
end)
L
for r in r1:set r2:read r1:set r3:forced; do
	BUILDAT_LUANTI_GAME="${GAME:-minetest_game}" BUILDAT_LUANTI_SAVE=$save \
		BUILDAT_LUANTI_LUA="$out/${r%:*}.lua" \
		start_server "$out/${r%:*}.log" "aliascheck: ${r#*:}" 120 auto \
		timeout 150 bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
		skip "run ${r%:*} never got to its end; see $out/${r%:*}.log"
	kill -INT $SERVER_PID 2>/dev/null
	# A poll: the server's exit
	for _ in $(seq 150); do kill -0 $SERVER_PID 2>/dev/null || break; sleep 0.2; done
done
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
forced=$(grep -a "aliascheck: forced" "$out/r3.log" | sed 's/.*aliascheck: forced //')
echo "forced alias: saved and placed read as: $forced"
[ "$forced" = "aliascheck:new aliascheck:new" ] || fail "register_alias_force: $forced"
got=$(grep -a "aliascheck: read" "$out/r2.log" | sed 's/.*aliascheck: read //')
echo "renamed node read back as: $got"
[ "$got" = aliascheck:new ] || fail "the saved node under its old name read as $got"
echo "PASS: an alias in a node name list matches its node; a saved node renamed reads as its new name"
