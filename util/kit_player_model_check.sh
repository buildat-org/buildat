#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~25 s (2026-11-06)
# covers: builtin/kit/client_lua/players.lua builtin/kit/client_data/player_model.json builtin/kit/client_lua/controls.lua builtin/kit/kit.cpp
# [KIT_PLAYER_MODEL] Players see each other: Workbench's stone floor, a
# fresh save. kitboss places a World and a kit/team (4, "#3060ff") and
# plays; kitbob joins and watches. kitboss joins the team (the editor's
# try), takes a sword ("give"), walks 3 m along +z, turns back to face
# kitbob, looks up and swings at the air. kitbob's client draws kitboss's body:
# in the team's colour, holding kit/sword, walking, then mining (the
# swing), at kitboss's place (the server's) within 0.3 m; screenshots
# front.png (the body, the team's shirt, the sword) and kitboss's own
# third.png (kit/controls' camera "chase": its own body, the sword).
#   util/kit_player_model_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_player_model; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
client() # <name>: its commands in $t/<name>.cmds
{
	run_client 90 "$t/$1.log" timeout 300 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
export BUILDAT_JOIN_PASSWORD=checkpass12
n=0
edit() # <json>
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
BOSS=1000000 BOB=1000001
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
	edit '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/team", "pos": [6, 1, 6]}'
	edit '{"op": "set", "id": 4, "comp": 0, "param": "color", "value": "#3060ff"}'
	edit '{"op": "place", "type": "kit/controls", "pos": [-6, 1, -6]}'
	cat <<'EOF'
sync 2000
quit
EOF
} > "$t/boss1.cmds"
cat > "$t/boss2.cmds" <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 60000 kit: player $BOB's body in
keypress F6
wait_log 10000 kit editor: edit mode on
event kit_edit {"op": "try", "id": 4, "input": "join", "value": null}
wait_log 10000 kit editor: tried 4's join
event kit_edit {"op": "give", "item": "kit/sword"}
delay 1500
keypress F6
wait_log 10000 kit editor: edit mode off
keypress 1
look_dir 0 0 1
frames 5
keydown W
delay 700
keyup W
look_dir 0 0.3 -1
delay 3000
mouse_click left
delay 400
mouse_click left
delay 400
mouse_click left
delay 400
mouse_click left
delay 3000
keypress F6
wait_log 10000 kit editor: edit mode on
event kit_edit {"op": "set", "id": 5, "comp": 0, "param": "camera", "value": "chase"}
wait_log 10000 entities
event kit_edit {"op": "set", "id": 5, "comp": 0, "param": "distance", "value": 3}
wait_log 10000 entities
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir 0.5 -0.3 -1
frames 30
event kit_players
screenshot $t/third.png
sync 2000
quit
EOF
cat > "$t/bob.cmds" <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
look_dir 0.55 -0.05 1
wait_log_any 60000 kit: player $BOSS's body in #3060ff
wait_log_any 30000 kit: player $BOSS holds kit/sword
wait_log_any 30000 kit: player $BOSS mine
event kit_players
screenshot $t/front.png
delay 3000
event kit_players
sync 1000
quit
EOF
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss1
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 client bob &
bob=$!
BUILDAT_JOIN_NAME=kitboss client boss2
wait $bob || fail "kitbob's client did not see kitboss's body ($t/bob.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log b=$t/bob.log
grep -a "kit: player $BOSS" "$b" | sed 's/^.* I [a-z_]* *: /  /' | cut -c1-150
want "$b" "kit: player $BOSS's body in #3060ff" "kit: player $BOSS holds kit/sword"
grep -aqE "kit: player $BOSS (mine|walk_mine)" "$b" || fail "kitboss's swing not drawn ($b)"
# The body at the server's place for kitboss: the last drawn line's x, z
# against the server's last body (kitboss's own client says it: kit: body at)
read bx bz < <(grep -aoP "kit: player $BOSS drawn at \K-?[0-9.]+,-?[0-9.]+,-?[0-9.]+" "$b" |
	tail -1 | awk -F, '{print $1, $3}')
read sx sz < <(grep -aoP "kit: player $BOSS drawn at \K-?[0-9.]+,-?[0-9.]+,-?[0-9.]+" "$t/boss2.log" |
	tail -1 | awk -F, '{print $1, $3}')
echo "  kitboss drawn by kitbob at $bx,$bz, by itself at $sx,$sz"
awk -v a="$bx" -v b="$bz" -v c="$sx" -v d="$sz" 'BEGIN {
	exit !(a != "" && c != "" && (a - c) ^ 2 + (b - d) ^ 2 < 0.09 && d > 1) }' ||
	fail "kitboss's body not drawn where it walked ($b, $t/boss2.log)"
for f in front third; do
	[ -s "$t/$f.png" ] || fail "no screenshot $f ($t)"
done
echo "PASS: [KIT_PLAYER_MODEL] kitbob draws kitboss's body: the team's colour, the sword, the swing, at its place; screenshots $t/{front,third}.png"
