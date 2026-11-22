#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2.5 min (2026-11-23)
# covers: builtin/kit/types/stopwatch.lua builtin/kit/types/records.lua builtin/kit/types/ui_text.lua builtin/kit/client_lua/ui.lua builtin/kit/client_lua/controls.lua builtin/kit/box/box.c
# [KIT_RECORDS] kit/stopwatch, kit/records and kit/ui_text's {value:time1}
# and clear_after, on a fresh Workbench project (flat stone): kitboss (the
# admin) places a stopwatch 3, records 4, a text 5 ("T {value:time1}", to
# the player) the stopwatch's time goes to, a sign 6 the records' board
# goes to, a text 7 ("N {value}", clear_after 1) its new_best goes to, a
# sign 8 the stopwatch's lap goes to and a text 9 ("B {value:time1}") its
# best goes to, a sign 10 its elapsed goes to (linked before the
# records); kitbob is a builder. Each drives inputs with the
# inspector's Try (by him):
#   1. both start theirs: each one's 5 counts on, on their own screen,
#      from the one value the server sent (one "value" each);
#   2. kitboss stops at about 1 s, kitbob later: elapsed to the records,
#      each a new best (7: "N <time>", gone a second later), the board
#      "1. kitboss|2. kitbob"; kitboss's 5 stands at his time; the
#      elapsed reaches 10 before 4 (its links' order, not by id) and 4's
#      best reaches 9 after both ([KIT_REPORT_1122]);
#   3. kitbob a quicker run: his new best, the board "1. kitbob|2.
#      kitboss"; kitboss a slower one: no new best, the board as it was;
#      (3b) clear_kept with key kitbob: the board "1. kitboss" (his best
#      alone gone), a key none has refused, undo: the board as before;
#   4. a lap (8: its seconds), the stopwatch running on; a reset by nobody:
#      everyone's at 0;
#   5. the server restarts: kitboss back, his best on 9 as it was; a
#      slower run still no new best (the bests kept);
#   6. ([KIT_REPORT_1123]) on a fresh sample_kit (it has guests; a
#      Workbench body that goes is an agent's play body, a guest's too):
#      a stopwatch, a guest's started (Try as them) beside kitboss's, the
#      guest leaves: their entry gone from the save's runs, kitboss's kept;
#   7. the save given a gone guest's, a bot's and a non-body key's entry
#      (as before 6), the server restarts: the two bodies' dropped at the
#      load, "note" and kitboss's kept; a new guest gets the gone guest's
#      id again and inherits no run (a reset by nobody resets kitboss's
#      alone).
# Screenshot, kept with KEEP_TMP=1: $t/running.png
#   util/kit_records_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_records; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_PROJECT=world BUILDAT_WORKBENCH_STONE=1
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1
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
cmd() { printf '%s\n' "$@" >&$FD; }
ed() { local e; for e in "$@"; do cmd "event kit_edit $e" "sync 5000"; done; }
SW=3
try() # <input> [as]: the stopwatch's input by the driven client (or as nobody)
{
	ed "{\"op\": \"try\", \"id\": $SW, \"input\": \"$1\", \"value\": null${2:+, \"as\": \"$2\"}}"
}
client() # <name> <log> [guest]: its commands from the fifo $t/<name>.cmd
{
	local join=(env BUILDAT_JOIN_NAME=kit$1)
	[ "${3:-}" = guest ] && join=(env -u BUILDAT_JOIN_NAME)
	rm -f "$t/$1.cmd"
	mkfifo "$t/$1.cmd"
	sleep 900 > "$t/$1.cmd" &
	CHECK_PIDS+=($!)
	"${join[@]}" timeout 300 bin/buildat -C "$t/client_cache_$1" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 -c - \
		< "$t/$1.cmd" > "$2" 2>&1 &
	CHECK_PIDS+=($!)
}
# The number in the last "<what> <n>" a log says (a ui text's, a log line's)
num() { tail -c +$(($2 + 1)) "$1" | grep -aoE "$3" | tail -1 | grep -aoE '[0-9]+\.[0-9]+$'; }
SL=$t/srv1.log
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
ed '{"op": "mode", "on": true}'
place() { ed "{\"op\": \"place\", \"type\": \"$1\", \"pos\": $2}"; }
setp() { ed "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
link() { ed "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"$2\", \"to\": $3, \"input\": \"$4\"}"; }
place kit/stopwatch '[0, 1, 0]'
place kit/records '[0, 1, 0]'
place kit/ui_text '[0, 1, 0]'
setp 5 text '"T {value:time1}"'
setp 5 to '"player"'
place kit/sign '[-4, 1, 8]'
setp 6 text '"{value}"'
place kit/ui_text '[0, 1, 0]'
setp 7 text '"N {value}"'
setp 7 to '"player"'
setp 7 y 12
setp 7 clear_after 1
place kit/sign '[4, 1, 8]'
setp 8 text '"{value}"'
place kit/ui_text '[0, 1, 0]'
setp 9 text '"B {value:time1}"'
setp 9 to '"player"'
setp 9 y 20
place kit/sign '[0, 1, 8]'
setp 10 text '"{value}"'
link 3 time 5 value
link 3 elapsed 10 value
link 3 elapsed 4 time
link 3 lap 8 value
link 4 board 6 value
link 4 new_best 7 value
link 4 best 9 value
await "$SL" 0 10 "An edit by kitboss: linked 4.best -> 9.value"
echo "ok: placed: the stopwatch 3, records 4, its texts 5, 7, 9 and signs 6, 8, 10"

client bob "$t/bob.log"
BOB=$!
exec 4> "$t/bob.cmd"
as bob
await "$CL" 0 120 "Joined as kitbob"
as boss
ed '{"op": "builder", "name": "kitbob", "on": true}'
await "$SL" 0 10 "kitboss made builder kitbob"
as bob
await "$CL" 0 30 "kit editor: edit rights: yes"
ed '{"op": "mode", "on": true}'

# 1. Both start; each one's 5 counts on from the one value
m=$(mark "$SL")
as boss
mc=$(mark "$CL")
try start
await "$SL" "$m" 10 "kit/stopwatch 3: started for kitboss"
as bob
mb=$(mark "$CL")
try start
await "$SL" "$m" 10 "kit/stopwatch 3: started for kitbob"
as boss
await "$CL" "$mc" 10 'kit: ui 5 text .*"T 1\.[0-9]"'
seen "$CL" "$mc" 'kit: ui 5 text .*"T 0\.[0-9]"' || fail "kitboss's 5 did not count up from 0 ($CL)"
cmd "frames 3" "screenshot $t/running.png"
as bob
await "$CL" "$mb" 10 'kit: ui 5 text .*"T 1\.[0-9]"'
n=$(count "$SL" "$m" "kit/ui_text 5: value for kitboss")
[ "$n" = 1 ] || fail "5 got $n values for kitboss while it ran, not 1 ($SL)"
echo "ok: both running: each one's time counted on their own screen from one value"

# 2. kitboss stops (~1.2 s), kitbob later
as boss
m=$(mark "$SL") mc=$(mark "$CL") m0=$m
try stop
await "$SL" "$m" 10 "kit/stopwatch 3: stopped for kitboss at [0-9.]+ s"
await "$SL" "$m" 10 "kit/records 4: kitboss has a new best: [0-9.]+ \(the first\)"
a=$(num "$SL" "$m" "kitboss has a new best: [0-9.]+")
await "$SL" "$m" 10 "kit/sign 6: shows \"1. kitboss $a\""
await "$CL" "$mc" 10 "kit: ui 5 text .*\"T $a\""
await "$CL" "$mc" 10 'kit: ui 7 text .*"N [0-9.]+"'
await "$CL" "$mc" 10 'kit: ui 7 text .*"N "'
python3 -I - "$CL" "$mc" <<'PY' || fail "7's clear_after ($CL)"
import re, sys
s = open(sys.argv[1], "rb").read()[int(sys.argv[2]):].decode(errors="replace")
def at(rx):
    l = next(l for l in s.splitlines() if re.search(rx, l))
    h, mi, se = re.search(r"(\d\d):(\d\d):(\d\d(?:\.\d+)?)", l).groups()
    return int(h) * 3600 + int(mi) * 60 + float(se)
d = at(r'kit: ui 7 text .*"N "$') - at(r'kit: ui 7 text .*"N [0-9.]+"$')
assert 0.8 <= d <= 2, d
print("ok: kitboss's new best on 7 cleared %.2f s after it came (clear_after 1)" % d)
PY
cmd "frames 10" "sync 2000"
sleep 0.5
tail -c +$((mc + 1)) "$CL" | grep -a "kit: ui 5 text" | tail -1 | grep -qaF "\"T $a\"" ||
	fail "kitboss's 5 not standing at $a after the stop ($CL)"
as bob
m=$(mark "$SL")
await "$CL" "$mb" 10 'kit: ui 5 text .*"T 2\.[0-9]"'
try stop
await "$SL" "$m" 10 "kit/records 4: kitbob has a new best: [0-9.]+ \(the first\)"
b=$(num "$SL" "$m" "kitbob has a new best: [0-9.]+")
await "$SL" "$m" 10 "kit/sign 6: shows \"1. kitboss $a.2. kitbob $b\""
# [KIT_REPORT_1122] One output's links in their order (10 linked before
# 4, so not by id), what they set off after both (4's best to 9)
python3 -I - "$SL" "$m0" <<'PY' || fail "the elapsed's links not delivered in their order ($SL)"
import sys
s = open(sys.argv[1], "rb").read()[int(sys.argv[2]):].decode(errors="replace")
at = [s.find(k) for k in ("kit/sign 10: shows", "kit/records 4: kitboss has a new best",
    "kit/ui_text 9: value for kitboss")]
print("the elapsed's runs at %s" % at)
assert -1 not in at and at == sorted(at), at
PY
echo "ok: stopped: kitboss $a, kitbob $b, each a first best; the board 1. kitboss|2. kitbob; the elapsed to 10 then 4 (its links' order), 4's best to 9 after"

# 3. kitbob quicker: his new best and the board turned; kitboss slower: none
m=$(mark "$SL")
try start
try stop
await "$SL" "$m" 10 "kit/records 4: kitbob has a new best: [0-9.]+ \(was $b\)"
b=$(num "$SL" "$m" "kitbob has a new best: [0-9.]+")
await "$SL" "$m" 10 "kit/sign 6: shows \"1. kitbob $b.2. kitboss $a\""
as boss
m=$(mark "$SL") mc=$(mark "$CL")
try start
await "$CL" "$mc" 10 'kit: ui 5 text .*"T 2\.[0-9]"'
try stop
await "$SL" "$m" 10 "kit/stopwatch 3: stopped for kitboss"
cmd "sync 2000"
seen "$SL" "$m" "kitboss has a new best" && fail "kitboss's slower run a new best ($SL)"
seen "$SL" "$m" "kit/sign 6: shows" && fail "the board changed for a slower run ($SL)"
echo "ok: kitbob's quicker run his new best ($b), the board 1. kitbob|2. kitboss; kitboss's slower run none"

# 3b. [KIT_REPORT_1122B] clear_kept of one key: only kitbob's best gone
# (the board, made from bests, within its second), undo brings it back,
# a key no kept table has refused
m=$(mark "$SL")
ed '{"op": "clear_kept", "id": 4, "comp": 0, "key": "kitbob"}'
await "$SL" "$m" 5 "kit/records: its kept state entry kitbob cleared by kitboss"
await "$SL" "$m" 10 "kit/sign 6: shows \"1. kitboss $a\""
seen "$SL" "$m" "kit/sign 6: shows \"\"" && fail "clear_kept with a key cleared the whole board ($SL)"
m=$(mark "$SL")
ed '{"op": "clear_kept", "id": 4, "comp": 0, "key": "nobody"}'
await "$SL" "$m" 5 "An edit \(clear_kept\) by peer [0-9]+ refused: no kept entry nobody in kit/records"
ed '{"op": "undo"}'
await "$SL" "$m" 5 "kit/records: its kept state put back by kitboss's undo"
await "$SL" "$m" 10 "kit/sign 6: shows \"1. kitbob $b.2. kitboss $a\""
echo "ok: clear_kept key kitbob took only his best (the board 1. kitboss), undo put it back, an unknown key refused"

# 4. A lap, running on; a reset by nobody: everyone's
m=$(mark "$SL") mc=$(mark "$CL")
try start
await "$CL" "$mc" 10 'kit: ui 5 text .*"T 1\.[0-9]"'
try lap
await "$SL" "$m" 10 "kit/stopwatch 3: lap for kitboss [0-9.]+ s"
await "$SL" "$m" 10 'kit/sign 8: shows "(0\.[5-9]|[1-9]\.)'
l=$(num "$SL" "$m" "lap for kitboss [0-9.]+")
ml=$(mark "$CL")
cmd "sync 2000"
await "$CL" "$ml" 10 'kit: ui 5 text .*"T [0-9]+\.[0-9]"'
seen "$SL" "$m" "stopped for kitboss" && fail "the lap stopped it ($SL)"
as bob
mb=$(mark "$CL")
try start
await "$SL" "$m" 10 "kit/stopwatch 3: started for kitbob"
await "$CL" "$mb" 10 'kit: ui 5 text .*"T 1\.[0-9]"'
mb=$(mark "$CL")
as boss
mc=$(mark "$CL")
try reset nobody
await "$SL" "$m" 10 "kit/stopwatch 3: reset for kitboss"
await "$SL" "$m" 10 "kit/stopwatch 3: reset for kitbob"
await "$CL" "$mc" 10 'kit: ui 5 text .*"T 0\.0"'
as bob
await "$CL" "$mb" 10 'kit: ui 5 text .*"T 0\.0"'
echo "ok: a lap sent its seconds ($l), the stopwatch running on; a reset by nobody put both at 0"

# 5. The server restarts: the bests kept
as boss
cmd quit
as bob
cmd quit
exec 3>&- 4>&-
wait $BOSS $BOB 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
SL=$t/srv2.log
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
	fail "the server did not come up again ($SL)"
CHECK_PIDS+=($SERVER_PID)
client boss "$t/boss2.log"
BOSS=$!
exec 3> "$t/boss.cmd"
as boss
CL=$t/boss2.log
await "$CL" 0 120 "Joined as kitboss"
await "$CL" 0 60 "kit editor: edit rights: yes"
await "$CL" 0 30 "kit: ui 9 text .*\"B $a\""
ed '{"op": "mode", "on": true}'
m=$(mark "$SL")
try start
await "$CL" 0 10 'kit: ui 5 text .*"T 2\.[0-9]"'
try stop
await "$SL" "$m" 10 "kit/stopwatch 3: stopped for kitboss"
cmd "sync 2000"
seen "$SL" "$m" "kitboss has a new best" && fail "a slower run a new best after the restart: the bests lost ($SL)"
echo "ok: after a restart kitboss's best ($a) back on 9, a slower run no new best"

# 6. [KIT_REPORT_1123] A body that goes: a guest's (Workbench has none but
# its agents' play bodies, the same drop): on sample_kit, a fresh save
cmd quit
exec 3>&-
wait $BOSS 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
db=$t/sk/apps/sample_kit/saves/world/save.sqlite
runs() # [<json entries to add>]: the save's stopwatch runs' keys (adds first)
{
	python3 -I - "$db" "$SW" "${1:-}" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1], timeout=10)
v = db.execute("select value from store where store = 'kit' and key = 'runtime'").fetchone()[0]
rt = json.loads(v if isinstance(v, str) else v.decode())
st = rt[sys.argv[2]][0]["state"]
if not isinstance(st.get("runs"), dict):
    st["runs"] = {}
if sys.argv[3]:
    st["runs"].update(json.loads(sys.argv[3]))
    s = json.dumps(rt)
    db.execute("update store set value = ? where store = 'kit' and key = 'runtime'",
        (s if isinstance(v, str) else s.encode(),))
    db.commit()
print(" ".join(sorted(st["runs"])))
PY
}
sk() # <log>: the sample_kit server
{
	SL=$1
	start_server "$SL" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/sample_kit -D "$t/sk" -l 3 ||
		fail "sample_kit did not come up ($SL)"
	CHECK_PIDS+=($SERVER_PID)
	CLIENT=$SERVER_PID
}
skboss() # <log> [code]: kitboss on it (the admin by the code), in edit mode
{
	if [ -n "${2:-}" ]; then
		BUILDAT_JOIN_CODE=$2 BUILDAT_JOIN_ADMIN="setting open_registration on" client boss "$1"
	else
		client boss "$1"
	fi
	BOSS=$!
	exec 3> "$t/boss.cmd"
	as boss
	CL=$1
	await "$CL" 0 120 "Joined as kitboss"
	[ -n "${2:-}" ] && cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
	await "$CL" 0 60 "kit editor: edit rights: yes"
	ed '{"op": "mode", "on": true}'
}
sk "$t/sk1.log"
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
skboss "$t/sk_boss1.log" "$code"
bid=$(grep -aoP 'kitboss is entity \K[0-9]+' "$SL" | head -1)
m=$(mark "$SL")
place kit/stopwatch '[0, 1, 0]'
await "$SL" "$m" 10 "placed kit/stopwatch [0-9]+"
SW=$(tail -c +$((m + 1)) "$SL" | grep -aoP 'placed kit/stopwatch \K[0-9]+' | head -1)
m=$(mark "$SL")
client g1 "$t/g1.log" guest
G1=$!
exec 5> "$t/g1.cmd"
await "$SL" "$m" 120 "p[0-9]+ is entity [0-9]+"
read -r gn gid < <(tail -c +$((m + 1)) "$SL" | grep -aoE "p[0-9]+ is entity [0-9]+" | head -1 | sed 's/ is entity / /')
try start
try start "$gn"
await "$SL" "$m" 10 "kit/stopwatch $SW: started for $gn"
await "$SL" "$m" 10 "kit/stopwatch $SW: started for kitboss"
cmd "sync 2000"
k=$(runs)
[ "$k" = "player:$bid player:$gid" ] || fail "the runs before $gn leaves: \"$k\" ($SL)"
printf 'quit\n' >&5
exec 5>&-
wait $G1 2>/dev/null
await "$SL" "$m" 30 "Guest $gn's entity $gid dropped"
k=$(runs)
[ "$k" = "player:$bid" ] || fail "the runs after $gn left: \"$k\", not kitboss's alone ($SL)"
echo "ok: guest $gn (entity $gid) ran stopwatch $SW and left: their entry gone with them, kitboss's ($bid) kept"

# 7. A gone body's entries in the save (as before 6): dropped at the load;
# the id handed out again (the next player's: one past the bodies kept)
# inherits nothing
cmd quit
exec 3>&-
wait $BOSS 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
k=$(runs "{\"player:$gid\": {\"from\": 0, \"lap\": 0}, \"bot:99999\": {\"from\": 0, \"lap\": 0}, \"note\": {\"at\": 1}}")
[ "$k" = "bot:99999 note player:$bid player:$gid" ] || fail "the save's runs not as written: \"$k\""
sk "$t/sk2.log"
await "$SL" 0 10 "per_player state: 2 entries of bodies not here dropped"
# (the first body made: kitboss's client is a guest too until it logs in)
client g2 "$t/g2.log" guest
G2=$!
exec 5> "$t/g2.cmd"
await "$SL" 0 120 "p[0-9]+ is entity [0-9]+"
read -r gn2 gid2 < <(grep -aoE "p[0-9]+ is entity [0-9]+" "$SL" | head -1 | sed 's/ is entity / /')
[ "$gid2" = "$gid" ] || fail "the new guest $gn2 is entity $gid2, not $gid again ($SL)"
k=$(runs)
[ "$k" = "note player:$bid" ] || fail "the runs after the load: \"$k\", not note and kitboss's ($SL)"
skboss "$t/sk_boss2.log"
m=$(mark "$SL")
try reset nobody
await "$SL" "$m" 10 "kit/stopwatch $SW: reset for kitboss"
cmd "sync 2000"
seen "$SL" "$m" "kit/stopwatch $SW: reset for $gn2" && fail "the new guest $gn2 (entity $gid again) inherited a run ($SL)"
echo "ok: the load dropped the gone guest's and the bot's entries, note and kitboss's kept; $gn2 is entity $gid again with no run"
printf 'quit\n' >&5
exec 5>&-
cmd quit
exec 3>&-
wait $BOSS $G2 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
[ -s "$t/running.png" ] || fail "no $t/running.png"
echo "PASS: kit/stopwatch, kit/records, {value:time1} and clear_after: two players' own times counted on their screens from one value each, elapsed to the records, new bests and the board's order, one best cleared by key and undone, a lap, a reset by nobody, the bests kept over a restart, a gone guest's and bot's runs dropped as they leave and at a load (a reused id inherits none); screenshot $t/running.png"
# vim: set noet ts=4 sw=4:
