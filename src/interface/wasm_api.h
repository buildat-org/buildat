// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// What a module's wasm/ code is written against ([CLIENT_WASM]): the server
// builds wasm/*.c, *.cc and *.cpp with clang --target=wasm32, no libc, and
// serves the .wasm to clients, which run it as a sandboxed module of its own
// and call its exports from Lua (buildat.wasm_load(), doc/client_api.txt).
//
// simplified: step 1 of [CLIENT_WASM] -- the export macro and a log line.
// The voxel, geometry, transform, time and packet imports come with the
// rest of the API (doc/plan/web_client_plan.md).
#pragma once

#ifdef __cplusplus
#define BUILDAT_WASM_EXTERN_C extern "C"
#else
#define BUILDAT_WASM_EXTERN_C
#endif

// A function Lua can call: BUILDAT_WASM_EXPORT int add(int a, int b)
#define BUILDAT_WASM_EXPORT BUILDAT_WASM_EXTERN_C \
		__attribute__((visibility("default")))

// A line in the client's log, prefixed with the module's name. The bytes
// are text; at most 1000 are shown.
BUILDAT_WASM_EXTERN_C
__attribute__((import_module("buildat"), import_name("log")))
void buildat_log(const char *text, unsigned int len);
