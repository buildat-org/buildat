#!/bin/bash
# tier: full
# cost: ~30s (2026-10-04); needs a display and reaches starport.buildat.org
# covers: client/extensions/network/init.lua builtin/starport_announce/starport_announce.cpp
# [WEB_ID_RELAY]: the web client has no HTTPS of its own; its server relays a
# raw TCP connection to a Starport and the client runs TLS over it in Lua.
# The relay is one connection per peer, reused back to back. A finished
# connection's last "closed by the Starport" could arrive after the next call
# had taken over the single relay packet handler, so that call failed with a
# relay error before its own response -- the web client then showed "The
# Starport cannot be reached" (or, with a saved login, the password prompt,
# the real reason only in the log). Each call now tags its connection with a
# generation id (client sends it on relay_open, the server echoes it on
# data/closed), so a call ignores what is not its own.
#
# The drive, with no full browser: a native client with BUILDAT_HTTP_RELAY=1
# (the same relay path the page takes) makes several back-to-back calls to the
# real Starport through a local server that lists it. Every call must get its
# own answer; none may fail with "relay:". Reverting the client's gen filter
# makes a middle call fail here.
#
#   util/web_id_relay_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here/Build"
[ -x bin/buildat_server ] || { echo "FAIL: no bin/buildat_server"; exit 1; }
[ -x bin/buildat ] || { echo "FAIL: no bin/buildat"; exit 1; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }

SP=https://starport.buildat.org
# Reach the Starport first; a network-less run would read as the very failure
# this checks for, so skip instead of failing.
curl -sS -o /dev/null --max-time 8 "$SP/api/v1/list" ||
	{ echo "SKIP: $SP not reachable"; exit 0; }

t=$(mktemp -d)
srv=
trap '[ -n "$srv" ] && kill $srv 2>/dev/null; rm -rf "$t"' EXIT
nolog(){ cat "$1"; }
fail(){ echo "FAIL: $*"; exit 1; }

# A throwaway app: it relays (starport_announce) and runs a client script that
# makes the back-to-back calls.
app="$t/relay_test"
mkdir -p "$app/main/client_lua"
cat > "$app/main/meta.json" <<'EOF'
{
	"engine_api": 2,
	"dependencies": [
		{"module": "network"},
		{"module": "client_lua"},
		{"module": "client_data"},
		{"module": "starport_announce"}
	]
}
EOF
cat > "$app/main/main.cpp" <<'EOF'
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "network/api.h"
#include "client_file/api.h"
#define MODULE "main"
using interface::Event;
namespace main {
struct Module: public interface::Module
{
	interface::Server *m_server;
	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server){}
	void init()
	{
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
	}
	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
	}
	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
		});
	}
};
extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
EOF
cat > "$app/main/client_lua/init.lua" <<EOF
local log = buildat.Logger("relay_test")
local network = require("buildat/extension/network")
local SP = "$SP"
local total = 6
local n, fails = 0, 0
-- /api/v1/id/token with no session answers {ok=false,error="session"} (a 200);
-- what matters is that each back-to-back call gets its own answer, not a
-- relay error left by the one before it.
local function fire(i)
	network.http_post(SP .. "/api/v1/id/token",
		network.write_json({session = "", listing = false,
			address = "relaytest", name = "x"}),
		function(body, err)
			n = n + 1
			if body then
				log:info("RELAYTEST " .. i .. ": OK " .. #body)
			else
				fails = fails + 1
				log:info("RELAYTEST " .. i .. ": ERR " .. tostring(err))
			end
			if n >= total then
				log:info("RELAYTEST SUMMARY fails=" .. fails)
				log:info("RELAYTEST END")
			end
		end)
end
for i = 1, total do fire(i) end
EOF

port=29646
srvuser="$t/sp"
# The relay allowlist: the server must list this Starport for on_relay_open to
# dial out to it. get_app_id is the -m path's last component (relay_test).
mkdir -p "$srvuser/apps/relay_test"
cat > "$srvuser/apps/relay_test/starport.json" <<EOF
{"enabled": true, "starports": ["$SP"]}
EOF

# The first start compiles the builtin modules and the app (rccpp)
start_server "$t/sp.log" "STATUS Listening" 120 "$port" \
	bin/buildat_server -m "$app" -D "$srvuser" -l 3 ||
	fail "server did not listen (sp.log)"
srv=$SERVER_PID

# Pre-accept the Starport address so the client's per-address network gate does
# not open a dialog ([CONSENT_PER_SERVER]). The app calls network.http_post,
# which keys the acceptance by the server this client is on (asking_server()),
# so the last column is that address, not empty.
mkdir -p "$t/cl"
now=$(date +%s)
printf 'accepted,address,description,created,last_attempt,name,icon,server\n'\
'true,%s,relaytest,%s,%s,,,127.0.0.1:%s\n' "$SP" "$now" "$now" "$port" \
	> "$t/cl/network_addresses.csv"

cat > "$t/cmds" <<EOF
wait_log 30000 RELAYTEST END
quit
EOF
BUILDAT_HTTP_RELAY=1 \
	timeout 60 bin/buildat -o launch_ui=launch_menu -D "$t/cl" -w 800x600 -l 3 -o sound_mute=1 \
	-s "127.0.0.1:$port" -c @"$t/cmds" > "$t/cl.log" 2>&1

nolog "$t/cl.log" | grep -q "RELAYTEST END" ||
	fail "the calls did not finish ($(nolog "$t/cl.log" | grep RELAYTEST | tail -3); $(nolog "$t/cl.log" | tail -3))"
echo "--- calls:"
nolog "$t/cl.log" | grep "RELAYTEST"
fails=$(nolog "$t/cl.log" | sed -n 's/.*RELAYTEST SUMMARY fails=\([0-9]*\).*/\1/p')
[ "${fails:-1}" = "0" ] ||
	fail "$fails of 6 relay calls failed with a relay error (the race)"

echo "PASS: back-to-back relay calls each got their own answer"
