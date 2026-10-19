// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// The save: chunk rows, the section index, the name and format tables and
// save(), included by voxelworld.cpp inside struct CInstance
// ([FILE_SPLITS_1019]: moved out as it was, the two parts of the file
// one after the other).

	// One chunk, one row. The section is the load and unload unit, but the
	// chunk is what a node holds and what the volume format describes, so a
	// key per chunk means no container format had to be invented for the
	// eight of them.
	ss_ chunk_key(const pv::Vector3DInt32 &chunk_p)
	{
		return m_world_name+"/"+itos(chunk_p.getX())+","+
				itos(chunk_p.getY())+","+itos(chunk_p.getZ());
	}

	// The generated mark, beside the section's chunks: "1" once a
	// generator has been over the section. A section a neighbour's
	// generator spilled into is saved before it is generated, and without
	// the mark it came back as generated and never was -- a hole in the
	// world ([UNGENERATED_SAVED] in doc/plan/world_persistence_plan.md).
	// A save from before the key has chunks and no mark, and those were
	// all generated for real.
	ss_ generated_key(const pv::Vector3DInt16 &section_p)
	{
		return m_world_name+"/s"+itos(section_p.getX())+","+
				itos(section_p.getY())+","+itos(section_p.getZ())+"/generated";
	}

	// [SAVE_LIMIT] The mark became the section's index: "i1 <generated>
	// <altered> <bytes> <day>". A mark from before ("1", "0") is altered
	// with its day unknown: nothing in an old save is forgotten until it has
	// been seen again.
	static ss_ index_row(bool generated, bool altered, int64_t bytes,
			int32_t day)
	{
		char buf[64];
		snprintf(buf, sizeof buf, "i1 %i %i %lld %i", generated ? 1 : 0,
				altered ? 1 : 0, (long long)bytes, (int)day);
		return buf;
	}
	static voxelworld::SectionStat parse_index_row(const ss_ &v)
	{
		voxelworld::SectionStat r;
		int g = 0, a = 0, d = -1;
		long long b = 0;
		if(v.compare(0, 3, "i1 ") == 0 &&
				sscanf(v.c_str() + 3, "%i %i %lld %i", &g, &a, &b, &d) == 4){
			r.generated = g != 0;
			r.altered = a != 0;
			r.bytes = b;
			r.day = d;
			return r;
		}
		// A newer Buildat's index ("i2 ..."): kept whole, never generated
		// over or trimmed. simplified: the save's format stamp refuses a
		// newer save before this; kept, not refused, should one get here
		if(v.size() >= 2 && v[0] == 'i' && isdigit((unsigned char)v[1])){
			r.generated = true;
			return r;
		}
		r.generated = (v == "1");
		return r;
	}
	static int32_t today()
	{
		return (int32_t)(interface::os::time_us() / 86400000000LL);
	}

	// What trim_to() takes, of stats, for need bytes: an unaltered section
	// none of whose 26 neighbours is altered, least recently visited first
	// and of a day the farthest from what is loaded; then, altered_days >=
	// 0, altered ones not visited in that many days, oldest first. Never a
	// loaded one, nor one not generated yet.
	static sv_<pv::Vector3DInt16> choose_forget(
			const sv_<voxelworld::SectionStat> &stats, int32_t day,
			int64_t need, int altered_days)
	{
		set_<uint64_t> altered;
		for(const auto &s : stats)
			if(s.altered)
				altered.insert(section_key(s.p));
		auto near_altered = [&](const pv::Vector3DInt16 &p){
			for(int dz = -1; dz <= 1; dz++)
			for(int dy = -1; dy <= 1; dy++)
			for(int dx = -1; dx <= 1; dx++){
				if(altered.count(section_key(pv::Vector3DInt16(p.getX() + dx,
						p.getY() + dy, p.getZ() + dz))))
					return true;
			}
			return false;
		};
		sv_<const voxelworld::SectionStat*> plain, old;
		for(const auto &s : stats){
			if(s.loaded || !s.generated)
				continue;
			if(!s.altered && !near_altered(s.p))
				plain.push_back(&s);
			else if(s.altered && altered_days >= 0 && s.day >= 0 &&
					day - s.day > altered_days)
				old.push_back(&s);
		}
		sv_<pv::Vector3DInt16> loaded;
		for(const auto &s : stats)
			if(s.loaded)
				loaded.push_back(s.p);
		std::map<const voxelworld::SectionStat*, int> away;
		for(const auto *list : {&plain, &old}){
			for(const auto *s : *list){
				int d = 0;
				for(size_t i = 0; i < loaded.size(); i++){
					const int e = std::max({std::abs(s->p.getX() -
							loaded[i].getX()), std::abs(s->p.getY() -
							loaded[i].getY()), std::abs(s->p.getZ() -
							loaded[i].getZ())});
					d = i == 0 ? e : std::min(d, e);
				}
				away[s] = d;
			}
		}
		auto by_day = [&](const voxelworld::SectionStat *a,
				const voxelworld::SectionStat *b){
			return a->day != b->day ? a->day < b->day : away[a] > away[b];
		};
		std::stable_sort(plain.begin(), plain.end(), by_day);
		std::stable_sort(old.begin(), old.end(), by_day);
		sv_<pv::Vector3DInt16> out;
		int64_t got = 0;
		for(const auto *list : {&plain, &old}){
			for(const auto *s : *list){
				if(got >= need)
					return out;
				out.push_back(s->p);
				got += std::max<int64_t>(s->bytes, 1);
			}
		}
		return out;
	}

	static void check_index()
	{
		auto check = [](bool ok){
			if(!ok)
				throw Exception("voxelworld: check_index failed");
		};
		auto r = parse_index_row(index_row(true, false, 1234, 20737));
		check(r.generated && !r.altered && r.bytes == 1234 && r.day == 20737);
		r = parse_index_row("1");
		check(r.generated && r.altered && r.day == -1);
		r = parse_index_row("0");
		check(!r.generated && r.altered);
		r = parse_index_row("i2 1 0 5 6 7");
		check(r.generated && r.altered);
		// Along x: 0 altered; 1 plain but beside 0, kept; 3 plain, visited
		// day 5; 5 plain, day 2; 7 altered, day 1; 9 plain but loaded; 11
		// plain, day 2, nearer 9 than 5 is
		sv_<voxelworld::SectionStat> g;
		auto add = [&](int x, bool alt, int day, bool loaded = false){
			voxelworld::SectionStat s;
			s.p = pv::Vector3DInt16(x, 0, 0);
			s.altered = alt;
			s.day = day;
			s.bytes = 100;
			s.loaded = loaded;
			g.push_back(s);
		};
		add(0, true, 9); add(1, false, 0); add(3, false, 5); add(5, false, 2);
		add(7, true, 1); add(9, false, 1, true); add(11, false, 2);
		auto pick = choose_forget(g, 10, 150, -1);
		check(pick.size() == 2 && pick[0].getX() == 5 && pick[1].getX() == 11);
		pick = choose_forget(g, 10, 1000, -1);
		check(pick.size() == 3 && pick[2].getX() == 3);
		pick = choose_forget(g, 10, 1000, 8);
		check(pick.size() == 4 && pick[3].getX() == 7); // 9 days unvisited
		pick = choose_forget(g, 10, 1000, 9);
		check(pick.size() == 3);
		log_v(MODULE, "check_index: rows round-trip, an old one is altered, "
				"the choice keeps the margin");
	}

	// A chunk's row in the save: a header naming the format the chunk was
	// written in, and then the blob replication already produces. The tag is
	// Luanti's MapBlock property and it buys what it buys there -- chunks
	// are independent of each other, so a save converges as sections are
	// touched instead of being rewritten in one go, and one unreadable chunk
	// is one unreadable chunk.
	static const size_t CHUNK_HEADER_SIZE = 6;

	ss_ chunk_row(const ss_ &blob)
	{
		ss_ row;
		row.reserve(CHUNK_HEADER_SIZE + blob.size());
		row += "BVC";
		row += (char)1;
		row += (char)(m_write_format & 0xff);
		row += (char)((m_write_format >> 8) & 0xff);
		row += blob;
		return row;
	}

	// A row without the header was written before there was one, and is in
	// the world's own format by definition -- there was only ever the one. A
	// cereal archive begins with an endianness byte and never with 'B', so
	// the two cannot be read for each other.
	bool split_chunk_row(const ss_ &row, uint16_t &format_out, ss_ &blob_out)
	{
		if(row.size() < CHUNK_HEADER_SIZE || row.compare(0, 3, "BVC") != 0){
			format_out = m_write_format;
			blob_out = row;
			return true;
		}
		if((uint8_t)row[3] != 1)
			return false;
		format_out = (uint16_t)(uint8_t)row[4] |
				((uint16_t)(uint8_t)row[5] << 8);
		blob_out = row.substr(CHUNK_HEADER_SIZE);
		return true;
	}

	// A chunk out of the save, in the cut and the numbering this world runs.
	// Byte for byte what was stored, in the common case.
	bool prepare_loaded_chunk(const pv::Vector3DInt32 &chunk_p,
			const ss_ &row, ss_ &data_out, bool &converted_out)
	{
		ss_ where = ss_("chunk ")+itos(chunk_p.getX())+","+
				itos(chunk_p.getY())+","+itos(chunk_p.getZ());
		uint16_t tag = 0;
		ss_ blob;
		if(!split_chunk_row(row, tag, blob)){
			refuse_save(where+" has a header this build does not know");
			return false;
		}
		if(tag == m_write_format && m_id_map_identity){
			data_out = blob;
			return true;
		}
		// What comes out is not what is on disk, so the section is written
		// back the next time it is unloaded: the save converges on the
		// world's own format as sections are touched, and nothing that was
		// not touched is rewritten
		converted_out = true;
		up_<VoxelVolume> volume = interface::deserialize_volume(blob);
		if(!volume){
			refuse_save(where+" is not in a volume format this build knows");
			return false;
		}
		const interface::VoxelFormat &format = m_voxel_reg->get_format();
		if(tag != m_write_format){
			if(tag >= m_save_formats.size()){
				refuse_save(where+" is tagged with format "+itos((int)tag)+
						", which the save's format table does not have");
				return false;
			}
			ss_ why;
			up_<VoxelVolume> moved = interface::migrate_volume(*volume,
					m_save_formats[tag], format, &why, m_migration);
			if(!moved){
				refuse_save(where+" was written in "+
						m_save_formats[tag].dump()+" and this world is "+
						format.dump()+": "+why);
				return false;
			}
			volume = std::move(moved);
		}
		if(!m_id_map_identity)
			interface::remap_volume_ids(*volume, format, m_save_to_session);
		data_out = interface::serialize_volume_compressed(*volume);
		return true;
	}

	// A chunk on its way into the save, in the save's numbering
	ss_ prepare_saved_chunk(const ss_ &blob)
	{
		if(m_id_map_identity)
			return blob;
		up_<VoxelVolume> volume = interface::deserialize_volume(blob);
		if(!volume)
			return blob;
		interface::remap_volume_ids(*volume, m_voxel_reg->get_format(),
				m_session_to_save);
		return interface::serialize_volume_compressed(*volume);
	}

	// Somehow get the section's static nodes and possible other nodes, either
	// by loading from the save or by creating new ones
	void load_section(Section &section)
	{
		if(section.loaded)
			return;
		section.loaded = true;
		pv::Vector3DInt16 section_p = section.section_p;
		log_d(MODULE, "Loading section " PV3I_FORMAT, PV3I_PARAMS(section_p));

		if(!m_store || !load_saved_section(section)){
			create_section(section);
			section.altered = false;
			section.visited_day = today();
		}
		// A section whose light went stale while it was away is flooded
		// again from what is around it now
		relight_if_stale(section);
		// What a game keeps of its own per section comes back with it
		m_server->emit_event("voxelworld:section_loaded",
				new SectionLoaded(m_scene_ref, section_p));
	}

	// True if the whole section was in the save. All or nothing: a section
	// with some of its chunks saved and some not would have to be both loaded
	// and generated, and generation is by section.
	bool load_saved_section(Section &section)
	{
		update_id_maps();
		if(!m_store) // update_id_maps() can refuse the save
			return false;
		auto lc = section.contained_chunks.getLowerCorner();
		auto uc = section.contained_chunks.getUpperCorner();
		sv_<ss_> chunks;
		chunks.reserve(section.num_chunks);
		bool converted = false;
		for(int z = 0; z <= uc.getZ() - lc.getZ(); z++){
			for(int y = 0; y <= uc.getY() - lc.getY(); y++){
				for(int x = 0; x <= uc.getX() - lc.getX(); x++){
					pv::Vector3DInt32 chunk_p(
							lc.getX() + x, lc.getY() + y, lc.getZ() + z);
					ss_ row;
					if(!m_store->get(chunk_key(chunk_p), row))
						return false;
					ss_ data;
					if(!prepare_loaded_chunk(chunk_p, row, data, converted))
						return false;
					chunks.push_back(data);
				}
			}
		}
		log_v(MODULE, "Loading section " PV3I_FORMAT " from the save",
				PV3I_PARAMS(section.section_p));
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene_ref);
			size_t i = 0;
			for(int z = 0; z <= uc.getZ() - lc.getZ(); z++){
				for(int y = 0; y <= uc.getY() - lc.getY(); y++){
					for(int x = 0; x <= uc.getX() - lc.getX(); x++){
						create_chunk_node(scene, section, x, y, z,
								&chunks[i++]);
					}
				}
			}
		});
		// Generated if the save says so, or if it predates the mark. A
		// section that is loaded and not generated goes to the generator
		// from load_or_generate_section(), whose merge writes by priority:
		// the terrain fills in around what was spilled rather than over it.
		ss_ mark;
		voxelworld::SectionStat row;
		if(m_store->get(generated_key(section.section_p), mark))
			row = parse_index_row(mark);
		section.generated = row.generated;
		section.altered = row.altered;
		section.saved_bytes = row.bytes;
		section.visited_day = row.day;
		if(!section.generated)
			log_v(MODULE, "Section " PV3I_FORMAT " came out of the save "
					"ungenerated", PV3I_PARAMS(section.section_p));
		section.modified = converted;
		return true;
	}

	// Writes the section's chunks as one transaction. Called when a section
	// is unloaded and when the world is saved as a whole; both are moments
	// where the data is about to stop being reachable.
	//
	// A section nothing has touched since it was read is not written at all,
	// which is what keeps saving a world people are only walking through
	// free. The flag is per section rather than per chunk because a section
	// is what is read and written as a unit.
	void save_section(Section &section)
	{
		// What the light reached while a section was away is written with
		// the sections, since it is about them
		save_stale_sections();
		if(!m_store || !section.loaded)
			return;
		if(!section.modified){
			// A day of a visit and nothing else: the row alone
			if(section.index_dirty){
				m_store->set(generated_key(section.section_p), index_row(
						section.generated && !section.awaiting,
						section.altered, section.saved_bytes,
						section.visited_day));
				section.index_dirty = false;
			}
			return;
		}
		update_id_maps();
		if(!m_store) // update_id_maps() can refuse the save
			return;
		sv_<ss_> keys;
		sv_<ss_> values;
		keys.reserve(section.num_chunks);
		values.reserve(section.num_chunks);
		const int64_t t0 = interface::os::time_us();
		int64_t t_in = 0;
		main_context::access(m_server, [&](main_context::Interface *imc){
			t_in = interface::os::time_us();
			Scene *scene = imc->check_scene(m_scene_ref);
			auto lc = section.contained_chunks.getLowerCorner();
			auto uc = section.contained_chunks.getUpperCorner();
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int y = lc.getY(); y <= uc.getY(); y++){
					for(int x = lc.getX(); x <= uc.getX(); x++){
						uint id = section.node_ids->getVoxelAt(x, y, z);
						if(!id)
							continue;
						Node *n = scene->GetNode(id);
						if(!n)
							continue;
						const Variant &var =
								n->GetVar(StringHash("buildat_voxel_data"));
						const PODVector<unsigned char> &buf = var.GetBuffer();
						if(buf.Size() == 0)
							continue;
						keys.push_back(chunk_key(pv::Vector3DInt32(x, y, z)));
						values.push_back(
								ss_((const char*)&buf[0], buf.Size()));
					}
				}
			}
		});
		const int64_t t1 = interface::os::time_us();
		m_save_times.wait += t_in - t0;
		m_save_times.copy += t1 - t_in;
		if(keys.empty()){
			section.modified = false;
			return;
		}
		// Outside the scene lock: a chunk that has to be renumbered is
		// decompressed, rewritten and compressed again, and the scene is not
		// waiting for that
		for(ss_ &value : values)
			value = chunk_row(prepare_saved_chunk(value));
		const int64_t t2 = interface::os::time_us();
		m_save_times.compress += t2 - t1;
		m_save_times.sections++;
		int64_t bytes = 0;
		for(const ss_ &value : values)
			bytes += value.size();
		m_save_times.bytes += bytes;
		// One transaction: a row at a time outside one is the classic slow
		// save, and it is also what leaves half a section on disk after a
		// crash. The name table goes in with the chunks that made it grow,
		// so there is no window where a row names an id the table has not.
		m_store->batch([&](){
			for(size_t i = 0; i < keys.size(); i++)
				m_store->set(keys[i], values[i]);
			m_store->set(generated_key(section.section_p), index_row(
					section.generated && !section.awaiting, section.altered,
					bytes, section.visited_day));
			save_name_table();
			save_registry();
			if(m_formats_dirty)
				save_format_table();
		});
		m_save_times.write += interface::os::time_us() - t2;
		section.modified = false;
		section.saved_bytes = bytes;
		section.index_dirty = false;
		// The save has it now, whatever the streamer was told earlier
		m_save_misses.erase(section_key(section.section_p));
	}

	bool is_section_generated(const pv::Vector3DInt16 &section_p)
	{
		Section *section = get_section(section_p);
		return section != nullptr && section->loaded && section->generated &&
				!section->awaiting;
	}

	// See api.h: what has been written into this section is all of it there
	// is going to be, so no generator is asked for one
	void set_section_generated(const pv::Vector3DInt16 &section_p)
	{
		Section &section = force_get_section(section_p);
		if(!section.loaded)
			load_section(section);
		if(section.generated)
			return;
		section.generated = true;
		// Marked rather than generated, and the mark belongs in the save
		// with the voxels: a section that came back without it would be
		// generated over on the next run
		section.modified = true;
	}

	void set_name_aliases(const std::map<ss_, ss_> &aliases)
	{
		m_name_aliases = aliases;
	}

	void set_save(storage::Save *save, const ss_ &world_name)
	{
		m_aliased_save_ids.clear();
		m_save_path = save ? save->path() : ss_();
		m_save = save;
		m_world_full = false;
		m_world_measured_us = 0;
		if(!save){
			m_store = nullptr;
			m_world_name = "";
			m_save_names.clear();
			m_save_id_of_name.clear();
			m_save_to_session.clear();
			m_session_to_save.clear();
			m_save_formats.clear();
			m_saved_reg.reset();
			return;
		}
		m_store = save->store("voxelworld");
		m_world_name = world_name;
		load_name_table();
		load_format_table();
		load_stale_sections();
	}

	// The save holds something this build must not overwrite: a chunk in a
	// cut nothing here can move it out of, or a voxel type with no name this
	// game or the save can put to it. Stop touching the save altogether
	// rather than guess -- what is on disk is somebody's world, and a wrong
	// guess written over it cannot be undone.
	void refuse_save(const ss_ &why)
	{
		log_e(MODULE, "World \"%s\": %s. The save is neither read nor written "
				"any further; migrating it is the game's to do.",
				cs(m_world_name), cs(why));
		m_store = nullptr;
	}

	void load_name_table()
	{
		m_save_names.clear();
		m_save_id_of_name.clear();
		m_save_to_session.clear();
		m_session_to_save.clear();
		m_save_names_dirty = false;
		m_names_synced_to = 0;
		m_registry_saved_to = (interface::VoxelTypeId)-1;
		ss_ data;
		if(m_store->get(names_key(), data)){
			std::istringstream is(data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			uint8_t version = 0;
			ar(version);
			if(version == 3){
				ar(m_save_names);
			} else if(version == 2){
				throw Exception(ss_()+"voxelworld: the name table of world \""+
						m_world_name+"\" was written by a 0.7 development build "
						"whose records this build does not read");
			} else if(version == 1){
				// 0.6's (voxel_cereal_legacy.h); written again as 3
				interface::legacy06::read_vector(ar, m_save_names,
						[](interface::legacy06::In &a, interface::VoxelName &n){
					interface::legacy06::read(a, n);
				});
				m_save_names_dirty = true;
			} else {
				throw Exception(ss_()+"voxelworld: the name table of world \""+
						m_world_name+"\" is version "+itos(version)+
						" and this build writes 3");
			}
		}
		// Save id 0 is VOXELTYPEID_UNDEFINED under every format, and is not
		// a name
		if(m_save_names.empty())
			m_save_names.resize(1);
		// A save written before there was a name table carries the registry
		// it was written under instead, and that registry *is* the numbering
		// its chunks are in. Seeding the table from it is what keeps such a
		// save readable by a game that has since registered its types in
		// another order -- without this the ids would quietly mean something
		// else.
		if(m_save_names.size() == 1)
			seed_name_table_from_saved_registry();
		for(size_t i = 1; i < m_save_names.size(); i++)
			m_save_id_of_name[m_save_names[i].dump()] =
					(interface::VoxelTypeId)i;
	}

	void seed_name_table_from_saved_registry()
	{
		if(!load_saved_registry())
			return;
		interface::VoxelTypeId num = m_saved_reg->num_voxels();
		for(interface::VoxelTypeId id = 1; id <= num; id++){
			const interface::VoxelDefinition *def = m_saved_reg->get(id);
			if(!def)
				break;
			m_save_names.push_back(def->name);
		}
		if(m_save_names.size() > 1){
			m_save_names_dirty = true;
			log_v(MODULE, "World \"%s\": name table seeded with %zu names "
					"from the registry the save carries",
					cs(m_world_name), m_save_names.size() - 1);
		}
	}

	bool load_saved_registry()
	{
		if(m_saved_reg)
			return true;
		ss_ data;
		if(!m_store->get(registry_key(), data))
			return false;
		m_saved_reg.reset(interface::createVoxelRegistry());
		m_saved_reg->deserialize(data);
		return true;
	}

	void save_name_table()
	{
		if(!m_store || !m_save_names_dirty)
			return;
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar((uint8_t)3, m_save_names);
		}
		m_store->set(names_key(), os.str());
		m_save_names_dirty = false;
	}

	// The save's id for a name, appending it if the save has not seen it.
	// The table only ever grows, which is what keeps a chunk written under
	// an older one valid.
	interface::VoxelTypeId save_id_of(const interface::VoxelName &name)
	{
		ss_ key = name.dump();
		auto it = m_save_id_of_name.find(key);
		if(it != m_save_id_of_name.end())
			return it->second;
		m_save_names.push_back(name);
		interface::VoxelTypeId id =
				(interface::VoxelTypeId)(m_save_names.size() - 1);
		m_save_id_of_name[key] = id;
		m_save_names_dirty = true;
		return id;
	}

	// A voxel type the save has and the game no longer registers. It gets a
	// session id of its own so that its word travels whole and it is written
	// back under the same name, and it is drawn with the definition the save
	// carries -- so a dropped type still looks like itself in an old world.
	//
	// What that would hide is that the game does not support it any more, so
	// every variant of it is tinted. Honest limitation: the tint multiplies
	// the vertex colour, which is light and not albedo, so in the dark an
	// unknown voxel looks like everything else.
	const interface::VoxelDefinition* adopt_unknown_voxel(
			const interface::VoxelName &name)
	{
		if(!load_saved_registry())
			return nullptr;
		const interface::VoxelDefinition *saved = m_saved_reg->get(name);
		if(!saved)
			return nullptr;
		interface::VoxelDefinition def = *saved;
		def.id = interface::VOXELTYPEID_UNDEFINED;
		// A definition with no variants has one now, which is the plain cube
		// with somewhere to put the tint; variant_of_param is all zeroes, so
		// every param value finds it
		if(def.variants.empty())
			def.variants.resize(1);
		for(interface::VoxelVariant &v : def.variants)
			v.color = UNKNOWN_VOXEL_TINT;
		interface::VoxelTypeId id = m_voxel_reg->add_voxel(def);
		log_w(MODULE, "World \"%s\": the save has voxel type %s, which this "
				"game does not register. It is kept and drawn with the "
				"definition the save carries, tinted.",
				cs(m_world_name), cs(name.dump()));
		m_unknown_voxels.push_back(name);
		return m_voxel_reg->get(id);
	}

	// save id -> session id and back, worked out by name.
	//
	// Called before a section is read or written rather than once, because
	// the game goes on registering voxel types after set_save(): a name that
	// does not resolve now may resolve later, and a type registered later
	// still has to reach the table before anything holding it is written.
	// Both loops normally do nothing at all.
	void update_id_maps()
	{
		// What cached_of() remembers is about a registry that may be about
		// to gain a type. Nothing that is already in it changes, but this is
		// the cheap place to be sure.
		m_def_memo = nullptr;
		// Every type the game has registered goes into the table first, so
		// that writing a chunk cannot come across a name the save has no id
		// for. Appending in id order is what keeps the identity case the
		// identity.
		interface::VoxelTypeId num = m_voxel_reg->num_voxels();
		for(interface::VoxelTypeId id = m_names_synced_to + 1; id <= num; id++){
			const interface::VoxelDefinition *def = m_voxel_reg->get(id);
			if(!def)
				break;
			interface::VoxelTypeId save_id = save_id_of(def->name);
			if(save_id >= m_save_to_session.size())
				m_save_to_session.resize(save_id + 1, 0);
			m_save_to_session[save_id] = id;
			m_names_synced_to = id;
		}
		// What is left is a name the save has and the game does not register
		m_save_to_session.resize(m_save_names.size(), 0);
		// A renamed type, registered or not (Luanti's register_alias_force
		// keeps the old one's id): the voxel its alias names, written back
		// under that name (the reverse map below skips this save id)
		for(size_t i = 1; !m_name_aliases.empty() &&
				i < m_save_names.size(); i++){
			auto al = m_name_aliases.find(m_save_names[i].block_name);
			if(al == m_name_aliases.end() || m_aliased_save_ids.count(i))
				continue;
			interface::VoxelName n = m_save_names[i];
			n.block_name = al->second;
			const interface::VoxelDefinition *d = m_voxel_reg->get(n);
			if(d){
				m_save_to_session[i] = d->id;
				m_aliased_save_ids.insert(i);
			}
		}
		for(size_t i = 1; i < m_save_names.size(); i++){
			if(m_save_to_session[i] != 0)
				continue; // Resolved once and for all: nothing is unregistered
			const interface::VoxelDefinition *def =
					adopt_unknown_voxel(m_save_names[i]);
			if(!def){
				refuse_save("the save holds voxel type "+
						m_save_names[i].dump()+", which this game does not "
						"register and the save's own definitions do not "
						"describe");
				return;
			}
			m_save_to_session[i] = def->id;
			if(def->id >= m_names_synced_to)
				m_names_synced_to = def->id;
		}
		m_session_to_save.assign(m_names_synced_to + 1, 0);
		for(size_t i = 1; i < m_save_to_session.size(); i++){
			interface::VoxelTypeId sid = m_save_to_session[i];
			if(m_aliased_save_ids.count(i))
				continue;
			if(sid != 0 && sid < m_session_to_save.size())
				m_session_to_save[sid] = (interface::VoxelTypeId)i;
		}
		m_id_map_identity = true;
		for(size_t i = 1; i < m_save_to_session.size(); i++){
			if(m_save_to_session[i] != i){
				m_id_map_identity = false;
				break;
			}
		}
		for(size_t i = 1; m_id_map_identity && i < m_session_to_save.size();
				i++){
			if(m_session_to_save[i] != i)
				m_id_map_identity = false;
		}
		if(!m_id_map_identity && !m_logged_remap){
			m_logged_remap = true;
			size_t n = 0;
			for(size_t i = 1; i < m_save_to_session.size(); i++)
				if(m_save_to_session[i] != i)
					n++;
			log_i(MODULE, "World \"%s\": the save's voxel numbering is not "
					"this run's; %zu of %zu names are read and written through "
					"the table", cs(m_world_name), n,
					m_save_names.size() - 1);
		}
	}

	// The formats the save's chunks are in. A save may hold a mix and that
	// is the point: chunks are independent, so nothing is rewritten that was
	// not modified, and one damaged chunk is one damaged chunk.
	void load_format_table()
	{
		m_save_formats.clear();
		m_write_format = 0;
		bool legacy_formats = false;
		ss_ data;
		if(m_store->get(formats_key(), data)){
			std::istringstream is(data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			uint8_t version = 0;
			ar(version);
			if(version == 3){
				ar(m_save_formats);
			} else if(version == 2){
				throw Exception(ss_()+"voxelworld: the format table of world "
						"\""+m_world_name+"\" was written by a 0.7 development "
						"build whose records this build does not read");
			} else if(version == 1){
				// 0.6's (voxel_cereal_legacy.h); written again as 3 below
				interface::legacy06::read_vector(ar, m_save_formats,
						[](interface::legacy06::In &a,
								interface::VoxelFormat &f){
					interface::legacy06::read(a, f);
				});
				legacy_formats = true;
			} else {
				throw Exception(ss_()+"voxelworld: the format table of world "
						"\""+m_world_name+"\" is version "+itos(version)+
						" and this build writes 3");
			}
		}
		m_formats_dirty = legacy_formats;
		const interface::VoxelFormat &format = m_voxel_reg->get_format();
		for(size_t i = 0; i < m_save_formats.size(); i++){
			if(m_save_formats[i] == format){
				m_write_format = (uint16_t)i;
				return;
			}
		}
		m_save_formats.push_back(format);
		m_write_format = (uint16_t)(m_save_formats.size() - 1);
		m_formats_dirty = true;
		if(m_save_formats.size() > 1)
			log_i(MODULE, "World \"%s\": %s is new to this save, which holds "
					"%zu formats now", cs(m_world_name), cs(format.dump()),
					m_save_formats.size());
	}

	void save_format_table()
	{
		if(!m_store)
			return;
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar((uint8_t)3, m_save_formats);
		}
		m_store->set(formats_key(), os.str());
		m_formats_dirty = false;
	}

	// The definitions themselves, so that a type the game stops registering
	// can still be drawn and still has a name. Not the authority on
	// numbering -- the name table is -- and written again whenever the game
	// has registered something since.
	void save_registry()
	{
		if(!m_store || m_registry_saved_to == m_names_synced_to)
			return;
		m_store->set(registry_key(), m_voxel_reg->serialize());
		m_registry_saved_to = m_names_synced_to;
	}

	sv_<interface::VoxelName> get_unknown_voxels()
	{
		return m_unknown_voxels;
	}

	void save()
	{
		if(!m_store)
			return;
		commit();
		save_stale_sections();
		size_t n = 0, total = 0;
		for(auto &sector_pair : m_sections){
			for(auto &section_pair : sector_pair.second){
				total++;
				if(!m_store) // A section can refuse the save
					continue;
				if(!section_pair.second.modified &&
						!section_pair.second.index_dirty)
					continue;
				save_section(section_pair.second);
				n++;
			}
		}
		log_v(MODULE, "World \"%s\": saved %zu sections of %zu",
				cs(m_world_name), n, total);
	}

	sv_<voxelworld::SectionStat> section_stats()
	{
		sv_<voxelworld::SectionStat> out;
		if(!m_store)
			return out;
		const ss_ prefix = m_world_name+"/s";
		const ss_ suffix = "/generated";
		for(const ss_ &key : m_store->list(prefix)){
			int x = 0, y = 0, z = 0;
			if(key.size() <= prefix.size() + suffix.size() ||
					key.compare(key.size() - suffix.size(), suffix.size(),
					suffix) != 0 ||
					sscanf(key.c_str() + prefix.size(), "%i,%i,%i",
					&x, &y, &z) != 3)
				continue;
			ss_ v;
			if(!m_store->get(key, v))
				continue;
			voxelworld::SectionStat s = parse_index_row(v);
			s.p = pv::Vector3DInt16(x, y, z);
			Section *section = get_section(s.p);
			if(section && section->loaded){
				s.loaded = true;
				s.altered = section->altered;
				s.day = section->visited_day;
			}
			out.push_back(s);
		}
		return out;
	}

	size_t forget_sections(const sv_<pv::Vector3DInt16> &list)
	{
		if(!m_store)
			return 0;
		sv_<pv::Vector3DInt16> gone;
		m_store->batch([&](){
			for(const pv::Vector3DInt16 &p : list){
				Section *section = get_section(p);
				if(section && section->loaded)
					continue;
				const pv::Vector3DInt32 lc(
						p.getX() * m_section_size_chunks.getX(),
						p.getY() * m_section_size_chunks.getY(),
						p.getZ() * m_section_size_chunks.getZ());
				for(int z = 0; z < m_section_size_chunks.getZ(); z++)
				for(int y = 0; y < m_section_size_chunks.getY(); y++)
				for(int x = 0; x < m_section_size_chunks.getX(); x++)
					m_store->remove(chunk_key(pv::Vector3DInt32(
							lc.getX() + x, lc.getY() + y, lc.getZ() + z)));
				m_store->remove(generated_key(p));
				if(m_stale_sections.erase(section_key(p)) > 0)
					m_stale_dirty = true;
				gone.push_back(p);
			}
			save_stale_sections();
		});
		if(gone.empty())
			return 0;
		log_v(MODULE, "World \"%s\": forgot %zu sections", cs(m_world_name),
				gone.size());
		m_server->emit_event("voxelworld:sections_forgotten",
				new SectionsForgotten(m_scene_ref, gone));
		return gone.size();
	}

	size_t trim_to(int64_t target_bytes, int altered_days)
	{
		if(!m_store || !m_save)
			return 0;
		const int64_t have = m_save->bytes();
		if(have <= target_bytes)
			return 0;
		const sv_<pv::Vector3DInt16> pick = choose_forget(section_stats(),
				today(), have - target_bytes, altered_days);
		const size_t n = forget_sections(pick);
		log_i(MODULE, "World \"%s\": %lld kB, trimmed toward %lld kB: %zu "
				"sections forgotten", cs(m_world_name), (long long)(have / 1024),
				(long long)(target_bytes / 1024), n);
		return n;
	}

	ss_ m_cause;
	void set_cause(const ss_ &player_name)
	{
		m_cause = player_name;
	}
	// A write while a player's action is handled. Into a section still
	// being generated too: what a player put there is kept either way.
	void note_cause(Section *section)
	{
		if(!m_cause.empty() && !section->altered){
			section->altered = true;
			section->index_dirty = true;
		}
	}

	void save(std::function<void()> also)
	{
		m_game_checkpoints = true;
		if(!m_store){
			also();
			return;
		}
		// save() can drop m_store (a refused save) half way
		storage::Store *store = m_store;
		const int64_t t0 = interface::os::time_us();
		int64_t t_commit = 0;
		m_save_times = SaveTimes();
		store->batch([&](){
			also();
			save();
			t_commit = interface::os::time_us();
		});
		const int64_t end = interface::os::time_us();
		log_v(MODULE, "save: %i ms: %s", (int)((end - t0) / 1000),
				cs(save_times(end - t_commit)));
	}

	void set_voxel_direct(const pv::Vector3DInt32 &p,
			const interface::VoxelInstance &v)
	{
		log_t(MODULE, "set_voxel_direct() p=" PV3I_FORMAT ", v=%i",
				PV3I_PARAMS(p), v.data);
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = get_section_of_chunk(chunk_p);
		if(section == nullptr){
			log_w(MODULE, "set_voxel_direct() p=" PV3I_FORMAT ", v=%i: No section "
					" " PV3I_FORMAT " for chunk " PV3I_FORMAT,
					PV3I_PARAMS(p), v.data, PV3I_PARAMS(section_p),
					PV3I_PARAMS(chunk_p));
			return;
		}
		int32_t node_id = section->node_ids->getVoxelAt(chunk_p);
		if(node_id == 0){
			log_w(MODULE, "set_voxel_direct() p=" PV3I_FORMAT ", v=%i: No node for "
					"chunk " PV3I_FORMAT " in section " PV3I_FORMAT,
					PV3I_PARAMS(p), v.data, PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section_p));
			return;
		}

		note_cause(section);

		// Have to commit first so that this modification doesn't get
		// overwritten by some older one
		// TODO: Commit only the current chunk
		commit();

		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene_ref);
			Node *n = scene->GetNode(node_id);
			const Variant &var = n->GetVar(StringHash("buildat_voxel_data"));
			const PODVector<unsigned char> &buf = var.GetBuffer();
			ss_ data((const char*)&buf[0], buf.Size());
			up_<VoxelVolume> volume =
					interface::deserialize_volume(data);

			pv::Vector3DInt32 voxel_p(
					p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX(),
					p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY(),
					p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ()
			);
			log_t(MODULE, "set_voxel_direct() p=" PV3I_FORMAT ", v=%i: "
					"Chunk " PV3I_FORMAT " in section " PV3I_FORMAT
					"; internal position " PV3I_FORMAT,
					PV3I_PARAMS(p), v.data, PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section_p), PV3I_PARAMS(voxel_p));
			volume->setVoxelAt(voxel_p, v);

			run_commit_hooks_in_thread(chunk_p, *volume);

			ss_ new_data = interface::serialize_volume_compressed(*volume);

			n->SetVar(StringHash("buildat_voxel_data"), Variant(
					PODVector<uint8_t>((const uint8_t*)new_data.c_str(),
					new_data.size())));

			run_commit_hooks_in_scene(chunk_p, n);
		});

		section->modified = true;

		// Mark node for collision box update
		mark_node_for_physics_update(node_id);

		m_server->emit_event("voxelworld:node_volume_updated",
				new NodeVolumeUpdated(m_scene_ref, node_id, true, chunk_p));
	}
// vim: set noet ts=4 sw=4:
