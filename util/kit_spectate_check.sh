#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~15 s (2026-11-06)
# covers: builtin/kit/client_lua/players.lua builtin/kit/client_lua/controls.lua
# [KIT_SPECTATE] A player out of play watches. Workbench's stone floor, a
# fresh save: kitboss places a World (3), kit/game_rules (4, respawn
# "on_signal") and a type of the check's own (BUILDAT_WORKBENCH_TYPES:
# workbench/doom, 5: used, it hurts its user by their health's whole)
# and plays; kitbob joins and stands. kitboss dies (doom's use)
# and waits: their client spectates -- the free camera, its hint
# (free.png), moved by W; a left click watches kitbob (from kitbob's eyes,
# watch.png), a right click goes back to the free camera; game_rules'
# respawn: back in play, spectating off.
#   util/kit_spectate_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_spectate; t=$CHECK_TMP
cd "$here/Build"
# (in its app directory: the sandboxed server reads nothing else of the run's)
export BUILDAT_WORKBENCH_TYPES="$t/user/apps/workbench/check_types"
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
cat > "$BUILDAT_WORKBENCH_TYPES/doom.lua" <<'EOF'
-- The check's death
return {
	version = 1,
	usable = true,
	look = {shape = "box", size = {0.3, 0.3, 0.3}, color = "#202020"},
	on_use = function(c, by)
		c:hurt(c.player, {fraction = 1})
	end,
}
EOF

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
try() # <id> <input>
{
	printf 'event kit_edit {"op": "try", "id": %s, "input": "%s", "value": null}\n' "$1" "$2"
	printf 'wait_log 10000 kit editor: tried %s'"'"'s %s\n' "$1" "$2"
}
BOB=1000001
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
	edit '{"op": "place", "type": "kit/world", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/game_rules", "pos": [-6, 1, -6]}'
	edit '{"op": "set", "id": 4, "comp": 0, "param": "respawn", "value": "on_signal"}'
	edit '{"op": "place", "type": "workbench/doom", "pos": [3, 1, 2]}'
	printf 'sync 2000\nquit\n'
} > "$t/boss1.cmds"
{
	cat <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 60000 kit: player $BOB's body in
look_dir 0 0 1
frames 5
keydown W
delay 700
keyup W
look_dir 0 -0.3 -1
frames 10
event kit_use 5
wait_log_any 10000 kit: spectating on
frames 10
event kit_players
screenshot @T@/free.png
keydown W
delay 1000
keyup W
frames 5
event kit_players
mouse_click left
wait_log 5000 kit: spectating kitbob
frames 30
event kit_players
screenshot @T@/watch.png
mouse_click right
wait_log 5000 kit: spectating with the free camera
keypress F6
wait_log 10000 kit editor: edit mode on
EOF
	try 4 respawn
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: spectating off
sync 2000
quit
EOF
} > "$t/boss2.cmds"
sed -i "s|@T@|$t|g" "$t/boss2.cmds"
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
look_dir 1 -0.2 0.3
wait_log_any 120000 kit: player 1000000's body gone
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
wait $bob
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log b=$t/boss2.log
grep -a "kit: spectat\|camera at" "$b" | sed 's/^.* I [a-z_]* *: /  /' | cut -c1-150
want "$s" "kitboss died" "respawns 1 waiting players"
want "$b" "kit: spectating on" "kit: spectating: Free camera:" \
	"kit: spectating: Watching kitbob" "kit: spectating off"
# The free camera moved by W (1 s at 8 m/s)
cams=($(grep -aoP "kit: the spectator's camera at \K[-0-9.,]+" "$b"))
[ "${#cams[@]}" -ge 2 ] || fail "no spectator's camera lines ($b)"
awk -v a="${cams[0]}" -v b="${cams[1]}" 'BEGIN { split(a, p, ","); split(b, q, ",")
	exit !((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2 + (p[3] - q[3]) ^ 2 > 25) }' ||
	fail "the free camera did not move (${cams[0]} -> ${cams[1]}; $b)"
for f in free watch; do
	[ -s "$t/$f.png" ] || fail "no screenshot $f ($t)"
done
echo "PASS: [KIT_SPECTATE] dead and waiting: the free camera (moved), kitbob watched, back to free, off at the respawn; screenshots $t/{free,watch}.png"
