// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// The local server the client starts, stops and adopts, and its state,
// which outlives a CApp reboot; included by app.cpp ([SPLITS]: moved out
// as it was).
#include "core/version.h"

// Survives CApp reboot so disconnect can kill the server we started.
static interface::process::Handle g_local_server;
// Port the local server was told to listen on ("" if none was started)
static ss_ g_local_server_port;
// The game the local server was started with, for the storage of the game
// code it serves
static ss_ g_local_server_app;
// The game id it was started with, as start_local_server() got it
static ss_ g_local_server_game;
// [SERVERLESS_PLAY] The app whose client half runs with no server, its
// storage's name as a local server's (server_app_id), or ""
static ss_ g_serverless_app;
// What the launcher asked of it, the -u lines: sent again on each
// connection (launch:untrusted), since a reused server was started with
// another launch's
static ss_ g_local_server_launch;
// It said it holds no world (launch:reusable): leaving it keeps it
// running, and the next launch of the same app connects to it instead of
// starting another. Any stop clears it.
static bool g_local_server_reusable = false;
// [LOCAL_REJOIN] The next leave_to_menu() keeps it: its goodbye said it
// goes on (a world switch's reload), and the client rejoins it
static bool g_local_server_keep_once = false;
// The watchdog's stall, in seconds; a screen may lower it ([BOX_PLAYTEST_2] 12)
static int g_watchdog_seconds = 10;
// **A script that does not return is stopped, not waited out**: a
// server's Lua has no instruction limit, and `while true do end` froze
// the client for good. After 30 s without a frame the watchdog sets this
// hook from its signal handler, the way luajit's own Ctrl-C does, and
// the first Lua instruction after it errors out to the nearest pcall.
// simplified: a loop LuaJIT has compiled never returns to the
// interpreter, so the hook does not reach it, and a freeze in C++ leaves
// the hook to fire in whatever Lua runs next before the frame clears it
static lua_State *g_watchdog_L = nullptr;
static std::atomic_bool g_watchdog_hooked(false);
static void watchdog_lua_hook(lua_State *L, lua_Debug *ar)
{
	(void)ar;
	lua_sethook(L, nullptr, 0, 0);
	g_watchdog_hooked = false;
	luaL_error(L, "the watchdog stopped Lua that ran for 30 s without a frame");
}
static void watchdog_freeze()
{
	g_watchdog_hooked = true;
	lua_sethook(g_watchdog_L, watchdog_lua_hook,
			LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
}
// The local server's log, tailed for its STATUS lines ([START_PROGRESS])
static ss_ g_local_server_log;
static size_t g_local_server_log_offset = 0;
static bool g_local_server_listening = false;
// What makes this client the local server's owner and admin, and nobody
// else who reaches its port ([SECURITY_RUN_1], decided by the user): made
// fresh per server, handed over in its environment -- a command line is
// every local user's to read -- and sent once connected. Not a script's
// to see.
static ss_ g_local_server_token;
static int64_t g_local_server_started_s = 0;
static ss_ g_local_server_status;

// [PROCESS_SANDBOX] B 2: on Windows the local server is boxed and loopback
// does not reach it, so it is joined, and asked whether it is up, by its
// pipe. "" where loopback is the way (client/wss.h).
static ss_ local_pipe()
{
	if(g_local_server_app.empty() || g_local_server_port.empty())
		return "";
	return client::local_server_pipe(g_local_server_app, g_local_server_port);
}
static ss_ to_local_pipe(const ss_ &address)
{
	const ss_ pipe = local_pipe();
	if(!pipe.empty() && (address == "localhost:"+g_local_server_port ||
			address == "127.0.0.1:"+g_local_server_port))
		return "pipe:"+pipe;
	return address;
}
static bool local_server_answers()
{
	const ss_ pipe = local_pipe();
	if(!pipe.empty())
		return client::pipe_ready(pipe);
	return interface::probe_connect("127.0.0.1", g_local_server_port);
}

// simplified: A free port is picked by probing; a race with another process
// grabbing it in between is possible but harmless for a local game (the server
// exits and the menu says so). Upgrade path: have the server bind port 0 and
// report the actual port back to the client.
static ss_ pick_free_local_port()
{
	std::random_device rd;
	for(int i = 0; i < 100; i++){
		// 29168...29999 is unassigned in IANA's registry and below the
		// ephemeral port range, so nothing else should want it
		int port = 29168 + rd() % 832;
		ss_ port_s = std::to_string(port);
		if(!interface::probe_connect("127.0.0.1", port_s))
			return port_s;
	}
	return "29500";
}

static ss_ pidfile_path()
{
	return g_client_config.get<ss_>("cache_path")+"/local_server.pid";
}

static void clear_pidfile()
{
	remove(pidfile_path().c_str());
}

static void write_pidfile()
{
#ifndef _WIN32
	if(!g_local_server.valid())
		return;
	FILE *f = fopen(pidfile_path().c_str(), "w");
	if(!f)
		return;
	// The server, and the client that started it ([SERVER_ADOPTED]), as
	// key=value lines ([COMPAT_BREAK_07] 8i)
	fprintf(f, "v=1\nversion=%s\nserver=%ld\nclient=%ld\napp=%s\nport=%s\n",
			BUILDAT_VERSION, (long)g_local_server.impl, (long)getpid(),
			g_local_server_app.c_str(), g_local_server_port.c_str());
	fclose(f);
#endif
}

#ifndef _WIN32
static bool exe_is(long pid, const char *name)
{
	char link[64];
	snprintf(link, sizeof link, "/proc/%ld/exe", pid);
	char buf[PATH_MAX];
	ssize_t n = readlink(link, buf, sizeof buf - 1);
	if(n < 0)
		return false;
	buf[n] = 0;
	const char *base = strrchr(buf, '/');
	base = base ? base + 1 : buf;
	return strcmp(base, name) == 0;
}
#endif

static void adopt_pidfile()
{
#ifndef _WIN32
	if(g_local_server.valid() && interface::process::is_running(g_local_server))
		return;
	g_local_server.impl = 0;
	FILE *f = fopen(pidfile_path().c_str(), "r");
	if(!f)
		return;
	long pid = 0, client = 0;
	ss_ v, version;
	char line[256];
	while(fgets(line, sizeof line, f)){
		ss_ l(line);
		const size_t eq = l.find('=');
		if(eq == ss_::npos)
			continue;
		const ss_ key = l.substr(0, eq), value = l.substr(eq + 1,
				l.find_first_of("\r\n") - eq - 1);
		if(key == "v")
			v = value;
		else if(key == "version")
			version = value;
		else if(key == "server")
			pid = atol(value.c_str());
		else if(key == "client")
			client = atol(value.c_str());
	}
	fclose(f);
	// Another version's server (0.6's file is "<server> <client>") is left
	// to its own client
	if(v != "1" || version != BUILDAT_VERSION)
		return;
	if(pid <= 0){
		clear_pidfile();
		return;
	}
	// Another client's server, while that client runs, is that client's to
	// stop: a scripted client quitting beside a person's launcher stopped
	// the person's game ([SERVER_ADOPTED]). Only a server whose client is
	// gone is taken, which is what a crash leaves.
	if(client > 0 && client != (long)getpid() && exe_is(client, "buildat"))
		return;
	if(!exe_is(pid, "buildat_server")){
		clear_pidfile();
		return;
	}
	g_local_server.impl = pid;
	if(!interface::process::is_running(g_local_server)){
		g_local_server.impl = 0;
		clear_pidfile();
		return;
	}
	log_i(MODULE, "Adopted leftover local server pid %ld", pid);
#endif
}

static void request_stop_local_server()
{
	g_local_server_reusable = false;
	adopt_pidfile();
	if(!g_local_server.valid())
		return;
	if(!interface::process::is_running(g_local_server)){
		g_local_server.impl = 0;
		clear_pidfile();
		return;
	}
	log_i(MODULE, "Stopping local server");
	interface::process::request_terminate(g_local_server);
}

static void force_kill_local_server()
{
	g_local_server_reusable = false;
	adopt_pidfile();
	if(!g_local_server.valid())
		return;
	log_w(MODULE, "Force-killing local server");
	interface::process::kill_force(g_local_server);
	clear_pidfile();
}

// Quit path: SIGTERM, wait 10s, SIGKILL. No dialog (window is closing).
// **Stopping the server is a wait, and a wait on the frame is a freeze**
// ([QUIT_STALL], 2026-09-24): terminate() sends SIGTERM and then sleeps
// up to ten seconds waiting to reap, and stop_local_server() then probes
// the port for two more -- twelve seconds of a main thread that is
// reached from a Lua UI handler, so the window is dead to the
// compositor while it sleeps and the watchdog says "no frame for 2 s".
//
// The Lua side asks for this instead: SIGTERM now, and the reaping and
// the force-kill happen a frame at a time in on_update(). The blocking
// one below is kept for the quit path, where there are no more frames
// to do it in.
static bool g_stopping_server = false;
static int64_t g_stopping_since_us = 0;

static void begin_stop_local_server()
{
	g_local_server_reusable = false;
	adopt_pidfile();
	if(!g_local_server.valid())
		return;
	log_i(MODULE, "Stopping local server (across frames)");
	interface::process::request_terminate(g_local_server);
	g_stopping_server = true;
	g_stopping_since_us = get_timeofday_us();
}

// One frame's worth of that wait; returns true while it is still going
static bool step_stop_local_server()
{
	if(!g_stopping_server)
		return false;
	if(interface::process::reap(g_local_server) ||
			!interface::process::is_running(g_local_server)){
		g_stopping_server = false;
		g_local_server.impl = 0;
		clear_pidfile();
		log_i(MODULE, "Local server stopped");
		return false;
	}
	if(get_timeofday_us() - g_stopping_since_us > 10000000){
		log_w(MODULE, "Local server did not stop in 10 s; killing");
		interface::process::kill_force(g_local_server);
		g_stopping_server = false;
		clear_pidfile();
		return false;
	}
	return true;
}

static void stop_local_server()
{
	g_local_server_reusable = false;
	adopt_pidfile();
	if(!g_local_server.valid())
		return;
	log_i(MODULE, "Stopping local server");
	interface::process::terminate(g_local_server);
	clear_pidfile();
	for(int i = 0; i < 40; i++){
		if(!interface::probe_connect("127.0.0.1", g_local_server_port))
			return;
		interface::os::sleep_us(50000);
	}
	log_w(MODULE, "Local server did not release port %s", cs(g_local_server_port));
}
