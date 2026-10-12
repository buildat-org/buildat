#!/bin/bash
# tier: full
# cost: ~1 min (2026-10-10)
# covers: src/client/app_lua.h src/client/state.cpp client/api.lua client/packet.lua client/extensions/starport/init.lua client/extensions/aitta/init.lua extensions/launch_menu/screens.lua
# [SERVERLESS_PLAY]: an app's client half with no server, natively, by
# BUILDAT_RUN. A small app (client_main, a texture in client_data):
#   1. As dev:sl: buildat.serverless() true, a packet sent twice said
#      once, the texture loaded, a stored value written; Escape leaves it
#      to the launcher's Home. Again: the value read back.
#   2. Published to a local Aitta as tester/sl with "serverless": true,
#      BUILDAT_RUN=tester/sl with that Aitta in the settings: installed
#      (the signature checked) and run.
#   util/serverless_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp serverless; t=$CHECK_TMP
b="$here/Build/bin/buildat"

app=$t/u/dev_apps/sl
mkdir -p "$app/main/client_lua" "$app/main/client_data"
cp "$here/3rdparty/Urho3D/bin/Data/Textures/LogoLarge.png" "$app/main/client_data/dot.png"
echo '{"engine_api": 2, "kind": "app", "client_main": "init.lua"}' > "$app/main/meta.json"
printf '{"author": "tester", "name": "sl", "version": "1.0.0", "engine_api": 2,
	"audience": "everyone", "license_code": "MIT", "license_media": "CC0-1.0",
	"description": "a serverless check", "serverless": true}\n' > "$app/meta.json"
cat > "$app/main/client_lua/init.lua" <<'L'
local log = buildat.Logger("sl")
local magic = require("buildat/extension/urho3d")
log:info("sl: serverless " .. tostring(buildat.serverless()))
buildat.send_packet("sl:hello", "a")
buildat.send_packet("sl:hello", "b")
log:info("sl: stored " .. tostring(buildat.storage_read("n")))
log:info("sl: write " .. tostring(buildat.storage_write("n", "1")))
local tex = magic.cache:GetResource("Texture2D", "main/dot.png")
log:info("sl: texture " .. tostring(tex and tex.width))
magic.SubscribeToEvent("KeyDown", function(_, d)
	if d:GetInt("Key") == magic.KEY_ESCAPE then
		buildat.leave()
	end
end)
L
cat > "$t/cmds" <<C
delay 4000
delay 1000
keypress Escape
wait_log 10000 launch_menu: back to Home
quit
C
cd "$here/Build"
run(){ # log what cmds [env...]
	local log=$1 what=$2 cmds=$3
	shift 3
	env BUILDAT_RUN=$what "$@" timeout 90 "$b" -o launch_ui=launch_menu \
		-D "$t/u" -w 800x600 -l 3 -o sound_mute=1 -c @"$cmds" > "$log" 2>&1
	grep -aq "Command sequence complete" "$log" ||
		fail "$what: the drive ($(grep -a "sl: \|serverless\|rror\|wait_log" "$log" | tail -4))"
}
run "$t/a.log" dev:sl "$t/cmds"
for x in "sl: serverless true" "sl: stored nil" "sl: write true" \
		"sl: texture 512" "launch_menu: back to Home"; do
	grep -aq "$x" "$t/a.log" || fail "first run: no \"$x\""
done
[ "$(grep -ac "serverless: sl:hello goes nowhere" "$t/a.log")" = 1 ] ||
	fail "the packet not said once"
run "$t/b.log" dev:sl "$t/cmds"
grep -aq "sl: stored 1" "$t/b.log" || fail "the stored value not read back"
echo "ok: run as dev:sl, the packet said once, the texture, stored and read back, left to Home"

# 2. From an Aitta
start_server "$t/srv.log" "setup code" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/srv" -l 3 ||
	fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)
P=$SERVER_PORT
code=$(grep -ao "setup code [A-Z0-9]*" "$t/srv.log" | cut -d' ' -f3)
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
printf 'delay 8000\nquit\n' > "$t/reqs.cmds"
BUILDAT_AITTA_CREATE=1 BUILDAT_AITTA_NAME=admin BUILDAT_AITTA_PASSWORD=checkpass \
	BUILDAT_AITTA_CODE=$code \
	BUILDAT_AITTA_REQS="{\"cmd\":\"bind\",\"author\":\"tester\",\"key\":\"$(cat "$t/pub")\"}
{\"cmd\":\"set_settings\",\"settings\":{\"page_delay\":0}}" \
	timeout 90 "$b" -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 \
	-o sound_mute=1 -s 127.0.0.1:$P -c @"$t/reqs.cmds" > "$t/bind.log" 2>&1
grep -aq 'ai: {"id":1,"ok":true' "$t/bind.log" || fail "the bind"
zip=$("$b" aitta pack "$app" "$t/key" "$t/out" 2>/dev/null) || fail "pack"
"$b" aitta publish "$zip" 127.0.0.1:$P 2>&1 | grep -q "listed: tester/sl" ||
	fail "publish"
echo "{\"aittas\": [\"http://127.0.0.1:$P\"], \"filters\": {\"unreviewed\": true}}" > "$t/managed.json"
rm -rf "$t/u/dev_apps"
# The network's question about the Aitta's address, said yes to
cat > "$t/aitta.cmds" <<C
wait_log 20000 Asking the user about http://127.0.0.1:$P
delay 1500
keypress Return
wait_log 20000 sl: texture
quit
C
run "$t/c.log" tester/sl "$t/aitta.cmds" BUILDAT_STARPORT_MANAGED="$t/managed.json"
grep -aq "aitta: play tester.sl@1.0.0 serverless" "$t/c.log" &&
	grep -aq "sl: serverless true" "$t/c.log" || fail "not run from the Aitta"
[ -f "$t/u/installed/tester/sl/1.0.0/main/client_lua/init.lua" ] || fail "not installed"
echo "PASS: run with no server by its id, a packet said once, its texture and storage, left to Home; installed from an Aitta by author/name and run"
