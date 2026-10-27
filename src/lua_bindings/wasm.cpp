// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [CLIENT_WASM] A module's wasm/, built by the server to a .wasm, run on
// the client as a sandbox of its own, its exports called from Lua.
//
// Both clients first read the .wasm with WABT and refuse it past the caps
// below. Then:
// - natively, wasm2c turns it into C (the client's own C: the export and
//   function names are renamed to f0, f1, ... before it is written, and no
//   name of the server's reaches the C or a command line), the system's
//   compiler builds that in a child process with a time and a memory
//   limit, and the result is cached under <cache>/wasm2c/ by the hashes of
//   the .wasm, WABT, the compiler and the flags, and dlopen()ed. Its memory
//   is checked by guard pages (8 GiB reserved per instance); a fault in
//   them, while a call is in it, is a trap and not a crash.
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
#include "wabt/validator.h"
#include "wabt/ir.h"
#include "wabt/cast.h"
#if defined(__linux__) && !defined(__EMSCRIPTEN__)
#define BUILDAT_WASM_NATIVE 1
#include "wabt/generate-names.h"
#include "wabt/apply-names.h"
#include "wabt/c-writer.h"
#include "wabt/stream.h"
#include "client/config.h"
#include "boot/autodetect.h"
#include "interface/fs.h"
#include "wasm-rt-impl.h"
#include "wasm-rt-exceptions.h"
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

// Read, validate and cap; fills exports and whether it imports anything
static bool check_module(const ss_ &bytes, wabt::Module &m,
		sv_<ExportSig> &exports, bool &has_imports, ss_ &why)
{
	if(bytes.size() > MAX_BYTES){
		why = "larger than "+itos(MAX_BYTES)+" bytes";
		return false;
	}
	// What clang builds with the server's flags; nothing else is read
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
// Bumped when the C this writes changes, so that the cache is not reused
static const char *GLUE_VERSION = "buildat-wasm2c-glue 2";

extern "C" const char buildat_wasm_rt_h[];

// What a built module exports to the client (the glue below)
typedef size_t (*SizeFn)(void);
typedef uint32_t (*ImportFn)(void*, uint32_t, const uint32_t*);
typedef void (*InstantiateFn)(void*, void*, ImportFn);
typedef void (*FreeFn)(void*);
typedef wasm_rt_memory_t* (*MemoryFn)(void*);
typedef void (*CallFn)(void*, uint32_t, const uint64_t*, uint64_t*);

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
		bool has_memory)
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
	ss_ dir; // the compile's directory in the cache
	ss_ tmp_so; // the compiler's output there, renamed once it is whole
	pid_t pid = 0;
	std::chrono::steady_clock::time_point started;
	bool has_imports = false;
	void *dl = nullptr;
	void *mem = nullptr;
	wasm_rt_memory_t *memory = nullptr;
	FreeFn free_fn = nullptr;
	CallFn call_fn = nullptr;
#endif
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

	void fail(const ss_ &why)
	{
		state = FAILED;
		error = why;
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

	uint64_t memory_size()
	{
#if BUILDAT_WASM_NATIVE
		return memory ? memory->size : 0;
#elif defined(__EMSCRIPTEN__)
		return (uint64_t)bw_memory_size(web_id);
#else
		return 0;
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
		memcpy(dst, memory->data + ptr, len);
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
		memcpy(memory->data + ptr, src, len);
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
			const uint32_t r = import_body(which, a, why);
			if(why.empty())
				return r;
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
	// simplified: the start function has no memory to give an import yet
	// (natively and on the web the memory is known once instantiation
	// returns), so an import with a pointer traps there.
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
			if(!copy_in(a[0], n, buf)){
				why = PAST;
				return 0;
			}
			log_i(MODULE, "wasm %s: %s", cs(name), cs(printable(buf, n)));
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
			event_bytes -= e.size();
			events.pop_front();
			return n;
		}
		}
		why = "no such import";
		return 0;
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

	// The wasm call with a trap caught: 0, or the trap's code. Nothing
	// here with a destructor between the setjmp and the call.
	static int trapping(Instance *in, int what, uint32_t f, const uint64_t *a,
			uint64_t *r)
	{
		g_in_wasm = 1;
		int code = wasm_rt_impl_try();
		if(code == 0){
			if(what == 0){
				in->mem = calloc(1, ((SizeFn)dlsym(in->dl, "buildat_size"))());
				((InstantiateFn)dlsym(in->dl, "buildat_instantiate"))(
						in->mem, in, host_import);
			} else {
				in->call_fn(in->mem, f, a, r);
			}
		}
		g_in_wasm = 0;
		return code;
	}

	void ready_from(const ss_ &so)
	{
		dl = dlopen(so.c_str(), RTLD_NOW | RTLD_LOCAL);
		if(!dl){
			const char *e = dlerror();
			fail(ss_("dlopen: ")+(e ? e : "?"));
			return;
		}
		free_fn = (FreeFn)dlsym(dl, "buildat_free");
		call_fn = (CallFn)dlsym(dl, "buildat_call");
		MemoryFn memory_fn = (MemoryFn)dlsym(dl, "buildat_memory");
		if(!free_fn || !call_fn || !memory_fn ||
				!dlsym(dl, "buildat_size") || !dlsym(dl, "buildat_instantiate")){
			fail("the built module lacks its entry points");
			return;
		}
		runtime_init();
		// The start function and the data segments run here
		const int code = trapping(this, 0, 0, nullptr, nullptr);
		if(mem)
			memory = memory_fn(mem);
		if(code != 0){
			fail("trap at start: "+(trap_reason.empty() ?
					ss_(wasm_rt_strerror((wasm_rt_trap_t)code)) : trap_reason));
			return;
		}
		state = READY;
	}

	// The child compile's progress, read without waiting
	void poll()
	{
		if(state != LOADING || pid <= 0)
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
				fail("the compile took over "+itos(COMPILE_WALL_S)+" s; killed");
			}
			return;
		}
		pid = 0;
		if(r < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0){
			std::ifstream f(dir+"/compile.log");
			ss_ line;
			for(int n = 0; std::getline(f, line) && n < 20; n++)
				log_w(MODULE, "wasm %s: compiler: %s", cs(name), cs(line));
			fail(WIFSIGNALED(status) ? "the compile was killed (signal "+
					itos(WTERMSIG(status))+"), past its limits?" :
					"the compile failed (its log above)");
			return;
		}
		if(rename((dir+"/"+tmp_so).c_str(), (dir+"/module.so").c_str())
				!= 0){
			fail("the compiled module went missing");
			return;
		}
		log_i(MODULE, "wasm %s: compiled in %i ms", cs(name), ms);
		ready_from(dir+"/module.so");
		if(state == READY)
			log_i(MODULE, "wasm %s: ready", cs(name));
	}

	void start_native(wabt::Module &m, const ss_ &hash_hex)
	{
		const Compiler &cc = compiler();
		if(cc.path.empty()){
			fail("no C compiler to build it with (the server's lookup: "
					"compiler/bin/c++, then c++ in PATH)");
			return;
		}
		has_imports = false;
		bool has_memory = false;
		for(const wabt::Import *imp : m.imports)
			if(imp->module_name == "buildat")
				has_imports = true;
		// The exports renamed to what the glue calls: f<i> in the order
		// of `exports`, mem for the memory named "memory", x<i> others
		size_t fi = 0, xi = 0;
		for(wabt::Export *e : m.exports){
			if(e->kind == wabt::ExternalKind::Func){
				e->name = "f"+itos(fi++);
			} else if(e->kind == wabt::ExternalKind::Memory &&
					e->name == "memory"){
				e->name = "mem";
				has_memory = true;
			} else {
				e->name = "x"+itos(xi++);
			}
		}
		const ss_ key = interface::sha1::hex(interface::sha1::calculate(
				hash_hex+"\n"+WABT_VERSION_STRING+"\n"+GLUE_VERSION+"\n"+
				cc.path+"\n"+cc.version+"\n"+cc.flags+"\n"+WASM2C_DEFINES));
		// The cache, the user's alone
		const ss_ root = g_client_config.get<ss_>("cache_path")+"/wasm2c";
		mkdir(g_client_config.get<ss_>("cache_path").c_str(), 0700);
		mkdir(root.c_str(), 0700);
		chmod(root.c_str(), 0700);
		dir = root+"/"+key.substr(0, 32);
		if(access((dir+"/module.so").c_str(), R_OK) == 0){
			log_i(MODULE, "wasm %s: compiled module from the cache (%s)",
					cs(name), cs(key.substr(0, 12)));
			ready_from(dir+"/module.so");
			if(state == READY)
				log_i(MODULE, "wasm %s: ready", cs(name));
			return;
		}
		mkdir(dir.c_str(), 0700);
		if(wabt::Failed(wabt::GenerateNames(&m))){
			fail("wasm2c could not name its functions");
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
			fail("wasm2c could not translate it");
			return;
		}
		const auto &cb = c_stream.output_buffer().data;
		const auto &hb = h_stream.output_buffer().data;
		if(!interface::fs::write_file(dir+"/m.c", ss_(cb.begin(), cb.end())) ||
				!interface::fs::write_file(dir+"/m.h", ss_(hb.begin(), hb.end())) ||
				!interface::fs::write_file(dir+"/wasm-rt.h", buildat_wasm_rt_h) ||
				!interface::fs::write_file(dir+"/glue.c",
						glue_c(exports, has_imports, has_memory))){
			fail("could not write into "+dir);
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
		// Its own output name: another client may be compiling the same
		tmp_so = "module."+itos(getpid())+".so.tmp";
		for(const ss_ &a : {ss_("-o"), tmp_so, ss_("m.c"), ss_("glue.c")})
			args.push_back(a);
		std::vector<char*> argv;
		for(ss_ &a : args)
			argv.push_back(&a[0]);
		argv.push_back(nullptr);
		const ss_ log_path = dir+"/compile.log";
		started = std::chrono::steady_clock::now();
		pid = fork();
		if(pid < 0){
			pid = 0;
			fail("fork failed");
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
			if(chdir(dir.c_str()) != 0)
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
		log_i(MODULE, "wasm %s: compiling (pid %i, %s)", cs(name), (int)pid,
				cs(key.substr(0, 12)));
	}
#endif

	~Instance()
	{
#if BUILDAT_WASM_NATIVE
		if(pid > 0){
			kill(-pid, SIGKILL);
			kill(pid, SIGKILL);
			waitpid(pid, nullptr, 0);
		}
		if(mem){
			if(free_fn)
				free_fn(mem);
			free(mem);
		}
		if(dl)
			dlclose(dl);
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
	const ss_ hash = interface::sha1::hex(interface::sha1::calculate(bytes));
	log_i(MODULE, "wasm %s: %zu bytes, %zu exports, valid (%s)", cs(name),
			bytes.size(), exports.size(), cs(hash.substr(0, 12)));
	Instance *in = new Instance();
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
#if BUILDAT_WASM_NATIVE
	in->start_native(m, hash);
#elif defined(__EMSCRIPTEN__)
	ss_ names;
	for(const ImportDef &d : IMPORTS)
		names += ss_(names.empty() ? "" : ",")+d.name;
	in->web_id = bw_new();
	bw_load(in->web_id, (const uint8_t*)bytes.data(), (int)bytes.size(),
			(int)(intptr_t)in, names.c_str());
	char *err = bw_take_error(in->web_id);
	if(err){
		in->fail(ss_("the browser: ")+err);
		free(err);
	} else {
		in->state = Instance::READY;
		log_i(MODULE, "wasm %s: ready (the browser's instance)", cs(name));
	}
#else
	in->fail("wasm modules do not run on this platform yet");
#endif
	return 1;
}

// m:status() -> "loading" | "ready" | "failed", why
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
	double result = 0;
	ss_ trap;
#if BUILDAT_WASM_NATIVE
	uint64_t r = 0;
	const int code = Instance::trapping(in, 1, (uint32_t)index, args, &r);
	if(code != 0)
		trap = wasm_rt_strerror((wasm_rt_trap_t)code);
	switch(sig.result){
	case 'i': result = (int32_t)(uint32_t)r; break;
	case 'I': result = (double)(int64_t)r; break;
	case 'f': { uint32_t u = (uint32_t)r; float f; memcpy(&f, &u, 4); result = f; } break;
	case 'F': memcpy(&result, &r, 8); break;
	}
#elif defined(__EMSCRIPTEN__)
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
	memcpy(&out[0], in->memory->data + (size_t)ptr, (size_t)len);
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
	memcpy(in->memory->data + (size_t)ptr, bytes, len);
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
