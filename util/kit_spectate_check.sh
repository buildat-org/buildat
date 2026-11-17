#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~50 s (2026-11-17)
# covers: builtin/kit/client_lua/players.lua builtin/kit/client_lua/controls.lua builtin/kit/types/controls.lua builtin/kit/types/lobby.lua
# [KIT_SPECTATE] A player out of play watches. Workbench's stone floor, a
# fresh save: kitboss places a World (3), kit/game_rules (4, respawn
# "on_signal") and a type of the check's own (BUILDAT_WORKBENCH_TYPES:
# workbench/doom, 5: used, it hurts its user by their health's whole)
# and plays; kitbob joins and stands. kitboss dies (doom's use)
# and waits: their client spectates -- the free camera, its hint
# (free.png), moved by W; a left click watches kitbob (from kitbob's eyes,
# watch.png), a right click goes back to the free camera; game_rules'
# respawn: back in play, spectating off.
# [KIT_SPECTATE_CAMERA] Then both again, driven step by step: kitboss
# places kit/controls (camera side, distance 10) and a kit/lobby and, by
# Try as kitbob, plays him and ends his run: kitbob on the result card
# keeps the side camera (its turn unchanged, at his held body, not moved;
# side.png); his left click watches kitboss, who walks right: the camera
# follows him sideways; fov 40 and shake 5 by nobody take effect on it;
# camera_target 5 (doom) as kitbob: his camera at the entity, kitboss's
# own on his body (no target); camera_target 0: back on kitboss; the
# camera first_person by nobody: the watched one's eyes, fov 50 and shake
# 4 taking effect there. All on a headless weston's Xwayland of its own.
#   util/kit_spectate_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_spectate; t=$CHECK_TMP
cd "$here/Build"
sock=buildat-spec-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
export DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11
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
	edit '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
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
echo "ok: [KIT_SPECTATE] dead and waiting: the free camera (moved), kitbob watched, back to free, off at the respawn"

# ---- [KIT_SPECTATE_CAMERA] Both again, each driven from here (a fifo)
mark() { wc -c < "$1"; }
as() # <boss|bob>: the client the next commands drive
{
	if [ "$1" = bob ]; then CL=$t/bob2.log CLIENT=$BOB FD=4
	else CL=$t/boss3.log CLIENT=$BOSS FD=3; fi
}
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($s, $CL)"
}
cmd() { printf '%s\n' "$@" >&$FD; }
step() # <seconds> <regex in the client's log> <command>...
{
	local sec=$1 re=$2 m
	shift 2
	m=$(mark "$CL")
	cmd "$@"
	await "$CL" "$m" "$sec" "$re"
}
fifo_client() # <name> <file>: commands from the fifo $t/<file>.cmd, log $t/<file>.log
{
	mkfifo "$t/$2.cmd"
	sleep 900 > "$t/$2.cmd" &
	CHECK_PIDS+=($!)
	BUILDAT_JOIN_NAME=kit$1 timeout 300 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -c - \
		< "$t/$2.cmd" > "$t/$2.log" 2>&1 &
	CHECK_PIDS+=($!)
}
ed() # <json>: an edit, its answer
{
	step 10 "entities, [0-9]+ to undo|kit editor: refused" "event kit_edit $1"
	! tail -c 400 "$CL" | grep -aq "kit editor: refused" || fail "refused: $1 ($CL)"
}
try_as() # <id> <input> <json value> <as>
{
	step 10 "kit editor: tried $1's $2|kit editor: refused" \
		"event kit_edit {\"op\": \"try\", \"id\": $1, \"input\": \"$2\", \"value\": $3, \"as\": \"$4\"}"
	! tail -c 400 "$CL" | grep -aq "kit editor: refused" || fail "refused: $1's $2 as $4 ($CL)"
}
camera() # the client's camera now, into cx cy cz, turn cw qx qy qz, fov cf, shaken csh
{
	step 5 "kit: camera at " "event kit_body"
	read cx cy cz cw qx qy qz cf csh <<< "$(tail -c 3000 "$CL" | grep -aoP \
		'kit: camera at \K[-0-9.,]+ turn [-0-9.,]+, fov [0-9.]+, shaken [0-9.]+' |
		tail -1 | sed -E 's/ turn |, fov |, shaken |,/ /g')"
}
body() # the client's body's feet now, into bx by bz (after camera())
{
	read bx by bz <<< "$(tail -c 3000 "$CL" | grep -aoP 'kit: body at \K[-0-9.]+,[-0-9.]+,[-0-9.]+' |
		tail -1 | tr , ' ')"
}
near() { awk -v a="$1" -v b="$2" -v e="$3" 'BEGIN { exit !(a - b < e && b - a < e) }'; }
level() # the camera's turn level and unturned (a side camera's): w 1
{
	near "$cw" 1 0.001 && near "$qx" 0 0.001 && near "$qy" 0 0.001 && near "$qz" 0 0.001
}
fifo_client boss boss3
BOSS=$!
exec 3> "$t/boss3.cmd"
fifo_client bob bob2
BOB=$!
exec 4> "$t/bob2.cmd"
as bob
await "$CL" 0 60 "player physics enabled"
as boss
await "$CL" 0 60 "player physics enabled"
await "$CL" 0 10 "kit editor: edit rights: yes"
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
ed '{"op": "place", "type": "kit/controls", "pos": [0, 1, 0], "params": {"camera": "side", "distance": 10}}'
ed '{"op": "place", "type": "kit/lobby", "pos": [0, 1, 4]}'
C=$(grep -aoP 'placed kit/controls \K[0-9]+' "$s" | tail -1)
L=$(grep -aoP 'placed kit/lobby \K[0-9]+' "$s" | tail -1)
[ -n "$C" ] && [ -n "$L" ] || fail "no kit/controls or kit/lobby placed ($s)"
try_as $L play null kitboss
try_as $L play null kitbob
as bob
await "$CL" 0 10 "kit: controls: camera side"
# In play, the side camera at his body
cmd "delay 600"
camera
level || fail "kitbob's side camera turned in play: $cw,$qx,$qy,$qz ($CL)"
c0=($cx $cy $cz)
# The result card: out of play, the camera as it was
m=$(mark "$CL")
as boss
try_as $L over null kitbob
as bob
await "$CL" "$m" 10 "kit: spectating on"
cmd "delay 500"
camera
body
level || fail "kitbob's camera turned on the result card: $cw,$qx,$qy,$qz ($CL)"
for i in 0 1 2; do
	c=($cx $cy $cz)
	near "${c[$i]}" "${c0[$i]}" 0.05 || fail "kitbob's camera moved on the result card: ${c0[*]} -> ${c[*]} ($CL)"
done
near "$cx" "$bx" 0.05 && awk -v c="$cy" -v b="$by" 'BEGIN { exit !(c - b > 0.5 && c - b < 1.2) }' ||
	fail "kitbob's camera ($cx,$cy) not at his held body ($bx,$by) ($CL)"
grep -aq "kit: spectating: Free camera" "$CL" && fail "a free camera's hint in a side game ($CL)"
cmd "screenshot $t/side.png"
echo "ok: the result card in a side game: the camera at kitbob's held body ($cx,$cy over $bx,$by), level, unmoved"
# Watching kitboss, who walks right: followed sideways. A held key may read
# as not held: once again if he never went
as boss
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
as bob
cmd "mouse_pos 512 350" "frames 3"
step 5 "kit: spectating kitboss" "mouse_click left"
cmd "delay 500"
camera
c2=$cx
as boss
for try in 1 2; do
	camera
	body
	b0=$bx
	cmd "keydown D" "delay 900" "delay 600" "keyup D" "delay 500"
	camera
	body
	awk -v a="$b0" -v b="$bx" 'BEGIN { exit !(b - a > 2) }' && break
done
awk -v a="$b0" -v b="$bx" 'BEGIN { exit !(b - a > 2) }' || fail "kitboss did not walk right: $b0 -> $bx ($CL)"
near "$cx" "$bx" 0.05 || fail "kitboss's own camera ($cx) not at his body ($bx) ($CL)"
kb=($bx $by)
as bob
cmd "delay 400"
camera
level && near "$cx" "${kb[0]}" 0.1 && awk -v c="$cy" -v b="${kb[1]}" 'BEGIN { exit !(c - b > 0.5 && c - b < 1.2) }' ||
	fail "kitbob's camera ($cx,$cy turn $cw,$qx,$qy,$qz) not following kitboss sideways (${kb[*]}) ($CL)"
c3=($cx $cy $cz $cf)
echo "ok: watching kitboss: the camera followed him sideways, $c2 -> $cx, level"
# fov and shake on a spectator's side camera
as boss
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
try_as $C fov 40 nobody
try_as $C shake 5 nobody
as bob
await "$CL" 0 10 "kit: camera fov 40 over"
await "$CL" 0 10 "kit: camera shake 5"
cmd "delay 300"
camera
near "$cf" 40 0.5 || fail "fov 40 not on kitbob's camera: $cf ($CL)"
awk -v d="$csh" 'BEGIN { exit !(d > 0.01) }' || fail "shake 5 not on kitbob's camera: $csh ($CL)"
echo "ok: fov $cf and a shake ($csh m off) on the spectator's side camera"
# camera_target by kitbob alone: his camera at the entity, kitboss's not
m=$(mark "$t/boss3.log")
as boss
try_as $C camera_target 5 kitbob
as bob
await "$CL" 0 10 "kit: camera target entity 5 at"
tg=($(grep -aoP 'kit: camera target entity 5 at \K\S+' "$CL" | tail -1 | tr , ' '))
cmd "delay 600"
camera
near "$cx" "${tg[0]}" 0.1 && near "$cy" "${tg[1]}" 0.1 ||
	fail "kitbob's camera ($cx,$cy) not at the target (${tg[*]}) ($CL)"
as boss
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
cmd "delay 400"
camera
body
near "$cx" "$bx" 0.05 || fail "kitboss's camera ($cx) not on his own body ($bx): kitbob's target his too? ($CL)"
grep -aq "kit: camera target entity" "$CL" && fail "kitbob's camera_target on kitboss's client ($CL)"
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
try_as $C camera_target 0 kitbob
as bob
await "$CL" 0 10 "kit: camera target none, was entity 5"
cmd "delay 600"
camera
near "$cx" "${c3[0]}" 0.1 && near "$cy" "${c3[1]}" 0.1 ||
	fail "kitbob's camera ($cx,$cy) not back on kitboss (${c3[*]}) ($CL)"
echo "ok: camera_target 5 by kitbob: his camera at it (${tg[*]}), kitboss's on his body; 0: back on kitboss"
# first_person: the watched one's eyes, fov and shake there too
as boss
try_as $C camera '"first_person"' nobody
try_as $C fov 50 nobody
try_as $C shake 4 nobody
as bob
await "$CL" 0 10 "kit: camera mode first_person"
await "$CL" 0 10 "kit: camera shake 4"
cmd "delay 300"
camera
near "$cf" 50 0.5 || fail "fov 50 not on kitbob's first-person spectator camera: $cf ($CL)"
awk -v d="$csh" 'BEGIN { exit !(d > 0.01) }' || fail "shake 4 not on kitbob's first-person spectator camera: $csh ($CL)"
grep -aq "kit: spectating: Watching kitboss" "$CL" || fail "no watching hint ($CL)"
echo "ok: first_person while spectating: fov $cf and a shake ($csh m off)"
for f in 3 4; do
	FD=$f cmd "sync 2000" quit
done
exec 3>&- 4>&-
wait $BOSS $BOB 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
[ -s "$t/side.png" ] || fail "no screenshot side ($t)"
echo "PASS: [KIT_SPECTATE] dead and waiting: the free camera (moved), kitbob watched, back to free, off at the respawn; [KIT_SPECTATE_CAMERA] a side game's result card keeps the side camera on the held body, watching follows sideways, fov and shake while spectating (side and first person), camera_target for one player and back; screenshots $t/{free,watch,side}.png"
