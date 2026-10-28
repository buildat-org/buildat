// SPDX-License-Identifier: Apache-2.0 OR MIT
// [CLIENT_WASM] step 7: a module's .wasm as a server hands it to a client,
// through what the client does to it before anything of it runs, then
// run: src/wasm/engine.cpp's check_module() (WABT's reader and
// validator, and the caps), meter_module() (and the validation after it),
// prepare_native() and movable(); the metered module written out (WABT's
// binary writer: what the browser and the interpreter get) and translated
// to C (wasm2c's writer, what the native client compiles); and the
// written bytes loaded, instantiated and each export called in WAMR's
// interpreter (its loader validates again) with a small budget, every
// import a trap. What is not here: the C compile and the browser.
//
// fuzz.sh compiles WABT and WAMR into this harness, instrumented, and
// includes engine.cpp with BUILDAT_WASM_FUZZ, which leaves out its
// instances and compiles. The imports allowed are the client's
// (src/lua_bindings/wasm.cpp's set_client_imports()). A slow input (a
// huge memory, a long loop under the budget) is a server denying its
// client service and out of scope;
// memory corruption in the checks, the meter, WABT or WAMR is a finding.
#define BUILDAT_WASM_FUZZ 1
#include "wasm/engine.cpp"

using namespace wasm_engine;

// The client's imports: wasm_api.h's and the bindings as g<k>
static ImportSet client_imports()
{
	static const struct { const char *name; int params; bool result; } API[] = {
		{"log", 2, false}, {"time_ms", 0, true}, {"voxels_size", 2, false},
		{"voxels_read", 4, true}, {"geometry_set", 6, false},
		{"texture_set", 5, false}, {"node_get", 2, false},
		{"node_set", 2, false}, {"send_packet", 4, false},
		{"event_take", 2, true}, {"drop", 1, false},
	};
	static const char *const BINDINGS[] = {
#define BUILDAT_BINDING(n, k, c, m) n,
#include "lua_bindings/wasm_bindings.inc"
#undef BUILDAT_BINDING
	};
	ImportSet set;
	set.what = "the client's";
	for(const auto &a : API)
		set.defs.push_back({a.name, a.name, a.params, a.result});
	size_t k = 0;
	for(const char *n : BINDINGS)
		set.defs.push_back({n, "g"+itos(k++), 4, true});
	return set;
}


// A small budget: a run stops soon, the meter's trap is still reached
static const int64_t FUZZ_BUDGET = 200000;

static void trap_import(wasm_exec_env_t env, uint64_t *args)
{
	(void)args;
	wasm_runtime_set_exception(wasm_runtime_get_module_inst(env),
			"an import trapped");
}

static bool wamr_init()
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
	wasm_runtime_set_log_level(WASM_LOG_LEVEL_FATAL);
	// Both sets' names, by the names they are renamed to (the bindings'
	// g<k> are not called with numbers that matter: each traps)
	static std::map<ss_, ss_> sigs;
	for(const ImportSet &set : {client_imports()})
		for(const ImportDef &d : set.defs)
			sigs[d.c_name] = "("+ss_(d.params, 'i')+")"+(d.result ? "i" : "");
	static sv_<ss_> names;
	static sv_<NativeSymbol> syms;
	for(const auto &it : sigs)
		names.push_back(it.first);
	syms.resize(names.size());
	for(size_t k = 0; k < names.size(); k++){
		syms[k].symbol = names[k].c_str();
		syms[k].func_ptr = (void*)trap_import;
		syms[k].signature = sigs[names[k]].c_str();
		syms[k].attachment = (void*)(uintptr_t)k;
	}
	if(!wasm_runtime_register_natives_raw("buildat", syms.data(),
			(uint32_t)syms.size()))
		return false;
	done = 1;
	return true;
}

static void run(sv_<uint8_t> bytes, const sv_<ExportSig> &exports,
		bool has_start)
{
	if(!wamr_init())
		abort();
	char err[200] = "";
	wasm_module_t wm = wasm_runtime_load(bytes.data(), (uint32_t)bytes.size(),
			err, sizeof err);
	if(!wm)
		return;
	wasm_module_inst_t wi = wasm_runtime_instantiate(wm, 176 << 10, 0, err,
			sizeof err);
	wasm_exec_env_t we = wi ? wasm_runtime_create_exec_env(wi, 176 << 10) :
			nullptr;
	int64_t *meter = nullptr;
	wasm_global_inst_t g;
	if(wi && wasm_runtime_get_export_global_inst(wi, METER, &g) &&
			g.kind == WASM_I64 && g.is_mutable)
		meter = (int64_t*)g.global_data;
	if(we && meter){
		sv_<std::pair<wasm_function_inst_t, const ExportSig*>> calls;
		if(has_start)
			calls.push_back({wasm_runtime_lookup_function(wi, START), nullptr});
		for(size_t i = 0; i < exports.size(); i++)
			calls.push_back({wasm_runtime_lookup_function(wi,
					("f"+itos(i)).c_str()), &exports[i]});
		for(auto &c : calls){
			if(!c.first)
				continue;
			*meter = FUZZ_BUDGET;
			wasm_val_t args[MAX_PARAMS], res[1];
			memset(args, 0, sizeof args);
			memset(res, 0, sizeof res);
			uint32_t nargs = 0, nres = 0;
			if(c.second){
				nargs = (uint32_t)c.second->params.size();
				nres = c.second->result ? 1 : 0;
				for(uint32_t k = 0; k < nargs; k++){
					switch(c.second->params[k]){
					case 'i': args[k].kind = WASM_I32; args[k].of.i32 = 7; break;
					case 'I': args[k].kind = WASM_I64; args[k].of.i64 = 7; break;
					case 'f': args[k].kind = WASM_F32; args[k].of.f32 = 7; break;
					case 'F': args[k].kind = WASM_F64; args[k].of.f64 = 7; break;
					}
				}
			}
			if(!wasm_runtime_call_wasm_a(we, c.first, nres, res, nargs, args))
				wasm_runtime_clear_exception(wi);
		}
	}
	if(we)
		wasm_runtime_destroy_exec_env(we);
	if(wi)
		wasm_runtime_deinstantiate(wi);
	wasm_runtime_unload(wm);
}

static void one(const uint8_t *data, size_t size);

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	static const ImportSet sets[] = {client_imports()};
	for(const ImportSet &set : sets){
		set_imports(set);
		one(data, size);
	}
	return 0;
}

static void one(const uint8_t *data, size_t size)
{
	const ss_ bytes((const char*)data, size);
	wabt::Module m;
	sv_<ExportSig> exports;
	bool has_imports = false, has_start = false, has_memory = false;
	ss_ why;
	if(!check_module(bytes, m, exports, has_imports, why))
		return;
	if(!meter_module(m, has_start, why))
		return;
	sv_<GlobalCopy> globals;
	prepare_native(m, has_memory, globals);
	(void)movable(m, has_memory);
	wabt::MemoryStream prepared;
	if(wabt::Failed(wabt::WriteBinaryModule(&prepared, &m,
			wabt::WriteBinaryOptions(features(), true, false, false))))
		return;
	sv_<uint8_t> written(prepared.output_buffer().data.begin(),
			prepared.output_buffer().data.end());
	// What the engine compiles, as it makes it (Impl::start_native())
	if(wabt::Succeeded(wabt::GenerateNames(&m))){
		(void)wabt::ApplyNames(&m);
		wabt::MemoryStream c_stream, h_stream;
		wabt::WriteCOptions wo;
		wo.module_name = "m";
		std::vector<wabt::Stream*> c_streams = {&c_stream};
		(void)wabt::WriteC(std::move(c_streams), &h_stream, &c_stream, "m.h",
				"", &m, wo);
	}
	run(std::move(written), exports, has_start);
	return;
}
