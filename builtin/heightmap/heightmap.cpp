// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [HEIGHTMAP_TERRAIN] The server half: the grid, its save, the chunks sent,
// and a Terrain with a heightfield for the scene's physics. api.h says what
// the data is.
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
#include <Image.h>
#include <Terrain.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <cmath>
#include <cstring>
#include <map>
#include <set>
#include <sstream>
#define MODULE "heightmap"

using interface::Event;
using namespace Urho3D;

namespace heightmap {

static const char CHUNK_FORMAT = 1;
static const char *STORE = "heightmap";
// What a client's packet of the map's shape says before its numbers
static const char *INIT_VERSION = "1";

struct Module;

struct Map: public Instance
{
	Module *m_module;
	interface::Server *m_server;
	SceneReference m_scene;
	Size m_size;
	int m_sx, m_sz;
	sv_<uint16_t> m_heights;
	sv_<uint8_t> m_weights; // NUM_MATERIALS a sample
	// Chunks written since the last commit, by index cz * chunks_x + cx
	std::set<int> m_written;
	bool m_terrain_stale = true;
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
				size.chunks_z * size.chunk_size > 8192)
			throw Exception("heightmap: a size of whole chunks, chunk_size a"
					" multiple of 64, 8192 samples a side at most, a cell"
					" over 0");
		m_sx = size.chunks_x * size.chunk_size;
		m_sz = size.chunks_z * size.chunk_size;
		m_heights.assign((size_t)m_sx * m_sz, 0);
		m_weights.assign((size_t)m_sx * m_sz * NUM_MATERIALS, 0);
		for(size_t i = 0; i < m_weights.size(); i += NUM_MATERIALS)
			m_weights[i] = 255;
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
		if(m_written.count(ci))
			return;
		if(!m_hooks.empty()){
			const ss_ old = chunk_data(cx, cz);
			for(auto &hook : m_hooks)
				hook->before_write(this, cx, cz, old);
		}
		m_written.insert(ci);
		m_terrain_stale = true;
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
		const size_t i = index(x, z) * NUM_MATERIALS;
		Weights w;
		for(int k = 0; k < NUM_MATERIALS; k++)
			w[k] = m_weights[i + k];
		return w;
	}

	void set_weights(int x, int z, const Weights &w)
	{
		const size_t i = index(x, z) * NUM_MATERIALS;
		if(memcmp(&m_weights[i], w.data(), NUM_MATERIALS) == 0)
			return;
		will_write(x, z);
		memcpy(&m_weights[i], w.data(), NUM_MATERIALS);
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
				h[(size_t)z * m_sx + x] = interface::noise::noise2(
						p.height, p.seed, x * cell, z * cell);
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
			auto ramp = [](float v){ return v < 0 ? 0.0f : v > 1 ? 1.0f : v; };
			const float rock = ramp((slope - p.rock_slope) * 10.0f + 0.5f);
			const float sand = ramp(p.sand_below + 0.5f -
					h[(size_t)z * m_sx + x]) * (1.0f - rock);
			const float grass = 1.0f - rock - sand;
			set_weights(x, z, Weights{{(uint8_t)std::round(grass * 255),
					(uint8_t)std::round(rock * 255),
					(uint8_t)std::round(sand * 255)}});
		}
		// Every chunk, also one the noise left as it was
		for(int ci = 0; ci < m_size.chunks_x * m_size.chunks_z; ci++)
			will_write(ci % m_size.chunks_x * m_size.chunk_size,
					ci / m_size.chunks_x * m_size.chunk_size);
		log_i(MODULE, "heightmap: generated %ix%i seed %u in %.0f ms, hash %08x",
				m_sx, m_sz, p.seed,
				(interface::os::time_us() - t0) / 1000.0, content_hash());
	}

	// The chunk's raw bytes: heights big-endian, then the weights
	ss_ chunk_raw(int cx, int cz)
	{
		const int cs = m_size.chunk_size;
		ss_ raw((size_t)cs * cs * (2 + NUM_MATERIALS), '\0');
		char *h = &raw[0], *w = &raw[(size_t)cs * cs * 2];
		for(int z = 0; z < cs; z++){
			const size_t row = (size_t)(cz * cs + z) * m_sx + cx * cs;
			for(int x = 0; x < cs; x++){
				const uint16_t v = m_heights[row + x];
				*h++ = (char)(v >> 8);
				*h++ = (char)(v & 0xff);
			}
			memcpy(w, &m_weights[row * NUM_MATERIALS], cs * NUM_MATERIALS);
			w += cs * NUM_MATERIALS;
		}
		return raw;
	}

	ss_ chunk_data(int cx, int cz)
	{
		std::ostringstream os(std::ios::binary);
		os.put(CHUNK_FORMAT);
		interface::compress_zstd(chunk_raw(cx, cz), os);
		return os.str();
	}

	bool read_chunk(int cx, int cz, const ss_ &data)
	{
		const int cs = m_size.chunk_size;
		if(data.empty() || data[0] != CHUNK_FORMAT)
			return false;
		ss_ raw((size_t)cs * cs * (2 + NUM_MATERIALS), '\0');
		try {
			if(interface::decompress_zstd(data.substr(1), (uint8_t*)&raw[0],
					raw.size()) != raw.size())
				return false;
		} catch(std::exception &e){
			return false;
		}
		const char *h = raw.data(), *w = raw.data() + (size_t)cs * cs * 2;
		for(int z = 0; z < cs; z++){
			const size_t row = (size_t)(cz * cs + z) * m_sx + cx * cs;
			for(int x = 0; x < cs; x++, h += 2)
				m_heights[row + x] = (uint16_t)((uint8_t)h[0] << 8 |
						(uint8_t)h[1]);
			memcpy(&m_weights[row * NUM_MATERIALS], w, cs * NUM_MATERIALS);
			w += cs * NUM_MATERIALS;
		}
		return true;
	}

	ss_ meta()
	{
		return storage::pack((int32_t)1, (int32_t)m_size.chunks_x,
				(int32_t)m_size.chunks_z, (int32_t)m_size.chunk_size,
				m_size.cell_size, m_size.base_y);
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
			if(read_chunk(cx, cz, data))
				n++;
			else
				bad++;
		}
		if(bad)
			log_w(MODULE, "heightmap: %i chunks of \"%s\" did not read", bad,
					cs(name));
		m_terrain_stale = true;
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

	// The Terrain's heightmap: a vertex more than the samples each way,
	// the last row and column copies of the one before, top row the
	// largest z (Terrain reads its image upside down)
	// simplified: so the last cell each way is flat; a map that wants its
	// edge sloped is a sample larger
	SharedPtr<Image> make_image(Context *context)
	{
		const int w = m_sx + 1, h = m_sz + 1;
		SharedPtr<Image> img(new Image(context));
		img->SetSize(w, h, 2);
		unsigned char *d = img->GetData();
		for(int r = 0; r < h; r++){
			const int z = std::min(m_sz - r, m_sz - 1);
			for(int vx = 0; vx < w; vx++){
				const uint16_t v = m_heights[(size_t)z * m_sx +
						std::min(vx, m_sx - 1)];
				*d++ = v >> 8;
				*d++ = v & 0xff;
			}
		}
		return img;
	}

	void update_terrain()
	{
		const int64_t t0 = interface::os::time_us();
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene);
			Node *n = m_node_id ? scene->GetNode(m_node_id) : nullptr;
			bool created = false;
			if(!n){
				n = scene->CreateChild("heightmap", LOCAL);
				n->SetPosition(Vector3(m_sx * m_size.cell_size / 2,
						m_size.base_y, m_sz * m_size.cell_size / 2));
				m_node_id = n->GetID();
				Terrain *t = n->CreateComponent<Terrain>(LOCAL);
				t->SetPatchSize(64);
				t->SetSpacing(Vector3(m_size.cell_size, HEIGHT_STEP * 256,
						m_size.cell_size));
				created = true;
			}
			Terrain *t = n->GetComponent<Terrain>();
			t->SetHeightMap(make_image(scene->GetContext()));
			if(created){
				n->CreateComponent<RigidBody>(LOCAL);
				n->CreateComponent<CollisionShape>(LOCAL)->SetTerrain(0);
			}
		});
		m_terrain_stale = false;
		log_v(MODULE, "heightmap: the server's terrain built in %.0f ms",
				(interface::os::time_us() - t0) / 1000.0);
	}

	void commit();

	ss_ init_packet()
	{
		return ss_(INIT_VERSION)+" "+itos(m_size.chunks_x)+" "+
				itos(m_size.chunks_z)+" "+itos(m_size.chunk_size)+" "+
				ftos(m_size.cell_size)+" "+ftos(m_size.base_y)+" "+
				ftos(HEIGHT_STEP);
	}

	ss_ chunk_packet(int cx, int cz, const ss_ &data)
	{
		ss_ p(4, '\0');
		p[0] = (char)(cx >> 8); p[1] = (char)(cx & 0xff);
		p[2] = (char)(cz >> 8); p[3] = (char)(cz & 0xff);
		return p + data;
	}

	// The whole map to a peer that joined the scene
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
				const ss_ p = chunk_packet(cx, cz, chunk_data(cx, cz));
				bytes += p.size();
				inet->send(peer, "heightmap:chunk", p);
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
		m_server->sub_event(this, Event::t("replicate:peer_joined_scene"));
		m_server->sub_event(this, Event::t("main_context:scene_deleted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
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
		auto it = m_maps.find(scene);
		if(it == m_maps.end())
			return;
		uint node_id = it->second->m_node_id;
		if(node_id){
			main_context::access(m_server, [&](main_context::Interface *imc){
				Node *n = imc->check_scene(scene)->GetNode(node_id);
				if(n)
					n->Remove();
			});
		}
		m_maps.erase(it);
	}

	Instance* get_instance(SceneReference scene)
	{
		auto it = m_maps.find(scene);
		return it == m_maps.end() ? nullptr : it->second.get();
	}
};

void Map::commit()
{
	if(m_terrain_stale)
		update_terrain();
	if(m_written.empty())
		return;
	std::set<int> written;
	written.swap(m_written);
	sv_<std::pair<int, ss_>> chunks;
	for(int ci : written)
		chunks.emplace_back(ci, chunk_data(ci % m_size.chunks_x,
				ci / m_size.chunks_x));
	if(m_store){
		m_store->batch([&](){
			m_store->set(m_name+"/meta", meta());
			for(auto &c : chunks)
				m_store->set(chunk_key(c.first % m_size.chunks_x,
						c.first / m_size.chunks_x), c.second);
		});
		log_v(MODULE, "heightmap: saved %zu chunks of \"%s\"",
				chunks.size(), cs(m_name));
	}
	sv_<replicate::PeerId> peers;
	replicate::access(m_server, [&](replicate::Interface *irep){
		peers = irep->find_peers_on_scene(m_scene);
	});
	if(peers.empty())
		return;
	network::access(m_server, [&](network::Interface *inet){
		for(replicate::PeerId peer : peers)
			for(auto &c : chunks)
				inet->send(peer, "heightmap:chunk", chunk_packet(
						c.first % m_size.chunks_x, c.first / m_size.chunks_x,
						c.second));
	});
}

extern "C" {
	BUILDAT_EXPORT void* createModule_heightmap(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
