#!/bin/bash
# tier: full
# cost: ~30 s (2026-10-27)
# covers: src/client/app.cpp
# [CACHE_TMP_SHADOWS]: a game writes PNGs with compose_image under the
# cache, at <cache>/tmp/launch_menu/res/icon_local.png and
# <cache>/server_icons/launch_menu/res/icon_network.png, 3x5 both. A
# second client on the same cache reads those plain names: it gets the
# client's installed icons (120x120, 128x128), not the written files.
#   util/cache_tmp_shadows_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp cache_tmp_shadows; t=$CHECK_TMP
app="$t/u/dev_apps/shadow_write"
mkdir -p "$app/launcher" "$app/main/client_lua" "$t/c"
cat > "$app/launcher/init.lua" <<'EOF'
return function(ctx) return {{id = "run", label = "shadow_write",
	run = function() ctx.launch{app = "shadow_write"} end}} end
EOF
cat > "$app/main/meta.json" <<'EOF'
{"engine_api": 2, "kind": "check", "disable_cpp": true,
	"client_main": "init.lua",
	"dependencies": [{"module": "network"}, {"module": "client_lua"}]}
EOF
cat > "$app/main/client_lua/init.lua" <<'EOF'
local log = buildat.Logger("shadow_write")
local function size(name)
	local w, h = buildat.read_image(name)
	return tostring(w).."x"..tostring(h)
end
local seen = "local "..size("launch_menu/res/icon_local.png")..
		" network "..size("launch_menu/res/icon_network.png")
local c = buildat.get_cache_path()
for _, p in ipairs({"/tmp/launch_menu/res/icon_local.png",
		"/server_icons/launch_menu/res/icon_network.png"}) do
	buildat.compose_image({size = {3, 5}, ops = {}, write = c..p})
end
log:info("shadow_write: read "..seen)
EOF
printf 'wait_log_any 60000 shadow_write: read\nquit\n' > "$t/cmds.txt"
cd "$here/Build"
for run in 1 2; do
	run_client 30 "$t/cli$run.log" timeout -k 5 90 bin/buildat -C "$t/c" \
		-D "$t/u" -a dev/shadow_write/run -w 640x360 -l 3 \
		-o sound_mute=1 -c @"$t/cmds.txt"
done
[ -f "$t/c/tmp/launch_menu/res/icon_local.png" ] ||
	fail "the first run wrote nothing ($(grep -ao 'shadow_write.*\|Command sequence failed.*' "$t/cli1.log" | head -1))"
seen=$(grep -ao 'shadow_write: read .*' "$t/cli2.log" | head -1)
[ -n "$seen" ] || fail "the second run read nothing ($t/cli2.log)"
[ "$seen" = "shadow_write: read local 120x120 network 128x128" ] ||
	fail "a file written under the cache took an installed name: $seen"
echo "PASS: files written under <cache>/tmp and <cache>/server_icons do not take the installed icons' names"
