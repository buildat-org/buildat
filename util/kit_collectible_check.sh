#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-22)
# covers: builtin/kit/types/collectible.lua builtin/kit/types/collectible.client.lua builtin/kit/client_lua/module.lua
# [KIT_COLLECTIBLE] kit/collectible, each player's own, on a fresh
# Workbench project (flat stone): kitboss (the admin) places a gem 3
# (value "gem", a long zone, its look at the far end, counted by a
# kit/counter 6), a coin 4 (value "coin", again 2 s), a plain one 7 (vanish
# none) and a kit/sign 5 their pickups go to, and makes kitbob a builder;
# both go about by Walk here's op (edit mode's):
#   1. kitboss, in play, walks (W) into 3: taken (the sign shows "gem" by
#      kitboss), on his screen at once (its client part's prediction) and
#      vanishing (a shot in it, vanish.png; before.png, gone.png);
#   2. kitbob: 3 still there for him; he takes it too (counted 2);
#   3. kitboss into 4: "coin", back for him 2 s later; into 7: gone at once
#      (no vanish drawn);
#   4. 3's reset tried by kitboss: back for him alone; as nobody: back for
#      kitbob too.
# Screenshots, kept with KEEP_TMP=1: $t/before.png, $t/vanish.png, $t/gone.png
#   util/kit_collectible_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_collectible; t=$CHECK_TMP
cd "$here/Build"
check_build
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
cmd() { printf '%s\n' "$@" >&$FD; }
ed() { local e; for e in "$@"; do cmd "event kit_edit $e" "sync 5000"; done; }
walk() # <x> <z>: the driven client's feet there, on the stone (in edit
{      # mode: its op's)
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
ed '{"op": "mode", "on": true}'
place() { ed "{\"op\": \"place\", \"type\": \"$1\", \"pos\": $2}"; }
setp() { ed "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"; }
link() { ed "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"pickup\", \"to\": $2, \"input\": \"$3\"}"; }
# 3: x 0...2, z 4...11, its look at (1, 2, 10): ahead of one walking in at z 5
place kit/collectible '[0, 0, 4]'
setp 3 value '"gem"'
setp 3 size '[3, 4, 8]'
setp 3 offset '[1, 2, 6]'
setp 3 look_size 0.4
place kit/collectible '[6, 0, 4]'
setp 4 value '"coin"'
setp 4 size '[3, 4, 3]'
setp 4 again 2
place kit/sign '[-4, 1, 8]'
setp 5 text '"{value}"'
place kit/counter '[-4, 1, 4]'
place kit/collectible '[12, 0, 4]'
setp 7 size '[3, 4, 3]'
setp 7 vanish '"none"'
link 3 5 value
link 4 5 value
link 3 6 count
await "$SL" 0 10 "An edit by kitboss: linked 3.pickup -> 6.count"
echo "ok: placed: the gem 3, the coin 4 (again 2), the sign 5, the counter 6, 7 (vanish none)"

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

# 1. kitboss walks (W, in play) into 3, looking along it; the vanish shot
# as it is drawn taken
as boss
cmd "max_fps 30"
walk 1 2
ed '{"op": "mode", "on": false}'
cmd "look 0 -5" "frames 10" "screenshot $t/before.png"
m=$(mark "$SL") mc=$(mark "$CL")
cmd "keydown w" "wait_log 10000 kit: entity 3's look: taken on" "keyup w" \
	"frames 3" "screenshot $t/vanish.png"
await "$CL" "$mc" 10 "kit: entity 3 vanished"
cmd "frames 3" "screenshot $t/gone.png"
await "$SL" "$m" 10 "kit/collectible 3: kitboss took it"
await "$SL" "$m" 10 'kit/sign 5: shows "gem" by kitboss'
await "$SL" "$m" 10 "kit/counter 6: count 1 by kitboss"
seen "$CL" "$mc" "kit: entity 3 predicted taken = true" ||
	fail "3 not hidden by its client part's prediction ($CL)"
lp=$(tail -c +$((mc + 1)) "$CL" | grep -an "kit: entity 3 predicted taken = true" | head -1 | cut -d: -f1)
lv=$(tail -c +$((mc + 1)) "$CL" | grep -an "kit: entity 3 vanished" | head -1 | cut -d: -f1)
[ "$lp" -lt "$lv" ] || fail "3 vanished before its prediction: lines $lp, $lv ($CL)"
echo "ok: kitboss took 3: the pickup's value \"gem\", hidden by the prediction, vanished"

# 2. kitbob: 3 still there for him, his own take
as bob
cmd "sync 3000"
sleep 0.5
seen "$CL" 0 "kit: entity 3's look: taken on" && fail "kitboss's take of 3 hid it for kitbob ($CL)"
m=$(mark "$SL") mc=$(mark "$CL")
walk 1 2
walk 1 5
await "$SL" "$m" 10 "kit/collectible 3: kitbob took it"
await "$SL" "$m" 10 "kit/counter 6: count 2 by kitbob"
await "$CL" "$mc" 10 "kit: entity 3's look: taken on"
echo "ok: 3 still there for kitbob after kitboss's take; his own take counted (2)"

# 3. The coin's again; 7's vanish none
as boss
m=$(mark "$SL") mc=$(mark "$CL")
walk 7 5
await "$SL" "$m" 10 "kit/collectible 4: kitboss took it"
await "$SL" "$m" 10 'kit/sign 5: shows "coin" by kitboss'
await "$CL" "$mc" 10 "kit: entity 4's look: taken on"
await "$SL" "$m" 10 "kit/collectible 4: back for kitboss"
await "$CL" "$mc" 10 "kit: entity 4's look: taken off"
python3 -I - "$SL" "$m" <<'PY' || fail "the coin's again ($SL)"
import re, sys
s = open(sys.argv[1], "rb").read()[int(sys.argv[2]):].decode(errors="replace")
def at(w):
    l = next(l for l in s.splitlines() if w in l)
    h, mi, se = re.search(r"(\d\d):(\d\d):(\d\d(?:\.\d+)?)", l).groups()
    return int(h) * 3600 + int(mi) * 60 + float(se)
d = at("kit/collectible 4: back for kitboss") - at("kit/collectible 4: kitboss took it")
assert 1.5 <= d <= 4, d
print("ok: the coin back for kitboss %.1f s after his take (again 2)" % d)
PY
mc=$(mark "$CL")
walk 13 5
await "$CL" "$mc" 10 "kit: entity 7's look: taken on"
cmd "frames 30" "sync 3000"
sleep 0.5
seen "$CL" "$mc" "kit: entity 7 vanished" && fail "7 (vanish none) drawn vanishing ($CL)"
echo "ok: 7, vanish none: gone at once"

# 4. Reset: by kitboss his own alone; as nobody everyone's
m=$(mark "$SL") mc=$(mark "$CL")
ed '{"op": "try", "id": 3, "input": "reset", "value": null}'
await "$SL" "$m" 10 "kit/collectible 3: back for kitboss"
await "$CL" "$mc" 10 "kit: entity 3's look: taken off"
seen "$SL" "$m" "kit/collectible 3: back for kitbob|kit/collectible 3: back$" &&
	fail "kitboss's reset brought 3 back for kitbob ($SL)"
as bob
mb=$(mark "$CL")
as boss
ed '{"op": "try", "id": 3, "input": "reset", "value": null, "as": "nobody"}'
await "$SL" "$m" 10 "kit/collectible 3: back$"
as bob
await "$CL" "$mb" 10 "kit: entity 3's look: taken off"
echo "ok: 3's reset by kitboss: back for him alone; as nobody: back for kitbob too"
cmd quit
as boss
cmd quit
exec 3>&- 4>&-
wait $BOSS $BOB 2>/dev/null
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
for f in before vanish gone; do
	[ -s "$t/$f.png" ] || fail "no $t/$f.png"
done
echo "PASS: kit/collectible: each player's own (one's take leaves it for the other), the pickup's value, again's return, a reset by one player and by nobody, the client's prediction and vanish; screenshots $t/before.png, $t/vanish.png, $t/gone.png"
# vim: set noet ts=4 sw=4:
