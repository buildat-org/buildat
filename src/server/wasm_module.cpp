// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [SERVER_WASM] A server module that is a .wasm: run by src/wasm/engine.cpp
// (validated, capped, metered, wasm2c with the server's compiler, WAMR's
// interpreter meanwhile), on the module's own thread as a C++ module is. It
// reaches the server only through interface/wasm_server_api.h's imports
// (import_body() below), and only those meta.json grants: a .wasm
// importing another is refused at load, by name.
//
// The module is called, never the other way: its export init() once it
// runs, events() after each event it subscribed to is queued (it takes
// them with buildat_event_take()), and its "callable" exports by other
// wasm modules' buildat_call(). An import calls into no wasm but that one,
// which runs on the callee's thread while the caller waits; a module
// already in the chain of a call is not called again (no re-entry). A call
// that traps is logged and the module goes on; one past its budget stops
// the module, and the server goes on.
//
// What it reaches, each through the module's interface as a C++ module
// would: its own packets (network), its own keys and values (a save of
// its own, "wasm_<module>"), scenes it made and their nodes (main_context,
// replicate), a voxel world in a scene of its (voxelworld), and other wasm
// modules' exports that their meta.json says are callable. Scenes and
// nodes are handles of the module's own table (wasm/engine.h's Handles).
//
// The boundary's bytes: an event is little-endian 32-bit words, its kind
// first, then its numbers, and a name or data as their bytes -- the
// layout of the client's events (wasm_api.h), so one parser reads both,
// and a no_std module reads it with a few lines; wasm's memory is
// little-endian, so a word is one load. A packet, a stored value and a
// call's input and output are the module's own bytes.
#include "server/wasm_module.h"
#include "server/wasm_imports.h"
#include "wasm/engine.h"
#include "interface/module.h"
#include "interface/module_info.h"
#include "interface/server.h"
#include "interface/voxel.h"
#include "interface/voxel_volume.h"
#include "network/api.h"
#include "storage/api.h"
#include "main_context/api.h"
#include "replicate/api.h"
#include "voxelworld/api.h"
#include "core/log.h"
#include <Scene.h>
#include <Node.h>
#include <cmath>
#include <deque>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <cstring>
#define MODULE "wasm"

namespace pv = PolyVox;

namespace server {

using namespace wasm_engine;
using interface::Event;

// Per module
static const size_t MAX_EVENTS = 256; // queued
static const size_t MAX_EVENT_BYTES = 4 << 20; // queued
static const size_t MAX_SUBSCRIPTIONS = 64; // events and packets
static const size_t MAX_NAME = 128; // an event's name
static const size_t MAX_PACKET_NAME = 64;
static const uint32_t MAX_PACKET = 65536;
static const size_t MAX_PACKETS = 256; // sent in one call
static const uint32_t MAX_KEY = 256;
static const uint32_t MAX_VALUE = 1 << 20;
static const int64_t MAX_STORED = 64 << 20; // keys and values, a module's
static const size_t MAX_SCENES = 4;
static const int32_t MAX_WORLD_SPAN = 8; // sections, each axis
static const int64_t MAX_WORLD_SECTIONS = 64;
static const size_t MAX_VOXEL_TYPES = 256;
static const uint64_t MAX_VOXELS = 1 << 20; // a call's
static const uint32_t MAX_CALL_BYTES = 1 << 20; // a call's input and output
// How long a call between modules waits for another chain of calls to end
// before it is refused (two modules calling each other at once would each
// wait for the other's thread)
static const int CALL_WAIT_MS = 100;

// wasm_server_api.h's event kinds
enum { EV_START = 1, EV_TICK = 2, EV_PEER_JOINED = 3, EV_PEER_LEFT = 4,
		EV_PACKET = 5 };
// The events a module may subscribe to by name: what their bytes carry is
// known. Packets are by the module's own names (packet_subscribe).
static const struct { const char *name; uint32_t kind; } SUBSCRIBABLE[] = {
	{"core:start", EV_START},
	{"core:tick", EV_TICK},
	{"network:client_connected", EV_PEER_JOINED},
	{"network:client_disconnected", EV_PEER_LEFT},
};

// One chain of calls between wasm modules at a time: its first caller
// holds this until the chain returns, and a new chain waits for it at most
// CALL_WAIT_MS (simplified: calls of unrelated modules wait for each other;
// a token per pair of modules is the upgrade if that matters)
static std::timed_mutex g_call_token;

static void put32(ss_ &b, uint32_t v)
{
	const char w[4] = {(char)(v & 0xff), (char)((v >> 8) & 0xff),
			(char)((v >> 16) & 0xff), (char)(v >> 24)};
	b.append(w, 4);
}

static bool name_chars(const ss_ &s, const char *also)
{
	for(char c : s)
		if(!isalnum((unsigned char)c) && !strchr(also, c))
			return false;
	return true;
}

// The server's imports as the engine's ImportSet, once
static void set_server_imports()
{
	static std::once_flag once;
	std::call_once(once, [](){
		ImportSet set;
		set.what = "wasm_server_api.h's";
		for(const WasmImportDef &d : WASM_IMPORTS){
			ImportDef x;
			x.name = x.c_name = d.name;
			x.params = d.params;
			x.result = d.result;
			set.defs.push_back(x);
		}
		set_imports(set);
	});
}

struct WasmModule;

struct ServerEngine: public Engine
{
	WasmModule *owner = nullptr;
	uint32_t import_body(uint32_t which, const uint32_t *a, ss_ &why);
	void on_fail();
};

struct WasmModule: public interface::Module
{
	interface::Server *m_server;
	interface::ModuleInfo m_info;
	ss_ m_cache_root;
	ServerEngine m_engine;
	// The exports the server calls (exports.size() for none)
	size_t m_init = 0, m_events = 0;
	bool m_inited = false;
	// The events it subscribed to, by type: their kinds; and its packets'
	// names
	std::map<Event::Type, uint32_t> m_kinds;
	std::map<Event::Type, ss_> m_packet_names;
	Event::Type m_tick_type = 0;
	// Its events, queued for buildat_event_take()
	std::deque<ss_> m_queue;
	size_t m_queue_bytes = 0;
	bool m_queue_full_said = false;
	// The packets the call under way sends: peer, name, data
	struct Sent { uint32_t peer; ss_ name, data; };
	sv_<Sent> m_sent;
	// Its storage: a save of its own, opened on first use
	storage::Save *m_save = nullptr;
	storage::Store *m_store = nullptr;
	int64_t m_stored = 0;
	// Its scenes and nodes
	struct Slot {
		enum Kind { NONE, SCENE, NODE } kind = NONE;
		main_context::SceneReference scene = nullptr;
		uint32_t node = 0;
	};
	Handles<Slot> m_handles;
	struct Scene {
		main_context::SceneReference ref = nullptr;
		bool world = false;
		pv::Region voxels; // the world's bounds in voxels
		set_<uint32_t> types; // the voxel types the module defined in it
	};
	sv_<Scene> m_scenes;
	size_t m_voxel_types = 0;
	// The chain of calls this module is in (its own name last), while it
	// serves one or makes one; whether it holds g_call_token; a served
	// call's input and output
	sv_<ss_> m_chain;
	bool m_holds_token = false;
	bool m_serving = false;
	ss_ m_call_input, m_call_output;

	WasmModule(interface::Server *server, const interface::ModuleInfo &info,
			const ss_ &cache_root):
		interface::Module("(wasm)"),
		m_server(server),
		m_info(info),
		m_cache_root(cache_root)
	{
		m_module_name = m_info.name.c_str();
		m_engine.owner = this;
		m_engine.name = m_info.name;
	}

	~WasmModule()
	{
		// What it made goes with it; the modules it reached may be stopping
		for(const Scene &s : m_scenes){
			try {
				if(s.world)
					m_server->access_module_optional("voxelworld",
							[&](interface::Module *m){
						auto *i = (voxelworld::Interface*)m->check_interface();
						i->delete_instance(s.ref);
					});
				m_server->access_module_optional("main_context",
						[&](interface::Module *m){
					auto *i = (main_context::Interface*)m->check_interface();
					i->delete_scene(s.ref);
				});
			} catch(std::exception &e){
				log_w(MODULE, "wasm %s: its scene was not deleted: %s",
						cs(m_info.name), e.what());
			}
		}
		if(m_save){
			try {
				m_server->access_module_optional("storage",
						[&](interface::Module *m){
					((storage::Interface*)m->check_interface())->close(m_save);
				});
			} catch(std::exception &e){
				log_w(MODULE, "wasm %s: its save was not closed: %s",
						cs(m_info.name), e.what());
			}
		}
	}

	// The .wasm checked: its imports against the grants, the exports the
	// server calls against their signature (none takes or returns a value)
	bool prepare(const ss_ &bytes, ss_ &why)
	{
		set_<ss_> granted;
		for(const ss_ &g : m_info.meta.server_wasm_imports){
			bool known = false;
			for(const char *k : WASM_GRANTS)
				known = known || g == k;
			if(!known){
				why = "meta.json grants \""+g.substr(0, 40)+"\", which is not "
						"a group of wasm_server_api.h's imports";
				return false;
			}
			granted.insert(g);
		}
		m_engine.refuse_import = [granted](size_t which) -> ss_ {
			const char *g = WASM_IMPORTS[which].grant;
			if(!*g || granted.count(g))
				return "";
			return ss_("which meta.json does not grant (\"server_wasm\": "
					"{\"imports\": [\"")+g+"\"]})";
		};
		if(!m_engine.prepare(bytes, why))
			return false;
		m_init = m_engine.find_export("init");
		m_events = m_engine.find_export("events");
		sv_<ss_> called = m_info.meta.server_wasm_callable;
		called.push_back("init");
		called.push_back("events");
		for(const ss_ &n : called){
			const size_t i = m_engine.find_export(n);
			if(i == m_engine.exports.size()){
				if(n == "init" || n == "events")
					continue;
				why = "meta.json says \""+n.substr(0, 64)+"\" is callable, and "
						"the .wasm does not export it";
				return false;
			}
			const ExportSig &s = m_engine.exports[i];
			if(!s.params.empty() || s.result){
				why = "its export "+n+" takes or returns a value; the server "
						"calls it with none";
				return false;
			}
		}
		return true;
	}

	// On the module's thread, which runs it from now on
	void init()
	{
		m_tick_type = Event::t("core:tick");
		// Always: the compile's progress is read between calls, and init()
		// called once the module runs
		m_server->sub_event(this, m_tick_type);
		m_engine.cache_root = m_cache_root;
		m_engine.start();
		ready();
	}

	// The module's init(), once it runs
	void ready()
	{
		m_engine.poll();
		if(m_inited || m_engine.state != Engine::READY)
			return;
		m_inited = true;
		if(m_init < m_engine.exports.size()){
			m_chain = {m_info.name};
			run(m_init);
			m_chain.clear();
		}
	}

	// An export called: a trap logged, a run past its budget stops it; the
	// packets it sent go once it returns. False if it did not return.
	bool run(size_t index)
	{
		if(m_engine.state != Engine::READY || m_engine.in_call)
			return false;
		m_sent.clear();
		uint64_t args[1] = {0}, r = 0;
		const ss_ trap = m_engine.call(index, args, &r);
		sv_<Sent> sent;
		sent.swap(m_sent);
		if(trap.empty()){
			if(!sent.empty()){
				try {
					network::access(m_server, [&](network::Interface *i){
						for(const Sent &s : sent)
							i->send(s.peer, m_info.name+":"+s.name, s.data);
					});
				} catch(std::exception &e){
					log_w(MODULE, "wasm %s: its packets were not sent: %s",
							cs(m_info.name), e.what());
				}
			}
			return true;
		}
		const ss_ &fn = m_engine.exports[index].name;
		if(m_engine.past_budget()){
			m_engine.fail("stopped: "+fn+" ran past its budget of "+
					itos(m_engine.budget())+" (a loop that does not end?)");
			return false;
		}
		log_w(MODULE, "wasm %s: %s: trap: %s", cs(m_info.name), cs(fn),
				cs(trap));
		return false;
	}

	void push(const ss_ &e)
	{
		if(m_queue.size() >= MAX_EVENTS ||
				m_queue_bytes + e.size() > MAX_EVENT_BYTES){
			if(!m_queue_full_said)
				log_w(MODULE, "wasm %s: its event queue is full (%zu events); "
						"events are dropped until it takes them",
						cs(m_info.name), m_queue.size());
			m_queue_full_said = true;
			return;
		}
		m_queue_full_said = false;
		m_queue.push_back(e);
		m_queue_bytes += e.size();
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		if(m_engine.state == Engine::FAILED)
			return;
		ready();
		auto it = m_kinds.find(type);
		if(it == m_kinds.end())
			return;
		ss_ e;
		put32(e, it->second);
		switch(it->second){
		case EV_TICK: {
			auto *t = dynamic_cast<const interface::TickEvent*>(p);
			float dt = t ? t->dtime : 0.0f;
			uint32_t u;
			memcpy(&u, &dt, 4);
			put32(e, u);
			break; }
		case EV_PEER_JOINED: {
			auto *c = dynamic_cast<const network::NewClient*>(p);
			if(!c)
				return;
			put32(e, (uint32_t)c->info.id);
			break; }
		case EV_PEER_LEFT: {
			auto *c = dynamic_cast<const network::OldClient*>(p);
			if(!c)
				return;
			put32(e, (uint32_t)c->info.id);
			break; }
		case EV_PACKET: {
			auto *pk = dynamic_cast<const network::Packet*>(p);
			if(!pk)
				return;
			const ss_ &n = m_packet_names[type];
			put32(e, (uint32_t)pk->sender);
			put32(e, (uint32_t)n.size());
			e += n;
			e += pk->data;
			break; }
		default:
			break;
		}
		push(e);
		if(m_events < m_engine.exports.size() && m_engine.state == Engine::READY){
			m_chain = {m_info.name};
			run(m_events);
			m_chain.clear();
		}
	}

	// Another module's buildat_call(), on this module's thread: "" and the
	// output, or why not
	ss_ serve_call(const ss_ &fn, const ss_ &input, const sv_<ss_> &chain,
			ss_ &out)
	{
		if(m_engine.state != Engine::FAILED)
			ready();
		if(m_engine.state != Engine::READY)
			return m_engine.state == Engine::FAILED ? "it is stopped" :
					"it is not running yet";
		bool callable = false;
		for(const ss_ &c : m_info.meta.server_wasm_callable)
			callable = callable || c == fn;
		const size_t index = m_engine.find_export(fn);
		if(!callable || index == m_engine.exports.size())
			return "its meta.json does not say "+fn+" is callable";
		if(m_engine.in_call || m_serving)
			return "it is in a call"; // never: its thread runs this
		m_chain = chain;
		m_chain.push_back(m_info.name);
		m_serving = true;
		m_call_input = input;
		m_call_output.clear();
		const bool ok = run(index);
		m_serving = false;
		m_chain.clear();
		m_call_input.clear();
		out.swap(m_call_output);
		m_call_output.clear();
		if(!ok)
			return m_engine.state == Engine::FAILED ? fn+" stopped it" :
					fn+" trapped";
		return "";
	}

	// A name the module handed: its bytes, checked
	bool name_arg(uint32_t ptr, uint32_t len, size_t max, ss_ &out, ss_ &why)
	{
		if(len < 1 || len > max){
			why = "a name of "+itos(len)+" bytes (1 to "+itos(max)+")";
			return false;
		}
		out.assign(len, '\0');
		if(!m_engine.copy_in(ptr, len, &out[0])){
			why = "past the module's memory";
			return false;
		}
		return true;
	}

	// Its bytes, at most max
	bool bytes_arg(uint32_t ptr, uint32_t len, uint32_t max, ss_ &out,
			ss_ &why)
	{
		if(len > max){
			why = itos(len)+" bytes, past the cap of "+itos(max);
			return false;
		}
		out.assign(len, '\0');
		if(len > 0 && !m_engine.copy_in(ptr, len, &out[0])){
			why = "past the module's memory";
			return false;
		}
		m_engine.import_cost += len;
		return true;
	}

	// Bytes into the module's memory if they fit cap: their length
	uint32_t give_bytes(const ss_ &b, uint32_t ptr, uint32_t cap, ss_ &why)
	{
		if(b.size() > cap)
			return (uint32_t)b.size();
		if(!m_engine.copy_out(ptr, b.data(), b.size()))
			why = "past the module's memory";
		m_engine.import_cost += b.size();
		return (uint32_t)b.size();
	}

	// The scene behind a handle, or null with why
	Scene* scene_arg(uint32_t h, ss_ &why)
	{
		Slot *s = m_handles.get(h, why);
		if(!s)
			return nullptr;
		if(s->kind != Slot::SCENE){
			why = "not a scene's handle";
			return nullptr;
		}
		for(Scene &sc : m_scenes)
			if(sc.ref == s->scene)
				return &sc;
		why = "its scene is gone";
		return nullptr;
	}

	// A box (corner, size) in the module's memory, as a region inside the
	// world's: its voxel count, or 0 with why
	uint64_t box_arg(const Scene &sc, uint32_t ptr, pv::Region &r, ss_ &why)
	{
		int32_t box[6];
		if(!m_engine.copy_in(ptr, sizeof box, box)){
			why = "past the module's memory";
			return 0;
		}
		if(!sc.world){
			why = "the scene has no world (buildat_world_create())";
			return 0;
		}
		for(int k = 3; k < 6; k++)
			if(box[k] < 1 || (uint64_t)box[k] > MAX_VOXELS){
				why = "a box's size is not 1 or more, or is past the cap";
				return 0;
			}
		const uint64_t n = (uint64_t)box[3] * box[4] * box[5];
		if(n > MAX_VOXELS){
			why = "more than "+itos(MAX_VOXELS)+" voxels";
			return 0;
		}
		const pv::Vector3DInt32 lc = sc.voxels.getLowerCorner(),
				uc = sc.voxels.getUpperCorner();
		const int64_t lo[3] = {lc.getX(), lc.getY(), lc.getZ()};
		const int64_t hi[3] = {uc.getX(), uc.getY(), uc.getZ()};
		for(int k = 0; k < 3; k++)
			if(box[k] < lo[k] || (int64_t)box[k] + box[k + 3] - 1 > hi[k]){
				why = "the box is not inside the world";
				return 0;
			}
		r = pv::Region(box[0], box[1], box[2], box[0] + box[3] - 1,
				box[1] + box[4] - 1, box[2] + box[5] - 1);
		return n;
	}

	// The module's store, opened (or made) on first use
	storage::Store* store(ss_ &why)
	{
		if(m_store)
			return m_store;
		const ss_ name = "wasm_"+m_info.name;
		if(!m_server->access_module_optional("storage",
				[&](interface::Module *m){
			auto *i = (storage::Interface*)m->check_interface();
			m_save = i->open(name);
			if(!m_save)
				m_save = i->create(name);
		}) || !m_save){
			why = "no save (the storage module is a dependency in meta.json)";
			return nullptr;
		}
		m_store = m_save->store("kv");
		// What it holds already, against its cap
		for(const ss_ &k : m_store->list("")){
			ss_ v;
			m_store->get(k, v);
			m_stored += (int64_t)(k.size() + v.size());
		}
		return m_store;
	}

	// A node's transform checked as the client's is (wasm_api.h)
	static bool transform_ok(const float t[10], ss_ &why)
	{
		for(int i = 0; i < 10; i++)
			if(!std::isfinite(t[i]) || t[i] > 1e9f || t[i] < -1e9f){
				why = "a transform value is not finite, or past 1e9";
				return false;
			}
		if(t[3] * t[3] + t[4] * t[4] + t[5] * t[5] + t[6] * t[6] < 1e-12f){
			why = "a zero rotation";
			return false;
		}
		return true;
	}

	uint32_t import_body(uint32_t which, const uint32_t *a, ss_ &why)
	{
		static const char *PAST = "past the module's memory";
		switch(which){
		case WI_LOG: {
			// The whole range is checked; the first MAX_LOG bytes shown
			if((uint64_t)a[0] + a[1] > m_engine.memory_size()){
				why = PAST;
				return 0;
			}
			uint8_t buf[MAX_LOG];
			const size_t n = std::min<size_t>(a[1], MAX_LOG);
			if(!m_engine.copy_in(a[0], n, buf)){
				why = PAST;
				return 0;
			}
			m_engine.log_line(buf, n);
			return 0;
		}
		case WI_TIME_MS:
			return (uint32_t)std::chrono::duration_cast<
					std::chrono::milliseconds>(std::chrono::steady_clock::now() -
					m_engine.loaded).count();
		case WI_EVENT_TAKE: {
			if(m_queue.empty())
				return (uint32_t)-1;
			const ss_ e = m_queue.front();
			const uint32_t n = give_bytes(e, a[0], a[1], why);
			if(e.size() <= a[1] && why.empty()){
				m_queue_bytes -= e.size();
				m_queue.pop_front();
			}
			return n;
		}
		case WI_DROP: {
			Slot old;
			m_handles.drop(a[0], why, &old);
			return 0;
		}
		case WI_CALL_INPUT:
			if(!m_serving)
				return (uint32_t)-1;
			return give_bytes(m_call_input, a[0], a[1], why);
		case WI_CALL_OUTPUT:
			if(!bytes_arg(a[0], a[1], MAX_CALL_BYTES, m_call_output, why))
				return 0;
			if(!m_serving)
				m_call_output.clear();
			return 0;
		case WI_EVENT_SUBSCRIBE: {
			ss_ n;
			if(!name_arg(a[0], a[1], MAX_NAME, n, why))
				return 0;
			uint32_t kind = 0;
			for(const auto &s : SUBSCRIBABLE)
				if(n == s.name)
					kind = s.kind;
			if(!kind){
				why = "\""+printable((const uint8_t*)n.data(), n.size())+
						"\" is not an event a module subscribes to by name";
				return 0;
			}
			return subscribe(Event::t(n), kind, "", why);
		}
		case WI_PACKET_SUBSCRIBE: {
			ss_ n;
			if(!name_arg(a[0], a[1], MAX_PACKET_NAME, n, why))
				return 0;
			if(!name_chars(n, "_")){
				why = "a packet's name is not [A-Za-z0-9_]";
				return 0;
			}
			return subscribe(Event::t("network:packet_received/"+m_info.name+
					":"+n), EV_PACKET, n, why);
		}
		case WI_PACKET_SEND: {
			ss_ n, data;
			if(!name_arg(a[1], a[2], MAX_PACKET_NAME, n, why) ||
					!bytes_arg(a[3], a[4], MAX_PACKET, data, why))
				return 0;
			if(!name_chars(n, "_")){
				why = "a packet's name is not [A-Za-z0-9_]";
				return 0;
			}
			if(m_sent.size() >= MAX_PACKETS){
				why = "more than "+itos(MAX_PACKETS)+" packets in a call";
				return 0;
			}
			m_sent.push_back({a[0], n, data});
			return 0;
		}
		case WI_STORAGE_GET: {
			ss_ key, value;
			if(!bytes_arg(a[0], a[1], MAX_KEY, key, why))
				return 0;
			if(key.empty()){
				why = "an empty key";
				return 0;
			}
			storage::Store *st = store(why);
			if(!st)
				return 0;
			if(!st->get(key, value))
				return (uint32_t)-1;
			return give_bytes(value, a[2], a[3], why);
		}
		case WI_STORAGE_SET:
		case WI_STORAGE_REMOVE: {
			ss_ key, value;
			if(!bytes_arg(a[0], a[1], MAX_KEY, key, why) ||
					(which == WI_STORAGE_SET &&
					!bytes_arg(a[2], a[3], MAX_VALUE, value, why)))
				return 0;
			if(key.empty()){
				why = "an empty key";
				return 0;
			}
			storage::Store *st = store(why);
			if(!st)
				return 0;
			ss_ old;
			const int64_t old_bytes = st->get(key, old) ?
					(int64_t)(key.size() + old.size()) : 0;
			const int64_t new_bytes = which == WI_STORAGE_SET ?
					(int64_t)(key.size() + value.size()) : 0;
			if(m_stored - old_bytes + new_bytes > MAX_STORED){
				why = "past the module's "+itos(MAX_STORED)+" bytes of storage";
				return 0;
			}
			m_engine.import_cost += 200000; // a write to the database: ~50 us
			if(which == WI_STORAGE_SET)
				st->set(key, value);
			else
				st->remove(key);
			m_stored += new_bytes - old_bytes;
			return 0;
		}
		case WI_SCENE_CREATE: {
			if(m_scenes.size() >= MAX_SCENES){
				why = "more than "+itos(MAX_SCENES)+" scenes";
				return 0;
			}
			Scene sc;
			main_context::access(m_server, [&](main_context::Interface *i){
				sc.ref = i->create_scene();
			});
			m_scenes.push_back(sc);
			Slot s;
			s.kind = Slot::SCENE;
			s.scene = sc.ref;
			const uint32_t h = m_handles.give(s);
			if(!h)
				why = "more than "+itos(m_handles.cap)+" handles";
			return h;
		}
		case WI_SCENE_PEER: {
			Scene *sc = nullptr;
			if(a[0] != 0 && !(sc = scene_arg(a[0], why)))
				return 0;
			const replicate::PeerId peer = a[1];
			bool connected = false, ours = false;
			network::access(m_server, [&](network::Interface *i){
				for(network::PeerInfo::Id p : i->list_peers())
					connected = connected || p == peer;
			});
			if(!connected)
				return 0; // gone, as a packet to it is
			replicate::access(m_server, [&](replicate::Interface *i){
				// Taken off a scene only if it is one of this module's
				if(!sc){
					for(const Scene &s : m_scenes)
						for(replicate::PeerId p : i->find_peers_on_scene(s.ref))
							ours = ours || p == peer;
					if(ours)
						i->assign_scene_to_peer(nullptr, peer);
					return;
				}
				i->assign_scene_to_peer(sc->ref, peer);
			});
			return 0;
		}
		case WI_NODE_CREATE: {
			Scene *sc = scene_arg(a[0], why);
			if(!sc)
				return 0;
			uint32_t id = 0;
			main_context::access(m_server, sc->ref,
					[&](Urho3D::Scene *scene){
				id = scene->CreateChild()->GetID();
			});
			Slot s;
			s.kind = Slot::NODE;
			s.scene = sc->ref;
			s.node = id;
			const uint32_t h = m_handles.give(s);
			if(!h){
				why = "more than "+itos(m_handles.cap)+" handles";
				node_remove(sc->ref, id);
			}
			return h;
		}
		case WI_NODE_GET:
		case WI_NODE_SET:
		case WI_NODE_REMOVE: {
			Slot *s = m_handles.get(a[0], why);
			if(!s)
				return 0;
			if(s->kind != Slot::NODE){
				why = "not a node's handle";
				return 0;
			}
			if(which == WI_NODE_REMOVE){
				node_remove(s->scene, s->node);
				Slot old;
				m_handles.drop(a[0], why, &old);
				return 0;
			}
			float t[10];
			if(which == WI_NODE_SET){
				if(!m_engine.copy_in(a[1], sizeof t, t)){
					why = PAST;
					return 0;
				}
				if(!transform_ok(t, why))
					return 0;
			}
			bool gone = true;
			m_engine.import_cost += 1000;
			main_context::access(m_server, s->scene,
					[&](Urho3D::Scene *scene){
				Urho3D::Node *n = scene->GetNode(s->node);
				if(!n || n->GetScene() != scene)
					return;
				gone = false;
				if(which == WI_NODE_SET){
					Urho3D::Quaternion q(t[3], t[4], t[5], t[6]);
					q.Normalize();
					n->SetTransform(Urho3D::Vector3(t[0], t[1], t[2]), q,
							Urho3D::Vector3(t[7], t[8], t[9]));
					return;
				}
				const Urho3D::Vector3 p = n->GetPosition(), sc = n->GetScale();
				const Urho3D::Quaternion q = n->GetRotation();
				const float out[10] = {p.x_, p.y_, p.z_, q.w_, q.x_, q.y_, q.z_,
						sc.x_, sc.y_, sc.z_};
				memcpy(t, out, sizeof t);
			});
			if(gone){
				why = "its node is gone";
				return 0;
			}
			if(which == WI_NODE_GET && !m_engine.copy_out(a[1], t, sizeof t))
				why = PAST;
			return 0;
		}
		case WI_WORLD_CREATE: {
			Scene *sc = scene_arg(a[0], why);
			if(!sc)
				return 0;
			if(sc->world){
				why = "the scene has a world already";
				return 0;
			}
			int32_t s[6];
			if(!m_engine.copy_in(a[1], sizeof s, s)){
				why = PAST;
				return 0;
			}
			int64_t count = 1;
			for(int k = 0; k < 3; k++){
				const int64_t span = (int64_t)s[k + 3] - s[k] + 1;
				if(span < 1 || span > MAX_WORLD_SPAN || s[k] < -30000 ||
						s[k + 3] > 30000){
					why = "a world from section "+itos(s[k])+" to "+
							itos(s[k + 3])+": 1 to "+itos(MAX_WORLD_SPAN)+
							" sections on each axis, inside +-30000";
					return 0;
				}
				count *= span;
			}
			if(count > MAX_WORLD_SECTIONS){
				why = "more than "+itos(MAX_WORLD_SECTIONS)+" sections";
				return 0;
			}
			m_engine.import_cost += 1000000;
			const pv::Region region(s[0], s[1], s[2], s[3], s[4], s[5]);
			pv::Vector3DInt16 size;
			voxelworld::access(m_server, [&](voxelworld::Interface *i){
				if(i->get_instance(sc->ref))
					throw Exception("the scene has a world already");
				i->create_instance(sc->ref, region);
				voxelworld::Instance *w = i->get_instance(sc->ref);
				w->get_voxel_reg()->set_format(interface::VoxelFormat::blocks());
				size = w->get_section_size_voxels();
			});
			sc->world = true;
			sc->voxels = pv::Region(s[0] * size.getX(), s[1] * size.getY(),
					s[2] * size.getZ(), (s[3] + 1) * size.getX() - 1,
					(s[4] + 1) * size.getY() - 1, (s[5] + 1) * size.getZ() - 1);
			return 0;
		}
		case WI_VOXEL_DEFINE: {
			Scene *sc = scene_arg(a[0], why);
			if(!sc)
				return 0;
			if(!sc->world){
				why = "the scene has no world (buildat_world_create())";
				return 0;
			}
			ss_ n, tex;
			if(!name_arg(a[1], a[2], 64, n, why) ||
					!bytes_arg(a[3], a[4], 128, tex, why))
				return 0;
			bool lower = true;
			for(char c : n)
				lower = lower && !isupper((unsigned char)c);
			if(!name_chars(n, "_:") || !lower){
				why = "a voxel's name is not [a-z0-9_:]";
				return 0;
			}
			if(!name_chars(tex, "_./-") || tex.find("..") != ss_::npos ||
					(!tex.empty() && tex[0] == '/')){
				why = "a texture's name is not a file the clients have "
						"([A-Za-z0-9_./-], no \"..\")";
				return 0;
			}
			if(m_voxel_types >= MAX_VOXEL_TYPES){
				why = "more than "+itos(MAX_VOXEL_TYPES)+" voxel types";
				return 0;
			}
			interface::VoxelDefinition d;
			d.name.block_name = n;
			for(size_t i = 0; i < 6; i++){
				interface::AtlasSegmentDefinition &seg = d.textures[i];
				seg.resource_name = tex;
				seg.total_segments = Urho3D::IntVector2(tex.empty() ? 0 : 1,
						tex.empty() ? 0 : 1);
				seg.select_segment = Urho3D::IntVector2(0, 0);
			}
			d.edge_material_id = tex.empty() ? interface::EDGEMATERIALID_EMPTY :
					interface::EDGEMATERIALID_GROUND;
			d.physically_solid = !tex.empty();
			d.fully_empty = tex.empty();
			uint32_t id = 0;
			m_engine.import_cost += 100000;
			voxelworld::access(m_server, [&](voxelworld::Interface *i){
				voxelworld::Instance *w = i->get_instance(sc->ref);
				if(!w)
					throw Exception("the scene's world is gone");
				// A name defined already throws
				id = w->get_voxel_reg()->add_voxel(d);
			});
			m_voxel_types++;
			sc->types.insert(id);
			return id;
		}
		case WI_VOXELS_SET:
		case WI_VOXELS_READ: {
			Scene *sc = scene_arg(a[0], why);
			if(!sc)
				return 0;
			pv::Region r;
			const uint64_t n = box_arg(*sc, a[1], r, why);
			if(!n)
				return 0;
			if(n * 4 > a[3]){
				why = itos(a[3])+" bytes for "+itos(n)+" voxels, not "+
						itos(n * 4);
				return 0;
			}
			if((uint64_t)a[2] + n * 4 > m_engine.memory_size()){
				why = PAST;
				return 0;
			}
			m_engine.import_cost += n * 16;
			sv_<uint32_t> ids(n);
			if(which == WI_VOXELS_SET){
				if(!m_engine.copy_in(a[2], n * 4, ids.data())){
					why = PAST;
					return 0;
				}
				for(uint32_t id : ids)
					if(id != interface::VOXELTYPEID_UNDEFINED && !sc->types.count(id)){
						why = "voxel type "+itos(id)+" is not one the module "
								"defined in this scene";
						return 0;
					}
			}
			voxelworld::access(m_server, [&](voxelworld::Interface *i){
				voxelworld::Instance *w = i->get_instance(sc->ref);
				if(!w)
					throw Exception("the scene's world is gone");
				const interface::VoxelFormat &f = w->get_voxel_reg()->get_format();
				size_t k = 0;
				const pv::Vector3DInt32 lc = r.getLowerCorner(),
						uc = r.getUpperCorner();
				if(which == WI_VOXELS_SET){
					interface::VoxelVolume v(r);
					for(int32_t z = lc.getZ(); z <= uc.getZ(); z++)
					for(int32_t y = lc.getY(); y <= uc.getY(); y++)
					for(int32_t x = lc.getX(); x <= uc.getX(); x++){
						const uint32_t id = ids[k++];
						if(id == interface::VOXELTYPEID_UNDEFINED)
							continue;
						uint32_t word = 0;
						f.id.set(word, id);
						v.setVoxelAt(x, y, z, interface::VoxelInstance(word));
					}
					w->set_volume(v, true);
					return;
				}
				const interface::VoxelVolume v = w->get_volume(r);
				for(int32_t z = lc.getZ(); z <= uc.getZ(); z++)
				for(int32_t y = lc.getY(); y <= uc.getY(); y++)
				for(int32_t x = lc.getX(); x <= uc.getX(); x++)
					ids[k++] = f.id_of(v.getVoxelAt(x, y, z).data);
			});
			if(which == WI_VOXELS_READ){
				if(!m_engine.copy_out(a[2], ids.data(), n * 4))
					why = PAST;
				return (uint32_t)n;
			}
			return 0;
		}
		case WI_CALL:
			return call_import(a, why);
		}
		why = "no such import";
		return 0;
	}

	uint32_t subscribe(Event::Type type, uint32_t kind, const ss_ &packet,
			ss_ &why)
	{
		if(!m_kinds.count(type) && m_kinds.size() >= MAX_SUBSCRIPTIONS){
			why = "more than "+itos(MAX_SUBSCRIPTIONS)+" subscriptions";
			return 0;
		}
		if(!m_kinds.count(type) && type != m_tick_type)
			m_server->sub_event(this, type);
		m_kinds[type] = kind;
		if(kind == EV_PACKET)
			m_packet_names[type] = packet;
		return 0;
	}

	void node_remove(main_context::SceneReference ref, uint32_t id)
	{
		main_context::access(m_server, ref, [&](Urho3D::Scene *scene){
			Urho3D::Node *n = scene->GetNode(id);
			if(n && n != scene && n->GetScene() == scene)
				n->Remove();
		});
	}

	// buildat_call(): -1 when refused or failed, said once a call
	uint32_t call_import(const uint32_t *a, ss_ &why)
	{
		ss_ target, fn, input;
		if(!name_arg(a[0], a[1], 64, target, why) ||
				!name_arg(a[2], a[3], 64, fn, why) ||
				!bytes_arg(a[4], a[5], MAX_CALL_BYTES, input, why))
			return 0;
		if((uint64_t)a[6] + a[7] > m_engine.memory_size()){
			why = "past the module's memory";
			return 0;
		}
		m_engine.import_cost += 40000; // ~9 us, a switch of threads each way
		auto refused = [&](const ss_ &reason) -> uint32_t {
			if(++m_engine.logged <= MAX_LOG_LINES)
				log_w(MODULE, "wasm %s: buildat_call(%s, %s) refused: %s",
						cs(m_info.name), cs(printable((const uint8_t*)
						target.data(), target.size())), cs(printable(
						(const uint8_t*)fn.data(), fn.size())), cs(reason));
			return (uint32_t)-1;
		};
		if(!name_chars(target, "_") || !name_chars(fn, "_"))
			return refused("not a module's and an export's name");
		for(const ss_ &c : m_chain)
			if(c == target)
				return refused(target+" is in this call's chain already");
		if(!m_server->has_module(target))
			return refused("no module "+target);
		// The first call of a chain takes the token; one it makes waits for
		// no other
		const bool first = !m_serving && !m_holds_token;
		if(first){
			if(!g_call_token.try_lock_for(std::chrono::milliseconds(
					CALL_WAIT_MS)))
				return refused("another call between modules is under way");
			m_holds_token = true;
		}
		const sv_<ss_> chain = m_chain.empty() ? sv_<ss_>{m_info.name} : m_chain;
		ss_ out, err;
		try {
			m_server->access_module(target, [&](interface::Module *m){
				WasmModule *w = dynamic_cast<WasmModule*>(m);
				if(!w){
					err = target+" is not a wasm module";
					return;
				}
				err = w->serve_call(fn, input, chain, out);
			});
		} catch(std::exception &e){
			err = e.what();
		}
		if(first){
			m_holds_token = false;
			g_call_token.unlock();
		}
		if(!err.empty())
			return refused(err);
		return give_bytes(out, a[6], a[7], why);
	}
};

uint32_t ServerEngine::import_body(uint32_t which, const uint32_t *a, ss_ &why)
{
	return owner->import_body(which, a, why);
}

void ServerEngine::on_fail()
{
	owner->m_queue.clear();
	owner->m_queue_bytes = 0;
	owner->m_sent.clear();
}

interface::Module* create_wasm_module(interface::Server *server,
		const interface::ModuleInfo &info, const ss_ &wasm_path,
		const ss_ &cache_root, ss_ &why)
{
	set_server_imports();
	std::ifstream f(wasm_path, std::ios::binary);
	std::ostringstream os(std::ios::binary);
	os<<f.rdbuf();
	if(!f.good()){
		why = "its .wasm could not be read";
		return nullptr;
	}
	up_<WasmModule> m(new WasmModule(server, info, cache_root));
	if(!m->prepare(os.str(), why))
		return nullptr;
	return m.release();
}

}
// vim: set noet ts=4 sw=4:
