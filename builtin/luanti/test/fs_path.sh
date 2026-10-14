#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# [FS_PATH_0676]: VoxeLibre's recipe book and its help categories open on a
# vanilla server. The server's core.get_translated_string() runs the
# clients' shared formspec.lua, which moved in 0.6.76 to
# extensions/luanti_client/res and left the server reading the old path
# ("cannot open .../client_lua/formspec.lua"). With a player joined, the
# fixture opens the recipe book, its search and every help category, each
# in a pcall, and logs what each did.
#
#   builtin/luanti/test/fs_path.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/fs_path"; mkdir -p "$out"
save=buildat_test_fs_path
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running"; exit 77
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
cat > "$out/fixture.lua" <<'LUA'
local function try(what, f, ...)
	local ok, err = pcall(f, ...)
	core.log("action", "fs_path: " .. what .. " " ..
			(ok and "ok" or "error " .. tostring(err)))
end
core.register_on_joinplayer(function(player)
	core.after(3, function()
		local name = player:get_player_name()
		try("translated", core.get_translated_string, "en", "x")
		try("recipe book", mcl_craftguide.show, name)
		-- What a typed search runs: every item's description translated
		try("recipe search", function()
			for _, f in ipairs(core.registered_on_player_receive_fields) do
				f(player, "mcl_craftguide", {filter = "stone",
						search = "true"})
			end
		end)
		for id in pairs(doc.data.categories) do
			try("help " .. id, doc.show_category, name, id)
		end
		core.log("action", "fs_path: done")
	end)
end)
LUA
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
	BUILDAT_LUANTI_LUA="$out/fixture.lua" \
	start_server "$out/srv.log" "Mods loaded" 120 29794 \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
srv=$SERVER_PID
trap 'kill -INT "$srv" 2>/dev/null' EXIT
# The client only has to be joined: it is held there, and ended as soon as
# the server's fixture says it is done
printf 'delay 60000\nquit\n' > "$out/cmds.txt"
timeout 120 bin/buildat -s localhost:29794 -w 800x600 -l 3 \
	-o sound_mute=1 -c @"$out/cmds.txt" > "$out/cli.log" 2>&1 &
cli=$!
for _i in $(seq 600); do
	grep -aq 'fs_path: done' "$out/srv.log" && break
	kill -0 "$cli" 2>/dev/null || break
	sleep 0.1
done
kill "$cli" 2>/dev/null
wait "$cli" 2>/dev/null
grep -ao 'fs_path: .*' "$out/srv.log"
grep -aq 'fs_path: done' "$out/srv.log" ||
	{ echo "FAIL: the fixture did not run"; exit 1; }
grep -aq 'fs_path: help ' "$out/srv.log" ||
	{ echo "FAIL: no help categories"; exit 1; }
if grep -aE 'fs_path: .* error|cannot open' "$out/srv.log"; then
	echo "FAIL: the recipe book or a help category failed"; exit 1
fi
echo "PASS: the recipe book, its search and every help category open"
