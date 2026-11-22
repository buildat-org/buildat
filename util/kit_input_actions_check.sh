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
#      count (4) and held -> another's (6); a kit/sign (5) "Press
#      [{key:use}] to use, [{key:fire}] to fire, [{key:forward}] to walk,
#      {key:jump} to jump, {key:item_next} {key:nosuch} {foo:bar} [use]"
#      shows kitboss "[Left click] ... [R] ... [I] ... Space ... (unbound)
#      {key:nosuch} {foo:bar} [use]" (use: no key by default, the left
#      click; [KIT_TEXT_PLACEHOLDER] {key:<action>} bare, an unknown action
#      and word as written, a [<word>] too, the server warning kitboss of
#      {foo:...} after the edit and at Play);
#      R held: the server's "Action fire pressed", counter 4 counts once,
#      counter 6 at least once; the key store has Kit's actions and the
#      world's (the keys page); there Jump rebound to J: the sign shows
#      "J to jump" once the settings close;
#   3b. [KIT_KEY_ACTIONS_CAP] the check's types workbench/acts_a (8
#      actions) and acts_b (7) placed: with fire the world's 16 actions;
#      each key pressed reaches the server; the store has the 16th;
#      [KIT_SMALL_PIECES] b7's mouse = "middle": the middle button presses
#      it too;
#   3c. [WB_MUTE_KEY] Workbench's M in the editor mutes, again unmutes; M
#      in an inspector field does not, nor in play where the world's b1 is
#      on M (b1 is pressed);
#   4. kitbob on a touchscreen (BUILDAT_TOUCH=1): a Fire button over
#      the touch bar; pressed, the counter counts again; the sign shows him
#      "[Tap] ... [Fire] ... [the stick] ... Jump ... [use]" (on a touchscreen: a
#      tap, the on-screen controls' labels).
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
# The check's types: 8 and 7 actions (with fire, the world's 16 at most)
mkdir -p "$t/user/apps/workbench/check_types"
acts_type() # <name> <prefix> <key>...
{
	local f=$t/user/apps/workbench/check_types/$1.lua p=$2 i=1 k
	shift 2
	echo "local acts = {}" > "$f"
	for k in "$@"; do
		echo "acts[$i] = {name = \"$p$i\", key = \"$k\", label = \"$p$i\"}" >> "$f"
		i=$((i + 1))
	done
	# ([KIT_SMALL_PIECES] the last one's mouse button: MOUSE_LAST)
	[ -z "${MOUSE_LAST:-}" ] || echo "acts[$((i - 1))].mouse = \"$MOUSE_LAST\"" >> "$f"
	echo "return {version = 1, actions = acts}" >> "$f"
}
ACTS_A="Y U O P J K L N" ACTS_B="M F4 F5 F7 F8 Home End"
acts_type acts_a a $ACTS_A
MOUSE_LAST=middle acts_type acts_b b $ACTS_B
export BUILDAT_WORKBENCH_TYPES=$t/user/apps/workbench/check_types
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
keypress M
wait_log 5000 workbench: the mute key: sound
keypress M
wait_log 5000 workbench: the mute key: sound
EOF
	edit '{"op": "place", "type": "kit/action", "pos": [2, 1, 4]}'
	edit '{"op": "place", "type": "kit/counter", "pos": [3, 1, 4]}'
	edit '{"op": "link", "id": 3, "comp": 0, "output": "pressed", "to": 4, "input": "count"}'
	edit '{"op": "place", "type": "kit/sign", "pos": [0, 2, 10]}'
	set_p 5 text '"Press [{key:use}] to use, [{key:fire}] to fire, [{key:forward}] to walk, {key:jump} to jump, {key:item_next} {key:nosuch} {foo:bar} [use]"'
	# (M typed in a field: no mute; a click on the world takes the focus)
	cat <<'EOF'
event kit_select 5
frames 5
click LineEdit "position x"
frames 2
keypress M
frames 2
screenshot @T@/field.png
mouse_pos 512 200
frames 2
mouse_click left
frames 3
EOF
	edit '{"op": "place", "type": "kit/counter", "pos": [4, 1, 4]}'
	edit '{"op": "link", "id": 3, "comp": 0, "output": "held", "to": 6, "input": "count"}'
	cat <<'EOF'
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: the world's actions: 1
wait_log_any 10000 kit: entity 5 shows "Press [Left click] to use, [R] to fire, [I] to walk, Space to jump, (unbound) {key:nosuch} {foo:bar} [use]"
look 0 0
frames 10
screenshot @T@/sign.png
keydown R
delay 600
keyup R
wait_log 10000 kit: action fire released
frames 10
keypress F6
wait_log 10000 kit editor: edit mode on
EOF
	edit '{"op": "place", "type": "workbench/acts_a", "pos": [5, 1, 4]}'
	edit '{"op": "place", "type": "workbench/acts_b", "pos": [6, 1, 4]}'
	printf '%s\n' "keypress F6" "wait_log_any 10000 kit: the world's actions: 16" \
		"frames 10"
	for k in $ACTS_A $ACTS_B; do
		printf 'keydown %s\nframes 5\nkeyup %s\nframes 5\n' "$k" "$k"
	done
	cat <<'EOF'
wait_log_any 10000 kit: action b7 released
frames 10
mouse_down middle
frames 5
mouse_up middle
wait_log 10000 kit: action b7 released
frames 10
keypress Escape
frames 5
click Button "Settings..."
frames 5
click Button "Key bindings..."
frames 10
screenshot @T@/keys.png
click Button "Jump, or up in the editor's 3D view"
wait_log 5000 Jump, or up in the editor's 3D view waits for a key
keypress J
wait_log 5000 Jump, or up in the editor's 3D view = J
keypress Escape
frames 5
keypress Escape
wait_log 10000 kit: entity 5 shows "Press [Left click] to use, [R] to fire, [I] to walk, J to jump
sync 3000
quit
EOF
} > "$t/kitboss.cmds"
cat > "$t/kitbob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit: the touch bar: Jump, Menu; the world's: Fire
wait_log_any 10000 kit: entity 5 shows "Press [Tap] to use, [Fire] to fire, [the stick] to walk, Jump to jump, (unbound) {key:nosuch} {foo:bar} [use]"
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
for a in a1 a2 a3 a4 a5 a6 a7 a8 b1 b2 b3 b4 b5 b6 b7; do
	want "$s" "Action $a pressed by kitboss"
done
grep -aqP '^action\t[^\t]+\tb7\tEnd\t' "$t/cu_kitboss/keys.txt" ||
	fail "the key store lacks the world's 16th action"
echo "ok: the world's 16 actions: each key reached the server"
# [KIT_SMALL_PIECES] b7's mouse = "middle": the middle button pressed it again
[ "$(grep -ac 'Action b7 pressed by kitboss' "$s")" -ge 2 ] ||
	fail "the middle mouse button did not press b7 (mouse = \"middle\") ($s)"
echo "ok: an action's mouse button (b7's middle) presses it"
# [WB_MUTE_KEY] M in the editor muted and unmuted; in a field, and in play
# where the world's action b1 has M, it did not
m=$(grep -aoP "workbench: the mute key: sound \K\S+" "$c" | tr '\n' ' ')
[ "$m" = "muted on " ] || [ "$m" = "on muted " ] ||
	fail "the mute key: not muted and unmuted once each in the editor alone: $(grep -a "workbench: the mute key" "$c" | sed 's/^.*: //' | tr '\n' ' ') ($c)"
grep -aqP '^action\t[^\t]+\tmute\tM\t' "$t/cu_kitboss/keys.txt" ||
	fail "the key store lacks Workbench's mute key"
echo "ok: M muted and unmuted in the editor, not in a field nor over the world's b1 in play; the store has it"
want "$c" 'kit: entity 5 shows "Press [Left click] to use, [R] to fire, [I] to walk, Space to jump, (unbound) {key:nosuch} {foo:bar} [use]"' \
	'kit: entity 5 shows "Press [Left click] to use, [R] to fire, [I] to walk, J to jump, (unbound) {key:nosuch} {foo:bar} [use]"' \
	"kit: warning: entity 5's kit/sign text: {foo:...} is no text placeholder of Kit's" \
	"kit: the gamepad read"
k=$t/cu_kitboss/keys.txt
grep -aqP '^action\t[^\t]+\tforward\tW\tmove.forward\t' "$k" &&
	grep -aqP '^action\t[^\t]+\tfire\tR\t\tThis world: Fire$' "$k" &&
	grep -aqP '^action\t[^\t]+\tvoxel1\t1\t' "$k" &&
	grep -aqP '^shared\tmove.forward\tI$' "$k" ||
	fail "the key store lacks Kit's, Workbench's or the world's actions ($k)"
want "$s" "kitboss's edit: entity 5's kit/sign text: {foo:...} is no text placeholder of Kit's"
grep -a "edit: entity 5's" "$s" | grep -aq "nosuch" &&
	fail "{key:nosuch} warned of, though key is Kit's word ($s)"
echo "ok: the sign shows kitboss's keys, {key:jump} J after the rebind, {key:item_next} (unbound), {key:nosuch}, {foo:bar} and [use] as written, {foo:...} warned of; the store has Kit's, Workbench's and the world's actions"
# 4. The touch bar
want "$t/kitbob.log" "kit: the touch bar: Jump, Menu; the world's: Fire"
echo "ok: a touch client: the Fire button, pressed, reached the counter"
for p in keys sign touch; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
echo "PASS: Kit's input actions: a rebound key walks and flies the editor; an action's signal linked; {key:use} in a sign; a touch button; Workbench's mute key; screenshots $t/keys.png $t/sign.png $t/touch.png"
