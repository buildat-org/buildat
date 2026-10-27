// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_wasm_ui: a module importing a call of the list by its name
// with another signature (as one built against an older engine API might):
// the client refuses it at the load, saying which import.
#include "interface/wasm_api.h"

#ifdef BUILDAT_WASM_MODULE
BUILDAT_WASM_EXTERN_C __attribute__((import_module("buildat"),
		import_name("Node.position:Vector3")))
int position(int node);
#else
static int position(int node){ (void)node; __builtin_trap(); }
#endif

BUILDAT_WASM_EXPORT void frame(float dt)
{
	(void)dt;
	position(1);
}
