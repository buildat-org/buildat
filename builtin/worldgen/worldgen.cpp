#include <algorithm>
#include <cstdlib>
#include "core/log.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/mesh.h"
#include "interface/voxel.h"
#include "interface/voxel_volume.h"
#include "interface/thread.h"
#include <mutex>
#include <map>
#include "interface/semaphore.h"
#include "interface/os.h"
#include <Vector2.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/unordered_map.hpp>
#include <cereal/types/vector.hpp>
#include <deque>
#include <set>
#include <tuple>
#define MODULE "worldgen"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::Event;
using interface::VoxelInstance;

#include "interface/polyvox_std.h"

#include "interface/polyvox_cereal.h"

namespace worldgen {

struct Module;

struct GenerateThread: public interface::ThreadedThing
{
	Module *m_module = nullptr;

	GenerateThread(Module *module):
		m_module(module)
	{}

	void run(interface::Thread *thread);
	void on_crash(interface::Thread *thread);
};

struct CInstance;

// One section of one instance: what has to be known before generating it
struct GenerateTask
{
	SceneReference scene_ref;
	pv::Vector3DInt16 section_p = pv::Vector3DInt16(0, 0, 0);
	GeneratorInterface *generator = nullptr;
	// The instance's generator epoch when the task was taken; see
	// CInstance::m_epoch
	uint64_t epoch = 0;
	CInstance *instance = nullptr;
};

struct CInstance: public worldgen::Instance
{
	interface::Server *m_server;
	SceneReference m_scene_ref;

	up_<GeneratorInterface> m_generator;
	// Bumped whenever m_generator is replaced, under the module's
	// m_generate_mutex: a task taken before that is not run, because its
	// generator is gone. A generator's code is often another module's,
	// which unloads after this one has stopped using it -- not while
	// generate() is still running in it.
	std::mutex *m_generate_mutex = nullptr;
	uint64_t m_epoch = 0;
	bool m_enabled = false;

	std::deque<pv::Vector3DInt16> m_queued_sections;
	pv::Vector3DInt16 m_last_taken = pv::Vector3DInt16(0, 0, 0);
	// Counts the takes, for the pinned sections' share; see
	// take_next_section()
	size_t m_takes = 0;
	// Taken off the queue and not yet done (generate_and_merge()); under
	// the module like the queue
	size_t m_taken = 0;

	CInstance(interface::Server *server, SceneReference scene_ref):
		m_server(server),
		m_scene_ref(scene_ref)
	{}

	~CInstance()
	{}

	void on_generation_request(const pv::Vector3DInt16 &section_p)
	{
		m_queued_sections.push_back(section_p);
		log_v(MODULE, "Queued section (%i, %i, %i); queue size: %zu (scene %p)",
				section_p.getX(), section_p.getY(),
				section_p.getZ(), m_queued_sections.size(), m_scene_ref);
		m_server->emit_event("worldgen:queue_modified",
				new QueueModifiedEvent(m_scene_ref, m_queued_sections.size()));
	}

	// Interface for GenerateThread

	// NOTE: on_tick() cannot be used here, because as this takes much longer
	//       than a tick, the ticks accumulate and result in nothing getting
	//       queued but instead sectors get queued in the event queue.

	// Take one section off the queue: the one nearest a player's section,
	// the oldest with no player ([FAR_SPAWN_SLOW_JOIN]: a far spawn's
	// sections waited 20 s behind the origin's). Called with the module
	// held; the generation itself is done outside it.
	// simplified: a scan of the whole queue per section; it is hundreds
	// long and a section takes a hundred milliseconds or more to generate
	bool take_next_section(const sv_<pv::Vector3DInt16> &players,
			const std::set<std::tuple<int16_t, int16_t, int16_t>> &pinned,
			pv::Vector3DInt16 *section_p_out,
			GeneratorInterface **generator_out, uint64_t *epoch_out)
	{
		if(!m_enabled || m_queued_sections.empty())
			return false;
		auto d2 = [](const pv::Vector3DInt16 &a, const pv::Vector3DInt16 &b){
			int64_t dx = a.getX() - b.getX(), dy = a.getY() - b.getY(),
					dz = a.getZ() - b.getZ();
			return dx*dx + dy*dy + dz*dz;
		};
		auto ring = [](const pv::Vector3DInt16 &a, const pv::Vector3DInt16 &b){
			return std::max({std::abs(a.getX() - b.getX()),
					std::abs(a.getY() - b.getY()), std::abs(a.getZ() - b.getZ())});
		};
		// The ring of sections around a player first, and in it the one
		// nearest the last taken ([WORLDGEN_SLOWDOWN]): a generator keeps
		// what it made for the last few sections (luanti_mapgen's chunk
		// cache). By plain distance the nearest are on opposite sides of
		// the player, taken in turn, and every chunk was made again: 5.6
		// chunks a section in a fuzz.sh walk, 3.4 by the ring.
		size_t best = 0;
		int64_t best_ring = INT64_MAX, best_last = INT64_MAX;
		// Every other take is the oldest pinned section's, a forceload's
		// or an emerge_area's, not one only held (LoadPoint::hold_only)
		// ([FORCELOAD_STARVED]): by the player's ring
		// alone one far from every player waited as long as anybody kept
		// walking into new terrain, minutes. Not the last taken: the
		// player's next one is still nearest the player's last.
		bool share = !pinned.empty() && m_takes++ % 2 == 1;
		bool found = false;
		for(size_t i = 0; share && i < m_queued_sections.size(); i++){
			const pv::Vector3DInt16 &s = m_queued_sections[i];
			if(pinned.count(std::make_tuple(s.getX(), s.getY(), s.getZ()))){
				best = i;
				found = true;
				break;
			}
		}
		for(size_t i = 0; !found && i < m_queued_sections.size() &&
				!players.empty(); i++){
			const pv::Vector3DInt16 &s = m_queued_sections[i];
			for(const pv::Vector3DInt16 &p : players){
				int64_t r = ring(s, p);
				if(r > best_ring)
					continue;
				int64_t last = d2(s, m_last_taken);
				if(r < best_ring || last < best_last){
					best_ring = r;
					best_last = last;
					best = i;
				}
			}
		}
		*section_p_out = m_queued_sections[best];
		if(!found)
			m_last_taken = *section_p_out;
		*generator_out = m_generator.get();
		*epoch_out = m_epoch;
		m_queued_sections.erase(m_queued_sections.begin() + best);
		m_taken++;
		return true;
	}

	// generate_and_merge()'s end, the section merged or not
	void on_task_done()
	{
		if(m_taken > 0)
			m_taken--;
		announce_queue_size();
	}

	void announce_queue_size()
	{
		m_server->emit_event("worldgen:queue_modified",
				new QueueModifiedEvent(m_scene_ref, m_queued_sections.size()));
	}

	// Interface

	void set_generator(GeneratorInterface *generator)
	{
		std::lock_guard<std::mutex> lock(*m_generate_mutex);
		m_epoch++;
		m_generator.reset(generator);
	}

	void enable()
	{
		m_enabled = true;
	}

	size_t get_num_sections_queued()
	{
		return m_queued_sections.size();
	}

	size_t get_num_sections_pending()
	{
		return m_queued_sections.size() + m_taken;
	}
};

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;

	sm_<SceneReference, up_<CInstance>> m_instances;
	sp_<interface::Thread> m_thread;
	interface::Semaphore m_queued_sections_sem;
	// Held while a generator runs; see CInstance::m_epoch. Nothing that
	// holds it reaches for a module, so whoever holds this module and
	// waits for it cannot deadlock with the thread.
	std::mutex m_generate_mutex;
	// Requests for a scene with no instance yet, queued when it gets one
	std::map<SceneReference, sv_<pv::Vector3DInt16>> m_early_requests;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
		m_thread.reset(interface::createThread(new GenerateThread(this)));
		m_thread->set_name("worldgen/generate");
		m_thread->start();
	}

	~Module()
	{
		m_thread->request_stop();
		m_queued_sections_sem.post();
		m_thread->join();
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("voxelworld:generation_request"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("voxelworld:generation_request",
				on_generation_request, voxelworld::GenerationRequest)
	}

	void on_start()
	{
	}

	void on_continue()
	{
	}

	void on_tick(const interface::TickEvent &event)
	{
	}

	void on_generation_request(const voxelworld::GenerationRequest &event)
	{
		auto it = m_instances.find(event.scene);
		if(it == m_instances.end()){
			// voxelworld asks as soon as its own instance exists, and the
			// game makes this one after it: a request dropped here left
			// the section asked for and never generated
			m_early_requests[event.scene].push_back(event.section_p);
			return;
		}
		up_<CInstance> &instance = it->second;
		instance->on_generation_request(event.section_p);
		m_queued_sections_sem.post();
	}

	// Interface

	void create_instance(SceneReference scene_ref)
	{
		auto it = m_instances.find(scene_ref);
		// TODO: Is an exception the best way to handle this?
		if(it != m_instances.end())
			throw Exception("create_instance(): Scene already has worldgen");

		up_<CInstance> instance(new CInstance(m_server, scene_ref));
		instance->m_generate_mutex = &m_generate_mutex;
		CInstance *created = instance.get();
		{
			std::lock_guard<std::mutex> lock(m_generate_mutex);
			m_instances[scene_ref] = std::move(instance);
		}
		auto early = m_early_requests.find(scene_ref);
		if(early != m_early_requests.end()){
			for(const pv::Vector3DInt16 &sp : early->second){
				created->on_generation_request(sp);
				m_queued_sections_sem.post();
			}
			m_early_requests.erase(early);
		}
	}

	void delete_instance(SceneReference scene_ref)
	{
		auto it = m_instances.find(scene_ref);
		if(it == m_instances.end())
			throw Exception("delete_instance(): Scene does not have worldgen");
		// Out of the map under the lock, so the thread sees it gone, and
		// destructed after it, so a generator never goes mid-generate()
		m_early_requests.erase(scene_ref);
		up_<CInstance> gone;
		{
			std::lock_guard<std::mutex> lock(m_generate_mutex);
			gone = std::move(it->second);
			m_instances.erase(it);
		}
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

	// Interface for GenerateThread. Called with no module held.
	void generate_and_merge(const GenerateTask &task)
	{
		generate_and_merge_section(task);
		// The instance may be gone by now
		worldgen::access(m_server, [&](worldgen::Interface*){
			for(auto &pair : m_instances){
				if(pair.second.get() == task.instance)
					pair.second->on_task_done();
			}
		});
	}

	void generate_and_merge_section(const GenerateTask &task)
	{
		try {
			if(!task.generator)
				return;

			// The section grown by whatever the generator needs to place a
			// thing that crosses the section boundary
			pv::Region section_region;
			voxelworld::access(m_server, task.scene_ref,
					[&](voxelworld::Instance *world)
			{
				section_region =
						world->get_section_region_voxels(task.section_p);
			});
			// Undefined is what a generator leaves where it puts nothing,
			// and it is what a volume starts as: every plane of a new one
			// reads as zero, which is VOXELTYPEID_UNDEFINED, without any of
			// them being allocated. Sized by the padding under the lock
			// below ([WORLDGEN_PADDING_RACE]: asked before it, a generator
			// replaced meanwhile was already freed)
			up_<VoxelVolume> volume_p;

			{
				// The instance may be gone by now: it is looked for under
				// the lock, and its generator used only if it is still the
				// one the task was taken with
				std::lock_guard<std::mutex> lock(m_generate_mutex);
				bool current = false;
				for(auto &pair : m_instances){
					if(pair.second.get() == task.instance &&
							task.instance->m_epoch == task.epoch)
						current = true;
				}
				if(!current){
					log_v(MODULE, "Section " PV3I_FORMAT " not generated: "
							"its generator was replaced",
							PV3I_PARAMS(task.section_p));
					return;
				}
				pv::Region region = section_region;
				pv::Vector3DInt32 pad = task.generator->get_padding_voxels();
				region.setLowerCorner(region.getLowerCorner() - pad);
				region.setUpperCorner(region.getUpperCorner() + pad);

				log_v(MODULE, "Generating section " PV3I_FORMAT " (scene %p)",
						PV3I_PARAMS(task.section_p), task.scene_ref);

				volume_p.reset(new VoxelVolume(region));
				task.generator->generate(task.scene_ref, task.section_p,
						*volume_p);
			}
			VoxelVolume &volume = *volume_p;

			// Only this part needs voxelworld. A section the padding reaches
			// into that does not exist yet is created ungenerated, so that it
			// keeps whatever crossed into it and is still generated later.
			voxelworld::access(m_server, task.scene_ref,
					[&](voxelworld::Instance *world)
			{
				// The section itself is this generator's to write; the
				// padding around it is only a gift to whoever owns that,
				// and loses to what is already there
				world->merge_volume(volume, true, &section_region);
			});

			// On the main thread, after the merge: what a game runs over
			// terrain that has just appeared goes here
			m_server->emit_event("worldgen:section_generated",
					new SectionGenerated(task.scene_ref, task.section_p));
		} catch(NullptrCatch &e){
			// Something was probably deleted or unloaded
			log_v(MODULE, "NullptrCatch: %s", e.what());
		}
	}
};

void GenerateThread::run(interface::Thread *thread)
{
	for(;;){
		// Give some time for accumulating the section queues
		interface::os::sleep_us(5000);
		// Wait for some generation requests
		m_module->m_queued_sections_sem.wait();
		if(thread->stop_requested())
			break;

		// The sections the players are in, per scene, for the queue's
		// order; asked of voxelworld with this module not held
		sv_<SceneReference> scenes;
		worldgen::access(m_module->m_server,
				[&](worldgen::Interface *iworldgen)
		{
			for(auto &pair: m_module->m_instances)
				scenes.push_back(pair.first);
		});
		std::map<SceneReference, sv_<pv::Vector3DInt16>> players;
		// And the pinned sections asked for, the points with no radius
		std::map<SceneReference, std::set<std::tuple<int16_t, int16_t,
				int16_t>>> pinned;
		for(SceneReference scene : scenes){
			try {
				voxelworld::access(m_module->m_server, scene,
						[&](voxelworld::Instance *world)
				{
					pv::Vector3DInt16 ss = world->get_section_size_voxels();
					auto floor_div = [](int32_t a, int32_t b){
						return (int16_t)(a >= 0 ? a / b : -((-a + b - 1) / b));
					};
					for(const voxelworld::LoadPoint &lp :
							world->get_load_points()){
						pv::Vector3DInt16 sp(
								floor_div(lp.p.getX(), ss.getX()),
								floor_div(lp.p.getY(), ss.getY()),
								floor_div(lp.p.getZ(), ss.getZ()));
						if(lp.peer != 0)
							players[scene].push_back(sp);
						else if(lp.load_xz == 0 && lp.load_y == 0 &&
								!lp.hold_only)
							pinned[scene].insert(std::make_tuple(sp.getX(),
									sp.getY(), sp.getZ()));
					}
				});
			} catch(NullptrCatch &e){
				// No world for it (yet, or any more): the queue's order
			}
		}

		// Take one section for each instance. We can avoid implementing our
		// own mutex locking in Module by using
		// interface::Server::access_module() instead of directly accessing it.
		sv_<GenerateTask> tasks;
		worldgen::access(m_module->m_server,
				[&](worldgen::Interface *iworldgen)
		{
			for(auto &pair: m_module->m_instances){
				up_<CInstance> &instance = pair.second;
				if(!instance->m_enabled){
					if(!instance->m_queued_sections.empty()){
						// Has to be checked later
						m_module->m_queued_sections_sem.post();
					}
					continue;
				}
				GenerateTask task;
				task.scene_ref = instance->m_scene_ref;
				task.instance = instance.get();
				if(instance->take_next_section(players[pair.first],
						pinned[pair.first], &task.section_p,
						&task.generator, &task.epoch))
					tasks.push_back(task);
			}
		});

		// Generate outside of every module: this is the part that takes
		// milliseconds per section, and voxelworld is wanted by everything
		// else in the meantime -- an explosion waiting for it is an explosion
		// the player sees seconds after the bomb landed.
		for(const GenerateTask &task : tasks)
			m_module->generate_and_merge(task);
	}
}

void GenerateThread::on_crash(interface::Thread *thread)
{
	m_module->m_server->shutdown(1, "GenerateThread crashed");
}

extern "C" {
	BUILDAT_EXPORT void* createModule_worldgen(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
