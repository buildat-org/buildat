// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// What answers the client's requests, and the rest of the C functions the
// game's Lua calls (the node searches); included by luanti.cpp inside
// struct Module ([SPLITS]: moved out as they were).

	// What the client sends back when a form's button is pressed: the form's
	// name and then the fields, a name and a value each.
	// The reference fixture's readiness reply: the client has drawn the state
	// it was marked for and has taken the picture. Carries the token and the
	// name the picture was saved under, and nothing else -- the fixture set
	// the state, so it is the one that knows which state this is. See
	// [ONE_CYCLE] in doc/plan/rendering_plan.md.
	void on_refshot_shot(const network::Packet &packet)
	{
		sv_<ss_> flat;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(flat);
		} catch(std::exception &e){
			log_w(MODULE, "luanti:refshot_shot: %s", e.what());
			return;
		}
		if(flat.size() < 2){
			log_w(MODULE, "luanti:refshot_shot: %zu values", flat.size());
			return;
		}
		if(!m_lua)
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__refshot_shot");
		if(!lua_isfunction(L, -1)){
			// Nobody is listening, which is every run that is not taking a
			// reference set
			lua_settop(L, base);
			return;
		}
		lua_pushinteger(L, atoi(flat[0].c_str()));
		lua_pushlstring(L, flat[1].c_str(), flat[1].size());
		int nargs = 2;
		if(flat.size() >= 3){
			lua_pushlstring(L, flat[2].c_str(), flat[2].size());
			nargs = 3;
		}
		if(lua_pcall(L, nargs, 0, 0) != 0)
			log_w(MODULE, "__refshot_shot(): %s", lua_tostring(L, -1));
		lua_settop(L, base);
	}

	void on_fields(const network::Packet &packet)
	{
		auto who = m_peer_players.find(packet.sender);
		if(who == m_peer_players.end())
			return;
		sv_<ss_> flat;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(flat);
		} catch(std::exception &e){
			log_w(MODULE, "luanti:fields: %s", e.what());
			return;
		}
		if(flat.empty())
			return;
		PlayerCause cause(m_map.m_by_player);
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__player_receive_fields");
		lua_pushlstring(L, who->second.c_str(), who->second.size());
		lua_pushlstring(L, flat[0].c_str(), flat[0].size());
		lua_createtable(L, 0, (int)(flat.size() / 2));
		for(size_t i = 1; i + 1 < flat.size(); i += 2){
			lua_pushlstring(L, flat[i + 1].c_str(), flat[i + 1].size());
			lua_setfield(L, -2, flat[i].c_str());
		}
		if(lua_pcall(L, 3, 0, 0) != 0){
			log_w(MODULE, "__player_receive_fields(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
		}
		lua_settop(L, base);
	}

	// A stack picked up in one slot and put down in another. The strings are
	// what the move is; lua/entity.lua says what they mean.
	void on_inv_action(const network::Packet &packet)
	{
		auto who = m_peer_players.find(packet.sender);
		if(who == m_peer_players.end())
			return;
		sv_<ss_> flat;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(flat);
		} catch(std::exception &e){
			log_w(MODULE, "luanti:inv_action: %s", e.what());
			return;
		}
		if(flat.empty())
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__inventory_action");
		lua_pushlstring(L, who->second.c_str(), who->second.size());
		lua_createtable(L, (int)flat.size(), 0);
		for(size_t i = 0; i < flat.size(); i++){
			lua_pushlstring(L, flat[i].c_str(), flat[i].size());
			lua_rawseti(L, -2, (int)i + 1);
		}
		if(lua_pcall(L, 2, 0, 0) != 0){
			log_w(MODULE, "__inventory_action(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
		}
		lua_settop(L, base);
	}

	// Every object's look, for a client that has just arrived: the props are
	// sent when they change and a client that was not there missed them.
	void on_get_object_props(const network::Packet &packet)
	{
		sv_<ss_> flat = string_list_from_lua("__object_appearances");
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:object_props", os.str());
		});
		log_v(MODULE, "C%zu: %zu object looks", (size_t)packet.sender,
				flat.size() / 6);
	}

	// The quads of one model, asked for by name: an object whose visual is a
	// mesh is drawn as that mesh, and the client is told which file by the
	// appearance and asks for the file's contents once. The same reader a
	// mesh node goes through, so a format nothing reads answers with
	// nothing and the object keeps the cube it had.
	//
	// The numbers cross as text, which is what every other flat channel
	// here does: a model is asked for once and devtest's frog is thirty
	// kilobytes of it.
	void on_get_model(const network::Packet &packet)
	{
		sv_<ss_> asked;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(asked);
		} catch(std::exception &e){
			log_w(MODULE, "luanti:get_model: %s", e.what());
			return;
		}
		if(asked.empty() || asked[0].empty() || !m_lua)
			return;
		const ss_ name = asked[0];
		// The second value, if any, is the frame the model is wanted
		// posed at, and the answer carries it back so the client files
		// the quads under the right key
		const ss_ frame_s = asked.size() > 1 ? asked[1] : "";
		const float frame = frame_s.empty() ? -1.0f : (float)atof(frame_s.c_str());
		// The quads as doubles, 21 a quad -- the tile, four corners, four
		// texture coordinates -- after the name and the frame: as strings
		// a pose was 40 KB and 80 ms of the client's Lua to read, and a
		// walking mob is one pose after another ([OBJECT_MESH] step 1)
		sv_<double> nums;
		{
			interface::MutexScope ms(m_lua_mutex);
			// Scale 1: an object's model is scaled by its visual_size,
			// which is the client's to apply and is not the same number
			// for two objects of one kind
			const sv_<interface::VoxelQuad> quads = m_registry.mesh_quads(name, 1.0f,
					frame);
			nums.reserve(quads.size() * 21);
			for(const interface::VoxelQuad &q : quads){
				nums.push_back((double)q.tile);
				for(size_t c = 0; c < 4; c++)
					for(size_t k = 0; k < 3; k++)
						nums.push_back(q.p[c][k]);
				for(size_t c = 0; c < 4; c++)
					for(size_t k = 0; k < 2; k++)
						nums.push_back(q.uv[c][k]);
			}
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(name, frame_s, nums);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:model", os.str());
		});
		log_v(MODULE, "C%zu: model \"%s\": %zu quads", (size_t)packet.sender,
				cs(name), nums.size() / 21);
	}

	// How long a dig takes and how far a tool reaches, which the client
	// works out for itself rather than asking per dig. See core.__dig_props()
	// for what a record holds.
	void on_get_dig_props(const network::Packet &packet)
	{
		sv_<ss_> flat = string_list_from_lua("__dig_props");
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:dig_props", os.str());
		});
		log_v(MODULE, "C%zu: %zu dig prop records", (size_t)packet.sender,
				flat.size());
	}

	// The game's name, the world's seed and which Luanti this is: what the
	// client's status line shows and cannot know. Constants for a session,
	// so they are asked for once instead of riding along with the position.
	void on_get_world_info(const network::Packet &packet)
	{
		// Remembered per peer, so the packet can be sent again unasked
		// when the step peak moves ([STEP_PEAK]); a mode's name, so short
		m_peer_mode[packet.sender] = packet.data.substr(0, 32);
		send_world_info(packet.sender, packet.data);
	}

	// The step peak's number changed by what the status row would show:
	// world_info goes out again to every client that has asked for it
	static int l_step_peak(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__luanti_module");
		Module *self = (Module*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		if(!self || !self->m_game_running)
			return 0;
		for(const auto &pair : self->m_peer_mode)
			self->send_world_info(pair.first, pair.second);
		return 0;
	}

	sm_<network::PeerInfo::Id, ss_> m_peer_mode;

	// What is kept per peer goes with it: a peer that never became a
	// player was never removed from these, and the step peak's re-send
	// went on to it ([SECURITY_RUN_1])
	void on_client_disconnected(const network::OldClient &old)
	{
		m_session.left(old.info.id);
		m_peer_mode.erase(old.info.id);
		m_files_transmitted.erase(old.info.id);
		m_texmods_waiting.erase(old.info.id);
	}

	void send_world_info(network::PeerInfo::Id peer, const ss_ &asked_mode)
	{
		sv_<ss_> flat = string_list_from_lua("__world_info");
		// Which of the three rendering modes this session draws in --
		// "unlit", "shadows" or "pbr" -- which is a startup choice and not a
		// toggle: the atlas's surface maps have to be on from the first
		// texture the client builds. So it goes with the rest of what is
		// constant for a session rather than getting a packet of its own.
		// See [RENDER_MODES] in doc/plan/rendering_plan.md.
		//
		// The client asks for its own -- the packet carries what its
		// BUILDAT_RENDER_MODE says, through buildat.get_env() -- and the
		// server's environment is the default for one that says nothing,
		// so one server can serve a client in each mode ([PROBE_CYCLE]).
		// An unset variable on both means this client's own default, which
		// is pbr. The numbers keep working for whatever already passes
		// them: 0 was the unlit path before either had a name.
		const char *mode = getenv("BUILDAT_RENDER_MODE");
		ss_ m = !asked_mode.empty() ? asked_mode :
				(mode != nullptr) ? ss_(mode) : ss_("");
		// Neither side saying: the launcher game's setting
		// (user/shared/vanilla/settings.json, its "render_mode"; [LAUNCH_GRID])
		if(m.empty())
			m = settings_render_mode();
		if(m == "0")
			m = "unlit";
		else if(m == "" || m == "1")
			m = "pbr";
		else if(m != "unlit" && m != "shadows" && m != "pbr" &&
				m != "pbr_debug_shadows" && m != "pbr_debug_light" &&
				m != "pbr_debug_nibbles" && m != "pbr_debug_ground" &&
				m != "pbr_debug_skyamb" && m != "pbr_debug_baked"){
			log_w(MODULE, "BUILDAT_RENDER_MODE=\"%s\" is not a mode; "
					"drawing pbr. Wanted unlit, shadows, pbr, "
					"pbr_debug_shadows, pbr_debug_light, "
					"pbr_debug_nibbles, pbr_debug_ground, "
					"pbr_debug_skyamb or pbr_debug_baked", cs(m));
			m = "pbr";
		}
		// Kept for the step peak's resends ([VIEW_SETTINGS_LOCAL]): a mode
		// read from settings.json is the session's, and a later write to
		// it must not switch a session that has started drawing
		auto kept = m_peer_mode.find(peer);
		if(kept != m_peer_mode.end())
			kept->second = m;
		flat.push_back(m);
		// How far this client tilts the sun and the moon's orbit when the
		// game has no opinion, in degrees. A game that sets body_orbit_tilt
		// is obeyed instead, whatever this says; see the sky handler in
		// apps/vanilla. **Zero is what a comparison against
		// official Luanti wants**, because that is what Luanti does with a
		// game that never asks. Read here rather than in the client's Lua
		// for the same reason the mode is: that half runs in the sandbox,
		// where there is no getenv.
		const char *tilt = getenv("BUILDAT_LUANTI_ORBIT_TILT");
		flat.push_back(tilt != nullptr ? ss_(tilt) : ss_(""));
		// The server's step peak and the phase that set it, [STEP_PEAK]
		for(const ss_ &v : string_list_from_lua("__step_peak_info"))
			flat.push_back(v);
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "luanti:world_info", os.str());
		});
	}

	// What the game's locale/*.tr files say, for the one language in force,
	// as domain, key, value repeating. The lookup is the client's because
	// the markers are in every string that reaches it; see lua/
	// translations.lua for which language and why it is the server that
	// picks it.
	void on_get_translations(const network::Packet &packet)
	{
		sv_<ss_> flat = string_list_from_lua("__translations");
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:translations", os.str());
		});
		log_v(MODULE, "C%zu: %zu translated strings", (size_t)packet.sender,
				flat.size() / 3);
	}

	// A core.__<name>() that answers with an array of strings, as a vector
	sv_<ss_> string_list_from_lua(const char *name)
	{
		sv_<ss_> flat;
		interface::MutexScope ms(m_lua_mutex);
		// No game yet -- a server at its world menu -- and a client may
		// ask anyway: an empty answer, not a null state
		if(!m_lua)
			return flat;
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, name);
		if(lua_pcall(L, 0, 1, 0) != 0){
			log_w(MODULE, "%s(): %s", name,
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return flat;
		}
		size_t n = lua_objlen(L, -1);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, -1, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		lua_settop(L, base);
		return flat;
	}

	// What an item looks like, as the texture modifier expression the client
	// composes: its inventory image, or the first tile of the node it
	// places. Asked for the way the texmods are.
	//
	// simplified: one expression per item, so a node is drawn as one of its
	// tiles rather than as the little cube Luanti draws. The upgrade path is
	// sending the three tiles a cube shows and shearing them client-side,
	// which extensions/luanti_client does.
	void on_get_item_palettes(const network::Packet &packet)
	{
		sv_<ss_> flat = string_list_from_lua("__item_palettes");
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:item_palettes", os.str());
		});
		log_v(MODULE, "C%zu: %zu item palettes", (size_t)packet.sender,
				flat.size() / 2);
	}

	// What a hand holding a mesh node draws ([WIELD_MESH]); see
	// core.__wield_meshes()
	void on_get_wield_meshes(const network::Packet &packet)
	{
		sv_<ss_> flat = string_list_from_lua("__wield_meshes");
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:wield_meshes", os.str());
		});
	}

	void on_get_item_images(const network::Packet &packet)
	{
		sv_<ss_> flat;
		{
			interface::MutexScope ms(m_lua_mutex);
			if(!m_lua)
				return;
			lua_State *L = m_lua;
			int base = lua_gettop(L);
			lua_getglobal(L, "core");
			lua_getfield(L, -1, "__item_images");
			if(lua_pcall(L, 0, 1, 0) != 0){
				log_w(MODULE, "__item_images(): %s",
						lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
				lua_settop(L, base);
				return;
			}
			size_t n = lua_objlen(L, -1);
			flat.reserve(n);
			for(size_t i = 0; i < n; i++){
				lua_rawgeti(L, -1, (int)i + 1);
				size_t len = 0;
				const char *p = lua_tolstring(L, -1, &len);
				flat.push_back(ss_(p ? p : "", p ? len : 0));
				lua_pop(L, 1);
			}
			lua_settop(L, base);
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:item_images", os.str());
		});
		log_v(MODULE, "C%zu: %zu item images", (size_t)packet.sender,
				flat.size() / 2);
	}

	// __luanti_find_ids(x0,y0,z0,x1,y1,z1, {ids, ids, ...})
	//         -> {{x,y,z, x,y,z, ...}, ...}, one list per set of ids
	//
	// The same read as __luanti_get_region, with the match done here: what a
	// sweep over the map wants is the handful of voxels that are of a kind,
	// not a table of a quarter of a million names it then walks. Many sets
	// at once because the read is what a sweep costs and every rule that is
	// due can share one. Flat lists because three numbers per hit is cheaper
	// than a table per hit, and the caller is the one loop that cares.
	static int l_find_ids(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t x0 = luaL_checkinteger(L, 1);
		int32_t y0 = luaL_checkinteger(L, 2);
		int32_t z0 = luaL_checkinteger(L, 3);
		int32_t x1 = luaL_checkinteger(L, 4);
		int32_t y1 = luaL_checkinteger(L, 5);
		int32_t z1 = luaL_checkinteger(L, 6);
		luaL_checktype(L, 7, LUA_TTABLE);
		size_t n_sets = lua_objlen(L, 7);
		if(n_sets > 32)
			return luaL_error(L, "find_ids(): at most 32 sets at a time");
		lua_createtable(L, (int)n_sets, 0);
		for(size_t si = 1; si <= n_sets; si++){
			lua_newtable(L);
			lua_rawseti(L, -2, (int)si);
		}
		if(n_sets == 0 || x1 < x0 || y1 < y0 || z1 < z0 ||
				!MapAccess::box_ok(x0, y0, z0, x1, y1, z1))
			return 1;
		double volume = (double)(x1 - x0 + 1) * (double)(y1 - y0 + 1) *
				(double)(z1 - z0 + 1);
		if(volume > (double)MapAccess::MAX_REGION_VOXELS){
			// Lua's own formatting, which has no %.0f in it
			return luaL_error(L, "find_ids(): %s voxels is more than the "
					"%d this reads at once", cs(itos((int64_t)volume)),
					(int)MapAccess::MAX_REGION_VOXELS);
		}
		// A Luanti node id is 16 bits, so which sets an id is in is one word
		// per id and the test in the loop is one load
		sv_<uint32_t> in_sets(65536, 0);
		bool any = false;
		for(size_t si = 1; si <= n_sets; si++){
			lua_rawgeti(L, 7, (int)si);
			luaL_checktype(L, -1, LUA_TTABLE);
			size_t n_ids = lua_objlen(L, -1);
			for(size_t i = 1; i <= n_ids; i++){
				lua_rawgeti(L, -1, (int)i);
				lua_Integer id = lua_tointeger(L, -1);
				lua_pop(L, 1);
				if(id < 0 || id > 65535)
					continue;
				in_sets[id] |= 1u << (si - 1);
				any = true;
			}
			lua_pop(L, 1);
		}
		if(!any)
			return 1;
		sv_<uint32_t> words;
		self->m_map.read_region(x0, y0, z0, x1, y1, z1, words);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		int n[32] = {0};
		size_t i = 0;
		for(int32_t z = z0; z <= z1; z++)
		for(int32_t y = y0; y <= y1; y++)
		for(int32_t x = x0; x <= x1; x++, i++){
			uint32_t sets = in_sets[f.id.get(words[i])];
			while(sets){
				int si = 0;
				while(!(sets & (1u << si)))
					si++;
				sets &= ~(1u << si);
				lua_rawgeti(L, -1, si + 1);
				lua_pushinteger(L, x);
				lua_rawseti(L, -2, ++n[si]);
				lua_pushinteger(L, y);
				lua_rawseti(L, -2, ++n[si]);
				lua_pushinteger(L, z);
				lua_rawseti(L, -2, ++n[si]);
				lua_pop(L, 1);
			}
		}
		return 1;
	}

	// liquid_edges(x0, y0, z0, x1, y1, z1, liquid_ids, floodable_ids) ->
	// positions, flat: the liquid nodes of a generated box that have
	// somewhere to flow, which is what Mapgen::updateLiquid queues --
	// per column from the top, the topmost node of a liquid run when a
	// floodable node is beside it, and the lowest node of a run when the
	// node under it is floodable (or the topmost was not checked and is
	// flowable). Columns on the box's rim are skipped as official skips
	// them: their side neighbours are outside. Ignore ends a run without
	// queueing. [LIQUID_FLOW]
	static int l_liquid_edges(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t x0 = luaL_checkinteger(L, 1);
		int32_t y0 = luaL_checkinteger(L, 2);
		int32_t z0 = luaL_checkinteger(L, 3);
		int32_t x1 = luaL_checkinteger(L, 4);
		int32_t y1 = luaL_checkinteger(L, 5);
		int32_t z1 = luaL_checkinteger(L, 6);
		luaL_checktype(L, 7, LUA_TTABLE);
		luaL_checktype(L, 8, LUA_TTABLE);
		lua_newtable(L);
		if(!MapAccess::box_ok(x0, y0, z0, x1, y1, z1) || x1 - x0 < 2 || z1 - z0 < 2 ||
				y1 < y0)
			return 1;
		double volume = (double)(x1 - x0 + 1) * (double)(y1 - y0 + 1) *
				(double)(z1 - z0 + 1);
		if(volume > (double)MapAccess::MAX_REGION_VOXELS)
			return luaL_error(L, "liquid_edges(): %s voxels is more than "
					"the %d this reads at once", cs(itos((int64_t)volume)),
					(int)MapAccess::MAX_REGION_VOXELS);
		// Bit 0: a liquid; bit 1: floodable
		sv_<uint8_t> kind(65536, 0);
		for(int arg = 7; arg <= 8; arg++){
			size_t n_ids = lua_objlen(L, arg);
			for(size_t i = 1; i <= n_ids; i++){
				lua_rawgeti(L, arg, (int)i);
				lua_Integer id = lua_tointeger(L, -1);
				lua_pop(L, 1);
				if(id >= 0 && id <= 65535)
					kind[id] |= (arg == 7) ? 1 : 2;
			}
		}
		sv_<uint32_t> words;
		self->m_map.read_region(x0, y0, z0, x1, y1, z1, words);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		const size_t sx = x1 - x0 + 1, sy = y1 - y0 + 1;
		auto at = [&](int32_t x, int32_t y, int32_t z) -> uint16_t {
			return f.id.get(words[((size_t)(z - z0) * sy + (y - y0)) * sx +
					(x - x0)]);
		};
		auto flowable = [&](int32_t x, int32_t y, int32_t z) -> bool {
			return (kind[at(x + 1, y, z)] & 2) || (kind[at(x - 1, y, z)] & 2) ||
					(kind[at(x, y, z + 1)] & 2) || (kind[at(x, y, z - 1)] & 2);
		};
		int n = 0;
		auto push = [&](int32_t x, int32_t y, int32_t z){
			lua_pushinteger(L, x); lua_rawseti(L, -2, ++n);
			lua_pushinteger(L, y); lua_rawseti(L, -2, ++n);
			lua_pushinteger(L, z); lua_rawseti(L, -2, ++n);
		};
		for(int32_t z = z0 + 1; z <= z1 - 1; z++)
		for(int32_t x = x0 + 1; x <= x1 - 1; x++){
			bool wasignored = true, wasliquid = false;
			bool waschecked = false, waspushed = false;
			for(int32_t y = y1; y >= y0; y--){
				uint16_t id = at(x, y, z);
				bool isignored = id == 0;
				bool isliquid = (kind[id] & 1) != 0;
				if(isignored || wasignored || isliquid == wasliquid){
					waschecked = false;
					waspushed = false;
				} else if(isliquid){
					// The topmost node of a liquid run
					bool pushed = false;
					if(flowable(x, y, z)){
						push(x, y, z);
						pushed = true;
					}
					waschecked = true;
					waspushed = pushed;
				} else {
					// The topmost node under a liquid run
					if(!waspushed && ((kind[id] & 2) ||
							(!waschecked && flowable(x, y + 1, z))))
						push(x, y + 1, z);
				}
				wasliquid = isliquid;
				wasignored = isignored;
			}
		}
		return 1;
	}

	// find_nodes(x0, y0, z0, x1, y1, z1, ids) -> positions, ids_at
	//
	// Every voxel of the box whose content id is in the list: the positions
	// flat -- x, y, z, x, y, z -- and the id found at each, in the order
	// Luanti's own find_nodes_in_area() answers in, which is x fastest.
	//
	// The Lua this replaces walked the box a voxel at a time asking a
	// closure about each, and was a quarter of all the Lua VoxeLibre's world
	// generation ran. What is left in Lua is one table per *hit*, which is
	// what the API hands back and cannot be helped.
	static int l_find_nodes(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t x0 = luaL_checkinteger(L, 1);
		int32_t y0 = luaL_checkinteger(L, 2);
		int32_t z0 = luaL_checkinteger(L, 3);
		int32_t x1 = luaL_checkinteger(L, 4);
		int32_t y1 = luaL_checkinteger(L, 5);
		int32_t z1 = luaL_checkinteger(L, 6);
		luaL_checktype(L, 7, LUA_TTABLE);
		lua_newtable(L); // positions
		lua_newtable(L); // ids at each
		if(x1 < x0 || y1 < y0 || z1 < z0 || !MapAccess::box_ok(x0, y0, z0, x1, y1, z1))
			return 2;
		double volume = (double)(x1 - x0 + 1) * (double)(y1 - y0 + 1) *
				(double)(z1 - z0 + 1);
		if(volume > (double)MapAccess::MAX_REGION_VOXELS){
			// Lua's own formatting, which has no %.0f in it
			return luaL_error(L, "find_nodes(): %s voxels is more than the "
					"%d this reads at once", cs(itos((int64_t)volume)),
					(int)MapAccess::MAX_REGION_VOXELS);
		}
		// A Luanti node id is 16 bits, so wanted-or-not is one byte per id
		// and the test in the loop is one load
		sv_<uint8_t> wanted(65536, 0);
		bool any = false;
		const size_t n_ids = lua_objlen(L, 7);
		for(size_t i = 1; i <= n_ids; i++){
			lua_rawgeti(L, 7, (int)i);
			lua_Integer id = lua_tointeger(L, -1);
			lua_pop(L, 1);
			if(id < 0 || id > 65535)
				continue;
			wanted[id] = 1;
			any = true;
		}
		if(!any)
			return 2;
		sv_<uint32_t> words;
		self->m_map.read_region(x0, y0, z0, x1, y1, z1, words);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		int n_pos = 0, n_hit = 0;
		size_t i = 0;
		for(int32_t z = z0; z <= z1; z++)
		for(int32_t y = y0; y <= y1; y++)
		for(int32_t x = x0; x <= x1; x++, i++){
			const uint32_t id = f.id.get(words[i]);
			if(!wanted[id])
				continue;
			lua_pushinteger(L, x);
			lua_rawseti(L, -3, ++n_pos);
			lua_pushinteger(L, y);
			lua_rawseti(L, -3, ++n_pos);
			lua_pushinteger(L, z);
			lua_rawseti(L, -3, ++n_pos);
			lua_pushinteger(L, (lua_Integer)id);
			lua_rawseti(L, -2, ++n_hit);
		}
		return 2;
	}

	static int l_get_region(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t x0 = luaL_checkinteger(L, 1);
		int32_t y0 = luaL_checkinteger(L, 2);
		int32_t z0 = luaL_checkinteger(L, 3);
		int32_t x1 = luaL_checkinteger(L, 4);
		int32_t y1 = luaL_checkinteger(L, 5);
		int32_t z1 = luaL_checkinteger(L, 6);
		if(x1 < x0 || y1 < y0 || z1 < z0 || !MapAccess::box_ok(x0, y0, z0, x1, y1, z1)){
			lua_newtable(L);
			return 1;
		}
		double volume = (double)(x1 - x0 + 1) * (double)(y1 - y0 + 1) *
				(double)(z1 - z0 + 1);
		if(volume > (double)MapAccess::MAX_REGION_VOXELS){
			// Lua's own formatting, which has no %.0f in it
			return luaL_error(L, "get_region(): %s voxels is more than the "
					"%d this reads at once", cs(itos((int64_t)volume)),
					(int)MapAccess::MAX_REGION_VOXELS);
		}
		sv_<uint32_t> words;
		self->m_map.read_region(x0, y0, z0, x1, y1, z1, words);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		lua_createtable(L, (int)words.size(), 0);
		for(size_t i = 0; i < words.size(); i++){
			lua_pushinteger(L, (lua_Integer)f.id.get(words[i]));
			lua_rawseti(L, -2, (int)i + 1);
		}
		return 1;
	}
