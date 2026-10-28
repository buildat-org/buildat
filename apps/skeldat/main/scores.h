// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT_MODULAR] **The high scores** ([SKELDAT_HIGH_SCORES]), outside
// the worlds: the save "_skeldat", store "scores", a key a parameter set;
// an ended world's score recorded, the sets and the presets sent.
// Included by main.cpp inside namespace skeldat, after bones_growth.h
#pragma once

// [SKELDAT_MORE_FUN] The rules' version a score was made under: a set
// of another (before bones::PACE, none) is not listed, its days not
// comparable
static const int SCORE_RULES = 2;

struct Scores
{
	WorldView &world;
	BonesGrowth &growth;
	// The Module's: the world's save and its skeldat store while open,
	// its name, and each player's seconds in it
	storage::Save *&save;
	storage::Store *&store;
	const ss_ &world_name;
	std::map<ss_, double> &played;
	// The save "_skeldat", opened at the first need
	storage::Save *db = nullptr;
	// The ended world's set's best days and this score's place in it
	double end_best = 0;
	int end_place = 0;

	Scores(WorldView &world, BonesGrowth &growth, storage::Save *&save,
			storage::Store *&store, const ss_ &world_name,
			std::map<ss_, double> &played):
		world(world), growth(growth), save(save), store(store),
		world_name(world_name), played(played)
	{}

	storage::Store* scores()
	{
		return db_store("scores");
	}
	// A store of the save "_skeldat": "scores", or "server"'s running
	// world ([SKELDAT_RESUME_WORLD])
	storage::Store* db_store(const char *name)
	{
		if(!db){
			storage::access(world.server, [&](storage::Interface *i){
				db = i->open("_skeldat");
				if(!db)
					db = i->create("_skeldat");
			});
		}
		return db ? db->store(name) : nullptr;
	}

	// A set's JSON: {name, seed, size, speed, scores: [{days, date, world,
	// players: [[name, seconds]]}]}, best first
	json::Value read_set(storage::Store *st, const ss_ &key)
	{
		ss_ v;
		if(st && st->get(key, v)){
			const json::Value j = json::load_string(v.c_str());
			if(j.is_object())
				return j;
		}
		return json::object();
	}

	// Who played this world: the most time first, ten, and after them each
	// one in for more than half the world's time
	sv_<std::pair<ss_, double>> players_kept()
	{
		sv_<std::pair<ss_, double>> all(played.begin(), played.end());
		std::sort(all.begin(), all.end(), [](const std::pair<ss_, double> &a,
				const std::pair<ss_, double> &b){ return a.second > b.second; });
		sv_<std::pair<ss_, double>> kept;
		for(size_t i = 0; i < all.size(); i++)
			if(i < 10 || all[i].second > world.t / 2)
				kept.push_back(all[i]);
		return kept;
	}

	// The end's score into its set (seed, size, the lowest speed), the set
	// named after the last world not "_rerun" to end with it; the world's
	// own Players field; the presets again
	void record_score()
	{
		const sv_<std::pair<ss_, double>> kept = players_kept();
		std::ostringstream names;
		json::Value players = json::array();
		for(size_t i = 0; i < kept.size(); i++){
			char h[32];
			snprintf(h, sizeof h, "%.1f h", kept[i].second / 3600);
			names<<(i ? ", " : "")<<kept[i].first<<" "<<h;
			json::Value p = json::array();
			p.append(json::Value(kept[i].first));
			p.append(json::Value(kept[i].second));
			players.append(p);
		}
		save->store("world_menu")->set("players", names.str());
		storage::Store *st = scores();
		if(!st)
			return;
		ss_ seed = "0";
		store->get("seed", seed);
		const int size = world.half * 2 * skeldat::bones::SECTION;
		// [SKELDAT_OWN_MAPGEN] The form in the key; a valleys world's keyed
		// as before
		ss_ form = "legacy_valleys";
		store->get("terrain", form);
		const ss_ key = "set/"+seed+"/"+itos(size)+"/"+itos(growth.speed_low)+
				(form == "legacy_valleys" ? ss_() : "/"+form)+
				"/rules"+itos(SCORE_RULES);
		json::Value set = read_set(st, key);
		set.set("seed", json::Value(seed));
		set.set("terrain", json::Value(form));
		set.set("size", json::Value((int64_t)size));
		set.set("speed", json::Value((int64_t)growth.speed_low));
		set.set("rules", json::Value((int64_t)SCORE_RULES));
		const ss_ rerun = "_rerun";
		const bool is_rerun = world_name.size() > rerun.size() &&
				world_name.compare(world_name.size() - rerun.size(),
				rerun.size(), rerun) == 0;
		if(!is_rerun)
			set.set("name", json::Value(world_name));
		else if(json::jstr(set, "name").empty())
			set.set("name", json::Value(world_name.substr(0,
					world_name.size() - rerun.size())));
		char date[16];
		const time_t now = time(nullptr);
		strftime(date, sizeof date, "%Y-%m-%d", localtime(&now));
		json::Value score = json::object();
		score.set("days", json::Value(growth.end_days));
		score.set("date", json::Value(ss_(date)));
		score.set("world", json::Value(world_name));
		score.set("players", players);
		// Best first: in before the first with fewer days
		const json::Value &old = set.get("scores");
		json::Value list = json::array();
		end_place = 0;
		for(unsigned i = 0; old.is_array() && i < old.size(); i++){
			if(!end_place && old.at(i).get("days").as_number() < growth.end_days){
				list.append(score);
				end_place = list.size();
			}
			list.append(old.at(i));
		}
		if(!end_place){
			list.append(score);
			end_place = list.size();
		}
		set.set("scores", list);
		end_best = list.at(0u).get("days").as_number();
		st->set(key, set.stringify());
		store->set("ended_rank", dtos(end_best)+" "+itos(end_place));
		log_i(MODULE, "skeldat: the score %.1f days is %d. of %u in %s "
				"(\"%s\"), best %.1f; players: %s", growth.end_days, end_place,
				list.size(), cs(key), cs(json::jstr(set, "name")), end_best,
				cs(names.str()));
		send_presets();
	}

	// The sets, best first: [{key, name, seed, size, speed, best}]
	json::Value list_sets()
	{
		json::Value out = json::array();
		storage::Store *st = scores();
		if(!st)
			return out;
		sv_<std::pair<double, json::Value>> sets;
		for(const ss_ &key : st->list("set/")){
			const json::Value set = read_set(st, key);
			const json::Value &sc = set.get("scores");
			if(!sc.is_array() || sc.size() == 0 ||
					json::jint(set, "rules") != SCORE_RULES)
				continue;
			json::Value v = json::object();
			v.set("key", json::Value(key));
			v.set("name", json::Value(json::jstr(set, "name")));
			v.set("seed", json::Value(json::jstr(set, "seed")));
			v.set("size", json::Value(json::jint(set, "size")));
			v.set("speed", json::Value(json::jint(set, "speed")));
			// A set from before the forms: Luanti's valleys made it
			const ss_ terrain = json::jstr(set, "terrain");
			v.set("terrain", json::Value(terrain.empty() ? ss_("legacy_valleys") :
					terrain));
			const double best = sc.at(0u).get("days").as_number();
			v.set("best", json::Value(best));
			sets.push_back({best, v});
		}
		std::stable_sort(sets.begin(), sets.end(), [](
				const std::pair<double, json::Value> &a,
				const std::pair<double, json::Value> &b){
			return a.first > b.first; });
		for(const auto &p : sets)
			out.append(p.second);
		return out;
	}

	// The world menu's "From the high scores": each set's parameters
	void send_presets()
	{
		const json::Value sets = list_sets();
		std::vector<world_menu::Preset> presets;
		for(unsigned i = 0; i < sets.size() && i < 20; i++){
			const json::Value &v = sets.at(i);
			char label[200];
			snprintf(label, sizeof label, "%s: %d, %dx, %s, seed %s, best %.1f days",
					cs(json::jstr(v, "name")), (int)json::jint(v, "size"),
					(int)json::jint(v, "speed"), cs(json::jstr(v, "terrain")),
					cs(json::jstr(v, "seed")), v.get("best").as_number());
			world_menu::Preset p;
			p.label = label;
			p.options["seed"] = json::jstr(v, "seed");
			p.options["size"] = itos(json::jint(v, "size"));
			p.options["speed"] = itos(json::jint(v, "speed"));
			// A valleys set's world is made on rivers now
			if(mapgen::form_of(json::jstr(v, "terrain")) >= 0)
				p.options["terrain"] = json::jstr(v, "terrain");
			presets.push_back(p);
		}
		world_menu::access(world.server, [&](world_menu::Interface *i){
			i->set_presets(presets);
		});
	}

	// skeldat:scores: "list", the sets; "set <key>", one set's best ten
	void send_scores(size_t peer, const ss_ &ask)
	{
		json::Value out = json::object();
		if(ask.compare(0, 4, "set ") == 0){
			const ss_ key = ask.substr(4);
			json::Value set = read_set(scores(), key);
			const json::Value &sc = set.get("scores");
			json::Value best = json::array();
			for(unsigned i = 0; sc.is_array() && i < sc.size() && i < 10; i++)
				best.append(sc.at(i));
			set.set("scores", best);
			set.set("key", json::Value(key));
			out.set("set", set);
		} else {
			out.set("sets", list_sets());
		}
		network::send(world.server, peer, "skeldat:scores", out.stringify());
	}
};
// vim: set noet ts=4 sw=4:
