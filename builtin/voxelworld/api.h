// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include "interface/voxel.h"
#include "interface/voxel_volume.h"
#include "storage/api.h"
#include <PolyVoxCore/Vector.h>
#include <PolyVoxCore/Region.h>
#include <PolyVoxCore/RawVolume.h>
#include <functional>
#include <map>

namespace Urho3D
{
	class Context;
	class Scene;
	class Node;
}

namespace main_context
{
	struct OpaqueSceneReference;
	typedef OpaqueSceneReference* SceneReference;
}

namespace voxelworld
{
	namespace magic = Urho3D;
	namespace pv = PolyVox;

	using interface::VoxelVolume;
	using interface::VoxelInstance;
	using main_context::SceneReference;

	struct GenerationRequest: public interface::Event::Private
	{
		SceneReference scene;
		pv::Vector3DInt16 section_p;

		GenerationRequest(SceneReference scene,
				const pv::Vector3DInt16 &section_p):
			scene(scene),
			section_p(section_p)
		{}
	};

	// A section has come into the world, or is about to leave it. What
	// listens is a game that keeps something of its own per section -- what
	// hangs off the nodes, the timers running in it -- and has to bring it
	// back with the section and write it out with it.
	//
	// Loaded is emitted after the voxels are there and unloaded before they
	// go; both reach the listener after voxelworld has let go of the
	// section, so a listener may call back into it.
	struct SectionLoaded: public interface::Event::Private
	{
		SceneReference scene;
		pv::Vector3DInt16 section_p;

		SectionLoaded(SceneReference scene,
				const pv::Vector3DInt16 &section_p):
			scene(scene), section_p(section_p){}
	};

	struct SectionUnloaded: public interface::Event::Private
	{
		SceneReference scene;
		pv::Vector3DInt16 section_p;

		SectionUnloaded(SceneReference scene,
				const pv::Vector3DInt16 &section_p):
			scene(scene), section_p(section_p){}
	};

	// [SAVE_LIMIT] Sections forget_sections() took out of the save: what a
	// game keeps beside them (the luanti module's node metadata) goes too
	struct SectionsForgotten: public interface::Event::Private
	{
		SceneReference scene;
		sv_<pv::Vector3DInt16> sections;

		SectionsForgotten(SceneReference scene,
				const sv_<pv::Vector3DInt16> &sections):
			scene(scene), sections(sections){}
	};

	// [SAVE_LIMIT] A saved section's index row (section_stats()). altered:
	// changed by a player after the generator's merge landed; a row from
	// before the index is altered. day: days since 1970 it was last loaded
	// for a player, -1 unknown. bytes: its chunks as last written.
	struct SectionStat
	{
		pv::Vector3DInt16 p;
		bool generated = true;
		bool altered = true;
		bool loaded = false;
		int64_t bytes = 0;
		int32_t day = -1;
	};

	struct NodeVolumeUpdated: public interface::Event::Private
	{
		SceneReference scene;
		uint node_id;
		bool is_static_chunk = false;
		pv::Vector3DInt32 chunk_p; // Only set if is_static_chunk == true

		NodeVolumeUpdated(SceneReference scene, uint node_id,
				bool is_static_chunk, const pv::Vector3DInt32 &chunk_p):
			scene(scene), node_id(node_id),
			is_static_chunk(is_static_chunk), chunk_p(chunk_p)
		{}
	};

	// Where the world is kept loaded: a point in voxels, and how far around
	// it sections live. The radii are per point because a player needs a big
	// one and a machine that only has to keep working needs the smallest one
	// that does -- and because two players differ from each other: a client
	// on a weaker computer wants less sent to it, and loading more than that
	// client will look at is the server spending memory on nothing.
	//
	// A section pinned in place is a point with every radius zero.
	struct LoadPoint
	{
		pv::Vector3DInt32 p; // In voxels
		// Sections this far out are loaded if the save has them and left
		// alone if it does not: what a player sees far away is the terrain
		// that is already there, and new terrain appears closer in. This is
		// also the radius a section has to leave before it is unloaded, so
		// keeping it larger than the generate radius is what stops a player
		// walking back and forth from generating the same section twice.
		int16_t load_xz = 0;
		int16_t load_y = 0;
		// ... and this far out, generated as well. <= the load radii.
		int16_t generate_xz = 0;
		int16_t generate_y = 0;
		// Whose point this is, if it is a client's, and zero if it is not.
		// A peer's point is also where the world is sent to that peer from:
		// how much it gets is the smaller of what its client asked for and
		// this point's load radius, because the server cannot send what it
		// does not keep. A peer with no point of its own gets everything.
		size_t peer = 0;

		LoadPoint(){}
		LoadPoint(const pv::Vector3DInt32 &p,
				int16_t load_xz, int16_t load_y,
				int16_t generate_xz, int16_t generate_y, size_t peer = 0):
			p(p), load_xz(load_xz), load_y(load_y),
			generate_xz(generate_xz), generate_y(generate_y), peer(peer)
		{}
	};

	struct Instance;

	struct CommitHook
	{
		virtual ~CommitHook(){}
		virtual void in_thread(voxelworld::Instance *world,
				const pv::Vector3DInt32 &chunk_p,
				VoxelVolume &volume){}
		virtual void in_scene(voxelworld::Instance *world,
				const pv::Vector3DInt32 &chunk_p, magic::Node *n){}
	};

	struct Instance
	{
		virtual interface::VoxelRegistry* get_voxel_reg() = 0;

		// The game's own migration, for a saved chunk whose format differs
		// from this world's by more than moved bits: a field or a named
		// plane whose width changed (VoxelMigration,
		// interface/voxel_volume.h). Set before the save is opened, and
		// kept alive by the game; nullptr, as by default, refuses such a
		// save.
		virtual void set_migration(interface::VoxelMigration *migration) = 0;

		// Persist this world in a save, under a name of its own -- a save
		// holds zero, one or many worlds, so the name is what separates
		// them. Until this is called nothing is persisted, which is what
		// every game did before it existed: generate and forget.
		//
		// Call it after registering voxels and before asking for any
		// section. Sections already in the save are loaded instead of
		// generated.
		//
		// The running game owns the voxel numbering and the save stores
		// names: what a save holds is a name table, and loading translates
		// its ids into the ones this run registered. So a game is free to
		// register its types in another order, or to add and drop them,
		// without a world it has saved meaning anything else than it did.
		// Registering more types after this call is allowed; each reaches
		// the save's table before anything holding it is written.
		//
		// The Save belongs to whoever opened it, and closing it while a
		// world still points at it is a use-after-free. Pass nullptr to stop
		// persisting first.
		virtual void set_save(storage::Save *save, const ss_ &world_name) = 0;

		// Before set_save(): old block name -> the one it is now. A name the
		// save holds is read as the voxel of the name its alias gives, and
		// written back under that name -- whether the game still registers
		// the old one (Luanti's register_alias_force keeps its id) or not
		// (it would be unknown) -- as Luanti remaps a stored block's names
		// ([FEATURE_SWEEP_1009]).
		virtual void set_name_aliases(const std::map<ss_, ss_> &aliases) = 0;

		// Write out every section that has changed since it was read.
		// Happens by itself when a section is unloaded and at shutdown, so
		// this is for a game that wants a checkpoint of its own.
		virtual void save() = 0;
		// [SAVE_CHECKPOINT] The same, with the game's own writes (also(),
		// called on voxelworld's thread) in one transaction with the
		// world's. A game that calls this checkpoints itself; one that does
		// not has the world saved every save_interval_s by voxelworld.
		virtual void save(std::function<void()> also) = 0;

		// [SAVE_LIMIT] Whose doing the writes from now on are: a player's
		// name while a game handles that player's action (a dig, a place, a
		// command), "" after. A section a player changes is altered, and
		// trim_to() does not take it. The luanti module sets it for a
		// Luanti game; a C++ game sets it around its own handling.
		// simplified: what the action sets going (a fire spreading) is the
		// world's own once the call returns.
		virtual void set_cause(const ss_ &player_name) = 0;
		// Every saved section's index row, loaded ones as they are now
		virtual sv_<SectionStat> section_stats() = 0;
		// Their chunks and rows deleted in one batch, a loaded one skipped;
		// a forgotten section is generated again when it is next visited.
		// Sends voxelworld:sections_forgotten. Returns how many went.
		virtual size_t forget_sections(const sv_<pv::Vector3DInt16> &list) = 0;
		// Forgets unaltered sections with no altered one around them, least
		// recently visited first, until the save is at target_bytes;
		// altered_days >= 0 then also takes altered ones nobody has visited
		// in that many days, oldest first. Returns how many went.
		// simplified: the unit is a section, which is a Luanti game's
		// mapchunk; a generator with a larger one would want its own.
		virtual size_t trim_to(int64_t target_bytes, int altered_days = -1) = 0;

		virtual void add_commit_hook(up_<CommitHook> hook) = 0;

		virtual pv::Vector3DInt16 get_section_size_voxels() = 0;

		virtual pv::Region get_section_region_voxels(
				const pv::Vector3DInt16 &section_p) = 0;

		virtual const pv::Vector3DInt16& get_chunk_size_voxels() = 0;

		virtual pv::Region get_chunk_region_voxels(
				const pv::Vector3DInt32 &chunk_p) = 0;

		virtual void load_or_generate_section(
				const pv::Vector3DInt16 &section_p) = 0;
		// Loaded from the save or created empty, not generated: what a
		// write lands in when it reaches past the generated world -- a
		// mapgen mod's structure spilling into the next section -- and the
		// generator fills in the rest around it when that section's turn
		// comes, as write_volume() has always had it. Generating it on the
		// spot was 500 ms inside the mod's own step ([STEP_SLICE]).
		virtual void load_section_no_generate(
				const pv::Vector3DInt16 &section_p) = 0;

		// The points the world stays loaded around, replacing the previous
		// set; call it whenever they move, it only remembers them. A few
		// sections are loaded, generated or unloaded per pass after that, so
		// that one tick never carries a whole world.
		//
		// Nothing outside the region given to create_instance() is loaded,
		// which is what makes that region the world's bounds: a game that
		// streams says how tall and how wide its world is by asking for it,
		// and the sky is still at the top of it.
		//
		// A world that never calls this loads its whole region at the start
		// and keeps it, which is what every game did before this existed.
		virtual void set_load_points(const sv_<LoadPoint> &points) = 0;

		// Every section that is loaded right now, in no particular order.
		// What asks is a sweep -- an ABM, a fill, an importer clipping what
		// it reads -- which would otherwise walk the bounds and skip what is
		// not there; over a streamed world that walk is the cost.
		virtual sv_<pv::Vector3DInt16> get_loaded_sections() = 0;

		// How many sections one streaming pass may load, generate or unload;
		// two by default. A game whose generator runs behind turns this down
		// to nothing while its queue is long and back up when it drains --
		// only the game can see that queue. Nothing else should touch it.
		virtual void set_stream_budget(size_t sections_per_pass) = 0;

		virtual void unload_section(const pv::Vector3DInt16 &section_p) = 0;

		virtual bool is_section_loaded(const pv::Vector3DInt16 &section_p) = 0;

		// Whether a generator has been over it. A section can be loaded and
		// not generated -- a volume write created it to hold what crossed
		// into it -- and what a generator writes when it does arrive is the
		// section's own; see merge_volume()'s owned region. So anything
		// that wants to write terrain of its own and have it stay waits for
		// this.
		virtual bool is_section_generated(
				const pv::Vector3DInt16 &section_p) = 0;

		// Say a section has been generated without generating it: its
		// voxels came from somewhere else. What asks is an importer reading
		// another engine's world, and what it prevents is the generator
		// running over that section afterwards and writing what was read
		// away -- inside its own section a generator's volume wins, which
		// is what merge_volume()'s owned region means.
		//
		// The section is created and loaded if it is not there yet. What
		// the caller does not write stays undefined, the way it is in a
		// section nobody has asked for: a caller that only covers part of a
		// section is saying that the rest of it is not there rather than
		// that it is empty.
		virtual void set_section_generated(
				const pv::Vector3DInt16 &section_p) = 0;

		virtual void set_voxel(const pv::Vector3DInt32 &p,
				const VoxelInstance &v,
				bool disable_warnings = false) = 0;

		// The voxels of a region, in one read rather than one per voxel:
		// what asks for this is a sweep, and a section is a quarter of a
		// million voxels. The answer carries every plane the chunks it came
		// from have.
		//
		// What is not there -- a section that is not loaded, a chunk nothing
		// has written -- comes back as VOXELTYPEID_UNDEFINED, which is what
		// get_voxel() answers for one.
		virtual VoxelVolume get_volume(const pv::Region &region) = 0;

		// The other direction, and the one merge_volume() below is not:
		// every defined voxel of the volume is written, whatever was there.
		// An importer, a VoxelManip and a mod putting a building down all
		// mean this; a generator means merge_volume().
		//
		// A voxel that is undefined in the volume is skipped, so a caller
		// can still leave holes, and create_missing_sections works the same
		// way it does below.
		//
		// exact_light: the volume's light is the light, a 0 included, and
		// nothing is seeded for it -- a Luanti mod's write_to_map(false),
		// whose param1 is its own work ([WIELDLIGHT_STALE]: vl_wieldlight
		// takes its torch's light back by writing 0s, which without this
		// meant "no light given" and left the old light). The voxels that
		// block light beside a changed one wear their neighbours' light
		// again after it (see "Skylight" in lighting.h).
		virtual void set_volume(const VoxelVolume &volume,
				bool create_missing_sections = false,
				bool exact_light = false) = 0;

		// Write a generated volume into the world, by priority per voxel: a
		// voxel that has not been generated yet (VOXELTYPEID_UNDEFINED) takes
		// anything, an empty one takes anything that is not empty, and one
		// that already holds something is left alone -- it is either terrain
		// that was generated by whoever owns that section or something that
		// was built there since, and neither should be overwritten by a
		// neighbour's padding. A voxel that is undefined in the volume is
		// skipped, so a generator can leave holes for others to fill.
		//
		// The volume may reach outside the section it was generated for.
		// With create_missing_sections, a section it reaches into that does
		// not exist yet is created and left ungenerated, holding only what
		// the volume puts in it; it is generated for real when someone asks
		// for it. Without it, such a part of the volume is dropped.
		//
		// "Empty" is VoxelDefinition::fully_empty: a voxel that nothing
		// occupies. A voxel that merely leaves the faces against it undrawn
		// (EDGEMATERIALID_EMPTY) may still hold a mesh of its own, and counts
		// as something standing there.
		virtual void merge_volume(
				const VoxelVolume &volume,
				bool create_missing_sections,
				const pv::Region *owned = nullptr) = 0;

		// Maintain the sky light (the format's light_sky) of every voxel in
		// the world.
		// Off by default; a world that does not want skylight pays nothing and
		// keeps whatever is in those bits. Once on, the light is kept up to
		// date by set_voxel(), including through generation, and is settled
		// before commit() meshes anything.
		//
		// Light enters from two places, and needs no switch between them:
		// from above the top of the world region, when that section is
		// loaded; and from any voxel that already holds light, because the
		// light is stored in the voxel and the save carries it. The second
		// is what a world taller than anything that will ever be loaded at
		// once needs -- its region top is thirty thousand voxels up and is
		// never there -- and it makes producing correct light the
		// generator's contract.
		//
		// So a voxel written with light of its own keeps it: that is a
		// generator saying what the sky reaches where it has just built.
		// One written without takes the light that was there, and the
		// change is what the flood works from.
		//
		// Light gets past a voxel whose edge material is EDGEMATERIALID_EMPTY
		// or which says transmits_light (glass, a plant: drawn, and seen
		// through), and spreads sideways and upwards losing one step per
		// voxel. The open sky's column falls undiminished only through a
		// voxel that is fully_empty or says transmits_light (Luanti's
		// sunlight_propagates; see lighting.h): water lets light through a
		// level at a time. Air that says neither is refused by add_voxel()
		// ([API_DEFAULTS_07]).
		//
		// Which light this is about. A game binds the fields it fills (see
		// VoxelFormat) and asks for the ones it wants kept up to date here;
		// the two are separate questions and both are opt-in.
		//
		// LIGHT_SKY is the sky's, and every game in this tree that has a sky
		// asks for it. LIGHT_LAMP is light a voxel emits of its own --
		// VoxelDefinition::light_source -- which a Luanti game's mechanics
		// read (mob spawning, crops) and a game whose lamps are lights in
		// the scene does not want at all: the shader does that work and the
		// field would be bits spent on zeroes.
		enum LightField { LIGHT_SKY, LIGHT_LAMP };

		virtual void set_light_maintained(LightField field,
				bool maintained) = 0;

		// The sky's, which is what nearly every caller means
		void set_skylight_enabled(bool enabled){
			set_light_maintained(LIGHT_SKY, enabled);
		}

		// Work the light in these sections out again from what is in them
		// and what is around them. A game that writes a region of terrain
		// with no light in it -- a Luanti mod's mapgen does exactly that,
		// and Luanti's own answer to it is VoxelManip:calc_lighting() --
		// asks for this afterwards; without it the terrain it wrote is dark
		// and stays dark, because a write carrying no light takes the light
		// that was there and there was none.
		//
		// It is the same work a section that came back stale does: the
		// light in the section is taken out and let back in from its faces
		// and its own sources. Costly enough to be worth asking for rather
		// than doing on every write -- a section is a quarter of a million
		// voxels.
		virtual void relight_region(const pv::Region &region) = 0;

		// The same, later: the sections are marked stale now and
		// relight_stale() brings them up to date under a budget, one section
		// at a time, so the recompute is not inside the step that wrote them
		// ([STEP_SLICE]: a mapgen mod's write_to_map was a 160 ms relight
		// in the same step as its own 200 ms). Until then the section wears
		// the light the write's own flood left, which is nearly right.
		virtual void relight_region_later(const pv::Region &region) = 0;
		// Returns how many sections are still stale. The nearest a load point
		// goes first; while that one is within near_sections of a load
		// point the budget is near_budget_us instead -- a jungle spawn's
		// own canopy is black until its sections are relit, and the tick
		// may spend more on those than on the far ones ([SEED5_SETTLE])
		virtual size_t relight_stale(int64_t budget_us,
				int64_t near_budget_us = 0, int near_sections = 2) = 0;
		// While on, a write does not flood light from what it changed: for
		// a writer that will ask for a relight of everything it touched
		// anyway, whose flood was the same work twice ([STEP_SLICE])
		virtual void set_light_deferred(bool on) = 0;

		virtual void commit() = 0;

		virtual VoxelInstance get_voxel(const pv::Vector3DInt32 &p,
				bool disable_warnings = false) = 0;

		// The same, for a world whose voxels are more than one plane: a
		// sample is every plane of a voxel read or written together. A
		// chunk takes on the world's planes the first time one is written
		// into it.
		//
		// set_voxel() writes the first plane and leaves the rest of a
		// voxel alone, which is what it has always meant and what a game
		// with one plane wants; set_sample() writes all of them.
		virtual void set_sample(const pv::Vector3DInt32 &p,
				const interface::VoxelSample &v,
				bool disable_warnings = false) = 0;
		virtual interface::VoxelSample get_sample(const pv::Vector3DInt32 &p,
				bool disable_warnings = false) = 0;

		// NOTE: There is no interface in here for directly accessing chunk
		// volumes of static nodes, because it is so much more hassly and was
		// tested to improve speed only by 53% compared to the current very
		// robust interface.
	};

	struct Interface
	{
		// physics_enabled gives the chunk nodes server-side Bullet collision
		// shapes. Off by default: they cost more than the world generation
		// they are built alongside, and only a game that has the server
		// simulate something against the terrain queries them at all. A game
		// that reads terrain hits out of the voxel volumes does not need them.
		// It is a parameter and not a setting because the initial sections are
		// created here. The client has its own switch; see physics_distance in
		// voxelworld's client_lua.
		//
		// The region is in sections, and is the world's bounds: nothing
		// outside it is ever loaded, and the sky is above the top of it. A
		// world that does not stream (see set_load_points()) also has every
		// section of it loaded at the start, so a world that wants bounds
		// bigger than it wants to load has to stream.
		virtual void create_instance(SceneReference scene_ref,
				const pv::Region &region, bool physics_enabled = false) = 0;
		virtual void delete_instance(SceneReference scene_ref) = 0;

		virtual Instance* get_instance(SceneReference scene_ref) = 0;

		virtual void commit() = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(voxelworld::Interface*)> cb)
	{
		return server->access_module("voxelworld", [&](interface::Module *module){
			auto *iface = (voxelworld::Interface*)module->check_interface();
			cb(iface);
			iface->commit();
		});
	}

	inline bool access(interface::Server *server, SceneReference scene_ref,
			std::function<void(voxelworld::Instance*instance)> cb)
	{
		return access(server, [&](voxelworld::Interface *i){
			voxelworld::Instance *instance =
					check(i->get_instance(scene_ref));
			cb(instance);
		});
	}

	// [ACCESS_ONE_SHOT]: one voxel read or written, each an access (and a
	// write its commit); several under one lock are still access()'s
	inline VoxelInstance get_voxel(interface::Server *server,
			SceneReference scene_ref, const pv::Vector3DInt32 &p,
			bool disable_warnings = false)
	{
		VoxelInstance v(0);
		access(server, scene_ref, [&](Instance *w){
			v = w->get_voxel(p, disable_warnings);
		});
		return v;
	}
	inline void set_voxel(interface::Server *server, SceneReference scene_ref,
			const pv::Vector3DInt32 &p, const VoxelInstance &v,
			bool disable_warnings = false)
	{
		access(server, scene_ref, [&](Instance *w){
			w->set_voxel(p, v, disable_warnings);
		});
	}
	inline interface::VoxelSample get_sample(interface::Server *server,
			SceneReference scene_ref, const pv::Vector3DInt32 &p,
			bool disable_warnings = false)
	{
		interface::VoxelSample v;
		access(server, scene_ref, [&](Instance *w){
			v = w->get_sample(p, disable_warnings);
		});
		return v;
	}
	inline void set_sample(interface::Server *server, SceneReference scene_ref,
			const pv::Vector3DInt32 &p, const interface::VoxelSample &v,
			bool disable_warnings = false)
	{
		access(server, scene_ref, [&](Instance *w){
			w->set_sample(p, v, disable_warnings);
		});
	}
}

// vim: set noet ts=4 sw=4:
