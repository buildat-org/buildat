// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "client/command_seq.h"
#include "core/log.h"
#include "interface/fs.h"
#include <ctime>
#include <set>
#include <map>
#include <c55/string_util.h>
#include <Graphics.h>
#include <Image.h>
#include <Input.h>
#include <FileSystem.h>
#include <SDL/SDL.h>
// The PNG encoder, ours in this file: Urho3D's Image::SavePNG is 180-210 ms
// of the frame for a 1280x720 shot, on the main thread, and every
// scripted run's screenshot was a "rest" peak in the frame column
// ([FRAME_PEAK]); the pixels are copied out and written on a thread.
// The web client links the engine statically, and its archive has the
// encoder already ([WEB_CLIENT]).
#ifndef __EMSCRIPTEN__
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBIW_ASSERT(x)
#endif
#include <STB/stb_image_write.h>
#include <thread>
#include <mutex>
#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <climits>
#include <fcntl.h>
#include <unistd.h>
#include <map>
#define MODULE "cmdseq"
namespace magic = Urho3D;

namespace client {
namespace command_seq {

static ss_ trim_copy(const ss_ &s)
{
	return c55::trim(s);
}

static bool parse_i64(const ss_ &s, int64_t *out)
{
	if(s.empty())
		return false;
	errno = 0;
	char *end = nullptr;
	long long v = strtoll(s.c_str(), &end, 10);
	if(errno || end == s.c_str() || *end != '\0')
		return false;
	*out = (int64_t)v;
	return true;
}

static bool parse_int(const ss_ &s, int *out)
{
	int64_t v = 0;
	if(!parse_i64(s, &v))
		return false;
	if(v < (int64_t)INT_MIN || v > (int64_t)INT_MAX)
		return false;
	*out = (int)v;
	return true;
}

static bool parse_f64(const ss_ &s, double *out)
{
	if(s.empty())
		return false;
	errno = 0;
	char *end = nullptr;
	double v = strtod(s.c_str(), &end);
	if(errno || end == s.c_str() || *end != '\0' || v != v)
		return false;
	*out = v;
	return true;
}

static void split_cmd(const ss_ &line, ss_ *cmd, ss_ *rest)
{
	size_t i = 0;
	while(i < line.size() && (line[i] == ' ' || line[i] == '\t'))
		i++;
	size_t j = i;
	while(j < line.size() && line[j] != ' ' && line[j] != '\t')
		j++;
	*cmd = line.substr(i, j - i);
	size_t k = j;
	while(k < line.size() && (line[k] == ' ' || line[k] == '\t'))
		k++;
	*rest = line.substr(k);
}

static bool parse_button(const ss_ &s, int *sdl_button, ss_ *error)
{
	ss_ t;
	t.reserve(s.size());
	for(char c : s)
		t.push_back((char)tolower((unsigned char)c));
	if(t == "left" || t == "l" || t == "1" || t == "lmb"){
		*sdl_button = SDL_BUTTON_LEFT;
		return true;
	}
	if(t == "middle" || t == "m" || t == "2" || t == "mmb"){
		*sdl_button = SDL_BUTTON_MIDDLE;
		return true;
	}
	if(t == "right" || t == "r" || t == "3" || t == "rmb"){
		*sdl_button = SDL_BUTTON_RIGHT;
		return true;
	}
	if(t == "x1" || t == "4"){
		*sdl_button = SDL_BUTTON_X1;
		return true;
	}
	if(t == "x2" || t == "5"){
		*sdl_button = SDL_BUTTON_X2;
		return true;
	}
	*error = "Unknown mouse button \""+s+"\" (left, middle, right)";
	return false;
}

static bool parse_xy(const ss_ &rest, int *x, int *y, ss_ *error)
{
	c55::Strfnd f(rest);
	ss_ xs = trim_copy(f.next(" "));
	ss_ ys = trim_copy(f.next(""));
	if(xs.empty() || ys.empty() || !parse_int(xs, x) || !parse_int(ys, y)){
		*error = "Expected two integers";
		return false;
	}
	return true;
}

// "10 -20" -> yaw, pitch in degrees
static bool parse_angles(const ss_ &rest, double *yaw, double *pitch,
		ss_ *error)
{
	c55::Strfnd f(rest);
	ss_ a = trim_copy(f.next(" "));
	ss_ b = trim_copy(f.next(""));
	if(a.empty() || b.empty() || !parse_f64(a, yaw) || !parse_f64(b, pitch)){
		*error = "Expected two numbers";
		return false;
	}
	return true;
}

// "0 0 1" -> the same two angles: yaw from +Z towards +X, pitch upwards
static bool parse_direction(const ss_ &rest, double *yaw, double *pitch,
		ss_ *error)
{
	c55::Strfnd f(rest);
	ss_ xs = trim_copy(f.next(" "));
	ss_ ys = trim_copy(f.next(" "));
	ss_ zs = trim_copy(f.next(""));
	double x = 0, y = 0, z = 0;
	if(xs.empty() || ys.empty() || zs.empty() ||
			!parse_f64(xs, &x) || !parse_f64(ys, &y) || !parse_f64(zs, &z)){
		*error = "Expected three numbers";
		return false;
	}
	double len = sqrt(x * x + y * y + z * z);
	if(len < 1e-9){
		*error = "The direction has no length";
		return false;
	}
	// Not M_PI: Urho3D's MathDefs.h #undefs it, which with Emscripten's
	// headers leaves it undefined here ([WEB_CLIENT])
	const double deg = 180.0 / 3.14159265358979323846;
	*yaw = atan2(x, z) * deg;
	*pitch = asin(y / len) * deg;
	return true;
}

static bool parse_body(const ss_ &text, sv_<Command> *out, ss_ *error)
{
	out->clear();
	int line_no = 0;
	size_t i = 0;
	while(i <= text.size()){
		size_t nl = text.find('\n', i);
		ss_ line;
		if(nl == ss_::npos){
			line = text.substr(i);
			i = text.size() + 1;
		} else {
			line = text.substr(i, nl - i);
			i = nl + 1;
		}
		line_no++;
		if(!line.empty() && line.back() == '\r')
			line.pop_back();
		line = trim_copy(line);
		if(line.empty() || line[0] == '#')
			continue;

		ss_ cmd;
		ss_ rest;
		split_cmd(line, &cmd, &rest);

		auto fail = [&](const ss_ &msg){
			*error = "line "+itos(line_no)+": "+msg;
			out->clear();
			return false;
		};

		Command c;
		if(cmd == "delay"){
			c.type = Type::Delay;
			if(!parse_i64(rest, &c.n) || c.n < 0)
				return fail("delay <ms> (non-negative integer)");
		} else if(cmd == "wait_log"){
			c.type = Type::WaitLog;
			ss_ ms, text;
			split_cmd(rest, &ms, &text);
			if(!parse_i64(ms, &c.n) || c.n < 0 || text.empty())
				return fail("wait_log <ms> <text>");
			c.s = text;
		} else if(cmd == "wait_log_absent"){
			c.type = Type::WaitLogAbsent;
			ss_ ms, text;
			split_cmd(rest, &ms, &text);
			if(!parse_i64(ms, &c.n) || c.n < 0 || text.empty())
				return fail("wait_log_absent <ms> <text>");
			c.s = text;
		} else if(cmd == "expect_error"){
			c.type = Type::ExpectError;
			c.s = rest;
			if(c.s.empty())
				return fail("expect_error <text>");
		} else if(cmd == "wait_log_any"){
			c.type = Type::WaitLogAny;
			ss_ ms, text;
			split_cmd(rest, &ms, &text);
			if(!parse_i64(ms, &c.n) || c.n < 0 || text.empty())
				return fail("wait_log_any <ms> <text>");
			c.s = text;
		} else if(cmd == "screenshot"){
			c.type = Type::Screenshot;
			c.s = rest;
			if(c.s.empty())
				return fail("screenshot <path>");
		} else if(cmd == "event"){
			c.type = Type::Event;
			size_t sp = rest.find(' ');
			c.s = rest.substr(0, sp);
			c.param = sp == ss_::npos ? "" : rest.substr(sp + 1);
			if(c.s.empty())
				return fail("event <name> [param]");
		} else if(cmd == "keydown"){
			c.type = Type::KeyDown;
			c.s = rest;
			if(c.s.empty())
				return fail("keydown <key>");
		} else if(cmd == "keyup"){
			c.type = Type::KeyUp;
			c.s = rest;
			if(c.s.empty())
				return fail("keyup <key>");
		} else if(cmd == "keypress"){
			c.type = Type::KeyPress;
			c.s = rest;
			if(c.s.empty())
				return fail("keypress <key>");
		} else if(cmd == "mouse_pos"){
			c.type = Type::MousePos;
			if(!parse_xy(rest, &c.x, &c.y, error))
				return fail(*error);
		} else if(cmd == "mouse_move"){
			c.type = Type::MouseMove;
			if(!parse_xy(rest, &c.x, &c.y, error))
				return fail(*error);
		} else if(cmd == "mouse_down"){
			c.type = Type::MouseDown;
			if(!parse_button(rest, &c.x, error))
				return fail(*error);
		} else if(cmd == "mouse_up"){
			c.type = Type::MouseUp;
			if(!parse_button(rest, &c.x, error))
				return fail(*error);
		} else if(cmd == "mouse_click"){
			c.type = Type::MouseClick;
			if(!parse_button(rest, &c.x, error))
				return fail(*error);
		} else if(cmd == "click"){
			// simplified: the label has no escapes; a " cannot be in it
			c.type = Type::Click;
			size_t q0 = rest.find('"');
			size_t q1 = q0 == ss_::npos ? q0 : rest.find('"', q0 + 1);
			c.s = trim_copy(rest.substr(0, q0));
			if(q1 == ss_::npos || c.s.empty() || c.s.find(' ') != ss_::npos)
				return fail("click <type> \"<label>\" [x y]");
			c.param = rest.substr(q0 + 1, q1 - q0 - 1);
			ss_ hint = trim_copy(rest.substr(q1 + 1));
			if(!hint.empty()){
				if(!parse_xy(hint, &c.x, &c.y, error))
					return fail(*error);
				c.n = 1;
			}
		} else if(cmd == "tap"){
			c.type = Type::Tap;
			c.n = 1;
			if(!parse_xy(rest, &c.x, &c.y, error))
				return fail(*error);
		} else if(cmd == "finger_down" || cmd == "finger_move" ||
				cmd == "finger_up"){
			c.type = Type::Finger;
			c.param = cmd.substr(7);
			const size_t sp = rest.find(' ');
			const ss_ id = rest.substr(0, sp);
			if(!parse_i64(id, &c.n) || c.n < 1 || c.n > 9)
				return fail(cmd+" <id 1-9>"+(c.param == "up" ? "" : " <x> <y>"));
			if(c.param != "up" && (sp == ss_::npos ||
					!parse_xy(rest.substr(sp + 1), &c.x, &c.y, error)))
				return fail(cmd+" <id 1-9> <x> <y>");
		} else if(cmd == "mouse_wheel"){
			c.type = Type::MouseWheel;
			if(!parse_i64(rest, &c.n))
				return fail("mouse_wheel <delta>");
		} else if(cmd == "text"){
			c.type = Type::Text;
			c.s = rest;
			if(c.s.empty())
				return fail("text <string>");
		} else if(cmd == "look"){
			c.type = Type::Look;
			if(!parse_angles(rest, &c.yaw, &c.pitch, error))
				return fail(*error+"; look <yaw> <pitch>, in degrees");
		} else if(cmd == "look_dir"){
			c.type = Type::Look;
			if(!parse_direction(rest, &c.yaw, &c.pitch, error))
				return fail(*error+"; look_dir <x> <y> <z>");
		} else if(cmd == "quit"){
			c.type = Type::Quit;
			if(!rest.empty())
				return fail("quit takes no arguments");
		} else {
			return fail("unknown command \""+cmd+"\"");
		}
		out->push_back(c);
	}
	return true;
}

// Standard input, non-blocking, a line at a time. The buffer is static
// because the fd is: there is only one standard input.
void read_stdin_lines(sv_<ss_> *out_lines, bool *eof)
{
	static ss_ buf;
	static bool nonblock_set = false;
	static bool done = false;
	if(done){
		*eof = true;
		return;
	}
#ifdef _WIN32
	// simplified: no non-blocking stdin on Windows -- a pipe there cannot
	// be polled the way a Unix fd can; the stdin-driven run is a Linux
	// tool for now, and here stdin is simply never read
	(void)buf; (void)nonblock_set;
	done = true;
	*eof = true;
	return;
#else
	if(!nonblock_set){
		nonblock_set = true;
		int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
		if(flags == -1 || fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == -1)
			log_w(MODULE, "Could not put stdin in non-blocking mode: %s",
					strerror(errno));
	}
	for(;;){
		char tmp[4096];
		ssize_t n = read(STDIN_FILENO, tmp, sizeof tmp);
		if(n > 0){
			buf.append(tmp, (size_t)n);
			continue;
		}
		if(n == 0){
			done = true;
			break;
		}
		if(errno == EINTR)
			continue;
		if(errno != EAGAIN && errno != EWOULDBLOCK){
			log_w(MODULE, "Failed to read stdin: %s", strerror(errno));
			done = true;
		}
		break;
	}
	for(;;){
		size_t nl = buf.find('\n');
		if(nl == ss_::npos)
			break;
		out_lines->push_back(buf.substr(0, nl));
		buf = buf.substr(nl + 1);
	}
	// At end of input, what is left without a newline is still a command
	if(done && !buf.empty()){
		out_lines->push_back(buf);
		buf.clear();
	}
	*eof = done;
#endif
}

static void self_check()
{
	sv_<Command> cs;
	ss_ err;
	const char *sample =
			"# comment\n"
			"delay 100\n"
			"keydown W\n"
			"keyup W\n"
			"keypress Space\n"
			"mouse_pos 10 20\n"
			"mouse_move -1 2\n"
			"mouse_down left\n"
			"mouse_up left\n"
			"mouse_click right\n"
			"mouse_wheel 3\n"
			"text hello\n"
			"screenshot /tmp/x.png\n"
			"look 10 -20\n"
			"look_dir 1 0 0\n"
			"click Button \"No invites*\" 30 40\n"
			"quit\n";
	if(!parse_body(sample, &cs, &err))
		throw Exception(ss_()+"command_seq self_check parse: "+err);
	if(cs.size() != 16)
		throw Exception("command_seq self_check count "+itos(cs.size()));
	if(cs[0].type != Type::Delay || cs[0].n != 100)
		throw Exception("command_seq self_check delay");
	if(cs[5].type != Type::MouseMove || cs[5].x != -1 || cs[5].y != 2)
		throw Exception("command_seq self_check mouse_move");
	if(cs[6].x != SDL_BUTTON_LEFT || cs[8].x != SDL_BUTTON_RIGHT)
		throw Exception("command_seq self_check buttons");

	// The name is the date and the time, it carries no directory, and it
	// does not change between two calls in one second unless the file is
	// already there
	const ss_ name = screenshot_name("/nonexistent");
	if(name.size() != ss_("screenshot_20250713_130617.png").size() ||
			name.compare(0, 11, "screenshot_") != 0 ||
			name.compare(name.size() - 4, 4, ".png") != 0 ||
			name.find('/') != ss_::npos)
		throw Exception("command_seq self_check screenshot_name "+name);
	// A second can turn between the two calls (this runs at every parse; a
	// driven playtest aborted on it): then a third agrees with the second
	const ss_ again = screenshot_name("/nonexistent");
	if(again != name && screenshot_name("/nonexistent") != again)
		throw Exception("command_seq self_check screenshot_name twice");
	if(cs[12].type != Type::Look || cs[12].yaw != 10.0 || cs[12].pitch != -20.0)
		throw Exception("command_seq self_check look");
	// Straight along +X is a quarter turn from +Z, and level
	if(cs[13].type != Type::Look || fabs(cs[13].yaw - 90.0) > 1e-9 ||
			fabs(cs[13].pitch) > 1e-9)
		throw Exception("command_seq self_check look_dir");
	if(cs[14].type != Type::Click || cs[14].s != "Button" ||
			cs[14].param != "No invites*" || cs[14].n != 1 || cs[14].y != 40)
		throw Exception("command_seq self_check click");
	if(!parse_body("nope 1\n", &cs, &err) && err.find("unknown command") != ss_::npos)
		return;
	throw Exception("command_seq self_check unknown command");
}

bool parse(const ss_ &text, sv_<Command> *out, ss_ *error)
{
	self_check();
	return parse_body(text, out, error);
}

static ss_ button_name(int sdl_button)
{
	if(sdl_button == SDL_BUTTON_LEFT)
		return "left";
	if(sdl_button == SDL_BUTTON_MIDDLE)
		return "middle";
	if(sdl_button == SDL_BUTTON_RIGHT)
		return "right";
	if(sdl_button == SDL_BUTTON_X1)
		return "x1";
	if(sdl_button == SDL_BUTTON_X2)
		return "x2";
	return itos(sdl_button);
}

ss_ dump_command(const Command &c)
{
	switch(c.type){
	case Type::Delay:
		return "delay "+itos(c.n);
	case Type::WaitLog:
		return "wait_log "+itos(c.n)+" "+c.s;
	case Type::WaitLogAny:
		return "wait_log_any "+itos(c.n)+" "+c.s;
	case Type::WaitLogAbsent:
		return "wait_log_absent "+itos(c.n)+" "+c.s;
	case Type::ExpectError:
		return "expect_error "+c.s;
	case Type::Screenshot:
		return "screenshot "+c.s;
	case Type::Event:
		return "event "+c.s+(c.param.empty() ? "" : " "+c.param);
	case Type::KeyDown:
		return "keydown "+c.s;
	case Type::KeyUp:
		return "keyup "+c.s;
	case Type::KeyPress:
		return "keypress "+c.s;
	case Type::Click:
		return "click "+c.s+" \""+c.param+"\""+
				(c.n ? " "+itos(c.x)+" "+itos(c.y) : "");
	case Type::MousePos:
		return "mouse_pos "+itos(c.x)+" "+itos(c.y);
	case Type::MouseMove:
		return "mouse_move "+itos(c.x)+" "+itos(c.y);
	case Type::MouseDown:
		return "mouse_down "+button_name(c.x);
	case Type::MouseUp:
		return "mouse_up "+button_name(c.x);
	case Type::MouseClick:
		return "mouse_click "+button_name(c.x);
	case Type::MouseWheel:
		return "mouse_wheel "+itos(c.n);
	case Type::Tap:
		return "tap "+itos(c.x)+" "+itos(c.y);
	case Type::Finger:
		return "finger_"+c.param+" "+itos(c.n)+(c.param == "up" ? ss_() :
				" "+itos(c.x)+" "+itos(c.y));
	case Type::Text:
		return "text "+c.s;
	case Type::Quit:
		return "quit";
	case Type::Look:
		{
			char buf[64];
			snprintf(buf, sizeof buf, "look %g %g", c.yaw, c.pitch);
			return buf;
		}
	}
	return "?";
}

static const char *key_alias(const ss_ &name)
{
	ss_ t;
	t.reserve(name.size());
	for(char c : name)
		t.push_back((char)tolower((unsigned char)c));
	if(t == "enter")
		return "Return";
	if(t == "esc")
		return "Escape";
	if(t == "ctrl")
		return "Left Ctrl";
	if(t == "shift")
		return "Left Shift";
	if(t == "alt")
		return "Left Alt";
	if(t == "super" || t == "gui" || t == "win")
		return "Left GUI";
	return nullptr;
}

static int key_from_name(magic::Input *input, const ss_ &name)
{
	int key = input->GetKeyFromName(name.c_str());
	if(key != 0)
		return key;
	const char *alias = key_alias(name);
	if(alias)
		key = input->GetKeyFromName(alias);
	return key;
}

static Uint32 window_id(magic::Input *input)
{
	magic::Graphics *g = input->GetSubsystem<magic::Graphics>();
	SDL_Window *w = g ? g->GetWindow() : nullptr;
	return w ? SDL_GetWindowID(w) : 0;
}

// Marks the mouse events this file pushes, so that the event filter can tell
// them apart from whatever the real mouse is doing. Urho3D does not read the
// "which" field of mouse events, so it is free for this.
static const Uint32 INJECTED_MOUSE_ID = 0x42554944; // "BUID"

static SDL_EventFilter g_prev_filter = nullptr;
static void *g_prev_filter_userdata = nullptr;
static bool g_input_inhibited = false;
// SDL_PushEvent runs the event filter in the pushing thread, before it returns,
// so a flag held across a push is enough to tell our own events apart from
// whatever the real keyboard is doing. Keyboard events have no free field to
// mark the way mouse events do.
static bool g_injecting_keys = false;

// Left through even while a sequence runs: escape, so that a run can be
// abandoned, and alt+tab, so that the window can be left if it grabbed the
// real mouse.
static bool always_allowed_key(SDL_Keycode sym)
{
	return sym == SDLK_ESCAPE || sym == SDLK_TAB ||
			sym == SDLK_LALT || sym == SDLK_RALT;
}

static int SDLCALL input_inhibit_filter(void *userdata, SDL_Event *e)
{
	Uint32 which = 0;
	switch(e->type){
	case SDL_KEYDOWN:
	case SDL_KEYUP:
		if(!g_injecting_keys && !always_allowed_key(e->key.keysym.sym))
			return 0; // The real keyboard; the sequence owns input
		if(g_prev_filter)
			return g_prev_filter(g_prev_filter_userdata, e);
		return 1;
	case SDL_TEXTINPUT:
	case SDL_TEXTEDITING:
		if(!g_injecting_keys)
			return 0;
		if(g_prev_filter)
			return g_prev_filter(g_prev_filter_userdata, e);
		return 1;
	case SDL_MOUSEMOTION: which = e->motion.which; break;
	case SDL_MOUSEBUTTONDOWN:
	case SDL_MOUSEBUTTONUP: which = e->button.which; break;
	case SDL_MOUSEWHEEL: which = e->wheel.which; break;
	default:
		// Not an input event; leave it to whoever was filtering before us
		if(g_prev_filter)
			return g_prev_filter(g_prev_filter_userdata, e);
		return 1;
	}
	if(which != INJECTED_MOUSE_ID)
		return 0; // A real mouse moved or clicked; the sequence owns input
	if(g_prev_filter)
		return g_prev_filter(g_prev_filter_userdata, e);
	return 1;
}

// The window is not grabbed during a sequence, so the physical mouse sits on
// the same display and its motion would otherwise land in GetMouseMove along
// with the injected motion, which makes a run unreproducible. The keyboard is
// worse than that: the window raises itself, so typing meant for another
// window lands in the client and perturbs the run in both places.
void inhibit_real_input(bool enable)
{
	if(enable == g_input_inhibited)
		return;
	if(enable){
		SDL_GetEventFilter(&g_prev_filter, &g_prev_filter_userdata);
		SDL_SetEventFilter(input_inhibit_filter, nullptr);
	} else {
		SDL_SetEventFilter(g_prev_filter, g_prev_filter_userdata);
		g_prev_filter = nullptr;
		g_prev_filter_userdata = nullptr;
	}
	g_input_inhibited = enable;
}

// Urho3D calls SuppressNextMouseMove() whenever mouse visibility, mode or
// grab actually changes, which makes it drop the next mouse motion it sees --
// including an injected one, so a mouse_move issued after the game toggled the
// mouse would silently do nothing. Feed it one pixel of motion to swallow
// instead. It is dropped by definition, so it moves nothing.
// The motion asked for, waiting for the top of the next frame
static magic::IntVector2 g_pending_mouse_move(0, 0);

void apply_pending_mouse_move(magic::Input *input)
{
	if(g_pending_mouse_move == magic::IntVector2::ZERO)
		return;
	input->AddMouseMove(g_pending_mouse_move.x_, g_pending_mouse_move.y_);
	g_pending_mouse_move = magic::IntVector2::ZERO;
}

void absorb_mouse_move_suppression(magic::Input *input)
{
	SDL_Event e;
	memset(&e, 0, sizeof(e));
	e.type = SDL_MOUSEMOTION;
	e.motion.windowID = window_id(input);
	e.motion.which = INJECTED_MOUSE_ID;
	e.motion.xrel = 1;
	e.motion.yrel = 0;
	SDL_PushEvent(&e);
}

// The window has to be mapped for the GL context to render what a screenshot
// reads, but it is deliberately not raised and not given input focus: a
// sequence can then run beside whatever the user is doing without the window
// jumping in front of it at every injected key. Urho3D drops key and mouse
// events while it has no focus, so the sequence forces the focus flag
// instead; see Input::SetForceInputFocus.
void show_window(magic::Graphics *graphics, magic::Input *input)
{
	// **A driven window does not take the desk's focus** (user,
	// 2026-09-24: a check "popping up the window open and closed and
	// open repeatedly, taking my input focus away from what I'm
	// doing"). The vendored SDL reads this hint when it maps a window
	// and, with it set, says _NET_WM_USER_TIME = 0 first -- EWMH for
	// "the user did not ask for this window" -- and maps without
	// raising. A client somebody started themselves is unaffected:
	// this is only ever set for a command sequence.
	SDL_SetHint("BUILDAT_WINDOW_NO_ACTIVATION", "1");
	if(graphics){
		SDL_Window *w = graphics->GetWindow();
		if(w)
			SDL_ShowWindow(w);
	}
	if(input)
		input->SetForceInputFocus(true);
}

void release_forced_focus(magic::Input *input)
{
	if(input)
		input->SetForceInputFocus(false);
}

static bool push_key(magic::Input *input, int key, bool down, ss_ *error)
{
	SDL_Event e;
	memset(&e, 0, sizeof(e));
	e.type = down ? SDL_KEYDOWN : SDL_KEYUP;
	e.key.state = down ? SDL_PRESSED : SDL_RELEASED;
	e.key.repeat = 0;
	e.key.windowID = window_id(input);
	e.key.keysym.sym = key;
	e.key.keysym.scancode = SDL_GetScancodeFromKey((SDL_Keycode)key);
	g_injecting_keys = true;
	int r = SDL_PushEvent(&e);
	g_injecting_keys = false;
	if(r != 1){
		*error = "SDL_PushEvent failed";
		return false;
	}
	return true;
}

// The keys a sequence holds (keydown without its keyup), so that a key
// Urho's input has dropped can be pressed again: Input::ResetState()
// clears every key on a focus change, and a scripted run's held key
// read as not held one run in ten with nothing downstream to say why
// ([HELD_KEY_FLAKE]). reassert_held_keys() runs every frame.
// A key is only pressed again once Urho has read it as down: the event
// a keydown pushes is read on the next frame, and a second KeyDown before
// that would be a second press (a toggle key toggled back).
static std::map<int, bool> g_held_keys; // key -> seen down

// The buttons a sequence holds, the same way g_held_keys holds its keys
// and for the same reason: Input::ResetState() clears the mouse buttons
// as well as the keys, and a hold that spans a focus change comes back
// with the button up. A hold on a sphere in the launcher room is a
// second and a half of held button, and it read as no button at all in
// a container (2026-09-24). Urho's mask is 1 << (SDL button - 1).
static std::map<int, bool> g_held_buttons; // sdl button -> seen down

static bool push_mouse_button(magic::Input *input, int sdl_button,
		bool down, ss_ *error);

bool inject_key(magic::Input *input, const ss_ &name, bool down, bool up_too,
		ss_ *error)
{
	int key = key_from_name(input, name);
	if(key == 0){
		*error = "Unknown key \""+name+"\"";
		return false;
	}
	if(!push_key(input, key, down, error))
		return false;
	if(up_too && !push_key(input, key, false, error))
		return false;
	if(down && !up_too)
		g_held_keys[key] = false;
	else
		g_held_keys.erase(key);
	return true;
}

void reassert_held_keys(magic::Input *input)
{
	for(auto &held : g_held_keys){
		int key = held.first;
		if(input->GetKeyDown(key)){
			held.second = true;
			continue;
		}
		if(!held.second)
			continue;
		ss_ error;
		if(push_key(input, key, true, &error)){
			held.second = false;
			log_w(MODULE, "held key %s read as not held; pressed again",
					cs(ss_(SDL_GetKeyName((SDL_Keycode)key))));
		}
	}
	for(auto &held : g_held_buttons){
		int button = held.first;
		if(input->GetMouseButtonDown(1 << (button - 1))){
			held.second = true;
			continue;
		}
		if(!held.second)
			continue;
		ss_ error;
		if(push_mouse_button(input, button, true, &error)){
			held.second = false;
			log_w(MODULE, "held mouse button %i read as not held; "
					"pressed again", button);
		}
	}
}

bool button_held_unseen(int sdl_button)
{
	auto it = g_held_buttons.find(sdl_button);
	return it != g_held_buttons.end() && !it->second;
}

void release_held_keys()
{
	g_held_keys.clear();
	g_held_buttons.clear();
}

static bool push_mouse_button(magic::Input *input, int sdl_button, bool down,
		ss_ *error)
{
	magic::IntVector2 p = input->GetMousePosition();
	SDL_Event e;
	memset(&e, 0, sizeof(e));
	e.type = down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
	e.button.windowID = window_id(input);
	e.button.button = (Uint8)sdl_button;
	e.button.state = down ? SDL_PRESSED : SDL_RELEASED;
	e.button.clicks = 1;
	e.button.which = INJECTED_MOUSE_ID;
	e.button.x = p.x_;
	e.button.y = p.y_;
	if(SDL_PushEvent(&e) != 1){
		*error = "SDL_PushEvent failed";
		return false;
	}
	return true;
}

bool inject_mouse_button(magic::Input *input, int sdl_button, bool down,
		bool up_too, ss_ *error)
{
	if(!push_mouse_button(input, sdl_button, down, error))
		return false;
	if(up_too && !push_mouse_button(input, sdl_button, false, error))
		return false;
	if(down && !up_too)
		g_held_buttons[sdl_button] = false;
	else
		g_held_buttons.erase(sdl_button);
	return true;
}

bool inject_mouse_pos(magic::Input *input, int x, int y, ss_ *error)
{
	magic::IntVector2 old = input->GetMousePosition();
	// The scripted client's mouse is not the desk's ([SEQ_MOUSE_FREE]):
	// a virtual position the UI reads for its clicks and hover, so the
	// real cursor stays wherever the user left it. Set from the first
	// mouse_pos on; the real mouse's own events are dropped by the
	// filter below either way.
	input->SetVirtualMousePosition(magic::IntVector2(x, y));
	SDL_Event e;
	memset(&e, 0, sizeof(e));
	e.type = SDL_MOUSEMOTION;
	e.motion.windowID = window_id(input);
	e.motion.which = INJECTED_MOUSE_ID;
	e.motion.x = x;
	e.motion.y = y;
	e.motion.xrel = x - old.x_;
	e.motion.yrel = y - old.y_;
	if(SDL_PushEvent(&e) != 1){
		*error = "SDL_PushEvent failed";
		return false;
	}
	return true;
}

bool inject_mouse_move(magic::Input *input, int dx, int dy, ss_ *error)
{
	// **Into the accumulator, and not through the SDL queue at all.**
	// mouse_move is for the look, which reads GetMouseMove(), and the
	// queue served it badly: the first motion of a run vanished between
	// the push and Urho3D -- it never reached HandleSDLEvent, never
	// accumulated and was dropped by no suppression -- so every sequence
	// lost its first mouse_move and a scripted look began one command
	// late (2026-09-23). Pushing it as well as adding it counted it
	// twice on the frames where it did arrive. mouse_pos is what a UI
	// wants, and it still goes through the queue.
	//
	// Relative only. No warp: captured look has no persistent cursor
	// position.
	// Held for the top of the next frame: Urho3D clears the accumulator
	// at the start of every frame, so a delta added while commands are
	// being stepped is seen by a handler only if that handler happens to
	// run later in the same frame -- and whether it does is subscription
	// order. Applied a frame later it is seen by all of them, always.
	g_pending_mouse_move += magic::IntVector2(dx, dy);
	(void)input;
	(void)error;
	return true;
}

bool inject_mouse_wheel(magic::Input *input, int delta, ss_ *error)
{
	SDL_Event e;
	memset(&e, 0, sizeof(e));
	e.type = SDL_MOUSEWHEEL;
	e.wheel.windowID = window_id(input);
	e.wheel.which = INJECTED_MOUSE_ID;
	e.wheel.y = delta;
	if(SDL_PushEvent(&e) != 1){
		*error = "SDL_PushEvent failed";
		return false;
	}
	return true;
}

// A touchscreen's fingers ([TOUCH_CHAT_CLUTTER], [HEARTH_USABILITY]),
// which Urho3D makes TouchBegin, TouchMove and TouchEnd; a tap is the down
// and the up in one push. SDL's fingers are in fractions of the window;
// an up is where the finger last was.
static std::map<int, std::pair<float, float>> g_fingers;
bool inject_finger(magic::Input *input, const ss_ &phase, int id, int x,
		int y, ss_ *error)
{
	magic::Graphics *g = input->GetSubsystem<magic::Graphics>();
	if(!g || g->GetWidth() <= 0 || g->GetHeight() <= 0){
		*error = "finger: no window";
		return false;
	}
	sv_<Uint32> types;
	if(phase == "tap")
		types = {SDL_FINGERDOWN, SDL_FINGERUP};
	else if(phase == "down")
		types = {SDL_FINGERDOWN};
	else if(phase == "move" || phase == "up"){
		if(!g_fingers.count(id)){
			*error = "finger "+itos(id)+" is not down";
			return false;
		}
		types = {phase == "move" ? (Uint32)SDL_FINGERMOTION : (Uint32)SDL_FINGERUP};
	}
	float fx = (float)x / g->GetWidth(), fy = (float)y / g->GetHeight();
	if(phase == "up"){
		fx = g_fingers[id].first;
		fy = g_fingers[id].second;
	}
	for(Uint32 type : types){
		SDL_Event e;
		memset(&e, 0, sizeof(e));
		e.type = type;
		e.tfinger.touchId = 1;
		e.tfinger.fingerId = id;
		e.tfinger.x = fx;
		e.tfinger.y = fy;
		if(type == SDL_FINGERMOTION && g_fingers.count(id)){
			e.tfinger.dx = fx - g_fingers[id].first;
			e.tfinger.dy = fy - g_fingers[id].second;
		}
		e.tfinger.pressure = 1.f;
		if(SDL_PushEvent(&e) != 1){
			*error = "SDL_PushEvent failed";
			return false;
		}
		if(type == SDL_FINGERUP)
			g_fingers.erase(id);
		else
			g_fingers[id] = {fx, fy};
	}
	return true;
}

bool inject_text(magic::Input *input, const ss_ &text, ss_ *error)
{
	size_t i = 0;
	while(i < text.size()){
		SDL_Event e;
		memset(&e, 0, sizeof(e));
		e.type = SDL_TEXTINPUT;
		e.text.windowID = window_id(input);
		size_t n = text.size() - i;
		if(n > sizeof(e.text.text) - 1)
			n = sizeof(e.text.text) - 1;
		memcpy(e.text.text, text.c_str() + i, n);
		e.text.text[n] = 0;
		g_injecting_keys = true;
		int r = SDL_PushEvent(&e);
		g_injecting_keys = false;
		if(r != 1){
			*error = "SDL_PushEvent failed";
			return false;
		}
		i += n;
	}
	return true;
}

static std::mutex g_screenshot_mutex;
// The shots handed to a writer thread and not on disk yet: a script
// taking one a frame was given the name of the one still being written,
// and half its shots were overwritten
static std::set<ss_> g_screenshots_writing;

static bool taken(const ss_ &path)
{
	std::lock_guard<std::mutex> lock(g_screenshot_mutex);
	return interface::fs::path_exists(path) ||
			g_screenshots_writing.count(interface::fs::get_absolute_path(path));
}

ss_ screenshot_name(const ss_ &dir)
{
	char stamp[32] = {};
	const time_t t = time(nullptr);
	struct tm tmv;
#ifdef _WIN32
	localtime_s(&tmv, &t);
#else
	localtime_r(&t, &tmv);
#endif
	strftime(stamp, sizeof stamp, "%Y%m%d_%H%M%S", &tmv);
	const ss_ base = ss_("screenshot_")+stamp;
	ss_ name = base+".png";
	// A second is plenty of resolution for somebody pressing a key and not
	// enough for a script taking a set, and the collision would be silent:
	// the second shot overwrites the first, and the caller is handed a name
	// that no longer means what it did when it was given out.
	for(int i = 2; i < 1000 && taken(dir+"/"+name); i++)
		name = base+"_"+itos(i)+".png";
	return name;
}
// Joined at exit as well as by finish_screenshots(): a std::thread still
// joinable when its vector is destroyed calls terminate, which is what
// the client did on quit three seconds after its last shot (the campaign
// rerun's seed 1, 2026-09-19)
static struct ScreenshotThreads {
	sv_<std::thread> v;
	~ScreenshotThreads(){
		for(std::thread &t : v)
			if(t.joinable())
				t.join();
	}
} g_screenshot_threads;

void finish_screenshots()
{
	// Joined outside the lock: a thread takes it to say it is done
	sv_<std::thread> v;
	{
		std::lock_guard<std::mutex> lock(g_screenshot_mutex);
		v.swap(g_screenshot_threads.v);
	}
	for(std::thread &t : v)
		if(t.joinable())
			t.join();
}

bool save_screenshot(magic::Graphics *graphics, const ss_ &path, ss_ *error,
		int logical_w, int logical_h, int ox, int oy, float s)
{
	if(!graphics){
		*error = "Graphics not available";
		return false;
	}
	magic::Image img(graphics->GetContext());
	if(!graphics->TakeScreenShot(img)){
		*error = "TakeScreenShot failed";
		return false;
	}
	// The logical frame out of the window: cropped to the letterbox and
	// resampled to the logical size (bilinear), so a picture is the scan's
	// pixels whatever the window is
	if(logical_w > 0 && logical_h > 0 &&
			(img.GetWidth() != logical_w || img.GetHeight() != logical_h ||
			ox != 0 || oy != 0)){
		const int c = (int)img.GetComponents();
		const int sw = img.GetWidth(), sh = img.GetHeight();
		const unsigned char *src = img.GetData();
		sv_<unsigned char> out((size_t)logical_w * logical_h * c);
		for(int y = 0; y < logical_h; y++){
			float fy = oy + (y + 0.5f) * s - 0.5f;
			int y0 = (int)fy; if(y0 < 0) y0 = 0; if(y0 > sh - 1) y0 = sh - 1;
			int y1 = y0 + 1 < sh ? y0 + 1 : y0;
			float ty = fy - y0; if(ty < 0) ty = 0; if(ty > 1) ty = 1;
			for(int x = 0; x < logical_w; x++){
				float fx = ox + (x + 0.5f) * s - 0.5f;
				int x0 = (int)fx; if(x0 < 0) x0 = 0; if(x0 > sw - 1) x0 = sw - 1;
				int x1 = x0 + 1 < sw ? x0 + 1 : x0;
				float tx = fx - x0; if(tx < 0) tx = 0; if(tx > 1) tx = 1;
				for(int k = 0; k < c; k++){
					float a = src[((size_t)y0 * sw + x0) * c + k] * (1 - tx) +
							src[((size_t)y0 * sw + x1) * c + k] * tx;
					float b = src[((size_t)y1 * sw + x0) * c + k] * (1 - tx) +
							src[((size_t)y1 * sw + x1) * c + k] * tx;
					out[((size_t)y * logical_w + x) * c + k] =
							(unsigned char)(a * (1 - ty) + b * ty + 0.5f);
				}
			}
		}
		img.SetSize(logical_w, logical_h, c);
		img.SetData(out.data());
	}
	ss_ abs = interface::fs::get_absolute_path(path);
	ss_ parent = interface::fs::strip_file_name(abs);
	if(!parent.empty() && !interface::fs::create_directories(parent)){
		*error = "Failed to create directory \""+parent+"\"";
		return false;
	}
	magic::FileSystem *fs = graphics->GetSubsystem<magic::FileSystem>();
	if(fs && !parent.empty())
		fs->RegisterPath(parent.c_str());
	const int w = img.GetWidth(), h = img.GetHeight(),
			c = (int)img.GetComponents();
	sv_<unsigned char> pixels(img.GetData(),
			img.GetData() + (size_t)w * h * c);
	{
		std::lock_guard<std::mutex> lock(g_screenshot_mutex);
		g_screenshots_writing.insert(abs);
		g_screenshot_threads.v.emplace_back([abs, w, h, c, pixels](){
			if(stbi_write_png(abs.c_str(), w, h, c, pixels.data(), w * c))
				log_i(MODULE, "Wrote screenshot %s", cs(abs));
			else
				log_w(MODULE, "Failed to write \"%s\"", cs(abs));
			std::lock_guard<std::mutex> lock(g_screenshot_mutex);
			g_screenshots_writing.erase(abs);
		});
	}
	return true;
}

}
}
// vim: set noet ts=4 sw=4:
