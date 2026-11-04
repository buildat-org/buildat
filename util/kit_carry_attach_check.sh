#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-05)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/api.h builtin/kit/client_lua/players.lua
# [KIT_CARRY_ATTACH] c:attach and c:detach, with a type of the check's own
# (BUILDAT_WORKBENCH_TYPES: workbench/carry, a box; "grab" attaches it to
# whoever tries it, on the head, 0.5 over the neck; "drop" detaches it;
# "where" logs its c.pos). Workbench's stone floor, a fresh save:
# kitboss places it (3) and kit/controls (4, camera "chase") and plays;
# kitbob joins and watches. kitboss grabs it, walks 3 m along +z and
# turns to face kitbob:
#   - the server: attached, c.pos following kitboss's (within 0.6 m of
#     their place after the walk, 1.3 + 0.5 over their feet);
#   - kitbob's client: drawn on kitboss's body, 1.85 over their drawn feet
#     (0.3), screenshot other.png; kitboss's own: the same on their own
#     body (chase), screenshot own.png;
#   - "drop": detached, kitbob's look let go.
#   util/kit_carry_attach_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_carry_attach; t=$CHECK_TMP
cd "$here/Build"
# (in its app directory: the sandboxed server reads nothing else of the run's)
export BUILDAT_WORKBENCH_TYPES="$t/user/apps/workbench/check_types"
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
cat > "$BUILDAT_WORKBENCH_TYPES/carry.lua" <<'EOF'
-- The check's carried thing
local function f(x) return tostring(math.floor(x * 100 + 0.5) / 100) end
return {
	version = 1,
	players = true,
	look = {shape = "box", size = {0.3, 0.3, 0.3}, color = "#ffd020"},
	inputs = {grab = "any", drop = "any", where = "any"},
	on_input = function(c, input, v, by)
		if input == "grab" then
			c:attach(by, {bone = "head", offset = {0, 0.5, 0}})
		elseif input == "drop" then
			c:detach()
		else
			c:log("at " .. f(c.pos[1]) .. "," .. f(c.pos[2]) .. "," .. f(c.pos[3]))
		end
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
try() # <input>
{
	printf 'event kit_edit {"op": "try", "id": 3, "input": "%s", "value": null}\n' "$1"
	printf 'wait_log 10000 kit editor: tried 3'"'"'s %s\n' "$1"
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
	edit '{"op": "place", "type": "workbench/carry", "pos": [3, 1, 3]}'
	edit '{"op": "place", "type": "kit/controls", "pos": [-6, 1, -6]}'
	edit '{"op": "set", "id": 4, "comp": 0, "param": "camera", "value": "chase"}'
	edit '{"op": "set", "id": 4, "comp": 0, "param": "distance", "value": 4}'
	printf 'sync 2000\nquit\n'
} > "$t/boss1.cmds"
{
	cat <<EOF
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 60000 kit: player $BOB's body in
keypress F6
wait_log 10000 kit editor: edit mode on
EOF
	try grab
	cat <<EOF
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir 0 0 1
frames 5
keydown W
delay 700
keyup W
look_dir 0 -0.2 -1
delay 2500
event kit_players
screenshot $t/own.png
keypress F6
wait_log 10000 kit editor: edit mode on
EOF
	try where
	echo "delay 3000"
	try drop
	try where
	printf 'sync 2000\nquit\n'
} > "$t/boss2.cmds"
cat > "$t/bob.cmds" <<EOF
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
look_dir 0.55 0 1
wait_log_any 60000 kit: an entity drawn on player $BOSS
delay 3000
event kit_players
screenshot $t/other.png
wait_log_any 60000 kit: an entity let go of player
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
wait $bob || fail "kitbob's client did not draw it on kitboss ($t/bob.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -a "attached\|detached\|carry 3" "$s" | sed 's/^.* I [a-z_]* *: /  /' | cut -c1-150
want "$s" "Entity 3 attached to kitboss (head, 0, 0.5, 0)" "Entity 3 detached (c:detach)"
# Each client: the entity drawn 1.85 m over the body's feet (the neck's
# 1.35 at the model's 1.77, the offset 0.5), its x and z the body's
over() # <client log>: the drawn entity against kitboss's drawn feet
{
	local body ent
	body=$(grep -aoP "kit: player $BOSS drawn at \K[-0-9.,]+" "$1" | tail -1)
	ent=$(grep -aoP "kit: entity 3 drawn at \K[-0-9.,]+(?= on $BOSS head)" "$1" | tail -1)
	echo "  $(basename "$1"): kitboss's feet $body, the entity $ent"
	awk -v a="$body" -v b="$ent" 'BEGIN { split(a, p, ","); split(b, q, ",")
		exit !(b != "" && (p[1] - q[1]) ^ 2 + (p[3] - q[3]) ^ 2 < 0.09 &&
			q[2] - p[2] > 1.6 && q[2] - p[2] < 2.1 && p[3] > 1) }' ||
		fail "the entity not drawn over kitboss's head ($1)"
}
over "$t/bob.log"
over "$t/boss2.log"
want "$t/bob.log" "kit: an entity let go of player"
# The server's c.pos: near kitboss's feet's cell after the walk
read ex ey ez < <(grep -aoP "carry 3: at \K[-0-9.,]+" "$s" | head -1 | tr , ' ')
read bx bz < <(grep -aoP "kit: player $BOSS drawn at \K[-0-9.,]+" "$t/boss2.log" |
	tail -1 | awk -F, '{print $1, $3}')
echo "  the server's c.pos $ex,$ey,$ez"
awk -v x="$ex" -v y="$ey" -v z="$ez" -v bx="$bx" -v bz="$bz" 'BEGIN {
	exit !(x != "" && (x - bx) ^ 2 + (z - bz) ^ 2 < 0.36 && y > 2.0 && y < 2.6) }' ||
	fail "c.pos did not follow kitboss ($s)"
for f in own other; do
	[ -s "$t/$f.png" ] || fail "no screenshot $f ($t)"
done
echo "PASS: [KIT_CARRY_ATTACH] attached on the head: drawn over kitboss's drawn body by kitbob's client and kitboss's own, c.pos following; detached; screenshots $t/{own,other}.png"
