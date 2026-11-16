#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-15)
# covers: builtin/kit/types/lobby.lua builtin/kit/types/ui_scene_list.lua builtin/kit/types/scene_info.lua builtin/kit/kit.cpp builtin/kit/types/ui_chat.lua builtin/kit/types/ui_view.lua builtin/kit/types/ui_panel.lua builtin/kit/client_lua/ui.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/players.lua
# [KIT_LOBBY] A lobby on Workbench. kitboss (the admin) places 3 kit/lobby,
# its lobby screen 4 (a kit/ui_panel, screen full, to the player: 5 a
# kit/ui_chat, 6 Play -> 3 play, 7 a kit/ui_view following 3's entered and
# left), its result screen 8 (screen over: 9 a text, 10 Again -> 3 again,
# 11 Lobby -> 3 lobby), 12 a HUD panel with 13 Finish -> 3 over and 14 a
# HUD text, [KIT_LAYOUT_AUTO] 15 a panel of layout auto at the lobby's
# bottom holding 5 and 7 ([KIT_PANEL_LEFTOVERS] its duplicate 16 under 4
# as it is, hidden); [KIT_SCENE_PACKAGES] 11's link by name (3 renamed
# "the lobby", the link "to_name" in the save), 19 a kit/scene_info on
# the scene and 20 a kit/ui_scene_list on the lobby screen listing it
# ("Yard, by kitboss"). Back beside kitbob, each in the lobby (a full
# screen: no world, no HUD; the chat left of the view in a row on these
# landscape screens), kitboss says a line in the lobby's chat, plays (the
# screen gone, the view following him), finishes (the result card over the
# play), again, finishes, back to the lobby; then edits: kitbob's chat line
# from the lobby a notification in his edit mode. [KIT_LOBBY_OUT_OF_PLAY]
# In the lobby and over each out of play (the server's line), kitboss's
# client spectating, kitbob's body not drawn on kitboss's screen while he
# plays, W held moving the free camera over the result card but not
# under the lobby. The desktop HUD view: the frame and the tool panel, its shape a
# phone's, its screen picker on the lobby (15 a column there: the view the
# frame's width, the chat under it). Screenshots: lobby.png, result.png,
# bob_lobby.png, notify.png, hud.png, hud_412x915.png, hud_lobby.png
#   util/kit_lobby_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_lobby; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
client() # <name> <size>: its commands in $t/<name>.cmds
{
	sed -i "s|@T@|$t|g" "$t/$1.cmds"
	run_client 60 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache_$1" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w "$2" -u 1 -l 3 \
		-c @"$t/$1.cmds" || fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
n=0
edit()
{
	# (the undo keeps 50: each edit after says 50 again)
	n=$((n < 50 ? n + 1 : 50))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
place() { edit "{\"op\": \"place\", \"type\": \"$1\", \"pos\": [$2, 1, 6]}"; }
set_p() { edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
link() { edit "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"$2\", \"to\": $3, \"input\": \"$4\"}"; }
in_panel() { edit "{\"op\": \"parent\", \"id\": $1, \"parent\": $2}"; }
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
EOF
	place kit/lobby 0
	place kit/ui_panel 1
	set_p 4 title '"Lobby"'
	set_p 4 screen '"full"'
	set_p 4 to '"player"'
	place kit/ui_chat 2
	in_panel 5 4
	place kit/ui_button 3
	in_panel 6 4
	set_p 6 label '"Play"'
	set_p 6 anchor '"center"'
	link 6 pressed 3 play
	place kit/ui_view 4
	in_panel 7 4
	set_p 7 title '"On the track"'
	link 3 entered 7 follow
	link 3 left 7 unfollow
	place kit/ui_panel 5
	set_p 8 title '"Result"'
	set_p 8 screen '"over"'
	set_p 8 to '"player"'
	set_p 8 layout '"column"'
	set_p 8 width 0
	set_p 8 height 0
	place kit/ui_text 6
	in_panel 9 8
	set_p 9 text '"Your time: 0:42"'
	place kit/ui_button 7
	in_panel 10 8
	set_p 10 label '"Again"'
	link 10 pressed 3 again
	place kit/ui_button 8
	in_panel 11 8
	set_p 11 label '"Lobby"'
	# [KIT_SCENE_PACKAGES] by name: 3 "the lobby" in the player's scene
	edit '{"op": "rename", "id": 3, "name": "the lobby"}'
	edit '{"op": "link", "id": 11, "comp": 0, "output": "pressed", "to_name": "the lobby", "input": "lobby"}'
	place kit/ui_panel 9
	set_p 12 title '"Run"'
	set_p 12 anchor '"top_left"'
	set_p 12 shown true
	place kit/ui_button 10
	in_panel 13 12
	set_p 13 label '"Finish"'
	link 13 pressed 3 over
	place kit/ui_text 11
	set_p 14 text '"Builder away"'
	place kit/ui_panel 12
	in_panel 15 4
	set_p 15 layout '"auto"'
	set_p 15 anchor '"bottom"'
	set_p 15 width 0
	set_p 15 height 0
	set_p 15 background '"none"'
	set_p 15 border '"none"'
	set_p 15 shown true
	in_panel 5 15
	in_panel 7 15
	# [KIT_PANEL_LEFTOVERS] 15 duplicated: 16 (its 5 and 7 as 17, 18) under 4
	# as 15 is, hidden
	edit '{"op": "duplicate", "ids": [15], "by": [0, 0, 0]}'
	set_p 16 shown false
	set_p 3 lobby_screen 4
	set_p 3 over_screen 8
	# [KIT_SCENE_PACKAGES] the scene listed (19), its list on the lobby (20)
	place kit/scene_info 13
	set_p 19 title '"Yard"'
	set_p 19 author '"kitboss"'
	place kit/ui_scene_list 14
	in_panel 20 4
	set_p 20 title '"Tracks"'
	set_p 20 anchor '"top"'
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: ui full screen 4 up
sync 2000
quit
EOF
} > "$t/boss1.cmds"
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 30000 kit: ui full screen 4 up
wait_log_any 30000 kit: ui 7 view
wait_log_any 10000 shown, layer 4: "Tracks | Yard, by kitboss"
click LineEdit "kit chat 5"
delay 300
text hello lobby
delay 300
keypress Return
wait_log_any 10000 kit: ui chat 5 said (11 bytes)
wait_log_any 10000 hello lobby"
frames 10
screenshot @T@/lobby.png
event kit_players
frames 3
keydown w
frames 30
keyup w
event kit_players
frames 3
click Button "Play"
wait_log 10000 kit: ui full screen none
wait_log_any 10000 shown: "Builder away"
frames 5
event kit_players
frames 3
click Button "Finish"
wait_log 10000 shown, layer 8: "Result"
frames 10
screenshot @T@/result.png
event kit_players
frames 3
keydown w
frames 30
keyup w
event kit_players
frames 3
click Button "Again"
wait_log 10000 hidden, layer 8: "Result"
frames 5
click Button "Finish"
wait_log 10000 shown, layer 8: "Result"
frames 5
click Button "Lobby"
wait_log 10000 kit: ui full screen 4 up
frames 5
keypress F6
wait_log 10000 kit editor: edit mode on
EOF
	cat <<'EOF'
event kit_edit {"op": "set", "id": 14, "comp": 0, "param": "text", "value": "Builder here"}
wait_log_any 10000 : "Builder here"
wait_log_any 60000 kit: chat while editing:
frames 10
screenshot @T@/notify.png
keypress F4
wait_log 10000 kit editor: the view is HUD
wait_log_any 10000 kit editor: the HUD tool panel
frames 10
screenshot @T@/hud.png
click DropDownList "hud shape"
wait_log 10000 hud shape open
frames 3
click Text "hud shape: Phone 412x915"
wait_log 10000 kit editor: the HUD view's shape is 412x915
frames 10
screenshot @T@/hud_412x915.png
click DropDownList "hud screen"
wait_log 10000 hud screen open
frames 3
click Text "hud screen: ◆ 4 ui_panel"
wait_log 10000 kit editor: the HUD view shows screen 4
frames 10
screenshot @T@/hud_lobby.png
event kit_edit {"op": "set", "id": 14, "comp": 0, "param": "text", "value": "Builder done"}
wait_log_any 10000 : "Builder done"
sync 3000
quit
EOF
} > "$t/boss2.cmds"
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 30000 kit: ui full screen 4 up
wait_log_any 120000 : "Builder here"
click LineEdit "kit chat 5"
delay 300
text hi builder
delay 300
keypress Return
wait_log_any 10000 kit: ui chat 5 said (10 bytes)
wait_log_any 10000 hi builder"
frames 10
screenshot @T@/bob_lobby.png
# (gone only after kitboss's HUD view: a leave's state redraws its tool
# panel, and a dropdown clicked then did not open)
wait_log_any 120000 : "Builder done"
sync 3000
quit
EOF
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss1 1280x720
BUILDAT_JOIN_NAME=kitbob client bob 1024x600 &
bob=$!
BUILDAT_JOIN_NAME=kitboss client boss2 1280x720
wait $bob || fail "client bob failed ($t/bob.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log b=$t/boss2.log
for l in "kit/lobby 3: kitboss: none -> lobby" "kit/lobby 3: kitboss: lobby -> playing" \
		"kit/lobby 3: kitboss: playing -> over" "kit/lobby 3: kitboss: over -> lobby" \
		"kit/lobby 3: kitbob: none -> lobby" "kit/ui_view 7: follows kitboss"; do
	grep -aqF "$l" "$s" || fail "no \"$l\" ($s)"
done
grep -a "dropped: " "$s" && fail "a link by name dropped ($s)"
grep -a -A1 "Exception on handling packet" "$t"/boss1.log "$t"/boss2.log "$t"/bob.log &&
	fail "a client's packet handler failed"
grep -aqF "kit/ui_scene_list 20: scenes: world=Yard/kitboss" "$s" || fail "no listed scene Yard ($s)"
# Again from the result: over -> playing a second time
[ "$(grep -acF "kit/lobby 3: kitboss: over -> playing" "$s")" -ge 1 ] ||
	fail "Again did not start a run ($s)"
grep -aqF "kit: chat while editing: " "$b" || fail "no chat notification ($b)"
grep -aqF "hi builder" "$b" || fail "kitbob's line did not reach kitboss ($b)"
# The tool panel and its frame: the room left, then a phone's, centred
grep -aqP "the HUD tool panel 390x720, the frame 0 0 890 720$" "$b" ||
	fail "the tool panel or the frame not as wanted ($b)"
grep -aqP "the HUD tool panel 390x720, the frame 283 0 324 720$" "$b" ||
	fail "the 412x915 frame not as wanted ($b)"
grep -aq "OFF SCREEN" "$b" "$t/bob.log" && fail "a UI component off the screen"
# [KIT_LOBBY_OUT_OF_PLAY] Out of play in the lobby and over, in play as a
# run starts; kitboss's client spectating as he is out; kitbob's body (in
# the lobby) not drawn on kitboss's screen while he plays
for l in "kitboss is out of play (a lobby)" "kitboss is in play" "kitbob is out of play (a lobby)"; do
	grep -aqF "$l" "$s" || fail "no \"$l\" ($s)"
done
awk '/kit: spectating on/ { on = 1 } on && /kit: ui full screen none/ { up = 1 }
	up && /kit: spectating off/ { ok = 1 } END { exit !ok }' "$b" ||
	fail "kitboss not spectating in the lobby, or still after Play ($b)"
# W held: the free camera still under the lobby's full screen (its view
# follows by the camera's offset), moving over the result card
cams=($(grep -aoP "kit: the spectator's camera at \K\S+" "$b" | head -4))
[ ${#cams[@]} = 4 ] && [ "${cams[0]}" = "${cams[1]}" ] && [ "${cams[2]}" != "${cams[3]}" ] ||
	fail "W under the lobby, then over the result: the camera at ${cams[*]} ($b)"
db=$(find "$t/user" -name save.sqlite -path "*/saves/world/*" | head -1)
python3 -I - "$db" <<'PY' || fail "the panel's duplicate ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
au = json.loads(db.execute("select value from store where store='kit' and key='authored'").fetchone()[0])
e = {x["id"]: x for x in au["entities"]}
assert e[16]["parent"] == 4 and "pos" not in e[16], e.get(16)
assert e[17]["parent"] == 16 and e[18]["parent"] == 16, (e.get(17), e.get(18))
assert e[16]["components"][0]["type"] == "kit/ui_panel", e[16]
print("ok: the panel's copy under the lobby screen", e[16])
# [KIT_SCENE_PACKAGES] Lobby's link by name kept as one
ls = e[11]["components"][0]["links"]
assert ls == [{"output": "pressed", "to_name": "the lobby", "input": "lobby"}], ls
print("ok: a link by name saved as to_name", ls)
PY
bob=$(grep -aoP 'kit: this player is entity \K[0-9]+' "$t/bob.log" | tail -1)
[ -n "$bob" ] || fail "no entity of kitbob's ($t/bob.log)"
grep -aq "kit: player $bob drawn at" "$b" && fail "kitbob's body drawn for kitboss from the lobby ($b)"
# [KIT_LAYOUT_AUTO] The lobby's 15 a row on kitboss's 1280x720 (the chat
# left of the view, both at the bottom), a column in the HUD view's phone
# frame (the view its width, the chat under it)
python3 -I - "$b" <<'PY' || fail "the auto panel's layout ($b)"
import re, sys
at = {}
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"kit: ui (5|7) (\w+) at (-?\d+),(-?\d+) (\d+)x(\d+) in (\d+x\d+) .* shown", l)
    if m:
        at[(m[1], m[7])] = tuple(map(int, m.group(3, 4, 5, 6)))
c, v = at.get(("5", "1280x720")), at.get(("7", "1280x720"))
assert c and v and c[0] + c[2] <= v[0] and c[1] + c[3] > 600 and v[1] + v[3] > 600, (c, v)
c, v = at.get(("5", "324x720")), at.get(("7", "324x720"))
assert c and v and v[2] >= 300 and c[2] == v[2] and c[1] >= v[1] + v[3], (c, v)
print("ok: the row", at[("5", "1280x720")], at[("7", "1280x720")], "the phone's column", c, v)
PY
for p in lobby result bob_lobby notify hud hud_412x915 hud_lobby; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
echo "PASS: a lobby: each player's lobby, run and result screens, its chat and view (an auto panel: a row, a column in the phone frame), out of play there (the free camera still under the lobby), a panel's duplicate under its parent, chat lines a builder's notifications, the desktop HUD view's frame, shapes and screens; screenshots in $t"
