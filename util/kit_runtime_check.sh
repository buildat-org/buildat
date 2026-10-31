#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-10-30)
# covers: builtin/kit/** apps/sample_kit/** src/wasm/engine.cpp src/server/wasm_module.cpp util/prebuild_wasm.py
# [KIT] stage 2, Kit's runtime, on apps/sample_kit and a scripted client:
#   1. The wiring fires: a client uses the button, which opens the door
#      (its voxel air, its shared "open" replicated to the client), and
#      the door's move reaches the counter, `by` the player all the way.
#   2. Clients act, components react: a use out of range, a use of an
#      entity with nothing usable on it and packets that name a signal are
#      refused or go nowhere; a dig at the door is routed to it, which
#      keeps its voxel.
#   3. The budget: the runaway component is stopped and disabled, and the
#      button and the door go on; the relays' loop is cut and named; a
#      Lua error is logged and the box goes on.
#   4. A restart: the counter's count, the door's state and the runaway's
#      disablement are the save's runtime row, apart from its authored row;
#      the rows made as a save from before types had authors (bare names)
#      are read as sample_kit's types and written back <author>/<name>;
#      ([KIT] stage 4c) a kit/door of voxels it owned (the first slice's)
#      is made an object, its voxels' parameters dropped. A fresh save is
#      Running. The pouch's loop (an item giver giving "spin") disables
#      the pouch, not the giver, and Kit's own counts take over.
#   6. ([KIT] stage 4b) Types by author: sample_kit/door and kit/door in
#      one palette and save; sample_kit's pouch provides the players'
#      inventory (a second pouch refused): kit/item_giver fills it to its
#      capacity, kit/key_door refuses one without the key and opens
#      taking it.
#   7. ([KIT] stage 4d) A spawner added to the save makes a copy of the
#      kit/button_door prefab when a button signals it: the copy's button
#      opens the copy's door (its link remapped), and the copy, play state,
#      is in the runtime row and back after the next restart.
# The first run is the box in WAMR's interpreter alone; the second waits
# for the compiled module (wasm2c's), and has a Lua error and a second
# runaway there.
#   5. The box prebuilt as util/package.sh puts it into an archive's cache
#      (util/prebuild_wasm.py, meta.json's "wasm_box"), named as the
#      server names it; a server with no wasm toolchain runs Kit on it.
# With `local`: sample_kit's server in the page (?local=sample_kit,
# util/build_web_server.sh sample_kit, the box built by
# util/web_server.cmake) in headless Chrome: the button opens the door,
# the runaway is stopped on the browser's wasm, and the button closes it.
#
#   util/kit_runtime_check.sh
#   util/kit_runtime_check.sh local
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = local ]; then
	[ -f "$here/web/local/sample_kit/buildat_server.wasm" ] ||
		skip "no web/local/sample_kit (util/build_web_server.sh sample_kit)"
	check_tmp kit_local; t=$CHECK_TMP
	export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9
	# apps/play serves the page, isolated for ?local, and web/local/
	cd "$here/Build"
	BUILDAT_LUANTI_LIST=http://127.0.0.1:9 start_server "$t/play.log" \
			"STATUS Listening" 120 auto bin/buildat_server -m ../apps/play \
			-D "$t/play" -C "$t/play.cache" -W "$here/web" -l 3 ||
		fail "the page's server ($t/play.log)"
	CHECK_PIDS+=($SERVER_PID)
	cat > "$t/steps.json" <<'EOF'
[
	["nav", "${URL}"],
	["waitlog", "local: asking the player's name", 60], ["type", "tester"], ["key", "Enter"],
	["waitlog", "replicated: entity 4 open = false", 120],
	["eval", "'isolated ' + crossOriginIsolated"],
	["key", "b"],
	["waitlog", "replicated: entity 4 open = true", 30],
	["key", "r"],
	["waitlog", "server: .*Entity 7's sample_kit/runaway disabled", 30],
	["key", "b"],
	["waitlog", "replicated: entity 4 open = false", 30]
]
EOF
	WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/?local=sample_kit" \
		"$here/util/web_drive.sh" chrome sample_kit "$t/steps.json" "$t/local" > "$t/drive.log" 2>&1 ||
		{ tail -20 "$t/drive.log"; fail "the drive failed ($t/local)"; }
	page=$t/local/page.log
	grep -a "eval:" "$t/drive.log" | cut -c 1-200
	grep -a "server: .*\(wasm kit\| kit \| main \)" "$page" |
		sed 's/.*server: *//' | cut -c1-140
	grep -q "isolated true" "$t/drive.log" || fail "the page was not cross-origin isolated"
	for want in "server: .*kit: box/ is built with this server" \
			"server: .*sample_kit: at start the counter is 0, the door open false" \
			"server: .*sample_kit/button 3: pressed by tester" \
			"server: .*sample_kit/door 4: opened by tester" \
			"server: .*Entity 7's sample_kit/runaway disabled: on_use ran past its budget" \
			"server: .*sample_kit/door 4: closed by tester"; do
		grep -aq "$want" "$page" || fail "no \"$want\" in $page"
	done
	echo "PASS: sample_kit with its server in the page: the box built with the server, the wiring and the meter on the browser's wasm"
	exit 0
fi
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_runtime; t=$CHECK_TMP
save="$BUILDAT_USER_PATH/apps/sample_kit/saves/world"
rm -rf "$save"
cd "$here/Build"

# One server and one client: the client's commands in $t/<n>.cmds
run() # <n> [env...]
{
	local n=$1
	shift
	start_server "$t/srv$n.log" "Listening at" 300 auto env "$@" \
		bin/buildat_server -m ../apps/sample_kit -l 3 ||
		fail "the server did not come up ($t/srv$n.log)"
	CHECK_PIDS+=($SERVER_PID)
	if [ $# = 0 ]; then
		wait_for_log "$t/srv$n.log" "wasm kit: (moved to the compiled module|compiled module from the cache|ready \\(compiled\\))" 300 ||
			fail "the box was not compiled ($t/srv$n.log)"
	fi
	set -- "$n"
	run_client 60 "$t/cli$1.log" timeout 120 bin/buildat -C "$t/client_cache" \
		-s localhost:$SERVER_PORT -w 320x240 -l 3 -c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/cli$1.log, $t/srv$1.log)"
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	grep -a " kit \| main \| wasm kit" "$t/srv$1.log" |
		sed 's/^.*\(kit\|main\) *: /  /' | cut -c1-140
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}

# Every key's work is seen by the client before the next: the door's
# replicated state after b, and after the rest, which the server takes
# in order, b again
cat > "$t/1.cmds" <<'EOF'
wait_log 60000 replicated: entity 4 open = false
keypress b
wait_log 30000 replicated: entity 4 open = true
keypress f
frames 2
keypress c
frames 2
keypress s
wait_log 10000 sent the signal packets
keypress e
frames 2
keypress r
frames 2
keypress d
frames 2
event kit_use 16
frames 2
event kit_use 15
wait_log 10000 kit: items: key x1
event kit_use 15
frames 2
event kit_use 16
frames 2
keypress b
wait_log 60000 replicated: entity 4 open = false
quit
EOF
run 1 BUILDAT_CHECK_WASM_INTERPRETER=1
s=$t/srv1.log
grep -aq "wasm kit: ready (interpreter): no C compiler" "$s" ||
	fail "run 1 is not the interpreter's ($s)"
want "$s" "sample_kit: at start the counter is 0, the door open false" \
	"Entity 3 used by p" "sample_kit/button 3: pressed by p" \
	"sample_kit/door 4: opened by p" "sample_kit/counter 5: count 1 by p" \
	"sample_kit/door 4: closed by p" "sample_kit/counter 5: count 2 by p" \
	"A use of entity 6 by peer" "refused: out of range" \
	"A use of entity 5 by peer" "refused: no such object" \
	"Entity 7's sample_kit/runaway disabled: on_use ran past its budget" \
	"A signal loop cut: entity" \
	"Entity 10's sample_kit/faulty, on_use: sample_kit/faulty:8: attempt to index local 't' (a nil value)" \
	"sample_kit: a dig at the door: routed to its owner" \
	"sample_kit/door 4: kept its voxel from p" \
	"sample_kit: the door's voxel is air"
grep -aq "sample_kit/counter 5: count 3" "$s" && fail "the counter counted a signal a client sent ($s)"
# The Lua error is recovered in the box; only the runaway needs a new one
[ "$(grep -ac "A new box after" "$s")" = 1 ] ||
	fail "not one new box, for the runaway alone ($s)"
grep -a "sample_kit: the door's voxel is" "$s" | sed 's/.*: the/  the/' | tr '\n' ' '
echo
[ "$(grep -a "sample_kit: the door's voxel is" "$s" | tail -1 | sed 's/.* is //')" = stone ] ||
	fail "the door's voxel is not stone at the end ($s)"
echo "ok: the wiring, the refusals, the budget, the loop, the routed write"
# 6. Types by author: sample_kit's door and Kit's side by side; the
# inventory sample_kit's pouch provides (a second refused): the item
# giver fills it to its capacity of one, the key door refuses a player
# without the key and opens taking it
want "$s" "Component type sample_kit/door version 1" \
	"Component type kit/door version 2" \
	"The players' inventory: entity 13's sample_kit/pouch" \
	"Entity 14's sample_kit/pouch would provide the players' inventory, which entity 13's sample_kit/pouch does: refused" \
	"kit/key_door 16: locked to p" \
	"kit/item_giver 15: gives p" "holds 1" \
	"has no room for 1 key" "could not take 1 key" \
	"kit/key_door 16: opened by p" "gave up 1 key and holds 0"
grep -a "The palette: " "$s" | grep -q " kit/door .* sample_kit/door" ||
	fail "kit/door and sample_kit/door are not both in the palette ($s)"
[ "$(grep -ac "sample_kit/pouch would provide" "$s")" = 1 ] ||
	fail "the second pouch was not refused once ($s)"
echo "ok: two authors' doors, the pouch in place of Kit's counts (a second refused), the item giver and the key door on it"

# The save's rows of Kit's: the authored and runtime ones, the session
# ([KIT] stage 4c: a fresh save Running; the floor a generator's, the
# start) and the copy of the section play wrote to
db=$(ls "$save"/*.sqlite 2>/dev/null | head -1)
[ -n "$db" ] || fail "no database in $save"
rows=$(sqlite3 "$db" "SELECT key FROM store WHERE store = 'kit' ORDER BY key" | tr '\n' ' ')
[ "$rows" = "authored runtime session start:world:0,0,0 " ] || fail "kit's rows are \"$rows\""
want "$s" "A fresh save: Running" "1 sections copied out (1 this round)"
grep -aq "Play by" "$s" && fail "a fresh save was played, not Running from the start ($s)"
sqlite3 "$db" "SELECT value FROM store WHERE store = 'kit' AND key = 'authored'" |
	grep -q '"presses"' && fail "runtime state in the authored row"
# The rows as a save from before types had authors has them: sample_kit's
# types bare names, read back as sample_kit's (the runtime row's too), and
# no session (from before Play and Stop: it runs on, its start its types'
# defaults); and ([KIT] stage 4c) the first slice's kit/door 12 a door of
# voxels it owned (version 1, its voxels' parameters), and the item giver
# giving "spin", which sample_kit's pouch never returns from
python3 -I - "$db" <<'PY' || fail "could not make the rows of before ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
a = json.loads(db.execute("SELECT value FROM store WHERE store = 'kit' AND key = 'authored'").fetchone()[0])
for e in a["entities"]:
	for c in e["components"]:
		if e["id"] == 12:
			c["version"] = 1
			c["params"].update({"closed": "glass", "open": "air"})
		if e["id"] == 15:
			c["params"]["item"] = "spin"
# [KIT] stage 4d: a spawner of kit/button_door's copies, set off by a button
a["entities"] += [
	{"id": 17, "parent": 2, "name": "copier", "pos": [-1, 1, 1],
		"components": [{"type": "kit/spawner", "version": 2, "params": {
			"players": False, "prefab": "kit/button_door", "max": 2}}]},
	{"id": 18, "parent": 2, "name": "copy button", "pos": [-1, 1, -1],
		"components": [{"type": "kit/button", "version": 2,
			"params": {"hold": 0.1},
			"links": [{"output": "pressed", "to": 17, "input": "spawn"}]}]}]
db.execute("UPDATE store SET value = ? WHERE store = 'kit' AND key = 'authored'", (json.dumps(a),))
# A runtime row from before [KIT] stage 4d: no players' entities, Kit's
# counts the row's "items"
r = json.loads(db.execute("SELECT value FROM store WHERE store = 'kit' AND key = 'runtime'").fetchone()[0])
r = {k: v for k, v in r.items() if k not in ("players", "made", "removed", "next_id")}
r["items"] = {"p1": {"gem": 2}}
db.execute("UPDATE store SET value = ? WHERE store = 'kit' AND key = 'runtime'", (json.dumps(r),))
db.commit()
PY
sqlite3 "$db" "UPDATE store SET value = replace(value, 'sample_kit/', '') WHERE store = 'kit';
	DELETE FROM store WHERE store = 'kit' AND key NOT IN ('authored', 'runtime')"

cat > "$t/2.cmds" <<'EOF'
wait_log 60000 replicated: entity 4 open = false
keypress b
wait_log 30000 replicated: entity 4 open = true
keypress e
frames 2
keypress h
frames 2
event kit_use 18
wait_log 10000 replicated: entity 18 presses = 1
event kit_use 20
wait_log 10000 replicated: entity 19 open = true
event kit_use 15
frames 2
event kit_use 15
wait_log 10000 spin x1
keypress b
wait_log 60000 replicated: entity 4 open = false
quit
EOF
run 2
s=$t/srv2.log
want "$s" "sample_kit: at start the counter is 2, the door open false" \
	"Entity 7's sample_kit/runaway stays disabled" "sample_kit/counter 5: count 3 by p" \
	"Entity 10's sample_kit/faulty, on_use: sample_kit/faulty:8: attempt to index local 't' (a nil value)" \
	"Entity 11's sample_kit/runaway disabled: on_use ran past its budget" \
	"sample_kit/counter 5: count 4 by p"
# The pouch's spin: the pouch disabled, not the item giver, and Kit's own
# counts take the second use
want "$s" "Entity 13's sample_kit/pouch disabled: its inventory ran past its budget in entity 15's on_use; the players' inventory is their entities' own now" \
	'"spin":1' "p1's items {\"gem\":2} are their own inventory's now"
grep -aq "Entity 15's kit/item_giver disabled" "$s" && fail "the item giver was disabled for its provider's loop ($s)"
[ "$(grep -ac "sample_kit/pouch disabled" "$s")" = 1 ] || fail "the pouch's disablement not logged once ($s)"
[ "$(grep -ac "A new box after" "$s")" = 2 ] ||
	fail "run 2: not two new boxes, for the runaway and the pouch ($s)"
want "$s" "Guest p1's entity 1000000 dropped"
want "$s" "Entity 12's kit/door is an object now: its voxels' parameters dropped, its 2 owned cells to be cleared to air"
grep -aq "the composition's first start" "$s" && fail "the composition was read again ($s)"
want "$s" "11 bare type names made <author>/<name>" \
	"A save from before Play and Stop: Running, its start its types' defaults"
python3 -I - "$db" <<'PY' || fail "the rows after the migration ($db)"
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
rows = dict(db.execute("SELECT key, value FROM store WHERE store = 'kit'"))
a, r = json.loads(rows["authored"]), json.loads(rows["runtime"])
types = [c["type"] for e in a["entities"] for c in e["components"]]
assert all("/" in t for t in types), types
assert "kit/door" in types and types.count("sample_kit/door") == 1, types
objects = ("kit/door", "kit/key_door", "kit/gate", "kit/button", "kit/lever", "kit/spawner")
assert all(c["version"] == (2 if c["type"] in objects else 1) for e in a["entities"] for c in e["components"]), a
door = [e for e in a["entities"] if e["id"] == 12][0]["components"][0]
assert "closed" not in door["params"] and "open" not in door["params"], door
assert all("/" in c["type"] for k, v in r.items() if k.isdigit() for c in v), r
# [KIT] stage 4d: the spawner's copy of the prefab, made in the round:
# the door and the button, linked to its own door
made = {m["entity"]["id"]: m for m in r["made"]}
assert sorted(made) == [19, 20] and all(m["origin"] == "g" for m in made.values()), r["made"]
assert made[20]["entity"]["components"][0]["links"][0]["to"] == 19, made[20]
# The 4c row's items went onto p1's entity's kit/inventory (the log says
# so); p1 is a guest, its entity dropped when it left ([KIT] stage 4e)
assert "p1" not in r.get("players", {}) and "items" not in r, (r.get("players"), r.get("items"))
print("  rows: %d instances, every type <author>/<name> with its version" % len(types))
PY
echo "ok: state over a restart, a save of bare type names migrated, the compiled box"

# 5. The box as an archive carries it: util/prebuild_wasm.py names it as
# the server did, and in rccpp_build/wasm/ (an archive's cache/; what a
# boxed server reads as built before, -r) it serves a server with no wasm
# toolchain
h=$(grep -ao "kit: \(built box/ in [0-9]* ms\|box/ is built (cache hit)\): [^ ]*\.wasm" "$s" |
	sed 's|.*/\([0-9a-f]\{40\}\)\.wasm|\1|' | tail -1)
[ -n "$h" ] || fail "no name of the box's .wasm in $s"
em=${EMSDK:-$HOME/emsdk}/upstream/bin
python3 -I "$here/util/prebuild_wasm.py" "$(command -v clang || echo "$em/clang")" \
		"$(command -v wasm-ld || echo "$em/wasm-ld")" "$here/src/interface" \
		"$t/pre" "$here/builtin/kit" > "$t/pre.log" 2>&1 ||
	fail "prebuild_wasm.py failed ($t/pre.log)"
[ -f "$t/pre/$h.wasm" ] || fail "prebuild_wasm.py did not name it $h ($t/pre.log)"
own=$BUILDAT_CACHE_PATH/apps/sample_kit/rccpp_build/wasm/$h.wasm
pre=$t/rccpp_build/wasm/$h.wasm
[ -f "$own" ] || fail "the box is not at $own"
mkdir -p "$(dirname "$pre")" "$t/home"
mv "$own" "$t/own.wasm" && cp "$t/pre/$h.wasm" "$pre" || fail "could not place $pre"
start_server "$t/srv3.log" "sample_kit: at start the counter is|Kit is not hosted" 120 auto \
	env HOME="$t/home" EMSDK="$t/nowhere" RUSTUP_HOME="$t/nowhere" \
	BUILDAT_WASM_CC= BUILDAT_WASM_LD= BUILDAT_CHECK_WASM_INTERPRETER=1 \
	bin/buildat_server -m ../apps/sample_kit -r "$t/rccpp_build" -l 3
CHECK_PIDS+=($SERVER_PID)
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
mv "$t/own.wasm" "$own"
grep -a "No wasm toolchain\|kit: box/\|sample_kit: at start" "$t/srv3.log" | sed "s/^.* [IEW] /  /" | cut -c 1-140
want "$t/srv3.log" "No wasm toolchain" "kit: box/ is in the shared build" \
	"sample_kit: at start the counter is 4" "2 entities made in the round"
echo "PASS: Kit's runtime: wiring, client actions and their refusals, replication, a routed voxel write, the budget and a loop cut, state over a restart; the box prebuilt as an archive carries it"
# vim: set noet ts=4 sw=4:
