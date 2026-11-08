#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-04)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/hands.lua builtin/kit/types/region.lua builtin/kit/types/item_giver.lua builtin/kit/types/pickup.lua apps/workbench/**
# [KIT_ITEMS_TAB] [KIT_TEAM_LEFTOVERS] The editor's Items tab on a fresh
# Workbench save, the admin (kitboss) in edit mode, Ended:
#   1. the tab lists Kit's item types by group (Tools, Weapons, Ammo);
#      the search narrows it; kit/sword selected shows its sheet in the
#      inspector, in sections (one opened by its button)
#   2. Copy as new makes kitboss/sword, its sheet's Save its version 2,
#      its Delete takes it away; "New item type..." and Make: kitboss/my_item
#   3. kit/pickaxe's row dragged into the 3D view places a kit/pickup of it
#   4. an item_giver's item picked from the same list (the inspector's
#      dropdown) and applied
#   5. Running: Give to me puts a kit/arrow into a slot
#   6. a region (use: owners, capture by team) over a button: kitboss's
#      use refused; kitboss joins a team, the region's set_owner by them
#      captures it for the team, and the button is theirs to press
# Screenshots: items.png (the tab), search.png, sheet.png (kit/sword's
# sheet), picker.png (the item_giver's open dropdown)
#   util/kit_items_tab_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_items_tab; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
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
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
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
KIT='Tools kit/pickaxe, Weapons kit/bow, Weapons kit/paintball, Weapons kit/pistol, Weapons kit/shotgun, Weapons kit/sword, Ammo kit/arrow'
# The ids: 3 the World, 4 the item giver, 5 the team, 6 the region, 7 the
# button, 8 the pickup dragged in
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
	edit '{"op": "place", "type": "kit/item_giver", "pos": [-2, 1, 2]}'
	edit '{"op": "place", "type": "kit/team", "pos": [2, 1, 0]}'
	edit '{"op": "place", "type": "kit/region", "pos": [-4, 0, -4]}'
	set_ 6 size '[9, 6, 9]'
	set_ 6 use '"owners"'
	set_ 6 capture '"team"'
	edit '{"op": "place", "type": "kit/button", "pos": [1, 1, 1]}'
	# 1. The tab, the search, a sheet
	cat <<EOF
click Button "Items"
wait_log 5000 kit editor: items (7): $KIT
frames 3
screenshot @T@/items.png
click LineEdit "item search"
text pist
wait_log 5000 kit editor: items for "pist": 1
frames 3
screenshot @T@/search.png
keypress BackSpace
keypress BackSpace
keypress BackSpace
keypress BackSpace
wait_log 5000 kit editor: items for "": 7
click Button "item kit/sword"
wait_log 5000 kit editor: item kit/sword selected
frames 3
click Button "section Ranged"
wait_log 5000 kit editor: item section Ranged open
frames 3
screenshot @T@/sheet.png
EOF
	# 2. Copy as new, Save, Delete; a new one
	cat <<'EOF'
click Button "copy kit/sword"
wait_log 5000 kit editor: item kit/sword copied as kitboss/sword
wait_log 10000 kit editor: items (8): Tools kit/pickaxe, Weapons kitboss/sword,
frames 3
click Button "Save"
wait_log 5000 kit editor: item kitboss/sword saved
wait_log 10000 kit: 8 item types
click Button "delete kitboss/sword"
wait_log 5000 kit editor: item kitboss/sword deleted
wait_log 10000 kit editor: items (7):
click Button "New item type..."
wait_log 5000 kit editor: a new item type
frames 3
click Button "Make"
wait_log 5000 kit editor: item kitboss/my_item made
wait_log 10000 kit editor: items (8):
EOF
	# 3. A drag from the tab into the 3D view
	n=$((n + 1))
	cat <<EOF
event kit_cam3d 6 12 14 6 1 6
frames 5
click Button "item kit/pickaxe"
wait_log 5000 kit editor: item kit/pickaxe selected
frames 3
mouse_down left
frames 2
mouse_pos 480 330
frames 2
mouse_pos 512 350
frames 2
mouse_up left
wait_log 10000 entities, $n to undo
EOF
	# 4. The item giver's item, picked
	n=$((n + 1))
	cat <<EOF
click Button "Entities"
frames 3
click Button "Positioned*"
frames 3
click Button "select 4"
wait_log 5000 kit editor: selected 4
frames 5
click DropDownList "▼" ${PICK_X:-965} ${PICK_Y:-220}
delay 500
frames 3
screenshot @T@/picker.png
click Text "kit/pistol"
wait_log 5000 kit editor: 4/1 item = kit/pistol
click Button "Apply"
wait_log 10000 entities, $n to undo
EOF
	# 5. Running: Give to me
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
click Button "Items"
wait_log 5000 kit editor: the panel's Items tab
frames 3
click Button "give kit/arrow"
wait_log 5000 kit editor: give me kit/arrow
wait_log_any 10000 kit/arrow x1
EOF
	# 6. The team's capture
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
sync 2000
event kit_use 7
sync 3000
keypress F6
wait_log 10000 kit editor: edit mode on
event kit_edit {"op": "try", "id": 5, "input": "join"}
sync 3000
event kit_edit {"op": "try", "id": 6, "input": "set_owner"}
sync 3000
keypress F6
wait_log 10000 kit editor: edit mode off
sync 2000
event kit_use 7
sync 3000
EOF
} > "$t/boss.cmds"
sed -i "s|@T@|$t|g" "$t/boss.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 run_client 90 "$t/boss.log" timeout 300 bin/buildat -C "$t/client_cache" \
	-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
	-c @"$t/boss.cmds" || fail "the client failed ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
echo "ok: the Items tab lists Kit's item types by group, the search narrows it, a sheet in sections"
want "$s" "kitboss made item type kitboss/sword version 1" \
	"kitboss made item type kitboss/sword version 2" \
	"kitboss deleted item type kitboss/sword" \
	"kitboss made item type kitboss/my_item version 1"
echo "ok: Copy as new, Save, Delete, New item type... and Make"
grep -aqE 'placed kit/pickup 8 at \[[-0-9.,]+\] with \{"item":"kit/pickaxe"\}' "$s" ||
	fail "no pickup of kit/pickaxe placed by the drag ($s)"
echo "ok: kit/pickaxe dragged into the world: a pickup of it"
want "$s" "set 4's kit/item_giver item to \"kit/pistol\""
echo "ok: the item giver's item picked from the list"
want "$s" "kitboss gives themselves kit/arrow"
grep -aq "kit: slots: .*kit/arrow x1" "$t/boss.log" ||
	fail "no kit/arrow in a slot ($t/boss.log)"
echo "ok: Give to me: a kit/arrow in a slot"
python3 - "$s" <<'PY' || fail "the team's capture ($s)"
import sys
log = open(sys.argv[1], errors="replace").read()
locked = log.find("A use of entity 7 by peer 1 refused: Protected")
captured = log.find("kit/region 6: captured by team 5")
pressed = log.find("kit/button 7: pressed by kitboss")
assert 0 <= locked < captured < pressed, (locked, captured, pressed)
assert log.count("kit/button 7: pressed by kitboss") == 1
PY
echo "ok: a region captured by the team of the player who set it off: its button theirs"
echo "PASS: Kit's Items tab: groups, search, sheets, Copy as new, Save, Delete, New, a drag's pickup, the item picker, Give to me; set_owner by team"
