#!/bin/bash
# tier: full
# cost: ~20 s (2026-10-16)
# covers: client/api.lua client/sandbox.lua
# A server's module named like a bundled extension (here luanti_client)
# serves `luanti_client/x.lua`; run by name, that chunk is the server's,
# and the extension verbs that answer by the calling extension
# (run_extension_file, read_extension_file) refuse it. Before, it ran
# luanti_client's settings.lua and rewrote the player name and the last
# address the extension shows at its next start.
#   util/served_extension_name_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp served_ext_name; t=$CHECK_TMP
app="$t/u/dev_apps/hostile_ext"
mkdir -p "$app/launcher" "$app/main/client_lua" "$app/luanti_client/client_lua" \
	"$t/u/extensions/luanti_client" "$t/c"
cat > "$app/launcher/init.lua" <<'EOF'
return function(ctx) return {{id = "run", label = "hostile_ext",
	run = function() ctx.launch{app = "hostile_ext"} end}} end
EOF
cat > "$app/main/meta.json" <<'EOF'
{"engine_api": 2, "kind": "check", "disable_cpp": true,
	"client_main": "init.lua",
	"dependencies": [{"module": "network"}, {"module": "client_lua"},
		{"module": "client_data"}, {"module": "luanti_client"}]}
EOF
echo '{"engine_api": 2, "disable_cpp": true, "dependencies": [{"module": "client_lua"}]}' \
	> "$app/luanti_client/meta.json"
cat > "$app/main/client_lua/init.lua" <<'EOF'
local log = buildat.Logger("hostile_ext")
local ok, err = pcall(buildat.run_script_file, "luanti_client/x.lua")
log:info("hostile_ext: finished: "..tostring(ok).." "..tostring(err))
EOF
# Each way of calling a verb: direct, through pcall (whose frame is C),
# as a tail call and in a coroutine (which leave no frame of the chunk's)
cat > "$app/luanti_client/client_lua/x.lua" <<'EOF2'
local log = buildat.Logger("hostile_ext")
local function try(how, f)
	local ok, r = pcall(f)
	if ok and type(r) == "table" then
		local cur = r.load()
		cur.name, cur.address = "planted", "planted.invalid:30000"
		r.save(cur)
	end
	log:info("hostile_ext: "..how..": "..(ok and type(r) or "error"))
end
local run, read = buildat.run_extension_file, buildat.read_extension_file
try("run", function() return (run("settings.lua")) end)
try("run by pcall", function() return select(2, pcall(run, "settings.lua")) end)
try("run as a tail call", function() return run("settings.lua") end)
try("run in a coroutine", function() return coroutine.wrap(run)("settings.lua") end)
try("read", function() return (read("init.lua")) end)
try("read by pcall", function() return select(2, pcall(read, "init.lua")) end)
EOF2
settings="$t/u/extensions/luanti_client/settings.json"
echo '{"name": "users-own-name", "address": "users.server:30000"}' > "$settings"
cp "$settings" "$t/before.json"
printf 'wait_log_any 60000 hostile_ext: finished\nquit\n' > "$t/cmds.txt"
cd "$here/Build"
run_client 30 "$t/cli.log" timeout -k 5 90 bin/buildat -C "$t/c" -D "$t/u" \
	-a dev/hostile_ext/run -w 320x240 -l 3 -o sound_mute=1 -c @"$t/cmds.txt"
grep -aq "hostile_ext: finished" "$t/cli.log" ||
	fail "the hostile app never finished ($(grep -ao 'Command sequence failed.*' "$t/cli.log" | head -1))"
cmp -s "$settings" "$t/before.json" ||
	fail "luanti_client's settings rewritten: $(cat "$settings")"
n=$(grep -ac "hostile_ext: \(run\|read\)[a-z ]*: " "$t/cli.log")
[ "$n" -eq 6 ] || fail "$n of 6 attempts logged"
grep -a "hostile_ext: \(run\|read\)[a-z ]*: \(table\|string\)" "$t/cli.log" &&
	fail "an attempt above got an extension's file"
echo "PASS: a server's chunk named as luanti_client's is refused its files"
