#!/bin/bash
# tier: full
# cost: 40s (a first run compiles the app and storage, 2026-10-03)
# covers: builtin/storage/storage.cpp src/server/confine.h src/impl/aitta.cpp
# [AITTA_MVP] step 1: **a save stays with the release that made it**. A
# small app that opens its save "s" or makes it, packed as 1.0.0 and 1.1.0 and
# both installed: 1.0.0 makes the save, 1.1.0 is refused it, 1.0.0 opens it
# again; moved to 1.1.0 when told, 1.0.0 is refused it -- each a boxed server
# from <user>/installed, under its one app directory, apps/tester.pin.
#
#   util/aitta_pin_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/Build/bin/buildat"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail(){ echo "FAIL: $*"; exit 1; }

mkdir -p "$t/app/main" "$t/user"
echo '{"engine_api": 2, "dependencies": [{"module": "storage"}]}' > "$t/app/main/meta.json"
cat > "$t/app/main/main.cpp" <<'EOF'
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "storage/api.h"
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
			storage::Save *save = s->open("s");
			const char *what = save ? "opened" : "refused";
			if(!save){
				save = s->create("s");
				what = save ? "made" : "refused";
			}
			log_i(MODULE, "pin_check: %s", what);
			if(save)
				s->close(save);
		});
		m_server->shutdown(0, "pin_check done");
	}
};
extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
EOF

"$b" aitta keygen "$t/key" > /dev/null || fail "keygen"
for v in 1.0.0 1.1.0; do
	printf '{"author": "tester", "name": "pin", "version": "%s",
		"engine_api": 2, "license_code": "MIT", "license_media": "CC0-1.0"}\n' \
		"$v" > "$t/app/meta.json"
	zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack $v"
	"$b" aitta install "$zip" "$t/user" > /dev/null 2>&1 || fail "install $v"
done
run(){ # version [launch lines] -> the line
	(cd "$here/Build" && timeout 120 bin/buildat_server \
		-m "$t/user/installed/tester/pin/$1" -D "$t/user" -C "$t/cache" \
		-P 29873 -l 3 ${2:+-u "$2"} 2>&1) > "$t/srv_$1.log"
	grep -ao "pin_check: [a-z]*" "$t/srv_$1.log" | tail -1
}
r=$(run 1.0.0); [ "$r" = "pin_check: made" ] || fail "1.0.0 did not make its save: '$r' (srv_1.0.0.log: $(tail -3 "$t/srv_1.0.0.log"))"
r=$(run 1.1.0); [ "$r" = "pin_check: refused" ] || fail "1.1.0 was not refused 1.0.0's save: '$r'"
grep -aq "was made with release 1.0.0" "$t/srv_1.1.0.log" || fail "1.1.0 did not say why"
r=$(run 1.0.0); [ "$r" = "pin_check: opened" ] || fail "1.0.0 did not open its save again: '$r'"
[ -d "$t/user/apps/tester.pin/saves/s" ] || fail "the save is not under apps/tester.pin"
# The player moves it: the grid's "move saves here" launches with this
r=$(run 1.1.0 "aitta_move_saves=1"); [ "$r" = "pin_check: opened" ] ||
	fail "1.1.0 did not take the save when told to: '$r'"
r=$(run 1.0.0); [ "$r" = "pin_check: refused" ] || fail "1.0.0 still opens the moved save: '$r'"
echo "PASS: a save made by 1.0.0 opens in 1.0.0 and not in 1.1.0, under apps/tester.pin, and moves to 1.1.0 when told"
