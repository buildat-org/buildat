#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-09)
# covers: builtin/kit/kit.cpp builtin/kit/creatures.h builtin/kit/box/box.c builtin/kit/types/creature_walker.lua builtin/kit/types/senses.lua builtin/kit/types/wander.lua builtin/kit/types/follow.lua builtin/kit/types/attack.lua builtin/kit/types/flee.lua builtin/kit/types/creature.prefab.json builtin/kit/types/spawner.lua apps/workbench/**
# [KIT_CREATURES_8A] (kit_plan stage 8, slice 8a) one creature end to end, on a
# fresh Workbench save composed by the editor's ops, an infinite flat World:
#   1. The prefab kit/creature placed 260 m out (its senses off) wanders: a way
#      found, walked, arrived. A spawner makes a second one, which steps too.
#   2. Its senses on: it spots kitboss, its attack's move wins over wander, it
#      chases and hits him through his health.
#   3. Its health set low: flee wins, it runs off, further from him than it was;
#      [KIT_COMPONENT_ORDER] (placed and detached) flee moved under wander:
#      attack wins; moved back: flee again.
#   4. kitboss teleported 650 m away: it loses him, its section unloads and it
#      sleeps; teleported back: it wakes where it slept and walks on.
# A screenshot of it chasing, kept with KEEP_TMP=1: $t/chase.png
# The client is driven through a fifo, each step after the server's log says
# what the last one waited for.
#   util/kit_creatures_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_creatures; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_JOIN_PASSWORD=checkpass12
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
mkfifo "$t/cmd"
sleep 900 > "$t/cmd" &
CHECK_PIDS+=($!)
# (not run_client: a job in the background reads /dev/null unless told)
check_build
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	timeout 600 bin/buildat -C "$t/client_cache" -D "$t/cu_boss" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -c - < "$t/cmd" > "$t/boss.log" 2>&1 &
CLIENT=$!
CHECK_PIDS+=($CLIENT)
exec 3> "$t/cmd"
cmd() { printf '%s\n' "$@" >&3; }
# The client's own log: a line logged after <offset> (wc -c then), within s
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($t/boss.log)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($t/srv.log, $t/boss.log)"
}
step() # <seconds> <regex in the client's log> <command>...: the commands, then the wait
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$t/boss.log")
	cmd "$@"
	await "$t/boss.log" "$m" "$s" "$re"
}
ed() { step 10 "kit editor: state:" "event kit_edit $1"; }
set_() { ed "{\"op\": \"set\", \"id\": $1, \"comp\": $2, \"param\": \"$3\", \"value\": $4}"; }
try() { step 10 "kit editor: tried|kit editor: .*refused" "event kit_edit {\"op\": \"try\", \"id\": $1, \"input\": \"$2\"${3:+, \"value\": $3}}"; }
srv() # <seconds> <regex>: in the server's log after the last srv_mark
{
	await "$t/srv.log" "$SM" "$1" "$2"
}
srv_mark() { SM=$(mark "$t/srv.log"); }
srv_mark
await "$t/boss.log" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$t/boss.log" 0 60 "player physics enabled"
await "$t/boss.log" 0 20 "kit editor: edit rights: yes"
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
step 10 "the server is Ended" 'event kit_edit {"op": "stop"}'
# (all past 128 m: the spawn's load point keeps its 64 m sections round x 0)
# 3 world, 4 walker, 5 the players' spawner, 6 the prefab's root, 7 the creature,
# 8 and 9 teleporters out and back, 10 a spawner of creatures
ed '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
set_ 3 0 size '"infinite"'
set_ 3 0 generator '"flat"'
set_ 3 0 decorations false
ed '{"op": "place", "type": "kit/walker", "pos": [0, 1, 0]}'
ed '{"op": "place", "type": "kit/spawner", "pos": [250, 1, 0]}'
set_ 5 0 players true
ed '{"op": "place", "prefab": "kit/creature", "pos": [260, 1, 8]}'
# its senses: off, all round, far (comps: part, walker, health, senses, flee,
# attack, wander)
set_ 7 3 enabled false
set_ 7 3 range 30
set_ 7 3 angle 360
# [KIT_COMPONENT_ORDER] detached, as the editor places a stock prefab: its
# components its own (the root gone, the ids kept)
ed '{"op": "prefab_detach", "id": 6}'
ed '{"op": "place", "type": "kit/teleporter", "pos": [248, 1, -8]}'
set_ 8 0 to '[900, 1, 0]'
ed '{"op": "place", "type": "kit/teleporter", "pos": [900, 1, 8]}'
set_ 9 0 to '[250, 1, 0]'
ed '{"op": "place", "type": "kit/spawner", "pos": [270, 1, -6]}'
set_ 10 0 prefab '"kit/creature"'
set_ 10 0 max 1
# 1. Played: it wanders
srv_mark
step 15 "the server is Running" 'event kit_edit {"op": "play"}'
srv 20 "Entity 7's kit/creature_walker steps in play"
srv 20 "Entity 7: kit/wander's move wins"
srv 20 "Entity 7: kit/wander's way to .*: [1-9][0-9]* waypoints"
srv 30 "Entity 7 stopped at .*: arrived"
srv_mark
try 10 spawn
srv 10 "kit/spawner 10: made [0-9]+"
srv 20 "Entity [0-9]+: kit/wander's way to"
# 2. Its senses on: spots him, chases, hits
srv_mark
try 7 enable
srv 10 "kit/senses 7: spotted [0-9]+ kitboss"
srv 10 "Entity 7: kit/attack's move wins"
step 10 "kit editor: edit mode off" 'event kit_edit {"op": "mode", "on": false}'
cmd "look_dir 1 0 0.8" "frames 30" "screenshot $t/chase.png"
srv 30 "Entity 7's kit/attack hurts kitboss: 2 bite"
srv_mark
srv 10 "Entity 7's kit/attack hurts kitboss: 2 bite"
# 3. Its health low: flees
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
srv_mark
try 7 set 2
srv 10 "Entity 7: kit/flee's move wins"
srv 10 "kit/flee 7: flees from [0-9]+ \(health low\)"
# [KIT_COMPONENT_ORDER] The order is the priority: flee under wander, attack's
# move wins; back over attack, flee's again
srv_mark
ed '{"op": "move_component", "id": 7, "comp": 4, "by": 1}'
ed '{"op": "move_component", "id": 7, "comp": 5, "by": 1}'
srv 10 "Entity 7: kit/attack's move wins"
srv_mark
ed '{"op": "move_component", "id": 7, "comp": 6, "by": -1}'
ed '{"op": "move_component", "id": 7, "comp": 5, "by": -1}'
srv 10 "Entity 7: kit/flee's move wins"
# (out of its senses' 30 m: it lost him)
srv 30 "kit/senses 7: lost"
# 4. Far away: it sleeps; back: it wakes where it slept
srv_mark
try 8 teleport
srv 60 "Entity 7 sleeps at"
srv_mark
try 9 teleport
srv 60 "Entity 7 wakes at"
srv 20 "Entity 7: kit/[a-z]+'s way to"
cmd quit
exec 3>&-
wait $CLIENT 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 - "$t" <<'PY' || fail "the logs say otherwise ($t)"
import re, sys
t = sys.argv[1]
srv = open(f"{t}/srv.log", errors="replace").read()
def pos(m):
	return tuple(float(v) for v in m.groups())
# 3. Away from him: its flight's goals, each further from his spawn (250, 0) than
# the last, to past 20 m before it lost him (from flee moved back over attack)
f = srv.rfind("moved kit/flee up on 7")
lost = srv.find("kit/senses 7: lost", f)
goals = [pos(m) for m in re.finditer(r"Entity 7: kit/flee's way to \(([-\d.]+), ([-\d.]+), ([-\d.]+)\)",
	srv[f:lost])]
ds = [((x - 250) ** 2 + z ** 2) ** 0.5 for x, y, z in goals]
if len(ds) < 3 or any(b < a for a, b in zip(ds, ds[1:])) or ds[-1] < 20:
	sys.exit(f"its flight's goals from him: {ds}")
d = ds[-1]
# 4. Woken where it slept: the last of each (the first is before its section
# had loaded at all, at the play)
tp = srv.find("Entity 8's kit/teleporter teleports kitboss")
s = list(re.finditer(r"Entity 7 sleeps at \(([-\d.]+), ([-\d.]+), ([-\d.]+)\)", srv))
w = list(re.finditer(r"Entity 7 wakes at \(([-\d.]+), ([-\d.]+), ([-\d.]+)\) after ([\d.]+) s", srv))
if not s or not w or s[-1].start() < tp or w[-1].start() < s[-1].start():
	sys.exit("no sleep and wake after the teleport")
s, w = s[-1], w[-1]
a, b = pos(s), tuple(float(v) for v in w.groups()[:3])
if max(abs(a[k] - b[k]) for k in range(3)) > 0.01:
	sys.exit(f"it slept at {a} and woke at {b}")
# No step while asleep: no way found between the two
seg = srv[s.start():w.start()]
if re.search(r"Entity 7: kit/[a-z]+'s way to", seg):
	sys.exit("it found a way while asleep")
print(f"fled {d:.1f} m from him; slept {w.group(4)} s at {a}")
PY
verdict_keep
[ "$verdict_rc" = 0 ] && echo "PASS: a creature wanders, spots, chases and hits, flees, sleeps and wakes"
verdict_exit
# vim: set noet ts=4 sw=4:
