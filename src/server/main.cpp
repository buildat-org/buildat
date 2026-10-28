// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/fs.h"
#include "core/types.h"
#include "core/log.h"
#include "core/version.h"
#include "core/config.h"
#include "boot/basic_init.h"
#include "boot/autodetect.h"
#include "server/config.h"
#include "server/state.h"
#include "server/confine.h"
#include "server/wasm_build.h"
#include "interface/server.h"
#include "interface/debug.h"
#include "interface/os.h"
#include <c55/getopt.h>
#include <c55/os.h>
#include <iostream>
#include <fstream>
#include <algorithm>
#include <climits>
#include <cstdlib> // srand()
#include <signal.h>
#include <malloc.h> // mallopt(), M_PERTURB
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#include <atomic>
#endif
#include <string.h> // strerror()
#include <time.h> // struct timeval
#define MODULE "main"

server::Config g_server_config;

// The signal that asked for shutdown, read by the main loop. Only things a
// signal handler may touch belong in here: no logging, no locking, no
// allocation. The loop does all of that once it sees this.
volatile sig_atomic_t g_shutdown_signal = 0;

void shutdown_signal_handler(int sig)
{
	if(g_shutdown_signal == 0){
		g_shutdown_signal = sig;
	} else {
		// Asked twice: the shutdown is not getting anywhere, so let the
		// default action have the process
		(void)signal(sig, SIG_DFL);
		(void)raise(sig);
	}
}

#ifdef __EMSCRIPTEN__
// [WEB_LOCAL_SERVER]: no signal reaches a server in a page. The page calls
// Module._buildat_server_stop() from any thread, and the main loop shuts
// down as on SIGTERM.
static std::atomic<bool> g_stop_asked(false);
extern "C" EMSCRIPTEN_KEEPALIVE void buildat_server_stop()
{
	g_stop_asked = true;
}
#endif

void signal_handler_init()
{
	(void)signal(SIGINT, shutdown_signal_handler);
	(void)signal(SIGTERM, shutdown_signal_handler);
#ifndef _WIN32
	(void)signal(SIGPIPE, SIG_IGN);
#endif
}

int main(int argc, char *argv[])
{
	boot::BasicInitScope basic_init_scope;

	// glibc fills a freed block with 0x5a and a fresh one with 0xa5 when
	// this is set, which turns a read of a freed object from a value that
	// looks plausible into one that names itself: 0x5a5a5a5a5a5a5a5a in a
	// backtrace says "freed" at a glance and 0xa5a5... says "never
	// written". It costs a memset per allocation and nothing else, so it is
	// on in every build that has its asserts -- which is every ordinary one,
	// the default build type being Debug. MALLOC_PERTURB_=90 does the same
	// for a binary already built.
	//
	// Measured here rather than assumed, because two things about it are not
	// what one would guess: a small free goes to the tcache and is *not*
	// poisoned while that bin has room -- seven per size class -- and the
	// first sixteen bytes of a poisoned small chunk hold glibc's own links
	// rather than the pattern. A large block is poisoned from its first
	// byte. So this catches a great deal and promises nothing; the
	// quarantine is a sanitizer's job. See doc/plan/master_plan.md,
	// "Catching a use-after-free before it is a mystery".
#ifndef NDEBUG
	mallopt(M_PERTURB, 0x5a);
#endif

	server::Config &config = g_server_config;

#if defined(__linux__) && !defined(__EMSCRIPTEN__)
	// [WEB_LOCAL_AITTA] Aitta's build of a release's .wasm, in a box of
	// its own, and nothing else; [WEB_LOCAL_AITTA_CPP] with a kit, its C++
	// server for the page as well
	if((argc == 4 || argc == 5) && ss_(argv[1]) == "--build-wasm")
		return server::build_wasm_job(argv[2], argv[3], argc == 5 ? argv[4] : "");
#endif

	std::string module_path;
	bool port_given = false, proxies_given = false;

	// [PROCESS_SANDBOX]: --unconfined, taken out before getopt, which
	// knows no long options; BUILDAT_UNCONFINED=1 says the same
	bool unconfined = interface::os::unconfined_by_env();
	// --connect-ports P,Q: what a boxed server may connect to beyond
	// buildat's own ports; also BUILDAT_CONNECT_PORTS
	if(getenv("BUILDAT_CONNECT_PORTS"))
		config.set("connect_ports", ss_(getenv("BUILDAT_CONNECT_PORTS")));
	// The launcher's owner token: kept in the config, where no game's Lua
	// reaches, and out of the environment, where os.getenv() would
	if(const char *token = getenv("BUILDAT_OWNER_TOKEN")){
		config.set("owner_token", ss_(token));
#ifdef _WIN32
		_putenv_s("BUILDAT_OWNER_TOKEN", "");
#else
		unsetenv("BUILDAT_OWNER_TOKEN");
#endif
	}
	// [LOGIN_UNLOADED]: how long a login waits for its TOTP code, seconds;
	// shorter for a check
	if(getenv("BUILDAT_TOTP_WAIT_S"))
		config.set("totp_wait_s", ss_(getenv("BUILDAT_TOTP_WAIT_S")));
	// [ADMIN_NOTIFY]: the ntfy pushes' window, seconds; shorter for a check
	if(getenv("BUILDAT_NTFY_BATCH_S"))
		config.set("ntfy_batch_s", ss_(getenv("BUILDAT_NTFY_BATCH_S")));
	if(getenv("BUILDAT_LAN_ANNOUNCE"))
		config.set("lan_announce", ss_(getenv("BUILDAT_LAN_ANNOUNCE")));
	for(int i = 1; i < argc; i++){
		int take = 0;
		if(ss_(argv[i]) == "--unconfined"){
			unconfined = true;
			take = 1;
		} else if(ss_(argv[i]) == "--boxed"){
			// The child a boxed parent started (Windows); see confine.h
			config.set("boxed", true);
			take = 1;
		} else if(ss_(argv[i]) == "--compile-only"){
			// [COMPILE_ONLY]: the modules compiled and loaded, then out
			// before core:start opens the port; for runs whose clock a
			// first start's compile would otherwise eat
			config.set("compile_only", true);
			take = 1;
		} else if(ss_(argv[i]) == "--sim-clock"){
			// [SIM_CLOCK]: a check moves the calendar by writing seconds
			// to <user_path>/sim_clock; only from this command line
			config.set("sim_clock", true);
			take = 1;
		} else if(ss_(argv[i]) == "--free-run"){
			// [SERVER_FREE_RUN]: ticks back to back, for a headless check
			// that measures the game; only from this command line
			config.set("free_run", true);
			take = 1;
		} else if(ss_(argv[i]) == "--lan-announce" && i + 1 < argc){
			config.set("lan_announce", ss_(argv[i + 1]));
			take = 2;
		} else if(ss_(argv[i]) == "--connect-ports" && i + 1 < argc){
			config.set("connect_ports", ss_(argv[i + 1]));
			take = 2;
		} else if((ss_(argv[i]) == "--max-players" ||
				ss_(argv[i]) == "--max-view-range" ||
				ss_(argv[i]) == "--max-disk-mb" ||
				ss_(argv[i]) == "--max-world-mb") && i + 1 < argc){
			// [SERVER_CAPS]: --max-players N -> max_players, a number
			ss_ key = ss_(argv[i]).substr(2);
			std::replace(key.begin(), key.end(), '-', '_');
			if(key == "max_world_mb")
				key = "max_disk_mb";
			const ss_ v = argv[i + 1];
			if(v.empty() || v.size() > 12 ||
					v.find_first_not_of("0123456789") != ss_::npos){
				std::cerr<<argv[i]<<" takes a number"<<std::endl;
				return 1;
			}
			config.set(key, v);
			take = 2;
		} else if(ss_(argv[i]) == "--save-interval" && i + 1 < argc){
			// [SAVE_CHECKPOINT]: seconds, 0 none
			const ss_ v = argv[i + 1];
			char *end = nullptr;
			const double d = strtod(v.c_str(), &end);
			if(v.empty() || *end || !(d >= 0) || d > 86400){
				std::cerr<<"--save-interval takes seconds"<<std::endl;
				return 1;
			}
			config.set("save_interval_s", v);
			take = 2;
		}
		if(!take)
			continue;
		for(int j = i; j < argc - take; j++)
			argv[j] = argv[j + take];
		argc -= take;
		i--;
	}

	const char opts[100] = "hm:r:i:S:D:U:c:l:L:C:A:P:W:T:wRu:x:";
	const char usagefmt[] =
			"Usage: %s [OPTION]...\n"
			"  -h                   Show this help\n"
			"  -m [module_path]     Specify module path\n"
			"  -r [rccpp_build_path]Specify runtime compiled C++ build path\n"
			"  -i [interface_path]  Specify path to interface headers\n"
			"  -S [share_path]      Specify path to share/\n"
			"  -D [user_path]       Specify user/ path (saves live here)\n"
			"  -C [cache_path]      Specify cache/ path (compiled modules, the\n"
			"                       runtime build under it); the client's -C\n"
			"  -U [urho3d_path]     Specify Urho3D path\n"
			"  -c [command]         Set compiler command\n"
			"  -l [integer]         Set maximum log level (0...5)\n"
			"  -L [log file path]   Append log to a specified file\n"
			"  -x [module_name]     Skip compiling specified module\n"
			"  -A [address]         Set listening address (default any: IPv6 and IPv4)\n"
			"  -P [port]            Set network port (default 29500, or the\n"
			"                       app's default_port: Starport's 29595)\n"
			"  -W [web_client_path] Serve the web client from here\n"
			"                       (default share_path/web)\n"
			"  -T [proxies]         Believe X-Forwarded-For from these\n"
			"                       (comma separated; default 127.0.0.1,::1)\n"
			"  -w                   Watch served files and push changes to\n"
			"                       connected clients (for development)\n"
			"  -R                   Restart a module when its source changes\n"
			"                       (for development; off by default)\n"
			"  -u [key=value lines] What an untrusted launcher asked for\n"
			"                       (the launch grid; a module reads it as it\n"
			"                       would a packet)\n"
			"  --connect-ports P,Q  Ports the sandboxed server may\n"
			"                       connect to\n"
			"                       beyond 80, 443, 465, 587, 29500 and\n"
			"                       29595, or \"any\" (also\n"
			"                       BUILDAT_CONNECT_PORTS)\n"
			"  --lan-announce NAME  Announce this server to the LAN under\n"
			"                       NAME (also BUILDAT_LAN_ANNOUNCE)\n"
			"  --max-players N      Players at once; admins join over it\n"
			"  --max-view-range N   The world sent to a client, in voxels\n"
			"  --max-disk-mb N      What the app may write (its saves,\n"
			"                       games, cache); over it a world forgets\n"
			"                       land nobody changed, and at it nothing\n"
			"                       new is generated (--max-world-mb)\n"
			"  --save-interval S    Seconds between writes of a running\n"
			"                       world (5.3; 0 only at shutdown)\n"
			"  --unconfined         Run without the sandbox (also\n"
			"                       BUILDAT_UNCONFINED=1): the app reaches\n"
			"                       all of your files\n"
			"  --compile-only       Compile and load the modules, then exit\n"
			"                       (1 if one failed); nothing is opened\n"
			"  --sim-clock          Run the calendar ahead by the seconds\n"
			"                       in user_path/sim_clock, read every tick\n"
			"                       (for checks)\n"
			"  --free-run           Tick as fast as the modules go, not with\n"
			"                       the clock; headless (for checks): no\n"
			"                       client is let in, and with --lan-announce,\n"
			"                       -W or -T it does not start\n"
			"\n"
			"Environment:\n"
			"  BUILDAT_USER_PATH    As -D, where -D is not given\n"
			"  BUILDAT_CACHE_PATH   As -C, where -C is not given\n"
			"  BUILDAT_LOG_CAP_BYTES  Bytes at which the log file is moved to\n"
			"                       <file>_1 and begun again (512 MB)\n"
			;

	int c;
	// What this is, before anything else, so every log begins with it
	log_i(MODULE, "%s %s (%s)", "buildat_server", BUILDAT_VERSION, BUILDAT_GIT_HASH);
	while((c = c55_getopt(argc, argv, opts)) != -1)
	{
		switch(c)
		{
		case 'h':
			printf(usagefmt, argv[0]);
			return 1;
		case 'm':
			log_i(MODULE, "module_path: %s", c55_optarg);
			module_path = c55_optarg;
			break;
		case 'u':
			// The launch grid's params, one key=value a line, from a
			// sandboxed launcher file through the client: a module reads
			// it under this name, which says what it is, and treats it as
			// a packet from a server ([LAUNCH_GRID])
			log_i(MODULE, "config.untrusted_launch: %zu bytes",
					strlen(c55_optarg));
			config.set("untrusted_launch", c55_optarg);
			break;
		case 'r':
			log_i(MODULE, "config.rccpp_build_path: %s", c55_optarg);
			config.set("rccpp_build_path", c55_optarg);
			break;
		case 'i':
			log_i(MODULE, "config.interface_path: %s", c55_optarg);
			config.set("interface_path", c55_optarg);
			break;
		case 'S':
			log_i(MODULE, "config.share_path: %s", c55_optarg);
			config.set("share_path", c55_optarg);
			break;
		case 'D':
			log_i(MODULE, "config.user_path: %s", c55_optarg);
			config.set("user_path", c55_optarg);
			break;
		case 'C':
			log_i(MODULE, "config.cache_path: %s", c55_optarg);
			config.set("cache_path", c55_optarg);
			break;
		case 'U':
			log_i(MODULE, "config.urho3d_path: %s", c55_optarg);
			config.set("urho3d_path", c55_optarg);
			break;
		case 'c':
			log_i(MODULE, "config.compiler_command: %s", c55_optarg);
			config.set("compiler_command", c55_optarg);
			break;
		case 'A':
			log_i(MODULE, "config.network_address: %s", c55_optarg);
			config.set("network_address", c55_optarg);
			break;
		case 'P':
			log_i(MODULE, "config.network_port: %s", c55_optarg);
			config.set("network_port", c55_optarg);
			port_given = true;
			break;
		case 'W':
			log_i(MODULE, "config.web_client_path: %s", c55_optarg);
			config.set("web_client_path", c55_optarg);
			break;
		case 'T':
			log_i(MODULE, "config.web_trusted_proxies: %s", c55_optarg);
			config.set("web_trusted_proxies", c55_optarg);
			proxies_given = true;
			break;
		case 'w':
			config.set("watch_client_files", true);
			break;
		case 'R':
			config.set("reload_modules", true);
			break;
		case 'l':
			log_set_max_level(atoi(c55_optarg));
			config.set("log_level_given", true);
			break;
		case 'L':
			// Opened once the paths are settled (boot::autodetect::open_log),
			// absolute against the cwd; kept here until then
			config.set("log_file", c55_optarg);
			break;
		case 'x':
			log_i(MODULE, "config.skip_compiling_modules += %s",
					c55_optarg);
			{
				auto v = config.get<json::Value>("skip_compiling_modules");
				v.set(c55_optarg, json::Value(true));
				config.set("skip_compiling_modules", v);
			}
			break;
		default:
			fprintf(stderr, "ERROR: Invalid command-line argument\n");
			fprintf(stderr, usagefmt, argv[0]);
			return 1;
		}
	}

	std::cerr<<"Buildat server"<<std::endl;

	// The whole fault this warns about is a restart nobody was told about,
	// so it says once that it can happen; "reload_module" in the log is
	// where it did
	if(config.get<bool>("reload_modules")){
		log_i(MODULE, "Module hot-reload is on: a module is restarted when "
				"its source changes, and whatever it was holding goes with "
				"it");
	}

	signal_handler_init();
	interface::os::die_with_parent_if_asked();

	// **A boxed child takes the paths its parent settled**: detecting them
	// writes where the box cannot, and the parent did it, the log and the
	// move of old directories with it. Its output is the parent's to log.
	const bool boxed = config.get<bool>("boxed");
	if(boxed){
		// Its output is a pipe to its parent: unbuffered, so what it shows
		// is where the child is
		setvbuf(stdout, nullptr, _IONBF, 0);
		setvbuf(stderr, nullptr, _IONBF, 0);
		server::boxed_step("main: the arguments read");
		const char *paths = getenv("BUILDAT_BOXED_PATHS");
		ss_ all = paths ? paths : "";
		size_t at = 0;
		while(at < all.size()){
			size_t nl = all.find('\n', at);
			if(nl == ss_::npos)
				nl = all.size();
			const ss_ kv = all.substr(at, nl - at);
			const size_t eq = kv.find('=');
			if(eq != ss_::npos)
				config.set(kv.substr(0, eq), kv.substr(eq + 1));
			at = nl + 1;
		}
		server::boxed_step("main: the parent's paths taken");
		// Its own name, so that a forced crash can pick the box
		interface::debug::set_crash_dump_dir(config.get<ss_>("cache_path"),
				"buildat_server_boxed");
	} else {
#ifdef BUILDAT_STATIC_MODULES
		// [WEB_LOCAL_SERVER]: the page names every path, in a file system
		// with no compiler, sources or engine data, and the log is the
		// console's
		interface::fs::create_directories(config.get<ss_>("user_path"));
		interface::fs::create_directories(config.get<ss_>("cache_path"));
#else
		if(!boot::autodetect::detect_server_paths(config))
			return 1;
		boot::autodetect::open_log(config, "buildat_server", argv[0]);
		if(!config.check_paths()){
			return 1;
		}
#endif
		interface::fs::migrate_user_apps(config.get<ss_>("user_path"));
		// [FIRST_ADMIN]: the admin's file <user>/first_admin, one line, read
		// here, where the box does not hide the user path's top level, and
		// removed, as it can hold a password; the accounts module applies it
		// to a server with no admin. Left alone by --compile-only, which
		// starts no accounts and would use it up before the start that
		// does ([FIRST_ADMIN_KEPT])
		const ss_ path = config.get<ss_>("user_path")+"/first_admin";
		std::ifstream f;
		if(!config.get<bool>("compile_only"))
			f.open(path);
		ss_ line;
		if(std::getline(f, line)){
			f.close();
			if(!line.empty() && line.back() == '\r')
				line.pop_back();
			config.set("first_admin", line);
			if(remove(path.c_str()) != 0)
				log_w(MODULE, "%s read; it could not be removed", cs(path));
		}
	}

	if(module_path.empty()){
		std::cerr<<"Module path (-m) is empty"<<std::endl;
		return 1;
	}
	// **An app's own default port** ([STARPORT] 10g): apps/<app>/default_port,
	// one number, where -P says none -- Starport's is 29595, so a Starport
	// and a server of another app share an address without either naming
	// a port
	if(!port_given){
		std::ifstream f(module_path+"/default_port");
		int port = 0;
		if(f >> port && port > 0 && port < 65536){
			log_i(MODULE, "config.network_port: %i (the app's default_port)",
					port);
			config.set("network_port", itos(port));
		}
	}

	// [SIM_CLOCK]: opened before the box, which hides the user path's
	// root; read again every tick, so a check writes it in place.
	// simplified: a Windows box's child opens it after the box, and needs
	// --unconfined for it
	// [SERVER_FREE_RUN]: headless only; a public server's flags with it
	// are a mistake, and it does not start
	const bool free_run = config.get<bool>("free_run");
	if(free_run){
		if(!config.get<ss_>("lan_announce").empty() ||
				!config.get<ss_>("web_client_path").empty() ||
				proxies_given){
			log_e(MODULE, "--free-run is for a headless check; not with "
					"--lan-announce, -W or -T");
			return 1;
		}
		log_w(MODULE, "--free-run: the ticks go as fast as the modules "
				"take them, and no client is let in");
	}

	FILE *sim_clock = nullptr;
	if(config.get<bool>("sim_clock")){
		const ss_ path = config.get<ss_>("user_path")+"/sim_clock";
		sim_clock = fopen(path.c_str(), "a+");
		if(!sim_clock){
			log_e(MODULE, "--sim-clock: cannot open %s", cs(path));
			return 1;
		}
		// Unbuffered: a rewind within the buffer would read it again
		setvbuf(sim_clock, nullptr, _IONBF, 0);
		log_w(MODULE, "--sim-clock: the calendar is what %s says", cs(path));
	}

	// [COMPILE_SLOTS] Opened where /tmp still is, before the box
	server::open_compile_slots();
	// [CLIENT_WASM] Looked for before the box, which is given their
	// directories to read
	server::find_wasm_toolchain(config);
	// [PROCESS_SANDBOX]: the box, before anything of the app is loaded.
	// Where it cannot be made the server refuses to start (decided
	// 2026-10-02), and says how to start it anyway.
	if(unconfined){
		log_w(MODULE, "Unconfined (--unconfined or BUILDAT_UNCONFINED=1): "
				"the app can reach every file you can");
		config.set("box", "off (--unconfined)");
	} else {
		// Windows: the unboxed process is the box's parent, and is done
		// when its child is -- whatever the child's code, never running
		// the app itself
		int child_exit = -1;
		const ss_ why = server::confine(config, module_path, &child_exit);
		if(child_exit != -1)
			return child_exit;
		if(!why.empty()){
			log_e(MODULE, "The server's sandbox could not be made: %s. Starting "
					"an app unsandboxed lets it reach every file you can; to do "
					"that anyway, give --unconfined or set "
					"BUILDAT_UNCONFINED=1.", cs(why));
			return 1;
		}
#ifdef _WIN32
		if(config.get<ss_>("box").empty())
			config.set("box", config.get<bool>("boxed") ?
					"an AppContainer and a job object" :
					"off (BUILDAT_WINDOWS_SANDBOX=0)");
#endif
	}

	int exit_status = 0;
	ss_ shutdown_reason;

	try {
		server::boxed_step("main: making the state");
		up_<server::State> state(server::createState());
		server::boxed_step("main: loading the modules");

		state->load_modules(module_path);
		if(config.get<bool>("compile_only")){
			// Nothing started, so nothing has anything to save: no
			// core:shutdown. A module that failed shut the server down
			// with its name logged
			if(!state->is_shutdown_requested(&exit_status, &shutdown_reason))
				log_i(MODULE, "--compile-only: every module compiled");
			state->thread_request_stop();
			state->thread_join();
			return exit_status;
		}
		server::boxed_step("main: the modules loaded; the main loop");

		// Main loop
		uint64_t next_tick_us = get_timeofday_us();
		uint64_t t_per_tick = 1000000 / 30; // Same as physics FPS
		long long sim_offset_s = 0;
		uint64_t free_ticks = 0;
		const uint64_t free_start_us = next_tick_us;
		// **Save now** ([USER_DIR_COPY]): <user>/apps/<app>/save_now, looked
		// for once a second (in the app's directory, which the box reads):
		// core:save to every module, synchronously, and then the file
		// removed -- gone, everything a game holds is on disk, and a
		// snapshot of the user directory loses nothing
		const ss_ save_now_path = config.get<ss_>("user_path")+"/apps/"+
				server::app_of(module_path)+"/save_now";
		uint64_t next_save_look_us = 0;

		for(;;){
			if(g_shutdown_signal != 0){
				// SIGINT leaves a "^C" on the terminal to write past
				if(g_shutdown_signal == SIGINT)
					fprintf(stdout, "\n");
				log_i(MODULE, "%s; shutting down",
						g_shutdown_signal == SIGINT ? "SIGINT" : "SIGTERM");
				shutdown_reason = "Signal";
				break;
			}
#ifdef __EMSCRIPTEN__
			if(g_stop_asked){
				log_i(MODULE, "The page asked the server to stop; shutting "
						"down");
				shutdown_reason = "Stopped by the page";
				break;
			}
#endif
			uint64_t current_us = get_timeofday_us();
			int64_t delay_us = next_tick_us - current_us;
			if(delay_us < 0)
				delay_us = 0;

			if(!free_run)
				usleep(delay_us);

			state->handle_events();

			if(free_run || current_us >= next_tick_us){
				next_tick_us += t_per_tick;
				if(free_run){
					// The pace, every simulated ten minutes
					if(++free_ticks % (30 * 600) == 0){
						const double wall = (current_us - free_start_us) / 1e6;
						log_i(MODULE, "free-run: %.0f s simulated in %.1f s "
								"(%.1fx)", free_ticks / 30.0, wall,
								free_ticks / 30.0 / std::max(wall, 1e-3));
					}
				} else if(next_tick_us < current_us - 1000 * 1000){
					log_w("main", "Skipping %zuus", current_us - next_tick_us);
					next_tick_us = current_us;
				}
				// [SIM_CLOCK]: a jump is seen by the tick after it, once:
				// whatever runs on the calendar compares against it
				long long v = 0;
				if(sim_clock){
					rewind(sim_clock);
					if(fscanf(sim_clock, "%lld", &v) == 1 && v != sim_offset_s){
						sim_offset_s = v;
						interface::os::set_wall_offset_us(v * 1000000);
						log_i(MODULE, "sim clock: %llds ahead", v);
					}
				}
				interface::Event event("core:tick",
						new interface::TickEvent(t_per_tick / 1e6));
				// Free-running, the next tick waits for every module to
				// have taken this one, or the queue would only grow
				if(free_run)
					state->emit_event_synchronously(std::move(event));
				else
					state->emit_event(std::move(event));
				if(current_us >= next_save_look_us){
					next_save_look_us = current_us + 1000000;
					if(interface::fs::path_exists(save_now_path)){
						log_i(MODULE, "save_now: saving");
						state->emit_event_synchronously(
								interface::Event("core:save"));
						::remove(save_now_path.c_str());
						log_i(MODULE, "save_now: saved");
					}
				}
			}

			if(state->is_shutdown_requested(&exit_status, &shutdown_reason))
				break;
		}

		// Whatever a module is holding gets one last chance to reach the
		// disk. Synchronous, because the main loop is over and a queued
		// event would never be handled; before the module threads stop,
		// because a module's work happens in one.
		state->emit_event_synchronously(interface::Event("core:shutdown"));

		state->thread_request_stop();
		state->thread_join();
	} catch(server::ServerShutdownRequest &e){
		log_v(MODULE, "ServerShutdownRequest: %s", e.what());
	}
	log_d(MODULE, "The state is gone");

	if(shutdown_reason != ""){
		if(exit_status != 0)
			log_w(MODULE, "Shutdown: %s", cs(shutdown_reason));
		else
			log_v(MODULE, "Shutdown: %s", cs(shutdown_reason));
	}

	return exit_status;
}

// vim: set noet ts=4 sw=4:
