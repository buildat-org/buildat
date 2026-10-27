// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// What a module's wasm/ code is written against ([CLIENT_WASM]): the server
// builds wasm/*.c, *.cc and *.cpp with clang --target=wasm32, no libc, and
// serves the .wasm to clients, which run it as a sandboxed module of its own
// and call its exports from Lua (buildat.wasm_load(), doc/client_api.txt).
//
// The imports below, and interface/buildat_client.h's (the Lua sandbox's
// classes, [CLIENT_WASM_BINDINGS]), are all a module can call, each
// checked by the client (natively and on the web alike):
// - a pointer and a length are checked against the module's memory, and
//   the bytes copied before they are used; one past it is a trap;
// - nodes, textures and voxel volumes are handles (an int), given to the
//   module by its own Lua (m:handle(object)); a handle the module was not
//   given, one dropped or whose object is gone, and another module's are
//   each a trap;
// - none calls into Lua or back into wasm: what Lua has for the module
//   (packets, input) is queued with m:push() and taken with
//   buildat_event_take(), and the packets the module sends go out when the
//   call it is in returns.
// A trap stops the call that is running; Lua's m:call() is then an error,
// and the client logs why.
#pragma once

#ifdef __cplusplus
#define BUILDAT_WASM_EXTERN_C extern "C"
#else
#define BUILDAT_WASM_EXTERN_C
#endif

// BUILDAT_WASM_MODULE: this is the client's .wasm being built (clang
// --target=wasm32), not the server's native build of the same files --
// which on the web's server (Emscripten, [WEB_LOCAL_SERVER]) is wasm too
#if defined(__wasm__) && !defined(__EMSCRIPTEN__)
#define BUILDAT_WASM_MODULE 1
#endif

#ifdef BUILDAT_WASM_MODULE
// A function Lua can call: BUILDAT_WASM_EXPORT int add(int a, int b)
#define BUILDAT_WASM_EXPORT BUILDAT_WASM_EXTERN_C \
		__attribute__((visibility("default")))

#define BUILDAT_WASM_IMPORT(name) BUILDAT_WASM_EXTERN_C \
		__attribute__((import_module("buildat"), import_name(#name)))
#else
// The server compiles the same files natively into the module ([CLIENT_WASM]
// step 5), which calls them as plain functions: an export is a function
// of the module's own (hidden, as the rest of it), and the imports, which
// are the client's, stop the server if reached (the bottom of this file).
#define BUILDAT_WASM_EXPORT BUILDAT_WASM_EXTERN_C
#define BUILDAT_WASM_IMPORT(name) static inline
#endif

// A line in the client's log, prefixed with the module's name. The bytes
// are text; at most 1000 are shown.
BUILDAT_WASM_IMPORT(log)
void buildat_log(const char *text, unsigned int len);

// Milliseconds since the module was loaded, whole ones (a coarse clock, on
// purpose: see the plan's side channels). Wraps after 49 days.
BUILDAT_WASM_IMPORT(time_ms)
unsigned int buildat_time_ms(void);

// A voxel volume's region (a handle Lua gave, of a buildat.Volume: a
// chunk's is voxelworld's get_volume(node)): out[0..2] its lowest corner,
// out[3..5] its size in voxels, x, y, z.
BUILDAT_WASM_IMPORT(voxels_size)
void buildat_voxels_size(int volume, int out[6]);

// The voxels of a box of it -- box[0..2] its lowest corner, box[3..5] its
// size, inside the volume's region -- as each voxel's first plane (a
// VoxelInstance's 32 bits), x fastest, then y, then z, into out, which has
// room for out_bytes. Returns how many it wrote. At most 4194304 voxels.
BUILDAT_WASM_IMPORT(voxels_read)
int buildat_voxels_read(int volume, const int box[6], unsigned int *out,
		unsigned int out_bytes);

// A vertex count of a vertex buffer, 12 floats a vertex (position, normal,
// colour r, g, b, a, texture coordinate), and an index buffer of triangles
// into it as a node's geometry number `geometry` (0 to 15). The node's
// CustomGeometry is the one its Lua made, with the material it gave; one
// geometry may have 196608 indices, a module 1048576 in all.
BUILDAT_WASM_IMPORT(geometry_set)
void buildat_geometry_set(int node, unsigned int geometry,
		const float *vertices, unsigned int vertex_count,
		const unsigned int *indices, unsigned int index_count);

// A texture's size and pixels, RGBA, 8 bits each, rows from the top;
// `len` is width * height * 4. At most 4096 across, and 64 MiB of
// textures a module.
BUILDAT_WASM_IMPORT(texture_set)
void buildat_texture_set(int texture, unsigned int width, unsigned int height,
		const unsigned char *rgba, unsigned int len);

// A node's transform, in its parent's space, 10 floats: position x, y, z,
// rotation w, x, y, z, scale x, y, z. A value that is not finite, or past
// 1e9, is a trap.
BUILDAT_WASM_IMPORT(node_get)
void buildat_node_get(int node, float transform[10]);
BUILDAT_WASM_IMPORT(node_set)
void buildat_node_set(int node, const float transform[10]);

// A packet to the server, named "<module>:<name>" (the module's own), sent
// when the call this is in returns. A name is [A-Za-z0-9_] and at most 64
// bytes, the data at most 65536; at most 64 packets a call.
BUILDAT_WASM_IMPORT(send_packet)
void buildat_send_packet(const char *name, unsigned int name_len,
		const void *data, unsigned int data_len);

// The oldest event Lua queued (m:push(bytes)) into buf: its length, which
// is taken only if it is at most cap; -1 with none.
BUILDAT_WASM_IMPORT(event_take)
int buildat_event_take(void *buf, unsigned int cap);

// The module is done with a handle ([CLIENT_WASM_BINDINGS]): it names
// nothing from now on, and what it named is no longer kept alive by it. A
// handle the module was not given, or one dropped, is a trap.
BUILDAT_WASM_IMPORT(drop)
void buildat_drop(int handle);

// **The default client_main** ([CLIENT_WASM] step 7): a module whose
// meta.json says "client_main": "wasm" has no Lua of its own; the engine's
// (builtin/client_lua/client_lua/wasm_main.lua) loads its .wasm, makes a
// scene for it -- a camera, a directional light and 8 nodes, each with a
// CustomGeometry whose material shows the vertex colours times the node's
// own texture (white until set) -- and calls its exports:
// - void frame(float dt): each frame, dt the seconds since the last one.
//   The module takes its events here, with buildat_event_take(), and
//   draws through the imports above. A trap is logged and the next frame
//   calls it again; a module the meter stops is not called again.
// - const char *packets(void), optional: the names of the packets it is
//   sent, without "<module>:", separated by spaces, ending in a 0 byte
//   (at most 4096 bytes); each comes to it as BUILDAT_EVENT_PACKET.
// (An export's name may not begin with "buildat_": those are the
// engine's.) It also binds interface/buildat_client.h's calls -- the Lua
// sandbox's classes, the UI's included, as wasm imports
// ([CLIENT_WASM_BINDINGS]) -- so that a module needs no Lua of its own.
//
// Each event from it is little-endian 32-bit words, the first its kind:
// - START, first, once: camera node, light node, the window's width and
//   height in pixels, n (8), then n pairs of a mesh node and its texture.
//   All are handles for the imports above.
// - KEY_DOWN: key, repeat (1 for a key repeat), qualifiers (shift 1, ctrl
//   2, alt 4). A key is Urho3D's (SDL's) code: a letter its lowercase
//   ASCII, space 32. KEY_UP: key.
// - MOUSE_DOWN, MOUSE_UP: button (left 1, middle 2, right 4).
// - MOUSE_MOVE: x, y in window pixels, dx, dy. WHEEL: its steps, + up.
// - PACKET: the name's length, then the name's bytes, then the data to the
//   event's end.
// - RESIZE: the window's width and height.
// - OBJECT ([CLIENT_WASM_BINDINGS], interface/buildat_client.h): an
//   object's event the module subscribed to: the handle it subscribed
//   with, the event's name's length, then the name's bytes.
// None is longer than BUILDAT_EVENT_MAX bytes: a buffer of that size
// takes each (buildat_event_take() leaves one that does not fit queued).
// Keys the client keeps (F9 to F12, and all while a password is typed)
// do not come.
#define BUILDAT_EVENT_START 1
#define BUILDAT_EVENT_KEY_DOWN 2
#define BUILDAT_EVENT_KEY_UP 3
#define BUILDAT_EVENT_MOUSE_DOWN 4
#define BUILDAT_EVENT_MOUSE_UP 5
#define BUILDAT_EVENT_MOUSE_MOVE 6
#define BUILDAT_EVENT_WHEEL 7
#define BUILDAT_EVENT_PACKET 8
#define BUILDAT_EVENT_RESIZE 9
#define BUILDAT_EVENT_OBJECT 10
#define BUILDAT_EVENT_MAX (8 + 64 + 65536)

#ifndef BUILDAT_WASM_MODULE
static inline void buildat_log(const char *a, unsigned int b)
{ (void)a; (void)b; __builtin_trap(); }
static inline unsigned int buildat_time_ms(void){ __builtin_trap(); }
static inline void buildat_voxels_size(int a, int b[6])
{ (void)a; (void)b; __builtin_trap(); }
static inline int buildat_voxels_read(int a, const int b[6], unsigned int *c,
		unsigned int d){ (void)a; (void)b; (void)c; (void)d; __builtin_trap(); }
static inline void buildat_geometry_set(int a, unsigned int b, const float *c,
		unsigned int d, const unsigned int *e, unsigned int f)
{ (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; __builtin_trap(); }
static inline void buildat_texture_set(int a, unsigned int b, unsigned int c,
		const unsigned char *d, unsigned int e)
{ (void)a; (void)b; (void)c; (void)d; (void)e; __builtin_trap(); }
static inline void buildat_node_get(int a, float b[10])
{ (void)a; (void)b; __builtin_trap(); }
static inline void buildat_node_set(int a, const float b[10])
{ (void)a; (void)b; __builtin_trap(); }
static inline void buildat_send_packet(const char *a, unsigned int b,
		const void *c, unsigned int d)
{ (void)a; (void)b; (void)c; (void)d; __builtin_trap(); }
static inline int buildat_event_take(void *a, unsigned int b)
{ (void)a; (void)b; __builtin_trap(); }
static inline void buildat_drop(int a){ (void)a; __builtin_trap(); }
#endif
