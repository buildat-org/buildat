// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/fs.h"
#include "core/types.h"
#include "core/log.h"
#include "core/version.h"
#include "boot/basic_init.h"
#include "boot/autodetect.h"
#include "client/config.h"
#include "client/state.h"
#include "client/app.h"
#include "client/command_seq.h"
#include "interface/os.h"
#include <c55/getopt.h>
#include <Context.h>
#include <cstdio> // sscanf()
#include <cstdlib> // srand()
#include <fstream>
#include <thread> // the Aitta publish's wait
#include <chrono>
#include <sstream>
#include <signal.h>
#include <malloc.h> // mallopt(), M_PERTURB
#include <fstream>
#include "interface/aitta.h"
#include "interface/http.h"
#include "core/json.h"
#include "interface/fs.h"
#define MODULE "__main"
namespace magic = Urho3D;

client::Config g_client_config;

// The signal that asked for shutdown, read by App::on_update(). Only things a
// signal handler may touch belong in here: no logging, no locking, no
// allocation. The frame that sees this does all of that.
volatile sig_atomic_t g_shutdown_signal = 0;

void shutdown_signal_handler(int sig)
{
	if(g_shutdown_signal == 0){
		g_shutdown_signal = sig;
	} else {
		// Asked twice: the shutdown is not getting anywhere -- or the frame
		// loop is not running yet -- so let the default action have the
		// process
		(void)signal(sig, SIG_DFL);
		(void)raise(sig);
	}
}

void signal_handler_init()
{
	(void)signal(SIGINT, shutdown_signal_handler);
	(void)signal(SIGTERM, shutdown_signal_handler);
#ifndef _WIN32
	// A write to a socket the server has dropped must not kill the client
	(void)signal(SIGPIPE, SIG_IGN);
#endif
}

// `buildat aitta ...` ([AITTA_MVP]): an author's key, a signed release of
// an app, and installing one, from a terminal
static int aitta_main(int argc, char *argv[])
{
	const ss_ verb = argc >= 1 ? argv[0] : "";
	try {
		if(verb == "keygen" && argc == 2){
			if(interface::fs::path_exists(argv[1])){
				fprintf(stderr, "%s exists; not overwriting a key\n", argv[1]);
				return 1;
			}
			ss_ key, pub;
			interface::aitta::keygen(key, pub);
			std::ofstream f(argv[1], std::ios::binary);
			f<<key;
			if(!f.good())
				throw Exception(ss_("cannot write ")+argv[1]);
			printf("%s\n", pub.c_str());
			return 0;
		}
		if(verb == "pack" && argc == 4){
			// The share and cache paths, for a serverless package's .wasm
			if(!boot::autodetect::detect_client_paths(g_client_config))
				throw Exception("the share and cache paths not found");
			printf("%s\n", interface::aitta::pack(argv[1], argv[2],
					argv[3], app::serverless_wasms(argv[1])).c_str());
			return 0;
		}
		// [AITTA_PACKAGE_PAGE] The package's page, packed beside its files
		// in .packed/ and sent as a release is
		ss_ zip_path, aitta;
		if(verb == "page" && argc == 5){
			aitta = argv[1];
			zip_path = interface::aitta::pack_page(argv[3], argv[2], argv[4],
					ss_(argv[3])+"/.packed");
		} else if(verb == "publish" && argc == 3){
			zip_path = argv[1];
			aitta = argv[2];
		}
		if(!zip_path.empty()){
			// The release to an Aitta: its .sig first, which says who
			// signed what, then the archive in the pieces its upload_begin
			// names; a refusal for the Aitta's rate waits and sends again
			const ss_ sig_path =
					interface::fs::strip_file_extension(zip_path)+".sig";
			ss_ base = aitta;
			if(base.find("://") == ss_::npos)
				base = "http://"+base;
			while(!base.empty() && base.back() == '/')
				base.pop_back();
			base += "/api/v1/aitta/";
			auto read_all = [](const ss_ &path){
				std::ifstream f(path, std::ios::binary);
				if(!f.good())
					throw Exception("cannot read "+path);
				std::ostringstream os;
				os<<f.rdbuf();
				return os.str();
			};
			const ss_ zip = read_all(zip_path), sig = read_all(sig_path);
			json::json_error_t e;
			const json::Value sigv = json::load_string(sig.c_str(), &e);
			const ss_ sha = sigv.get("sha256").is_string() ?
					sigv.get("sha256").as_string() : "";
			auto call = [&](const ss_ &url, const ss_ &body, const char *type){
				ss_ out = interface::http_post(url, body, type);
				json::Value v = json::load_string(out.c_str(), &e);
				while(v.get("error").is_string() && v.get("error").as_string().find(
						"too many requests") != ss_::npos){
					printf("waiting for the Aitta's limit on uploads a minute\n");
					std::this_thread::sleep_for(std::chrono::seconds(5));
					out = interface::http_post(url, body, type);
					v = json::load_string(out.c_str(), &e);
				}
				if(!v.get("ok").is_true())
					throw Exception(v.get("error").is_string() ?
							v.get("error").as_string() : "Aitta said: "+out);
				return v;
			};
			const json::Value begun = call(base+"upload_begin?size="+
					itos((int64_t)zip.size()), sig, "application/json");
			const size_t piece = begun.get("piece").is_number() &&
					begun.get("piece").as_number() > 0 ?
					(size_t)begun.get("piece").as_number() : 60000;
			for(size_t at = 0; at < zip.size(); at += piece)
				call(base+"upload_part?sha256="+sha+"&offset="+itos((int64_t)at),
						zip.substr(at, piece), "application/octet-stream");
			const json::Value v = call(base+"upload_end?sha256="+sha, "",
					"application/octet-stream");
			printf("%s: %s\n", verb == "page" ? "page" : "listed",
					v.get("result").is_string() ?
					v.get("result").as_cstring() : "?");
			if(v.get("warning").is_string())
				printf("warning: %s", v.get("warning").as_cstring());
			return 0;
		}
		if(verb == "install" && argc == 4){
			// [AITTA_SERVE] By name, from an Aitta: the list read, the
			// release picked (the version asked, else the newest listed),
			// its .zip and .sig fetched beside the user dir and installed as
			// a file is; one installed already is only said
			ss_ base = argv[1];
			if(base.find("://") == ss_::npos)
				base = "http://"+base;
			while(!base.empty() && base.back() == '/')
				base.pop_back();
			const ss_ want = argv[2], user = argv[3];
			const size_t at = want.find('@');
			const ss_ pkg = want.substr(0, at),
					version = at == ss_::npos ? "" : want.substr(at + 1);
			json::json_error_t e;
			const json::Value list = json::load_string(interface::http_get(
					base+"/api/v1/aitta/list").c_str(), &e).get("releases");
			json::Value pick;
			bool found = false;
			ss_ versions;
			for(unsigned i = 0; list.is_array() && i < list.size(); i++){
				const json::Value &r = list.at(i);
				if(r.get("author").as_string()+"/"+r.get("name").as_string()
						!= pkg)
					continue;
				versions += (versions.empty() ? "" : ", ")+
						r.get("version").as_string();
				if(version.empty() ? !found ||
						r.get("time").as_number() >= pick.get("time").as_number() :
						r.get("version").as_string() == version){
					pick = r;
					found = true;
				}
			}
			if(!found)
				throw Exception(versions.empty() ? base+" lists no "+pkg :
						base+" lists no "+want+"; its versions of "+pkg+": "+
						versions);
			// From the network: only a name's characters go into a path
			auto plain = [](const ss_ &s){
				if(s.empty() || s == "." || s == "..")
					return false;
				for(char c : s)
					if(!isalnum((unsigned char)c) && !strchr("._+-", c))
						return false;
				return true;
			};
			const ss_ a = pick.get("author").as_string(),
					n = pick.get("name").as_string(),
					v = pick.get("version").as_string(),
					sha = pick.get("sha256").as_string();
			if(!plain(a) || !plain(n) || !plain(v) || !plain(sha))
				throw Exception("the list's release has a name not taken");
			const ss_ dir = user+"/installed/"+a+"/"+n+"/"+v;
			if(interface::fs::path_exists(dir)){
				fprintf(stderr, "%s/%s %s is installed already\n", a.c_str(),
						n.c_str(), v.c_str());
				printf("%s\n", dir.c_str());
				return 0;
			}
			interface::fs::create_directories(user);
			const ss_ tmp = user+"/.aitta-"+sha;
			for(const char *ext : {".zip", ".sig"}){
				std::ofstream f(tmp+ext, std::ios::binary);
				f<<interface::http_get(base+"/api/v1/aitta/archive/"+sha+ext);
				if(!f.good())
					throw Exception("cannot write "+tmp+ext);
			}
			ss_ out;
			try {
				out = interface::aitta::install(tmp+".zip", tmp+".sig", user);
			} catch(...){
				std::remove((tmp+".zip").c_str());
				std::remove((tmp+".sig").c_str());
				throw;
			}
			std::remove((tmp+".zip").c_str());
			std::remove((tmp+".sig").c_str());
			printf("%s\n", out.c_str());
			return 0;
		}
		if(verb == "install" && argc == 3){
			ss_ zip = argv[1];
			const ss_ sig = interface::fs::strip_file_extension(zip)+".sig";
			printf("%s\n", interface::aitta::install(zip, sig,
					argv[2]).c_str());
			return 0;
		}
	} catch(std::exception &e){
		fprintf(stderr, "aitta %s: %s\n", verb.c_str(), e.what());
		return 1;
	}
	fprintf(stderr,
			"Usage: buildat aitta keygen <key file>\n"
			"       buildat aitta pack <app dir> <key file> <out dir>\n"
			"       buildat aitta install <release .zip> <user path>\n"
			"       buildat aitta install <Aitta> <author>/<name>[@<version>] <user path>\n"
			"       buildat aitta publish <release .zip> <Aitta's host:port>\n"
			"       buildat aitta page <Aitta's host:port> <author>/<name> <dir> <key file>\n"
			"         the package's page: <dir>'s description.txt and screenshots\n"
			"An app's meta.json: doc/aitta.txt\n");
	return 1;
}

int main(int argc, char *argv[])
{
	boot::BasicInitScope basic_init_scope;
	if(argc >= 2 && ss_(argv[1]) == "aitta")
		return aitta_main(argc - 2, argv + 2);

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

	client::Config &config = g_client_config;

	const char opts[100] = "hs:P:C:D:U:l:L:m:u:w:o:c:Ra:";
	const char usagefmt[] =
			"Usage: %s [OPTION]...\n"
			"  -h                   Show this help\n"
			"  -s [address]         Specify server address: host[:port], or\n"
			"                       https://host[:port] behind a TLS proxy\n"
			"  -P [share_path]      Specify share/ path\n"
			"  -C [cache_path]      Specify cache/ path (with -c and no -C:\n"
			"                       <cache>/scripted)\n"
			"  -D [user_path]       Specify user/ path\n"
			"  -U [urho3d_path]     Specify Urho3D path\n"
			"  -l [level number]    Set maximum log level (0...5)\n"
			"  -L [log file path]   Append log to a specified file. A local\n"
			"                       server this client starts logs beside it,\n"
			"                       with _server before the extension\n"
			"  -m [name]            Choose menu extension name\n"
			"  -u [scale]           UI scale (0 = auto from short side / 1080)\n"
			"  -w [WxH]             Windowed at this size; not remembered\n"
			"  -o [k=v,...]         Set preferences; not remembered. Keys:\n"
			"                       render_scale, vsync, max_fps,\n"
			"                       multisampling, sound_volume_db, sound_mute,\n"
			"                       ui_size (auto, or the UI scale 0.5 to 3),\n"
			"                       page_size (the most items a Page Up or\n"
			"                       Down moves, 1 to 100),\n"
			"                       web_idle_fps (the web client: 1, 5, 10,\n"
			"                       30 or 60 while unfocused or idle)\n"
			"  -c [commands]        Run command sequence and exit\n"
			"                       One command per line. @file reads a file,\n"
			"                       - reads standard input as it arrives.\n"
			"                       See doc/client_commands.txt\n"
			"  -R                   A local server this client starts restarts\n"
			"                       a module when its source changes\n"
			"  -a [kind/name/id]    Run one launch-grid action on boot, e.g.\n"
			"                       app/vanilla/devtest, app/demo_digger/play;\n"
			"                       dev/<name>/<id> for an app in\n"
			"                       <user>/dev_apps, installed/<author>.<name>\n"
			"                       @<version>/<id> for one installed from a\n"
			"                       release (game/ is read as app/). <id> is\n"
			"                       the id the app's launcher/init.lua gives\n"
			"                       its tile; a wrong one logs \"Launch\n"
			"                       action ... is not here\"\n"
			"\n"
			"  aitta ...            As the first argument: an app's key, signed\n"
			"                       release and install, from a file or by\n"
			"                       name from an Aitta (a dedicated server's);\n"
			"                       \"aitta\" alone for its usage\n"
			"\n"
			"Environment:\n"
			"  BUILDAT_USER_PATH    As -D, where -D is not given\n"
			"  BUILDAT_CACHE_PATH   As -C, where -C is not given\n"
			"  BUILDAT_TOUCH=1      Touch mode, as on a phone: the touch\n"
			"                       controls, and the mouse as a finger\n"
			"  BUILDAT_LOG_CAP_BYTES  Bytes at which the log file is moved to\n"
			"                       <file>_1 and begun again (512 MB)\n"
			;

	int forced_w = 0, forced_h = 0;
	bool cache_given = false;
	ss_ preference_overrides;

	int c;
	// What this is, before anything else, so every log begins with it
	log_i(MODULE, "%s %s (%s)", "buildat", BUILDAT_VERSION, BUILDAT_GIT_HASH);
	while((c = c55_getopt(argc, argv, opts)) != -1)
	{
		switch(c)
		{
		case 'h':
			printf(usagefmt, argv[0]);
			return 1;
		case 's':
			log_i(MODULE, "config.server_address: %s", c55_optarg);
			config.set("server_address", c55_optarg);
			break;
		case 'P':
			log_i(MODULE, "config.share_path: %s", c55_optarg);
			config.set("share_path", c55_optarg);
			break;
		case 'C':
			log_i(MODULE, "config.cache_path: %s", c55_optarg);
			config.set("cache_path", c55_optarg);
			cache_given = true;
			break;
		case 'D':
			log_i(MODULE, "config.user_path: %s", c55_optarg);
			config.set("user_path", c55_optarg);
			break;
		case 'U':
			log_i(MODULE, "config.urho3d_path: %s", c55_optarg);
			config.set("urho3d_path", c55_optarg);
			break;
		case 'l':
			log_set_max_level(atoi(c55_optarg));
			config.set("log_level_given", true);
			break;
		case 'L':
			// Opened once the paths are settled (boot::autodetect::open_log),
			// absolute against the cwd; and a local server started later is
			// given a log beside it (l_start_local_server() in app.cpp)
			config.set("log_file", c55_optarg);
			break;
		case 'm':
			log_i(MODULE, "config.menu_extension_name: %s", c55_optarg);
			config.set("menu_extension_name", c55_optarg);
			break;
		case 'a':
			log_i(MODULE, "config.launch_action: %s", c55_optarg);
			config.set("launch_action", c55_optarg);
			break;
		case 'u':
			log_i(MODULE, "config.ui_scale: %s", c55_optarg);
			config.set("ui_scale", atof(c55_optarg));
			break;
		case 'w':
			if(sscanf(c55_optarg, "%dx%d", &forced_w, &forced_h) != 2 ||
					forced_w <= 0 || forced_h <= 0){
				fprintf(stderr, "-w: expected WxH, got \"%s\"\n", c55_optarg);
				return 1;
			}
			log_i(MODULE, "window size: %ix%i", forced_w, forced_h);
			break;
		case 'o': {
			// Repeatable, and later items win, so that a wrapper script's -o
			// can be overridden on the command line after it
			ss_ items = c55_optarg ? c55_optarg : "";
			ss_ merged = preference_overrides.empty() ? items :
					preference_overrides + "," + items;
			// Accepted here so that a typo is a usage error rather than a
			// startup failure; applied in the app, on top of the saved file
			app::Options probe;
			ss_ err;
			if(!app::parse_preference_options(merged, &probe, &err)){
				fprintf(stderr, "-o: %s\n", err.c_str());
				return 1;
			}
			log_i(MODULE, "preferences: %s", merged.c_str());
			preference_overrides = merged;
			break;
		}
		case 'c': {
			ss_ arg = c55_optarg ? c55_optarg : "";
			ss_ text;
			// A single dash means standard input, read as it arrives rather
			// than up front: what the next command should be is often
			// something only a screenshot of the running client can say.
			if(arg == "-" || arg == "@-"){
				log_i(MODULE, "config.command_seq: from stdin");
				config.set("command_seq", "");
				config.set("command_seq_enabled", true);
				config.set("command_seq_stdin", true);
				break;
			}
			if(!arg.empty() && arg[0] == '@'){
				ss_ path = arg.substr(1);
				if(path.empty()){
					fprintf(stderr, "-c @file: empty path\n");
					return 1;
				}
				std::ifstream in(path.c_str());
				if(!in){
					fprintf(stderr, "Failed to read command file: %s\n",
							path.c_str());
					return 1;
				}
				std::ostringstream ss;
				ss<<in.rdbuf();
				text = ss.str();
			} else {
				text = arg;
			}
			sv_<client::command_seq::Command> parsed;
			ss_ err;
			if(!client::command_seq::parse(text, &parsed, &err)){
				fprintf(stderr, "Invalid -c command sequence: %s\n",
						err.c_str());
				return 1;
			}
			log_i(MODULE, "config.command_seq: %zu commands", parsed.size());
			config.set("command_seq", text);
			config.set("command_seq_enabled", true);
			// **A driven run's window says what it is** (user,
			// 2026-09-24): a check maps its client on whatever session
			// it is started from, and a window manager can put it out
			// of the way -- another workspace, no focus -- but only if
			// it can tell that window from one somebody opened.
			// icewm's winoptions matches WM_CLASS, which SDL takes
			// from SDL_VIDEO_X11_WMCLASS and otherwise from the
			// program name: a normal client is "buildat" and a driven
			// one is "buildat-scripted". **Here, not in App::Setup()**:
			// SDL reads it when the video subsystem starts, and the
			// default window size asks SDL for the desktop's before
			// that. A value the caller set is left alone. X11's alone:
			// MinGW has no setenv, and the Windows archive did not build
			// from 0.5.0 on for it.
#ifndef _WIN32
			if(getenv("SDL_VIDEO_X11_WMCLASS") == NULL)
				setenv("SDL_VIDEO_X11_WMCLASS", "buildat-scripted", 1);
#endif
			break;
		}
		case 'R':
			config.set("reload_modules", true);
			break;
		default:
			fprintf(stderr, "Invalid command-line argument\n");
			fprintf(stderr, usagefmt, argv[0]);
			return 1;
		}
	}

	signal_handler_init();
	interface::os::die_with_parent_if_asked();

	if(!boot::autodetect::detect_client_paths(config))
		return 1;
	// A scripted client keeps out of the cache a person's client uses: its
	// log would push theirs out, and the pidfile there names their local
	// server ([SERVER_ADOPTED])
	if(config.get<bool>("command_seq_enabled") && !cache_given){
		config.set("cache_path", config.get<ss_>("cache_path")+"/scripted");
		interface::fs::create_directories(config.get<ss_>("cache_path"));
	}
	boot::autodetect::open_log(config, "buildat", argv[0]);

	if(!config.check_paths()){
		return 1;
	}
	interface::fs::migrate_user_apps(config.get<ss_>("user_path"));

	app::Options app_options;
	app_options.preference_overrides = preference_overrides;
	if(forced_w > 0){
		app_options.graphics.window_w = forced_w;
		app_options.graphics.window_h = forced_h;
		app_options.graphics.size_forced = true;
	}

	int exit_status = 0;
	{
		magic::Context context;
		sp_<app::App> app0(app::createApp(&context, app_options));
		sp_<client::State> state(client::createState(app0));
		app0->set_state(state);

		if(config.get<ss_>("server_address") != ""){
			ss_ error;
			if(!state->connect(config.get<ss_>("server_address"), &error)){
				log_e(MODULE, "Connect failed: %s", cs(error));
				return 1;
			}
		} else {
			config.set("boot_to_menu", true);
		}

		exit_status = app0->run();
	}
	log_v(MODULE, "Succesful shutdown");
	return exit_status;
}
// vim: set noet ts=4 sw=4:
