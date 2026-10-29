// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [KIT] stage 2, the runtime: api.h says what it is. Here: the box (a
// wasm_engine::Engine running box/'s Lua), the entity tree with its
// instances, the queue of runs a tick works through within its budget,
// the save's two rows, the nodes that carry shared state to the clients,
// and the voxels the instances own.
#include "kit/api.h"
#include "main_context/api.h"
#include "network/api.h"
#include "storage/api.h"
#include "voxelworld/api.h"
#include "interface/wasm_box.h"
#include "core/log.h"
#include "core/json.h"
#include "interface/fs.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include <Scene.h>
#include <Node.h>
#include <chrono>
#include <cmath>
#include <deque>
#include <fstream>
#include <mutex>
#include <set>
#include <sstream>
#define MODULE "kit"

namespace kit {

namespace pv = PolyVox;
namespace magic = Urho3D;
using interface::Event;
using json::jstr;

// A signal passed along more links than this is a loop, and cut
static const int MAX_HOPS = 16;
static const size_t MAX_QUEUE = 4096;
// A run's slice of the box's meter is its budget() / this (about 5 ms of
// a plain loop); a tick works through TICK_SLICES of them at most
static const int64_t SLICE_DIV = 20;
static const int64_t TICK_SLICES = 4;
static const size_t MAX_TYPE_SOURCE = 256 << 10;

struct Link
{
	ss_ output;
	uint64_t to = 0;
	ss_ input;
};

struct Instance
{
	ss_ type;
	json::Value params = json::object(); // authored
	sv_<Link> links; // authored
	json::Value state = json::object(); // runtime
	ss_ disabled; // runtime: why, "" while it runs
};

struct Entity
{
	uint64_t id = 0, parent = 0;
	ss_ name, kind; // "app", "scene" or "" (an entity)
	bool has_pos = false;
	double pos[3] = {0, 0, 0};
	sv_<Instance> comps;
	uint32_t node = 0; // a positional one's node in its scene
};

struct Type
{
	json::Value decl;
	std::set<ss_> inputs, outputs, handlers, shared;
	bool usable = false, owns_voxel = false;
};

struct Run
{
	uint64_t entity = 0;
	size_t comp = 0;
	ss_ handler;
	json::Value args = json::array();
	ss_ by = "app"; // who caused it, carried along the links
	int hops = 0;
};

struct Write
{
	main_context::SceneReference scene = nullptr;
	pv::Vector3DInt32 p;
	ss_ voxel, by;
};

struct Peer
{
	ss_ name, scene;
	double pos[3] = {0, 0, 0};
};

struct Module;

// voxelworld's side: a write to a position Kit owns, queued for Kit's
// thread (it comes on voxelworld's, under its lock)
struct Owner: public voxelworld::OwnerHandler
{
	main_context::SceneReference scene;
	std::mutex *mutex;
	std::deque<Write> *queue;
	void on_write(voxelworld::Instance *world, const pv::Vector3DInt32 &p,
			const interface::VoxelInstance &v, const voxelworld::Owned &owned,
			const ss_ &by)
	{
		Write w;
		w.scene = scene;
		w.p = p;
		const interface::VoxelDefinition *def =
				world->get_voxel_reg()->get(world->get_voxel_reg()->get_format().
				id.get(v.data));
		w.voxel = def ? def->name.block_name : "?";
		w.by = by;
		std::lock_guard<std::mutex> lock(*mutex);
		if(queue->size() < MAX_QUEUE)
			queue->push_back(w);
	}
};

// A JSON value as a Lua literal, for the box's requests (which it reads
// with an empty environment)
static void lua_lit(const json::Value &v, ss_ &o, int depth = 0)
{
	if(depth > 32){
		o += "nil";
		return;
	}
	switch(v.get_type()){
	case json::Value::T_BOOL:
		o += v.as_boolean() ? "true" : "false";
		return;
	case json::Value::T_INT:
		o += itos(v.as_integer());
		return;
	case json::Value::T_FLOAT: {
		const double d = v.as_real();
		if(d != d){
			o += "(0/0)";
		} else if(std::isinf(d)){
			o += d > 0 ? "(1/0)" : "(-1/0)";
		} else {
			char b[40];
			snprintf(b, sizeof b, "%.17g", d);
			o += b;
		}
		return; }
	case json::Value::T_STRING: {
		o += '"';
		for(unsigned char c : v.as_string()){
			if(c == '"' || c == '\\'){
				o += '\\';
				o += (char)c;
			} else if(c < 32 || c == 127){
				char b[8];
				snprintf(b, sizeof b, "\\%03d", c);
				o += b;
			} else {
				o += (char)c;
			}
		}
		o += '"';
		return; }
	case json::Value::T_ARRAY:
		o += '{';
		for(unsigned i = 0; i < v.size(); i++){
			lua_lit(v.at(i), o, depth + 1);
			o += ',';
		}
		o += '}';
		return;
	case json::Value::T_OBJECT:
		o += '{';
		for(json::Iterator it(v); it; ++it){
			o += '[';
			lua_lit(json::Value(it.key()), o, depth + 1);
			o += "]=";
			lua_lit(*it, o, depth + 1);
			o += ',';
		}
		o += '}';
		return;
	default:
		o += "nil";
	}
}

static ss_ read_file(const ss_ &path)
{
	std::ifstream f(path, std::ios::binary);
	std::ostringstream os(std::ios::binary);
	os<<f.rdbuf();
	return os.str();
}

static bool name_ok(const ss_ &s)
{
	if(s.empty() || s.size() > 64)
		return false;
	for(char c : s)
		if(!isalnum((unsigned char)c) && c != '_')
			return false;
	return true;
}

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;
	bool m_hosted = false;
	Host m_host;
	storage::Store *m_store = nullptr;
	up_<interface::WasmBox> m_box;
	bool m_starting = false;
	sm_<ss_, ss_> m_sources; // the types' Lua, by name
	sm_<ss_, Type> m_types;
	std::map<uint64_t, Entity> m_entities;
	uint64_t m_next_id = 2;
	std::deque<Run> m_queue;
	sm_<size_t, Peer> m_peers;
	bool m_runtime_dirty = false;
	// Writes routed to owned voxels, from voxelworld's thread
	std::mutex m_writes_mutex;
	std::deque<Write> m_writes;
	// Voxels an instance set whose section was not loaded: tried each tick
	std::deque<Write> m_pending_voxels;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		if(m_hosted){
			// The owner handlers hold pointers into this module
			voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
				for(auto &s : m_host.scenes){
					voxelworld::Instance *w = ivw->get_instance(s.second);
					if(w)
						w->set_owner_handler("kit", nullptr);
				}
			});
			save_runtime();
		}
	}

	void init()
	{
		sub(m_server, "core:tick", &Module::on_tick);
		sub(m_server, "network:packet_received/kit:use", &Module::on_use);
		sub(m_server, "network:client_disconnected", &Module::on_left);
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}

	// ---- The box

	bool start_box(ss_ &why)
	{
		// The new box is made before the old one goes: a compile of the
		// .wasm under way is then the new one's to wait on, not killed (and
		// waited for) with the old
		up_<interface::WasmBox> b(m_server->create_wasm_box(MODULE, "box",
				why));
		m_box = std::move(b);
		if(!m_box)
			return false;
		// The types again: a new box knows none. One that fails here
		// leaves no box (no restart inside a restart)
		m_starting = true;
		for(auto &s : m_sources){
			ss_ answer;
			if(!define(s.first, s.second, answer, why)){
				m_starting = false;
				m_box.reset();
				return false;
			}
		}
		m_starting = false;
		return true;
	}

	// One request: true and the answer, or false and the error.
	// *runaway: the meter stopped it (the box is a new one after that)
	bool box_call(const ss_ &request, ss_ &answer, ss_ &error,
			bool *runaway = nullptr, int64_t *spent = nullptr)
	{
		if(runaway)
			*runaway = false;
		if(!m_box){
			error = "no box";
			return false;
		}
		m_box->poll();
		// A type's file (and the box's first making) runs with the whole
		// of a call's budget; a handler with its slice
		const int64_t slice = request[0] == 'D' ? m_box->budget() :
				m_box->budget() / SLICE_DIV;
		m_box->set_call_budget(slice);
		m_box->input = request;
		m_box->output.clear();
		uint32_t r = 0;
		const auto t0 = std::chrono::steady_clock::now();
		const ss_ trap = m_box->call("box_call", &r);
		log_d(MODULE, "A %c call: %i ms, %s, spent %lli of %lli", request[0],
				(int)std::chrono::duration_cast<std::chrono::milliseconds>(
				std::chrono::steady_clock::now() - t0).count(),
				trap.empty() ? "ok" : cs(trap),
				(long long)(slice - m_box->meter_left()), (long long)slice);
		if(spent)
			*spent = slice - std::max<int64_t>(0, m_box->meter_left());
		ss_ out = m_box->output;
		if(!trap.empty()){
			const bool past = m_box->meter_left() < 0;
			bool recovered = false;
			if(!past){
				m_box->input.clear();
				m_box->output.clear();
				const ss_ t2 = m_box->call("box_recover", &r);
				recovered = t2.empty() && r == 1;
				out = m_box->output;
			}
			if(!recovered){
				// The state inside is not to be trusted: a new box
				error = past ? "past its budget of "+itos(slice)+
						" (a loop that does not end?)" : "trap: "+trap;
				if(runaway)
					*runaway = past;
				ss_ why;
				if(m_starting){
					m_box.reset();
				} else if(!start_box(why)){
					log_e(MODULE, "The box could not be started again: %s",
							cs(why));
					m_box.reset();
				} else {
					log_w(MODULE, "A new box after: %s", cs(error));
				}
				return false;
			}
		}
		if(out.empty() || (out[0] != 'O' && out[0] != 'E')){
			error = "no answer";
			return false;
		}
		if(out[0] == 'E'){
			error = out.substr(1);
			return false;
		}
		answer = out.substr(1);
		return true;
	}

	bool define(const ss_ &name, const ss_ &src, ss_ &decl_json, ss_ &why)
	{
		ss_ request = "D"+name;
		request += '\0';
		request += src;
		if(!box_call(request, decl_json, why)){
			why = name+": "+why;
			return false;
		}
		return true;
	}

	bool load_type(const ss_ &name, ss_ &why)
	{
		if(m_types.count(name))
			return true;
		if(!name_ok(name)){
			why = "a type's name is letters, digits and _: \""+
					name.substr(0, 64)+"\"";
			return false;
		}
		const ss_ path = m_host.types_path+"/"+name+".lua";
		const ss_ src = read_file(path);
		if(src.empty() || src.size() > MAX_TYPE_SOURCE){
			why = "no component type "+name+" ("+path+")";
			return false;
		}
		ss_ decl_json;
		if(!define(name, src, decl_json, why))
			return false;
		m_sources[name] = src;
		Type t;
		t.decl = json::load_string(decl_json.c_str());
		auto names = [&](const char *key, std::set<ss_> &out){
			const json::Value &a = t.decl.get(key);
			for(unsigned i = 0; i < a.size(); i++)
				if(a.at(i).is_string())
					out.insert(a.at(i).as_string());
		};
		names("inputs", t.inputs);
		names("outputs", t.outputs);
		names("handlers", t.handlers);
		const json::Value &st = t.decl.get("state");
		if(st.is_object())
			for(json::Iterator it(st); it; ++it)
				if((*it).get("shared").is_true())
					t.shared.insert(it.key());
		t.usable = t.decl.get("usable").is_true();
		t.owns_voxel = t.decl.get("owns_voxel").is_true();
		m_types[name] = t;
		log_i(MODULE, "Component type %s: inputs %zu, outputs %zu, %s%s",
				cs(name), t.inputs.size(), t.outputs.size(),
				t.usable ? "usable" : "not usable",
				t.owns_voxel ? ", owns its voxel" : "");
		return true;
	}

	// ---- The tree

	main_context::SceneReference scene_of(const Entity &e, ss_ *name = nullptr)
	{
		uint64_t id = e.parent;
		for(int i = 0; i < 64 && id; i++){
			auto it = m_entities.find(id);
			if(it == m_entities.end())
				return nullptr;
			if(it->second.kind == "scene"){
				auto s = m_host.scenes.find(it->second.name);
				if(name)
					*name = it->second.name;
				return s == m_host.scenes.end() ? nullptr : s->second;
			}
			id = it->second.parent;
		}
		return nullptr;
	}

	static pv::Vector3DInt32 voxel_p(const Entity &e)
	{
		return pv::Vector3DInt32((int32_t)std::floor(e.pos[0]),
				(int32_t)std::floor(e.pos[1]), (int32_t)std::floor(e.pos[2]));
	}

	bool load_composition(const json::Value &c, ss_ &why)
	{
		Entity root;
		root.id = 1;
		root.kind = "app";
		root.name = "app";
		m_entities[1] = root;
		const json::Value &es = c.get("entities");
		for(unsigned i = 0; i < es.size(); i++){
			const json::Value &j = es.at(i);
			Entity e;
			e.id = (uint64_t)json::jint(j, "id", 0);
			e.parent = (uint64_t)json::jint(j, "parent", 1);
			e.name = jstr(j, "name");
			e.kind = jstr(j, "kind");
			if(e.id < 2 || m_entities.count(e.id)){
				why = "an entity's id is 2 or more and its own: "+
						j.stringify();
				return false;
			}
			if(e.kind != "" && e.kind != "scene"){
				why = "entity "+itos(e.id)+": no kind \""+e.kind+"\"";
				return false;
			}
			const json::Value &p = j.get("pos");
			if(p.size() == 3){
				e.has_pos = true;
				for(int k = 0; k < 3; k++)
					e.pos[k] = p.at(k).as_number();
			}
			const json::Value &cs_ = j.get("components");
			for(unsigned k = 0; k < cs_.size(); k++){
				const json::Value &cj = cs_.at(k);
				Instance in;
				in.type = jstr(cj, "type");
				if(!load_type(in.type, why))
					return false;
				const Type &t = m_types[in.type];
				// The parameters the type declares, its defaults under the
				// instance's
				const json::Value &decl = t.decl.get("params");
				if(decl.is_object())
					for(json::Iterator it(decl); it; ++it)
						in.params.set(it.key(), (*it).get("default"));
				const json::Value &pj = cj.get("params");
				if(pj.is_object())
					for(json::Iterator it(pj); it; ++it){
						if(!decl.get(it.key()).is_object()){
							why = "entity "+itos(e.id)+": "+in.type+
									" has no parameter "+it.key();
							return false;
						}
						in.params.set(it.key(), *it);
					}
				const json::Value &ls = cj.get("links");
				for(unsigned m = 0; m < ls.size(); m++){
					Link l;
					l.output = jstr(ls.at(m), "output");
					l.to = (uint64_t)json::jint(ls.at(m), "to", 0);
					l.input = jstr(ls.at(m), "input");
					if(!t.outputs.count(l.output)){
						why = "entity "+itos(e.id)+": "+in.type+
								" has no output "+l.output;
						return false;
					}
					in.links.push_back(l);
				}
				e.comps.push_back(in);
			}
			m_entities[e.id] = e;
		}
		m_next_id = std::max<uint64_t>((uint64_t)json::jint(c, "next_id", 2), 2);
		for(auto &p : m_entities){
			Entity &e = p.second;
			if(e.id != 1 && !m_entities.count(e.parent)){
				why = "entity "+itos(e.id)+": no parent "+itos(e.parent);
				return false;
			}
			m_next_id = std::max(m_next_id, e.id + 1);
			if(e.kind == "scene" && !m_host.scenes.count(e.name)){
				why = "scene "+e.name+": the app has none of that name";
				return false;
			}
			if(e.has_pos && !scene_of(e)){
				why = "entity "+itos(e.id)+" has a position and no scene";
				return false;
			}
			for(Instance &in : e.comps)
				for(const Link &l : in.links)
					if(!m_entities.count(l.to)){
						why = "entity "+itos(e.id)+": a link to "+itos(l.to)+
								", which is not there";
						return false;
					}
		}
		return true;
	}

	json::Value authored_json()
	{
		json::Value c = json::object();
		json::Value es = json::array();
		for(auto &p : m_entities){
			const Entity &e = p.second;
			if(e.id == 1)
				continue;
			json::Value j = json::object();
			j.set("id", (int64_t)e.id);
			j.set("parent", (int64_t)e.parent);
			j.set("name", e.name);
			if(!e.kind.empty())
				j.set("kind", e.kind);
			if(e.has_pos){
				json::Value pos = json::array();
				for(int k = 0; k < 3; k++)
					pos.append(e.pos[k]);
				j.set("pos", pos);
			}
			json::Value comps = json::array();
			for(const Instance &in : e.comps){
				json::Value cj = json::object();
				cj.set("type", in.type);
				cj.set("params", in.params);
				json::Value ls = json::array();
				for(const Link &l : in.links){
					json::Value lj = json::object();
					lj.set("output", l.output);
					lj.set("to", (int64_t)l.to);
					lj.set("input", l.input);
					ls.append(lj);
				}
				cj.set("links", ls);
				comps.append(cj);
			}
			j.set("components", comps);
			es.append(j);
		}
		c.set("entities", es);
		c.set("next_id", (int64_t)m_next_id);
		return c;
	}

	// {"<id>": [{"type", "state", "disabled"}, ...]}
	json::Value runtime_json()
	{
		json::Value r = json::object();
		for(auto &p : m_entities){
			if(p.second.comps.empty())
				continue;
			json::Value a = json::array();
			for(const Instance &in : p.second.comps){
				json::Value j = json::object();
				j.set("type", in.type);
				j.set("state", in.state);
				if(!in.disabled.empty())
					j.set("disabled", in.disabled);
				a.append(j);
			}
			r.set(itos(p.first), a);
		}
		return r;
	}

	void save_runtime()
	{
		if(!m_store || !m_runtime_dirty)
			return;
		m_store->set("runtime", runtime_json().stringify());
		m_runtime_dirty = false;
		log_v(MODULE, "Runtime state saved");
	}

	// ---- Hosting

	bool host(const Host &host, ss_ &why)
	{
		if(m_hosted){
			why = "Kit is hosted already";
			log_e(MODULE, "%s", cs(why));
			return false;
		}
		const bool ok = host_u(host, why);
		if(!ok)
			log_e(MODULE, "Not hosted: %s", cs(why));
		return ok;
	}

	bool host_u(const Host &host, ss_ &why)
	{
		m_host = host;
		if(!host.save){
			why = "no save";
			return false;
		}
		m_store = host.save->store("kit");
		if(!start_box(why)){
			why = "no box: "+why;
			return false;
		}
		log_i(MODULE, "The box is up (%s)", cs(m_box->engine_name()));

		// Authored: the save's, or the app's file the first time
		ss_ authored;
		bool first = false;
		if(!m_store->get("authored", authored)){
			authored = read_file(host.composition_path);
			if(authored.empty()){
				why = "no composition at "+host.composition_path;
				return false;
			}
			first = true;
		}
		json::json_error_t err;
		err.line = -1;
		const json::Value c = json::load_string(authored.c_str(), &err);
		if(!c.is_object()){
			why = "the composition is not a JSON object";
			return false;
		}
		if(!load_composition(c, why))
			return false;
		if(first)
			m_store->set("authored", authored_json().stringify());

		// Runtime: the save's, over each type's defaults
		ss_ runtime;
		const json::Value rt = m_store->get("runtime", runtime) ?
				json::load_string(runtime.c_str()) : json::object();
		for(auto &p : m_entities){
			Entity &e = p.second;
			const json::Value &saved = rt.get(itos(e.id));
			for(size_t i = 0; i < e.comps.size(); i++){
				Instance &in = e.comps[i];
				const json::Value &sd = m_types[in.type].decl.get("state");
				if(sd.is_object())
					for(json::Iterator it(sd); it; ++it)
						in.state.set(it.key(), (*it).get("default"));
				const json::Value &s = saved.at((unsigned)i);
				if(jstr(s, "type") == in.type){
					const json::Value &st = s.get("state");
					if(st.is_object())
						for(json::Iterator it(st); it; ++it)
							in.state.set(it.key(), *it);
					in.disabled = jstr(s, "disabled");
					if(!in.disabled.empty())
						log_w(MODULE, "Entity %s's %s stays disabled: %s",
								cs(itos(e.id)), cs(in.type), cs(in.disabled));
				} else {
					// New: its start
					Run r;
					r.entity = e.id;
					r.comp = i;
					r.handler = "on_start";
					m_queue.push_back(r);
					m_runtime_dirty = true;
				}
			}
		}

		// The nodes that carry the positional entities' shared state, and
		// the voxels they own
		for(auto &p : m_entities)
			if(p.second.has_pos)
				make_node(p.second);
		own_voxels();
		m_hosted = true;
		size_t n = 0;
		for(auto &p : m_entities)
			n += p.second.comps.size();
		log_i(MODULE, "Hosted: %zu entities, %zu instances, %zu types%s",
				m_entities.size(), n, m_types.size(),
				first ? " (the composition's first start)" : "");
		return true;
	}

	void make_node(Entity &e)
	{
		main_context::SceneReference ref = scene_of(e);
		main_context::access(m_server, ref, [&](magic::Scene *scene){
			magic::Node *n = scene->CreateChild(("kit:"+itos(e.id)).c_str());
			n->SetPosition(magic::Vector3(e.pos[0], e.pos[1], e.pos[2]));
			n->SetVar(magic::StringHash("kit_id"), magic::Variant((int)e.id));
			e.node = n->GetID();
		});
		for(size_t i = 0; i < e.comps.size(); i++)
			for(const ss_ &k : m_types[e.comps[i].type].shared)
				replicate_state(e, i, k);
	}

	void replicate_state(const Entity &e, size_t comp, const ss_ &key)
	{
		if(!e.node)
			return;
		const ss_ v = e.comps[comp].state.get(key).stringify();
		main_context::access(m_server, scene_of(e), [&](magic::Scene *scene){
			magic::Node *n = scene->GetNode(e.node);
			if(n)
				n->SetVar(magic::StringHash(("kit:"+key).c_str()),
						magic::Variant(v.c_str()));
		});
	}

	void own_voxels()
	{
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			for(auto &s : m_host.scenes){
				voxelworld::Instance *w = ivw->get_instance(s.second);
				if(!w)
					continue;
				auto owner = std::make_shared<Owner>();
				owner->scene = s.second;
				owner->mutex = &m_writes_mutex;
				owner->queue = &m_writes;
				w->set_owner_handler("kit", owner);
				// Each section's "kit" entries, replaced: loaded or not
				const pv::Vector3DInt16 ss = w->get_section_size_voxels();
				std::map<std::tuple<int, int, int>, voxelworld::OwnedList> by;
				for(auto &p : m_entities){
					const Entity &e = p.second;
					if(!e.has_pos || scene_of(e) != s.second)
						continue;
					bool owns = false;
					for(const Instance &in : e.comps)
						owns = owns || m_types[in.type].owns_voxel;
					if(!owns)
						continue;
					const pv::Vector3DInt32 v = voxel_p(e);
					auto div = [](int32_t a, int b){
						return (int)std::floor((double)a / b);
					};
					by[std::make_tuple(div(v.getX(), ss.getX()),
							div(v.getY(), ss.getY()), div(v.getZ(), ss.getZ()))].
							push_back(std::make_pair(v, itos(e.id)));
				}
				for(auto &b : by)
					w->set_section_owned(pv::Vector3DInt16(
							std::get<0>(b.first), std::get<1>(b.first),
							std::get<2>(b.first)), "kit", b.second);
			}
		});
	}

	// ---- Runs

	void queue_run(const Run &r)
	{
		if(m_queue.size() >= MAX_QUEUE){
			log_w(MODULE, "The queue is full: %s on entity %s dropped",
					cs(r.handler), cs(itos(r.entity)));
			return;
		}
		m_queue.push_back(r);
	}

	// An input to an entity: each of its instances that has it
	void deliver(uint64_t to, const ss_ &input, const json::Value &value,
			const ss_ &by, int hops)
	{
		auto it = m_entities.find(to);
		if(it == m_entities.end())
			return;
		for(size_t i = 0; i < it->second.comps.size(); i++){
			const Instance &in = it->second.comps[i];
			if(!m_types[in.type].inputs.count(input))
				continue;
			Run r;
			r.entity = to;
			r.comp = i;
			r.handler = "on_input";
			r.args.append(input);
			r.args.append(value);
			r.args.append(by);
			r.by = by;
			r.hops = hops;
			queue_run(r);
		}
	}

	ss_ request_of(const Entity &e, const Instance &in, const Run &r)
	{
		ss_ o = "Rreturn {type=";
		lua_lit(json::Value(in.type), o);
		o += ",handler=";
		lua_lit(json::Value(r.handler), o);
		o += ",id="+itos(e.id);
		if(e.has_pos){
			o += ",pos={";
			for(int k = 0; k < 3; k++){
				lua_lit(json::Value(e.pos[k]), o);
				o += ',';
			}
			o += '}';
		}
		o += ",params=";
		lua_lit(in.params, o);
		o += ",state=";
		lua_lit(in.state, o);
		o += ",args=";
		lua_lit(r.args, o);
		o += ",nargs="+itos(r.args.size())+"}";
		return o;
	}

	// One run; what it spent of the meter
	int64_t run(const Run &r)
	{
		auto it = m_entities.find(r.entity);
		if(it == m_entities.end() || r.comp >= it->second.comps.size())
			return 0;
		Entity &e = it->second;
		const ss_ type = e.comps[r.comp].type;
		if(!e.comps[r.comp].disabled.empty() ||
				!m_types[type].handlers.count(r.handler))
			return 0;
		ss_ answer, error;
		bool runaway = false;
		int64_t spent = 0;
		const ss_ request = request_of(e, e.comps[r.comp], r);
		if(!box_call(request, answer, error, &runaway, &spent)){
			if(runaway){
				Instance &in = m_entities[r.entity].comps[r.comp];
				in.disabled = r.handler+" ran past its budget";
				m_runtime_dirty = true;
				log_w(MODULE, "Entity %s's %s disabled: %s", cs(itos(r.entity)),
						cs(type), cs(in.disabled));
			} else {
				log_w(MODULE, "Entity %s's %s, %s: %s", cs(itos(r.entity)),
						cs(type), cs(r.handler), cs(error));
			}
			return spent;
		}
		const json::Value fx = json::load_string(answer.c_str());
		Instance &in = e.comps[r.comp];
		const Type &t = m_types[type];
		const json::Value &sets = fx.get("set");
		for(unsigned i = 0; i < sets.size(); i++){
			const json::Value &kv = sets.at(i);
			if(!kv.at(0u).is_string())
				continue;
			const ss_ k = kv.at(0u).as_string();
			in.state.set(k, kv.at(1u));
			m_runtime_dirty = true;
			if(t.shared.count(k))
				replicate_state(e, r.comp, k);
		}
		const json::Value &emits = fx.get("emit");
		for(unsigned i = 0; i < emits.size(); i++){
			const ss_ output = emits.at(i).at(0u).is_string() ?
					emits.at(i).at(0u).as_string() : ss_();
			if(!t.outputs.count(output)){
				log_w(MODULE, "Entity %s's %s emits %s, which it does not "
						"declare", cs(itos(e.id)), cs(type), cs(output));
				continue;
			}
			for(const Link &l : in.links){
				if(l.output != output)
					continue;
				if(r.hops + 1 > MAX_HOPS){
					log_w(MODULE, "A signal loop cut: entity %s's %s -> entity "
							"%s's %s, past %i links", cs(itos(e.id)), cs(output),
							cs(itos(l.to)), cs(l.input), MAX_HOPS);
					continue;
				}
				deliver(l.to, l.input, emits.at(i).at(1u), r.by, r.hops + 1);
			}
		}
		const json::Value &voxel = fx.get("voxel");
		if(voxel.is_string()){
			if(!t.owns_voxel || !e.has_pos){
				log_w(MODULE, "Entity %s's %s sets a voxel it does not own",
						cs(itos(e.id)), cs(type));
			} else {
				Write w;
				w.scene = scene_of(e);
				w.p = voxel_p(e);
				w.voxel = voxel.as_string();
				w.by = r.by;
				if(!set_voxel(w))
					m_pending_voxels.push_back(w);
			}
		}
		return spent;
	}

	// A voxel an instance sets: false if its section is not loaded yet
	bool set_voxel(const Write &w)
	{
		bool done = true;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *world = ivw->get_instance(w.scene);
			if(!world)
				return;
			const pv::Vector3DInt16 ss = world->get_section_size_voxels();
			auto div = [](int32_t a, int b){
				return (int16_t)std::floor((double)a / b);
			};
			const pv::Vector3DInt16 sp(div(w.p.getX(), ss.getX()),
					div(w.p.getY(), ss.getY()), div(w.p.getZ(), ss.getZ()));
			if(!world->is_section_loaded(sp)){
				done = false;
				return;
			}
			interface::VoxelRegistry *reg = world->get_voxel_reg();
			interface::VoxelName name;
			name.block_name = w.voxel;
			const interface::VoxelDefinition *def = reg->get(name);
			if(!def){
				log_w(MODULE, "No voxel type %s", cs(w.voxel));
				return;
			}
			uint32_t word = 0;
			reg->get_format().id.set(word, def->id);
			world->set_voxel(w.p, interface::VoxelInstance(word));
			log_v(MODULE, "Voxel (%i,%i,%i) set to %s by %s", w.p.getX(),
					w.p.getY(), w.p.getZ(), cs(w.voxel), cs(w.by));
		});
		return done;
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(!m_hosted || !m_box)
			return;
		m_box->poll();
		for(size_t n = m_pending_voxels.size(); n > 0; n--){
			Write w = m_pending_voxels.front();
			m_pending_voxels.pop_front();
			if(!set_voxel(w))
				m_pending_voxels.push_back(w);
		}
		// Writes routed to owned voxels: to the owner's on_voxel
		std::deque<Write> writes;
		{
			std::lock_guard<std::mutex> lock(m_writes_mutex);
			writes.swap(m_writes);
		}
		for(const Write &w : writes){
			bool owned = false;
			for(auto &p : m_entities){
				Entity &e = p.second;
				if(!e.has_pos || voxel_p(e) != w.p || scene_of(e) != w.scene)
					continue;
				for(size_t i = 0; i < e.comps.size(); i++){
					if(!m_types[e.comps[i].type].owns_voxel)
						continue;
					owned = true;
					Run r;
					r.entity = e.id;
					r.comp = i;
					r.handler = "on_voxel";
					r.args.append(w.voxel);
					r.args.append(w.by);
					r.by = w.by;
					queue_run(r);
				}
			}
			if(!owned)
				log_w(MODULE, "A write routed to (%i,%i,%i), which no entity "
						"owns now", w.p.getX(), w.p.getY(), w.p.getZ());
		}
		// The queue, in order, within the tick's budget
		const int64_t budget = m_box ? m_box->budget() / SLICE_DIV *
				TICK_SLICES : 0;
		int64_t spent = 0;
		while(!m_queue.empty() && spent < budget && m_box){
			const Run r = m_queue.front();
			m_queue.pop_front();
			spent += run(r);
		}
		if(!m_queue.empty())
			log_v(MODULE, "%zu runs wait for the next tick", m_queue.size());
		// simplified: the runtime row is written after each tick that
		// changed it; a write per interval is the upgrade if a busy world
		// makes it a cost
		save_runtime();
	}

	// ---- Clients act

	void on_use(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		const ss_ data = packet.data.substr(0, 32);
		char *end = nullptr;
		const uint64_t id = strtoull(data.c_str(), &end, 10);
		auto refuse = [&](const ss_ &why){
			log_i(MODULE, "A use of entity %s by peer %zu refused: %s",
					cs(data), peer, cs(why));
		};
		if(!m_hosted)
			return refuse("Kit is not hosted");
		if(data.empty() || !end || *end)
			return refuse("not an entity's id");
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end())
			return refuse("the app has not placed the player");
		auto it = m_entities.find(id);
		if(it == m_entities.end() || !it->second.has_pos)
			return refuse("no such object");
		Entity &e = it->second;
		ss_ scene;
		scene_of(e, &scene);
		if(scene != pi->second.scene)
			return refuse("in another scene");
		double d2 = 0;
		for(int k = 0; k < 3; k++)
			d2 += (e.pos[k] - pi->second.pos[k]) * (e.pos[k] - pi->second.pos[k]);
		if(d2 > m_host.use_range * m_host.use_range)
			return refuse("out of range");
		bool any = false;
		for(size_t i = 0; i < e.comps.size(); i++){
			const Type &t = m_types[e.comps[i].type];
			if(!t.usable || !t.handlers.count("on_use"))
				continue;
			any = true;
			Run r;
			r.entity = id;
			r.comp = i;
			r.handler = "on_use";
			r.by = "player:"+pi->second.name;
			r.args.append(r.by);
			queue_run(r);
		}
		if(!any)
			return refuse("nothing on it is usable");
		log_i(MODULE, "Entity %s used by %s", cs(itos(id)),
				cs(pi->second.name));
	}

	void on_left(const network::OldClient &old)
	{
		m_peers.erase(old.info.id);
	}

	void set_peer(size_t peer, const ss_ &name, const ss_ &scene,
			double x, double y, double z)
	{
		Peer &p = m_peers[peer];
		p.name = name;
		p.scene = scene;
		p.pos[0] = x;
		p.pos[1] = y;
		p.pos[2] = z;
	}

	void input(uint64_t entity, const ss_ &input, const ss_ &value)
	{
		deliver(entity, input, value.empty() ? json::null() :
				json::load_string(value.c_str()), "app", 0);
	}

	ss_ get_state(uint64_t entity, size_t component, const ss_ &key)
	{
		auto it = m_entities.find(entity);
		if(it == m_entities.end() || component >= it->second.comps.size())
			return "";
		const json::Value &v = it->second.comps[component].state.get(key);
		return v.is_undefined() ? "" : v.stringify();
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_kit(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
