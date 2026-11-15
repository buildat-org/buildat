#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~20 s (2026-11-15)
# covers: apps/workbench/templates/crag_trial/** builtin/kit/box/box.c builtin/kit/client_lua/move.lua builtin/kit/client_lua/controls.lua builtin/kit/client_lua/players.lua builtin/kit/kit.cpp builtin/accounts/client_lua/accounts.lua
# [KIT_PLANE] stage 4: a movement of a project's own, the Crag Trial template
# (local/crag_bike, its gems and run) on Workbench; one server, kitboss (the
# admin) and kitbob on a headless weston's Xwayland of the check's own:
#   0. the template packed by util/pack_templates.sh and installed, its
#      types with it;
#   1. New from it, F6: the side camera, the bike's movement, its client
#      part's draw hook drawing the body (start.png);
#   2. W, then A: the bike up the first ramp's polygon, leaning back, the
#      head down: the crash (crag_bike's output, linked to the run: its line
#      says Crashed), the bike back at the start a second later;
#   3. back in edit mode (Stopped), a version with a heavy step put over
#      kit:type: refused, "too slow";
#   4. played again, W: the old version steps on the server, the first gem's trigger zone
#      taken (the run's line: Gems 1/3, side.png); the corrections few;
#   5. kitbob joins, his body drawn by the hook on kitboss's screen; his
#      first My account page drawn again when the hello comes, "Connect an
#      agent..." on it (accounts.lua).
# Screenshots, kept with KEEP_TMP=1: $t/start.png, $t/side.png
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
client() # <name>: its commands from the fifo $t/<name>.cmd, its log $t/<name>.log
{
	mkfifo "$t/$1.cmd"
	sleep 900 > "$t/$1.cmd" &
	CHECK_PIDS+=($!)
	DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kit$1 \
		timeout 600 bin/buildat -C "$t/client_cache_$1" -D "$t/cu_$1" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
		< "$t/$1.cmd" > "$t/$1.log" 2>&1 &
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
for re in "The template's type local/crag_bike \([0-9]+ bytes\)" "The template's type local/crag_gem " \
		"The template's type local/crag_run "; do
	grep -aqE "$re" "$SL" || fail "no \"$re\" in $SL"
done
step 10 "kit editor: edit mode off" "frames 3" "keypress F6"
await "$CL" 0 10 "kit: controls: camera side, pointer [a-z]+, movement local/crag_bike, plane z 1"
await "$CL" 0 10 "crag_bike: the draw hook draws a bike"
await "$CL" 0 10 "kit: player [0-9]+'s body drawn by its movement"
# (kitbob on his way meanwhile)
BUILDAT_JOIN_CREATE=1 client bob
BOB=$!
exec 4> "$t/bob.cmd"
cmd "frames 30" "screenshot $t/start.png"
body
awk -v x="$bx" 'BEGIN { exit !(x > -61 && x < -59) }' || fail "the bike not at the start: $bx $by ($CL)"
echo "ok: a project from it, played: the side view, the bike's movement drawn by its hook"
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
	awk '$1 > -50 && $1 < -38 && $2 > 1.5 { f = 1 } END { exit !f }' ||
	fail "the bike never on the first ramp ($CL)"
for i in $(seq 20); do
	body
	awk -v x="$bx" 'BEGIN { exit !(x < -58) }' && break
	cmd "delay 200"
done
awk -v x="$bx" 'BEGIN { exit !(x < -58) }' || fail "the bike not back at the start after the crash: $bx ($CL)"
echo "ok: throttle up the ramp's polygon, the crash an output (the run's line), back at the start"
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
for f in 3 4; do
	FD=$f cmd "sync 2000" quit
done
exec 3>&- 4>&-
wait $BOSS $BOB 2>/dev/null
for p in start side; do
	[ -s "$t/$p.png" ] || fail "no screenshot $t/$p.png"
done
# (the run's teleports, a hazard's or the finish's, from its scene)
grep -a "a teleport refused" "$SL" && fail "a teleport refused ($SL)"
echo "PASS: Crag Trial packed, installed and played: the bike's own movement up a polygon ramp, its crash an output and back at the start, a heavy step refused while the old one stepped to a gem's zone, $n corrections, drawn by its hook for both players; kitbob's first My account page drawn again; screenshots $t/start.png $t/side.png"
# vim: set noet ts=4 sw=4:
