// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [VOXEL_OBJECTS] The server half: the models, their save, the chunks sent,
// and the objects' nodes with the models' collision boxes. api.h says what
// the data is.
#include "voxel_objects/api.h"
#include "voxelworld/api.h"
#include "main_context/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "core/log.h"
#include "interface/compress.h"
#include "interface/mesh.h"
#include "interface/module.h"
#include "interface/os.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel_volume.h"
#include <Context.h>
#include <Scene.h>
#include <Node.h>
#include <RigidBody.h>
#include <PhysicsWorld.h>
#include <BulletDynamics/Dynamics/btDiscreteDynamicsWorld.h>
#include <BulletDynamics/Dynamics/btRigidBody.h>
#include <Ray.h>
#include <CollisionShape.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <map>
#include <set>
#include <sstream>
#define MODULE "voxel_objects"

using interface::Event;
using interface::VoxelSample;
using interface::VoxelVolume;
using interface::VoxelRegistry;
using namespace Urho3D;
namespace pv = PolyVox;

namespace voxel_objects {

static const char DATA_FORMAT = 1;
static const char *STORE = "voxel_objects";
static const char *MODEL_VAR = "voxel_model";

static bool valid_name(const ss_ &name)
{
	if(name.empty() || name.size() > 64)
		return false;
	for(char c : name)
		if(!(isalnum((unsigned char)c) || c == '_' || c == '-' || c == '.'))
			return false;
	return true;
}

struct World;

struct ModelImpl: public Model
{
	World *m_world;
	ss_ m_name;
	int m_sx, m_sy, m_sz;
	int m_cx, m_cy, m_cz; // chunks each way
	sv_<VoxelTypeId> m_voxels;
	// Each voxel's param << 8 | tint; empty until a voxel has either
	sv_<uint16_t> m_state;
	bool m_loaded = false;
	int m_rev = 0;
	// Chunk index -> written since the last commit (saved, sent, boxes
	// made again); and only sent (a neighbour's padding changed)
	std::set<int> m_dirty;
	std::set<int> m_resend;
	// Chunk index -> its padded volume as sent, and its boxes in the
	// model's frame; a chunk with nothing in it has neither
	std::map<int, ss_> m_wire;
	std::map<int, sv_<interface::mesh::TemporaryBox>> m_boxes;
	bool m_announced = false;

	ModelImpl(World *world, const ss_ &name, int sx, int sy, int sz):
		m_world(world), m_name(name), m_sx(sx), m_sy(sy), m_sz(sz)
	{
		m_cx = (sx + CHUNK - 1) / CHUNK;
		m_cy = (sy + CHUNK - 1) / CHUNK;
		m_cz = (sz + CHUNK - 1) / CHUNK;
		m_voxels.assign((size_t)sx * sy * sz, 0);
	}

	const ss_& name(){ return m_name; }
	int size_x(){ return m_sx; }
	int size_y(){ return m_sy; }
	int size_z(){ return m_sz; }
	bool loaded(){ return m_loaded; }
	int rev(){ return m_rev; }

	size_t index(int x, int y, int z)
	{
		if(x < 0 || y < 0 || z < 0 || x >= m_sx || y >= m_sy || z >= m_sz)
			throw Exception("voxel_objects: ("+itos(x)+", "+itos(y)+", "+
					itos(z)+") is outside model \""+m_name+"\" ("+itos(m_sx)+
					"x"+itos(m_sy)+"x"+itos(m_sz)+")");
		return (size_t)x + (size_t)m_sx * ((size_t)y + (size_t)m_sy * z);
	}

	int chunk_index(int cx, int cy, int cz)
	{
		return cx + m_cx * (cy + m_cy * cz);
	}

	VoxelTypeId get_voxel(int x, int y, int z)
	{
		return m_voxels[index(x, y, z)];
	}

	void set_voxel(int x, int y, int z, VoxelTypeId id)
	{
		set_voxel_state(x, y, z, id, 0, 0);
	}

	void set_voxel_state(int x, int y, int z, VoxelTypeId id, uint8_t param,
			uint8_t tint);

	uint32_t content_hash()
	{
		uint32_t h = 2166136261u;
		for(VoxelTypeId v : m_voxels)
			for(int i = 0; i < 4; i++)
				h = (h ^ ((v >> (i * 8)) & 0xff)) * 16777619u;
		return h;
	}

	// A chunk's origin and size in voxels
	void chunk_box(int ci, int &ox, int &oy, int &oz, int &w, int &h, int &d)
	{
		const int cx = ci % m_cx, cy = (ci / m_cx) % m_cy,
				cz = ci / (m_cx * m_cy);
		ox = cx * CHUNK, oy = cy * CHUNK, oz = cz * CHUNK;
		w = std::min(CHUNK, m_sx - ox);
		h = std::min(CHUNK, m_sy - oy);
		d = std::min(CHUNK, m_sz - oz);
	}

	bool chunk_empty(int ci)
	{
		int ox, oy, oz, w, h, d;
		chunk_box(ci, ox, oy, oz, w, h, d);
		for(int z = 0; z < d; z++)
		for(int y = 0; y < h; y++){
			const VoxelTypeId *row = &m_voxels[index(ox, oy + y, oz + z)];
			for(int x = 0; x < w; x++)
				if(row[x])
					return false;
		}
		return true;
	}

	// The chunk and a voxel of its neighbours each way, light_sky full:
	// what the client meshes and the boxes are made of
	up_<VoxelVolume> chunk_volume(int ci, VoxelRegistry *reg)
	{
		int ox, oy, oz, w, h, d;
		chunk_box(ci, ox, oy, oz, w, h, d);
		up_<VoxelVolume> vol(new VoxelVolume(pv::Region(
				pv::Vector3DInt32(-1, -1, -1), pv::Vector3DInt32(w, h, d))));
		const interface::VoxelFormat &fmt = reg->get_format();
		const uint32_t sky = fmt.light_sky.mask();
		for(int z = -1; z <= d; z++)
		for(int y = -1; y <= h; y++)
		for(int x = -1; x <= w; x++){
			const int mx = ox + x, my = oy + y, mz = oz + z;
			VoxelSample v;
			if(mx >= 0 && my >= 0 && mz >= 0 && mx < m_sx && my < m_sy &&
					mz < m_sz){
				const size_t i = (size_t)mx + (size_t)m_sx *
						((size_t)my + (size_t)m_sy * mz);
				fmt.id.set(v, m_voxels[i]);
				if(!m_state.empty()){
					if(fmt.param.bound())
						fmt.param.set(v, m_state[i] >> 8);
					if(fmt.tint.bound())
						fmt.tint.set(v, m_state[i] & 0xff);
				}
			}
			// Lit as if out in the open: an object is lit by the scene's
			// lights, and the mesher's corners still darken what is
			// enclosed (as volume_from_8bit's models)
			fmt.light_sky.set(v, sky);
			vol->set_sample_at(x, y, z, v);
		}
		return vol;
	}

	ss_ chunk_header(int ci)
	{
		const int cx = ci % m_cx, cy = (ci / m_cx) % m_cy,
				cz = ci / (m_cx * m_cy);
		return m_name+" "+itos(cx)+" "+itos(cy)+" "+itos(cz)+" "+
				itos(m_rev)+"\n";
	}

	// The wire volume and the boxes of a chunk made again
	void rebuild_chunk(int ci, VoxelRegistry *reg, bool boxes)
	{
		if(chunk_empty(ci)){
			// An emptied chunk is still sent, so a client drops its mesh
			m_wire[ci] = "";
			m_boxes.erase(ci);
			return;
		}
		up_<VoxelVolume> vol = chunk_volume(ci, reg);
		m_wire[ci] = interface::serialize_volume_compressed(*vol);
		if(!boxes)
			return;
		int ox, oy, oz, w, h, d;
		chunk_box(ci, ox, oy, oz, w, h, d);
		sv_<interface::mesh::TemporaryBox> b;
		interface::mesh::generate_voxel_physics_boxes(b, *vol, reg);
		// The generator's positions are about the volume's middle (an
		// integer half of its size); the model's frame is its corner
		const Vector3 shift(ox + w / 2, oy + h / 2, oz + d / 2);
		for(auto &box : b)
			box.position += shift;
		m_boxes[ci] = b;
	}

	// The save's chunk (api.h)
	ss_ chunk_save_data(int ci, VoxelRegistry *reg)
	{
		int ox, oy, oz, w, h, d;
		chunk_box(ci, ox, oy, oz, w, h, d);
		std::map<VoxelTypeId, uint16_t> palette;
		sv_<VoxelTypeId> order;
		ss_ body;
		body.reserve((size_t)w * h * d * 2);
		for(int z = 0; z < d; z++)
		for(int y = 0; y < h; y++)
		for(int x = 0; x < w; x++){
			const VoxelTypeId id = m_voxels[index(ox + x, oy + y, oz + z)];
			uint16_t p = 0;
			if(id){
				auto it = palette.find(id);
				if(it == palette.end()){
					order.push_back(id);
					p = palette[id] = (uint16_t)order.size();
				} else {
					p = it->second;
				}
			}
			body += (char)(p >> 8);
			body += (char)(p & 0xff);
		}
		ss_ raw;
		raw += (char)(order.size() >> 8);
		raw += (char)(order.size() & 0xff);
		for(VoxelTypeId id : order){
			const interface::VoxelDefinition *def = reg->get(id);
			interface::VoxelName n;
			if(def)
				n = def->name;
			const ss_ bn = n.block_name.substr(0, 255);
			raw += (char)bn.size();
			raw += bn;
			raw += (char)n.segment_x;
			raw += (char)n.segment_y;
			raw += (char)n.segment_z;
			raw += (char)n.rotation_primary;
			raw += (char)n.rotation_secondary;
		}
		raw += body;
		std::ostringstream os(std::ios::binary);
		os.put(DATA_FORMAT);
		interface::compress_zstd(raw, os);
		return os.str();
	}

	// Returns how many voxels were of a name this run does not have, or -1
	// when the data does not read
	int read_chunk(int ci, const ss_ &data, VoxelRegistry *reg)
	{
		if(data.empty() || data[0] != DATA_FORMAT)
			return -1;
		ss_ raw;
		try {
			std::ostringstream os(std::ios::binary);
			interface::decompress_zstd(data.substr(1), os);
			raw = os.str();
		} catch(std::exception &e){
			return -1;
		}
		int ox, oy, oz, w, h, d;
		chunk_box(ci, ox, oy, oz, w, h, d);
		size_t p = 0;
		auto byte = [&]() -> uint8_t {
			if(p >= raw.size())
				throw Exception("short");
			return (uint8_t)raw[p++];
		};
		sv_<VoxelTypeId> ids(1, 0);
		int unknown = 0;
		try {
			const int n = byte() << 8 | byte();
			for(int i = 0; i < n; i++){
				interface::VoxelName name;
				const int len = byte();
				if(p + len > raw.size())
					return -1;
				name.block_name = raw.substr(p, len);
				p += len;
				name.segment_x = byte();
				name.segment_y = byte();
				name.segment_z = byte();
				name.rotation_primary = byte();
				name.rotation_secondary = byte();
				const interface::VoxelDefinition *def = reg->get(name);
				ids.push_back(def ? def->id : 0);
			}
			if(raw.size() - p != (size_t)w * h * d * 2)
				return -1;
			for(int z = 0; z < d; z++)
			for(int y = 0; y < h; y++)
			for(int x = 0; x < w; x++){
				const int i = byte() << 8 | byte();
				VoxelTypeId id = i < (int)ids.size() ? ids[i] : 0;
				if(i && !id)
					unknown++;
				m_voxels[index(ox + x, oy + y, oz + z)] = id;
			}
		} catch(std::exception &e){
			return -1;
		}
		return unknown;
	}

	ss_ meta()
	{
		return itos(DATA_FORMAT)+" "+itos(m_sx)+" "+itos(m_sy)+" "+
				itos(m_sz)+" "+itos(CHUNK);
	}

	ss_ model_packet()
	{
		return "1 "+m_name+" "+itos(m_sx)+" "+itos(m_sy)+" "+itos(m_sz)+
				" "+itos(CHUNK);
	}
};

struct Module;

struct World: public Instance
{
	Module *m_module;
	interface::Server *m_server;
	SceneReference m_scene;
	VoxelRegistry *m_reg = nullptr;
	std::map<ss_, up_<ModelImpl>> m_models;
	// Object node id -> its model
	std::map<uint, ModelImpl*> m_objects;
	storage::Store *m_store = nullptr;
	ss_ m_save_name;

	World(Module *module, interface::Server *server, SceneReference scene):
		m_module(module), m_server(server), m_scene(scene)
	{
		voxelworld::access(m_server, scene, [&](voxelworld::Instance *w){
			m_reg = w->get_voxel_reg();
		});
		if(!m_reg)
			throw Exception("voxel_objects: the scene has no voxelworld"
					" instance, whose registry a model's ids are of");
	}

	~World()
	{
		// [VOXEL_OBJECTS_UNLOAD_LOSS] What was written since the last tick's
		// commit is saved still: an edit just before the server stopped was
		// lost. The store outlives the world (storage is below this module,
		// and a store whose save the app closed first drops the writes:
		// [SAVE_CLOSE_ORDER]);
		// the registry is looked up again, as a deleted scene's voxelworld
		// instance may be gone already
		save_dirty_all();
		// The objects' nodes are this module's to take
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->find_scene(m_scene);
			if(!scene)
				return;
			for(auto &pair : m_objects){
				Node *n = scene->GetNode(pair.first);
				if(n)
					n->Remove();
			}
		});
	}

	void set_save(storage::Save *save, const ss_ &name)
	{
		m_store = save ? save->store(STORE) : nullptr;
		m_save_name = name;
	}

	ss_ key(ModelImpl *m, const ss_ &what)
	{
		return m_save_name+"/"+m->m_name+"/"+what;
	}

	ss_ chunk_key(ModelImpl *m, int ci)
	{
		const int cx = ci % m->m_cx, cy = (ci / m->m_cx) % m->m_cy,
				cz = ci / (m->m_cx * m->m_cy);
		return key(m, itos(cx)+","+itos(cy)+","+itos(cz));
	}

	Model* create_model(const ss_ &name, int sx, int sy, int sz)
	{
		if(!valid_name(name))
			throw Exception("voxel_objects: \""+name+"\" is not a model name"
					" (letters, digits, _ - and ., 64 at most)");
		if(m_models.count(name))
			throw Exception("voxel_objects: model \""+name+"\" exists");
		if(sx < 1 || sy < 1 || sz < 1 || sx > MAX_SIDE || sy > MAX_SIDE ||
				sz > MAX_SIDE || (int64_t)sx * sy * sz > MAX_VOXELS)
			throw Exception("voxel_objects: a model of 1 to "+
					itos(MAX_SIDE)+" a side and "+itos(MAX_VOXELS)+
					" voxels at most");
		ModelImpl *m = new ModelImpl(this, name, sx, sy, sz);
		m_models[name] = up_<ModelImpl>(m);
		load(m);
		// Every chunk with something in it made for the wire, and the
		// boxes; nothing saved (the save has it, or nothing is there)
		const int64_t t0 = interface::os::time_us();
		const int n = m->m_cx * m->m_cy * m->m_cz;
		for(int ci = 0; ci < n; ci++)
			if(m->m_loaded && !m->chunk_empty(ci))
				m->rebuild_chunk(ci, m_reg, true);
		if(m->m_loaded)
			log_i(MODULE, "voxel_objects: model \"%s\" loaded: %ix%ix%i,"
					" %zu chunks, %zu boxes, in %.0f ms, hash %08x",
					cs(name), sx, sy, sz, m->m_wire.size(), num_boxes(m),
					(interface::os::time_us() - t0) / 1000.0,
					m->content_hash());
		return m;
	}

	void load(ModelImpl *m)
	{
		if(!m_store)
			return;
		ss_ saved;
		if(!m_store->get(key(m, "meta"), saved))
			return;
		if(saved != m->meta()){
			log_w(MODULE, "voxel_objects: the save's model \"%s\" is \"%s\","
					" not \"%s\"; not read", cs(m->m_name), cs(saved),
					cs(m->meta()));
			return;
		}
		int bad = 0, unknown = 0;
		const int n = m->m_cx * m->m_cy * m->m_cz;
		for(int ci = 0; ci < n; ci++){
			ss_ data;
			if(!m_store->get(chunk_key(m, ci), data))
				continue;
			const int u = m->read_chunk(ci, data, m_reg);
			if(u < 0)
				bad++;
			else
				unknown += u;
		}
		if(bad)
			log_w(MODULE, "voxel_objects: %i chunks of \"%s\" did not read",
					bad, cs(m->m_name));
		if(unknown)
			log_w(MODULE, "voxel_objects: %i voxels of \"%s\" are of names"
					" this run does not register; read as empty", unknown,
					cs(m->m_name));
		m->m_loaded = true;
	}

	size_t num_boxes(ModelImpl *m)
	{
		size_t n = 0;
		for(auto &b : m->m_boxes)
			n += b.second.size();
		return n;
	}

	Model* get_model(const ss_ &name)
	{
		auto it = m_models.find(name);
		return it == m_models.end() ? nullptr : it->second.get();
	}

	void remove_model(const ss_ &name)
	{
		auto it = m_models.find(name);
		if(it == m_models.end())
			return;
		sv_<uint> ids;
		for(auto &pair : m_objects)
			if(pair.second == it->second.get())
				ids.push_back(pair.first);
		for(uint id : ids)
			remove_object(id);
		const bool announced = it->second->m_announced;
		m_models.erase(it);
		if(!announced)
			return;
		sv_<replicate::PeerId> peers;
		replicate::access(m_server, [&](replicate::Interface *irep){
			peers = irep->find_peers_on_scene(m_scene);
		});
		network::access(m_server, [&](network::Interface *inet){
			for(replicate::PeerId peer : peers)
				inet->send(peer, "voxel_objects:remove_model", name);
		});
	}

	void set_boxes(Node *n, ModelImpl *m)
	{
		sv_<interface::mesh::TemporaryBox> all;
		for(auto &b : m->m_boxes)
			all.insert(all.end(), b.second.begin(), b.second.end());
		interface::mesh::set_voxel_physics_boxes(n, n->GetContext(), all,
				true);
	}

	uint create_object(const ss_ &model, const Vector3 &position,
			const Quaternion &rotation)
	{
		auto it = m_models.find(model);
		if(it == m_models.end())
			throw Exception("voxel_objects: no model \""+model+"\"");
		uint id = 0;
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene);
			Node *n = scene->CreateChild("voxel_object");
			n->SetPosition(position);
			n->SetRotation(rotation);
			n->SetVar(StringHash(MODEL_VAR), Variant(String(model.c_str())));
			n->CreateComponent<RigidBody>(LOCAL);
			set_boxes(n, it->second.get());
			id = n->GetID();
		});
		m_objects[id] = it->second.get();
		return id;
	}

	void remove_object(uint node_id)
	{
		if(!m_objects.erase(node_id))
			return;
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->find_scene(m_scene);
			Node *n = scene ? scene->GetNode(node_id) : nullptr;
			if(n)
				n->Remove();
		});
	}

	size_t num_objects(){ return m_objects.size(); }

	void set_body_pose(uint node_id, const Vector3 &position,
			const Quaternion &rotation)
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->find_scene(m_scene);
			Node *n = scene ? scene->GetNode(node_id) : nullptr;
			RigidBody *rb = n ? n->GetComponent<RigidBody>() : nullptr;
			if(!rb || !rb->GetBody())
				return;
			rb->SetTransform(position, rotation);
			// (a static body's bounds are the world's to update, in a step)
			PhysicsWorld *pw = scene->GetComponent<PhysicsWorld>();
			if(pw && pw->GetWorld())
				pw->GetWorld()->updateSingleAabb(rb->GetBody());
		});
	}

	bool ray_down(const Vector3 &from, float len, float *y)
	{
		bool hit = false;
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->find_scene(m_scene);
			PhysicsWorld *pw = scene ? scene->GetComponent<PhysicsWorld>() : nullptr;
			if(!pw)
				return;
			PhysicsRaycastResult r;
			pw->RaycastSingle(r, Ray(from, Vector3(0, -1, 0)), len);
			if(r.body_){
				hit = true;
				*y = r.position_.y_;
			}
		});
		return hit;
	}

	void commit();
	void save_dirty(ModelImpl *m, const std::set<int> &dirty,
			VoxelRegistry *reg, size_t *saved = nullptr);
	void save_dirty_all();

	// The models and their chunks to a peer that joined the scene
	void send_all(replicate::PeerId peer)
	{
		const int64_t t0 = interface::os::time_us();
		size_t bytes = 0, chunks = 0;
		network::access(m_server, [&](network::Interface *inet){
			inet->send(peer, "core:run_script",
					"require(\"buildat/module/voxel_objects\")");
			for(auto &pair : m_models){
				ModelImpl *m = pair.second.get();
				inet->send(peer, "voxel_objects:model", m->model_packet());
				for(auto &w : m->m_wire){
					if(w.second.empty())
						continue;
					const ss_ p = m->chunk_header(w.first) + w.second;
					bytes += p.size();
					chunks++;
					inet->send(peer, "voxel_objects:chunk", p);
				}
			}
		});
		log_i(MODULE, "voxel_objects: %zu models sent to peer %zu: %zu chunks,"
				" %zu bytes in %.0f ms", m_models.size(), peer, chunks, bytes,
				(interface::os::time_us() - t0) / 1000.0);
	}
};

void ModelImpl::set_voxel_state(int x, int y, int z, VoxelTypeId id,
		uint8_t param, uint8_t tint)
{
	const size_t i = index(x, y, z);
	if(id > m_world->m_reg->num_voxels())
		throw Exception("voxel_objects: voxel id "+itos(id)+" is not in"
				" the registry");
	const uint16_t state = (uint16_t)(param << 8 | tint);
	if(m_voxels[i] == id && (m_state.empty() ? 0 : m_state[i]) == state)
		return;
	if(state && m_state.empty()){
		if(m_world->m_store)
			throw Exception("voxel_objects: model \""+m_name+"\" has a save,"
					" whose format has no param or tint");
		m_state.assign(m_voxels.size(), 0);
	}
	if(!m_state.empty())
		m_state[i] = state;
	m_voxels[i] = id;
	const int cx = x / CHUNK, cy = y / CHUNK, cz = z / CHUNK;
	m_dirty.insert(chunk_index(cx, cy, cz));
	// The neighbours whose padding this voxel is
	const int lx = x % CHUNK, ly = y % CHUNK, lz = z % CHUNK;
	for(int dz = -1; dz <= 1; dz++)
	for(int dy = -1; dy <= 1; dy++)
	for(int dx = -1; dx <= 1; dx++){
		if(!dx && !dy && !dz)
			continue;
		if((dx < 0 && lx != 0) || (dx > 0 && lx != CHUNK - 1) ||
				(dy < 0 && ly != 0) || (dy > 0 && ly != CHUNK - 1) ||
				(dz < 0 && lz != 0) || (dz > 0 && lz != CHUNK - 1))
			continue;
		const int nx = cx + dx, ny = cy + dy, nz = cz + dz;
		if(nx < 0 || ny < 0 || nz < 0 || nx >= m_cx || ny >= m_cy ||
				nz >= m_cz)
			continue;
		m_resend.insert(chunk_index(nx, ny, nz));
	}
}

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;
	std::map<SceneReference, up_<World>> m_worlds;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("replicate:peer_joined_scene"));
		m_server->sub_event(this, Event::t("main_context:scene_deleted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_TYPEN("replicate:peer_joined_scene", on_peer_joined_scene,
				replicate::PeerJoinedScene)
		EVENT_TYPEN("main_context:scene_deleted", on_scene_deleted,
				main_context::SceneDeleted)
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}

	void on_tick(const interface::TickEvent &event)
	{
		for(auto &pair : m_worlds)
			pair.second->commit();
	}

	// simplified: the models and objects are not kept over a hot reload;
	// the objects' nodes go with them
	void on_unload()
	{
		m_worlds.clear();
	}

	void on_peer_joined_scene(const replicate::PeerJoinedScene &event)
	{
		auto it = m_worlds.find(event.scene);
		if(it == m_worlds.end())
			return;
		it->second->commit();
		it->second->send_all(event.peer);
	}

	void on_scene_deleted(const main_context::SceneDeleted &event)
	{
		m_worlds.erase(event.scene);
	}

	Instance* create_instance(SceneReference scene)
	{
		if(m_worlds.count(scene))
			throw Exception("voxel_objects: the scene has an instance"
					" already");
		World *w = new World(this, m_server, scene);
		m_worlds[scene] = up_<World>(w);
		return w;
	}

	void delete_instance(SceneReference scene)
	{
		m_worlds.erase(scene);
	}

	Instance* get_instance(SceneReference scene)
	{
		auto it = m_worlds.find(scene);
		return it == m_worlds.end() ? nullptr : it->second.get();
	}
};

void World::save_dirty(ModelImpl *m, const std::set<int> &dirty,
		VoxelRegistry *reg, size_t *saved)
{
	if(!m_store || dirty.empty())
		return;
	m_store->batch([&](){
		m_store->set(key(m, "meta"), m->meta());
		for(int ci : dirty){
			if(m->chunk_empty(ci))
				m_store->remove(chunk_key(m, ci));
			else
				m_store->set(chunk_key(m, ci), m->chunk_save_data(ci, reg));
			if(saved)
				(*saved)++;
		}
	});
}

void World::save_dirty_all()
{
	if(!m_store)
		return;
	size_t n = 0;
	for(auto &pair : m_models)
		n += pair.second->m_dirty.size();
	if(!n)
		return;
	bool done = false;
	try {
		voxelworld::access(m_server, [&](voxelworld::Interface *iv){
			voxelworld::Instance *w = iv->get_instance(m_scene);
			if(!w)
				return;
			for(auto &pair : m_models)
				save_dirty(pair.second.get(), pair.second->m_dirty,
						w->get_voxel_reg());
			done = true;
		});
	} catch(std::exception &e){
		log_w(MODULE, "voxel_objects: saving at the end: %s", e.what());
	}
	if(done)
		log_i(MODULE, "voxel_objects: %zu chunks written since the last"
				" commit saved at the end", n);
	else
		log_w(MODULE, "voxel_objects: %zu chunks written since the last"
				" commit not saved: the scene's voxelworld is gone", n);
}

void World::commit()
{
	// A model made since the last commit is announced to the peers on the
	// scene, as a join gets it
	sv_<ModelImpl*> announce;
	sv_<ModelImpl*> changed;
	for(auto &pair : m_models){
		ModelImpl *m = pair.second.get();
		if(!m->m_announced){
			m->m_announced = true;
			announce.push_back(m);
		}
		if(!m->m_dirty.empty() || !m->m_resend.empty())
			changed.push_back(m);
	}
	if(announce.empty() && changed.empty())
		return;
	const int64_t t0 = interface::os::time_us();
	sv_<std::pair<ss_, ss_>> packets; // type, data
	// Per model: chunks saved, chunks sent, bodies given its boxes
	std::map<ModelImpl*, std::array<size_t, 3>> st;
	for(ModelImpl *m : changed){
		m->m_rev++;
		std::set<int> dirty, resend;
		dirty.swap(m->m_dirty);
		resend.swap(m->m_resend);
		for(int ci : dirty)
			resend.erase(ci);
		for(int ci : dirty)
			m->rebuild_chunk(ci, m_reg, true);
		for(int ci : resend)
			m->rebuild_chunk(ci, m_reg, false);
		save_dirty(m, dirty, m_reg, &st[m][0]);
		if(std::find(announce.begin(), announce.end(), m) != announce.end())
			continue; // All its chunks go below
		for(const std::set<int> *s : {&dirty, &resend})
			for(int ci : *s){
				packets.push_back({"voxel_objects:chunk",
						m->chunk_header(ci) + m->m_wire[ci]});
				st[m][1]++;
			}
	}
	for(ModelImpl *m : announce){
		packets.push_back({"voxel_objects:model", m->model_packet()});
		for(auto &w : m->m_wire){
			if(w.second.empty())
				continue;
			packets.push_back({"voxel_objects:chunk",
					m->chunk_header(w.first) + w.second});
			st[m][1]++;
		}
	}
	// The objects of a changed model take its boxes again
	if(!changed.empty()){
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->find_scene(m_scene);
			if(!scene)
				return;
			for(auto &pair : m_objects){
				if(std::find(changed.begin(), changed.end(), pair.second) ==
						changed.end())
					continue;
				Node *n = scene->GetNode(pair.first);
				if(n){
					set_boxes(n, pair.second);
					st[pair.second][2]++;
				}
			}
		});
	}
	sv_<replicate::PeerId> peers;
	replicate::access(m_server, [&](replicate::Interface *irep){
		peers = irep->find_peers_on_scene(m_scene);
	});
	if(!peers.empty()){
		network::access(m_server, [&](network::Interface *inet){
			for(replicate::PeerId peer : peers)
				for(auto &p : packets)
					inet->send(peer, p.first, p.second);
		});
	}
	for(ModelImpl *m : changed)
		log_i(MODULE, "voxel_objects: model \"%s\" rev %i committed: %zu"
				" chunks saved, %zu sent to %zu peers, %zu bodies, %zu"
				" boxes, hash %08x, in %.1f ms", cs(m->m_name), m->m_rev,
				st[m][0], st[m][1], peers.size(), st[m][2], num_boxes(m),
				m->content_hash(),
				(interface::os::time_us() - t0) / 1000.0);
}

extern "C" {
	BUILDAT_EXPORT void* createModule_voxel_objects(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
