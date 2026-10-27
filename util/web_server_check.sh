#!/bin/bash
# tier: full
# cost: ~40 s (2026-10-27); ~30 s more the first time, building the
# fixture's server
# covers: util/web_server.cmake src/server/web/** builtin/network/network_web.cpp builtin/accounts/accounts_web.cpp builtin/starport_announce/starport_announce_web.cpp
# [WEB_LOCAL_SERVER]: hillclimb's server built for the web
# (util/build_web_server.sh) run headless under node: every module in the
# loader's order is loaded from the linked-in table, the car's drive
# (BUILDAT_HILLCLIMB_DRIVE, no client) climbs off the pad, and the server
# ends itself. --free-run, so the ticks' rate is the wasm's own. Then:
# - the page's stop (Module._buildat_server_stop, which node's SIGTERM
#   calls in src/server/web/pre.js) ends a running server with status 0;
# - a fixture app in local/check/web_server_fixture: the build refuses it
#   while its module does not say "web": true, naming the module; marked,
#   it builds, and its module, playing two peers, finds the first to
#   connect the local player and the admin, and the second neither.
# Needs Build-webserver/ from util/build_web_server.sh, and node; the
# fixture needs emsdk as util/build_web_server.sh does.
#   util/web_server_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
js="$here/Build-webserver/bin/buildat_server.js"
[ -f "$js" ] || skip "no $js: run util/build_web_server.sh"
command -v node > /dev/null || skip "no node"
check_tmp web_server; t=$CHECK_TMP

# The paths are in the wasm's own file system (/buildat is packed in it);
# the .data is found beside the .js from the working directory
start=$(date +%s.%N)
(cd "$(dirname "$js")" && BUILDAT_HILLCLIMB_DRIVE="0:S 2:W2 32:Q" timeout 90 \
	node "$js" --unconfined --free-run -l 3 -m /buildat/apps/hillclimb \
	-S /buildat -U /urho -D /user -C /cache > "$t/server.log" 2>&1)
rc=$?
end=$(date +%s.%N)
grep -E 'Module load order|Loading module|network: the web' "$t/server.log" | cut -c 20-
grep -E 'car t=' "$t/server.log" | cut -c 20-90
[ $rc = 0 ] || fail "the server exited with $rc ($t/server.log: $(tail -3 "$t/server.log"))"
grep -q 'the drive is over' "$t/server.log" || fail "no end of the drive"
order=$(sed -n 's/.*Module load order: \[\(.*\)\]/\1/p' "$t/server.log" | tr -d ',')
[ -n "$order" ] || fail "no load order"
for m in loader $order; do
	grep -q "Loading module $m from" "$t/server.log" || fail "$m was not loaded"
done
grep -q 'Failed to construct\|not in this build' "$t/server.log" && fail "$(grep -m1 'Failed to construct\|not in this build' "$t/server.log")"
# The car off its pad: x from 16.9 m to past 25 m in 30 s of second gear
last=$(grep -E 'car t=' "$t/server.log" | tail -1 | sed 's/.*car t=\([0-9.]*\) pos=\([0-9.-]*\),.*/\1 \2/')
read -r secs x <<< "$last"
awk -v x="${x:-0}" 'BEGIN{exit !(x > 25)}' || fail "the car did not climb: $last"
ticks=$(awk -v s="$secs" 'BEGIN{printf "%d", s * 30}')
echo "$ticks ticks (to t=$secs s) in $(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.1f", b - a}') s of wall time, with the start"

# Stopped as the page stops it: <log> <the line to stop at> <js> [args]
stop_run()
{
	local log=$1 ready=$2 p
	shift 2
	(cd "$(dirname "$1")" && exec timeout 90 node "$@" > "$log" 2>&1) &
	p=$!
	CHECK_PIDS+=($p)
	wait_for_log "$log" "$ready" 60 || fail "no \"$ready\" ($log: $(tail -3 "$log"))"
	kill -TERM $p
	wait $p
	rc=$?
	[ $rc = 0 ] || fail "the stopped server exited with $rc ($log: $(tail -3 "$log"))"
	grep -q 'The page asked the server to stop' "$log" || fail "no stop in $log"
}
stop_run "$t/stop.log" 'hillclimb: a public server' "$js" --unconfined -l 3 \
	-m /buildat/apps/hillclimb -S /buildat -U /urho -D /user -C /cache
echo "the page's stop: status 0"

# The fixture: the gate, then the accounts stand-in
EMSDK=${EMSDK:-$HOME/emsdk}
[ -f "$EMSDK/emsdk_env.sh" ] || skip "no emsdk for the fixture (the rest passed)"
source "$EMSDK/emsdk_env.sh" > /dev/null 2>&1
fx="$here/local/check/web_server_fixture"
mkdir -p "$fx/app/probe" "$fx/build"
cat > "$fx/app/probe/probe.cpp" << 'EOF'
// Two peers that are not there: the first to connect is the page's
// player, who joins as "tester"; the second tries to join first
#include "accounts/api.h"
#include "accounts/wire.h"
#include "network/api.h"
#include "storage/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#define MODULE "probe"
namespace probe {
struct Module: public interface::Module
{
	interface::Server *m_server;
	int m_ticks = 0;
	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server){}
	void init()
	{
		sub(m_server, "core:start", &Module::on_start);
		sub(m_server, "core:tick", &Module::on_tick);
	}
	void connect(size_t id)
	{
		network::PeerInfo info;
		info.id = id;
		m_server->emit_event("network:client_connected",
				new network::NewClient(info));
	}
	void login(size_t id, const ss_ &name)
	{
		accounts::LoginRequest r;
		r.name = name;
		m_server->emit_event("network:packet_received/accounts:login",
				new network::Packet(id, "accounts:login", storage::pack(r)));
	}
	void on_start()
	{
		connect(7);
		connect(8);
		login(8, "intruder");
		login(7, "tester");
	}
	void on_tick(const interface::TickEvent &)
	{
		if(++m_ticks != 10)
			return;
		ss_ r;
		accounts::access(m_server, [&](accounts::Interface *a){
			for(auto p : {std::make_pair(7, "tester"),
					std::make_pair(8, "intruder")})
				r += "["+a->name_of(p.first)+" "+
						(a->is_local(p.first) ? "local" : "remote")+" "+
						(a->is_admin(p.second) ? "admin " : "")+
						std::to_string(a->level(p.second))+"]";
		});
		log_i(MODULE, "probe: %s", r.c_str());
	}
};
extern "C" {
	BUILDAT_EXPORT void* createModule_probe(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
EOF
meta()
{
	echo "{\"engine_api\": 2, $1\"dependencies\": [{\"module\": \"accounts\"}]}" \
		> "$fx/app/probe/meta.json"
}
configure()
{
	(cd "$fx/build" && emcmake cmake "$here" -DCMAKE_BUILD_TYPE=Release \
		-DBUILDAT_WEB_SERVER_APP="$fx/app" > "$t/configure.log" 2>&1)
}
meta ""
configure && fail "the build took a module without \"web\": true"
grep -q "^ *$fx/app/probe\$" "$t/configure.log" ||
	fail "the refusal does not name the module ($t/configure.log: $(grep -m3 -A3 Error "$t/configure.log"))"
echo "the gate: the module without \"web\": true refused"
meta '"web": true, '
configure || fail "configure ($t/configure.log: $(tail -5 "$t/configure.log"))"
make -C "$fx/build" -j"$(nproc)" buildat_server > "$t/build.log" 2>&1 ||
	fail "the fixture's build ($t/build.log: $(grep -m3 error "$t/build.log"))"
stop_run "$t/fixture.log" 'probe: ' "$fx/build/bin/buildat_server.js" \
	--unconfined -l 3 -m "/buildat${fx#$here}/app" -S /buildat -U /urho \
	-D /user -C /cache
got=$(sed -n 's/.*probe: //p' "$t/fixture.log")
echo "the accounts stand-in: $got"
[ "$got" = "[tester local admin 40][ remote 0]" ] ||
	fail "the local player is not the admin alone: $got"
echo "PASS: hillclimb's web server: $(echo loader $order | wc -w) modules, $ticks ticks, the car at x=$x; the page's stop, the gate and the accounts stand-in"
