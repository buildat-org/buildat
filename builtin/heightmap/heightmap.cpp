// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [HEIGHTMAP_TERRAIN] The server half: the grid, its save, the rectangles
// sent, and a Bullet heightfield for the scene's physics. api.h says what
// the data is.
//
// [HEIGHTMAP_REST] The physics has no Terrain: a drawable Terrain's patches
// were ~87 MB for 1 km^2 at a metre, none of which the server draws. The
// heightfield is a btHeightfieldTerrainShape over the map's own float array
// (Bullet reads it in place), a child of the node's RigidBody's compound
// shape, so a commit writes the changed samples and rebuilds nothing.
#include "heightmap/api.h"
#include "main_context/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "core/log.h"
#include "interface/compress.h"
#include "interface/module.h"
#include "interface/os.h"
#include "interface/server.h"
#include "interface/event.h"
#include <Context.h>
#include <Scene.h>
#include <Node.h>
#include <RigidBody.h>
#include <BulletCollision/CollisionShapes/btHeightfieldTerrainShape.h>
#include <BulletCollision/CollisionShapes/btCompoundShape.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <sstream>
#define MODULE "heightmap"

using interface::Event;
using namespace Urho3D;

namespace heightmap {

static const char DATA_FORMAT = 2;
static const char *STORE = "heightmap";
// What a client's packet of the map's shape says before its numbers
static const char *INIT_VERSION = "2";

// A rectangle of samples, inclusive
struct Rect
{
	int x0, z0, x1, z1;
	void grow(int x, int z)
	{
		x0 = std::min(x0, x); z0 = std::min(z0, z);
		x1 = std::max(x1, x); z1 = std::max(z1, z);
	}
};

struct Module;

struct Map: public Instance
{
	Module *m_module;
	interface::Server *m_server;
	SceneReference m_scene;
	Size m_size;
	int m_sx, m_sz;
	int m_planes; // RGBA weight planes in the data format
	sv_<uint16_t> m_heights;
	sv_<uint8_t> m_weights; // m_size.materials a sample
	// What Bullet reads: (sx + 1) x (sz + 1) heights in metres over base_y,
	// z rows, the last row and column copies of the ones before
	sv_<float> m_field;
	up_<btHeightfieldTerrainShape> m_shape;
	// Written since the last commit: chunk index cz * chunks_x + cx -> the
	// rectangle written in it
	std::map<int, Rect> m_written;
	// Read from the save since the last commit: for the heightfield only
	sv_<Rect> m_field_pending;
	uint m_node_id = 0;
	storage::Store *m_store = nullptr;
	ss_ m_name;
	sv_<up_<ChunkHook>> m_hooks;

	Map(Module *module, interface::Server *server, SceneReference scene,
			const Size &size):
		m_module(module), m_server(server), m_scene(scene), m_size(size)
	{
		if(size.chunks_x < 1 || size.chunks_z < 1 || size.chunk_size < 2 ||
				size.chunk_size % 64 != 0 || size.cell_size <= 0 ||
				size.chunks_x * size.chunk_size > 8192 ||
				size.chunks_z * size.chunk_size > 8192 ||
				size.materials < 1 || size.materials > MAX_MATERIALS)
			throw Exception("heightmap: a size of whole chunks, chunk_size a"
					" multiple of 64, 8192 samples a side at most, a cell"
					" over 0, 1 to "+itos(MAX_MATERIALS)+" materials");
		m_sx = size.chunks_x * size.chunk_size;
		m_sz = size.chunks_z * size.chunk_size;
		m_planes = (size.materials + 3) / 4;
		m_heights.assign((size_t)m_sx * m_sz, 0);
		m_weights.assign((size_t)m_sx * m_sz * size.materials, 0);
		for(size_t i = 0; i < m_weights.size(); i += size.materials)
			m_weights[i] = 255;
		m_field.assign((size_t)(m_sx + 1) * (m_sz + 1), 0.0f);
	}

	~Map()
	{
		// The node's RigidBody holds the shape in its compound: gone first
		if(m_node_id){
			main_context::access(m_server, [&](main_context::Interface *imc){
				Scene *scene = imc->find_scene(m_scene);
				Node *n = scene ? scene->GetNode(m_node_id) : nullptr;
				if(n)
					n->Remove();
			});
		}
	}

	const Size& get_size(){ return m_size; }
	int samples_x(){ return m_sx; }
	int samples_z(){ return m_sz; }

	size_t index(int x, int z)
	{
		if(x < 0 || z < 0 || x >= m_sx || z >= m_sz)
			throw Exception("heightmap: sample ("+itos(x)+", "+itos(z)+
					") is outside the "+itos(m_sx)+"x"+itos(m_sz)+" map");
		return (size_t)z * m_sx + x;
	}

	void will_write(int x, int z)
	{
		const int cx = x / m_size.chunk_size, cz = z / m_size.chunk_size;
		const int ci = cz * m_size.chunks_x + cx;
		auto it = m_written.find(ci);
		if(it != m_written.end()){
			it->second.grow(x, z);
			return;
		}
		if(!m_hooks.empty()){
			const ss_ old = chunk_data(cx, cz);
			for(auto &hook : m_hooks)
				hook->before_write(this, cx, cz, old);
		}
		m_written[ci] = Rect{x, z, x, z};
	}

	float get_height(int x, int z)
	{
		return m_size.base_y + m_heights[index(x, z)] * HEIGHT_STEP;
	}

	void set_height(int x, int z, float height)
	{
		const size_t i = index(x, z);
		float n = std::round((height - m_size.base_y) / HEIGHT_STEP);
		const uint16_t v = n < 0 ? 0 : n > 65535 ? 65535 : (uint16_t)n;
		if(m_heights[i] == v)
			return;
		will_write(x, z);
		m_heights[i] = v;
	}

	Weights get_weights(int x, int z)
	{
		const int n = m_size.materials;
		const size_t i = index(x, z) * n;
		Weights w{};
		for(int k = 0; k < n; k++)
			w[k] = m_weights[i + k];
		return w;
	}

	void set_weights(int x, int z, const Weights &w)
	{
		const int n = m_size.materials;
		const size_t i = index(x, z) * n;
		if(memcmp(&m_weights[i], w.data(), n) == 0)
			return;
		will_write(x, z);
		memcpy(&m_weights[i], w.data(), n);
	}

	float raw(int x, int z)
	{
		x = x < 0 ? 0 : x >= m_sx ? m_sx - 1 : x;
		z = z < 0 ? 0 : z >= m_sz ? m_sz - 1 : z;
		return m_heights[(size_t)z * m_sx + x] * HEIGHT_STEP;
	}

	float height_at(float wx, float wz)
	{
		float fx = wx / m_size.cell_size, fz = wz / m_size.cell_size;
		fx = fx < 0 ? 0 : fx > m_sx - 1 ? m_sx - 1 : fx;
		fz = fz < 0 ? 0 : fz > m_sz - 1 ? m_sz - 1 : fz;
		const int x = (int)fx, z = (int)fz;
		float xf = fx - x, zf = fz - z, h1, h2, h3;
		if(xf + zf >= 1.0f){
			h1 = raw(x + 1, z + 1);
			h2 = raw(x, z + 1);
			h3 = raw(x + 1, z);
			xf = 1.0f - xf;
			zf = 1.0f - zf;
		} else {
			h1 = raw(x, z);
			h2 = raw(x + 1, z);
			h3 = raw(x, z + 1);
		}
		return m_size.base_y + h1 * (1.0f - xf - zf) + h2 * xf + h3 * zf;
	}

