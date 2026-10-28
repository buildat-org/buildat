// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [CLIENT_WASM] [SERVER_WASM] A .wasm run as a sandbox of its own: the
// client's modules (src/lua_bindings/wasm.cpp) and the server's
// (src/server/wasm_module.cpp) alike.
//
// Every engine first reads the .wasm with WABT and refuses it past the caps,
// or importing anything but the process's ImportSet (and, on the server,
// what the module's meta.json grants), and meters it (meter_module(): a call
// past its budget traps, and the module is stopped). Then:
// - natively, wasm2c turns it into C (the process's own C: the export and
//   function names are renamed to f0, f1, ... before it is written, and no
//   name of the module's reaches the C or a command line), the system's
//   compiler builds that in a child process with a time and a memory
//   limit, and the result is cached under cache_root by the hashes of the
//   .wasm, WABT, the compiler and the flags, and dlopen()ed. Its memory is
//   checked by guard pages (8 GiB reserved per instance); a fault in them,
//   while a call is in it on that thread, is a trap and not a crash.
//   Until that is done, and for good with no compiler, WAMR's fast
//   interpreter (3rdparty/wamr) runs the same bytes, the memory's bounds
//   checked by its code; between two calls the module moves to the
//   compiled one, its state copied (prepare_native()).
// - on the web, the browser's own WebAssembly runs it, as an instance of
//   its own with its own memory: the JS between (EM_JS below) passes
//   numbers and copies bytes, and the module never sees the process's heap,
//   table or Module.
//
// The imports go through Engine::run_import() on every engine (natively
// wasm2c's import functions call it through the glue, on the web the
// module's import object does through buildat_wasm_import()), which charges
// them and hands them to the owner's import_body(): that checks every
// pointer and length against the module's memory (copy_in(), copy_out())
// and copies the bytes.
//
// Threads ([SERVER_WASM]): the server runs each module on its own thread,
// several at once. A module is loaded, called, polled and freed on one
// thread; what is shared between them here (the fault handler's table of
// memories, the compiles under way, WAMR's loader, the handle tags) is
// locked, and the fault handler's "a call is in wasm" is the thread's own.
//
// Natively on Windows ([CLIENT_WASM_WINDOWS]) the same, but: the compile is
// the package's MinGW in a job object (memory, CPU time and process caps,
// killed with the process), the module a DLL with wasm2c's runtime in it (a
// DLL does not see the executable's symbols), and its memory checked by
// wasm2c's explicit bounds checks instead of guard pages, so that no
// exception handler is needed (WASM2C_DEFINES below says why).
// BUILDAT_WASM_FUZZ: util/fuzz/wasm_fuzz.cpp includes this file for the
// checks, the meter and the preparation (to the end of movable()), with
// none of the engines: the instances and the compile are left out
#include "wasm/engine.h"
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
#include <map>
#include <memory>
#include <mutex>
#include <cmath>
#include <cstring>
#define MODULE "wasm"

namespace wasm_engine {

static ImportSet g_imports;
static std::map<ss_, size_t> g_import_index, g_import_c_index;

void set_imports(const ImportSet &set)
{
	g_imports = set;
	g_import_index.clear();
	g_import_c_index.clear();
	for(size_t k = 0; k < set.defs.size(); k++){
		g_import_index[set.defs[k].name] = k;
		g_import_c_index[set.defs[k].c_name] = k;
	}
}

const ImportSet& imports()
{
	return g_imports;
}

size_t ImportSet::find(const ss_ &name) const
{
	auto it = g_import_index.find(name);
	return it == g_import_index.end() ? defs.size() : it->second;
}

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

ss_ printable(const uint8_t *p, size_t n)
{
	ss_ r;
	for(size_t i = 0; i < n && i < MAX_LOG; i++)
		r += (p[i] >= 32 && p[i] < 127) ? (char)p[i] : '?';
	return r;
}

// What clang (and rustc, with the server's flags) builds; nothing else is
// read. Bulk memory stays (memory.fill and memory.copy, which the meter
// counts by their sizes), and so does multi-value.
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

// Read, validate and cap; fills exports and whether it imports anything.
// Each import is one of imports() by name and signature, once, not refused
// by refuse (the server's grants), and renamed to its c_name.
static bool check_module(const ss_ &bytes, wabt::Module &m,
		sv_<ExportSig> &exports, bool &has_imports, ss_ &why,
		const std::function<ss_(size_t)> &refuse = nullptr)
{
	if(bytes.size() > MAX_BYTES){
		why = "larger than "+itos(MAX_BYTES)+" bytes";
		return false;
	}
	const wabt::Features f = features();
	wabt::Errors errors;
	// No debug names: nothing of the module's is a C name
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
	const ImportSet &set = g_imports;
	has_imports = false;
	sv_<bool> seen(set.defs.size(), false);
	for(wabt::Import *imp : m.imports){
		const wabt::FuncImport *fi = wabt::dyn_cast<wabt::FuncImport>(imp);
		const size_t k = imp->module_name == "buildat" ?
				set.find(imp->field_name) : set.defs.size();
		bool ok = fi && k < set.defs.size() && !seen[k];
		if(ok){
			const wabt::FuncSignature &s = fi->func.decl.sig;
			ok = (int)s.param_types.size() == set.defs[k].params &&
					s.result_types.size() == (set.defs[k].result ? 1u : 0u);
			for(wabt::Type t : s.param_types)
				ok = ok && t == wabt::Type::I32;
			for(wabt::Type t : s.result_types)
				ok = ok && t == wabt::Type::I32;
		}
		if(!ok){
			why = "imports \""+imp->module_name.substr(0, 32)+"."+
					imp->field_name.substr(0, 120)+"\", which is not one of "+
					set.what+" with its signature (built for another engine API?)";
			// Printable only: the names are the module's
			why = printable((const uint8_t*)why.data(), why.size());
			return false;
		}
		if(refuse){
			const ss_ r = refuse(k);
			if(!r.empty()){
				why = "imports buildat."+set.defs[k].name+", "+r;
				return false;
			}
		}
		seen[k] = true;
		has_imports = true;
		imp->field_name = set.defs[k].c_name;
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
			why = "an export's name begins with buildat_, the engine's own";
			return false;
		}
		// The memory exported as "memory" is what the owner reaches
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
// the process (on the web, the tab; on the server, the module's thread).
// The module is rewritten before it is translated (natively) or
// instantiated (on the web), so that both run the same metered code: a
// global of its own, counted down, and a trap once it is below zero.
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
//   functions only, so it cannot import a global either.
// The engine sets the meter to the budget before each call; the call that
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
// past WEB_STACK_LIMIT the call traps. The engine sets it to 0 before each
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
// others; so that no name of the module's reaches the C, and no name means
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
// The imports' hash: in the compiled module's cache key, as their indices
// are in its C
static ss_ imports_hash()
{
	ss_ all;
	for(const ImportDef &d : g_imports.defs)
		all += d.name+" "+d.c_name+" "+itos(d.params)+(d.result ? "r" : "")+"\n";
	return interface::sha1::hex(interface::sha1::calculate(all));
}

static std::atomic<size_t> g_instance_count{0};

size_t instance_count()
{
	return g_instance_count;
}

// The live tables' handle tags (1 to 127)
static std::mutex g_tag_mutex;
static bool g_tag_used[128] = {};

uint32_t take_tag()
{
	std::lock_guard<std::mutex> lock(g_tag_mutex);
	for(uint32_t t = 1; t < 128; t++)
		if(!g_tag_used[t]){
			g_tag_used[t] = true;
			return t;
		}
	return 0;
}

void give_back_tag(uint32_t tag)
{
	std::lock_guard<std::mutex> lock(g_tag_mutex);
	if(tag < 128)
		g_tag_used[tag] = false;
}

#if BUILDAT_WASM_NATIVE

// The C wasm2c makes is built with these (and on Linux the runtime linked
// into the process with the first two: CMakeLists.txt). The call depth is
// counted, so that a deep recursion is a trap, not a native stack
// overflow, and each native frame is capped by the compiler (MAX_FRAME,
// compiler() below), as a frame's size is the module's to choose (its
// locals, its operand stack, what the compiler inlines): 2000 frames of
// at most 2 KiB (and the saved registers, about 64 bytes) take some 4.2
// MiB of the thread's 8 MiB (Linux's default, the main thread's and a
// server module's thread's; buildat.exe's 8 MiB too, CMakeLists.txt), the
// rest for the process below the call and the imports above it. A module
// past the cap is not compiled and stays in the interpreter
// ([WASM_FRAME_SIZE]; hillclimb's largest is 608 bytes).
// - Linux: guard pages (8 GiB reserved an instance), the runtime's own
//   signal handler off, as this file's chains to the process's crash
//   handler.
// - Windows ([CLIENT_WASM_WINDOWS]): wasm2c's explicit bounds checks, a
//   compare and a branch an access. Guard pages there want a vectored
//   exception handler that leaves the faulting frame for the trap: a
//   longjmp from inside the handler unwinds through the system's exception
//   dispatch, which Win64 does not support, and the supported way (the
//   faulting context pointed at a trampoline) depends on the unwind data of
//   the module's frames being right. A check in the C is correct by
//   construction, shares no handler with the crash handler, and reserves
//   no address space.
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
// little deeper than the load was
static const size_t STACK_NEEDED = 2000 * (size_t)(MAX_FRAME + 64) + (1 << 20);
#ifndef _WIN32
// The stack left below this point on the calling thread, which runs the
// module's calls too (the client's main thread: its size is RLIMIT_STACK's,
// read by glibc, so a small ulimit -s shows here, with RLIM_INFINITY the
// room up to the next mapping, which is plenty; a server module's thread:
// its own stack, of the same default size)
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
static const char *GLUE_VERSION = "buildat-wasm2c-glue 8";

// wasm2c's runtime files the C is built with, as name, contents, name,
// contents, ..., null (3rdparty/wabt/CMakeLists.txt): its headers, and on
// Windows its sources, as each module's DLL has the runtime in it
extern "C" const char *const buildat_wasm_rt_files[];

// What a built module exports to the engine (the glue below)
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

// A call is in a compiled module on this thread (trapping() below)
static thread_local volatile sig_atomic_t g_in_wasm = 0;

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

// A child of the process's ([CLIENT_WASM_WINDOWS]): args[0] the program,
// each argument quoted (none here has a quote or ends in a backslash; one
// that does is refused), in cwd (the process's when empty), its stdout and
// stderr into out (an inheritable handle) and its stdin from NUL, those
// two the only handles it inherits. Its environment is the process's with
// the program's directory first in PATH (its tools' DLLs, as rccpp does)
// and, when tmp is given, TMP and TEMP there. No window. In a job object
// of its own, from before it runs: the compile's memory (a process's),
// CPU time (the job's) and process count, no error dialog, and killed when
// the job's last handle closes -- the process's, however it ends. process
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
// the process loads code from): made with a protected DACL granting this
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
// the process loads code from): made 0700, or, there already, a directory
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
// one, while a call is in wasm on the faulting thread, is the module's
// out-of-bounds access. Kept by the runtime's own allocation (below), so
// that a memory is known from the moment it exists, a start function's
// access included. Written under the mutex, read by the handler without
// it: a thread's own instance's range was written before it ran.
struct Range { std::atomic<uintptr_t> begin{0}, end{0}; };
static Range g_ranges[MAX_INSTANCES];
static std::mutex g_ranges_mutex;
static struct sigaction g_old_segv, g_old_bus;

static void wasm_fault_handler(int sig, siginfo_t *si, void *ctx)
{
	if(g_in_wasm){
		const uintptr_t a = (uintptr_t)si->si_addr;
		for(const Range &r : g_ranges){
			const uintptr_t b = r.begin.load(std::memory_order_relaxed);
			if(b && a >= b && a < r.end.load(std::memory_order_relaxed)){
				g_in_wasm = 0;
				wasm_rt_trap(WASM_RT_TRAP_OOB);
			}
		}
	}
	// Not the module's: the process's own crash, its handler's
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

} // namespace wasm_engine

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
	{
		std::lock_guard<std::mutex> lock(wasm_engine::g_ranges_mutex);
		for(wasm_engine::Range &r : wasm_engine::g_ranges)
			if(!r.begin){
				r.end = (uintptr_t)m->data_end;
				r.begin = (uintptr_t)m->data;
				return;
			}
	}
	// More memories than instances can have: never, as each has one
	wasm_rt_trap(WASM_RT_TRAP_OOB);
}
extern "C" void wasm_rt_free_memory(wasm_rt_memory_t *m)
{
	{
		std::lock_guard<std::mutex> lock(wasm_engine::g_ranges_mutex);
		for(wasm_engine::Range &r : wasm_engine::g_ranges)
			if(r.begin == (uintptr_t)m->data){
				r.begin = 0;
				r.end = 0;
			}
	}
	buildat_wasm_rt_free_memory_impl(m);
}

namespace wasm_engine {

static void runtime_init()
{
	static const bool done = [](){
		wasm_rt_init();
		struct sigaction sa;
		memset(&sa, 0, sizeof sa);
		sa.sa_sigaction = wasm_fault_handler;
		sa.sa_flags = SA_SIGINFO;
		sigemptyset(&sa.sa_mask);
		sigaction(SIGSEGV, &sa, &g_old_segv);
		sigaction(SIGBUS, &sa, &g_old_bus);
		return true;
	}();
	(void)done;
}

#endif // _WIN32, Linux

// The interpreter's (WAMR's fast interpreter, 3rdparty/wamr) stack: its
// frames and operand cells in one buffer of this size, so the call depth
// is bounded by it (a frame of the toy's recursion takes about 88 bytes:
// about 2000 of them, as the compiled code's 2000). Past it, a trap ("wasm
// operand stack overflow"). The interpreter does not recurse natively for
// a wasm call, so the thread's own stack is not at stake.
static const uint32_t INTERP_STACK = 176 << 10;

// WAMR's loader and its instances' making and freeing, one thread at a
// time (the server's modules load and stop on threads of their own)
static std::mutex g_wamr_mutex;

static void interp_import(wasm_exec_env_t env, uint64_t *args);

// WAMR, once: the system's allocator, the ImportSet's imports as natives of
// "buildat" by their c_names (each with its signature, checked against the
// module's import by WAMR as well), its log to errors only. No signal
// handler is set up: the memory's bounds are checked by its code
// (3rdparty/wamr/CMakeLists.txt).
static bool interp_init()
{
	static const bool ok = [](){
		std::lock_guard<std::mutex> lock(g_wamr_mutex);
		RuntimeInitArgs args;
		memset(&args, 0, sizeof args);
		args.mem_alloc_type = Alloc_With_System_Allocator;
		if(!wasm_runtime_full_init(&args))
			return false;
		wasm_runtime_set_log_level(WASM_LOG_LEVEL_ERROR);
		const sv_<ImportDef> &defs = g_imports.defs;
		static sv_<ss_> sigs(defs.size());
		static sv_<NativeSymbol> syms(defs.size());
		for(size_t k = 0; k < defs.size(); k++){
			sigs[k] = "("+ss_(defs[k].params, 'i')+")"+
					(defs[k].result ? "i" : "");
			syms[k].symbol = defs[k].c_name.c_str();
			syms[k].func_ptr = (void*)interp_import;
			syms[k].signature = sigs[k].c_str();
			syms[k].attachment = (void*)(uintptr_t)k;
		}
		return (bool)wasm_runtime_register_natives_raw("buildat", syms.data(),
				(uint32_t)defs.size());
	}();
	return ok;
}

// The compiler: its path (execv and CreateProcess take one), its first
// --version line, and wasm2c's recommended flags for it. Looked up once.
struct Compiler {
	ss_ path;
	ss_ version;
	ss_ flags;
};
static Compiler find_compiler()
{
	Compiler c;
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
static const Compiler& compiler()
{
	static const Compiler c = find_compiler();
	return c;
}

// The process's own C around wasm2c's: an instance's size, its binding to
// the engine's import function, its making and freeing, its memory, and
// one trapping entry (the runtime's setjmp is in it: on Windows the
// runtime is the DLL's own) that instantiates, runs the start function or
// unpacks numbers for an export by index. Nothing in it comes from the
// module but types; its import functions are the ImportSet's, by index.
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
	// The imports the module has (renamed to their c_names:
	// check_module()): each hands its numbers to the engine's
	// run_import(), and traps here when it says so
	for(const wabt::Import *imp : m.imports){
		auto it = g_import_c_index.find(imp->field_name);
		if(it == g_import_c_index.end())
			continue; // never: check_module() named it
		const size_t k = it->second;
		const ImportDef &d = g_imports.defs[k];
		os<<(d.result ? "uint32_t" : "void")<<" w2c_buildat_"<<d.c_name<<
				"(struct w2c_buildat *b";
		for(int i = 0; i < d.params; i++)
			os<<", uint32_t a"<<i;
		os<<"){ uint32_t a["<<MAX_IMPORT_PARAMS<<"] = {";
		for(int i = 0; i < d.params; i++)
			os<<(i ? ", a" : "a")<<i;
		os<<(d.params ? "" : "0")<<"}; int t = 0; uint32_t r = b->imp(b->host, "<<
				k<<", a, &t); if(t) wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE); "<<
				(d.result ? "return r;" : "(void)r;")<<" }\n";
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

// A compile's cached refusal beside <cache>/<key>: a file of the
// compiler's error lines. It only ever means "do not compile"; what is in
// it is logged, made printable, and nothing else is read from it.
static ss_ refused_path(const ss_ &dir)
{
	return dir+".refused";
}
// A compile of one key ([WASM_COMPILE_RACE]): the loads of the same module
// in this process share it, and each waits on it (on the server from
// threads of their own: poll() is locked). It writes into a directory of
// its own and renames that whole into the cache as <key>/ once the module
// is built, so that another process compiling the same key into the same
// cache never sees half a directory: whichever renames first wins, the
// other takes the winner's.
struct Compile {
	ss_ name; // the module's, for the log
	ss_ dir; // <cache>/<key>, there once whole
	ss_ tmp; // this compile's own, removed once done
#ifdef _WIN32
	HANDLE process = NULL, job = NULL;
#else
	pid_t pid = 0;
#endif
	std::chrono::steady_clock::time_point started;
	enum State { RUNNING, DONE, FAILED };
	std::atomic<int> state{RUNNING};
	ss_ error;
	// The compiler exited with an error, not killed past a limit: the same
	// key fails the same way again ([WASM_STACK_RLIMIT]), and is not
	// compiled again (refused_path())
	bool refused = false;
	std::mutex mutex;

	void finish_failed(const ss_ &why)
	{
		error = why;
		state = FAILED;
	}

	// The compiler's command line, all the process's, run in tmp with its
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
		std::lock_guard<std::mutex> lock(mutex);
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
		// Into place whole; a directory there already is another process's
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
// The compiles under way in this process, by key
static std::map<ss_, std::weak_ptr<Compile>> g_compiles;
static std::mutex g_compiles_mutex;

#endif // BUILDAT_WASM_NATIVE

#ifdef __EMSCRIPTEN__
// The module as an instance of its own, from the page's JS: its own
// memory, importing the ImportSet's functions only, each of which hands its
// numbers to buildat_wasm_import() (run_import(), the C++ every engine
// shares) and throws its trap. What crosses is numbers, and bytes copied
// between its memory and the process's heap by the JS here.
EM_JS(int, bw_new, (void), {
	var w = Module.buildatWasm || (Module.buildatWasm = {next: 1, list: {}});
	var id = w.next++;
	w.list[id] = {inst: null, err: ""};
	return id;
});
// names: the imports' c_names, comma separated, in run_import()'s order
EM_JS(void, bw_load, (int id, const uint8_t *p, int n, int host,
		const char *names), {
	var rec = Module.buildatWasm.list[id];
	try {
		var mod = new WebAssembly.Module(HEAPU8.slice(p, p + n));
		var imports = {buildat: {}};
		UTF8ToString(names).split(",").forEach(function(name, k) {
			imports.buildat[name] = function(a0, a1, a2, a3, a4, a5, a6, a7) {
				var r = _buildat_wasm_import(host, k, a0 | 0, a1 | 0, a2 | 0,
						a3 | 0, a4 | 0, a5 | 0, a6 | 0, a7 | 0);
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
		// Thrown in the process's own code under an import, the stack
		// pointer is where that code left it
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
// [WEB_LOCAL_AITTA] On the thread that made it; the server's modules each
// have their own (a worker each), and one freed elsewhere finds no list
EM_JS(void, bw_free, (int id), {
	var w = Module.buildatWasm;
	if (w) delete w.list[id];
});
#endif

// The engines' own state, and their work
struct Engine::Impl
{
	Engine &e;
	// Between prepare() and start(): the module checked and metered, and
	// the hash of its bytes
	up_<wabt::Module> module;
	ss_ hash;
	bool has_start = false;
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
	enum Kind { NONE, INTERP, COMPILED } engine = NONE;
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
#ifdef __EMSCRIPTEN__
	int web_id = 0;
#endif

	Impl(Engine &e): e(e){}

#if BUILDAT_WASM_NATIVE
	// The engine's memory: its bytes (null with none)
	uint8_t* mem_data()
	{
		if(engine == INTERP)
			return wmem ? (uint8_t*)wasm_memory_get_base_address(wmem) : nullptr;
		return memory ? memory->data : nullptr;
	}

	// wasm2c's import functions (the glue) call this. A refused import
	// traps in the glue, once this has returned (*trap set): nothing of
	// C++'s is left to destroy between there and buildat_try()'s setjmp.
	static uint32_t host_import(void *host, uint32_t which, const uint32_t *a,
			int *trap)
	{
		Engine *self = (Engine*)host;
		g_in_wasm = 0;
		const uint32_t r = self->run_import(which, a);
		g_in_wasm = 1;
		*trap = !self->trap_reason.empty();
		return r;
	}

	// The compiled module's call with a trap caught (the glue's
	// buildat_try()): 0, or the trap's code. what: 0 instantiates, 1 calls
	// export f, 2 the start function, those two with its meter at BUDGET.
	int trapping(int what, uint32_t f, const uint64_t *a, uint64_t *r)
	{
		if(what != 0)
			*c_meter = BUDGET;
		g_in_wasm = 1;
		const int code = try_fn(mem, what, f, a, r);
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
		bind_fn(mem, &e, host_import);
		const int code = trapping(0, 0, nullptr, nullptr);
		memory = memory_fn(mem);
		c_meter = meter_fn(mem);
		if(code != 0){
			why = "instantiation: "+(e.trap_reason.empty() ? trap_text(code) :
					e.trap_reason);
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
			e.fail(why);
			return;
		}
		engine = COMPILED;
		meter = c_meter;
		if(has_start){
			const int code = trapping(2, 0, nullptr, nullptr);
			if(code != 0){
				e.started_or_failed(e.trap_reason.empty() ? trap_text(code) :
						e.trap_reason);
				return;
			}
		}
		e.started_or_failed("");
		if(e.state == READY)
			log_i(MODULE, "wasm %s: ready (compiled)", cs(e.name));
	}

	// WAMR's imports (interp_init()): the engine from the module
	// instance's custom data, which import from the attachment
	static void interp_native(wasm_exec_env_t env, uint64_t *args)
	{
		wasm_module_inst_t wi = wasm_runtime_get_module_inst(env);
		Engine *self = (Engine*)wasm_runtime_get_custom_data(wi);
		const uintptr_t which = (uintptr_t)wasm_runtime_get_function_attachment(
				env);
		if(!self || which >= g_imports.defs.size()){
			wasm_runtime_set_exception(wi, "an import with no instance");
			return;
		}
		const ImportDef &d = g_imports.defs[which];
		uint32_t a[MAX_IMPORT_PARAMS] = {};
		for(int i = 0; i < d.params && i < MAX_IMPORT_PARAMS; i++)
			a[i] = (uint32_t)args[i];
		const uint32_t r = self->run_import((uint32_t)which, a);
		// The interpreter checks for this after the native returns, and
		// unwinds; call() reports trap_reason
		if(!self->trap_reason.empty()){
			wasm_runtime_set_exception(wi, "an import trapped");
			return;
		}
		if(d.result)
			*(uint32_t*)args = r;
	}

	// The interpreter's call: "" or the trap. f is the export's index, or
	// ~0 for the start function; the meter at the budget before.
	ss_ interp_call(uint32_t f, const uint64_t *a, uint64_t *r)
	{
		*i_meter = INTERP_BUDGET;
		wasm_val_t args[MAX_PARAMS], res[1];
		memset(args, 0, sizeof args);
		memset(res, 0, sizeof res);
		wasm_function_inst_t fn = wstart;
		uint32_t nargs = 0, nres = 0;
		if(f != ~0u){
			const ExportSig &s = e.exports[f];
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
		const char *ex = wasm_runtime_get_exception(wi);
		ss_ trap = ex ? ex : "?";
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
		{
			std::lock_guard<std::mutex> lock(g_wamr_mutex);
			// WAMR's loader validates it again, and may write into the bytes
			wm = wasm_runtime_load((uint8_t*)&interp_bytes[0],
					(uint32_t)interp_bytes.size(), err, sizeof err);
			if(wm)
				wi = wasm_runtime_instantiate(wm, INTERP_STACK, 0, err, sizeof err);
			if(wi){
				wasm_runtime_set_custom_data(wi, &e);
				// On the thread that calls it, whose stack WAMR reads here
				we = wasm_runtime_create_exec_env(wi, INTERP_STACK);
			}
		}
		if(!we){
			why = "the interpreter refused it: "+printable((const uint8_t*)err,
					strnlen(err, sizeof err));
			close_interp();
			return false;
		}
		for(size_t i = 0; i < e.exports.size(); i++){
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
			e.in_call = true;
			e.trap_reason.clear();
			trap = interp_call(~0u, nullptr, nullptr);
			e.in_call = false;
			if(!e.trap_reason.empty())
				trap = e.trap_reason;
		}
		e.started_or_failed(trap);
		return true;
	}

	void close_interp()
	{
		{
			std::lock_guard<std::mutex> lock(g_wamr_mutex);
			if(we)
				wasm_runtime_destroy_exec_env(we);
			if(wi)
				wasm_runtime_deinstantiate(wi);
			if(wm)
				wasm_runtime_unload(wm);
		}
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
		const uint64_t bytes = e.memory_size();
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
			log_w(MODULE, "wasm %s: stays in the interpreter: %s", cs(e.name),
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
				"memory and %zu globals copied); ready (compiled)", cs(e.name),
				(unsigned long long)bytes, globals.size());
	}

	// The compile failed or could not start: the module stays in the
	// interpreter if it runs there, else fails
	void compile_failed(const ss_ &why)
	{
		compile.reset();
		if(engine != INTERP){
			e.fail(why);
			return;
		}
		log_w(MODULE, "wasm %s: %s; it stays in the interpreter", cs(e.name),
				cs(why));
	}

	// For checks only: the compiler hidden, as on a player-only archive,
	// so that the interpreter runs the module for good
	static bool compiler_hidden()
	{
		const char *ev = getenv("BUILDAT_CHECK_WASM_INTERPRETER");
		return ev && *ev && strcmp(ev, "0") != 0;
	}

	// Not to be compiled, for the reason given: the interpreter for good,
	// or failed
	void interp_for_good(const ss_ &reason)
	{
		ss_ why;
		if(start_interp(why)){
			if(e.state == READY)
				log_w(MODULE, "wasm %s: ready (interpreter): not compiled, as %s",
						cs(e.name), cs(reason));
			return;
		}
		e.fail("not compiled, as "+reason+", and "+why);
	}

	// m is the module checked, metered and prepared (prepare_native()), its
	// bytes as written from it in interp_bytes
	void start_native(wabt::Module &m)
	{
		static const Compiler none;
		const Compiler &cc = compiler_hidden() ? none : compiler();
		has_imports = !m.imports.empty();
		ss_ why;
#ifndef _WIN32
		// Too small a stack for the compiled code's depth limit (a small
		// ulimit -s): the interpreter, whose stack is its own. On Windows
		// the calls run on the main thread, linked at 8 MiB (CMakeLists.txt).
		const size_t left = stack_left();
		if(left < STACK_NEEDED){
			interp_for_good("the stack has "+itos((int)(left >> 10))+
					" KiB left and the compiled code's call depth needs "+
					itos((int)(STACK_NEEDED >> 10))+" (ulimit -s)");
			return;
		}
#endif
		if(cc.path.empty()){
			if(start_interp(why)){
				if(e.state == READY)
					log_i(MODULE, "wasm %s: ready (interpreter): no C compiler "
							"to build it with%s", cs(e.name), compiler_hidden() ?
							" (hidden for a check)" : "");
				return;
			}
			e.fail("no C compiler to build it with (the server's lookup: "
					"compiler/bin/c++, then c++ in PATH), and "+why);
			return;
		}
		const ss_ key = interface::sha1::hex(interface::sha1::calculate(
				hash+"\n"+WABT_VERSION_STRING+"\n"+GLUE_VERSION+"\n"+
				imports_hash()+"\n"+
				cc.path+"\n"+cc.version+"\n"+cc.flags+"\n"+WASM2C_DEFINES));
		// The cache, the user's alone; else no compiled module at all
		const ss_ root = e.cache_root;
		interface::fs::create_directories(interface::fs::strip_file_name(root));
		if(root.empty() || !private_dir(root, why)){
			if(root.empty())
				why = "there is no cache for it";
			ss_ why2;
			if(start_interp(why2)){
				if(e.state == READY)
					log_w(MODULE, "wasm %s: ready (interpreter): not compiled, "
							"as %s", cs(e.name), cs(why));
				return;
			}
			e.fail("not compiled, as "+why+", and "+why2);
			return;
		}
		const ss_ dir = root+"/"+key.substr(0, 32);
		if(is_file(dir+"/"+MODULE_FILE)){
			log_i(MODULE, "wasm %s: compiled module from the cache (%s)",
					cs(e.name), cs(key.substr(0, 12)));
			ready_from(dir+"/"+MODULE_FILE);
			return;
		}
		// Refused by an earlier compile of the same key: not compiled again
		std::ifstream refused(refused_path(dir));
		if(refused.good()){
			ss_ line;
			for(int n = 0; n < 5 && std::getline(refused, line); n++)
				log_w(MODULE, "wasm %s: compiler (cached): %s", cs(e.name),
						cs(printable((const uint8_t*)line.data(), line.size())));
			interp_for_good("its compile was refused before (cached, "+
					key.substr(0, 12)+")");
			return;
		}
		// Not in the cache: the interpreter runs it while it compiles
		if(!movable(m, has_memory)){
			log_i(MODULE, "wasm %s: its state could not move to the compiled "
					"module; it waits on its compile", cs(e.name));
		} else if(start_interp(why)){
			if(e.state != READY)
				return; // its start function failed
			log_i(MODULE, "wasm %s: ready (interpreter) while it compiles",
					cs(e.name));
		} else {
			log_w(MODULE, "wasm %s: %s; it waits on its compile", cs(e.name),
					cs(why));
		}
		// The same key compiling in this process: wait on it
		std::lock_guard<std::mutex> lock(g_compiles_mutex);
		for(auto it = g_compiles.begin(); it != g_compiles.end();)
			it = it->second.expired() ? g_compiles.erase(it) : std::next(it);
		auto running = g_compiles.find(key);
		if(running != g_compiles.end()){
			compile = running->second.lock();
			log_i(MODULE, "wasm %s: waiting on its compile under way (%s)",
					cs(e.name), cs(key.substr(0, 12)));
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
		compile->name = e.name;
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
				glue_c(m, e.exports, has_imports, has_memory, has_start, globals));
		for(const char *const *f = buildat_wasm_rt_files; *f; f += 2)
			written = written && interface::fs::write_file(tmp+"/"+f[0], f[1]);
		if(!written){
			compile_failed("could not write into "+tmp);
			return;
		}
		// The command line is the process's: its compiler, its flags, file
		// names it chose. On Windows the runtime goes into the DLL, which
		// is linked whole (-static: no MinGW DLL of the process's needed)
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
		log_i(MODULE, "wasm %s: compiling (pid %i, %s)", cs(e.name), pid,
				cs(key.substr(0, 12)));
	}
#endif // BUILDAT_WASM_NATIVE

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
#else
		(void)v;
#endif
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
	Engine::Impl::interp_native(env, args);
}
#endif

#ifdef __EMSCRIPTEN__
// The module's imports, from bw_load()'s JS: the result, or -1 for a trap
// (run_import() logged why, and the JS throws)
extern "C" EMSCRIPTEN_KEEPALIVE double buildat_wasm_import(int host, int which,
		int a0, int a1, int a2, int a3, int a4, int a5, int a6, int a7)
{
	Engine *in = (Engine*)(intptr_t)host;
	const uint32_t a[MAX_IMPORT_PARAMS] = {(uint32_t)a0, (uint32_t)a1,
			(uint32_t)a2, (uint32_t)a3, (uint32_t)a4, (uint32_t)a5,
			(uint32_t)a6, (uint32_t)a7};
	const uint32_t r = in->run_import((uint32_t)which, a);
	return in->trap_reason.empty() ? (double)r : -1.0;
}
#endif

Engine::Engine():
	impl(new Impl(*this))
{
	g_instance_count++;
}

Engine::~Engine()
{
#if BUILDAT_WASM_NATIVE
	impl->compile.reset(); // killed if no other load waits on it
	impl->close_interp();
	impl->close_compiled();
#endif
#ifdef __EMSCRIPTEN__
	if(impl->web_id)
		bw_free(impl->web_id);
#endif
	delete impl;
	g_instance_count--;
}

void Engine::fail(const ss_ &why)
{
	state = FAILED;
	error = why;
	on_fail();
#if BUILDAT_WASM_NATIVE
	impl->compile.reset();
#endif
	log_w(MODULE, "wasm %s: %s", cs(name), cs(why));
}

void Engine::started_or_failed(const ss_ &trap)
{
	if(trap.empty()){
		state = READY;
		return;
	}
	if(past_budget())
		fail("stopped: its start function ran past its budget of "+
				itos(budget())+" (a loop that does not end?)");
	else
		fail("trap at start: "+trap);
}

bool Engine::prepare(const ss_ &bytes, ss_ &why)
{
	if(g_instance_count > MAX_INSTANCES){
		why = "more than "+itos(MAX_INSTANCES)+" wasm modules loaded";
		return false;
	}
	up_<wabt::Module> m(new wabt::Module());
	bool has_imports = false;
	if(!check_module(bytes, *m, exports, has_imports, why, refuse_import))
		return false;
	if(!meter_module(*m, impl->has_start, why))
		return false;
	impl->hash = interface::sha1::hex(interface::sha1::calculate(bytes));
	impl->module = std::move(m);
	log_i(MODULE, "wasm %s: %zu bytes, %zu exports, valid (%s)", cs(name),
			bytes.size(), exports.size(), cs(impl->hash.substr(0, 12)));
	return true;
}

void Engine::start()
{
	if(!impl->module){
		fail("not prepared");
		return;
	}
	up_<wabt::Module> m = std::move(impl->module);
#if BUILDAT_WASM_NATIVE
	// The bytes the interpreter runs, written from the module wasm2c
	// translates: the same, metered and prepared
	prepare_native(*m, impl->has_memory, impl->globals);
	wabt::MemoryStream prepared;
	if(wabt::Failed(wabt::WriteBinaryModule(&prepared, m.get(),
			wabt::WriteBinaryOptions(features(), true, false, false)))){
		fail("the metered module could not be written");
		return;
	}
	impl->interp_bytes.assign(prepared.output_buffer().data.begin(),
			prepared.output_buffer().data.end());
	impl->start_native(*m);
#elif defined(__EMSCRIPTEN__)
	ss_ names;
	for(const ImportDef &d : g_imports.defs)
		names += ss_(names.empty() ? "" : ",")+d.c_name;
	// The metered module is what the browser instantiates
	wabt::MemoryStream metered;
	if(wabt::Failed(wabt::WriteBinaryModule(&metered, m.get(),
			wabt::WriteBinaryOptions(features(), true, false, false)))){
		fail("the metered module could not be written");
		return;
	}
	const auto &mb = metered.output_buffer().data;
	impl->web_id = bw_new();
	bw_load(impl->web_id, mb.data(), (int)mb.size(), (int)(intptr_t)this,
			names.c_str());
	char *err = bw_take_error(impl->web_id);
	if(err){
		fail(ss_("the browser: ")+err);
		free(err);
		return;
	}
	ss_ trap;
	if(impl->has_start){
		double unused = 0;
		impl->meter_set(BUDGET);
		bw_global(impl->web_id, STACK, 1, 0);
		trap_reason.clear();
		in_call = true;
		if(bw_call(impl->web_id, START, nullptr, "", 0, &unused) != 0)
			trap = impl->take_error();
		in_call = false;
		if(!trap_reason.empty())
			trap = trap_reason;
	}
	started_or_failed(trap);
	if(state == READY)
		log_i(MODULE, "wasm %s: ready (the browser's instance)", cs(name));
#else
	fail("wasm modules do not run on this platform yet");
#endif
}

void Engine::poll()
{
#if BUILDAT_WASM_NATIVE
	Impl &I = *impl;
	if(!I.compile || state == FAILED || in_call)
		return;
	I.compile->poll();
	if(I.compile->state == Compile::RUNNING)
		return;
	const sp_<Compile> c = std::move(I.compile);
	if(c->state == Compile::FAILED){
		I.compile_failed(c->error);
		return;
	}
	if(I.engine == Impl::INTERP)
		I.move_to(c->dir+"/"+MODULE_FILE);
	else
		I.ready_from(c->dir+"/"+MODULE_FILE);
#endif
}

ss_ Engine::call(size_t index, const uint64_t *args, uint64_t *result)
{
	ss_ trap;
	*result = 0;
	if(index >= exports.size())
		return "no such export";
	in_call = true;
	trap_reason.clear();
	logged = 0;
#if BUILDAT_WASM_NATIVE
	Impl &I = *impl;
	if(I.engine == Impl::INTERP){
		trap = I.interp_call((uint32_t)index, args, result);
	} else if(I.engine == Impl::COMPILED){
		const int code = I.trapping(1, (uint32_t)index, args, result);
		if(code != 0)
			trap = I.trap_text(code);
	} else {
		trap = "not running";
	}
#elif defined(__EMSCRIPTEN__)
	// What JS takes: numbers, an i64 as a BigInt made from a double (the
	// browser wraps it, as the bits are)
	const ExportSig &sig = exports[index];
	double plain[MAX_PARAMS] = {0};
	for(size_t k = 0; k < sig.params.size(); k++){
		switch(sig.params[k]){
		case 'i': plain[k] = (double)(int32_t)(uint32_t)args[k]; break;
		case 'I': plain[k] = (double)(int64_t)args[k]; break;
		case 'f': { uint32_t u = (uint32_t)args[k]; float f; memcpy(&f, &u, 4);
				plain[k] = f; } break;
		case 'F': memcpy(&plain[k], &args[k], 8); break;
		}
	}
	impl->meter_set(BUDGET);
	bw_global(impl->web_id, STACK, 1, 0);
	double r = 0;
	if(bw_call(impl->web_id, sig.name.c_str(), plain, sig.params.c_str(),
			(int)sig.params.size(), &r) != 0)
		trap = impl->take_error();
	switch(sig.result){
	case 'i': *result = (uint32_t)(int32_t)r; break;
	case 'I': *result = (uint64_t)(int64_t)r; break;
	case 'f': { const float f = (float)r; uint32_t u; memcpy(&u, &f, 4);
			*result = u; } break;
	case 'F': memcpy(result, &r, 8); break;
	}
#else
	trap = "not running";
	(void)args;
#endif
	in_call = false;
	if(!trap_reason.empty())
		trap = trap_reason;
	return trap;
}

bool Engine::past_budget()
{
	return impl->meter_get() < 0;
}

int64_t Engine::budget()
{
#if BUILDAT_WASM_NATIVE
	return impl->engine == Impl::INTERP ? INTERP_BUDGET : BUDGET;
#else
	return BUDGET;
#endif
}

ss_ Engine::engine_name()
{
#if BUILDAT_WASM_NATIVE
	return impl->engine == Impl::COMPILED ? "compiled" :
			impl->compile ? "interpreter, compiling" : "interpreter";
#else
	return "browser";
#endif
}

size_t Engine::find_export(const ss_ &n)
{
	size_t i = 0;
	while(i < exports.size() && exports[i].name != n)
		i++;
	return i;
}

uint64_t Engine::memory_size()
{
#if BUILDAT_WASM_NATIVE
	Impl &I = *impl;
	if(I.engine == Impl::INTERP)
		return I.wmem ? wasm_memory_get_cur_page_count(I.wmem) *
				(uint64_t)wasm_memory_get_bytes_per_page(I.wmem) : 0;
	return I.memory ? I.memory->size : 0;
#elif defined(__EMSCRIPTEN__)
	return (uint64_t)bw_memory_size(impl->web_id);
#else
	return 0;
#endif
}

bool Engine::copy_in(uint64_t ptr, uint64_t len, void *dst)
{
	if(ptr > memory_size() || len > memory_size() - ptr)
		return false;
	if(len == 0)
		return true;
#if BUILDAT_WASM_NATIVE
	memcpy(dst, impl->mem_data() + ptr, len);
	return true;
#elif defined(__EMSCRIPTEN__)
	return bw_copy(impl->web_id, (double)ptr, (int)(intptr_t)dst, (int)len, 0) == 0;
#else
	return false;
#endif
}

bool Engine::copy_out(uint64_t ptr, const void *src, uint64_t len)
{
	if(ptr > memory_size() || len > memory_size() - ptr)
		return false;
	if(len == 0)
		return true;
#if BUILDAT_WASM_NATIVE
	memcpy(impl->mem_data() + ptr, src, len);
	return true;
#elif defined(__EMSCRIPTEN__)
	return bw_copy(impl->web_id, (double)ptr, (int)(intptr_t)src, (int)len, 1) == 0;
#else
	return false;
#endif
}

void Engine::log_line(const uint8_t *p, size_t n)
{
	n = std::min<size_t>(n, MAX_LOG);
	import_cost += 10000 + n; // a line written out
	if(++logged <= MAX_LOG_LINES)
		log_i(MODULE, "wasm %s: %s", cs(name), cs(printable(p, n)));
	else if(logged == MAX_LOG_LINES + 1)
		log_w(MODULE, "wasm %s: more than %zu lines in a call; the "
				"rest of this call's are not written", cs(name),
				MAX_LOG_LINES);
}

uint32_t Engine::run_import(uint32_t which, const uint32_t *a)
{
	try {
		ss_ why;
		import_cost = IMPORT_COST;
		const uint32_t r = which < g_imports.defs.size() ?
				import_body(which, a, why) : 0;
		if(which >= g_imports.defs.size())
			why = "no such import";
		if(why.empty()){
			// Its work charged to the call's budget, as the module's own
			// instructions are
			const int64_t left = impl->meter_get() - (int64_t)std::min<uint64_t>(
					import_cost, BUDGET);
			impl->meter_set(left);
			if(left >= 0)
				return r;
			why = "past the call's budget";
		}
		trap_reason = "buildat."+(which < g_imports.defs.size() ?
				g_imports.defs[which].name : ss_("?"))+": "+why;
	} catch(std::exception &ex){
		trap_reason = ss_("an import: ")+ex.what();
	} catch(...){
		trap_reason = "an import: an exception";
	}
	log_w(MODULE, "wasm %s: trap: %s", cs(name), cs(trap_reason));
	return 0;
}

#endif // BUILDAT_WASM_FUZZ

} // namespace wasm_engine
// vim: set noet ts=4 sw=4:
