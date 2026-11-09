#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# needs: pixels
# cost: ~1 min (2026-11-09)
# covers: builtin/kit/client_lua/module.lua builtin/kit/client_lua/environment.lua
# [KIT_HOVER_BOX_NIGHT] The editor's voxel hover frame (drawn unlit) dimmed
# with the scene's light. A fresh Workbench save, Ended, a flat grassland
# World, kit/environment (fast_physical, then cartoon); the Voxels tool's
# place frame under the pointer from the editor's 3D camera at noon, at
# midnight, and in a tunnel dug into a hill with the World's sky light on:
#   - the frames' light logged 1 by day and its floor at night (0.05
#     physical, 0.25 cartoon);
#   - at midnight the frame's green on the field is dim, not the white it
#     was (under 120 of 255 physical) yet over the ground's by 8 (18
#     to 2 under physical, its meter still adapting; 44 adapted);
#   - in the tunnel at midnight it stands over the dark wall by 40.
# The shots are kept with KEEP_TMP=1.
set -u
. "$(dirname "$0")/check_lib.sh"
check_user
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_hover_night; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss

run() # <lighting>: shots <lighting>_{noon,night,cave_night}.png
{
	local lt=$1 n=0 x y z code
	edit() { n=$((n + 1)); echo "event kit_edit $1"; echo "wait_log 10000 entities, $n to undo"; }
	ep() { edit "{\"op\": \"set\", \"id\": 4, \"comp\": 0, \"param\": \"$1\", \"value\": $2}"; }
	shot() # <name> [camera]
	{
		cat <<EOF
event kit_cam3d ${2:-20 4 20 30 1 30}
frames 10
mouse_pos 512 420
delay 1500
frames 3
screenshot $t/${lt}_$1.png
EOF
	}
	start_server "$t/srv_$lt.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user_$lt" -l 3 ||
		fail "the server did not come up ($t/srv_$lt.log)"
	CHECK_PIDS+=($SERVER_PID)
	{
		cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
		edit '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
		edit '{"op": "set", "id": 3, "comp": 0, "param": "biome", "value": "grassland"}'
		echo "wait_log_any 30000 kit: World: generated again"
		n=$((n + 1))
		echo 'event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "decorations", "value": false}'
		echo "wait_log 30000 kit: World: generated again"
		edit '{"op": "place", "type": "kit/environment", "pos": [0, 1, 0]}'
		ep lighting "\"$lt\""
		ep weather_fade 0
		ep cloud_cover 0.2
		echo "keypress V"
		echo "frames 5"
		ep time 12
		shot noon
		ep time 0
		shot night
		# A hill (8 x 8, up to 6), a tunnel 2 x 2 and 6 deep into it
		n=$((n + 1))
		echo 'event kit_edit {"op": "terrain", "tool": "fill", "x": -30, "y": 0, "z": 20, "x1": -23, "z1": 27, "level": 6, "stroke": 1}'
		echo "wait_log 10000 kit editor: terrain: fill"
		for x in -30 -29 -28 -27 -26 -25; do for y in 1 2; do for z in 23 24; do
			edit "{\"op\": \"set_voxel\", \"pos\": [$x, $y, $z], \"voxel\": \"air\"}"
		done; done; done
		edit '{"op": "set", "id": 3, "comp": 0, "param": "sky_light", "value": true}'
		echo "wait_log_any 10000 kit: sky light on"
		echo "wait_log_any 60000 kit: sky light: the loaded world relit"
		shot cave_night "-29.5 1.9 23.5 -24 1.5 23.5"
		echo quit
	} > "$t/$lt.cmds"
	wait_for_log "$t/srv_$lt.log" "setup code [A-Z0-9]+" 30 ||
		fail "no setup code ($t/srv_$lt.log)"
	code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv_$lt.log" | head -1)
	BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
		run_client 60 "$t/$lt.log" timeout 240 bin/buildat \
		-C "$t/client_cache" -D "$t/cu_$lt" -s localhost:$SERVER_PORT \
		-w 1024x700 -l 3 -o lighting=game -c @"$t/$lt.cmds" ||
		fail "client $lt failed ($t/$lt.log, $t/srv_$lt.log)"
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
# <png>: the frame's brightest green and the median's about the pointer
green()
{
	python3 - "$1" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB").crop((440, 380, 590, 460))
g = sorted(p[1] for p in im.getdata())
print(g[-1], g[len(g) // 2])
EOF
}
for lt in fast_physical cartoon; do
	run $lt
	floor=0.05
	[ $lt = cartoon ] && floor=0.25
	l=$t/$lt.log
	grep -aq "kit: the frames' light 1$\|kit: the frames' light 0.99$" "$l" ||
		fail "$lt: no frames' light of noon ($l)"
	grep -aq "kit: the frames' light $floor$" "$l" ||
		fail "$lt: no frames' light $floor at midnight ($l)"
	read ng ngm <<<"$(green "$t/${lt}_night.png")"
	read cg cgm <<<"$(green "$t/${lt}_cave_night.png")"
	[ "$ng" -gt $((ngm + 8)) ] ||
		fail "$lt: the frame not seen on the field at midnight: $ng, ground $ngm"
	[ $lt = cartoon ] || [ "$ng" -lt 120 ] ||
		fail "$lt: the frame bright on the field at midnight: $ng, ground $ngm"
	[ "$cg" -gt $((cgm + 40)) ] ||
		fail "$lt: the frame not seen in the tunnel at midnight: $cg, wall $cgm"
	echo "ok: $lt: the frame's green at midnight $ng (ground $ngm), in the tunnel $cg (wall $cgm)"
done
echo "PASS: the voxel hover frame dimmed with the light, seen at midnight and in a tunnel"
