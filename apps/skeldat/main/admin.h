// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT_MODULAR] **The world's admin**: the role (an admin, the
// picker), the pause ([SKELDAT_WORLD_ADMIN]) and the skip to sunrise or
// sunset ([SKELDAT_SKIP_TIME]), and the admin's menu with its audit log.
// The world's step and the bones' speed are AdminHost's, which the Module
// is.
// Included by main.cpp inside namespace skeldat, after players.h
#pragma once

// moderation::Host for the audit log alone (the admin's give and take): a
// subject is a player's name, and nothing is reported or decided here
struct AuditHost: public moderation::Host
{
	storage::Save *m_save = nullptr;
	storage::Save* save(){ return m_save; }
	ss_ name(){ return "skeldat"; }
	json::Value subject(const ss_ &id)
	{
		json::Value s = json::object();
		s.set("id", id);
		s.set("name", id);
		s.set("owner", id);
		s.set("players", 1);
		return s;
	}
	sv_<ss_> members(const json::Value &group){ return {}; }
	int severity(const ss_ &reason){ return 1; }
	json::Value thresholds(const json::Value &group){ return json::object(); }
	ss_ held(const json::Value &report){ return ""; }
	ss_ bucket(const json::Value &report){ return ""; }
	json::Value auto_act(const json::Value &group, const ss_ &id,
			const ss_ &want){ return json::Value(); }
	void uphold(moderation::Interface *m, const ss_ &by,
			const json::Value &group, const json::Value &q){}
	bool undo_auto(const ss_ &id, const json::Value &group){ return false; }
	void reverse(moderation::Interface *m, const ss_ &by,
			const json::Value &appeal, const ss_ &text){}
	void decided(const json::Value &report, bool upheld){}
	void event(const sv_<ss_> &to, const ss_ &by, const ss_ &text){}
	void notify(const json::Value &statement){}
};

struct AdminHost
{
	virtual void step_world(float dtime) = 0;
	virtual void set_speed(int s, const ss_ &by) = 0;
protected:
	~AdminHost() {}
};

struct Admin
{
	WorldView &world;
	AdminHost &host;
	// The Module's, the world's save while one is open
	storage::Save *&save;
	Players &players;
	BonesGrowth &growth;
	Terrain &terrain;
	AuditHost audit_host;
	// [SKELDAT_WORLD_ADMIN] The world paused, by whom, and whether by a
	// single player's open pause menu (auto); the peers whose refused
	// requests were logged this pause
	bool paused = false, pause_auto = false;
	ss_ paused_by;
	std::set<size_t> pause_refused;
	// [SKELDAT_SKIP_TIME] A skip to sunrise or sunset: the game seconds
	// left of it (0: none) and in all, the wall time it started, whom by,
	// the expansions before it, and the last progress sent
	double skip_left = 0, skip_total = 0;
	int64_t skip_us = 0, skip_sent_us = 0;
	ss_ skip_to, skip_by;
	size_t skip_expansions = 0;

	Admin(WorldView &world, AdminHost &host, storage::Save *&save,
			Players &players, BonesGrowth &growth, Terrain &terrain):
		world(world), host(host), save(save), players(players),
		growth(growth), terrain(terrain)
	{}

	bool picker(size_t peer)
	{
		bool ok = false;
		world_menu::access(world.server, [&](world_menu::Interface *i){
			ok = i->is_picker(peer);
		});
		return ok;
	}

	// A game request while paused: refused, logged once a peer a pause
	void refused_paused(const network::Packet &p)
	{
		if(pause_refused.insert(p.sender).second)
			log_i(MODULE, "skeldat: %s's %s refused: %s",
					cs(players.name_of(p.sender)), cs(p.name),
					paused ? "paused" : "skipping");
	}

	// "on" / "off" from the picker; "auto on" / "auto off" from a local
	// game's only client, its pause menu opened and closed
	void on_pause(size_t peer, const ss_ &how)
	{
		const bool is_auto = how.compare(0, 5, "auto ") == 0;
		const bool on = how == "on" || how == "auto on";
		if(is_auto){
			bool single = false;
			accounts::access(world.server, [&](accounts::Interface *i){
				single = i->is_local(peer);
			});
			network::access(world.server, [&](network::Interface *i){
				single = single && i->list_peers().size() == 1;
			});
			// A picker's own pause is not the menu's to end; a skip runs
			// with the menu open (its button is in it)
			if(!single || (paused && !pause_auto) || on == paused ||
					skip_left > 0)
				return;
		} else if(!picker(peer)){
			log_w(MODULE, "skeldat: %s's pause %s refused: not the picker",
					cs(players.name_of(peer)), cs(how));
			return;
		}
		// [SKELDAT_SKIP_TIME] A pause stops a skip first
		if(on && skip_left > 0)
			end_skip("stopped by the pause");
		set_paused(on, is_auto, players.name_of(peer));
	}

	// [SKELDAT_SKIP_TIME] "on": to the next sunset by day, sunrise by
	// night; "stop". The picker's, not after the end; a single player's
	// menu pause gives way to it.
	void on_skip(size_t peer, const ss_ &how)
	{
		if(!picker(peer)){
			log_w(MODULE, "skeldat: %s's skip refused: not the picker",
					cs(players.name_of(peer)));
			return;
		}
		if(how == "stop"){
			if(skip_left > 0)
				end_skip("stopped by "+players.name_of(peer));
			return;
		}
		if(how != "on" || growth.ended || skip_left > 0 || !world.ready ||
				(paused && !pause_auto)){
			log_w(MODULE, "skeldat: %s's skip refused: %s", cs(players.name_of(peer)),
					growth.ended ? "the world has ended" : skip_left > 0 ?
					"one runs" : "not now");
			return;
		}
		if(paused){
			paused = pause_auto = false;
			paused_by.clear();
		}
		// [SKELDAT_SKIP_DAWN] The night's skip ends at 05:00, an hour
		// before sunrise, as the sky brightens; the choice turns there
		// too, so a skip asked at 05:30 is to sunset
		const double DAWN = 0.25 - 1.0 / 24;
		const bool day = world.day >= DAWN && world.day < 0.75;
		const double target = day ? 0.75 : DAWN;
		// To sunset a hair past it, so the phase turns in the skip; to
		// dawn none, the sunrise's phase an hour of game time after it
		skip_left = skip_total = (std::fmod(target - world.day + 1.0, 1.0) +
				(day ? 1e-5 : 0.0)) * world.day_s;
		// "sunrise" stays the packet's word (send_paused())
		skip_to = day ? "sunset" : "sunrise";
		skip_by = players.name_of(peer);
		skip_us = skip_sent_us = interface::os::time_us();
		skip_expansions = growth.expansions;
		pause_refused.clear();
		const ss_ line = skip_by+" skips to "+(day ? "sunset" : "dawn (05:00)");
		log_i(MODULE, "skeldat: %s: %.1f s of game time, day %.4f", cs(line),
				skip_total, world.day);
		chat::access(world.server, [&](chat::Interface *c){ c->say(line); });
		for(auto &pair : players.all)
			send_paused(pair.first);
	}

	// Sub-steps of 0.1 s of game time, as many as fit in 35 ms of the
	// tick's wall time; the progress to the clients four times a second
	void step_skip()
	{
		const int64_t t0 = interface::os::time_us();
		while(skip_left > 0 && interface::os::time_us() - t0 < 35000){
			const float dt = (float)std::min(0.1, skip_left);
			host.step_world(dt);
			skip_left -= dt;
		}
		const int64_t now = interface::os::time_us();
		if(skip_left <= 0){
			end_skip("done");
		} else if(now - skip_sent_us >= 250000){
			skip_sent_us = now;
			for(auto &pair : players.all){
				send_paused(pair.first);
				players.send_time(pair.first);
			}
		}
	}

	void end_skip(const ss_ &how)
	{
		const double done = skip_total - std::max(0.0, skip_left);
		const double rate = growth.sections.size() / growth.section_period;
		log_i(MODULE, "skeldat: the skip to %s %s: %.1f s of game time in "
				"%.2f s, day %.4f, %zu expansions (%.1f due)", cs(skip_to),
				cs(how), done, (interface::os::time_us() - skip_us) / 1e6, world.day,
				growth.expansions - skip_expansions, done * rate);
		skip_left = 0;
		// The lag notice's minute starts again
		growth.keep_up_us = 0, growth.ticked_s = 0, growth.dropped_n = 0;
		for(auto &pair : players.all){
			send_paused(pair.first);
			players.send_time(pair.first);
		}
	}

	void set_paused(bool on, bool is_auto, const ss_ &by)
	{
		if(on == paused && is_auto == pause_auto)
			return;
		const bool chat_line = !(on ? is_auto : pause_auto);
		paused = on;
		pause_auto = on && is_auto;
		paused_by = on ? by : "";
		pause_refused.clear();
		// The lag notice's minute starts again
		growth.keep_up_us = 0, growth.ticked_s = 0, growth.dropped_n = 0;
		const ss_ line = by+(on ? " paused the world" : " resumed the world")+
				(is_auto ? " (the pause menu)" : "");
		log_i(MODULE, "skeldat: %s, day %.4f, world_t %.1f", cs(line), world.day,
				world.t);
		if(chat_line)
			chat::access(world.server, [&](chat::Interface *c){ c->say(line); });
		for(auto &pair : players.all)
			send_paused(pair.first);
	}

	// "" running, else "<name>" or "auto <name>"; skipping, "skip <percent>
	// <sunrise|sunset>"
	void send_paused(size_t peer)
	{
		if(skip_left > 0){
			network::send(world.server, peer, "skeldat:paused", "skip "+itos((int)(
					100 * (1 - skip_left / skip_total)))+" "+skip_to);
			return;
		}
		network::send(world.server, peer, "skeldat:paused", !paused ? "" :
				(pause_auto ? "auto " : "")+paused_by);
	}

	// Paused, said; a second player ends a single player's pause
	void joined(size_t peer, Player &pl)
	{
		if(pause_auto && players.all.size() > 1)
			set_paused(false, true, pl.name);
		send_paused(peer);
	}

	bool skipping(){ return skip_left > 0; }

	// The admin's menu ([SKELDAT] decision 4): a player's inventory viewed,
	// an item given to it or taken from it, each in moderation's audit log
	// of the world's save. "skeldat:admin" both ways, a command a line:
	//   players                    -> players\n<name> a line
	//   view <name>                -> inv <name>\nmain=<list_text's>
	//                                 invulnerable=0|1 (a line)
	//   give <name> <item> <count> -> the view again
	//   take <name> <slot>         -> the view again
	//   invulnerable <name> on|off -> the view again
	//   audit                      -> audit\n<ts by action whom text> a line
	//   start_items                -> start_items\n<item count> a line
	//   set_start_items [<item count>]... -> the same, "start_items refused
	//                                 <name>" for an unknown item
	// simplified: the players on the server now, not the save's others
	void on_admin(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		auto me = players.all.find(peer);
		if(me == players.all.end() || !save || !is_admin(peer))
			return;
		std::istringstream is(packet.data);
		ss_ cmd, name;
		is>>cmd>>name;
		if(cmd == "speed"){
			host.set_speed(atoi(name.c_str()), me->second.name);
			cmd = "players";
		}
		if(cmd == "players"){
			ss_ out = "players "+itos(growth.speed)+"\n";
			for(auto &pair : players.all)
				out += pair.second.name+"\n";
			network::send(world.server, peer, "skeldat:admin", out);
			return;
		}
		if(cmd == "map"){
			network::send(world.server, peer, "skeldat:admin", "map\n"+terrain.write_map());
			return;
		}
		if(cmd == "audit"){
			std::ostringstream os;
			os<<"audit\n";
			moderation::access(world.server, [&](moderation::Interface *m){
				audit_host.m_save = save;
				const json::Value l = m->audit_log(&audit_host);
				for(unsigned i = 0; i < l.size() && i < 50; i++){
					const json::Value &a = l.at(i);
					os<<json::jstr(a, "by")<<" "<<json::jstr(a, "action")<<" "
							<<json::jstr(a, "listing")<<": "
							<<json::jstr(a, "text")<<"\n";
				}
			});
			network::send(world.server, peer, "skeldat:admin", os.str());
			return;
		}
		// [SKELDAT_START_ITEMS] The new players' items: "start_items" ->
		// "start_items [refused <name>]\n<item> <count> a line"; "set_start_items
		// [<item> <count>]..." sets them (none: nothing given), each name a
		// known item and its count up to a stack, else the whole refused
		if(cmd == "start_items" || cmd == "set_start_items"){
			ss_ refused;
			if(cmd == "set_start_items"){
				std::istringstream in(packet.data);
				in>>cmd;
				ss_ item, list;
				int count = 0;
				while(in>>item){
					if(!(in>>count) || !world.game.item(item)){
						refused = item;
						break;
					}
					count = std::max(1, std::min(count,
							world.game.stack_max(item)));
					list += (list.empty() ? "" : " ")+item+" "+itos(count);
				}
				if(refused.empty()){
					save->store("skeldat")->set("start_items", list);
					audit(me->second.name, "new players", "set", "start items: "+
							(list.empty() ? ss_("nothing") : list));
				} else {
					log_i(MODULE, "skeldat: %s's start items refused: no item %s",
							cs(me->second.name), cs(refused));
				}
			}
			ss_ out = "start_items"+(refused.empty() ? ss_() :
					" refused "+refused)+"\n";
			for(const Stack &st : players.start_items())
				out += st.name+" "+itos(st.count)+"\n";
			network::send(world.server, peer, "skeldat:admin", out);
			return;
		}
		size_t to = 0;
		Player *pl = nullptr;
		for(auto &pair : players.all){
			if(pair.second.name == name){
				to = pair.first;
				pl = &pair.second;
			}
		}
		if(!pl)
			return;
		const ss_ by = me->second.name;
		if(cmd == "give"){
			ss_ item;
			int count = 0;
			const skeldat::ItemDef *d = nullptr;
			if(!(is>>item>>count) || !(d = world.game.item(item)))
				return;
			count = std::max(1, std::min(count,
					world.game.stack_max(item)));
			const Stack left = world.game.add(pl->main, Stack(item, count));
			const int given = count - left.count;
			if(given > 0)
				audit(by, name, "give", itos(given)+" "+item);
		} else if(cmd == "take"){
			int slot = -1;
			if(!(is>>slot) || slot < 0 || slot >= (int)pl->main.size() ||
					pl->main[slot].empty())
				return;
			const ss_ what = pl->main[slot].str();
			pl->main[slot] = Stack();
			audit(by, name, "take", what);
		} else if(cmd == "invulnerable"){
			ss_ v;
			is>>v;
			if(v != "on" && v != "off")
				return;
			pl->invulnerable = v == "on";
			audit(by, name, "set", "invulnerable "+v);
		} else if(cmd != "view"){
			return;
		}
		if(cmd != "view")
			players.send_inventory(to, *pl);
		network::send(world.server, peer, "skeldat:admin", "inv "+name+"\n"+
				players.list_text("main", pl->main)+"invulnerable="+
				(pl->invulnerable ? "1" : "0"));
	}

	void audit(const ss_ &by, const ss_ &whom, const ss_ &action,
			const ss_ &text)
	{
		moderation::access(world.server, [&](moderation::Interface *m){
			audit_host.m_save = save;
			m->audit(&audit_host, by, whom, action, "admin", text, false, false);
		});
		log_i(MODULE, "skeldat: %s %ss %s: %s", cs(by), cs(action), cs(whom),
				cs(text));
	}

	bool is_admin(size_t peer)
	{
		bool admin = false;
		accounts::access(world.server, [&](accounts::Interface *i){
			admin = i->is_local(peer) ||
					i->level(i->name_of(peer)) >= accounts::LV_ADMIN;
		});
		return admin;
	}

	// accounts' admin, or the launcher's own client (its owner token): fly,
	// fast and noclip on the client, no movement check here. Sent as it
	// changes, and always when `tell`.
	void update_role(size_t peer, Player &pl, bool tell)
	{
		const bool admin = is_admin(peer);
		if(admin == pl.admin && !tell)
			return;
		pl.admin = admin;
		// [SKELDAT_WORLD_ADMIN] And world_menu's picker
		network::send(world.server, peer, "skeldat:role", ss_(admin ? "admin" : "")+
				(picker(peer) ? " picker" : ""));
		log_i(MODULE, "skeldat: %s is %s", cs(pl.name),
				admin ? "an admin" : "a player");
	}
};
// vim: set noet ts=4 sw=4:
