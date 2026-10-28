// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [CLIENT_WASM] [SERVER_WASM] The runtime a .wasm runs in, the client's and
// the server's: read, validated and capped, metered, then natively run by
// WAMR's interpreter while wasm2c's translation of it compiles, and moved
// to the compiled module between two calls; on the web the browser's own
// WebAssembly. What a module may import is the process's ImportSet (the
// client's wasm_api.h and bindings, or the server's wasm_server_api.h);
// what an import does is the owner's (Engine::import_body()).
// engine.cpp says how each part keeps a module away from the process.
#pragma once
#include "core/types.h"
#include <atomic>
#include <chrono>
#include <functional>

namespace wasm_engine
{
	// The caps, the same on every engine ([CLIENT_WASM] security). The
	// server links with --max-memory at MAX_PAGES' size, so a module it
	// built passes.
	static const size_t MAX_BYTES = 8 << 20;
	static const size_t MAX_FUNCS = 50000;
	static const uint64_t MAX_PAGES = 1024; // 64 MiB
	static const uint64_t MAX_TABLE = 100000;
	static const size_t MAX_EXPORTS = 1000;
	static const size_t MAX_PARAMS = 16;
	// Live modules in a process (the compiled ones' memories are known to
	// the fault handler by a table of this size)
	static const size_t MAX_INSTANCES = 32;
	static const size_t MAX_LOG = 1000;
	static const size_t MAX_LOG_LINES = 100; // in one call, then one "suppressed"
	// An import's numbers at most
	static const int MAX_IMPORT_PARAMS = 8;
	// A call's budget, in meter units (about an instruction each): of the
	// order of a second of a tight loop on either engine
	static const int64_t BUDGET = 4000000000;
	// An import's charge, as a guess at its time in the same units: this
	// for any, and its work on top (import_cost)
	static const uint64_t IMPORT_COST = 200;

	// What a module may import, all from "buildat", all i32: its name as
	// imported, the name it is renamed to before translation (so that no
	// name of the module's reaches the C or the interpreter; the same name
	// for the engine's own), its parameters and whether it returns one
	struct ImportDef {
		ss_ name, c_name;
		int params = 0;
		bool result = false;
	};
	struct ImportSet {
		sv_<ImportDef> defs;
		// What a refused import is said not to be, e.g. "wasm_api.h's"
		ss_ what;
		// defs.size() for none
		size_t find(const ss_ &name) const;
	};
	// The process's, once, before any module (the client's or the server's)
	void set_imports(const ImportSet &set);
	const ImportSet& imports();

	struct ExportSig {
		ss_ name;
		ss_ params; // 'i' i32, 'I' i64, 'f' f32, 'F' f64
		char result = 0; // one of those, or 0 for none
	};

	// The bytes a module logged, as one line of printable ASCII (at most
	// MAX_LOG of them)
	ss_ printable(const uint8_t *p, size_t n);

	// The live modules in this process
	size_t instance_count();

	struct Engine
	{
		ss_ name; // the module's, for the log
		sv_<ExportSig> exports; // by index, in call()'s numbering
		enum State { LOADING, READY, FAILED };
		std::atomic<int> state{LOADING};
		ss_ error;
		// A call into the module is running: none other starts. Read from
		// other threads on the server (a call between modules), so atomic
		std::atomic<bool> in_call{false};
		// An import refused what the module asked: the call traps with this
		ss_ trap_reason;
		// What the import under way has cost (run_import())
		uint64_t import_cost = 0;
		// Log lines in this call (log_line())
		size_t logged = 0;
		std::chrono::steady_clock::time_point loaded =
				std::chrono::steady_clock::now();

		// Set before prepare():
		// - why the module may not import this import (its index in
		//   imports()), "" if it may; all may when unset (the client)
		std::function<ss_(size_t which)> refuse_import;
		// - natively, where its compiled module is cached (a directory
		//   only this user can write is made there)
		ss_ cache_root;

		Engine();
		virtual ~Engine();
		Engine(const Engine&) = delete;
		Engine& operator=(const Engine&) = delete;

		// The bytes read, validated, capped and metered: false with why,
		// the module refused and nothing of it run
		bool prepare(const ss_ &bytes, ss_ &why);
		// Run: natively the interpreter, the compile or the cached compiled
		// module, on the web the browser's instance; its start function
		// run. state says how it went (LOADING while it compiles, with no
		// interpreter to run it meanwhile).
		void start();
		// Natively, the compile's progress, read without waiting; between
		// calls only
		void poll();
		// Export `index` called with args (bits: i32 and f32 in the low 32,
		// i64 and f64 whole), its result's bits into *result: "" or the
		// trap. A call past its budget leaves past_budget() true.
		ss_ call(size_t index, const uint64_t *args, uint64_t *result);
		// The last call (or the start function) ran out of its budget
		bool past_budget();
		// A call's budget on the engine running the module
		int64_t budget();
		// "compiled", "interpreter, compiling", "interpreter" or "browser"
		ss_ engine_name();
		// Stopped, for good: no more calls; the owner's on_fail()
		void fail(const ss_ &why);
		// The export's index, or exports.size()
		size_t find_export(const ss_ &name);

		// The module's memory: its size now, and bytes at [ptr, ptr+len)
		// checked against it and copied
		uint64_t memory_size();
		bool copy_in(uint64_t ptr, uint64_t len, void *dst);
		bool copy_out(uint64_t ptr, const void *src, uint64_t len);

		// A line the module logs, prefixed by its name: MAX_LOG_LINES a
		// call, then one saying the rest are not written. Charged.
		void log_line(const uint8_t *p, size_t n);

		// The boundary: import `which` with its numbers, from the glue, the
		// interpreter or the browser. Its result, or trap_reason set (the
		// caller traps). Calls no wasm and lets no exception out.
		uint32_t run_import(uint32_t which, const uint32_t *a);

		struct Impl; // engine.cpp's: the engines' own state
		Impl *impl = nullptr;

	protected:
		// One import's work: its result, or why set (a trap). Checks every
		// pointer and length with copy_in()/copy_out().
		virtual uint32_t import_body(uint32_t which, const uint32_t *a,
				ss_ &why) = 0;
		// The module is stopped (fail()): what it holds is let go
		virtual void on_fail(){}

	private:
		void started_or_failed(const ss_ &trap);
		friend struct Impl;
	};

	// A module's handles ([CLIENT_WASM] step 2): a table of its own of what
	// it names. A handle is tag << 24 | generation << 10 | slot; the tag is
	// the table's (another module's handle names another tag), the
	// generation the slot's when it was given (one dropped since is stale;
	// a slot whose generation would wrap is not used again).
	uint32_t take_tag();
	void give_back_tag(uint32_t tag);
	template<typename T>
	struct Handles
	{
		static const uint32_t GEN_MAX = (1 << 14) - 1;
		struct Entry {
			bool used = false;
			uint32_t gen = 1;
			T v;
		};
		uint32_t tag = 0;
		size_t cap = 1024; // at most 1024: the slot is 10 bits
		sv_<Entry> e;

		Handles(): tag(take_tag()){}
		~Handles(){ give_back_tag(tag); }
		Handles(const Handles&) = delete;
		Handles& operator=(const Handles&) = delete;

		// A new handle for v, or 0 with the table full
		uint32_t give(T v)
		{
			size_t i = 0;
			while(i < e.size() && (e[i].used || e[i].gen > GEN_MAX))
				i++;
			if(i == e.size()){
				if(e.size() >= cap || e.size() >= 1024 || tag == 0)
					return 0;
				e.emplace_back();
			}
			e[i].used = true;
			e[i].v = std::move(v);
			return tag << 24 | e[i].gen << 10 | (uint32_t)i;
		}
		// The handle's value, or null with why: a handle not given, one
		// given and dropped, or another module's
		T* get(uint32_t h, ss_ &why)
		{
			const uint32_t t = h >> 24, gen = (h >> 10) & GEN_MAX, i = h & 1023;
			if(t != tag){
				why = "handle "+itos(h)+" is not this module's"+
						(t >= 1 && t < 128 ? " (another module's)" : "");
				return nullptr;
			}
			if(i >= e.size() || gen == 0 || gen > e[i].gen){
				why = "handle "+itos(h)+" was never given";
				return nullptr;
			}
			if(gen != e[i].gen || !e[i].used){
				why = "handle "+itos(h)+" is stale (dropped)";
				return nullptr;
			}
			return &e[i].v;
		}
		// The slot free, its generation on; what it held into *old
		bool drop(uint32_t h, ss_ &why, T *old = nullptr)
		{
			T *v = get(h, why);
			if(!v)
				return false;
			Entry &x = e[h & 1023];
			if(old)
				*old = std::move(x.v);
			x.v = T();
			x.used = false;
			x.gen++;
			return true;
		}
		template<typename F>
		void each(F f)
		{
			for(Entry &x : e)
				if(x.used)
					f(x.v);
		}
	};
}
// vim: set noet ts=4 sw=4:
