// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// What a server module's .wasm is written against ([SERVER_WASM]): a module
// whose meta.json says
//
//   "server_wasm": {"source": "server", "imports": ["packets", "storage"],
//       "callable": ["count"]}
//
// is not C++ but its server/ directory built to a .wasm by the server at
// its start -- a Rust crate (Cargo.toml, with the buildat_wasm_server
// crate) by cargo, or C and C++ (including this header) by clang, no libc
// -- and run sandboxed (src/server/wasm_module.cpp): it reaches the server
// only through the functions below, and only the groups of them meta.json
// grants ("imports"); a .wasm importing one it is not granted is refused
// at load, the import named. The functions without a group every module
// has. The server checks each call:
// - a pointer and a length are checked against the module's memory, and
//   the bytes copied before they are used; one past it is a trap;
// - scenes and nodes are handles (an int) of the module's own: a handle it
//   was not given, one dropped, and another module's are each a trap;
// - none calls into wasm, the module's own or another's: the server's
//   events are queued and taken with buildat_event_take().
// A trap stops the call that is running, and is logged; the module goes
// on. A call past its budget (about a second of a tight loop) stops the
// module for good; the server goes on.
//
// **What the server calls**, all exports taking and returning nothing:
// - init(): once, when the module starts (on its own thread, after the
//   modules it depends on). Subscribe to events here.
// - events(): after each event the module subscribed to is queued. Take
//   them with buildat_event_take() until it says there are none.
// - the exports meta.json names "callable": called by other modules'
//   buildat_call(), with buildat_call_input() and buildat_call_output().
// (An export's name may not begin with "buildat_": those are the engine's.)
//
// **The bytes at the boundary**: an event is little-endian 32-bit words,
// the first its kind, then its numbers, then a name or data as its bytes
// to the event's end -- as the client's events are (wasm_api.h), so that a
// crate both halves use reads both. A packet's data, a stored value and a
// call's input and output are the module's own bytes.
#pragma once

#ifdef __cplusplus
#define BUILDAT_SERVER_EXTERN_C extern "C"
#else
#define BUILDAT_SERVER_EXTERN_C
#endif
// An export the server calls: BUILDAT_SERVER_EXPORT void events(void)
#define BUILDAT_SERVER_EXPORT BUILDAT_SERVER_EXTERN_C \
		__attribute__((visibility("default")))
#define BUILDAT_SERVER_IMPORT(name) BUILDAT_SERVER_EXTERN_C \
		__attribute__((import_module("buildat"), import_name(#name)))

// ---- Every module's ----

// A line in the server's log, prefixed with the module's name. The bytes
// are text; at most 1000 are shown, and 100 lines a call.
BUILDAT_SERVER_IMPORT(log)
void buildat_log(const char *text, unsigned int len);

// Milliseconds since the module was loaded, whole ones. Wraps after 49 days.
BUILDAT_SERVER_IMPORT(time_ms)
unsigned int buildat_time_ms(void);

// The oldest queued event into buf: its length, which is taken only if it
// is at most cap (else it stays queued); -1 with none. At most 256 events
// or 4 MiB wait; past that new ones are dropped, and the log says so.
BUILDAT_SERVER_IMPORT(event_take)
int buildat_event_take(void *buf, unsigned int cap);

// The module is done with a handle: it names nothing from now on (a node
// stays in its scene, a scene stays until the module stops). A handle the
// module was not given, or one dropped, is a trap.
BUILDAT_SERVER_IMPORT(drop)
void buildat_drop(int handle);

// Inside a call of one of its "callable" exports (buildat_call()): the
// input into buf, its length, taken whole only if it is at most cap; -1
// outside such a call.
BUILDAT_SERVER_IMPORT(call_input)
int buildat_call_input(void *buf, unsigned int cap);
// The call's output, at most 1 MiB; a later one replaces it. Outside such
// a call it goes nowhere.
BUILDAT_SERVER_IMPORT(call_output)
void buildat_call_output(const void *data, unsigned int len);

// ---- "events" ----

// Subscribes to the server's event of this name (at most 64 a module), one
// of: "core:start" (all modules are loaded; START), "core:tick" (TICK),
// "network:client_connected" (PEER_JOINED), "network:client_disconnected"
// (PEER_LEFT). Another name is a trap.
BUILDAT_SERVER_IMPORT(event_subscribe)
void buildat_event_subscribe(const char *name, unsigned int len);

// ---- "packets" ----

// Subscribes to the packets named "<module>:<name>" (the module's own: a
// name is [A-Za-z0-9_], 1 to 64 bytes) that peers send; each comes as a
// PACKET event.
BUILDAT_SERVER_IMPORT(packet_subscribe)
void buildat_packet_subscribe(const char *name, unsigned int len);

// A packet named "<module>:<name>" to a peer, sent when the call this is
// in returns (nothing from a call that traps). The data is at most 65536
// bytes, and 256 packets a call. A peer that has gone is not sent to.
BUILDAT_SERVER_IMPORT(packet_send)
void buildat_packet_send(unsigned int peer, const char *name,
		unsigned int name_len, const void *data, unsigned int data_len);

// ---- "storage": the module's own keys and values, kept across restarts ----

// The value of a key (1 to 256 bytes) into out: its length, written only if
// it is at most cap; -1 if there is none.
BUILDAT_SERVER_IMPORT(storage_get)
int buildat_storage_get(const void *key, unsigned int key_len, void *out,
		unsigned int cap);
// A key's value set, at most 1 MiB; a module's keys and values are at most
// 64 MiB in all (past it, a trap).
BUILDAT_SERVER_IMPORT(storage_set)
void buildat_storage_set(const void *key, unsigned int key_len,
		const void *value, unsigned int value_len);
BUILDAT_SERVER_IMPORT(storage_remove)
void buildat_storage_remove(const void *key, unsigned int key_len);

// ---- "scene": scenes and their nodes, as replicate sends them to peers ----

// A new scene (main_context's), at most 4 a module; deleted when the module
// stops. Its handle.
BUILDAT_SERVER_IMPORT(scene_create)
int buildat_scene_create(void);
// The scene shown to a connected peer (replicate's): its nodes are sent to
// it from now on. Scene 0: none.
BUILDAT_SERVER_IMPORT(scene_peer)
void buildat_scene_peer(int scene, unsigned int peer);
// A new node at the scene's root, replicated; its handle.
BUILDAT_SERVER_IMPORT(node_create)
int buildat_node_create(int scene);
// A node's transform, 10 floats: position x, y, z, rotation w, x, y, z,
// scale x, y, z. A value that is not finite, or past 1e9, is a trap.
BUILDAT_SERVER_IMPORT(node_get)
void buildat_node_get(int node, float transform[10]);
BUILDAT_SERVER_IMPORT(node_set)
void buildat_node_set(int node, const float transform[10]);
// The node removed from its scene, its handle dropped
BUILDAT_SERVER_IMPORT(node_remove)
void buildat_node_remove(int node);

// ---- "voxels": a voxel world in a scene of the module's (voxelworld's) ----

// The scene's voxel world, its bounds in sections: sections[0..2] the lowest
// section, sections[3..5] the highest, at most 8 apart on each axis and 64
// sections in all, loaded whole. Once a scene.
BUILDAT_SERVER_IMPORT(world_create)
void buildat_world_create(int scene, const int sections[6]);
// A voxel type of the scene's world (at most 256 a module): a name
// ([a-z0-9_:], 1 to 64 bytes) and the texture its faces show (a file the
// clients have, e.g. "main/rock.png"; none for an empty voxel: air). Its id.
BUILDAT_SERVER_IMPORT(voxel_define)
int buildat_voxel_define(int scene, const char *name, unsigned int name_len,
		const char *texture, unsigned int texture_len);
// The voxels of a box of the world -- box[0..2] its lowest corner, box[3..5]
// its size -- set from ids, a voxel type id (the module's) per voxel, x
// fastest, then y, then z; ids_bytes is the box's voxels * 4. At most
// 1048576 voxels a call.
BUILDAT_SERVER_IMPORT(voxels_set)
void buildat_voxels_set(int scene, const int box[6], const unsigned int *ids,
		unsigned int ids_bytes);
// The ids of a box's voxels into out, which has room for out_bytes; how
// many it wrote. A voxel nothing has set reads as 0 (undefined).
BUILDAT_SERVER_IMPORT(voxels_read)
int buildat_voxels_read(int scene, const int box[6], unsigned int *out,
		unsigned int out_bytes);

// ---- "calls": other modules' exports ----

// Calls the export fn of the wasm module named module -- one its meta.json
// names "callable" -- with input (at most 1 MiB), on that module's thread,
// and waits for it: the output's length, written into out only if it is
// at most out_cap; -1 if the call was refused or failed (no such module or
// export, not callable, the callee stopped or trapped, the callee already
// in this call's chain, or another call between modules under way for more
// than 100 ms); the log says which.
BUILDAT_SERVER_IMPORT(call)
int buildat_call(const char *module, unsigned int module_len, const char *fn,
		unsigned int fn_len, const void *input, unsigned int input_len,
		void *out, unsigned int out_cap);

// ---- The events' kinds ----
// Each event is little-endian 32-bit words, the first its kind:
// - START: none more.
// - TICK: the seconds since the last one, a float's bits.
// - PEER_JOINED, PEER_LEFT: the peer.
// - PACKET: the peer, the name's length, the name's bytes (without
//   "<module>:"), then the data to the event's end.
#define BUILDAT_SERVER_EVENT_START 1
#define BUILDAT_SERVER_EVENT_TICK 2
#define BUILDAT_SERVER_EVENT_PEER_JOINED 3
#define BUILDAT_SERVER_EVENT_PEER_LEFT 4
#define BUILDAT_SERVER_EVENT_PACKET 5
// vim: set noet ts=4 sw=4:
