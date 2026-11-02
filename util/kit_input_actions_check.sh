#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1.5 min (2026-11-02)
# covers: builtin/kit/kit.cpp builtin/kit/api.h builtin/kit/types/action.lua builtin/kit/client_lua/** apps/workbench/main/client_lua/init.lua
# [KIT_INPUT_ACTIONS] Kit's keys as named actions on Workbench. kitboss's
# key store has the shared name move.forward bound to I before the start:
#   1. play: W walks nowhere, I walks forward;
#   2. the editor's 3D view: I flies the camera forward;
#   3. a kit/action "fire" (key R, 3) linked pressed -> a kit/counter's
#      count (4) and held -> another's (6); a kit/sign (5) "Press [use] to
#      use, [fire] to fire, [forward] to walk" shows kitboss "[E] ... [R]
#      ... [I]"; R held: the server's "Action fire pressed", counter 4
#      counts once, counter 6 at least once;
#      the key store has Kit's actions and the world's (the keys page);
#   4. kitbob on a touchscreen (BUILDAT_TOUCH=1): a Fire button over
#      the touch bar; pressed, the counter counts again; the sign shows him
#      "[Use] ... [Fire] ... [Forward ...]" (the buttons' labels).
# Screenshots kept with KEEP_TMP=1: $t/keys.png (the pause menu's
# Settings, Key bindings), $t/sign.png, $t/touch.png; look at them.
#   util/kit_input_actions_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_input_actions; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

client() # <name>: its commands in $t/<name>.cmds
{
	sed -i "s|@T@|$t|g" "$t/$1.cmds"
	run_client 60 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" || fail "client $1 failed ($t/$1.log, $t/srv.log)"
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
mkdir -p "$t/cu_kitboss"
printf 'shared\tmove.forward\tI\n' > "$t/cu_kitboss/keys.txt"

n=0
edit() # <op json>: an edit and its answer
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
set_p() # <id> <param> <json value>
{
	edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
look 0 -10
frames 10
event kit_body
keydown W
delay 800
keyup W
frames 30
event kit_body
keydown I
delay 1000
keyup I
frames 60
event kit_body
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
keypress F2
frames 5
event kit_cam_where before
keydown I
delay 500
keyup I
frames 2
event kit_cam_where after
EOF
	edit '{"op": "place", "type": "kit/action", "pos": [2, 1, 4]}'
	edit '{"op": "place", "type": "kit/counter", "pos": [3, 1, 4]}'
	edit '{"op": "link", "id": 3, "comp": 0, "output": "pressed", "to": 4, "input": "count"}'
	edit '{"op": "place", "type": "kit/sign", "pos": [0, 2, 10]}'
	set_p 5 text '"Press [use] to use, [fire] to fire, [forward] to walk"'
	edit '{"op": "place", "type": "kit/counter", "pos": [4, 1, 4]}'
	edit '{"op": "link", "id": 3, "comp": 0, "output": "held", "to": 6, "input": "count"}'
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: the world's actions: 1
wait_log_any 10000 kit: entity 5 shows "Press [E] to use, [R] to fire, [I] to walk"
look 0 0
frames 10
screenshot @T@/sign.png
keydown R
delay 600
keyup R
wait_log 10000 kit: action fire released
frames 10
keypress Escape
frames 5
click Button "Settings..."
frames 5
click Button "Key bindings..."
frames 10
screenshot @T@/keys.png
sync 3000
quit
EOF
} > "$t/kitboss.cmds"
cat > "$t/kitbob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit: the touch bar: Jump, Menu; the world's: Fire
wait_log_any 10000 kit: entity 5 shows "Press [Use what is pointed at] to use, [Fire] to fire, [Forward (play and the editor)] to walk"
frames 10
screenshot @T@/touch.png
click Button "Fire"
wait_log 10000 kit: action fire released
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
	BUILDAT_JOIN_ADMIN="setting open_registration on" client kitboss
BUILDAT_TOUCH=1 BUILDAT_JOIN_NAME=kitbob client kitbob
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
c=$t/kitboss.log s=$t/srv.log
grep -a "kit: body at\|3D camera at\|kit: keys:\|Action fire\|counter 4: count [0-9]" "$c" "$s" |
	sed 's/^.*kit[a-z_/ 0-9]*: //' | cut -c1-140

# 1. W nowhere, I forward (z: the third field)
body_z() { grep -aoP 'kit: body at [-0-9.]+,[-0-9.]+,\K[-0-9.]+' "$c" | sed -n "$1p"; }
z1=$(body_z 1) z2=$(body_z 2) z3=$(body_z 3)
[ -n "$z3" ] || fail "no body lines ($c)"
awk -v a="$z1" -v b="$z2" 'BEGIN { exit !((b - a) ^ 2 < 0.01) }' ||
	fail "W walked though forward is I: z $z1 -> $z2"
awk -v a="$z2" -v b="$z3" 'BEGIN { exit !(b - a > 2) }' ||
	fail "I did not walk forward: z $z2 -> $z3"
echo "ok: play: W walks nowhere, I (move.forward rebound) walks forward"
# 2. The editor's camera
cam() { grep -aoP "the 3D camera at \K[-0-9. ]+(?= \($1\))" "$c"; }
read -r ax ay az <<< "$(cam before)"
read -r bx by bz <<< "$(cam after)"
[ -n "${bz:-}" ] || fail "no 3D camera lines ($c)"
awk -v a="$ax" -v b="$az" -v c="$bx" -v d="$bz" \
	'BEGIN { exit !((c - a) ^ 2 + (d - b) ^ 2 > 1) }' ||
	fail "I did not fly the editor's camera: $ax $az -> $bx $bz"
echo "ok: the editor: I flies the 3D camera"
# 3. The action's signal, the sign, the store
want "$s" "Action fire pressed by kitboss" "Action fire released by kitboss" \
	"Action fire pressed by kitbob"
[ "$(grep -ac 'kit/counter 4: count 1 by' "$s")" = 1 ] &&
	[ "$(grep -ac 'kit/counter 4: count 2 by' "$s")" = 1 ] ||
	fail "the counter did not count each press once ($s)"
grep -aq "kit/action 3: fire pressed by" "$s" || fail "no on_action ($s)"
grep -aq "kit/counter 6: count 1 by kitboss" "$s" ||
	fail "R held: no \"held\" reached counter 6 ($s)"
echo "ok: R pressed: kit/action's pressed and held reached the linked counters"
want "$c" 'kit: entity 5 shows "Press [E] to use, [R] to fire, [I] to walk"' \
	"kit: the gamepad read"
k=$t/cu_kitboss/keys.txt
grep -aqP '^action\t[^\t]+\tforward\tW\tmove.forward\t' "$k" &&
	grep -aqP '^action\t[^\t]+\tfire\tR\t\tThis world: Fire$' "$k" &&
	grep -aqP '^action\t[^\t]+\tvoxel1\t1\t' "$k" &&
	grep -aqP '^shared\tmove.forward\tI$' "$k" ||
	fail "the key store lacks Kit's, Workbench's or the world's actions ($k)"
echo "ok: the sign shows kitboss's keys; the store has Kit's, Workbench's and the world's actions"
# 4. The touch bar
want "$t/kitbob.log" "kit: the touch bar: Jump, Menu; the world's: Fire"
echo "ok: a touch client: the Fire button, pressed, reached the counter"
for p in keys sign touch; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
echo "PASS: Kit's input actions: a rebound key walks and flies the editor; an action's signal linked; [use] in a sign; a touch button; screenshots $t/keys.png $t/sign.png $t/touch.png"
