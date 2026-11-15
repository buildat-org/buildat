#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~30 s (2026-11-15)
# covers: apps/workbench/templates/crag_trial/** builtin/kit/box/box.c builtin/kit/client_lua/move.lua builtin/kit/client_lua/controls.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/players.lua builtin/kit/kit.cpp builtin/accounts/client_lua/accounts.lua
# [KIT_PLANE] stage 4: a movement of a project's own, the Crag Trial template
# (local/crag_bike, its gems and run) on Workbench; one server, kitboss (the
# admin) and kitbob on a headless weston's Xwayland of the check's own:
#   0. the template packed by util/pack_templates.sh and installed, its
#      types with it;
#   1. New from it: the editor in 2D, the Front view in a game whose camera
#      is side (edit.png, its kit/controls' edit_view 2d); Walk, the view
#      clicked (30 selected), then 7 picked in Entities: 7 stays selected
#      ([KIT_CRAG_PLAYTEST_1], fault 0a9); F6: the side camera, the bike's
#      movement, its client part's draw hook drawing the body (start.png),
#      the bike on the ground at y 0, the 1 grid ([KIT_CRAG_PLAYTEST_1]);
#      [KIT_LOBBY] first the lobby (a full screen, lobby.png), Play starting
#      the run;
#   2. W, then A: the bike up the first ramp's polygon, leaning back, the
#      head down: the crash (crag_bike's output, linked to the run: its line
#      says Crashed), the bike back at the start a second later;
#   3. back in edit mode (Stopped), a version with a heavy step put over
#      kit:type: refused, "too slow";
#   4. played again, W: the old version steps on the server, the first gem's trigger zone
#      taken (the run's line: Gems 1/3, side.png); the corrections few; the
#      side camera led ahead in +x, after Space (turned round) in -x
#      (turned.png, [KIT_SIDE_LEAD]);
#   5. kitbob joins, his body drawn by the hook on kitboss's screen; his
#      first My account page drawn again when the hello comes, "Connect an
#      agent..." on it (accounts.lua); [KIT_LOBBY] he in the lobby, the gem
#      kitboss took still drawn for him (each rider's own);
#   6. [CRAG_BEST_RESET] a fourth gem placed, linked only to the run: the run
#      counts it (Gems 0/4), the finish refused at 3 of 4 and taken at 4, the
#      run's reset brings it back; [KIT_LOBBY] the finish the result card
#      (an over screen: the time, result.png); the best on the top-5 sign (a kit/sign
#      fed by the run's board), kitbob's clear_kept refused (no builder),
#      End then Play: still listed;
#   7. the server restarted Ended, kitboss back, Play: still listed, his HUD's
#      best; the inspector's Clear kept state (asked first) empties the
#      sign, Undo brings it back; the lobby lists it, Play (sign.png).
# And [KIT_PLAY_HINTS]: Workbench's help line in play the bike's own hints
# (movement.help), W's and A's gone once used, Space's last after the gem:
# the line gone, kept in Kit's storage (kit_hints).
# Screenshots, kept with KEEP_TMP=1: $t/edit.png, $t/lobby.png, $t/start.png,
# $t/side.png, $t/turned.png, $t/result.png, $t/sign.png
#   util/kit_bike_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_bike; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
check_build
b="$here/Build/bin/buildat"

# 0. Packed and installed
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
zip=$("$here/util/pack_templates.sh" "$t/key" "$t/out" crag_trial 2> "$t/pack.err") ||
	fail "the pack ($t/pack.err)"
"$b" aitta install "$zip" "$t/user" > "$t/install.txt" 2>&1 || fail "the install ($t/install.txt)"
fp=$(aitta_fp "$t/pub")
for f in crag_bike.lua crag_bike.client.lua crag_gem.lua crag_run.lua; do
	[ -f "$t/user/installed/$fp/crag_trial/1.0.0/types/$f" ] ||
		fail "no types/$f installed ($t/install.txt)"
done
echo "ok: Crag Trial packed and installed"

sock=buildat-bike-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=800 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
SL=$t/srv.log CL=$t/boss.log FD=3
mark() { wc -c < "$1"; }
as() # <boss|bob>: the client the next commands drive
{
	if [ "$1" = bob ]; then
		CL=$t/bob.log CLIENT=$BOB FD=4
	else
		CL=$t/boss.log CLIENT=$BOSS FD=3
	fi
}
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL, $CL)"
}
seen() { tail -c +$(($2 + 1)) "$1" | grep -qaE "$3"; } # <log> <offset> <regex>
cmd() { printf '%s\n' "$@" >&$FD; }
step() # <seconds> <regex in the client's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$CL")
	cmd "$@"
	await "$CL" "$m" "$s" "$re"
}
body() # the body's x and y now, into bx and by
{
	step 5 "kit: body at" "event kit_body"
	read bx by <<< "$(tail -c 3000 "$CL" | grep -aoP 'kit: body at \K-?[0-9.]+,-?[0-9.]+' |
		tail -1 | tr , ' ')"
}
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
grep -aq "workbench: the template in .*crag_trial" "$SL" && fail "the template refused ($SL)"
client() # <name> [<file>]: its commands from the fifo $t/<file>.cmd, its log $t/<file>.log
{
	local f=${2:-$1}
	mkfifo "$t/$f.cmd"
	sleep 900 > "$t/$f.cmd" &
	CHECK_PIDS+=($!)
	DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kit$1 \
		timeout 600 bin/buildat -C "$t/client_cache_$1" -D "$t/cu_$1" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
		< "$t/$f.cmd" > "$t/$f.log" 2>&1 &
	CHECK_PIDS+=($!)
}
# (registration open for kitbob)
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss
BOSS=$!
exec 3> "$t/boss.cmd"
as boss
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
# 1. New from the installed template, played
await "$CL" 0 30 "world_menu: the list shown"
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New project..."'
cmd "frames 3" 'click DropDownList "▼"' "delay 300" "frames 3"
step 10 "world_menu: template picked" 'click Text "Crag Trial (buildat, installed, unverified)"'
step 60 "kit editor: edit mode on" "frames 3" 'click Button "Create"'
await "$CL" 0 30 "player physics enabled"
# [KIT_EDIT_VIEW] the template's kit/controls: the editor comes up in 2D,
# [KIT_CRAG_PLAYTEST_1] the Front view in a game whose camera is side
await "$CL" 0 10 "kit editor: kit/controls' edit view 2d"
await "$CL" 0 10 "kit editor: the view is 2D \(front\)"
cmd "frames 10" "screenshot $t/edit.png"
echo "ok: the editor came up in 2D, the Front view (kit/controls' edit_view 2d)"
# [KIT_CRAG_PLAYTEST_1] (fault 0a9) Walk in a side game: the view clicked
# (the mountains, 30), then 7 picked in Entities' Scene list. 7 stays: the
# free pointer takes no crosshair, which made each click on a panel one at
# the view's middle, 30 again
step 5 "kit editor: the view is Walk" "keypress F3"
cmd "frames 5" 'click Button "Entities"' "frames 3"
step 5 "kit editor: selected 30 " "mouse_pos 600 350" "frames 3" "mouse_click left"
step 5 "kit editor: selected 7 " "frames 5" 'click Button "Scene (*"' "frames 5" 'click Button "select 7"'
m=$(mark "$CL")
step 5 "kit: body at" "frames 30" "event kit_body"
seen "$CL" "$m" "kit editor: selected " && fail "7 not kept selected in Walk: $(tail -c +$((m + 1)) "$CL" | grep -a "kit editor: selected" | head -1) ($CL)"
step 5 "kit editor: the view is 2D \(front\)" "keypress F1"
echo "ok: Walk: the view clicked, then 7 picked in the list: 7 kept"
for re in "The template's type local/crag_bike \([0-9]+ bytes\)" "The template's type local/crag_gem " \
		"The template's type local/crag_run "; do
	grep -aqE "$re" "$SL" || fail "no \"$re\" in $SL"
done
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
await "$CL" 0 10 "kit: controls: camera side, pointer [a-z]+, movement local/crag_bike, plane z 1"
await "$CL" 0 10 "crag_bike: the draw hook draws a bike"
# ([KIT_PLAY_HINTS] the movement's hints, none of the walker's)
await "$CL" 0 10 'workbench: the hint "\[W\]/\[S\]: gas, brake  \[A\]/\[D\]: lean  \[Space\]: turn round"'
await "$CL" 0 10 "kit: player [0-9]+'s body drawn by its movement"
# [KIT_LOBBY] In the lobby (a full screen: its chat, its view, Play), the
# run's clock still; Play starts it
await "$CL" 0 10 "kit: ui full screen 45 up"
grep -aq "kit/lobby 44: kitboss: none -> lobby" "$SL" || fail "kitboss not in the lobby ($SL)"
cmd "frames 10" "screenshot $t/lobby.png"
m=$(mark "$SL")
step 10 "kit: ui full screen none" "frames 3" 'click Button "Play"'
await "$SL" "$m" 5 "kit/lobby 44: kitboss: lobby -> playing"
await "$SL" "$m" 5 "local/crag_run 7: kitboss: off you go, the run starts over"
echo "ok: the lobby's full screen, Play: the run started"
# (kitbob on his way meanwhile)
BUILDAT_JOIN_CREATE=1 client bob
BOB=$!
exec 4> "$t/bob.cmd"
cmd "frames 30" "screenshot $t/start.png"
body
awk -v x="$bx" 'BEGIN { exit !(x > -61 && x < -59) }' || fail "the bike not at the start: $bx $by ($CL)"
# [KIT_CRAG_PLAYTEST_1] The heightmap's flat ground at its level, y 0 (the 1
# grid), the bike's feet on it
awk -v y="$by" 'BEGIN { exit !(y > -0.1 && y < 0.1) }' || fail "the bike not on the ground at y 0: $bx $by ($CL)"
echo "ok: a project from it, played: the side view, the bike's movement drawn by its hook, on the ground at y $by"
# 2. Up the ramp, leaning back: the crash, back at the start. A held key may
# read as not held: once again if the bike never left the start
for try in 1 2; do
	m=$(mark "$CL")
	cmd "keydown W" "delay 800" "keydown A"
	for i in $(seq 20); do
		body
		cmd "delay 150"
		seen "$CL" "$m" '"Time [0-9.]+ .*Crashed"' && break
	done
	cmd "keyup A" "keyup W"
	seen "$CL" "$m" '"Time [0-9.]+ .*Crashed"' && break
	tail -c +$((m + 1)) "$CL" | grep -aoP 'kit: body at \K-?[0-9.]+' |
		awk '$1 > -58 { f = 1 } END { exit !f }' && fail "the bike moved and never crashed ($CL)"
	[ $try = 2 ] && fail "the bike never left the start: the keys not held twice ($CL)"
	echo "the bike stood still: W and A again"
done
tail -c +$((m + 1)) "$CL" | grep -aoP 'kit: body at \K-?[0-9.]+,-?[0-9.]+' | tr , ' ' |
	awk '$1 > -50 && $1 < -38 && $2 > 1 { f = 1 } END { exit !f }' ||
	fail "the bike never on the first ramp ($CL)"
for i in $(seq 20); do
	body
	awk -v x="$bx" 'BEGIN { exit !(x < -58) }' && break
	cmd "delay 200"
done
awk -v x="$bx" 'BEGIN { exit !(x < -58) }' || fail "the bike not back at the start after the crash: $bx ($CL)"
seen "$CL" 0 'workbench: the hint "\[Space\]: turn round"' || fail "the used hints not gone ($CL)"
echo "ok: throttle up the ramp's polygon, the crash an output (the run's line), back at the start; W and A's hints gone"
# 3. A heavy step: refused, the old version kept
python3 -I - "$here/apps/workbench/templates/crag_trial/types/crag_bike.lua" > "$t/heavy.cmd" <<'PY'
import json, sys
s = open(sys.argv[1]).read()
head = "step = function(s, i, dt, w, p)\n"
assert head in s and "version = 1," in s
s = s.replace("version = 1,", "version = 2,", 1).replace(head, head + "\t\tfor _ = 1, 1000000 do end\n", 1)
print("event kit_type " + json.dumps({"op": "put", "name": "crag_bike", "source": s}))
PY
[ -s "$t/heavy.cmd" ] || fail "the heavy version ($t/heavy.cmd)"
# (a put is the edit mode's, Stopped)
step 10 "kit editor: edit mode on" "frames 3" "keypress F6"
step 15 "kit editor: type: put [^:]*: Refused: too slow: a step past" "$(cat "$t/heavy.cmd")"
grep -aq "An edit by kitboss: the type local/crag_bike" "$SL" && fail "the heavy version taken ($SL)"
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
echo "ok: a version with a heavy step refused: too slow"
# 4. The old one steps on the server: the first gem's zone (once again, as above)
for try in 1 2; do
	m=$(mark "$CL")
	cmd "keydown W"
	for i in $(seq 20); do
		body
		seen "$CL" "$m" '"Time [0-9.]+ +Gems 1/3' && break
		cmd "delay 100"
	done
	cmd "screenshot $t/side.png" "keyup W"
	seen "$CL" "$m" '"Time [0-9.]+ +Gems 1/3' && break
	tail -c +$((m + 1)) "$CL" | grep -aoP 'kit: body at \K-?[0-9.]+' |
		awk '$1 > -58 { f = 1 } END { exit !f }' && fail "the bike moved and took no gem ($CL)"
	[ $try = 2 ] && fail "the bike never left the start: W not held twice ($CL)"
	echo "the bike stood still: W again"
	cmd "delay 500"
done
step 5 "kit: body at" "frames 10" "event kit_body"
c=$(tail -c 3000 "$CL" | grep -aoP 'kit: body at .*, \K[0-9]+ acks, [0-9]+ corrections' | tail -1)
n=$(grep -ac "kit: the body corrected by" "$CL")
[ "$n" -le 10 ] || fail "$n corrections ($c; $CL)"
echo "ok: the old version stepping, the first gem taken (a trigger zone); $c"
# ([KIT_LOBBY] the gem kitboss's own: gone on his screen)
await "$CL" 0 5 "kit: entity 11's look: taken on"
# [KIT_SIDE_LEAD] The side camera led ahead of the bike riding right (+x);
# turned round (Space), eased to its other side
lead() # the side camera's lead along x now, into lx
{
	step 5 "kit: side camera at" "event kit_body"
	lx=$(tail -c 3000 "$CL" | grep -aoP 'kit: side camera at .*, lead \K-?[0-9.]+' | tail -1)
}
lead
awk -v l="$lx" 'BEGIN { exit !(l > 1) }' || fail "the camera not ahead riding right: lead $lx ($CL)"
l0=$lx
hm=$(mark "$CL")
for try in 1 2; do
	cmd "keydown Space" "delay 200" "keyup Space"
	for i in $(seq 10); do
		lead
		awk -v l="$lx" 'BEGIN { exit !(l < -1) }' && break 2
		cmd "delay 200"
	done
done
awk -v l="$lx" 'BEGIN { exit !(l < -1) }' || fail "the camera not led to -x after Space: lead $lx ($CL)"
cmd "frames 10" "screenshot $t/turned.png"
echo "ok: the side camera led $l0 riding right, $lx turned round"
# ([KIT_PLAY_HINTS] Space the last one used: the line gone, kept on this client)
seen "$CL" "$hm" 'workbench: the hint ""' || await "$CL" "$hm" 5 'workbench: the hint ""'
grep -raq --include=kit_hints "local/crag_bike jump" "$t/cu_boss" || fail "the used hints not kept ($t/cu_boss)"
echo "ok: Space used, the hint line gone and kept"
# 5. kitbob: drawn by the hook on kitboss's screen; his first My account page
as bob
await "$CL" 0 120 "Joined as kitbob"
await "$CL" 0 60 "player physics enabled"
await "$CL" 0 10 "kit: player [0-9]+'s body drawn by its movement"
as boss
two=
for i in $(seq 25); do
	[ "$(grep -aoP "kit: player \K[0-9]+(?='s body drawn by its movement)" "$CL" | sort -u | wc -l)" -ge 2 ] &&
		two=1 && break
	sleep 0.2
done
[ -n "$two" ] || fail "kitbob's body not drawn by the hook on kitboss's screen ($CL)"
as bob
# [KIT_LOBBY] kitbob in the lobby; kitboss's gem still there on his screen
await "$CL" 0 10 "kit: ui full screen 45 up"
await "$CL" 0 10 "kit: entity 11's look: taken off"
seen "$CL" 0 "kit: entity 11's look: taken on" && fail "kitboss's gem gone for kitbob ($CL)"
grep -aq "kit/lobby 44: kitbob: none -> lobby" "$SL" || fail "kitbob not in the lobby ($SL)"
for i in 1 2 3; do
	m=$(mark "$CL")
	cmd "frames 3" "keypress Escape"
	for k in $(seq 15); do
		seen "$CL" "$m" "pause: the menu shown" && break 2
		sleep 0.2
	done
done
seen "$CL" "$m" "pause: the menu shown" || fail "no pause menu ($CL)"
step 10 "accounts: the hello came: the page drawn again" "frames 3" 'click Button "My account*"'
step 10 "accounts: agents: " "frames 3" 'click Button "Connect an agent..."'
echo "ok: kitbob's body drawn by the hook; his first My account page with Connect an agent..."
# 6. [CRAG_BEST_RESET] A fourth gem, linked only to the run (no reset link):
# counted (Gems 0/4), the finish refused at 3 of 4, taken at 4; the run's
# reset brings it back
as boss
try_() { cmd "event kit_edit {\"op\": \"try\", \"id\": 7, \"comp\": 0, \"input\": \"$1\"}"; }
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
m=$(mark "$SL")
try_ hazard
await "$SL" "$m" 5 "local/crag_run 7: kitboss: hit a hazard"
for i in $(seq 20); do
	body
	awk -v x="$bx" 'BEGIN { exit !(x < -58) }' && break
	cmd "delay 200"
done
awk -v x="$bx" 'BEGIN { exit !(x < -58) }' || fail "the hazard did not take the bike to the start: $bx ($CL)"
cmd 'event kit_edit {"op": "place", "type": "local/crag_gem", "pos": [-45, 8, 1]}'
await "$SL" "$m" 5 "An edit by kitboss: placed local/crag_gem 54 "
step 5 "Gems 0/4" 'event kit_edit {"op": "link", "id": 54, "comp": 0, "output": "collected", "to": 7, "input": "gem"}'
# (onto the bike at the start: its zone entered)
cmd 'event kit_edit {"op": "move", "id": 54, "pos": [-61, 0, 1]}'
await "$SL" "$m" 5 "local/crag_run 7: kitboss has 1 of 4 gems"
seen "$SL" "$m" "local/crag_gem 54: kitboss took the gem" || fail "not gem 54's take ($SL)"
try_ gem
try_ gem
await "$SL" "$m" 5 "kitboss has 3 of 4 gems"
try_ finish
await "$SL" "$m" 5 "Take every gem first"
try_ gem
await "$SL" "$m" 5 "kitboss has 4 of 4 gems"
try_ finish
await "$SL" "$m" 5 "local/crag_run 7: kitboss finished in [0-9.]+ \(best\)"
best=$(tail -c +$((m + 1)) "$SL" | grep -aoP 'kitboss finished in \K[0-9.]+(?= \(best\))' | tail -1)
await "$SL" "$m" 5 "local/crag_gem 54: back"
echo "ok: a fourth gem linked only to the run: Gems 0/4, its take counted, the finish refused at 3 of 4 and taken at 4 ($best), the gem back by the run's reset"
# [KIT_LOBBY] The finish kitboss's result card (an over screen): the time,
# the best; the clock held till Again or the lobby's Play
await "$SL" "$m" 5 "kit/lobby 44: kitboss: playing -> over"
await "$CL" 0 5 "kit: ui 51 text .*: \"Time $best"
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
await "$CL" 0 5 "kit: ui 50 panel .* shown, layer 50: \"Finished\""
cmd "frames 10" "screenshot $t/result.png"
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
echo "ok: the result card: Time $best"
# The top-5 sign lists it; kitbob (no builder) may not clear it; End, then
# Play: still there
sign() { echo "kit/sign 43: shows \"Best times.$1\" by"; } # (the log's newline a ?)
await "$SL" "$m" 5 "$(sign "1\. kitboss $best")"
as bob
m=$(mark "$SL")
cmd 'event kit_edit {"op": "clear_kept", "id": 7, "comp": 0}'
await "$SL" "$m" 5 "An edit \(clear_kept\) by peer [0-9]+ refused: no edit rights here"
as boss
seen "$SL" "$m" "kept state cleared" && fail "kitbob cleared the bests ($SL)"
step 5 "the server is Ended" 'event kit_edit {"op": "stop"}'
m=$(mark "$SL")
step 5 "the server is Running" 'event kit_edit {"op": "play"}'
await "$SL" "$m" 5 "$(sign "1\. kitboss $best")"
echo "ok: the top-5 sign lists kitboss $best; kitbob's clear refused; End, then Play: still listed"
# (Ended over the restart: the kept state from the save, not the round's)
step 5 "the server is Ended" 'event kit_edit {"op": "stop"}'
for f in 3 4; do
	FD=$f cmd "sync 2000" quit
done
exec 3>&- 4>&-
wait $BOSS $BOB 2>/dev/null
# 7. The server restarted (the project that ran last opens), kitboss back:
# Play, still listed and his HUD's best; his "Clear kept state" (the
# inspector's, asked first) empties the sign, Undo brings it back
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
SL=$t/srv2.log
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up again ($SL)"
CHECK_PIDS+=($SERVER_PID)
client boss boss2
BOSS=$!
exec 3> "$t/boss2.cmd"
as boss
CL=$t/boss2.log
await "$CL" 0 120 "Joined as kitboss"
await "$CL" 0 60 "player physics enabled"
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
m=$(mark "$SL")
step 5 "the server is Running" 'event kit_edit {"op": "play"}'
await "$SL" "$m" 5 "$(sign "1\. kitboss $best")"
await "$CL" 0 5 "Best $best "
cmd "frames 5" 'click Button "Entities"' "frames 3" 'click Button "Scene (*"' "frames 3"
step 5 "kit editor: selected 7 " 'click Button "select 7"'
step 5 "kit editor: clear local/crag_run's kept state\?" "frames 5" 'click Button "clear kept local/crag_run"'
m=$(mark "$SL")
cmd "frames 5" 'click Button "clear kept yes"'
await "$SL" "$m" 5 "Entity 7's local/crag_run: its kept state cleared by kitboss"
await "$SL" "$m" 5 "$(sign "")"
m=$(mark "$SL")
cmd 'event kit_edit {"op": "undo"}'
await "$SL" "$m" 5 "its kept state put back by kitboss's undo"
await "$SL" "$m" 5 "$(sign "1\. kitboss $best")"
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
# ([KIT_LOBBY] the lobby lists them too; Play, back at the sign)
await "$CL" 0 10 "kit: ui full screen 45 up"
await "$CL" 0 5 "kit: ui 49 text .* shown, layer 45: \"Best times \| 1\. kitboss $best\""
step 10 "kit: ui full screen none" "frames 3" 'click Button "Play"'
cmd "frames 30" "screenshot $t/sign.png"
echo "ok: over a server restart (Ended) still listed, the HUD's best $best; kitboss's Clear kept state emptied the sign, Undo brought it back"
cmd "sync 2000" quit
exec 3>&-
wait $BOSS 2>/dev/null
for p in edit lobby start side turned result sign; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
# (the run's teleports, a hazard's or the finish's, from its scene)
grep -a "a teleport refused" "$t/srv.log" "$SL" && fail "a teleport refused ($t/srv.log, $SL)"
echo "PASS: Crag Trial packed, installed and played: the bike's own movement up a polygon ramp, its crash an output and back at the start, a heavy step refused while the old one stepped to a gem's zone, $n corrections, drawn by its hook for both players; kitbob's first My account page drawn again; the best time kept over End, Play and a restart, on the top-5 sign, cleared by a builder only; screenshots $t/start.png $t/side.png $t/sign.png"
# vim: set noet ts=4 sw=4:
