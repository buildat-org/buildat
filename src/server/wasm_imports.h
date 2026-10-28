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
		WI_LOG, WI_TIME_MS, WI_EVENT_TAKE, WI_DROP, WI_CALL_INPUT,
		WI_CALL_OUTPUT,
		WI_EVENT_SUBSCRIBE,
		WI_PACKET_SUBSCRIBE, WI_PACKET_SEND,
		WI_STORAGE_GET, WI_STORAGE_SET, WI_STORAGE_REMOVE,
		WI_SCENE_CREATE, WI_SCENE_PEER, WI_NODE_CREATE, WI_NODE_GET,
		WI_NODE_SET, WI_NODE_REMOVE,
		WI_WORLD_CREATE, WI_VOXEL_DEFINE, WI_VOXELS_SET, WI_VOXELS_READ,
		WI_CALL,
		WI_COUNT
	};
	struct WasmImportDef { const char *name; int params; bool result;
			const char *grant; };
	static const WasmImportDef WASM_IMPORTS[WI_COUNT] = {
		{"log", 2, false, ""},
		{"time_ms", 0, true, ""},
		{"event_take", 2, true, ""},
		{"drop", 1, false, ""},
		{"call_input", 2, true, ""},
		{"call_output", 2, false, ""},
		{"event_subscribe", 2, false, "events"},
		{"packet_subscribe", 2, false, "packets"},
		{"packet_send", 5, false, "packets"},
		{"storage_get", 4, true, "storage"},
		{"storage_set", 4, false, "storage"},
		{"storage_remove", 2, false, "storage"},
		{"scene_create", 0, true, "scene"},
		{"scene_peer", 2, false, "scene"},
		{"node_create", 1, true, "scene"},
		{"node_get", 2, false, "scene"},
		{"node_set", 2, false, "scene"},
		{"node_remove", 1, false, "scene"},
		{"world_create", 2, false, "voxels"},
		{"voxel_define", 5, true, "voxels"},
		{"voxels_set", 4, false, "voxels"},
		{"voxels_read", 4, true, "voxels"},
		{"call", 8, true, "calls"},
	};
	// The groups, as meta.json names them
	static const char *const WASM_GRANTS[] = {"events", "packets", "storage",
			"scene", "voxels", "calls"};
}
// vim: set noet ts=4 sw=4:
