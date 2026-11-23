#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-23)
# covers: builtin/kit/kit.cpp builtin/kit/types/game_rules.lua builtin/kit/client_lua/editor_input.lua builtin/kit/client_lua/controls.lua extensions/pause_menu/init.lua extensions/launch_menu/preferences.lua client/api.lua src/client/app.cpp src/client/app_lua.h apps/workbench/**
# [KIT_PAUSE_ALONE] The pause menu pauses a scene played alone, on a fresh
# Workbench project (flat stone): kitboss (the admin) places a probe (a
# timer every second logging c.now) and a wandering creature in "world", a
# probe in the new scene "second"; kitbob (a builder, his client with
# -o kit_pause_unfocused=1) plays in second. Running:
#   1. kitboss, alone in world, opens the pause menu: world pauses (his
#      client's kit:controls paused, its shared time frozen), its probe's
#      timer and the creature stop while second's probe ticks on and
#      kitbob's client is not paused; Continue: world runs again, its probe's
#      next tick as due by the time left at the pause (not early), its c.now
#      on from where it stopped; the creature walks again.
#   2. The menu again: kitbob comes to world, editing (5: he does not count,
#      world stays paused), then into play there: world runs again, kitboss's
#      menu still open.
#   3. (6) The focus: kitboss's window losing it does nothing (the preference
#      off); kitbob's (on) opens his menu, pausing second.
#   4. kit/game_rules' pause_alone off: kitboss's menu pauses nothing.
#   util/kit_pause_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v weston > /dev/null || skip "no weston"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_pause; t=$CHECK_TMP
cd "$here/Build"
check_build
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
export BUILDAT_WORKBENCH_TYPES="$t/user/apps/workbench/check_types"
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
cat > "$BUILDAT_WORKBENCH_TYPES/probe.lua" <<'LUA'
return {
	version = 1,
	state = {n = {default = 0}},
	on_start = function(c)
		c:after(1, "tick")
	end,
	on_timer = function(c)
		c.state.n = c.state.n + 1
		c:log(string.format("tick %d now %.3f", c.state.n, c.now))
		c:after(1, "tick")
	end,
}
LUA
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
ticks() # <probe> <offset> <n> <seconds>: n of its ticks in the server's log
{
	local i
	for i in $(seq $(($4 * 5))); do
		[ "$(count "$SL" "$2" "workbench/probe $1: tick")" -ge "$3" ] && return 0
		sleep 0.2
	done
	fail "probe $1 did not tick $3 times in $4 s ($SL)"
}
cmd() { printf '%s\n' "$@" >&$FD; }
ed() { local e; for e in "$@"; do cmd "event kit_edit $e" "sync 5000"; done; }
step() # <seconds> <regex in the client's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$CL")
	cmd "$@"
	await "$CL" "$m" "$s" "$re"
}
# Each client on a headless weston's Xwayland of its own: no pointer, nobody
# else's window, so its window has no focus a "focus off" would not drop
# (on the desk's X a pointer over it gave it one)
weston_display() # <name>: WD, the display of a weston started for it
{
	local i
	WD=
	weston --backend=headless --xwayland --socket=buildat-pause-$1-$$ --width=1100 \
		--height=800 > "$t/weston_$1.log" 2>&1 &
	CHECK_PIDS+=($!)
	for i in $(seq 50); do
		WD=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston_$1.log" | grep -o ":[0-9]*$")
		[ -n "$WD" ] && break
		sleep 0.2
	done
	[ -n "$WD" ] || fail "weston's Xwayland ($t/weston_$1.log)"
}
client() # <name> <log> [-o ...]: its commands from the fifo $t/<name>.cmd
{
	local name=$1 log=$2 d
	shift 2
	weston_display "$name"
	d=$WD
	rm -f "$t/$name.cmd"
	mkfifo "$t/$name.cmd"
	sleep 900 > "$t/$name.cmd" &
	CHECK_PIDS+=($!)
	DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 \
		BUILDAT_JOIN_NAME=kit$name timeout 400 bin/buildat -C "$t/client_cache_$name" \
		-D "$t/cu_$name" -s localhost:$SERVER_PORT -w 1024x700 -l 3 "$@" -c - \
		< "$t/$name.cmd" > "$log" 2>&1 &
	CHECK_PIDS+=($!)
}
SL=$t/srv.log
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"

BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_ADMIN="setting open_registration on" client boss "$t/boss.log"
BOSS=$!
exec 3> "$t/boss.cmd"
as boss
await "$CL" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$CL" 0 60 "kit editor: edit rights: yes"
step 20 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
step 10 "kit editor: the server is Ended" 'event kit_edit {"op": "stop"}'
placed() # <what>: the id of the last "placed <what> <id>" since $m
{
	tail -c +$((m + 1)) "$SL" | grep -aoP "An edit by kitboss: placed $1 \K[0-9]+" | tail -1
}
m=$(mark "$SL")
ed '{"op": "place", "type": "workbench/probe", "pos": [0, 1, 2]}'
await "$SL" "$m" 10 "An edit by kitboss: placed workbench/probe"
P1=$(placed workbench/probe)
# The creature: its senses off (comps: part, walker, health, senses, flee,
# attack, wander), wandering often
m=$(mark "$SL")
ed '{"op": "place", "prefab": "kit/creature", "pos": [6, 1, 6]}'
await "$SL" "$m" 10 "An edit by kitboss: placed prefab kit/creature as [0-9]+\.\.\.[0-9]+"
CR=$(tail -c +$((m + 1)) "$SL" | grep -aoP "placed prefab kit/creature as [0-9]+\.\.\.\K[0-9]+" | head -1)
ed "{\"op\": \"set\", \"id\": $CR, \"comp\": 3, \"param\": \"enabled\", \"value\": false}" \
	"{\"op\": \"set\", \"id\": $CR, \"comp\": 6, \"param\": \"pause\", \"value\": 0.5}"
await "$SL" "$m" 10 "An edit by kitboss: set $CR's kit/wander pause to 0.5"
step 20 "kit editor: in the scene second " 'event kit_edit {"op": "new_scene", "name": "second"}'
m=$(mark "$SL")
ed '{"op": "place", "type": "workbench/probe", "pos": [0, 1, 2]}'
await "$SL" "$m" 10 "An edit by kitboss: placed workbench/probe"
P2=$(placed workbench/probe)
[ -n "$P1" ] && [ -n "$P2" ] && [ "$P1" != "$P2" ] || fail "the probes' ids: \"$P1\" \"$P2\" ($SL)"
step 20 "kit editor: in the scene world " 'event kit_edit {"op": "scene", "name": "world"}'
m=$(mark "$SL")
step 15 "kit editor: the server is Running" 'event kit_edit {"op": "play"}'
await "$SL" "$m" 20 "Entity $CR's kit/creature_walker steps in play"
ticks "$P1" "$m" 1 10
ticks "$P2" "$m" 1 10
echo "ok: placed and Running: probe $P1 and creature $CR in world, probe $P2 in second"

client bob "$t/bob.log" -o kit_pause_unfocused=1
BOB=$!
exec 4> "$t/bob.cmd"
as bob
await "$CL" 0 120 "Joined as kitbob"
as boss
ed '{"op": "builder", "name": "kitbob", "on": true}'
await "$SL" 0 10 "kitboss made builder kitbob"
as bob
await "$CL" 0 30 "kit editor: edit rights: yes"
await "$CL" 0 60 "player physics enabled"
step 20 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
step 20 "kit editor: in the scene second " 'event kit_edit {"op": "scene", "name": "second"}'
step 20 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
as boss
step 20 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
await "$CL" 0 60 "player physics enabled"
m=$(mark "$SL")
await "$SL" "$m" 30 "Entity $CR: kit/wander's way to|Entity $CR stopped at"
echo "ok: kitbob plays in second, kitboss in world; the creature walks"

# 1. kitboss alone in world opens the menu: world pauses, second does not
m1=$(mark "$SL") mc1=$(mark "$t/boss.log") mb1=$(mark "$t/bob.log")
step 10 "pause: the menu shown" "keypress Escape"
await "$SL" "$m1" 10 "\[KIT_PAUSE_ALONE\] kitboss's pause menu open"
await "$SL" "$m1" 10 "\[KIT_PAUSE_ALONE\] Scene world paused: kitboss, alone in it"
await "$CL" "$mc1" 10 "kit: the scene paused"
mp=$(mark "$SL")
ticks "$P2" "$mp" 4 10
step 10 "pause: the menu closed" 'click Button "Continue"'
await "$SL" "$m1" 10 "\[KIT_PAUSE_ALONE\] Scene world runs again after [0-9.]+ s \(the menu closed\)"
await "$CL" "$mc1" 10 "kit: the scene runs"
mw=$(mark "$SL")
ticks "$P1" "$mw" 2 10
await "$SL" "$mw" 30 "Entity $CR: kit/wander's way to|Entity $CR stopped at|kit/wander $CR: wanders"
seen "$t/bob.log" "$mb1" "kit: the scene (paused|runs)" && fail "kitbob's client in second was paused ($t/bob.log)"
# (the logs whole: this is the first pause)
python3 -I - "$SL" 0 "$t/boss.log" 0 "$P1" "$P2" "$CR" <<'PY' || fail "the pause ($SL, $t/boss.log)"
import re, sys
def lines(path, off):
    return open(path, "rb").read()[int(off):].decode(errors="replace").splitlines()
def at(l):
    h, m, s = l.split()[2].split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)
srv = lines(sys.argv[1], sys.argv[2])
p1, p2, cr = sys.argv[5:8]
pi = next(i for i, l in enumerate(srv) if "Scene world paused" in l)
wi = next(i for i, l in enumerate(srv) if "Scene world runs again" in l)
tp, tw = at(srv[pi]), at(srv[wi])
assert tw - tp >= 2.5, f"paused only {tw - tp:.2f} s"
def ticks(p, a, b):
    rx = re.compile(r"workbench/probe %s: tick (\d+) now ([\d.]+)" % p)
    return [(at(l), int(m.group(1)), float(m.group(2))) for l in srv[a:b]
            for m in [rx.search(l)] if m]
before, during, after = ticks(p1, 0, pi), ticks(p1, pi, wi), ticks(p1, wi, len(srv))
assert before and after, (before, after)
assert not during, f"probe {p1} ticked while paused: {during}"
ta, na, nowa = before[-1]
tb, nb, nowb = after[0]
assert nb == na + 1, (na, nb)
# its c.now on from where it stopped: a second of the scene's time apart
assert abs(nowb - nowa - 1) < 0.06, f"c.now {nowa} then {nowb}"
# the time left at the pause, after the wake: not early, not late
due = tw + (1 - (tp - ta))
assert due - 0.12 <= tb <= due + 0.25, f"the tick after the wake at {tb - tw:.3f} s, due {due - tw:.3f} s"
other = ticks(p2, pi, wi)
assert len(other) >= 3, f"probe {p2} in second ticked {len(other)} times while world was paused"
crx = re.compile(r"Entity %s(: kit/[a-z]+'s way to| stopped at)|kit/wander %s: wanders" % (cr, cr))
moved = [l for l in srv[pi + 1:wi] if crx.search(l)]
assert not moved, f"the creature moved while paused: {moved}"
cl = lines(sys.argv[3], sys.argv[4])
cp = next(i for i, l in enumerate(cl) if "kit: the scene paused" in l)
cw = next(i for i, l in enumerate(cl) if "kit: the scene runs" in l)
st = lambda a, b: [float(m.group(1)) for l in cl[a:b] for m in [re.search(r"kit: the shared time is ([\d.]+)", l)] if m]
sa, sb = st(0, cp), st(cp, cw)
assert sa and sb, f"no shared time at the pause ({sa}) and the wake ({sb})"
assert abs(sb[-1] - sa[-1]) < 0.25, f"the client's shared time {sa[-1]} at the pause, {sb[-1]} at the wake"
print(f"ok: world paused {tw - tp:.2f} s: probe {p1} tick {na} (c.now {nowa}) then {nb} "
      f"(c.now {nowb}) {tb - tw:.3f} s after the wake (due {due - tw:.3f}); probe {p2} "
      f"ticked {len(other)} times; the creature still; the client's clock {sa[-1]} -> {sb[-1]}")
PY

# 2. The menu again; kitbob comes in editing (5: not counted), then plays
m2=$(mark "$SL") mc2=$(mark "$t/boss.log")
step 10 "pause: the menu shown" "keypress Escape"
await "$SL" "$m2" 10 "Scene world paused: kitboss"
as bob
step 20 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
step 20 "kit editor: in the scene world " 'event kit_edit {"op": "scene", "name": "world"}'
me=$(mark "$SL")
ticks "$P2" "$me" 2 10
seen "$SL" "$m2" "Scene world runs again" && fail "world ran again for kitbob editing in it ($SL)"
seen "$SL" "$me" "workbench/probe $P1: tick" && fail "probe $P1 ticked with kitbob editing in world ($SL)"
echo "ok: (5) kitbob editing in world: it stays paused"
step 20 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
await "$SL" "$m2" 20 "Scene world runs again after [0-9.]+ s \(another player came in\)"
as boss
await "$CL" "$mc2" 10 "kit: the scene runs"
mw=$(mark "$SL")
ticks "$P1" "$mw" 1 10
seen "$CL" "$mc2" "pause: the menu closed" && fail "kitboss's menu closed as kitbob came in ($CL)"
echo "ok: kitbob into play in world: it runs again, kitboss's menu still open"
step 10 "pause: the menu closed" 'click Button "Continue"'
seen "$SL" "$mw" "Scene world paused" && fail "world paused with two players in it ($SL)"

# 3. (6) The focus: off for kitboss (no menu), on for kitbob (his menu)
as bob
step 20 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
step 20 "kit editor: in the scene second " 'event kit_edit {"op": "scene", "name": "second"}'
step 20 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
as boss
m3=$(mark "$SL") mc3=$(mark "$CL")
step 10 "kit: the window lost the focus \(kit_pause_unfocused off\)" "focus off"
ticks "$P1" "$m3" 1 10
seen "$CL" "$mc3" "pause: the menu shown" && fail "kitboss's lost focus opened the menu, the preference off ($CL)"
step 10 "command: focus on" "focus on"
as bob
mb3=$(mark "$CL")
step 10 "kit: the window lost the focus: the pause menu" "focus off"
await "$CL" "$mb3" 10 "pause: the menu shown"
await "$SL" "$m3" 10 "Scene second paused: kitbob, alone in it"
step 10 "command: focus on" "focus on"
step 10 "pause: the menu closed" 'click Button "Continue"'
await "$SL" "$m3" 10 "Scene second runs again after [0-9.]+ s \(the menu closed\)"
seen "$SL" "$m3" "Scene world paused" && fail "world paused for kitbob's menu in second ($SL)"
echo "ok: (6) a lost focus: nothing for kitboss (the preference off), kitbob's menu (on) and second paused"

# 4. pause_alone off: the menu pauses nothing
as boss
step 20 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
m=$(mark "$SL")
ed '{"op": "place", "type": "kit/game_rules", "pos": [0, 1, 0]}'
await "$SL" "$m" 10 "An edit by kitboss: placed kit/game_rules"
G=$(placed kit/game_rules)
ed "{\"op\": \"set\", \"id\": $G, \"comp\": 0, \"param\": \"pause_alone\", \"value\": false}"
await "$SL" "$m" 10 "An edit by kitboss: set $G"
step 20 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
m4=$(mark "$SL")
step 10 "pause: the menu shown" "keypress Escape"
await "$SL" "$m4" 10 "kitboss's pause menu open"
ticks "$P1" "$m4" 2 10
seen "$SL" "$m4" "Scene world paused" && fail "world paused with pause_alone off ($SL)"
step 10 "pause: the menu closed" 'click Button "Continue"'
echo "ok: (4) pause_alone off: kitboss's menu paused nothing"

as bob
cmd quit
as boss
cmd quit
exec 3>&- 4>&-
wait $BOSS $BOB 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
echo "PASS: a scene pauses while its one player has the pause menu open (its timers, creature, clock and the client's held; the next tick as due), another scene and a builder editing in it untouched, a second player wakes it with the menu open, the lost-focus preference, pause_alone off ($t)"
# vim: set noet ts=4 sw=4:
