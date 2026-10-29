// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Skylight and the light flood, included by voxelworld.cpp inside struct
// CInstance ([SPLITS]: moved out as it was).

	// Skylight
	//
	// Air voxels hold the light itself. Voxels that block light hold the
	// brightest light next to them instead, which is what the mesher reads
	// when the air voxel in front of a face is in a chunk it is not meshing.

	// What the three questions below ask the registry, with the last answer
	// kept. They are asked of every voxel a write or a light flood touches
	// -- a section is a quarter of a million of them -- and those are nearly
	// all the same handful of types, stone under air. Asking is a virtual
	// call and a couple of loads; comparing the sample is neither.
	//
	// An entry never moves and a new voxel type does not change an old one's,
	// so what would invalidate this is the registry being cleared, which
	// does not happen to a server's. update_id_maps() drops it anyway, being
	// the one place here that adds a type.
	interface::VoxelSample m_def_memo_key;
	const interface::CachedVoxelDefinition *m_def_memo = nullptr;

	const interface::CachedVoxelDefinition* cached_of(
			const interface::VoxelSample &v)
	{
		if(m_def_memo != nullptr &&
				memcmp(&v, &m_def_memo_key, sizeof(v)) == 0)
			return m_def_memo;
		const interface::CachedVoxelDefinition *def =
				m_voxel_reg->get_cached(v);
		if(def != nullptr){
			m_def_memo_key = v;
			m_def_memo = def;
		}
		return def;
	}

	// Whether nothing at all occupies the voxel. Not the same as
	// voxel_transmits_light(): a voxel can leave the faces against it
	// undrawn and still hold a mesh of its own inside itself, and such a
	// voxel is not free for something else to take.
	bool voxel_is_fully_empty(const interface::VoxelSample &v)
	{
		if(is_undefined(VoxelInstance(v.planes[0])))
			return false;
		const interface::CachedVoxelDefinition *def = cached_of(v);
		if(def == nullptr)
			return false;
		return def->fully_empty;
	}

	// What a voxel makes of its own light, by value. Only asked while lamp
	// light is maintained, so a world without it pays nothing.
	uint8_t voxel_light_source(const interface::VoxelSample &v)
	{
		if(is_undefined(VoxelInstance(v.planes[0])))
			return 0;
		const interface::CachedVoxelDefinition *def = cached_of(v);
		return def ? def->light_source : 0;
	}

	// Whether the sunlight column goes on through the voxel undiminished,
	// which is Luanti's sunlight_propagates and not the same question as
	// whether light gets past at all ([WATER_LIGHT]): water lets light
	// through a level at a time in every direction, the column included, so
	// a pool ten deep is not lit like its surface. A voxel with nothing in
	// it propagates by being nothing; anything else says so, which is what
	// transmits_light carries (luanti.cpp registers it from the game's
	// sunlight_propagates). A shaped voxel leaves its edges empty so that
	// its neighbours draw their faces, and that is what used to answer this.
	bool voxel_propagates_sunlight(const interface::VoxelSample &v)
	{
		if(is_undefined(VoxelInstance(v.planes[0])))
			return false;
		const interface::CachedVoxelDefinition *def = cached_of(v);
		if(def == nullptr)
			return false;
		return def->fully_empty || def->transmits_light;
	}

	bool voxel_transmits_light(const interface::VoxelSample &v)
	{
		if(is_undefined(VoxelInstance(v.planes[0])))
			return false;
		const interface::CachedVoxelDefinition *def = cached_of(v);
		if(def == nullptr)
			return false;
		// Two ways light gets past a voxel: nothing is there, or something
		// is and the sky is seen through it anyway. See
		// VoxelDefinition::transmits_light.
		return def->edge_material_id == interface::EDGEMATERIALID_EMPTY ||
				def->transmits_light;
	}

	// Voxels in the topmost row of the world see the open sky
	// Where the sky reaches a voxel from outside the world's own data.
	//
	// The top of the section region is the formal answer, and on a
	// Luanti-sized map that is thirty thousand voxels up and never loaded,
	// so it never fires: what lit a generated world was the mapgen writing
	// the light once and the flood keeping it. That leaves a re-flood with
	// no source of its own -- relight_if_stale() zeroes a section before it
	// re-floods it, and it could only get the daylight back from a
	// neighbouring section that still had some. A section zeroed while the
	// lit one above it was out of memory stayed dark for ever and was then
	// the dark neighbour for the next one relit beside it, which is a
	// played world going dark in patches ([UNDERGROUND_LIGHT], 2026-09-28:
	// a played VoxeLibre world read daylight 0 in open air thirty nodes
	// above its own canopy where the same seed generated afresh reads 15,
	// and core.fix_light() could not bring it back).
	//
	// So the top of the *data* answers too: a voxel at the top of its own
	// section whose column walks up through clear air and out of the loaded
	// world is under the open sky. That is Luanti's own rule -- its
	// propagateSunlight() takes the ignore above a chunk as sunlit -- and
	// the same one mesh.cpp's horizon_says() uses where a ray leaves the
	// volume ("walked out under the open sky").
	//
	// simplified: a cave section relit while the rock above it happens to
	// be out of memory reads as sky. The sections above a loaded one are
	// loaded too inside a load point's radius, so what this answers in
	// practice is the top of the loaded column; the principled version
	// wants the column's surface height, which voxelworld does not keep --
	// mesh.cpp's horizon map is where that lives.
	//
	// Only asked of a voxel at the top edge of its section, so the walk is
	// one column per section face rather than one per seed.
	// The lowest voxel in a column the sky still reaches: everything above
	// the highest thing that stops light, and the whole column where
	// nothing does. Walked from the top of the world down, a whole section
	// at a step where the section is not loaded -- there is no data there
	// and above the terrain that is sky.
	//
	// Cached per column for the run of one flood, because a relight seeds a
	// section's whole face and those seeds share their columns; cleared
	// wherever a flood begins, since a write can move a column's top.
	sm_<uint64_t, int32_t> m_open_sky_from;

	void forget_open_sky()
	{
		m_open_sky_from.clear();
	}

	int32_t open_sky_from(int32_t x, int32_t z)
	{
		const uint64_t key = ((uint64_t)(uint32_t)x << 32) | (uint32_t)z;
		auto it = m_open_sky_from.find(key);
		if(it != m_open_sky_from.end())
			return it->second;
		const int section_h = m_section_size_chunks.getY() *
				m_chunk_size_voxels.getY();
		const int32_t region_top =
				(m_section_region.getUpperCorner().getY() + 1) * section_h - 1;
		const int32_t region_bottom =
				(int32_t)m_section_region.getLowerCorner().getY() * section_h;
		int32_t from = region_bottom;
		// **No data is sky until the column has shown some.** Above the
		// terrain a chunk was never generated and is not in memory, and
		// that is where the daylight comes from; below it, a gap in what
		// is loaded says nothing, so the walk stops there rather than
		// lighting a cave through a chunk it cannot see.
		bool seen_data = false;
		for(int32_t y = region_top; y >= region_bottom; ){
			const pv::Vector3DInt32 q(x, y, z);
			const pv::Vector3DInt16 qs = section_of_voxel(q);
			Section *section = get_section(qs);
			if(section == nullptr || !section->loaded){
				if(seen_data){
					from = y + 1;
					break;
				}
				// Step over the whole section rather than every voxel of it
				y = (int32_t)qs.getY() * section_h - 1;
				continue;
			}
			const pv::Vector3DInt32 chunk_p =
					container_coord(q, m_chunk_size_voxels);
			ChunkBuffer &buf =
					section->chunk_buffers[section->get_chunk_i(chunk_p)];
			if(!buf.volume){
				// The section is loaded and this chunk of it is not: read
				// as no data, and not pulled in -- a walk that loaded a
				// column would load the world
				if(seen_data){
					from = y + 1;
					break;
				}
				y = chunk_p.getY() * m_chunk_size_voxels.getY() - 1;
				continue;
			}
			seen_data = true;
			// **Sunlight's own predicate, not "light gets past".** Water
			// and leaves let light through and still take a level off the
			// sunlight going down a column, which is the difference
			// voxel_propagates_sunlight() carries: water_light.sh reads a
			// water column that falls a level a node, and with
			// voxel_transmits_light() here the walk went straight through
			// it and seeded the whole column at fifteen.
			if(!voxel_propagates_sunlight(
					buf.volume->sample_at(light_local_p(q, chunk_p)))){
				from = y + 1;
				break;
			}
			y--;
		}
		m_open_sky_from[key] = from;
		return from;
	}

	// **Where the sky reaches, wherever it is asked about.**
	//
	// It used to be one row of voxels at the top of the section region,
	// which on a Luanti-sized map is thirty thousand voxels up and never
	// loaded, so it never fired; then the top edge of a section whose
	// column walked out of the data, which fired only for the section at
	// the top of the loaded column. That second one left every relight
	// below it with no source of its own: `/fixlight` over a box whose top
	// was under the loaded column zeroed the box and could not fill it
	// again -- measured on a played world, where the same command with a
	// taller box put the whole column back to 15 and with a shorter one
	// changed nothing ([UNDERGROUND_LIGHT], 2026-09-28). So the column is
	// asked for whatever voxel wants to know.
	// **On by default since 2026-09-28**, and it was off for a day before
	// that. The column rule is what lets a relight put daylight back at
	// all -- without it core.fix_light() over a box whose top is under the
	// loaded column zeroes the box and cannot fill it again, which is a
	// played world that cannot be mended: on a copy of the user's
	// c55_mc2_12, /fixlight with the rule off left every reading where it
	// was and the picture broken, and with it on put the open columns back
	// to fifteen and drew a world with a sky in it.
	// What held it off was apps/sample_lighting_scene's cave going 92% black
	// with it on (RMSE 37.3 against a bar of 30), and that was the
	// generator being asked a question only a relight can answer; see
	// SkylightSeed::from_relight. With that fixed the same view reads 1.9
	// and the check passes, water_light.sh still falls a level a node and
	// diglight.sh still reads its gradient.
	//
	// The old rule was the top of the section region and nothing else,
	// which on a Luanti-sized map never fires; BUILDAT_SKY_COLUMN=0 put it
	// back until [SKY_COLUMN_CAVE] was closed (2026-10-03).
	// **The column is only asked for a relight** (from_relight): during
	// worldgen the column above a voxel is half made and open_sky_from()
	// then calls a cave open sky. The region's own top row is asked for
	// every seed, as it always was -- on a small world it is the sky the
	// generator's own flood comes from, and taking it away from
	// generation seeds left apps/sample_lighting_scene 126560 voxels dark
	// (2026-09-28).
	bool is_below_open_sky(const pv::Vector3DInt32 &p, bool from_relight)
	{
		const int section_h = m_section_size_chunks.getY() *
				m_chunk_size_voxels.getY();
		if(p.getY() == (m_section_region.getUpperCorner().getY() + 1) *
				section_h - 1)
			return true;
		if(!from_relight)
			return false;
		return p.getY() >= open_sky_from(p.getX(), p.getZ());
	}

	struct LightNode
	{
		pv::Vector3DInt32 p;
		uint8_t level;
	};

	// The light update walks one voxel at a time and nearly every step stays
	// inside the chunk the last one was in, so it keeps that chunk's buffer
	// rather than going through get_voxel()/set_voxel() and their section
	// lookup and bookkeeping for every neighbour. Only crossing a chunk
	// boundary costs a lookup. Nothing is unloaded while this is in use, so
	// the buffer stays put.
	pv::Vector3DInt32 m_light_chunk_p;
	ChunkBuffer *m_light_buf = nullptr;
	pv::Vector3DInt16 m_light_section_p;
	Section *m_light_section = nullptr;
	// World position of the cached chunk's first voxel, so that a position
	// inside it can be turned into a local one by subtraction. Dividing to
	// find the chunk costs more than everything else the light update does.
	pv::Vector3DInt32 m_light_chunk_lc;
	// Indexed by voxel type id: 1 transmits light, 0 does not, 2 not asked yet
	sv_<uint8_t> m_light_transmits;

	ChunkBuffer* light_buffer(const pv::Vector3DInt32 &chunk_p)
	{
		if(m_light_buf && chunk_p == m_light_chunk_p)
			return m_light_buf;
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = m_light_section;
		if(section == nullptr || section_p != m_light_section_p){
			section = get_section(section_p);
			if(section == nullptr){
				// The light reached a section that is not in memory. What
				// it holds may now be wrong either way, so it is marked and
				// re-flooded when it is loaded -- rather than pulled in
				// here, which one node at the top of a shaft would do all
				// the way down it.
				mark_section_stale(section_p);
				return nullptr;
			}
			list_loaded(section);
			m_light_section = section;
			m_light_section_p = section_p;
		}
		// Reached straight into rather than through get_buffer(), which reads
		// the clock to timestamp the buffer on every call; the light update
		// changes chunk often enough for that to be most of its time. Loading
		// one that is not in memory still goes the long way.
		ChunkBuffer &buf = section->chunk_buffers[section->get_chunk_i(chunk_p)];
		if(!buf.volume){
			if(!section->get_buffer(chunk_p, m_server,
					&m_total_buffers_loaded).volume)
				return nullptr;
		}
		m_light_chunk_p = chunk_p;
		m_light_chunk_lc = pv::Vector3DInt32(
				chunk_p.getX() * m_chunk_size_voxels.getX(),
				chunk_p.getY() * m_chunk_size_voxels.getY(),
				chunk_p.getZ() * m_chunk_size_voxels.getZ());
		m_light_buf = &buf;
		return m_light_buf;
	}

	pv::Vector3DInt32 light_local_p(const pv::Vector3DInt32 &p,
			const pv::Vector3DInt32 &chunk_p)
	{
		return pv::Vector3DInt32(
				p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX(),
				p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY(),
				p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ());
	}

	VoxelInstance light_get(const pv::Vector3DInt32 &p)
	{
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		ChunkBuffer *buf = light_buffer(chunk_p);
		if(buf == nullptr)
			return VoxelInstance(interface::VOXELTYPEID_UNDEFINED);
		return buf->volume->getVoxelAt(light_local_p(p, chunk_p));
	}

	// Give the voxels that block light the brightest light next to them, by
	// pushing each new light value into the blocking neighbours of the voxel
	// that got it. Only ever raises one, so it is right on its own as long as
	// no light went away; update_skylight() recomputes the few that did.
	// Which light the flood below is maintaining. One field is brought up
	// to date at a time, so this is set for the run rather than threaded
	// through every helper of it.
	LightField m_light_running = LIGHT_SKY;

	uint8_t flood_get(const VoxelInstance &v)
	{
		return get_light(v, m_light_running);
	}

	void flood_set(VoxelInstance &v, uint8_t level)
	{
		set_light(v, level, m_light_running);
	}

	uint8_t flood_max()
	{
		return light_max(m_light_running);
	}

	// Light a voxel makes of its own, which is what lamp light floods from:
	// a torch, a lava flow. The sky has no emitters -- its source is the
	// open sky above the world and the light already stored in a voxel.
	uint8_t emitted_at(const pv::Vector3DInt32 &p)
	{
		if(m_light_running != LIGHT_LAMP)
			return 0;
		VoxelInstance v = light_get(p);
		const interface::CachedVoxelDefinition *def = cached_of(sample_of(v));
		return def ? def->light_source : 0;
	}

	// A voxel light does not pass through wears the brightest light beside
	// it, which is what the mesher reads off a face; one that makes its own
	// light keeps that whatever is around it.
	void light_blocker_from_neighbours(const pv::Vector3DInt32 &p)
	{
		VoxelInstance v = light_get(p);
		if(transmits_light_at(p))
			return;
		uint8_t best = emitted_at(p);
		for(size_t k = 0; k < 6; k++){
			pv::Vector3DInt32 np(
					p.getX() + LIGHT_OFF[k][0],
					p.getY() + LIGHT_OFF[k][1],
					p.getZ() + LIGHT_OFF[k][2]);
			VoxelInstance nv = light_get(np);
			if(transmits_light_at(np) && flood_get(nv) > best)
				best = flood_get(nv);
		}
		if(flood_get(v) != best)
			light_set(p, v, best);
	}

	void light_bleed_into_blockers(const pv::Vector3DInt32 &p, uint8_t level)
	{
		for(size_t k = 0; k < 6; k++){
			pv::Vector3DInt32 n(p.getX() + LIGHT_OFF[k][0],
					p.getY() + LIGHT_OFF[k][1], p.getZ() + LIGHT_OFF[k][2]);
			VoxelInstance nv = light_get(n);
			if(transmits_light_at(n) || flood_get(nv) >= level)
				continue;
			light_set(n, nv, level);
		}
	}

	void light_set(const pv::Vector3DInt32 &p, VoxelInstance v, uint8_t level)
	{
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		ChunkBuffer *buf = light_buffer(chunk_p);
		if(buf == nullptr)
			return;
		flood_set(v, level);
		buf->volume->setVoxelAt(light_local_p(p, chunk_p), v);
		buf->interior_dirty = true;
		if(!buf->dirty){
			buf->dirty = true;
			m_total_buffers_dirty++;
		}
	}

	// Whether light passes through the voxel at p.
	//
	// By position rather than by value, and without the cache-by-id it used
	// to have, because **a voxel is its planes**: which definition it wears
	// can depend on any of them, and the first plane's id role says only
	// whether the voxel has been generated in a world whose looks come from
	// rules. What is left is the registry's own cached-definition array,
	// which is an index and a mutex.
	//
	// simplified: that mutex is now taken once per voxel of a light flood
	// where the cache made it once per id. If a flood ever shows up in a
	// profile, the fix is a per-flood memo keyed on the planes the rules
	// actually read.
	bool transmits_light_at(const pv::Vector3DInt32 &p)
	{
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		ChunkBuffer *buf = light_buffer(chunk_p);
		if(buf == nullptr)
			return false;
		return voxel_transmits_light(
				buf->volume->sample_at(light_local_p(p, chunk_p)));
	}

	// See voxel_propagates_sunlight(): asked of the voxel the column is
	// about to enter
	bool propagates_sunlight_at(const pv::Vector3DInt32 &p)
	{
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		ChunkBuffer *buf = light_buffer(chunk_p);
		if(buf == nullptr)
			return false;
		return voxel_propagates_sunlight(
				buf->volume->sample_at(light_local_p(p, chunk_p)));
	}

	// Bring the skylight up to date after the voxels in m_light_seeds[LIGHT_SKY]
	// changed. Light is taken out of everything the changed voxels were
	// lighting, and then spread back in from whatever still has light, so the
	// work done is proportional to how far the change reaches rather than to
	// the size of the world. Neighbours are read in world coordinates, so this
	// crosses chunk and section boundaries by itself; a section that is not in
	// memory reads as undefined and stops the light, which keeps an edit next
	// to the edge of the loaded world from running away.
	// Every light the world maintains, each in turn
	// A flood in progress, kept between ticks ([STEP_SLICE]): the deferred
	// relight of a section is a breadth-first flood over its air, 100-200
	// ms for a VoxeLibre section, and one tick may not hold it. The
	// queues and the indices into them are the whole state; a flood that
	// stops at its deadline goes on where it was on the next call, and
	// what it has written so far is committed like any other write, so a
	// section may be seen half-lit for a tick or two.
	struct FloodState
	{
		bool active = false;
		std::vector<LightNode> unlight, spread;
		// Voxels that block light next to light that went away. Only
		// these have to be worked out the slow way; everywhere else the
		// light is pushed into them as it is written.
		std::vector<pv::Vector3DInt32> blockers;
		size_t ui = 0, si = 0, seeds_n = 0;
		std::chrono::steady_clock::time_point t0;
	};
	FloodState m_flood[NUM_LIGHT_FIELDS];

	void update_skylight()
	{
		for(size_t f = 0; f < NUM_LIGHT_FIELDS; f++)
			update_light((LightField)f, 0);
	}

	// A write's seeds flooded now, to the end, while a deferred relight's
	// flood is under way and would otherwise take them on its end -- ticks
	// or seconds later under relight_stale()'s budget: a placed lamp lit
	// nothing in the reference set's vp8 and check_map read its room lit
	// before the flood ([DIG_LIGHT], [CHECK_MAP_FLAKE]). The relight's
	// state is put aside, the seeds run as a flood of their own, and the
	// relight goes on where it was; the two write the same voxels and the
	// relight's pass, which takes light out and lets it back in, settles
	// whatever they disagree on.
	// Only a handful of seeds -- a player's dig or placement; a relight's
	// pass seeds a section by the ten thousand into the same queue, and
	// those are the sliced flood's to take under its budget, not this
	// one's to run at once (a probe cycle stalled on it, 2026-09-20).
	static const size_t NOW_SEEDS_MAX = 256;
	void update_skylight_now()
	{
		for(size_t f = 0; f < NUM_LIGHT_FIELDS; f++){
			if(m_light_seeds[f].empty() ||
					m_light_seeds[f].size() > NOW_SEEDS_MAX)
				continue;
			FloodState paused;
			paused.active = m_flood[f].active;
			paused.unlight.swap(m_flood[f].unlight);
			paused.spread.swap(m_flood[f].spread);
			paused.blockers.swap(m_flood[f].blockers);
			paused.ui = m_flood[f].ui; paused.si = m_flood[f].si;
			paused.seeds_n = m_flood[f].seeds_n; paused.t0 = m_flood[f].t0;
			m_flood[f] = FloodState();
			update_light((LightField)f, 0);
			m_flood[f].active = paused.active;
			m_flood[f].unlight.swap(paused.unlight);
			m_flood[f].spread.swap(paused.spread);
			m_flood[f].blockers.swap(paused.blockers);
			m_flood[f].ui = paused.ui; m_flood[f].si = paused.si;
			m_flood[f].seeds_n = paused.seeds_n; m_flood[f].t0 = paused.t0;
		}
	}

	// Every field's flood until the deadline (microseconds of time_us(),
	// 0 for none); false when one is still unfinished
	bool update_skylight_until(int64_t deadline_us)
	{
		// The columns the seeds are about may have moved since the last
		// flood; see open_sky_from()
		forget_open_sky();
		bool done = true;
		for(size_t f = 0; f < NUM_LIGHT_FIELDS; f++)
			done = update_light((LightField)f, deadline_us) && done;
		return done;
	}

	// Returns false when the deadline stopped it before the end
	bool update_light(LightField field, int64_t deadline_us)
	{
		FloodState &st = m_flood[field];
		auto over = [&](){
			return deadline_us != 0 && interface::os::time_us() >= deadline_us;
		};
		std::vector<SkylightSeed> seeds;
		if(!st.active){
			seeds.swap(m_light_seeds[field]);
			if(!m_light_maintained[field] || seeds.empty())
				return true;
			st = FloodState();
			st.active = true;
			st.t0 = std::chrono::steady_clock::now();
			st.seeds_n = seeds.size();
		} else if(!m_light_seeds[field].empty()){
			// New seeds while a flood runs go on the end of it
			seeds.swap(m_light_seeds[field]);
			st.seeds_n += seeds.size();
		}
		m_light_running = field;
		m_light_buf = nullptr;
		m_light_section = nullptr;

		std::vector<LightNode> &unlight = st.unlight;
		std::vector<LightNode> &spread = st.spread;
		std::vector<pv::Vector3DInt32> &blockers = st.blockers;

		for(size_t si = 0; si < seeds.size(); si++){
			// The seeds are the slow half under a flood ([FLOOD_STEP]: a
			// liquid pass's 11 806 seeds took 1.9 s with 1210 spread --
			// each one scattered over the sea, its chunk's buffer loaded
			// for it); over the deadline the rest go back to the front of
			// the queue and this returns unfinished, the next call's first
			if((si & 63) == 63 && over()){
				m_light_seeds[field].insert(m_light_seeds[field].begin(),
						seeds.begin() + si, seeds.end());
				st.seeds_n -= seeds.size() - si;
				return false;
			}
			const SkylightSeed &seed = seeds[si];
			VoxelInstance v = light_get(seed.p);
			bool now_transparent = transmits_light_at(seed.p);
			// A handful of seeds is a player's dig: said one by one, so a
			// dig whose light does not come out right can be read off
			// the log ([DIG_LIGHT])
			if(seeds.size() <= 4){
				log_d(MODULE, "%s seed " PV3I_FORMAT ": was %s now %s, old %u, "
						"holds %u, emits %u", field == LIGHT_SKY ? "sky" : "lamp",
						PV3I_PARAMS(seed.p),
						seed.was_transparent ? "clear" : "solid",
						now_transparent ? "clear" : "solid",
						(unsigned)seed.old_level, (unsigned)flood_get(v),
						(unsigned)emitted_at(seed.p));
				for(size_t k = 0; k < 6; k++){
					pv::Vector3DInt32 n(
							seed.p.getX() + LIGHT_OFF[k][0],
							seed.p.getY() + LIGHT_OFF[k][1],
							seed.p.getZ() + LIGHT_OFF[k][2]);
					log_d(MODULE, "  beside " PV3I_FORMAT ": %s, holds %u",
							PV3I_PARAMS(n),
							transmits_light_at(n) ? "clear" : "solid",
							(unsigned)flood_get(light_get(n)));
				}
			}
			if(seed.was_transparent && !now_transparent){
				// It took its light with it
				unlight.push_back(LightNode{seed.p, seed.old_level});
				blockers.push_back(seed.p);
				// Unless what arrived makes its own light. A torch is a
				// solid node that nothing sees through and it still lights
				// the room: an emitter is a source whether or not light
				// passes through it.
				const uint8_t emitted = emitted_at(seed.p);
				if(emitted > 0){
					light_set(seed.p, v, emitted);
					spread.push_back(LightNode{seed.p, emitted});
				}
			} else if(!seed.was_transparent && now_transparent){
				// It has to be filled from around it, unless it is a source
				// itself: the open sky above the world, a voxel that makes
				// its own light, or one the generator lit -- which is what
				// makes the sky reach the ground in a world whose region
				// top is thirty thousand voxels up and never loaded
				uint8_t l = flood_get(v);
				const uint8_t emitted = emitted_at(seed.p);

				// Unless what went was a light source of its own: a torch
				// is solid and lights the room, and taking one away has to
				// take its light with it. What it holds is that light --
				// a blocker wears the brightest light beside it so the
				// mesher has something to read off its faces -- so it is
				// cleared here rather than spread back out.
				//
				// Found through nodecore, whose player hand is a node with
				// light_source 14 that blocks light: the startup map check
				// put one in a room, took it out again, and the room stayed
				// lit at 13. devtest's own lamps are glasslike and let light
				// through, which is the other branch and has always worked.
				if(seed.old_emitted > emitted){
					light_set(seed.p, v, 0);
					unlight.push_back(LightNode{seed.p, seed.old_emitted});
					l = 0;
				}

				if(field == LIGHT_SKY &&
						is_below_open_sky(seed.p, seed.from_relight))
					l = flood_max();
				if(emitted > l)
					l = emitted;
				light_set(seed.p, v, l);
				if(l > 0){
					spread.push_back(LightNode{seed.p, l});
					light_bleed_into_blockers(seed.p, l);
				}
				for(size_t k = 0; k < 6; k++){
					pv::Vector3DInt32 n(
							seed.p.getX() + LIGHT_OFF[k][0],
							seed.p.getY() + LIGHT_OFF[k][1],
							seed.p.getZ() + LIGHT_OFF[k][2]);
					VoxelInstance nv = light_get(n);
					if(!transmits_light_at(n))
						continue;
					if(flood_get(nv) > 0)
						spread.push_back(LightNode{n, flood_get(nv)});
				}
			} else {
				// Transparency did not change, so what changed is what the
				// voxel makes of its own light: a torch put down or taken
				// away. More than it holds makes it a source; less means
				// the light it was giving has to be taken back.
				const uint8_t emitted = emitted_at(seed.p);
				const uint8_t held = flood_get(v);
				if(emitted > held){
					light_set(seed.p, v, emitted);
					spread.push_back(LightNode{seed.p, emitted});
					light_bleed_into_blockers(seed.p, emitted);
				} else if(seed.old_level > 0 && emitted < seed.old_level){
					light_set(seed.p, v, 0);
					unlight.push_back(LightNode{seed.p, seed.old_level});
				}
			}
		}

		// Take the light out. A neighbour dimmer than where the light is being
		// removed from was lit by it and goes dark too; one that is as bright
		// or brighter is lit by something else and becomes a source to spread
		// back from. Straight down is the exception: light does not dim on the
		// way down, so a full strength voxel below a full strength one was
		// still lit by it.
		for(size_t &i = st.ui; i < unlight.size(); i++){
			if((i & 255) == 255 && over())
				return false;
			LightNode node = unlight[i];
			for(size_t k = 0; k < 6; k++){
				pv::Vector3DInt32 n(
						node.p.getX() + LIGHT_OFF[k][0],
						node.p.getY() + LIGHT_OFF[k][1],
						node.p.getZ() + LIGHT_OFF[k][2]);
				VoxelInstance nv = light_get(n);
				if(!transmits_light_at(n)){
					// It may have been holding the light that is going away
					blockers.push_back(n);
					continue;
				}
				uint8_t nl = flood_get(nv);
				if(nl == 0)
					continue;
				bool lit_from_above = (field == LIGHT_SKY &&
						k == LIGHT_DOWN && node.level == flood_max() &&
						nl == flood_max() && propagates_sunlight_at(n));
				if(nl < node.level || lit_from_above){
					light_set(n, nv, 0);
					unlight.push_back(LightNode{n, nl});
				} else {
					spread.push_back(LightNode{n, nl});
				}
			}
		}

		// Spread it back in
		for(size_t &i = st.si; i < spread.size(); i++){
			if((i & 255) == 255 && over())
				return false;
			LightNode node = spread[i];
			if(node.level == 0)
				continue;
			// Spread whatever the voxel holds now, not what it held when it
			// was put on the list: a source can be unlit by another branch
			// after it was queued, and spreading the level it used to have
			// would put light back where it was just taken from.
			VoxelInstance v = light_get(node.p);
			const uint8_t emitted = emitted_at(node.p);
			// A voxel light does not pass through spreads nothing, unless
			// it is making the light itself
			if(!transmits_light_at(node.p) && emitted == 0)
				continue;
			node.level = flood_get(v);
			if(emitted > node.level){
				node.level = emitted;
				light_set(node.p, v, node.level);
			}
			if(node.level == 0)
				continue;
			for(size_t k = 0; k < 6; k++){
				pv::Vector3DInt32 n(
						node.p.getX() + LIGHT_OFF[k][0],
						node.p.getY() + LIGHT_OFF[k][1],
						node.p.getZ() + LIGHT_OFF[k][2]);
				VoxelInstance nv = light_get(n);
				if(!transmits_light_at(n)){
					if(flood_get(nv) < node.level)
						light_set(n, nv, node.level);
					continue;
				}
				uint8_t target = (field == LIGHT_SKY &&
						k == LIGHT_DOWN && node.level == flood_max() &&
						propagates_sunlight_at(n)) ?
						flood_max() : node.level - 1;
				if(target > flood_get(nv)){
					light_set(n, nv, target);
					spread.push_back(LightNode{n, target});
				}
			}
		}

		// Give the voxels that block light the brightest light next to them.
		// The same one is reached from every transparent voxel around it, so
		// this is mostly duplicates by now and recomputing each of them costs
		// seven voxel reads.
		auto before = [](const pv::Vector3DInt32 &a, const pv::Vector3DInt32 &b){
			if(a.getX() != b.getX()) return a.getX() < b.getX();
			if(a.getY() != b.getY()) return a.getY() < b.getY();
			return a.getZ() < b.getZ();
		};
		std::sort(blockers.begin(), blockers.end(), before);
		blockers.erase(std::unique(blockers.begin(), blockers.end()),
				blockers.end());
		size_t n_blockers = blockers.size();
		for(const pv::Vector3DInt32 &p : blockers)
			light_blocker_from_neighbours(p);

		const int took_ms =
				(int)std::chrono::duration_cast<std::chrono::milliseconds>(
				std::chrono::steady_clock::now() - st.t0).count();
		// Said out loud when it is slow, because this runs at the end of
		// every access into voxelworld and everything waiting to get in
		// waits for it: a game that builds its terrain in on_generated --
		// VoxeLibre does -- hands it a section's worth of seeds at a time,
		// and a caller that only wanted to read a node is behind that.
		static const int SLOW_LIGHT_MS = 500;
		log_(took_ms >= SLOW_LIGHT_MS ? CORE_WARNING : CORE_VERBOSE, MODULE,
				"update_skylight(): %zu seeds, %zu unlit, %zu spread, "
				"%zu blockers in %i ms", st.seeds_n, unlight.size(),
				spread.size(), n_blockers, took_ms);
		st = FloodState();
		return true;
	}
