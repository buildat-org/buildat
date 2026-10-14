#!/bin/bash
# tier: quick
# ci
# cost: ~15 s (2026-10-12)
# covers: builtin/storage/storage.cpp
# [COMPAT_BREAK_07] 8h: a save is stamped with its format (PRAGMA
# user_version 1) and the version that last opened it; one stamped newer is
# refused with the reason, and left as it was. A 0.6 save (the store table
# and its rows, user_version 0) opens through the storage module with its
# rows as they were, and is stamped 1 with the version row.
#   util/save_stamp_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp save_stamp; t=$CHECK_TMP
mkdir -p "$t/app/main"
echo '{"engine_api": 2, "dependencies": [{"module": "storage"}]}' > "$t/app/main/meta.json"
cat > "$t/app/main/main.cpp" <<'EOF'
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "storage/api.h"
#include <cstdlib>
#define MODULE "main"
using interface::Event;
struct Module: public interface::Module {
	interface::Server *m_server;
	Module(interface::Server *server): interface::Module(MODULE), m_server(server){}
	void init(){ m_server->sub_event(this, Event::t("core:start")); }
	void event(const Event::Type &type, const Event::Private *p){
		EVENT_VOIDN("core:start", on_start)
	}
	void on_start(){
		storage::access(m_server, [&](storage::Interface *s){
			const char *name = getenv("STAMP_SAVE");
			storage::Save *save = s->open(name ? name : "s");
			const char *what = save ? "opened" : "missing";
			if(!save){
				save = s->create("s");
				what = "made";
			}
			log_i(MODULE, "stamp_check: %s", what);
			if(save && what[0] == 'o'){
				storage::Store *g = save->store("game");
				for(const ss_ &k : g->list("")){
					ss_ v;
					g->get(k, v);
					log_i(MODULE, "stamp_check: row %s=%s", cs(k), cs(v));
				}
			}
			if(save)
				s->close(save);
		});
		m_server->shutdown(0, "stamp_check done");
	}
};
extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
EOF
run(){ # log
	(cd "$here/Build" && timeout 120 bin/buildat_server -m "$t/app" \
		-D "$t/user" -C "$t/cache" -P 29874 -l 3 2>&1) > "$t/$1"
}
run made.log
grep -aq "stamp_check: made" "$t/made.log" || fail "no save made ($t/made.log)"
db=$(find "$t/user" -name save.sqlite | head -1)
[ -n "$db" ] || fail "no save.sqlite under $t/user"
python3 - "$db" <<'PY' || fail "the stamp"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
assert c.execute("PRAGMA user_version").fetchone()[0] == 1
v = c.execute("SELECT value FROM store WHERE store='__save' AND key='version'").fetchone()
assert v and v[0], v
c.execute("PRAGMA user_version=2")
c.commit()
PY
echo "ok: stamped format 1 and the version"
run newer.log
grep -aq "was written by a newer Buildat (save format 2" "$t/newer.log" ||
	fail "a newer save was not refused with the reason ($t/newer.log)"
grep -aq "stamp_check: opened" "$t/newer.log" && fail "a newer save was opened"
[ "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("PRAGMA user_version").fetchone()[0])' "$db")" = 2 ] ||
	fail "the newer save was written over"

# A 0.6 save beside it: the same table, rows, no stamp
old=$(dirname "$(dirname "$db")")/o/save.sqlite
mkdir -p "$(dirname "$old")"
python3 - "$old" <<'PY' || fail "the 0.6 save"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE store (store TEXT NOT NULL, key TEXT NOT NULL,"
		" value BLOB, PRIMARY KEY(store, key))")
c.executemany("INSERT INTO store VALUES ('game', ?, ?)", [("a", "one"), ("b", "two")])
c.commit()
assert c.execute("PRAGMA user_version").fetchone()[0] == 0
PY
STAMP_SAVE=o run old.log
grep -aq "stamp_check: opened" "$t/old.log" || fail "the 0.6 save did not open ($t/old.log)"
rows=$(grep -ao "stamp_check: row .*" "$t/old.log" | sed 's/stamp_check: row //' | tr '\n' ' ')
[ "$rows" = "a=one b=two " ] || fail "the 0.6 save's rows: $rows ($t/old.log)"
python3 - "$old" <<'PY' || fail "the 0.6 save was not stamped"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
assert c.execute("PRAGMA user_version").fetchone()[0] == 1
v = c.execute("SELECT value FROM store WHERE store='__save' AND key='version'").fetchone()
assert v and v[0], v
PY
echo "ok: a 0.6 save opened with its rows, stamped 1 and the version"
echo "PASS: a save stamped with its format and version; one stamped newer refused with the reason and left as it was; a 0.6 save opened as it was and stamped"