	void generate(const GenerateParams &p)
	{
		const int64_t t0 = interface::os::time_us();
		const float cell = m_size.cell_size;
		sv_<float> h((size_t)m_sx * m_sz);
		for(int z = 0; z < m_sz; z++)
			for(int x = 0; x < m_sx; x++)
				h[(size_t)z * m_sx + x] = p.height_fn ?
						p.height_fn(x * cell, z * cell) :
						interface::noise::noise2(p.height, p.seed,
								x * cell, z * cell);
		const int n = m_size.materials;
		auto ramp = [](float v){ return v < 0 ? 0.0f : v > 1 ? 1.0f : v; };
		for(int z = 0; z < m_sz; z++)
		for(int x = 0; x < m_sx; x++){
			set_height(x, z, h[(size_t)z * m_sx + x]);
			// Rise over run from the neighbours, central where there are two
			const int x0 = x > 0 ? x - 1 : x, x1 = x < m_sx - 1 ? x + 1 : x;
			const int z0 = z > 0 ? z - 1 : z, z1 = z < m_sz - 1 ? z + 1 : z;
			const float dx = (h[(size_t)z * m_sx + x1] -
					h[(size_t)z * m_sx + x0]) / ((x1 - x0) * cell);
			const float dz = (h[(size_t)z1 * m_sx + x] -
					h[(size_t)z0 * m_sx + x]) / ((z1 - z0) * cell);
			const float slope = std::sqrt(dx * dx + dz * dz);
			const float rock = n > 1 ?
					ramp((slope - p.rock_slope) * 10.0f + 0.5f) : 0.0f;
			const float sand = n > 2 ? ramp(p.sand_below + 0.5f -
					h[(size_t)z * m_sx + x]) * (1.0f - rock) : 0.0f;
			const float grass = 1.0f - rock - sand;
			Weights w{};
			w[0] = (uint8_t)std::round(grass * 255);
			w[1] = (uint8_t)std::round(rock * 255);
			w[2] = (uint8_t)std::round(sand * 255);
			set_weights(x, z, w);
		}
		// Every chunk whole, also one the noise left as it was
		for(int cz = 0; cz < m_size.chunks_z; cz++)
		for(int cx = 0; cx < m_size.chunks_x; cx++){
			const Rect r = chunk_rect(cx, cz);
			will_write(r.x0, r.z0);
			m_written[cz * m_size.chunks_x + cx].grow(r.x1, r.z1);
		}
		log_i(MODULE, "heightmap: generated %ix%i seed %u in %.0f ms, hash %08x",
				m_sx, m_sz, p.seed,
				(interface::os::time_us() - t0) / 1000.0, content_hash());
	}

	Rect chunk_rect(int cx, int cz)
	{
		const int cs = m_size.chunk_size;
		return Rect{cx * cs, cz * cs, cx * cs + cs - 1, cz * cs + cs - 1};
	}

	// A rectangle's raw bytes (api.h): heights big-endian, then the planes
	ss_ rect_raw(const Rect &r)
	{
		const int w = r.x1 - r.x0 + 1, h = r.z1 - r.z0 + 1;
		const int n = m_size.materials;
		ss_ raw((size_t)w * h * (2 + 4 * m_planes), '\0');
		char *hp = &raw[0];
		for(int z = r.z0; z <= r.z1; z++){
			const uint16_t *src = &m_heights[(size_t)z * m_sx + r.x0];
			for(int x = 0; x < w; x++){
				*hp++ = (char)(src[x] >> 8);
				*hp++ = (char)(src[x] & 0xff);
			}
		}
		for(int p = 0; p < m_planes; p++){
			char *wp = &raw[(size_t)w * h * (2 + 4 * p)];
			const int k0 = p * 4, kn = std::min(4, n - k0);
			for(int z = r.z0; z <= r.z1; z++){
				const uint8_t *src = &m_weights[((size_t)z * m_sx + r.x0) * n];
				for(int x = 0; x < w; x++, wp += 4, src += n)
					memcpy(wp, src + k0, kn);
			}
		}
		return raw;
	}

	ss_ rect_data(const Rect &r)
	{
		std::ostringstream os(std::ios::binary);
		os.put(DATA_FORMAT);
		interface::compress_zstd(rect_raw(r), os);
		return os.str();
	}

	ss_ chunk_data(int cx, int cz)
	{
		return rect_data(chunk_rect(cx, cz));
	}

	bool read_chunk(int cx, int cz, const ss_ &data)
	{
		const Rect r = chunk_rect(cx, cz);
		const int cs = m_size.chunk_size, n = m_size.materials;
		if(data.empty() || data[0] != DATA_FORMAT)
			return false;
		ss_ raw((size_t)cs * cs * (2 + 4 * m_planes), '\0');
		try {
			if(interface::decompress_zstd(data.substr(1), (uint8_t*)&raw[0],
					raw.size()) != raw.size())
				return false;
		} catch(std::exception &e){
			return false;
		}
		const char *hp = raw.data();
		for(int z = r.z0; z <= r.z1; z++){
			uint16_t *dst = &m_heights[(size_t)z * m_sx + r.x0];
			for(int x = 0; x < cs; x++, hp += 2)
				dst[x] = (uint16_t)((uint8_t)hp[0] << 8 | (uint8_t)hp[1]);
		}
		for(int p = 0; p < m_planes; p++){
			const char *wp = raw.data() + (size_t)cs * cs * (2 + 4 * p);
			const int k0 = p * 4, kn = std::min(4, n - k0);
			for(int z = r.z0; z <= r.z1; z++){
				uint8_t *dst = &m_weights[((size_t)z * m_sx + r.x0) * n];
				for(int x = 0; x < cs; x++, wp += 4, dst += n)
					memcpy(dst + k0, wp, kn);
			}
		}
		return true;
	}

	ss_ meta()
	{
		return storage::pack((int32_t)DATA_FORMAT, (int32_t)m_size.chunks_x,
				(int32_t)m_size.chunks_z, (int32_t)m_size.chunk_size,
				m_size.cell_size, m_size.base_y, (int32_t)m_size.materials);
	}

	ss_ chunk_key(int cx, int cz)
	{
		return m_name+"/"+itos(cx)+","+itos(cz);
	}

	bool set_save(storage::Save *save, const ss_ &name)
	{
		m_store = save ? save->store(STORE) : nullptr;
		m_name = name;
		if(!m_store)
			return false;
		ss_ saved;
		if(!m_store->get(name+"/meta", saved))
			return false;
		if(saved != meta()){
			log_w(MODULE, "heightmap: the save's map \"%s\" is of another"
					" size or format; not read", cs(name));
			m_store = nullptr;
			return false;
		}
		const int64_t t0 = interface::os::time_us();
		int n = 0, bad = 0;
		for(int cz = 0; cz < m_size.chunks_z; cz++)
		for(int cx = 0; cx < m_size.chunks_x; cx++){
			ss_ data;
			if(!m_store->get(chunk_key(cx, cz), data))
				continue;
			if(read_chunk(cx, cz, data)){
				n++;
				// Not written: the save has it, and a hook would take the
				// load for a change
				m_field_pending.push_back(chunk_rect(cx, cz));
			} else {
				bad++;
			}
		}
		if(bad)
			log_w(MODULE, "heightmap: %i chunks of \"%s\" did not read", bad,
					cs(name));
		log_i(MODULE, "heightmap: loaded \"%s\": %i chunks in %.0f ms, hash %08x",
				cs(name), n, (interface::os::time_us() - t0) / 1000.0,
				content_hash());
		return true;
	}

	void add_chunk_hook(up_<ChunkHook> hook)
	{
		m_hooks.push_back(std::move(hook));
	}

	uint32_t content_hash()
	{
		uint32_t h = 2166136261u;
		auto add = [&](uint8_t b){ h = (h ^ b) * 16777619u; };
		for(uint16_t v : m_heights){ add(v >> 8); add(v & 0xff); }
		for(uint8_t v : m_weights) add(v);
		return h;
	}

	// The heightfield's samples of a rectangle, and the copied last row and
	// column where it reaches them
	// simplified: so the last cell each way is flat; a map that wants its
	// edge sloped is a sample larger
	void update_field(const Rect &r)
	{
		const int fw = m_sx + 1;
		for(int z = r.z0; z <= r.z1; z++){
			const uint16_t *src = &m_heights[(size_t)z * m_sx];
			float *dst = &m_field[(size_t)z * fw];
			for(int x = r.x0; x <= r.x1; x++)
				dst[x] = src[x] * HEIGHT_STEP;
			if(r.x1 == m_sx - 1)
				dst[m_sx] = dst[m_sx - 1];
		}
		if(r.z1 == m_sz - 1)
			memcpy(&m_field[(size_t)m_sz * fw + r.x0],
					&m_field[(size_t)(m_sz - 1) * fw + r.x0],
					sizeof(float) * (r.x1 - r.x0 + 1 + (r.x1 == m_sx - 1)));
	}

	// The node, its static RigidBody and the heightfield in its compound,
	// placed as an Urho3D Terrain of the same size would be, so the surface
	// is where height_at() says
	void create_body(Scene *scene)
	{
		Node *n = scene->CreateChild("heightmap", LOCAL);
		n->SetPosition(Vector3(m_sx * m_size.cell_size / 2, m_size.base_y,
				m_sz * m_size.cell_size / 2));
		m_node_id = n->GetID();
		RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
		// Bullet centres a heightfield between its least and greatest
		// height; these are the format's whole range, so a write anywhere
		// in it stays inside the shape's box without a rebuild
		const float max_h = 65535 * HEIGHT_STEP;
		m_shape.reset(new btHeightfieldTerrainShape(m_sx + 1, m_sz + 1,
				m_field.data(), 1.0f, 0.0f, max_h, 1, PHY_FLOAT, false));
		m_shape->setLocalScaling(btVector3(m_size.cell_size, 1.0f,
				m_size.cell_size));
		btTransform offset;
		offset.setIdentity();
		offset.setOrigin(btVector3(0, max_h / 2, 0));
		body->GetCompoundShape()->addChildShape(offset, m_shape.get());
		body->UpdateMass();
		log_i(MODULE, "heightmap: the heightfield made: %ix%i, %i materials,"
				" %.1f MB held (heights, weights, heightfield)", m_sx, m_sz,
				m_size.materials, (m_heights.size() * 2 + m_weights.size() +
				m_field.size() * 4) / 1048576.0);
	}

	void commit();

	ss_ init_packet()
	{
		return ss_(INIT_VERSION)+" "+itos(m_size.chunks_x)+" "+
				itos(m_size.chunks_z)+" "+itos(m_size.chunk_size)+" "+
				ftos(m_size.cell_size)+" "+ftos(m_size.base_y)+" "+
				ftos(HEIGHT_STEP)+" "+itos(m_size.materials);
	}

	ss_ region_packet(const Rect &r, const ss_ &data)
	{
		const int v[4] = {r.x0, r.z0, r.x1 - r.x0 + 1, r.z1 - r.z0 + 1};
		ss_ p(8, '\0');
		for(int i = 0; i < 4; i++){
			p[i * 2] = (char)(v[i] >> 8);
			p[i * 2 + 1] = (char)(v[i] & 0xff);
		}
		return p + data;
	}

	// The whole map to a peer that joined the scene, a chunk a region
	void send_all(replicate::PeerId peer)
	{
		const int64_t t0 = interface::os::time_us();
		size_t bytes = 0;
		network::access(m_server, [&](network::Interface *inet){
			inet->send(peer, "core:run_script",
					"require(\"buildat/module/heightmap\")");
			inet->send(peer, "heightmap:init", init_packet());
			for(int cz = 0; cz < m_size.chunks_z; cz++)
			for(int cx = 0; cx < m_size.chunks_x; cx++){
				const Rect r = chunk_rect(cx, cz);
				const ss_ p = region_packet(r, rect_data(r));
				bytes += p.size();
				inet->send(peer, "heightmap:region", p);
			}
			inet->send(peer, "heightmap:ready", "");
		});
		log_i(MODULE, "heightmap: the map sent to peer %zu: %i chunks,"
				" %zu bytes in %.0f ms", peer,
				m_size.chunks_x * m_size.chunks_z, bytes,
				(interface::os::time_us() - t0) / 1000.0);
	}
};

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;
	std::map<SceneReference, up_<Map>> m_maps;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
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
		for(auto &pair : m_maps)
			pair.second->commit();
	}

	// The maps' nodes go before this module's code does: their RigidBodies
	// hold heightfields this module made
	// simplified: so the maps are not kept over a hot reload
	void on_unload()
	{
		m_maps.clear();
	}

	void on_peer_joined_scene(const replicate::PeerJoinedScene &event)
	{
		auto it = m_maps.find(event.scene);
		if(it == m_maps.end())
			return;
		// What is written and not committed goes first, so the whole map
		// sent is the map as it is
		it->second->commit();
		it->second->send_all(event.peer);
	}

	void on_scene_deleted(const main_context::SceneDeleted &event)
	{
		m_maps.erase(event.scene);
	}

	// Interface

	Instance* create_instance(SceneReference scene, const Size &size)
	{
		if(m_maps.count(scene))
			throw Exception("heightmap: the scene has a map already");
		Map *map = new Map(this, m_server, scene, size);
		m_maps[scene] = up_<Map>(map);
		return map;
	}

	void delete_instance(SceneReference scene)
	{
		m_maps.erase(scene);
	}

	Instance* get_instance(SceneReference scene)
	{
		auto it = m_maps.find(scene);
		return it == m_maps.end() ? nullptr : it->second.get();
	}
};

void Map::commit()
{
	if(m_written.empty() && m_field_pending.empty() && m_node_id)
		return;
	const int64_t t0 = interface::os::time_us();
	std::map<int, Rect> written;
	written.swap(m_written);
	main_context::access(m_server, [&](main_context::Interface *imc){
		if(!m_node_id)
			create_body(imc->check_scene(m_scene));
		for(const Rect &r : m_field_pending)
			update_field(r);
		for(auto &w : written)
			update_field(w.second);
	});
	m_field_pending.clear();
	if(written.empty())
		return;
	if(m_store){
		m_store->batch([&](){
			m_store->set(m_name+"/meta", meta());
			for(auto &w : written){
				const int cx = w.first % m_size.chunks_x;
				const int cz = w.first / m_size.chunks_x;
				m_store->set(chunk_key(cx, cz), chunk_data(cx, cz));
			}
		});
	}
	sv_<replicate::PeerId> peers;
	replicate::access(m_server, [&](replicate::Interface *irep){
		peers = irep->find_peers_on_scene(m_scene);
	});
	size_t bytes = 0;
	if(!peers.empty()){
		sv_<ss_> packets;
		for(auto &w : written){
			packets.push_back(region_packet(w.second, rect_data(w.second)));
			bytes += packets.back().size();
		}
		network::access(m_server, [&](network::Interface *inet){
			for(replicate::PeerId peer : peers)
				for(const ss_ &p : packets)
					inet->send(peer, "heightmap:region", p);
		});
	}
	// Verbose: a map deformed every tick commits every tick
	log_v(MODULE, "heightmap: committed %zu chunks%s, %zu bytes a peer to"
			" %zu peers, in %.1f ms", written.size(), m_store ? " (saved)" :
			"", bytes, peers.size(),
			(interface::os::time_us() - t0) / 1000.0);
}

extern "C" {
	BUILDAT_EXPORT void* createModule_heightmap(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
