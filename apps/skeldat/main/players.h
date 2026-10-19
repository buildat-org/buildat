// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT_MODULAR] **The players**: who is in the world, their
// inventories, what they do (dig, place, craft, the bow, the drops they
// take), what they are sent, and the session's calls
// (luanti_session::Game), by the player's name. Placed at the join; in the
// world when the client says it has the world loaded (luanti:world_in),
// which changes nothing here. The leave is the Module's
// on_client_disconnected. The mobs reach the players through MobsHost;
// what is the world's run (the role, the end, the pause) is PlayersHost's,
// which the Module is.
// Included by main.cpp inside namespace skeldat, after mobs.h
#pragma once

struct PlayersHost
{
	virtual void update_role(size_t peer, Player &pl, bool tell) = 0;
	virtual void send_end(size_t peer) = 0;
	virtual void send_world(size_t peer) = 0;
	virtual void send_intro(size_t peer) = 0;
	// A player placed and sent everything else: the pause's part
	virtual void joined(size_t peer, Player &pl) = 0;
	// A skip of time running: the players held
	virtual bool skipping() = 0;
protected:
	~PlayersHost() {}
};

struct Players: public luanti_session::Game, public MobsHost
{
	WorldView &world;
	PlayersHost &host;
	// The Module's, the world's save while one is open
	storage::Save *&save;
	Mobs &mobs;
	Drops &drops;
	BonesGrowth &growth;
	Furnaces &furnaces;
	std::map<size_t, Player> all;
	// The peers shown the world (show())
	std::set<size_t> shown;
	luanti_session::Session session{*this};

	Players(WorldView &world, PlayersHost &host, storage::Save *&save,
			Mobs &mobs, Drops &drops, BonesGrowth &growth, Furnaces &furnaces):
		world(world), host(host), save(save), mobs(mobs), drops(drops),
		growth(growth), furnaces(furnaces)
	{}

	// Once per peer: files_transmitted comes again after each batch
	void show(size_t peer)
	{
		if(!shown.insert(peer).second)
			return;
		ss_ name;
		accounts::access(world.server, [&](accounts::Interface *i){
			name = i->name_of(peer);
		});
		// A peer without an account is "client<peer>", which accounts keeps
		// from new accounts (reserved_name()): "player<peer>" was any
		// account's of that name, its inventory and its chat name
		if(name.empty())
			name = "client"+itos(peer);
		session.join(name, peer, false);
	}

	void place_player(const ss_ &name, size_t peer)
	{
		Player &pl = all[peer];
		pl.name = name;
		ss_ v;
		if(save->store("skeldat_players")->get(name, v))
			pl.load(v);
		else
			pl.intro = !getenv("BUILDAT_SKELDAT_INTRO") ||
					ss_(getenv("BUILDAT_SKELDAT_INTRO")) != "0";
		network::send(world.server, peer, "core:run_script",
				"buildat.run_script_file(\"main/init.lua\")");
		network::send(world.server, peer, "skeldat:items", items_text());
		host.update_role(peer, pl, true);
		chat::access(world.server, [&](chat::Interface *c){ c->join(peer, name); });
		replicate::assign_scene_to_peer(world.server, world.scene, peer);
		if(!pl.placed)
			respawn(peer, pl);
		else
			send_position(peer, pl);
		send_inventory(peer, pl);
		send_stats(peer, pl);
		send_time(peer);
		host.send_end(peer);
		host.send_world(peer);
		host.joined(peer, pl);
		world.load_points_dirty = true;
		log_i(MODULE, "skeldat: %s joins at (%.1f, %.1f, %.1f)", cs(name),
				pl.x, pl.y, pl.z);
	}

	void add_player(const ss_ &name, size_t peer)
	{
		log_i(MODULE, "skeldat: %s is in the world", cs(name));
		auto it = all.find(peer);
		// [SKELDAT_DEAD_REJOIN] A dead joiner's hp 0 again once its world
		// is in, its screens up by then (the join's was sent before)
		if(it != all.end() && it->second.hp <= 0)
			send_stats(peer, it->second);
		if(it != all.end() && it->second.intro){
			it->second.intro = false;
			host.send_intro(peer);
		}
	}

	void remove_player(const ss_ &name){}

	// accounts' admin is host.update_role()'s
	void set_admin(const ss_ &name, bool admin){}

	// Chat is builtin/chat's
	void chat_message(const ss_ &name, const ss_ &message){}

	void chat_send(const ss_ &to, const ss_ &text){}

	// The drop key: count of the held stack, 0 all of it, thrown ahead
	bool drop_wielded(const ss_ &name, int count)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(!pl || pl->main[pl->wield].empty())
			return false;
		Stack &st = pl->main[pl->wield];
		const int n = count <= 0 || count > st.count ? st.count : count;
		Stack out = st;
		out.count = n;
		st.take(n);
		const float yaw = pl->yaw * (float)M_PI / 180;
		drops.drop(out, pl->x, pl->y + 1.2f, pl->z, std::sin(yaw) * 3, 2,
				std::cos(yaw) * 3, pl->name);
		send_inventory(peer, *pl);
		return true;
	}

	// [SKELDAT_INV_DROP] count of a slot dropped as the drop key drops: the
	// slot by a move's source checks (slot()), the count clamped
	void drop_slot(size_t peer, Player &pl, int count, const ss_ &loc,
			const ss_ &list, int index)
	{
		Stack *from = slot(pl, loc, list, index, false);
		if(!from || from->empty() || count <= 0 || pl.hp <= 0)
			return;
		Stack out = *from;
		out.count = std::min(count, from->count);
		from->take(out.count);
		log_i(MODULE, "skeldat: %s drops %s from %s %s:%d", cs(pl.name),
				cs(out.str()), cs(loc), cs(list), index);
		const float yaw = pl.yaw * (float)M_PI / 180;
		drops.drop(out, pl.x, pl.y + 1.2f, pl.z, std::sin(yaw) * 3, 2,
				std::cos(yaw) * 3, pl.name);
		send_inventory(peer, pl);
		if(loc != "me")
			send_furnace(loc);
	}

	// The living player by name; the dead do nothing but respawn, which is
	// skeldat:respawn
	// simplified: a walk over the players, a handful at most
	Player *alive(const ss_ &name, size_t &peer)
	{
		for(auto &pair : all){
			if(pair.second.name == name){
				peer = pair.first;
				return pair.second.hp > 0 ? &pair.second : nullptr;
			}
		}
		return nullptr;
	}

	void set_player_pos(const ss_ &name, float x, float y, float z,
			float look_h, float look_v, int32_t controls)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(!pl)
			return;
		for(float v : {x, y, z, look_h})
			if(!std::isfinite(v) || std::fabs(v) > 1e6f)
				return;
		// A lagging client's places from before the one sent: a pull back
		// of each would only queue more of them
		if(pl->moved){
			if((controls & PLACES_MASK) != pl->places)
				return;
			pl->moved = false;
		}
		auto section = [](const Player &pl){
			return std::make_tuple((int)std::floor(pl.x / 16),
					(int)std::floor(pl.y / 16), (int)std::floor(pl.z / 16));
		};
		const auto was = section(*pl);
		// simplified: the gap at least 0.05 s, so a where sent early (the
		// bow's release sends one) does not read as a burst of speed
		if(pl->where_t >= 0)
			pl->speed = std::sqrt((x - pl->x) * (x - pl->x) +
					(y - pl->y) * (y - pl->y) + (z - pl->z) * (z - pl->z)) /
					std::max(0.05, world.time - pl->where_t);
		pl->where_t = world.time;
		pl->x = x;
		pl->y = y;
		pl->z = z;
		pl->board = (controls & BOARD_BIT) != 0;
		pl->board_seen = pl->board_seen || pl->board;
		pl->prone = (controls & PRONE_BIT) != 0;
		pl->prone_seen = pl->prone_seen || pl->prone;
		// Luanti's horizontal look turns the other way from Urho's yaw
		pl->yaw = -look_h * 180 / (float)M_PI;
		if(section(*pl) != was)
			world.load_points_dirty = true;
	}

	// [SKELDAT_NO_FALL_DAMAGE] A fall does not hurt (user, 2026-10-17):
	// getting back up is its cost
	void player_fell(const ss_ &name, float speed)
	{
		log_i(MODULE, "skeldat: %s lands at %.1f, no damage", cs(name), speed);
	}

	void set_wield_index(const ss_ &name, int index)
	{
		size_t peer;
		if(Player *pl = alive(name, peer)){
			const int w = std::max(0, std::min(8, index - 1));
			// A switch ends the bow's draw unshot
			if(w != pl->wield)
				pl->draw_t = -1;
			pl->wield = w;
		}
	}

	bool dig_node(int32_t x, int32_t y, int32_t z, const ss_ &name)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(pl)
			dig(peer, *pl, x, y, z);
		return pl != nullptr;
	}

	// Where a held dig starts: dig() wants it to have taken its time
	bool punch_node(int32_t x, int32_t y, int32_t z, const ss_ &name)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(!pl)
			return false;
		pl->dig_at = pos_key(x, y, z);
		pl->dig_t0 = world.time;
		return true;
	}

	bool punch_object(int32_t id, const ss_ &name)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(pl)
			punch(peer, *pl, (uint32_t)id);
		return pl != nullptr;
	}

	// Into above; under is what was pointed at, and the table's and the
	// furnace's windows are skeldat:open
	bool place_node(int32_t under_x, int32_t under_y, int32_t under_z,
			int32_t above_x, int32_t above_y, int32_t above_z,
			const ss_ &name, bool sneak)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(pl)
			place(peer, *pl, above_x, above_y, above_z);
		return pl != nullptr;
	}

	// Food is eaten
	bool use_wielded(const ss_ &name)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(!pl)
			return false;
		Stack &st = pl->main[pl->wield];
		const skeldat::ItemDef *d = world.game.item(st.name);
		if(!d || d->eat <= 0 || pl->hp >= HP_MAX)
			return false;
		pl->hp = std::min(HP_MAX, pl->hp + d->eat);
		st.take(1);
		log_i(MODULE, "skeldat: %s eats %s", cs(pl->name), cs(d->name));
		send_inventory(peer, *pl);
		send_stats(peer, *pl);
		return true;
	}

	void respawn(size_t peer, Player &pl)
	{
		pl.x = world.spawn[0];
		pl.y = world.spawn[1];
		pl.z = world.spawn[2];
		pl.hp = HP_MAX;
		pl.breath = BREATH_MAX;
		pl.placed = true;
		send_position(peer, pl);
		send_stats(peer, pl);
	}

	// Where the server puts the player: the movement check's base too
	void send_position(size_t peer, Player &pl)
	{
		// Its range follows ([SKELDAT_RESPAWN_LOAD]): the moves' own check
		// sees no section change, the place having been set here already,
		// and a respawned player's range stayed where it died
		world.load_points_dirty = true;
		pl.cx = pl.x;
		pl.cy = pl.y;
		pl.cz = pl.z;
		pl.check_t = world.time;
		pl.check_air = false;
		pl.moved = true;
		pl.places = (pl.places + 1) & PLACES_MASK;
		std::ostringstream os;
		os<<pl.x<<" "<<pl.y<<" "<<pl.z<<" "<<pl.yaw;
		network::send(world.server, peer, "skeldat:position", os.str());
	}

	void send_stats(size_t peer, const Player &pl)
	{
		network::send(world.server, peer, "skeldat:stats",
				itos(pl.hp)+" "+itos(pl.breath));
	}

	void send_time(size_t peer)
	{
		std::ostringstream os;
		os<<world.day<<" "<<(1.0 / world.day_s);
		network::send(world.server, peer, "skeldat:time", os.str());
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
		const skeldat::Recipe *r = world.game.craft(grid);
		sv_<Stack> preview(1);
		if(r)
			preview[0] = Stack::parse(r->output);
		network::send(world.server, peer, "skeldat:inv", list_text("main", pl.main)+
				list_text("craft", pl.craft)+
				list_text("craftresult", pl.craftresult)+
				list_text("craftpreview", preview));
	}

	void send_furnace(const ss_ &at)
	{
		auto it = furnaces.all.find(at);
		if(it == furnaces.all.end())
			return;
		const Furnace &f = it->second;
		std::ostringstream os;
		os<<at<<"\n"<<list_text("src", {f.src})<<list_text("fuel", {f.fuel})
				<<list_text("dst", {f.dst});
		for(auto &pair : all)
			if(pair.second.open == at)
				network::send(world.server, pair.first, "skeldat:node_inv",
						os.str());
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
		os<<"hand\t"<<caps(world.game.hand.caps)<<"\n";
		for(auto &pair : world.game.items){
			const skeldat::ItemDef &d = pair.second;
			os<<"item\t"<<d.name<<"\t"<<d.desc<<"\t"<<d.image<<"\t"
					<<d.stack_max<<"\t"<<caps(d.caps)<<"\t"<<d.eat<<"\n";
		}
		for(const skeldat::NodeDef &n : world.game.nodes){
			os<<"node\t"<<n.name<<"\t";
			for(auto &g : n.groups)
				os<<g.first<<"="<<g.second<<";";
			os<<"\n";
		}
		return os.str();
	}

	void save_player(const Player &pl)
	{
		if(save && pl.placed)
			save->store("skeldat_players")->set(pl.name, pl.save());
	}

	// From the player's eyes to the middle of the voxel
	// Within reach, and inside the world above its bottom layer, which is
	// not dug ([SKELDAT_BOUNDED_WORLD])
	bool reaches(const Player &pl, int x, int y, int z)
	{
		if(growth.ended || !world.reaches_world(x, y, z))
			return false;
		const float dx = x - pl.x, dy = y - (pl.y + EYE), dz = z - pl.z;
		return std::sqrt(dx * dx + dy * dy + dz * dz) <= REACH;
	}

	// [SKELDAT_BOW_AIM] Where an arrow starts: the client's eye at the
	// release (e, when it sent one) if it is within 1.5 + speed x 0.25 of
	// the server's copy's eye and no solid voxel is between the two, else
	// the copy's eye. A client cannot shoot from inside a wall or afar.
	Urho3D::Vector3 bow_eye(const Player &pl, const float *e)
	{
		const Urho3D::Vector3 copy(pl.x, pl.y + (pl.prone ? PRONE_EYE : EYE),
				pl.z);
		if(!e)
			return copy;
		// For a check: the eye said moved this far along x (a client's lie)
		static const float shift = getenv("BUILDAT_SKELDAT_EYE_SHIFT") ?
				(float)atof(getenv("BUILDAT_SKELDAT_EYE_SHIFT")) : 0;
		const Urho3D::Vector3 eye(e[0] + shift, e[1], e[2]);
		const float off = (eye - copy).Length();
		const bool finite = std::isfinite(e[0]) && std::isfinite(e[1]) &&
				std::isfinite(e[2]);
		bool clear = finite && off <= 1.5f + pl.speed * 0.25f;
		if(clear){
			voxelworld::access(world.server, world.scene,
					[&](voxelworld::Instance *w){
				const int n = (int)std::ceil(off / 0.25f);
				for(int i = 1; i <= n && clear; i++){
					const Urho3D::Vector3 p = copy + (eye - copy) * (i / (float)n);
					clear = !world.walkable(w, (int)std::floor(p.x_ + 0.5f),
							(int)std::floor(p.y_ + 0.5f),
							(int)std::floor(p.z_ + 0.5f));
				}
			});
		}
		if(clear)
			return eye;
		log_w(MODULE, "skeldat: %s's eye at the release refused (%.2f off at "
				"%.1f a second%s): the copy's", cs(pl.name), finite ? off : -1.0f,
				pl.speed, finite && off <= 1.5f + pl.speed * 0.25f ?
				", through a voxel" : "");
		return copy;
	}

	// [SKELDAT_BOW] "start": the draw begins with the bow held and an
	// arrow in the main inventory; "release dx dy dz [ex ey ez]": timed
	// here, the arrow shot from the eye (bow_eye()) along the look at the
	// draw's speed, one arrow taken and the bow worn; under BOW_MIN nothing
	void bow(size_t peer, Player &pl, const ss_ &how, float dx, float dy,
			float dz, const float *e = nullptr)
	{
		Stack &held = pl.main[pl.wield];
		auto arrow = std::find_if(pl.main.begin(), pl.main.end(),
				[](const Stack &st){ return st.name == "skeldat:arrow"; });
		if(how == "start"){
			pl.draw_t = held.name == "skeldat:bow" && arrow != pl.main.end() ?
					world.time : -1;
			if(pl.draw_t >= 0){
				log_i(MODULE, "skeldat: %s draws the bow", cs(pl.name));
				// [SKELDAT_BOW_SOUNDS] The others hear the draw play out
				sound("bow_draw", pl.x, pl.y + 1.5f, pl.z, peer);
			}
			return;
		}
		if(how != "release" || pl.draw_t < 0)
			return;
		// The where the client sent with the release, applied now
		session.apply_where(peer);
		const float draw = std::min(1.0f, (float)(world.time - pl.draw_t) / BOW_DRAW);
		pl.draw_t = -1;
		const float l = std::sqrt(dx * dx + dy * dy + dz * dz);
		if(held.name != "skeldat:bow" || arrow == pl.main.end() ||
				!(l > 0.5f && l < 2)){
			return;
		}
		if(draw < BOW_MIN){
			log_i(MODULE, "skeldat: %s lets the bow go undrawn (%.2f)",
					cs(pl.name), draw);
			return;
		}
		dx /= l, dy /= l, dz /= l;
		arrow->take(1);
		held.wear += skeldat::WEAR_MAX / BOW_USES;
		if(held.wear >= skeldat::WEAR_MAX)
			held = Stack();
		send_inventory(peer, pl);
		const float speed = draw * BOW_SPEED;
		const Urho3D::Vector3 eye = bow_eye(pl, e);
		const float off = (eye - Urho3D::Vector3(pl.x, pl.y +
				(pl.prone ? PRONE_EYE : EYE), pl.z)).Length();
		Arrow a;
		a.x = eye.x_ + dx * 0.5f, a.y = eye.y_ + dy * 0.5f,
				a.z = eye.z_ + dz * 0.5f;
		a.vx = dx * speed, a.vy = dy * speed, a.vz = dz * speed;
		a.by_player = true;
		a.peer = peer;
		main_context::access(world.server, world.scene, [&](Urho3D::Scene *scene){
			Urho3D::Node *n = scene->CreateChild("skeldat_arrow");
			n->SetPosition(Urho3D::Vector3(a.x, a.y, a.z));
			a.node_id = n->GetID();
		});
		mobs.arrows.push_back(a);
		// [SKELDAT_BOW_SOUND_TUNE] The shooter plays its own at the release
		sound("bow", a.x, a.y, a.z, peer);
		log_i(MODULE, "skeldat: %s shoots an arrow at %.1f (drawn %.2f) from "
				"%.3f,%.3f,%.3f (the copy's %.2f off; the feet at %.2f)",
				cs(pl.name), speed, draw, eye.x_, eye.y_, eye.z_, off, pl.y);
	}

	// drops: false, what the death drops is burnt (lava): gone
	void hurt(size_t peer, Player &pl, int damage, const char *how,
			bool drops = true)
	{
		if(damage <= 0 || pl.hp <= 0)
			return;
		// [SKELDAT_SKIP_TIME] Held through a skip, unharmed
		if(pl.invulnerable || host.skipping()){
			log_i(MODULE, "skeldat: %s %s, %s", cs(pl.name), how,
					pl.invulnerable ? "invulnerable" : "held by a skip");
			return;
		}
		pl.hp = std::max(0, pl.hp - damage);
		log_i(MODULE, "skeldat: %s %s, %d hp left", cs(pl.name), how, pl.hp);
		if(pl.hp == 0){
			death_drops(pl, !drops);
			send_inventory(peer, pl);
		}
		send_stats(peer, pl);
	}

	// Half the non-empty stacks, rounded up, picked at random, dropped
	// where the player died (burnt: gone); nothing below the world
	void death_drops(Player &pl, bool burnt = false)
	{
		if(pl.y < world.y0 * skeldat::bones::SECTION)
			return;
		sv_<Stack*> full;
		for(auto *l : {&pl.main, &pl.craft, &pl.craftresult})
			for(Stack &st : *l)
				if(!st.empty())
					full.push_back(&st);
		std::shuffle(full.begin(), full.end(), world.rand);
		const size_t n = (full.size() + 1) / 2;
		for(size_t i = 0; i < n; i++){
			if(!burnt)
				drops.drop(*full[i], pl.x + world.rnd() - 0.5f, pl.y + 0.5f,
						pl.z + world.rnd() - 0.5f);
			*full[i] = Stack();
		}
		log_i(MODULE, "skeldat: %s dies at %.1f,%.1f,%.1f, %s %zu of %zu "
				"stacks", cs(pl.name), pl.x, pl.y, pl.z,
				burnt ? "burning" : "dropping", n, full.size());
	}

	// What does not fit the player's inventory, dropped at its feet
	void give_or_drop(Player &pl, const Stack &st)
	{
		drops.drop(world.game.add(pl.main, st), pl.x, pl.y + 0.5f, pl.z);
	}

	// The drops a tick; a living player within DROP_REACH takes what fits
	// (the drop key's not its dropper's until it has walked away from it)
	void step_drops(float dt)
	{
		// An unloaded voxel is ground to walkable(): not before the world
		if(!world.ready)
			return;
		// [SKELDAT_BOW_SOUNDS] One pickup sound a player a tick, at a drop
		// it took from
		std::map<size_t, Urho3D::Vector3> picked;
		drops.step(dt, world.day_s, [&](Drop &d){
			for(auto &pair : all){
				Player &pl = pair.second;
				if(!pl.placed || pl.hp <= 0)
					continue;
				const float dist = std::sqrt((pl.x - d.x) * (pl.x - d.x) +
						(pl.y + 0.5f - d.y) * (pl.y + 0.5f - d.y) +
						(pl.z - d.z) * (pl.z - d.z));
				if(pl.name == d.owner){
					if(dist > DROP_AWAY)
						d.owner.clear();
					continue;
				}
				if(dist > DROP_REACH)
					continue;
				const Stack left = world.game.add(pl.main, d.st);
				if(left.count == d.st.count)
					continue;
				log_i(MODULE, "skeldat: %s picks up %d %s", cs(pl.name),
						d.st.count - left.count, cs(d.st.name));
				d.st = left;
				send_inventory(pair.first, pl);
				picked[pair.first] = Urho3D::Vector3(d.x, d.y, d.z);
				if(d.st.empty())
					break;
			}
		});
		for(auto &pair : picked){
			sound("pickup", pair.second.x_, pair.second.y_, pair.second.z_,
					pair.first);
			sound_own(pair.first, "pickup");
		}
	}

	void dig(size_t peer, Player &pl, int x, int y, int z)
	{
		const ss_ at = pos_key(x, y, z);
		// Reach first: a client's y of 5e8 made voxelworld throw, and each
		// throw logged a backtrace ([SECURITY_RUN_6])
		if(!reaches(pl, x, y, z)){
			log_i(MODULE, "skeldat: %s's dig at %s refused", cs(pl.name),
					cs(at));
			return;
		}
		const uint32_t id = world.id_at(x, y, z);
		const skeldat::NodeDef *n = world.node_of(id);
		Stack &tool = pl.main[pl.wield];
		// The bow digs nothing ([SKELDAT_BOW])
		if(tool.name == "skeldat:bow")
			return;
		const skeldat::Cap *cap = nullptr;
		const float time = n ? world.game.dig_time(tool.name, *n, &cap) : -1;
		// A quarter less than the time, for the network's lag
		if(!n || time < 0 || !reaches(pl, x, y, z) || pl.dig_at != at ||
				world.time - pl.dig_t0 < time * 0.75f){
			log_i(MODULE, "skeldat: %s's dig at %s refused", cs(pl.name),
					cs(at));
			return;
		}
		if(has_slots(n->name)){
			if(!furnaces.dug(at))
				return; // not while it holds anything
		}
		pl.dig_at = "";
		const int bones = world.bones_at(x, y, z);
		// [SKELDAT_APPLE_TREES] A dug apple leaves its branch, an apple
		// again at midnight
		world.set_node(x, y, z, n->name == "skeldat:apple_fruit" ?
				world.id_of("skeldat:apple_branch") : ID_AIR);
		if(cap && cap->uses > 0){
			tool.wear += skeldat::WEAR_MAX / cap->uses;
			if(tool.wear >= skeldat::WEAR_MAX)
				tool = Stack();
		}
		// What it drops goes straight into the inventory, what does not
		// fit to the ground
		Stack drop;
		if(bones > skeldat::bones::NO_DROP)
			; // bone-ridden: nothing
		else if(n->drop == "")
			drop = Stack(n->name);
		else if(n->drop != "-" && (n->drop_rarity <= 1 ||
				world.rand() % n->drop_rarity == 0))
			drop = Stack::parse(n->drop);
		give_or_drop(pl, drop);
		// The arrows stuck into it, the digger's ([SKELDAT_BOW])
		static const int FACE[6][3] = {{0, 1, 0}, {0, -1, 0}, {1, 0, 0},
				{-1, 0, 0}, {0, 0, 1}, {0, 0, -1}};
		for(int f = 0; f < 6; f++){
			const int ax = x - FACE[f][0], ay = y - FACE[f][1],
					az = z - FACE[f][2];
			if(world.id_at(ax, ay, az) == world.stuck_id &&
					world.param_at(ax, ay, az) == (uint32_t)f){
				world.set_node(ax, ay, az, ID_AIR);
				give_or_drop(pl, Stack("skeldat:arrow"));
			}
		}
		log_i(MODULE, "skeldat: %s digs %s at %s, bones %d%s", cs(pl.name),
				cs(n->name), cs(at), bones, bones > skeldat::bones::NO_DROP ?
				", dropping nothing" : "");
		send_inventory(peer, pl);
	}

	void place(size_t peer, Player &pl, int x, int y, int z)
	{
		if(!reaches(pl, x, y, z))
			return;
		Stack &st = pl.main[pl.wield];
		const uint32_t id = world.id_of(st.name);
		const skeldat::NodeDef *n = world.node_of(id);
		const skeldat::NodeDef *here = world.node_of(world.id_at(x, y, z));
		const uint32_t here_id = world.id_at(x, y, z);
		// Into air or water, beside something, out of everyone's way
		bool beside = false;
		static const int D[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0},
				{0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
		for(auto &d : D){
			const uint32_t b = world.id_at(x + d[0], y + d[1], z + d[2]);
			beside = beside || (b != ID_AIR && b != ID_IGNORE &&
					b != world.id_of("skeldat:water_source"));
		}
		// An apple branch is built over as air is ([SKELDAT_APPLE_TREES])
		if(!n || !(here_id == ID_AIR || here_id == world.stuck_id ||
				(here && here->name == "skeldat:apple_branch") || (here &&
				(here->shape == skeldat::LIQUID || here->shape == skeldat::GAS))) ||
				!beside ||
				!reaches(pl, x, y, z))
			return;
		// [SKELDAT_WATER_TORCH] No torch into a liquid
		if(n->shape == skeldat::TORCH && here && here->shape == skeldat::LIQUID){
			log_i(MODULE, "skeldat: %s's torch into %s at %s refused",
					cs(pl.name), cs(here->name), cs(pos_key(x, y, z)));
			return;
		}
		if(n->shape != skeldat::TORCH){
			for(auto &pair : all){
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
		// [SKELDAT_APPLE_TREES] Placed leaves never decay: param2's 1
		if(n->groups.count("leaves"))
			param = 1;
		world.set_node(x, y, z, id, param);
		log_i(MODULE, "skeldat: %s places %s at %s", cs(pl.name),
				cs(n->name), cs(pos_key(x, y, z)));
		if(n->name == "skeldat:furnace" || n->name == "skeldat:lantern")
			furnaces.placed(x, y, z, n->name == "skeldat:lantern");
		st.take(1);
		send_inventory(peer, pl);
	}

	// A furnace or a lantern, lit or not: furnaces holds its slots
	static bool has_slots(const ss_ &name)
	{
		return name.compare(0, 15, "skeldat:furnace") == 0 ||
				name.compare(0, 15, "skeldat:lantern") == 0;
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
		auto it = furnaces.all.find(loc);
		if(it == furnaces.all.end())
			return nullptr;
		if(it->second.lantern && list != "fuel")
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
		return world.id_at(x, y, z) == world.id_of("skeldat:table");
	}

	void move(size_t peer, Player &pl, int count, const ss_ &floc,
			const ss_ &flist, int fi, const ss_ &tloc, const ss_ &tlist,
			int ti)
	{
		Stack *from = slot(pl, floc, flist, fi, false);
		Stack *to = slot(pl, tloc, tlist, ti, true);
		if(!from || !to || !world.game.move(*from, *to, count))
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
		const skeldat::Recipe *r = world.game.craft(grid);
		if(!r || (outside && !at_table(pl)))
			return;
		Stack out = Stack::parse(r->output);
		Stack &res = pl.craftresult[0];
		if(!res.empty() && (res.name != out.name ||
				res.count + out.count > world.game.stack_max(out.name)))
			return;
		for(Stack &s : pl.craft)
			if(!s.empty())
				s.take(1);
		if(res.empty())
			res = out;
		else
			res.count += out.count;
		log_i(MODULE, "skeldat: %s crafts %s, the result %s", cs(pl.name),
				cs(out.str()), cs(res.str()));
		send_inventory(peer, pl);
	}

	// The nearest player placed and alive, and how far
	Player* nearest(float x, float y, float z, float &d,
			size_t *peer_out = nullptr)
	{
		Player *best = nullptr;
		d = 1e9f;
		for(auto &pair : all){
			Player &p = pair.second;
			const float e = std::sqrt((p.x-x)*(p.x-x) + (p.y-y)*(p.y-y) +
					(p.z-z)*(p.z-z));
			if(p.placed && p.hp > 0 && e < d){
				d = e;
				best = &p;
				if(peer_out)
					*peer_out = pair.first;
			}
		}
		return best;
	}

	// A moment's sound at a place, to everyone in the world; what it sounds
	// like is the client's (client_lua/sounds.lua)
	// (but `except`, which plays it itself)
	void sound(const char *moment, float x, float y, float z,
			size_t except = (size_t)-1)
	{
		char buf[100];
		snprintf(buf, sizeof buf, "%s %.2f %.2f %.2f", moment, x, y, z);
		for(size_t peer : shown)
			if(peer != except)
				network::send(world.server, peer, "skeldat:sound", buf);
	}

	void sound_own(size_t peer, const char *moment)
	{
		if(shown.count(peer))
			network::send(world.server, peer, "skeldat:sound_own", moment);
	}
	void sound_near(size_t peer, const char *moment, float x, float y, float z)
	{
		char buf[100];
		snprintf(buf, sizeof buf, "%s %.2f %.2f %.2f near 16", moment, x, y, z);
		if(shown.count(peer))
			network::send(world.server, peer, "skeldat:sound", buf);
	}

	// A client's click at a mob: what the player holds hits it, from no
	// further than a hand reaches with room for the lag
	void punch(size_t peer, Player &pl, uint32_t id)
	{
		if(id == 0 || world.time - pl.last_hit < 0.35 ||
				pl.main[pl.wield].name == "skeldat:bow")
			return;
		for(auto &kv : mobs.all){
			Mob &m = kv.second;
			if(m.node_id != id)
				continue;
			const float dy = pl.y + 1.6f - m.y - MOB_HEIGHT[m.kind] / 2.0f;
			if(std::sqrt((pl.x-m.x)*(pl.x-m.x) + (pl.z-m.z)*(pl.z-m.z) +
					dy * dy) > 6)
				return;
			pl.last_hit = world.time;
			Stack &st = pl.main[pl.wield];
			const skeldat::ItemDef *def = world.game.item(st.name);
			const int dmg = def ? def->fleshy : world.game.hand.fleshy;
			if(def && def->tool){
				st.wear += skeldat::WEAR_MAX /
						(st.name.find("sword") != ss_::npos ? 200 : 100);
				if(st.wear >= skeldat::WEAR_MAX)
					st = Stack();
				send_inventory(peer, pl);
			}
			log_i(MODULE, "skeldat: %s hits the %s (%u) for %d, hp %d",
					cs(pl.name), MOB_KIND[m.kind], kv.first, dmg, m.hp - dmg);
			mobs.damage(kv.first, dmg, peer, pl.x, pl.z);
			return;
		}
	}

	// The movement check (move_check.h), every second for each player not
	// an admin: a move that could not have been made is pulled back to
	// where the last check passed
	// simplified: every player in the same tick, under a millisecond each
	// (2026-10-15); spread them over the second when there are many
	void check_moves()
	{
		for(auto &pair : all){
			const size_t peer = pair.first;
			Player &pl = pair.second;
			host.update_role(peer, pl, false);
			if(!pl.placed)
				continue;
			const float dt = (float)(world.time - pl.check_t);
			skeldat::move_check::Board bd;
			bd.on = pl.board_seen;
			bd.v0 = pl.check_v;
			bd.air = pl.board_air;
			bd.prone = pl.prone_seen;
			pl.board_seen = pl.board;
			pl.prone_seen = pl.prone;
			if(pl.admin || pl.hp <= 0 || dt <= 0 || pl.moved){
				pl.cx = pl.x;
				pl.cy = pl.y;
				pl.cz = pl.z;
				pl.check_t = world.time;
				pl.check_air = false;
				pl.check_v = 0;
				pl.board_air = 0;
				continue;
			}
			skeldat::move_check::Verdict v;
			voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
				v = skeldat::move_check::check([&](vp::Field &f){
					world.fill_cells(w, f);
				}, pl.cx, pl.cy, pl.cz, pl.x, pl.y, pl.z, dt, pl.check_air, bd);
			});
			if(v.ok){
				pl.cx = pl.x;
				pl.cy = pl.y;
				pl.cz = pl.z;
				pl.check_t = world.time;
				pl.check_air = v.air;
				pl.check_v = v.speed;
				pl.board_air = bd.on && v.air ? bd.air + 1 : 0;
				continue;
			}
			log_i(MODULE, "skeldat: %s pulled back from (%.1f, %.1f, %.1f) to "
					"(%.1f, %.1f, %.1f): %s%s", cs(pl.name), pl.x, pl.y, pl.z,
					pl.cx, pl.cy, pl.cz, v.why, bd.on ? " (on the board)" : "");
			// The client's board stops where it is put
			pl.check_v = 0;
			pl.board_air = 0;
			pl.x = pl.cx;
			pl.y = pl.cy;
			pl.z = pl.cz;
			const bool air = pl.check_air;
			send_position(peer, pl);
			pl.check_air = air;
		}
	}

	// Where the others are, to everyone: "name x y z yaw skeleton" a line,
	// skeleton 1 or 0
	void send_players()
	{
		for(auto &to : all){
			std::ostringstream os;
			for(auto &pair : all){
				const Player &o = pair.second;
				if(pair.first != to.first && o.placed && o.hp > 0)
					os<<o.name<<" "<<o.x<<" "<<o.y<<" "<<o.z<<" "<<o.yaw
							<<" "<<(o.skeleton ? 1 : 0)<<" "<<(o.board ? 1 : 0)
							<<" "<<(o.prone ? 1 : 0)<<"\n";
			}
			network::send(world.server, to.first, "skeldat:players", os.str());
		}
	}

	// Drowning: a breath a second with the head in water, then a hit
	// point; two breaths back a second out of it. And the hazards' harm
	// ([SKELDAT_MINING_HAZARDS], world.harm())
	void step_breath()
	{
		const uint32_t water = world.id_of("skeldat:water_source"),
				pocket = world.id_of("skeldat:pocket_water");
		for(auto &pair : all){
			Player &pl = pair.second;
			if(!pl.placed || pl.hp <= 0)
				continue;
			const int x = (int)std::floor(pl.x + 0.5f),
					hy = (int)std::floor(pl.y + 1.6f + 0.5f),
					z = (int)std::floor(pl.z + 0.5f);
			const uint32_t head = world.id_at(x, hy, z);
			const char *how = "";
			const int harm = world.harm(world.id_at(x,
					(int)std::floor(pl.y + 0.5f), z), head,
					world.param_at(x, hy, z), &how);
			if(harm > 0){
				hurt(pair.first, pl, harm, how, ss_(how) != "burns in lava");
				if(pl.hp <= 0)
					continue;
			}
			const bool under = head == water || head == pocket;
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

	ss_ name_of(size_t peer)
	{
		auto it = all.find(peer);
		return it != all.end() ? it->second.name : "client"+itos(peer);
	}
};
// vim: set noet ts=4 sw=4:
