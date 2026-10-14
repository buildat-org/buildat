#!/bin/bash
# tier: full
# ci
# cost: ~60 s (2026-10-13)
# covers: builtin/luanti/luanti.cpp builtin/luanti/lua/entity.lua builtin/luanti/lua/bootstrap.lua
# [COMPAT_BREAK_07] 8h: a luanti world's players row and clock that this
# build cannot read (a newer Buildat's) are kept as they are through a run
# and its shutdown, not dropped or reset to noon. [COMPAT_CHECKS]: a
# players row and a mod's storage as 0.6 wrote them (no v) are read with
# their values and written back as {v = 1, ...}; a mod storage of a newer
# v is said and not written over while its mod sets a value.
#   util/luanti_rows_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp luanti_rows; t=$CHECK_TMP
cd "$here/Build"
run(){ # log
	BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=rows \
	start_server "$t/$1" "STATUS Listening" 180 auto \
		bin/buildat_server -m ../apps/vanilla -D "$t/srv" -l 3 ||
		fail "the server did not listen ($t/$1)"
	CHECK_PIDS+=($SERVER_PID)
	kill -TERM "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null
}
run first.log
# The temp directory's own name has "rows" in it: the save's by its path
db=$(find "$t/srv" -name save.sqlite -path '*/saves/rows/*' | head -1)
[ -n "$db" ] || fail "no save.sqlite for the world under $t/srv"
w=$(dirname "$db")/luanti
[ -d "$w" ] || fail "no world directory $w"
# A world mod that logs a value of its storage and sets another
mkdir -p "$w/worldmods/ctest" "$w/mod_storage"
echo "name = ctest" > "$w/worldmods/ctest/mod.conf"
cat > "$w/worldmods/ctest/init.lua" <<'L'
local s = core.get_mod_storage()
core.log("action", "ctest: a=" .. s:get_string("a"))
s:set_string("b", "new")
L
# 0.6's: the fields bare, and the players with no v
printf 'return {["a"] = "kept"}' > "$w/mod_storage/ctest"
python3 - "$db" <<'PY' || fail "writing 0.6's players row"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT OR REPLACE INTO store VALUES('luanti', 'players', ?)",
        (b"return {players = {bob = {hp = 20}}}",))
c.commit()
PY
run old.log
grep -aq "ctest: a=kept" "$t/old.log" || fail "0.6's mod storage was not read ($t/old.log)"
python3 - "$db" "$w/mod_storage/ctest" <<'PY' || fail "0.6's rows not written back wrapped ($t/old.log)"
import re, sqlite3, sys
c = sqlite3.connect(sys.argv[1])
p = bytes(c.execute("SELECT value FROM store WHERE store='luanti' AND "
        "key='players'").fetchone()[0]).decode()
assert re.search(r"\bv ?= ?1\b", p) and "bob" in p, p
m = open(sys.argv[2]).read()
assert re.search(r"\bv ?= ?1\b", m) and "kept" in m and "new" in m, m
PY
echo "ok: 0.6's players row and mod storage read and written back with v = 1"
newer='return {v = 2, fields = {a = "later"}}'
printf '%s' "$newer" > "$w/mod_storage/ctest"
python3 - "$db" <<'PY' || fail "writing the newer rows"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT OR REPLACE INTO store VALUES('luanti', 'players', ?)",
        (b"return {v = 2, players = {bob = {hp = 20}}}",))
c.execute("INSERT OR REPLACE INTO store VALUES('luanti', 'clock', ?)",
        (b"\x01\x02later",))
c.commit()
PY
run second.log
grep -aq "The save's players cannot be read" "$t/second.log" ||
	fail "the newer players row was not noticed ($t/second.log)"
grep -aq "The save's clock is version 2" "$t/second.log" ||
	fail "the newer clock was not noticed ($t/second.log)"
grep -aq "Cannot read mod storage of ctest" "$t/second.log" ||
	fail "the newer mod storage was not noticed ($t/second.log)"
[ "$(cat "$w/mod_storage/ctest")" = "$newer" ] ||
	fail "the newer mod storage was written over: $(cat "$w/mod_storage/ctest")"
python3 - "$db" <<'PY' || fail "a newer row was written over"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
get = lambda k: c.execute("SELECT value FROM store WHERE store='luanti' "
        "AND key=?", (k,)).fetchone()[0]
assert bytes(get("players")) == b"return {v = 2, players = {bob = {hp = 20}}}", get("players")
assert bytes(get("clock")) == b"\x01\x02later", get("clock")
PY
echo "PASS: 0.6's players row and mod storage read and wrapped; a newer players row, clock and mod storage kept through a run"
