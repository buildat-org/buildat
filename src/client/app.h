// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace Urho3D {
	class Context;
	class Graphics;
	class Scene;
	class Viewport;
}
namespace client {
	struct State;
}
namespace interface {
	struct VoxelRegistry;
	struct AtlasRegistry;

	namespace thread_pool {
		struct ThreadPool;
	}
}
extern "C" {
	struct lua_State;
	typedef struct lua_State lua_State;
}

namespace app
{
	// One step under the quietest level a setting offers, and what
	// "off" is: the settings move on 3 dB steps from 0 to -30
	// ([VOLUME_LAW])
	static const float SOUND_OFF_DB = -33.0f;

	struct AppStartupError: public Exception {
		ss_ msg;
		AppStartupError(const ss_ &msg): Exception(msg){}
	};

	struct GraphicsOptions
	{
		int window_w = 0; // 0 = pick from saved size or desktop
		int window_h = 0;
		int full_w = 0;
		int full_h = 0;
		bool fullscreen = false;
		bool maximized = false;
		bool borderless = false;
		bool resizable = true;
		bool vsync = true;
		bool triple_buffer = false;
		int multisampling = 1; // 2 looks much better but is much heavier(?)
		// 3D viewports a game asked the engine to draw are rendered at this
		// fraction of the window size; the UI stays at native resolution.
		// 1.0 is a bypass, not a scale of one.
		float render_scale = 1.0f;
		// render_scale "auto" (user, 2026-09-30), the default: the scale is
		// then settle_render_scale()'s, at the start and on each resize
		bool render_scale_auto = true;
		// Frame limiter. 200 is Urho3D's own desktop default, so leaving it
		// alone changes nothing; 0 is unlimited.
		int max_fps = 200;
		// The web client's frame rate while the page is unfocused, hidden or
		// left without input ([WEB_IDLE_FPS]): 1, 5, 10, 30 or 60
		int web_idle_fps = 5;
		// The web page's address bar while a game asks for fullscreen
		// ([WEB_ADDRESS_BAR]): "hide" or "show"; empty is the device's
		// default, hidden on a small touchscreen, which the page decides
		ss_ web_address_bar;
		// The screen's orientation on the web page while it is fullscreen
		// ([SCREEN_ORIENTATION]): "auto", "landscape" or "portrait"
		ss_ screen_orientation = "auto";
		// Set by -w: the size came from the command line, so it is not
		// remembered across runs and the saved size is left alone
		bool size_forced = false;

		void apply(Urho3D::Graphics *magic_graphics);
	};

	struct Options
	{
		GraphicsOptions graphics;
		// Beside the graphics rather than inside it: the file is the user's
		// preferences, GraphicsOptions is a display mode
		// **A volume is decibels below full, not a fader position**
		// ([VOLUME_LAW], user 2026-09-28: 80% against 100% on a linear
		// scale is no change at all, and most of the slider does almost
		// nothing). 0 dB is full, the steps are 3 dB down to -30, and
		// SOUND_OFF_DB is the step under that, which is silence. The
		// gain is made from it where it is applied and nowhere else.
		float sound_volume_db = 0.0f;
		bool sound_mute = false;
		// **Listening for LAN games** ([WIN_FIREWALL]): off until the
		// player first opens the list of this network's games, then on
		// from each start. The listen is on every interface, which is what
		// Windows' firewall asks about: asked once, when the player looked.
		bool lan_discovery = false;
		// **The UI's size** (user, 2026-10-06, a floorplanner playtest):
		// the UI scale, or "auto", the default, which follows the window
		// (apply_ui_scale). -u for a run wins over it.
		float ui_size = 1.0f;
		bool ui_size_auto = true;
		// The client's own log level and the one it hands its local server
		// as -l ([LOG_LEVEL_PREF]): a box report without a shell. 3 is
		// info; -l on the command line wins for that run.
		int log_level = 3;
		int server_log_level = 3;
		// -o k=v,...: applied on top of the saved file, and never written
		// back, the same rule -w already follows
		ss_ preference_overrides;
		// -c: the saved file is neither read nor written, so that a
		// preference someone left behind cannot change a screenshot
		bool preferences_disabled = false;
		// **Which extension is the launch UI** ([LAUNCH_SANDBOX]: the
		// launch UI is a slot rather than a setting with three values).
		// An extension's directory name; -m wins for that run, and a
		// name that does not load falls back to launch_menu, since a user
		// with no launcher has no way to fix the setting.
		ss_ launch_ui = "launch_menu";
		// **The name a game offers when it asks for one** ([FP_LAUNCH]):
		// read by games through get_preference("default_username"), so the
		// user types it once and not once per game. Luanti's rule for a
		// name: 1 to 20 letters, digits, _ and -.
		ss_ default_username = "User";
	};

	// Parses "k=v[,k=v...]" on top of whatever *opt already holds. Returns
	// false and fills *error on a malformed item, an unknown key or a value
	// out of range; *opt is then partially applied and should be discarded.
	bool parse_preference_options(const ss_ &s, Options *opt, ss_ *error);

	struct App
	{
		virtual ~App(){}
		virtual void set_state(sp_<client::State> state) = 0;
		virtual int run() = 0;
		virtual void shutdown() = 0;
		// The connection is gone: shut down, but when the local server
		// this client started has died, show its log's tail first
		// ([START_PROGRESS]). restarting: the server's goodbye said it
		// restarts, and a rejoin is tried ([SERVE_UPDATE_SMOOTH] 6)
		virtual void lost_connection(const ss_ &reason, bool restarting) = 0;
		// The owner token of the local server this client started, when
		// address is that server; "" for any other ([SECURITY_RUN_1])
		virtual ss_ owner_token_for(const ss_ &address) = 0;
		// The -u lines of the latest launch of that server, sent after the
		// token, since a reused server was started with another's
		virtual ss_ local_server_launch() = 0;
		virtual void run_script(const ss_ &script) = 0;
		virtual bool run_script_no_sandbox(const ss_ &script) = 0;
		virtual void handle_packet(const ss_ &name, const ss_ &data) = 0;
		virtual void file_updated_in_cache(const ss_ &file_name,
				const ss_ &file_hash, const ss_ &cached_path) = 0;
		// The viewports the user's graphics preferences apply to: they are
		// drawn at the render_scale the user asked for, under a UI that
		// stays at native resolution. An empty list is teardown. A game that
		// uses Renderer::SetViewport() instead is drawn at native
		// resolution and keeps working.
		virtual void set_preferred_viewports(
				const sv_<Urho3D::Viewport*> &viewports) = 0;
		virtual float get_preferred_render_scale() = 0;
		virtual Urho3D::Scene* get_scene() = 0;
		virtual interface::thread_pool::ThreadPool* get_thread_pool() = 0;
		virtual lua_State* get_lua() = 0;
	};

	App* createApp(Urho3D::Context *context, const Options &options = Options());
}
// vim: set noet ts=4 sw=4:
