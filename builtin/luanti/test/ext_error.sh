#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [MENU_ERRORS]: an error raised inside a session is a notice line and not
# a dialog -- a dialog under a world takes the mouse from the player. A
# worldmod sends the client a formspec it cannot read; the client's log says
# which way the error was shown. Needs the Luanti checkout the way
# camera_ext.sh does.
#
#   builtin/luanti/test/ext_error.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/ext_error"; mkdir -p "$out"
luanti=~/projects/luanti
bin=${LUANTI_BIN:-$luanti/bin/luanti-refshots}
if check_pgrep buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	echo "a client or a Luanti server is already running" >&2; exit 2
fi
work="$out/luanti_world"
rm -rf "$work"; mkdir -p "$work/worldmods/camera"
cat > "$work/world.mt" <<MT
gameid = mineclone2
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
mod_storage_backend = sqlite3
world_name = camera
creative_mode = false
server_announce = false
MT
{ cat "$me/camera.lua"; cat <<'LUA'
-- Asked for by chat once the client's world is up, not on a timer
core.register_chatcommand("broken", {func = function(name)
	core.show_formspec(name, "broken",
			"formspec_version[9]size[8,8]nosuchelement[1,1;2,2;x;y]"..
			"image[a,b;c,d;nope.png]field[]")
	core.log("action", "ext_error: the broken formspec is sent")
	return true
end})
LUA
} > "$work/worldmods/camera/init.lua"
printf 'name = camera\n' > "$work/worldmods/camera/mod.conf"
{ echo "fixed_map_seed = 5"; echo "time_speed = 0"; echo "enable_damage = false"
	echo "mute_sound = true"; } > "$out/luanti.conf"
port=30030
check_allow "udp://127.0.0.1:$port"
( cd "$luanti" && exec "$bin" --server --world "$work" --port "$port" \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
srv=$!
trap 'kill "$srv" 2>/dev/null' EXIT
for i in $(seq 1 600); do
	grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null && break
	kill -0 "$srv" 2>/dev/null || break
	sleep 0.2
done
grep -q "Server for gameid" "$out/luanti_srv.log" 2>/dev/null ||
	{ echo "the Luanti server did not come up" >&2; exit 1; }
# The formspec's error is logged as an E line before it is shown: the
# drive's own doing. The 200 ms puts the typed command and its Return
# in frames of their own; the 1.5 s is the notice drawn after its line.
cat > "$out/cmds.txt" <<CMDS
expect_error Failed to run
wait_log 90000 voxel types have their own textures
keypress T
wait_log 5000 chat: the line opened
text /broken
# the typed command in a frame of its own
delay 200
keypress Return
wait_log 10000 error shown
delay 1500
screenshot $out/notice.png
wait_log 20000 Wrote screenshot $out/notice.png
quit
CMDS
BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=cam \
	BUILDAT_LUANTI_CONNECT=1 \
	timeout 180 "$here/Build/bin/buildat" -m luanti_client -w 1280x720 -l 3 \
	-c @"$out/cmds.txt" > "$out/extension_cli.log" 2>&1 ||
	{ echo "FAIL: the drive (see $out/extension_cli.log)"; exit 1; }
kill "$srv" 2>/dev/null
# A poll: the server's exit
for i in $(seq 1 150); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
shown=$(grep -av "command: \\|wait_log" "$out/extension_cli.log" | grep -a "error shown" | sed 's/.*error shown /error shown /' | head -2)
echo "${shown:-no error was reported}"
if echo "$shown" | grep -q "as a notice"; then
	echo "PASS: the error under a session is a notice line"
else
	echo "FAIL: the error under a session was not a notice"
	exit 1
fi
