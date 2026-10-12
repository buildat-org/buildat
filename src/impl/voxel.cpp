// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/voxel.h"
#include "interface/voxel_selector.h"
#include "interface/voxel_volume.h"
#include "core/log.h"
#include "interface/os.h"
#include "interface/voxel_cereal.h"
#include "interface/voxel_cereal_legacy.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <mutex>
#include <atomic>
#include <cassert>
#define MODULE "voxel"

namespace std {
template<> struct hash<interface::VoxelName>{
	std::size_t operator()(const interface::VoxelName &v) const {
		return ((std::hash<ss_>() (v.block_name) << 0) ^
				(std::hash<uint>() (v.segment_x) << 1) ^
				(std::hash<uint>() (v.segment_y) << 2) ^
				(std::hash<uint>() (v.segment_z) << 3) ^
				(std::hash<uint>() (v.rotation_primary) << 4) ^
				(std::hash<uint>() (v.rotation_secondary) << 5));
	}
};
}

namespace interface {

ss_ VoxelName::dump() const
{
	std::ostringstream os(std::ios::binary);
	os<<"VoxelName(";
	os<<"block_name="<<block_name;
	os<<", segment=("<<(int)segment_x<<","<<(int)segment_y<<","
			<<(int)segment_z<<")";
	os<<", rotation_primary="<<(int)rotation_primary;
	os<<", rotation_secondary="<<(int)rotation_secondary;
	os<<")";
	return os.str();
}

bool VoxelName::operator==(const VoxelName &other) const
{
	return (
			block_name == other.block_name &&
			segment_x == other.segment_x &&
			segment_y == other.segment_y &&
			segment_z == other.segment_z &&
			rotation_primary == other.rotation_primary &&
			rotation_secondary == other.rotation_secondary
	);
}

// Voxel types are added on the main thread while worker threads mesh chunks
// out of them, so every access goes through m_mutex, and the definitions live
// in deques: a pointer handed out by get_cached() stays valid across an
// add_voxel(), which is not true of a vector.
struct CVoxelRegistry: public VoxelRegistry
{
	sd_<VoxelDefinition> m_defs;
	sd_<CachedVoxelDefinition> m_cached_defs;
	sm_<VoxelName, VoxelTypeId> m_name_to_id;
	VoxelFormat m_format = VoxelFormat::default_cut();
	// What add_plane() was asked for, appended again to every format set
	sv_<VoxelPlane> m_added_planes;
	// How a voxel's definition is found; the default is the id role
	VoxelSelector m_look;
	bool m_is_dirty = false;
	std::mutex m_mutex;

	// What get_cached() answers from without taking the mutex.
	//
	// It is asked once per voxel -- the light flood and the mesher both walk
	// a quarter of a million of them per section -- and a lock and unlock
	// around a table lookup was 6% of the whole server in a devtest profile,
	// more than the lookup itself. Nearly every one of those calls is about
	// an id whose cache entry was finished long ago.
	//
	// A pointer into m_cached_defs stays good for the life of the registry,
	// since a deque never moves an element, and every caller of this already
	// reads the entry after the lock is dropped. So what the fast path needs
	// is a way to learn that an id is cached without touching the deque's
	// own bookkeeping, which a concurrent add_voxel() may be writing: a
	// table of pointers, published entry by entry with a release store and
	// read with an acquire load.
	//
	// simplified: two levels of fixed size, so 65536 voxel types are fast
	// and anything above that takes the lock. A game with more types than
	// that has other problems.
	static const uint32_t FAST_SHIFT = 8;
	static const uint32_t FAST_IN_BLOCK = 1 << FAST_SHIFT;
	static const uint32_t FAST_MASK = FAST_IN_BLOCK - 1;
	static const uint32_t FAST_BLOCKS = 256;
	static const uint32_t FAST_IDS = FAST_BLOCKS * FAST_IN_BLOCK;
	typedef std::atomic<CachedVoxelDefinition*> FastSlot;
	std::atomic<FastSlot*> m_fast[FAST_BLOCKS];
	// **And the same table again for the callers that need the textures**
	// ([CLIENT_FRAME], 2026-09-26). The one above is published as soon as
	// an entry's basic fields are filled, which is why a caller carrying
	// an atlas could not use it: its textures may not be built yet. So it
	// took the mutex for every voxel of a chunk -- 39 thousand of them --
	// against three or four workers meshing at the same time, and the
	// waiting was 70 to 825 ms inside `set_voxel_geometry()`, on a chunk
	// of 177 bytes. An entry lands in this one only once its textures are
	// there, so the atlas path can read it with no lock at all.
	std::atomic<FastSlot*> m_fast_tex[FAST_BLOCKS];
	// The blocks themselves, kept until the registry goes: a reader may be
	// in one. There are at most 256 of them.
	sv_<sp_<FastSlot>> m_fast_blocks;

	// Called with the mutex held, once an entry is finished
	void publish_fast_in(std::atomic<FastSlot*> *table, VoxelTypeId id,
			CachedVoxelDefinition *cache)
	{
		if(id >= FAST_IDS)
			return;
		const uint32_t bi = id >> FAST_SHIFT;
		FastSlot *block = table[bi].load(std::memory_order_relaxed);
		if(block == nullptr){
			m_fast_blocks.push_back(sp_<FastSlot>(
					new FastSlot[FAST_IN_BLOCK](),
					std::default_delete<FastSlot[]>()));
			block = m_fast_blocks.back().get();
			table[bi].store(block, std::memory_order_release);
		}
		block[id & FAST_MASK].store(cache, std::memory_order_release);
	}
	void publish_fast(VoxelTypeId id, CachedVoxelDefinition *cache)
	{
		publish_fast_in(m_fast, id, cache);
	}
	// The entry is complete down to its atlas segments
	void publish_fast_tex(VoxelTypeId id, CachedVoxelDefinition *cache)
	{
		publish_fast_in(m_fast_tex, id, cache);
	}

	// Nothing is fast any more: the entries these point at are about to go
	void forget_fast()
	{
		std::atomic<FastSlot*> *tables[2] = {m_fast, m_fast_tex};
		for(int t = 0; t < 2; t++){
			for(uint32_t i = 0; i < FAST_BLOCKS; i++){
				FastSlot *block = tables[t][i].load(std::memory_order_relaxed);
				if(block == nullptr)
					continue;
				for(uint32_t j = 0; j < FAST_IN_BLOCK; j++)
					block[j].store(nullptr, std::memory_order_release);
			}
		}
	}

	CVoxelRegistry()
	{
		for(uint32_t i = 0; i < FAST_BLOCKS; i++){
			m_fast[i].store(nullptr, std::memory_order_relaxed);
			m_fast_tex[i].store(nullptr, std::memory_order_relaxed);
		}
		m_defs.resize(1); // Id 0 is VOXELTYPEID_UNDEFINEDD
	}

	void clear()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		forget_fast();
		m_defs.clear();
		m_cached_defs.clear();
		m_name_to_id.clear();

		m_defs.resize(1); // Id 0 is VOXELTYPEID_UNDEFINEDD
	}

	const VoxelFormat& get_format()
	{
		// Set before the first voxel and never after, so a reader on a
		// worker thread does not have to take the lock for this
		return m_format;
	}

	void set_format(const VoxelFormat &format)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		ss_ why;
		if(!format.validate(&why))
			throw Exception(ss_()+"set_format(): "+why);
		if(m_defs.size() > 1)
			throw Exception(ss_()+"set_format(): "+
					itos(m_defs.size() - 1)+" voxels have already been "
					"added under "+m_format.dump());
		m_format = format;
		for(const VoxelPlane &p : m_added_planes)
			append_plane(p);
		m_is_dirty = true;
		log_v(MODULE, "CVoxelRegistry::set_format(): %s",
				cs(m_format.dump()));
	}

	// Under the lock
	int append_plane(const VoxelPlane &p)
	{
		int i = m_format.plane_of_name(p.name);
		if(i >= 0){
			if(m_format.planes[i].bits != p.bits)
				throw Exception(ss_()+"add_plane(): \""+p.name+"\" is "+
						itos(m_format.planes[i].bits)+" bits already, not "+
						itos(p.bits));
			return i;
		}
		VoxelFormat f = m_format;
		f.planes.push_back(p);
		ss_ why;
		if(!f.validate(&why))
			throw Exception(ss_()+"add_plane(): "+why);
		m_format = f;
		return (int)m_format.planes.size() - 1;
	}

	int add_plane(const ss_ &name, uint8_t bits)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		m_added_planes.push_back(VoxelPlane(name, bits));
		int i = append_plane(m_added_planes.back());
		m_is_dirty = true;
		log_v(MODULE, "CVoxelRegistry::add_plane(): %s", cs(m_format.dump()));
		return i;
	}

	const VoxelSelector& get_look_selector()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		return m_look;
	}

	void set_look_selector(const VoxelSelector &selector)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		ss_ why;
		if(!selector.validate(m_defs.size(), &why))
			throw Exception(ss_()+"set_look_selector(): "+why);
		m_look = selector;
		m_is_dirty = true;
		log_v(MODULE, "CVoxelRegistry::set_look_selector(): kind=%i rules=%zu "
				"fallback=%i", (int)m_look.kind, m_look.rules.size(),
				(int)m_look.fallback);
	}

	sv_<VoxelDefinition> get_all()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		sv_<VoxelDefinition> result;
		result.insert(result.end(), m_defs.begin()+1, m_defs.end());
		return result;
	}

	// Without id 0, which is VOXELTYPEID_UNDEFINED and not a type anything
	// registered
	size_t get_count()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		return m_defs.size() - 1;
	}

	VoxelTypeId num_voxels()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		return m_defs.size() - 1;
	}

	VoxelTypeId add_voxel(const VoxelDefinition &def)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		VoxelTypeId id = m_defs.size();
		if(def.id != VOXELTYPEID_UNDEFINED && id != def.id)
			throw Exception(ss_()+"add_voxel(): def.id="+itos(def.id)+
					"; should be "+itos(id));
		if(m_name_to_id.count(def.name) != 0)
			throw Exception(ss_()+"add_voxel(): Already exists: "+
					cs(def.name.dump()));
		m_defs.resize(id + 1);
		m_defs[id] = def;
		m_defs[id].id = id;
		m_name_to_id[def.name] = id;
		// The level is asked first because the name is built by dumping
		// it, and the arguments of a log call are worked out whether or
		// not the line is printed -- a registry's worth of them is a
		// tenth of a second ([CLIENT_FRAME])
		if(log_get_max_level() >= CORE_VERBOSE)
			log_v(MODULE, "CVoxelRegistry::add_voxel(): Added id=%i name=%s",
					id, cs(def.name.dump()));
		m_is_dirty = true;
		return id;
	}

	// A whole registry at once: one lock, one allocation, and the
	// definitions moved rather than copied. See the interface.
	void add_voxels(sv_<VoxelDefinition> &defs)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		for(VoxelDefinition &def : defs){
			const VoxelTypeId id = m_defs.size();
			if(def.id != VOXELTYPEID_UNDEFINED && id != def.id)
				throw Exception(ss_()+"add_voxels(): def.id="+itos(def.id)+
						"; should be "+itos(id));
			if(m_name_to_id.count(def.name) != 0)
				throw Exception(ss_()+"add_voxels(): Already exists: "+
						cs(def.name.dump()));
			m_name_to_id[def.name] = id;
			m_defs.push_back(std::move(def));
			m_defs[id].id = id;
		}
		m_is_dirty = true;
	}

	const VoxelDefinition* get(const VoxelTypeId &id)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		return get_unlocked(id);
	}

	const VoxelDefinition* get_unlocked(const VoxelTypeId &id)
	{
		if(id >= m_defs.size()){
			log_w(MODULE, "CVoxelRegistry::get(): id=%i not found", id);
			return NULL;
		}
		return &m_defs[id];
	}

	const VoxelDefinition* get(const VoxelName &name)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		auto it = m_name_to_id.find(name);
		if(it == m_name_to_id.end()){
			log_w(MODULE, "CVoxelRegistry::get(): name=%s not found",
					cs(name.dump()));
			return NULL;
		}
		VoxelTypeId id = it->second;
		return get_unlocked(id);
	}

	// The fast path: an id whose entry is finished. `table` says finished
	// for what -- the basic fields, or those and the atlas segments.
	const CachedVoxelDefinition* fast_cached_in(
			std::atomic<FastSlot*> *table, VoxelTypeId id)
	{
		if(id >= FAST_IDS)
			return nullptr;
		FastSlot *block = table[id >> FAST_SHIFT].load(
				std::memory_order_acquire);
		if(block == nullptr)
			return nullptr;
		return block[id & FAST_MASK].load(std::memory_order_acquire);
	}
	const CachedVoxelDefinition* fast_cached(VoxelTypeId id)
	{
		return fast_cached_in(m_fast, id);
	}
	// Finished down to its textures: what the mesher's preload asks for,
	// and the reason it no longer takes the mutex once a voxel has been
	// seen once
	const CachedVoxelDefinition* fast_cached_tex(VoxelTypeId id)
	{
		return fast_cached_in(m_fast_tex, id);
	}

	const CachedVoxelDefinition* get_cached(const VoxelTypeId &id,
			AtlasRegistry *atlas_reg, bool with_lod)
	{
		const CachedVoxelDefinition *fast = (atlas_reg == nullptr) ?
				fast_cached(id) :
				// With an atlas the entry has to carry its segments, and
				// the LOD ones only when those are what is asked for
				(with_lod ? nullptr : fast_cached_tex(id));
		if(fast != nullptr)
			return fast;
		std::lock_guard<std::mutex> lock(m_mutex);
		return get_cached_locked(id, atlas_reg, with_lod);
	}

	const CachedVoxelDefinition* get_cached_locked(const VoxelTypeId &id,
			AtlasRegistry *atlas_reg, bool with_lod)
	{
		if(id >= m_defs.size()){
			log_w(MODULE, "CVoxelRegistry::get_cached(): id=%i not found", id);
			return NULL;
		}
		if(m_cached_defs.size() < m_defs.size()){
			m_cached_defs.resize(m_defs.size());
		}
		const VoxelDefinition &def = m_defs[id];
		CachedVoxelDefinition &cache = m_cached_defs[id];
		if(!cache.valid){
			update_cache_basic(cache, def);
			cache.valid = true;
			// Finished, so the next caller need not come here at all
			publish_fast(id, &cache);
		}
		if(!cache.textures_valid && atlas_reg){
			// **What one voxel's first sight costs** ([CLIENT_FRAME],
			// 2026-09-26): its faces' segments are added to the atlases
			// and uploaded here, and a chunk that meets 800 ms of this is
			// a chunk that blocks the frame for 800 ms.
			const int64_t tex_t0 = interface::os::time_us();
			update_cache_textures(cache, def, atlas_reg);
			const int64_t tex_took = interface::os::time_us() - tex_t0;
			if(tex_took >= 25000){
				log_w(MODULE, "one voxel's textures took %i ms: %s",
						(int)(tex_took / 1000), cs(def.name.block_name));
			}
			cache.textures_valid = true;
			// Complete for a caller that carries an atlas, and published
			// after the segments are there rather than before
			publish_fast_tex(id, &cache);
		}
		if(with_lod && !cache.lod_textures_valid && atlas_reg){
			update_cache_lod_textures(cache, def, atlas_reg);
			cache.lod_textures_valid = true;
		}
		return &cache;
	}

	const CachedVoxelDefinition* get_cached(const VoxelInstance &v,
			AtlasRegistry *atlas_reg, bool with_lod)
	{
		VoxelSample sample;
		sample.planes[0] = v.data;
		return get_cached(sample, atlas_reg, with_lod);
	}

	const CachedVoxelDefinition* get_cached(const VoxelSample &v,
			AtlasRegistry *atlas_reg, bool with_lod)
	{
		// Which id a sample is took a lock of its own, so this call -- the
		// one the light flood and the mesher make per voxel -- locked twice.
		// The selector and the format are set while the registry is being
		// built and not after (set_format() refuses once anything is
		// registered), so the fast path reads them the way it reads the
		// entry they lead to: without the lock.
		{
			const VoxelTypeId id = m_look.id_of(v, m_format);
			const CachedVoxelDefinition *fast = (atlas_reg == nullptr) ?
					fast_cached(id) :
					(with_lod ? nullptr : fast_cached_tex(id));
			if(fast != nullptr)
				return fast;
		}
		std::lock_guard<std::mutex> lock(m_mutex);
		return get_cached_locked(m_look.id_of(v, m_format), atlas_reg,
				with_lod);
	}

	bool is_dirty()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		return m_is_dirty;
	}

	void clear_dirty()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		m_is_dirty = false;
	}

	void update_cache_basic(CachedVoxelDefinition &cache,
			const VoxelDefinition &def)
	{
		log_d(MODULE, "CVoxelRegistry::update_cache_basic(): id=%i", def.id);
		cache.handler_module = def.handler_module;
		cache.face_draw_type = def.face_draw_type;
		cache.edge_material_id = def.edge_material_id;
		cache.physically_solid = def.physically_solid;
		cache.fully_empty = def.fully_empty;
		cache.transmits_light = def.transmits_light;
		cache.light_source = def.light_source;
		cache.shape = def.shape;
		cache.variants = def.variants;
		for(size_t i = 0; i < 256; i++)
			cache.variant_of_param[i] = def.variant_of_param[i];
		cache.tint_ramp[0] = def.tint_ramp[0];
		cache.tint_ramp[1] = def.tint_ramp[1];
		cache.sag_extent = def.sag_extent;
		cache.shape_double_sided = def.shape_double_sided;
		cache.shape_lit_from_above = def.shape_lit_from_above;
		cache.uv_scale = def.uv_scale < 1 ? 1 : def.uv_scale;
		// Nought is "the same as across", which is every definition
		// written before the two axes were told apart ([SIGIL_ROUND])
		cache.uv_scale_v = def.uv_scale_v < 1 ? cache.uv_scale :
				def.uv_scale_v;
		cache.translucent = def.translucent;
		cache.alpha_masked = def.alpha_masked;
		cache.shape_group = def.shape_group;
		cache.is_liquid = def.is_liquid;
		cache.climbable = def.climbable;
		cache.move_resistance = def.move_resistance;
		cache.swimmable = def.swimmable;
		cache.pointable = def.pointable;
		cache.liquid_top = def.liquid_top;
		cache.liquid_is_source = def.liquid_is_source;
		cache.connect_group = def.connect_group;
		cache.connect_mask = def.connect_mask;
		cache.connect_to_solid = def.connect_to_solid;
		cache.shape_masked = def.shape_masked;
		for(size_t i = 0; i < 21; i++)
			cache.shape_masked_begin[i] = def.shape_masked_begin[i];
		for(size_t i = 0; i < 6; i++)
			cache.tile_turns[i] = def.tile_turns[i] & 3;
		// Caller sets cache.valid = true
	}

	void update_cache_textures(CachedVoxelDefinition &cache,
			const VoxelDefinition &def, AtlasRegistry *atlas_reg)
	{
		log_d(MODULE, "CVoxelRegistry::update_cache_textures(): id=%i", def.id);
		for(size_t i = 0; i<6; i++){
			const AtlasSegmentDefinition &seg_def = def.textures[i];
			if(seg_def.resource_name == ""){
				cache.textures[i] = AtlasSegmentReference(); // Default values
			} else {
				cache.textures[i] = atlas_reg->find_or_add_segment(seg_def);
			}
		}
		// And the ones a shape's quads wear beyond the six faces
		cache.extra_textures.resize(def.extra_textures.size());
		for(size_t i = 0; i < def.extra_textures.size(); i++){
			const AtlasSegmentDefinition &seg_def = def.extra_textures[i];
			cache.extra_textures[i] = seg_def.resource_name == "" ?
					AtlasSegmentReference() :
					atlas_reg->find_or_add_segment(seg_def);
		}
		// And the ones a variant wears instead of the definition's, which is
		// how a palette entry gets its own tinted tiles; see
		// VoxelVariant::textures
		for(size_t vi = 0; vi < cache.variants.size() &&
				vi < def.variants.size(); vi++){
			const VoxelVariant &def_variant = def.variants[vi];
			VoxelVariant &variant = cache.variants[vi];
			variant.texture_refs.resize(def_variant.textures.size());
			for(size_t i = 0; i < def_variant.textures.size(); i++){
				const AtlasSegmentDefinition &seg_def = def_variant.textures[i];
				variant.texture_refs[i] = seg_def.resource_name == "" ?
						AtlasSegmentReference() :
						atlas_reg->find_or_add_segment(seg_def);
			}
		}
		// Caller sets cache.textures_valid = true
	}

	// The same for the segments a LOD mesh samples, which are a texture
	// scaled and drawn into an atlas each: three times the work of the
	// segments above, and nothing but a LOD volume ever looks at them.
	void update_cache_lod_textures(CachedVoxelDefinition &cache,
			const VoxelDefinition &def, AtlasRegistry *atlas_reg)
	{
		for(size_t i = 0; i<6; i++){
			const AtlasSegmentDefinition &seg_def = def.textures[i];
			for(size_t j = 0; j < VOXELDEF_NUM_LOD; j++){
				if(seg_def.resource_name == ""){
					cache.lod_textures[j][i] = AtlasSegmentReference();
					continue;
				}
				AtlasSegmentDefinition lod_seg_def = seg_def;
				lod_seg_def.lod_simulation = 2 + j;
				cache.lod_textures[j][i] =
						atlas_reg->find_or_add_segment(lod_seg_def);
			}
		}
		// Caller sets cache.lod_textures_valid = true
	}
};

bool VoxelFormat::light_pair(VoxelField *out) const
{
	if(!light_sky.bound() || !light_lamp.bound())
		return false;
	if(light_sky.plane != light_lamp.plane)
		return false;
	if(light_sky.shift + light_sky.width != light_lamp.shift)
		return false;
	if(out){
		*out = VoxelField{light_sky.plane, light_sky.shift,
				(uint8_t)(light_sky.width + light_lamp.width)};
	}
	return true;
}

size_t VoxelFormat::surface_modifiers(
		VoxelField out[VOXEL_SURFACE_MODIFIERS]) const
{
	const VoxelField *all[] = {&tint, &wetness, &grain, &gloss, &speckle,
			&emission};
	size_t n = 0;
	for(size_t i = 0; i < sizeof all / sizeof all[0]; i++){
		if(!all[i]->bound())
			continue;
		if(n < VOXEL_SURFACE_MODIFIERS)
			out[n] = *all[i];
		n++;
	}
	for(size_t i = n; i < VOXEL_SURFACE_MODIFIERS; i++)
		out[i] = VoxelField();
	return n < VOXEL_SURFACE_MODIFIERS ? n : VOXEL_SURFACE_MODIFIERS;
}

bool VoxelFormat::validate(ss_ *why) const
{
	auto fail = [&](const ss_ &s){
		if(why)
			*why = s;
		return false;
	};

	if(planes.empty())
		return fail("a format has to have at least one plane");
	if(planes.size() > VOXEL_MAX_PLANES)
		return fail("a format has at most "+itos((int)VOXEL_MAX_PLANES)+
				" planes, not "+itos(planes.size()));
	for(size_t i = 0; i < planes.size(); i++){
		const VoxelPlane &p = planes[i];
		if(p.bits != 8 && p.bits != 16 && p.bits != 32)
			return fail("plane "+itos(i)+": bits must be 8, 16 or 32, not "+
					itos((int)p.bits));
		if(i == 0 && !p.name.empty())
			return fail("the first plane is the game's own and has no name");
		if(i != 0 && p.name.empty())
			return fail("plane "+itos(i)+" has no name");
		for(size_t j = 0; j < i; j++){
			if(planes[j].name == p.name)
				return fail("two planes are both named \""+p.name+"\"");
		}
	}

	// One list of roles, in roles(), so that a role added to the format is
	// validated here and migrated by migrate_volume() without a second list
	// anywhere to keep in step with it
	const sv_<Role> &fields = roles();

	for(const Role &n : fields){
		const VoxelField &f = this->*(n.field);
		if(!f.bound())
			continue;
		if(f.plane >= planes.size())
			return fail(ss_(n.name)+": there is no plane "+
					itos((int)f.plane));
		if(f.width > 32)
			return fail(ss_(n.name)+": width "+itos((int)f.width)+" > 32");
		const int bits = (int)plane_bits(f.plane);
		if((int)f.shift + (int)f.width > bits)
			return fail(ss_(n.name)+": bits "+itos((int)f.shift)+"..."+
					itos((int)f.shift + (int)f.width - 1)+" reach past the "+
					itos(bits)+"-bit plane "+itos((int)f.plane));
	}

	// VOXELTYPEID_MAX is not a mask -- it is a lower cap inside 21 bits --
	// so the rule here is the field's width, and the registry is what
	// refuses an id above the cap
	// The colour role is 0xRRGGBB in the low 24 bits of its field, so it is
	// that wide or 32 bits with the top byte unread. A palette index is not
	// this: indexing a palette is a lookup the engine does not have, and a
	// definition's variants are where a palette belongs.
	if(color.bound() && color.width != 24 && color.width != 32)
		return fail("color: width "+itos((int)color.width)+" is not 24 or 32");

	if(id.bound() && id.width > 21)
		return fail("id: width "+itos((int)id.width)+" > 21, the bits a "
				"voxel type id has");

	for(size_t i = 0; i < fields.size(); i++){
		for(size_t j = i + 1; j < fields.size(); j++){
			const VoxelField &a = this->*(fields[i].field);
			const VoxelField &b = this->*(fields[j].field);
			if(!a.bound() || !b.bound())
				continue;
			if(a.plane != b.plane)
				continue;
			if((a.mask() << a.shift) & (b.mask() << b.shift))
				return fail(ss_(fields[i].name)+" and "+fields[j].name+
						" overlap");
		}
	}

	// Four is what the vertex has room for; a fifth would have nowhere to
	// go and the game would find out by not seeing it
	{
		size_t n = 0;
		const VoxelField *surface[] = {&tint, &wetness, &grain, &gloss,
				&speckle, &emission};
		for(size_t i = 0; i < sizeof surface / sizeof surface[0]; i++)
			if(surface[i]->bound())
				n++;
		if(n > VOXEL_SURFACE_MODIFIERS)
			return fail("at most "+itos((int)VOXEL_SURFACE_MODIFIERS)+
					" surface modifiers can be bound at once, not "+itos((int)n));
	}

	// Nothing to look up and nothing to wear: there would be no way to draw
	// a voxel of this format at all.
	if(!id.bound() && !color.bound())
		return fail("neither id nor color is bound");

	return true;
}

ss_ VoxelFormat::dump() const
{
	std::ostringstream os(std::ios::binary);
	os<<"VoxelFormat("<<(int)plane_bits(0)<<"-bit";
	for(size_t i = 1; i < planes.size(); i++)
		os<<" + "<<planes[i].name<<":"<<(int)planes[i].bits<<"-bit";
	auto one = [&](cc_ *name, const VoxelField &f){
		if(!f.bound())
			return;
		os<<", "<<name<<"="<<(int)f.shift<<"..."
				<<(int)(f.shift + f.width - 1);
	};
	one("id", id);
	one("light_sky", light_sky);
	one("light_lamp", light_lamp);
	one("param", param);
	one("color", color);
	one("tint", tint);
	one("wetness", wetness);
	one("grain", grain);
	one("gloss", gloss);
	one("speckle", speckle);
	one("emission", emission);
	one("sag_top", sag_top);
	one("sag_bottom", sag_bottom);
	os<<")";
	return os.str();
}

bool VoxelSelector::validate(size_t count, ss_ *why) const
{
	auto fail = [&](const ss_ &s){
		if(why)
			*why = s;
		return false;
	};
	if(kind != RULES)
		return true;
	if(rules.empty())
		return fail("a rule selector with no rules selects nothing");
	for(size_t i = 0; i < rules.size(); i++){
		if(rules[i].result >= count)
			return fail("rule "+itos(i)+" points at voxel "+
					itos(rules[i].result)+", of which there are "+
					itos(count));
		// A rule with no clauses claims everything left, so nothing after it
		// can ever be reached
		if(rules[i].clauses.empty() && i + 1 < rules.size())
			return fail("rule "+itos(i)+" claims everything, so the "+
					itos(rules.size() - i - 1)+" after it are unreachable");
	}
	if(fallback >= count)
		return fail("the fallback is voxel "+itos(fallback)+", of which "
				"there are "+itos(count));
	return true;
}

bool voxel_selector_self_test()
{
	// FIELD is the format's own id role, whatever the selector holds
	{
		VoxelFormat f = VoxelFormat::luanti();
		VoxelSelector s;
		VoxelSample word;
		f.id.set(word, 1234);
		assert(s.id_of(word, f) == 1234);
	}

	// RULES: first match wins, an empty clause list claims what is left
	{
		VoxelFormat f;
		f.id = VoxelField(0, 0, 4); // bound, and deliberately not read
		VoxelField rock(0, 4, 8), sand(0, 12, 8);
		VoxelSelector s;
		s.kind = VoxelSelector::RULES;
		s.fallback = 9;
		{
			VoxelRule r; // mostly rock
			r.clauses.push_back(VoxelRuleClause(rock, 128, 255));
			r.result = 1;
			s.rules.push_back(r);
		}
		{
			VoxelRule r; // some of each
			r.clauses.push_back(VoxelRuleClause(rock, 32, 127));
			r.clauses.push_back(VoxelRuleClause(sand, 32, 255));
			r.result = 2;
			s.rules.push_back(r);
		}
		{
			VoxelRule r; // anything left
			r.result = 3;
			s.rules.push_back(r);
		}
		auto word_of = [&](uint32_t r, uint32_t sa){
			VoxelSample w;
			rock.set(w, r);
			sand.set(w, sa);
			return w;
		};
		assert(s.id_of(word_of(200, 0), f) == 1);
		assert(s.id_of(word_of(200, 200), f) == 1); // the first match, not the best
		assert(s.id_of(word_of(64, 64), f) == 2);
		assert(s.id_of(word_of(64, 0), f) == 3);    // the second rule's other clause
		assert(s.id_of(word_of(0, 0), f) == 3);

		ss_ why;
		assert(s.validate(10, &why));
		// The rule that claims everything has to be the last one
		VoxelSelector bad = s;
		std::swap(bad.rules[0], bad.rules[2]);
		assert(!bad.validate(10, &why));
		// And every rule has to point at a voxel that exists
		bad = s;
		bad.rules[0].result = 99;
		assert(!bad.validate(10, &why));
	}

	// A clause on a field nothing bound never holds, so a rule wearing one
	// is dead rather than always true
	{
		VoxelFormat f = VoxelFormat::default_cut();
		VoxelSelector s;
		s.kind = VoxelSelector::RULES;
		s.fallback = 7;
		VoxelRule r;
		r.clauses.push_back(VoxelRuleClause(VoxelField(), 0, 0));
		r.result = 1;
		s.rules.push_back(r);
		assert(s.id_of(VoxelSample(), f) == 7);
	}

	return true;
}

const sv_<VoxelFormat::Role>& VoxelFormat::roles()
{
	static const sv_<Role> a = {
		{"id", &VoxelFormat::id},
		{"light_sky", &VoxelFormat::light_sky},
		{"light_lamp", &VoxelFormat::light_lamp},
		{"param", &VoxelFormat::param},
		{"color", &VoxelFormat::color},
		{"tint", &VoxelFormat::tint},
		{"wetness", &VoxelFormat::wetness},
		{"grain", &VoxelFormat::grain},
		{"gloss", &VoxelFormat::gloss},
		{"speckle", &VoxelFormat::speckle},
		{"emission", &VoxelFormat::emission},
		{"sag_top", &VoxelFormat::sag_top},
		{"sag_bottom", &VoxelFormat::sag_bottom},
	};
	return a;
}

bool voxel_format_self_test()
{
	// A field reads back what was written to it, and leaves the rest alone
	for(uint8_t width : {1, 4, 8, 16, 21, 32}){
		for(uint8_t shift = 0; shift + width <= 32; shift++){
			VoxelField f{0, shift, width};
			uint32_t word = 0xdeadbeef;
			uint32_t untouched = word & ~(f.mask() << shift);
			uint32_t value = f.mask() & 0x5a5a5a5a;
			f.set(word, value);
			assert(f.get(word) == value);
			assert((word & ~(f.mask() << shift)) == untouched);
			// A value too large for the field is cut, not spilled
			f.set(word, 0xffffffff);
			assert(f.get(word) == f.mask());
			assert((word & ~(f.mask() << shift)) == untouched);
		}
	}

	ss_ why;
	assert(VoxelFormat::default_cut().validate(&why));
	assert(VoxelFormat::luanti().validate(&why));

	// The ways a format can be wrong
	{
		VoxelFormat f = VoxelFormat::default_cut();
		f.param = f.id; // overlaps
		assert(!f.validate(&why));
	}
	{
		VoxelFormat f = VoxelFormat::default_cut();
		f.param = VoxelField{0, 28, 8}; // past the end of the plane
		assert(!f.validate(&why));
	}
	{
		VoxelFormat f;
		f.id = VoxelField{0, 0, 32}; // wider than a voxel type id
		assert(!f.validate(&why));
	}
	{
		VoxelFormat f;
		f.id = VoxelField{0, 0, 21}; // the widest one there is
		assert(f.validate(&why));
	}
	{
		VoxelFormat f; // nothing bound
		assert(!f.validate(&why));
	}
	{
		// A painter: one implicit type, and a colour
		VoxelFormat f;
		f.color = VoxelField{0, 0, 32};
		assert(f.validate(&why));
		assert(f.id_of(0) == 1);
		assert(f.id_of(0xffffffff) == 1);
		// A colour is 24 bits of RGB, in a field of 24 or 32
		f.color = VoxelField{0, 0, 24};
		assert(f.validate(&why));
		f.color = VoxelField{0, 0, 16};
		assert(!f.validate(&why));
	}

	// Planes: a format has one 32-bit one unless it says otherwise, a named
	// one belongs to a module, and a field lives inside its own plane
	{
		VoxelFormat f = VoxelFormat::default_cut();
		assert(f.plane_count() == 1);
		assert(f.plane_bits(0) == 32);
		assert(f.plane_of_name("mod:heat") == -1);

		f.planes.push_back(VoxelPlane("mod:heat", 8));
		assert(f.validate(&why));
		assert(f.plane_of_name("mod:heat") == 1);
		// A field of the new plane is checked against its width, not the
		// first plane's
		f.param = VoxelField(1, 0, 8);
		assert(f.validate(&why));
		f.param = VoxelField(1, 4, 8);
		assert(!f.validate(&why));
		f.param = VoxelField(1, 0, 8);
		// And it no longer overlaps anything in plane 0
		f.param = VoxelField(1, 0, 8);
		assert(f.validate(&why));

		// A voxel's planes are read together
		VoxelSample v;
		f.id.set(v, 12345);
		f.param.set(v, 200);
		assert(f.id.get(v) == 12345);
		assert(f.param.get(v) == 200);
		assert(v.planes[0] != 0 && v.planes[1] == 200);

		// Only the first plane is the game's own, and a name is once
		f.planes.push_back(VoxelPlane("", 8));
		assert(!f.validate(&why));
		f.planes.back().name = "mod:heat";
		assert(!f.validate(&why));
		f.planes.back().name = "mod:wear";
		assert(f.validate(&why));
	}

	// The modifiers: at most four surface ones, in role order, and the
	// geometry ones do not count against that
	{
		VoxelFormat f;
		f.id = VoxelField{0, 0, 8};
		f.gloss = VoxelField{0, 8, 4};
		f.tint = VoxelField{0, 12, 4};
		assert(f.validate(&why));
		VoxelField slots[VOXEL_SURFACE_MODIFIERS];
		assert(f.surface_modifiers(slots) == 2);
		// Role order, not the order they were written here
		assert(slots[0] == f.tint);
		assert(slots[1] == f.gloss);
		assert(!slots[2].bound());

		f.sag_top = VoxelField{0, 16, 4};
		f.sag_bottom = VoxelField{0, 20, 4};
		assert(f.validate(&why));
		assert(f.surface_modifiers(slots) == 2);

		f.wetness = VoxelField{0, 24, 2};
		f.grain = VoxelField{0, 26, 2};
		assert(f.validate(&why));
		assert(f.surface_modifiers(slots) == 4);
		f.speckle = VoxelField{0, 28, 2}; // a fifth has nowhere to go
		assert(!f.validate(&why));
	}

	// default_cut() through the format is VoxelInstance's own hardcoded cut
	{
		VoxelFormat f = VoxelFormat::default_cut();
		for(uint32_t word : {0u, 0xffffffffu, 0x12345678u, 0xdeadbeefu,
				0x000fffffu, 0xf0f0f0f0u, 0x00000001u, 0x0badf00du}){
			VoxelInstance v(word);
			assert(f.id_of(word) == v.get_id());
			assert(f.light_sky.get(word) == v.get_skylight());
			assert(f.light_lamp.get(word) == v.get_lamplight());
		}
		VoxelField both;
		assert(f.light_pair(&both));
		assert(both.shift == 24 && both.width == 8);
	}

	// Luanti's cut fills the word with no room left over
	{
		VoxelFormat f = VoxelFormat::luanti();
		uint32_t word = 0;
		f.id.set(word, 0xabcd);
		f.light_sky.set(word, 7);
		f.light_lamp.set(word, 9);
		f.param.set(word, 0x5e);
		assert(f.id_of(word) == 0xabcd);
		assert(f.light_sky.get(word) == 7);
		assert(f.light_lamp.get(word) == 9);
		assert(f.param.get(word) == 0x5e);
	}

	// [SECURITY_RUN_5] A saved format that does not validate is refused by
	// migrate_volume(), not read past a VoxelSample's planes: a role on
	// plane 200, and a plane named at index 9 of ten
	{
		const VoxelFormat to = VoxelFormat::default_cut();
		const pv::Region r(pv::Vector3DInt32(0, 0, 0), pv::Vector3DInt32(1, 1, 1));
		VoxelFormat a = to;
		a.id = VoxelField{200, 0, 21};
		VoxelFormat b;
		b.planes.push_back(VoxelPlane{"", 32});
		for(int i = 1; i < 10; i++)
			b.planes.push_back(VoxelPlane{"p"+itos(i), 8});
		VoxelFormat to_b = to;
		to_b.planes.push_back(VoxelPlane{"p9", 8});
		ss_ why;
		assert(!migrate_volume(VoxelVolume(r, a.planes), a, to, &why));
		assert(!migrate_volume(VoxelVolume(r, b.planes), b, to_b, &why));
	}

	return true;
}

VoxelRegistry* createVoxelRegistry()
{
	// Cheap, once per process, and it is the only place every build passes
	// through before a voxel exists
	static const bool tested = voxel_format_self_test() &&
			voxel_selector_self_test() && voxel_volume_self_test();
	(void)tested;
	return new CVoxelRegistry();
}

void VoxelRegistry::serialize(std::ostream &os)
{
	sv_<VoxelDefinition> defs = get_all();
	VoxelFormat format = get_format();
	VoxelSelector look = get_look_selector();
	cereal::PortableBinaryOutputArchive archive(os);
	archive((uint8_t)3, format, defs, look);
}

void VoxelRegistry::deserialize(std::istream &is)
{
	uint8_t version = 0;
	VoxelFormat format;
	sv_<VoxelDefinition> defs;
	VoxelSelector look;
	cereal::PortableBinaryInputArchive archive(is);
	archive(version);
	if(version == 3){
		archive(format, defs, look);
	} else if(version == 2){
		// 0.6's, in a saved world (voxel_cereal_legacy.h)
		legacy06::read(archive, format);
		legacy06::read_vector(archive, defs,
				[](legacy06::In &a, VoxelDefinition &d){ legacy06::read(a, d); });
		legacy06::read(archive, look);
	} else {
		throw Exception(ss_()+"VoxelRegistry::deserialize(): format "+
				itos(version)+", where this reads 3 (and 0.6's 2)");
	}
	clear();
	set_format(format);
	// In one go: a registry arriving over the network is thousands of
	// definitions and this is the client's own frame ([CLIENT_FRAME])
	add_voxels(defs);
	// After the definitions, because the selector points at them
	set_look_selector(look);
}

ss_ VoxelRegistry::serialize()
{
	std::ostringstream os(std::ios::binary);
	serialize(os);
	return os.str();
}

void VoxelRegistry::deserialize(const ss_ &s)
{
	std::istringstream is(s, std::ios::binary);
	deserialize(is);
}

} // interface
// vim: set noet ts=4 sw=4:
