#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-11-20)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c src/interface/aitta.h util/kit_api1_alpha47.json builtin/kit/types/effect.lua builtin/kit/types/symmetry.lua builtin/kit/types/spawn_rule.lua builtin/kit/types/voxel_replace.lua builtin/kit/types/voxel_states.lua
# [KIT_API_1] Kit's formats and levels, on Workbench's server alone (no
# client): save rows written by the check, the server started on them, the
# rows it saves read back.
#   1. A composition of "kit" 1: a check type bumped since (workbench/probe
#      version 2, its migrate) migrates its version 1 instance, the value
#      the migrate leaves out kept as old_params; kit/ui_text of version 1
#      and one with no version (1 in such a file) migrate too (x 540 ->
#      50). The keys a newer Kit wrote (the composition's, an entity's, a
#      component's) are written back; so is a made entity this Kit cannot
#      read (the runtime row's). A timer's c:hurt("player:60") hurts the
#      player tester (entity 60); c:hurt(nil) is an error.
#   2. A composition of "kit" 2, and one with a kit/door of version 9:
#      refused, "This game was made with a newer Buildat", the rows kept.
#   3. A composition from before (no "kit"): a component without a version
#      is its type's current one, not migrated (x 300 stays).
#   4. A save of Crag Trial written by 0.8.0-alpha.47 (util/kit_api1_alpha47
#      .json) is hosted and written back with "kit" 1, each entity kept.
#   5. 4z37j (3) B's renames: kit/effect's, kit/symmetry's and
#      kit/spawn_rule's `on`, kit/voxel_replace's and kit/voxel_states'
#      `start_on` at version 1 in "kit" 1, and unversioned from before, are
#      written back at version 2 under the new names. A check type with
#      players = true (no longer reads_players' alias) loads, warned of as
#      a field Kit does not know, and reads no players; its c:add with
#      ext.player and c:list with ext.kit_x are refused.
#   util/kit_api1_formats_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
if check_pgrep buildat_server >/dev/null; then
	skip "a buildat server is already running"
fi
check_tmp kit_api1_formats; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_WORKBENCH_STONE=1
export BUILDAT_WORKBENCH_TYPES="$t/user/apps/workbench/check_types"
mkdir -p "$BUILDAT_WORKBENCH_TYPES"
cat > "$BUILDAT_WORKBENCH_TYPES/probe.lua" <<'EOF'
-- Bumped to 2 after an export of 1: name became label
return {
	version = 2,
	params = {label = {type = "string", default = ""}},
	look = {shape = "sphere", size = 0.3, color = "#ff3030"},
	migrate = function(params, from)
		params.label = "from " .. tostring(params.name) .. " v" .. from
		return params
	end,
}
EOF
cat > "$BUILDAT_WORKBENCH_TYPES/hurter.lua" <<'EOF'
return {
	version = 1,
	look = {shape = "box", size = {0.3, 0.3, 0.3}, color = "#202020"},
	on_timer = function(c, name)
		if name == "a" then
			c:hurt("player:60", 3)
		else
			c:hurt(nil, 3)
		end
	end,
}
EOF
# (5) a table of before: players = true, a field Kit does not know now
cat > "$BUILDAT_WORKBENCH_TYPES/reader.lua" <<'EOF'
return {
	version = 1,
	players = true,
	look = {shape = "box", size = {0.3, 0.3, 0.3}, color = "#2020a0"},
	on_timer = function(c, name)
		if name == "a" then
			c:log("reader players " .. type(c.players))
			c:add("stone", 1, {player = 1})
		else
			c:list({kit_x = 1})
		end
	end,
}
EOF

# The project's save: its rows by the server's first start, then the
# check's over them
server() # <n> <project> [a log line to wait for]: until it is hosted or
{        # refused (and that line), then stopped
	BUILDAT_WORKBENCH_PROJECT=$2 start_server "$t/srv$1.log" \
		"Hosted: |Not hosted: " 300 auto \
		bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 ||
		grep -aq "Not hosted: " "$t/srv$1.log" ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
	[ -z "${3:-}" ] || wait_for_log "$t/srv$1.log" "$3" 10 ||
		fail "no \"$3\" ($t/srv$1.log)"
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	grep -a "Not hosted\|Hosted:\|hurt\|old_params\|left out\|upgraded\|kept as it was" \
		"$t/srv$1.log" | sed 's/^.*kit *: /  /' | cut -c1-200
}
db() { echo "$t/user/apps/workbench/saves/$1/save.sqlite"; }
rows() # <project> <python, the rows given as R {key: JSON or text}>
{
	python3 - "$(db "$1")" "$2" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
exec(sys.argv[2], {"db": db, "json": json})
PY
}
SET='
def put(k, v):
	db.execute("insert or replace into store (store, key, value) values (?, ?, ?)",
		("kit", k, json.dumps(v).encode()))
def get(k):
	r = db.execute("select value from store where store=? and key=?", ("kit", k)).fetchone()
	return json.loads(r[0]) if r else None
'

server 1 world
[ -f "$(db world)" ] || fail "no save ($t/user)"

# 1. Of "kit" 1, a bump after the export, newer keys, a made entity unread
rows world "$SET"'
put("authored", {"kit": 1, "api": 1, "zz_top": {"by": "a newer Kit"},
	"next_id": 7, "entities": [
	{"id": 2, "parent": 1, "name": "world", "kind": "scene"},
	{"id": 3, "parent": 2, "name": "probe", "pos": [0, 1, 0], "zz_e": [1, 2],
		"components": [{"type": "workbench/probe", "version": 1,
		"params": {"name": "old"}, "zz_c": "kept"}]},
	{"id": 4, "parent": 1, "name": "text v1", "components": [
		{"type": "kit/ui_text", "version": 1, "params": {"x": 540}}]},
	{"id": 5, "parent": 1, "name": "text unversioned", "components": [
		{"type": "kit/ui_text", "params": {"x": 540}}]},
	{"id": 6, "parent": 2, "name": "hurter", "pos": [2, 1, 0],
		"components": [{"type": "workbench/hurter", "version": 1}]}]})
put("session", {"by": "", "restore": [], "round": [], "running": True})
put("runtime", {"6": [{"type": "workbench/hurter", "state": {}, "timers": [
		{"name": "a", "player": "", "s": 0.3, "by": ""},
		{"name": "b", "player": "", "s": 0.6, "by": ""}]}],
	"made": [{"entity": {"id": 40, "parent": 2, "name": "a newer Kit made",
		"pos": [4, 1, 0], "components": [{"type": "kit/zz_newer", "version": 1}]},
		"origin": "g", "by": "", "maker": [0, 0]}],
	"removed": [], "players": {"tester": {"id": 60}}, "next_id": 61})
db.commit()
' || fail "the rows"
# (the timers' hurts: 0.3 and 0.6 s in)
server 2 world "Entity 6's workbench/hurter, on_timer: .*hurt: a player"
grep -aq "Hosted: " "$t/srv2.log" || fail "not hosted ($t/srv2.log)"
grep -aqE "Entity 6's workbench/hurter (hurts tester|: hurt of tester refused)" "$t/srv2.log" ||
	fail "c:hurt(\"player:60\") did not reach tester ($t/srv2.log)"
grep -aq "hurt: 0 is no player" "$t/srv2.log" && fail "a hurt went to nobody ($t/srv2.log)"
grep -aq 'hurt: a player is an entity id, "player:<id>" or "bot:<id>"' "$t/srv2.log" ||
	fail "c:hurt(nil) was no error ($t/srv2.log)"
rows world "$SET"'
a = get("authored")
e = {x["id"]: x for x in a["entities"]}
assert a["kit"] == 1 and a["api"] == 1, a.get("kit")
assert a["zz_top"] == {"by": "a newer Kit"}, "the composition key lost"
assert e[3]["zz_e"] == [1, 2], "the entity key lost: %r" % e[3]
p = e[3]["components"][0]
print("  the probe:", json.dumps(p, sort_keys=True))
assert p["version"] == 2 and p["params"]["label"] == "from old v1", p
assert p["old_params"] == {"name": "old"}, "old_params %r" % p.get("old_params")
assert p["zz_c"] == "kept", "the component key lost"
for i in (4, 5):
	c = e[i]["components"][0]
	assert c["version"] == 2 and c["params"]["x"] == 50, (i, c)
r = get("runtime")
m = [x for x in r["made"] if x["entity"]["id"] == 40]
assert m and m[0]["entity"]["components"][0]["type"] == "kit/zz_newer", r["made"]
print("ok: kit 1: the probe migrated (old_params kept), the ui_texts v1 and unversioned migrated, the newer keys and the unread made entity written back")
'
[ $? = 0 ] || fail "the rows written back ($(db world))"
echo "ok: c:hurt(\"player:60\") reached tester; c:hurt(nil) an error"

# 2. Newer: "kit" 2; a kit/door of version 9
newer() # <n> <what> <authored row's python> <the refusal>
{
	rows world "$SET""put('authored', $3)
db.commit()"
	server "$1" world
	grep -aqF "Not hosted: $4" "$t/srv$1.log" ||
		fail "$2 not refused with \"$4\" ($t/srv$1.log)"
	rows world "$SET""assert get('authored') == $3, 'the row changed'" ||
		fail "$2: the authored row changed"
	echo "ok: $2 refused, the row kept"
}
newer 3 '"kit" 2' '{"kit": 2, "api": 1, "entities": [], "next_id": 2}' \
	"This game was made with a newer Buildat (Kit format 2). This Buildat reads up to Kit format 1. Update Buildat to open it."
newer 4 'a kit/door of version 9' '{"kit": 1, "api": 1, "next_id": 4, "entities": [
	{"id": 2, "parent": 1, "name": "world", "kind": "scene"},
	{"id": 3, "parent": 2, "name": "door", "pos": [0, 1, 0],
		"components": [{"type": "kit/door", "version": 9}]}]}' \
	"entity 3: This game was made with a newer Buildat (kit/door version 9). This Buildat has kit/door version 2."

# 3. From before: no "kit", a version left out the type's current
rows world "$SET"'
put("authored", {"next_id": 4, "entities": [
	{"id": 2, "parent": 1, "name": "world", "kind": "scene"},
	{"id": 3, "parent": 1, "name": "text", "components": [
		{"type": "kit/ui_text", "params": {"x": 300}}]}]})
db.commit()
' || fail "the rows"
server 5 world
rows world "$SET"'
c = get("authored")["entities"]
c = [x for x in c if x["id"] == 3][0]["components"][0]
assert c["version"] == 2 and c["params"]["x"] == 300, c
'
[ $? = 0 ] || fail "a composition from before: its unversioned ui_text migrated ($t/srv5.log)"
echo "ok: from before, an unversioned component is its type's current"

# 5. 4z37j's renames, from "kit" 1 at version 1 and from before unversioned
RENAMED='[
	{"id": 3, "parent": 2, "name": "effect", "components": [
		{"type": "kit/effect", VER "params": {"on": "hit"}}]},
	{"id": 4, "parent": 1, "name": "symmetry", "components": [
		{"type": "kit/symmetry", VER "params": {"on": True}}]},
	{"id": 5, "parent": 2, "name": "spawn_rule", "components": [
		{"type": "kit/spawn_rule", VER "params": {"on": "stone", "enabled": False}}]},
	{"id": 6, "parent": 2, "name": "voxel_replace", "components": [
		{"type": "kit/voxel_replace", VER "params": {"start_on": True}}]},
	{"id": 7, "parent": 2, "name": "voxel_states", "components": [
		{"type": "kit/voxel_states", VER "params": {"start_on": True}}]}]'
V1='"version": 1,'
CHECK_RENAMED='
c = {x["id"]: x["components"][0] for x in get("authored")["entities"] if x["id"] in range(3, 8)}
want = {3: ("trigger", "hit"), 4: ("enabled", True), 5: ("on_voxels", "stone"),
	6: ("enabled", True), 7: ("enabled", True)}
for i, (k, v) in want.items():
	p = c[i]["params"]
	assert c[i]["version"] == 2 and p.get(k) == v, (WHAT, c[i])
	assert "on" not in p and "start_on" not in p and not c[i].get("old_params"), (WHAT, c[i])
assert c[5]["params"]["enabled"] is False, c[5]
'
rows world "$SET"'
put("authored", {"kit": 1, "api": 1, "next_id": 9, "entities": [
	{"id": 2, "parent": 1, "name": "world", "kind": "scene"},
	{"id": 8, "parent": 2, "name": "reader", "pos": [0, 1, 0],
		"components": [{"type": "workbench/reader", "version": 1}]}] + '"${RENAMED//VER/$V1}"'})
put("session", {"by": "", "restore": [], "round": [], "running": True})
put("runtime", {"8": [{"type": "workbench/reader", "state": {}, "timers": [
		{"name": "a", "player": "", "s": 0.2, "by": ""},
		{"name": "b", "player": "", "s": 0.4, "by": ""}]}],
	"made": [], "removed": [], "players": {}, "next_id": 61})
db.commit()
' || fail "the rows"
server 7 world "ext.kit_x is reserved"
grep -aq "Hosted: " "$t/srv7.log" || fail "not hosted ($t/srv7.log)"
for w in "Component type workbench/reader: players: not a type field Kit knows" \
		"reader players nil" "ext.player is reserved" "ext.kit_x is reserved"; do
	grep -aqF "$w" "$t/srv7.log" || fail "no \"$w\" ($t/srv7.log)"
done
rows world "$SET""WHAT = 'kit 1'$CHECK_RENAMED" ||
	fail "kit 1's renamed params ($t/srv7.log)"
echo "ok: kit 1: effect's on, symmetry's on, spawn_rule's on, voxel_replace's and voxel_states' start_on migrated to v2's names; a type of players = true loads warned of an unknown field, reads no players; ext.player and ext.kit_ refused"
rows world "$SET"'
put("authored", {"next_id": 8, "entities": [
	{"id": 2, "parent": 1, "name": "world", "kind": "scene"}] + '"${RENAMED//VER/}"'})
put("session", {"by": "", "restore": [], "round": [], "running": False})
put("runtime", {"made": [], "removed": [], "players": {}, "next_id": 61})
db.commit()
' || fail "the rows"
server 8 world
rows world "$SET""WHAT = 'from before'$CHECK_RENAMED" ||
	fail "the renamed params from before ($t/srv8.log)"
echo "ok: from before: the five renamed params, unversioned, migrated"

# 4. alpha.47's Crag Trial save
mkdir -p "$(dirname "$(db crag)")"
python3 - "$here/util/kit_api1_alpha47.json" "$(db crag)" <<'PY' || fail "the fixture"
import base64, json, sqlite3, sys
rows = json.load(open(sys.argv[1]))["rows"]
db = sqlite3.connect(sys.argv[2])
db.execute("CREATE TABLE store (store TEXT NOT NULL, key TEXT NOT NULL, value BLOB, PRIMARY KEY(store, key))")
for s, k, v in rows:
	v = base64.b64decode(v["b64"]) if isinstance(v, dict) else v.encode()
	db.execute("insert into store values (?, ?, ?)", (s, k, v))
db.commit()
PY
server 6 crag
grep -aq "Hosted: " "$t/srv6.log" || fail "alpha.47's save not hosted ($t/srv6.log)"
python3 - "$here/util/kit_api1_alpha47.json" "$(db crag)" <<'PY' || fail "alpha.47's save written back ($t/srv6.log)"
import json, sqlite3, sys
was = {(s, k): v for s, k, v in json.load(open(sys.argv[1]))["rows"]}
old = json.loads(was[("kit", "authored")])
db = sqlite3.connect(sys.argv[2])
now = json.loads(db.execute("select value from store where store='kit' and key='authored'").fetchone()[0])
# (written back only if anything changed: the levels then)
if "kit" in now:
	assert now["kit"] == 1 and now["api"] == 1, now.get("kit")
o = {e["id"]: e for e in old["entities"]}
n = {e["id"]: e for e in now["entities"]}
assert set(o) == set(n), set(o) ^ set(n)
for i in o:
	for a, b in zip(o[i].get("components", []), n[i].get("components", [])):
		# (a parameter added since, e.g. kit/terrain's flatten, is written
		# back at its default: the old ones as they were)
		assert a["type"] == b["type"] and a["version"] == b["version"] and \
			all(b["params"].get(k) == v for k, v in a["params"].items()), \
			(i, a, b)
print("ok: alpha.47's Crag Trial save hosted, its %d entities as they were%s" %
	(len(n), ", written back with \"kit\" 1" if "kit" in now else ""))
PY
echo "PASS: Kit's formats and levels: a type bumped after the export migrates (old_params kept), a newer \"kit\" and a newer component version refused with the newer-Buildat message, unknown keys and an unread made entity written back, c:hurt(\"player:<id>\"); a composition from before and alpha.47's save load; the 4z37j renames migrate, a type table of before loads warned of"
