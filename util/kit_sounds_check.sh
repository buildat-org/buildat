#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~3 min (2026-11-04)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/world.h builtin/kit/box/box.c builtin/kit/sounds.json builtin/kit/materials.json builtin/kit/types/sound.lua builtin/kit/types/door.lua builtin/kit/types/button.lua builtin/kit/types/pickup.lua builtin/kit/types/equipment.lua builtin/kit/types/*.item.json builtin/kit/client_lua/sounds.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/hands.lua builtin/kit/client_lua/module.lua extensions/blip/init.lua apps/workbench/**
# [KIT_SOUNDS] The project's sounds on a fresh Workbench save:
#   1. the admin (kitboss), in edit mode: the Sounds tab lists Kit's 9;
#      "New sound..." names my_sound and opens blip's designer, its laser
#      then Save makes kitboss/my_sound; Copy as new of kit/click makes
#      kitboss/click_2 and its Delete removes it; my_sound's Edit opens the
#      designer on it, explosion then Save writes it back (version 2,
#      other params). Placed: a door whose sound_open is my_sound (the
#      inspector's dropdown shown), a button linked to a kit/sound
#      (kit/hit, everywhere), a dummy with kit/health, a giver of
#      kit/sword, kit/game_rules' building "creative", a region open
#      to digs and places
#   2. kitboss again (back in edit mode as he left it, [WB_EDITOR_VIEW_MEMORY];
#      out of it), in play: the door's use plays my_sound at the door,
#      the button's kit/click at it and kit/sound's kit/hit everywhere;
#      the sword's hit on the dummy kit/hit there (its swing the others':
#      the server sends it to none here); a place and a dig kit/place and
#      kit/dig at the cell (Kit's voxels' own); his client plays each
#      (blip's play_cached)
#   3. with Chrome and web/: a web player (webear) in the world meanwhile
#      gets the sounds and plays them in the web client
# Packages carry sounds: kit_publish_check.sh. Screenshots: $t/tab.png,
# $t/tab2.png, $t/inspector.png, $t/dropdown.png, $t/drive/web.png
#   util/kit_sounds_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_sounds; t=$CHECK_TMP
cd "$here/Build"

web=""
if command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ]; then
	web="-W $here/web"
fi
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 $web \
	--sim-rate "$CHECK_RATE" ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
client() # <name> <cmds>
{
	run_client 90 "$t/$1.log" timeout 300 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_kitboss" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$2.cmds" || fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
export BUILDAT_JOIN_PASSWORD=checkpass12
n=0
edit() # <json>
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
set_() # <id> <param> <value>
{
	edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
}
# 3 the World, 4 the door, 5 the button, 6 kit/sound, 7 the dummy, 8 the
# giver, 9 game_rules, 10 a region where all dig and place
{
	cat <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
wait_log_any 10000 kit: 9 sounds
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
click Button "Sounds"
wait_log 5000 kit editor: the panel's Sounds tab
frames 5
screenshot $t/tab.png
click Button "New sound..."
frames 3
click Button "OK"
wait_log 5000 kit editor: designing sound my_sound
frames 5
click Button "laser"
wait_log 5000 designer: laser
click Button "Save"
wait_log 10000 kit: 10 sounds
frames 5
click Button "sound copy kit/click"
frames 3
click Button "OK"
wait_log 10000 kit: 11 sounds
frames 5
screenshot $t/tab2.png
click Button "sound delete kitboss/click_2"
wait_log 10000 kit: 10 sounds
frames 5
click Button "sound edit kitboss/my_sound"
wait_log 5000 kit editor: designing sound kitboss/my_sound
frames 5
click Button "explosion"
wait_log 5000 designer: explosion
click Button "Save"
wait_log 10000 kit: 10 sounds
EOF
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/door", "pos": [2, 1, -2]}'
	set_ 4 sound_open '"kitboss/my_sound"'
	edit '{"op": "place", "type": "kit/button", "pos": [-1, 1, -2]}'
	edit '{"op": "place", "type": "kit/sound", "pos": [6, 1, 6]}'
	set_ 6 sound '"kit/hit"'
	set_ 6 everywhere true
	edit '{"op": "link", "id": 5, "comp": 0, "output": "pressed", "to": 6, "input": "play"}'
	edit '{"op": "place", "type": "kit/health", "pos": [-2, 1, 1]}'
	edit '{"op": "place", "type": "kit/item_giver", "pos": [1, 1, -2]}'
	set_ 8 item '"kit/sword"'
	edit '{"op": "place", "type": "kit/game_rules", "pos": [0, 1, 0]}'
	set_ 9 building '"creative"'
	edit '{"op": "place", "type": "kit/region", "pos": [-6, 0, -6]}'
	set_ 10 size '[13, 6, 13]'
	set_ 10 dig '"all"'
	set_ 10 place '"all"'
	cat <<EOF
click Button "Entities"
frames 3
click Button "Positioned*"
frames 3
event kit_select 4
wait_log_any 5000 kit editor: selected 4
delay 1000
screenshot $t/inspector.png
wait_log_any 5000 Wrote screenshot $t/inspector.png
mouse_pos 945 311
frames 3
click DropDownList "▼" 945 311
delay 500
screenshot $t/dropdown.png
wait_log_any 5000 Wrote screenshot $t/dropdown.png
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
sync 2000
quit
EOF
} > "$t/boss1.cmds"
cat > "$t/boss2.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit: 10 sounds
wait_log_any 10000 kit editor: edit mode on
keypress F6
wait_log 10000 kit editor: edit mode off
event kit_use 4
wait_log 10000 kit: sound kitboss/my_sound at
event kit_use 5
wait_log 10000 kit: sound kit/click at
event kit_use 8
sync 3000
event kit_hold kit/sword
sync 2000
event kit_hit 7
sync 2000
event workbench_build {"p": [3, 1, 3], "voxel": "kit/stone"}
sync 2000
event workbench_build {"p": [3, 1, 3], "voxel": "air"}
wait_log 10000 kit: sound kit/dig at
sync 2000
quit
EOF
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss1 boss1
if [ -n "$web" ]; then
	# A player who makes an account, by kit_ui_components_check's keys
	cat > "$t/web.json" <<'J'
[
 ["nav", "${URL}"],
 ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "webear"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["key", "Enter"], ["waitlog", "Joined as webear", 30],
 ["waitlog", "player physics enabled", 120],
 ["waitlog_any", "kit: 10 sounds", 30],
 ["waitlog", "kit: sound kitboss/my_sound at", 240],
 ["waitlog", "played cached", 10],
 ["waitlog", "kit: sound kit/dig at", 120],
 ["frames", 5], ["shot", "${OUT}/web.png"], ["sync", 2000]
]
J
	WEB_DRIVE_VIEWPORT=1000x500@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/web.json" "$t/drive" \
		> "$t/drive.txt" 2>&1 &
	drive=$!
	wait_for_log "$t/srv.log" "webear joined" 240 ||
		fail "the web player did not join ($t/drive.txt, $t/srv.log)"
fi
BUILDAT_JOIN_NAME=kitboss client boss2 boss2
if [ -n "$web" ]; then
	wait $drive || fail "the web drive ($(tail -2 "$t/drive.txt"), $t/drive)"
fi
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log c=$t/boss2.log
grep -a "Sounds:\|sound \|Sound " "$s" | sed 's/^.*\(kit\|wasm\) *: /  /' |
	cut -c1-160
want "$s" "Sounds: 8" \
	"kitboss made sound kitboss/my_sound version 1:" \
	"kitboss made sound kitboss/click_2 version 1:" \
	"kitboss deleted sound kitboss/click_2" \
	"kitboss made sound kitboss/my_sound version 2:"
v1=$(grep -aoP 'made sound kitboss/my_sound version 1: \K\S+' "$s")
v2=$(grep -aoP 'made sound kitboss/my_sound version 2: \K\S+' "$s")
[ -n "$v1" ] && [ -n "$v2" ] && [ "$v1" != "$v2" ] ||
	fail "Edit's Save did not change the params ($v1, $v2)"
echo "ok: the Sounds tab: New, Copy as new, Delete; Edit's Save wrote the designer's sound back"
want "$s" "Sound kitboss/my_sound (entity 4's kit/door) at (2.0,1.0,-2.0)" \
	"Sound kit/click (entity 5's kit/button) at (" \
	"Sound kit/hit (entity 6's kit/sound) everywhere to" \
	"Sound kit/swing (kit/sword's swing) at" \
	"Sound kit/hit (kit/sword's hit) at (" \
	"Sound kit/place (kit/stone's place) at (3.5,1.5,3.5) to" \
	"Sound kit/dig (kit/stone's dig) at (3.5,1.5,3.5) to"
want "$c" "kit: sound kit/hit at" "kit: sound kit/place at" \
	"played cached $v2"
echo "ok: the triggers' sounds: the door, the button, kit/sound, the sword's hit, a place and a dig"
if [ -n "$web" ]; then
	want "$t/drive/page.log" "kit: sound kit/click at" "kit: sound kit/hit"
	echo "ok: the web client got them and blip played them"
fi
echo "PASS: Kit's sounds: the Sounds tab's New, Copy as new, Delete and Edit (blip's designer, its Save); the door's, the button's, kit/sound's, an item's and the voxels' sounds on their triggers${web:+, on the web too}; screenshots in $t"
