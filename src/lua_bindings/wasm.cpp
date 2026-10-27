// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [CLIENT_WASM] A module's wasm/, built by the server to a .wasm, run on
// the client as a sandbox of its own, its exports called from Lua.
//
// Both clients first read the .wasm with WABT and refuse it past the caps
// below, and meter it (meter_module(): a call past its budget traps, and
// the module is stopped). Then:
// - natively, wasm2c turns it into C (the client's own C: the export and
//   function names are renamed to f0, f1, ... before it is written, and no
//   name of the server's reaches the C or a command line), the system's
//   compiler builds that in a child process with a time and a memory
//   limit, and the result is cached under <cache>/wasm2c/ by the hashes of
//   the .wasm, WABT, the compiler and the flags, and dlopen()ed. Its memory
//   is checked by guard pages (8 GiB reserved per instance); a fault in
//   them, while a call is in it, is a trap and not a crash.
//   Until that is done, and for good with no compiler, WAMR's fast
//   interpreter (3rdparty/wamr) runs the same bytes, the memory's bounds
//   checked by its code; between two calls the module moves to the
//   compiled one, its state copied (prepare_native()).
// - on the web, the browser's own WebAssembly runs it, as an instance of
//   its own with its own memory: the JS between (EM_JS below) passes
//   numbers and copies bytes, and the module never sees the client's heap,
//   table or Module.
//
// The imports (interface/wasm_api.h) are the same C++ on both clients
// (run_import() below): natively wasm2c's import functions call it through
// the glue, on the web the module's import object does through
// buildat_wasm_import(). It checks every pointer and length against the
// module's memory and copies the bytes, names objects by handles from a
// table of the instance's own, and calls neither Lua nor wasm -- but for
// the bindings ([CLIENT_WASM_BINDINGS], binding_import()), which are calls
// of the Lua sandbox's own list made through the module's dispatcher in
// its sandbox, as its script would make them; no wasm call starts while
// one runs (g_import_depth).
//
// Natively on Windows ([CLIENT_WASM_WINDOWS]) the same, but: the compile
// is the package's MinGW in a job object (memory, CPU time and process
// caps, killed with the client), the module a DLL with wasm2c's runtime
// in it (a DLL does not see the executable's symbols), and its memory
// checked by wasm2c's explicit bounds checks instead of guard pages, so
// that no exception handler is needed (WASM2C_DEFINES below says why).
// BUILDAT_WASM_FUZZ: util/fuzz/wasm_fuzz.cpp includes this file for the
// checks, the meter and the preparation (to the end of movable()), with
// none of the client: the instances, the compile and Lua are left out
#ifndef BUILDAT_WASM_FUZZ
#include "lua_bindings/util.h"
#include "interface/voxel_volume.h"
#include <tolua++.h>
#include <luabind/luabind.hpp>
#include <Node.h>
#include <CustomGeometry.h>
#include <Texture2D.h>
#include <Image.h>
#else
#include "core/types.h"
#endif
#include "core/log.h"
#include "interface/sha1.h"
#include "wabt/binary-reader-ir.h"
#include "wabt/binary-reader.h"
#include "wabt/binary-writer.h"
#include "wabt/stream.h"
#include "wabt/validator.h"
#include "wabt/ir.h"
#include "wabt/cast.h"
#if (defined(__linux__) || defined(_WIN32)) && !defined(__EMSCRIPTEN__)
#define BUILDAT_WASM_NATIVE 1
#include "wabt/generate-names.h"
#include "wabt/apply-names.h"
#include "wabt/c-writer.h"
#ifndef BUILDAT_WASM_FUZZ
#include "client/config.h"
#include "boot/autodetect.h"
#endif
#include "interface/fs.h"
#include "wasm_export.h"
#include <algorithm>
#include <csignal>
#include <fstream>
#include <sstream>
#ifdef _WIN32
#include "wasm-rt.h"
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "ports/windows_minimal.h"
#include <sddl.h>
#include <aclapi.h>
// Defined again by those (objbase.h), and interface is this tree's namespace
#undef interface
#else
#include "wasm-rt-impl.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#endif
#endif
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#endif
#include <cctype>
#include <deque>
#include <map>
#include <memory>
#include <chrono>
#include <cmath>
#include <cstring>
#include <cstdarg>
#define MODULE "wasm"

#if BUILDAT_WASM_NATIVE && !defined(BUILDAT_WASM_FUZZ)
extern client::Config g_client_config;
#endif

namespace lua_bindings {

// The caps, the same on both clients ([CLIENT_WASM] security). The server
// links with --max-memory at MAX_PAGES' size, so a module it built passes.
static const size_t MAX_BYTES = 8 << 20;
static const size_t MAX_FUNCS = 50000;
static const uint64_t MAX_PAGES = 1024; // 64 MiB
static const uint64_t MAX_TABLE = 100000;
static const size_t MAX_EXPORTS = 1000;
static const size_t MAX_PARAMS = 16;
static const size_t MAX_INSTANCES = 32;
static const size_t MAX_LOG = 1000;
static const size_t MAX_LOG_LINES = 100; // in one call, then one "suppressed"
// The imports' caps ([CLIENT_WASM] step 2), per module (instance)
static const size_t MAX_HANDLES = 1024; // nodes, textures and volumes
static const uint32_t MAX_GEOMETRIES = 16; // a node's
static const uint64_t MAX_INDICES = 196608; // a geometry's (and vertices)
static const uint64_t MAX_INDICES_ALL = 1048576; // a module's, 48 MiB of C++
		// and GPU vertices, as the CustomGeometry has no index buffer
static const uint32_t MAX_TEXTURE_SIDE = 4096;
static const uint64_t MAX_TEXTURE_BYTES = 64 << 20; // a module's
static const uint64_t MAX_VOXELS = 4194304; // a read's
static const size_t MAX_PACKET_NAME = 64;
static const uint64_t MAX_PACKET = 65536;
static const size_t MAX_PACKETS = 64; // sent in one call
static const size_t MAX_EVENTS = 256; // queued
static const size_t MAX_EVENT_BYTES = 4 << 20; // queued

// What a module may import, all from "buildat", all i32 (wasm_api.h): the
// parameters and whether it returns one. Validation allows exactly these.
enum {
	IMP_LOG, IMP_TIME_MS, IMP_VOXELS_SIZE, IMP_VOXELS_READ, IMP_GEOMETRY_SET,
	IMP_TEXTURE_SET, IMP_NODE_GET, IMP_NODE_SET, IMP_SEND_PACKET,
	IMP_EVENT_TAKE, IMP_DROP, IMP_COUNT
};
struct ImportDef { const char *name; int params; bool result; };
static const ImportDef IMPORTS[IMP_COUNT] = {
	{"log", 2, false},
	{"time_ms", 0, true},
	{"voxels_size", 2, false},
	{"voxels_read", 4, true},
	{"geometry_set", 6, false},
	{"texture_set", 5, false},
	{"node_get", 2, false},
	{"node_set", 2, false},
	{"send_packet", 4, false},
	{"event_take", 2, true},
	{"drop", 1, false},
};
static const int MAX_IMPORT_PARAMS = 6;

// [CLIENT_WASM_BINDINGS] The imports generated from the Lua sandbox's own
// list (util/gen_wasm_bindings.lua writes wasm_bindings.inc and
// interface/buildat_client.h): each the call its name says -- "Node:
// SetPosition(Vector3)", "Text.text=string" -- made through the module's
// dispatcher, a Lua function in the module's sandbox (m:bind(), the
// default client_main's), as a script's own call is: what Lua is refused,
// these are refused. All are (args, args_len, ret, ret_cap) -> the
// results' length, the values encoded as buildat_client.h says. Validation
// allows exactly these names with that signature; each is then renamed
// g<k> (k its index here), so that the C and the interpreter see no name
// of the module's. The import's index is IMP_COUNT + k.
struct BindingDef { const char *name, *kind, *cls, *member; };
static const BindingDef BINDINGS[] = {
#define BUILDAT_BINDING(n, k, c, m) {n, k, c, m},
#include "lua_bindings/wasm_bindings.inc"
#undef BUILDAT_BINDING
};
static const size_t BINDING_COUNT = sizeof BINDINGS / sizeof BINDINGS[0];
static const size_t IMP_ALL = IMP_COUNT + BINDING_COUNT;
// The values carried by their components (Vector3, Color, ...), by kind
struct ValueDef { unsigned int kind; const char *cls; int n; const char *c[4]; };
static const ValueDef VALUE_DEFS[] = {
#define BUILDAT_VALUE(k, cls, n, a, b, c, d) {k, cls, n, {a, b, c, d}},
#include "lua_bindings/wasm_bindings.inc"
#undef BUILDAT_VALUE
};
// A binding call's values, in and out, and how many
static const size_t MAX_BINDING_BYTES = 1 << 20;
static const unsigned int MAX_BINDING_VALUES = 32;
// Its charge, as IMPORT_COST: a call into the sandbox's Lua
static const uint64_t BINDING_COST = 20000;

static const char *import_name(size_t which)
{
	return which < IMP_COUNT ? IMPORTS[which].name :
			which < IMP_ALL ? BINDINGS[which - IMP_COUNT].name : "?";
}
static int import_params(size_t which)
{
	return which < IMP_COUNT ? IMPORTS[which].params : 4;
}
static bool import_result(size_t which)
{
	return which < IMP_COUNT ? IMPORTS[which].result : true;
}
// The bindings' names by index; and their hash, which is in the compiled
// module's cache key, as the indices are in its C
static size_t binding_index(const ss_ &name)
{
	static std::map<ss_, size_t> m;
	if(m.empty())
		for(size_t k = 0; k < BINDING_COUNT; k++)
			m[BINDINGS[k].name] = k;
	auto it = m.find(name);
	return it == m.end() ? BINDING_COUNT : it->second;
}
static ss_ bindings_hash()
{
	ss_ all;
	for(const BindingDef &d : BINDINGS)
		all += ss_(d.name)+"\n";
	return interface::sha1::hex(interface::sha1::calculate(all));
}

struct ExportSig {
	ss_ name;
	ss_ params; // 'i' i32, 'I' i64, 'f' f32, 'F' f64
	char result = 0; // one of those, or 0 for none
};

static char type_char(wabt::Type t)
{
	switch(t){
	case wabt::Type::I32: return 'i';
	case wabt::Type::I64: return 'I';
	case wabt::Type::F32: return 'f';
	case wabt::Type::F64: return 'F';
	default: return 0;
	}
}

static bool export_name_ok(const ss_ &n)
{
	if(n.empty() || n.size() > 64 || isdigit((unsigned char)n[0]))
		return false;
	for(char c : n)
		if(!isalnum((unsigned char)c) && c != '_')
			return false;
	return true;
}

// The bytes a module logged, as one line of printable ASCII
static ss_ printable(const uint8_t *p, size_t n)
{
	ss_ r;
	for(size_t i = 0; i < n && i < MAX_LOG; i++)
		r += (p[i] >= 32 && p[i] < 127) ? (char)p[i] : '?';
	return r;
}

// What clang builds with the server's flags; nothing else is read. Bulk
// memory stays (memory.fill and memory.copy, which the meter counts by
// their sizes), and so does multi-value.
static wabt::Features features()
{
	wabt::Features f;
	f.disable_exceptions();
	f.disable_simd();
	f.disable_relaxed_simd();
	f.disable_threads();
	f.disable_tail_call();
	f.disable_memory64();
	f.disable_multi_memory();
	f.disable_extended_const();
	f.disable_reference_types();
	f.disable_annotations();
	return f;
}

// Read, validate and cap; fills exports and whether it imports anything
static bool check_module(const ss_ &bytes, wabt::Module &m,
		sv_<ExportSig> &exports, bool &has_imports, ss_ &why)
{
	if(bytes.size() > MAX_BYTES){
		why = "larger than "+itos(MAX_BYTES)+" bytes";
		return false;
	}
	const wabt::Features f = features();
	wabt::Errors errors;
	// No debug names: nothing of the server's is a C name
	wabt::ReadBinaryOptions options(f, nullptr, false, true, true);
	if(wabt::Failed(wabt::ReadBinaryIr("module.wasm", (const uint8_t*)bytes.data(),
			bytes.size(), options, &errors, &m)) ||
			wabt::Failed(wabt::ValidateModule(&m, &errors, f))){
		why = errors.empty() ? ss_("not valid") :
				"not valid: "+errors[0].message.substr(0, 200);
		return false;
	}
	if(m.funcs.size() > MAX_FUNCS){
		why = "more than "+itos(MAX_FUNCS)+" functions";
		return false;
	}
	// Exactly wasm_api.h's imports and the bindings, by name and signature,
	// each once; a binding renamed g<k>
	has_imports = false;
	sv_<bool> seen(IMP_ALL, false);
	for(wabt::Import *imp : m.imports){
		const wabt::FuncImport *fi = wabt::dyn_cast<wabt::FuncImport>(imp);
		size_t k = 0;
		while(k < IMP_COUNT && imp->field_name != IMPORTS[k].name)
			k++;
		if(k == IMP_COUNT)
			k = IMP_COUNT + binding_index(imp->field_name);
		bool ok = fi && imp->module_name == "buildat" && k < IMP_ALL &&
				!seen[k];
		if(ok){
			const wabt::FuncSignature &s = fi->func.decl.sig;
			ok = (int)s.param_types.size() == import_params(k) &&
					s.result_types.size() == (import_result(k) ? 1u : 0u);
			for(wabt::Type t : s.param_types)
				ok = ok && t == wabt::Type::I32;
			for(wabt::Type t : s.result_types)
				ok = ok && t == wabt::Type::I32;
		}
		if(!ok){
			why = "imports \""+imp->module_name.substr(0, 32)+"."+
					imp->field_name.substr(0, 120)+"\", which is not one of "
					"wasm_api.h's or buildat_client.h's with its signature "
					"(built for another engine API?)";
			// Printable only: the names are the server's
			why = printable((const uint8_t*)why.data(), why.size());
			return false;
		}
		seen[k] = true;
		has_imports = true;
		if(k >= IMP_COUNT)
			imp->field_name = "g"+itos(k - IMP_COUNT);
	}
	if(m.memories.size() > 1){
		why = "more than one memory";
		return false;
	}
	for(const wabt::Memory *mem : m.memories){
		const wabt::Limits &l = mem->page_limits;
		if(l.is_shared || l.is_64 || !l.has_max || l.max > MAX_PAGES ||
				l.initial > l.max){
			why = "its memory has no maximum, or one above "+
					itos(MAX_PAGES)+" pages";
			return false;
		}
	}
	for(const wabt::Table *t : m.tables){
		const wabt::Limits &l = t->elem_limits;
		if(!l.has_max || l.max > MAX_TABLE || l.initial > l.max){
			why = "a table with no maximum, or one above "+itos(MAX_TABLE);
			return false;
		}
	}
	if(m.exports.size() > MAX_EXPORTS){
		why = "more than "+itos(MAX_EXPORTS)+" exports";
		return false;
	}
	exports.clear();
	for(const wabt::Export *e : m.exports){
		// The meter's names (meter_module()), whatever their kind
		if(e->name.compare(0, 8, "buildat_") == 0){
			why = "an export's name begins with buildat_, the client's own";
			return false;
		}
		// m:read() and m:write() reach the memory exported as "memory"
		if(e->name == "memory" && e->kind != wabt::ExternalKind::Memory){
			why = "\"memory\" is exported as something other than its memory";
			return false;
		}
		if(e->kind != wabt::ExternalKind::Func)
			continue;
		const wabt::Func *fn = m.GetFunc(e->var);
		if(!export_name_ok(e->name)){
			why = "an export's name is not [A-Za-z_][A-Za-z0-9_]{0,63}";
			return false;
		}
		if(!fn || m.IsImport(wabt::ExternalKind::Func, e->var)){
			why = "exports an import";
			return false;
		}
		ExportSig sig;
		sig.name = e->name;
		const wabt::FuncSignature &s = fn->decl.sig;
		if(s.param_types.size() > MAX_PARAMS || s.result_types.size() > 1){
			why = "an export with more than "+itos(MAX_PARAMS)+
					" parameters or more than one result";
			return false;
		}
		for(wabt::Type t : s.param_types){
			const char c = type_char(t);
			if(!c){
				why = "an export takes a type other than i32, i64, f32, f64";
				return false;
			}
			sig.params += c;
		}
		if(!s.result_types.empty()){
			sig.result = type_char(s.result_types[0]);
			if(!sig.result){
				why = "an export returns a type other than i32, i64, f32, f64";
				return false;
			}
		}
		exports.push_back(sig);
	}
	return true;
}

// [CLIENT_WASM] step 3, the meter: a call that never ends must not freeze
// the client (on the web, the tab). The module is rewritten before it is
// translated (natively) or instantiated (on the web), so that both run the
// same metered code: a global of its own, counted down, and a trap once it
// is below zero.
// - It is charged at each function's entry and at the top of each loop
//   (where every back-edge lands: br, br_if and br_table alike), by the
//   number of instructions of that region: the function's or the loop's
//   own, those in a loop nested in it being that loop's. So every
//   instruction run is charged at least once (an overcount, never an
//   undercount), whatever the path, a call_indirect and a recursion
//   included. Tail calls are not read (validation).
// - memory.fill, memory.copy, memory.init, table.copy and table.init are
//   charged by their sizes too (bytes / 16), before they run.
// - The imports charge their own work (run_import()).
// - The start function is not run by instantiation: it is exported as
//   buildat_start and called as an export is, after it, with its budget.
// - The meter is the defined global exported as buildat_meter, added
//   after validation: the module's own code cannot name it (an index past
//   the module's globals failed validation), and a module exporting a
//   buildat_ name of its own is refused (check_module()). Its imports are
//   wasm_api.h's functions only, so it cannot import a global either.
// The client sets the meter to BUDGET before each call; the call that
// ends with it below zero traps, and the module is stopped.
// simplified: the meter is a global, loaded and stored at each charge,
// which costs a tight loop about a quarter (a byte swap: 70 ms to 88 ms
// natively, 72 to 92 on the web); a local copy kept in a register and
// written back around calls and exits is the upgrade if that matters.
// simplified: a unit is an instruction, not a time: the budget is about
// 0.1 s of the densest loop measured and 1-2 s of a plain one (a counter,
// memory.fill, a recursion), and a loop that misses the cache each round
// takes longer per unit; a stop by the clock as well is the upgrade.
static const char *METER = "buildat_meter";
static const char *START = "buildat_start";
// A call's budget, in the units above (about an instruction each): of
// the order of a second of a tight loop on either client
static const int64_t BUDGET = 4000000000;
// The interpreter's (step 4): the same units, a sixteenth of them, as it
// runs them up to 20 times slower than the compiled code (measured: 5 a
// counter loop, 17 the toy's byte reversal, 4.5 a recursion, 1-2
// memory.fill; a loop of nothing but the meter's own charge, the worst,
// 2.5e8 in 0.9 s), so that a call that does not end freezes the client
// about as long on either engine (with BUDGET, up to 27 s here: past the
// client's 30 s watchdog with the rest of a frame)
#if BUILDAT_WASM_NATIVE
static const int64_t INTERP_BUDGET = BUDGET / 16;
#endif
// The bytes of memory.fill and its kind that count as one instruction
static const int BULK_SHIFT = 4;
// An import's charge, as a guess at its time in the same units: this for
// any, and its work on top (import_body())
static const uint64_t IMPORT_COST = 200;

// The instructions of a region: these, and those of their blocks and
// ifs, but not those of a loop (its own region; the loop itself counts)
static uint64_t region_cost(const wabt::ExprList &l)
{
	uint64_t n = 0;
	for(const wabt::Expr &e : l){
		n++;
		if(const wabt::BlockExpr *b = wabt::dyn_cast<wabt::BlockExpr>(&e))
			n += region_cost(b->block.exprs);
		else if(const wabt::IfExpr *i = wabt::dyn_cast<wabt::IfExpr>(&e))
			n += region_cost(i->true_.exprs) + region_cost(i->false_);
	}
	return n;
}

// [WASM_WEB_CALL_DEPTH] On the web the browser's own stack holds the
// module's frames, and nothing counted them: a recursion ran until the
// browser's RangeError, which may come inside the client's own code during
// a binding (l_wasm_call()). There the module also keeps an estimate of
// the browser's stack its frames take, the global exported as
// buildat_stack (as the meter, after validation): at each call a function
// makes, its own frame's estimate is added before and taken off after, and
// past WEB_STACK_LIMIT the call traps. The client sets it to 0 before each
// call. A frame is estimated at WEB_FRAME_BASE and 8 bytes a parameter or
// local, which is what Chrome takes (measured: a recursion of no locals
// stopped at 17696 frames, one of 242 at 494: about 970 KiB), so the limit
// leaves some 330 KiB for the client below the call and a binding above
// it (the deepest, 75 KiB natively).
// simplified: values a function holds on its operand stack across a call
// are not counted, nor the deepest frame's own (it makes no call); past
// the estimate the browser's RangeError stops it, as before
// ([WASM_WEB_IMPORT_DEPTH]). Natively wasm2c and WAMR count the depth.
static const char STACK[] = "buildat_stack";
static const int64_t WEB_FRAME_BASE = 48;
static const int64_t WEB_STACK_LIMIT = 640 << 10;

struct Meter {
	wabt::Index global;
	wabt::Index stack = ~0u; // buildat_stack's, on the web
	int64_t frame = 0; // the function's frame, estimated as above
	// The meter less (the i32 in local `scratch` >> BULK_SHIFT) when
	// scratch is set, else less cost; then the trap if it is below zero
	wabt::ExprList charge(uint64_t cost, wabt::Index scratch = ~0u)
	{
		using namespace wabt;
		ExprList l;
		const Var g(global, Location());
		l.push_back(std::make_unique<GlobalGetExpr>(g));
		if(scratch != ~0u){
			l.push_back(std::make_unique<LocalGetExpr>(Var(scratch, Location())));
			l.push_back(std::make_unique<ConvertExpr>(Opcode::I64ExtendI32U));
			l.push_back(std::make_unique<ConstExpr>(Const::I64(BULK_SHIFT)));
			l.push_back(std::make_unique<BinaryExpr>(Opcode::I64ShrU));
		} else {
			l.push_back(std::make_unique<ConstExpr>(Const::I64(cost)));
		}
		l.push_back(std::make_unique<BinaryExpr>(Opcode::I64Sub));
		l.push_back(std::make_unique<GlobalSetExpr>(g));
		l.push_back(std::make_unique<GlobalGetExpr>(g));
		l.push_back(std::make_unique<ConstExpr>(Const::I64(0)));
		l.push_back(std::make_unique<CompareExpr>(Opcode::I64LtS));
		auto trap = std::make_unique<IfExpr>();
		trap->true_.exprs.push_back(std::make_unique<UnreachableExpr>());
		l.push_back(std::move(trap));
		return l;
	}

	// A list's loops charged at their tops, its bulk operations by their
	// sizes; scratch is the function's i32 for those, made on first use
	void walk(wabt::Func *f, wabt::ExprList &l, wabt::Index &scratch)
	{
		using namespace wabt;
		for(auto it = l.begin(); it != l.end(); ++it){
			switch(it->type()){
			case ExprType::Block:
				walk(f, cast<BlockExpr>(&*it)->block.exprs, scratch);
				break;
			case ExprType::If:
				walk(f, cast<IfExpr>(&*it)->true_.exprs, scratch);
				walk(f, cast<IfExpr>(&*it)->false_, scratch);
				break;
			case ExprType::Loop: {
				ExprList &body = cast<LoopExpr>(&*it)->block.exprs;
				walk(f, body, scratch);
				ExprList c = charge(region_cost(body) + 1);
				body.splice(body.begin(), c);
				break;
			}
			case ExprType::Call:
			case ExprType::CallIndirect: {
				if(stack == ~0u)
					break;
				const Var g(stack, Location());
				ExprList c;
				c.push_back(std::make_unique<GlobalGetExpr>(g));
				c.push_back(std::make_unique<ConstExpr>(Const::I64(frame)));
				c.push_back(std::make_unique<BinaryExpr>(Opcode::I64Add));
				c.push_back(std::make_unique<GlobalSetExpr>(g));
				c.push_back(std::make_unique<GlobalGetExpr>(g));
				c.push_back(std::make_unique<ConstExpr>(
						Const::I64(WEB_STACK_LIMIT)));
				c.push_back(std::make_unique<CompareExpr>(Opcode::I64GtS));
				auto trap = std::make_unique<IfExpr>();
				trap->true_.exprs.push_back(std::make_unique<UnreachableExpr>());
				c.push_back(std::move(trap));
				l.splice(it, c);
				ExprList after;
				after.push_back(std::make_unique<GlobalGetExpr>(g));
				after.push_back(std::make_unique<ConstExpr>(Const::I64(frame)));
				after.push_back(std::make_unique<BinaryExpr>(Opcode::I64Sub));
				after.push_back(std::make_unique<GlobalSetExpr>(g));
				auto next = it;
				++next;
				l.splice(next, after);
				break;
			}
			case ExprType::MemoryFill:
			case ExprType::MemoryCopy:
			case ExprType::MemoryInit:
			case ExprType::TableCopy:
			case ExprType::TableInit:
			case ExprType::TableFill: {
				// Each takes its size (an i32: no memory64, no table64)
				// last, on the top of the stack
				if(scratch == ~0u){
					scratch = f->GetNumParamsAndLocals();
					f->local_types.AppendDecl(Type::I32, 1);
				}
				ExprList c;
				c.push_back(std::make_unique<LocalTeeExpr>(
						Var(scratch, Location())));
				ExprList rest = charge(0, scratch);
				c.splice(c.end(), rest);
				l.splice(it, c);
				break;
			}
			default:
				break;
			}
		}
	}
};

// The module metered, as above; has_start whether it had a start function
// (now its export START). Validated again after, so that a fault here is a
// refusal and not a module that does something else.
static bool meter_module(wabt::Module &m, bool &has_start, ss_ &why)
{
	using namespace wabt;
	Meter meter;
#ifdef __EMSCRIPTEN__
	{
		meter.stack = (Index)m.globals.size();
		auto sg = std::make_unique<GlobalModuleField>();
		sg->global.type = Type::I64;
		sg->global.mutable_ = true;
		sg->global.init_expr.push_back(std::make_unique<ConstExpr>(Const::I64(0)));
		m.AppendField(std::move(sg));
		auto se = std::make_unique<ExportModuleField>();
		se->export_.name = STACK;
		se->export_.kind = ExternalKind::Global;
		se->export_.var = Var(meter.stack, Location());
		m.AppendField(std::move(se));
	}
#endif
	meter.global = (Index)m.globals.size();
	auto g = std::make_unique<GlobalModuleField>();
	g->global.type = Type::I64;
	g->global.mutable_ = true;
	g->global.init_expr.push_back(std::make_unique<ConstExpr>(Const::I64(0)));
	m.AppendField(std::move(g));
	auto ge = std::make_unique<ExportModuleField>();
	ge->export_.name = METER;
	ge->export_.kind = ExternalKind::Global;
	ge->export_.var = Var(meter.global, Location());
	m.AppendField(std::move(ge));
	for(Index i = m.num_func_imports; i < m.funcs.size(); i++){
		Func *f = m.funcs[i];
		Index scratch = ~0u;
		meter.frame = WEB_FRAME_BASE + 8 * (int64_t)f->GetNumParamsAndLocals();
		meter.walk(f, f->exprs, scratch);
		ExprList c = meter.charge(region_cost(f->exprs) + 1);
		f->exprs.splice(f->exprs.begin(), c);
	}
	has_start = !m.starts.empty();
	if(has_start){
		const Var start = *m.starts[0];
		m.starts.clear();
		for(auto it = m.fields.begin(); it != m.fields.end(); ++it)
			if(it->type() == ModuleFieldType::Start){
				m.fields.erase(it);
				break;
			}
		auto se = std::make_unique<ExportModuleField>();
		se->export_.name = START;
		se->export_.kind = ExternalKind::Func;
		se->export_.var = start;
		m.AppendField(std::move(se));
	}
	Errors errors;
	if(Failed(ValidateModule(&m, &errors, features()))){
		why = "not valid once metered: "+(errors.empty() ? ss_("?") :
				errors[0].message.substr(0, 200));
		return false;
	}
	return true;
}

#if BUILDAT_WASM_NATIVE
// [CLIENT_WASM] step 4: natively, the module runs in WAMR's interpreter
// while its compile is under way, and moves to the compiled one between
// two calls: its memory and its mutable globals are copied over (the
// meter's included), so the move is not a start over and not a budget
// reset. The rest of an instance's state is what instantiation made, the
// same in both, unless the module changes it: a dropped data segment
// (only memory.init can tell) or a table changed by table.init or
// table.copy (elem.drop only matters to table.init; table.set, .grow and
// .fill need reference types, refused). A module using those, or with a
// memory that is not exported as "memory" (which the compiled glue does
// not reach), waits on its compile instead (MOVABLE below).

// The mutable globals, exported for the move as buildat_g<index> (a name a
// module cannot export: check_module()); the meter is exported already
struct GlobalCopy {
	ss_ name;
	size_t size;
};

// The exports renamed to what the glue and the interpreter look up: f<i>
// in the order of `exports`, mem for the memory named "memory", x<i>
// others; so that no name of the server's reaches the C, and no name means
// something to WAMR (__wasm_call_ctors, malloc, _initialize and others it
// calls or uses by name). Then the mutable globals exported as above.
static void prepare_native(wabt::Module &m, bool &has_memory,
		sv_<GlobalCopy> &globals)
{
	using namespace wabt;
	has_memory = false;
	size_t fi = 0, xi = 0;
	for(Export *e : m.exports){
		if(e->name == METER || e->name == START){
			// The meter's (meter_module()), named as the glue knows
		} else if(e->kind == ExternalKind::Func){
			e->name = "f"+itos(fi++);
		} else if(e->kind == ExternalKind::Memory && e->name == "memory"){
			e->name = "mem";
			has_memory = true;
		} else {
			e->name = "x"+itos(xi++);
		}
	}
	globals.clear();
	for(Index i = 0; i < m.globals.size(); i++){
		const Global *g = m.globals[i];
		if(!g->mutable_)
			continue;
		const size_t size = g->type == Type::I64 || g->type == Type::F64 ? 8 : 4;
		ss_ name = METER;
		if(i != (Index)m.globals.size() - 1){ // the meter is the last
			name = "buildat_g"+itos(i);
			auto ge = std::make_unique<ExportModuleField>();
			ge->export_.name = name;
			ge->export_.kind = ExternalKind::Global;
			ge->export_.var = Var(i, Location());
			m.AppendField(std::move(ge));
		}
		globals.push_back({name, size});
	}
}

// Whether a list uses an instruction whose state the move does not copy
static bool uses_uncopied(const wabt::ExprList &l)
{
	using namespace wabt;
	for(const Expr &e : l){
		switch(e.type()){
		case ExprType::MemoryInit:
		case ExprType::TableInit:
		case ExprType::TableCopy:
			return true;
		case ExprType::Block:
			if(uses_uncopied(cast<BlockExpr>(&e)->block.exprs))
				return true;
			break;
		case ExprType::Loop:
			if(uses_uncopied(cast<LoopExpr>(&e)->block.exprs))
				return true;
			break;
		case ExprType::If:
			if(uses_uncopied(cast<IfExpr>(&e)->true_.exprs) ||
					uses_uncopied(cast<IfExpr>(&e)->false_))
				return true;
			break;
		default:
			break;
		}
	}
	return false;
}

// Whether the module's state can be moved to the compiled one (above)
static bool movable(const wabt::Module &m, bool has_memory)
{
	if(!m.memories.empty() && !has_memory)
		return false;
	for(const wabt::Func *f : m.funcs)
		if(uses_uncopied(f->exprs))
			return false;
	return true;
}
#endif

#ifndef BUILDAT_WASM_FUZZ
struct Instance;
static size_t g_instance_count = 0;
// The client's Lua (init_wasm()): the handles' and the dispatchers'
// references are in its registry
static lua_State *g_L = nullptr;
// A binding's Lua is running ([CLIENT_WASM_BINDINGS]): no wasm call starts
// meanwhile, of this module or another, so that no import re-enters wasm
static int g_import_depth = 0;
#ifdef __EMSCRIPTEN__
// [WASM_WEB_IMPORT_DEPTH] On the web the browser's stack can run out
// inside the client's own code during a binding's Lua, and its RangeError
// unwinds through the client to bw_call()'s catch: no destructor, no
// lua_pcall's error path and no g_import_depth-- run. What lua_pcall would
// restore is kept here while a binding runs, for l_wasm_call() to put back
// (lua_unwind_restore(), with Lua's internals at the end of this file).
struct LuaUnwind {
	lua_State *L = nullptr;
	ptrdiff_t top = 0, ci = 0, errfunc = 0;
	void *error_jmp = nullptr;
	unsigned short n_ccalls = 0;
	unsigned char allowhook = 0;
};
static void lua_unwind_save(LuaUnwind &u, lua_State *L);
static void lua_unwind_restore(const LuaUnwind &u);
static struct {
	bool active = false;
	// The binding's Lua, and the client's main state, where Urho3D's event
	// handlers run, if another
	LuaUnwind call, main;
} g_binding_unwind;
#endif
// The live instances' handle tags (1 to 127)
static bool g_tag_used[128] = {};

#if BUILDAT_WASM_NATIVE

// The C wasm2c makes is built with these (and on Linux the runtime linked
// into the client with the first two: CMakeLists.txt). The call depth is
// counted, so that a deep recursion is a trap, not a native stack
// overflow, and each native frame is capped by the compiler (MAX_FRAME,
// compiler() below), as a frame's size is the module's to choose (its
// locals, its operand stack, what the compiler inlines): 2000 frames of
// at most 2 KiB (and the saved registers, about 64 bytes) take some 4.2
// MiB of the main thread's 8 MiB (Linux's default; buildat.exe's 8 MiB
// too, CMakeLists.txt), the rest for the client below the call and the
// imports above it. A module past the cap is not compiled and stays in
// the interpreter ([WASM_FRAME_SIZE]; hillclimb's largest is 608 bytes).
// - Linux: guard pages (8 GiB reserved an instance), the runtime's own
//   signal handler off, as this file's chains to the client's crash
//   handler.
// - Windows ([CLIENT_WASM_WINDOWS]): wasm2c's explicit bounds checks, a
//   compare and a branch an access. Guard pages there want a vectored
//   exception handler that leaves the faulting frame for the trap: a
//   longjmp from inside the handler unwinds through the system's exception
//   dispatch, which Win64 does not support, and the supported way (the
//   faulting context pointed at a trampoline) depends on the unwind data of
//   the module's frames being right. A check in the C is correct by
//   construction, shares no handler with the client's crash handler, and
//   reserves no address space.
#ifdef _WIN32
static const char *WASM2C_DEFINES = "-DWASM_RT_MEMCHECK_BOUNDS_CHECK=1 "
		"-DWASM_RT_STACK_DEPTH_COUNT=1 -DWASM_RT_MAX_CALL_STACK_DEPTH=2000";
static const char *MODULE_FILE = "module.dll";
#else
static const char *WASM2C_DEFINES = "-DWASM_RT_SKIP_SIGNAL_RECOVERY=1 "
		"-DWASM_RT_STACK_DEPTH_COUNT=1 -DWASM_RT_MAX_CALL_STACK_DEPTH=2000";
static const char *MODULE_FILE = "module.so";
#endif
static const int MAX_FRAME = 2048; // bytes, a native frame's
// The stack a compiled module's deepest call needs free below the load's
// own frame ([WASM_STACK_RLIMIT]): the 2000 frames above and their saved
// registers, and 1 MiB for the imports above them and for a call made a
// little deeper in the client than the load was
static const size_t STACK_NEEDED = 2000 * (size_t)(MAX_FRAME + 64) + (1 << 20);
#ifndef _WIN32
// The stack left below this point on the calling thread, which runs the
// module's calls too (the main thread: its size is RLIMIT_STACK's, read
// by glibc, so a small ulimit -s shows here; with RLIM_INFINITY the room
// up to the next mapping, which is plenty)
static size_t stack_left()
{
	pthread_attr_t a;
	void *lo = nullptr;
	size_t size = 0;
	if(pthread_getattr_np(pthread_self(), &a) != 0)
		return 0;
	const bool ok = pthread_attr_getstack(&a, &lo, &size) == 0;
	pthread_attr_destroy(&a);
	const char *here = (const char*)__builtin_frame_address(0);
	if(!ok || here < (const char*)lo)
		return 0;
	return (size_t)(here - (const char*)lo);
}
#endif
// The time and memory a compile may take before it is killed
static const int COMPILE_WALL_S = 180;
static const uint64_t COMPILE_CPU_S = 120;
static const uint64_t COMPILE_MEM_BYTES = (uint64_t)2 << 30;
#ifdef _WIN32
// And the processes it may have at once (gcc, cc1, as, collect2, ld)
static const DWORD COMPILE_PROCESSES = 16;
#endif
// Bumped when the C this writes changes (the glue, or what meter_module()
// adds), so that the cache is not reused
static const char *GLUE_VERSION = "buildat-wasm2c-glue 7";

// wasm2c's runtime files the C is built with, as name, contents, name,
// contents, ..., null (3rdparty/wabt/CMakeLists.txt): its headers, and on
// Windows its sources, as each module's DLL has the runtime in it
extern "C" const char *const buildat_wasm_rt_files[];

// What a built module exports to the client (the glue below)
typedef uint32_t (*ImportFn)(void*, uint32_t, const uint32_t*, int*);
typedef size_t (*SizeFn)(void);
typedef void (*BindFn)(void*, void*, ImportFn);
typedef int (*TryFn)(void*, int, uint32_t, const uint64_t*, uint64_t*);
typedef void (*FreeFn)(void*);
typedef wasm_rt_memory_t* (*MemoryFn)(void*);
typedef int64_t* (*MeterFn)(void*);
typedef void* (*GlobalFn)(void*, uint32_t);
typedef uint64_t (*GrowFn)(void*, uint64_t);
typedef const char* (*StrerrorFn)(int);

// A call is in a compiled module (trapping() below)
static volatile sig_atomic_t g_in_wasm = 0;

#ifdef _WIN32

static ss_ last_error()
{
	const DWORD e = GetLastError();
	char buf[300] = "";
	FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
			NULL, e, 0, buf, sizeof buf - 1, NULL);
	ss_ r = buf;
	while(!r.empty() && (r.back() == '\n' || r.back() == '\r' || r.back() == ' '))
		r.pop_back();
	return "error "+itos((int)e)+(r.empty() ? ss_() : ": "+r);
}

static void* lib_open(const ss_ &path, ss_ &why)
{
	void *h = (void*)LoadLibraryA(path.c_str());
	if(!h)
		why = "LoadLibrary: "+last_error();
	return h;
}
static void* lib_sym(void *lib, const char *name)
{
	return (void*)GetProcAddress((HMODULE)lib, name);
}
static void lib_close(void *lib)
{
	FreeLibrary((HMODULE)lib);
}
static bool is_file(const ss_ &path)
{
	const DWORD a = GetFileAttributesA(path.c_str());
	return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}
static bool is_program(const ss_ &path)
{
	return is_file(path);
}

static ss_ upper(ss_ s)
{
	for(char &c : s)
		c = (char)toupper((unsigned char)c);
	return s;
}

// A child of the client's ([CLIENT_WASM_WINDOWS]): args[0] the program,
// each argument quoted (none here has a quote or ends in a backslash; one
// that does is refused), in cwd (the client's when empty), its stdout and
// stderr into out (an inheritable handle) and its stdin from NUL, those
// two the only handles it inherits. Its environment is the client's with
// the program's directory first in PATH (its tools' DLLs, as rccpp does)
// and, when tmp is given, TMP and TEMP there. No window. In a job object
// of its own, from before it runs: the compile's memory (a process's),
// CPU time (the job's) and process count, no error dialog, and killed when
// the job's last handle closes -- the client's, however it ends. process
// and job are the caller's to close; false with why.
static bool spawn(const sv_<ss_> &args, const ss_ &cwd, HANDLE out,
		const ss_ &tmp, HANDLE &process, HANDLE &job, ss_ &why)
{
	process = job = NULL;
	ss_ cmdline;
	for(const ss_ &a : args){
		if(a.find('"') != ss_::npos || (!a.empty() && a.back() == '\\')){
			why = "an argument that cannot be quoted: "+a;
			return false;
		}
		cmdline += (cmdline.empty() ? "\"" : " \"")+a+"\"";
	}
	// The environment block, sorted by name as CreateProcess asks
	sv_<ss_> env;
	ss_ path;
	if(LPCH parent = GetEnvironmentStringsA()){
		for(const char *e = parent; *e; e += strlen(e) + 1){
			const ss_ v = e;
			const ss_ name = upper(v.substr(0, v.find('=', 1)));
			if(name == "PATH")
				path = v.substr(5);
			else if(tmp.empty() || (name != "TMP" && name != "TEMP"))
				env.push_back(v);
		}
		FreeEnvironmentStringsA(parent);
	}
	const size_t slash = args[0].find_last_of("/\\");
	env.push_back("PATH="+(slash == ss_::npos ? ss_() :
			args[0].substr(0, slash)+";")+path);
	if(!tmp.empty()){
		env.push_back("TEMP="+tmp);
		env.push_back("TMP="+tmp);
	}
	std::sort(env.begin(), env.end(), [](const ss_ &a, const ss_ &b){
		return upper(a.substr(0, a.find('=', 1))) <
				upper(b.substr(0, b.find('=', 1)));
	});
	sv_<char> block;
	for(const ss_ &v : env)
		block.insert(block.end(), v.c_str(), v.c_str() + v.size() + 1);
	block.push_back(0);

	JOBOBJECT_EXTENDED_LIMIT_INFORMATION info;
	memset(&info, 0, sizeof info);
	info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
			JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION |
			JOB_OBJECT_LIMIT_PROCESS_MEMORY | JOB_OBJECT_LIMIT_JOB_TIME |
			JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
	info.BasicLimitInformation.PerJobUserTimeLimit.QuadPart =
			(LONGLONG)COMPILE_CPU_S * 10000000;
	info.BasicLimitInformation.ActiveProcessLimit = COMPILE_PROCESSES;
	info.ProcessMemoryLimit = (SIZE_T)COMPILE_MEM_BYTES;
	job = CreateJobObjectA(NULL, NULL);
	if(!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation,
			&info, sizeof info)){
		why = "a job object for the compile's limits: "+last_error();
		if(job)
			CloseHandle(job);
		job = NULL;
		return false;
	}

	SECURITY_ATTRIBUTES sa;
	memset(&sa, 0, sizeof sa);
	sa.nLength = sizeof sa;
	sa.bInheritHandle = TRUE;
	HANDLE nul = CreateFileA("NUL", GENERIC_READ, FILE_SHARE_READ |
			FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, NULL);
	HANDLE inherit[2] = {out, nul};
	SIZE_T size = 0;
	InitializeProcThreadAttributeList(NULL, 1, 0, &size);
	sv_<char> attr_buf(size);
	LPPROC_THREAD_ATTRIBUTE_LIST attrs =
			(LPPROC_THREAD_ATTRIBUTE_LIST)attr_buf.data();
	bool ok = nul != INVALID_HANDLE_VALUE &&
			InitializeProcThreadAttributeList(attrs, 1, 0, &size);
	const bool attrs_made = ok;
	ok = ok && UpdateProcThreadAttribute(attrs, 0,
			PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherit, sizeof inherit, NULL,
			NULL);
	STARTUPINFOEXA si;
	memset(&si, 0, sizeof si);
	si.StartupInfo.cb = sizeof si;
	si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
	si.StartupInfo.hStdInput = nul;
	si.StartupInfo.hStdOutput = out;
	si.StartupInfo.hStdError = out;
	si.lpAttributeList = attrs;
	PROCESS_INFORMATION pi;
	memset(&pi, 0, sizeof pi);
	ok = ok && CreateProcessA(args[0].c_str(), &cmdline[0], NULL, NULL, TRUE,
			CREATE_SUSPENDED | CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
			block.data(), cwd.empty() ? NULL : cwd.c_str(), &si.StartupInfo, &pi);
	if(!ok)
		why = "CreateProcess: "+last_error();
	if(attrs_made)
		DeleteProcThreadAttributeList(attrs);
	if(nul != INVALID_HANDLE_VALUE)
		CloseHandle(nul);
	// Never run without its limits
	if(ok && !AssignProcessToJobObject(job, pi.hProcess)){
		why = "the compile could not be put under its limits: "+last_error();
		TerminateProcess(pi.hProcess, 1);
		ok = false;
	}
	if(!ok){
		if(pi.hProcess)
			CloseHandle(pi.hProcess);
		if(pi.hThread)
			CloseHandle(pi.hThread);
		CloseHandle(job);
		job = NULL;
		return false;
	}
	ResumeThread(pi.hThread);
	CloseHandle(pi.hThread);
	process = pi.hProcess;
	return true;
}

// The compiler's first --version line, from a child under the same limits
static ss_ compiler_version(const ss_ &cmd)
{
	SECURITY_ATTRIBUTES sa;
	memset(&sa, 0, sizeof sa);
	sa.nLength = sizeof sa;
	sa.bInheritHandle = TRUE;
	HANDLE rd = NULL, wr = NULL;
	if(!CreatePipe(&rd, &wr, &sa, 65536))
		return "";
	SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
	HANDLE process = NULL, job = NULL;
	ss_ why, out;
	const bool ok = spawn({cmd, "--version"}, "", wr, "", process, job, why);
	CloseHandle(wr);
	if(ok){
		const bool exited = WaitForSingleObject(process, 10000) == WAIT_OBJECT_0;
		// Nothing of it left holding the pipe: the read ends
		TerminateJobObject(job, 1);
		WaitForSingleObject(process, 1000);
		char buf[4096];
		DWORD n = 0;
		while(exited && out.size() < 65536 &&
				ReadFile(rd, buf, sizeof buf, &n, NULL) && n > 0)
			out.append(buf, n);
		CloseHandle(process);
		CloseHandle(job);
	} else {
		log_w(MODULE, "Compiler for wasm modules: %s: %s", cs(cmd), cs(why));
	}
	CloseHandle(rd);
	return out.substr(0, out.find_first_of("\r\n"));
}

// A directory only this user can reach ([CLIENT_WASM] security: the cache
// the client loads code from): made with a protected DACL granting this
// user alone everything, inherited by what is made in it; or, there
// already, a directory (not a link) whose owner is this user, the same
// DACL set on it again. false with why.
static bool private_dir(const ss_ &path, ss_ &why)
{
	HANDLE token = NULL;
	union { TOKEN_USER user; char bytes[256]; } tu;
	DWORD n = 0;
	if(!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)){
		why = "OpenProcessToken: "+last_error();
		return false;
	}
	const bool got = GetTokenInformation(token, TokenUser, &tu, sizeof tu, &n);
	CloseHandle(token);
	char *sid = NULL;
	if(!got || !ConvertSidToStringSidA(tu.user.User.Sid, &sid)){
		why = "the user's SID: "+last_error();
		return false;
	}
	const ss_ sddl = ss_("D:P(A;OICI;FA;;;")+sid+")";
	LocalFree(sid);
	PSECURITY_DESCRIPTOR sd = NULL;
	if(!ConvertStringSecurityDescriptorToSecurityDescriptorA(sddl.c_str(),
			SDDL_REVISION_1, &sd, NULL)){
		why = "a security descriptor: "+last_error();
		return false;
	}
	SECURITY_ATTRIBUTES sa;
	memset(&sa, 0, sizeof sa);
	sa.nLength = sizeof sa;
	sa.lpSecurityDescriptor = sd;
	bool ok = CreateDirectoryA(path.c_str(), &sa) != 0;
	if(!ok && GetLastError() == ERROR_ALREADY_EXISTS){
		const DWORD attr = GetFileAttributesA(path.c_str());
		PSID owner = NULL;
		PSECURITY_DESCRIPTOR osd = NULL;
		BOOL present = FALSE, defaulted = FALSE;
		PACL dacl = NULL;
		DWORD e = 0;
		if(attr == INVALID_FILE_ATTRIBUTES || !(attr & FILE_ATTRIBUTE_DIRECTORY) ||
				(attr & FILE_ATTRIBUTE_REPARSE_POINT)){
			why = path+" is not a directory (or is a link)";
		} else if((e = GetNamedSecurityInfoA(path.c_str(), SE_FILE_OBJECT,
				OWNER_SECURITY_INFORMATION, &owner, NULL, NULL, NULL, &osd)) !=
				ERROR_SUCCESS || !owner){
			why = path+": its owner could not be read (error "+itos((int)e)+")";
		} else if(!EqualSid(owner, tu.user.User.Sid)){
			char *o = NULL;
			ConvertSidToStringSidA(owner, &o);
			why = path+" is owned by "+(o ? o : "?")+", not this user";
			if(o)
				LocalFree(o);
		} else if(!GetSecurityDescriptorDacl(sd, &present, &dacl, &defaulted) ||
				!present || (e = SetNamedSecurityInfoA((char*)path.c_str(),
				SE_FILE_OBJECT, DACL_SECURITY_INFORMATION |
				PROTECTED_DACL_SECURITY_INFORMATION, NULL, NULL, dacl, NULL)) !=
				ERROR_SUCCESS){
			why = path+": its permissions could not be set (error "+
					itos((int)e)+")";
		} else {
			ok = true;
		}
		if(osd)
			LocalFree(osd);
	} else if(!ok){
		why = "could not make "+path+": "+last_error();
	}
	LocalFree(sd);
	return ok;
}

#else // Linux

static void* lib_open(const ss_ &path, ss_ &why)
{
	void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
	if(!h){
		const char *e = dlerror();
		why = ss_("dlopen: ")+(e ? e : "?");
	}
	return h;
}
static void* lib_sym(void *lib, const char *name)
{
	return dlsym(lib, name);
}
static void lib_close(void *lib)
{
	dlclose(lib);
}
static bool is_file(const ss_ &path)
{
	return access(path.c_str(), R_OK) == 0;
}
static bool is_program(const ss_ &path)
{
	return access(path.c_str(), X_OK) == 0;
}

static ss_ compiler_version(const ss_ &cmd)
{
	FILE *f = popen(("'"+cmd+"' --version 2>/dev/null").c_str(), "r");
	char line[256] = "";
	if(f){
		if(!fgets(line, sizeof line, f))
			line[0] = 0;
		pclose(f);
	}
	ss_ v = line;
	while(!v.empty() && (v.back() == '\n' || v.back() == '\r'))
		v.pop_back();
	return v;
}

// A directory only this user can reach ([CLIENT_WASM] security: the cache
// the client loads code from): made 0700, or, there already, a directory
// (not a link) of this user's, made 0700 again. false with why.
static bool private_dir(const ss_ &path, ss_ &why)
{
	mkdir(path.c_str(), 0700);
	struct stat st;
	if(lstat(path.c_str(), &st) != 0 || !S_ISDIR(st.st_mode) ||
			st.st_uid != geteuid() || chmod(path.c_str(), 0700) != 0){
		why = path+" is not a directory of this user's own";
		return false;
	}
	return true;
}

// The memories of the live instances, for the signal handler: a fault in
// one, while a call is in wasm, is the module's out-of-bounds access.
// Kept by the runtime's own allocation (below), so that a memory is known
// from the moment it exists, a start function's access included.
struct Range { uintptr_t begin, end; };
static Range g_ranges[MAX_INSTANCES];
static struct sigaction g_old_segv, g_old_bus;

static void wasm_fault_handler(int sig, siginfo_t *si, void *ctx)
{
	if(g_in_wasm){
		const uintptr_t a = (uintptr_t)si->si_addr;
		for(const Range &r : g_ranges)
			if(r.begin && a >= r.begin && a < r.end){
				g_in_wasm = 0;
				wasm_rt_trap(WASM_RT_TRAP_OOB);
			}
	}
	// Not the module's: the client's own crash, its handler's
	struct sigaction *old = sig == SIGSEGV ? &g_old_segv : &g_old_bus;
	if(old->sa_flags & SA_SIGINFO){
		if(old->sa_sigaction){
			old->sa_sigaction(sig, si, ctx);
			return;
		}
	} else if(old->sa_handler == SIG_IGN){
		return;
	} else if(old->sa_handler != SIG_DFL){
		old->sa_handler(sig);
		return;
	}
	// The default: put back, and the fault happens again to it
	signal(sig, SIG_DFL);
}

} // namespace lua_bindings

// The runtime's (wasm-rt-mem-impl.c, built with these names renamed to
// _impl in CMakeLists.txt): what the modules call to make and free their
// memory, with its address range kept for the handler
extern "C" void buildat_wasm_rt_allocate_memory_impl(wasm_rt_memory_t*,
		uint64_t, uint64_t, bool, uint32_t);
extern "C" void buildat_wasm_rt_free_memory_impl(wasm_rt_memory_t*);
extern "C" void wasm_rt_allocate_memory(wasm_rt_memory_t *m,
		uint64_t initial_pages, uint64_t max_pages, bool is64, uint32_t page_size)
{
	buildat_wasm_rt_allocate_memory_impl(m, initial_pages, max_pages, is64,
			page_size);
	for(lua_bindings::Range &r : lua_bindings::g_ranges)
		if(!r.begin){
			r.end = (uintptr_t)m->data_end;
			r.begin = (uintptr_t)m->data;
			return;
		}
	// More memories than instances can have: never, as each has one
	wasm_rt_trap(WASM_RT_TRAP_OOB);
}
extern "C" void wasm_rt_free_memory(wasm_rt_memory_t *m)
{
	for(lua_bindings::Range &r : lua_bindings::g_ranges)
		if(r.begin == (uintptr_t)m->data)
			r.begin = r.end = 0;
	buildat_wasm_rt_free_memory_impl(m);
}

namespace lua_bindings {

static void runtime_init()
{
	static bool done = false;
	if(done)
		return;
	done = true;
	wasm_rt_init();
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_sigaction = wasm_fault_handler;
	sa.sa_flags = SA_SIGINFO;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGSEGV, &sa, &g_old_segv);
	sigaction(SIGBUS, &sa, &g_old_bus);
}


#endif // _WIN32, Linux

// The interpreter's (WAMR's fast interpreter, 3rdparty/wamr) stack: its
// frames and operand cells in one buffer of this size, so the call depth
// is bounded by it (a frame of the toy's recursion takes about 88 bytes:
// about 2000 of them, as the compiled code's 2000). Past it, a trap ("wasm
// operand stack overflow"). The interpreter does not recurse natively for
// a wasm call, so the client's own stack is not at stake.
static const uint32_t INTERP_STACK = 176 << 10;

static void interp_import(wasm_exec_env_t env, uint64_t *args);

// WAMR, once: the system's allocator, wasm_api.h's imports as natives of
// "buildat" (each with its signature, checked against the module's import
// by WAMR as well), its log to errors only. No signal handler is set up:
// the memory's bounds are checked by its code (3rdparty/wamr/CMakeLists.txt).
static bool interp_init()
{
	static int done = 0;
	if(done)
		return done > 0;
	done = -1;
	RuntimeInitArgs args;
	memset(&args, 0, sizeof args);
	args.mem_alloc_type = Alloc_With_System_Allocator;
	if(!wasm_runtime_full_init(&args))
		return false;
	wasm_runtime_set_log_level(WASM_LOG_LEVEL_ERROR);
	static sv_<ss_> sigs(IMP_ALL), names(IMP_ALL);
	static sv_<NativeSymbol> syms(IMP_ALL);
	for(size_t k = 0; k < IMP_ALL; k++){
		sigs[k] = "("+ss_(import_params(k), 'i')+")"+
				(import_result(k) ? "i" : "");
		names[k] = k < IMP_COUNT ? ss_(IMPORTS[k].name) :
				"g"+itos(k - IMP_COUNT);
		syms[k].symbol = names[k].c_str();
		syms[k].func_ptr = (void*)interp_import;
		syms[k].signature = sigs[k].c_str();
		syms[k].attachment = (void*)(uintptr_t)k;
	}
	if(!wasm_runtime_register_natives_raw("buildat", syms.data(),
			(uint32_t)IMP_ALL))
		return false;
	done = 1;
	return true;
}

// The compiler: its path (execv and CreateProcess take one), its first
// --version line, and wasm2c's recommended flags for it. Looked up once.
struct Compiler {
	ss_ path;
	ss_ version;
	ss_ flags;
};
static const Compiler& compiler()
{
	static Compiler c;
	static bool done = false;
	if(done)
		return c;
	done = true;
	ss_ cmd = boot::autodetect::find_compiler_command();
	if(cmd.empty())
		return c;
#ifdef _WIN32
	const ss_ exe = ".exe";
	const char sep = ';';
	const char *slashes = "/\\";
	if(cmd.size() > 4 && upper(cmd.substr(cmd.size() - 4)) == ".EXE")
		cmd.resize(cmd.size() - 4);
#else
	const ss_ exe = "";
	const char sep = ':';
	const char *slashes = "/";
#endif
	if(cmd.find_first_of(slashes) == ss_::npos){
		const char *env = getenv("PATH");
		ss_ path = env ? env : "";
		size_t at = 0;
		while(at <= path.size()){
			size_t end = path.find(sep, at);
			if(end == ss_::npos)
				end = path.size();
			const ss_ p = path.substr(at, end - at)+"/"+cmd;
			if(end > at && is_program(p+exe)){
				cmd = p;
				break;
			}
			at = end + 1;
		}
	}
	if(cmd.find_first_of(slashes) == ss_::npos)
		return c;
	// The C driver beside it: g++ (Fedora's 15) compiles C++ given -x c
	for(const auto &p : sv_<std::pair<ss_, ss_>>{{"clang++", "clang"},
			{"g++", "gcc"}, {"c++", "cc"}, {"c++", "gcc"}}){
		if(cmd.size() >= p.first.size() && cmd.compare(cmd.size() -
				p.first.size(), p.first.size(), p.first) == 0){
			const ss_ c_driver = cmd.substr(0, cmd.size() - p.first.size())+
					p.second;
			if(is_program(c_driver+exe)){
				cmd = c_driver;
				break;
			}
		}
	}
	cmd += exe;
	// The version, for the cache's key
	c.version = compiler_version(cmd);
	if(c.version.empty())
		return c;
	c.path = cmd;
	// wasm2c/README.md: what keeps -O2 conformant (NaN quieting, a
	// recursion trapping), per compiler; nothing that drops a check. And
	// a frame past MAX_FRAME an error (WASM2C_DEFINES above), in each
	// compiler's spelling: clang only warns of gcc's, so an unknown
	// warning option is an error there too
	c.flags = c.version.find("clang") != ss_::npos ?
			"-O2 -fno-optimize-sibling-calls -frounding-math "
			"-Werror=unknown-warning-option -Wframe-larger-than="+
			itos(MAX_FRAME)+" -Werror=frame-larger-than" :
			"-O2 -fno-optimize-sibling-calls -frounding-math -fsignaling-nans "
			"-Werror=frame-larger-than="+itos(MAX_FRAME);
	log_i(MODULE, "Compiler for wasm modules: %s (%s)", cs(c.path),
			cs(c.version));
	return c;
}

// The client's own C around wasm2c's: an instance's size, its binding to
// the client's import function, its making and freeing, its memory, and
// one trapping entry (the runtime's setjmp is in it: on Windows the
// runtime is the DLL's own) that instantiates, runs the start function or
// unpacks numbers for an export by index. Nothing in it comes from the
// module but types.
static ss_ glue_c(const wabt::Module &m, const sv_<ExportSig> &exports,
		bool has_imports, bool has_memory, bool has_start,
		const sv_<GlobalCopy> &globals)
{
	std::ostringstream os;
	os<<"#ifndef _WIN32\n#define _POSIX_C_SOURCE 200809L\n#endif\n" // sigsetjmp
		"#include <string.h>\n#include <stdint.h>\n#include \"m.h\"\n"
		"#include \"wasm-rt-impl.h\"\n#include \"wasm-rt-exceptions.h\"\n"
		"#ifdef _WIN32\n#define BX __declspec(dllexport)\n#else\n"
		"#define BX __attribute__((visibility(\"default\")))\n#endif\n"
		"typedef uint32_t (*imp_t)(void*, uint32_t, const uint32_t*, int*);\n"
		"struct w2c_buildat { void *host; imp_t imp; };\n";
	// wasm_api.h's imports, whether the module has them or not, and the
	// bindings it has (renamed g<k>: check_module()): each hands its
	// numbers to the client's run_import(), and traps here when it says so
	sv_<size_t> which;
	for(size_t k = 0; k < IMP_COUNT; k++)
		which.push_back(k);
	for(const wabt::Import *imp : m.imports){
		const ss_ &n = imp->field_name;
		if(n.size() > 1 && n[0] == 'g' &&
				n.find_first_not_of("0123456789", 1) == ss_::npos)
			which.push_back(IMP_COUNT + (size_t)atoi(n.c_str() + 1));
	}
	for(size_t k : which){
		const int params = import_params(k);
		const bool result = import_result(k);
		os<<(result ? "uint32_t" : "void")<<" w2c_buildat_"<<
				(k < IMP_COUNT ? ss_(IMPORTS[k].name) : "g"+itos(k - IMP_COUNT))<<
				"(struct w2c_buildat *b";
		for(int i = 0; i < params; i++)
			os<<", uint32_t a"<<i;
		os<<"){ uint32_t a["<<MAX_IMPORT_PARAMS<<"] = {";
		for(int i = 0; i < params; i++)
			os<<(i ? ", a" : "a")<<i;
		os<<(params ? "" : "0")<<"}; int t = 0; uint32_t r = b->imp(b->host, "<<
				k<<", a, &t); if(t) wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE); "<<
				(result ? "return r;" : "(void)r;")<<" }\n";
	}
	os<<"typedef struct { w2c_m m; struct w2c_buildat b; } inst_t;\n"
		"static float F(uint64_t v){ uint32_t u = (uint32_t)v; float f; memcpy(&f, &u, 4); return f; }\n"
		"static double D(uint64_t v){ double d; memcpy(&d, &v, 8); return d; }\n"
		"static uint64_t FB(float f){ uint32_t u; memcpy(&u, &f, 4); return u; }\n"
		"static uint64_t DB(double d){ uint64_t u; memcpy(&u, &d, 8); return u; }\n"
		"BX size_t buildat_size(void){ return sizeof(inst_t); }\n"
		"BX void buildat_bind(void *p, void *host, imp_t imp){\n"
		"\tinst_t *i = (inst_t*)p; i->b.host = host; i->b.imp = imp; wasm_rt_init();\n}\n"
		"BX void buildat_free(void *p){ wasm2c_m_free(&((inst_t*)p)->m); }\n"
		"BX wasm_rt_memory_t *buildat_memory(void *p){ return "<<
		(has_memory ? "w2c_m_mem(&((inst_t*)p)->m)" : "0")<<"; }\n"
		"BX uint64_t buildat_grow(void *p, uint64_t pages){\n"
		"\twasm_rt_memory_t *mem = buildat_memory(p);\n"
		"\treturn mem ? wasm_rt_grow_memory(mem, pages) : (uint64_t)-1;\n}\n"
		"BX const char *buildat_strerror(int code){ return wasm_rt_strerror((wasm_rt_trap_t)code); }\n"
		"BX int64_t *buildat_meter(void *p){ return (int64_t*)w2c_m_"<<METER<<
		"(&((inst_t*)p)->m); }\n"
		// The mutable globals, for the move from the interpreter
		"BX void *buildat_global(void *p, uint32_t k){\n"
		"\tw2c_m *m = &((inst_t*)p)->m; (void)m;\n\tswitch(k){\n";
	for(size_t k = 0; k < globals.size(); k++)
		os<<"\tcase "<<k<<": return (void*)w2c_m_"<<globals[k].name<<"(m);\n";
	os<<"\t}\n\treturn 0;\n}\n"
		"static void call(w2c_m *m, uint32_t f, const uint64_t *a, uint64_t *r){\n"
		"\t(void)m; (void)a; (void)r; (void)F; (void)D; (void)FB; (void)DB;\n"
		"\tswitch(f){\n";
	for(size_t i = 0; i < exports.size(); i++){
		const ExportSig &s = exports[i];
		ss_ call = "w2c_m_f"+itos(i)+"(m";
		for(size_t k = 0; k < s.params.size(); k++){
			const ss_ a = "a["+itos(k)+"]";
			switch(s.params[k]){
			case 'i': call += ", (uint32_t)"+a; break;
			case 'I': call += ", "+a; break;
			case 'f': call += ", F("+a+")"; break;
			case 'F': call += ", D("+a+")"; break;
			}
		}
		call += ")";
		os<<"\tcase "<<i<<": ";
		switch(s.result){
		case 0: os<<call<<";"; break;
		case 'i': os<<"r[0] = (uint32_t)"<<call<<";"; break;
		case 'I': os<<"r[0] = "<<call<<";"; break;
		case 'f': os<<"r[0] = FB("<<call<<");"; break;
		case 'F': os<<"r[0] = DB("<<call<<");"; break;
		}
		os<<" break;\n";
	}
	os<<"\t}\n}\n"
		// what: 0 instantiates, 1 calls export f, 2 runs the start function;
		// 0, or the trap's code
		"BX int buildat_try(void *p, int what, uint32_t f, const uint64_t *a, uint64_t *r){\n"
		"\tinst_t *i = (inst_t*)p;\n"
		"\tint code = wasm_rt_impl_try();\n"
		"\tif(code == 0){\n"
		"\t\tif(what == 0) wasm2c_m_instantiate(&i->m"<<
		(has_imports ? ", &i->b" : "")<<");\n"
		"\t\telse if(what == 1) call(&i->m, f, a, r);\n"
		"\t\telse { "<<(has_start ? ss_("w2c_m_")+START+"(&i->m);" :
		ss_(""))<<" }\n"
		"\t}\n\treturn code;\n}\n";
	return os.str();
}

// A compile's cached refusal beside <cache>/wasm2c/<key>: a file of the
// compiler's error lines. It only ever means "do not compile"; what is in
// it is logged, made printable, and nothing else is read from it.
static ss_ refused_path(const ss_ &dir)
{
	return dir+".refused";
}
// A compile of one key ([WASM_COMPILE_RACE]): the loads of the same module
// in this client share it, and each waits on it. It writes into a
// directory of its own and renames that whole into the cache as <key>/
// once the module is built, so that another client compiling the same key
// into the same cache never sees half a directory: whichever renames first
// wins, the other takes the winner's.
struct Compile {
	ss_ name; // the module's, for the log
	ss_ dir; // <cache>/wasm2c/<key>, there once whole
	ss_ tmp; // this compile's own, removed once done
#ifdef _WIN32
	HANDLE process = NULL, job = NULL;
#else
	pid_t pid = 0;
#endif
	std::chrono::steady_clock::time_point started;
	enum State { RUNNING, DONE, FAILED } state = RUNNING;
	ss_ error;
	// The compiler exited with an error, not killed past a limit: the same
	// key fails the same way again ([WASM_STACK_RLIMIT]), and is not
	// compiled again (refused_path())
	bool refused = false;

	void finish_failed(const ss_ &why)
	{
		state = FAILED;
		error = why;
	}

	// The compiler's command line, all the client's, run in tmp with its
	// limits, its output into tmp/compile.log; false with why
	bool start(sv_<ss_> args, ss_ &why)
	{
		started = std::chrono::steady_clock::now();
		const ss_ log_path = tmp+"/compile.log";
#ifdef _WIN32
		SECURITY_ATTRIBUTES sa;
		memset(&sa, 0, sizeof sa);
		sa.nLength = sizeof sa;
		sa.bInheritHandle = TRUE;
		HANDLE log = CreateFileA(log_path.c_str(), GENERIC_WRITE,
				FILE_SHARE_READ, &sa, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
		if(log == INVALID_HANDLE_VALUE){
			why = "could not make "+log_path+": "+last_error();
			return false;
		}
		const bool ok = spawn(args, tmp, log, tmp, process, job, why);
		CloseHandle(log);
		return ok;
#else
		std::vector<char*> argv;
		for(ss_ &a : args)
			argv.push_back(&a[0]);
		argv.push_back(nullptr);
		const pid_t p = fork();
		if(p < 0){
			why = "fork failed";
			return false;
		}
		if(p == 0){
			// The child: async-signal-safe calls only, then the compiler
			setpgid(0, 0);
			prctl(PR_SET_PDEATHSIG, SIGKILL);
			struct rlimit as = {(rlim_t)COMPILE_MEM_BYTES,
					(rlim_t)COMPILE_MEM_BYTES};
			struct rlimit cpu = {(rlim_t)COMPILE_CPU_S, (rlim_t)COMPILE_CPU_S};
			setrlimit(RLIMIT_AS, &as);
			setrlimit(RLIMIT_CPU, &cpu);
			if(chdir(tmp.c_str()) != 0)
				_exit(126);
			const int fd = open(log_path.c_str(), O_WRONLY | O_CREAT | O_TRUNC,
					0600);
			if(fd >= 0){
				dup2(fd, 1);
				dup2(fd, 2);
			}
			const int null = open("/dev/null", O_RDONLY);
			if(null >= 0)
				dup2(null, 0);
			for(int i = 3; i < 1024; i++)
				close(i);
			execv(argv[0], argv.data());
			_exit(127);
		}
		setpgid(p, p);
		pid = p;
		return true;
#endif
	}

	// The child and anything it started, gone
	void kill_child()
	{
#ifdef _WIN32
		if(job)
			TerminateJobObject(job, 1);
		if(process){
			WaitForSingleObject(process, 5000);
			CloseHandle(process);
		}
		if(job)
			CloseHandle(job);
		process = job = NULL;
#else
		if(pid > 0){
			kill(-pid, SIGKILL);
			kill(pid, SIGKILL);
			waitpid(pid, nullptr, 0);
		}
		pid = 0;
#endif
	}

	// 1 while the child runs, 0 once it has succeeded, -1 failed with why
	int child_state(ss_ &why)
	{
#ifdef _WIN32
		if(WaitForSingleObject(process, 0) == WAIT_TIMEOUT)
			return 1;
		DWORD code = 1;
		if(!GetExitCodeProcess(process, &code))
			code = 1;
		kill_child(); // what it started, if anything is left
		if(code != 0){
			refused = code != ERROR_NOT_ENOUGH_QUOTA;
			why = "the compile failed (exit code "+itos((int)code)+
					(code == ERROR_NOT_ENOUGH_QUOTA ? ", past its CPU time limit" :
					"")+"; its log above)";
			return -1;
		}
		return 0;
#else
		int status = 0;
		const pid_t r = waitpid(pid, &status, WNOHANG);
		if(r == 0)
			return 1;
		pid = 0;
		if(r < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0){
			refused = r > 0 && WIFEXITED(status);
			why = WIFSIGNALED(status) ? "the compile was killed (signal "+
					itos(WTERMSIG(status))+"), past its limits?" :
					"the compile failed (its log above)";
			return -1;
		}
		return 0;
#endif
	}

	// The child's progress, read without waiting
	void poll()
	{
		if(state != RUNNING)
			return;
		const int ms = (int)std::chrono::duration_cast<
				std::chrono::milliseconds>(std::chrono::steady_clock::now() -
				started).count();
		ss_ why;
		const int r = child_state(why);
		if(r > 0){
			if(ms > COMPILE_WALL_S * 1000){
				kill_child();
				finish_failed("the compile took over "+itos(COMPILE_WALL_S)+
						" s; killed");
			}
			return;
		}
		if(r < 0){
			std::ifstream f(tmp+"/compile.log");
			ss_ line, errors;
			for(int n = 0; std::getline(f, line) && n < 20; n++){
				log_w(MODULE, "wasm %s: compiler: %s", cs(name), cs(line));
				if(line.find("error") != ss_::npos && errors.size() < 1000)
					errors += line+"\n";
			}
			// The refusal kept by the key, its error lines the reason; put
			// in place whole, as the module is
			if(refused && interface::fs::write_file(tmp+"/refused",
					errors.empty() ? why+"\n" : errors))
				rename((tmp+"/refused").c_str(), refused_path(dir).c_str());
			finish_failed(why);
			return;
		}
		// Into place whole; a directory there already is another client's
		// compile of the same key, as whole
		if(rename(tmp.c_str(), dir.c_str()) == 0)
			tmp.clear();
		if(!is_file(dir+"/"+MODULE_FILE)){
			finish_failed("the compiled module could not be put in "+dir);
			return;
		}
		log_i(MODULE, "wasm %s: compiled in %i ms", cs(name), ms);
		state = DONE;
	}

	~Compile()
	{
		kill_child();
		if(!tmp.empty())
			interface::fs::remove_all(tmp);
	}
};
// The compiles under way in this client, by key
static std::map<ss_, std::weak_ptr<Compile>> g_compiles;

#endif // BUILDAT_WASM_NATIVE

#ifdef __EMSCRIPTEN__
// The module as an instance of its own, from the page's JS: its own
// memory, importing wasm_api.h's functions only, each of which hands its
// numbers to buildat_wasm_import() (run_import(), the C++ both clients
// share) and throws its trap. What crosses is numbers, and bytes copied
// between its memory and the client's heap by the JS here.
EM_JS(int, bw_new, (void), {
	var w = Module.buildatWasm || (Module.buildatWasm = {next: 1, list: {}});
	var id = w.next++;
	w.list[id] = {inst: null, err: ""};
	return id;
});
// names: the imports' names, comma separated, in run_import()'s order
EM_JS(void, bw_load, (int id, const uint8_t *p, int n, int host,
		const char *names), {
	var rec = Module.buildatWasm.list[id];
	try {
		var mod = new WebAssembly.Module(HEAPU8.slice(p, p + n));
		var imports = {buildat: {}};
		UTF8ToString(names).split(",").forEach(function(name, k) {
			imports.buildat[name] = function(a0, a1, a2, a3, a4, a5) {
				var r = _buildat_wasm_import(host, k, a0 | 0, a1 | 0, a2 | 0,
						a3 | 0, a4 | 0, a5 | 0);
				if (r < 0)
					throw new WebAssembly.RuntimeError("buildat." + name +
							": trapped (the client's log says why)");
				return r | 0;
			};
		});
		rec.inst = new WebAssembly.Instance(mod, imports);
	} catch (e) {
		rec.err = String(e).substring(0, 300);
	}
});
EM_JS(char*, bw_take_error, (int id), {
	var rec = Module.buildatWasm.list[id];
	var s = rec.err;
	rec.err = "";
	return s ? stringToNewUTF8(s) : 0;
});
// The memory's size: 0 with none, or while the start function runs (the
// instance is not there yet)
EM_JS(double, bw_memory_size, (int id), {
	var inst = Module.buildatWasm.list[id].inst;
	var mem = inst && inst.exports.memory;
	return mem instanceof WebAssembly.Memory ? mem.buffer.byteLength : 0;
});
// to_module: copy n bytes from the heap at heap to the module's memory at
// ptr, else the other way; the bounds checked here again
EM_JS(int, bw_copy, (int id, double ptr, int heap, int n, int to_module), {
	var inst = Module.buildatWasm.list[id].inst;
	var mem = inst && inst.exports.memory;
	if (!(mem instanceof WebAssembly.Memory) || ptr < 0 || n < 0 ||
			ptr + n > mem.buffer.byteLength) return 1;
	var m = new Uint8Array(mem.buffer, ptr, n);
	if (to_module) m.set(HEAPU8.subarray(heap, heap + n));
	else HEAPU8.set(m, heap);
	return 0;
});
// args: n doubles; types: a char per argument ('i', 'I', 'f', 'F'); the
// result into *out. 0, or 1 with the error in bw_take_error(id).
EM_JS(int, bw_call, (int id, const char *name, const double *args,
		const char *types, int n, double *out), {
	var rec = Module.buildatWasm.list[id];
	var t = UTF8ToString(types);
	var a = [];
	for (var i = 0; i < n; i++) {
		var v = HEAPF64[(args >> 3) + i];
		a.push(t[i] == 'I' ? BigInt(v) : v);
	}
	var sp = stackSave();
	try {
		var r = rec.inst.exports[UTF8ToString(name)].apply(null, a);
		HEAPF64[out >> 3] = r === undefined ? 0 : Number(r);
		return 0;
	} catch (e) {
		// Thrown in the client's own code under an import, the client's
		// stack pointer is where that code left it
		stackRestore(sp);
		rec.err = String(e).substring(0, 300);
		return 1;
	}
});
// An i64 global of meter_module()'s, buildat_meter or buildat_stack: set
// to v if set, and read
EM_JS(double, bw_global, (int id, const char *name, int set, double v), {
	var inst = Module.buildatWasm.list[id].inst;
	var g = inst && inst.exports[UTF8ToString(name)];
	if (!(g instanceof WebAssembly.Global)) return 0;
	if (set) g.value = BigInt(v);
	return Number(g.value);
});
EM_JS(void, bw_free, (int id), {
	delete Module.buildatWasm.list[id];
});
#endif

struct Instance {
	ss_ name;
	sv_<ExportSig> exports;
	enum State { LOADING, READY, FAILED } state = LOADING;
	ss_ error;
#if BUILDAT_WASM_NATIVE
	sp_<Compile> compile; // while it is loading
	bool has_imports = false;
	void *dl = nullptr;
	void *mem = nullptr;
	wasm_rt_memory_t *memory = nullptr;
	FreeFn free_fn = nullptr;
	TryFn try_fn = nullptr;
	GrowFn grow_fn = nullptr;
	StrerrorFn strerror_fn = nullptr;
	int64_t *meter = nullptr; // the module's (meter_module()), the engine's
	// which runs the module: the interpreter (WAMR) until the compiled
	// module is there, or with no compiler, for good
	enum Engine { NONE, INTERP, COMPILED } engine = NONE;
	int64_t *c_meter = nullptr; // the compiled module's
	GlobalFn global_fn = nullptr;
	bool has_memory = false; // exported as "memory"
	sv_<GlobalCopy> globals; // what the move copies (prepare_native())
	// The interpreter's: the bytes (WAMR keeps pointers into them), the
	// module, its instance, the stack it runs on, the exports by index
	ss_ interp_bytes;
	wasm_module_t wm = nullptr;
	wasm_module_inst_t wi = nullptr;
	wasm_exec_env_t we = nullptr;
	wasm_memory_inst_t wmem = nullptr;
	sv_<wasm_function_inst_t> wfuncs;
	wasm_function_inst_t wstart = nullptr;
	int64_t *i_meter = nullptr;
#endif
	bool has_start = false;
	// What the import under way has cost (run_import())
	uint64_t import_cost = 0;
#ifdef __EMSCRIPTEN__
	int web_id = 0;
#endif
	std::chrono::steady_clock::time_point loaded =
			std::chrono::steady_clock::now();
	// A call into the module is running: none other starts
	bool in_call = false;
	// An import refused what the module asked: the call traps with this
	ss_ trap_reason;

	// The handles: a table of the instance's own. A handle is
	// tag << 24 | generation << 10 | slot; the tag is this instance's
	// (another's handle names another tag), the generation the slot's
	// when it was given (one dropped since is stale; a slot whose
	// generation would wrap is not used again).
	// Each holds what Lua handed for it (the sandbox's wrapper, or a Volume)
	// by a reference in the registry, so that the object lives while the
	// module has the handle, as a script's reference keeps it
	// ([CLIENT_WASM_BINDINGS]); OBJECT is any other object of the list.
	struct Slot {
		enum Kind { NONE, NODE, TEXTURE, VOLUME, OBJECT } kind = NONE;
		uint32_t gen = 1;
		int ref = LUA_NOREF;
		Urho3D::WeakPtr<Urho3D::Node> node;
		Urho3D::WeakPtr<Urho3D::Texture2D> texture;
		std::weak_ptr<interface::VoxelVolume> volume;
		uint64_t indices[MAX_GEOMETRIES] = {}; // counted against the caps
		uint64_t texture_bytes = 0;
	};
	static const uint32_t GEN_MAX = (1 << 14) - 1;
	uint32_t tag = 0;
	sv_<Slot> slots;
	uint64_t indices_all = 0, texture_bytes_all = 0;
	// Events Lua queued (m:push), and the packets the call sends
	std::deque<ss_> events;
	size_t event_bytes = 0;
	sv_<std::pair<ss_, ss_>> sent;
	size_t logged = 0; // lines in this call

	void fail(const ss_ &why)
	{
		state = FAILED;
		error = why;
		release_refs();
#if BUILDAT_WASM_NATIVE
		compile.reset();
#endif
		log_w(MODULE, "wasm %s: %s", cs(name), cs(why));
	}

	// The module's dispatcher (m:bind()), a reference in the registry
	int bind_ref = LUA_NOREF;
	// The Lua running the module's call (m:call()), which its bindings'
	// calls are made on; null outside a call
	lua_State *call_L = nullptr;

	// A new handle for an object, or 0 with the table full; ref is taken
	// (released with the handle, or now if there is none)
	uint32_t give(Slot::Kind kind, Urho3D::Node *node, Urho3D::Texture2D *tex,
			const sp_<interface::VoxelVolume> &volume, int ref = LUA_NOREF)
	{
		size_t i = 0;
		while(i < slots.size() && (slots[i].kind != Slot::NONE ||
				slots[i].gen > GEN_MAX))
			i++;
		if(i == slots.size()){
			if(slots.size() >= MAX_HANDLES){
				unref(ref);
				return 0;
			}
			slots.emplace_back();
		}
		Slot &s = slots[i];
		s.kind = kind;
		s.ref = ref;
		s.node = node;
		s.texture = tex;
		s.volume = volume;
		return tag << 24 | s.gen << 10 | (uint32_t)i;
	}

	// The handle's slot, or null with why: a handle not given, one given
	// and dropped, or another module's
	Slot* slot_of(uint32_t h, ss_ &why)
	{
		const uint32_t t = h >> 24, gen = (h >> 10) & GEN_MAX, i = h & 1023;
		if(t != tag){
			why = "handle "+itos(h)+" is not this module's"+
					(t >= 1 && t < 128 ? " (another module's)" : "");
			return nullptr;
		}
		if(i >= slots.size() || gen == 0 || gen > slots[i].gen){
			why = "handle "+itos(h)+" was never given";
			return nullptr;
		}
		Slot &s = slots[i];
		if(gen != s.gen || s.kind == Slot::NONE){
			why = "handle "+itos(h)+" is stale (dropped)";
			return nullptr;
		}
		return &s;
	}

	// m:drop(h): the slot free, its generation on
	bool drop(uint32_t h, ss_ &why)
	{
		Slot *s = slot_of(h, why);
		if(!s)
			return false;
		for(uint64_t n : s->indices)
			indices_all -= n;
		texture_bytes_all -= s->texture_bytes;
		const uint32_t gen = s->gen + 1;
		const int ref = s->ref;
		*s = Slot();
		s->gen = gen;
		unref(ref);
		return true;
	}

	static void unref(int ref)
	{
		if(ref != LUA_NOREF && ref != LUA_REFNIL && g_L)
			luaL_unref(g_L, LUA_REGISTRYINDEX, ref);
	}

	// A stopped or freed module's: what its handles kept alive goes (the
	// handles stay, naming nothing; a stopped module makes no more calls)
	void release_refs()
	{
		for(Slot &s : slots){
			unref(s.ref);
			s.ref = LUA_NOREF;
		}
		unref(bind_ref);
		bind_ref = LUA_NOREF;
	}

#if BUILDAT_WASM_NATIVE
	// The engine's memory: its bytes (null with none), its size
	uint8_t* mem_data()
	{
		if(engine == INTERP)
			return wmem ? (uint8_t*)wasm_memory_get_base_address(wmem) : nullptr;
		return memory ? memory->data : nullptr;
	}
#endif
	uint64_t memory_size()
	{
#if BUILDAT_WASM_NATIVE
		if(engine == INTERP)
			return wmem ? wasm_memory_get_cur_page_count(wmem) *
					(uint64_t)wasm_memory_get_bytes_per_page(wmem) : 0;
		return memory ? memory->size : 0;
#elif defined(__EMSCRIPTEN__)
		return (uint64_t)bw_memory_size(web_id);
#else
		return 0;
#endif
	}

	// A call's budget on the engine running the module
	int64_t budget()
	{
#if BUILDAT_WASM_NATIVE
		return engine == INTERP ? INTERP_BUDGET : BUDGET;
#else
		return BUDGET;
#endif
	}

	// The meter (meter_module()), once the module is instantiated
	int64_t meter_get()
	{
#if BUILDAT_WASM_NATIVE
		return meter ? *meter : 0;
#elif defined(__EMSCRIPTEN__)
		return (int64_t)bw_global(web_id, METER, 0, 0);
#else
		return 0;
#endif
	}
	void meter_set(int64_t v)
	{
#if BUILDAT_WASM_NATIVE
		if(meter)
			*meter = v;
#elif defined(__EMSCRIPTEN__)
		bw_global(web_id, METER, 1, (double)v);
#endif
	}

	// The module's memory at [ptr, ptr+len), checked and copied
	bool copy_in(uint32_t ptr, uint64_t len, void *dst)
	{
		if((uint64_t)ptr + len > memory_size())
			return false;
		if(len == 0)
			return true;
#if BUILDAT_WASM_NATIVE
		memcpy(dst, mem_data() + ptr, len);
		return true;
#elif defined(__EMSCRIPTEN__)
		return bw_copy(web_id, ptr, (int)(intptr_t)dst, (int)len, 0) == 0;
#else
		return false;
#endif
	}
	bool copy_out(uint32_t ptr, const void *src, uint64_t len)
	{
		if((uint64_t)ptr + len > memory_size())
			return false;
		if(len == 0)
			return true;
#if BUILDAT_WASM_NATIVE
		memcpy(mem_data() + ptr, src, len);
		return true;
#elif defined(__EMSCRIPTEN__)
		return bw_copy(web_id, ptr, (int)(intptr_t)src, (int)len, 1) == 0;
#else
		return false;
#endif
	}

	// One import's work (IMPORTS[which], its numbers in a): its result, or
	// trap_reason set. Calls no wasm, Lua only for a binding (in a
	// pcall), and lets no exception out: natively a trap is a longjmp, which must not cross a C++ frame
	// with something to destroy, so the caller traps after this returns.
	uint32_t run_import(uint32_t which, const uint32_t *a)
	{
		try {
			ss_ why;
			import_cost = IMPORT_COST;
			const uint32_t r = import_body(which, a, why);
			if(why.empty()){
				// Its work charged to the call's budget, as the module's
				// own instructions are
				const int64_t left = meter_get() - (int64_t)std::min<uint64_t>(
						import_cost, BUDGET);
				meter_set(left);
				if(left >= 0)
					return r;
				why = "past the call's budget";
			}
			trap_reason = "buildat."+ss_(import_name(which))+": "+why;
		} catch(std::exception &e){
			trap_reason = ss_("an import: ")+e.what();
		} catch(...){
			trap_reason = "an import: an exception";
		}
		log_w(MODULE, "wasm %s: trap: %s", cs(name), cs(trap_reason));
		return 0;
	}

	static bool finite_under(float v, float max)
	{
		return std::isfinite(v) && v <= max && v >= -max;
	}

	// simplified: wasm_api.h's imports make no node or component: Urho3D
	// sends E_NODEADDED and E_COMPONENTADDED to Lua's handlers as they are
	// made, so a module makes them through its bindings (Node:CreateChild,
	// which are Lua calls) or its Lua hands them over.
	// simplified: a geometry's indices are expanded into CustomGeometry's
	// vertex list (it has no index buffer), so the caps count indices; a
	// Model with an IndexBuffer of its own when a mesh's size matters.
	// simplified: a voxel read gives each voxel's first plane (the 32-bit
	// word); a plane argument when a module wants another.
	uint32_t import_body(uint32_t which, const uint32_t *a, ss_ &why)
	{
		using namespace Urho3D;
		static const char *PAST = "past the module's memory";
		switch(which){
		case IMP_LOG: {
			// The whole range is checked; the first MAX_LOG bytes shown
			if((uint64_t)a[0] + a[1] > memory_size()){
				why = PAST;
				return 0;
			}
			uint8_t buf[MAX_LOG];
			const size_t n = std::min<size_t>(a[1], MAX_LOG);
			import_cost += 10000 + n; // a line written out
			if(!copy_in(a[0], n, buf)){
				why = PAST;
				return 0;
			}
			if(++logged <= MAX_LOG_LINES)
				log_i(MODULE, "wasm %s: %s", cs(name), cs(printable(buf, n)));
			else if(logged == MAX_LOG_LINES + 1)
				log_w(MODULE, "wasm %s: more than %zu lines in a call; the "
						"rest of this call's are not written", cs(name),
						MAX_LOG_LINES);
			return 0;
		}
		case IMP_TIME_MS:
			return (uint32_t)std::chrono::duration_cast<
					std::chrono::milliseconds>(
					std::chrono::steady_clock::now() - loaded).count();
		case IMP_VOXELS_SIZE:
		case IMP_VOXELS_READ: {
			Slot *s = slot_of(a[0], why);
			if(!s)
				return 0;
			sp_<interface::VoxelVolume> v = s->volume.lock();
			if(s->kind != Slot::VOLUME || !v){
				why = s->kind != Slot::VOLUME ? "not a volume's handle" :
						"its volume is gone";
				return 0;
			}
			const PolyVox::Region &r = v->getEnclosingRegion();
			const PolyVox::Vector3DInt32 lc = r.getLowerCorner(),
					uc = r.getUpperCorner();
			if(which == IMP_VOXELS_SIZE){
				const int32_t out[6] = {lc.getX(), lc.getY(), lc.getZ(),
						uc.getX() - lc.getX() + 1, uc.getY() - lc.getY() + 1,
						uc.getZ() - lc.getZ() + 1};
				if(!copy_out(a[1], out, sizeof out))
					why = PAST;
				return 0;
			}
			int32_t box[6];
			if(!copy_in(a[1], sizeof box, box)){
				why = PAST;
				return 0;
			}
			for(int k = 3; k < 6; k++)
				if(box[k] < 0 || (uint64_t)box[k] > MAX_VOXELS){
					why = "a box's size is negative or past the cap";
					return 0;
				}
			const uint64_t n = (uint64_t)box[3] * box[4] * box[5];
			if(n > MAX_VOXELS){
				why = "more than "+itos(MAX_VOXELS)+" voxels";
				return 0;
			}
			const int64_t lo[3] = {lc.getX(), lc.getY(), lc.getZ()};
			const int64_t hi[3] = {uc.getX(), uc.getY(), uc.getZ()};
			for(int k = 0; k < 3; k++)
				if(n > 0 && (box[k] < lo[k] ||
						(int64_t)box[k] + box[k + 3] - 1 > hi[k])){
					why = "the box is not inside the volume";
					return 0;
				}
			if(n == 0)
				return 0;
			if(n * 4 > a[3]){
				why = "out has room for "+itos(a[3])+" bytes, not "+
						itos(n * 4);
				return 0;
			}
			if((uint64_t)a[2] + n * 4 > memory_size()){
				why = PAST;
				return 0;
			}
			import_cost += n * 16;
			sv_<uint32_t> out(n);
			size_t i = 0;
			for(int64_t z = box[2]; z < (int64_t)box[2] + box[5]; z++)
			for(int64_t y = box[1]; y < (int64_t)box[1] + box[4]; y++)
			for(int64_t x = box[0]; x < (int64_t)box[0] + box[3]; x++)
				out[i++] = v->getVoxelAt((int32_t)x, (int32_t)y, (int32_t)z).data;
			if(!copy_out(a[2], out.data(), n * 4))
				why = PAST;
			return (uint32_t)n;
		}
		case IMP_GEOMETRY_SET: {
			Slot *s = slot_of(a[0], why);
			if(!s)
				return 0;
			Node *node = s->node.Get();
			if(s->kind != Slot::NODE || !node){
				why = s->kind != Slot::NODE ? "not a node's handle" :
						"its node is gone";
				return 0;
			}
			const uint32_t g = a[1];
			const uint64_t nv = a[3], ni = a[5];
			if(g >= MAX_GEOMETRIES || nv > MAX_INDICES || ni > MAX_INDICES ||
					ni % 3 != 0){
				why = "geometry "+itos(g)+", "+itos(nv)+" vertices, "+
						itos(ni)+" indices: past the caps (geometry < "+
						itos(MAX_GEOMETRIES)+", "+itos(MAX_INDICES)+
						" each), or not triangles";
				return 0;
			}
			if(indices_all - s->indices[g] + ni > MAX_INDICES_ALL){
				why = "past the module's "+itos(MAX_INDICES_ALL)+" indices";
				return 0;
			}
			CustomGeometry *cg = node->GetComponent<CustomGeometry>();
			if(!cg){
				why = "the node has no CustomGeometry (its Lua makes one)";
				return 0;
			}
			import_cost += nv * 12 + ni * 32;
			sv_<float> verts(nv * 12);
			sv_<uint32_t> idx(ni);
			if(!copy_in(a[2], nv * 48, verts.data()) ||
					!copy_in(a[4], ni * 4, idx.data())){
				why = PAST;
				return 0;
			}
			for(float f : verts)
				if(!std::isfinite(f)){
					why = "a vertex value is not finite";
					return 0;
				}
			for(uint32_t k : idx)
				if(k >= nv){
					why = "index "+itos(k)+" is past the "+itos(nv)+
							" vertices";
					return 0;
				}
			if(cg->GetNumGeometries() <= g)
				cg->SetNumGeometries(g + 1);
			cg->BeginGeometry(g, TRIANGLE_LIST);
			for(uint32_t k : idx){
				const float *f = &verts[(size_t)k * 12];
				cg->DefineVertex(Vector3(f[0], f[1], f[2]));
				cg->DefineNormal(Vector3(f[3], f[4], f[5]));
				cg->DefineColor(Color(f[6], f[7], f[8], f[9]));
				cg->DefineTexCoord(Vector2(f[10], f[11]));
			}
			cg->Commit();
			indices_all = indices_all - s->indices[g] + ni;
			s->indices[g] = ni;
			return 0;
		}
		case IMP_TEXTURE_SET: {
			Slot *s = slot_of(a[0], why);
			if(!s)
				return 0;
			Texture2D *tex = s->texture.Get();
			if(s->kind != Slot::TEXTURE || !tex){
				why = s->kind != Slot::TEXTURE ? "not a texture's handle" :
						"its texture is gone";
				return 0;
			}
			const uint32_t w = a[1], h = a[2];
			if(w < 1 || h < 1 || w > MAX_TEXTURE_SIDE || h > MAX_TEXTURE_SIDE){
				why = itos(w)+"x"+itos(h)+" is not 1 to "+
						itos(MAX_TEXTURE_SIDE)+" across";
				return 0;
			}
			const uint64_t bytes = (uint64_t)w * h * 4;
			if(a[4] != bytes){
				why = "len "+itos(a[4])+" is not width * height * 4";
				return 0;
			}
			if(texture_bytes_all - s->texture_bytes + bytes > MAX_TEXTURE_BYTES){
				why = "past the module's "+itos(MAX_TEXTURE_BYTES)+
						" bytes of textures";
				return 0;
			}
			import_cost += bytes * 2;
			// An Image, as the sandbox's Texture2D:SetData(image) takes:
			// Urho3D keeps it for a device reset
			SharedPtr<Image> image(new Image(tex->GetContext()));
			if(!image->SetSize((int)w, (int)h, 4)){
				why = "no image of that size";
				return 0;
			}
			if(!copy_in(a[3], bytes, image->GetData())){
				why = PAST;
				return 0;
			}
			if(!tex->SetData(image, false)){
				why = "the texture took no data";
				return 0;
			}
			texture_bytes_all = texture_bytes_all - s->texture_bytes + bytes;
			s->texture_bytes = bytes;
			return 0;
		}
		case IMP_NODE_GET:
		case IMP_NODE_SET: {
			Slot *s = slot_of(a[0], why);
			if(!s)
				return 0;
			Node *node = s->node.Get();
			if(s->kind != Slot::NODE || !node){
				why = s->kind != Slot::NODE ? "not a node's handle" :
						"its node is gone";
				return 0;
			}
			import_cost += 1000;
			float t[10];
			if(which == IMP_NODE_GET){
				const Vector3 p = node->GetPosition(), sc = node->GetScale();
				const Quaternion q = node->GetRotation();
				const float out[10] = {p.x_, p.y_, p.z_, q.w_, q.x_, q.y_, q.z_,
						sc.x_, sc.y_, sc.z_};
				if(!copy_out(a[1], out, sizeof out))
					why = PAST;
				return 0;
			}
			if(!copy_in(a[1], sizeof t, t)){
				why = PAST;
				return 0;
			}
			for(float f : t)
				if(!finite_under(f, 1e9f)){
					why = "a transform value is not finite, or past 1e9";
					return 0;
				}
			Quaternion q(t[3], t[4], t[5], t[6]);
			if(q.LengthSquared() < 1e-12f){
				why = "a zero rotation";
				return 0;
			}
			q.Normalize();
			node->SetTransform(Vector3(t[0], t[1], t[2]), q,
					Vector3(t[7], t[8], t[9]));
			return 0;
		}
		case IMP_SEND_PACKET: {
			const uint32_t nl = a[1], dl = a[3];
			if(nl < 1 || nl > MAX_PACKET_NAME || dl > MAX_PACKET){
				why = "a name of "+itos(nl)+" bytes or data of "+itos(dl)+
						": past the caps ("+itos(MAX_PACKET_NAME)+", "+
						itos(MAX_PACKET)+")";
				return 0;
			}
			if(sent.size() >= MAX_PACKETS){
				why = "more than "+itos(MAX_PACKETS)+" packets in a call";
				return 0;
			}
			import_cost += nl + dl;
			ss_ pname(nl, '\0'), data(dl, '\0');
			if(!copy_in(a[0], nl, &pname[0]) || !copy_in(a[2], dl, &data[0])){
				why = PAST;
				return 0;
			}
			for(char c : pname)
				if(!isalnum((unsigned char)c) && c != '_'){
					why = "a packet's name is not [A-Za-z0-9_]";
					return 0;
				}
			sent.emplace_back(name+":"+pname, std::move(data));
			return 0;
		}
		case IMP_DROP:
			drop(a[0], why);
			return 0;
		case IMP_EVENT_TAKE: {
			if(events.empty())
				return (uint32_t)-1;
			const ss_ &e = events.front();
			if(e.size() > a[1])
				return (uint32_t)e.size();
			if(!copy_out(a[0], e.data(), e.size())){
				why = PAST;
				return 0;
			}
			const uint32_t n = (uint32_t)e.size();
			import_cost += n;
			event_bytes -= e.size();
			events.pop_front();
			return n;
		}
		}
		if(which >= IMP_COUNT && which < IMP_ALL)
			return binding_import(which - IMP_COUNT, a, why);
		why = "no such import";
		return 0;
	}

	// [CLIENT_WASM_BINDINGS] A binding's call: a[0], a[1] its values, a[2],
	// a[3] the buffer for its results; the results' length
	uint32_t binding_import(size_t k, const uint32_t *a, ss_ &why)
	{
		static const char *PAST = "past the module's memory";
		if(a[1] > MAX_BINDING_BYTES){
			why = "its values are more than "+itos(MAX_BINDING_BYTES)+" bytes";
			return 0;
		}
		if((uint64_t)a[2] + a[3] > memory_size()){
			why = PAST;
			return 0;
		}
		if(!call_L || bind_ref == LUA_NOREF){
			why = call_L ? "no dispatcher (the module runs under no "
					"client_main that binds the calls: \"client_main\": \"wasm\")" :
					"not in a call (the start function makes none)";
			return 0;
		}
		BindingCall c;
		c.in = this;
		c.k = k;
		c.args.resize(a[1]);
		if(!copy_in(a[0], a[1], c.args.empty() ? nullptr : &c.args[0])){
			why = PAST;
			return 0;
		}
		lua_State *L = call_L;
		const int top = lua_gettop(L);
		if(!lua_checkstack(L, 8)){
			why = "the Lua stack is full";
			return 0;
		}
#ifdef __EMSCRIPTEN__
		lua_unwind_save(g_binding_unwind.call, L);
		lua_unwind_save(g_binding_unwind.main, g_L != L ? g_L : nullptr);
		g_binding_unwind.active = true;
#endif
		g_import_depth++;
		lua_pushcfunction(L, binding_lua);
		lua_pushlightuserdata(L, &c);
		const int status = lua_pcall(L, 1, 0, 0);
		g_import_depth--;
#ifdef __EMSCRIPTEN__
		g_binding_unwind.active = false;
#endif
		if(status != 0){
			const char *e = lua_tostring(L, -1);
			why = printable((const uint8_t*)(e ? e : "?"),
					e ? std::min<size_t>(strlen(e), 300) : 1);
			lua_settop(L, top);
			// What it was given in this call goes with it
			for(uint32_t h : c.given){
				ss_ unused;
				drop(h, unused);
			}
			return 0;
		}
		lua_settop(L, top);
		import_cost += BINDING_COST + c.args.size() + c.out.size();
		if(c.out.size() > a[3]){
			for(uint32_t h : c.given){
				ss_ unused;
				drop(h, unused);
			}
			why = "its results are "+itos(c.out.size())+" bytes, past the "
					"buffer's "+itos(a[3]);
			return 0;
		}
		if(!copy_out(a[2], c.out.data(), c.out.size())){
			why = PAST;
			return 0;
		}
		return (uint32_t)c.out.size();
	}

	// One binding call's state, for binding_lua()
	struct BindingCall {
		Instance *in = nullptr;
		size_t k = 0;
		ss_ args, out;
		sv_<uint32_t> given; // handles made for its results
	};

	// Whether the value at idx is a wrapper of the sandbox's (a table whose
	// metatable has the object it wraps), of class cls or one derived from
	// it; the stack as it was
	static bool wrapper_is(lua_State *L, int idx, const char *cls)
	{
		if(lua_type(L, idx) != LUA_TTABLE || !lua_getmetatable(L, idx))
			return false;
		const int mt = lua_gettop(L);
		lua_pushstring(L, "unsafe");
		lua_rawget(L, mt);
		const bool wrapper = !lua_isnil(L, -1);
		lua_settop(L, mt);
		bool found = false;
		// The class's meta, then its parents' (magic_sandbox's wrap_class)
		lua_pushvalue(L, mt);
		for(int depth = 0; wrapper && !found && depth < 32; depth++){
			const int m = lua_gettop(L);
			lua_getfield(L, m, "type_name");
			found = lua_type(L, -1) == LUA_TSTRING &&
					strcmp(lua_tostring(L, -1), cls) == 0;
			lua_pop(L, 1);
			lua_getfield(L, m, "inherited_from_by_wrapper");
			if(lua_isnil(L, -1)){
				lua_pop(L, 1);
				lua_getfield(L, m, "inherited_from_in_sandbox");
			}
			if(lua_isnil(L, -1) || !lua_getmetatable(L, -1))
				break;
			lua_replace(L, m);
			lua_settop(L, m);
		}
		lua_settop(L, mt - 1);
		return found;
	}

	// Run under lua_pcall() by binding_import(): the values decoded and
	// pushed, the dispatcher called, its results encoded. An error is the
	// call's refusal. No C++ object with a destructor is alive across a
	// call that can raise one (natively LuaJIT unwinds, on the web Lua
	// longjmps).
	static int binding_lua(lua_State *L)
	{
		BindingCall &c = *(BindingCall*)lua_touserdata(L, 1);
		Instance *in = c.in;
		const BindingDef &d = BINDINGS[c.k];
		const uint8_t *p = (const uint8_t*)c.args.data();
		const size_t n = c.args.size();
		size_t i = 0;
		char err[200] = "";
		if(n < 1)
			return luaL_error(L, "no values");
		const unsigned int count = p[i++];
		if(count > MAX_BINDING_VALUES)
			return luaL_error(L, "more than %d values", (int)MAX_BINDING_VALUES);
		if(!lua_checkstack(L, (int)count + 16))
			return luaL_error(L, "the Lua stack is full");
		lua_rawgeti(L, LUA_REGISTRYINDEX, in->bind_ref);
		const int fn = lua_gettop(L);
		lua_pushstring(L, d.kind);
		lua_pushstring(L, d.cls);
		lua_pushstring(L, d.member);
		uint32_t first_handle = 0;
		for(unsigned int v = 0; v < count; v++){
			if(i >= n)
				return luaL_error(L, "the values end before the %d said", count);
			const uint8_t tag = p[i++];
			auto need = [&](size_t len){ return n - i >= len; };
			switch(tag){
			case 0: lua_pushnil(L); break;
			case 1: lua_pushboolean(L, 0); break;
			case 2: lua_pushboolean(L, 1); break;
			case 3: {
				if(!need(8))
					return luaL_error(L, "a number past the values' end");
				double x;
				memcpy(&x, p + i, 8);
				i += 8;
				lua_pushnumber(L, x);
				break; }
			case 4: {
				if(!need(4))
					return luaL_error(L, "a string past the values' end");
				uint32_t len;
				memcpy(&len, p + i, 4);
				i += 4;
				if(!need(len))
					return luaL_error(L, "a string past the values' end");
				lua_pushlstring(L, (const char*)p + i, len);
				i += len;
				break; }
			case 5: {
				if(!need(4))
					return luaL_error(L, "a handle past the values' end");
				uint32_t h;
				memcpy(&h, p + i, 4);
				i += 4;
				int ref = LUA_NOREF;
				{
					ss_ why;
					Slot *s = in->slot_of(h, why);
					if(!s)
						snprintf(err, sizeof err, "%s", why.c_str());
					else if(s->ref == LUA_NOREF)
						snprintf(err, sizeof err, "handle %u names nothing "
								"the calls take", (unsigned)h);
					else
						ref = s->ref;
				}
				if(err[0])
					return luaL_error(L, "%s", err);
				if(v == 0)
					first_handle = h;
				lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
				break; }
			case 6: {
				if(!need(1))
					return luaL_error(L, "a value past the values' end");
				const unsigned int kind = p[i++];
				const ValueDef *vd = nullptr;
				for(const ValueDef &x : VALUE_DEFS)
					if(x.kind == kind)
						vd = &x;
				if(!vd)
					return luaL_error(L, "no value of kind %d", (int)kind);
				if(!need(8 * (size_t)vd->n))
					return luaL_error(L, "a value past the values' end");
				// Made by the dispatcher, as a script makes one
				lua_pushvalue(L, fn);
				lua_pushstring(L, "value");
				lua_pushstring(L, vd->cls);
				lua_pushstring(L, "");
				for(int j = 0; j < vd->n; j++){
					double x;
					memcpy(&x, p + i, 8);
					i += 8;
					lua_pushnumber(L, x);
				}
				lua_call(L, 3 + vd->n, 1);
				break; }
			default:
				return luaL_error(L, "a value of kind %d", (int)tag);
			}
		}
		if(i != n)
			return luaL_error(L, "%d bytes after the values", (int)(n - i));
		const bool on_object = !strcmp(d.kind, "call") || !strcmp(d.kind, "get")
				|| !strcmp(d.kind, "set");
		if(on_object && (count < 1 || !wrapper_is(L, fn + 4, d.cls)))
			return luaL_error(L, "not called on a %s", d.cls);
		// A table a call returned, read here: a plain table only (no
		// metatable, so no Lua runs), as a script reads it
		const bool table_get = !strcmp(d.kind, "table_get");
		if(table_get || !strcmp(d.kind, "table_len")){
			if(count != (table_get ? 2u : 1u) || lua_type(L, fn + 4) != LUA_TTABLE ||
					lua_getmetatable(L, fn + 4))
				return luaL_error(L, "not called on a table a call returned");
			if(table_get){
				lua_pushvalue(L, fn + 5);
				lua_rawget(L, fn + 4);
			} else {
				lua_pushnumber(L, (lua_Number)lua_objlen(L, fn + 4));
			}
			lua_replace(L, fn);
			lua_settop(L, fn);
		} else {
			// An object's event names the handle it was subscribed with
			if(!strcmp(d.kind, "subscribe"))
				lua_pushnumber(L, first_handle);
			lua_call(L, lua_gettop(L) - fn, LUA_MULTRET);
		}
		// The results
		const int results = lua_gettop(L) - fn + 1;
		if(results > (int)MAX_BINDING_VALUES)
			return luaL_error(L, "more than %d results", (int)MAX_BINDING_VALUES);
		c.out.assign(1, (char)results);
		for(int r = fn; r < fn + results; r++){
			if(c.out.size() > MAX_BINDING_BYTES)
				return luaL_error(L, "results of more than %d bytes",
						(int)MAX_BINDING_BYTES);
			switch(lua_type(L, r)){
			case LUA_TNIL: c.out += '\0'; break;
			case LUA_TBOOLEAN: c.out += (char)(lua_toboolean(L, r) ? 2 : 1); break;
			case LUA_TNUMBER: {
				const double x = lua_tonumber(L, r);
				char b[9] = {3};
				memcpy(b + 1, &x, 8);
				c.out.append(b, 9);
				break; }
			case LUA_TSTRING: {
				size_t len = 0;
				const char *s = lua_tolstring(L, r, &len);
				if(len > MAX_BINDING_BYTES)
					return luaL_error(L, "a string of more than %d bytes",
							(int)MAX_BINDING_BYTES);
				const uint32_t l32 = (uint32_t)len;
				char b[5] = {4};
				memcpy(b + 1, &l32, 4);
				c.out.append(b, 5);
				c.out.append(s, len);
				break; }
			case LUA_TTABLE: {
				if(!encode_object(L, r, c, err, sizeof err))
					return luaL_error(L, "%s", err);
				break; }
			default:
				return luaL_error(L, "a result of type %s, which the calls do not "
						"carry", lua_typename(L, lua_type(L, r)));
			}
		}
		return 0;
	}

	// A table the dispatcher returned, into c.out: a value by its
	// components, any other object or a plain table as a new handle.
	// false with err.
	static bool encode_object(lua_State *L, int r, BindingCall &c, char *err,
			size_t err_len)
	{
		// A plain table (Octree:GetDrawables(), Skeleton:GetBone()): a
		// handle, read by table_get and table_len
		if(!lua_getmetatable(L, r))
			return give_ref(L, r, c, Slot::OBJECT, nullptr, nullptr, err, err_len);
		const int mt = lua_gettop(L);
		lua_pushstring(L, "unsafe");
		lua_rawget(L, mt);
		const int unsafe = lua_gettop(L);
		if(lua_isnil(L, unsafe)){
			lua_settop(L, mt - 1);
			snprintf(err, err_len, "a table result, which the calls do not carry");
			return false;
		}
		lua_getfield(L, mt, "type_name");
		const char *tn = lua_tostring(L, -1);
		for(const ValueDef &vd : VALUE_DEFS){
			if(!tn || strcmp(tn, vd.cls) != 0)
				continue;
			char b[2] = {6, (char)vd.kind};
			c.out.append(b, 2);
			for(int j = 0; j < vd.n; j++){
				// Read as a script reads it: the property's get
				lua_getfield(L, r, vd.c[j]);
				const double x = lua_tonumber(L, -1);
				lua_pop(L, 1);
				char xb[8];
				memcpy(xb, &x, 8);
				c.out.append(xb, 8);
			}
			lua_settop(L, mt - 1);
			return true;
		}
		tolua_Error te;
		Slot::Kind kind = Slot::OBJECT;
		Urho3D::Node *node = nullptr;
		Urho3D::Texture2D *tex = nullptr;
		if(lua_isuserdata(L, unsafe) && tolua_isusertype(L, unsafe, "Node", 0, &te)){
			kind = Slot::NODE;
			node = (Urho3D::Node*)tolua_tousertype(L, unsafe, 0);
		} else if(lua_isuserdata(L, unsafe) &&
				tolua_isusertype(L, unsafe, "Texture2D", 0, &te)){
			kind = Slot::TEXTURE;
			tex = (Urho3D::Texture2D*)tolua_tousertype(L, unsafe, 0);
		}
		lua_settop(L, mt - 1);
		return give_ref(L, r, c, kind, node, tex, err, err_len);
	}

	// The value at r held by a new handle, into c.out
	static bool give_ref(lua_State *L, int r, BindingCall &c, Slot::Kind kind,
			Urho3D::Node *node, Urho3D::Texture2D *tex, char *err, size_t err_len)
	{
		lua_pushvalue(L, r);
		const int ref = luaL_ref(L, LUA_REGISTRYINDEX);
		const uint32_t h = c.in->give(kind, node, tex, nullptr, ref);
		if(!h){
			snprintf(err, err_len, "more than %d handles", (int)MAX_HANDLES);
			return false;
		}
		c.given.push_back(h);
		char b[5] = {5};
		memcpy(b + 1, &h, 4);
		c.out.append(b, 5);
		return true;
	}

	// Instantiated, its start function run: ready, or with trap (the start
	// function's) failed, stopped if it ran past its budget
	void started_or_failed(const ss_ &trap)
	{
		if(trap.empty()){
			state = READY;
			return;
		}
		if(meter_get() < 0)
			fail("stopped: its start function ran past its budget of "+
					itos(budget())+" (a loop that does not end?)");
		else
			fail("trap at start: "+trap);
	}

#if BUILDAT_WASM_NATIVE
	// wasm2c's import functions (the glue) call this. A refused import
	// traps in the glue, once this has returned (*trap set): nothing of
	// C++'s is left to destroy between there and buildat_try()'s setjmp.
	static uint32_t host_import(void *host, uint32_t which, const uint32_t *a,
			int *trap)
	{
		Instance *self = (Instance*)host;
		g_in_wasm = 0;
		const uint32_t r = self->run_import(which, a);
		g_in_wasm = 1;
		*trap = !self->trap_reason.empty();
		return r;
	}

	// The compiled module's call with a trap caught (the glue's
	// buildat_try()): 0, or the trap's code. what: 0 instantiates, 1 calls
	// export f, 2 the start function, those two with its meter at BUDGET.
	static int trapping(Instance *in, int what, uint32_t f, const uint64_t *a,
			uint64_t *r)
	{
		if(what != 0)
			*in->c_meter = BUDGET;
		g_in_wasm = 1;
		const int code = in->try_fn(in->mem, what, f, a, r);
		g_in_wasm = 0;
		return code;
	}

	// A trap's code as the runtime says it
	ss_ trap_text(int code)
	{
		const char *t = strerror_fn ? strerror_fn(code) : nullptr;
		return t ? ss_(t) : "trap "+itos(code);
	}

	// The compiled module loaded and instantiated (its data segments
	// written), its start function not run: true, or false with why
	bool open_compiled(const ss_ &so, ss_ &why)
	{
		dl = lib_open(so, why);
		if(!dl)
			return false;
		free_fn = (FreeFn)lib_sym(dl, "buildat_free");
		try_fn = (TryFn)lib_sym(dl, "buildat_try");
		grow_fn = (GrowFn)lib_sym(dl, "buildat_grow");
		strerror_fn = (StrerrorFn)lib_sym(dl, "buildat_strerror");
		global_fn = (GlobalFn)lib_sym(dl, "buildat_global");
		SizeFn size_fn = (SizeFn)lib_sym(dl, "buildat_size");
		BindFn bind_fn = (BindFn)lib_sym(dl, "buildat_bind");
		MemoryFn memory_fn = (MemoryFn)lib_sym(dl, "buildat_memory");
		MeterFn meter_fn = (MeterFn)lib_sym(dl, "buildat_meter");
		if(!free_fn || !try_fn || !grow_fn || !strerror_fn || !global_fn ||
				!size_fn || !bind_fn || !memory_fn || !meter_fn){
			why = "the built module lacks its entry points";
			return false;
		}
#ifndef _WIN32
		runtime_init();
#endif
		mem = calloc(1, size_fn());
		if(!mem){
			why = "out of memory";
			return false;
		}
		bind_fn(mem, this, host_import);
		const int code = trapping(this, 0, 0, nullptr, nullptr);
		memory = memory_fn(mem);
		c_meter = meter_fn(mem);
		if(code != 0){
			why = "instantiation: "+(trap_reason.empty() ? trap_text(code) :
					trap_reason);
			return false;
		}
		return true;
	}

	void close_compiled()
	{
		if(mem){
			if(free_fn)
				free_fn(mem);
			free(mem);
		}
		if(dl)
			lib_close(dl);
		mem = nullptr;
		dl = nullptr;
		memory = nullptr;
		c_meter = nullptr;
	}

	// The compiled module as the engine from the start (no interpreter ran
	// it): its start function run
	void ready_from(const ss_ &so)
	{
		ss_ why;
		if(!open_compiled(so, why)){
			fail(why);
			return;
		}
		engine = COMPILED;
		meter = c_meter;
		if(has_start){
			const int code = trapping(this, 2, 0, nullptr, nullptr);
			if(code != 0){
				started_or_failed(trap_reason.empty() ? trap_text(code) :
						trap_reason);
				return;
			}
		}
		started_or_failed("");
		if(state == READY)
			log_i(MODULE, "wasm %s: ready (compiled)", cs(name));
	}

	// WAMR's imports (interp_init()): the instance from the module
	// instance's custom data, which import from the attachment
	static void interp_native(wasm_exec_env_t env, uint64_t *args)
	{
		wasm_module_inst_t wi = wasm_runtime_get_module_inst(env);
		Instance *self = (Instance*)wasm_runtime_get_custom_data(wi);
		const uintptr_t which = (uintptr_t)wasm_runtime_get_function_attachment(
				env);
		if(!self || which >= IMP_ALL){
			wasm_runtime_set_exception(wi, "an import with no instance");
			return;
		}
		uint32_t a[MAX_IMPORT_PARAMS] = {};
		for(int i = 0; i < import_params(which); i++)
			a[i] = (uint32_t)args[i];
		const uint32_t r = self->run_import((uint32_t)which, a);
		// The interpreter checks for this after the native returns, and
		// unwinds; l_call() reports trap_reason
		if(!self->trap_reason.empty()){
			wasm_runtime_set_exception(wi, "an import trapped");
			return;
		}
		if(import_result(which))
			*(uint32_t*)args = r;
	}

	// The interpreter's call: "" or the trap. f is the export's index, or
	// ~0 for the start function; the meter at BUDGET before.
	ss_ interp_call(uint32_t f, const uint64_t *a, uint64_t *r)
	{
		*i_meter = INTERP_BUDGET;
		wasm_val_t args[MAX_PARAMS], res[1];
		memset(args, 0, sizeof args);
		memset(res, 0, sizeof res);
		wasm_function_inst_t fn = wstart;
		uint32_t nargs = 0, nres = 0;
		if(f != ~0u){
			const ExportSig &s = exports[f];
			fn = wfuncs[f];
			nargs = (uint32_t)s.params.size();
			nres = s.result ? 1 : 0;
			for(uint32_t k = 0; k < nargs; k++){
				switch(s.params[k]){
				case 'i': args[k].kind = WASM_I32; args[k].of.i32 = (int32_t)a[k]; break;
				case 'I': args[k].kind = WASM_I64; args[k].of.i64 = (int64_t)a[k]; break;
				case 'f': {
					args[k].kind = WASM_F32;
					const uint32_t u = (uint32_t)a[k];
					memcpy(&args[k].of.f32, &u, 4);
					break;
				}
				case 'F':
					args[k].kind = WASM_F64;
					memcpy(&args[k].of.f64, &a[k], 8);
					break;
				}
			}
		}
		if(wasm_runtime_call_wasm_a(we, fn, nres, res, nargs, args)){
			if(nres && r){
				switch(res[0].kind){
				case WASM_I32: *r = (uint32_t)res[0].of.i32; break;
				case WASM_I64: *r = (uint64_t)res[0].of.i64; break;
				case WASM_F32: { uint32_t u; memcpy(&u, &res[0].of.f32, 4); *r = u; } break;
				case WASM_F64: memcpy(r, &res[0].of.f64, 8); break;
				default: break;
				}
			}
			return "";
		}
		const char *e = wasm_runtime_get_exception(wi);
		ss_ trap = e ? e : "?";
		if(trap.compare(0, 11, "Exception: ") == 0)
			trap = trap.substr(11);
		wasm_runtime_clear_exception(wi);
		return trap.empty() ? ss_("?") :
				printable((const uint8_t*)trap.data(), trap.size());
	}

	// The module in the interpreter, its start function run: true (READY,
	// or FAILED by its start function), or false with why (WAMR refused it)
	bool start_interp(ss_ &why)
	{
		if(!interp_init()){
			why = "the interpreter could not be set up";
			return false;
		}
		char err[200] = "";
		// WAMR's loader validates it again, and may write into the bytes
		wm = wasm_runtime_load((uint8_t*)&interp_bytes[0],
				(uint32_t)interp_bytes.size(), err, sizeof err);
		if(wm)
			wi = wasm_runtime_instantiate(wm, INTERP_STACK, 0, err, sizeof err);
		if(wi){
			wasm_runtime_set_custom_data(wi, this);
			we = wasm_runtime_create_exec_env(wi, INTERP_STACK);
		}
		if(!we){
			why = "the interpreter refused it: "+printable((const uint8_t*)err,
					strnlen(err, sizeof err));
			close_interp();
			return false;
		}
		for(size_t i = 0; i < exports.size(); i++){
			wfuncs.push_back(wasm_runtime_lookup_function(wi,
					("f"+itos(i)).c_str()));
			if(!wfuncs.back())
				why = "the interpreter does not find an export";
		}
		if(has_start && !(wstart = wasm_runtime_lookup_function(wi, START)))
			why = "the interpreter does not find the start function";
		wasm_global_inst_t g;
		if(wasm_runtime_get_export_global_inst(wi, METER, &g) &&
				g.kind == WASM_I64 && g.is_mutable)
			i_meter = (int64_t*)g.global_data;
		else
			why = "the interpreter does not find the meter";
		if(has_memory && !(wmem = wasm_runtime_get_default_memory(wi)))
			why = "the interpreter does not find the memory";
		if(!why.empty()){
			close_interp();
			return false;
		}
		engine = INTERP;
		meter = i_meter;
		ss_ trap;
		if(has_start){
			in_call = true;
			trap_reason.clear();
			trap = interp_call(~0u, nullptr, nullptr);
			in_call = false;
			if(!trap_reason.empty())
				trap = trap_reason;
		}
		started_or_failed(trap);
		return true;
	}

	void close_interp()
	{
		if(we)
			wasm_runtime_destroy_exec_env(we);
		if(wi)
			wasm_runtime_deinstantiate(wi);
		if(wm)
			wasm_runtime_unload(wm);
		we = nullptr;
		wi = nullptr;
		wm = nullptr;
		wmem = nullptr;
		wfuncs.clear();
		wstart = nullptr;
		i_meter = nullptr;
		if(engine == INTERP){
			engine = NONE;
			meter = nullptr;
		}
	}

	// From the interpreter to the compiled module, between two calls: its
	// memory, mutable globals and meter copied. A failure leaves it in the
	// interpreter.
	void move_to(const ss_ &so)
	{
		ss_ why;
		bool ok = open_compiled(so, why);
		const uint64_t bytes = memory_size();
		if(ok && has_memory){
			if(!memory || memory->page_size != 65536 || bytes % 65536 != 0){
				ok = false;
				why = "the memories do not match";
			} else if(bytes / 65536 > memory->pages &&
					grow_fn(mem, bytes / 65536 - memory->pages) ==
					(uint64_t)-1){
				ok = false;
				why = "the compiled module's memory could not grow to "+
						itos(bytes)+" bytes";
			} else if(memory->size != bytes){
				ok = false;
				why = "the memories' sizes do not match";
			}
		}
		for(size_t k = 0; ok && k < globals.size(); k++){
			wasm_global_inst_t g;
			void *to = global_fn(mem, (uint32_t)k);
			if(!to || !wasm_runtime_get_export_global_inst(wi,
					globals[k].name.c_str(), &g)){
				ok = false;
				why = "a global is not found in both";
			}
		}
		if(!ok){
			close_compiled();
			log_w(MODULE, "wasm %s: stays in the interpreter: %s", cs(name),
					cs(why));
			return;
		}
		if(bytes > 0)
			memcpy(memory->data, mem_data(), bytes);
		for(size_t k = 0; k < globals.size(); k++){
			wasm_global_inst_t g;
			wasm_runtime_get_export_global_inst(wi, globals[k].name.c_str(), &g);
			memcpy(global_fn(mem, (uint32_t)k), g.global_data, globals[k].size);
		}
		close_interp();
		engine = COMPILED;
		meter = c_meter;
		log_i(MODULE, "wasm %s: moved to the compiled module (%llu bytes of "
				"memory and %zu globals copied); ready (compiled)", cs(name),
				(unsigned long long)bytes, globals.size());
	}

	// The compile failed or could not start: the module stays in the
	// interpreter if it runs there, else fails
	void compile_failed(const ss_ &why)
	{
		compile.reset();
		if(engine != INTERP){
			fail(why);
			return;
		}
		log_w(MODULE, "wasm %s: %s; it stays in the interpreter", cs(name),
				cs(why));
	}

	// The compile's progress, read without waiting; between calls only
	void poll()
	{
		if(!compile || state == FAILED || in_call)
			return;
		compile->poll();
		if(compile->state == Compile::RUNNING)
			return;
		const sp_<Compile> c = std::move(compile);
		if(c->state == Compile::FAILED){
			compile_failed(c->error);
			return;
		}
		if(engine == INTERP)
			move_to(c->dir+"/"+MODULE_FILE);
		else
			ready_from(c->dir+"/"+MODULE_FILE);
	}

	// For checks only: the compiler hidden, as on a player-only archive,
	// so that the interpreter runs the module for good
	static bool compiler_hidden()
	{
		const char *e = getenv("BUILDAT_CHECK_WASM_INTERPRETER");
		return e && *e && strcmp(e, "0") != 0;
	}

	// Not to be compiled, for the reason given: the interpreter for good,
	// or failed
	void interp_for_good(const ss_ &reason)
	{
		ss_ why;
		if(start_interp(why)){
			if(state == READY)
				log_w(MODULE, "wasm %s: ready (interpreter): not compiled, as %s",
						cs(name), cs(reason));
			return;
		}
		fail("not compiled, as "+reason+", and "+why);
	}

	// m is the module checked, metered and prepared (prepare_native()), its
	// bytes as written from it in interp_bytes
	void start_native(wabt::Module &m, const ss_ &hash_hex)
	{
		static const Compiler none;
		const Compiler &cc = compiler_hidden() ? none : compiler();
		has_imports = !m.imports.empty();
		ss_ why;
#ifndef _WIN32
		// Too small a stack for the compiled code's depth limit (a small
		// ulimit -s): the interpreter, whose stack is its own. On Windows
		// the calls run on the main thread, linked at 8 MiB (CMakeLists.txt).
		static const size_t left = stack_left();
		if(left < STACK_NEEDED){
			interp_for_good("the stack has "+itos((int)(left >> 10))+
					" KiB left and the compiled code's call depth needs "+
					itos((int)(STACK_NEEDED >> 10))+" (ulimit -s)");
			return;
		}
#endif
		if(cc.path.empty()){
			if(start_interp(why)){
				if(state == READY)
					log_i(MODULE, "wasm %s: ready (interpreter): no C compiler "
							"to build it with%s", cs(name), compiler_hidden() ?
							" (hidden for a check)" : "");
				return;
			}
			fail("no C compiler to build it with (the server's lookup: "
					"compiler/bin/c++, then c++ in PATH), and "+why);
			return;
		}
		const ss_ key = interface::sha1::hex(interface::sha1::calculate(
				hash_hex+"\n"+WABT_VERSION_STRING+"\n"+GLUE_VERSION+"\n"+
				bindings_hash()+"\n"+
				cc.path+"\n"+cc.version+"\n"+cc.flags+"\n"+WASM2C_DEFINES));
		// The cache, the user's alone; else no compiled module at all
		const ss_ root = g_client_config.get<ss_>("cache_path")+"/wasm2c";
		interface::fs::create_directories(g_client_config.get<ss_>(
				"cache_path"));
		if(!private_dir(root, why)){
			ss_ why2;
			if(start_interp(why2)){
				if(state == READY)
					log_w(MODULE, "wasm %s: ready (interpreter): not compiled, "
							"as %s", cs(name), cs(why));
				return;
			}
			fail("not compiled, as "+why+", and "+why2);
			return;
		}
		const ss_ dir = root+"/"+key.substr(0, 32);
		if(is_file(dir+"/"+MODULE_FILE)){
			log_i(MODULE, "wasm %s: compiled module from the cache (%s)",
					cs(name), cs(key.substr(0, 12)));
			ready_from(dir+"/"+MODULE_FILE);
			return;
		}
		// Refused by an earlier compile of the same key: not compiled again
		std::ifstream refused(refused_path(dir));
		if(refused.good()){
			ss_ line;
			for(int n = 0; n < 5 && std::getline(refused, line); n++)
				log_w(MODULE, "wasm %s: compiler (cached): %s", cs(name),
						cs(printable((const uint8_t*)line.data(), line.size())));
			interp_for_good("its compile was refused before (cached, "+
					key.substr(0, 12)+")");
			return;
		}
		// Not in the cache: the interpreter runs it while it compiles
		if(!movable(m, has_memory)){
			log_i(MODULE, "wasm %s: its state could not move to the compiled "
					"module; it waits on its compile", cs(name));
		} else if(start_interp(why)){
			if(state != READY)
				return; // its start function failed
			log_i(MODULE, "wasm %s: ready (interpreter) while it compiles",
					cs(name));
		} else {
			log_w(MODULE, "wasm %s: %s; it waits on its compile", cs(name),
					cs(why));
		}
		// The same key compiling in this client: wait on it
		for(auto it = g_compiles.begin(); it != g_compiles.end();)
			it = it->second.expired() ? g_compiles.erase(it) : std::next(it);
		auto running = g_compiles.find(key);
		if(running != g_compiles.end()){
			compile = running->second.lock();
			log_i(MODULE, "wasm %s: waiting on its compile under way (%s)",
					cs(name), cs(key.substr(0, 12)));
			return;
		}
		// This compile's own directory (in the private root)
		ss_ tmpl = root+"/"+key.substr(0, 32)+".XXXXXX";
#ifdef _WIN32
		bool made = false;
		for(unsigned i = 0; i < 100 && !made; i++){
			tmpl = root+"/"+key.substr(0, 32)+"."+itos((int)GetCurrentProcessId())+
					"."+itos((int)((GetTickCount() + i) & 0xffffff));
			made = CreateDirectoryA(tmpl.c_str(), NULL) != 0;
		}
#else
		const bool made = mkdtemp(&tmpl[0]) != nullptr;
#endif
		if(!made){
			compile_failed("could not make a directory in "+root);
			return;
		}
		compile.reset(new Compile());
		compile->name = name;
		compile->dir = dir;
		compile->tmp = tmpl;
		const ss_ &tmp = compile->tmp;
		if(wabt::Failed(wabt::GenerateNames(&m))){
			compile_failed("wasm2c could not name its functions");
			return;
		}
		// As wasm2c's own main: a name that cannot be applied is skipped
		(void)wabt::ApplyNames(&m);
		wabt::MemoryStream c_stream, h_stream;
		wabt::WriteCOptions wo;
		wo.module_name = "m";
		std::vector<wabt::Stream*> c_streams = {&c_stream};
		if(wabt::Failed(wabt::WriteC(std::move(c_streams), &h_stream,
				&c_stream, "m.h", "", &m, wo))){
			compile_failed("wasm2c could not translate it");
			return;
		}
		const auto &cb = c_stream.output_buffer().data;
		const auto &hb = h_stream.output_buffer().data;
		bool written = interface::fs::write_file(tmp+"/m.c",
				ss_(cb.begin(), cb.end())) &&
				interface::fs::write_file(tmp+"/m.h", ss_(hb.begin(), hb.end())) &&
				interface::fs::write_file(tmp+"/glue.c",
				glue_c(m, exports, has_imports, has_memory, has_start, globals));
		for(const char *const *f = buildat_wasm_rt_files; *f; f += 2)
			written = written && interface::fs::write_file(tmp+"/"+f[0], f[1]);
		if(!written){
			compile_failed("could not write into "+tmp);
			return;
		}
		// The command line is the client's: its compiler, its flags, file
		// names it chose. On Windows the runtime goes into the DLL, which
		// is linked whole (-static: no MinGW DLL of the client's needed)
#ifdef _WIN32
		sv_<ss_> args = {cc.path, "-x", "c", "-std=c11", "-shared", "-static",
				"-I."};
#else
		sv_<ss_> args = {cc.path, "-x", "c", "-std=c11", "-fPIC", "-shared",
				"-fvisibility=hidden", "-I."};
#endif
		for(const char *flags : {cc.flags.c_str(), WASM2C_DEFINES}){
			std::istringstream is(flags);
			ss_ w;
			while(is >> w)
				args.push_back(w);
		}
		for(const char *a : {"-o", MODULE_FILE, "m.c", "glue.c"})
			args.push_back(a);
#ifdef _WIN32
		for(const char *a : {"wasm-rt-impl.c", "wasm-rt-mem-impl.c",
				"wasm-rt-exceptions-impl.c"})
			args.push_back(a);
#endif
		if(!compile->start(args, why)){
			compile_failed(why);
			return;
		}
		g_compiles[key] = compile;
#ifdef _WIN32
		const int pid = (int)GetProcessId(compile->process);
#else
		const int pid = (int)compile->pid;
#endif
		log_i(MODULE, "wasm %s: compiling (pid %i, %s)", cs(name), pid,
				cs(key.substr(0, 12)));
	}
#endif

	~Instance()
	{
#if BUILDAT_WASM_NATIVE
		compile.reset(); // killed if no other load waits on it
		close_interp();
		close_compiled();
#endif
#ifdef __EMSCRIPTEN__
		if(web_id)
			bw_free(web_id);
#endif
		release_refs();
		g_tag_used[tag] = false;
		g_instance_count--;
	}

#ifdef __EMSCRIPTEN__
	// The browser's error of a call that failed, or the stack counter's
	// trap ([WASM_WEB_CALL_DEPTH])
	ss_ take_error()
	{
		char *s = bw_take_error(web_id);
		ss_ r = s ? s : "?";
		free(s);
		if(bw_global(web_id, STACK, 0, 0) > WEB_STACK_LIMIT)
			return "call stack exhausted (past the web client's "+
					itos((int)(WEB_STACK_LIMIT >> 10))+" KiB of frames, estimated)";
		return r;
	}
#endif
};

#if BUILDAT_WASM_NATIVE
static void interp_import(wasm_exec_env_t env, uint64_t *args)
{
	Instance::interp_native(env, args);
}
#endif

#ifdef __EMSCRIPTEN__
// The module's imports, from bw_load()'s JS: the result, or -1 for a trap
// (run_import() logged why, and the JS throws)
extern "C" EMSCRIPTEN_KEEPALIVE double buildat_wasm_import(int host, int which,
		int a0, int a1, int a2, int a3, int a4, int a5)
{
	Instance *in = (Instance*)(intptr_t)host;
	const uint32_t a[MAX_IMPORT_PARAMS] = {(uint32_t)a0, (uint32_t)a1,
			(uint32_t)a2, (uint32_t)a3, (uint32_t)a4, (uint32_t)a5};
	const uint32_t r = in->run_import((uint32_t)which, a);
	return in->trap_reason.empty() ? (double)r : -1.0;
}
#endif

static const char *META = "buildat.wasm_module";

// The errors, as exceptions: guarded<> turns one into a Lua error with its
// message
[[noreturn]] static void raise(const char *fmt, ...)
{
	char buf[400];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof buf, fmt, ap);
	va_end(ap);
	throw Exception(buf);
}

static double number(lua_State *L, int i)
{
	if(lua_type(L, i) != LUA_TNUMBER)
		raise("wasm: argument %d is not a number", i - 1);
	return lua_tonumber(L, i);
}

static Instance* check_instance(lua_State *L)
{
	Instance **p = (Instance**)lua_touserdata(L, 1);
	bool ours = false;
	if(p && lua_getmetatable(L, 1)){
		luaL_getmetatable(L, META);
		ours = lua_rawequal(L, -1, -2);
		lua_pop(L, 2);
	}
	if(!ours)
		raise("wasm: not a module (m:call(...), not m.call(...))");
	if(!*p)
		raise("wasm: a freed module");
	return *p;
}

// __buildat_wasm_load(name, bytes) -> module or nil, why
static int l_wasm_load(lua_State *L)
{
	const ss_ name = lua_checkcppstring(L, 1).substr(0, 64);
	const ss_ bytes = lua_checkcppstring(L, 2);
	// Its start function would run inside the import
	if(g_import_depth > 0)
		raise("wasm: loaded from inside a module's call to the client");
	if(g_instance_count >= MAX_INSTANCES){
		lua_pushnil(L);
		lua_pushstring(L, "too many wasm modules loaded");
		return 2;
	}
	wabt::Module m;
	sv_<ExportSig> exports;
	bool has_imports = false;
	ss_ why;
	if(!check_module(bytes, m, exports, has_imports, why)){
		log_w(MODULE, "wasm %s: refused: %s", cs(name), cs(why));
		lua_pushnil(L);
		lua_pushstring(L, ("refused: "+why).c_str());
		return 2;
	}
	bool has_start = false;
	if(!meter_module(m, has_start, why)){
		log_w(MODULE, "wasm %s: refused: %s", cs(name), cs(why));
		lua_pushnil(L);
		lua_pushstring(L, ("refused: "+why).c_str());
		return 2;
	}
	const ss_ hash = interface::sha1::hex(interface::sha1::calculate(bytes));
	log_i(MODULE, "wasm %s: %zu bytes, %zu exports, valid (%s)", cs(name),
			bytes.size(), exports.size(), cs(hash.substr(0, 12)));
	Instance *in = new Instance();
	in->has_start = has_start;
	g_instance_count++;
	// A tag no live instance has: MAX_INSTANCES is below 127
	for(uint32_t t = 1; t < 128 && !in->tag; t++)
		if(!g_tag_used[t])
			in->tag = t;
	g_tag_used[in->tag] = true;
	in->name = name;
	in->exports = exports;
	Instance **ud = (Instance**)lua_newuserdata(L, sizeof(Instance*));
	*ud = in;
	luaL_getmetatable(L, META);
	lua_setmetatable(L, -2);
	// For checks only: the module failed as on a platform with no wasm
	// (macOS), so a game's way without it is driven
	if(const char *e = getenv("BUILDAT_CHECK_WASM_OFF")){
		if(*e && strcmp(e, "0") != 0){
			in->fail("wasm modules do not run on this platform yet (hidden for "
					"a check)");
			return 1;
		}
	}
#if BUILDAT_WASM_NATIVE
	// The bytes the interpreter runs, written from the module wasm2c
	// translates: the same, metered and prepared
	prepare_native(m, in->has_memory, in->globals);
	wabt::MemoryStream prepared;
	if(wabt::Failed(wabt::WriteBinaryModule(&prepared, &m,
			wabt::WriteBinaryOptions(features(), true, false, false)))){
		in->fail("the metered module could not be written");
		return 1;
	}
	in->interp_bytes.assign(prepared.output_buffer().data.begin(),
			prepared.output_buffer().data.end());
	in->start_native(m, hash);
#elif defined(__EMSCRIPTEN__)
	ss_ names;
	for(const ImportDef &d : IMPORTS)
		names += ss_(names.empty() ? "" : ",")+d.name;
	for(size_t k = 0; k < BINDING_COUNT; k++)
		names += ",g"+itos(k);
	// The metered module is what the browser instantiates
	wabt::MemoryStream metered;
	if(wabt::Failed(wabt::WriteBinaryModule(&metered, &m,
			wabt::WriteBinaryOptions(features(), true, false, false)))){
		in->fail("the metered module could not be written");
		return 1;
	}
	const auto &mb = metered.output_buffer().data;
	in->web_id = bw_new();
	bw_load(in->web_id, mb.data(), (int)mb.size(), (int)(intptr_t)in,
			names.c_str());
	char *err = bw_take_error(in->web_id);
	if(err){
		in->fail(ss_("the browser: ")+err);
		free(err);
		return 1;
	}
	ss_ trap;
	if(has_start){
		double unused = 0;
		in->meter_set(BUDGET);
		bw_global(in->web_id, STACK, 1, 0);
		in->trap_reason.clear();
		in->in_call = true;
		if(bw_call(in->web_id, START, nullptr, "", 0, &unused) != 0)
			trap = in->take_error();
		in->in_call = false;
		if(!in->trap_reason.empty())
			trap = in->trap_reason;
	}
	in->started_or_failed(trap);
	if(in->state == Instance::READY)
		log_i(MODULE, "wasm %s: ready (the browser's instance)", cs(name));
#else
	in->fail("wasm modules do not run on this platform yet");
#endif
	return 1;
}

// m:status() -> "loading" | "ready", engine | "failed", why; the engine
// "compiled", "interpreter, compiling" (moved to the compiled module
// between two calls once its compile is done), "interpreter" (for good)
// or "browser"
static int l_status(lua_State *L)
{
	Instance *in = check_instance(L);
#if BUILDAT_WASM_NATIVE
	in->poll();
#endif
	lua_pushstring(L, in->state == Instance::LOADING ? "loading" :
			in->state == Instance::READY ? "ready" : "failed");
	if(in->state == Instance::FAILED){
		lua_pushstring(L, in->error.c_str());
		return 2;
	}
	if(in->state == Instance::READY){
#if BUILDAT_WASM_NATIVE
		lua_pushstring(L, in->engine == Instance::COMPILED ? "compiled" :
				in->compile ? "interpreter, compiling" : "interpreter");
#else
		lua_pushstring(L, "browser");
#endif
		return 2;
	}
	return 1;
}

static Instance* ready_instance(lua_State *L)
{
	Instance *in = check_instance(L);
#if BUILDAT_WASM_NATIVE
	in->poll();
#endif
	if(in->state != Instance::READY)
		raise("wasm %s: not ready (%s)", in->name.c_str(),
				in->state == Instance::LOADING ? "loading" : in->error.c_str());
	return in;
}

// m:call(export, numbers...) -> its result, or nothing; a trap is an error
static int l_call(lua_State *L)
{
	Instance *in = ready_instance(L);
	const ss_ fname = lua_checkcppstring(L, 2);
	size_t index = 0;
	while(index < in->exports.size() && in->exports[index].name != fname)
		index++;
	if(index == in->exports.size())
		raise("wasm %s: no export \"%s\"", in->name.c_str(),
				fname.substr(0, 64).c_str());
	const ExportSig &sig = in->exports[index];
	const int n = lua_gettop(L) - 2;
	if(n != (int)sig.params.size())
		raise("wasm %s: %s takes %d numbers, given %d",
				in->name.c_str(), fname.c_str(), (int)sig.params.size(), n);
	uint64_t args[MAX_PARAMS] = {0};
	double plain[MAX_PARAMS] = {0};
	for(int k = 0; k < n; k++){
		const double v = number(L, 3 + k);
		const char t = sig.params[k];
		if((t == 'i' || t == 'I') && (!std::isfinite(v) || v != std::floor(v) ||
				(t == 'i' && (v < -2147483648.0 || v > 4294967295.0)) ||
				(t == 'I' && (v < -9223372036854775808.0 ||
						v >= 18446744073709551616.0))))
			raise("wasm %s: %s: argument %d is not a %s",
					in->name.c_str(), fname.c_str(), k + 1,
					t == 'i' ? "32-bit integer" : "64-bit integer");
		plain[k] = v;
		if(t == 'i')
			args[k] = (uint32_t)(int64_t)v;
		else if(t == 'I')
			args[k] = v < 0 ? (uint64_t)(int64_t)v : (uint64_t)v;
		else if(t == 'f'){
			const float f = (float)v;
			uint32_t u;
			memcpy(&u, &f, 4);
			args[k] = u;
		} else {
			memcpy(&args[k], &v, 8);
		}
	}
	(void)plain;
	if(in->in_call)
		raise("wasm %s: called from inside its own call", in->name.c_str());
	if(g_import_depth > 0)
		raise("wasm %s: called from inside a module's call to the client",
				in->name.c_str());
	in->in_call = true;
	in->call_L = L;
	in->trap_reason.clear();
	in->sent.clear();
	in->logged = 0;
	double result = 0;
	ss_ trap;
#if BUILDAT_WASM_NATIVE
	uint64_t r = 0;
	if(in->engine == Instance::INTERP){
		trap = in->interp_call((uint32_t)index, args, &r);
	} else {
		const int code = Instance::trapping(in, 1, (uint32_t)index, args, &r);
		if(code != 0)
			trap = in->trap_text(code);
	}
	switch(sig.result){
	case 'i': result = (int32_t)(uint32_t)r; break;
	case 'I': result = (double)(int64_t)r; break;
	case 'f': { uint32_t u = (uint32_t)r; float f; memcpy(&f, &u, 4); result = f; } break;
	case 'F': memcpy(&result, &r, 8); break;
	}
#elif defined(__EMSCRIPTEN__)
	in->meter_set(BUDGET);
	bw_global(in->web_id, STACK, 1, 0);
	if(bw_call(in->web_id, sig.name.c_str(), plain, sig.params.c_str(),
			n, &result) != 0)
		trap = in->take_error();
	// A binding's Lua unwound by the browser (above): the Lua states put
	// back first, as nothing on L can run before; the module stopped, as
	// the client's work for it may be anywhere
	if(g_binding_unwind.active){
		g_binding_unwind.active = false;
		lua_unwind_restore(g_binding_unwind.call);
		lua_unwind_restore(g_binding_unwind.main);
		g_import_depth = 0;
		in->in_call = false;
		in->call_L = nullptr;
		in->sent.clear();
		in->fail("stopped: "+fname+": the stack ran out inside the client "
				"during a binding ("+trap+")");
		raise("wasm %s: %s: stopped: the stack ran out in a binding",
				in->name.c_str(), fname.c_str());
	}
#endif
	in->in_call = false;
	in->call_L = nullptr;
	if(!in->trap_reason.empty())
		trap = in->trap_reason;
	if(!trap.empty()){
		// What a call that trapped sent is dropped with it
		in->sent.clear();
		in->logged = 0;
		// Past its budget: the module is stopped, as it may be anywhere
		// in its work, and its calls refused from now on
		if(in->meter_get() < 0){
			in->fail("stopped: "+fname+" ran past its budget of "+
					itos(in->budget())+" (a loop that does not end?)");
			raise("wasm %s: %s: stopped: past its budget", in->name.c_str(),
					fname.c_str());
		}
		raise("wasm %s: %s: trap: %s", in->name.c_str(), fname.c_str(),
				trap.c_str());
	}
	// The packets it sent, now that it has returned: through
	// buildat.send_packet, as Lua's (a serverless app's go nowhere)
	sv_<std::pair<ss_, ss_>> sent;
	sent.swap(in->sent);
	for(const auto &p : sent){
		lua_getglobal(L, "buildat");
		lua_getfield(L, -1, "send_packet");
		lua_remove(L, -2);
		lua_pushlstring(L, p.first.data(), p.first.size());
		lua_pushlstring(L, p.second.data(), p.second.size());
		if(lua_pcall(L, 2, 0, 0) != 0){
			log_w(MODULE, "wasm %s: sending %s: %s", cs(in->name),
					cs(p.first), lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_pop(L, 1);
		}
	}
	if(!sig.result)
		return 0;
	lua_pushnumber(L, result);
	return 1;
}

// __buildat_wasm_handle(m, object, safe) -> a handle the module can use
// for the object: a Node, a Texture2D (tolua's, unwrapped by api.lua), a
// buildat.Volume, or another of the sandbox's objects for the bindings
// ([CLIENT_WASM_BINDINGS]); safe is what the script handed (the wrapper),
// which the handle keeps, and the bindings' calls are made on
static int l_handle(lua_State *L)
{
	Instance *in = check_instance(L);
	if(in->state == Instance::FAILED)
		raise("wasm %s: stopped", in->name.c_str());
	tolua_Error err;
	uint32_t h = 0;
	lua_pushvalue(L, lua_isnoneornil(L, 3) ? 2 : 3);
	const int ref = luaL_ref(L, LUA_REGISTRYINDEX);
	bool wrapper = false;
	if(lua_type(L, 3) == LUA_TTABLE && lua_getmetatable(L, 3)){
		lua_pushstring(L, "unsafe");
		lua_rawget(L, -2);
		wrapper = !lua_isnil(L, -1);
		lua_pop(L, 2);
	}
	if(lua_isuserdata(L, 2) && tolua_isusertype(L, 2, "Node", 0, &err)){
		h = in->give(Instance::Slot::NODE,
				(Urho3D::Node*)tolua_tousertype(L, 2, 0), nullptr, nullptr, ref);
	} else if(lua_isuserdata(L, 2) &&
			tolua_isusertype(L, 2, "Texture2D", 0, &err)){
		h = in->give(Instance::Slot::TEXTURE, nullptr,
				(Urho3D::Texture2D*)tolua_tousertype(L, 2, 0), nullptr, ref);
	} else if(wrapper){
		h = in->give(Instance::Slot::OBJECT, nullptr, nullptr, nullptr, ref);
	} else {
		sp_<interface::VoxelVolume> v;
		if(lua_isuserdata(L, 2)){
			luabind::object o(luabind::from_stack(L, 2));
			try {
				v = luabind::object_cast<sp_<interface::VoxelVolume>>(o);
			} catch(luabind::cast_failed&){
			}
		}
		if(!v){
			Instance::unref(ref);
			raise("wasm %s: handle(object): an object of the sandbox's or a "
					"Volume", in->name.c_str());
		}
		h = in->give(Instance::Slot::VOLUME, nullptr, nullptr, v, ref);
	}
	if(!h)
		raise("wasm %s: more than %d handles", in->name.c_str(),
				(int)MAX_HANDLES);
	lua_pushnumber(L, h);
	return 1;
}

static uint32_t handle_arg(lua_State *L, int i)
{
	const double v = number(L, i);
	if(!(v >= 0 && v <= 4294967295.0 && v == std::floor(v)))
		raise("wasm: not a handle");
	return (uint32_t)v;
}

// m:drop(handle): the module's handle no longer names the object
static int l_drop(lua_State *L)
{
	Instance *in = check_instance(L);
	ss_ why;
	if(!in->drop(handle_arg(L, 2), why))
		raise("wasm %s: drop: %s", in->name.c_str(), why.c_str());
	return 0;
}

// m:bind(f): the module's dispatcher ([CLIENT_WASM_BINDINGS]), through
// which its calls of buildat_client.h are made: f(kind, class, member,
// values...) -> results, in the module's sandbox (the default
// client_main's)
static int l_bind(lua_State *L)
{
	Instance *in = check_instance(L);
	if(lua_type(L, 2) != LUA_TFUNCTION)
		raise("wasm: bind(f): f is not a function");
	if(in->state == Instance::FAILED)
		raise("wasm %s: stopped", in->name.c_str());
	lua_pushvalue(L, 2);
	const int ref = luaL_ref(L, LUA_REGISTRYINDEX);
	Instance::unref(in->bind_ref);
	in->bind_ref = ref;
	return 0;
}

// m:push(bytes): an event queued for the module (buildat_event_take())
static int l_push(lua_State *L)
{
	Instance *in = check_instance(L);
	if(lua_type(L, 2) != LUA_TSTRING)
		raise("wasm: push(bytes): bytes is not a string");
	size_t len = 0;
	const char *p = lua_tolstring(L, 2, &len);
	if(in->events.size() >= MAX_EVENTS ||
			in->event_bytes + len > MAX_EVENT_BYTES)
		raise("wasm %s: its event queue is full (%d events, %d bytes)",
				in->name.c_str(), (int)MAX_EVENTS, (int)MAX_EVENT_BYTES);
	in->events.emplace_back(p, len);
	in->event_bytes += len;
	return 0;
}

// The module's memory at [ptr, ptr+len), checked against its size now
static void check_range(lua_State *L, Instance *in, double ptr, double len)
{
	if(!(ptr >= 0) || !(len >= 0) || ptr != std::floor(ptr) ||
			len != std::floor(len) || ptr + len > (double)in->memory_size())
		raise("wasm %s: %.0f bytes at %.0f are past its memory (%.0f)",
				in->name.c_str(), len, ptr, (double)in->memory_size());
}

// m:read(ptr, len) -> the bytes there, copied
static int l_read(lua_State *L)
{
	Instance *in = ready_instance(L);
	const double ptr = number(L, 2), len = number(L, 3);
	check_range(L, in, ptr, len);
	ss_ out((size_t)len, '\0');
#if BUILDAT_WASM_NATIVE
	if(len > 0)
		memcpy(&out[0], in->mem_data() + (size_t)ptr, (size_t)len);
#elif defined(__EMSCRIPTEN__)
	if(len > 0 && bw_copy(in->web_id, ptr, (int)(intptr_t)&out[0], (int)len, 0))
		raise("wasm %s: read past its memory", in->name.c_str());
#endif
	lua_pushlstring(L, out.data(), out.size());
	return 1;
}

// m:write(ptr, bytes): the bytes copied into its memory at ptr
static int l_write(lua_State *L)
{
	Instance *in = ready_instance(L);
	const double ptr = number(L, 2);
	size_t len = 0;
	if(lua_type(L, 3) != LUA_TSTRING)
		raise("wasm: write(ptr, bytes): bytes is not a string");
	const char *bytes = lua_tolstring(L, 3, &len);
	check_range(L, in, ptr, (double)len);
#if BUILDAT_WASM_NATIVE
	if(len > 0)
		memcpy(in->mem_data() + (size_t)ptr, bytes, len);
#elif defined(__EMSCRIPTEN__)
	if(len > 0 && bw_copy(in->web_id, ptr, (int)(intptr_t)bytes, (int)len, 1))
		raise("wasm %s: write past its memory", in->name.c_str());
#endif
	return 0;
}

static int l_gc(lua_State *L)
{
	Instance **p = (Instance**)luaL_checkudata(L, 1, META);
	delete *p;
	*p = nullptr;
	return 0;
}

void init_wasm(lua_State *L)
{
	g_L = L;
	luaL_newmetatable(L, META);
	// Hidden from the sandbox's code, which has no getmetatable anyway
	lua_pushboolean(L, 0);
	lua_setfield(L, -2, "__metatable");
	lua_pushcfunction(L, l_gc);
	lua_setfield(L, -2, "__gc");
	lua_newtable(L);
	lua_pushcfunction(L, guarded<l_status>);
	lua_setfield(L, -2, "status");
	lua_pushcfunction(L, guarded<l_call>);
	lua_setfield(L, -2, "call");
	lua_pushcfunction(L, guarded<l_read>);
	lua_setfield(L, -2, "read");
	lua_pushcfunction(L, guarded<l_write>);
	lua_setfield(L, -2, "write");
	lua_pushcfunction(L, guarded<l_drop>);
	lua_setfield(L, -2, "drop");
	lua_pushcfunction(L, guarded<l_push>);
	lua_setfield(L, -2, "push");
	lua_pushcfunction(L, guarded<l_bind>);
	lua_setfield(L, -2, "bind");
	// m:handle(object) is api.lua's, which unwraps a sandboxed object
	lua_pushvalue(L, -1);
	lua_setglobal(L, "__buildat_wasm_methods");
	lua_setfield(L, -2, "__index");
	lua_pop(L, 1);
	lua_pushcfunction(L, guarded<l_handle>);
	lua_setglobal(L, "__buildat_wasm_handle");
	lua_pushcfunction(L, guarded<l_wasm_load>);
	lua_setglobal(L, "__buildat_wasm_load");
}
#endif // BUILDAT_WASM_FUZZ

} // namespace lua_bindings

#if defined(__EMSCRIPTEN__) && !defined(BUILDAT_WASM_FUZZ)
// Last in the file: Lua's internal headers define short macros. PUC Lua
// 5.1, which the web client runs, built as C++ as this file is.
#include <lstate.h>
#include <ldo.h>
#include <lfunc.h>
namespace lua_bindings {
// What luaD_pcall() keeps and puts back on an error
static void lua_unwind_save(LuaUnwind &u, lua_State *L)
{
	u.L = L;
	if(!L)
		return;
	u.top = savestack(L, L->top);
	u.ci = saveci(L, L->ci);
	u.errfunc = L->errfunc;
	u.error_jmp = L->errorJmp;
	u.n_ccalls = L->nCcalls;
	u.allowhook = L->allowhook;
}
static void lua_unwind_restore(const LuaUnwind &u)
{
	lua_State *L = u.L;
	if(!L)
		return;
	StkId oldtop = restorestack(L, u.top);
	luaF_close(L, oldtop);
	L->top = oldtop;
	L->nCcalls = u.n_ccalls;
	L->ci = restoreci(L, u.ci);
	L->base = L->ci->base;
	L->savedpc = L->ci->savedpc;
	L->allowhook = u.allowhook;
	L->errfunc = u.errfunc;
	L->errorJmp = (struct lua_longjmp*)u.error_jmp;
	// ldo.c's restore_stack_limit()
	if(L->size_ci > LUAI_MAXCALLS){
		int inuse = (int)(L->ci - L->base_ci);
		if(inuse + 1 < LUAI_MAXCALLS)
			luaD_reallocCI(L, LUAI_MAXCALLS);
	}
}
} // namespace lua_bindings
#endif
// vim: set noet ts=4 sw=4:

