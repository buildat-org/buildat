// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [SERVER_WASM] What a server module's .wasm may import, all from "buildat",
// all i32: interface/wasm_server_api.h's functions, as the server checks
// them (src/server/wasm_module.cpp). Each is in a group a module's
// meta.json grants ("server_wasm": {"imports": [...]}), or in none: those
// every module has. A module importing one of a group it is not granted
// is refused at load, the import named.
#pragma once

namespace server
{
	enum WasmImport {
		WI_LOG, WI_TIME_MS, WI_EVENT_TAKE,
		WI_EVENT_SUBSCRIBE,
		WI_COUNT
	};
	struct WasmImportDef { const char *name; int params; bool result;
			const char *grant; };
	static const WasmImportDef WASM_IMPORTS[WI_COUNT] = {
		{"log", 2, false, ""},
		{"time_ms", 0, true, ""},
		{"event_take", 2, true, ""},
		{"event_subscribe", 2, false, "events"},
	};
	// The groups, as meta.json names them
	static const char *const WASM_GRANTS[] = {"events"};
}
// vim: set noet ts=4 sw=4:
