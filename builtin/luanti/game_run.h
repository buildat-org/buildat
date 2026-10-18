// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Running the game: run_game() and the world it makes, included by
// luanti.cpp inside struct Module ([LUANTI_MODULAR]). The glue of the
// parts, in the order they start in -- which is every part's, so this is
// the Module's own code in a file of its own rather than a part.

	// The world
	//
	// Built after the mods have loaded, because add_voxel() takes a finished
	// definition and hands out ids in call order -- so the definitions have
	// to be made in one pass in content id order, and only the final
	// core.registered_nodes is ever looked at. That is also what makes
	// core.override_item and core.unregister_item non-issues here.

	void create_world()
	{
		m_world.read_range_settings();
		// Nothing streams while a world is being imported into this one:
		// see run_game(). The budget goes back to what it was once the
		// import is done.
		if(!m_importer.m_import_path.empty())
			m_world.m_stream_budget = 0;
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_scene = imc->create_scene();
		});

		// Singlenode: nothing generates anything, so the world is void and
		// the only nodes in it are the ones a mod places. The region is the
		// map's limits; what is loaded of it is what the load points keep.
		voxelworld::access(m_server, [&](voxelworld::Interface *iv){
			iv->create_instance(m_scene, m_section_region, m_server_physics);
		});

		// Before voxelworld's first tick, which is when a world that has
		// said nothing gets its whole region created
		m_world.update_load_points();

		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			interface::VoxelRegistry *reg = world->get_voxel_reg();
			// Luanti's cut of the voxel word: a 16-bit node id, param1 as
			// two light nibbles, param2 above them. Nothing is packed by
			// hand anywhere in this module because of this line.
			reg->set_format(interface::VoxelFormat::luanti());
			m_registry.build_voxel_registry(reg);
			// After the registry and before anything asks for a section: the
			// save stores node names and the run owns the numbering, so the
			// content ids the mods asked for while loading are the ids this
			// run uses whatever a previous one did. See
			// doc/plan/world_persistence_plan.md.
			world->set_name_aliases(m_mapgen.node_aliases());
			world->set_save(m_save, "main");
			// [SAVE_CHECKPOINT] Nothing to write yet; says this game
			// checkpoints itself, so voxelworld does not on its own
			world->save([](){});
			m_section_size = world->get_section_size_voxels();
		});
		// The startup tables are known once the registry is built, and they
		// go out as files as well as on request ([BLOCKED_MODULE])
		m_media.serve_startup_tables();
		// A section is what this world generates at a time, which is what
		// core.get_mapgen_chunksize() answers with
		set_global_string("__luanti_section_size",
				itos(m_section_size.getX()));

		// The generator runs in worldgen's thread rather than here: what
		// fills a section is a mod's Lua today and Luanti's own mapgen
		// when it is vendored, and neither belongs on the thread the
		// server steps on. It is created before the first section is
		// asked for, which is the next line but one.
		// What fills a section is builtin/luanti_mapgen's, which is where
		// Luanti's own mapgens are vendored: this module hands over what a
		// generator is a function of and gets one back.
		luanti_mapgen::Params params;
		params.mgname = m_mapgen.mapgen_name();
		params.seed = m_clock.m_seed;
		params.singlenode_word = m_world.singlenode_word();
		params.content_ids = m_mapgen.content_ids_by_name();
		params.node_props = m_mapgen.mapgen_node_props();
		params.biomes = m_mapgen.mapgen_biomes();
		params.ores = m_mapgen.mapgen_ores();
		params.decorations = m_mapgen.mapgen_decorations();
		params.section_size = m_section_size.getX();
		params.water_level = m_mapgen.mapgen_water_level();
		params.mg_flags = m_mapgen.mapgen_flags();
		// What a mod asks for as get_mapgen_setting("water_level"): the
		// world's own, which is not always what the settings say
		set_global_string("__luanti_water_level", itos(params.water_level));
		m_mapgen.mapgen_gen_notify(params.gen_notify_flags,
				params.gen_notify_deco_ids);
		if(!params.gen_notify_flags.empty())
			log_v(MODULE, "gennotify: \"%s\", %zu decoration ids",
					cs(params.gen_notify_flags),
					params.gen_notify_deco_ids.size());
		// Kept, because the spawn search asks the same mapgen where the
		// ground is without generating anything; see l_spawn_level()
		m_world.m_mapgen_params = params;
		m_biome_query = nullptr;
		worldgen::GeneratorInterface *generator = nullptr;
		luanti_mapgen::access(m_server, [&](luanti_mapgen::Interface *im){
			generator = im->create_generator(params);
		});
		worldgen::access(m_server, [&](worldgen::Interface *iw){
			iw->create_instance(m_scene);
			worldgen::Instance *instance = iw->get_instance(m_scene);
			if(generator)
				instance->set_generator(generator);
			instance->enable();
		});

		// Singlenode is a node everywhere, and this is where it is put.
		// Before the skylight is on: what the fill writes is a world of lit
		// air, and every voxel of it changing from nothing to air with the
		// light running would be a skylight seed -- seven million of them,
		// and eight seconds of startup to settle what the fill already
		// knows.
		//
		// A world being imported waits: what this asks for is the sections
		// around the origin, and a section a generator has been over is one
		// the import can no longer write into. run_game() calls it once the
		// map has been read, and the sections the import filled are marked
		// generated by then.
		if(m_importer.m_import_path.empty())
			m_world.generate_world();

		// The light is voxelworld's to maintain and the generator's to
		// start. voxelworld floods from the top of the world region, which
		// for a Luanti-sized map is thirty thousand voxels up and never
		// loaded -- so nothing would ever be lit if that were the only
		// source. What lights a generated world is the mapgen, which fills
		// the light as it builds (the MG_LIGHT flag), and voxelworld keeps
		// that light and spreads it from there: a write that carries light
		// means it. So a hole dug into a mountain fills from the daylight
		// around its mouth, the way it does in Luanti.
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_light_maintained(
					voxelworld::Instance::LIGHT_SKY, true);
			// And the light a node makes of its own, which a Luanti game's
			// mechanics are written against: what spawns where, what grows
			// underground, what a mod reads out of core.get_node_light().
			// A game whose lamps are lights in the scene would leave this
			// off; a Luanti game cannot.
			world->set_light_maintained(
					voxelworld::Instance::LIGHT_LAMP, true);
		});

		m_players.check_active_range();

		// After the world, because a section is what the metadata is now
		// written per and the section size comes from voxelworld
		m_meta.migrate_node_meta();
	}

	void set_progress_handler(std::function<void(const ss_ &)> handler)
	{
		m_progress = handler;
	}

	void progress(const ss_ &line)
	{
		// And the log's status line, which the client's waiting screen
		// and a shell start read ([START_PROGRESS])
		log_i(MODULE, "STATUS %s", cs(line));
		if(m_progress)
			m_progress(line);
	}

	void run_game(const ss_ &game_path, storage::Save *save)
	{
		if(m_game_running)
			throw Exception("luanti: run_game() called twice");
		if(!save)
			throw Exception("luanti: run_game() without a save; the world is "
					"the save");
		m_save = save;
		m_store = save->store("luanti");
		// A directory of the save's rather than the save's own root, so that
		// a mod writing through core.get_worldpath() cannot land on
		// save.sqlite or on anything else of ours it does not expect to be
		// there. devtest's testnodes mod writes a PNG through it while it
		// loads, so this is not hypothetical.
		ss_ world_path = save->path()+"/luanti";
		interface::fs::create_directories(world_path);
		log_i(MODULE, "run_game(): game=%s world=%s",
				cs(game_path), cs(world_path));
		progress("Loading "+game_path.substr(game_path.find_last_of('/') + 1));

		m_lua = luaL_newstate();
		if(!m_lua)
			throw Exception("luanti: cannot create a Lua state");
		luaL_openlibs(m_lua);
		{
			// The Lua sampling profiler, if this run asked for one
			const char *env = getenv("BUILDAT_LUANTI_LUAPROF");
			// The hook is on either way: without the profiler it is only
			// the step watchdog, at an interval coarse enough to cost
			// nothing measurable.
			if(env == nullptr || env[0] == '\0'){
				lua_sethook(m_lua, lua_prof_hook, LUA_MASKCOUNT, 1000000);
			}
			if(env != nullptr && env[0] != '\0'){
				const int n = atoi(env);
				g_lua_prof.interval = n > 0 ? n : 10000;
				g_lua_prof.enabled = true;
				lua_sethook(m_lua, lua_prof_hook, LUA_MASKCOUNT,
						g_lua_prof.interval);
				log_i(MODULE, "Lua profile: sampling every %i instructions; "
						"the report comes at shutdown",
						g_lua_prof.interval);
			}
		}
		// bit.band and its family, before any mod can ask for them
		lua_pushcfunction(m_lua, luaopen_bit);
		lua_pushstring(m_lua, "bit");
		lua_call(m_lua, 1, 0);

		register_lua_functions();
		// The world is not made yet and a mod that asks how big a chunk is
		// asks while it loads -- minetest_game does -- so this carries the
		// default until create_world() knows the real one. Without it the
		// read is of a global that does not exist, which the module's own
		// strict-global guard warns about, once, for nothing.
		set_global_string("__luanti_section_size", "64");
		lua_pushlightuserdata(m_lua, (void*)this);
		lua_setfield(m_lua, LUA_REGISTRYINDEX, "__luanti_module");
		set_global_string("__luanti_module_path", module_path());
		// The Lua both clients share, serve_shared_lua()'s; the server's
		// get_translated_string() runs its formspec.lua too
		set_global_string("__luanti_shared_path",
				m_server->get_config().get<ss_>("share_path")+
				"/extensions/luanti_client/res");
		set_global_string("__luanti_cache_path", luanti_cache_path());
		set_global_string("__luanti_game_path", game_path);
		set_global_string("__luanti_world_path", world_path);

		// Ours first: it is what builds the core table the vendored builtin
		// then expects to be there
		run_chunk_file(module_path()+"/lua/bootstrap.lua");
		run_chunk_file(module_path()+"/vendor/builtin/init.lua");
		// And what this tree adds to what the builtin registered: after it,
		// because it changes commands the builtin has already put there
		run_chunk_file(module_path()+"/lua/chatcommands.lua");
		for(const auto &pair : m_pending_lua)
			run_chunk_string(pair.first, pair.second);
		m_pending_lua.clear();
		// Before the mods load, because a mod can ask the time while it
		// does, and after the builtin, because that is where the clock is
		m_clock.load_clock();
		m_clock.load_seed();
		// Which mapgen this world is, before the mods load, because a mod
		// reads it while it loads -- VoxeLibre registers no biomes at all
		// for a singlenode world. The save's own answer, which for an
		// imported world is its map_meta.txt's and is in no setting here.
		set_global_string("__luanti_mapgen_name", m_mapgen.mapgen_name());
		// And which LBMs this world has already had; see Importer::lbm_names_of()
		m_mapgen.publish_lbm_introduced();

		run_chunk_file(module_path()+"/lua/modloader.lua");

		// After the mods, because what the metadata holds is item strings
		// and a mod's items have to be registered for one to mean anything.
		// The node metadata is not read here any more: it comes back with
		// the section it is in, and the migrate_node_meta() below is what an
		// older save's one blob of it becomes.
		m_players.load_players();
		run_chunk_string("core.__check_players() "
				"core.__check_inventory_move() "
				"core.__check_bone_hand() "
				"core.__check_craft_index()", "check_players");

		check_shapes();
		check_params();
		check_registry();
		luanti_mapblock::check_mapblock();
		luanti_media::check_media_names();

		// The game's own media before the registry, because what a node's
		// tiles can be depends on which files were actually shipped
		progress("Serving the media");
		m_media.serve_game_media(game_path);

		// The registry, the world and the light, in that order: the ids the
		// mods asked for while loading are the ids the definitions are built
		// under, and the definitions have to exist before anything is lit.
		progress("Building the world");
		create_world();

		m_game_running = true;

		// The map of another engine's world, if this world is being made
		// out of one: after the nodes and the world, and before anything
		// has asked a generator for a section. The streamer was told to
		// take on nothing while this runs, because a section it generated
		// underneath the import would be one the import cannot have.
		if(!m_importer.m_import_path.empty()){
			progress("Importing the world");
			m_importer.read_luanti_world(m_importer.m_import_path);
			m_importer.m_import_path.clear();
			// What create_world() left to this: the sections around the
			// origin, so that whatever the imported world did not reach
			// still has ground under it
			m_world.generate_world();
			m_world.m_stream_budget = 2;
			m_world.update_load_points();
		}

		m_world.start_check_map();

		// Last, so that it is the hour whatever the save or the imported
		// world said
		m_clock.force_clock();

		m_server->emit_event("luanti:game_loaded", new GameLoaded(m_scene));
	}

	void load_lua(const ss_ &chunk, const ss_ &chunkname)
	{
		if(m_game_running)
			throw Exception("luanti: load_lua() after run_game(); whatever "
					"extends the environment is registered before the game "
					"runs");
		m_pending_lua.push_back({chunk, chunkname});
	}
