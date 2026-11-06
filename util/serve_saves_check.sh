#!/bin/bash
# tier: full
# cost: ~1 min (2026-11-07)
# covers: util/serve_latest_release.sh builtin/storage/storage.cpp
# [SERVE_SAVES_ON_UPDATE]: serve_latest_release.sh on an Aitta app whose
# save stays with its release, each version installed with the script stopped
# (no Aitta: a start runs the newest installed, the same path as following one).
#   1. 1.0.0 makes the save and writes to it.
#   2. 1.1.0 opens it, 1.0.0's value there, the old saves copied; outlasts its
#      trial.
#   3. 1.2.0 writes to the save and fails: back to 1.1.0, whose value is there
#      and 1.2.0's is not, 1.2.0 not started again.
#   4. 1.3.0 with the copy impossible: 1.1.0 stays.
#
#   util/serve_saves_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/Build/bin/buildat"
check_tmp serve_saves; t=$CHECK_TMP
groups=()
stop_serve(){
	for g in "${groups[@]}"; do kill -TERM -- "-$g" 2>/dev/null; done
	for g in "${groups[@]}"; do
		for n in $(seq 100); do kill -0 -- "-$g" 2>/dev/null || break; sleep 0.2; done
		kill -KILL -- "-$g" 2>/dev/null
	done
	groups=()
}
trap 'stop_serve; check_cleanup' EXIT
P=$((29700 + RANDOM % 200))

# The app: the save "s", what it holds said, then this version's mark; FAILS
# means it exits with a failure after that
mkdir -p "$t/app/main" "$t/u"
echo '{"engine_api": 2, "dependencies": [{"module": "storage"}]}' > "$t/app/main/meta.json"
cat > "$t/main.cpp.in" <<'EOF'
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
			if(!save)
				save = s->create("s");
			if(!save){
				log_i(MODULE, "saves_check: VERSION refused");
				return;
			}
			ss_ was = "none";
			save->store("x")->get("mark", was);
			log_i(MODULE, "saves_check: VERSION found %s", cs(was));
			save->store("x")->set("mark", "VERSION");
			s->close(save);
		});
		if(FAILS)
			m_server->shutdown(3, "saves_check: failing");
	}
};
extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
EOF
"$b" aitta keygen "$t/key" > /dev/null || fail "keygen"
install(){ # version fails
	sed "s/VERSION/$1/g; s/FAILS/$2/" "$t/main.cpp.in" > "$t/app/main/main.cpp"
	printf '{"author": "tester", "name": "sv", "version": "%s",
		"engine_api": 2, "license_code": "MIT", "license_media": "CC0-1.0"}\n' \
		"$1" > "$t/app/meta.json"
	zip=$("$b" aitta pack "$t/app" "$t/key" "$t/out" 2>/dev/null) || fail "pack $1"
	"$b" aitta install "$zip" "$t/u" > /dev/null 2>&1 || fail "install $1"
}

# A release of this tree, served as GitHub's list would be
HP=$((P + 1))
r="$t/rel/buildat-0.0.1-check-linux-x86_64-web-precompiled"
mkdir -p "$r/apps"
for e in 3rdparty Build builtin client extensions src VERSION web util; do
	ln -s "$here/$e" "$r/$e"
done
ln -s Build/bin "$r/bin"
tar -C "$t/rel" -czf "$r.tar.gz" "$(basename "$r")"
echo "[{\"browser_download_url\": \"http://127.0.0.1:$HP/$(basename "$r").tar.gz\"}]" \
	> "$t/rel/releases.json"
setsid python3 -m http.server $HP --bind 127.0.0.1 --directory "$t/rel" > "$t/http.log" 2>&1 &
http=$!
trap 'stop_serve; kill "$http" 2>/dev/null; check_cleanup' EXIT

serve(){ # log
	setsid env BUILDAT_SERVE_DIR="$t/serve" POLL_SECONDS=2 APP_TRIAL_SECONDS=1 \
		RELEASES_URL="http://127.0.0.1:$HP/releases.json" \
		"$here/util/serve_latest_release.sh" tester/sv $P "$t/u" -l 3 > "$1" 2>&1 &
	groups+=($!)
}

install 1.0.0 false
serve "$t/s1.log"
wait_for_log "$t/s1.log" "saves_check: 1.0.0 found none" 180 || fail "1.0.0 did not make its save ($t/s1.log)"
stop_serve
echo "ok: 1.0.0 made the save"

install 1.1.0 false
serve "$t/s2.log"
wait_for_log "$t/s2.log" "saves_check: 1.1.0 " 180 || fail "1.1.0 did not start ($t/s2.log)"
grep -aq "saves_check: 1.1.0 found 1.0.0" "$t/s2.log" ||
	fail "1.1.0 did not get 1.0.0's save: $(grep -a saves_check "$t/s2.log" | tail -3)"
keep=$(echo "$t"/serve/saves_before/*sv-$P)
[ "$(cat "$keep/for")" = 1.1.0 ] && [ -f "$keep/saves/s/save.sqlite" ] || fail "no copy of the saves for 1.1.0"
wait_for_log "$t/s2.log" "tester/sv 1.1.0 stayed up" 30 || fail "1.1.0's trial did not end ($t/s2.log)"
stop_serve
echo "ok: 1.1.0 took 1.0.0's save, a copy kept, and outlasted its trial"

# Long enough that the trial is not over when it fails
install 1.2.0 true
serve_long(){
	setsid env BUILDAT_SERVE_DIR="$t/serve" POLL_SECONDS=2 APP_TRIAL_SECONDS=120 \
		RELEASES_URL="http://127.0.0.1:$HP/releases.json" \
		"$here/util/serve_latest_release.sh" tester/sv $P "$t/u" -l 3 > "$1" 2>&1 &
	groups+=($!)
}
serve_long "$t/s3.log"
wait_for_log "$t/s3.log" "saves_check: 1.2.0 found 1.1.0" 180 || fail "1.2.0 did not take the save ($t/s3.log)"
wait_for_log "$t/s3.log" "tester/sv 1.2.0 failed in its trial; going back to 1.1.0" 30 ||
	fail "no going back ($t/s3.log)"
wait_for_log "$t/s3.log" "saves_check: 1.1.0 " 60 || fail "1.1.0 did not start again ($t/s3.log)"
grep -aq "saves_check: 1.1.0 found 1.1.0" "$t/s3.log" ||
	fail "1.1.0 did not get its own saves back: $(grep -a saves_check "$t/s3.log" | tail -3)"
[ "$(grep -ac 'saves_check: 1.2.0 ' "$t/s3.log")" = 1 ] || fail "1.2.0 started again"
[ "$(cat "$t"/serve/app_version-*sv-$P)" = 1.1.0 ] || fail "the version to go back to is not 1.1.0"
stop_serve
echo "ok: 1.2.0 failed in its trial and 1.1.0 runs with the saves from before"

# The copy cannot be made: the server stays where it is
install 1.3.0 false
chmod 555 "$t/serve/saves_before"
serve_long "$t/s4.log"
wait_for_log "$t/s4.log" "saves_check: 1." 60 || fail "nothing started ($t/s4.log)"
chmod 755 "$t/serve/saves_before"
grep -aq "could not copy" "$t/s4.log" && grep -aq "staying on tester/sv 1.1.0" "$t/s4.log" ||
	fail "no word of the copy: $(tail -3 "$t/s4.log")"
grep -aq "saves_check: 1.3.0" "$t/s4.log" && fail "1.3.0 started with no copy"
stop_serve
echo "PASS: an app's update moves its saves, a copy kept; a version failing in its trial goes back to the one before with the copy, not started again; with no copy it is not started"
