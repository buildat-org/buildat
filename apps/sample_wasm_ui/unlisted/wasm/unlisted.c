// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_wasm_ui: a module importing a call the sandbox's list does
// not name (extensions/sandbox_test's "Image:FlipHorizontal", which is off
// the whitelist): the client refuses it at the load, saying which import.
#include "interface/wasm_api.h"

#ifdef BUILDAT_WASM_MODULE
BUILDAT_WASM_EXTERN_C __attribute__((import_module("buildat"),
		import_name("Image:FlipHorizontal():boolean")))
int flip(const void *a, unsigned int b, void *c, unsigned int d);
#else
static int flip(const void *a, unsigned int b, void *c, unsigned int d)
{ (void)a; (void)b; (void)c; (void)d; __builtin_trap(); }
#endif

BUILDAT_WASM_EXPORT void frame(float dt)
{
	(void)dt;
	unsigned char out[16];
	flip("\0", 1, out, sizeof out);
}
