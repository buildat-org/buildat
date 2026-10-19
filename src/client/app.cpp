// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "app.h"
#include <cmath>
#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#include <emscripten/html5.h>
// [WEB_ID_TRUST] (c): l_http_get's on the web, a job in
// Module.buildatHttp that l_http_poll reads back
EM_JS(void, web_fetch, (int id, const char *url_p, int post,
		const char *body, int len), {
	var jobs = Module['buildatHttp'] = Module['buildatHttp'] || {};
	var url = UTF8ToString(url_p);
	var init = {redirect: 'manual'};
	if(post){
		init.method = 'POST';
		init.headers = {'Content-Type': 'text/plain'};
		init.body = HEAPU8.slice(body, body + len);
	}
	var text = function(t){ return new TextEncoder().encode(t); };
	jobs[id] = null;
	fetch(url, init).then(function(r){
		if(r.type === 'opaqueredirect'){
			jobs[id] = {ok: false, data: text('redirected')};
			return;
		}
		return r.arrayBuffer().then(function(b){
			jobs[id] = r.ok ? {ok: true, data: new Uint8Array(b)} :
				{ok: false, data: text('HTTP ' + r.status)};
		});
	}).catch(function(e){
		jobs[id] = {ok: false, data: text(String(e && e.message || e))};
	});
});
// [PLAY_PAGE] (c): a datagram socket on the web, a WebSocket to apps/play's
// bridge whose each message is one datagram, in Module.buildatDgram
EM_JS(int, web_dgram_open, (const char *url_p), {
	var all = Module['buildatDgram'] = Module['buildatDgram'] || {n: 0};
	var id = ++all.n;
	var d = all[id] = {q: [], out: [], state: 'connecting'};
	try {
		d.ws = new WebSocket(UTF8ToString(url_p));
	} catch(e){
		d.state = 'closed: ' + e.message;
		return id;
	}
	d.ws.binaryType = 'arraybuffer';
	d.ws.onopen = function(){
		d.state = 'open';
		d.out.forEach(function(m){ d.ws.send(m); });
		d.out = [];
	};
	// simplified: what the game does not read in 16384 datagrams is lost,
	// as a full UDP buffer loses it
	d.ws.onmessage = function(e){
		if(d.q.length >= 16384)
			return;
		var m = new Uint8Array(e.data);
		// [ACK_OFF_FRAME]: as network.cpp's ack_thread, a reliable packet
		// of Luanti's acked as it arrives rather than in the game's frame;
		// only one kept, as an acked one is never resent
		if(d.ack && m.length >= 10 && m[0] == 0x4f && m[1] == 0x45 &&
				m[2] == 0x74 && m[3] == 0x03 && m[6] < 3 && m[7] == 3){
			d.ws.send(new Uint8Array([0x4f, 0x45, 0x74, 0x03,
					d.peer >> 8, d.peer & 255, m[6], 0, 0, m[8], m[9]]));
			if(m.length >= 14 && m[10] == 0 && m[11] == 1)
				d.peer = (m[12] << 8) | m[13];
		}
		d.q.push(m);
	};
	d.ws.onclose = function(e){
		d.state = 'closed: ' + (e.reason ? 'the bridge refused it: ' + e.reason :
				'the bridge closed the connection (' + e.code + ')');
	};
	return id;
});
EM_JS(void, web_dgram_send, (int id, const char *p, int n), {
	var d = (Module['buildatDgram'] || {})[id];
	if(!d)
		return;
	var m = HEAPU8.slice(p, p + n);
	if(d.state === 'open')
		d.ws.send(m);
	else if(d.state === 'connecting' && d.out.length < 256)
		d.out.push(m);
});
EM_JS(void, web_dgram_ack_luanti, (int id), {
	var d = (Module['buildatDgram'] || {})[id];
	if(d){
		d.ack = true;
		d.peer = 0;
	}
});
EM_JS(int, web_dgram_peek, (int id), {
	var d = (Module['buildatDgram'] || {})[id];
	return d && d.q.length ? d.q[0].length : -1;
});
EM_JS(void, web_dgram_take, (int id, char *p), {
	HEAPU8.set(Module['buildatDgram'][id].q.shift(), p);
});
EM_JS(char*, web_dgram_state, (int id), {
	var d = (Module['buildatDgram'] || {})[id];
	return stringToNewUTF8(d ? d.state : 'closed: closed');
});
EM_JS(void, web_dgram_close, (int id), {
	var all = Module['buildatDgram'] || {};
	if(all[id]){
		try { all[id].ws.close(); } catch(e){}
		delete all[id];
	}
});
#endif
#include "core/log.h"
#include "core/json.h"
#include "client/config.h"
#include "client/state.h"
#include "client/wss.h"
#include "client/command_seq.h"
#include "lua_bindings/init.h"
#include "lua_bindings/util.h"
#include "lua_bindings/replicate.h"
#include "interface/fs.h"
#include "interface/debug.h"
#include <sys/stat.h>
#include <ctime>
#include "interface/os.h"
#include "interface/process.h"
#include "interface/tcpsocket.h"
#include "interface/voxel.h"
#include "interface/thread_pool.h"
#include "interface/http.h"
#include "interface/address.h"
#include <map>
#include <atomic>
#include <cctype>
#include <algorithm>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <fstream>
#include "interface/aitta.h"
#include "interface/sha256.h"
#include "interface/bignum.h"
#include <sstream>
#include <sqlite3.h> // save_value() ([SAVE_ICON])
#include <c55/getopt.h>
#include <c55/os.h>
#include <Application.h>
#include <Engine.h>
#include <LuaScript.h>
#include <tolua++.h>
#include <CoreEvents.h>
#include <Input.h>
#include <InputEvents.h> // E_EXITREQUESTED
#include <ResourceCache.h>
#include <Graphics.h>
#include <GraphicsEvents.h> // E_SCREENMODE
#include <IOEvents.h> // E_LOGMESSAGE
#include <Log.h>
#include <DebugHud.h>
#include <XMLFile.h>
#include <Scene.h>
#include <LuaFunction.h>
#include <Viewport.h>
#include <Camera.h>
#include <Renderer.h>
#include <Audio.h>
#include <SoundSource.h>
#include <RenderSurface.h>
#include <Texture2D.h>
#include <Image.h>
#include <MemoryBuffer.h>
#include <zlib.h>
#include <VertexBuffer.h>
#include <Geometry.h>
#include <BorderImage.h>
#include <Octree.h>
#include <FileSystem.h>
#include <PhysicsWorld.h>
#include <DebugRenderer.h>
#include <Profiler.h>
#include <UI.h>
#include <LineEdit.h>
#include <Text.h>
#include <Font.h>
#include <CustomGeometry.h>
#include <Node.h>
#include <Camera.h>
#include <SDL/SDL.h>
#include <ctime>
extern "C" {
#include <lua.h>
#include <lauxlib.h>
}
#include <signal.h>
#include <random>
#include <cstdio>
#include <cstring>
#ifndef _WIN32
#include <unistd.h>
#include <limits.h>
#endif
// windows.h, which SDL and Urho3D pull in above, does #define interface
// struct, and interface is this tree's namespace
#ifdef interface
	#undef interface
#endif
#define MODULE "__app"
namespace magic = Urho3D;

// Auto UI scale: min(window w,h) / this. Lua/config/CLI overrides replace it.
static const float UI_REF_SHORT = 1080.f;
// The fewest UI pixels a web page's short side is given, however big a
// finger wants the UI ([FP_TOUCH] 1): a dialog's width and its margins
static const float UI_MIN_SHORT = 400.f;
// Snap to 1x, 2x, ... when close, so 1px lines stay on-pixel.
// Under: maximized window chrome (taskbar, title). Over: 16:10 like 1200p.
static const float UI_SNAP_UNDER = 0.08f;
static const float UI_SNAP_OVER = 0.12f;
// A file a user gives game code ([FP_EXPORT] 4), at most
static const size_t MAX_USER_FILE_BYTES = 64 * 1024 * 1024;
static const int MIN_WINDOW_W = 640;
static const int MIN_WINDOW_H = 360;

#include "look_axis.h"

extern client::Config g_client_config;
extern volatile sig_atomic_t g_shutdown_signal;

// The preference the local server's -l comes from, kept where the static
// start function can read it ([LOG_LEVEL_PREF])
static int g_server_log_level_pref = 3;

static ss_ preferences_path()
{
	return g_client_config.get<ss_>("user_path")+"/settings.json";
}

#ifdef __EMSCRIPTEN__
// The name field beside a password field ([LOGIN_UNLOADED]): the LineEdit
// marked "username" in the same window, for the page's login form
static magic::LineEdit *web_username_field(magic::UIElement *e)
{
	while(e->GetParent() && e->GetParent()->GetParent())
		e = e->GetParent();
	magic::PODVector<magic::UIElement*> all;
	e->GetChildren(all, true);
	for(magic::UIElement *c : all){
		if(c->GetType() == magic::LineEdit::GetTypeStatic() &&
				c->GetVar("autocomplete").GetString() == "username")
			return static_cast<magic::LineEdit*>(c);
	}
	return nullptr;
}

// The page's hidden stand-in follows the focused LineEdit ([WEB_KEYS] steps
// 2 and 4, src/client/web/index.html): its place, text and selection, and
// whether it is a password's. The browser's IME, a touchscreen's keyboard,
// its right click menu, select all, copy, cut and paste then work on it,
// and what they did comes back as actions, taken here once a frame:
//   "v<caret>,<text>"  the field's text is now this, the caret there
//   "i<text>"          type the text (a paste; its lines kept in a
//                      multi-line field)
//   "s<start>,<len>"   select
//   "e"                Enter, from a touchscreen's keyboard
//   "u<text>"          the name field beside a password is this: a
//                      password manager filled the page's login form
// Positions are in characters.
static void web_text_sync(magic::UI *ui)
{
	magic::UIElement *f = ui->GetFocusElement();
	magic::LineEdit *e = f && f->GetType() == magic::LineEdit::GetTypeStatic() ?
			static_cast<magic::LineEdit*>(f) : nullptr;
	for(;;){
		char *a = (char*)EM_ASM_PTR({
			var a = window.buildatText ? buildatText.take() : null;
			return a === null ? 0 : stringToNewUTF8(a);
		});
		if(!a)
			break;
		const char *comma = strchr(a, ',');
		if(e && a[0] == 'v' && comma && e->IsEditable()){
			unsigned caret = (unsigned)atoi(a + 1);
			// The user's own edit: an undo step as typing is ([TEXT_UNDO])
			e->SetTextAsTyped(magic::String(comma + 1));
			e->SetCursorPosition(caret);
			e->GetTextElement()->ClearSelection();
		} else if(e && a[0] == 'i'){
			e->OnTextInput(magic::String(a + 1));
		} else if(e && a[0] == 'u'){
			// The page's name input filled by a password manager
			if(magic::LineEdit *u = web_username_field(e))
				u->SetText(magic::String(a + 1));
		} else if(e && a[0] == 'e'){
			// A touchscreen keyboard's Enter: the field's own, which is
			// what finishes it (TextFinished)
			e->OnKey(magic::KEY_RETURN, 0, 0);
		} else if(e && a[0] == 's'){
			unsigned start = 0, len = 0;
			if(sscanf(a + 1, "%u,%u", &start, &len) == 2){
				e->SetCursorPosition(start + len);
				e->GetTextElement()->SetSelection(start, len);
			}
		}
		free(a);
	}
	if(!e){
		EM_ASM({ if(window.buildatText) buildatText.sync(null); });
		return;
	}
	float k = ui->GetScale();
	magic::IntVector2 p = e->GetScreenPosition();
	magic::IntVector2 size = e->GetSize();
	magic::Text *t = e->GetTextElement();
	unsigned len = t->GetSelectionLength();
	unsigned start = len ? t->GetSelectionStart() : e->GetCursorPosition();
	// A password's stand-in is a password input: never copied, and a phone's
	// keyboard does not suggest it
	bool secret = !e->IsTextCopyable() || e->GetEchoCharacter();
	// What it is for, and a password's name beside it, for a password
	// manager ([LOGIN_UNLOADED])
	const magic::String purpose = e->GetVar("autocomplete").GetString();
	magic::LineEdit *u = secret ? web_username_field(e) : nullptr;
	EM_ASM({
		if(window.buildatText)
			buildatText.sync($0, $1, $2, $3, UTF8ToString($4), $5, $6, $7, $8,
					$9, UTF8ToString($10), $11 ? UTF8ToString($11) : null);
	}, p.x_ * k, p.y_ * k, size.x_ * k, size.y_ * k, e->GetText().CString(),
			start, len, e->IsEditable() ? 1 : 0, secret ? 1 : 0,
			e->IsMultiLine() ? 1 : 0, purpose.CString(),
			u ? u->GetText().CString() : nullptr);
}

// **The fields a tap can open a keyboard on** ([WEB_TAP_KEYBOARD]): a
// phone's browser opens its on-screen keyboard only for a focus made in the
// user's own touch event, and web_text_sync() focuses the stand-in a frame
// after it. So on a page with a touchscreen the editable LineEdits shown
// are given to the page whenever they change, "x,y,w,h,secret;" each in
// the canvas's pixels, the topmost last; index.html's touchend focuses the
// stand-in for the one tapped, inside the event.
// simplified: a field under another window counts as tapped; the next
// frame's sync takes the stand-in away again if the engine did not focus it
static void web_fields_publish(magic::UI *ui)
{
	// A touchscreen by what the page says, or by a touch it has seen
	static bool touch = false;
	if(!touch)
		touch = EM_ASM_INT({ return ('ontouchstart' in window) ||
				navigator.maxTouchPoints > 0 || Module.buildatTouched ||
				(window.matchMedia && matchMedia('(pointer: coarse)').matches) ?
				1 : 0; });
	if(!touch)
		return;
	const float k = ui->GetScale();
	ss_ out;
	char buf[96];
	magic::PODVector<magic::UIElement*> all;
	for(magic::UIElement *root : {ui->GetRoot(), ui->GetRootModalElement()}){
		if(!root)
			continue;
		all.Clear();
		root->GetChildren(all, true);
		for(magic::UIElement *c : all){
			if(c->GetType() != magic::LineEdit::GetTypeStatic() || !c->IsEditable() ||
					!c->IsVisibleEffective())
				continue;
			magic::LineEdit *e = static_cast<magic::LineEdit*>(c);
			const magic::IntVector2 p = e->GetScreenPosition(), s = e->GetSize();
			snprintf(buf, sizeof buf, "%d,%d,%d,%d,%d;", (int)(p.x_ * k),
					(int)(p.y_ * k), (int)(s.x_ * k), (int)(s.y_ * k),
					!e->IsTextCopyable() || e->GetEchoCharacter() ? 1 : 0);
			out += buf;
		}
	}
	static ss_ last = "-";
	if(out == last)
		return;
	last = out;
	EM_ASM({ if(window.buildatText) buildatText.fields(UTF8ToString($0)); },
			out.c_str());
}
#endif

namespace app {

// Every preference -o and settings.json can carry is listed here once, so
// that the flag and the file cannot drift apart.
bool parse_preference_options(const ss_ &s, Options *opt, ss_ *error)
{
	size_t i = 0;
	while(i < s.size()){
		size_t comma = s.find(',', i);
		if(comma == ss_::npos)
			comma = s.size();
		ss_ item = s.substr(i, comma - i);
		i = comma + 1;
		if(item.empty())
			continue;
		size_t eq = item.find('=');
		if(eq == ss_::npos){
			*error = "\""+item+"\": expected key=value";
			return false;
		}
		ss_ key = item.substr(0, eq);
		ss_ value = item.substr(eq + 1);
		// **The launch UI is a name, not a number**: it is an
		// extension's directory name, so letters, digits and
		// underscores and nothing that could be a path
		if(key == "launch_ui"){
			bool ok = !value.empty() && value.size() <= 84;
			for(char c : value)
				if(!(isalnum((unsigned char)c) || c == '_'))
					ok = false;
			if(!ok){
				*error = "launch_ui: \""+value+"\" is not an extension name";
				return false;
			}
			// launch_menu_v2 took launch_menu's place and name
			// ([RETIRE_DEAD]); a preference saved before says the same
			opt->launch_ui = value == "launch_menu_v2" ? "launch_menu" : value;
			continue;
		}
		if(key == "web_address_bar"){
			if(value != "hide" && value != "show"){
				*error = "web_address_bar: hide or show";
				return false;
			}
			opt->graphics.web_address_bar = value;
			continue;
		}
		if(key == "screen_orientation"){
			if(value != "auto" && value != "landscape" && value != "portrait"){
				*error = "screen_orientation: auto, landscape or portrait";
				return false;
			}
			opt->graphics.screen_orientation = value;
			continue;
		}
		if(key == "default_username"){
			bool ok = !value.empty() && value.size() <= 20;
			for(char c : value)
				if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
					ok = false;
			if(!ok){
				*error = "default_username: \""+value+"\" is not 1 to 20 "
						"letters, digits, _ or -";
				return false;
			}
			opt->default_username = value;
			continue;
		}
		// fov.<app>: an app's id, and "default" takes it out
		if(key.compare(0, 4, "fov.") == 0){
			const ss_ app = key.substr(4);
			bool ok = !app.empty() && app.size() <= 64;
			for(char c : app)
				if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
					ok = false;
			if(!ok){
				*error = key+": not an app's id";
				return false;
			}
			if(value == "default"){
				opt->fov.erase(app);
				continue;
			}
			char *end = nullptr;
			long v = strtol(value.c_str(), &end, 10);
			if(value.empty() || *end != '\0' || v < 30 || v > 140){
				*error = key+": "+value+" is not 30 to 140 degrees";
				return false;
			}
			opt->fov[app] = (int)v;
			continue;
		}
		if(key == "render_scale" && value == "auto"){
			opt->graphics.render_scale_auto = true;
			continue;
		}
		if(key == "ui_size" && value == "auto"){
			opt->ui_size_auto = true;
			continue;
		}
		char *end = nullptr;
		double v = strtod(value.c_str(), &end);
		if(value.empty() || *end != '\0'){
			*error = key+": \""+value+"\" is not a number";
			return false;
		}
		bool in_range = true;
		if(key == "render_scale"){
			// Below 2 is undersampling, which is the point; above it is
			// supersampling, which the same code path gives away for free
			in_range = (v >= 0.1 && v <= 2.0);
			opt->graphics.render_scale = (float)v;
			opt->graphics.render_scale_auto = false;
		} else if(key == "vsync"){
			opt->graphics.vsync = (v != 0);
		} else if(key == "max_fps"){
			in_range = (v >= 0 && v <= 1000);
			opt->graphics.max_fps = (int)v;
		} else if(key == "web_idle_fps"){
			in_range = (v == 1 || v == 5 || v == 10 || v == 30 || v == 60);
			opt->graphics.web_idle_fps = (int)v;
		} else if(key == "multisampling"){
			in_range = (v == 1 || v == 2 || v == 4 || v == 8 || v == 16);
			opt->graphics.multisampling = (int)v;
		} else if(key == "sound_volume_db"){
			in_range = (v >= app::SOUND_OFF_DB && v <= 0.0);
			opt->sound_volume_db = (float)v;
		} else if(key == "sound_mute"){
			opt->sound_mute = (v != 0);
		} else if(key == "lan_discovery"){
			opt->lan_discovery = (v != 0);
		} else if(key == "ui_size"){
			in_range = (v >= 0.5 && v <= 3.0);
			opt->ui_size = (float)v;
			opt->ui_size_auto = false;
		} else if(key == "log_level"){
			in_range = (v >= 0 && v <= 6);
			opt->log_level = (int)v;
		} else if(key == "server_log_level"){
			in_range = (v >= 0 && v <= 6);
			opt->server_log_level = (int)v;
		} else {
			*error = "unknown preference \""+key+"\"";
			return false;
		}
		if(!in_range){
			*error = key+": "+value+" is out of range";
			return false;
		}
	}
	return true;
}

}

// [VERSION_CHECK]: a link a server gave that the system's opener may be
// handed (open_with_system: ShellExecute on Windows, a shell elsewhere):
// https only, and only characters no shell reads in quotes. simplified:
// no '%', so a percent-encoded link is shown and not opened; an exec
// without a shell on every platform is the upgrade
static bool open_url_ok(const ss_ &u)
{
	if(u.compare(0, 8, "https://") != 0 || u.size() <= 8 || u.size() > 500)
		return false;
	for(char c : u)
		if(!isalnum((unsigned char)c) && !strchr("-._~:/?#@=&+,", c))
			return false;
	return true;
}

static void check_open_url_ok()
{
	if(!open_url_ok("https://github.com/buildat-org/buildat/releases/tag/v0.6.90") ||
			open_url_ok("http://example.org/") ||
			open_url_ok("https://") ||
			open_url_ok("https://x/'; rm -rf ~") ||
			open_url_ok("https://x/\"&calc") ||
			open_url_ok("https://x/%PATH%") ||
			open_url_ok("file:///etc/passwd"))
		throw Exception("open_url_ok: wrong answer");
}

static void check_parse_preference_options()
{
	app::Options o;
	ss_ err;
	if(!app::parse_preference_options(
			"render_scale=0.5,vsync=0,sound_mute=1", &o, &err))
		throw Exception("parse_preference_options: "+err);
	if(o.graphics.render_scale != 0.5f || o.graphics.vsync || !o.sound_mute)
		throw Exception("parse_preference_options: wrong values");
	// What an item does not name is left alone
	if(o.graphics.max_fps != app::Options().graphics.max_fps)
		throw Exception("parse_preference_options: clobbered max_fps");
	if(o.graphics.render_scale_auto)
		throw Exception("parse_preference_options: a number left it auto");
	if(!app::parse_preference_options("render_scale=auto", &o, &err) ||
			!o.graphics.render_scale_auto)
		throw Exception("parse_preference_options: refused render_scale=auto");
	if(app::parse_preference_options("render_scale", &o, &err))
		throw Exception("parse_preference_options: took a bare key");
	if(app::parse_preference_options("render_scale=0.5x", &o, &err))
		throw Exception("parse_preference_options: took a non-number");
	if(app::parse_preference_options("render_scale=9", &o, &err))
		throw Exception("parse_preference_options: took an out-of-range value");
	if(app::parse_preference_options("multisampling=3", &o, &err))
		throw Exception("parse_preference_options: took a bad sample count");
	if(app::parse_preference_options("web_idle_fps=7", &o, &err) ||
			!app::parse_preference_options("web_idle_fps=10", &o, &err) ||
			o.graphics.web_idle_fps != 10)
		throw Exception("parse_preference_options: web_idle_fps's choices");
	if(app::parse_preference_options("web_address_bar=auto", &o, &err) ||
			!app::parse_preference_options("web_address_bar=show", &o, &err) ||
			o.graphics.web_address_bar != "show")
		throw Exception("parse_preference_options: web_address_bar's choices");
	if(app::parse_preference_options("ui_size=4", &o, &err) ||
			!app::parse_preference_options("ui_size=1.25", &o, &err) ||
			o.ui_size != 1.25f || o.ui_size_auto ||
			!app::parse_preference_options("ui_size=auto", &o, &err) ||
			!o.ui_size_auto)
		throw Exception("parse_preference_options: ui_size's values");
	if(!app::parse_preference_options("fov.skeldat=90", &o, &err) ||
			o.fov["skeldat"] != 90 ||
			app::parse_preference_options("fov.skeldat=500", &o, &err) ||
			app::parse_preference_options("fov.a/b=90", &o, &err) ||
			app::parse_preference_options("fov.=90", &o, &err) ||
			!app::parse_preference_options("fov.skeldat=default", &o, &err) ||
			o.fov.count("skeldat"))
		throw Exception("parse_preference_options: fov.<app>'s values");
	if(app::parse_preference_options("nonesuch=1", &o, &err))
		throw Exception("parse_preference_options: took an unknown key");
}

// Rounded, and never zero: a window can be dragged small enough that a low
// scale would otherwise ask for a zero-pixel texture.
static int scaled_length(int px, float scale)
{
	int v = (int)(px * scale + 0.5f);
	return v < 1 ? 1 : v;
}

// A viewport rect stays in window pixels from the game's point of view, so
// this is the only place the scale is applied to one. IntRect::ZERO means the
// whole target and has to stay that way.
static magic::IntRect scaled_rect(const magic::IntRect &r, float scale)
{
	if(r == magic::IntRect::ZERO)
		return r;
	return magic::IntRect(
			(int)(r.left_ * scale + 0.5f),
			(int)(r.top_ * scale + 0.5f),
			(int)(r.right_ * scale + 0.5f),
			(int)(r.bottom_ * scale + 0.5f));
}

static void check_scaled_viewport_size()
{
	if(scaled_length(1280, 0.5f) != 640 || scaled_length(720, 0.5f) != 360)
		throw Exception("scaled_length: even");
	if(scaled_length(721, 0.5f) != 361)
		throw Exception("scaled_length: rounding");
	if(scaled_length(4, 0.1f) != 1)
		throw Exception("scaled_length: minimum of one pixel");
	if(scaled_length(1280, 1.5f) != 1920)
		throw Exception("scaled_length: above one");
	// apps/demo_bomber_drone's second viewport: the same factor, so the two
	// halves still meet
	magic::IntRect r = scaled_rect(magic::IntRect(0, 360, 1280, 720), 0.5f);
	if(r.left_ != 0 || r.top_ != 180 || r.right_ != 640 || r.bottom_ != 360)
		throw Exception("scaled_rect: rect");
	if(scaled_rect(magic::IntRect::ZERO, 0.5f) != magic::IntRect::ZERO)
		throw Exception("scaled_rect: whole target");
}

static bool desktop_size(int *w, int *h)
{
	if(!SDL_WasInit(SDL_INIT_VIDEO)){
		if(SDL_InitSubSystem(SDL_INIT_VIDEO) != 0)
			return false;
	}
	SDL_DisplayMode mode;
	if(SDL_GetDesktopDisplayMode(0, &mode) != 0)
		return false;
	if(mode.w < 1 || mode.h < 1)
		return false;
	*w = mode.w;
	*h = mode.h;
	return true;
}

// Half the desktop height, at least 720p, at most 75%. 16:9. If the short
// side is already in the UI integer-scale band, nudge to n*1080 x 16:9 when
// that still leaves ~15% desktop margin. 1080p -> 1280x720; 4K -> 1920x1080.
static void pick_default_window_size(int desk_w, int desk_h, int *out_w, int *out_h)
{
	if(desk_w < MIN_WINDOW_W)
		desk_w = MIN_WINDOW_W;
	if(desk_h < 480)
		desk_h = 480;

	int h = desk_h / 2;
	if(h < 720)
		h = 720;
	int max_h = desk_h * 3 / 4;
	if(h > max_h)
		h = max_h;
	int w = h * 16 / 9;
	int max_w = desk_w * 85 / 100;
	if(w > max_w){
		w = max_w;
		h = w * 9 / 16;
	}
	if(w < MIN_WINDOW_W)
		w = MIN_WINDOW_W;
	if(h < MIN_WINDOW_H)
		h = MIN_WINDOW_H;
	if(w > desk_w)
		w = desk_w;
	if(h > desk_h)
		h = desk_h;

	int short_side = w < h ? w : h;
	float s = (float)short_side / UI_REF_SHORT;
	int n = (int)(s + 0.5f);
	if(n >= 1 &&
			s >= (float)n * (1.f - UI_SNAP_UNDER) &&
			s <= (float)n * (1.f + UI_SNAP_OVER)){
		int snap_h = n * (int)UI_REF_SHORT;
		int snap_w = snap_h * 16 / 9;
		if(snap_w <= desk_w * 85 / 100 && snap_h <= desk_h * 85 / 100 &&
				snap_w >= MIN_WINDOW_W && snap_h >= MIN_WINDOW_H){
			w = snap_w;
			h = snap_h;
		}
	}

	*out_w = w;
	*out_h = h;
}

static void check_pick_default_window_size()
{
	int w = 0;
	int h = 0;
	pick_default_window_size(1920, 1080, &w, &h);
	if(w != 1280 || h != 720)
		throw Exception("pick_default_window_size 1080p");
	pick_default_window_size(3840, 2160, &w, &h);
	if(w != 1920 || h != 1080)
		throw Exception("pick_default_window_size 4K");
}

static bool window_is_maximized(magic::Graphics *g)
{
	SDL_Window *win = g ? g->GetWindow() : nullptr;
	if(!win)
		return false;
	return (SDL_GetWindowFlags(win) & SDL_WINDOW_MAXIMIZED) != 0;
}

// Reads the saved preferences into *opt. A missing field keeps its default,
// so a file written by an older build is read by a newer one; a field that is
// present but out of range drops the whole set back to the defaults, because
// a file that has been edited into nonsense is better answered with something
// known than with half of it. The return value is about the window geometry
// alone: it is the one thing that has somewhere else to come from.
static bool load_preferences(int desk_w, int desk_h, app::Options *opt)
{
	json::json_error_t err;
	json::Value o = json::load_file(preferences_path().c_str(), &err);
	if(!o.is_object())
		return false;

	ss_ pref_err;
	const json::Value &jrs = o.get("render_scale");
	const json::Value &jvs = o.get("vsync");
	const json::Value &jmf = o.get("max_fps");
	const json::Value &jwf = o.get("web_idle_fps");
	const json::Value &jms = o.get("multisampling");
	const json::Value &jsv = o.get("sound_volume_db");
	// **The old key, read once** ([VOLUME_LAW]): a `sound_volume` in a
	// file from before is a fader position, 0 to 1. It is turned into
	// the decibels that sound the same and written back on the next
	// save, so nobody's volume jumps on an upgrade. The two cannot be
	// told apart by their values -- 0 is silence on one scale and full
	// on the other -- which is why the key is a new one.
	const json::Value &jsv_old = o.get("sound_volume");
	const json::Value &jsm = o.get("sound_mute");
	const json::Value &jld = o.get("lan_discovery");
	const json::Value &jus = o.get("ui_size");
	const json::Value &jui = o.get("launch_ui");
	const json::Value &jwa = o.get("web_address_bar");
	const json::Value &jso = o.get("screen_orientation");
	const json::Value &jdu = o.get("default_username");
	const json::Value &jll = o.get("log_level");
	const json::Value &jsl = o.get("server_log_level");
	// Through the same parser as -o, so that the range checks are written
	// once and a hand-edited file is refused the same way a flag is
	ss_ items;
	if(jll.is_integer())
		items += ss_()+(items.empty()?"":",")+"log_level="+itos(jll.as_integer());
	if(jsl.is_integer())
		items += ss_()+(items.empty()?"":",")+"server_log_level="+itos(jsl.as_integer());
	if(jrs.is_number())
		items += ss_()+(items.empty()?"":",")+"render_scale="+ftos(jrs.as_number());
	else if(jrs.is_string() && jrs.as_string() == "auto")
		items += ss_()+(items.empty()?"":",")+"render_scale=auto";
	if(jvs.is_boolean())
		items += ss_()+(items.empty()?"":",")+"vsync="+(jvs.as_boolean()?"1":"0");
	if(jmf.is_integer())
		items += ss_()+(items.empty()?"":",")+"max_fps="+itos(jmf.as_integer());
	if(jwf.is_integer())
		items += ss_()+(items.empty()?"":",")+"web_idle_fps="+itos(jwf.as_integer());
	if(jms.is_integer())
		items += ss_()+(items.empty()?"":",")+"multisampling="+itos(jms.as_integer());
	if(jsv.is_number()){
		items += ss_()+(items.empty()?"":",")+
				"sound_volume_db="+ftos(jsv.as_number());
	} else if(jsv_old.is_number()){
		const double v = jsv_old.as_number();
		double db = app::SOUND_OFF_DB;
		if(v > 0.0){
			db = 20.0 * log10(v);
			// Onto the step grid the settings now move on, to the
			// nearest step: the point is that nobody's volume jumps,
			// and flooring 0.5 -- which is -6.02 dB -- to -9 is a jump
			// down of a third of the gain
			db = std::floor(db / 3.0 + 0.5) * 3.0;
			if(db > 0.0)
				db = 0.0;
			if(db < app::SOUND_OFF_DB)
				db = app::SOUND_OFF_DB;
		}
		log_i(MODULE, "sound_volume %s in the settings is a fader position"
				" and is now %s dB", cs(ftos(v)), cs(ftos(db)));
		items += ss_()+(items.empty()?"":",")+"sound_volume_db="+ftos(db);
	}
	if(jsm.is_boolean())
		items += ss_()+(items.empty()?"":",")+"sound_mute="+(jsm.as_boolean()?"1":"0");
	if(jld.is_boolean())
		items += ss_()+(items.empty()?"":",")+"lan_discovery="+(jld.as_boolean()?"1":"0");
	if(jus.is_number())
		items += ss_()+(items.empty()?"":",")+"ui_size="+ftos(jus.as_number());
	else if(jus.is_string() && jus.as_string() == "auto")
		items += ss_()+(items.empty()?"":",")+"ui_size=auto";
	if(jui.is_string())
		items += ss_()+(items.empty()?"":",")+"launch_ui="+jui.as_string();
	if(jwa.is_string() && !jwa.as_string().empty())
		items += ss_()+(items.empty()?"":",")+"web_address_bar="+
				jwa.as_string();
	if(jso.is_string())
		items += ss_()+(items.empty()?"":",")+"screen_orientation="+
				jso.as_string();
	if(jdu.is_string())
		items += ss_()+(items.empty()?"":",")+"default_username="+
				jdu.as_string();
	const json::Value &jfov = o.get("fov");
	if(jfov.is_object()){
		for(json::Iterator it(jfov); it.valid(); it.next()){
			if(it.value().is_integer())
				items += ss_()+(items.empty()?"":",")+"fov."+it.key()+"="+
						itos(it.value().as_integer());
		}
	}
	if(!items.empty()){
		app::Options parsed = *opt;
		if(!app::parse_preference_options(items, &parsed, &pref_err))
			log_w(MODULE, "%s: %s; using defaults",
					cs(preferences_path()), cs(pref_err));
		else
			*opt = parsed;
	}

	// -w said what the size is, so the file does not get to
	if(opt->graphics.size_forced)
		return true;
	const json::Value &jw = o.get("width");
	const json::Value &jh = o.get("height");
	if(!jw.is_integer() || !jh.is_integer())
		return false;
	int rw = (int)jw.as_integer();
	int rh = (int)jh.as_integer();
	if(rw < MIN_WINDOW_W || rh < MIN_WINDOW_H || rw > desk_w || rh > desk_h)
		return false;
	opt->graphics.window_w = rw;
	opt->graphics.window_h = rh;
	const json::Value &jm = o.get("maximized");
	const json::Value &jf = o.get("fullscreen");
	opt->graphics.maximized = jm.is_boolean() && jm.as_boolean();
	opt->graphics.fullscreen = jf.is_boolean() && jf.as_boolean();
	return true;
}

static void save_preferences(const app::Options &opt)
{
	// Nothing that came from the command line is remembered: -o's
	// preferences, a -c run's whole set of them, and -w's size -- the rest
	// of a -w run's are, since the web page always gives -w, and the
	// window's are then what the file had
	if(opt.preferences_disabled || !opt.preference_overrides.empty())
		return;
	json::Value o = json::object();
	if(opt.graphics.size_forced){
		json::json_error_t err;
		json::Value old = json::load_file(preferences_path().c_str(), &err);
		if(old.is_object()){
			for(const char *k : {"width", "height", "maximized", "fullscreen"}){
				if(!old.get(k).is_undefined())
					o.set(k, old.get(k));
			}
		}
	} else {
		if(opt.graphics.window_w < MIN_WINDOW_W ||
				opt.graphics.window_h < MIN_WINDOW_H)
			return;
		o.set("width", opt.graphics.window_w);
		o.set("height", opt.graphics.window_h);
		o.set("maximized", opt.graphics.maximized);
		o.set("fullscreen", opt.graphics.fullscreen);
	}
	if(opt.graphics.render_scale_auto)
		o.set("render_scale", "auto");
	else
		o.set("render_scale", opt.graphics.render_scale);
	o.set("vsync", opt.graphics.vsync);
	o.set("max_fps", opt.graphics.max_fps);
	o.set("web_idle_fps", opt.graphics.web_idle_fps);
	if(!opt.graphics.web_address_bar.empty())
		o.set("web_address_bar", opt.graphics.web_address_bar);
	o.set("screen_orientation", opt.graphics.screen_orientation);
	o.set("multisampling", opt.graphics.multisampling);
	o.set("sound_volume_db", opt.sound_volume_db);
	o.set("sound_mute", opt.sound_mute);
	o.set("lan_discovery", opt.lan_discovery);
	if(opt.ui_size_auto)
		o.set("ui_size", "auto");
	else
		o.set("ui_size", opt.ui_size);
	o.set("log_level", opt.log_level);
	o.set("server_log_level", opt.server_log_level);
	o.set("launch_ui", opt.launch_ui);
	o.set("default_username", opt.default_username);
	if(!opt.fov.empty()){
		json::Value f = json::object();
		for(auto &kv : opt.fov)
			f.set(kv.first.c_str(), kv.second);
		o.set("fov", f);
	}
	o.save_file(preferences_path().c_str());
}

// What render_scale "auto" is: natively 1, the bypass
static float auto_render_scale()
{
#ifdef __EMSCRIPTEN__
	// **The web's render scale default** (user, 2026-09-30): a browser is
	// not a performance setup. The 3D gets about a 1080p frame's pixels
	// (2.1 M) of the page's canvas, a screen of over 3000 device pixels on
	// a side (4K) half at most, and a GPU that is the CPU (SwiftShader,
	// llvmpipe, Microsoft's basic renderer) half at most too; rounded down
	// to a step the settings offer. Only while render_scale is "auto".
	return (float)EM_ASM_DOUBLE({
		var dpr = window.devicePixelRatio || 1;
		var s = Math.min(1, Math.sqrt(2.1e6 /
				(window.innerWidth * window.innerHeight * dpr * dpr)));
		if(Math.max(screen.width, screen.height) * dpr > 3000)
			s = Math.min(s, 0.5);
		try {
			var gl = document.createElement('canvas').getContext('webgl');
			var info = gl && gl.getExtension('WEBGL_debug_renderer_info');
			var name = info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : '';
			if(/swiftshader|llvmpipe|softpipe|basic render|software/i.test(name))
				s = Math.min(s, 0.5);
			var lose = gl && gl.getExtension('WEBGL_lose_context');
			if(lose)
				lose.loseContext();
		} catch(e){}
		// (no [a, b] here: a comma outside parentheses splits the macro)
		var steps = '1 0.75 0.67 0.5 0.33 0.25'.split(' ');
		for(var i = 0; i < steps.length; i++){
			if(+steps[i] <= s + 0.001)
				return +steps[i];
		}
		return 0.25;
	});
#else
	return 1.0f;
#endif
}

// A render scale of "auto" made a number, for now: at the start, on a
// resize and when the setting is chosen
static void settle_render_scale(app::Options *opt)
{
	if(opt->graphics.render_scale_auto)
		opt->graphics.render_scale = auto_render_scale();
}

static void resolve_preferences(app::Options *opt)
{
	int desk_w = 0;
	int desk_h = 0;
	if(!desktop_size(&desk_w, &desk_h)){
		desk_w = 1920;
		desk_h = 1080;
	}
	// -w says what the size is, so nothing else has to; -c reads no file at
	// all, and then the size can only come from the default
	bool size_ok = opt->graphics.size_forced;
	if(!opt->preferences_disabled && load_preferences(desk_w, desk_h, opt)){
		size_ok = true;
		if(!g_client_config.get<bool>("log_level_given"))
			log_set_max_level(opt->log_level);
		g_server_log_level_pref = opt->server_log_level;
	}
	if(!size_ok)
		pick_default_window_size(desk_w, desk_h,
				&opt->graphics.window_w, &opt->graphics.window_h);
}

static bool valid_app_name(const ss_ &name)
{
	if(name.empty() || name.size() > 64)
		return false;
	for(char c : name){
		if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
			return false;
	}
	return true;
}

// **An app installed from a release** ([AITTA_MVP]) is named on the grid
// and to start_local_server() "<author>.<name>@<version>", and lives in
// <user>/installed/<author>/<name>/<version>/; its server calls it
// "<author>.<name>" (server::app_of()). Each part as the install checked
// it (interface::aitta::check_manifest()); "" for anything else.
static ss_ installed_app_dir(const ss_ &id)
{
	const size_t dot = id.find('.'), at = id.find('@');
	if(dot == ss_::npos || at == ss_::npos || at < dot)
		return "";
	const ss_ author = id.substr(0, dot), name = id.substr(dot + 1, at - dot - 1),
			version = id.substr(at + 1);
	auto plain = [](const ss_ &p, bool dots){
		if(p.empty() || p.size() > 40 || p == "." || p == "..")
			return false;
		for(char c : p)
			if(!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' ||
					(dots && (isalnum((unsigned char)c) || c == '.' ||
					c == '-' || c == '+'))))
				return false;
		return true;
	};
	if(!plain(author, false) || !plain(name, false) || !plain(version, true))
		return "";
	return g_client_config.get<ss_>("user_path")+"/installed/"+author+"/"+
			name+"/"+version;
}

// **A reviewer's playtest** ([AITTA_REVIEW]): "review:<author>.<name>
// @<version>" on the grid and to start_local_server(), in
// <user>/review/<author>__<name>/<version>/, apart from the installed
// ones; its server calls it "review.<author>__<name>", its saves its own
static ss_ review_app_dir(const ss_ &id)
{
	if(id.compare(0, 7, "review:") != 0)
		return "";
	const ss_ inner = id.substr(7);
	const ss_ dir = installed_app_dir(inner);
	if(dir.empty())
		return "";
	const size_t dot = inner.find('.'), at = inner.find('@');
	return g_client_config.get<ss_>("user_path")+"/review/"+
			inner.substr(0, dot)+"__"+inner.substr(dot + 1, at - dot - 1)+"/"+
			inner.substr(at + 1);
}

// Every playtest's id, sorted
static sv_<ss_> review_app_ids()
{
	const ss_ review = g_client_config.get<ss_>("user_path")+"/review";
	sv_<ss_> ids;
	for(const auto &p : interface::fs::list_directory(review)){
		const size_t sep = p.name.find("__");
		if(!p.is_directory || sep == ss_::npos)
			continue;
		for(const auto &v : interface::fs::list_directory(review+"/"+p.name)){
			const ss_ id = "review:"+p.name.substr(0, sep)+"."+
					p.name.substr(sep + 2)+"@"+v.name;
			if(v.is_directory && review_app_dir(id) == review+"/"+p.name+"/"+
					v.name)
				ids.push_back(id);
		}
	}
	std::sort(ids.begin(), ids.end());
	return ids;
}

// **An author's own app or extension** ([AITTA_PUBLISH_UI]), in
// <user>/dev_apps/<name>/, run as it is there: an app is "dev:<name>" on
// the grid and to start_local_server(), and its server calls it <name>,
// as a tree app's (server::app_of()), saves and all. An extension is
// "<author>__<name>" by its meta.json, as an installed one is, and the
// one here is loaded over an installed one of the same name.
static ss_ dev_apps_path()
{
	return g_client_config.get<ss_>("user_path")+"/dev_apps";
}

static ss_ dev_app_dir(const ss_ &id)
{
	if(id.compare(0, 4, "dev:") != 0 || !valid_app_name(id.substr(4)))
		return "";
	return dev_apps_path()+"/"+id.substr(4);
}

struct DevEntry { ss_ name, dir, kind, client_name; };
// What is in dev_apps, sorted by name; client_name is an extension's
// "<author>__<name>", "" where its meta.json does not say both yet
static sv_<DevEntry> dev_entries()
{
	sv_<DevEntry> out;
	for(const auto &n : interface::fs::list_directory(dev_apps_path())){
		if(!n.is_directory || !valid_app_name(n.name))
			continue;
		DevEntry e{n.name, dev_apps_path()+"/"+n.name, "app", ""};
		json::json_error_t err;
		const json::Value m = json::load_file((e.dir+"/meta.json").c_str(),
				&err);
		e.kind = interface::aitta::kind_of(m);
		if(e.kind == "extension" && m.get("author").is_string() &&
				m.get("name").is_string() &&
				valid_app_name(m.get("author").as_string()) &&
				valid_app_name(m.get("name").as_string()))
			e.client_name = m.get("author").as_string()+"__"+
					m.get("name").as_string();
		out.push_back(e);
	}
	std::sort(out.begin(), out.end(), [](const DevEntry &a, const DevEntry &b){
		return a.name < b.name; });
	return out;
}

// Every installed version's id, sorted: the apps', or the extensions'
static sv_<ss_> installed_app_ids(bool extensions = false)
{
	const ss_ installed = g_client_config.get<ss_>("user_path")+"/installed";
	sv_<ss_> ids;
	for(const auto &a : interface::fs::list_directory(installed))
		for(const auto &n : interface::fs::list_directory(installed+"/"+a.name))
			for(const auto &v : interface::fs::list_directory(
					installed+"/"+a.name+"/"+n.name)){
				const ss_ id = a.name+"."+n.name+"@"+v.name;
				if(v.is_directory && !installed_app_dir(id).empty() &&
						(interface::aitta::kind_of(json::load_file((
						installed_app_dir(id)+"/meta.json").c_str())) ==
						"extension") == extensions)
					ids.push_back(id);
			}
	std::sort(ids.begin(), ids.end());
	return ids;
}

// An installed extension's directory by its name in the client,
// "<author>__<name>" ([AITTA]), or "" -- there is one version of it
static ss_ installed_extension_dir(const ss_ &name)
{
	const size_t sep = name.find("__");
	if(sep == ss_::npos)
		return "";
	for(const DevEntry &e : dev_entries())
		if(!e.client_name.empty() && e.client_name == name)
			return e.dir;
	const ss_ prefix = name.substr(0, sep)+"."+name.substr(sep + 2)+"@";
	for(const ss_ &id : installed_app_ids(true))
		if(id.compare(0, prefix.size(), prefix) == 0)
			return installed_app_dir(id);
	return "";
}

// A tree app's directory or an installed one's, "" for neither
static ss_ app_dir(const ss_ &id)
{
	if(valid_app_name(id))
		return g_client_config.get<ss_>("share_path")+"/apps/"+id;
	if(!dev_app_dir(id).empty())
		return dev_app_dir(id);
	if(!review_app_dir(id).empty())
		return review_app_dir(id);
	return installed_app_dir(id);
}

// [APP_CATEGORY] what an app says it is: main/meta.json's "kind", or its
// base's ("base" in the app's meta.json, as the loader takes it); "" for
// none
static ss_ app_kind(const ss_ &dir)
{
	// load_file writes its error into err: without one a missing file
	// crashes it
	json::json_error_t err;
	const json::Value m = json::load_file((dir+"/main/meta.json").c_str(),
			&err);
	if(m.get("kind").is_string())
		return m.get("kind").as_string();
	ss_ why;
	const ss_ base = interface::aitta::find_base(json::load_file(
			(dir+"/meta.json").c_str(), &err), dir,
			g_client_config.get<ss_>("share_path"),
			g_client_config.get<ss_>("user_path"), &why);
	return base.empty() ? "" : app_kind(base);
}

// What the app's server calls it: an installed one without its version
static ss_ server_app_id(const ss_ &id)
{
	const size_t at = id.find('@');
	if(!dev_app_dir(id).empty())
		return id.substr(4);
	if(!review_app_dir(id).empty()){
		const size_t dot = id.find('.');
		return "review."+id.substr(7, dot - 7)+"__"+
				id.substr(dot + 1, at - dot - 1);
	}
	return installed_app_dir(id).empty() ? id : id.substr(0, at);
}

#include "local_server.h"

namespace app {

void GraphicsOptions::apply(magic::Graphics *magic_graphics)
{
	int w = fullscreen ? full_w : window_w;
	int h = fullscreen ? full_h : window_h;
	// The web's canvas is drawn at device pixels ([FP_TOUCH] 1)
#ifdef __EMSCRIPTEN__
	const bool high_dpi = true;
#else
	const bool high_dpi = false;
#endif
	magic_graphics->SetMode(w, h, fullscreen, borderless, resizable,
			high_dpi, vsync, triple_buffer, multisampling, 0, 0);
}

class BuildatResourceRouter: public magic::ResourceRouter
{
	URHO3D_OBJECT(BuildatResourceRouter, magic::ResourceRouter);

	sp_<client::State> m_client;
public:
	BuildatResourceRouter(magic::Context *context):
		magic::ResourceRouter(context)
	{}
	void set_client(sp_<client::State> client)
	{
		m_client = client;
	}

	// **A builtin module's client_data, with no server to send it.** A
	// module publishes its client_data as <module>/<path> and the client
	// gets it over the wire; an extension that wants the same shaders --
	// extensions/launch_world wants voxel_shading's -- has no server to
	// get them from. So a name nobody has announced is looked for under
	// builtin/<module>/client_data/ before it is given up on.
	ss_ builtin_client_data(const ss_ &orig)
	{
		size_t slash = orig.find('/');
		if(slash == ss_::npos || slash == 0)
			return "";
		// A name is a resource name and never a path out of the tree
		if(orig.find("..") != ss_::npos)
			return "";
		ss_ path = g_client_config.get<ss_>("share_path")+"/builtin/"+
				orig.substr(0, slash)+"/client_data/"+orig.substr(slash + 1);
		if(!interface::fs::path_exists(path))
			return "";
		return path;
	}

	void Route(magic::String &name, magic::ResourceRequest requestType)
	{
		if(!m_client){
			ss_ builtin = builtin_client_data(ss_(name.CString()));
			if(builtin != ""){
				log_v(MODULE, "Resource route access: %s -> %s (builtin)",
						name.CString(), cs(builtin));
				name = builtin.c_str();
				return;
			}
			log_w(MODULE, "Resource route access: %s (client not initialized)",
					name.CString());
			return;
		}
		ss_ orig(name.CString());
		ss_ path = m_client->get_file_path(orig);
		if(path == "")
			path = builtin_client_data(orig);
		if(path == ""){
			log_v(MODULE, "Resource route access: %s (assuming local file)",
					name.CString());
			// NOTE: Path safety is checked by magic::FileSystem
			return;
		}
		// Announced but not here yet -- a cold cache with the media on its
		// way ([FIRST_RUN]): the name stays as it is, so cache:Exists()
		// says no and a GetResource fails on the name rather than on a
		// path in the cache, and whoever asked asks again later
		if(!interface::fs::path_exists(path)){
			log_v(MODULE, "Resource route access: %s (not arrived yet)",
					name.CString());
			return;
		}
		// Cache files are stored as a bare hash. Urho Sound (and some
		// other loaders) pick the decoder from the File path extension.
		magic::String ext = magic::GetExtension(name);
		if(!ext.Empty()){
			ss_ hex = path;
			size_t slash = hex.rfind('/');
			if(slash != ss_::npos)
				hex = hex.substr(slash + 1);
			ss_ dest = g_client_config.get<ss_>("cache_path")+
					"/tmp/"+hex+ext.CString();
			if(!interface::fs::path_exists(dest)){
				if(!interface::fs::copy_file(path, dest)){
					log_w(MODULE, "Resource route copy failed: %s -> %s",
							cs(path), cs(dest));
				} else {
					path = dest;
				}
			} else {
				path = dest;
			}
		}
		log_v(MODULE, "Resource route access: %s -> %s",
				name.CString(), cs(path));
		name = path.c_str();
	}
};

struct CApp: public App, public magic::Application
{
	sp_<client::State> m_state;
	// dump_meshes(): the textures written so far this session, by the
	// Texture2D they were read back from, so that eight viewpoints of one
	// world read the atlas back once and not eight times -- the read-back
	// and the PNG encode were 96% of a dump, and a dump longer than 30 s
	// has the server drop the client as stalled
	sm_<magic::Texture2D*, ss_> m_dumped_textures;
	// The PNG encoding of a dump's textures, off the main thread: sixty
	// atlas pages of 2048^2 took a minute to encode on it, which is
	// longer than the server waits for a client that answers nothing, and
	// the frames the client owes are the main thread's. One worker for
	// the session with a queue, never joined between dumps -- a join
	// before the second dump was the same minute on the main thread --
	// only at shutdown. A texture is queued once a session (see
	// m_dumped_textures), so a later dump never rewrites a file the
	// worker is still on.
	std::thread m_texture_writer;
	std::mutex m_texture_mutex;
	std::condition_variable m_texture_cv;
	std::deque<std::pair<ss_, magic::SharedPtr<magic::Image>>> m_texture_queue;
	bool m_texture_stop = false;
	void queue_textures(sv_<std::pair<ss_, magic::SharedPtr<magic::Image>>> &items)
	{
		{
			std::lock_guard<std::mutex> lock(m_texture_mutex);
			for(auto &item : items)
				m_texture_queue.push_back(item);
		}
		if(!m_texture_writer.joinable()){
			m_texture_writer = std::thread([this](){
				for(;;){
					std::pair<ss_, magic::SharedPtr<magic::Image>> item;
					{
						std::unique_lock<std::mutex> lock(m_texture_mutex);
						m_texture_cv.wait(lock, [this](){
							return m_texture_stop || !m_texture_queue.empty();
						});
						if(m_texture_queue.empty())
							return;
						item = m_texture_queue.front();
						m_texture_queue.pop_front();
					}
					const int64_t t0 = interface::os::time_us();
					write_dump_texture(item.first, item.second);
					log_v(MODULE, "dump_meshes: wrote %s in %.1f s",
							cs(item.first),
							(interface::os::time_us() - t0) / 1e6);
				}
			});
		}
		m_texture_cv.notify_one();
	}
	// A map's PNG, and for the two whose alpha is a channel of its own --
	// the spec map's spots, the normal map's static spots -- the alpha
	// forced opaque and the channel written beside it as <stem>_spots.png
	// or <stem>_static_spots.png: a viewer composited the used tiles
	// transparent over black and the map looked empty when it was not.
	// [SPEC_DUMP_ALPHA]
	static void write_dump_texture(const ss_ &path,
			magic::SharedPtr<magic::Image> img)
	{
		const bool spec = path.size() > 9 &&
				path.compare(path.size() - 9, 9, "_spec.png") == 0;
		const bool normal = path.size() > 11 &&
				path.compare(path.size() - 11, 11, "_normal.png") == 0;
		if((!spec && !normal) || img->GetComponents() != 4){
			img->SavePNG(magic::String(path.c_str()));
			return;
		}
		const int w = img->GetWidth(), h = img->GetHeight();
		const unsigned char *src = img->GetData();
		magic::SharedPtr<magic::Image> opaque(new magic::Image(img->GetContext()));
		magic::SharedPtr<magic::Image> chan(new magic::Image(img->GetContext()));
		opaque->SetSize(w, h, 4);
		chan->SetSize(w, h, 4);
		unsigned char *o = opaque->GetData(), *c = chan->GetData();
		for(int i = 0; i < w * h; i++){
			o[i * 4] = src[i * 4];
			o[i * 4 + 1] = src[i * 4 + 1];
			o[i * 4 + 2] = src[i * 4 + 2];
			o[i * 4 + 3] = 255;
			c[i * 4] = c[i * 4 + 1] = c[i * 4 + 2] = src[i * 4 + 3];
			c[i * 4 + 3] = 255;
		}
		opaque->SavePNG(magic::String(path.c_str()));
		const ss_ stem = path.substr(0, path.size() - (spec ? 9 : 11));
		chan->SavePNG(magic::String((stem + (spec ? "_spots.png" :
				"_static_spots.png")).c_str()));
	}

	void join_texture_writer()
	{
		{
			std::lock_guard<std::mutex> lock(m_texture_mutex);
			m_texture_stop = true;
		}
		m_texture_cv.notify_one();
		if(m_texture_writer.joinable())
			m_texture_writer.join();
	}
	BuildatResourceRouter *m_router;
	magic::LuaScript *m_script;
	lua_State *L;
	// shutdown() is not instant; the frames until the window closes must not
	// each call it again
	bool m_shutdown_signal_handled = false;
	// The last key, button or touch the user gave, down or up
	// (l_user_activated)
	int64_t m_last_press_us = 0;
	float m_ui_scale_lua = 0.f; // 0 = not set by Lua
	// **What the scale is multiplied by for a menu to fit** (user,
	// 2026-09-30: a phone in portrait showed part of a menu, its buttons
	// out of reach): 1, or less while a top-level element is bigger than
	// the screen; see update_ui_fit()
	float m_fit_factor = 1.f;
	// The root's size before the fit last changed the scale: what a
	// root-sized element still is for a frame after it ([LUANTI_NO_WORLD])
	magic::IntVector2 m_fit_prev_root;
	// When a button, a finger or a key was last down: the scale is not
	// changed under a press or a gesture, nor for FIT_QUIET_US after one
	int64_t m_input_busy_us = 0;
	static constexpr int64_t FIT_QUIET_US = 500000;
	static constexpr float FIT_FLOOR = 0.5f;
	bool m_restore_maximized = false;
	Options m_options;
	bool m_draw_debug_geometry = false;
	// The client's own keys, the key store's (__buildat_set_client_keys);
	// -1 is unbound
	int m_key_profiler = Urho3D::KEY_F10;
	int m_key_fullscreen = Urho3D::KEY_F11;
	int m_key_screenshot = Urho3D::KEY_F12;
	int64_t m_last_update_us;

	sv_<client::command_seq::Command> m_commands;
	size_t m_command_index = 0;
	int64_t m_command_wait_until_us = 0;
	// wait_log: the log's line count when the wait began, -1 for none
	long long m_wait_log_since = -1;
	int64_t m_wait_log_until_us = 0;
	// The error watch ([CHECKS_EVENT_WAITS]): the problems logged so far
	// that it has looked at, and the error texts the drive said to expect
	long long m_problems_seen = 0;
	sv_<ss_> m_expected_errors;
	bool m_shutdown_begun = false;
	// When the wait last said it was still waiting
	int64_t m_wait_log_said_us = 0;
	ss_ m_pending_screenshot;
	bool m_command_seq_active = false;
	// The logical size a scripted client keeps whatever the window does
	// ([SEQ_FIXED_SIZE]): the -w size. The world renders into a texture of
	// it, the UI lays out at it, and both are shown scaled and letterboxed
	// in the window; the scan, the mouse and the screenshots are in it.
	int m_logical_w = 0;
	int m_logical_h = 0;
	// How the logical frame sits in the window: scale and offset, in pixels
	float m_logical_scale = 1.f;
	int m_logical_ox = 0;
	int m_logical_oy = 0;
	bool logical_mode() const { return m_command_seq_active && m_logical_w > 0; }
	void update_logical_placement()
	{
		magic::Graphics *g = GetSubsystem<magic::Graphics>();
		if(!g || !logical_mode())
			return;
		float sx = (float)g->GetWidth() / (float)m_logical_w;
		float sy = (float)g->GetHeight() / (float)m_logical_h;
		m_logical_scale = sx < sy ? sx : sy;
		m_logical_ox = (int)((g->GetWidth() - m_logical_w * m_logical_scale) / 2);
		m_logical_oy = (int)((g->GetHeight() - m_logical_h * m_logical_scale) / 2);
	}
	// -c - : commands arrive from standard input while the client runs, and
	// the run ends at end of input rather than when the list is used up
	bool m_command_seq_stdin = false;
	bool m_command_seq_stdin_eof = false;
	bool m_command_seq_failed = false;
	bool m_command_seq_extra_frame = false;

	// The look command, which aims the camera by injecting mouse movement
	// and watching what the camera does about it. Nothing here knows what
	// game is running: how far a pixel turns the camera, and which way, is
	// measured from the last frame's injection rather than assumed.
	// What the command log line has already been written for, so that a
	// command that takes several frames is announced once
	int m_command_logged_index = -1;
	// Frames a mouse_up has waited for its own down to be read
	int m_mouse_up_frames = 0;
	bool m_look_running = false;
	LookAxis m_look_x;
	LookAxis m_look_y;
	float m_look_last_yaw = 0.0f;
	float m_look_last_pitch = 0.0f;
	bool m_look_had_angles = false;
	int m_look_frames = 0;
	int m_look_no_camera_frames = 0;

	magic::SharedPtr<magic::Scene> m_scene;
	magic::SharedPtr<magic::Node> m_camera_node;

	// What set_preferred_viewports() was last given, and the rects the game
	// gave them in -- in window pixels, so that the scale can be applied
	// again from scratch when the window changes size
	// Bumped by set_preferred_viewports(); read through
	// buildat.viewport_generation() by a launcher waiting for a game
	int m_viewport_generation = 0;
	sv_<magic::SharedPtr<magic::Viewport>> m_preferred_viewports;
	sv_<magic::IntRect> m_preferred_rects;
	magic::SharedPtr<magic::Texture2D> m_preferred_texture;
	magic::SharedPtr<magic::BorderImage> m_preferred_image;

	// **What the launcher's UI was before a game was started**
	// ([MENU_CONTEXT]). A game's client half puts its HUD straight on
	// ui.root and nothing of it is named or removed, so the way back to
	// the launcher has to take it off -- and it cannot do that by
	// sweeping ui.root, because the client's own image is a child of it
	// too: the world's texture is drawn through
	// "buildat_preferred_viewports", and sweeping ui.root blind takes
	// the world off the screen and leaves a black frame (which is what
	// the first attempt found, 2026-09-23). So the launcher's children
	// are remembered when a connection starts, and the way back removes
	// the difference.
	sv_<magic::SharedPtr<magic::UIElement>> m_menu_ui_children;
	// No connection since the last leave, so no game put anything there:
	// a launch cancelled while its server compiled left through the same
	// leave and took the launcher's own elements ([RELEASE_RED] core.sh)
	bool m_menu_ui_remembered = false;
	// The launch UI that was asked for and did not load, so that the one
	// that did can say why it is not the one the setting names
	ss_ m_launch_ui_fell_back;
	// [LAN_DISCOVERY]: the group's socket, opened at the start or when
	// lan_discovery is turned on ([WIN_FIREWALL]), and what was heard,
	// by "host:port"
	struct LanEntry {
		ss_ name, app, version;
		int64_t players = 0;
		bool account = false;
		int64_t heard_us = 0;
	};
	int m_lan_fd = -1;
	bool m_lan_tried = false;
	bool m_lan_full_said = false;
	sm_<ss_, LanEntry> m_lan;

	sp_<interface::thread_pool::ThreadPool> m_thread_pool;

	CApp(magic::Context *context, const Options &options):
		magic::Application(context),
		m_script(nullptr),
		L(nullptr),
		m_options(options),
		m_last_update_us(get_timeofday_us()),
		m_thread_pool(interface::thread_pool::createThreadPool())
	{
		log_v(MODULE, "constructor()");
		check_pick_default_window_size();
		check_parse_preference_options();
		check_open_url_ok();
		check_scaled_viewport_size();
		// A -c run is on the built-in defaults, and muted: nothing captures
		// audio, and a driven run playing a game's music through the
		// developer's speakers is a small recurring annoyance with no upside
		m_options.preferences_disabled =
				g_client_config.get<bool>("command_seq_enabled");
		if(m_options.preferences_disabled)
			m_options.sound_mute = true;
		resolve_preferences(&m_options);
		if(!m_options.preference_overrides.empty()){
			// Already accepted once in main(), where a bad -o is a usage
			// error rather than a startup failure
			ss_ err;
			if(!parse_preference_options(m_options.preference_overrides,
					&m_options, &err))
				throw AppStartupError("-o: "+err);
		}
		// [LAN_DISCOVERY]: a launcher listens from the client's start,
		// so one built in its first frames (launch_world's floor) has
		// heard the 2 s announcements by then: the window takes ~2 s.
		// No address given is a launcher (boot_to_menu, set after this).
		// Once the player has looked at this network's games ([WIN_FIREWALL])
		if(g_client_config.get<ss_>("server_address").empty() &&
				m_options.lan_discovery)
			lan_listen();
		settle_render_scale(&m_options);
		if(m_options.graphics.size_forced){
			m_options.graphics.fullscreen = false;
			m_options.graphics.maximized = false;
		}
		log_v(MODULE, "preferences: render_scale=%s vsync=%i max_fps=%i"
				" multisampling=%i sound_volume_db=%s sound_mute=%i",
				cs(ftos(m_options.graphics.render_scale)),
				m_options.graphics.vsync ? 1 : 0,
				m_options.graphics.max_fps,
				m_options.graphics.multisampling,
				cs(ftos(m_options.sound_volume_db)),
				m_options.sound_mute ? 1 : 0);
		m_restore_maximized = m_options.graphics.maximized;
		log_v(MODULE, "window size: %ix%i maximized=%i fullscreen=%i",
				m_options.graphics.window_w, m_options.graphics.window_h,
				m_options.graphics.maximized ? 1 : 0,
				m_options.graphics.fullscreen ? 1 : 0);

#ifdef __EMSCRIPTEN__
		// No threads in the web client ([WEB_CLIENT]): the pool runs its
		// tasks' threaded part in run_post() instead
		m_thread_pool->start(0);
#else
		m_thread_pool->start(4); // TODO: Configurable
#endif

		interface::fs::create_directories(
				g_client_config.get<ss_>("cache_path")+"/server_icons");
		interface::fs::create_directories(
				g_client_config.get<ss_>("cache_path")+"/package_media");
		sv_<ss_> resource_paths = {
			g_client_config.get<ss_>("share_path")+"/client/data",
			g_client_config.get<ss_>("cache_path")+"/tmp",
			// The icons native servers sent ([LAUNCH_WORLD] (4)): a PNG a
			// file, named by its sha256, checked before it was kept
			g_client_config.get<ss_>("cache_path")+"/server_icons",
			// Aitta releases' icons and screenshots ([PACKAGE_MEDIA]), the
			// same: named by the hash, checked before kept
			g_client_config.get<ss_>("cache_path")+"/package_media",
			g_client_config.get<ss_>("share_path")+"/extensions", // Could be unsafe
			// The launch grid's icons: <name>/launcher/<icon>.png and a
			// game's icon.png, resolved by the menu on the trusted side
			// ([LAUNCH_GRID]). The same exposure as extensions above.
			g_client_config.get<ss_>("share_path")+"/apps",
			g_client_config.get<ss_>("share_path")+"/builtin",
			g_client_config.get<ss_>("urho3d_path")+"/bin/CoreData",
			g_client_config.get<ss_>("urho3d_path")+"/bin/Data",
		};
		ss_ resource_paths_s;
		for(const ss_ &path : resource_paths){
			if(!resource_paths_s.empty())
				resource_paths_s += ";";
			resource_paths_s += interface::fs::get_absolute_path(path);
		}

		// Set allowed paths in urho3d filesystem (part of sandbox)
		magic::FileSystem *magic_fs = GetSubsystem<magic::FileSystem>();
		for(const ss_ &path : resource_paths){
			magic_fs->RegisterPath(interface::fs::get_absolute_path(path).c_str());
		}
		magic_fs->RegisterPath(interface::fs::get_absolute_path(
				g_client_config.get<ss_>("cache_path")).c_str());

		// Useful for saving stuff for inspection when debugging
		magic_fs->RegisterPath("/tmp");
		// Where dump_meshes() writes its albedo textures through Urho's
		// own Image::SavePNG; the .obj beside them goes through fopen
		magic_fs->RegisterPath(interface::fs::get_absolute_path(
				g_client_config.get<ss_>("user_path")+"/meshdumps").c_str());

		// Set Urho3D engine parameters
		engineParameters_["WindowTitle"] =
				g_client_config.get<bool>("command_seq_enabled") ?
				"Buildat Client (scripted)" : "Buildat Client";
#ifdef __EMSCRIPTEN__
		// [PAGE_TITLE] SDL's window title is the page's: the one the server
		// wrote stays
		engineParameters_["WindowTitle"] = emscripten_run_script_string(
				"document.title");
#endif
		// The title bar's and the taskbar's ([WIN_RESOURCES]), from client/data
		engineParameters_["WindowIcon"] = "buildat_icon.png";
		engineParameters_["Headless"] = false;
		engineParameters_["ResourcePaths"] = resource_paths_s.c_str();
		engineParameters_["AutoloadPaths"] = "";
		engineParameters_["LogName"] = "";
		engineParameters_["LogQuiet"] = true; // Don't log to stdout

		// Graphics options
		engineParameters_["FullScreen"] = m_options.graphics.fullscreen;
		if(m_options.graphics.fullscreen){
			engineParameters_["WindowWidth"] = m_options.graphics.full_w;
			engineParameters_["WindowHeight"] = m_options.graphics.full_h;
		} else {
			engineParameters_["WindowWidth"] = m_options.graphics.window_w;
			engineParameters_["WindowHeight"] = m_options.graphics.window_h;
			engineParameters_["WindowResizable"] = m_options.graphics.resizable;
		}
#ifdef __EMSCRIPTEN__
		engineParameters_["HighDPI"] = true;
#endif
		engineParameters_["VSync"] = m_options.graphics.vsync;
		engineParameters_["TripleBuffer"] = m_options.graphics.triple_buffer;
		engineParameters_["Multisample"] = m_options.graphics.multisampling;
#ifndef __EMSCRIPTEN__
		// The audio device's buffer, ms: Urho3D's 100 is heard as a delay
		// ([SKELDAT_BOARD_SOUND_LAG]); 20 is its least, 1024 samples at
		// 44100 ([SKELDAT_BOARD_SOUND_FAULT]). The web's stays.
		// simplified: 20 for every app; 40 again if one crackles
		engineParameters_["SoundBuffer"] = 20;
#endif

		magic::Log *magic_log = GetSubsystem<magic::Log>();
		// Disable timestamps in log messages (also added to events)
		magic_log->SetTimeStamp(false);

		// Set up event handlers
		SubscribeToEvent(magic::E_BEGINFRAME, URHO3D_HANDLER(CApp, on_begin_frame));
		SubscribeToEvent(magic::E_UPDATE, URHO3D_HANDLER(CApp, on_update));
		SubscribeToEvent(magic::E_POSTRENDERUPDATE,
				URHO3D_HANDLER(CApp, on_post_render_update));
		SubscribeToEvent(magic::E_ENDRENDERING,
				URHO3D_HANDLER(CApp, on_end_rendering));
		SubscribeToEvent(magic::E_KEYDOWN, URHO3D_HANDLER(CApp, on_keydown));
		for(magic::StringHash e : {magic::E_KEYUP, magic::E_MOUSEBUTTONDOWN,
				magic::E_MOUSEBUTTONUP, magic::E_TOUCHBEGIN, magic::E_TOUCHEND})
			SubscribeToEvent(e, URHO3D_HANDLER(CApp, on_press));
		SubscribeToEvent(magic::E_SCREENMODE, URHO3D_HANDLER(CApp, on_screenmode));
		SubscribeToEvent(magic::E_INPUTFOCUS, URHO3D_HANDLER(CApp, on_inputfocus));
		SubscribeToEvent(magic::E_LOGMESSAGE, URHO3D_HANDLER(CApp, on_logmessage));

		// Default to not grabbing the mouse
		magic::Input *magic_input = GetSubsystem<magic::Input>();
		magic_input->SetMouseChangeReason("the client's start");
		magic_input->SetMouseVisible(true);

		// Default to auto-loading resources as they are modified
		magic::ResourceCache *magic_cache = GetSubsystem<magic::ResourceCache>();
		magic_cache->SetAutoReloadResources(true);
		m_router = new BuildatResourceRouter(context_);
		magic_cache->AddResourceRouter(m_router);
	}

	~CApp()
	{
		client::command_seq::finish_screenshots();
		stop_local_server();
	}

	void set_state(sp_<client::State> state)
	{
		m_state = state;
		m_joined_noted = false;
		m_router->set_client(state);
	}

	int run()
	{
		int r = magic::Application::Run();
		if(m_command_seq_failed)
			return 1;
		if(m_command_seq_active)
			return 1;
		return r;
	}

	void shutdown()
	{
		log_v(MODULE, "shutdown()");
		// What the window does while it goes is not the run's
		m_shutdown_begun = true;
		join_texture_writer();
		// Whatever is running has one last chance to close what it opened.
		// A network client that vanishes without saying goodbye is left on
		// the server until it times out, and the next client to connect
		// under the same name is refused; Urho3D sends this event when the
		// window is closed and nowhere else, so the paths that exit without
		// the window -- a command sequence ending, an error -- send it here.
		SendEvent(magic::E_EXITREQUESTED);
		stop_local_server();

		magic::Graphics *g = GetSubsystem<magic::Graphics>();
		if(g){
			m_options.graphics.fullscreen = g->GetFullscreen();
			if(!m_options.graphics.fullscreen)
				m_options.graphics.maximized = window_is_maximized(g);
			save_preferences(m_options);
		}

		magic::Engine *engine = GetSubsystem<magic::Engine>();
		engine->Exit();
	}

	void run_script(const ss_ &script)
	{
		log_v(MODULE, "run_script():\n%s", cs(script));

		lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_run_served_code");
		lua_pushlstring(L, script.c_str(), script.size());
		// A name of its own, which sandbox.lua counts as a server's chunk:
		// unnamed, its name was its own text, which no gate knew
		lua_pushstring(L, "=server");
		error_logging_pcall(L, 2, 1);
		bool status = lua_toboolean(L, -1);
		lua_pop(L, 1);
		if(status == false){
			log_w(MODULE, "run_script(): failed");
		} else {
			log_v(MODULE, "run_script(): succeeded");
		}
	}

	// When the connection went, if a local server this client started
	// might be what went with it; see lost_connection() and on_update()
	int64_t m_lost_connection_us = 0;
	// [LEAVE_WITH_REASON]: a remote server's connection went, and why;
	// the leave waits for on_update(), out of the state's own reading
	bool m_lost_remote = false;
	ss_ m_lost_remote_why;
	bool m_lost_remote_restarting = false;

	ss_ local_server_launch()
	{
		return g_local_server_launch;
	}

	ss_ owner_token_for(const ss_ &address)
	{
		if(g_local_server_token.empty() || g_local_server_port.empty() ||
				!interface::process::is_running(g_local_server))
			return "";
		if(address == "localhost:"+g_local_server_port ||
				address == "127.0.0.1:"+g_local_server_port ||
				(!local_pipe().empty() && address == "pipe:"+local_pipe()))
			return g_local_server_token;
		return "";
	}

#ifdef __EMSCRIPTEN__
	// **A web client left alone draws at web_idle_fps** ([WEB_IDLE_FPS]):
	// while the page is hidden or unfocused, or has had no input for a
	// minute. The frame is the browser's animation callback there, and
	// Urho3D's own limits (max_fps, the unfocused rate) are skipped under
	// __EMSCRIPTEN__, so the callback's timing is what changes. The page's
	// input listener (index.html) calls buildatWake, which puts the full
	// rate back on that input rather than on the next slow frame.
	bool m_web_idle = false;
	int m_web_idle_ms = 0;
	void web_idle_step()
	{
		const int rate = m_options.graphics.web_idle_fps;
		const int st = EM_ASM_INT({
			var idle = !(document.visibilityState === 'visible' &&
					document.hasFocus()) ||
					Date.now() - (Module['buildatInputAt'] || 0) > 60000;
			return (idle ? 1 : 0) | (Module['buildatWake'] ? 0 : 2);
		});
		const bool idle = st & 1;
		// **Catching up**: idle with a backlog ([WEB_LINK_BEHIND]). At 5
		// frames a second the page handles a few packets a frame, and a
		// world streaming in to a player who waited without touching
		// anything came in minutes late. A timer at 60 a second, not the
		// animation callback, which a hidden page does not get at all.
		const bool catching_up = idle &&
				m_state && m_state->get_backlog_bytes() > 0;
		const int ms = catching_up ? 16 : 1000 / (rate > 0 ? rate : 5);
		// The page's input woke it: the rate is full again, whatever this
		// side last set, and an unfocused page goes back to slow from there
		if(m_web_idle && (st & 2))
			m_web_idle = false;
		if(idle == m_web_idle && (!idle || ms == m_web_idle_ms))
			return;
		m_web_idle = idle;
		m_web_idle_ms = ms;
		if(idle){
			emscripten_set_main_loop_timing(EM_TIMING_SETTIMEOUT, ms);
			EM_ASM({
				Module['buildatWake'] = function(){
					Module['buildatWake'] = null;
					_emscripten_set_main_loop_timing(1, 1); // EM_TIMING_RAF
				};
			});
		} else {
			emscripten_set_main_loop_timing(EM_TIMING_RAF, 1);
			EM_ASM({ Module['buildatWake'] = null; });
		}
		log_v(MODULE, "web: %s", !idle ? "full rate" : catching_up ?
				"idle, catching up" : cs("idle, "+itos(rate)+" frames a second"));
	}
#endif

	void lost_connection(const ss_ &reason, bool restarting)
	{
#ifdef __EMSCRIPTEN__
		// The web client has no menu to go back to and cannot close its
		// tab ([WEB_CLIENT]): it stops, and the page says so and offers the
		// reload that connects again. An engine shutdown here only died in
		// its GL calls on the way out.
		EM_ASM({
			if(Module['onDisconnected'])
				Module['onDisconnected'](UTF8ToString($0), !!$1);
		}, reason.c_str(), restarting);
		emscripten_pause_main_loop();
		return;
#endif
		m_lost_remote_why = reason;
		m_lost_remote_restarting = restarting;
		// [LOCAL_REJOIN] A local server whose goodbye said it goes on is
		// left at once, to be rejoined: the wait below is for a crash
		if(g_local_server.valid() && !g_local_server_log.empty() &&
				!restarting){
			// The socket closes before the process is gone -- a crash
			// writes its backtrace first -- so the verdict waits a moment
			m_lost_connection_us = get_timeofday_us();
			return;
		}
		m_lost_remote = true;
	}

	void check_lost_connection()
	{
		// **A remote server's leaving is the launcher's, with why**
		// ([LEAVE_WITH_REASON], user 2026-10-07): a kick's text or the
		// connection's end in a dialog over it. A client started straight
		// into a server has no launcher under it and shuts down
		if(m_lost_remote){
			m_lost_remote = false;
			lua_pushlstring(L, m_lost_remote_why.c_str(),
					m_lost_remote_why.size());
			lua_setglobal(L, "__buildat_lost_why");
			lua_pushboolean(L, m_lost_remote_restarting);
			lua_setglobal(L, "__buildat_lost_restarting");
			if(!run_script_no_sandbox(
					"if not __buildat_leave_lost(__buildat_lost_why, "
					"__buildat_lost_restarting) then\n"
					"    __buildat_disconnect()\n"
					"end\n"))
				shutdown();
			return;
		}
		if(m_lost_connection_us == 0)
			return;
		if(!interface::process::is_running(g_local_server)){
			m_lost_connection_us = 0;
			// The dialog closes the client; the frozen view stays behind
			// it, and a client with no menu extension loaded gets the
			// plain shutdown
			const ss_ menu = launch_ui_name();
			if(run_script_no_sandbox(
					"local m = buildat.menu_extension and "
					"buildat.menu_extension()\n"
					"if not m or not m.show_dead_server then\n"
					"    m = require('buildat/extension/"+menu+"')\n"
					"end\n"
					"if not m or not m.show_dead_server then\n"
					"    error('the launcher cannot show a dead server')\n"
					"end\n"
					"m.show_dead_server('The server exited', "
					"function() __buildat_disconnect() end)\n"))
				return;
			shutdown();
		} else if(get_timeofday_us() - m_lost_connection_us > 2000000){
			// The server lives and dropped this client: a kick
			m_lost_connection_us = 0;
			m_lost_remote = true;
		}
	}

	bool run_script_no_sandbox(const ss_ &script)
	{
		log_v(MODULE, "run_script_no_sandbox():\n%s", cs(script));

		// TODO: Use lua_load() so that chunkname can be set
		if(luaL_loadstring(L, script.c_str())){
			ss_ error = lua_bindings::lua_tocppstring(L, -1);
			log_e("%s", cs(error));
			lua_pop(L, 1);
			return false;
		}
		error_logging_pcall(L, 0, 0);
		return true;
	}

	// **A server's icon** ([LAUNCH_WORLD] (4), 2026-10-03): what a native
	// server sends at connect, kept for the lobby's list of servers after
	// the connection is gone. Checked here and not trusted from the wire
	// -- a PNG of 64 KB at most and 512 pixels a side -- kept under the
	// cache by its sha256, and its hash written against the address the
	// client connected to in network_addresses.csv (the network
	// extension's own store, a column of its own). Not for the local
	// server the client started, whose address is a port of the moment,
	// nor a pipe's.
	// **One a server** ([SECURITY_RUN_1]): each new PNG was a new file
	// and a rewrite of the address store, so a server sending them in a
	// loop filled the cache. The first one from an address in a run.
	// simplified: a server's new icon is taken at the client's next run
	// **A server's icon, checked and kept** under the cache's
	// server_icons/ by its hash, which it returns; "" when it is not a
	// picture of SERVER_ICON_SIDE pixels a side or less. The handshake's
	// and Starport's listings' ([SERVER_ICONS]) both; from names the
	// source for the log.
	ss_ keep_icon(const ss_ &data, const ss_ &from)
	{
		// The size the PNG says it is, before decoding: a 64 KB file can
		// say 65535 pixels a side and be given the memory for it
		// ([SECURITY_RUN_1])
		const unsigned side = interface::fs::SERVER_ICON_SIDE;
		if(!interface::fs::icon_png_ok(data, side)){
			log_w(MODULE, "server icon from %s: not a PNG of 64 KB or less "
					"and %u pixels a side or less", cs(from), side);
			return "";
		}
		magic::MemoryBuffer buf(data.data(), (unsigned)data.size());
		magic::SharedPtr<magic::Image> img(new magic::Image(context_));
		if(!img->Load(buf) || img->GetWidth() < 1 || img->GetHeight() < 1 ||
				img->GetWidth() > (int)side || img->GetHeight() > (int)side){
			log_w(MODULE, "server icon from %s: not a picture of %u "
					"pixels a side or less", cs(from), side);
			return "";
		}
		const ss_ sha = interface::sha256::hex(interface::sha256::calculate(data));
		const ss_ dir = g_client_config.get<ss_>("cache_path")+"/server_icons";
		const ss_ path = dir+"/"+sha+".png";
		if(!interface::fs::path_exists(path)){
			interface::fs::create_directories(dir);
			std::ofstream f(path, std::ios::binary);
			f<<data;
			if(!f.good()){
				log_w(MODULE, "server icon: cannot write %s", cs(path));
				return "";
			}
		}
		return sha;
	}

	// **The store's row for the server joined** ([JOINED_TLS_SERVERS]):
	// "tcp://host:port", or "https://host:port" behind TLS -- the port
	// always said, as Starport's rows have it, so that the two match.
	// "" for the local server the client started, whose address is a
	// port of the moment, and for a pipe.
	ss_ store_uri()
	{
		const ss_ address = m_state ? m_state->get_address() : "";
		if(address.empty() || address.compare(0, 5, "pipe:") == 0)
			return "";
		adopt_pidfile();
		if(!g_local_server_app.empty() &&
				interface::process::is_running(g_local_server) &&
				(address == "localhost:"+g_local_server_port ||
				address == "127.0.0.1:"+g_local_server_port))
			return "";
		ss_ host, port, scheme = "tcp://";
#ifdef __EMSCRIPTEN__
		// A page on https has a secure WebSocket whatever the address says
		if(EM_ASM_INT({ return location.protocol === 'https:' ? 1 : 0; }))
			scheme = "https://";
#endif
		if(client::parse_secure_address(address, &host, &port))
			scheme = "https://";
		else if(address.find("://") != ss_::npos ||
				!interface::split_host_port(address, &host, &port, "29500"))
			return "";
		const ss_ hostport = interface::join_host_port(host, port);
		for(char c : hostport)
			if(!(isalnum((unsigned char)c) || c == '.' || c == '-' ||
					c == ':' || c == '[' || c == ']'))
				return ""; // not an address the store's rows can carry
		return scheme+hostport;
	}

	// The row made or touched once a connection, at the server's first
	// packet: a server joined is listed whether or not it sends an icon
	bool m_joined_noted = false;
	void note_joined()
	{
		m_joined_noted = true;
		const ss_ uri = store_uri();
		if(uri.empty())
			return;
		run_script_no_sandbox("require('buildat/core/network')"
				".remember_server('"+uri+"')");
	}

	ss_ m_icon_address;
	void handle_server_icon(const ss_ &data)
	{
		const ss_ address = m_state ? m_state->get_address() : "";
		const ss_ uri = store_uri();
		if(uri.empty() || address == m_icon_address)
			return;
		const ss_ sha = keep_icon(data, address);
		if(sha.empty())
			return;
		m_icon_address = address;
		run_script_no_sandbox("require('buildat/core/network')"
				".remember_server('"+uri+"', '"+sha+"')");
		log_i(MODULE, "server icon from %s kept as %s", cs(address),
				cs(sha.substr(0, 12)));
	}

	void handle_packet(const ss_ &name, const ss_ &data)
	{
		if(!m_joined_noted)
			note_joined();
		if(name == "core:server_icon"){
			handle_server_icon(data);
			return;
		}
		if(name == "launch:reusable"){
			if(m_state && !owner_token_for(m_state->get_address()).empty())
				g_local_server_reusable = data == "1";
			return;
		}
		log_v(MODULE, "handle_packet(): %s", cs(name));
		magic::AutoProfileBlock profiler_block(
				GetSubsystem<magic::Profiler>(), "Buildat|handle_packet");
		// **Which packet** ([PACKET_STALL]): the block above covers the
		// whole Lua dispatch and names nothing, and the worst frame on
		// the box is one packet -- so a nested block per packet type is
		// what tells an expensive handler from a burst of cheap ones.
		// Urho3D keeps the name pointer rather than the string, so the
		// names are interned here and outlive every block made from
		// them; the set of packet types is defined on the wire and does
		// not grow with traffic.
		static sm_<ss_, ss_> block_names;
		auto bn = block_names.find(name);
		if(bn == block_names.end())
			bn = block_names.insert(std::make_pair(name,
					ss_("Buildat|packet:")+name)).first;
		magic::AutoProfileBlock type_block(
				GetSubsystem<magic::Profiler>(), bn->second.c_str());

		lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_handle_packet");
		lua_pushlstring(L, name.c_str(), name.size());
		lua_pushlstring(L, data.c_str(), data.size());
		error_logging_pcall(L, 2, 0);
	}

	void served_file_forgotten(const ss_ &file_name)
	{
		magic::ResourceCache *magic_cache = GetSubsystem<magic::ResourceCache>();
		// Only a name the client has a file for: the rest have nothing to
		// go back to, and a game's thousands would each log a failed load
		if(magic_cache->Exists(file_name.c_str()))
			magic_cache->ReloadResourceWithDependencies(file_name.c_str());
	}

	void file_updated_in_cache(const ss_ &file_name,
			const ss_ &file_hash, const ss_ &cached_path)
	{
		log_v(MODULE, "file_updated_in_cache(): %s", cs(file_name));

		magic::ResourceCache *magic_cache = GetSubsystem<magic::ResourceCache>();
		magic_cache->ReloadResourceWithDependencies(file_name.c_str());

		/*lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_file_updated_in_cache");
		if(lua_isnil(L, -1)){
			lua_pop(L, 1);
			return;
		}
		lua_pushlstring(L, file_name.c_str(), file_name.size());
		lua_pushlstring(L, file_hash.c_str(), file_hash.size());
		lua_pushlstring(L, cached_path.c_str(), cached_path.size());
		error_logging_pcall(L, 3, 0);*/
	}

	magic::Scene* get_scene()
	{
		return m_scene;
	}

	interface::thread_pool::ThreadPool* get_thread_pool()
	{
		return m_thread_pool.get();
	}

	lua_State* get_lua()
	{
		return L;
	}

	// Non-public methods

	void apply_ui_scale()
	{
		magic::Graphics *g = GetSubsystem<magic::Graphics>();
		magic::UI *ui = GetSubsystem<magic::UI>();
		if(!g || !ui)
			return;
		float s = 0.f;
		if(m_ui_scale_lua > 0.f)
			s = m_ui_scale_lua;
		else {
			double cfg = g_client_config.get<double>("ui_scale");
			if(cfg > 0)
				s = (float)cfg;
			else if(!m_options.ui_size_auto)
				s = m_options.ui_size;
			else {
				// From the logical size in a scripted client, so that the
				// layout does not move with the window ([SEQ_FIXED_SIZE])
				int short_side = logical_mode() ? m_logical_w : g->GetWidth();
				int other = logical_mode() ? m_logical_h : g->GetHeight();
				if(other < short_side)
					short_side = other;
#ifdef __EMSCRIPTEN__
				// [FP_TOUCH] 1: the canvas is at device pixels, and a CSS
				// pixel is about as big to the eye on any screen, so the UI
				// is sized in those: never below one UI pixel to one CSS
				// pixel, and half again for a finger (the page says whether
				// the pointer is one)
				const double dpr = emscripten_get_device_pixel_ratio();
				short_side = (int)(short_side / dpr);
#endif
				s = (float)short_side / UI_REF_SHORT;
				if(s < 0.01f)
					s = 0.01f;
				else {
					int n = (int)(s + 0.5f);
					if(n >= 1 &&
							s >= (float)n * (1.f - UI_SNAP_UNDER) &&
							s <= (float)n * (1.f + UI_SNAP_OVER))
						s = (float)n;
				}
				// The web's, and a native client under BUILDAT_TOUCH=1 as a
				// phone at one device pixel to a CSS pixel ([HEARTH_USABILITY]:
				// the touch mode's fast loop)
				const char *touch = getenv("BUILDAT_TOUCH");
				const bool finger = touch && touch[0] == '1';
#ifdef __EMSCRIPTEN__
				const bool phone_rules = true;
#else
				const bool phone_rules = finger;
				const double dpr = 1.0;
#endif
				if(phone_rules){
					if(s < 1.f)
						s = 1.f;
					if(finger)
						s *= 1.5f;
					s *= (float)dpr;
					// But a phone's short side keeps room for a dialog: at
					// least UI_MIN_SHORT UI pixels across
					const float fit = (float)(short_side * dpr) / UI_MIN_SHORT;
					if(s > fit)
						s = fit;
				}
			}
		}
		// A scripted client keeps its logical size, which is what its
		// pictures are compared at; update_ui_fit() leaves it at 1 there
		s *= m_fit_factor;
		if(logical_mode()){
			// The root stays the logical size over the game's own UI scale,
			// drawn at that scale times the window's, and sits in the
			// letterbox
			update_logical_placement();
			// Urho divides the custom size by the scale for the root, so
			// the custom size is the letterboxed frame in pixels and the
			// root comes out at the logical size over the game's scale
			ui->SetCustomSize((int)(m_logical_w * m_logical_scale + 0.5f),
					(int)(m_logical_h * m_logical_scale + 0.5f));
			ui->SetScale(s * m_logical_scale);
			ui->GetRoot()->SetPosition(
					(int)(m_logical_ox / (s * m_logical_scale)),
					(int)(m_logical_oy / (s * m_logical_scale)));
			log_i(MODULE, "UI scale %g at logical %ix%i in %ix%i (x%g at %i,%i)",
					s, m_logical_w, m_logical_h, g->GetWidth(), g->GetHeight(),
					m_logical_scale, m_logical_ox, m_logical_oy);
			return;
		}
		ui->SetScale(s);
		// **The world's image is in UI units** ([WEB_QUARTER_VIEW]): a new
		// scale is a new root size, and an image left at the old one drew
		// the world in a corner (a phone's join, the fit going 3.09 ->
		// 1.55: the top-left quarter until a resize)
		if(m_preferred_image)
			m_preferred_image->SetSize(ui->GetRoot()->GetSize());
		log_i(MODULE, "UI scale %g (%ix%i)", s, g->GetWidth(), g->GetHeight());
	}

	// **Menus fit the screen** (user, 2026-09-30): each frame, the visible
	// top-level UI elements' sizes in UI units -- which a scale does not
	// change, so shrinking cannot feed back -- against the screen, and the
	// scale made small enough for the biggest to fit, down to FIT_FLOOR of
	// what it would be; back up when they fit again. By size, and for one
	// held to the top or the left by where it starts too, which scales
	// with it (user, 2026-09-30: the floorplanner's palette, under a
	// toolbar of two rows on a phone, ran off the bottom while its size
	// alone fitted); one that starts in the far half of the screen is put
	// partly off it on purpose, and is its game's. Centred or held to the
	// bottom or the right, the place moves with the scale and would feed
	// back, so only the size counts.
	// A side that is the root's own (a HUD, a stretched bar) follows the
	// screen and does not count.
	void update_ui_fit()
	{
		if(logical_mode())
			return;
		magic::Graphics *g = GetSubsystem<magic::Graphics>();
		magic::UI *ui = GetSubsystem<magic::UI>();
		magic::Input *in = GetSubsystem<magic::Input>();
		if(!g || !ui || !in)
			return;
		const int64_t now = get_timeofday_us();
		bool busy = in->GetMouseButtonDown(magic::MOUSEB_LEFT |
				magic::MOUSEB_MIDDLE | magic::MOUSEB_RIGHT) ||
				in->GetNumTouches() > 0;
		if(!busy){
			int n = 0;
			const Uint8 *keys = SDL_GetKeyboardState(&n);
			for(int i = 0; keys && i < n && !busy; i++)
				busy = keys[i] != 0;
		}
		if(busy){
			m_input_busy_us = now;
			return;
		}
		if(now - m_input_busy_us < FIT_QUIET_US)
			return;
		magic::UIElement *root = ui->GetRoot();
		const float base = ui->GetScale() / m_fit_factor;
		const magic::IntVector2 rs = root->GetSize();
		const float room_w = g->GetWidth() * 0.98f;
		const float room_h = g->GetHeight() * 0.98f;
		float need = base;
		// What set `need`, for the line: a fit that flips is a size that
		// follows the scale, and the line has to say whose
		magic::UIElement *by = nullptr;
		// A layer the size of the screen (a launcher's stack of screens)
		// is looked into: what is in it is what has to fit
		std::function<void(magic::UIElement *, int)> scan =
				[&](magic::UIElement *parent, int depth){
			for(magic::UIElement *c : parent->GetChildren()){
				if(!c || !c->IsVisible())
					continue;
				// A wrapped text is as wide as it was made, never what is in
				// it: a chat line follows the root's width, and counted it
				// scaled the UI down to fit itself ([LUANTI_CHAT_WRAP])
				if(c->GetType() == magic::Text::GetTypeStatic() &&
						static_cast<magic::Text *>(c)->GetWordwrap())
					continue;
				const magic::IntVector2 sz = c->GetSize();
				// The root's own size, give or take its rounding -- or its
				// size before the last fit: an element that follows the
				// root (a loading panel, a HUD) is resized after it, and
				// counted at its old size it moved the fit, which moved the
				// root, and the scale flipped between two values for good
				// ([LUANTI_NO_WORLD], x0.5 and x0.658 twice a second)
				const bool fill_w = std::abs(sz.x_ - rs.x_) <= 1 ||
						std::abs(sz.x_ - m_fit_prev_root.x_) <= 1;
				const bool fill_h = std::abs(sz.y_ - rs.y_) <= 1 ||
						std::abs(sz.y_ - m_fit_prev_root.y_) <= 1;
				if(fill_w && fill_h){
					if(depth < 4)
						scan(c, depth + 1);
					continue;
				}
				const magic::IntVector2 at = c->GetPosition();
				int ext_w = sz.x_;
				int ext_h = sz.y_;
				if(c->GetHorizontalAlignment() == magic::HA_LEFT &&
						at.x_ > 0 && at.x_ < rs.x_ / 2)
					ext_w += at.x_;
				if(c->GetVerticalAlignment() == magic::VA_TOP &&
						at.y_ > 0 && at.y_ < rs.y_ / 2)
					ext_h += at.y_;
				if(ext_w > 0 && !fill_w && ext_w * base > room_w &&
						room_w / ext_w < need){
					need = room_w / ext_w;
					by = c;
				}
				if(ext_h > 0 && !fill_h && ext_h * base > room_h &&
						room_h / ext_h < need){
					need = room_h / ext_h;
					by = c;
				}
			}
		};
		scan(root, 0);
		float f = std::max(FIT_FLOOR, std::min(1.f, need / base));
		if(std::fabs(f - m_fit_factor) > 0.02f){
			m_fit_factor = f;
			m_fit_prev_root = rs;
			if(by)
				log_i(MODULE, "UI scale fitted to the screen: x%g, by %s"
						" \"%s\" %ix%i at %i,%i in a root of %ix%i", f,
						by->GetTypeName().CString(), by->GetName().CString(),
						by->GetSize().x_, by->GetSize().y_,
						by->GetPosition().x_, by->GetPosition().y_,
						rs.x_, rs.y_);
			else
				log_i(MODULE, "UI scale fitted to the screen: x%g", f);
			apply_ui_scale();
		}
	}

	void Start()
	{
		log_v(MODULE, "Start()");

		apply_ui_scale();

#ifndef __EMSCRIPTEN__
		// [OS_CLIPBOARD] A field's Ctrl+C and Ctrl+V go through the OS
		// clipboard and not a copy Urho3D keeps of its own. The paste is
		// read on the C++ side into the focused field; the sandbox still
		// has no way to read the clipboard (safe_classes.lua).
		GetSubsystem<magic::UI>()->SetUseSystemClipboard(true);
#endif

#ifdef __EMSCRIPTEN__
		// Text input only while a text field has focus ([WEB_KEYS]): SDL
		// starts it with the window, and LineEdit turns it on and off with
		// its focus only for a screen keyboard. The web client's key handler
		// leaves character keys to the browser only while it is on.
		GetSubsystem<magic::UI>()->SetUseScreenKeyboard(true);
		SDL_StopTextInput();
#endif

		GetSubsystem<magic::Engine>()->SetMaxFps(m_options.graphics.max_fps);
		apply_sound_preferences();

		if(!m_options.graphics.fullscreen && m_restore_maximized){
			magic::Graphics *g = GetSubsystem<magic::Graphics>();
			if(g){
				g->Maximize();
				m_options.graphics.maximized = true;
				save_preferences(m_options);
			}
			m_restore_maximized = false;
		}

		start_lua();

		// Create a scene that will be synchronized from the server
		m_scene = new magic::Scene(context_);
		m_scene->CreateComponent<magic::Octree>(magic::LOCAL);
		m_scene->CreateComponent<magic::PhysicsWorld>(magic::LOCAL);
		m_scene->CreateComponent<magic::DebugRenderer>(magic::LOCAL);

		// Push the scene to the Lua environment
		lua_bindings::replicate::set_scene(L, m_scene);

		// Run initial client Lua scripts
		ss_ init_lua_path = g_client_config.get<ss_>("share_path")+
				"/client/init.lua";
		int error = luaL_dofile(L, init_lua_path.c_str());
		if(error){
			log_w(MODULE, "luaL_dofile: An error occurred: %s\n",
					lua_tostring(L, -1));
			lua_pop(L, 1);
			throw AppStartupError("Could not initialize Lua environment");
		}

		// **Which extension is the launcher**, for the places that have to
		// go back to it: leaving a game, a server that exited, and
		// whether a game is running under it. They named launch_menu,
		// which is wrong the moment the client is booted with another one
		// (-m launch_world). client/api.lua reads this.
		{
			const ss_ name = launch_ui_name();
			lua_pushstring(L, name.c_str());
			lua_setglobal(L, "__buildat_menu_extension_name");
		}

		// **A run is scripted from before the launcher boots**, not from
		// when the sequence starts stepping. It was set below, after the
		// menu extension had already loaded and taken the cursor --
		// which is what [SCRIPTED_CURSOR] exists to stop, and both its
		// guards read this flag (user, 2026-09-23: "I can't use my
		// mouse during your tests").
		m_command_seq_active = g_client_config.get<bool>("command_seq_enabled");
		// The mouse as a finger under BUILDAT_TOUCH=1, for a person trying
		// the touch UI by hand; a scripted run keeps its mouse and has
		// finger_* for touches ([HEARTH_USABILITY]). Not on the web: its
		// fingers are real, and SDL's mouse made from each one became a
		// second finger ([TOUCH_PARITY])
#ifndef __EMSCRIPTEN__
		{
			const char *touch = getenv("BUILDAT_TOUCH");
			if(touch && touch[0] == '1' && !m_command_seq_active)
				GetSubsystem<magic::Input>()->SetTouchEmulation(true);
		}
#endif

		boot_launcher();

		// Create debug HUD
		magic::ResourceCache *magic_cache = GetSubsystem<magic::ResourceCache>();
		magic::DebugHud *dhud = GetSubsystem<magic::Engine>()->CreateDebugHud();
		dhud->SetDefaultStyle(magic_cache->GetResource<magic::XMLFile>(
				"UI/DefaultStyle.xml"));

		start_command_seq();
	}

	// Start()'s phases ([SPLITS]: moved out as they were)

	// The Lua state, its watchdog and the client's __buildat_ functions
	void start_lua()
	{
		// Instantiate and register the Lua script subsystem so that we can use the LuaScriptInstance component
		context_->RegisterSubsystem(new magic::LuaScript(context_));

		m_script = context_->GetSubsystem<magic::LuaScript>();
		L = m_script->GetState();
		if(L == nullptr)
			throw Exception("m_script.GetState() returned null");
		g_watchdog_L = L;
		interface::debug::watchdog_on_freeze(watchdog_freeze);

		// Store current CApp instance in registry
		lua_pushlightuserdata(L, (void*)this);
		lua_setfield(L, LUA_REGISTRYINDEX, "__buildat_app");

		lua_bindings::init(L);

#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, lua_bindings::guarded<l_##name>); \
		lua_setglobal(L, "__buildat_" #name); \
}

		DEF_BUILDAT_FUNC(connect_server)
		DEF_BUILDAT_FUNC(keep_server_icon)
		DEF_BUILDAT_FUNC(keep_package_media)
		DEF_BUILDAT_FUNC(connect_server_start)
		DEF_BUILDAT_FUNC(connect_server_poll)
		DEF_BUILDAT_FUNC(disconnect)
		DEF_BUILDAT_FUNC(list_apps)
		DEF_BUILDAT_FUNC(aitta_install)
		DEF_BUILDAT_FUNC(remove_review)
		DEF_BUILDAT_FUNC(aitta_dev)
		DEF_BUILDAT_FUNC(open_url)
		DEF_BUILDAT_FUNC(open_log_folder)
#ifndef __EMSCRIPTEN__
		// Not in the web client, which has no folder to open: an app
		// leaves its button out there ([LUANTI_IMPORT_FOLDER])
		DEF_BUILDAT_FUNC(open_import_folder)
		DEF_BUILDAT_FUNC(local_game)
#endif
		DEF_BUILDAT_FUNC(start_local_server)
		DEF_BUILDAT_FUNC(list_launchers)
		DEF_BUILDAT_FUNC(list_installed_games)
		DEF_BUILDAT_FUNC(list_saves)
		DEF_BUILDAT_FUNC(save_value)
		DEF_BUILDAT_FUNC(stop_local_server)
		DEF_BUILDAT_FUNC(request_stop_local_server)
		DEF_BUILDAT_FUNC(force_kill_local_server)
		DEF_BUILDAT_FUNC(local_server_ready)
		DEF_BUILDAT_FUNC(local_server_running)
		DEF_BUILDAT_FUNC(keep_local_server)
		DEF_BUILDAT_FUNC(local_server_port)
		DEF_BUILDAT_FUNC(game_storage_dir)
		DEF_BUILDAT_FUNC(set_client_keys)
		DEF_BUILDAT_FUNC(server_address)
		DEF_BUILDAT_FUNC(lan_address)
		DEF_BUILDAT_FUNC(lan_servers)
		DEF_BUILDAT_FUNC(local_server_status)
		DEF_BUILDAT_FUNC(local_server_log_tail)
		DEF_BUILDAT_FUNC(send_packet);
		DEF_BUILDAT_FUNC(take_screenshot)
		DEF_BUILDAT_FUNC(save_file)
		DEF_BUILDAT_FUNC(exported_files)
		DEF_BUILDAT_FUNC(read_exported)
		DEF_BUILDAT_FUNC(pick_file)
		DEF_BUILDAT_FUNC(picked_file)
		DEF_BUILDAT_FUNC(save_part_begin)
		DEF_BUILDAT_FUNC(save_part_add)
		DEF_BUILDAT_FUNC(save_part_end)
		DEF_BUILDAT_FUNC(read_exported_part)
		DEF_BUILDAT_FUNC(picked_part)
		DEF_BUILDAT_FUNC(dump_meshes)
		DEF_BUILDAT_FUNC(get_file_path)
		DEF_BUILDAT_FUNC(get_file_content)
		DEF_BUILDAT_FUNC(get_path)
		DEF_BUILDAT_FUNC(create_directories)
		DEF_BUILDAT_FUNC(count_files)
		DEF_BUILDAT_FUNC(set_watchdog_seconds)
		DEF_BUILDAT_FUNC(set_reload_on_return)
		DEF_BUILDAT_FUNC(set_web_fullscreen)
		DEF_BUILDAT_FUNC(web_authorize)
		DEF_BUILDAT_FUNC(web_authorized)
		DEF_BUILDAT_FUNC(web_dgram)
		DEF_BUILDAT_FUNC(extension_path)
		DEF_BUILDAT_FUNC(set_ui_scale)
		DEF_BUILDAT_FUNC(user_activated)
		DEF_BUILDAT_FUNC(get_ui_scale)
		DEF_BUILDAT_FUNC(keyboard_height)
		DEF_BUILDAT_FUNC(display_density)
		DEF_BUILDAT_FUNC(received)
		DEF_BUILDAT_FUNC(last_arrival)
		DEF_BUILDAT_FUNC(in_flight)
		DEF_BUILDAT_FUNC(logical_size)
		DEF_BUILDAT_FUNC(get_preferred_render_scale)
		DEF_BUILDAT_FUNC(viewport_generation)
		DEF_BUILDAT_FUNC(get_preference)
		DEF_BUILDAT_FUNC(set_preference)
		DEF_BUILDAT_FUNC(list_preferences)
		DEF_BUILDAT_FUNC(launch_ui_fell_back)
		DEF_BUILDAT_FUNC(crash_dump_untold)
		DEF_BUILDAT_FUNC(get_env)
		DEF_BUILDAT_FUNC(is_scripted)
		DEF_BUILDAT_FUNC(press_back)
		DEF_BUILDAT_FUNC(set_back_depth)
		DEF_BUILDAT_FUNC(leave_web_page)
		DEF_BUILDAT_FUNC(serverless_start)
		DEF_BUILDAT_FUNC(leave_to_menu)
		DEF_BUILDAT_FUNC(http_get)
		DEF_BUILDAT_FUNC(http_poll)
		DEF_BUILDAT_FUNC(parse_json)
	}

	// The launcher booted, and what the environment asks of it at boot
	void boot_launcher()
	{
		// Launch menu if requested
		if(g_client_config.get<bool>("boot_to_menu")){
			ss_ extname = launch_ui_name();
			// -a kind/name/id: the menu boots and runs that one action of
			// its grid ([LAUNCH_GRID]); the string goes in quoted, and it
			// is a path's shape or nothing -- with an installed app's
			// "<author>.<name>@<version>" in it ([AITTA_MVP])
			ss_ action = g_client_config.get<ss_>("launch_action");
			for(char c : action)
				if(!(isalnum((unsigned char)c) || c == '_' || c == '-' ||
						c == '/' || c == '.' || c == '@' || c == '+')){
					action = "";
					break;
				}
			// **A launch UI that asks to be sandboxed is run in the
			// sandbox** ([LAUNCH_SANDBOX]): its own init.lua goes
			// through run_extension_file, which is the same door its
			// other files use, and what it gets is `buildat.safe` under
			// the name `buildat` -- the API every game has and nothing
			// else. A launch UI that does not ask for it is loaded the
			// way it always was, so the two kinds can live side by side
			// while the rest are moved over.
			const ss_ arg = action.empty() ? ss_("") : "'"+action+"'";
			ss_ script = ss_() +
					"if buildat.launch_ui_sandboxed('"+extname+"') then\n"
					"    local ok, err = __buildat_run_code_in_sandbox(\n"
					"        \"local m = buildat.run_extension_file('init.lua')\\n\"\n"
					"        ..\"if type(m) ~= 'table' or type(m.boot) ~= 'function' then\\n\"\n"
					"        ..\"    error('"+extname+" has no boot()')\\n\"\n"
					"        ..\"end\\n\"\n"
					"        ..\"m.boot("+arg+")\\n\"\n"
					// **And it hands its interface over**: a sandboxed
					// launch UI is not in the trusted table of loaded
					// extensions, so without this a game's own "back to
					// the launcher" finds no launcher and disconnects
					// instead ([LAUNCH_SANDBOX], 2026-09-24)
					"        ..\"buildat.provide_launch_interface(m)\\n\",\n"
					"        '"+extname+"/init.lua')\n"
					"    if not ok then error(err) end\n"
					"else\n"
					"    local m = require('buildat/extension/"+extname+"')\n"
					"    if type(m) ~= 'table' then\n"
					"        error('Failed to load extension "+extname+"')\n"
					"    end\n"
					"    m.boot("+arg+")\n"
					"end\n";
			// **A launch UI that raises is a launch UI that did not
			// load**: the runner turns a Lua error into an exception,
			// so a raising one would otherwise take the client with it
			// rather than falling back.
			bool booted = false;
			try {
				booted = run_script_no_sandbox(script);
			} catch(std::exception &e){
				log_w(MODULE, "launch UI \"%s\" raised: %s",
						cs(extname), e.what());
				booted = false;
			}
			if(!booted){
				// **A user cannot be left with no launcher**, which is
				// what a slot anybody can fill has to promise: the one
				// that came with the client is what a missing or
				// raising one falls back to, and the log says which
				// was asked for ([LAUNCH_SANDBOX]).
				bool tried_fallback = false;
				if(extname != "launch_menu"){
					log_w(MODULE, "launch UI \"%s\" did not load; falling"
							" back to launch_menu", cs(extname));
					m_launch_ui_fell_back = extname;
					lua_pushstring(L, "launch_menu");
					lua_setglobal(L, "__buildat_menu_extension_name");
					ss_ fallback = ss_() +
							"local m = require('buildat/extension/launch_menu')\n"
							"if type(m) ~= 'table' then\n"
							"    error('Failed to load extension launch_menu')\n"
							"end\n"
							"m.boot()\n";
					// **The fallback is caught too, which is the whole
					// promise**: a Lua error in the runner becomes a C++
					// exception, and nothing caught it here -- so the one
					// case this code exists for, a launch UI that raises,
					// terminated the client instead of falling back
					// ([MENU_FALLBACK], 2026-09-23).
					bool ok2 = false;
					try {
						// BUILDAT_TEST_NO_LAUNCHER=1 makes the fallback
						// fail, which is the only way to drive the last
						// resort without breaking launch_menu on disk: the
						// promise it keeps is worth a check of its own
						if(getenv("BUILDAT_TEST_NO_LAUNCHER"))
							throw Exception("BUILDAT_TEST_NO_LAUNCHER");
						ok2 = run_script_no_sandbox(fallback);
					} catch(std::exception &e2){
						log_e(MODULE, "the fallback launch UI launch_menu"
								" raised: %s", e2.what());
						ok2 = false;
					}
					tried_fallback = true;
					if(ok2){
						log_i(MODULE, "the launch UI is launch_menu, not \"%s\"",
								cs(extname));
						goto launch_ui_done;
					}
				}
				// **A last resort that is not Lua**: there is nothing
				// left to draw a screen with, so it is the operating
				// system's own box, and it says how to pick another.
				{
					ss_ msg = ss_() +
							"buildat could not start a launch UI.\n\n"
							"Asked for: " + extname + "\n" +
							(tried_fallback ?
							"The built-in menu (launch_menu) raised as well.\n" :
							"") +
							"\nStart it with another one:\n"
							"    buildat -m launch_world\n"
							"or take launch_ui out of settings.json.\n\n"
							"The log has the error.";
					log_e(MODULE, "%s", cs(msg));
					// **In the client's own window, not a box from the
					// window manager** (user, 2026-09-23: "that dialog
					// comes up as a different WM window"). A separate
					// window steals the desktop's focus, which is the
					// same intrusion as taking the screen or the
					// keyboard. This is Urho3D's own UI from C++ --
					// there is no Lua left to draw with, but the engine
					// is up -- and the client keeps running so the
					// message can be read.
					magic::UI *ui = GetSubsystem<magic::UI>();
					magic::ResourceCache *rc =
							GetSubsystem<magic::ResourceCache>();
					if(ui && ui->GetRoot() && rc){
						magic::Text *t =
								ui->GetRoot()->CreateChild<magic::Text>();
						magic::Font *font = rc->GetResource<magic::Font>(
								"Fonts/OverpassMono-Regular.ttf");
						if(!font)
							font = rc->GetResource<magic::Font>(
									"Fonts/Anonymous Pro.ttf");
						if(font)
							t->SetFont(font, 15);
						t->SetText(msg.c_str());
						t->SetColor(magic::Color(1.0f, 0.85f, 0.6f));
						t->SetTextAlignment(magic::HA_CENTER);
						t->SetAlignment(magic::HA_CENTER, magic::VA_CENTER);
					}
					// **And the rest of Start() still runs**: a client
					// that returned here had no command sequence set up
					// either, so a driven run hung with nothing to
					// quit it (2026-09-23).
				}
				launch_ui_done: ;
			}
			// [PLAY_LINKS] a play page's ?server=host:port (index.html's
			// BUILDAT_JOIN): joined if a Starport in the settings lists it.
			// The shape is checked here too, since it goes into a script.
			const char *join = getenv("BUILDAT_JOIN");
			if(join && *join){
				const ss_ a = join;
				ss_ host, port;
				bool ok = a.size() <= 260 &&
						interface::split_host_port(a, &host, &port, "") &&
						!port.empty();
				for(size_t i = 0; ok && i < host.size(); i++){
					const char c = host[i];
					ok = isalnum((unsigned char)c) || c == '.' || c == '-';
				}
				if(ok)
					run_script_no_sandbox("__buildat_join_listed('"+a+"')");
				else
					log_w(MODULE, "BUILDAT_JOIN is not host:port; not joined");
			}
			// [SERVERLESS_PLAY] BUILDAT_RUN (a play page's #run=): an app run
			// with no server, <author>/<name> or an app id; the shape
			// checked here too, since it goes into a script
			const char *run = getenv("BUILDAT_RUN");
			if(run && *run){
				const ss_ r = run;
				bool ok = r.size() <= 200;
				for(size_t i = 0; ok && i < r.size(); i++){
					const char c = r[i];
					ok = isalnum((unsigned char)c) || strchr("._-/:@", c);
				}
				if(ok)
					run_script_no_sandbox("__buildat_run_serverless('"+r+"')");
				else
					log_w(MODULE, "BUILDAT_RUN is not an app's name; not run");
			}
		}
	}

	#include "command_seq_run.h"

	void on_update(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		// A frame: the watchdog hears it, and logs this thread's stack
		// when none comes for ten seconds ([WIN8_START] 14) -- or for
		// what a screen asked (the starting screen asks for two: its
		// counter froze for seconds on the box while the server loaded
		// worldgen, and the stack says what this thread was doing;
		// [BOX_PLAYTEST_2] 12)
		interface::debug::watchdog_alive(g_watchdog_seconds);
#ifdef __EMSCRIPTEN__
		// The page's "Starting the engine..." ends at the first frame
		// ([LOAD_SHOWN]); what a join does next says its own
		static bool started = false;
		if(!started){
			started = true;
			EM_ASM({
				Module.buildatUp = 1;
				if(Module.setStatus)
					Module.setStatus('');
			});
		}
#endif
		if(g_watchdog_hooked.exchange(false))
			lua_sethook(L, nullptr, 0, 0);
#ifdef __EMSCRIPTEN__
		web_text_sync(GetSubsystem<magic::UI>());
		web_fields_publish(GetSubsystem<magic::UI>());
		web_idle_step();
		// [TAP_BACK] the browser's Back, each one Escape (index.html)
		for(int n = EM_ASM_INT({ var n = Module.buildatBack | 0;
				Module.buildatBack = 0; return n; }); n > 0; n--){
			ss_ err;
			client::command_seq::inject_key(GetSubsystem<magic::Input>(),
					"Escape", true, true, &err);
		}
#endif
		update_ui_fit();
		// A local server on its way out is reaped here rather than in
		// whoever asked for it to go ([QUIT_STALL])
		step_stop_local_server();
		// Before anything reads it: a scripted mouse_move's delta lands
		// at the top of the frame after the one that asked for it
		client::command_seq::apply_pending_mouse_move(
				GetSubsystem<magic::Input>());
		/*magic::AutoProfileBlock profiler_block(
				GetSubsystem<magic::Profiler>(), "App::on_update");*/

		check_lost_connection();
		if(g_shutdown_signal != 0 && !m_shutdown_signal_handled){
			m_shutdown_signal_handled = true;
			// SIGINT leaves a "^C" on the terminal to write past
			if(g_shutdown_signal == SIGINT)
				fprintf(stdout, "\n");
			log_i(MODULE, "%s; shutting down",
					g_shutdown_signal == SIGINT ? "SIGINT" : "SIGTERM");
			shutdown();
		}
		if(m_state){
			// Under a block of its own: the network's packets and the Lua
			// they run land here, and a frame that goes into them showed
			// as an Update with nothing in it ([FRAME_PEAK])
			magic::AutoProfileBlock profiler_block(
					GetSubsystem<magic::Profiler>(), "Buildat|State::update");
			m_state->update();
		}

		{
			magic::AutoProfileBlock profiler_block(
					GetSubsystem<magic::Profiler>(), "Buildat|ThreadPool::post");
			m_thread_pool->run_post();
		}

#ifdef DEBUG_CORE_TIMING
		int64_t t1 = get_timeofday_us();
		int interval = t1 - m_last_update_us;
		if(interval > 30000)
			log_w(MODULE, "Too long update interval: %ius", interval);
		m_last_update_us = t1;
#endif
	}

	void on_begin_frame(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		command_seq_tick();
	}

	void on_post_render_update(
			magic::StringHash event_type, magic::VariantMap &event_data)
	{
		if(m_draw_debug_geometry)
			m_scene->GetComponent<magic::PhysicsWorld>()->DrawDebugGeometry(true);
	}

	void on_end_rendering(
			magic::StringHash event_type, magic::VariantMap &event_data)
	{
		if(m_pending_screenshot.empty())
			return;
		ss_ path = m_pending_screenshot;
		m_pending_screenshot.clear();
		ss_ err;
		update_logical_placement();
		if(!client::command_seq::save_screenshot(
				GetSubsystem<magic::Graphics>(), path, &err,
				logical_mode() ? m_logical_w : 0, logical_mode() ? m_logical_h : 0,
				m_logical_ox, m_logical_oy, m_logical_scale))
			command_seq_fail(err);
	}

	void on_press(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		m_last_press_us = interface::os::time_us();
	}

	void on_keydown(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		m_last_press_us = interface::os::time_us();
		int key = event_data["Key"].GetInt();
		if(key == m_key_fullscreen){
			log_v(MODULE, "F11");
			magic::Graphics *magic_graphics = GetSubsystem<magic::Graphics>();
			if(magic_graphics->GetFullscreen()){
				m_options.graphics.fullscreen = false;
				m_options.graphics.resizable = true;
				m_options.graphics.apply(magic_graphics);
				if(m_options.graphics.maximized)
					magic_graphics->Maximize();
			} else {
				m_options.graphics.fullscreen = true;
				m_options.graphics.resizable = false;
				m_options.graphics.apply(magic_graphics);
			}
		}
		if(key == m_key_screenshot && (event_data["Qualifiers"].GetInt() & Urho3D::QUAL_CTRL)){
			ss_ extname = "sandbox_scan";
			ss_ script = ss_() +
					"local m = require('buildat/core/"+extname+"')\n"
					"if type(m) ~= 'table' then\n"
					"    error('Failed to load "+extname+"')\n"
					"end\n"
					"m.toggle()\n";
			if(!run_script_no_sandbox(script)){
				log_e(MODULE, "Failed to load and run extension %s", cs(extname));
			}
		}
		// **F9 to F12 are the client's, every other key an app's**
		// ([CLIENT_KEYS]); no script hears these four
		// (client/core/urho3d). F9 is the trusted overlay's. The
		// player can move them (the key store, client/api.lua).
		const bool ctrl = event_data["Qualifiers"].GetInt() & Urho3D::QUAL_CTRL;
		// F10: the engine's DebugHud, the profiler there is; Ctrl+F10 the
		// physics debug geometry
		if(key == m_key_profiler && !ctrl){
			magic::DebugHud *dhud = GetSubsystem<magic::Engine>()->CreateDebugHud();
			dhud->ToggleAll();
		}
		if(key == m_key_profiler && ctrl){
			m_draw_debug_geometry = !m_draw_debug_geometry;
			log_i(MODULE, "Ctrl+F10: physics debug geometry %s",
					m_draw_debug_geometry ? "on" : "off");
		}
		// F12 alone: a screenshot under <user>/screenshots, as official's
		// ([VIEW_KEYS]); Ctrl+F12 stays the sandbox test's
		if(key == m_key_screenshot && !(event_data["Qualifiers"].GetInt() & Urho3D::QUAL_CTRL)){
			if(m_pending_screenshot.empty()){
				const ss_ dir = g_client_config.get<ss_>("user_path")+"/screenshots";
				const ss_ name = client::command_seq::screenshot_name(dir);
				m_pending_screenshot = dir+"/"+name;
				log_i(MODULE, "F12: screenshot %s", cs(name));
			}
		}
	}

	void remember_menu_ui()
	{
		m_menu_ui_children.clear();
		m_menu_ui_remembered = true;
		magic::UI *ui = GetSubsystem<magic::UI>();
		if(!ui || !ui->GetRoot())
			return;
		const magic::Vector<magic::SharedPtr<magic::UIElement>> &cs =
				ui->GetRoot()->GetChildren();
		for(unsigned i = 0; i < cs.Size(); i++)
			m_menu_ui_children.push_back(cs[i]);
		log_v(MODULE, "remember_menu_ui(): %zu elements",
				m_menu_ui_children.size());
	}

	// Everything a game put on ui.root, and nothing the launcher or the
	// client owns. The client's own image is kept whether or not it was
	// there when the connection started -- it carries the world.
	void forget_game_ui()
	{
		if(!m_menu_ui_remembered)
			return;
		m_menu_ui_remembered = false;
		magic::UI *ui = GetSubsystem<magic::UI>();
		if(!ui || !ui->GetRoot())
			return;
		magic::Vector<magic::SharedPtr<magic::UIElement>> cs =
				ui->GetRoot()->GetChildren();
		unsigned removed = 0;
		for(unsigned i = 0; i < cs.Size(); i++){
			magic::UIElement *e = cs[i];
			if(!e || e == m_preferred_image)
				continue;
			// **The client's own trusted overlay**, whenever it was made
			// ([TRUST_OVERLAY_LEAVE]): the trust colour's sample is made on
			// the first frame, and one made during a connection was taken
			// for the game's -- and its handler holds it
			if(e->GetName().StartsWith("__trusted"))
				continue;
			bool theirs = true;
			for(const auto &k : m_menu_ui_children){
				if(k == e){
					theirs = false;
					break;
				}
			}
			if(theirs){
				e->Remove();
				removed++;
			}
		}
		m_menu_ui_children.clear();
		log_i(MODULE, "forget_game_ui(): %u elements removed", removed);
	}

	// **Which extension is the launch UI** ([LAUNCH_SANDBOX]: a slot an
	// extension fills, not a setting with three values). `-m` wins for
	// the run it is given on; otherwise it is the saved preference,
	// which defaults to `launch_menu`.
	ss_ launch_ui_name()
	{
		const ss_ named = g_client_config.get<ss_>("menu_extension_name");
		if(!named.empty())
			return named;
		if(m_options.launch_ui.empty())
			return "launch_menu";
		return m_options.launch_ui;
	}

	void set_preferred_viewports(const sv_<magic::Viewport*> &viewports)
	{
		// **Who has the screen** ([LAUNCH_WORLD], 2026-09-24: the room
		// stands down too early). Taking the view is this call, and a
		// launcher that keeps drawing while a game loads has to know
		// when the game has actually taken it. The count lives here
		// rather than in client/core/urho3d because each sandbox has its
		// own copy of that file: a game bumping its own count is not
		// something the launcher's copy can see.
		m_viewport_generation++;
		m_preferred_viewports.clear();
		m_preferred_rects.clear();
		for(magic::Viewport *vp : viewports){
			m_preferred_viewports.push_back(magic::SharedPtr<magic::Viewport>(vp));
			m_preferred_rects.push_back(vp->GetRect());
		}
		apply_preferred_viewports();
	}

	float get_preferred_render_scale()
	{
		return m_options.graphics.render_scale;
	}

	// The user's render_scale reaching viewports the games made themselves:
	// they go onto an offscreen texture of the asked-for size, and that
	// texture is drawn under the UI. Urho3D draws the UI to the backbuffer
	// after the viewports, so the UI is never undersampled.
	void apply_preferred_viewports()
	{
		magic::Renderer *renderer = GetSubsystem<magic::Renderer>();
		magic::Graphics *graphics = GetSubsystem<magic::Graphics>();
		if(!renderer || !graphics)
			return;
		unsigned n = m_preferred_viewports.size();
		float scale = m_options.graphics.render_scale;
		// 1.0 is a bypass and not a scale of one: no texture, no blit, the
		// frame the client draws when nothing asked for anything -- except
		// in the scripted client, whose world always goes onto a texture of
		// the logical size ([SEQ_FIXED_SIZE])
		if(scale > 0.999f && scale < 1.001f && !logical_mode()){
			drop_preferred_texture();
			renderer->SetNumViewports(n);
			for(unsigned i = 0; i < n; i++){
				m_preferred_viewports[i]->SetRect(m_preferred_rects[i]);
				renderer->SetViewport(i, m_preferred_viewports[i]);
			}
			return;
		}
		if(n == 0){
			// Teardown has to leave nothing behind: a stale texture under
			// the UI is last frame's world, still on the screen
			drop_preferred_texture();
			renderer->SetNumViewports(0);
			return;
		}

		int tw = scaled_length(graphics->GetWidth(), scale);
		int th = scaled_length(graphics->GetHeight(), scale);
		// The rects the game gave are in the window it saw; in logical
		// mode they are taken as fractions of it onto the logical frame
		float rx = 1.f, ry = 1.f;
		if(logical_mode()){
			tw = m_logical_w;
			th = m_logical_h;
			scale = 1.f;
			rx = (float)m_logical_w / (float)graphics->GetWidth();
			ry = (float)m_logical_h / (float)graphics->GetHeight();
		}
		if(!m_preferred_texture || m_preferred_texture->GetWidth() != tw ||
				m_preferred_texture->GetHeight() != th){
			m_preferred_texture = new magic::Texture2D(context_);
			m_preferred_texture->SetSize(tw, th,
					magic::Graphics::GetRGBFormat(), magic::TEXTURE_RENDERTARGET);
			m_preferred_texture->SetFilterMode(magic::FILTER_BILINEAR);
		}
		magic::RenderSurface *surface = m_preferred_texture->GetRenderSurface();
		if(!surface){
			log_w(MODULE, "set_preferred_viewports(): no render surface;"
					" drawing at native resolution");
			drop_preferred_texture();
			renderer->SetNumViewports(n);
			for(unsigned i = 0; i < n; i++)
				renderer->SetViewport(i, m_preferred_viewports[i]);
			return;
		}
		surface->SetNumViewports(n);
		for(unsigned i = 0; i < n; i++){
			magic::IntRect r = scaled_rect(m_preferred_rects[i], scale);
			if(logical_mode()){
				const magic::IntRect &p = m_preferred_rects[i];
				r = magic::IntRect((int)(p.left_ * rx), (int)(p.top_ * ry),
						(int)(p.right_ * rx), (int)(p.bottom_ * ry));
				if(n == 1)
					r = magic::IntRect(0, 0, tw, th);
			}
			m_preferred_viewports[i]->SetRect(r);
			surface->SetViewport(i, m_preferred_viewports[i]);
		}
		surface->SetUpdateMode(magic::SURFACE_UPDATEALWAYS);
		renderer->SetNumViewports(0);

		magic::UI *ui = GetSubsystem<magic::UI>();
		if(!ui)
			return;
		if(!m_preferred_image){
			m_preferred_image = new magic::BorderImage(context_);
			m_preferred_image->SetName("buildat_preferred_viewports");
			// Under whatever UI the game has, and never in the way of it:
			// a disabled element takes no input
			m_preferred_image->SetPriority(-10000);
			m_preferred_image->SetEnabled(false);
			ui->GetRoot()->AddChild(m_preferred_image);
		}
		m_preferred_image->SetTexture(m_preferred_texture);
		m_preferred_image->SetImageRect(magic::IntRect(0, 0, tw, th));
		// UI coordinates, which the UI scale has already divided down
		m_preferred_image->SetPosition(0, 0);
		m_preferred_image->SetSize(ui->GetRoot()->GetSize());
	}

	// The preferences to the page, whose sync_fullscreen reads them
	// ([WEB_ADDRESS_BAR], [SCREEN_ORIENTATION]); nothing natively
	void push_web_address_bar()
	{
#ifdef __EMSCRIPTEN__
		EM_ASM({
			Module['buildatAddressBar'] = UTF8ToString($0);
			Module['buildatOrientation'] = UTF8ToString($1);
			Module['buildatSyncFullscreen']();
		}, m_options.graphics.web_address_bar.c_str(),
				m_options.graphics.screen_orientation.c_str());
#endif
	}

	void drop_preferred_texture()
	{
		if(m_preferred_image){
			m_preferred_image->Remove();
			m_preferred_image.Reset();
		}
		if(m_preferred_texture){
			magic::RenderSurface *surface =
					m_preferred_texture->GetRenderSurface();
			if(surface)
				surface->SetNumViewports(0);
			m_preferred_texture.Reset();
		}
	}

	// Urho3D multiplies a sound type's gain by the "Master" one
	// (Audio::GetSoundSourceMasterGain()), so setting the master here scales
	// every sound in every game, under whatever mixing the game does of its
	// own. The sandbox refuses "Master" to sandboxed code, which is what
	// makes this enforcement rather than a default.
	// What a changed preference does now rather than at the next start. Each
	// one is applied only when it actually changed: setting a screen mode
	// that is already the screen mode still costs a mode change.
	void apply_changed_preferences(const app::Options &before)
	{
		const GraphicsOptions &g = m_options.graphics;
		const GraphicsOptions &b = before.graphics;
		if(m_options.sound_volume_db != before.sound_volume_db ||
				m_options.sound_mute != before.sound_mute)
			apply_sound_preferences();
		if(m_options.lan_discovery)
			lan_listen();
		// The client's own level at once; the server's on its next start.
		// Not over a -l given for this run.
		if(m_options.log_level != before.log_level &&
				!g_client_config.get<bool>("log_level_given")){
			log_set_max_level(m_options.log_level);
			log_i(MODULE, "log level %d, from the preferences", m_options.log_level);
		}
		g_server_log_level_pref = m_options.server_log_level;
		if(g.max_fps != b.max_fps){
			if(magic::Engine *e = GetSubsystem<magic::Engine>())
				e->SetMaxFps(g.max_fps);
		}
		if(g.vsync != b.vsync || g.multisampling != b.multisampling){
			if(magic::Graphics *gr = GetSubsystem<magic::Graphics>())
				m_options.graphics.apply(gr);
		}
		if(g.render_scale != b.render_scale)
			apply_preferred_viewports();
		if(g.web_address_bar != b.web_address_bar ||
				g.screen_orientation != b.screen_orientation)
			push_web_address_bar();
		if(m_options.ui_size != before.ui_size ||
				m_options.ui_size_auto != before.ui_size_auto)
			apply_ui_scale();
	}

	void apply_sound_preferences()
	{
		magic::Audio *audio = GetSubsystem<magic::Audio>();
		if(!audio)
			return;
		// **The one place a decibel becomes a gain** ([VOLUME_LAW]).
		// Everything above this line -- the settings screen, the pause
		// menu, the room's desk -- carries decibels and nothing else.
		const float db = m_options.sound_volume_db;
		const float gain = (m_options.sound_mute ||
				db <= app::SOUND_OFF_DB + 0.01f) ? 0.0f :
				(float)pow(10.0, db / 20.0);
		audio->SetMasterGain("Master", gain);
	}

	// With the cursor hidden, Urho3D on Linux hands the focus back only on
	// a click inside the window, and drops it again the same frame if the
	// WM has not given the window SDL's input focus. A client that stops
	// taking the mouse looks like that; this is the line that says so
	// (doc/plan/luanti_module_history.md, [MOUSE_FOCUS_LOST]).
	// The reason and the state before it are Urho3D's line (Input.cpp,
	// [FOCUS_LOG]); this adds what only the client knows
	void on_inputfocus(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		log_i(MODULE, "input focus %s; a command sequence %s",
				event_data["Focus"].GetBool() ? "gained" : "lost",
				m_command_seq_active ? "is running" : "is not running");
	}

	void on_screenmode(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		magic::Graphics *magic_graphics = GetSubsystem<magic::Graphics>();
		bool full = magic_graphics->GetFullscreen();
		bool maxed = !full && window_is_maximized(magic_graphics);
		int w = event_data["Width"].GetInt();
		int h = event_data["Height"].GetInt();
		// What a check waits on after it resizes the window or the canvas
		log_i(MODULE, "screen mode: %ix%i", w, h);
		int desk_w = 0;
		int desk_h = 0;
		bool fills_desktop = desktop_size(&desk_w, &desk_h) &&
				w >= desk_w * 9 / 10 && h >= desk_h * 9 / 10;
		m_options.graphics.fullscreen = full;
		if(!full){
			if(maxed || fills_desktop){
				// Don't save maximized pixel size as the restore size.
				m_options.graphics.maximized = true;
			} else {
				m_options.graphics.maximized = false;
				m_options.graphics.window_w = w;
				m_options.graphics.window_h = h;
			}
		}
		log_v(MODULE, "Window state: %ix%i maximized=%i fullscreen=%i",
				m_options.graphics.window_w, m_options.graphics.window_h,
				m_options.graphics.maximized ? 1 : 0,
				m_options.graphics.fullscreen ? 1 : 0);
		save_preferences(m_options);
		apply_ui_scale();
		// An "auto" render scale follows the window's size
		settle_render_scale(&m_options);
		// The offscreen texture is a fraction of the window, so a new window
		// size is a new texture
		apply_preferred_viewports();
	}

	void on_logmessage(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		int magic_level = event_data["Level"].GetInt();
		ss_ message = event_data["Message"].GetString().CString();
		//log_v(MODULE, "on_logmessage(): %i, %s", magic_level, cs(message));
		int c55_level = CORE_ERROR;
		if(magic_level == magic::LOG_DEBUG)
			c55_level = CORE_DEBUG;
		else if(magic_level == magic::LOG_INFO)
			// Urho3D's INFO is chatter, except the input lines this tree
			// added to it ([FOCUS_LOG]): a lost mouse is read from a log
			// at info
			// (the message carries Urho's "INFO: " prefix)
			c55_level = (message.find("INFO: input ") != ss_::npos ||
					message.find("INFO: mouse ") != ss_::npos) ?
					CORE_INFO : CORE_VERBOSE;
		else if(magic_level == magic::LOG_WARNING)
			c55_level = CORE_WARNING;
		else if(magic_level == magic::LOG_ERROR)
			// No audio device (a CI container, Wine) is the box's, not a
			// fault: a warning, so a drive's error watch does not end on
			// it ([PACKAGE_070_SMOKE])
			c55_level = message.find("Could not initialize audio output") !=
					ss_::npos ? CORE_WARNING : CORE_ERROR;
		log_(c55_level, MODULE, "Urho3D %s", cs(message));
	}

	#include "app_lua.h"
};

App* createApp(magic::Context *context, const Options &options)
{
	return new CApp(context, options);
}

}
// vim: set noet ts=4 sw=4:
