#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: 90s
# [API_DEFAULTS_07]: a peer that stops reading, under the default send
# policy and under Buffer asked for. A server app (written here) sends in
# bulk to the one client that joins; the client is stopped with SIGSTOP
# once it has joined, so its socket stays open and reads nothing. With
# the app saying nothing about the policy, the peer is disconnected once
# it has been over 8 MB for the 30 s grace. With Buffer asked for, it is
# still connected 40 s after going over. Prints PASS or FAIL.
#
#   builtin/network/send_policy_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp send_policy
# Under the repo, not /tmp: the boxed server reads nothing in /tmp
app="$here/local/send_policy"
rm -rf "$app"
mkdir -p "$app/main/client_lua" "$app/main/client_data"
cat > "$app/main/meta.json" <<'JSON'
{
	"engine_api": 2,
	"kind": "check",
	"client_main": "init.lua",
	"dependencies": [
		{"module": "network"},
		{"module": "client_lua"},
		{"module": "client_data"}
	]
}
JSON
cat > "$app/main/client_lua/init.lua" <<'LUA'
buildat.sub_packet("main:bulk", function(data) end)
LUA
cat > "$app/main/main.cpp" <<'CPP'
// send_policy_check.sh's app: SEND_POLICY_MODE is default or buffer
#include "core/log.h"
#include "network/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/os.h"
#include <cstdlib>
#define MODULE "main"
using interface::Event;

namespace main {

static const size_t OVER = 8 * 1024 * 1024;

struct Module: public interface::Module
{
	interface::Server *m_server;
	bool m_buffer = false;
	network::PeerInfo::Id m_peer = 0;
	int64_t m_joined_us = 0;
	int64_t m_over_us = 0;
	int64_t m_logged_us = 0;
	bool m_done = false;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("network:client_connected", on_connected,
				network::NewClient)
		EVENT_TYPEN("network:client_disconnected", on_disconnected,
				network::OldClient)
	}

	void on_start()
	{
		const char *m = getenv("SEND_POLICY_MODE");
		m_buffer = m && ss_(m) == "buffer";
		if(m_buffer){
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->set_send_policy(network::SendPolicy::Buffer, 0, 0);
			});
		}
		log_i(MODULE, "sp: mode %s", m_buffer ? "buffer" : "default");
	}

	void on_connected(const network::NewClient &event)
	{
		if(m_peer != 0)
			return;
		m_peer = event.info.id;
		m_joined_us = interface::os::time_us();
		log_i(MODULE, "sp: joined %zu", (size_t)m_peer);
	}

	void on_disconnected(const network::OldClient &event)
	{
		if(event.info.id != m_peer || m_done)
			return;
		const int64_t now = interface::os::time_us();
		log_i(MODULE, "sp: disconnected, %.0f s after going over",
				m_over_us ? (now - m_over_us) / 1e6 : -1.0);
		finish(0);
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(m_peer == 0 || m_done)
			return;
		const int64_t now = interface::os::time_us();
		// The script stops the client on the join line; the bulk waits
		// for that
		if(now - m_joined_us < 2000000)
			return;
		network::access(m_server, [&](network::Interface *inetwork){
			size_t pending = inetwork->pending_bytes(m_peer);
			// Three times the limit is plenty, and keeps Buffer's memory
			// bounded here
			for(int i = 0; i < 4 && pending < 3 * OVER; i++){
				inetwork->send(m_peer, "main:bulk", ss_(256 * 1024, 'x'));
				pending = inetwork->pending_bytes(m_peer);
			}
			if(pending > OVER && m_over_us == 0){
				m_over_us = now;
				log_i(MODULE, "sp: over 8 MB");
			}
			if(now - m_logged_us > 5000000){
				m_logged_us = now;
				log_i(MODULE, "sp: %zu bytes pending", pending);
			}
		});
		if(m_buffer && m_over_us != 0 && now - m_over_us > 40000000){
			log_i(MODULE, "sp: still connected 40 s after going over");
			finish(0);
		} else if(now - m_joined_us > 120000000){
			log_i(MODULE, "sp: nothing happened in 120 s");
			finish(1);
		}
	}

	void finish(int status)
	{
		m_done = true;
		m_server->shutdown(status, "send_policy_check");
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
CPP

cd "$here/Build"
client=""
cleanup()
{
	[ -n "$client" ] && kill -9 "$client" 2>/dev/null
	[ -n "${SERVER_PID:-}" ] && kill -9 "$SERVER_PID" 2>/dev/null
	check_cleanup
}
trap cleanup EXIT

# One run: the server with SEND_POLICY_MODE=$1, a client stopped once it
# has joined, and the server's own end of the run waited for
run()
{
	local mode=$1
	SEND_POLICY_MODE=$mode start_server "$CHECK_TMP/$mode.log" "STATUS Listening" 60 auto \
		timeout 180 bin/buildat_server -m "$app" ||
		fail "the $mode server did not come up ($CHECK_TMP/$mode.log)"
	timeout 180 bin/buildat -o launch_ui=launch_menu -s "localhost:$SERVER_PORT" \
		-w 640x360 > "$CHECK_TMP/$mode.cli.log" 2>&1 &
	client=$!
	local i
	for i in $(seq 300); do
		grep -aq "sp: joined" "$CHECK_TMP/$mode.log" && break
		sleep 0.1
	done
	grep -aq "sp: joined" "$CHECK_TMP/$mode.log" ||
		fail "$mode: the client did not join ($CHECK_TMP/$mode.cli.log)"
	# simplified: the timeout wrapper is stopped with the client; both are
	# killed after
	pkill -STOP -P "$client"
	wait "$SERVER_PID"
	kill -9 "$client" 2>/dev/null; pkill -9 -P "$client" 2>/dev/null
	wait "$client" 2>/dev/null
	client=""
	SERVER_PID=""
}

run default
grep -aq "sp: over 8 MB" "$CHECK_TMP/default.log" ||
	fail "default: never over 8 MB: $(grep -a 'sp: ' "$CHECK_TMP/default.log" | tail -2)"
grep -aq "sp: disconnected" "$CHECK_TMP/default.log" ||
	fail "default: the peer was not disconnected: $(grep -a 'sp: ' "$CHECK_TMP/default.log" | tail -2)"
grep -aq "has read nothing of" "$CHECK_TMP/default.log" ||
	fail "default: disconnected, but not by the send policy"
after=$(grep -a "sp: disconnected" "$CHECK_TMP/default.log" | sed 's/.*, \([0-9-]*\) s after.*/\1/')

run buffer
grep -aq "sp: still connected 40 s after going over" "$CHECK_TMP/buffer.log" ||
	fail "buffer: $(grep -a 'sp: \|has read nothing' "$CHECK_TMP/buffer.log" | tail -2)"
rm -rf "$app"
echo "PASS: a peer that reads nothing is let go ${after} s after going over 8 MB by default, and kept 40 s past it with Buffer asked for"
# vim: set noet ts=4 sw=4:
