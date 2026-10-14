// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "ground_plane_lighting/api.h"
#include "network/api.h"
#include "client_file/api.h"
#include "voxelworld/api.h"
#include "replicate/api.h"
#include "network/api.h"
#include "main_context/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/block.h"
#include "interface/voxel_volume.h"
#include "interface/polyvox_numeric.h"
#include "interface/polyvox_cereal.h"
#include "interface/os.h"
#include <PolyVoxCore/RawVolume.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/tuple.hpp>
#include <deque>
#include <algorithm>
#include <climits>
#define MODULE "ground_plane_lighting"

using interface::Event;
namespace magic = Urho3D;
namespace pv = PolyVox;
using namespace Urho3D;
using interface::VoxelInstance;
using interface::container_coord;
using interface::container_coord16;

#include "interface/polyvox_std.h"

namespace ground_plane_lighting {

// Y-seethrough data of a sector (size defined by voxelworld)
struct YSTSector
{
	pv::Vector<2, int16_t> sector_p; // In sectors
	pv::Vector<2, int16_t> sector_size; // In voxels
	sp_<pv::RawVolume<int32_t>> volume; // Voxel columns (region in global coords)

	YSTSector():
		sector_size(0, 0) // This is used to detect uninitialized instance
	{}
	YSTSector(const pv::Vector<2, int16_t> &sector_p,
			const pv::Vector<2, int16_t> &sector_size):
		sector_p(sector_p),
		sector_size(sector_size),
		volume(new pv::RawVolume<int32_t>(pv::Region(
				sector_p.getX() * sector_size.getX(),
				0,
				sector_p.getY() * sector_size.getY(),
				sector_p.getX() * sector_size.getX() + sector_size.getX() - 1,
				0,
				sector_p.getY() * sector_size.getY() + sector_size.getY() - 1
				)))
	{
		pv::Region region = volume->getEnclosingRegion();
		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();
		/*log_v(MODULE, "YSTSector volume lc=" PV3I_FORMAT ", uc=" PV3I_FORMAT
				", size=%zu", PV3I_PARAMS(lc), PV3I_PARAMS(uc),
				volume->m_dataSize);*/
		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				volume->setVoxelAt(x, 0, z, INT_MIN);
			}
		}
	}
};

// Global Y-seethrough map
struct GlobalYSTMap
{
	pv::Vector<2, int16_t> m_sector_size;
	sm_<pv::Vector<2, int16_t>, YSTSector> m_sectors;
	// Cache of last used sectors (add to end, remove from beginning)
	std::deque<YSTSector*> m_last_used_sectors;
	// Set of sectors that have been modified
	// (as a sorted array in descending order)
	sv_<YSTSector*> m_dirty_sectors;

	GlobalYSTMap(const pv::Vector<2, int16_t> &sector_size):
		m_sector_size(sector_size)
	{}

	YSTSector* get_sector(pv::Vector<2, int16_t> &sector_p, bool create)
	{
		// Check cache
		for(YSTSector *sector : m_last_used_sectors){
			if(sector->sector_p == sector_p)
				return sector;
		}
		// Not in cache
		YSTSector *sector = nullptr;
		auto it = m_sectors.find(sector_p);
		if(it == m_sectors.end()){
			if(!create)
				return nullptr;
			sector = &m_sectors[sector_p];
			*sector = YSTSector(sector_p, m_sector_size);
		} else {
			sector = &it->second;
		}
		// Add to cache and return
		m_last_used_sectors.push_back(sector);
		if(m_last_used_sectors.size() > 2) // 2 is maybe optimal-ish
			m_last_used_sectors.pop_front();
		return sector;
	}

	pv::Vector<2, int16_t> get_sector_p(int32_t x, int32_t z)
	{
		if(m_sector_size.getX() == 0)
			throw Exception("GlobalYSTMap not initialized");
		return container_coord16(pv::Vector<2, int32_t>(x, z), m_sector_size);
	}

	void set_yst(int32_t x, int32_t z, int32_t yst)
	{
		auto sector_p = get_sector_p(x, z);
		YSTSector *sector = get_sector(sector_p, true);
		sector->volume->setVoxelAt(x, 0, z, yst);

		// Set sector dirty flag
		auto it = std::lower_bound(m_dirty_sectors.begin(),
				m_dirty_sectors.end(), sector,
				std::greater<YSTSector*>()); // position in descending order
		if(it == m_dirty_sectors.end() || *it != sector)
			m_dirty_sectors.insert(it, sector);
	}

	int32_t get_yst(int32_t x, int32_t z)
	{
		auto sector_p = get_sector_p(x, z);
		YSTSector *sector = get_sector(sector_p, false);
		if(!sector)
			return INT_MIN;
		return sector->volume->getVoxelAt(x, 0, z);
	}
};

struct CInstance: public ground_plane_lighting::Instance
{
	interface::Server *m_server;
	SceneReference m_scene_ref;
	up_<GlobalYSTMap> m_global_yst;

	// Clients that are ready to receive things (by peer id)
	set_<int> m_clients_initialized;

	CInstance(interface::Server *server, SceneReference scene_ref):
		m_server(server),
		m_scene_ref(scene_ref)
	{
		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			voxelworld::Instance *world =
					ivoxelworld->get_instance(m_scene_ref);
			pv::Vector3DInt16 section_size = world->get_section_size_voxels();
			pv::Vector<2, int16_t> sector_size(
					section_size.getX(), section_size.getZ());
			m_global_yst.reset(new GlobalYSTMap(sector_size));
		});
	}

	~CInstance()
	{
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("replicate:peer_joined_scene", on_peer_joined_scene,
				replicate::PeerJoinedScene);
		EVENT_TYPEN("replicate:peer_left_scene", on_peer_left_scene,
				replicate::PeerLeftScene);
		EVENT_TYPEN("voxelworld:node_volume_updated",
				on_node_volume_updated, voxelworld::NodeVolumeUpdated)
	}

	void initial_update()
	{
		// TODO
	}

	void on_start()
	{
		initial_update();
	}

	void on_unload()
	{
	}

	void on_continue()
	{
		initial_update();
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(!m_global_yst->m_dirty_sectors.empty()){
			sv_<YSTSector*> dirty_sectors;
			dirty_sectors.swap(m_global_yst->m_dirty_sectors);
			for(YSTSector *sector : dirty_sectors){
				ss_ s = interface::serialize_volume_compressed(*sector->volume);
				std::ostringstream os(std::ios::binary);
				{
					cereal::PortableBinaryOutputArchive ar(os);
					ar(sector->sector_p);
					ar(s);
				}
				network::access(m_server, [&](network::Interface *inetwork){
					for(auto &peer: m_clients_initialized){
						inetwork->send(peer, "ground_plane_lighting:update",
								os.str());
					}
				});
			}
		}
	}

	void on_peer_joined_scene(const replicate::PeerJoinedScene &event)
	{
		int peer = event.peer;
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "core:run_script",
					"require(\"buildat/module/ground_plane_lighting\")");
		});
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(m_global_yst->m_sector_size);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "ground_plane_lighting:init", os.str());
		});

		m_clients_initialized.insert(peer);
		send_initial_sectors(peer);
	}

	void on_peer_left_scene(const replicate::PeerLeftScene &event)
	{
		m_clients_initialized.erase(event.peer);
	}

	void on_node_volume_updated(const voxelworld::NodeVolumeUpdated &event)
	{
		try {
			if(!event.is_static_chunk)
				return;
			if(event.scene != m_scene_ref)
				return;
			log_v(MODULE, "Checking ground level in chunk " PV3I_FORMAT,
					PV3I_PARAMS(event.chunk_p));
			const pv::Vector3DInt32 &chunk_p = event.chunk_p;
			voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
			{
				voxelworld::Instance *world =
						check(ivoxelworld->get_instance(m_scene_ref));
				interface::VoxelRegistry *voxel_reg = world->get_voxel_reg();
				//const auto &chunk_size_voxels = world->get_chunk_size_voxels();
				pv::Region chunk_region =
						world->get_chunk_region_voxels(chunk_p);

				auto lc = chunk_region.getLowerCorner();
				auto uc = chunk_region.getUpperCorner();
				//log_nv(MODULE, "yst=[");
				for(int z = lc.getZ(); z <= uc.getZ(); z++){
					for(int x = lc.getX(); x <= uc.getX(); x++){
						int32_t yst0 = get_yst(x, z);
						if(yst0 > uc.getY()){
							// Y-seethrough doesn't reach here
							continue;
						}
						int y = uc.getY();
						for(;; y--){
							VoxelInstance v = world->get_voxel(
									pv::Vector3DInt32(x, y, z), true);
							if(v.legacy06_id() == interface::VOXELTYPEID_UNDEFINED){
								// NOTE: This leaves the chunks below unhandled;
								// there would have to be some kind of a dirty
								// flag based on which this seach would be
								// continued at a later point when the chunk
								// gets loaded
								break;
							}
							const auto *def = voxel_reg->get_cached(v);
							if(!def)
								throw Exception(ss_()+"Undefined voxel: "+
										itos(v.legacy06_id()));
							bool light_passes = (!def || !def->physically_solid);
							if(!light_passes)
								break;
						}
						// The first voxel downwards from the top of the world that
						// doesn't pass light
						int32_t yst1 = y;
						//log_nv(MODULE, "%i -> %i, ", yst0, yst1);
						set_yst(x, z, yst1);
					}
				}
				//log_v(MODULE, "]");
			});
		} catch(NullptrCatch &e){
			// Something was probably deleted or unloaded
			log_v(MODULE, "NullptrCatch: %s", e.what());
		}
	}

	void send_initial_sectors(int peer)
	{
		for(auto &pair : m_global_yst->m_sectors){
			YSTSector *sector = &pair.second;
			ss_ s = interface::serialize_volume_compressed(*sector->volume);
			std::ostringstream os(std::ios::binary);
			{
				cereal::PortableBinaryOutputArchive ar(os);
				ar(sector->sector_p);
				ar(s);
			}
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(peer, "ground_plane_lighting:update", os.str());
			});
		}
	}

	// Interface

	void set_yst(int32_t x, int32_t z, int32_t yst)
	{
		return m_global_yst->set_yst(x, z, yst);
	}

	int32_t get_yst(int32_t x, int32_t z)
	{
		return m_global_yst->get_yst(x, z);
	}
};

struct Module: public interface::Module, public ground_plane_lighting::Interface
{
	interface::Server *m_server;

	sm_<SceneReference, up_<CInstance>> m_instances;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
	}

	~Module()
	{
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("replicate:peer_joined_scene"));
		m_server->sub_event(this, Event::t("replicate:peer_left_scene"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("voxelworld:node_volume_updated"));
		m_server->sub_event(this, Event::t("main_context:scene_deleted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		dispatch(type, p);
		for(auto &pair : m_instances){
			up_<CInstance> &instance = pair.second;
			instance->event(type, p);
		}
	}

	// The handlers' list, which returns at its match
	void dispatch(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("voxelworld:node_volume_updated",
				on_node_volume_updated, voxelworld::NodeVolumeUpdated)
		EVENT_TYPEN("main_context:scene_deleted", on_scene_deleted,
				main_context::SceneDeleted);
	}

	void on_start()
	{
	}

	void on_unload()
	{
	}

	void on_continue()
	{
	}

	void on_tick(const interface::TickEvent &event)
	{
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
	}

	void on_node_volume_updated(const voxelworld::NodeVolumeUpdated &event)
	{
	}

	void on_scene_deleted(const main_context::SceneDeleted &event)
	{
		// Drop instance of the deleted scene (there should be only one, but
		// loop through all of them just for robustness)
		for(auto it = m_instances.begin(); it != m_instances.end();){
			auto current_it = it++;
			up_<CInstance> &instance = current_it->second;
			if(instance->m_scene_ref == event.scene){
				m_instances.erase(current_it);
			}
		}
	}

	// Interface

	void create_instance(SceneReference scene_ref)
	{
		auto it = m_instances.find(scene_ref);
		// TODO: Is an exception the best way to handle this?
		if(it != m_instances.end())
			throw Exception("create_instance(): Scene already has gpl");

		up_<CInstance> instance(new CInstance(m_server, scene_ref));
		m_instances[scene_ref] = std::move(instance);
	}

	void delete_instance(SceneReference scene_ref)
	{
		auto it = m_instances.find(scene_ref);
		if(it == m_instances.end())
			throw Exception("delete_instance(): Scene does not have gpl");
		m_instances.erase(it);
	}

	Instance* get_instance(SceneReference scene_ref)
	{
		auto it = m_instances.find(scene_ref);
		if(it == m_instances.end())
			return nullptr;
		return it->second.get();
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_ground_plane_lighting(
			interface::Server *server){
		return (void*)(new Module(server));
	}
}
}

// vim: set noet ts=4 sw=4:
