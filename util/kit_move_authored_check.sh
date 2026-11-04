#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-04)
# covers: builtin/kit/kit.cpp builtin/kit/types/flag.lua
# [KIT_CTF] What play moves (c:move) is never the composition's: a fresh
# save on Workbench, the admin places a probe P (3, a type of the check's
# own: its input "move" a c:move) at (3, 1, -8). Running:
#   1. P moved to (6, 1, -8), then one of its parameters edited (the edit
#      saves the composition), the server stopped mid-round: the saved
#      composition has P at (3, 1, -8) and the edit.
#   2. Restarted: P moved again and dragged by the editor (0, 0, 1) from
#      there: the drag's place, (6, 1, -7), is its own. Moved to
#      (9, 1, -8), Stop (it saves the composition): P at (6, 1, -7).
#   util/kit_move_authored_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_move_authored; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss
export BUILDAT_WORKBENCH_STONE=1 BUILDAT_WORKBENCH_PROJECT=world
export BUILDAT_WORKBENCH_TYPES="$t/user/apps/workbench/check_types"
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
cat > "$BUILDAT_WORKBENCH_TYPES/probe.lua" <<'EOF'
return {
	version = 1,
	params = {label = {type = "string", default = ""}},
	look = {shape = "sphere", size = 0.3, color = "#ff3030"},
	inputs = {move = "position"},
	on_input = function(c, input, v)
		c:move(v)
	end,
}
EOF

server() # <n>
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <n>: its commands in $t/boss<n>.cmds
{
	run_client 60 "$t/boss$1.log" timeout 240 bin/buildat \
		-C "$t/client_cache" -D "$t/cu" -s localhost:$SERVER_PORT \
		-w 1024x700 -l 3 -c @"$t/boss$1.cmds" ||
		fail "the client failed ($t/boss$1.log, $t/srv$1.log)"
}
stop()
{
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
ed() { printf 'event kit_edit %s\n' "$1"; }
edit() # <json> <undo count after>
{
	ed "$1"
	printf 'wait_log 10000 entities, %d to undo\n' "$2"
}
move() # <pos>
{
	ed "{\"op\": \"try\", \"id\": 3, \"comp\": 0, \"input\": \"move\", \"value\": $1}"
	echo "wait_log 10000 kit editor: tried 3's move:"
}
joined()
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: edit mode on
EOF
}
authored() # <want x,y,z> <want label>: P's in the save
{
	local db
	db=$(find "$t/user" -name save.sqlite -path "*/saves/world/*" | head -1)
	[ -n "$db" ] || fail "no save.sqlite under $t/user"
	python3 - "$db" "$1" "$2" <<'PY' || fail "P's authored row ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
v = db.execute("select value from store where store='kit' and key='authored'").fetchone()[0]
p = {e["id"]: e for e in json.loads(v)["entities"]}[3]
pos = ",".join("%g" % x for x in p["pos"])
label = p["components"][0]["params"].get("label")
print("  authored P: (%s), label %r" % (pos, label))
assert pos == sys.argv[2], "P at (%s), not (%s)" % (pos, sys.argv[2])
assert label == sys.argv[3], "label %r" % label
PY
}

# 1. Moved, edited, the server stopped mid-round
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
EOF
	joined
	edit '{"op": "place", "type": "workbench/probe", "pos": [3, 1, -8]}' 1
	move '[6, 1, -8]'
	edit '{"op": "set", "id": 3, "comp": 0, "param": "label", "value": "edited"}' 2
	echo "sync 3000"
	echo quit
} > "$t/boss1.cmds"
export BUILDAT_JOIN_CREATE=1
server 1
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
export BUILDAT_JOIN_CODE=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$BUILDAT_JOIN_CODE" ] || fail "no setup code ($t/srv1.log)"
client 1
stop
grep -aqF "Entity 3's workbench/probe moves to (6, 1, -8)" "$t/srv1.log" ||
	fail "P did not move ($t/srv1.log)"
authored 3,1,-8 edited
echo "ok: a moved entity's edit and a stop mid-round keep its authored place"

# 2. Restarted: moved, dragged; moved again, Stop
{
	joined
	move '[6, 1, -8]'
	edit '{"op": "move", "ids": [3], "by": [0, 0, 1]}' 1
	move '[9, 1, -8]'
	ed '{"op": "stop"}'
	echo "wait_log 10000 kit editor: the server is Ended (by kitboss)"
	echo "sync 3000"
	echo quit
} > "$t/boss2.cmds"
BUILDAT_JOIN_CREATE=
server 2
client 2
stop
want=("moves to (6, 1, -8)" "moves to (9, 1, -8)" "Stop by kitboss")
for w in "${want[@]}"; do
	grep -aqF "$w" "$t/srv2.log" || fail "no \"$w\" ($t/srv2.log)"
done
authored 6,1,-7 edited
echo "PASS: [KIT_CTF] c:move's place is never saved as the composition's (an edit, a stop mid-round, Stop); an editor's drag of a moved entity is"
