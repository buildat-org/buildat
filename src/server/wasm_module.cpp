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
// them with buildat_event_take()). An import calls into no wasm, its own
// or another's. A call that traps is logged and the module goes on; one
// past its budget stops the module, and the server goes on.
//
// The boundary's bytes: an event is little-endian 32-bit words, its kind
// first, then its numbers, and a name or data as their bytes -- the
// layout of the client's events (wasm_api.h), so one parser reads both,
// and a no_std module reads it with a few lines; wasm's memory is
// little-endian, so a word is one load.
#include "server/wasm_module.h"
#include "server/wasm_imports.h"
#include "wasm/engine.h"
#include "interface/module.h"
#include "interface/module_info.h"
#include "interface/server.h"
#include "interface/fs.h"
#include "network/api.h"
#include "core/log.h"
#include <deque>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <cstring>
#define MODULE "wasm"

namespace server {

using namespace wasm_engine;
using interface::Event;

// Per module
static const size_t MAX_EVENTS = 256; // queued
static const size_t MAX_EVENT_BYTES = 4 << 20; // queued
static const size_t MAX_SUBSCRIPTIONS = 64;
static const size_t MAX_NAME = 128; // an event's name

// wasm_server_api.h's event kinds
enum { EV_START = 1, EV_TICK = 2, EV_PEER_JOINED = 3, EV_PEER_LEFT = 4 };
// The events a module may subscribe to by name: what their bytes carry is
// known. Packets are by the module's own names (packet_subscribe).
static const struct { const char *name; uint32_t kind; } SUBSCRIBABLE[] = {
	{"core:start", EV_START},
	{"core:tick", EV_TICK},
	{"network:client_connected", EV_PEER_JOINED},
	{"network:client_disconnected", EV_PEER_LEFT},
};

static void put32(ss_ &b, uint32_t v)
{
	const char w[4] = {(char)(v & 0xff), (char)((v >> 8) & 0xff),
			(char)((v >> 16) & 0xff), (char)(v >> 24)};
	b.append(w, 4);
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
	ServerEngine m_engine;
	// The exports the server calls (exports.size() for none)
	size_t m_init = 0, m_events = 0;
	bool m_inited = false;
	// The events it subscribed to, by type: their kinds
	std::map<Event::Type, uint32_t> m_kinds;
	Event::Type m_tick_type = 0;
	// Its events, queued for buildat_event_take()
	std::deque<ss_> m_queue;
	size_t m_queue_bytes = 0;
	bool m_queue_full_said = false;

	WasmModule(interface::Server *server, const interface::ModuleInfo &info):
		interface::Module("(wasm)"),
		m_server(server),
		m_info(info)
	{
		m_module_name = m_info.name.c_str();
		m_engine.owner = this;
		m_engine.name = m_info.name;
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
		m_engine.cache_root = cache_root;
		m_engine.start();
		ready();
	}

	ss_ cache_root;

	// The module's init(), once it runs
	void ready()
	{
		m_engine.poll();
		if(m_inited || m_engine.state != Engine::READY)
			return;
		m_inited = true;
		if(m_init < m_engine.exports.size())
			run(m_init);
	}

	// An export called: a trap logged, a run past its budget stops it
	void run(size_t index)
	{
		if(m_engine.state != Engine::READY || m_engine.in_call)
			return;
		uint64_t args[1] = {0}, r = 0;
		const ss_ trap = m_engine.call(index, args, &r);
		if(trap.empty())
			return;
		const ss_ &fn = m_engine.exports[index].name;
		if(m_engine.past_budget()){
			m_engine.fail("stopped: "+fn+" ran past its budget of "+
					itos(m_engine.budget())+" (a loop that does not end?)");
			return;
		}
		log_w(MODULE, "wasm %s: %s: trap: %s", cs(m_info.name), cs(fn),
				cs(trap));
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
		default:
			break;
		}
		push(e);
		if(m_events < m_engine.exports.size() && m_engine.state == Engine::READY)
			run(m_events);
	}

	// A name the module handed: its bytes, checked
	bool name_arg(uint32_t ptr, uint32_t len, ss_ &out, ss_ &why)
	{
		if(len < 1 || len > MAX_NAME){
			why = "a name of "+itos(len)+" bytes (1 to "+itos(MAX_NAME)+")";
			return false;
		}
		out.assign(len, '\0');
		if(!m_engine.copy_in(ptr, len, &out[0])){
			why = "past the module's memory";
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
			const ss_ &e = m_queue.front();
			if(e.size() > a[1])
				return (uint32_t)e.size();
			if(!m_engine.copy_out(a[0], e.data(), e.size())){
				why = PAST;
				return 0;
			}
			const uint32_t n = (uint32_t)e.size();
			m_engine.import_cost += n;
			m_queue_bytes -= e.size();
			m_queue.pop_front();
			return n;
		}
		case WI_EVENT_SUBSCRIBE: {
			ss_ n;
			if(!name_arg(a[0], a[1], n, why))
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
			if(m_kinds.size() >= MAX_SUBSCRIPTIONS){
				why = "more than "+itos(MAX_SUBSCRIPTIONS)+" subscriptions";
				return 0;
			}
			const Event::Type type = Event::t(n);
			if(!m_kinds.count(type) && type != m_tick_type)
				m_server->sub_event(this, type);
			m_kinds[type] = kind;
			return 0;
		}
		}
		why = "no such import";
		return 0;
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
	up_<WasmModule> m(new WasmModule(server, info));
	m->cache_root = cache_root;
	if(!m->prepare(os.str(), why))
		return nullptr;
	return m.release();
}

}
// vim: set noet ts=4 sw=4:
