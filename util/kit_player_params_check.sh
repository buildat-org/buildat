#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~30 s, ~2 min with a cold module cache (2026-11-22)
# covers: builtin/kit/types/param_set.lua builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/client_lua/ui.lua builtin/kit/client_lua/controls.lua
# [KIT_PLAYER_PARAMS] c:set_param(..., {player = by}) and kit/param_set, on a
# fresh Workbench project (flat stone): kitboss (the admin) places kit/controls
# 3, kit/walker 4, a kit/ui_bar 5, a type of the check's own 6 (local/pp: its
# inputs c:set_param for the player who sends them), kit/param_set 7 (kit/walker
# gravity 8 for the player) set and reset by a trigger zone 8's entered and
# left, kit/param_set 9 (kit/controls camera chase) by a lever 10's on and off,
# kit/param_set 11 (the bar's height from a signal: scale 0.5, offset 1, within
# 1...6) and 12 (the bar's label for everyone); kitbob is a builder. Inputs by
# the inspector's Try (by the driving client):
#   1. 6's cam: kitboss's camera top_down and distance 12, kitbob's as authored;
#      clear: back;
#   2. 6's grav: kitboss's gravity 5 on the server and in his prediction; he
#      jumps: no more than a correction; kitbob's 20;
#   3. kitboss walks into the zone 8: his gravity 8, out: 20 again; the lever by
#      kitboss: his camera chase, by kitbob: kitbob's, each back at its off;
#   4. 6's bar: kitboss's bar 30 wide; 11 by 20: his bar 6 high (clamped); 12:
#      both labels "E ..."; their resets and 6's clear: both as authored;
#   5. 6's flood (60 fov changes in a run): 20 taken, the refusal logged once;
#      a second later 6's same (one fov 77 and 40 more of it, a distance) all
#      taken; 6's bad (a player's own plane) refused;
#   6. 6's cam and bar again, then Stop: kitboss's camera and bar as authored.
#   util/kit_player_params_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_player_params; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
SL=$t/srv.log
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
count() { tail -c +$(($2 + 1)) "$1" | grep -caE "$3"; } # <log> <offset> <regex>
last() { tail -c +$(($2 + 1)) "$1" | grep -aE "$3" | tail -1; } # <log> <offset> <regex>
cmd() { printf '%s\n' "$@" >&$FD; }
ed() { local e; for e in "$@"; do cmd "event kit_edit $e" "sync 5000"; done; }
try() # <id> <input> [value]: by the driven client
{
	ed "{\"op\": \"try\", \"id\": $1, \"input\": \"$2\", \"value\": ${3:-null}}"
}
walk() # <x> <z>: the driven client's feet there, on the stone (edit mode's op)
{
	local m
	m=$(mark "$SL")
	ed '{"op": "mode", "on": true}' "{\"op\": \"walk_here\", \"pos\": [$1, 0.5, $2]}"
	await "$SL" "$m" 10 "walks here: \($1, 0.5, $2\)"
}
client() # <name>: its commands from the fifo $t/<name>.cmd, its log $t/<name>.log
{
	mkfifo "$t/$1.cmd"
	sleep 900 > "$t/$1.cmd" &
	CHECK_PIDS+=($!)
	BUILDAT_JOIN_NAME=kit$1 timeout 300 bin/buildat -C "$t/client_cache_$1" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -c - \
		< "$t/$1.cmd" > "$t/$1.log" 2>&1 &
	CHECK_PIDS+=($!)
}
# The bar 5's size as the driven client last logged it ("<w>x<h>"), and its text
bar() { last "$CL" 0 "kit: ui 5 bar at" | grep -aoE ' [0-9]+x[0-9]+ in' | head -1 | tr -d ' in'; }
bar_text() { last "$CL" 0 "kit: ui 5 bar at" | grep -aoE '"[^"]*"$'; }
await_bar() # <offset> <regex on the size> [text regex]: the bar's next line so
{
	local i
	for i in $(seq 50); do
		tail -c +$(($1 + 1)) "$CL" | grep -a "kit: ui 5 bar at" | tail -1 |
			grep -aE " $2 in .*${3:-}" >/dev/null && return 0
		sleep 0.2
	done
	fail "the bar 5 not $2 ${3:-} in $CL (last: $(last "$CL" 0 "kit: ui 5 bar at"))"
}
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"

BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_ADMIN="setting open_registration on" client boss
BOSS=$!
exec 3> "$t/boss.cmd"
as boss
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$CL" 0 60 "kit editor: edit rights: yes"
cmd "max_fps 30"
ed '{"op": "mode", "on": true}'
place() # <type> <pos> <id>
{
	ed "{\"op\": \"place\", \"type\": \"$1\", \"pos\": $2}"
	await "$SL" 0 10 "An edit by kitboss: placed $1 $3\b"
}
setp() { ed "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
link() { ed "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"$2\", \"to\": $3, \"input\": \"$4\"}"; }
python3 -I - > "$t/type.cmd" <<'PY'
import json
src = '''return {
	version = 1,
	no_position = true,
	params = {ctl = {type = "entity", default = 0}, walk = {type = "entity", default = 0},
		bar = {type = "entity", default = 0}},
	inputs = {cam = "none", grav = "none", bar = "none", clear = "none",
		flood = "none", same = "none", bad = "none"},
	on_input = function(c, input, value, by)
		local p, o = c.params, {player = by}
		if input == "cam" then
			c:set_param(p.ctl, "kit/controls", "camera", "top_down", o)
			c:set_param(p.ctl, "kit/controls", "distance", 12, o)
		elseif input == "grav" then
			c:set_param(p.walk, "kit/walker", "gravity", 5, o)
		elseif input == "bar" then
			c:set_param(p.bar, "kit/ui_bar", "width", 30, o)
		elseif input == "clear" then
			for _, k in ipairs({"camera", "distance", "fov"}) do
				c:set_param(p.ctl, "kit/controls", k, nil, o)
			end
			c:set_param(p.walk, "kit/walker", "gravity", nil, o)
			c:set_param(p.bar, "kit/ui_bar", "width", nil, o)
		elseif input == "flood" then
			for i = 1, 60 do
				c:set_param(p.ctl, "kit/controls", "fov", 40 + i, o)
			end
		elseif input == "same" then
			for i = 1, 41 do
				c:set_param(p.ctl, "kit/controls", "fov", 77, o)
			end
			c:set_param(p.ctl, "kit/controls", "distance", 13, o)
		elseif input == "bad" then
			c:set_param(p.ctl, "kit/controls", "plane", "vertical", o)
		end
		c:log("pp", input, "by", c:name(by))
	end,
}'''
print("event kit_type " + json.dumps({"op": "put", "name": "pp", "source": src}))
PY
place kit/controls '[0, 1, 0]' 3
place kit/walker '[0, 1, 0]' 4
place kit/ui_bar '[0, 1, 0]' 5
cat "$t/type.cmd" >&3
await "$CL" 0 20 "pp: Saved"
place local/pp '[0, 1, 0]' 6
setp 6 ctl 3
setp 6 walk 4
setp 6 bar 5
place kit/param_set '[0, 1, 0]' 7
setp 7 target 4
setp 7 target_type '"kit/walker"'
setp 7 param '"gravity"'
setp 7 value '"8"'
place kit/trigger_zone '[10, 0, -1]' 8
setp 8 size '[3, 4, 3]'
link 8 entered 7 set
link 8 left 7 reset
place kit/param_set '[0, 1, 0]' 9
setp 9 target 3
place kit/lever '[-6, 1, 0]' 10
link 10 on 9 set
link 10 off 9 reset
place kit/param_set '[0, 1, 0]' 11
setp 11 target 5
setp 11 target_type '"kit/ui_bar"'
setp 11 param '"height"'
setp 11 source '"signal"'
setp 11 scale 0.5
setp 11 offset 1
setp 11 min 1
setp 11 max 6
place kit/param_set '[0, 1, 0]' 12
setp 12 target 5
setp 12 target_type '"kit/ui_bar"'
setp 12 param '"label"'
setp 12 value '"E {value}"'
setp 12 to '"everyone"'
await "$SL" 0 10 "An edit by kitboss: set 12's kit/param_set to"
echo "ok: placed: controls 3, walker 4, bar 5, local/pp 6, param_sets 7, 9, 11, 12, the zone 8, the lever 10"

client bob
BOB=$!
exec 4> "$t/bob.cmd"
as bob
await "$CL" 0 120 "Joined as kitbob"
as boss
ed '{"op": "builder", "name": "kitbob", "on": true}'
await "$SL" 0 10 "kitboss made builder kitbob"
as bob
await "$CL" 0 30 "kit editor: edit rights: yes"
cmd "max_fps 30"
ed '{"op": "mode", "on": true}'
for w in boss bob; do
	as $w
	await "$CL" 0 20 "kit: controls: view distance 6, .*gravity 20"
	await "$CL" 0 20 "kit: ui 5 bar at"
done
as bob
b0=$(bar)
as boss
s0=$(bar)
[ -n "$s0" ] && [ "$s0" = "$b0" ] || fail "the bars not alike at the start: kitboss $s0, kitbob $b0"

# 1. A camera of kitboss's own by c:set_param
as bob
mb=$(mark "$CL")
as boss
m=$(mark "$SL") mc=$(mark "$CL")
try 6 cam
await "$SL" "$m" 10 'Entity 3.s kit/controls camera set to "top_down" for kitboss in play'
await "$CL" "$mc" 10 "kit: controls: camera top_down"
await "$CL" "$mc" 10 "kit: controls: view distance 12,"
as bob
cmd "sync 3000"
seen "$CL" "$mb" "kit: controls: camera top_down|view distance 12" &&
	fail "kitboss's own camera reached kitbob ($CL)"
as boss
mc=$(mark "$CL")
try 6 clear
await "$CL" "$mc" 10 "kit: controls: camera first_person"
await "$CL" "$mc" 10 "kit: controls: view distance 6,"
await "$SL" "$m" 10 "Entity 3.s kit/controls distance back for kitboss in play"
echo "ok: c:set_param {player}: kitboss's camera top_down at 12 m, kitbob's as authored; nil put it back"

# 2. Gravity of his own: the server's steps and his prediction alike
as bob
mb=$(mark "$CL")
as boss
m=$(mark "$SL") mc=$(mark "$CL")
try 6 grav
await "$SL" "$m" 10 "kitboss's movement kit/walker changed: gravity 5"
await "$CL" "$mc" 10 "kit: controls: view .*gravity 5$"
ed '{"op": "mode", "on": false}'
cmd "frames 30" "event kit_body"
await "$CL" "$mc" 10 "kit: body at .* corrections"
mc=$(mark "$CL")
read -r c0 j0 <<< "$(last "$CL" 0 "kit: body at .* corrections" | sed -E 's/.* ([0-9]+) corrections, [0-9]+ pending, ([0-9]+) jumps.*/\1 \2/')"
for i in 1 2 3; do
	cmd "keypress Space" "frames 50"
done
cmd "event kit_body"
await "$CL" "$mc" 10 "kit: body at .* corrections"
read -r c1 j1 <<< "$(last "$CL" 0 "kit: body at .* corrections" | sed -E 's/.* ([0-9]+) corrections, [0-9]+ pending, ([0-9]+) jumps.*/\1 \2/')"
[ $((j1 - j0)) -ge 2 ] || fail "kitboss jumped $((j1 - j0)) times, not 2 or more ($CL)"
[ $((c1 - c0)) -le 1 ] ||
	fail "kitboss's prediction corrected $((c1 - c0)) times in $((j1 - j0)) jumps under his own gravity ($CL)"
as bob
cmd "sync 3000"
seen "$CL" "$mb" "kit: controls: view .*gravity 5$" && fail "kitboss's gravity reached kitbob ($CL)"
seen "$SL" "$m" "kitbob's movement kit/walker changed" && fail "kitbob's movement changed ($SL)"
as boss
mc=$(mark "$CL")
ed '{"op": "mode", "on": true}'
try 6 clear
await "$CL" "$mc" 10 "kit: controls: view .*gravity 20$"
echo "ok: kitboss's own gravity 5: $((j1 - j0)) jumps, $((c1 - c0)) corrections; kitbob's 20; nil put it back"

# 3. kit/param_set: a gravity zone and a camera lever
as bob
mb=$(mark "$CL")
as boss
m=$(mark "$SL") mc=$(mark "$CL")
walk 11 0
await "$SL" "$m" 10 "kit/trigger_zone 8: kitboss entered"
await "$SL" "$m" 10 "kit/param_set 7: set gravity of 4 to 8 for kitboss"
await "$CL" "$mc" 10 "kit: controls: view .*gravity 8$"
walk 0 0
await "$SL" "$m" 10 "kit/param_set 7: reset gravity of 4 back for kitboss"
await "$CL" "$mc" 10 "kit: controls: view .*gravity 20$"
mc=$(mark "$CL")
try 10 toggle
await "$SL" "$m" 10 "kit/param_set 9: set camera of 3 to chase for kitboss"
await "$CL" "$mc" 10 "kit: controls: camera chase"
as bob
cmd "sync 3000"
seen "$CL" "$mb" "kit: controls: camera chase|gravity 8$" && fail "kitboss's zone or lever reached kitbob ($CL)"
as boss
try 10 toggle
await "$SL" "$m" 10 "kit/param_set 9: reset camera of 3 back for kitboss"
await "$CL" "$mc" 10 "kit: controls: camera first_person"
mc=$(mark "$CL")
as bob
mb=$(mark "$CL")
try 10 toggle
await "$SL" "$m" 10 "kit/param_set 9: set camera of 3 to chase for kitbob"
await "$CL" "$mb" 10 "kit: controls: camera chase"
try 10 toggle
await "$CL" "$mb" 10 "kit: controls: camera first_person"
as boss
cmd "sync 3000"
seen "$CL" "$mc" "kit: controls: camera chase" && fail "kitbob's lever reached kitboss ($CL)"
echo "ok: kit/param_set: the zone's gravity 8 for kitboss while in it; the lever's chase camera for whoever flipped it on, back at its off"

# 4. The bar: its width by c:set_param, its height from a signal, its label for everyone
as bob
mb=$(mark "$CL")
as boss
m=$(mark "$SL") mc=$(mark "$CL")
try 6 bar
await "$SL" "$m" 10 "Entity 5.s kit/ui_bar width set to 30 for kitboss in play"
await "$CL" "$mc" 10 'kit: ui own parameters: .*"5":\{"width":30\}'
try 11 set 20
await "$SL" "$m" 10 "kit/param_set 11: set height of 5 to 6 for kitboss"
await_bar "$mc" "[0-9]+x[0-9]+" ""
w0=${b0%x*} h0=${b0#*x}
for i in $(seq 50); do
	s=$(bar)
	[ "${s%x*}" -gt "$w0" ] && [ "${s#*x}" -gt "$h0" ] && break
	sleep 0.2
done
[ "${s%x*}" -gt "$w0" ] && [ "${s#*x}" -gt "$h0" ] ||
	fail "kitboss's bar $s, not wider and higher than the authored $b0 ($CL)"
try 12 set
await "$SL" "$m" 10 "kit/param_set 12: set label of 5 to E \{value\} for everyone"
await_bar "$mc" "${s}" '"E [0-9]+"$'
as bob
await_bar "$mb" "${b0}" '"E [0-9]+"$'
seen "$CL" "$mb" '"5":\{"width"|"height"' && fail "kitboss's bar size reached kitbob ($CL)"
[ "$(bar)" = "$b0" ] || fail "kitbob's bar $(bar), not the authored $b0 ($CL)"
mb=$(mark "$CL")
as boss
mc=$(mark "$CL")
try 12 reset
try 11 reset
try 6 clear
await_bar "$mc" "${b0}" '"[0-9]+"$'
as bob
await_bar "$mb" "${b0}" '"[0-9]+"$'
echo "ok: kitboss's bar $s (width 30, height 6 from 20 clamped), kitbob's $b0; the label E for both; the resets put both back"

# 5. The limit: a flood refused past 20 a second; the same value again free
as boss
m=$(mark "$SL")
try 6 flood
await "$SL" "$m" 10 "local/pp 6: pp flood by kitboss"
n=$(count "$SL" "$m" "Entity 3.s kit/controls fov set to [0-9]+ for kitboss in play")
r=$(count "$SL" "$m" "set_param refused: past 20 changes a second for kitboss")
[ "$n" -ge 1 ] && [ "$n" -le 20 ] || fail "$n fov changes of 60 taken in a run, not 1...20 ($SL)"
[ "$r" = 1 ] || fail "the flood's refusal logged $r times, not once ($SL)"
cmd "sync 3000"
sleep 1.1
m=$(mark "$SL")
try 6 same
await "$SL" "$m" 10 "local/pp 6: pp same by kitboss"
seen "$SL" "$m" "set_param refused" && fail "the same value again counted toward the limit ($SL)"
seen "$SL" "$m" "kit/controls distance set to 13 for kitboss" || fail "no distance 13 after the same fov ($SL)"
n2=$(count "$SL" "$m" "kit/controls fov set to 77 for kitboss")
[ "$n2" = 1 ] || fail "fov 77 logged $n2 times, not once ($SL)"
m=$(mark "$SL")
try 6 bad
await "$SL" "$m" 10 "set_param refused: kit/controls' plane is the scene's, not a player's own"
echo "ok: the flood: $n of 60 taken, refused once; the same value 40 times over free; a player's own plane refused"

# 6. Stop: all of them gone
m=$(mark "$SL") mc=$(mark "$CL")
try 6 clear
try 6 cam
try 6 bar
await "$CL" "$mc" 10 "kit: controls: view distance 12,"
await "$CL" "$mc" 10 'kit: ui own parameters: .*"5":\{"width":30\}'
mc=$(mark "$CL")
ed '{"op": "stop"}'
await "$SL" "$m" 10 "Stop by kitboss"
await "$CL" "$mc" 10 "kit: controls: camera first_person"
await "$CL" "$mc" 10 "kit: controls: view distance 6,"
await "$CL" "$mc" 10 'kit: ui own parameters: \{"ui":\{\}\}'
echo "ok: Stop: kitboss's own camera, distance and bar width gone"
cmd quit
as bob
cmd quit
exec 3>&- 4>&-
wait $BOSS $BOB 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
echo "PASS: per-player parameters: c:set_param {player} and kit/param_set (a zone's gravity, a lever's camera, a stat's bar height, a label for everyone) for one player alone, the other's as authored, the prediction under a player's gravity, nil and reset back, the rate limit (the same value free), Stop clearing them"
# vim: set noet ts=4 sw=4:
