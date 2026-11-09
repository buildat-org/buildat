#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-04)
# covers: builtin/kit/kit.cpp builtin/kit/client_lua/hands.lua builtin/kit/client_lua/module.lua builtin/kit/client_data/crack_*.png apps/workbench/**
# [KIT_DIG_LOOK] [KIT_DIG_HOLD] Digging's look and the held button, on a
# fresh Workbench save. The admin (kitboss), Stopped, in edit mode: a
# voxel type kitboss/clay (group wood: 2 s with a pickaxe, which has no
# wood speed), a spawner of players, a region (dig all), a giver of
# kit/pickaxe, and a row of three clay cells along -z in front of the
# spawn. Running (the server at --sim-rate 1: the dig's time is the
# subject), kitboss takes the pickaxe, looks along the row and holds the
# left button down once: the three cells dug one after another (the next
# asked for as the last goes, no second press), each one's crack through
# its ten frames and the pickaxe's swing cycling 8 times over its 2 s;
# a screenshot half way through a dig ($t/dig.png)
#   util/kit_dig_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
export BUILDAT_WORKBENCH_PROJECT=world
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_dig; t=$CHECK_TMP
cd "$here/Build"

start_server "$t/srv.log" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 \
	--sim-rate 1 ||
	fail "the server did not come up ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
export BUILDAT_JOIN_PASSWORD=checkpass12
ed() { printf 'event kit_edit %s\n' "$1"; }
n=0
edit() # <json>
{
	n=$((n + 1))
	ed "$1"
	printf 'wait_log 10000 entities, %d to undo\n' "$n"
}
set_() # <id> <param> <value>
{
	edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $3}"
}
# The ids: 3 the World, 4 the spawner, 5 the region, 6 the giver
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	ed '{"op": "voxel", "name": "clay", "texture": "kit/dirt.png", "group": "wood", "level": 0}'
	echo "sync 3000"
	edit '{"op": "place", "type": "kit/terrain", "pos": [0, 1, 0]}'
	edit '{"op": "place", "type": "kit/spawner", "pos": [0, 1, 0]}'
	set_ 4 players true
	edit '{"op": "place", "type": "kit/region", "pos": [-6, 0, -8]}'
	set_ 5 size '[13, 6, 15]'
	set_ 5 dig '"all"'
	edit '{"op": "place", "type": "kit/item_giver", "pos": [2, 1, 2]}'
	set_ 6 item '"kit/pickaxe"'
	for z in -2 -3 -4; do
		edit "{\"op\": \"set_voxel\", \"pos\": [0, 2, $z], \"voxel\": \"kitboss/clay\"}"
	done
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode off
event kit_use 6
wait_log 60000 kit: items: kit/pickaxe
event kit_hold kit/pickaxe
wait_log 10000 drawn in first person
look_dir 0 -0.1 -1
frames 10
wait_log_any 10000 kit: points at dig 0,2,-2
mouse_down left
wait_log 10000 kit: the crack's frame 5 at (0,2,-2)
screenshot @T@/dig.png
wait_log 20000 kit: digs on at (0,2,-3)
wait_log 20000 kit: digs on at (0,2,-4)
wait_log 20000 kit: the crack's frame 9 at (0,2,-4)
delay 1000
mouse_up left
sync 2000
quit
EOF
} | sed "s|@T@|$t|g" > "$t/boss.cmds"
wait_for_log "$t/srv.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" \
	run_client 90 "$t/boss.log" timeout 300 bin/buildat -C "$t/client_cache" \
	-D "$t/cu_boss" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
	-c @"$t/boss.cmds" ||
	fail "the client failed ($t/boss.log, $t/srv.log)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
s=$t/srv.log c=$t/boss.log
grep -a "digs \|dug " "$s" | sed 's/^.*kit *: /  /' | cut -c1-160
grep -a "kit: digging\|kit: digs on\|crack's frame [09]" "$c" |
	sed 's/^.*kit: /  /' | cut -c1-160
python3 - "$s" "$c" <<'PY' || fail "the held dig ($s, $c)"
import re, sys
srv = open(sys.argv[1], errors="replace").read()
cl = open(sys.argv[2], errors="replace").read()
dug = re.findall(r"kitboss dug kitboss/clay \(level 0\) with kit/pickaxe", srv)
assert len(dug) == 3, "dug %d of 3" % len(dug)
assert "kitboss digs kitboss/clay (wood, level 0) with kit/pickaxe: 2 s" in srv
# One press: the button went down once, the next two cells asked for by
# the hold
assert cl.count("kit: digs on at") >= 2, "no held digging"
for z in (-2, -3, -4):
	for f in range(10):
		assert "kit: the crack's frame %d at (0,2,%d)" % (f, z) in cl, (f, z)
	assert re.search(r"kit: digging \(0,2,%d\): [\d.]+ s, 8 swings" % z, cl), z
PY
echo "ok: one press held digs three cells in a row, each crack through frames 0..9, 8 swings over each 2 s dig"
[ -s "$t/dig.png" ] || fail "no screenshot ($t/dig.png)"
echo "PASS: digging: the held button digs on cell after cell, the crack and the held item's swing timed by the server's dig ($t/dig.png)"
# vim: set noet ts=4 sw=4:
