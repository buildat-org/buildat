// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	// [KIT] A .wasm a module runs for itself (Server::create_wasm_box()):
	// a directory of the module's C, built as a server .wasm is
	// (wasm_build.cpp, against wasm_server_api.h) and run in the server's
	// wasm sandbox and meter (src/wasm/engine.cpp) on the caller's thread.
	// It imports log and time_ms, and call_input/call_output, which read
	// `input` and append to `output`; nothing else, so it reaches nothing
	// but those bytes. Builtin/kit's Lua box is one.
	struct WasmBox
	{
		ss_ input, output;

		virtual ~WasmBox(){}
		// An export taking nothing, called: "" or its trap, and its i32
		// result
		virtual ss_ call(const ss_ &export_name, uint32_t *result) = 0;
		// The engine's whole budget for a call (its units differ between
		// the interpreter and the compiled module), and a smaller one for
		// the calls from now on (0: the whole)
		virtual int64_t budget() = 0;
		virtual void set_call_budget(int64_t units) = 0;
		// What the last call left of its budget; below 0 it ran past it
		virtual int64_t meter_left() = 0;
		// Between calls: the move to the compiled module when it is done
		virtual void poll() = 0;
		// "compiled", "interpreter, compiling", ...
		virtual ss_ engine_name() = 0;
	};
}
// vim: set noet ts=4 sw=4:
