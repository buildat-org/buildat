// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [HC_SCORES] The high scores, Module's, included by main.cpp inside the
// Module struct: the ranking's sets (a key's part up to its payload, every
// key version) for the pause menu's High scores page (hillclimb:scores),
// and the times under the keys with a seed read into the seedless ones.

	// A key's parts: its set (up to and with "payload<n>/"), its version,
	// its numbers by name ("steep" 27, "seed" 5, ...) and the numbers after
	// the set (the time's, and a circuit's laps before them)
	struct KeyParts
	{
		ss_ set, version;
		bool circuit = false;
		std::map<ss_, int> p;
		sv_<long long> rest;
	};
	static bool key_parts(const ss_ &key, KeyParts &out)
	{
		std::istringstream is(key);
		ss_ part;
		bool past = false;
		while(std::getline(is, part, '/')){
			if(past){
				out.rest.push_back(atoll(part.c_str()));
				continue;
			}
			out.set += part + "/";
			if(out.version.empty()){
				out.version = part;
				continue;
			}
			out.circuit = out.circuit || part == "circuit";
			size_t d = part.find_first_of("0123456789");
			if(d != ss_::npos && d > 0)
				out.p[part.substr(0, d)] = atoi(part.c_str() + d);
			past = part.compare(0, 7, "payload") == 0;
		}
		return past && !out.rest.empty();
	}
	// A set in words, ASCII as the HUD's font is
	static ss_ set_name(const KeyParts &k)
	{
		auto at = [&](const char *n){
			auto it = k.p.find(n);
			return it == k.p.end() ? 0 : it->second;
		};
		char buf[256];
		const int payload = at("payload");
		const ss_ load = payload ? itos(payload)+" kg aboard" : "no payload";
		if(k.circuit)
			snprintf(buf, sizeof buf, "Circuit, %d degrees +-%d, %d m, %d m wide, "
					"%d m lanes, %d%% switchbacks, %d min rounds, %s", at("steep"),
					at("var"), at("length"), at("width"), at("lane"), at("switch"),
					at("round") / 60, cs(load));
		else
			snprintf(buf, sizeof buf, "%d degrees +-%d, %d m, %s", at("steep"),
					at("var"), at("length"), cs(load));
		// [HC_SOFT_GROUND] The knobs off the old firm soil, which the key holds
		ss_ name = buf;
		for(int i = 0; i < N_KNOBS; i++){
			auto it = k.p.find(KNOBS[i].name);
			if(it == k.p.end())
				continue;
			static const char *f[N_KNOBS] = {", sand %d kPa", ", dig %d",
					", power %d%%", ", grip %.2f", ", stones %d%%"};
			char t[32];
			if(i == 3)
				snprintf(t, sizeof t, f[i], it->second / 100.0);
			else
				snprintf(t, sizeof t, f[i], it->second);
			name += t;
		}
		// An older version's: its seed, which its key held
		if(k.version != SCORES_VERSION)
			return k.version+", seed "+itos(at("seed"))+": "+name;
		return name;
	}
	// An entry: "name\tdate\tfinished\tunfinished[\tseed]"
	static json::Value entry_of(const KeyParts &k, const ss_ &value)
	{
		std::istringstream is(value);
		ss_ name, date;
		std::getline(is, name, '\t');
		std::getline(is, date, '\t');
		int fin = 0, unfin = 0, seed = -1;
		is >> fin >> unfin >> seed;
		auto it = k.p.find("seed");
		if(seed < 0 && it != k.p.end())
			seed = it->second;
		json::Value e = json::object();
		e.set("name", name.empty() ? ss_("?") : name);
		e.set("date", date.empty() ? ss_("-") : date);
		e.set("fin", fin);
		e.set("unfin", unfin);
		e.set("seed", seed);
		const bool laps = k.circuit && k.rest.size() >= 3;
		e.set("laps", laps ? (int)(999999 - k.rest[0]) : -1);
		e.set("t", (double)k.rest[laps ? 1 : 0] / 1000);
		return e;
	}

	// hillclimb:scores: "sets", every set with times, the current one first,
	// then this version's (circuits by laps, then the climbs by time), then
	// the older; "set <key>", a set's entries, all of them (at most 1000),
	// and its parameters
	json::Value scores_answer(const ss_ &ask)
	{
		// Always an answer the page can show: no save or no such set, the
		// sets (none)
		json::Value out = json::object();
		storage::Store *st = m_save ? m_save->store("times") : nullptr;
		if(!st){
			out.set("sets", json::array());
			return out;
		}
		const ss_ current = ranking_prefix();
		if(ask.compare(0, 4, "set ") == 0){
			const ss_ want = ask.substr(4);
			json::Value list = json::array();
			KeyParts first;
			for(const ss_ &key : st->list(want)){
				KeyParts k;
				if(!key_parts(key, k) || k.set != want || list.size() >= 1000)
					continue;
				ss_ v;
				st->get(key, v);
				list.append(entry_of(k, v));
				first = k;
			}
			if(list.size() == 0)
				return scores_answer("sets");
			json::Value set = json::object();
			set.set("key", want);
			set.set("name", set_name(first));
			set.set("current", want == current);
			// Its parameters, for "Drive this hill" on this version's
			set.set("drivable", first.version == SCORES_VERSION);
			set.set("circuit", first.circuit);
			for(const auto &p : first.p)
				set.set(p.first.c_str(), p.second);
			set.set("entries", list);
			out.set("set", set);
			return out;
		}
		// The keys come in order: a set's best is its first
		struct Set { KeyParts k; json::Value best; int n = 0; };
		std::map<ss_, Set> sets;
		for(const ss_ &key : st->list("")){
			KeyParts k;
			if(!key_parts(key, k))
				continue;
			Set &s = sets[k.set];
			if(s.n++ == 0){
				ss_ v;
				st->get(key, v);
				s.k = k;
				s.best = entry_of(k, v);
			}
		}
		sv_<std::pair<std::tuple<int, int, double>, json::Value>> rows;
		for(auto &kv : sets){
			const Set &s = kv.second;
			const KeyParts &k = s.k;
			const bool now = k.version == SCORES_VERSION;
			json::Value v = json::object();
			v.set("key", kv.first);
			v.set("name", set_name(k));
			v.set("count", s.n);
			v.set("best", s.best);
			v.set("current", kv.first == current);
			v.set("drivable", now);
			for(const auto &p : k.p)
				v.set(p.first.c_str(), p.second);
			v.set("circuit", k.circuit);
			const int laps = (int)json::jint(s.best, "laps", -1);
			const double t = s.best.get("t").as_number();
			// Sorted: the current, this version's circuits by laps, its climbs,
			// the older versions'
			const int group = kv.first == current ? 0 : !now ? 3 : k.circuit ? 1 : 2;
			rows.push_back({std::make_tuple(group, -laps, t), v});
		}
		std::stable_sort(rows.begin(), rows.end(), [](
				const std::pair<std::tuple<int, int, double>, json::Value> &a,
				const std::pair<std::tuple<int, int, double>, json::Value> &b){
			return a.first < b.first; });
		json::Value list = json::array();
		for(const auto &r : rows)
			list.append(r.second);
		out.set("sets", list);
		return out;
	}
	void on_scores(const network::Packet &packet)
	{
		if(packet.data.size() > 300)
			return;
		network::send(m_server, packet.sender, "hillclimb:scores",
				scores_answer(packet.data).stringify());
	}

	// The times under the keys with a seed (v4: no variance; v5) copied
	// once under the seedless key of their parameters, the seed into the
	// entry; the old keys left as they are
	void read_old_scores()
	{
		storage::Store *settings = m_save ? m_save->store("settings") : nullptr;
		ss_ done;
		if(!settings || settings->get("scores_"+ss_(SCORES_VERSION), done))
			return;
		storage::Store *st = m_save->store("times");
		int copied = 0;
		for(const ss_ &old : {ss_("v4/"), ss_("v5/seed")}){
			for(const ss_ &key : st->list(old)){
				KeyParts k;
				if(!key_parts(key, k) || k.circuit || k.rest.size() != 2 ||
						!k.p.count("seed"))
					continue;
				char nk[192];
				snprintf(nk, sizeof nk, "%s/straight/steep%d/var%d/length%d/sand/"
						"payload%d/%09lld/%lld", SCORES_VERSION, k.p["steep"],
						k.p.count("var") ? k.p["var"] : 0, k.p["length"],
						k.p["payload"], k.rest[0], k.rest[1]);
				ss_ v, there;
				if(st->get(nk, there) || !st->get(key, v))
					continue;
				st->set(nk, v+"\t"+itos(k.p["seed"]));
				copied++;
			}
		}
		settings->set("scores_"+ss_(SCORES_VERSION), itos(copied));
		log_i(MODULE, "hillclimb: %d times with a seed read into %s's sets",
				copied, SCORES_VERSION);
	}
// vim: set noet ts=4 sw=4:
