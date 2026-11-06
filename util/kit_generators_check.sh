#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-03)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/types/lights_out.lua builtin/kit/types/lights_out_tile.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua apps/sample_kit/main/kit/gen_*.lua
# [KIT_GENERATORS] (kit_plan 4q) Generators, in apps/sample_kit; kitboss
# builds in Kit's editor, Ended:
#   1. A kit/lights_out L (17) placed at (0, 1, -3): its build, 25 tiles
#      (18...42) under it. Tile 18's lit set (an override), a kit/sign 43
#      put under L by hand. L's size 6: 36 tiles, the 25 kept (18 still
#      lit), 11 new; 7: 49; undone: the 36 back, the 13 gone; 5: the 25,
#      11 gone, 43 still under L. 18's lit set back to false.
#   2. sample_kit/gen_many (70 children) refused at the cap;
#      sample_kit/gen_runaway's build cut by the meter, refused; neither
#      placed. A builder's builds are rate-limited: right after the
#      runaway's a build is refused ("built too often"), and runs again a
#      few seconds later (the runaway's again, cut by the meter).
#   3. A kit/spawner (68) copying L. Run: the board's middle lit as a
#      plus (5); the corner tile 18 pressed (it and its two neighbours:
#      8), again (5), the middle 30 (0): "solved". The spawner tried: a
#      copy of L and what is under it (69...95).
#   4. A restart: the save has L and its 25 tiles as built, 43 under L,
#      18's override; no build runs as it loads.
#
#   util/kit_generators_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_generators; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_NAME=kitboss

server() # <n>
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/sample_kit -D "$t/user" -C "$t/cache" \
		-l 3 --sim-rate "$CHECK_RATE" ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <name>: its commands in $t/<name>.cmds
{
	run_client 60 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" || fail "client $1 failed ($t/$1.log, $t/srv*.log)"
}
stop()
{
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
n=0 c=15
edit() # <json> <entities after>
{
	n=$((n + 1)) c=$2
	printf 'event kit_edit %s\nwait_log 10000 kit editor: state: %d entities, %d to undo\n' \
		"$1" "$c" "$n"
}
refused() # <json> <reason>
{
	printf 'event kit_edit %s\nwait_log 30000 kit editor: refused: %s\n' "$1" "$2"
}
size() { edit "{\"op\": \"set\", \"id\": 17, \"comp\": 0, \"param\": \"size\", \"value\": $1}" "$2"; }
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 10000 admin script: done
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
frames 3
wait_log_any 60000 kit editor: edit rights: yes
click Button "Edit"
wait_log 10000 kit editor: state: 15 entities, 0 to undo
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	edit '{"op": "place", "type": "kit/lights_out", "pos": [0, 1, -3]}' 41
	edit '{"op": "set", "id": 18, "comp": 0, "param": "lit", "value": true}' 41
	edit '{"op": "place", "type": "kit/sign", "pos": [4, 1, -3], "parent": 17}' 42
	size 6 53
	size 7 66
	echo 'event kit_edit {"op": "undo"}'
	n=$((n - 1)) c=53
	printf 'wait_log 10000 kit editor: state: %d entities, %d to undo\n' $c $n
	size 5 42
	edit '{"op": "set", "id": 18, "comp": 0, "param": "lit", "value": false}' 42
	refused '{"op": "place", "type": "sample_kit/gen_many", "pos": [10, 1, 10]}' \
		"place: entity 68's sample_kit/gen_many: on_build: "
	refused '{"op": "place", "type": "sample_kit/gen_runaway", "pos": [10, 1, 12]}' \
		"place: entity 68's sample_kit/gen_runaway: on_build ran past its budget"
	refused '{"op": "place", "type": "sample_kit/gen_runaway", "pos": [10, 1, 12]}' \
		"place: generators built too often: again in "
	echo "delay 6000"
	refused '{"op": "place", "type": "sample_kit/gen_runaway", "pos": [10, 1, 12]}' \
		"place: entity 68's sample_kit/gen_runaway: on_build ran past its budget"
	# 68: a kit/spawner copying L (with its board)
	edit '{"op": "place", "type": "kit/spawner", "pos": [8, 1, -3]}' 43
	edit '{"op": "set", "id": 68, "comp": 0, "param": "copy", "value": 17}' 43
	cat <<'EOF'
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
wait_log_any 10000 replicated: entity 17 lit = 5
event kit_use 18
wait_log 10000 replicated: entity 17 lit = 8
event kit_use 18
wait_log 10000 replicated: entity 17 lit = 5
event kit_use 30
wait_log 10000 replicated: entity 17 lit = 0
event kit_edit {"op": "try", "id": 68, "input": "spawn"}
sync 5000
quit
EOF
} > "$t/boss1.cmds"
server 1
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss1
stop
s=$t/srv1.log
grep -a "An edit by\|An undo by\|build refused\|kit/lights_out 17: \(built\|solved\)" "$s" |
	sed 's/^.* I [a-z_]* *: /  /' | cut -c1-170
want "$s" "placed kit/lights_out 17 at [0,1,-3], built 17 again: 25 children (0 kept, 25 new, 0 gone)" \
	"kit/lights_out 17: built 5x5 5 lit" \
	"set 17's kit/lights_out size to 6, built 17 again: 36 children (25 kept, 11 new, 0 gone, 1 overrides kept)" \
	"set 17's kit/lights_out size to 7, built 17 again: 49 children (36 kept, 13 new, 0 gone, 1 overrides kept)" \
	"An undo by kitboss: 50 entities put back" \
	"set 17's kit/lights_out size to 5, built 17 again: 25 children (25 kept, 0 new, 11 gone, 1 overrides kept)"
echo "ok: placed, it builds its board under it; a size change builds it again (kept, new, gone), a tile's override kept; an undo puts the old children back"
want "$t/boss1.log" "kit editor: refused: place: entity 68's sample_kit/gen_many: on_build: sample_kit/gen_many:8: child: 63 a build at most" \
	"kit editor: refused: place: entity 68's sample_kit/gen_runaway: on_build ran past its budget"
grep -aq "placed sample_kit/gen_" "$s" && fail "a refused generator was placed ($s)"
grep -ao "build refused: \(entity 68's sample_kit/gen_runaway\|generators built too often: again in [1-9] s\)" "$s" |
	sed 's/: again in .*//' | tr '\n' '|' |
	grep -qx "build refused: entity 68's sample_kit/gen_runaway|build refused: generators built too often|build refused: entity 68's sample_kit/gen_runaway|" ||
	fail "a build right after the runaway's not refused by the builder's rate, or not run again later ($s)"
want "$t/boss1.log" "kit editor: refused: place: generators built too often: again in "
echo "ok: a build past the cap is refused, a runaway build cut by the meter and refused; one right after it refused by the builder's rate, run again later"
want "$s" "kit/lights_out 17: lit 8" "kit/lights_out 17: solved"
[ "$(grep -ac "kit/lights_out 17: solved" "$s")" = 1 ] ||
	fail "\"solved\" not once ($s)"
echo "ok: play: a press toggles the tile and its neighbours, none lit is solved"
want "$s" "Entity 68 made a copy of entity:17: $(seq -s, 69 95) (a game change)"
echo "ok: a kit/spawner copies the generator with its board"

# 4. A restart: the output is the save's
db=$(find "$t/user" -name save.sqlite -path "*/saves/world/*" | head -1)
[ -n "$db" ] || fail "no save.sqlite under $t/user"
check_save()
{
	python3 - "$db" <<'PY' || fail "the build in the save ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
au = json.loads(db.execute("select value from store where store='kit' and key='authored'").fetchone()[0])
ents = {e["id"]: e for e in au["entities"]}
built = sorted(i for i, e in ents.items() if e.get("built", {}).get("by") == 17)
assert built == list(range(18, 43)), built
for i in built:
    e = ents[i]
    assert e["parent"] == 17 and e["components"][0]["type"] == "kit/lights_out_tile", e
    assert e["built"]["member"] == i - 17, e
assert ents[17]["components"][0]["params"]["size"] == 5, ents[17]
assert ents[43]["parent"] == 17 and "built" not in ents[43], ents[43]
c18 = ents[18]["components"][0]
assert c18["overrides"] == ["lit"] and c18["params"]["lit"] is False, c18
c30 = ents[30]["components"][0]
assert c30["params"]["lit"] is True and {"output": "pressed", "to": 25, "input": "toggle"} in c30["links"], c30
assert {"output": "changed", "to": 17, "input": "add"} in c30["links"], c30
assert ents[18]["pos"] == [-2, 0, 1] and ents[42]["pos"] == [2, 0, 5], (ents[18], ents[42])
assert not any(i in ents for i in range(44, 68)), sorted(ents)
print("  the save: 17 and its 25 tiles as built, 43 under it, 18's override")
PY
}
check_save
cat > "$t/boss2.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 kit editor: edit rights: yes
click Button "Edit"
wait_log 10000 kit editor: state: 43 entities
sync 5000
quit
EOF
server 2
BUILDAT_JOIN_CREATE= client boss2
stop
grep -aq "built 17 again" "$t/srv2.log" && fail "a build ran as the save loaded ($t/srv2.log)"
check_save
echo "ok: a restart keeps the build as it was"
echo "PASS: generators: kit/lights_out builds its board as placed and as its size changes, overrides and a builder's child kept, an undo putting the old ones back; the cap and the meter refuse a build; the board plays and is solved; the save keeps the output"
# vim: set noet ts=4 sw=4:
