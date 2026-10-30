// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [KIT] stage 2, the runtime: api.h says what it is. Here: the box (a
// wasm_engine::Engine running box/'s Lua), the entity tree with its
// instances, the queue of runs a tick works through within its budget,
// the save's two rows, the nodes that carry shared state to the clients,
// and the voxels the instances own.
#include "kit/api.h"
#include "accounts/api.h"
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
#include "interface/sha256.h"
#include <Scene.h>
#include <Node.h>
#include <chrono>
#include <cmath>
#include <deque>
#include <fstream>
#include <mutex>
#include <algorithm>
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
// What an editor's packet may be and do
static const size_t MAX_EDIT_PACKET = 4096;
static const size_t MAX_STRING = 256;
static const double MAX_COORD = 30000;
static const size_t MAX_ENTITIES = 4096;
static const size_t MAX_LINKS = 64;
// An editor's undo goes back this many edits
static const size_t UNDO_MAX = 50;

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
	bool editing = false;
};

// One edit: the entities it changed as they were before (null: not there),
// in the order an undo puts them back
struct Change
{
	sv_<std::pair<uint64_t, json::Value>> before;
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
	// The editor: edit rights the app gave or took (set_editor) over the
	// accounts' default, the types an editor places (every file in
	// types_path that loads), each editor's undo, and the sections Kit owns
	// positions in, each scene's
	std::map<ss_, bool> m_rights;
	std::set<ss_> m_palette;
	sm_<ss_, std::deque<Change>> m_undo;
	std::map<main_context::SceneReference,
			std::set<std::tuple<int, int, int>>> m_owned_sections;
	// Play from edit mode: a test's throwaway runtime, and what it put
	// aside to bring back at its end (the runtime row as it was, the runs
	// and voxel writes waiting, the owned voxels)
	struct Test
	{
		bool on = false;
		size_t peer = 0;
		ss_ name;
		json::Value runtime;
		std::deque<Run> queue;
		std::deque<Write> pending;
		sv_<Write> voxels;
	} m_test;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		// The owner handlers hold pointers into this module. Nothing is
		// saved here: the runtime row is written after each tick that
		// changed it, and the app's save may be closed by now
		if(m_hosted) try {
			voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
				for(auto &s : m_host.scenes){
					voxelworld::Instance *w = ivw->get_instance(s.second);
					if(w)
						w->set_owner_handler("kit", nullptr);
				}
			});
		} catch(std::exception &e){
			log_w(MODULE, "The voxel owners' handlers not taken back: %s",
					e.what());
		}
	}

	void init()
	{
		sub(m_server, "core:tick", &Module::on_tick);
		sub(m_server, "network:packet_received/kit:use", &Module::on_use);
		sub(m_server, "network:packet_received/kit:edit", &Module::on_edit);
		sub(m_server, "network:client_disconnected", &Module::on_left);
		sub(m_server, "accounts:privs", &Module::on_privs);
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
		// "box", meta.json's "wasm_box"
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

	// A parameter's value as its declaration types it: "" when it is one,
	// else what it should be. The composition's, the save's and an
	// editor's values all pass here
	ss_ check_param(const json::Value &decl, const json::Value &v)
	{
		const ss_ t = jstr(decl, "type");
		if(t == "number"){
			if(!v.is_number() || !std::isfinite(v.as_number()))
				return "a number";
			const json::Value &lo = decl.get("min"), &hi = decl.get("max");
			if(lo.is_number() && v.as_number() < lo.as_number())
				return "at least "+lo.stringify();
			if(hi.is_number() && v.as_number() > hi.as_number())
				return "at most "+hi.stringify();
			return "";
		}
		if(t == "bool")
			return v.is_boolean() ? "" : "true or false";
		if(t == "string"){
			if(!v.is_string() || v.as_string().size() > MAX_STRING)
				return "a string of at most "+itos(MAX_STRING)+" bytes";
			for(unsigned char c : v.as_string())
				if(c < 32 || c == 127)
					return "a line of text";
			return "";
		}
		if(t == "voxel"){
			if(!v.is_string() || v.as_string().empty() ||
					v.as_string().size() > 64)
				return "a voxel's name";
			for(char c : v.as_string())
				if(!isalnum((unsigned char)c) && c != '_' && c != ':')
					return "a voxel's name (letters, digits, _ and :)";
			return "";
		}
		if(t == "entity"){
			// 0: none
			if(!v.is_number() || v.as_number() != std::floor(v.as_number()) ||
					v.as_number() < 0 || v.as_number() > 9e15 ||
					(v.as_number() != 0 &&
					!m_entities.count((uint64_t)v.as_number())))
				return "an entity's id";
			return "";
		}
		if(t == "position")
			return pos_ok(v) ? "" : "a position, three numbers";
		return "a type of parameter Kit has (\""+t.substr(0, 32)+"\" is none)";
	}

	static bool pos_ok(const json::Value &p)
	{
		if(!p.is_array() || p.size() != 3)
			return false;
		for(unsigned k = 0; k < 3; k++)
			if(!p.at(k).is_number() || !std::isfinite(p.at(k).as_number()) ||
					std::fabs(p.at(k).as_number()) > MAX_COORD)
				return false;
		return true;
	}

	// An entity as the authored row has it (the parent and the links not
	// checked against the tree here)
	bool entity_from_json(const json::Value &j, Entity &e, ss_ &why)
	{
		e.id = (uint64_t)json::jint(j, "id", 0);
		e.parent = (uint64_t)json::jint(j, "parent", 1);
		e.name = jstr(j, "name");
		e.kind = jstr(j, "kind");
		if(e.id < 2){
			why = "an entity's id is 2 or more: "+j.stringify().substr(0, 200);
			return false;
		}
		if(e.kind != "" && e.kind != "scene"){
			why = "entity "+itos(e.id)+": no kind \""+e.kind+"\"";
			return false;
		}
		const json::Value &p = j.get("pos");
		if(!p.is_undefined()){
			if(!pos_ok(p)){
				why = "entity "+itos(e.id)+": a position is three numbers";
				return false;
			}
			e.has_pos = true;
			for(unsigned k = 0; k < 3; k++)
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
					const ss_ bad = check_param(decl.get(it.key()), *it);
					if(!bad.empty()){
						why = "entity "+itos(e.id)+": "+in.type+"'s "+
								it.key()+" is "+bad;
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
		return true;
	}

	json::Value entity_json(const Entity &e)
	{
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
		return j;
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
			Entity e;
			if(!entity_from_json(es.at(i), e, why))
				return false;
			if(m_entities.count(e.id)){
				why = "entity "+itos(e.id)+" twice";
				return false;
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
		for(auto &p : m_entities)
			if(p.first != 1)
				es.append(entity_json(p.second));
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
		// A test's runtime is never saved: the row keeps the one before it
		if(!m_store || !m_runtime_dirty || m_test.on)
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
		// The palette: every type of the app's that loads
		for(const auto &n : interface::fs::list_directory(host.types_path)){
			const size_t dot = n.name.rfind(".lua");
			if(n.is_directory || dot == ss_::npos || dot + 4 != n.name.size())
				continue;
			ss_ twhy;
			if(load_type(n.name.substr(0, dot), twhy))
				m_palette.insert(n.name.substr(0, dot));
			else
				log_w(MODULE, "Not in the palette: %s", cs(twhy));
		}

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
				// And emptied where an entity owned and owns no more
				for(const auto &k : m_owned_sections[s.second])
					by[k];
				m_owned_sections[s.second].clear();
				for(auto &b : by){
					w->set_section_owned(pv::Vector3DInt16(
							std::get<0>(b.first), std::get<1>(b.first),
							std::get<2>(b.first)), "kit", b.second);
					if(!b.second.empty())
						m_owned_sections[s.second].insert(b.first);
				}
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

	static bool loaded(voxelworld::Instance *world, const pv::Vector3DInt32 &p)
	{
		const pv::Vector3DInt16 ss = world->get_section_size_voxels();
		auto div = [](int32_t a, int b){
			return (int16_t)std::floor((double)a / b);
		};
		return world->is_section_loaded(pv::Vector3DInt16(div(p.getX(),
				ss.getX()), div(p.getY(), ss.getY()), div(p.getZ(), ss.getZ())));
	}

	// A voxel an instance sets: false if its section is not loaded yet
	bool set_voxel(const Write &w)
	{
		bool done = true;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *world = ivw->get_instance(w.scene);
			if(!world)
				return;
			if(!loaded(world, w.p)){
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
		if(m_test.on && m_test.peer == old.info.id)
			stop_test("its tester left");
		m_peers.erase(old.info.id);
		for(auto &p : m_peers)
			if(p.second.editing)
				send_state(p.first);
	}

	void set_peer(size_t peer, const ss_ &name, const ss_ &scene,
			double x, double y, double z)
	{
		Peer &p = m_peers[peer];
		if(p.name != name){
			p.editing = false;
			// The admins' list of who is here
			for(auto &o : m_peers)
				if(o.second.editing && o.first != peer)
					send_state(o.first);
		}
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

	// ---- The editor (api.h: edit mode, the packet kit:edit)

	void set_editor(const ss_ &player, bool can)
	{
		m_rights[player] = can;
		log_i(MODULE, "%s %s edit rights (the app's)", cs(player),
				can ? "has" : "has no");
		recheck_rights();
	}

	// The accounts' name of a peer and whether it is the server's admin
	// (the launcher's own user is): "" and false without builtin/accounts
	ss_ account_of(size_t peer, bool *admin = nullptr)
	{
		ss_ name;
		bool a = false;
		if(m_server->has_module("accounts"))
			accounts::access(m_server, [&](accounts::Interface *i){
				name = i->name_of(peer);
				a = i->is_local(peer) || (!name.empty() && i->is_admin(name));
			});
		if(admin)
			*admin = a;
		return name;
	}

	bool is_builder(const ss_ &account)
	{
		bool b = false;
		if(!account.empty() && m_server->has_module("accounts"))
			accounts::access(m_server, [&](accounts::Interface *i){
				b = i->has_priv(account, "builder");
			});
		return b;
	}

	// Edit rights: the app's word for the name it gave the player, else
	// builtin/accounts': the admin, and the accounts the admin made
	// builders. By the peer's account, not the app's name for it: a name
	// the app makes up may be someone's account
	bool can_edit(size_t peer)
	{
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end())
			return false;
		auto o = m_rights.find(pi->second.name);
		if(o != m_rights.end())
			return o->second;
		bool admin = false;
		const ss_ name = account_of(peer, &admin);
		return admin || is_builder(name);
	}

	// An editor who lost the rights leaves edit mode; the admins' lists
	// of who is a builder are sent again
	void recheck_rights()
	{
		if(m_test.on && !can_edit(m_test.peer))
			stop_test("its tester has no edit rights now");
		for(auto &p : m_peers){
			if(!p.second.editing)
				continue;
			if(!can_edit(p.first)){
				p.second.editing = false;
				log_i(MODULE, "%s left edit mode: no edit rights now",
						cs(p.second.name));
			}
			send_state(p.first);
		}
	}

	// The player is told, so a new builder's client says it may edit now
	void on_privs(const accounts::Login &login)
	{
		recheck_rights();
		auto pi = m_peers.find(login.peer);
		if(pi != m_peers.end() && !pi->second.editing)
			send_state(login.peer);
	}

	// ---- Play from edit mode: a test

	static ss_ digest(const json::Value &v)
	{
		return interface::sha256::hex(interface::sha256::calculate(
				v.stringify())).substr(0, 16);
	}

	// The voxels the entities own, as the world has them now
	// simplified: those in loaded sections; one not loaded at a test's
	// start is not put back at its end
	sv_<Write> owned_voxels()
	{
		sv_<Write> out;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			for(auto &pe : m_entities){
				const Entity &e = pe.second;
				bool owns = false;
				for(const Instance &in : e.comps)
					owns = owns || m_types[in.type].owns_voxel;
				Write w;
				w.scene = owns && e.has_pos ? scene_of(e) : nullptr;
				voxelworld::Instance *world = w.scene ?
						ivw->get_instance(w.scene) : nullptr;
				w.p = voxel_p(e);
				if(!world || !loaded(world, w.p))
					continue;
				interface::VoxelRegistry *reg = world->get_voxel_reg();
				const interface::VoxelDefinition *def = reg->get(
						reg->get_format().id.get(world->get_voxel(w.p).data));
				if(!def)
					continue;
				w.voxel = def->name.block_name;
				w.by = "app";
				out.push_back(w);
			}
		});
		return out;
	}

	void send_editors(size_t also)
	{
		for(auto &p : m_peers)
			if(p.second.editing || p.first == also)
				send_state(p.first);
	}

	// The editor's test: the runtime starts again from the authored row
	// (each instance's state its type's defaults, on_start run, none
	// disabled), live for everyone on the server -- the one runtime Kit
	// has, which the other players see and use too -- and edits wait.
	// Its end puts back the runtime and the owned voxels as they were.
	// simplified: only Kit's own runtime and voxels come back; what the
	// app or a player changed in the world meanwhile stays. A copy of the
	// world on a server of its own is the upgrade ([KIT] stage 3, later)
	void start_test(size_t peer)
	{
		Peer &p = m_peers[peer];
		save_runtime();
		m_test = Test();
		m_test.runtime = runtime_json();
		m_test.on = true;
		m_test.peer = peer;
		m_test.name = p.name;
		m_test.queue.swap(m_queue);
		m_test.pending.swap(m_pending_voxels);
		m_test.voxels = owned_voxels();
		for(auto &pe : m_entities){
			Entity &e = pe.second;
			for(size_t i = 0; i < e.comps.size(); i++){
				Instance &in = e.comps[i];
				const Type &t = m_types[in.type];
				in.state = json::object();
				const json::Value &sd = t.decl.get("state");
				if(sd.is_object())
					for(json::Iterator it(sd); it; ++it)
						in.state.set(it.key(), (*it).get("default"));
				in.disabled.clear();
				for(const ss_ &k : t.shared)
					replicate_state(e, i, k);
				Run r;
				r.entity = e.id;
				r.comp = i;
				r.handler = "on_start";
				queue_run(r);
			}
		}
		p.editing = false;
		log_i(MODULE, "A test by %s starts: authored %s, runtime %s",
				cs(p.name), cs(digest(authored_json())),
				cs(digest(m_test.runtime)));
		send_editors(peer);
	}

	void stop_test(const ss_ &why)
	{
		if(!m_test.on)
			return;
		Test t;
		std::swap(t, m_test);
		m_queue = std::move(t.queue);
		m_pending_voxels = std::move(t.pending);
		for(auto &pe : m_entities){
			Entity &e = pe.second;
			const json::Value &saved = t.runtime.get(itos(e.id));
			for(size_t i = 0; i < e.comps.size(); i++){
				Instance &in = e.comps[i];
				const json::Value &s = saved.at((unsigned)i);
				in.state = s.get("state").is_object() ? s.get("state") :
						json::object();
				in.disabled = jstr(s, "disabled");
				for(const ss_ &k : m_types[in.type].shared)
					replicate_state(e, i, k);
			}
		}
		for(const Write &w : t.voxels)
			if(!set_voxel(w))
				m_pending_voxels.push_back(w);
		m_runtime_dirty = true;
		save_runtime();
		auto pi = m_peers.find(t.peer);
		if(pi != m_peers.end() && can_edit(t.peer))
			pi->second.editing = true;
		log_i(MODULE, "The test by %s ended (%s): authored %s, runtime %s",
				cs(t.name), cs(why), cs(digest(authored_json())),
				cs(digest(runtime_json())));
		send_editors(t.peer);
	}

	// {"op": "builder", "name": n, "on": bool}: the admin grants or takes
	// an account's edit rights, kept in builtin/accounts
	void grant(size_t peer, const json::Value &j,
			const std::function<void(const ss_&)> &refuse)
	{
		bool admin = false;
		const ss_ by = account_of(peer, &admin);
		if(!admin)
			return refuse("only the server's admin makes builders");
		const ss_ name = jstr(j, "name").substr(0, 64);
		const bool on = j.get("on").is_true();
		// The launcher's own user may have no account: Kit checked it
		ss_ why;
		accounts::access(m_server, [&](accounts::Interface *i){
			why = i->set_priv(name, "builder", on, by);
		});
		if(!why.empty())
			return refuse(why);
		log_i(MODULE, "%s %s builder %s", by.empty() ? "The local user" :
				cs(by), on ? "made" : "took", cs(name));
	}

	// What an editor's client shows: the palette and the authored tree, or
	// that it is not editing
	void send_state(size_t peer)
	{
		auto pi = m_peers.find(peer);
		json::Value j = json::object();
		const bool editing = pi != m_peers.end() && pi->second.editing;
		j.set("editing", editing);
		j.set("can_edit", can_edit(peer));
		if(m_test.on){
			j.set("testing", m_test.name);
			j.set("playing", m_test.peer == peer);
		}
		if(editing){
			json::Value pal = json::object();
			for(const ss_ &t : m_palette){
				const json::Value &d = m_types[t].decl;
				json::Value o = json::object();
				for(const char *k : {"params", "inputs", "outputs", "gizmo",
						"usable"})
					if(!d.get(k).is_undefined())
						o.set(k, d.get(k));
				pal.set(t, o);
			}
			// The composition's types that are not in the palette, too:
			// the inspector needs every instance's parameters and signals
			json::Value types = pal;
			for(auto &t : m_types)
				if(!m_palette.count(t.first)){
					json::Value o = json::object();
					for(const char *k : {"params", "inputs", "outputs", "gizmo"})
						if(!t.second.decl.get(k).is_undefined())
							o.set(k, t.second.decl.get(k));
					types.set(t.first, o);
				}
			json::Value names = json::array();
			for(const ss_ &t : m_palette)
				names.append(t);
			j.set("palette", names);
			j.set("types", types);
			j.set("authored", authored_json());
			j.set("undo", (int64_t)m_undo[pi->second.name].size());
			// The admin's: who is here with an account, to make builders
			bool admin = false;
			account_of(peer, &admin);
			j.set("admin", admin);
			if(admin){
				json::Value people = json::array();
				for(auto &o : m_peers){
					bool o_admin = false;
					const ss_ n = account_of(o.first, &o_admin);
					if(o.first == peer || n.empty())
						continue;
					json::Value r = json::object();
					r.set("name", n);
					r.set("admin", o_admin);
					r.set("builder", is_builder(n));
					people.append(r);
				}
				j.set("people", people);
			}
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:edit_state", j.stringify());
		});
	}

	void on_edit(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		const json::Value j = packet.data.size() <= MAX_EDIT_PACKET ?
				json::load_string(packet.data.c_str()) : json::null();
		const ss_ op = j.is_object() ? jstr(j, "op").substr(0, 16) : "";
		auto refuse = [&](const ss_ &why){
			log_i(MODULE, "An edit (%s) by peer %zu refused: %s",
					op.empty() ? "?" : cs(op), peer, cs(why));
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(peer, "kit:edit_refused", (op.empty() ? "?" :
						op)+": "+why);
			});
		};
		if(!m_hosted)
			return refuse("Kit is not hosted");
		if(!j.is_object())
			return refuse("not a JSON object of at most "+
					itos(MAX_EDIT_PACKET)+" bytes");
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end())
			return refuse("the app has not placed the player");
		Peer &p = pi->second;
		// Rights each packet: a revoked editor's next edit is refused
		if(!can_edit(peer)){
			if(p.editing){
				p.editing = false;
				send_state(peer);
			}
			return refuse("no edit rights here");
		}
		if(op == "builder")
			return grant(peer, j, refuse);
		if(op == "mode"){
			p.editing = j.get("on").is_true();
			log_i(MODULE, "%s %s edit mode", cs(p.name),
					p.editing ? "is in" : "left");
			send_state(peer);
			return;
		}
		if(op == "stop"){
			if(!m_test.on || m_test.peer != peer)
				return refuse("no test of yours runs");
			return stop_test("its tester stopped it");
		}
		if(!p.editing)
			return refuse("not in edit mode");
		if(m_test.on)
			return refuse("a test of "+m_test.name+"'s runs; edits wait for "
					"its end");
		if(op == "play")
			return start_test(peer);
		sv_<std::pair<uint64_t, json::Value>> change;
		ss_ why, what;
		if(op == "undo"){
			std::deque<Change> &u = m_undo[p.name];
			if(u.empty())
				return refuse("nothing of "+p.name+"'s to undo");
			const Change c = u.back();
			u.pop_back();
			commit(c.before, nullptr);
			log_i(MODULE, "An undo by %s: %zu entities put back (%zu more "
					"to undo)", cs(p.name), c.before.size(), u.size());
			return;
		}
		if(!build_change(op, j, p, change, what, why))
			return refuse(why);
		commit(change, &m_undo[p.name]);
		log_i(MODULE, "An edit by %s: %s", cs(p.name), cs(what));
	}

	// An id in a client's packet: a whole number of an entity that is there
	Entity* entity_arg(const json::Value &j, const char *key, ss_ &why)
	{
		const json::Value &v = j.get(key);
		if(!v.is_number() || v.as_number() != std::floor(v.as_number()) ||
				v.as_number() < 2 || v.as_number() > 9e15){
			why = ss_(key)+": an entity's id";
			return nullptr;
		}
		auto it = m_entities.find((uint64_t)v.as_number());
		if(it == m_entities.end()){
			why = ss_(key)+": no entity "+v.stringify();
			return nullptr;
		}
		return &it->second;
	}

	// An instance of an entity in a client's packet: "id" and "comp"
	Instance* instance_arg(const json::Value &j, Entity *&e, ss_ &why)
	{
		e = entity_arg(j, "id", why);
		if(!e)
			return nullptr;
		const json::Value &v = j.get("comp");
		if(!v.is_number() || v.as_number() != std::floor(v.as_number()) ||
				v.as_number() < 0 || v.as_number() >= e->comps.size()){
			why = "comp: entity "+itos(e->id)+" has "+itos(e->comps.size())+
					" components";
			return nullptr;
		}
		return &e->comps[(size_t)v.as_number()];
	}

	// What an editor's op changes: each entity after it (null: gone).
	// Everything in it is checked here; the client is trusted with nothing
	bool build_change(const ss_ &op, const json::Value &j, const Peer &p,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what, ss_ &why)
	{
		if(op == "place"){
			const ss_ type = jstr(j, "type");
			if(!m_palette.count(type)){
				why = "no type \""+type.substr(0, 64)+"\" in the palette";
				return false;
			}
			if(!pos_ok(j.get("pos"))){
				why = "pos: three numbers within "+itos((int)MAX_COORD);
				return false;
			}
			if(m_entities.size() >= MAX_ENTITIES){
				why = "the composition has "+itos(MAX_ENTITIES)+" entities";
				return false;
			}
			// In the scene the app placed the editor in
			uint64_t scene = 0;
			for(auto &e : m_entities)
				if(e.second.kind == "scene" && e.second.name == p.scene)
					scene = e.first;
			if(!scene){
				why = "the editor is in no scene of the composition's";
				return false;
			}
			const uint64_t id = m_next_id++;
			json::Value e = json::object();
			e.set("id", (int64_t)id);
			e.set("parent", (int64_t)scene);
			e.set("name", type+" "+itos(id));
			json::Value pos = json::array();
			for(unsigned k = 0; k < 3; k++)
				pos.append(std::floor(j.get("pos").at(k).as_number()));
			e.set("pos", pos);
			json::Value comp = json::object();
			comp.set("type", type);
			json::Value comps = json::array();
			comps.append(comp);
			e.set("components", comps);
			change.push_back(std::make_pair(id, e));
			what = "placed "+type+" "+itos(id)+" at "+pos.stringify();
			return true;
		}
		if(op == "move"){
			Entity *e = entity_arg(j, "id", why);
			if(!e)
				return false;
			if(!e->has_pos || !e->kind.empty()){
				why = "entity "+itos(e->id)+" has no position to move";
				return false;
			}
			if(!pos_ok(j.get("pos"))){
				why = "pos: three numbers within "+itos((int)MAX_COORD);
				return false;
			}
			json::Value after = entity_json(*e);
			json::Value pos = json::array();
			for(unsigned k = 0; k < 3; k++)
				pos.append(std::floor(j.get("pos").at(k).as_number()));
			after.set("pos", pos);
			change.push_back(std::make_pair(e->id, after));
			what = "moved "+itos(e->id)+" to "+pos.stringify();
			return true;
		}
		if(op == "delete"){
			Entity *e = entity_arg(j, "id", why);
			if(!e)
				return false;
			if(!e->kind.empty()){
				why = "entity "+itos(e->id)+" is a "+e->kind;
				return false;
			}
			for(auto &o : m_entities)
				if(o.second.parent == e->id){
					why = "entity "+itos(e->id)+" has entities under it";
					return false;
				}
			change.push_back(std::make_pair(e->id, json::null()));
			// And the links to it, from the others
			for(auto &o : m_entities){
				if(o.first == e->id)
					continue;
				bool links = false;
				for(const Instance &in : o.second.comps)
					for(const Link &l : in.links)
						links = links || l.to == e->id;
				if(!links)
					continue;
				Entity copy = o.second;
				for(Instance &in : copy.comps)
					in.links.erase(std::remove_if(in.links.begin(),
							in.links.end(), [&](const Link &l){
						return l.to == e->id;
					}), in.links.end());
				change.push_back(std::make_pair(o.first, entity_json(copy)));
			}
			what = "deleted "+itos(e->id)+(change.size() > 1 ? " and "+
					itos(change.size() - 1)+" links' ends" : "");
			return true;
		}
		if(op == "set"){
			Entity *e = nullptr;
			Instance *in = instance_arg(j, e, why);
			if(!in)
				return false;
			const ss_ param = jstr(j, "param");
			const json::Value &decl = m_types[in->type].decl.get("params").
					get(param);
			if(param.empty() || !decl.is_object()){
				why = in->type+" has no parameter \""+param.substr(0, 64)+"\"";
				return false;
			}
			const ss_ bad = check_param(decl, j.get("value"));
			if(!bad.empty()){
				why = in->type+"'s "+param+" is "+bad;
				return false;
			}
			const size_t ci = in - &e->comps[0];
			Entity copy = *e;
			copy.comps[ci].params.set(param, j.get("value"));
			change.push_back(std::make_pair(e->id, entity_json(copy)));
			what = "set "+itos(e->id)+"'s "+in->type+" "+param+" to "+
					j.get("value").stringify();
			return true;
		}
		if(op == "link" || op == "unlink"){
			Entity *e = nullptr;
			Instance *in = instance_arg(j, e, why);
			if(!in)
				return false;
			Link l;
			l.output = jstr(j, "output");
			l.input = jstr(j, "input");
			if(!m_types[in->type].outputs.count(l.output)){
				why = in->type+" has no output \""+l.output.substr(0, 64)+"\"";
				return false;
			}
			Entity *to = entity_arg(j, "to", why);
			if(!to)
				return false;
			l.to = to->id;
			bool has_input = false;
			for(const Instance &ti : to->comps)
				has_input = has_input || m_types[ti.type].inputs.count(l.input);
			if(!has_input){
				why = "entity "+itos(to->id)+" has no input \""+
						l.input.substr(0, 64)+"\"";
				return false;
			}
			auto same = [&](const Link &o){
				return o.output == l.output && o.to == l.to && o.input == l.input;
			};
			const bool there = std::any_of(in->links.begin(), in->links.end(),
					same);
			const size_t ci = in - &e->comps[0];
			Entity copy = *e;
			sv_<Link> &links = copy.comps[ci].links;
			if(op == "link"){
				if(there){
					why = "that link is there";
					return false;
				}
				if(links.size() >= MAX_LINKS){
					why = "an instance has "+itos(MAX_LINKS)+" links at most";
					return false;
				}
				links.push_back(l);
			} else {
				if(!there){
					why = "no such link";
					return false;
				}
				links.erase(std::remove_if(links.begin(), links.end(), same),
						links.end());
			}
			change.push_back(std::make_pair(e->id, entity_json(copy)));
			what = op+"ed "+itos(e->id)+"."+l.output+" -> "+itos(l.to)+"."+
					l.input;
			return true;
		}
		why = "no op \""+op+"\"";
		return false;
	}

	// The entities as the change has them, live: their nodes, runtime state
	// and owned voxels follow, the authored row is saved, and each editor
	// is sent the tree. undo: the editor's, which gets what puts it back
	void commit(const sv_<std::pair<uint64_t, json::Value>> &change,
			std::deque<Change> *undo)
	{
		Change back;
		for(const auto &c : change){
			if(undo){
				auto it = m_entities.find(c.first);
				back.before.push_back(std::make_pair(c.first,
						it == m_entities.end() ? json::null() :
						entity_json(it->second)));
			}
			apply(c.first, c.second);
		}
		if(undo){
			undo->push_back(back);
			while(undo->size() > UNDO_MAX)
				undo->pop_front();
		}
		m_runtime_dirty = true;
		own_voxels();
		m_store->set("authored", authored_json().stringify());
		for(auto &p : m_peers)
			if(p.second.editing)
				send_state(p.first);
	}

	void remove_node(const Entity &e)
	{
		if(!e.node)
			return;
		main_context::access(m_server, scene_of(e), [&](magic::Scene *scene){
			magic::Node *n = scene->GetNode(e.node);
			if(n)
				n->Remove();
		});
	}

	void apply(uint64_t id, const json::Value &after)
	{
		auto it = m_entities.find(id);
		if(after.is_null()){
			if(it != m_entities.end()){
				remove_node(it->second);
				m_entities.erase(it);
			}
			return;
		}
		Entity n;
		ss_ why;
		if(!entity_from_json(after, n, why) || n.id != id ||
				!m_entities.count(n.parent) || (n.has_pos && !scene_of(n))){
			log_w(MODULE, "An edit of entity %s not made: %s", cs(itos(id)),
					why.empty() ? "no parent or scene" : cs(why));
			return;
		}
		// Links to what is no longer there (an undo past a delete of
		// someone else's) are left out
		for(Instance &in : n.comps)
			in.links.erase(std::remove_if(in.links.begin(), in.links.end(),
					[&](const Link &l){ return !m_entities.count(l.to); }),
					in.links.end());
		const bool had = it != m_entities.end();
		for(size_t i = 0; i < n.comps.size(); i++){
			Instance &in = n.comps[i];
			if(had && i < it->second.comps.size() &&
					it->second.comps[i].type == in.type){
				// The same instance: its runtime state goes on
				in.state = it->second.comps[i].state;
				in.disabled = it->second.comps[i].disabled;
				continue;
			}
			// simplified: a new instance (an undone delete's too) starts
			// with its type's defaults; the runtime state of a deleted one
			// is not kept for an undo
			const json::Value &sd = m_types[in.type].decl.get("state");
			if(sd.is_object())
				for(json::Iterator si(sd); si; ++si)
					in.state.set(si.key(), (*si).get("default"));
			Run r;
			r.entity = id;
			r.comp = i;
			r.handler = "on_start";
			queue_run(r);
		}
		if(had){
			n.node = it->second.node;
			if(n.node && (!n.has_pos || scene_of(n) != scene_of(it->second))){
				remove_node(it->second);
				n.node = 0;
			}
		}
		m_entities[id] = n;
		Entity &e = m_entities[id];
		if(e.has_pos && !e.node){
			make_node(e);
		} else if(e.node){
			main_context::access(m_server, scene_of(e), [&](magic::Scene *scene){
				magic::Node *nd = scene->GetNode(e.node);
				if(nd)
					nd->SetPosition(magic::Vector3(e.pos[0], e.pos[1], e.pos[2]));
			});
		}
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_kit(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
