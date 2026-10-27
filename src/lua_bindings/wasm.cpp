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
// table of the instance's own, and calls neither Lua nor wasm.
//
// simplified: the native build is Linux's (fork, rlimits, guard pages, a
// signal handler); Windows refuses a module until the compile has a job
// object and the traps a vectored handler.
#include "lua_bindings/util.h"
#include "core/log.h"
#include "interface/sha1.h"
#include "interface/voxel_volume.h"
#include <tolua++.h>
#include <luabind/luabind.hpp>
#include <Node.h>
#include <CustomGeometry.h>
#include <Texture2D.h>
#include <Image.h>
#include "wabt/binary-reader-ir.h"
#include "wabt/binary-reader.h"
#include "wabt/binary-writer.h"
#include "wabt/stream.h"
#include "wabt/validator.h"
#include "wabt/ir.h"
#include "wabt/cast.h"
#if defined(__linux__) && !defined(__EMSCRIPTEN__)
#define BUILDAT_WASM_NATIVE 1
#include "wabt/generate-names.h"
#include "wabt/apply-names.h"
#include "wabt/c-writer.h"
#include "client/config.h"
#include "boot/autodetect.h"
#include "interface/fs.h"
#include "wasm-rt-impl.h"
#include "wasm-rt-exceptions.h"
#include "wasm_export.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fstream>
#include <sstream>
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

#if BUILDAT_WASM_NATIVE
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
	IMP_EVENT_TAKE, IMP_COUNT
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
};
static const int MAX_IMPORT_PARAMS = 6;

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
	// Exactly wasm_api.h's imports, by name and signature, each once
	has_imports = false;
	bool seen[IMP_COUNT] = {};
	for(const wabt::Import *imp : m.imports){
		const wabt::FuncImport *fi = wabt::dyn_cast<wabt::FuncImport>(imp);
		int k = 0;
		while(k < IMP_COUNT && imp->field_name != IMPORTS[k].name)
			k++;
		bool ok = fi && imp->module_name == "buildat" && k < IMP_COUNT &&
				!seen[k];
		if(ok){
			const wabt::FuncSignature &s = fi->func.decl.sig;
			ok = (int)s.param_types.size() == IMPORTS[k].params &&
					s.result_types.size() == (IMPORTS[k].result ? 1u : 0u);
			for(wabt::Type t : s.param_types)
				ok = ok && t == wabt::Type::I32;
			for(wabt::Type t : s.result_types)
				ok = ok && t == wabt::Type::I32;
		}
		if(!ok){
			why = "imports \""+imp->module_name.substr(0, 32)+"."+
					imp->field_name.substr(0, 32)+"\", which is not one of "
					"wasm_api.h's with its signature";
			// Printable only: the names are the server's
			why = printable((const uint8_t*)why.data(), why.size());
			return false;
		}
		seen[k] = true;
		has_imports = true;
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

struct Meter {
	wabt::Index global;
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

struct Instance;
static size_t g_instance_count = 0;
// The live instances' handle tags (1 to 127)
static bool g_tag_used[128] = {};

#if BUILDAT_WASM_NATIVE

// The C wasm2c makes is built with these, and the runtime linked into the
// client with the first two (CMakeLists.txt): the runtime's own signal
// handler off, as this file's chains to the client's crash handler; the
// call depth counted, so a deep recursion is a trap, not a native stack
// overflow. 2000 frames of wasm2c's C fit the main thread's 8 MiB.
static const char *WASM2C_DEFINES = "-DWASM_RT_SKIP_SIGNAL_RECOVERY=1 "
		"-DWASM_RT_STACK_DEPTH_COUNT=1 -DWASM_RT_MAX_CALL_STACK_DEPTH=2000";
// The time and memory a compile may take before it is killed
static const int COMPILE_WALL_S = 180;
static const rlim_t COMPILE_CPU_S = 120;
static const rlim_t COMPILE_AS_BYTES = (rlim_t)2 << 30;
// Bumped when the C this writes changes (the glue, or what meter_module()
// adds), so that the cache is not reused
static const char *GLUE_VERSION = "buildat-wasm2c-glue 5";

extern "C" const char buildat_wasm_rt_h[];

// What a built module exports to the client (the glue below)
typedef size_t (*SizeFn)(void);
typedef uint32_t (*ImportFn)(void*, uint32_t, const uint32_t*);
typedef void (*InstantiateFn)(void*, void*, ImportFn);
typedef void (*FreeFn)(void*);
typedef wasm_rt_memory_t* (*MemoryFn)(void*);
typedef void (*CallFn)(void*, uint32_t, const uint64_t*, uint64_t*);
typedef int64_t* (*MeterFn)(void*);
typedef void (*StartFn)(void*);
typedef void* (*GlobalFn)(void*, uint32_t);

// The memories of the live instances, for the signal handler: a fault in
// one, while a call is in wasm, is the module's out-of-bounds access.
// Kept by the runtime's own allocation (below), so that a memory is known
// from the moment it exists, a start function's access included.
struct Range { uintptr_t begin, end; };
static Range g_ranges[MAX_INSTANCES];
static volatile sig_atomic_t g_in_wasm = 0;
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
	static ss_ sigs[IMP_COUNT];
	static NativeSymbol syms[IMP_COUNT];
	for(int k = 0; k < IMP_COUNT; k++){
		sigs[k] = "("+ss_(IMPORTS[k].params, 'i')+")"+
				(IMPORTS[k].result ? "i" : "");
		syms[k].symbol = IMPORTS[k].name;
		syms[k].func_ptr = (void*)interp_import;
		syms[k].signature = sigs[k].c_str();
		syms[k].attachment = (void*)(uintptr_t)k;
	}
	if(!wasm_runtime_register_natives_raw("buildat", syms, IMP_COUNT))
		return false;
	done = 1;
	return true;
}

// The compiler: its path (execv takes one), its first --version line,
// and wasm2c's recommended flags for it. Looked up once.
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
	if(cmd.find('/') == ss_::npos){
		const char *env = getenv("PATH");
		ss_ path = env ? env : "";
		size_t at = 0;
		while(at <= path.size()){
			size_t end = path.find(':', at);
			if(end == ss_::npos)
				end = path.size();
			const ss_ p = path.substr(at, end - at)+"/"+cmd;
			if(end > at && access(p.c_str(), X_OK) == 0){
				cmd = p;
				break;
			}
			at = end + 1;
		}
	}
	if(cmd.find('/') == ss_::npos)
		return c;
	// The C driver beside it: g++ (Fedora's 15) compiles C++ given -x c
	for(const auto &p : sv_<std::pair<ss_, ss_>>{{"clang++", "clang"},
			{"g++", "gcc"}, {"c++", "cc"}}){
		if(cmd.size() >= p.first.size() && cmd.compare(cmd.size() -
				p.first.size(), p.first.size(), p.first) == 0){
			const ss_ c_driver = cmd.substr(0, cmd.size() - p.first.size())+
					p.second;
			if(access(c_driver.c_str(), X_OK) == 0)
				cmd = c_driver;
			break;
		}
	}
	// The version, for the cache's key
	FILE *f = popen(("'"+cmd+"' --version 2>/dev/null").c_str(), "r");
	char line[256] = "";
	if(f){
		if(!fgets(line, sizeof line, f))
			line[0] = 0;
		pclose(f);
	}
	c.version = line;
	while(!c.version.empty() && (c.version.back() == '\n' ||
			c.version.back() == '\r'))
		c.version.pop_back();
	if(c.version.empty())
		return c;
	c.path = cmd;
	// wasm2c/README.md: what keeps -O2 conformant (NaN quieting, a
	// recursion trapping), per compiler; nothing that drops a check
	c.flags = c.version.find("clang") != ss_::npos ?
			"-O2 -fno-optimize-sibling-calls -frounding-math" :
			"-O2 -fno-optimize-sibling-calls -frounding-math -fsignaling-nans";
	log_i(MODULE, "Compiler for wasm modules: %s (%s)", cs(c.path),
			cs(c.version));
	return c;
}

// The client's own C around wasm2c's: an instance's size, its making and
// freeing, its memory, and one call entry that unpacks numbers for each
// export by index. Nothing in it comes from the module but types.
static ss_ glue_c(const sv_<ExportSig> &exports, bool has_imports,
		bool has_memory, bool has_start, const sv_<GlobalCopy> &globals)
{
	std::ostringstream os;
	os<<"#include <string.h>\n#include <stdint.h>\n#include \"m.h\"\n"
		"#define BX __attribute__((visibility(\"default\")))\n"
		"struct w2c_buildat { void *host; uint32_t (*imp)(void*, uint32_t, const uint32_t*); };\n";
	// Every import, whether the module has it or not: each hands its
	// numbers to the client's run_import()
	for(int k = 0; k < IMP_COUNT; k++){
		const ImportDef &d = IMPORTS[k];
		os<<(d.result ? "uint32_t" : "void")<<" w2c_buildat_"<<d.name<<
				"(struct w2c_buildat *b";
		for(int i = 0; i < d.params; i++)
			os<<", uint32_t a"<<i;
		os<<"){ uint32_t a["<<MAX_IMPORT_PARAMS<<"] = {";
		for(int i = 0; i < d.params; i++)
			os<<(i ? ", a" : "a")<<i;
		os<<(d.params ? "" : "0")<<"}; "<<(d.result ? "return " : "")<<"b->imp(b->host, "<<k<<", a); }\n";
	}
	os<<"typedef struct { w2c_m m; struct w2c_buildat b; } inst_t;\n"
		"static float F(uint64_t v){ uint32_t u = (uint32_t)v; float f; memcpy(&f, &u, 4); return f; }\n"
		"static double D(uint64_t v){ double d; memcpy(&d, &v, 8); return d; }\n"
		"static uint64_t FB(float f){ uint32_t u; memcpy(&u, &f, 4); return u; }\n"
		"static uint64_t DB(double d){ uint64_t u; memcpy(&u, &d, 8); return u; }\n"
		"BX size_t buildat_size(void){ return sizeof(inst_t); }\n"
		"BX void buildat_instantiate(void *p, void *host, uint32_t (*imp)(void*, uint32_t, const uint32_t*)){\n"
		"\tinst_t *i = (inst_t*)p; i->b.host = host; i->b.imp = imp;\n"
		"\twasm2c_m_instantiate(&i->m"<<(has_imports ? ", &i->b" : "")<<");\n}\n"
		"BX void buildat_free(void *p){ wasm2c_m_free(&((inst_t*)p)->m); }\n"
		"BX wasm_rt_memory_t *buildat_memory(void *p){ return "<<
		(has_memory ? "w2c_m_mem(&((inst_t*)p)->m)" : "0")<<"; }\n"
		"BX int64_t *buildat_meter(void *p){ return (int64_t*)w2c_m_"<<METER<<
		"(&((inst_t*)p)->m); }\n"
		"BX void buildat_start(void *p){ "<<(has_start ? ss_("w2c_m_")+START+
		"(&((inst_t*)p)->m);" : ss_("(void)p;"))<<" }\n"
		// The mutable globals, for the move from the interpreter
		"BX void *buildat_global(void *p, uint32_t k){\n"
		"\tw2c_m *m = &((inst_t*)p)->m; (void)m;\n\tswitch(k){\n";
	for(size_t k = 0; k < globals.size(); k++)
		os<<"\tcase "<<k<<": return (void*)w2c_m_"<<globals[k].name<<"(m);\n";
	os<<"\t}\n\treturn 0;\n}\n"
		"BX void buildat_call(void *p, uint32_t f, const uint64_t *a, uint64_t *r){\n"
		"\tw2c_m *m = &((inst_t*)p)->m;\n\t(void)a; (void)r; (void)F; (void)D; (void)FB; (void)DB;\n"
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
	os<<"\t}\n}\n";
	return os.str();
}

// A compile of one key ([WASM_COMPILE_RACE]): the loads of the same module
// in this client share it, and each waits on it. It writes into a
// directory of its own (mkdtemp) and renames that whole into the cache
// as <key>/ once the .so is built, so that another client compiling the
// same key into the same cache never sees half a directory: whichever
// renames first wins, the other takes the winner's.
struct Compile {
	ss_ name; // the module's, for the log
	ss_ dir; // <cache>/wasm2c/<key>, there once whole
	ss_ tmp; // this compile's own, removed once done
	pid_t pid = 0;
	std::chrono::steady_clock::time_point started;
	enum State { RUNNING, DONE, FAILED } state = RUNNING;
	ss_ error;

	void finish_failed(const ss_ &why)
	{
		state = FAILED;
		error = why;
	}

	// The child's progress, read without waiting
	void poll()
	{
		if(state != RUNNING)
			return;
		int status = 0;
		const pid_t r = waitpid(pid, &status, WNOHANG);
		const int ms = (int)std::chrono::duration_cast<
				std::chrono::milliseconds>(std::chrono::steady_clock::now() -
				started).count();
		if(r == 0){
			if(ms > COMPILE_WALL_S * 1000){
				kill(-pid, SIGKILL);
				kill(pid, SIGKILL);
				waitpid(pid, nullptr, 0);
				pid = 0;
				finish_failed("the compile took over "+itos(COMPILE_WALL_S)+
						" s; killed");
			}
			return;
		}
		pid = 0;
		if(r < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0){
			std::ifstream f(tmp+"/compile.log");
			ss_ line;
			for(int n = 0; std::getline(f, line) && n < 20; n++)
				log_w(MODULE, "wasm %s: compiler: %s", cs(name), cs(line));
			finish_failed(WIFSIGNALED(status) ? "the compile was killed "
					"(signal "+itos(WTERMSIG(status))+"), past its limits?" :
					"the compile failed (its log above)");
			return;
		}
		// Into place whole; a directory there already is another client's
		// compile of the same key, as whole
		if(rename(tmp.c_str(), dir.c_str()) == 0)
			tmp.clear();
		if(access((dir+"/module.so").c_str(), R_OK) != 0){
			finish_failed("the compiled module could not be put in "+dir);
			return;
		}
		log_i(MODULE, "wasm %s: compiled in %i ms", cs(name), ms);
		state = DONE;
	}

	~Compile()
	{
		if(pid > 0){
			kill(-pid, SIGKILL);
			kill(pid, SIGKILL);
			waitpid(pid, nullptr, 0);
		}
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
	try {
		var r = rec.inst.exports[UTF8ToString(name)].apply(null, a);
		HEAPF64[out >> 3] = r === undefined ? 0 : Number(r);
		return 0;
	} catch (e) {
		rec.err = String(e).substring(0, 300);
		return 1;
	}
});
// The meter (meter_module()): set to v if set, and read
EM_JS(double, bw_meter, (int id, int set, double v), {
	var inst = Module.buildatWasm.list[id].inst;
	var g = inst && inst.exports.buildat_meter;
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
	CallFn call_fn = nullptr;
	StartFn start_fn = nullptr;
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
	struct Slot {
		enum Kind { NONE, NODE, TEXTURE, VOLUME } kind = NONE;
		uint32_t gen = 1;
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
#if BUILDAT_WASM_NATIVE
		compile.reset();
#endif
		log_w(MODULE, "wasm %s: %s", cs(name), cs(why));
	}

	// A new handle for an object, or 0 with the table full
	uint32_t give(Slot::Kind kind, Urho3D::Node *node, Urho3D::Texture2D *tex,
			const sp_<interface::VoxelVolume> &volume)
	{
		size_t i = 0;
		while(i < slots.size() && (slots[i].kind != Slot::NONE ||
				slots[i].gen > GEN_MAX))
			i++;
		if(i == slots.size()){
			if(slots.size() >= MAX_HANDLES)
				return 0;
			slots.emplace_back();
		}
		Slot &s = slots[i];
		s.kind = kind;
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
		*s = Slot();
		s->gen = gen;
		return true;
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
		return (int64_t)bw_meter(web_id, 0, 0);
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
		bw_meter(web_id, 1, (double)v);
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
	// trap_reason set. Calls neither Lua nor wasm, and lets no exception
	// out: natively a trap is a longjmp, which must not cross a C++ frame
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
			trap_reason = "buildat."+ss_(which < IMP_COUNT ?
					IMPORTS[which].name : "?")+": "+why;
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

	// simplified: a module makes no node or component of its own: Urho3D
	// sends E_NODEADDED and E_COMPONENTADDED to Lua's handlers as they are
	// made, which would be a re-entry, so its Lua makes them and hands them
	// over. An import that makes one wants those events queued for after
	// the call.
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
		why = "no such import";
		return 0;
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
	// traps here, once run_import() has returned: nothing of C++'s is
	// left to destroy between here and trapping()'s setjmp.
	static uint32_t host_import(void *host, uint32_t which, const uint32_t *a)
	{
		Instance *self = (Instance*)host;
		g_in_wasm = 0;
		const uint32_t r = self->run_import(which, a);
		g_in_wasm = 1;
		if(!self->trap_reason.empty())
			wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE);
		return r;
	}

	// The compiled module's call with a trap caught: 0, or the trap's
	// code. what: 0 instantiates, 1 calls export f, 2 the start function,
	// those two with its meter at BUDGET. Nothing here with a destructor
	// between the setjmp and the call.
	static int trapping(Instance *in, int what, uint32_t f, const uint64_t *a,
			uint64_t *r)
	{
		if(what != 0)
			*in->c_meter = BUDGET;
		g_in_wasm = 1;
		int code = wasm_rt_impl_try();
		if(code == 0){
			if(what == 0){
				in->mem = calloc(1, ((SizeFn)dlsym(in->dl, "buildat_size"))());
				((InstantiateFn)dlsym(in->dl, "buildat_instantiate"))(
						in->mem, in, host_import);
			} else if(what == 1){
				in->call_fn(in->mem, f, a, r);
			} else {
				in->start_fn(in->mem);
			}
		}
		g_in_wasm = 0;
		return code;
	}

	// The compiled module loaded and instantiated (its data segments
	// written), its start function not run: true, or false with why
	bool open_compiled(const ss_ &so, ss_ &why)
	{
		dl = dlopen(so.c_str(), RTLD_NOW | RTLD_LOCAL);
		if(!dl){
			const char *e = dlerror();
			why = ss_("dlopen: ")+(e ? e : "?");
			return false;
		}
		free_fn = (FreeFn)dlsym(dl, "buildat_free");
		call_fn = (CallFn)dlsym(dl, "buildat_call");
		start_fn = (StartFn)dlsym(dl, "buildat_start");
		global_fn = (GlobalFn)dlsym(dl, "buildat_global");
		MemoryFn memory_fn = (MemoryFn)dlsym(dl, "buildat_memory");
		MeterFn meter_fn = (MeterFn)dlsym(dl, "buildat_meter");
		if(!free_fn || !call_fn || !memory_fn || !start_fn || !meter_fn ||
				!global_fn || !dlsym(dl, "buildat_size") ||
				!dlsym(dl, "buildat_instantiate")){
			why = "the built module lacks its entry points";
			return false;
		}
		runtime_init();
		const int code = trapping(this, 0, 0, nullptr, nullptr);
		if(mem){
			memory = memory_fn(mem);
			c_meter = meter_fn(mem);
		}
		if(code != 0 || !mem){
			why = "instantiation: "+(trap_reason.empty() ?
					ss_(wasm_rt_strerror((wasm_rt_trap_t)code)) : trap_reason);
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
			dlclose(dl);
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
				started_or_failed(trap_reason.empty() ?
						ss_(wasm_rt_strerror((wasm_rt_trap_t)code)) : trap_reason);
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
		if(!self || which >= IMP_COUNT){
			wasm_runtime_set_exception(wi, "an import with no instance");
			return;
		}
		uint32_t a[MAX_IMPORT_PARAMS] = {};
		for(int i = 0; i < IMPORTS[which].params; i++)
			a[i] = (uint32_t)args[i];
		const uint32_t r = self->run_import((uint32_t)which, a);
		// The interpreter checks for this after the native returns, and
		// unwinds; l_call() reports trap_reason
		if(!self->trap_reason.empty()){
			wasm_runtime_set_exception(wi, "an import trapped");
			return;
		}
		if(IMPORTS[which].result)
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
					wasm_rt_grow_memory(memory, bytes / 65536 - memory->pages) ==
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
			move_to(c->dir+"/module.so");
		else
			ready_from(c->dir+"/module.so");
	}

	// For checks only: the compiler hidden, as on a player-only archive,
	// so that the interpreter runs the module for good
	static bool compiler_hidden()
	{
		const char *e = getenv("BUILDAT_CHECK_WASM_INTERPRETER");
		return e && *e && strcmp(e, "0") != 0;
	}

	// m is the module checked, metered and prepared (prepare_native()), its
	// bytes as written from it in interp_bytes
	void start_native(wabt::Module &m, const ss_ &hash_hex)
	{
		static const Compiler none;
		const Compiler &cc = compiler_hidden() ? none : compiler();
		has_imports = !m.imports.empty();
		ss_ why;
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
				cc.path+"\n"+cc.version+"\n"+cc.flags+"\n"+WASM2C_DEFINES));
		// The cache, the user's alone
		const ss_ root = g_client_config.get<ss_>("cache_path")+"/wasm2c";
		mkdir(g_client_config.get<ss_>("cache_path").c_str(), 0700);
		mkdir(root.c_str(), 0700);
		chmod(root.c_str(), 0700);
		const ss_ dir = root+"/"+key.substr(0, 32);
		if(access((dir+"/module.so").c_str(), R_OK) == 0){
			log_i(MODULE, "wasm %s: compiled module from the cache (%s)",
					cs(name), cs(key.substr(0, 12)));
			ready_from(dir+"/module.so");
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
		ss_ tmpl = root+"/"+key.substr(0, 32)+".XXXXXX";
		if(!mkdtemp(&tmpl[0])){
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
		if(!interface::fs::write_file(tmp+"/m.c", ss_(cb.begin(), cb.end())) ||
				!interface::fs::write_file(tmp+"/m.h", ss_(hb.begin(), hb.end())) ||
				!interface::fs::write_file(tmp+"/wasm-rt.h", buildat_wasm_rt_h) ||
				!interface::fs::write_file(tmp+"/glue.c",
						glue_c(exports, has_imports, has_memory, has_start, globals))){
			compile_failed("could not write into "+tmp);
			return;
		}
		// The command line is the client's: its compiler, its flags, file
		// names it chose
		sv_<ss_> args = {cc.path, "-x", "c", "-std=c11", "-fPIC", "-shared",
				"-fvisibility=hidden", "-I."};
		for(const char *flags : {cc.flags.c_str(), WASM2C_DEFINES}){
			std::istringstream is(flags);
			ss_ w;
			while(is >> w)
				args.push_back(w);
		}
		for(const ss_ &a : {ss_("-o"), ss_("module.so"), ss_("m.c"),
				ss_("glue.c")})
			args.push_back(a);
		std::vector<char*> argv;
		for(ss_ &a : args)
			argv.push_back(&a[0]);
		argv.push_back(nullptr);
		const ss_ log_path = tmp+"/compile.log";
		compile->started = std::chrono::steady_clock::now();
		const pid_t pid = fork();
		if(pid < 0){
			compile_failed("fork failed");
			return;
		}
		if(pid == 0){
			// The child: async-signal-safe calls only, then the compiler
			setpgid(0, 0);
			prctl(PR_SET_PDEATHSIG, SIGKILL);
			struct rlimit as = {COMPILE_AS_BYTES, COMPILE_AS_BYTES};
			struct rlimit cpu = {COMPILE_CPU_S, COMPILE_CPU_S};
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
		setpgid(pid, pid);
		compile->pid = pid;
		g_compiles[key] = compile;
		log_i(MODULE, "wasm %s: compiling (pid %i, %s)", cs(name), (int)pid,
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
		g_tag_used[tag] = false;
		g_instance_count--;
	}

#ifdef __EMSCRIPTEN__
	ss_ take_error()
	{
		char *s = bw_take_error(web_id);
		ss_ r = s ? s : "?";
		free(s);
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
	// yet (the Windows client), so a game's way without it is driven
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
	in->in_call = true;
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
			trap = wasm_rt_strerror((wasm_rt_trap_t)code);
	}
	switch(sig.result){
	case 'i': result = (int32_t)(uint32_t)r; break;
	case 'I': result = (double)(int64_t)r; break;
	case 'f': { uint32_t u = (uint32_t)r; float f; memcpy(&f, &u, 4); result = f; } break;
	case 'F': memcpy(&result, &r, 8); break;
	}
#elif defined(__EMSCRIPTEN__)
	in->meter_set(BUDGET);
	if(bw_call(in->web_id, sig.name.c_str(), plain, sig.params.c_str(),
			n, &result) != 0)
		trap = in->take_error();
#endif
	in->in_call = false;
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

// __buildat_wasm_handle(m, object) -> a handle the module can use for the
// object: a Node, a Texture2D (tolua's, unwrapped by api.lua) or a
// buildat.Volume
static int l_handle(lua_State *L)
{
	Instance *in = check_instance(L);
	tolua_Error err;
	uint32_t h = 0;
	if(lua_isuserdata(L, 2) && tolua_isusertype(L, 2, "Node", 0, &err)){
		h = in->give(Instance::Slot::NODE,
				(Urho3D::Node*)tolua_tousertype(L, 2, 0), nullptr, nullptr);
	} else if(lua_isuserdata(L, 2) &&
			tolua_isusertype(L, 2, "Texture2D", 0, &err)){
		h = in->give(Instance::Slot::TEXTURE, nullptr,
				(Urho3D::Texture2D*)tolua_tousertype(L, 2, 0), nullptr);
	} else {
		sp_<interface::VoxelVolume> v;
		if(lua_isuserdata(L, 2)){
			luabind::object o(luabind::from_stack(L, 2));
			try {
				v = luabind::object_cast<sp_<interface::VoxelVolume>>(o);
			} catch(luabind::cast_failed&){
			}
		}
		if(!v)
			raise("wasm %s: handle(object): a Node, a Texture2D or a Volume",
					in->name.c_str());
		h = in->give(Instance::Slot::VOLUME, nullptr, nullptr, v);
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

} // namespace lua_bindings
// vim: set noet ts=4 sw=4:

