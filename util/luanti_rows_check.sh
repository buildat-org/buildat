#!/bin/bash
# tier: full
# cost: ~40 s (2026-10-12)
# covers: builtin/luanti/luanti.cpp builtin/luanti/lua/entity.lua
# [COMPAT_BREAK_07] 8h: a luanti world's players row and clock that this
# build cannot read (a newer Buildat's) are kept as they are through a run
# and its shutdown, not dropped or reset to noon.
#   util/luanti_rows_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
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
db=$(find "$t/srv" -name save.sqlite -path '*rows*' | head -1)
[ -n "$db" ] || fail "no save.sqlite for the world under $t/srv"
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
python3 - "$db" <<'PY' || fail "a newer row was written over"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
get = lambda k: c.execute("SELECT value FROM store WHERE store='luanti' "
        "AND key=?", (k,)).fetchone()[0]
assert bytes(get("players")) == b"return {v = 2, players = {bob = {hp = 20}}}", get("players")
assert bytes(get("clock")) == b"\x01\x02later", get("clock")
PY
echo "PASS: a newer players row and clock kept through a run"
