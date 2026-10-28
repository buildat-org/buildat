// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [CLIENT_WASM] A module's wasm/, built by the server to a .wasm, run on
// the client as a sandbox of its own, its exports called from Lua.
//
// What runs it -- the checks, the caps, the meter, wasm2c and the compile,
// WAMR's interpreter, the browser's instance -- is src/wasm/engine.cpp,
// which the server's wasm modules share ([SERVER_WASM]). This is the
// client's half: its imports (interface/wasm_api.h, and the bindings of
// interface/buildat_client.h) and the Lua that loads and calls a module.
//
// The imports are the same C++ on both clients (Instance::import_body()
// below, through the engine's run_import()). Each checks every pointer and
// length against the module's memory and copies the bytes, names objects
// by handles from a table of the instance's own, and calls neither Lua nor
// wasm -- but for the bindings ([CLIENT_WASM_BINDINGS], binding_import()),
// which are calls of the Lua sandbox's own list made through the module's
// dispatcher in its sandbox, as its script would make them; no wasm call
// starts while one runs (g_import_depth).
#include "lua_bindings/util.h"
#include "interface/voxel_volume.h"
#include "wasm/engine.h"
#include <tolua++.h>
#include <luabind/luabind.hpp>
#include <Node.h>
#include <CustomGeometry.h>
#include <Texture2D.h>
#include <Image.h>
#include "core/log.h"
#if (defined(__linux__) || defined(_WIN32)) && !defined(__EMSCRIPTEN__)
#define BUILDAT_WASM_NATIVE 1
#include "client/config.h"
#endif
#include <cctype>
#include <deque>
#include <map>
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

using namespace wasm_engine;

// The imports' caps ([CLIENT_WASM] step 2), per module (instance); the
// engine's own (the module's size, memory, exports) are wasm/engine.h's
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
	IMP_EVENT_TAKE, IMP_DROP, IMP_COUNT
};
struct ImportSpec { const char *name; int params; bool result; };
static const ImportSpec IMPORTS[IMP_COUNT] = {
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
	{"drop", 1, false},
};

// [CLIENT_WASM_BINDINGS] The imports generated from the Lua sandbox's own
// list (util/gen_wasm_bindings.lua writes wasm_bindings.inc and
// interface/buildat_client.h): each the call its name says -- "Node:
// SetPosition(Vector3)", "Text.text=string" -- made through the module's
// dispatcher, a Lua function in the module's sandbox (m:bind(), the
// default client_main's), as a script's own call is: what Lua is refused,
// these are refused. All are (args, args_len, ret, ret_cap) -> the
// results' length, the values encoded as buildat_client.h says. Validation
// allows exactly these names with that signature; each is then renamed
// g<k> (k its index here), so that the C and the interpreter see no name
// of the module's. The import's index is IMP_COUNT + k.
struct BindingDef { const char *name, *kind, *cls, *member; };
static const BindingDef BINDINGS[] = {
#define BUILDAT_BINDING(n, k, c, m) {n, k, c, m},
#include "lua_bindings/wasm_bindings.inc"
#undef BUILDAT_BINDING
};
static const size_t BINDING_COUNT = sizeof BINDINGS / sizeof BINDINGS[0];
static const size_t IMP_ALL = IMP_COUNT + BINDING_COUNT;
// The values carried by their components (Vector3, Color, ...), by kind
struct ValueDef { unsigned int kind; const char *cls; int n; const char *c[4]; };
static const ValueDef VALUE_DEFS[] = {
#define BUILDAT_VALUE(k, cls, n, a, b, c, d) {k, cls, n, {a, b, c, d}},
#include "lua_bindings/wasm_bindings.inc"
#undef BUILDAT_VALUE
};
// The fields of the sandbox's whitelisted events (safe_events.lua), by
// event, each in the order an event's payload carries them; "command_seq:"
// is every event of that prefix
struct EventFieldDef { const char *event, *field, *variant, *safe; };
static const EventFieldDef EVENT_FIELDS[] = {
#define BUILDAT_EVENT_FIELD(e, f, v, s) {e, f, v, s},
#include "lua_bindings/wasm_bindings.inc"
#undef BUILDAT_EVENT_FIELD
};
// A binding call's values, in and out, and how many
static const size_t MAX_BINDING_BYTES = 1 << 20;
static const unsigned int MAX_BINDING_VALUES = 32;
// Its charge, as IMPORT_COST: a call into the sandbox's Lua, its time in
// units of a compiled module's own code. Measured 2026-10-28
// (apps/sample_wasm_ui's "cost" lines): a property read with a Vector3
// back 6 us natively (compiled or interpreted alike) and 17-22 us on the
// web, a method call with a number back 1-2 us and 7.5-9 us; plain code
// runs about 12 units a ns natively compiled and 4-7 on the web. The web's
// property read, 20 us at 4-5 units a ns, makes the budget (BUDGET) about
// a second of nothing but bindings there, and 0.3 s natively. The
// interpreter is charged its share (budget()), so that its smaller budget
// holds as many.
static const uint64_t BINDING_COST = 80000;

// The client's imports, the engine's ImportSet: wasm_api.h's by their own
// names, then the bindings as g<k>
static void set_client_imports()
{
	ImportSet set;
	set.what = "wasm_api.h's or buildat_client.h's";
	for(const ImportSpec &s : IMPORTS){
		ImportDef d;
		d.name = d.c_name = s.name;
		d.params = s.params;
		d.result = s.result;
		set.defs.push_back(d);
	}
	for(size_t k = 0; k < BINDING_COUNT; k++){
		ImportDef d;
		d.name = BINDINGS[k].name;
		d.c_name = "g"+itos(k);
		d.params = 4;
		d.result = true;
		set.defs.push_back(d);
	}
	set_imports(set);
}

// The client's Lua (init_wasm()): the handles' and the dispatchers'
// references are in its registry
static lua_State *g_L = nullptr;
// A binding's Lua is running ([CLIENT_WASM_BINDINGS]): no wasm call starts
// meanwhile, of this module or another, so that no import re-enters wasm
static int g_import_depth = 0;
#ifdef __EMSCRIPTEN__
// [WASM_WEB_IMPORT_DEPTH] On the web the browser's stack can run out
// inside the client's own code during a binding's Lua, and its RangeError
// unwinds through the client to bw_call()'s catch: no destructor, no
// lua_pcall's error path and no g_import_depth-- run. What lua_pcall would
// restore is kept here while a binding runs, for l_wasm_call() to put back
// (lua_unwind_restore(), with Lua's internals at the end of this file).
struct LuaUnwind {
	lua_State *L = nullptr;
	ptrdiff_t top = 0, ci = 0, errfunc = 0;
	void *error_jmp = nullptr;
	unsigned short n_ccalls = 0;
	unsigned char allowhook = 0;
};
static void lua_unwind_save(LuaUnwind &u, lua_State *L);
static void lua_unwind_restore(const LuaUnwind &u);
static struct {
	bool active = false;
	// The binding's Lua, and the client's main state, where Urho3D's event
	// handlers run, if another
	LuaUnwind call, main;
} g_binding_unwind;
#endif

struct Instance: public Engine
{
	// The handles (wasm/engine.h's Handles). Each holds what Lua handed
	// for it (the sandbox's wrapper, or a Volume) by a reference in the
	// registry, so that the object lives while the module has the handle,
	// as a script's reference keeps it ([CLIENT_WASM_BINDINGS]); OBJECT is
	// any other object of the list.
	struct Slot {
		enum Kind { NONE, NODE, TEXTURE, VOLUME, OBJECT } kind = NONE;
		int ref = LUA_NOREF;
		Urho3D::WeakPtr<Urho3D::Node> node;
		Urho3D::WeakPtr<Urho3D::Texture2D> texture;
		std::weak_ptr<interface::VoxelVolume> volume;
		uint64_t indices[MAX_GEOMETRIES] = {}; // counted against the caps
		uint64_t texture_bytes = 0;
	};
	Handles<Slot> handles;
	uint64_t indices_all = 0, texture_bytes_all = 0;
	// Events Lua queued (m:push), and the packets the call sends
	std::deque<ss_> events;
	size_t event_bytes = 0;
	sv_<std::pair<ss_, ss_>> sent;

	// The module's dispatcher (m:bind()), a reference in the registry
	int bind_ref = LUA_NOREF;
	// The Lua running the module's call (m:call()), which its bindings'
	// calls are made on; null outside a call
	lua_State *call_L = nullptr;

	Instance()
	{
		handles.cap = MAX_HANDLES;
	}
	~Instance()
	{
		release_refs();
	}

	void on_fail()
	{
		release_refs();
	}

	// A new handle for an object, or 0 with the table full; ref is taken
	// (released with the handle, or now if there is none)
	uint32_t give(Slot::Kind kind, Urho3D::Node *node, Urho3D::Texture2D *tex,
			const sp_<interface::VoxelVolume> &volume, int ref = LUA_NOREF)
	{
		Slot s;
		s.kind = kind;
		s.ref = ref;
		s.node = node;
		s.texture = tex;
		s.volume = volume;
		const uint32_t h = handles.give(s);
		if(!h)
			unref(ref);
		return h;
	}

	// The handle's slot, or null with why: a handle not given, one given
	// and dropped, or another module's
	Slot* slot_of(uint32_t h, ss_ &why)
	{
		return handles.get(h, why);
	}

	// m:drop(h): the slot free, its generation on
	bool drop(uint32_t h, ss_ &why)
	{
		Slot old;
		if(!handles.drop(h, why, &old))
			return false;
		for(uint64_t n : old.indices)
			indices_all -= n;
		texture_bytes_all -= old.texture_bytes;
		unref(old.ref);
		return true;
	}

	static void unref(int ref)
	{
		if(ref != LUA_NOREF && ref != LUA_REFNIL && g_L)
			luaL_unref(g_L, LUA_REGISTRYINDEX, ref);
	}

	// A stopped or freed module's: what its handles kept alive goes (the
	// handles stay, naming nothing; a stopped module makes no more calls)
	void release_refs()
	{
		handles.each([](Slot &s){
			unref(s.ref);
			s.ref = LUA_NOREF;
		});
		unref(bind_ref);
		bind_ref = LUA_NOREF;
	}

	static bool finite_under(float v, float max)
	{
		return std::isfinite(v) && v <= max && v >= -max;
	}

	// simplified: wasm_api.h's imports make no node or component: Urho3D
	// sends E_NODEADDED and E_COMPONENTADDED to Lua's handlers as they are
	// made, so a module makes them through its bindings (Node:CreateChild,
	// which are Lua calls) or its Lua hands them over.
	// simplified: a geometry's indices are expanded into CustomGeometry's
	// vertex list (it has no index buffer), so the caps count indices; a
	// Model with an IndexBuffer of its own when a mesh's size matters.
	// simplified: a voxel read gives each voxel's first plane (the 32-bit
	// word); a plane argument when a module wants another.
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
			log_line(buf, n);
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
			import_cost += n * 16;
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
			import_cost += nv * 12 + ni * 32;
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
			import_cost += bytes * 2;
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
			import_cost += 1000;
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
			import_cost += nl + dl;
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
		case IMP_DROP:
			drop(a[0], why);
			return 0;
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
			import_cost += n;
			event_bytes -= e.size();
			events.pop_front();
			return n;
		}
		}
		if(which >= IMP_COUNT && which < IMP_ALL)
			return binding_import(which - IMP_COUNT, a, why);
		why = "no such import";
		return 0;
	}

	// [CLIENT_WASM_BINDINGS] A binding's call: a[0], a[1] its values, a[2],
	// a[3] the buffer for its results; the results' length
	uint32_t binding_import(size_t k, const uint32_t *a, ss_ &why)
	{
		static const char *PAST = "past the module's memory";
		if(a[1] > MAX_BINDING_BYTES){
			why = "its values are more than "+itos(MAX_BINDING_BYTES)+" bytes";
			return 0;
		}
		if((uint64_t)a[2] + a[3] > memory_size()){
			why = PAST;
			return 0;
		}
		if(!call_L || bind_ref == LUA_NOREF){
			why = call_L ? "no dispatcher (the module runs under no "
					"client_main that binds the calls: \"client_main\": \"wasm\")" :
					"not in a call (the start function makes none)";
			return 0;
		}
		BindingCall c;
		c.in = this;
		c.k = k;
		c.args.resize(a[1]);
		if(!copy_in(a[0], a[1], c.args.empty() ? nullptr : &c.args[0])){
			why = PAST;
			return 0;
		}
		lua_State *L = call_L;
		const int top = lua_gettop(L);
		if(!lua_checkstack(L, 8)){
			why = "the Lua stack is full";
			return 0;
		}
#ifdef __EMSCRIPTEN__
		lua_unwind_save(g_binding_unwind.call, L);
		lua_unwind_save(g_binding_unwind.main, g_L != L ? g_L : nullptr);
		g_binding_unwind.active = true;
#endif
		g_import_depth++;
		lua_pushcfunction(L, binding_lua);
		lua_pushlightuserdata(L, &c);
		const int status = lua_pcall(L, 1, 0, 0);
		g_import_depth--;
#ifdef __EMSCRIPTEN__
		g_binding_unwind.active = false;
#endif
		if(status != 0){
			const char *e = lua_tostring(L, -1);
			why = printable((const uint8_t*)(e ? e : "?"),
					e ? std::min<size_t>(strlen(e), 300) : 1);
			lua_settop(L, top);
			// What it was given in this call goes with it
			for(uint32_t h : c.given){
				ss_ unused;
				drop(h, unused);
			}
			return 0;
		}
		lua_settop(L, top);
		import_cost += BINDING_COST * (uint64_t)budget() / BUDGET +
				c.args.size() + c.out.size();
		if(c.out.size() > a[3]){
			for(uint32_t h : c.given){
				ss_ unused;
				drop(h, unused);
			}
			why = "its results are "+itos(c.out.size())+" bytes, past the "
					"buffer's "+itos(a[3]);
			return 0;
		}
		if(!copy_out(a[2], c.out.data(), c.out.size())){
			why = PAST;
			return 0;
		}
		return (uint32_t)c.out.size();
	}

	// Handles given for something that did not happen, dropped
	void drop_all(const sv_<uint32_t> &given)
	{
		for(uint32_t h : given){
			ss_ unused;
			drop(h, unused);
		}
	}

	// One binding call's state, for binding_lua()
	struct BindingCall {
		Instance *in = nullptr;
		size_t k = 0;
		ss_ args, out;
		sv_<uint32_t> given; // handles made for its results
	};

	// Whether the value at idx is a wrapper of the sandbox's (a table whose
	// metatable has the object it wraps), of class cls or one derived from
	// it; the stack as it was
	static bool wrapper_is(lua_State *L, int idx, const char *cls)
	{
		if(lua_type(L, idx) != LUA_TTABLE || !lua_getmetatable(L, idx))
			return false;
		const int mt = lua_gettop(L);
		lua_pushstring(L, "unsafe");
		lua_rawget(L, mt);
		const bool wrapper = !lua_isnil(L, -1);
		lua_settop(L, mt);
		bool found = false;
		// The class's meta, then its parents' (magic_sandbox's wrap_class)
		lua_pushvalue(L, mt);
		for(int depth = 0; wrapper && !found && depth < 32; depth++){
			const int m = lua_gettop(L);
			lua_getfield(L, m, "type_name");
			found = lua_type(L, -1) == LUA_TSTRING &&
					strcmp(lua_tostring(L, -1), cls) == 0;
			lua_pop(L, 1);
			lua_getfield(L, m, "inherited_from_by_wrapper");
			if(lua_isnil(L, -1)){
				lua_pop(L, 1);
				lua_getfield(L, m, "inherited_from_in_sandbox");
			}
			if(lua_isnil(L, -1) || !lua_getmetatable(L, -1))
				break;
			lua_replace(L, m);
			lua_settop(L, m);
		}
		lua_settop(L, mt - 1);
		return found;
	}

	// Run under lua_pcall() by binding_import(): the values decoded and
	// pushed, the dispatcher called, its results encoded. An error is the
	// call's refusal. No C++ object with a destructor is alive across a
	// call that can raise one (natively LuaJIT unwinds, on the web Lua
	// longjmps).
	static int binding_lua(lua_State *L)
	{
		BindingCall &c = *(BindingCall*)lua_touserdata(L, 1);
		Instance *in = c.in;
		const BindingDef &d = BINDINGS[c.k];
		const uint8_t *p = (const uint8_t*)c.args.data();
		const size_t n = c.args.size();
		size_t i = 0;
		char err[200] = "";
		if(n < 1)
			return luaL_error(L, "no values");
		const unsigned int count = p[i++];
		if(count > MAX_BINDING_VALUES)
			return luaL_error(L, "more than %d values", (int)MAX_BINDING_VALUES);
		if(!lua_checkstack(L, (int)count + 16))
			return luaL_error(L, "the Lua stack is full");
		lua_rawgeti(L, LUA_REGISTRYINDEX, in->bind_ref);
		const int fn = lua_gettop(L);
		lua_pushstring(L, d.kind);
		lua_pushstring(L, d.cls);
		lua_pushstring(L, d.member);
		uint32_t first_handle = 0;
		for(unsigned int v = 0; v < count; v++){
			if(i >= n)
				return luaL_error(L, "the values end before the %d said", count);
			const uint8_t tag = p[i++];
			auto need = [&](size_t len){ return n - i >= len; };
			switch(tag){
			case 0: lua_pushnil(L); break;
			case 1: lua_pushboolean(L, 0); break;
			case 2: lua_pushboolean(L, 1); break;
			case 3: {
				if(!need(8))
					return luaL_error(L, "a number past the values' end");
				double x;
				memcpy(&x, p + i, 8);
				i += 8;
				lua_pushnumber(L, x);
				break; }
			case 4: {
				if(!need(4))
					return luaL_error(L, "a string past the values' end");
				uint32_t len;
				memcpy(&len, p + i, 4);
				i += 4;
				if(!need(len))
					return luaL_error(L, "a string past the values' end");
				lua_pushlstring(L, (const char*)p + i, len);
				i += len;
				break; }
			case 5: {
				if(!need(4))
					return luaL_error(L, "a handle past the values' end");
				uint32_t h;
				memcpy(&h, p + i, 4);
				i += 4;
				int ref = LUA_NOREF;
				{
					ss_ why;
					Slot *s = in->slot_of(h, why);
					if(!s)
						snprintf(err, sizeof err, "%s", why.c_str());
					else if(s->ref == LUA_NOREF)
						snprintf(err, sizeof err, "handle %u names nothing "
								"the calls take", (unsigned)h);
					else
						ref = s->ref;
				}
				if(err[0])
					return luaL_error(L, "%s", err);
				if(v == 0)
					first_handle = h;
				lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
				break; }
			case 6: {
				if(!need(1))
					return luaL_error(L, "a value past the values' end");
				const unsigned int kind = p[i++];
				const ValueDef *vd = nullptr;
				for(const ValueDef &x : VALUE_DEFS)
					if(x.kind == kind)
						vd = &x;
				if(!vd)
					return luaL_error(L, "no value of kind %d", (int)kind);
				if(!need(8 * (size_t)vd->n))
					return luaL_error(L, "a value past the values' end");
				// Made by the dispatcher, as a script makes one
				lua_pushvalue(L, fn);
				lua_pushstring(L, "value");
				lua_pushstring(L, vd->cls);
				lua_pushstring(L, "");
				for(int j = 0; j < vd->n; j++){
					double x;
					memcpy(&x, p + i, 8);
					i += 8;
					lua_pushnumber(L, x);
				}
				lua_call(L, 3 + vd->n, 1);
				break; }
			default:
				return luaL_error(L, "a value of kind %d", (int)tag);
			}
		}
		if(i != n)
			return luaL_error(L, "%d bytes after the values", (int)(n - i));
		const bool on_object = !strcmp(d.kind, "call") || !strcmp(d.kind, "get")
				|| !strcmp(d.kind, "set");
		if(on_object && (count < 1 || !wrapper_is(L, fn + 4, d.cls)))
			return luaL_error(L, "not called on a %s", d.cls);
		// A table a call returned, read here: a plain table only (no
		// metatable, so no Lua runs), as a script reads it
		const bool table_get = !strcmp(d.kind, "table_get");
		if(table_get || !strcmp(d.kind, "table_len")){
			if(count != (table_get ? 2u : 1u) || lua_type(L, fn + 4) != LUA_TTABLE ||
					lua_getmetatable(L, fn + 4))
				return luaL_error(L, "not called on a table a call returned");
			if(table_get){
				lua_pushvalue(L, fn + 5);
				lua_rawget(L, fn + 4);
			} else {
				lua_pushnumber(L, (lua_Number)lua_objlen(L, fn + 4));
			}
			lua_replace(L, fn);
			lua_settop(L, fn);
		} else {
			// An object's event names the handle it was subscribed with;
			// both kinds are given the event's fields, for its payload
			if(!strcmp(d.kind, "subscribe")){
				lua_pushnumber(L, first_handle);
				push_event_fields(L, fn + 5);
			} else if(!strcmp(d.kind, "subscribe_global")){
				push_event_fields(L, fn + 4);
			}
			lua_call(L, lua_gettop(L) - fn, LUA_MULTRET);
		}
		// The results
		c.out.clear();
		return encode_values(L, fn, lua_gettop(L) - fn + 1, c);
	}

	// The fields of the event named at idx, as {{field, variant, safe},
	// ...}: an empty table for no such event (which the sandbox refuses)
	static void push_event_fields(lua_State *L, int idx)
	{
		const char *event = lua_type(L, idx) == LUA_TSTRING ?
				lua_tostring(L, idx) : "";
		const char *prefix = "command_seq:";
		const bool seq = strncmp(event, prefix, strlen(prefix)) == 0;
		lua_newtable(L);
		int k = 1;
		for(const EventFieldDef &f : EVENT_FIELDS){
			if(strcmp(f.event, seq ? prefix : event) != 0)
				continue;
			lua_newtable(L);
			lua_pushstring(L, f.field);
			lua_rawseti(L, -2, 1);
			lua_pushstring(L, f.variant);
			lua_rawseti(L, -2, 2);
			lua_pushstring(L, f.safe);
			lua_rawseti(L, -2, 3);
			lua_rawseti(L, -2, k++);
		}
	}

	// m:push(bytes, values...)'s values, encoded (encode_values)
	static int push_encode_lua(lua_State *L)
	{
		BindingCall &c = *(BindingCall*)lua_touserdata(L, 1);
		return encode_values(L, 2, lua_gettop(L) - 1, c);
	}

	// The values at first.. into c.out, as a call's results are (a count
	// and each tagged), objects as new handles (c.given). Raises.
	static int encode_values(lua_State *L, int first, int results,
			BindingCall &c)
	{
		char err[200] = "";
		if(results > (int)MAX_BINDING_VALUES)
			return luaL_error(L, "more than %d results", (int)MAX_BINDING_VALUES);
		c.out += (char)results;
		for(int r = first; r < first + results; r++){
			if(c.out.size() > MAX_BINDING_BYTES)
				return luaL_error(L, "results of more than %d bytes",
						(int)MAX_BINDING_BYTES);
			switch(lua_type(L, r)){
			case LUA_TNIL: c.out += '\0'; break;
			case LUA_TBOOLEAN: c.out += (char)(lua_toboolean(L, r) ? 2 : 1); break;
			case LUA_TNUMBER: {
				const double x = lua_tonumber(L, r);
				char b[9] = {3};
				memcpy(b + 1, &x, 8);
				c.out.append(b, 9);
				break; }
			case LUA_TSTRING: {
				size_t len = 0;
				const char *s = lua_tolstring(L, r, &len);
				if(len > MAX_BINDING_BYTES)
					return luaL_error(L, "a string of more than %d bytes",
							(int)MAX_BINDING_BYTES);
				const uint32_t l32 = (uint32_t)len;
				char b[5] = {4};
				memcpy(b + 1, &l32, 4);
				c.out.append(b, 5);
				c.out.append(s, len);
				break; }
			case LUA_TTABLE: {
				if(!encode_object(L, r, c, err, sizeof err))
					return luaL_error(L, "%s", err);
				break; }
			default:
				return luaL_error(L, "a result of type %s, which the calls do not "
						"carry", lua_typename(L, lua_type(L, r)));
			}
		}
		return 0;
	}

	// A table the dispatcher returned, into c.out: a value by its
	// components, any other object or a plain table as a new handle.
	// false with err.
	static bool encode_object(lua_State *L, int r, BindingCall &c, char *err,
			size_t err_len)
	{
		// A plain table (Octree:GetDrawables(), Skeleton:GetBone()): a
		// handle, read by table_get and table_len
		if(!lua_getmetatable(L, r))
			return give_ref(L, r, c, Slot::OBJECT, nullptr, nullptr, err, err_len);
		const int mt = lua_gettop(L);
		lua_pushstring(L, "unsafe");
		lua_rawget(L, mt);
		const int unsafe = lua_gettop(L);
		if(lua_isnil(L, unsafe)){
			lua_settop(L, mt - 1);
			snprintf(err, err_len, "a table result, which the calls do not carry");
			return false;
		}
		lua_getfield(L, mt, "type_name");
		const char *tn = lua_tostring(L, -1);
		for(const ValueDef &vd : VALUE_DEFS){
			if(!tn || strcmp(tn, vd.cls) != 0)
				continue;
			char b[2] = {6, (char)vd.kind};
			c.out.append(b, 2);
			for(int j = 0; j < vd.n; j++){
				// Read as a script reads it: the property's get
				lua_getfield(L, r, vd.c[j]);
				const double x = lua_tonumber(L, -1);
				lua_pop(L, 1);
				char xb[8];
				memcpy(xb, &x, 8);
				c.out.append(xb, 8);
			}
			lua_settop(L, mt - 1);
			return true;
		}
		tolua_Error te;
		Slot::Kind kind = Slot::OBJECT;
		Urho3D::Node *node = nullptr;
		Urho3D::Texture2D *tex = nullptr;
		if(lua_isuserdata(L, unsafe) && tolua_isusertype(L, unsafe, "Node", 0, &te)){
			kind = Slot::NODE;
			node = (Urho3D::Node*)tolua_tousertype(L, unsafe, 0);
		} else if(lua_isuserdata(L, unsafe) &&
				tolua_isusertype(L, unsafe, "Texture2D", 0, &te)){
			kind = Slot::TEXTURE;
			tex = (Urho3D::Texture2D*)tolua_tousertype(L, unsafe, 0);
		}
		lua_settop(L, mt - 1);
		return give_ref(L, r, c, kind, node, tex, err, err_len);
	}

	// The value at r held by a new handle, into c.out
	static bool give_ref(lua_State *L, int r, BindingCall &c, Slot::Kind kind,
			Urho3D::Node *node, Urho3D::Texture2D *tex, char *err, size_t err_len)
	{
		lua_pushvalue(L, r);
		const int ref = luaL_ref(L, LUA_REGISTRYINDEX);
		const uint32_t h = c.in->give(kind, node, tex, nullptr, ref);
		if(!h){
			snprintf(err, err_len, "more than %d handles", (int)MAX_HANDLES);
			return false;
		}
		c.given.push_back(h);
		char b[5] = {5};
		memcpy(b + 1, &h, 4);
		c.out.append(b, 5);
		return true;
	}
};

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
	// Its start function would run inside the import
	if(g_import_depth > 0)
		raise("wasm: loaded from inside a module's call to the client");
	if(instance_count() >= MAX_INSTANCES){
		lua_pushnil(L);
		lua_pushstring(L, "too many wasm modules loaded");
		return 2;
	}
	up_<Instance> in(new Instance());
	in->name = name;
#if BUILDAT_WASM_NATIVE
	in->cache_root = g_client_config.get<ss_>("cache_path")+"/wasm2c";
#endif
	ss_ why;
	if(!in->prepare(bytes, why)){
		log_w(MODULE, "wasm %s: refused: %s", cs(name), cs(why));
		lua_pushnil(L);
		lua_pushstring(L, ("refused: "+why).c_str());
		return 2;
	}
	Instance **ud = (Instance**)lua_newuserdata(L, sizeof(Instance*));
	*ud = in.release();
	luaL_getmetatable(L, META);
	lua_setmetatable(L, -2);
	// For checks only: the module failed as on a platform with no wasm
	// (macOS), so a game's way without it is driven
	if(const char *e = getenv("BUILDAT_CHECK_WASM_OFF")){
		if(*e && strcmp(e, "0") != 0){
			(*ud)->fail("wasm modules do not run on this platform yet (hidden "
					"for a check)");
			return 1;
		}
	}
	(*ud)->start();
	return 1;
}

// m:status() -> "loading" | "ready", engine | "failed", why; the engine
// "compiled", "interpreter, compiling" (moved to the compiled module
// between two calls once its compile is done), "interpreter" (for good)
// or "browser"
static int l_status(lua_State *L)
{
	Instance *in = check_instance(L);
	in->poll();
	lua_pushstring(L, in->state == Instance::LOADING ? "loading" :
			in->state == Instance::READY ? "ready" : "failed");
	if(in->state == Instance::FAILED){
		lua_pushstring(L, in->error.c_str());
		return 2;
	}
	if(in->state == Instance::READY){
		lua_pushstring(L, in->engine_name().c_str());
		return 2;
	}
	return 1;
}

static Instance* ready_instance(lua_State *L)
{
	Instance *in = check_instance(L);
	in->poll();
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
	const size_t index = in->find_export(fname);
	if(index == in->exports.size())
		raise("wasm %s: no export \"%s\"", in->name.c_str(),
				fname.substr(0, 64).c_str());
	const ExportSig sig = in->exports[index];
	const int n = lua_gettop(L) - 2;
	if(n != (int)sig.params.size())
		raise("wasm %s: %s takes %d numbers, given %d",
				in->name.c_str(), fname.c_str(), (int)sig.params.size(), n);
	uint64_t args[MAX_PARAMS] = {0};
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
	if(in->in_call)
		raise("wasm %s: called from inside its own call", in->name.c_str());
	if(g_import_depth > 0)
		raise("wasm %s: called from inside a module's call to the client",
				in->name.c_str());
	in->call_L = L;
	in->sent.clear();
	uint64_t r = 0;
	ss_ trap = in->call(index, args, &r);
#ifdef __EMSCRIPTEN__
	// A binding's Lua unwound by the browser (above): the Lua states put
	// back first, as nothing on L can run before; the module stopped, as
	// the client's work for it may be anywhere
	if(g_binding_unwind.active){
		g_binding_unwind.active = false;
		lua_unwind_restore(g_binding_unwind.call);
		lua_unwind_restore(g_binding_unwind.main);
		g_import_depth = 0;
		in->call_L = nullptr;
		in->sent.clear();
		in->fail("stopped: "+fname+": the stack ran out inside the client "
				"during a binding ("+trap+")");
		raise("wasm %s: %s: stopped: the stack ran out in a binding",
				in->name.c_str(), fname.c_str());
	}
#endif
	in->call_L = nullptr;
	if(!trap.empty()){
		// What a call that trapped sent is dropped with it
		in->sent.clear();
		in->logged = 0;
		// Past its budget: the module is stopped, as it may be anywhere
		// in its work, and its calls refused from now on
		if(in->past_budget()){
			in->fail("stopped: "+fname+" ran past its budget of "+
					itos(in->budget())+" (a loop that does not end?)");
			raise("wasm %s: %s: stopped: past its budget", in->name.c_str(),
					fname.c_str());
		}
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
	double result = 0;
	switch(sig.result){
	case 0: return 0;
	case 'i': result = (int32_t)(uint32_t)r; break;
	case 'I': result = (double)(int64_t)r; break;
	case 'f': { uint32_t u = (uint32_t)r; float f; memcpy(&f, &u, 4); result = f; } break;
	case 'F': memcpy(&result, &r, 8); break;
	}
	lua_pushnumber(L, result);
	return 1;
}

// __buildat_wasm_handle(m, object, safe) -> a handle the module can use
// for the object: a Node, a Texture2D (tolua's, unwrapped by api.lua), a
// buildat.Volume, or another of the sandbox's objects for the bindings
// ([CLIENT_WASM_BINDINGS]); safe is what the script handed (the wrapper),
// which the handle keeps, and the bindings' calls are made on
static int l_handle(lua_State *L)
{
	Instance *in = check_instance(L);
	if(in->state == Instance::FAILED)
		raise("wasm %s: stopped", in->name.c_str());
	tolua_Error err;
	uint32_t h = 0;
	lua_pushvalue(L, lua_isnoneornil(L, 3) ? 2 : 3);
	const int ref = luaL_ref(L, LUA_REGISTRYINDEX);
	bool wrapper = false;
	if(lua_type(L, 3) == LUA_TTABLE && lua_getmetatable(L, 3)){
		lua_pushstring(L, "unsafe");
		lua_rawget(L, -2);
		wrapper = !lua_isnil(L, -1);
		lua_pop(L, 2);
	}
	if(lua_isuserdata(L, 2) && tolua_isusertype(L, 2, "Node", 0, &err)){
		h = in->give(Instance::Slot::NODE,
				(Urho3D::Node*)tolua_tousertype(L, 2, 0), nullptr, nullptr, ref);
	} else if(lua_isuserdata(L, 2) &&
			tolua_isusertype(L, 2, "Texture2D", 0, &err)){
		h = in->give(Instance::Slot::TEXTURE, nullptr,
				(Urho3D::Texture2D*)tolua_tousertype(L, 2, 0), nullptr, ref);
	} else if(wrapper){
		h = in->give(Instance::Slot::OBJECT, nullptr, nullptr, nullptr, ref);
	} else {
		sp_<interface::VoxelVolume> v;
		if(lua_isuserdata(L, 2)){
			luabind::object o(luabind::from_stack(L, 2));
			try {
				v = luabind::object_cast<sp_<interface::VoxelVolume>>(o);
			} catch(luabind::cast_failed&){
			}
		}
		if(!v){
			Instance::unref(ref);
			raise("wasm %s: handle(object): an object of the sandbox's or a "
					"Volume", in->name.c_str());
		}
		h = in->give(Instance::Slot::VOLUME, nullptr, nullptr, v, ref);
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

// m:bind(f): the module's dispatcher ([CLIENT_WASM_BINDINGS]), through
// which its calls of buildat_client.h are made: f(kind, class, member,
// values...) -> results, in the module's sandbox (the default
// client_main's)
static int l_bind(lua_State *L)
{
	Instance *in = check_instance(L);
	if(lua_type(L, 2) != LUA_TFUNCTION)
		raise("wasm: bind(f): f is not a function");
	if(in->state == Instance::FAILED)
		raise("wasm %s: stopped", in->name.c_str());
	lua_pushvalue(L, 2);
	const int ref = luaL_ref(L, LUA_REGISTRYINDEX);
	Instance::unref(in->bind_ref);
	in->bind_ref = ref;
	return 0;
}

// m:push(bytes [, values...]): an event queued for the module
// (buildat_event_take()). Values after the bytes are appended as a call's
// results are encoded ([CLIENT_WASM_BINDINGS]: an event's payload), an
// object as a new handle, which the module's event releases.
static int l_push(lua_State *L)
{
	Instance *in = check_instance(L);
	if(lua_type(L, 2) != LUA_TSTRING)
		raise("wasm: push(bytes): bytes is not a string");
	size_t len = 0;
	const char *p = lua_tolstring(L, 2, &len);
	const int values = lua_gettop(L) - 2;
	Instance::BindingCall c;
	c.in = in;
	if(values > 0){
		if(in->state == Instance::FAILED)
			raise("wasm %s: stopped", in->name.c_str());
		if(!lua_checkstack(L, values + 4))
			raise("wasm %s: push: the Lua stack is full", in->name.c_str());
		lua_pushcfunction(L, Instance::push_encode_lua);
		lua_pushlightuserdata(L, &c);
		for(int i = 0; i < values; i++)
			lua_pushvalue(L, 3 + i);
		if(lua_pcall(L, values + 1, 0, 0) != 0){
			const ss_ e = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
			lua_pop(L, 1);
			in->drop_all(c.given);
			raise("wasm %s: push: %s", in->name.c_str(), e.c_str());
		}
	}
	// With its payload no longer than wasm_api.h's BUILDAT_EVENT_MAX, the
	// buffer buildat_client.h takes it into
	if(values > 0 && len + c.out.size() > 8 + 64 + 65536){
		in->drop_all(c.given);
		raise("wasm %s: push: an event of %d bytes, past BUILDAT_EVENT_MAX",
				in->name.c_str(), (int)(len + c.out.size()));
	}
	if(in->events.size() >= MAX_EVENTS ||
			in->event_bytes + len + c.out.size() > MAX_EVENT_BYTES){
		in->drop_all(c.given);
		raise("wasm %s: its event queue is full (%d events, %d bytes)",
				in->name.c_str(), (int)MAX_EVENTS, (int)MAX_EVENT_BYTES);
	}
	in->events.emplace_back(ss_(p, len)+c.out);
	in->event_bytes += len + c.out.size();
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
	if(len > 0 && !in->copy_in((uint64_t)ptr, (uint64_t)len, &out[0]))
		raise("wasm %s: read past its memory", in->name.c_str());
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
	if(len > 0 && !in->copy_out((uint64_t)ptr, bytes, len))
		raise("wasm %s: write past its memory", in->name.c_str());
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
	g_L = L;
	set_client_imports();
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
	lua_pushcfunction(L, guarded<l_bind>);
	lua_setfield(L, -2, "bind");
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

#ifdef __EMSCRIPTEN__
// Last in the file: Lua's internal headers define short macros. PUC Lua
// 5.1, which the web client runs, built as C++ as this file is.
#include <lstate.h>
#include <ldo.h>
#include <lfunc.h>
namespace lua_bindings {
// What luaD_pcall() keeps and puts back on an error
static void lua_unwind_save(LuaUnwind &u, lua_State *L)
{
	u.L = L;
	if(!L)
		return;
	u.top = savestack(L, L->top);
	u.ci = saveci(L, L->ci);
	u.errfunc = L->errfunc;
	u.error_jmp = L->errorJmp;
	u.n_ccalls = L->nCcalls;
	u.allowhook = L->allowhook;
}
static void lua_unwind_restore(const LuaUnwind &u)
{
	lua_State *L = u.L;
	if(!L)
		return;
	StkId oldtop = restorestack(L, u.top);
	luaF_close(L, oldtop);
	L->top = oldtop;
	L->nCcalls = u.n_ccalls;
	L->ci = restoreci(L, u.ci);
	L->base = L->ci->base;
	L->savedpc = L->ci->savedpc;
	L->allowhook = u.allowhook;
	L->errfunc = u.errfunc;
	L->errorJmp = (struct lua_longjmp*)u.error_jmp;
	// ldo.c's restore_stack_limit()
	if(L->size_ci > LUAI_MAXCALLS){
		int inuse = (int)(L->ci - L->base_ci);
		if(inuse + 1 < LUAI_MAXCALLS)
			luaD_reallocCI(L, LUAI_MAXCALLS);
	}
}
} // namespace lua_bindings
#endif
// vim: set noet ts=4 sw=4:
