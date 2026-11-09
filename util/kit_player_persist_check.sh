#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-09)
# covers: builtin/kit/kit.cpp builtin/kit/types/player_state.lua apps/workbench/main/main.cpp
# [KIT_PLAYER_PERSIST] kit/player_state's remember, on a fresh Workbench
# save. The admin (kitboss), Stopped, places a spawner of players (3, at
# (0, 1, -4)), a giver of kit/pickaxe (4), kit/player_state (5, remember
# on) and kit/game_rules (6, building "creative"), and Runs it. Then
# kitbob, a player:
#   1. is put on the spawner, takes the pickaxe, places a stone, walks
#      and leaves: kept where he stood;
#   2. rejoins: back there (no spawn), the pickaxe his;
#   3. the server restarts; he rejoins: back there again, the pickaxe his;
#   4. kitboss builds over the place (its two cells stone): kitbob's next
#      join is the spawn's;
#   5. kitboss digs out the two cells under the spawner, where kitbob
#      left: he is put back there and falls.
#   util/kit_player_persist_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_player_persist; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
k=0
srv()
{
	k=$((k + 1))
	start_server "$t/srv$k.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
		fail "the server did not come up ($t/srv$k.log)"
	CHECK_PIDS+=($SERVER_PID)
}
stop()
{
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
c=0
client() # <name> <cmds file>
{
	c=$((c + 1))
	BUILDAT_JOIN_NAME=$1 run_client 90 "$t/c$c.log" timeout 200 \
		bin/buildat -C "$t/client_cache" -D "$t/cu_$1" \
		-s localhost:$SERVER_PORT -w 800x600 -l 3 -c @"$2" ||
		fail "client $c ($1) failed ($t/c$c.log, $t/srv$k.log)"
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
kept() # <log>: the last place kitbob was kept at, "x, y, z"
{
	grep -aoP 'kitbob kept at \(\K[^)]*' "$1" | tail -1
}
srv
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
n=0
edit() { n=$((n + 1)); printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"; }
set_() { edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
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
	edit '{"op": "place", "type": "kit/spawner", "pos": [0, 1, -4]}'
	set_ 3 players true
	edit '{"op": "place", "type": "kit/item_giver", "pos": [1, 1, -3]}'
	set_ 4 item '"kit/pickaxe"'
	edit '{"op": "place", "type": "kit/player_state", "pos": [0, 1, 0]}'
	set_ 5 remember true
	edit '{"op": "place", "type": "kit/game_rules", "pos": [0, 1, 0]}'
	set_ 6 building '"creative"'
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
sync 1000
quit
EOF
} > "$t/boss1.cmds"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_ADMIN="setting open_registration on" \
	client kitboss "$t/boss1.cmds"
cat > "$t/bob1.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 the server put the player at (0, 1.4, -4)
wait_log_any 60000 player physics enabled
event kit_use 4
wait_log 10000 kit: items: kit/pickaxe x1
event workbench_build {"p": [3, 1, -6], "voxel": "kit/stone"}
keydown W
delay 800
keyup W
sync 2000
quit
EOF
client kitbob "$t/bob1.cmds"
p1=$(kept "$t/srv1.log")
[ -n "$p1" ] || fail "kitbob was not kept as he left ($t/srv1.log)"
[ "$p1" != "0, 1, -4" ] || fail "kitbob did not walk off the spawner ($t/srv1.log)"
want "$t/srv1.log" "workbench: kitbob placed kit/stone (3,1,-6): written"
echo "ok: kitbob took the pickaxe, built, walked and left: kept at ($p1)"
cat > "$t/bob2.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit: items: kit/pickaxe x1
sync 2000
quit
EOF
client kitbob "$t/bob2.cmds"
want "$t/srv1.log" "kitbob back where they were at ($p1) in world"
want "$t/c$c.log" "the server put the player at ($(echo "$p1" | awk -F', ' '{print $1}')"
grep -aq "kit/spawner 3: spawns kitbob" <(sed -n '/kitbob back where/,$p' "$t/srv1.log") &&
	fail "the spawner placed kitbob after he was put back ($t/srv1.log)"
p2=$(kept "$t/srv1.log")
echo "ok: rejoined where he left, the pickaxe his; kept at ($p2) again"
stop
srv
client kitbob "$t/bob2.cmds"
want "$t/srv2.log" "kitbob back where they were at ($p2) in world"
p3=$(kept "$t/srv2.log")
echo "ok: over a server restart, back at ($p2), the pickaxe his"
# 4. Built over: the place's two cells
read -r x y z <<<"$(echo "$p3" | tr -d ',')"
cx=$(python3 -c "import math; print(math.floor($x + 0.5))")
cy=$(python3 -c "import math; print(math.floor($y + 0.5))")
cz=$(python3 -c "import math; print(math.floor($z + 0.5))")
voxels() # <cmds file> <"x, y, z voxel">...: kitboss sets them in edit mode
{
	local f=$1 v
	shift
	cat > "$f" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: edit mode on
EOF
	for v in "$@"; do
		echo "event kit_edit {\"op\": \"set_voxel\", \"pos\": [${v% *}], \"voxel\": \"${v##* }\"}" >> "$f"
	done
	printf 'sync 2000\nquit\n' >> "$f"
}
voxels "$t/boss2.cmds" "$cx, $cy, $cz kit/stone" "$cx, $((cy + 1)), $cz kit/stone"
client kitboss "$t/boss2.cmds"
client kitbob "$t/bob2.cmds"
want "$t/srv2.log" "kitbob's kept place ($p3) is built over: the spawn" \
	"kit/spawner 3: spawns kitbob"
echo "ok: built over while away: the spawn"
# 5. Dug out under the spawner, where he was kept: back there, falls
p4=$(kept "$t/srv2.log")
[ "$p4" = "0, 1, -4" ] || fail "kitbob was not kept on the spawner ($p4, $t/srv2.log)"
voxels "$t/boss3.cmds" "0, 0, -4 air" "0, -1, -4 air"
client kitboss "$t/boss3.cmds"
cat > "$t/bob3.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
sync 2000
frames 30
quit
EOF
client kitbob "$t/bob3.cmds"
stop
want "$t/srv2.log" "kitbob back where they were at (0, 1, -4) in world"
p5=$(kept "$t/srv2.log")
y5=$(echo "$p5" | awk -F', ' '{print $2}')
python3 -c "assert $y5 < 0, $y5" || fail "kitbob did not fall from the dug out place ($p5, $t/srv2.log)"
echo "ok: dug out under the place: back there, fell to y $y5"
echo "PASS: kit/player_state remember: a leaving player is back where he was with his items, over a restart too; built over, the spawn; dug out, he falls"
# vim: set noet ts=4 sw=4:
