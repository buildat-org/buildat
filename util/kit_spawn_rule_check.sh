#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-09)
# covers: builtin/kit/kit.cpp builtin/kit/types/spawn_rule.lua builtin/kit/types/creature.prefab.json builtin/kit/box/box.c builtin/kit/api.h
# [KIT_SPAWN_RULE] kit/spawn_rule on a fresh Workbench save composed by the
# editor's ops, an infinite flat World (stone on top), peaceful: kitbob at the spawn (0, 0)
# and kitboss 300 m off. Played with the rule disabled: nothing; enabled on a
# voxel the ground is not, and with a light range the open ground is out of:
# no spot; then on the ground's voxel: copies near each player, within the
# radius of one, none closer than `apart` to another, never more live than
# `max`. kitboss on to 600 m: his copies taken away (no player within
# `despawn`), the cap filled again.
#   util/kit_spawn_rule_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_spawn_rule; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_JOIN_PASSWORD=checkpass12
start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
mkfifo "$t/cmd" "$t/cmd_bob"
sleep 900 > "$t/cmd" &
CHECK_PIDS+=($!)
sleep 900 > "$t/cmd_bob" &
CHECK_PIDS+=($!)
check_build
# (not run_client: a job in the background reads /dev/null unless told)
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
	timeout 600 bin/buildat -C "$t/client_cache" -D "$t/cu_boss" \
	-s localhost:$SERVER_PORT -w 1024x700 -l 3 -c - < "$t/cmd" > "$t/boss.log" 2>&1 &
CLIENT=$!
CHECK_PIDS+=($CLIENT)
exec 3> "$t/cmd"
cmd() { printf '%s\n' "$@" >&3; }
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
step() # <seconds> <regex in the client's log> <command>...
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
srv() { await "$t/srv.log" "$SM" "$1" "$2"; }
srv_mark() { SM=$(mark "$t/srv.log"); }
srv_mark
await "$t/boss.log" 0 120 "Joined as kitboss"
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$t/boss.log" 0 60 "player physics enabled"
await "$t/boss.log" 0 20 "kit editor: edit rights: yes"
step 10 "kit editor: edit mode on" 'event kit_edit {"op": "mode", "on": true}'
step 10 "the server is Ended" 'event kit_edit {"op": "stop"}'
# 3 world, 4 the players' spawner, 5 the rules, 6 the spawn rule
ed '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
set_ 3 0 size '"infinite"'
set_ 3 0 generator '"flat"'
set_ 3 0 decorations false
ed '{"op": "place", "type": "kit/spawner", "pos": [0, 1, 0]}'
set_ 4 0 players true
ed '{"op": "place", "type": "kit/game_rules", "pos": [0, 1, 0]}'
set_ 5 0 peaceful true
ed '{"op": "place", "type": "kit/spawn_rule", "pos": [0, 1, 0]}'
set_ 6 0 enabled false
set_ 6 0 every 1
set_ 6 0 max 3
set_ 6 0 radius 16
set_ 6 0 apart 8
set_ 6 0 on '"kit/sand"'
srv_mark
step 15 "the server is Running" 'event kit_edit {"op": "play"}'
# kitbob at the spawn; kitboss 300 m off
BUILDAT_JOIN_NAME=kitbob BUILDAT_JOIN_CREATE=1 timeout 600 bin/buildat \
	-C "$t/client_cache_bob" -D "$t/cu_bob" -s localhost:$SERVER_PORT \
	-w 640x480 -l 3 -c - < "$t/cmd_bob" > "$t/bob.log" 2>&1 &
CHECK_PIDS+=($!)
exec 4> "$t/cmd_bob"
srv 120 "kitbob put at"
step 10 "the server put the player at \(300" 'event kit_edit {"op": "walk_here", "pos": [300, 3, 0]}'
srv 10 "kitboss put at \(300"
# Disabled: no tick makes anything; enabled on sand, then with a light
# range: no spot
srv_mark
try 6 enable
srv 10 "kit/spawn_rule 6: finds no spot"
srv_mark
set_ 6 0 on '"kit/grass, kit/stone"'
set_ 6 0 light_max 7
srv 10 "kit/spawn_rule 6: finds no spot"
# On the ground's voxel: made, up to the cap
srv_mark
set_ 6 0 light_max 15
srv 20 "kit/spawn_rule 6: made [0-9]+ at .*, 3 live"
# kitboss on to 600 m: his taken away, the cap's room made use of again
# (by whichever player has a spot first: the cap is the rule's, not each's)
srv_mark
step 10 "the server put the player at \(600" 'event kit_edit {"op": "walk_here", "pos": [600, 3, 0]}'
srv 20 "kit/spawn_rule 6: took away [0-9]+ far from every player"
srv 20 "kit/spawn_rule 6: made [0-9]+ at .*, 3 live"
printf 'quit\n' >&4
exec 4>&-
cmd quit
exec 3>&-
wait $CLIENT 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 -I - "$t" <<'PY' || fail "the logs say otherwise ($t)"
import re, sys
t = sys.argv[1]
srv = open(f"{t}/srv.log", errors="replace").read()
made = [(float(m[1]), float(m[2]), float(m[3]), int(m[4]), m.start()) for m in
	re.finditer(r"kit/spawn_rule 6: made \d+ at \(([-\d.]+), ([-\d.]+), ([-\d.]+)\), (\d+) live", srv)]
assert made, "nothing made"
en = srv.find("kit/spawn_rule 6: enabled by")
assert en >= 0 and made[0][4] > en, "made before it was enabled"
# Never past the cap
assert max(m[3] for m in made) <= 3, [m[3] for m in made]
# Each within the radius of a player: kitbob at (0, 0), kitboss at 300 then 600
far = srv.find("took away")
def near(m):
	ps = [(0, 0), (300, 0)] if m[4] < far else [(0, 0), (600, 0)]
	return min(((m[0] - x) ** 2 + (m[2] - z) ** 2) ** 0.5 for x, z in ps) <= 16.5
assert all(near(m) for m in made), made
first = [m for m in made if m[4] < far]
assert any(m[0] < 100 for m in first) and any(m[0] > 200 for m in first), \
	("not near each player", first)
# Apart: the live ones before the taking away 8 m from each other (the
# first three, none gone yet)
for i, a in enumerate(first[:3]):
	for b in first[i + 1:3]:
		d = ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2) ** 0.5
		assert d >= 8, (a, b, d)
print("made", len(made), "at", [(m[0], m[2]) for m in made])
PY
verdict_keep
[ "$verdict_rc" = 0 ] && echo "PASS: a spawn rule makes copies by its rules around each player, capped"
verdict_exit
# vim: set noet ts=4 sw=4:
