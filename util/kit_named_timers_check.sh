#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~15 s, more with a cold module cache (2026-11-06)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/api.h builtin/kit/types/timer.lua
# [KIT] stage 7b's first part, named timers and their scopes, on
# apps/sample_kit, the server's admin driving Kit's editor (one server,
# one client). The admin places a kit/timer T (id 17: every 0.5 s,
# autostart, scope per_player) and links button 3's "pressed" to its
# start. End, Run: autostart starts T's shared timer (the unnamed c:after, as
# by no player); a press (b) starts kitboss's own ("tick", {player =
# by}) beside it on the same instance, each counting its own ticks. The
# shared ticks replicated to 5, the client quits and the server stops:
# the save's runtime row holds both timers (the unnamed one and "tick"
# with kitboss's player), as game time left. Started again with no one
# on: both go on from their ticks (the shared one's 6th or more, and
# kitboss's next, as by them), the timers restored from the save.
# [KIT_AFTER_DRIFT] Two more timers start at the same Run: 18 every 0.1 s
# 300 times, 19 once after 30 s: when 19 ticks, 18 has ticked 298 to 300
# times (a chain re-armed in its on_timer keeps its period; the drift was
# a tick each, about 225).
#
#   util/kit_named_timers_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_named_timers; t=$CHECK_TMP
save="$t/user/apps/sample_kit/saves/world"
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

ed() { echo "event kit_edit $1"; }
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 10000 admin script: done
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
frames 3
wait_log_any 60000 replicated: entity 4 open = false
wait_log_any 60000 kit editor: edit rights: yes
click Button "Edit"
wait_log 10000 kit editor: state: 15 entities, 0 to undo
EOF
	n=0 ents=16
	edit() { ed "$1"; n=$((n + 1)); echo "wait_log 10000 kit editor: state: $ents entities, $n to undo"; }
	edit '{"op": "place", "type": "kit/timer", "pos": [2, 0, 2]}'
	set1() { edit "{\"op\": \"set\", \"id\": ${3:-17}, \"comp\": 0, \"param\": \"$1\", \"value\": $2}"; }
	set1 interval 0.5
	set1 autostart true
	set1 scope '"per_player"'
	edit '{"op": "link", "id": 3, "comp": 0, "output": "pressed", "to": 17, "input": "start"}'
	ents=17; edit '{"op": "place", "type": "kit/timer", "pos": [3, 0, 2]}'
	set1 interval 0.1 18; set1 repeats 300 18; set1 autostart true 18
	ents=18; edit '{"op": "place", "type": "kit/timer", "pos": [4, 0, 2]}'
	set1 interval 30 19; set1 repeats 1 19; set1 autostart true 19
	# A fresh save is Running: End, then Run, so T starts as authored
	echo 'click Button "End"'
	echo "wait_log 10000 kit editor: the server is Ended (by kitboss)"
	echo 'click Button "Run"'
	echo "wait_log 10000 kit editor: the server is Running (by kitboss)"
	echo "wait_log 10000 replicated: entity 17 ticks = 1"
	echo "keypress b"
	echo "wait_log 10000 replicated: entity 3 presses = 1"
	echo "wait_log 10000 replicated: entity 17 ticks = 5"
	# The press behind it, the rest of timer 19's 30 s of game time at the
	# rate's ceiling, its limit in the game's seconds
	echo "game_clock $t/user"
	echo "game_rate $CHECK_RATE"
	echo "wait_log_any 40000 replicated: entity 19 ticks = 1"
	echo "quit"
} > "$t/boss.cmds"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/sample_kit -D "$t/user" -l 3 --sim-rate 1 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
	run_client 60 "$t/boss.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_boss" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/boss.cmds" ||
	fail "the admin's client ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log
grep -a "kit/timer 17" "$s" | sed 's/^.*kit *: /  /' | cut -c1-150 | tail -12
grep -aq "kit/timer 17: started by kitboss every 0.5 s (theirs)" "$s" ||
	fail "kitboss's press did not start their own timer ($s)"
grep -aqE "kit/timer 17: tick 2 for kitboss" "$s" ||
	fail "kitboss's timer did not tick on its own ($s)"
grep -aqE "kit/timer 17: tick 5$" "$s" ||
	fail "the shared timer did not tick to 5 beside it ($s)"
mine=$(grep -aoP "kit/timer 17: tick \K[0-9]+(?= for kitboss)" "$s" | tail -1)
shared=$(grep -aoP "kit/timer 17: tick \K[0-9]+$" "$s" | tail -1)
python3 - "$save/save.sqlite" <<'EOF' || fail "the save's timers ($save)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
row = db.execute("select value from store where store='kit' and key='runtime'").fetchone()
rt = json.loads(row[0])
ts = rt["17"][0].get("timers", [])
print("  saved:", json.dumps(ts))
names = sorted((t.get("name"), "player" in t) for t in ts)
assert names == [("", False), ("tick", True)], names
assert all(0 <= t["s"] <= 0.5 for t in ts), ts
assert next(t for t in ts if t["name"] == "tick")["by"].startswith("player:"), ts
EOF
# The chain's ticks logged before the 30 s one's
chain=$(grep -a "kit/timer 1[89]: tick" "$s" | sed '/kit\/timer 19: tick 1$/q' |
	grep -ac "kit/timer 18: tick")
grep -aq "kit/timer 19: tick 1$" "$s" || fail "timer 19 did not tick ($s)"
[ "$chain" -ge 298 ] && [ "$chain" -le 300 ] ||
	fail "300 chained 0.1 s: $chain of them in 30 s ($s)"
echo "ok: c:after(0.1) chained: $chain in 30 s"
echo "ok: two timers on one instance, the shared and kitboss's, saved (shared at $shared, kitboss's at $mine)"

start_server "$t/srv2.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/sample_kit -D "$t/user" -l 3 ||
	fail "the server did not come up again ($t/srv2.log)"
CHECK_PIDS+=($SERVER_PID)
s=$t/srv2.log
wait_for_log "$s" "kit/timer 17: tick $((mine + 1)) for kitboss" 20 ||
	fail "kitboss's timer did not go on after the restart ($s)"
wait_for_log "$s" "kit/timer 17: tick $((shared + 1))$" 20 ||
	fail "the shared timer did not go on after the restart ($s)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
grep -a "kit/timer 17" "$s" | sed 's/^.*kit *: /  /' | cut -c1-150 | head -4
grep -aq "kit/timer 17: tick 1$" "$s" &&
	fail "the shared timer started over after the restart ($s)"
echo "PASS: named timers: kit/timer's shared and per-player timers side by side on one instance, saved as game time left and going on after a restart"
