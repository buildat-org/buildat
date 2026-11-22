#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~30 s (2026-11-15)
# covers: apps/workbench/templates/crag_trial/** builtin/kit/types/collectible.lua builtin/kit/types/collectible.client.lua builtin/kit/box/box.c builtin/kit/types/lobby.lua builtin/kit/types/ui_scene_list.lua builtin/kit/types/scene_info.lua builtin/kit/client_lua/ui.lua builtin/kit/client_lua/move.lua builtin/kit/client_lua/controls.lua builtin/kit/client_lua/module.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/players.lua builtin/kit/kit.cpp builtin/accounts/client_lua/accounts.lua
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
#      [KIT_LOBBY] first the lobby (a full screen, lobby.png), [KIT_SCENE_PACKAGES]
#      its track list (the lobby on the root, a kit/ui_scene_list: The Crags
#      and The Loop), The Crags starting its run (by name: "the run" in the
#      player's scene); [KIT_STILL_LOOKS] (0a7h) idle there, its gems' looks
#      (a state, a client part without on_update) still: 15% of the looks
#      read a frame at most;
#   2. W, then A: the bike up the first ramp's polygon, leaning back, the
#      head down: the crash (crag_bike's output, linked to the run: its line
#      says Crashed), the bike back at the start a second later;
#   3. back in edit mode (Stopped), a version with a heavy step put over
#      kit:type: refused, "too slow";
#   4. played again, W: the old version steps on the server, the first gem's trigger zone
#      taken (the run's line: Gems 1/3, side.png; [KIT_CLIENT_REACT] (1) its
#      zone met on the client no later than on the server, the gem's client
#      part's take predicted, drawn taken before the server's take reaches
#      the HUD; the pass's cost logged); the corrections few; the
#      side camera led ahead in +x, after Space (turned round) in -x
#      (turned.png, [KIT_SIDE_LEAD]);
#   5. kitbob joins: [KIT_LOBBY] he in the lobby, the gem kitboss took still
#      drawn for him (each rider's own), [KIT_LOBBY_OUT_OF_PLAY] out of play
#      (W held there leaves his bike where it is); his pick of The Crags, his body drawn by the hook on kitboss's screen;
#      his first My account page drawn again when the hello comes, "Connect
#      an agent..." on it (accounts.lua);
#   6. [KIT_STILL_LOOKS] gem 11 taken (moved onto the bike and away), a
#      hazard's reset brings it back on kitboss's screen (kit:mine, his own);
#      [CRAG_BEST_RESET] a fourth gem placed, linked only to the run: the run
#      counts it (Gems 0/4), the finish refused at 3 of 4 and taken at 4, the
#      run's reset brings it back; [KIT_BODY_VARS] the finish (its zone and its
#      line, a kit/polygon of surface "finish") moved ahead of the start: ridden
#      over at 0 of 3 (not held), at 4 of 4 (the run's c:body_var finish_open,
#      the finish's link away) the bike held on the line by its own step, no
#      correction on the client; the run over closes it; [KIT_LOBBY] the finish the result card
#      (an over screen: the time, result.png; [KIT_CLIENT_REACT] (9) the
#      lobby's keep_own_body set on for it: kitboss's own bike kept drawn
#      for him, hidden from kitbob); the best on the top-5 sign (a kit/sign
#      fed by the run's board); [KIT_SCENE_PACKAGES] the card's Lobby, then
#      The Loop: kitboss taken to that scene onto its start, its run (59)
#      started; W and A: his crash there (the root's bike's crash by name to
#      the loop's run), its gems and finish (tried) its result card (loop.png)
#      and its own sign; kitbob's clear_kept refused (no builder), End then
#      Play: still listed;
#   7. the server restarted Ended, kitboss back, Play: still listed, his HUD's
#      best; the inspector's Clear kept state (asked first) empties the
#      sign, Undo brings it back; the lobby, The Crags (sign.png);
#      (4z37h) the pause menu (Escape): no Retry or To lobby in the lobby,
#      both in the run; Retry starts the run over, To lobby the lobby;
#      [KIT_STILL_LOOKS] a gem type whose on_enter takes nothing (with
#      kit/collectible's client part): one moved onto the bike drawn taken
#      by its prediction, back after its second.
# And [KIT_PLAY_HINTS]: Workbench's help line in play the bike's own hints
# (movement.help), W's and A's gone once used, Space's last after the gem:
# the line gone, kept in Kit's storage (kit_hints).
# Screenshots, kept with KEEP_TMP=1: $t/edit.png, $t/lobby.png, $t/start.png,
# $t/side.png, $t/turned.png, $t/result.png, $t/loop.png, $t/sign.png
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
for f in crag_bike.lua crag_bike.client.lua crag_run.lua; do
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
# (4z37h) Escape's pause menu: its items line matching <regex> and not
# <regex 2> (if given), then Continue
pause_open() # <regex>: Escape's menu open, its items line matching
{
	# (an item reaches the client with its scene's entities, which may
	# still be drawn as a run starts: closed and opened again until then)
	local i m items=
	for i in $(seq 10); do
		m=$(mark "$CL")
		step 10 "pause: the items" "keypress Escape"
		items=$(tail -c +$((m + 1)) "$CL" | grep -a "pause: the items" | tail -1)
		echo "$items" | grep -qE "$1" && return 0
		step 10 "pause: the menu closed" "frames 3" 'click Button "Continue"'
		sleep 1
	done
	fail "the pause menu not \"$1\": $items ($CL)"
}
pause_items() # <regex> [regex 2]
{
	local m items
	m=$(mark "$CL")
	pause_open "$1"
	items=$(tail -c +$((m + 1)) "$CL" | grep -a "pause: the items" | tail -1)
	[ -z "${2:-}" ] || ! echo "$items" | grep -qE "$2" ||
		fail "the pause menu with \"$2\": $items ($CL)"
	step 10 "pause: the menu closed" "frames 3" 'click Button "Continue"'
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
step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New game..."'
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
# [KIT_LAYOUT_AUTO] The HUD view as a phone (412x915), the lobby's screen:
# its chat and view (54, auto) a column, the view the frame's width, the
# chat under it (hud_lobby.png)
step 10 "kit editor: the view is HUD" "keypress F4"
step 10 "hud shape open" "frames 5" 'click DropDownList "hud shape"'
step 10 "kit editor: the HUD view's shape is 412x915" "frames 3" 'click Text "hud shape: Phone 412x915"'
step 10 "hud screen open" "frames 5" 'click DropDownList "hud screen"'
step 10 "kit editor: the HUD view shows screen 45" "frames 3" 'click Text "hud screen: ◆ 45 *"'
cmd "frames 10" "screenshot $t/hud_lobby.png"
python3 -I - "$CL" <<'PY' || fail "the lobby's column in the HUD view's phone frame ($CL)"
import re, sys
at = {}
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"kit: ui (46|48) \w+ at (-?\d+),(-?\d+) (\d+)x(\d+) in (\d+)x(\d+) ", l)
    if m and int(m[6]) < int(m[7]):
        at[m[1]] = tuple(map(int, m.groups()[1:]))
c, v = at.get("46"), at.get("48")
assert c and v and c[2] == v[2] and v[2] >= 0.9 * v[4] and c[1] >= v[1] + v[3], (c, v)
print("ok: the HUD view's phone frame: the view", v, "the chat under it", c)
PY
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
for re in "The template's type local/crag_bike \([0-9]+ bytes\)" \
		"The template's type local/crag_run "; do
	grep -aqE "$re" "$SL" || fail "no \"$re\" in $SL"
done
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
await "$CL" 0 10 "kit: controls: camera side, pointer [a-z]+, movement local/crag_bike, plane z 1"
await "$CL" 0 10 "crag_bike: the draw hook draws a bike"
# ([KIT_PLAY_HINTS] the movement's hints, none of the walker's)
await "$CL" 0 10 'workbench: the hint "W/S: gas, brake  A/D: lean  Space: turn round"'
await "$CL" 0 10 "kit: player [0-9]+'s body drawn by its movement"
# [KIT_LOBBY] In the lobby (a full screen: its chat, its view, the tracks),
# the run's clock still; [KIT_SCENE_PACKAGES] the root's track list, The
# Crags (the scene he is in) starts its run
await "$CL" 0 10 "kit: ui full screen 45 up"
await "$CL" 0 10 'kit: ui 47 list .* shown, layer 45: "Pick a track \| The Crags, by buildat \| The Loop, by celeron55"'
grep -aq "kit/lobby 44: kitboss: none -> lobby" "$SL" || fail "kitboss not in the lobby ($SL)"
cmd "frames 10" "screenshot $t/lobby.png"
m=$(mark "$SL")
step 10 "kit: ui full screen none" "frames 3" 'click Button "The Crags*"'
await "$SL" "$m" 5 "kit/ui_scene_list 47: picked world by kitboss"
await "$SL" "$m" 5 "kit/lobby 44: kitboss: lobby -> playing"
await "$SL" "$m" 5 "local/crag_run 7: kitboss: off you go, the run starts over"
echo "ok: the lobby's full screen, its track list, The Crags: its run started"
# [KIT_STILL_LOOKS] (0a7h) Idle in the run the gems' looks (a state and a
# client part without on_update) are still: not read each frame (all but
# the bike's and the HUD's once; 6 of 29, now 3)
cmd "frames 30"
step 10 "kit: looks:" "event kit_looks"
step 30 "kit: looks:" "frames 30" "event kit_looks"
python3 -I - "$(grep -aoP 'kit: looks: .*' "$CL" | tail -1)" <<'PY' || fail "the run's idle looks ($CL)"
import re, sys
f, read, looks = re.search(r"(\d+) frames, ([0-9.]+) read a frame of ([0-9.]+)", sys.argv[1]).groups()
assert int(f) >= 20 and float(looks) >= 20 and float(read) <= 0.15 * float(looks), sys.argv[1]
print("ok: the run's idle frames read %s of %s looks a frame" % (read, looks))
PY
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
# (on the ramp's slope, from x -50, over the flat ground's -0.09: the softer
# springs crash it low on the slope)
tail -c +$((m + 1)) "$CL" | grep -aoP 'kit: body at \K-?[0-9.]+,-?[0-9.]+' | tr , ' ' |
	awk '$1 > -50 && $1 < -38 && $2 > 0.3 { f = 1 } END { exit !f }' ||
	fail "the bike never on the first ramp ($CL)"
for i in $(seq 20); do
	body
	awk -v x="$bx" 'BEGIN { exit !(x < -58) }' && break
	cmd "delay 200"
done
awk -v x="$bx" 'BEGIN { exit !(x < -58) }' || fail "the bike not back at the start after the crash: $bx ($CL)"
seen "$CL" 0 'workbench: the hint "Space: turn round"' || fail "the used hints not gone ($CL)"
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
# [KIT_CLIENT_REACT] (1) its zone met on his client first (its own test of
# the predicted wheels: the gem's client part takes it at once), the
# server's after
await "$SL" 0 5 "Entity 11: kitboss enters its zone"
grep -aq "kit: entity 11 predicted taken = true" "$CL" || fail "the gem's client part did not take it ($CL)"
# ([KIT_STILL_LOOKS] the gem, still till then, drawn taken by the
# prediction: before the server's take reaches the HUD)
lp=$(grep -an "kit: entity 11 predicted taken = true" "$CL" | head -1 | cut -d: -f1)
lo=$(grep -an "kit: entity 11's look: taken on" "$CL" | head -1 | cut -d: -f1)
lg=$(grep -anE '"Time [0-9.]+ +Gems 1/3' "$CL" | head -1 | cut -d: -f1)
[ "$lp" -lt "$lo" ] && [ "$lo" -lt "$lg" ] ||
	fail "the gem not drawn taken by its prediction: lines $lp, $lo, the HUD's $lg ($CL)"
ct=$(grep -am1 "kit: entity 11's zone entered (this client)" "$CL" | awk '{ print $3 }')
st=$(grep -am1 "Entity 11: kitboss enters its zone" "$SL" | awk '{ print $3 }')
[ -n "$ct" ] && [[ ! "$ct" > "$st" ]] || fail "the gem's zone on the client at '$ct', the server's at $st ($CL, $SL)"
echo "ok: the gem's zone met on the client at $ct, on the server at $st"
step 5 "kit: zones: " "event kit_zones"
echo "   $(tail -c 2000 "$CL" | grep -ao 'kit: zones: .*' | tail -1)"
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
# 5. kitbob: in the lobby, then drawn by the hook on kitboss's screen once
# he plays; his first My account page
as bob
await "$CL" 0 120 "Joined as kitbob"
await "$CL" 0 60 "player physics enabled"
await "$CL" 0 10 "kit: player [0-9]+'s body drawn by its movement"
# [KIT_LOBBY] kitbob in the lobby; kitboss's gem still there on his screen;
# [KIT_LOBBY_OUT_OF_PLAY] out of play there, Play takes him in
await "$CL" 0 10 "kit: ui full screen 45 up"
await "$CL" 0 10 "kit: entity 11's look: taken off"
seen "$CL" 0 "kit: entity 11's look: taken on" && fail "kitboss's gem gone for kitbob ($CL)"
grep -aq "kit/lobby 44: kitbob: none -> lobby" "$SL" || fail "kitbob not in the lobby ($SL)"
await "$SL" 0 10 "kitbob is out of play \(a lobby\)"
# (4z16: the rider's keys drove the bike under the lobby screen) W held
# there: the bike stays. simplified: a held key may read as not held, which
# passes too
body
x0=$bx
cmd "keydown W" "delay 800" "keyup W" "frames 10"
body
awk -v a="$x0" -v b="$bx" 'BEGIN { exit !((a - b) ^ 2 < 0.0025) }' ||
	fail "W under the lobby moved kitbob's bike: x $x0 -> $bx ($CL)"
echo "ok: W held under the lobby: kitbob's bike stayed at x $bx"
m=$(mark "$SL")
step 10 "kit: ui full screen none" "frames 3" 'click Button "The Crags*"'
await "$SL" "$m" 5 "kitbob is in play"
as boss
two=
for i in $(seq 25); do
	[ "$(grep -aoP "kit: player \K[0-9]+(?='s body drawn by its movement)" "$CL" | sort -u | wc -l)" -ge 2 ] &&
		two=1 && break
	sleep 0.2
done
[ -n "$two" ] || fail "kitbob's body not drawn by the hook on kitboss's screen ($CL)"
# [KIT_MOVE_DRAW] A check-only version of the bike (put over kit:type, its
# client part logging what its draw gets): its input probe sets a public
# body var (flag) and a private one (secret) on every rider and c:speed 0,
# its step writes the named pose's tr slot as i.speed. Each client's draw
# gets the other rider's flag, not their secret; i.speed 0 in the own
# prediction and the server's steps (the other's pose, by name and as [8]);
# p the movement's params; the public vars set on a node once, not per
# tick; c.players' heading the bike's facing. Then a second version: its
# draw on a node made anew (the first's child gone), [KIT_SMALL_PIECES] its
# step's math.pow, math.exp and w:resolve_circle the same bits in the
# server's steps and the client's prediction; then the template's own
probe() # <version> <letter>: the probe's put as a kit_type event
{
	python3 -I - "$here/apps/workbench/templates/crag_trial/types/crag_bike.lua" \
			"$here/apps/workbench/templates/crag_trial/types/crag_bike.client.lua" "$1" "$2" <<'PY'
import json, sys
s, cl, v, x = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3], sys.argv[4]
s = s.replace("version = 1,", "version = %s," % v, 1)
if x != "-":
    assert "root = true,\n" in s and "tl = wl[6], tr = wr[6]}" in s
    s = s.replace("root = true,\n", """root = true,
	reads_players = true,
	inputs = {probe = "number"},
	on_input = function(c, input, v, by)
		for _, pl in ipairs(c.players) do
			c:log("probe: " .. pl.name .. " heading " .. tostring(pl.heading))
			c:body_var(pl.by, "flag", v ~= 0 and v or nil, {public = true})
			c:body_var(pl.by, "secret", v ~= 0 and v or nil)
			c:speed(pl.by, v ~= 0 and 0 or 1)
		end
	end,
""", 1).replace("tl = wl[6], tr = wr[6]}", "tl = wl[6], tr = i.speed}", 1)
    if x == "b":
        # [KIT_SMALL_PIECES] math.pow, math.exp and w:resolve_circle in the
        # step: their bits (exponent:high 26:low 26) in the state's km
        head = "step = function(s, i, dt, w, p)\n"
        assert head in s
        # (each step: the own prediction's its client's, not the server's kept)
        s = s.replace(head, head + """		do
			local function bits(v)
				if v == 0 then return "0" end
				local sg, e = v < 0 and ":-" or "", 0
				v = math.abs(v)
				while v >= 1 do v, e = v / 2, e + 1 end
				while v < 0.5 do v, e = v * 2, e - 1 end
				local hi = math.floor(v * 67108864)
				return e .. ":" .. hi .. ":" .. (v * 67108864 - hi) * 67108864 .. sg
			end
			local x, y, vx, vy, hits = w:resolve_circle(-60.3, 0.2, 0.36, 3, -2, 0.1, 0.5)
			local km = ""
			for _, v in ipairs({math.pow(1.7, 0.3), math.pow(23.5, 0.4),
					math.pow(0.81, -2.5), math.pow(-2, 3), math.exp(-3.21),
					math.exp(4.4), x, y, vx, vy, #hits}) do
				km = km .. " " .. bits(v)
			end
			-- (the server's print: its log; a client's step has none)
			if km ~= s.km and print then
				print("km" .. km)
			end
			s.km = km
		end
""", 1)
    a = cl.rindex("\nreturn {")
    cl = cl[:a] + "\nlocal T = {" + cl[a + 9:] + """
local inner, said = T.draw, {}
T.draw = function(s, node, yaw, p)
	inner(s, node, yaw, p)
	if not node:GetChild("probe_%s", false) then
		node:CreateChild("probe_%s")
	end
	local q, v = s.pose, type(s.vars) == "table" and s.vars or {}
	local who = s.c and "own" or "other"
	local line = string.format("crag_bike probe %s: %%s tr %%s [8] %%s flag %%s secret %%s wheel %%s children%%s%%s",
		who, tostring(q.tr), tostring(q[8]), tostring(v.flag), tostring(v.secret),
		tostring(p.wheel), node:GetChild("probe_a", false) and " probe_a" or "",
		node:GetChild("probe_b", false) and " probe_b" or "")
	if s.km then
		line = line .. " km" .. s.km
	end
	if said[who] ~= line then
		said[who] = line
		log:info(line)
	end
end
return T
""" % (x, x, x)
print("event kit_type " + json.dumps({"op": "put", "name": "crag_bike", "source": s, "client": cl}))
PY
}
put_bike() # <version> <letter|->
{
	local m
	m=$(mark "$SL")
	cmd "$(probe "$1" "$2")"
	await "$SL" "$m" 10 "A type put \((local/)?crag_bike\) by peer [0-9]+ done"
}
pv() { grep -ac "Entity $1's public body vars: " "$SL"; } # <entity id>
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
mb=$(mark "$t/bob.log")
put_bike 2 a
m=$(mark "$SL")
mc=$(mark "$CL")
cmd 'event kit_edit {"op": "try", "id": 6, "comp": 0, "input": "probe", "value": 1}'
for who in kitboss kitbob; do
	await "$SL" "$m" 5 "$who's body var flag = 1 \(public\)"
	await "$SL" "$m" 5 "$who's body var secret = 1$"
done
grep -aoP "local/crag_bike 6: probe: \K.*" "$SL" | tail -2 > "$t/headings"
grep -aqE "^kitboss heading 270$" "$t/headings" && grep -aqE "^kitbob heading 90$" "$t/headings" ||
	fail "c.players' heading not the bikes' facing (kitboss turned round): $(cat "$t/headings") ($SL)"
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
await "$CL" "$mc" 5 "crag_bike probe a: own tr 0 \[8\] 0 flag 1 secret 1 wheel 0.36"
await "$CL" "$mc" 5 "crag_bike probe a: other tr 0 \[8\] 0 flag 1 secret nil wheel 0.36"
await "$t/bob.log" "$mb" 5 "crag_bike probe a: other tr 0 \[8\] 0 flag 1 secret nil wheel 0.36"
# (the public vars on each node once; none again over a second of ticks)
ids=$(grep -aoP "Entity \K[0-9]+(?='s public body vars: \{\"flag\":1\})" "$SL" | sort -u)
[ "$(echo $ids | wc -w)" = 2 ] || fail "the public vars not on both riders' nodes: $ids ($SL)"
n0=$(for i in $ids; do pv $i; done)
cmd "frames 60"
sleep 1
n1=$(for i in $ids; do pv $i; done)
[ "$n0" = "$n1" ] || fail "the public vars set again with nothing changed: $n0 -> $n1 ($SL)"
echo "ok: a public body var in the other rider's draw (not the private one), i.speed 0 frozen on both sides, the named pose and p in draw, c.players' heading; the vars set once"
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
m=$(mark "$SL")
mc=$(mark "$CL")
cmd 'event kit_edit {"op": "try", "id": 6, "comp": 0, "input": "probe", "value": 0}'
await "$SL" "$m" 5 "kitbob's body var flag = nil"
put_bike 3 b
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
await "$CL" "$mc" 10 "kit: player [0-9]+'s movement node made anew \(its draw changed\)"
await "$CL" "$mc" 10 "crag_bike probe b: other tr 1 \[8\] 1 flag nil secret nil wheel 0.36 children probe_b$"
await "$CL" "$mc" 10 "crag_bike probe b: own tr 1 \[8\] 1 flag nil secret nil wheel 0.36 children probe_b km( [-0-9:]+){11}$"
# [KIT_SMALL_PIECES] the step's math.pow, math.exp and w:resolve_circle: the
# server's bits (its step's print) those of kitboss's client (his own
# prediction's state), and near what Python's libm says
await "$SL" "$m" 10 "local/crag_bike: km( [-0-9:]+){11}$"
python3 -I - "$CL" "$SL" <<'PY' || fail "the step's math.pow, math.exp or w:resolve_circle not the same bits on the server and the client ($CL, $SL)"
import math, re, sys
km = {}
for l in open(sys.argv[1], errors="replace"):
    m = re.search(r"crag_bike probe b: own .* km((?: [-0-9:]+){11})$", l.rstrip("\n"))
    if m:
        km.setdefault("own", m[1].split())
for l in open(sys.argv[2], errors="replace"):
    m = re.search(r"local/crag_bike: km((?: [-0-9:]+){11})$", l.rstrip("\n"))
    if m:
        km.setdefault("server", set()).add(m[1].strip())
# (the server's put tries a step in no world: its resolve_circle no hit)
assert km.get("own") and " ".join(km["own"]) in km.get("server", ()), km
assert {tuple(k.split()[:6]) for k in km["server"]} == {tuple(km["own"][:6])}, km
def val(b):
    if b == "0":
        return 0.0
    f = b.split(":")
    e, hi, lo = map(int, f[:3])
    return (-1 if f[3:] else 1) * (hi + lo / 2 ** 26) / 2 ** 26 * 2.0 ** e
v = [val(b) for b in km["own"]]
want = [1.7 ** 0.3, 23.5 ** 0.4, 0.81 ** -2.5, -8, math.exp(-3.21), math.exp(4.4)]
assert all(abs(a - b) <= 1e-13 * abs(b) for a, b in zip(v, want)), (v, want)
x, y, vx, vy, n = v[6:]
assert n >= 1 and y > 0.2 and vy > -2 and vx <= 3, v[6:]
print("ok: the step's math.pow, math.exp and w:resolve_circle the same bits on the server and the client:", " ".join(km["own"][:2]), "...; resolve_circle", x, y, vx, vy, int(n))
PY
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
put_bike 4 -
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
echo "ok: a client part put again: its draw on a fresh node; the template's own bike back"
as bob
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
# [KIT_BODY_VARS] The finish (its trigger zone and its line, a kit/polygon of
# surface "finish") moved just ahead of the start: ridden over without every
# gem (refused, the bike not held)
hazard_back() # try_ hazard, the bike back at the start
{
	local mh
	mh=$(mark "$SL")
	try_ hazard
	await "$SL" "$mh" 5 "local/crag_run 7: kitboss: hit a hazard"
	for i in $(seq 20); do
		body
		awk -v x="$bx" 'BEGIN { exit !(x < -58) }' && break
		cmd "delay 200"
	done
	awk -v x="$bx" 'BEGIN { exit !(x < -58) }' || fail "the hazard did not take the bike to the start: $bx ($CL)"
}
# [KIT_STILL_LOOKS] Gem 11 taken (moved onto the bike, then away), still
# past its prediction's second; a hazard's reset brings it back on his
# screen: his own taken is kit:mine's, not its node's
mg=$(mark "$CL")
cmd 'event kit_edit {"op": "move", "id": 11, "pos": [-61, 0, 1]}'
await "$SL" "$m" 5 "kit/collectible 11: kitboss took it"
cmd 'event kit_edit {"op": "move", "id": 11, "pos": [-30, 8, 1]}'
await "$SL" "$m" 5 "An edit by kitboss: moved 11 to \[-30"
await "$CL" "$mg" 5 "kit: entity 11's look: taken on"
cmd "delay 1200" "frames 20"
mg=$(mark "$CL")
hazard_back
await "$CL" "$mg" 5 "kit: entity 11's look: taken off"
echo "ok: gem 11 taken, then back on his screen by a hazard (kit:mine)"
cmd 'event kit_edit {"op": "move", "id": 15, "pos": [-57, 0, 1]}'
await "$SL" "$m" 5 "An edit by kitboss: moved 15 to"
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
for try in 1 2; do
	mf=$(mark "$CL")
	cmd "keydown W"
	for i in $(seq 20); do
		body
		awk -v x="$bx" 'BEGIN { exit !(x > -54) }' && break
		cmd "delay 100"
	done
	cmd "keyup W"
	awk -v x="$bx" 'BEGIN { exit !(x > -54) }' && break
	[ $try = 2 ] && fail "the bike not past the finish line without every gem: x $bx ($CL)"
	echo "the bike short of x -54 ($bx): W again"
done
await "$CL" "$mf" 5 "Gems 0/3   Take every gem first"
seen "$SL" "$m" "kitboss's body var finish_open" && fail "finish_open set without every gem ($SL)"
echo "ok: over the finish line without every gem: refused, the bike rode on to x $bx"
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
hazard_back
cmd 'event kit_edit {"op": "place", "type": "kit/collectible", "pos": [-45, 8, 1]}'
await "$SL" "$m" 5 "An edit by kitboss: placed kit/collectible 95 "
cmd 'event kit_edit {"op": "set", "id": 95, "comp": 0, "param": "size", "value": [2, 2, 1]}'
await "$SL" "$m" 5 "An edit by kitboss: set 95's kit/collectible size"
step 5 "Gems 0/4" 'event kit_edit {"op": "link", "id": 95, "comp": 0, "output": "pickup", "to": 7, "input": "gem"}'
# (onto the bike at the start: its zone entered)
cmd 'event kit_edit {"op": "move", "id": 95, "pos": [-61, 0, 1]}'
await "$SL" "$m" 5 "local/crag_run 7: kitboss has 1 of 4 gems"
seen "$SL" "$m" "kit/collectible 95: kitboss took it" || fail "not gem 95's take ($SL)"
try_ gem
try_ gem
await "$SL" "$m" 5 "kitboss has 3 of 4 gems"
try_ finish
await "$SL" "$m" 5 "Take every gem first"
try_ gem
await "$SL" "$m" 5 "kitboss has 4 of 4 gems"
# [KIT_BODY_VARS] Every gem: the run's finish_open on his body (c:body_var);
# the finish's link taken away (its zone then finishes nothing, the bike
# stays), ridden to the line: held still by the bike's own step (s.vars), W
# still held, and no correction on his client
await "$SL" "$m" 5 "kitboss's body var finish_open = true"
cmd 'event kit_edit {"op": "unlink", "id": 15, "comp": 0, "output": "entered", "to": 7, "input": "finish"}'
await "$SL" "$m" 5 "An edit by kitboss: unlinked 15"
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
mc=$(mark "$CL")
for try in 1 2; do
	cmd "keydown W"
	for i in $(seq 20); do
		body
		awk -v x="$bx" 'BEGIN { exit !(x > -58.5) }' && break
		cmd "delay 100"
	done
	awk -v x="$bx" 'BEGIN { exit !(x > -58.5) }' && break
	cmd "keyup W"
	[ $try = 2 ] && fail "the bike never reached the finish line: x $bx ($CL)"
	echo "the bike short of the line ($bx): W again"
done
cmd "delay 300"
body
x1=$bx
cmd "delay 1000"
body
cmd "keyup W"
awk -v a="$x1" -v b="$bx" 'BEGIN { exit !(a > -58.5 && a < -55 && (a - b) ^ 2 < 0.0001) }' ||
	fail "the bike not held on the finish line with every gem: x $x1 -> $bx ($CL)"
seen "$CL" "$mc" "kit: the body corrected by" &&
	fail "a correction on the way to the line: $(tail -c +$((mc + 1)) "$CL" | grep -a "kit: the body corrected by" | head -3) ($CL)"
echo "ok: every gem: finish_open on his body, the bike held on the finish line by its own step (x $bx, W held), no correction"
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
cmd 'event kit_edit {"op": "link", "id": 15, "comp": 0, "output": "entered", "to": 7, "input": "finish"}'
await "$SL" "$m" 5 "An edit by kitboss: linked 15"
cmd 'event kit_edit {"op": "move", "id": 15, "pos": [52, 0, 1]}'
await "$SL" "$m" 5 "An edit by kitboss: moved 15 to \[52"
# ([KIT_CLIENT_REACT] (9) the lobby's keep_own_body on for the card below)
cmd 'event kit_edit {"op": "set", "id": 44, "comp": 0, "param": "keep_own_body", "value": true}'
mb=$(mark "$t/bob.log")
try_ finish
await "$SL" "$m" 5 "local/crag_run 7: kitboss finished in [0-9.]+ \(best\)"
best=$(tail -c +$((m + 1)) "$SL" | grep -aoP 'kitboss finished in \K[0-9.]+(?= \(best\))' | tail -1)
# ([KIT_BODY_VARS] the run over: the finish closed again)
await "$SL" "$m" 5 "kitboss's body var finish_open = nil"
await "$SL" "$m" 5 "kit/collectible 95: back"
echo "ok: a fourth gem linked only to the run: Gems 0/4, its take counted, the finish refused at 3 of 4 and taken at 4 ($best), the gem back by the run's reset"
# [KIT_LOBBY] The finish kitboss's result card (an over screen): the time,
# the best; the clock held till Again or the lobby's Play
await "$SL" "$m" 5 "kit/lobby 44: kitboss: playing -> over"
await "$CL" 0 5 "kit: ui 51 text .*: \"Time $best"
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
await "$CL" 0 5 "kit: ui 50 panel .* shown, layer 50: \"Finished\""
# [KIT_CLIENT_REACT] (9) keep_own_body: out of play under the card, kitboss's
# own bike still drawn for him (no spectating), hidden from kitbob; off again
await "$SL" "$m" 5 "kitboss is out of play \(a lobby\), their own body kept"
await "$CL" 0 5 "kit: out of play, your own body kept drawn"
await "$t/bob.log" "$mb" 5 "kit: player [0-9]+'s body hidden \(out of play\)"
cmd "frames 10" "screenshot $t/result.png"
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
cmd 'event kit_edit {"op": "set", "id": 44, "comp": 0, "param": "keep_own_body", "value": false}'
await "$SL" "$m" 5 "set 44's kit/lobby keep_own_body to false"
echo "ok: the result card: Time $best; keep_own_body: kitboss's bike kept for him, hidden from kitbob"
# The top-5 sign lists it; kitbob (no builder) may not clear it; End, then
# Play: still there
sign() { echo "kit/sign ${2:-43}: shows \"Best times.$1\" by"; } # (the log's newline a ?)
await "$SL" "$m" 5 "$(sign "1\. kitboss $best")"
# [KIT_SCENE_PACKAGES] The card's Lobby, then the other track: The Loop's
# scene, onto its start, its run; a crash there by the root's bike's link
# by name, its gems and finish its result card and its own sign
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
m=$(mark "$SL")
step 10 "kit: ui full screen 45 up" "frames 3" 'click Button "Lobby"'
await "$SL" "$m" 5 "kit/lobby 44: kitboss: over -> lobby"
mc=$(mark "$CL")
step 10 "kit: ui full screen none" "frames 5" 'click Button "The Loop*"'
await "$SL" "$m" 5 "kit/lobby 44: kitboss goes to loop"
await "$SL" "$m" 10 "teleports kitboss to \(-60, 0.5, 1\) in the scene loop"
await "$SL" "$m" 10 "kit/lobby 44: kitboss: lobby -> playing"
await "$SL" "$m" 5 "local/crag_run 59: kitboss: off you go, the run starts over"
# (its own heightmap the client's floor, kit/controls' "hm")
await "$CL" "$mc" 30 "player physics enabled"
for i in $(seq 20); do
	body
	awk -v x="$bx" 'BEGIN { exit !(x > -61 && x < -59) }' && break
	cmd "delay 200"
done
awk -v x="$bx" 'BEGIN { exit !(x > -61 && x < -59) }' || fail "not at the loop's start: $bx $by ($CL)"
for try in 1 2; do
	m2=$(mark "$SL")
	cmd "keydown W" "delay 800" "keydown A"
	for i in $(seq 25); do
		cmd "delay 150"
		seen "$SL" "$m2" "local/crag_run 59: kitboss: crashed" && break
		sleep 0.2
	done
	cmd "keyup A" "keyup W"
	seen "$SL" "$m2" "local/crag_run 59: kitboss: crashed" && break
	[ $try = 2 ] && fail "no crash on the loop reaching its run ($SL)"
	echo "no crash yet: W and A again"
done
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
cm=$(mark "$CL")
for g in 1 2 3 4; do
	cmd 'event kit_edit {"op": "try", "id": 59, "comp": 0, "input": "gem"}'
done
await "$SL" "$m" 5 "local/crag_run 59: kitboss has 4 of 4 gems"
cmd 'event kit_edit {"op": "try", "id": 59, "comp": 0, "input": "finish"}'
await "$SL" "$m" 5 "local/crag_run 59: kitboss finished in [0-9.]+ \(best\)"
lbest=$(tail -c +$((m + 1)) "$SL" | grep -aoP 'run 59: kitboss finished in \K[0-9.]+' | tail -1)
await "$SL" "$m" 5 "kit/lobby 44: kitboss: playing -> over"
await "$SL" "$m" 5 "$(sign "1\. kitboss $lbest" 63)"
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
await "$CL" "$cm" 5 "kit: ui 50 panel .* shown, layer 50: \"Finished\""
await "$CL" "$cm" 5 "kit: ui 51 text .*: \"Time $lbest"
cmd "frames 10" "screenshot $t/loop.png"
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
grep -a "dropped: " "$SL" && fail "a link by name dropped ($SL)"
grep -a -A1 "Exception on handling packet" "$CL" && fail "a packet handler failed ($CL)"
echo "ok: the card's Lobby, The Loop: its scene and start, its run; a crash there by name, its finish $lbest its result card and its sign"
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
# ([KIT_LOBBY] the lobby, The Crags: back at the sign)
await "$CL" 0 10 "kit: ui full screen 45 up"
pause_items "Continue" "Retry|To lobby"
step 10 "kit: ui full screen none" "frames 3" 'click Button "The Crags*"'
await "$SL" 0 10 "local/crag_run 7: kitboss: off you go"
cmd "frames 30" "screenshot $t/sign.png"
# (4z37h) The pause menu in the run: Retry (the run over from its start),
# To lobby (the lobby, the two gone)
pause_items "Retry, To lobby"
m=$(mark "$SL")
pause_open "Retry, To lobby"
cmd "frames 3" 'click Button "Retry"'
await "$SL" "$m" 10 "local/crag_run 7: kitboss: off you go"
pause_open "Retry, To lobby"
step 10 "kit: ui full screen 45 up" "frames 3" 'click Button "To lobby"'
pause_items "Continue" "Retry|To lobby"
echo "ok: the pause menu: Retry and To lobby in the run, not in the lobby; Retry started it over, To lobby the lobby"
echo "ok: over a server restart (Ended) still listed, the HUD's best $best; kitboss's Clear kept state emptied the sign, Undo brought it back"
# [KIT_STILL_LOOKS] A prediction the server never confirms (a gem type
# whose on_enter takes nothing, with kit/collectible's client part): one
# placed, moved onto the bike, drawn taken, then back after the
# prediction's second (read till then, though still)
m=$(mark "$SL")
step 10 "kit: ui full screen none" "frames 3" 'click Button "The Crags*"'
await "$SL" "$m" 10 "local/crag_run 7: kitboss: off you go"
python3 -I - "$here/builtin/kit/types/collectible.client.lua" > "$t/gem.cmd" <<'PY'
import json, sys
s = """return {
	version = 1,
	zone = "size",
	look = {shape = "box", size = 0.24, color = "#4cc9f0", offset = {0.5, 0.5, 0},
		state = "taken", when = {scale = {0.01, 0.01, 0.01}}},
	params = {size = {cat = "look", type = "position", default = {2, 2, 1}}},
	state = {taken = {default = {}, per_player = true}},
	on_enter = function(c, by) end,
}
"""
print("event kit_type " + json.dumps({"op": "put", "name": "nogem", "source": s,
	"client": open(sys.argv[1]).read()}))
PY
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
cmd "$(cat "$t/gem.cmd")"
await "$SL" "$m" 10 "A type put \((local/)?nogem\) by peer [0-9]+ done"
mp=$(mark "$CL")
cmd 'event kit_edit {"op": "place", "type": "local/nogem", "pos": [-30, 8, 1]}'
await "$SL" "$m" 5 "An edit by kitboss: placed local/nogem [0-9]+ "
ng=$(tail -c +$((m + 1)) "$SL" | grep -aoP 'An edit by kitboss: placed local/nogem \K[0-9]+' | head -1)
await "$CL" "$mp" 5 "kit: entity $ng's look: taken off"
mc=$(mark "$CL")
cmd "event kit_edit {\"op\": \"move\", \"id\": $ng, \"pos\": [-61, 0, 1]}"
await "$CL" "$mc" 5 "kit: entity $ng's look: taken on"
seen "$CL" "$mc" "kit: entity $ng predicted taken = true" || fail "gem $ng drawn taken without its prediction ($CL)"
await "$CL" "$mc" 5 "kit: entity $ng's look: taken off"
echo "ok: a prediction never confirmed: gem $ng drawn taken, back after its second"
cmd "sync 2000" quit
exec 3>&-
wait $BOSS 2>/dev/null
for p in edit lobby start side turned result loop sign; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
# (the run's teleports, a hazard's or the finish's, from its scene)
grep -a "a teleport refused" "$t/srv.log" "$SL" && fail "a teleport refused ($t/srv.log, $SL)"
echo "PASS: Crag Trial packed, installed and played: the bike's own movement up a polygon ramp, its crash an output and back at the start, a heavy step refused while the old one stepped to a gem's zone, $n corrections, drawn by its hook for both players; kitbob's first My account page drawn again; the best time kept over End, Play and a restart, on the top-5 sign, cleared by a builder only; screenshots $t/start.png $t/side.png $t/sign.png"
# vim: set noet ts=4 sw=4:
