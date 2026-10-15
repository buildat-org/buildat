// Buildat: apps/demo_skeldat/main/main.cpp
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// skeldat ([SKELDAT]): skelenti made fresh in Buildat, no Luanti game under
// it. The rules are game.h's; this is the world they run in -- Luanti's own
// v7 mapgen (builtin/luanti_mapgen) fed skelenti's biomes, ores and trees,
// voxelworld keeping the light and the saves -- and the players: where
// they are, what they carry, what they dig, place, craft and cook.
//
// The world: until one runs, a joining client gets the world dialog
// (client_lua/worlds.lua) and the launcher's own client picks a save to
// play, a new one to make or one to delete. The first save picked is the
// world for as long as the server runs. BUILDAT_SKELDAT_WORLD=<name> skips
// the dialog (the checks; a server nobody sits at).
//
// The voxel word is Luanti's cut (VoxelFormat::luanti(): the id, the sky
// and the lamp light, param2), which is what the mapgen writes, and a
// second plane of 8 bits, "bones", whose low 4 are the bones field
// (bones.h): seeded by the mapgen in the danger zones, grown a section at
// a time, and drawn by the format's tint modifier.
//
// What the client says is trusted for now, apart from the reach and the
// time a dig takes: its position is taken as it comes until the movement
// check is in (stage 6).
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "accounts/api.h"
#include "client_file/api.h"
#include "luanti_mapgen/api.h"
#include "main_context/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "storage/api.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "game.h"
#include "bones.h"
#include <cmath>
#include <map>
#include <random>
#include <set>
#include <sstream>
#define MODULE "main"

namespace demo_skeldat {

using interface::Event;
using interface::VoxelInstance;
using skeldat::Stack;
namespace pv = PolyVox;

// Luanti's mapgens write these three as numbers (vendor/mapnode.h), so
// the registry has them at those ids: ignore is the registry's own
// undefined 0, and the game's nodes follow air
static const uint32_t ID_IGNORE = 0, ID_UNKNOWN = 1, ID_AIR = 2, ID_NODE0 = 3;
static const float REACH = 5.5f;       // a little over Luanti's 4 from the eye
static const float DAY_SECONDS = 1200; // Luanti's time_speed 72
static const int HP_MAX = 20, BREATH_MAX = 10;
// Faster than this a landing hurts, a point a node a second over it
// (Luanti's client: BS*14)
static const float FALL_TOLERANCE = 14;

// The four horizontal turns of a facedir, out of builtin/luanti's
// FACEDIR_TILES and FACEDIR_TURNS: which tile each face wears and how far
// it is turned in its face
static const uint8_t FACEDIR_TILES[4][6] = {{0, 1, 2, 3, 4, 5},
		{0, 1, 4, 5, 3, 2}, {0, 1, 3, 2, 5, 4}, {0, 1, 5, 4, 2, 3}};
static const uint8_t FACEDIR_TURNS[4][6] = {{0, 0, 0, 0, 0, 0},
		{3, 1, 0, 0, 0, 0}, {2, 2, 0, 0, 0, 0}, {1, 3, 0, 0, 0, 0}};

static ss_ pos_key(int x, int y, int z)
{
	return itos(x)+","+itos(y)+","+itos(z);
}

static ss_ dtos(double v)
{
	char buf[32];
	snprintf(buf, sizeof buf, "%.3f", v);
	return buf;
}

struct Player
{
	ss_ name;
	float x = 0, y = 0, z = 0, yaw = 0;
	bool placed = false; // the client has its position
	int hp = HP_MAX, breath = BREATH_MAX;
	sv_<Stack> main = sv_<Stack>(36), craft = sv_<Stack>(9),
			craftresult = sv_<Stack>(1);
	int wield = 0;
	// The table or the furnace whose window is open, by "x,y,z"
	ss_ open;
	// The dig under way: where, and since when
	ss_ dig_at;
	double dig_t0 = 0;

	ss_ save() const {
		std::ostringstream os;
		os<<x<<" "<<y<<" "<<z<<" "<<yaw<<" "<<hp<<" "<<breath<<"\n";
		for(auto *l : {&main, &craft, &craftresult}){
			for(size_t i = 0; i < l->size(); i++)
				os<<(i ? "|" : "")<<(*l)[i].str();
			os<<"\n";
		}
		return os.str();
	}
	void load(const ss_ &s){
		std::istringstream is(s);
		ss_ line;
		std::getline(is, line);
		std::istringstream(line)>>x>>y>>z>>yaw>>hp>>breath;
		for(auto *l : {&main, &craft, &craftresult}){
			std::getline(is, line);
			std::istringstream ls(line);
			ss_ one;
			for(size_t i = 0; i < l->size() && std::getline(ls, one, '|'); i++)
				(*l)[i] = Stack::parse(one);
		}
		placed = true;
	}
};

struct Furnace
{
	Stack src, fuel, dst;
	float fuel_left = 0, src_time = 0;

	ss_ save() const {
		std::ostringstream os;
		os<<src.str()<<"|"<<fuel.str()<<"|"<<dst.str()<<"|"<<fuel_left<<"|"
				<<src_time;
		return os.str();
	}
	void load(const ss_ &s){
		std::istringstream is(s);
		ss_ a[5];
		for(ss_ &p : a)
			std::getline(is, p, '|');
		src = Stack::parse(a[0]);
		fuel = Stack::parse(a[1]);
		dst = Stack::parse(a[2]);
		fuel_left = (float)atof(a[3].c_str());
		src_time = (float)atof(a[4].c_str());
	}
};

// The mapgen's section, and its bones seeded by the place's danger: every
// voxel that is not air in a column at bones::SEED_DANGER or more. Runs on
// worldgen's worker thread, so it touches nothing but the volume.
struct BonesGenerator: public worldgen::GeneratorInterface
{
	up_<worldgen::GeneratorInterface> m_inner;
	interface::VoxelFormat m_format;
	interface::VoxelField m_bones;
	uint32_t m_salt;

	BonesGenerator(worldgen::GeneratorInterface *inner,
			const interface::VoxelFormat &format,
			const interface::VoxelField &bones, uint32_t salt):
		m_inner(inner), m_format(format), m_bones(bones), m_salt(salt){}

	pv::Vector3DInt32 get_padding_voxels()
	{
		return m_inner->get_padding_voxels();
	}

	void generate(main_context::SceneReference scene,
			const pv::Vector3DInt16 &section_p, interface::VoxelVolume &volume)
	{
		m_inner->generate(scene, section_p, volume);
		volume.add_planes(m_format.planes);
		const pv::Region &r = volume.getEnclosingRegion();
		const pv::Vector3DInt32 &lc = r.getLowerCorner(),
				&uc = r.getUpperCorner();
		for(int32_t z = lc.getZ(); z <= uc.getZ(); z++)
		for(int32_t x = lc.getX(); x <= uc.getX(); x++){
			const int b = skeldat::bones::seed_value(
					skeldat::bones::danger(m_salt, (float)x, (float)z));
			if(b == 0)
				continue;
			for(int32_t y = lc.getY(); y <= uc.getY(); y++){
				const uint32_t id = m_format.id.get(
						volume.getVoxelAt(x, y, z).data);
				if(id == ID_IGNORE || id == ID_AIR)
					continue;
				uint32_t word = volume.plane_at(1, x, y, z);
				m_bones.set(word, (uint32_t)b);
				volume.set_plane_at(1, x, y, z, word);
			}
		}
	}
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	const skeldat::Game m_game = skeldat::make_game();
	main_context::SceneReference m_scene = nullptr;
	storage::Save *m_save = nullptr;
	storage::Store *m_store = nullptr;
	bool m_starting = false;
	std::set<size_t> m_waiting, m_shown;
	std::map<size_t, Player> m_players;
	std::map<ss_, Furnace> m_furnaces;
	luanti_mapgen::Params m_mapgen;
	bool m_spawn_ready = false;
	float m_spawn[3] = {0, 0, 0};
	double m_time = 0;
	// The time of day, 0 to 1 with 0.5 noon; a new world starts at 6:00
	double m_day = 0.25;
	float m_save_t = 0, m_furnace_t = 0, m_send_t = 0, m_breath_t = 0;
	size_t m_worldgen_queue = 0;
	bool m_load_points_dirty = true;
	interface::VoxelFormat m_format;
	interface::VoxelField m_bones{1, 0, 4};
	std::mt19937 m_rand{std::random_device{}()};
	// The world's own clock, seconds of game time since it was made, kept
	// in its save: what a section's catch-up is counted against
	double m_world_t = 0;
	// The loaded sections, each with the world time its bones were last up
	// to date; written to the store "skeldat_bones" when one unloads
	std::map<ss_, double> m_sections;
	// Expansions owed: due at random by the period, and the catch-ups of
	// sections that have just loaded, done a few a tick
	double m_expand_due = 0;
	std::map<ss_, int> m_catchup;
	size_t m_expansions = 0, m_expand_changed = 0;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server)
	{
		m_format = interface::VoxelFormat::luanti();
		m_format.planes.push_back(interface::VoxelPlane("bones", 8));
		// The bones drawn: the definitions' tint_ramp from white to a rust,
		// red over twice its green so that grass turns brown
		m_format.tint = m_bones;
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("core:shutdown"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this, Event::t("worldgen:queue_modified"));
		m_server->sub_event(this, Event::t("voxelworld:section_loaded"));
		m_server->sub_event(this, Event::t("voxelworld:section_unloaded"));
		for(const char *n : {"world_play", "world_create", "world_delete",
				"pos", "dig_start", "dig", "place", "use", "wield", "open",
				"close", "move", "craft", "fall", "respawn"})
			m_server->sub_event(this, Event::t(
					ss_("network:packet_received/skeldat:")+n));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_VOIDN("core:shutdown", save)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("worldgen:queue_modified", on_worldgen_queue_modified,
				worldgen::QueueModifiedEvent)
		EVENT_TYPEN("voxelworld:section_loaded", on_section_loaded,
				voxelworld::SectionLoaded)
		EVENT_TYPEN("voxelworld:section_unloaded", on_section_unloaded,
				voxelworld::SectionUnloaded)
		EVENT_TYPEN("network:packet_received/skeldat:world_play",
				on_world_play, network::Packet)
		EVENT_TYPEN("network:packet_received/skeldat:world_create",
				on_world_create, network::Packet)
		EVENT_TYPEN("network:packet_received/skeldat:world_delete",
				on_world_delete, network::Packet)
		// The rest of the game's packets go to one handler, by name
		static const ss_ GAME = "network:packet_received/skeldat:";
		for(const char *n : {"pos", "dig_start", "dig", "place", "use",
				"wield", "open", "close", "move", "craft", "fall",
				"respawn"}){
			if(type == Event::t(GAME+n)){
				on_game_packet(*dynamic_cast<const network::Packet*>(p));
				return;
			}
		}
	}

	void send(size_t peer, const ss_ &name, const ss_ &data)
	{
		network::access(m_server, [&](network::Interface *i){
			i->send(peer, name, data);
		});
	}

	//
	// The world dialog
	//

	void on_start()
	{
		const char *name = getenv("BUILDAT_SKELDAT_WORLD");
		if(name && name[0])
			start_world(name, true);
	}

	// A save a world may be: a valid name not beginning with _, which are
	// the server's own (_server, builtin/accounts')
	static bool is_world(storage::Interface *i, const ss_ &name)
	{
		return i->valid_name(name) && name[0] != '_';
	}

	bool may_pick(size_t peer)
	{
		bool local = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			local = i->is_local(peer);
		});
		return local && !m_starting;
	}

	void send_worlds(size_t peer)
	{
		ss_ data = "wait";
		if(may_pick(peer)){
			data = "list";
			storage::access(m_server, [&](storage::Interface *i){
				for(const storage::SaveInfo &info : i->list())
					if(is_world(i, info.name))
						data += "\n"+info.name;
			});
		}
		send(peer, "skeldat:worlds", data);
	}

	void on_world_play(const network::Packet &packet)
	{
		if(!may_pick(packet.sender) || !start_world(packet.data, false))
			send_worlds(packet.sender);
	}

	void on_world_create(const network::Packet &packet)
	{
		bool exists = false;
		storage::access(m_server, [&](storage::Interface *i){
			for(const storage::SaveInfo &info : i->list())
				exists = exists || info.name == packet.data;
		});
		if(!may_pick(packet.sender) || exists ||
				!start_world(packet.data, true))
			send_worlds(packet.sender);
	}

	void on_world_delete(const network::Packet &packet)
	{
		if(may_pick(packet.sender)){
			storage::access(m_server, [&](storage::Interface *i){
				if(is_world(i, packet.data)){
					log_i(MODULE, "skeldat: the world \"%s\" deleted",
							cs(packet.data));
					i->remove(packet.data);
				}
			});
		}
		send_worlds(packet.sender);
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		if(m_scene){
			show(event.recipient);
		} else if(m_waiting.insert(event.recipient).second){
			send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"main/worlds.lua\")");
			send_worlds(event.recipient);
		}
	}

	//
	// The world
	//

	bool start_world(const ss_ &name, bool create)
	{
		if(m_starting)
			return false;
		storage::access(m_server, [&](storage::Interface *i){
			if(!is_world(i, name))
				return;
			m_save = i->open(name);
			if(!m_save && create)
				m_save = i->create(name);
		});
		if(!m_save){
			log_w(MODULE, "skeldat: no world \"%s\"", cs(name));
			return false;
		}
		m_starting = true;
		m_store = m_save->store("skeldat");
		ss_ v;
		uint32_t seed = m_rand();
		const char *env_seed = getenv("BUILDAT_SKELDAT_SEED");
		if(m_store->get("seed", v))
			seed = (uint32_t)std::stoul(v);
		else if(env_seed && env_seed[0])
			seed = (uint32_t)std::stoul(env_seed);
		m_store->set("seed", itos(seed));
		if(m_store->get("day", v))
			m_day = atof(v.c_str());
		if(m_store->get("world_t", v))
			m_world_t = atof(v.c_str());
		// For a check: the time of day it starts at, 0.5 noon
		const char *env_time = getenv("BUILDAT_SKELDAT_TIME");
		if(env_time && env_time[0])
			m_day = atof(env_time);
		for(const ss_ &key : m_store->list("furnace/"))
			if(m_store->get(key, v))
				m_furnaces[key.substr(8)].load(v);
		log_i(MODULE, "skeldat: the world \"%s\" starts, seed %u, %zu "
				"furnaces", cs(name), seed, m_furnaces.size());
		create_world(seed);
		for(size_t peer : m_waiting)
			show(peer);
		m_waiting.clear();
		return true;
	}

	uint32_t id_of(const ss_ &name) const
	{
		for(size_t i = 0; i < m_game.nodes.size(); i++)
			if(m_game.nodes[i].name == name)
				return (uint32_t)i + ID_NODE0;
		return name == "air" ? ID_AIR : ID_IGNORE;
	}
	const skeldat::NodeDef* node_of(uint32_t id) const
	{
		return id >= ID_NODE0 && id - ID_NODE0 < m_game.nodes.size() ?
				&m_game.nodes[id - ID_NODE0] : nullptr;
	}

	void create_world(uint32_t seed)
	{
		main_context::access(m_server, [&](main_context::Interface *i){
			m_scene = i->create_scene();
		});
		m_mapgen = mapgen_params(seed);
		worldgen::GeneratorInterface *generator = nullptr;
		luanti_mapgen::access(m_server, [&](luanti_mapgen::Interface *i){
			generator = i->create_generator(m_mapgen);
		});
		// Before the voxelworld, or its first requests are lost
		worldgen::access(m_server, [&](worldgen::Interface *i){
			i->create_instance(m_scene);
			i->get_instance(m_scene)->set_generator(new BonesGenerator(
					generator, m_format, m_bones, m_mapgen.seed));
		});
		voxelworld::access(m_server, [&](voxelworld::Interface *i){
			// The bounds in sections of 64: what anyone will walk across,
			// and from below the diamonds to over the mountains
			i->create_instance(m_scene, pv::Region(-400, -4, -400,
					400, 3, 400));
		});
		// Before voxelworld's first tick, which loads a whole region that
		// has no load points
		update_load_points();
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			reg->set_format(m_format);
			build_registry(reg);
			w->set_save(m_save, "main");
			// The mapgen lights what it builds; voxelworld keeps it up as
			// the world changes, the torches' too
			w->set_light_maintained(voxelworld::Instance::LIGHT_SKY, true);
			w->set_light_maintained(voxelworld::Instance::LIGHT_LAMP, true);
		});
		worldgen::access(m_server, m_scene, [&](worldgen::Instance *i){
			i->enable();
		});
		find_spawn();
	}

	// Luanti's unknown and air, then the nodes at their ids
	void build_registry(interface::VoxelRegistry *reg)
	{
		for(uint32_t id = ID_UNKNOWN; id < ID_NODE0 + m_game.nodes.size();
				id++){
			interface::VoxelDefinition d;
			if(const skeldat::NodeDef *n = node_of(id)){
				d = voxel_def(*n);
			} else if(id == ID_AIR){
				d.name.block_name = "air";
				d.fully_empty = true;
				d.edge_material_id = interface::EDGEMATERIALID_EMPTY;
				d.physically_solid = false;
				d.pointable = 0;
			} else {
				// Never generated; drawn as stone if a save has one
				skeldat::NodeDef stone = *node_of(id_of("skeldat:stone"));
				d = voxel_def(stone);
				d.name.block_name = "unknown";
			}
			const interface::VoxelTypeId got = reg->add_voxel(d);
			if(got != id)
				throw Exception("skeldat: voxel "+d.name.block_name+" is id "+
						itos(got)+", not "+itos(id));
		}
	}

	static void box_quads(sv_<interface::VoxelQuad> &out, const float *b);
	static void turn_y(float v[3], int quarters)
	{
		static const float SIN[4] = {0, 1, 0, -1}, COS[4] = {1, 0, -1, 0};
		const int i = ((quarters % 4) + 4) % 4;
		const float a = v[0], c = v[2];
		v[0] = COS[i] * a - SIN[i] * c;
		v[2] = SIN[i] * a + COS[i] * c;
	}
	static sv_<float> turn_boxes(const sv_<float> &in, int quarters)
	{
		sv_<float> out;
		for(size_t b = 0; b + 6 <= in.size(); b += 6){
			float lo[3] = {in[b], in[b + 1], in[b + 2]};
			float hi[3] = {in[b + 3], in[b + 4], in[b + 5]};
			turn_y(lo, quarters);
			turn_y(hi, quarters);
			for(int k = 0; k < 3; k++)
				out.push_back(std::min(lo[k], hi[k]));
			for(int k = 0; k < 3; k++)
				out.push_back(std::max(lo[k], hi[k]));
		}
		return out;
	}

	interface::VoxelDefinition voxel_def(const skeldat::NodeDef &n)
	{
		interface::VoxelDefinition d;
		d.name.block_name = n.name;
		for(int i = 0; i < 6; i++){
			interface::AtlasSegmentDefinition &seg = d.textures[i];
			seg.resource_name = n.tiles[i];
			seg.total_segments = Urho3D::IntVector2(1, 1);
			seg.select_segment = Urho3D::IntVector2(0, 0);
		}
		d.edge_material_id = interface::EDGEMATERIALID_GROUND;
		d.physically_solid = true;
		d.light_source = (uint8_t)n.light_source;
		// The bones: the albedo times this, from none to all
		d.tint_ramp[0] = 0xffffff;
		d.tint_ramp[1] = 0xc0604c;
		sv_<interface::VoxelQuad> shape;
		switch(n.shape){
		case skeldat::CUBE:
			break;
		case skeldat::ALLFACES:
			d.face_draw_type = interface::FaceDrawType::ALWAYS;
			d.alpha_masked = true;
			d.transmits_light = true;
			break;
		case skeldat::LIQUID: {
			static const float CUBE[6] = {-0.5f, -0.5f, -0.5f,
					0.5f, 0.5f, 0.5f};
			box_quads(shape, CUBE);
			d.physically_solid = false;
			d.is_liquid = true;
			d.liquid_is_source = true;
			d.liquid_top = 0.5f;
			d.shape_group = 1;
			d.translucent = true;
			d.swimmable = true;
			d.pointable = 0;
			break;
		}
		case skeldat::NODEBOX:
			for(size_t b = 0; b + 6 <= n.boxes.size(); b += 6)
				box_quads(shape, &n.boxes[b]);
			d.transmits_light = true;
			d.collision_boxes = n.boxes;
			d.selection_boxes = n.boxes;
			break;
		case skeldat::TORCH: {
			// Two quads crossed, as a plant
			const float s = 0.5f;
			for(int k = 0; k < 2; k++){
				interface::VoxelQuad q;
				const float dx = k ? s : -s, dz = s;
				const float p[4][3] = {{-dx, -s, -dz}, {dx, -s, dz},
						{dx, s, dz}, {-dx, s, -dz}};
				const float uv[4][2] = {{0, 1}, {1, 1}, {1, 0}, {0, 0}};
				for(int c = 0; c < 4; c++){
					for(int j = 0; j < 3; j++)
						q.p[c][j] = p[c][j];
					q.uv[c][0] = uv[c][0];
					q.uv[c][1] = uv[c][1];
				}
				shape.push_back(q);
			}
			d.shape_double_sided = true;
			d.alpha_masked = true;
			d.transmits_light = true;
			d.physically_solid = false;
			d.selection_boxes = n.boxes;
			break;
		}
		}
		if(!shape.empty()){
			d.shape = shape;
			d.face_draw_type = interface::FaceDrawType::NEVER;
			d.edge_material_id = interface::EDGEMATERIALID_EMPTY;
		}
		if(n.facedir){
			// param2 0 to 3, the way the player looked when placing it
			for(int f = 0; f < 4; f++){
				interface::VoxelVariant var;
				for(int i = 0; i < 6; i++){
					var.tile_order[i] = FACEDIR_TILES[f][i];
					var.tile_turns[i] = FACEDIR_TURNS[f][i];
				}
				if(!shape.empty() && f != 0){
					var.shape = shape;
					for(interface::VoxelQuad &q : var.shape)
						for(int c = 0; c < 4; c++)
							turn_y(q.p[c], 4 - f);
					var.collision_boxes = turn_boxes(n.boxes, 4 - f);
					var.selection_boxes = var.collision_boxes;
				}
				d.variants.push_back(var);
			}
			for(int p = 0; p < 256; p++)
				d.variant_of_param[p] = (uint8_t)(p & 3);
		}
		return d;
	}

	luanti_mapgen::Params mapgen_params(uint32_t seed)
	{
		luanti_mapgen::Params mp;
		mp.mgname = "v7";
		mp.seed = seed;
		mp.water_level = 1;
		mp.section_size = 64;
		for(size_t i = 0; i < m_game.nodes.size(); i++)
			mp.content_ids[m_game.nodes[i].name] = (uint32_t)i + ID_NODE0;
		mp.content_ids["air"] = ID_AIR;
		mp.content_ids["ignore"] = ID_IGNORE;
		mp.content_ids["unknown"] = ID_UNKNOWN;
		const uint32_t stone = id_of("skeldat:stone"),
				water = id_of("skeldat:water_source");
		mp.content_ids["mapgen_stone"] = stone;
		mp.content_ids["mapgen_water_source"] = water;
		mp.content_ids["mapgen_river_water_source"] = water;
		mp.content_ids["mapgen_cobble"] = id_of("skeldat:cobble");
		for(size_t i = 0; i < m_game.nodes.size(); i++){
			const skeldat::NodeDef &n = m_game.nodes[i];
			luanti_mapgen::Params::NodeProps p;
			p.walkable = n.shape != skeldat::LIQUID &&
					n.shape != skeldat::TORCH;
			p.light_propagates = n.shape != skeldat::CUBE;
			p.sunlight_propagates = n.shape == skeldat::NODEBOX ||
					n.shape == skeldat::TORCH;
			p.liquid_type = n.shape == skeldat::LIQUID ? 2 : 0;
			p.drawtype = n.shape == skeldat::ALLFACES ? "allfaces_optional" :
					n.shape == skeldat::LIQUID ? "liquid" :
					n.shape == skeldat::NODEBOX ? "nodebox" :
					n.shape == skeldat::TORCH ? "torchlike" : "normal";
			p.param_type_light = n.shape != skeldat::CUBE;
			mp.node_props[(uint32_t)i + ID_NODE0] = p;
		}
		luanti_mapgen::Params::NodeProps air;
		air.walkable = false;
		air.light_propagates = air.sunlight_propagates = true;
		air.floodable = true;
		air.drawtype = "airlike";
		mp.node_props[ID_AIR] = air;
		auto biome = [&](const ss_ &name, const ss_ &top, int depth_top,
				const ss_ &filler, int depth_filler, const ss_ &riverbed,
				int y_min, int y_max){
			luanti_mapgen::Params::Biome b;
			b.name = name;
			b.c_top = id_of(top);
			b.c_filler = id_of(filler);
			b.c_stone = stone;
			b.c_water_top = b.c_water = b.c_river_water = water;
			b.c_riverbed = riverbed.empty() ? stone : id_of(riverbed);
			b.c_dust = b.c_dungeon = b.c_dungeon_alt = b.c_dungeon_stair =
					ID_IGNORE;
			b.depth_top = depth_top;
			b.depth_filler = depth_filler;
			b.depth_riverbed = riverbed.empty() ? 0 : 2;
			b.y_min = y_min;
			b.y_max = y_max;
			b.heat_point = b.humidity_point = 50;
			mp.biomes.push_back(b);
		};
		biome("grassland", "skeldat:grass", 1, "skeldat:dirt", 3,
				"skeldat:sand", 4, 31000);
		biome("beach", "skeldat:sand", 1, "skeldat:sand", 2, "skeldat:sand",
				-6, 3);
		biome("seabed", "skeldat:gravel", 1, "skeldat:sand", 2, "",
				-31000, -7);
		auto ore = [&](const ss_ &name, int scarcity, int num, int y_max,
				int y_min){
			luanti_mapgen::Params::Ore o;
			o.name = name;
			o.c_ore = id_of(name);
			o.c_wherein = {stone};
			o.clust_scarcity = scarcity;
			o.clust_num_ores = num;
			o.clust_size = 3;
			o.y_min = y_min;
			o.y_max = y_max;
			mp.ores.push_back(o);
		};
		ore("skeldat:coal_ore", 8 * 8 * 8, 8, 64, -31000);
		ore("skeldat:iron_ore", 10 * 10 * 10, 5, 0, -31000);
		ore("skeldat:diamond_ore", 15 * 15 * 15, 4, -48, -31000);
		ore("skeldat:gravel", 16 * 16 * 16, 20, 64, -31000);
		ore("skeldat:dirt", 16 * 16 * 16, 20, 64, -32);
		// A tree, 5x6x5: a trunk of four, leaves around its top two and
		// over it
		luanti_mapgen::Params::Decoration d;
		d.name = "skeldat:tree";
		d.type = "schematic";
		d.c_place_on = {id_of("skeldat:grass")};
		d.sidelen = 16;
		d.fill_ratio = 0.006f;
		d.biomes = {"grassland"};
		d.y_min = 4;
		d.y_max = 200;
		d.flags = "place_center_x, place_center_z";
		d.rotation = "random";
		luanti_mapgen::Params::Schematic &s = d.schematic;
		s.given = true;
		s.size_x = 5; s.size_y = 6; s.size_z = 5;
		s.node_names = {"skeldat:tree", "skeldat:leaves", "air"};
		for(int z = 0; z < 5; z++) for(int y = 0; y < 6; y++)
		for(int x = 0; x < 5; x++){
			const bool trunk = x == 2 && z == 2 && y < 4;
			const bool edge = (x == 0 || x == 4) && (z == 0 || z == 4);
			const bool inner = x >= 1 && x <= 3 && z >= 1 && z <= 3;
			const bool leaf = ((y == 2 || y == 3) && !edge) ||
					(y == 4 && inner) ||
					(y == 5 && (x == 2 || z == 2) && inner);
			s.ids.push_back(trunk ? 0 : leaf ? 1 : 2);
			// Half the probability, and force_place in the high bit, as
			// a .mts file holds it
			s.param1.push_back(trunk ? 127 + 128 : leaf ? 127 : 0);
			s.param2.push_back(0);
		}
		mp.decorations.push_back(d);
		return mp;
	}

	// Luanti's spawn search: out from the origin until the mapgen says a
	// column is land, kept in the save so that it does not move
	void find_spawn()
	{
		ss_ v;
		if(m_store->get("spawn", v)){
			std::istringstream(v)>>m_spawn[0]>>m_spawn[1]>>m_spawn[2];
			m_spawn_ready = true;
			return;
		}
		// For a check: the spawn's column, the zones allowed
		const char *env = getenv("BUILDAT_SKELDAT_SPAWN");
		int ex = 0, ez = 0;
		if(env && sscanf(env, "%d %d", &ex, &ez) == 2){
			int level = 0;
			luanti_mapgen::access(m_server, [&](luanti_mapgen::Interface *im){
				im->spawn_level(m_mapgen, ex, ez, level);
			});
			m_spawn[0] = (float)ex;
			m_spawn[1] = (float)std::max(level, 2);
			m_spawn[2] = (float)ez;
			m_spawn_ready = true;
		}
		std::mt19937 r(m_mapgen.seed);
		for(int i = 0; i < 4000 && !m_spawn_ready; i++){
			const int range = 32 + i / 4;
			const int x = (int)(r() % (2 * range)) - range;
			const int z = (int)(r() % (2 * range)) - range;
			int level = 0;
			bool ok = false;
			luanti_mapgen::access(m_server, [&](luanti_mapgen::Interface *im){
				ok = im->spawn_level(m_mapgen, x, z, level);
			});
			if(!ok || level < 2 || level > 120 || skeldat::bones::seed_value(
					skeldat::bones::danger(m_mapgen.seed, (float)x,
					(float)z)) > 0)
				continue;
			m_spawn[0] = (float)x;
			m_spawn[1] = (float)level;
			m_spawn[2] = (float)z;
			m_spawn_ready = true;
		}
		if(!m_spawn_ready){
			m_spawn[1] = 30;
			m_spawn_ready = true;
		}
		std::ostringstream os;
		os<<m_spawn[0]<<" "<<m_spawn[1]<<" "<<m_spawn[2];
		m_store->set("spawn", os.str());
		log_i(MODULE, "skeldat: spawn at %s", cs(os.str()));
	}

	void update_load_points()
	{
		sv_<voxelworld::LoadPoint> points;
		if(m_players.empty()){
			points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
					(int)m_spawn[0], (int)m_spawn[1], (int)m_spawn[2]),
					2, 1, 1, 1));
		}
		for(auto &pair : m_players){
			const Player &pl = pair.second;
			if(!pl.placed)
				continue;
			points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
					(int)std::floor(pl.x), (int)std::floor(pl.y),
					(int)std::floor(pl.z)), 3, 2, 2, 1, pair.first));
		}
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			w->set_load_points(points);
			w->set_stream_budget(m_worldgen_queue >= 12 ? 0 : 2);
		});
		m_load_points_dirty = false;
	}

	void on_worldgen_queue_modified(const worldgen::QueueModifiedEvent &e)
	{
		m_worldgen_queue = e.queue_size;
		m_load_points_dirty = true;
	}

	//
	// The bones (bones.h)
	//

	static ss_ section_key(const pv::Vector3DInt16 &sp)
	{
		return pos_key(sp.getX(), sp.getY(), sp.getZ());
	}

	// A section back: the expansions it missed while away, owed
	void on_section_loaded(const voxelworld::SectionLoaded &e)
	{
		if(e.scene != m_scene || !m_save)
			return;
		const ss_ key = section_key(e.section_p);
		ss_ v;
		if(m_save->store("skeldat_bones")->get(key, v)){
			const int n = skeldat::bones::catch_up(m_world_t - atof(v.c_str()));
			if(n > 0)
				m_catchup[key] = n;
		}
		m_sections[key] = m_world_t;
	}

	void on_section_unloaded(const voxelworld::SectionUnloaded &e)
	{
		if(e.scene != m_scene || !m_save)
			return;
		const ss_ key = section_key(e.section_p);
		m_save->store("skeldat_bones")->set(key, dtos(m_world_t));
		m_sections.erase(key);
		m_catchup.erase(key);
	}

	// Every loaded section expands every SECTION_PERIOD on average, picked
	// at random; the owed catch-ups a few a tick
	void step_bones(float dtime)
	{
		if(m_sections.empty())
			return;
		m_expand_due += dtime * m_sections.size() /
				skeldat::bones::SECTION_PERIOD;
		int budget = 4;
		while(m_expand_due >= 1 && budget-- > 0){
			m_expand_due -= 1;
			auto it = m_sections.begin();
			std::advance(it, m_rand() % m_sections.size());
			expand(it->first);
		}
		// What the budget did not reach is dropped, not carried: a server
		// that falls behind grows the bones slower rather than in a burst
		if(m_expand_due > 1)
			m_expand_due = 1;
		for(budget = 4; budget > 0 && !m_catchup.empty(); budget--){
			auto it = m_catchup.begin();
			const ss_ key = it->first;
			if(--it->second <= 0)
				m_catchup.erase(it);
			expand(key);
		}
	}

	// One expansion of a section, written back in one set_volume of the
	// voxels it changed
	void expand(const ss_ &key)
	{
		int sx, sy, sz;
		char c;
		std::istringstream is(key);
		if(!(is>>sx>>c>>sy>>c>>sz))
			return;
		const pv::Vector3DInt16 sp(sx, sy, sz);
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			if(!w->is_section_loaded(sp))
				return;
			const pv::Region section = w->get_section_region_voxels(sp);
			pv::Region grown = section;
			grown.setLowerCorner(grown.getLowerCorner() -
					pv::Vector3DInt32(1, 1, 1));
			grown.setUpperCorner(grown.getUpperCorner() +
					pv::Vector3DInt32(1, 1, 1));
			interface::VoxelVolume vol = w->get_volume(grown);
			if(!vol.plane_is_materialised(1))
				return; // no bones in it nor around it
			const pv::Vector3DInt32 &lc = grown.getLowerCorner();
			skeldat::bones::Box box(vol.getWidth(), vol.getHeight(),
					vol.getDepth());
			bool any = false;
			for(int z = 0; z < box.d; z++)
			for(int y = 0; y < box.h; y++)
			for(int x = 0; x < box.w; x++){
				const interface::VoxelSample v = vol.sample_at(
						lc.getX() + x, lc.getY() + y, lc.getZ() + z);
				const uint32_t id = m_format.id.get(v);
				const size_t i = box.at(x, y, z);
				box.air[i] = id == ID_AIR || id == ID_IGNORE;
				box.b[i] = (uint8_t)m_bones.get(v);
				any = any || box.b[i] != 0;
			}
			if(!any)
				return;
			const sv_<uint8_t> before = box.b;
			m_expansions++;
			if(!skeldat::bones::expand(box))
				return;
			interface::VoxelVolume out(section, m_format.planes);
			size_t changed = 0;
			for(int z = 1; z < box.d - 1; z++)
			for(int y = 1; y < box.h - 1; y++)
			for(int x = 1; x < box.w - 1; x++){
				const size_t i = box.at(x, y, z);
				if(box.b[i] == before[i])
					continue;
				const int32_t px = lc.getX() + x, py = lc.getY() + y,
						pz = lc.getZ() + z;
				interface::VoxelSample v = vol.sample_at(px, py, pz);
				m_bones.set(v, box.b[i]);
				out.set_sample_at(px, py, pz, v);
				changed++;
			}
			m_expand_changed += changed;
			// The light as it was read: nothing here changes it
			w->set_volume(out, false, true);
		});
	}

	//
	// The players
	//

	// Once per peer: files_transmitted comes again after each batch
	void show(size_t peer)
	{
		if(!m_shown.insert(peer).second)
			return;
		ss_ name;
		accounts::access(m_server, [&](accounts::Interface *i){
			name = i->name_of(peer);
		});
		if(name.empty())
			name = "player"+itos(peer);
		Player &pl = m_players[peer];
		pl.name = name;
		ss_ v;
		if(m_save->store("skeldat_players")->get(name, v))
			pl.load(v);
		send(peer, "skeldat:worlds", "up");
		send(peer, "core:run_script",
				"buildat.run_script_file(\"main/init.lua\")");
		send(peer, "skeldat:items", items_text());
		replicate::access(m_server, [&](replicate::Interface *i){
			i->assign_scene_to_peer(m_scene, peer);
		});
		if(!pl.placed)
			respawn(peer, pl);
		else
			send_position(peer, pl);
		send_inventory(peer, pl);
		send_stats(peer, pl);
		send_time(peer);
		m_load_points_dirty = true;
		log_i(MODULE, "skeldat: %s joins at (%.1f, %.1f, %.1f)", cs(name),
				pl.x, pl.y, pl.z);
	}

	void respawn(size_t peer, Player &pl)
	{
		pl.x = m_spawn[0];
		pl.y = m_spawn[1];
		pl.z = m_spawn[2];
		pl.hp = HP_MAX;
		pl.breath = BREATH_MAX;
		pl.placed = true;
		send_position(peer, pl);
		send_stats(peer, pl);
	}

	void send_position(size_t peer, const Player &pl)
	{
		std::ostringstream os;
		os<<pl.x<<" "<<pl.y<<" "<<pl.z<<" "<<pl.yaw;
		send(peer, "skeldat:position", os.str());
	}

	void send_stats(size_t peer, const Player &pl)
	{
		send(peer, "skeldat:stats", itos(pl.hp)+" "+itos(pl.breath));
	}

	void send_time(size_t peer)
	{
		std::ostringstream os;
		os<<m_day<<" "<<(1.0 / DAY_SECONDS);
		send(peer, "skeldat:time", os.str());
	}

	static ss_ list_text(const ss_ &name, const sv_<Stack> &l)
	{
		ss_ s = name+"=";
		for(size_t i = 0; i < l.size(); i++)
			s += (i ? "|" : "")+l[i].str();
		return s+"\n";
	}

	void send_inventory(size_t peer, const Player &pl)
	{
		Stack grid[9];
		for(int i = 0; i < 9; i++)
			grid[i] = pl.craft[i];
		const skeldat::Recipe *r = m_game.craft(grid);
		sv_<Stack> preview(1);
		if(r)
			preview[0] = Stack::parse(r->output);
		send(peer, "skeldat:inv", list_text("main", pl.main)+
				list_text("craft", pl.craft)+
				list_text("craftresult", pl.craftresult)+
				list_text("craftpreview", preview));
	}

	void send_furnace(const ss_ &at)
	{
		auto it = m_furnaces.find(at);
		if(it == m_furnaces.end())
			return;
		const Furnace &f = it->second;
		std::ostringstream os;
		os<<at<<"\n"<<list_text("src", {f.src})<<list_text("fuel", {f.fuel})
				<<list_text("dst", {f.dst});
		for(auto &pair : m_players)
			if(pair.second.open == at)
				send(pair.first, "skeldat:node_inv", os.str());
	}

	// What the client needs to know of the items: what they look like, how
	// they stack, what they dig and how fast; and the groups of the nodes
	// for the dig times. A line each, tab-separated.
	ss_ items_text()
	{
		auto caps = [](const sv_<skeldat::Cap> &cs){
			std::ostringstream os;
			for(const skeldat::Cap &c : cs)
				os<<c.group<<":"<<c.times[1]<<","<<c.times[2]<<","
						<<c.times[3]<<":"<<c.uses<<";";
			return os.str();
		};
		std::ostringstream os;
		os<<"hand\t"<<caps(m_game.hand.caps)<<"\n";
		for(auto &pair : m_game.items){
			const skeldat::ItemDef &d = pair.second;
			os<<"item\t"<<d.name<<"\t"<<d.desc<<"\t"<<d.image<<"\t"
					<<d.stack_max<<"\t"<<caps(d.caps)<<"\t"<<d.eat<<"\n";
		}
		for(const skeldat::NodeDef &n : m_game.nodes){
			os<<"node\t"<<n.name<<"\t";
			for(auto &g : n.groups)
				os<<g.first<<"="<<g.second<<";";
			os<<"\n";
		}
		return os.str();
	}

	void on_client_disconnected(const network::OldClient &old)
	{
		const size_t peer = old.info.id;
		auto it = m_players.find(peer);
		if(it != m_players.end()){
			save_player(it->second);
			m_players.erase(it);
		}
		m_shown.erase(peer);
		m_waiting.erase(peer);
		m_load_points_dirty = true;
	}

	void save_player(const Player &pl)
	{
		if(m_save && pl.placed)
			m_save->store("skeldat_players")->set(pl.name, pl.save());
	}

	void save()
	{
		if(!m_save)
			return;
		storage::Store *ps = m_save->store("skeldat_players");
		ps->batch([&](){
			for(auto &pair : m_players)
				if(pair.second.placed)
					ps->set(pair.second.name, pair.second.save());
		});
		storage::Store *bs = m_save->store("skeldat_bones");
		bs->batch([&](){
			for(auto &pair : m_sections){
				pair.second = m_world_t;
				bs->set(pair.first, dtos(m_world_t));
			}
		});
		m_store->batch([&](){
			std::ostringstream os;
			os<<m_day;
			m_store->set("day", os.str());
			m_store->set("world_t", dtos(m_world_t));
			for(auto &pair : m_furnaces)
				m_store->set("furnace/"+pair.first, pair.second.save());
		});
	}

	//
	// What a player does
	//

	VoxelInstance voxel_at(int x, int y, int z)
	{
		VoxelInstance v(0);
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			v = w->get_voxel(pv::Vector3DInt32(x, y, z), true);
		});
		return v;
	}
	uint32_t id_at(int x, int y, int z)
	{
		return m_format.id.get(voxel_at(x, y, z).data);
	}
	int bones_at(int x, int y, int z)
	{
		interface::VoxelSample v;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			v = w->get_sample(pv::Vector3DInt32(x, y, z), true);
		});
		return (int)m_bones.get(v);
	}
	// The bones stay with what is there, and go with it when it is dug
	void set_node(int x, int y, int z, uint32_t id, uint32_t param = 0)
	{
		const pv::Vector3DInt32 p(x, y, z);
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			interface::VoxelSample v = w->get_sample(p, true);
			uint32_t &word = v.planes[0];
			word = 0;
			m_format.id.set(word, id);
			m_format.param.set(word, param);
			if(id == ID_AIR)
				m_bones.set(v, 0);
			w->set_sample(p, v);
		});
	}

	// From the player's eyes to the middle of the voxel
	bool reaches(const Player &pl, int x, int y, int z)
	{
		const float dx = x - pl.x, dy = y - (pl.y + 1.625f), dz = z - pl.z;
		return std::sqrt(dx * dx + dy * dy + dz * dz) <= REACH;
	}

	void on_game_packet(const network::Packet &packet)
	{
		auto it = m_players.find(packet.sender);
		if(it == m_players.end())
			return;
		const size_t peer = packet.sender;
		Player &pl = it->second;
		const ss_ what = packet.name.substr(8); // after "skeldat:"
		std::istringstream is(packet.data);
		if(what == "respawn"){
			if(pl.hp <= 0)
				respawn(peer, pl);
			return;
		}
		if(pl.hp <= 0)
			return; // the dead do nothing else
		if(what == "pos"){
			const int sx = (int)std::floor(pl.x / 16),
					sz = (int)std::floor(pl.z / 16),
					sy = (int)std::floor(pl.y / 16);
			is>>pl.x>>pl.y>>pl.z>>pl.yaw;
			if(sx != (int)std::floor(pl.x / 16) ||
					sz != (int)std::floor(pl.z / 16) ||
					sy != (int)std::floor(pl.y / 16))
				m_load_points_dirty = true;
		} else if(what == "wield"){
			is>>pl.wield;
			pl.wield = std::max(0, std::min(8, pl.wield));
		} else if(what == "dig_start"){
			int x, y, z;
			if(is>>x>>y>>z){
				pl.dig_at = pos_key(x, y, z);
				pl.dig_t0 = m_time;
			}
		} else if(what == "dig"){
			int x, y, z;
			if(is>>x>>y>>z)
				dig(peer, pl, x, y, z);
		} else if(what == "place"){
			int x, y, z;
			if(is>>x>>y>>z)
				place(peer, pl, x, y, z);
		} else if(what == "use"){
			Stack &st = pl.main[pl.wield];
			const skeldat::ItemDef *d = m_game.item(st.name);
			if(d && d->eat > 0 && pl.hp < HP_MAX){
				pl.hp = std::min(HP_MAX, pl.hp + d->eat);
				st.take(1);
				log_i(MODULE, "skeldat: %s eats %s", cs(pl.name), cs(d->name));
				send_inventory(peer, pl);
				send_stats(peer, pl);
			}
		} else if(what == "open"){
			int x, y, z;
			pl.open = "";
			if(is>>x>>y>>z && reaches(pl, x, y, z)){
				const skeldat::NodeDef *n = node_of(id_at(x, y, z));
				if(n && (n->name == "skeldat:table" ||
						n->name.compare(0, 15, "skeldat:furnace") == 0)){
					pl.open = pos_key(x, y, z);
					if(n->name != "skeldat:table"){
						m_furnaces[pl.open]; // one that predates its record
						send_furnace(pl.open);
					}
				}
			}
		} else if(what == "close"){
			pl.open = "";
		} else if(what == "move"){
			int count = 0, fi = 0, ti = 0;
			ss_ floc, flist, tloc, tlist;
			if(is>>count>>floc>>flist>>fi>>tloc>>tlist>>ti)
				move(peer, pl, count, floc, flist, fi, tloc, tlist, ti);
		} else if(what == "craft"){
			craft(peer, pl);
		} else if(what == "fall"){
			float speed = 0;
			if(is>>speed && speed > FALL_TOLERANCE)
				hurt(peer, pl, std::min(HP_MAX, (int)(speed - FALL_TOLERANCE)),
						"falls");
		}
	}

	void hurt(size_t peer, Player &pl, int damage, const char *how)
	{
		if(damage <= 0 || pl.hp <= 0)
			return;
		pl.hp = std::max(0, pl.hp - damage);
		log_i(MODULE, "skeldat: %s %s, %d hp left", cs(pl.name), how, pl.hp);
		send_stats(peer, pl);
	}

	void dig(size_t peer, Player &pl, int x, int y, int z)
	{
		const ss_ at = pos_key(x, y, z);
		const uint32_t id = id_at(x, y, z);
		const skeldat::NodeDef *n = node_of(id);
		Stack &tool = pl.main[pl.wield];
		const skeldat::Cap *cap = nullptr;
		const float time = n ? m_game.dig_time(tool.name, *n, &cap) : -1;
		// A quarter less than the time, for the network's lag
		if(!n || time < 0 || !reaches(pl, x, y, z) || pl.dig_at != at ||
				m_time - pl.dig_t0 < time * 0.75f){
			log_i(MODULE, "skeldat: %s's dig at %s refused", cs(pl.name),
					cs(at));
			return;
		}
		if(n->name.compare(0, 15, "skeldat:furnace") == 0){
			auto f = m_furnaces.find(at);
			if(f != m_furnaces.end() && !(f->second.src.empty() &&
					f->second.fuel.empty() && f->second.dst.empty()))
				return; // not while it holds anything
			m_furnaces.erase(at);
			if(m_store)
				m_store->remove("furnace/"+at);
		}
		pl.dig_at = "";
		const int bones = bones_at(x, y, z);
		set_node(x, y, z, ID_AIR);
		if(cap && cap->uses > 0){
			tool.wear += skeldat::WEAR_MAX / cap->uses;
			if(tool.wear >= skeldat::WEAR_MAX)
				tool = Stack();
		}
		// What it drops goes straight into the inventory
		// simplified: no items on the ground; what does not fit is lost
		Stack drop;
		if(bones > skeldat::bones::NO_DROP)
			; // bone-ridden: nothing
		else if(n->drop == "")
			drop = Stack(n->name);
		else if(n->drop != "-" && (n->drop_rarity <= 1 ||
				m_rand() % n->drop_rarity == 0))
			drop = Stack::parse(n->drop);
		if(!drop.empty())
			m_game.add(pl.main, drop);
		log_i(MODULE, "skeldat: %s digs %s at %s, bones %d%s", cs(pl.name),
				cs(n->name), cs(at), bones, bones > skeldat::bones::NO_DROP ?
				", dropping nothing" : "");
		send_inventory(peer, pl);
	}

	void place(size_t peer, Player &pl, int x, int y, int z)
	{
		Stack &st = pl.main[pl.wield];
		const uint32_t id = id_of(st.name);
		const skeldat::NodeDef *n = node_of(id);
		const skeldat::NodeDef *here = node_of(id_at(x, y, z));
		const uint32_t here_id = id_at(x, y, z);
		// Into air or water, beside something, out of everyone's way
		bool beside = false;
		static const int D[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0},
				{0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
		for(auto &d : D){
			const uint32_t b = id_at(x + d[0], y + d[1], z + d[2]);
			beside = beside || (b != ID_AIR && b != ID_IGNORE &&
					b != id_of("skeldat:water_source"));
		}
		if(!n || !(here_id == ID_AIR || (here && here->shape ==
				skeldat::LIQUID)) || !beside || !reaches(pl, x, y, z))
			return;
		if(n->shape != skeldat::TORCH){
			for(auto &pair : m_players){
				const Player &o = pair.second;
				if(o.hp > 0 && x + 0.5f > o.x - 0.3f && x - 0.5f < o.x + 0.3f &&
						z + 0.5f > o.z - 0.3f && z - 0.5f < o.z + 0.3f &&
						y + 0.5f > o.y && y - 0.5f < o.y + 1.75f)
					return;
			}
		}
		// Facing the player: the yaw is the client's, 0 towards +z
		uint32_t param = 0;
		if(n->facedir){
			const int q = ((int)std::floor((pl.yaw + 45) / 90) % 4 + 4) % 4;
			// Looking towards +z the front faces -z, which is facedir 0
			static const uint32_t FACE[4] = {0, 1, 2, 3};
			param = FACE[q];
		}
		set_node(x, y, z, id, param);
		log_i(MODULE, "skeldat: %s places %s at %s", cs(pl.name),
				cs(n->name), cs(pos_key(x, y, z)));
		if(n->name == "skeldat:furnace")
			m_furnaces[pos_key(x, y, z)] = Furnace();
		st.take(1);
		send_inventory(peer, pl);
	}

	// A slot by where it is: "me" and a list of the player's own, or
	// "x,y,z" and a list of the furnace the player has open
	Stack* slot(Player &pl, const ss_ &loc, const ss_ &list, int index,
			bool put)
	{
		index--;
		if(loc == "me"){
			if(list == "main" && index >= 0 && index < 36)
				return &pl.main[index];
			// Outside the inventory's own 2x2 only at a table
			if(list == "craft" && index >= 0 && index < 9 &&
					(index % 3 < 2 && index / 3 < 2 || at_table(pl)))
				return &pl.craft[index];
			if(list == "craftresult" && index == 0 && !put)
				return &pl.craftresult[0];
			return nullptr;
		}
		if(loc != pl.open || index != 0)
			return nullptr;
		auto it = m_furnaces.find(loc);
		if(it == m_furnaces.end())
			return nullptr;
		if(list == "src")
			return &it->second.src;
		if(list == "fuel")
			return &it->second.fuel;
		if(list == "dst" && !put)
			return &it->second.dst;
		return nullptr;
	}

	bool at_table(Player &pl)
	{
		if(pl.open.empty())
			return false;
		int x, y, z;
		char c;
		std::istringstream is(pl.open);
		if(!(is>>x>>c>>y>>c>>z) || !reaches(pl, x, y, z))
			return false;
		return id_at(x, y, z) == id_of("skeldat:table");
	}

	void move(size_t peer, Player &pl, int count, const ss_ &floc,
			const ss_ &flist, int fi, const ss_ &tloc, const ss_ &tlist,
			int ti)
	{
		Stack *from = slot(pl, floc, flist, fi, false);
		Stack *to = slot(pl, tloc, tlist, ti, true);
		if(!from || !to || !m_game.move(*from, *to, count))
			return;
		send_inventory(peer, pl);
		if(floc != "me")
			send_furnace(floc);
		if(tloc != "me" && tloc != floc)
			send_furnace(tloc);
	}

	void craft(size_t peer, Player &pl)
	{
		Stack grid[9];
		bool outside = false;
		for(int i = 0; i < 9; i++){
			grid[i] = pl.craft[i];
			outside = outside || (!grid[i].empty() && (i % 3 == 2 || i / 3 == 2));
		}
		const skeldat::Recipe *r = m_game.craft(grid);
		if(!r || (outside && !at_table(pl)))
			return;
		Stack out = Stack::parse(r->output);
		Stack &res = pl.craftresult[0];
		if(!res.empty() && (res.name != out.name ||
				res.count + out.count > m_game.stack_max(out.name)))
			return;
		for(Stack &s : pl.craft)
			if(!s.empty())
				s.take(1);
		if(res.empty())
			res = out;
		else
			res.count += out.count;
		log_i(MODULE, "skeldat: %s crafts %s", cs(pl.name), cs(out.str()));
		send_inventory(peer, pl);
	}

	//
	// Time
	//

	void on_tick(const interface::TickEvent &event)
	{
		if(!m_scene)
			return;
		m_time += event.dtime;
		m_world_t += event.dtime;
		m_day = std::fmod(m_day + event.dtime / DAY_SECONDS, 1.0);
		step_bones(event.dtime);
		if(m_load_points_dirty)
			update_load_points();
		m_send_t += event.dtime;
		if(m_send_t >= 0.2f){
			m_send_t = 0;
			send_players();
		}
		m_breath_t += event.dtime;
		if(m_breath_t >= 1){
			m_breath_t = 0;
			step_breath();
		}
		m_furnace_t += event.dtime;
		if(m_furnace_t >= 1){
			m_furnace_t = 0;
			for(auto &pair : m_furnaces)
				step_furnace(pair.first, pair.second);
		}
		m_save_t += event.dtime;
		if(m_save_t >= 10){
			m_save_t = 0;
			save();
			// The pace, for whoever tunes it
			log_i(MODULE, "skeldat: bones: %zu expansions so far, %zu voxels "
					"changed, %zu sections loaded, %zu owed a catch-up",
					m_expansions, m_expand_changed, m_sections.size(),
					m_catchup.size());
			for(auto &pair : m_players)
				send_time(pair.first);
		}
	}

	// Where the others are, to everyone: "name x y z yaw" a line
	void send_players()
	{
		for(auto &to : m_players){
			std::ostringstream os;
			for(auto &pair : m_players){
				const Player &o = pair.second;
				if(pair.first != to.first && o.placed && o.hp > 0)
					os<<o.name<<" "<<o.x<<" "<<o.y<<" "<<o.z<<" "<<o.yaw
							<<"\n";
			}
			send(to.first, "skeldat:players", os.str());
		}
	}

	// Drowning: a breath a second with the head in water, then a hit
	// point; two breaths back a second out of it
	void step_breath()
	{
		const uint32_t water = id_of("skeldat:water_source");
		for(auto &pair : m_players){
			Player &pl = pair.second;
			if(!pl.placed || pl.hp <= 0)
				continue;
			const bool under = id_at((int)std::floor(pl.x + 0.5f),
					(int)std::floor(pl.y + 1.6f + 0.5f),
					(int)std::floor(pl.z + 0.5f)) == water;
			const int was = pl.breath;
			if(under && pl.breath > 0)
				pl.breath--;
			else if(under)
				hurt(pair.first, pl, 1, "drowns");
			else
				pl.breath = std::min(BREATH_MAX, pl.breath + 2);
			if(pl.breath != was)
				send_stats(pair.first, pl);
		}
	}

	// A second of a furnace: fuel taken when there is something to cook,
	// the cooking done when its time is up
	void step_furnace(const ss_ &at, Furnace &f)
	{
		const skeldat::Cooking *c = f.src.empty() ? nullptr :
				m_game.cooks(f.src.name);
		const bool cookable = c && (f.dst.empty() || (f.dst.name == c->output
				&& f.dst.count < m_game.stack_max(c->output)));
		const bool before = f.fuel_left > 0;
		bool changed = false;
		if(cookable && f.fuel_left <= 0){
			auto fuel = m_game.fuel.find(f.fuel.name);
			if(!f.fuel.empty() && fuel != m_game.fuel.end()){
				f.fuel_left = fuel->second;
				f.fuel.take(1);
				changed = true;
			}
		}
		float t = 0;
		if(f.fuel_left > 0){
			f.fuel_left -= 1;
			if(cookable){
				t = f.src_time + 1;
				if(t >= c->time){
					if(f.dst.empty())
						f.dst = Stack(c->output);
					else
						f.dst.count++;
					f.src.take(1);
					log_i(MODULE, "skeldat: the furnace at %s made %s",
							cs(at), cs(c->output));
					t = 0;
					changed = true;
				}
			}
		}
		f.src_time = t;
		if(changed)
			send_furnace(at);
		if(before != (f.fuel_left > 0)){
			int x, y, z;
			char ch;
			std::istringstream is(at);
			if(!(is>>x>>ch>>y>>ch>>z))
				return;
			// The front lit or not, the way it faces kept
			const VoxelInstance v = voxel_at(x, y, z);
			const uint32_t id = m_format.id.get(v.data);
			const uint32_t want = id_of(f.fuel_left > 0 ?
					"skeldat:furnace_active" : "skeldat:furnace");
			if(id != want && (id == id_of("skeldat:furnace") ||
					id == id_of("skeldat:furnace_active")))
				set_node(x, y, z, want, m_format.param.get(v.data));
		}
	}
};

void Module::box_quads(sv_<interface::VoxelQuad> &out, const float *b)
{
	// builtin/luanti's add_box_quads(): six quads, counter-clockwise seen
	// from outside, each wearing the part of its tile it covers
	float x0 = b[0], y0 = b[1], z0 = b[2], x1 = b[3], y1 = b[4], z1 = b[5];
	const float ux0 = x0 + 0.5f, ux1 = x1 + 0.5f;
	const float uy0 = y0 + 0.5f, uy1 = y1 + 0.5f;
	const float uz0 = z0 + 0.5f, uz1 = z1 + 0.5f;
	auto quad = [&](uint8_t tile,
			float ax, float ay, float az, float au, float av,
			float bx, float by, float bz, float bu, float bv,
			float cx, float cy, float cz, float cu, float cv,
			float dx, float dy, float dz, float du, float dv){
		interface::VoxelQuad q;
		const float p[4][3] = {{ax, ay, az}, {bx, by, bz},
				{cx, cy, cz}, {dx, dy, dz}};
		const float uv[4][2] = {{au, av}, {bu, bv}, {cu, cv}, {du, dv}};
		for(size_t i = 0; i < 4; i++){
			for(size_t j = 0; j < 3; j++)
				q.p[i][j] = p[i][j];
			q.uv[i][0] = uv[i][0];
			q.uv[i][1] = uv[i][1];
		}
		q.tile = tile;
		out.push_back(q);
	};
	quad(0, x0, y1, z1, ux0, 1-uz1,  x1, y1, z1, ux1, 1-uz1,
			x1, y1, z0, ux1, 1-uz0,  x0, y1, z0, ux0, 1-uz0);
	quad(1, x0, y0, z0, ux0, uz0,    x1, y0, z0, ux1, uz0,
			x1, y0, z1, ux1, uz1,    x0, y0, z1, ux0, uz1);
	quad(2, x1, y0, z1, uz1, 1-uy0,  x1, y0, z0, uz0, 1-uy0,
			x1, y1, z0, uz0, 1-uy1,  x1, y1, z1, uz1, 1-uy1);
	quad(3, x0, y0, z0, 1-uz0, 1-uy0, x0, y0, z1, 1-uz1, 1-uy0,
			x0, y1, z1, 1-uz1, 1-uy1, x0, y1, z0, 1-uz0, 1-uy1);
	quad(4, x0, y0, z1, 1-ux0, 1-uy0, x1, y0, z1, 1-ux1, 1-uy0,
			x1, y1, z1, 1-ux1, 1-uy1, x0, y1, z1, 1-ux0, 1-uy1);
	quad(5, x1, y0, z0, ux1, 1-uy0,  x0, y0, z0, ux0, 1-uy0,
			x0, y1, z0, ux0, 1-uy1,  x1, y1, z0, ux1, 1-uy1);
}

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
