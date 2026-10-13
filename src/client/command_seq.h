// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace Urho3D {
	class Graphics;
	class Input;
}

namespace client
{
namespace command_seq
{
	enum class Type
	{
		Delay,
		Screenshot,
		KeyDown,
		KeyUp,
		KeyPress,
		MousePos,
		MouseMove,
		MouseDown,
		MouseUp,
		MouseClick,
		MouseWheel,
		// tap <x> <y>: a finger down and up there, window pixels
		Tap,
		// finger_down <id> <x> <y>, finger_move <id> <x> <y>, finger_up
		// <id>: one finger of several, for drags, holds and two-finger
		// gestures (param "down", "move" or "up"; n the id)
		Finger,
		Text,
		Quit,
		Look,
		// event <name> <param>: the Urho3D event command_seq:<name> sent
		// on the client with the rest of the line as its Param, for any
		// client Lua to handle ([CMD_EVENT])
		Event,
		// wait_log <ms> <text>: the sequence held until the client's own
		// log has a line containing the text -- a wait for a screen or a
		// moment instead of a guessed delay ([START_WAIT]). Not seen in
		// the time, the sequence fails ([CHECKS_EVENT_WAITS])
		WaitLog,
		// wait_log_absent <ms> <text>: the time passes with no such line,
		// or the sequence fails -- a thing that must not happen
		WaitLogAbsent,
		// expect_error <text>: the next error line containing the text is
		// the drive's own doing and does not fail the sequence; any other
		// error line, or the connection dropping, does at once
		ExpectError,
		// **Whether the line has appeared at all in this run**, where
		// WaitLog waits for the next one after it starts. A launch UI
		// that says it is ready while the sequence is still being read
		// says it once, and a wait that only sees what comes after it
		// then sits out its whole timeout ([LAUNCH_WORLD], 2026-09-24:
		// the room's "hums" came twenty milliseconds early and every
		// drive ran ninety seconds late).
		WaitLogAny,
		// click <type> "<label>" [x y]: a left click at the centre of the
		// visible, uncovered UI element of that type whose label matches
		// (a trailing * is a prefix), the nearest the hint ([SEQ_CLICK]).
		// s is the type, param the label, n 1 with a hint in x, y.
		Click,
	};

	struct Command
	{
		Type type;
		int64_t n = 0;
		int x = 0;
		int y = 0;
		ss_ s;
		// Look only: where the camera is to point, in degrees. yaw is
		// measured from +Z towards +X and pitch is positive upwards, which
		// is what a direction vector (x, y, z) comes out as.
		double yaw = 0.0;
		double pitch = 0.0;
		// Event only: the rest of the line after the name
		ss_ param;
	};

	// One command per line. Empty lines and '#' comments are ignored.
	bool parse(const ss_ &text, sv_<Command> *out, ss_ *error);

	// Whatever whole lines standard input has for us, without waiting for
	// them: the client goes on rendering and stays connected while the other
	// end decides what to ask for next. A partial line is kept until the rest
	// arrives. Sets *eof once there will be no more.
	void read_stdin_lines(sv_<ss_> *out_lines, bool *eof);

	ss_ dump_command(const Command &c);

	// Drop real mouse and keyboard events while a sequence runs, so that
	// neither can perturb it and so that typing aimed at another window is
	// not swallowed by the client raising itself. Injected events still get
	// through, as do escape and alt+tab.
	void inhibit_real_input(bool enable);

	// Feed Urho3D the one mouse motion it drops after a mouse state change,
	// so that the next injected mouse_move is not the one that gets eaten.
	void absorb_mouse_move_suppression(Urho3D::Input *input);
	// The motion a mouse_move asked for, applied at the top of a frame
	// so that every handler in it sees the same thing
	void apply_pending_mouse_move(Urho3D::Input *input);

	// Map the window without raising it or taking input focus, and make
	// Urho3D accept injected input while the window has none.
	void show_window(Urho3D::Graphics *graphics, Urho3D::Input *input);
	void release_forced_focus(Urho3D::Input *input);
	// A held key Urho's input dropped is pressed again; once a frame
	// while a sequence runs ([HELD_KEY_FLAKE])
	void reassert_held_keys(Urho3D::Input *input);
	void release_held_keys();
	// True while a mouse_down has been pushed and no frame has read
	// the button as down yet: a mouse_up that goes out before that
	// frame is a hold nothing ever saw ([SEQ_HOLD_FRAME])
	bool button_held_unseen(int sdl_button);
	bool inject_key(Urho3D::Input *input, const ss_ &name, bool down,
			bool up_too, ss_ *error);
	bool inject_mouse_button(Urho3D::Input *input, int sdl_button, bool down,
			bool up_too, ss_ *error);
	bool inject_mouse_pos(Urho3D::Input *input, int x, int y, ss_ *error);
	bool inject_mouse_move(Urho3D::Input *input, int dx, int dy, ss_ *error);
	bool inject_mouse_wheel(Urho3D::Input *input, int delta, ss_ *error);
	// phase "down", "move", "up" (at the finger's last place) or "tap"
	// (down and up)
	bool inject_finger(Urho3D::Input *input, const ss_ &phase, int id, int x,
			int y, ss_ *error);
	bool inject_text(Urho3D::Input *input, const ss_ &text, ss_ *error);
	// Waits for every screenshot still being written; before the process
	// ends, so a run's last picture is whole
	void finish_screenshots();

	// With a logical size, the picture is that size: the letterboxed
	// frame at (ox, oy) scaled by s in the window, resampled back
	// ([SEQ_FIXED_SIZE])
	bool save_screenshot(Urho3D::Graphics *graphics, const ss_ &path,
			ss_ *error, int logical_w = 0, int logical_h = 0,
			int ox = 0, int oy = 0, float s = 1.f);
	// What to call the next screenshot in a directory: the date and the
	// time, screenshot_20250713_130617.png, with a numbered suffix when one
	// second holds two of them. The caller is given the name back and has
	// to be able to tell one shot from the next.
	ss_ screenshot_name(const ss_ &dir);
}
}
// vim: set noet ts=4 sw=4:
