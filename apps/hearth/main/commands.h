// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// Hearth's commands, Module::handle(), included by main.cpp inside the
// Module struct ([FILE_SPLITS_1019]: moved out as it was).

	json::Value handle(const ss_ &name, int lv, const ss_ &cmd,
			const json::Value &q, network::PeerId peer)
	{
		// What was the admin's is a moderator's ([TRUST_LADDER]), but what
		// is server-wide
		const bool mod = lv >= LV_MODERATOR, admin = lv >= LV_ADMIN;
		if(cmd == "me"){
			json::Value v = json::object();
			v.set("account", name);
			v.set("admin", admin);
			v.set("moderator", mod);
			v.set("helper", lv >= LV_HELPER);
			v.set("unseen", unseen(name));
			// The client's clock for "3 h ago" ([HEARTH_UI])
			v.set("now", now_s());
			Q mb(m_db, "INSERT OR IGNORE INTO members(account, first_seen) "
					"VALUES(?, ?)");
			mb.b(name).b(now_s()).step();
			v.set("level", (int64_t)lv);
			if(lv >= LV_HELPER){
				Q o(m_db, "SELECT count(*) FROM reports WHERE state = 'open'");
				o.step();
				v.set("open_reports", o.i(0));
			}
			return v;
		}
		// "topics" is the sidebar, which a client redraws with a thread
		// open; the client drops an "hr:new" for a thread it has left
		if(cmd != "thread" && cmd != "reply" && cmd != "edit" &&
				cmd != "answered" && cmd != "follow" && cmd != "topics")
			m_viewing.erase(peer);
		if(cmd == "topics"){
			json::Value v = json::object();
			v.set("topics", topics(name));
			json::Value latest = latest_threads(20);
			mark_unread(latest, name);
			v.set("latest", latest);
			// [HEARTH_NEW_MARKS] "Waiting for you": the unread threads of
			// every topic, the followed first
			// simplified: 50; the client shows five and the rest on "more"
			json::Value waiting = json::array();
			Q w(m_db, "SELECT " THREAD_COLUMNS ", EXISTS(SELECT 1 FROM "
					"follows WHERE account = ?1 AND thread = threads.id) f "
					"FROM threads WHERE hidden = 0 AND " UNREAD("threads")
					" ORDER BY f DESC, last DESC LIMIT 50");
			w.b(name).b(since(name));
			while(w.step()){
				json::Value t = thread_row(w);
				t.set("unread", true);
				t.set("followed", w.i(14) != 0);
				waiting.append(t);
			}
			v.set("waiting", waiting);
			return v;
		}
		// [HEARTH_NEW_MARKS] "Mark all read": a topic and its subtopics, or
		// with no topic everything
		if(cmd == "mark_read"){
			const int64_t topic_id = jint(q, "topic");
			if(topic_id == 0){
				Q u(m_db, "UPDATE members SET since = ? WHERE account = ?");
				u.b(now_s()).b(name).step();
			} else {
				Q u(m_db, "INSERT OR REPLACE INTO topic_reads(account, topic, "
						"time) SELECT ?, id, ? FROM topics WHERE id = ?3 OR "
						"parent = ?3");
				u.b(name).b(now_s()).b(topic_id).step();
			}
			return json::Value(true);
		}
		if(cmd == "topic"){
			json::Value t = topic(jint(q, "topic"));
			if(!t.is_object())
				throw Exception("no such topic");
			json::Value list = threads(jint(q, "topic"));
			mark_unread(list, name);
			t.set("threads", list);
			return t;
		}
		// [HEARTH_OPEN_HERE] A message's thread, as its /m/ page finds it
		if(cmd == "message"){
			Q m(m_db, "SELECT m.thread FROM messages m JOIN threads t ON "
					"t.id = m.thread WHERE m.id = ? AND (t.hidden = 0 OR ? OR "
					"t.author = ?)");
			m.b(jint(q, "message")).b((int64_t)mod).b(name);
			if(!m.step())
				throw Exception("no such message");
			return json::Value(m.i(0));
		}
		if(cmd == "thread"){
			json::Value t = thread(jint(q, "thread"), jint(q, "after"), name,
					mod);
			if(!t.is_object())
				throw Exception("no such thread");
			// Hidden: as its page shows it, the first message without its
			// title, but to a moderator and whoever started it
			if(t.get("hidden").is_true() && !mod && jstr(t, "author") != name){
				t.set("title", "A hidden thread");
				json::Value first = json::array();
				if(jint(q, "after") == 0 && t.get("list").size() > 0)
					first.append(t.get("list").at(0));
				t.set("list", first);
				t.set("more", false);
			}
			// [HEARTH_TRACKER]: a problem or a patch in a tracker topic
			t.set("ticket", (jstr(t, "kind") == "problem" || jstr(t, "kind") ==
					"patch") && topic(jint(t, "topic")).get("tracker").is_true());
			m_viewing[peer] = jint(q, "thread");
			Q rd(m_db, "INSERT OR IGNORE INTO reads(account, thread) "
					"VALUES(?, ?)");
			rd.b(name).b(jint(q, "thread")).step();
			Q ad(m_db, "INSERT OR IGNORE INTO active_days(account, day) "
					"VALUES(?, ?)");
			ad.b(name).b(now_s() / 86400).step();
			// [HEARTH_UI]: the last read before this part ("read", where
			// the client draws "new since"), then this part's last
			Q rl(m_db, "SELECT last FROM reads WHERE account = ? AND thread = ?");
			rl.b(name).b(jint(q, "thread")).step();
			t.set("read", rl.i(0));
			const json::Value &part = t.get("list");
			if(part.size() > 0){
				Q ru(m_db, "UPDATE reads SET last = max(last, ?) WHERE "
						"account = ? AND thread = ?");
				ru.b(jint(part.at(part.size() - 1), "id")).b(name)
						.b(jint(q, "thread")).step();
			}
			Q f(m_db, "SELECT 1 FROM follows WHERE account = ? AND thread = ?");
			f.b(name).b(jint(q, "thread"));
			t.set("following", f.step());
			return t;
		}
		// A package's place ([PACKAGE_SUBJECT]): the threads about it, as
		// "author/name key" names it
		// simplified: 200, the latest; paging when a package has more
		if(cmd == "subject"){
			const ss_ subject = jstr(q, "subject");
			need(text_ok(subject, 400, false, "the subject"));
			json::Value list = json::array();
			// A package's name alone ([HEARTH_OPEN_HERE]): every key's, as
			// its /p/ page lists them
			const bool pkg = is_package(subject);
			Q t(m_db, "SELECT " THREAD_COLUMNS " FROM threads WHERE "
					"(subject = ? OR (? AND substr(subject, 1, ?) = ?)) AND "
					"hidden = 0 ORDER BY last DESC LIMIT 200");
			t.b(subject).b((int64_t)pkg).b((int64_t)subject.size() + 1).
					b(subject+" ");
			while(t.step())
				list.append(thread_row(t));
			return list;
		}
		// [HEARTH_UI] **An account's page**: its level, its last messages
		// that stand (the HTML face's /u/), and to its owner what its
		// level is reached by
		if(cmd == "account"){
			const ss_ who = jstr(q, "name");
			need(text_ok(who, NAME_MAX, false, "the name"));
			json::Value v = json::object();
			v.set("name", who);
			const int who_lv = level(who);
			v.set("level", (int64_t)who_lv);
			if(who == name)
				v.set("trust", trust(who));
			// [TRUST_LADDER] To a helper and up: who trusted it, and the
			// accounts a helper trusted
			if(lv >= LV_HELPER){
				for(const char *k : {"approved_by", "approved"}){
					json::Value l = json::array();
					Q a(m_db, k[8] == '_' ? "SELECT by, time FROM approvals "
							"WHERE account = ? ORDER BY time DESC LIMIT 10" :
							"SELECT account, time FROM approvals WHERE by = ? "
							"ORDER BY time DESC LIMIT 200");
					a.b(who);
					while(a.step()){
						json::Value r = json::object();
						r.set("name", a.s(0));
						r.set("time", a.i(1));
						l.append(r);
					}
					v.set(k, l);
				}
			}
			json::Value list = json::array();
			Q m(m_db, "SELECT m.id, m.thread, t.title, m.created, "
					"substr(m.body, 1, 200) FROM messages m "
					"JOIN threads t ON t.id = m.thread WHERE m.author = ? "
					"AND m.hidden = 0 AND t.hidden = 0 "
					"ORDER BY m.id DESC LIMIT 50");
			m.b(who);
			while(m.step()){
				json::Value r = json::object();
				r.set("message", m.i(0));
				r.set("thread", m.i(1));
				r.set("title", m.s(2));
				r.set("created", m.i(3));
				r.set("body", m.s(4));
				list.append(r);
			}
			v.set("messages", list);
			return v;
		}
		// [HEARTH_UI] The threads followed, the unread first
		if(cmd == "following"){
			json::Value list = json::array();
			Q t(m_db, "SELECT " THREAD_COLUMNS " FROM threads WHERE id IN "
					"(SELECT thread FROM follows WHERE account = ?) AND "
					"(hidden = 0 OR author = ?) ORDER BY last DESC LIMIT 200");
			t.b(name).b(name);
			while(t.step())
				list.append(thread_row(t));
			mark_unread(list, name);
			json::Value out = json::array();
			for(int pass = 0; pass < 2; pass++)
				for(unsigned i = 0; i < list.size(); i++)
					if(list.at(i).get("unread").is_true() == (pass == 0))
						out.append(list.at(i));
			return out;
		}
		// The packages this Hearth has threads about, to link a thread to
		if(cmd == "subjects"){
			json::Value list = json::array();
			Q t(m_db, "SELECT DISTINCT subject FROM threads WHERE "
					"kind = 'release' ORDER BY subject LIMIT 200");
			while(t.step())
				list.append(t.s(0));
			return list;
		}
		// A thread started elsewhere, linked to a package afterwards by its
		// poster or a moderator; only to a package already known here, so a
		// link names a real release's key
		if(cmd == "link"){
			const int64_t thread_id = jint(q, "thread");
			const ss_ subject = jstr(q, "subject");
			Q t(m_db, "SELECT author, subject FROM threads WHERE id = ?");
			t.b(thread_id);
			if(!t.step())
				throw Exception("no such thread");
			if(t.s(0) != name && !mod)
				throw Exception("only whoever started the thread links it");
			if(!t.s(1).empty() && !mod)
				throw Exception("the thread is about a package already");
			Q k(m_db, "SELECT 1 FROM threads WHERE kind = 'release' AND "
					"subject = ?");
			k.b(subject);
			if(!k.step())
				throw Exception("no release here is that package");
			Q u(m_db, "UPDATE threads SET subject = ? WHERE id = ?");
			u.b(subject).b(thread_id).step();
			return json::Value(true);
		}
		// The markup's preview: what the HTML face makes of a message
		if(cmd == "preview"){
			const ss_ body = jstr(q, "body");
			need(text_ok(body, BODY_MAX, true, "the message"));
			return json::Value(interface::markup::to_html(body));
		}
		if(cmd == "search"){
			const ss_ text = jstr(q, "q");
			need(text_ok(text, 200, false, "the search"));
			if(!allowed("@"+name, SEARCHES_A_MINUTE))
				throw Exception("too many searches; try again in a minute");
			// Each result's thread's "unread" ([HEARTH_NEW_MARKS])
			json::Value list = search(text), ths = json::array();
			for(unsigned i = 0; i < list.size(); i++){
				json::Value t = json::object();
				t.set("id", jint(list.at(i), "thread"));
				ths.append(t);
			}
			mark_unread(ths, name);
			for(unsigned i = 0; i < list.size(); i++){
				json::Value r = list.at(i);
				r.set("unread", ths.at(i).get("unread"));
				list.set_at(i, r);
			}
			return list;
		}
		if(cmd == "new_topic"){
			// The tree changes rarely, by a trusted hand: a moderator's
			if(!mod)
				throw Exception("only a "+level_name(LV_MODERATOR)+" adds topics");
			const ss_ topic_name = jstr(q, "name"), about = jstr(q, "about");
			need(text_ok(topic_name, NAME_MAX, false, "the name"));
			if(!about.empty())
				need(text_ok(about, 400, false, "the description"));
			const int64_t parent = jint(q, "parent");
			if(parent != 0){
				const json::Value p = topic(parent);
				if(!p.is_object())
					throw Exception("no such parent topic");
				// One level of subtopics: the pages show no deeper
				if(p.get("parent").as_integer() != 0)
					throw Exception("a subtopic cannot have subtopics");
			}
			Q i(m_db, "INSERT INTO topics(parent, name, about, tracker) "
					"VALUES(?, ?, ?, ?)");
			i.b(parent).b(topic_name).b(about)
					.b((int64_t)q.get("tracker").is_true()).step();
			log_i(MODULE, "%s added the topic %s", cs(name), cs(topic_name));
			return json::Value((int64_t)sqlite3_last_insert_rowid(m_db));
		}
		// [HEARTH_TRACKER]: a topic made a tracker, or not
		// [HEARTH_UI] A topic's name and what it is about, by a moderator
		if(cmd == "edit_topic"){
			if(!mod)
				throw Exception("only a "+level_name(LV_MODERATOR)+" edits topics");
			const ss_ topic_name = jstr(q, "name"), about = jstr(q, "about");
			need(text_ok(topic_name, NAME_MAX, false, "the name"));
			if(!about.empty())
				need(text_ok(about, 400, false, "the description"));
			Q u(m_db, "UPDATE topics SET name = ?, about = ? WHERE id = ?");
			u.b(topic_name).b(about).b(jint(q, "topic")).step();
			if(sqlite3_changes(m_db) == 0)
				throw Exception("no such topic");
			return json::Value(true);
		}
		// [DISCUSS_SERVER] A topic's category: where Hearth puts a thread
		// about a server the client was playing on
		if(cmd == "topic_category"){
			if(!mod)
				throw Exception("only a "+level_name(LV_MODERATOR)+" sets a topic's category");
			const ss_ category = jstr(q, "category");
			// [LIVELY_MENU] "announcements": its threads lead the feed
			if(category != "" && category != "servers" &&
					category != "announcements")
				throw Exception("a category is \"servers\", "
						"\"announcements\" or none");
			Q u(m_db, "UPDATE topics SET category = ? WHERE id = ?");
			u.b(category).b(jint(q, "topic")).step();
			if(sqlite3_changes(m_db) == 0)
				throw Exception("no such topic");
			m_feed_at = -1;
			return json::Value(true);
		}
		if(cmd == "topic_tracker"){
			if(!mod)
				throw Exception("only a "+level_name(LV_MODERATOR)+" marks a tracker");
			Q u(m_db, "UPDATE topics SET tracker = ? WHERE id = ?");
			u.b((int64_t)q.get("on").is_true()).b(jint(q, "topic")).step();
			if(sqlite3_changes(m_db) == 0)
				throw Exception("no such topic");
			return json::Value(true);
		}
		// The tracker domains: {add, remove} -> the list. A removed one
		// takes with it every link a new account posted to it
		if(cmd == "tracker_domains"){
			std::set<ss_> domains = tracker_domains();
			if(!q.get("add").is_undefined() || !q.get("remove").is_undefined()){
				if(!mod)
					throw Exception("only a "+level_name(LV_MODERATOR)+" sets the tracker domains");
				for(const char *k : {"add", "remove"}){
					const json::Value &l = q.get(k);
					for(unsigned i = 0; l.is_array() && i < l.size(); i++){
						const ss_ h = l.at(i).is_string() ? url_host("http://"+
								l.at(i).as_string()) : ss_();
						if(h.empty() || h.size() > 100)
							throw Exception(ss_(k)+": not a domain");
						if(k[0] == 'a')
							domains.insert(h);
						else
							domains.erase(h);
					}
				}
				if(domains.size() > 200)
					throw Exception("200 tracker domains at most");
				set_tracker_domains(domains);
			}
			json::Value l = json::array();
			for(const ss_ &d : domains)
				l.append(d);
			return l;
		}
		// A ticket's tracker link, by whoever started it or a moderator; ""
		// takes it off. On a domain not whitelisted: an account that may
		// post links whitelists it, anyone else's waits in the queue
		if(cmd == "tracker_link"){
			const int64_t thread_id = jint(q, "thread");
			const ss_ link = jstr(q, "link");
			Q t(m_db, "SELECT t.author, t.kind, p.tracker, (SELECT min(id) "
					"FROM messages WHERE thread = t.id) FROM threads t JOIN "
					"topics p ON p.id = t.topic WHERE t.id = ?");
			t.b(thread_id);
			if(!t.step())
				throw Exception("no such thread");
			if(t.s(0) != name && !mod)
				throw Exception("only whoever started the ticket links it");
			if(!t.i(2) || (t.s(1) != "problem" && t.s(1) != "patch"))
				throw Exception("only a ticket (a problem or a patch in a "
						"tracker) has a tracker link");
			const ss_ host = url_host(link);
			if(!link.empty()){
				need(text_ok(link, 300, false, "the link"));
				if(host.empty())
					throw Exception("a tracker link is an http(s) address");
			}
			Q u(m_db, "UPDATE threads SET link = ?, link_by = ? WHERE id = ?");
			u.b(link).b(link.empty() ? ss_() : name).b(thread_id).step();
			std::set<ss_> domains = tracker_domains();
			if(link.empty() || domains.count(host))
				return json::Value(true);
			if(limits(lv).links){
				domains.insert(host);
				set_tracker_domains(domains);
				log_i(MODULE, "%s added the tracker domain %s", cs(name),
						cs(host));
				return json::Value(true);
			}
			Q o(m_db, "SELECT 1 FROM reports WHERE kind = 'domain' AND "
					"reason = ? AND state = 'open'");
			o.b(host);
			if(!o.step()){
				Q i(m_db, "INSERT INTO reports(kind, message, by, reason, time) "
						"VALUES('domain', ?, ?, ?, ?)");
				i.b(t.i(3)).b(name).b(host).b(now_s()).step();
				push_queue("a link's domain to look at");
			}
			return json::Value(false);
		}
		if(cmd == "upload"){
			// [FORUM] step 5: {name, data (hex)} -> {id, image}; at /f/<id>
			const ss_ file_name = jstr(q, "name");
			const ss_ hex = jstr(q, "data");
			if(hex.size() > UPLOAD_MAX * 2)
				throw Exception("a file is "+itos(UPLOAD_MAX >> 20)+
						" MiB at most");
			ss_ data = unhex(hex), type = "application/octet-stream";
			// [HEARTH_TRACKER]: a patch, a new account's too; and
			// [HEARTH_NEW_IMAGES] an image, one a thread, shown to everyone
			// once a helper says
			const bool patch = is_patch(file_name, data);
			const bool png = data.compare(0, 8, "\x89PNG\r\n\x1a\n") == 0;
			const bool jpeg = data.compare(0, 3, "\xff\xd8\xff") == 0;
			if(!limits(lv).links && !patch && !png && !jpeg)
				throw Exception("no files yet but a patch or an image (a "+
						level_name(LV_NEW)+"'s limit, until it has been "
						"active on five days or a "+level_name(LV_HELPER)+
						" approves it)");
			Q c(m_db, "SELECT count(*) FROM files WHERE uploader = ? AND "
					"created > ?");
			c.b(name).b(now_s() - 3600).step();
			if(lv < LV_MODERATOR && c.i(0) >= UPLOADS_AN_HOUR)
				throw Exception(itos(UPLOADS_AN_HOUR)+" files an hour at most");
			// [SECURITY_RUN_4] What an account has uploaded and no message
			// names, held a day by sweep_files(): 64 MiB of it at most
			Q u(m_db, "SELECT coalesce(sum(length(data)), 0) FROM files f "
					"WHERE uploader = ? AND NOT EXISTS (SELECT 1 FROM "
					"file_links WHERE file = f.id)");
			u.b(name).step();
			if(lv < LV_MODERATOR && u.i(0) >= (64 << 20))
				throw Exception("64 MiB of files not in a message yet at most; "
						"post them or wait a day");
			need(text_ok(file_name, NAME_MAX, false, "the file's name"));
			if(data.empty())
				throw Exception("the file is empty");
			int64_t lod = 0;
			if(patch){
				type = PATCH_TYPE;
			} else if(png){
				data = crush(data, false, 1920, 1080, 0);
				type = "image/png";
				lod = 1;
			} else if(jpeg){
				data = crush(data, true, 1920, 1080, 85);
				type = "image/jpeg";
				lod = 1;
			}
			// A random id, not the next one: a file not posted yet is
			// not found by counting ([SEC_HEARTH_FILES]). Under 2^46, so
			// Lua's tostring (%.14g) still writes it in digits.
			// simplified: a collision is not retried; one in 2^46 per file
			uint64_t r = 0;
			const ss_ rb = interface::bignum::random_bytes(8);
			memcpy(&r, rb.data(), sizeof r);
			const int64_t file_id = (int64_t)(r & ((1ULL << 46) - 1)) + 1;
			const ss_ thumb = lod == 1 ? make_thumb(data, type) : ss_();
			Q i(m_db, "INSERT INTO files(id, name, type, data, lod, uploader, "
					"created, used, thumb, vetted) VALUES(?, ?, ?, ?, ?, ?, ?, "
					"?, ?, ?)");
			i.b(file_id).b(file_name).b(type).blob(data).b(lod).b(name)
					.b(now_s()).b(now_s()).blob(thumb)
					.b((int64_t)(lv >= LV_MEMBER)).step();
			json::Value v = json::object();
			v.set("id", file_id);
			v.set("image", lod == 1);
			v.set("patch", patch);
			v.set("bytes", (int64_t)data.size());
			return v;
		}
		if(cmd == "thumb"){
			// [HEARTH_ATTACHMENTS] {file} -> {type, data (hex)}: an image's
			// thumbnail for the client, served as /f/<id>/thumb is
			const int64_t id = jint(q, "file");
			ss_ type, data;
			if(id <= 0 || !file_served(id) || !file_data(id, true, type, data))
				throw Exception("no such file");
			json::Value v = json::object();
			v.set("type", type);
			v.set("data", interface::sha256::hex(data));
			return v;
		}
		if(cmd == "file_settings"){
			if(!admin)
				throw Exception("only the "+level_name(LV_ADMIN)+" sets the files' budget");
			json::Value v = file_settings();
			bool any = false;
			for(const char *k : FILE_SETTINGS)
				any = any || !q.get(k).is_undefined();
			// None given: the settings as they are, the sweep left alone
			if(!any)
				return v;
			for(const char *k : FILE_SETTINGS){
				const json::Value &x = q.get(k);
				if(x.is_undefined())
					continue;
				if(!x.is_number() || !(x.as_number() >= 0 &&
						x.as_number() < 9e15))
					throw Exception(ss_(k)+": a number, 0 or more");
				v.set(k, (int64_t)x.as_number());
			}
			Q i(m_db, "INSERT OR REPLACE INTO settings(key, value) "
					"VALUES('files', ?)");
			i.b(v.stringify()).step();
			m_files_swept = 0;
			return v;
		}
		if(cmd == "vet_file"){
			// [HEARTH_NEW_IMAGES] {file | message, on}: a new account's image
			// shown to everyone, or taken back (then not shown when it is a
			// member either), by a helper or above; with message, each of its
			// images that is a new account's ([HEARTH_MOD_TOOLS])
			if(lv < LV_HELPER)
				throw Exception("a "+level_name(LV_HELPER)+" says whether "
						"everyone sees an image");
			std::vector<int64_t> ids;
			if(q.get("message").is_number()){
				Q m(m_db, "SELECT body FROM messages WHERE id = ?");
				m.b(jint(q, "message"));
				if(!m.step())
					throw Exception("no such message");
				const json::Value fs = files_of(m.s(0), true);
				for(unsigned i = 0; i < fs.size(); i++)
					if(fs.at(i).get("image").is_true() &&
							(!fs.at(i).get("vetted").is_true() ||
							jint(fs.at(i), "vet") == 1))
						ids.push_back(jint(fs.at(i), "id"));
			} else {
				ids.push_back(jint(q, "file"));
			}
			const bool on = q.get("on").is_true();
			int changed = 0;
			bool above = false;
			for(int64_t id : ids){
				// Only an image of an author below the one vetting
				// ([SEC_RUN4_LEFTOVERS]): a helper does not take back
				// the admin's or a moderator's
				Q o(m_db, "SELECT uploader FROM files WHERE id = ?");
				o.b(id);
				if(o.step() && level(o.s(0)) >= lv){
					above = true;
					continue;
				}
				Q u(m_db, "UPDATE files SET vetted = ? WHERE id = ? AND lod > 0");
				u.b((int64_t)(on ? 1 : -1)).b(id).step();
				changed += sqlite3_changes(m_db);
				log_i(MODULE, "%s %s image %lld", cs(name), on ?
						"showed everyone" : "took back", (long long)id);
			}
			if(changed == 0 && above)
				throw Exception("an image of a "+level_name(lv)+
						" or above is not yours to vet");
			if(changed == 0)
				throw Exception("no such image");
			return json::Value(true);
		}
		if(cmd == "delete"){
			// [HEARTH_MOD_TOOLS] {message, thread, reason, text}: a
			// moderator's Delete, of the message or (thread, or the thread's
			// first message) the whole thread -- hidden as DELETED, its place
			// saying so, the author told why and able to appeal; purged after
			// DELETED_KEEP_S. The admin's message is no one's to delete.
			if(!mod)
				throw Exception("only a "+level_name(LV_MODERATOR)+" deletes");
			const ss_ reason = jstr(q, "reason"), text = jstr(q, "text");
			need(text_ok(reason, 60, false, "the reason"));
			if(!text.empty())
				need(text_ok(text, 1000, true, "the text"));
			Q m(m_db, "SELECT m.author, m.thread, (SELECT min(id) FROM messages "
					"WHERE thread = m.thread) FROM messages m WHERE m.id = ?");
			m.b(jint(q, "message"));
			if(!m.step())
				throw Exception("no such message");
			const int64_t thread_id = m.i(1);
			const int64_t target = q.get("thread").is_true() ? m.i(2) :
					jint(q, "message");
			Q a(m_db, "SELECT author FROM messages WHERE id = ?");
			a.b(target).step();
			const ss_ author = a.s(0);
			delete_as_moderator(target, thread_id, author, name, reason, text);
			return json::Value(true);
		}
		if(cmd == "ban"){
			// [HEARTH_MOD_TOOLS] {name, days (0: until lifted), reason, text,
			// delete_days}: a moderator's Ban, by builtin/accounts, with its
			// end and why, which a refused join says; with delete_days their
			// messages of those days deleted, each as Delete does it. Not on
			// a helper or above.
			if(!mod)
				throw Exception("only a "+level_name(LV_MODERATOR)+" bans");
			const ss_ who = jstr(q, "name"), reason = jstr(q, "reason"),
					text = jstr(q, "text");
			need(text_ok(who, NAME_MAX, false, "the name"));
			need(text_ok(reason, 60, false, "the reason"));
			if(!text.empty())
				need(text_ok(text, 1000, true, "the text"));
			const int64_t days = jint(q, "days"), del = jint(q, "delete_days");
			if(days < 0 || days > 3650 || del < 0 || del > 30)
				throw Exception("days out of range");
			if(accounts::level(m_server, who) >= LV_HELPER)
				throw Exception("a "+level_name(LV_HELPER)+" or above is not "
						"banned here");
			ss_ why;
			accounts::access(m_server, [&](accounts::Interface *ai){
				why = ai->ban(who, name, days ? now_s() + days * 86400 : 0,
						reason+(text.empty() ? ss_() : " -- "+text));
			});
			need(why);
			if(del > 0){
				Q ms(m_db, "SELECT id, thread FROM messages WHERE author = ? "
						"AND created > ? AND hidden != ?");
				ms.b(who).b(now_s() - del * 86400).b((int64_t)DELETED);
				std::vector<std::pair<int64_t, int64_t>> ids;
				while(ms.step())
					ids.emplace_back(ms.i(0), ms.i(1));
				for(auto &p : ids)
					delete_as_moderator(p.first, p.second, who, name, reason,
							text);
			}
			log_i(MODULE, "%s banned %s for %lld days: %s", cs(name), cs(who),
					(long long)days, cs(reason));
			return json::Value(true);
		}
		if(cmd == "delete_file"){
			// A claim of copyright or personal data a moderator has upheld:
			// gone at once, whatever its use
			if(!mod)
				throw Exception("only a "+level_name(LV_MODERATOR)+" deletes a file");
			Q d(m_db, "DELETE FROM files WHERE id = ?");
			d.b(jint(q, "file")).step();
			if(sqlite3_changes(m_db) == 0)
				throw Exception("no such file");
			return json::Value(true);
		}
		if(cmd == "public_url"){
			// [HEARTH_DISCUSSED_API]: the base of /api/v1/discussed's links,
			// as the public reaches this Hearth; "" for the request's Host
			if(!admin)
				throw Exception("only the "+level_name(LV_ADMIN)+" sets the public address");
			ss_ u = jstr(q, "url");
			while(!u.empty() && u.back() == '/')
				u.pop_back();
			if(u.size() > 200 || (!u.empty() && u.compare(0, 7, "http://") != 0 &&
					u.compare(0, 8, "https://") != 0) ||
					u.find_first_of(" \"<>\\") != ss_::npos)
				throw Exception("not an http(s) address: "+u);
			json::Value v = json::object();
			v.set("url", u);
			Q i(m_db, "INSERT OR REPLACE INTO settings(key, value) "
					"VALUES('public_url', ?)");
			i.b(v.stringify()).step();
			m_discussed_at = -1;
			return v;
		}
		if(cmd == "release_sources"){
			// [PACKAGE_SUBJECT]: the Aittas read and this Hearth's own
			// addresses, set by a moderator; without either, the current
			if(!admin)
				throw Exception("only the "+level_name(LV_ADMIN)+" sets the release sources");
			json::Value v = setting("release_sources");
			// Neither given: as they are, nothing fetched again
			if(q.get("aittas").is_undefined() && q.get("addresses").is_undefined())
				return v;
			for(const char *k : {"aittas", "addresses"}){
				const json::Value &l = q.get(k);
				if(l.is_undefined())
					continue;
				if(!l.is_array() || l.size() > 10)
					throw Exception(ss_(k)+": a list of ten addresses at most");
				json::Value out = json::array();
				for(unsigned i = 0; i < l.size(); i++){
					const ss_ u = l.at(i).is_string() ? l.at(i).as_string() : "";
					if(u.size() > 200 || (u.compare(0, 7, "http://") != 0 &&
							u.compare(0, 8, "https://") != 0))
						throw Exception(ss_(k)+": not an http(s) address: "+u);
					out.append(norm_url(u));
				}
				v.set(k, out);
			}
			Q i(m_db, "INSERT OR REPLACE INTO settings(key, value) "
					"VALUES('release_sources', ?)");
			i.b(v.stringify()).step();
			{
				std::lock_guard<std::mutex> lock(m_rmutex);
				m_rsources = v;
				m_rkick = true;
			}
			m_rwake.notify_all();
			return v;
		}
		if(cmd == "new_thread"){
			// "feedback": the client's Feedback... on an app, which knows
			// the app's subject and not this Hearth's topics
			// ([PACKAGE_SUBJECT])
			// "server": the client's Discuss on a server it was playing
			// on ([DISCUSS_SERVER]), "server:<host>:<port>" its subject
			// "game": the same about a game ([OVERLAY_DISCUSS]),
			// "game:<source>" its subject
			const bool server = q.get("server").is_true(),
					game = q.get("game").is_true();
			const int64_t topic_id = q.get("feedback").is_true() ?
					top_topic("Feedback", "About the packages at home here, "
					"from their users' clients") :
					server ? category_topic("servers", "Servers",
					"About the game servers people play on") :
					game ? category_topic("games", "Games",
					"About the apps and games people play") :
					jint(q, "topic");
			const ss_ title = jstr(q, "title"), body = jstr(q, "body"),
					subject = jstr(q, "subject"), kind = jstr(q, "kind"),
					version = jstr(q, "version");
			if(server && subject.rfind("server:", 0) != 0)
				throw Exception("a server's thread has its subject");
			if(game && subject.rfind("game:", 0) != 0)
				throw Exception("a game's thread has its subject");
			const json::Value top = topic(topic_id);
			if(!top.is_object())
				throw Exception("no such topic");
			if(!POSTED_KINDS.count(kind))
				throw Exception("a thread is a discussion, a question, a "
						"problem, an idea or a patch");
			if(kind == "patch" && !top.get("tracker").is_true())
				throw Exception("a patch is a ticket, in a tracker topic");
			if(!version.empty() && !version_ok(version))
				throw Exception("a version is 1 to 40 of letters, digits "
						"and .+_-");
			need(text_ok(title, TITLE_MAX, false, "the title"));
			need(text_ok(body, BODY_MAX, true, "the message"));
			if(!subject.empty())
				need(text_ok(subject, 400, false, "the subject"));
			const bool held = check_limits(name, lv, true, title+"\n"+body);
			check_images(name, lv, 0, 0, body);
			const int64_t t = now_s();
			Q i(m_db, "INSERT INTO threads(topic, title, author, created, last, "
					"subject, kind, status, version) VALUES(?, ?, ?, ?, ?, ?, ?, "
					"?, ?)");
			i.b(topic_id).b(title).b(name).b(t).b(t).b(subject).b(kind)
					.b(ss_(kind == "problem" || kind == "patch" ? "open" : ""))
					.b(version).step();
			const int64_t id = sqlite3_last_insert_rowid(m_db);
			add_message(id, name, body, title, true, held);
			return json::Value(id);
		}
		// A problem's status. simplified: a moderator's; the package's owners
		// hold it once a Hearth account can be tied to an Aitta author
		// ([PACKAGE_SUBJECT], a question to the user)
		if(cmd == "status"){
			const int64_t thread_id = jint(q, "thread");
			const ss_ status = jstr(q, "status"), fixed_in = jstr(q, "fixed_in");
			if(!mod)
				throw Exception("only a "+level_name(LV_MODERATOR)+" sets a problem's status");
			Q t(m_db, "SELECT kind FROM threads WHERE id = ?");
			t.b(thread_id);
			if(!t.step() || (t.s(0) != "problem" && t.s(0) != "patch"))
				throw Exception("no such problem or patch");
			const ss_ kind = t.s(0);
			if(kind == "problem" && !STATUSES.count(status))
				throw Exception("a status is open, confirmed, fixed or wontfix");
			if(kind == "patch" && !PATCH_STATUSES.count(status))
				throw Exception("a patch is open, applied or wontfix");
			if(!fixed_in.empty() && ((status != "fixed" && status != "applied")
					|| !version_ok(fixed_in)))
				throw Exception("fixed_in is a version, and only with fixed or "
						"applied");
			Q u(m_db, "UPDATE threads SET status = ?, fixed_in = ? WHERE id = ?");
			u.b(status).b(fixed_in).b(thread_id).step();
			// Whoever reported it learns the outcome without a reply
			Q a(m_db, "SELECT author FROM threads WHERE id = ?");
			a.b(thread_id).step();
			json::Value now = json::object();
			now.set("kind", kind);
			now.set("status", status);
			now.set("fixed_in", fixed_in);
			if(a.s(0) != name)
				notify(a.s(0), "status", thread_id, 0, name, kind_text(now));
			log_i(MODULE, "%s set the thread %lld %s", cs(name),
					(long long)thread_id, cs(status));
			return json::Value(true);
		}
		if(cmd == "reply"){
			const int64_t thread_id = jint(q, "thread");
			const ss_ body = jstr(q, "body");
			Q t(m_db, "SELECT 1 FROM threads WHERE id = ?");
			t.b(thread_id);
			if(!t.step())
				throw Exception("no such thread");
			need(text_ok(body, BODY_MAX, true, "the message"));
			Q th(m_db, "SELECT hidden FROM threads WHERE id = ?");
			th.b(thread_id).step();
			if(th.i(0) && !mod)
				throw Exception("the thread is hidden");
			const bool held = check_limits(name, lv, false, body);
			check_images(name, lv, thread_id, 0, body);
			return json::Value(add_message(thread_id, name, body, "", true,
					held));
		}
		if(cmd == "edit"){
			const int64_t id = jint(q, "message");
			const ss_ body = jstr(q, "body");
			Q m(m_db, "SELECT m.author, m.body, m.hidden, t.hidden, m.thread "
					"FROM messages m JOIN threads t ON t.id = m.thread WHERE "
					"m.id = ?");
			m.b(id);
			if(!m.step())
				throw Exception("no such message");
			if(m.s(0) != name && !mod)
				throw Exception("only its author edits a message");
			// What the moderator hid stays what the appeal is read against
			if((m.i(2) || m.i(3)) && !mod)
				throw Exception("a hidden message is not edited");
			need(text_ok(body, BODY_MAX, true, "the message"));
			const bool held = check_limits(name, lv, false, body);
			check_images(name, lv, m.i(4), id, body);
			const int64_t t = now_s();
			Q h(m_db, "INSERT INTO edits(message, body, time, editor) "
					"VALUES(?, ?, ?, ?)");
			h.b(id).b(m.s(1)).b(t).b(name).step();
			Q u(m_db, "UPDATE messages SET body = ?, edited = ? WHERE id = ?");
			u.b(body).b(t).b(id).step();
			link_files(id, body);
			Q s(m_db, "UPDATE search SET body = ? WHERE rowid = ?");
			s.b(body).b(id).step();
			if(held)
				hold(id, name);
			return json::Value(true);
		}
		if(cmd == "answered"){
			// By whoever asked (or a moderator); message 0 takes it back
			const int64_t thread_id = jint(q, "thread"),
					message_id = jint(q, "message");
			Q t(m_db, "SELECT author, (SELECT min(id) FROM messages "
					"WHERE thread = threads.id) FROM threads WHERE id = ?");
			t.b(thread_id);
			if(!t.step())
				throw Exception("no such thread");
			if(t.s(0) != name && !mod)
				throw Exception("only whoever started the thread says what "
						"answered it");
			ss_ by;
			if(message_id != 0){
				Q m(m_db, "SELECT author FROM messages WHERE id = ? AND "
						"thread = ?");
				m.b(message_id).b(thread_id);
				if(!m.step() || message_id == t.i(1))
					throw Exception("not a reply in this thread");
				by = m.s(0);
			}
			Q u(m_db, "UPDATE threads SET answer = ? WHERE id = ?");
			u.b(message_id).b(thread_id).step();
			// Once a message: taking it back and giving it again tells no
			// one twice
			Q told(m_db, "SELECT 1 FROM notifications WHERE account = ? AND "
					"kind = 'answer' AND message = ?");
			told.b(by).b(message_id);
			if(!by.empty() && by != name && !told.step())
				notify(by, "answer", thread_id, message_id, name);
			return json::Value(true);
		}
		if(cmd == "thank"){
			// [HEARTH_THANKS]: {message, on}; the message's count back
			const int64_t message_id = jint(q, "message");
			const bool on = q.get("on").is_true();
			if(lv < LV_MEMBER)
				throw Exception("thanks are a "+level_name(LV_MEMBER)+"'s");
			Q m(m_db, "SELECT m.author, m.thread, m.hidden, t.hidden FROM "
					"messages m JOIN threads t ON t.id = m.thread WHERE "
					"m.id = ?");
			m.b(message_id);
			if(!m.step() || m.i(2) != 0 || m.i(3) != 0)
				throw Exception("no such message");
			const ss_ author = m.s(0);
			const int64_t thread_id = m.i(1);
			if(author == name)
				throw Exception("not your own message");
			Q was(m_db, "SELECT active FROM thanks WHERE message = ? AND "
					"account = ?");
			was.b(message_id).b(name);
			const bool had_row = was.step();
			if(on && !(had_row && was.i(0))){
				// simplified: a flat 60 an hour, past what a reader gives
				Q r(m_db, "SELECT count(*) FROM thanks WHERE account = ? AND "
						"time > ?");
				r.b(name).b(now_s() - 3600).step();
				if(r.i(0) >= 60)
					throw Exception("60 thanks an hour at most");
				Q t(m_db, "INSERT INTO thanks(message, account, time, active) "
						"VALUES(?, ?, ?, 1) ON CONFLICT(message, account) DO "
						"UPDATE SET active = 1, time = excluded.time");
				t.b(message_id).b(name).b(now_s()).step();
				// The author told once an account: gathered into the
				// unseen one for this message while there is one, the
				// latest name and the count of the others in its note
				if(!had_row){
					Q u(m_db, "SELECT id, note FROM notifications WHERE "
							"account = ? AND kind = 'thanks' AND message = ? "
							"AND seen = 0");
					u.b(author).b(message_id);
					if(u.step()){
						Q g(m_db, "UPDATE notifications SET by = ?, time = ?, "
								"note = ? WHERE id = ?");
						g.b(name).b(now_s()).b(itos(atoll(u.s(1).c_str()) + 1))
								.b(u.i(0)).step();
						m_notified.insert(author);
					} else {
						notify(author, "thanks", thread_id, message_id, name);
					}
				}
			} else if(!on){
				Q t(m_db, "UPDATE thanks SET active = 0 WHERE message = ? AND "
						"account = ?");
				t.b(message_id).b(name).step();
			}
			Q c(m_db, "SELECT count(*) FROM thanks WHERE message = ? AND "
					"active = 1");
			c.b(message_id).step();
			return json::Value(c.i(0));
		}
		if(cmd == "follow"){
			const int64_t thread_id = jint(q, "thread");
			if(q.get("on").is_true()){
				Q f(m_db, "INSERT OR IGNORE INTO follows(account, thread) "
						"SELECT ?, id FROM threads WHERE id = ?");
				f.b(name).b(thread_id).step();
			} else {
				Q f(m_db, "DELETE FROM follows WHERE account = ? AND thread = ?");
				f.b(name).b(thread_id).step();
			}
			return json::Value(true);
		}
		if(cmd == "notifications"){
			// The latest 50, and they are seen now
			json::Value list = json::array();
			Q n(m_db, "SELECT n.id, n.kind, n.thread, n.message, n.by, n.time, "
					"n.seen, CASE WHEN t.hidden AND t.author != ? THEN "
					"'A hidden thread' ELSE t.title END, n.note FROM "
					"notifications n JOIN threads t ON t.id = n.thread WHERE "
					"n.account = ? ORDER BY n.id DESC LIMIT 50");
			n.b(name).b(name);
			while(n.step()){
				json::Value v = json::object();
				v.set("id", n.i(0));
				v.set("kind", n.s(1));
				v.set("thread", n.i(2));
				v.set("message", n.i(3));
				v.set("by", n.s(4));
				v.set("time", n.i(5));
				v.set("seen", n.i(6) != 0);
				v.set("title", n.s(7));
				v.set("note", n.s(8));
				list.append(v);
			}
			Q u(m_db, "UPDATE notifications SET seen = 1 WHERE account = ? "
					"AND seen = 0");
			u.b(name).step();
			return list;
		}
		if(cmd == "report" || cmd == "appeal"){
			// A report: someone else's shown message. An appeal: one's own
			// hidden message. One open of each per account and message.
			const bool appeal = cmd == "appeal";
			const int64_t id = jint(q, "message");
			const ss_ reason = jstr(q, appeal ? "text" : "reason");
			need(text_ok(reason, 1000, true, appeal ? "the appeal" :
					"the reason"));
			Q m(m_db, "SELECT author, hidden FROM messages WHERE id = ?");
			m.b(id);
			if(!m.step())
				throw Exception("no such message");
			if(appeal && m.s(0) != name)
				throw Exception("only its author appeals");
			if(appeal && m.i(1) != HIDDEN && m.i(1) != DELETED)
				throw Exception("the message is not hidden or deleted by a "+
						level_name(LV_MODERATOR));
			if(!appeal && m.s(0) == name)
				throw Exception("one's own message is edited, not reported");
			if(!appeal && m.i(1))
				throw Exception("the message is hidden already");
			Q o(m_db, "SELECT 1 FROM reports WHERE kind = ? AND message = ? AND "
					"by = ? AND state = 'open'");
			o.b(cmd).b(id).b(name);
			if(o.step())
				throw Exception(appeal ? "the appeal is waiting already" :
						"the report is waiting already");
			Q d(m_db, "SELECT count(*) FROM reports WHERE by = ? AND time > ? "
					"AND kind IN ('report', 'appeal')");
			d.b(name).b(now_s() - 86400).step();
			if(!mod && d.i(0) >= REPORTS_A_DAY)
				throw Exception(itos(REPORTS_A_DAY)+" reports a day at most");
			// [TRUST_LADDER] Its weight by the reporter's level, none while
			// a hide it reported was undone in the last 30 days
			int weight = lv >= LV_HELPER ? HIDE_WEIGHT : lv >= LV_MEMBER ? 1 : 0;
			Q ov(m_db, "SELECT 1 FROM reports WHERE by = ? AND state = "
					"'overturned' AND handled_time > ?");
			ov.b(name).b(now_s() - 30 * 86400);
			if(ov.step())
				weight = 0;
			ss_ bin;
			accounts::access(m_server, [&](accounts::Interface *a){
				bin = network::address_bin(a->address_of(peer));
			});
			Q i(m_db, "INSERT INTO reports(kind, message, by, reason, time, "
					"bin, weight) VALUES(?, ?, ?, ?, ?, ?, ?)");
			i.b(cmd).b(id).b(name).b(reason).b(now_s()).b(appeal ? ss_() : bin)
					.b((int64_t)(appeal ? 0 : weight)).step();
			const int64_t report_id = sqlite3_last_insert_rowid(m_db);
			push_queue(appeal ? "a new appeal" : "a new report");
			// A network's reports once, at their highest; a helper's or
			// above's message is only queued
			Q w(m_db, "SELECT ifnull(sum(w), 0) FROM (SELECT max(weight) AS w "
					"FROM reports WHERE kind = 'report' AND message = ? AND "
					"state = 'open' GROUP BY bin)");
			w.b(id).step();
			if(!appeal && w.i(0) >= HIDE_WEIGHT && level(m.s(0)) < LV_HELPER){
				set_hidden(id, REPORTED, "");
				log_i(MODULE, "the message %lld hidden by reports until a "
						"moderator looks", (long long)id);
			}
			return json::Value(report_id);
		}
		if(cmd == "queue"){
			if(lv < LV_HELPER)
				throw Exception("only a "+level_name(LV_HELPER)+" or higher sees the "
						"queue");
			json::Value list = json::array();
			Q r(m_db, "SELECT r.id, r.kind, r.message, r.by, r.reason, r.time, "
					"m.author, m.body, m.thread, t.title, m.hidden_reason, "
					"m.hidden FROM "
					"reports r JOIN messages m ON m.id = r.message JOIN threads t "
					"ON t.id = m.thread WHERE r.state = 'open' ORDER BY r.id");
			while(r.step()){
				json::Value v = json::object();
				v.set("id", r.i(0));
				v.set("kind", r.s(1));
				v.set("message", r.i(2));
				v.set("by", r.s(3));
				v.set("reason", r.s(4));
				v.set("time", r.i(5));
				v.set("author", r.s(6));
				v.set("body", r.s(7));
				v.set("thread", r.i(8));
				v.set("title", r.s(9));
				v.set("hidden_reason", r.s(10));
				v.set("hidden", r.i(11));
				list.append(v);
			}
			return list;
		}
		if(cmd == "moderate"){
			// hide (a report), restore (an appeal), dismiss (either). Hiding
			// and refusing an appeal say why: the author is told it. A held
			// link ([TRUST_LADDER]): approve or reject, a helper's too.
			if(lv < LV_HELPER)
				throw Exception("only a "+level_name(LV_MODERATOR)+" moderates");
			const ss_ action = jstr(q, "action"), statement = jstr(q, "statement");
			Q r(m_db, "SELECT r.kind, r.message, m.author, m.thread, m.hidden "
					"FROM reports r JOIN messages m ON m.id = r.message WHERE "
					"r.id = ? AND r.state = 'open'");
			r.b(jint(q, "report"));
			if(!r.step())
				throw Exception("no such open report");
			const bool appeal = r.s(0) == "appeal";
			const int64_t message_id = r.i(1), thread_id = r.i(3);
			const ss_ author = r.s(2);
			auto settle = [&](const char *state){
				Q u(m_db, "UPDATE reports SET state = ?, handled_by = ?, "
						"handled_time = ?, statement = ?, bin = '' WHERE id = ?");
				u.b(ss_(state)).b(name).b(now_s()).b(statement)
						.b(jint(q, "report")).step();
			};
			if(r.s(0) == "held"){
				if(action == "approve"){
					trust_account(author, name, lv, true, message_id);
					set_hidden(message_id, 0, "");
				} else if(action == "reject"){
					delete_message(message_id);
				} else {
					throw Exception("a held link is approved or rejected");
				}
				settle(action == "approve" ? "upheld" : "dismissed");
				return json::Value(true);
			}
			if(!mod)
				throw Exception("only a "+level_name(LV_MODERATOR)+" moderates");
			// Hidden by reports and dismissed: shown again, and its reports
			// overturned, which weigh their reporters' next ones nothing
			if(!appeal && action == "dismiss" && r.i(4) == REPORTED){
				set_hidden(message_id, 0, "");
				Q u(m_db, "UPDATE reports SET state = 'overturned', "
						"handled_by = ?, handled_time = ?, statement = ?, "
						"bin = '' WHERE state = 'open' AND kind = 'report' AND "
						"message = ?");
				u.b(name).b(now_s()).b(statement).b(message_id).step();
				return json::Value(true);
			}
			// [HEARTH_TRACKER]: a tracker link's domain, accepted onto the
			// whitelist or dismissed
			if(r.s(0) == "domain"){
				if(action != "accept" && action != "dismiss")
					throw Exception("a domain is accepted or dismissed");
				Q d(m_db, "SELECT reason FROM reports WHERE id = ?");
				d.b(jint(q, "report")).step();
				if(action == "accept"){
					std::set<ss_> domains = tracker_domains();
					domains.insert(d.s(0));
					set_tracker_domains(domains);
				}
				settle(action == "accept" ? "upheld" : "dismissed");
				return json::Value(true);
			}
			if(action != "dismiss" && action != (appeal ? "restore" : "hide"))
				throw Exception(appeal ? "an appeal is restored or dismissed" :
						"a report is hidden or dismissed");
			if(action == "hide" || (appeal && action == "dismiss"))
				need(text_ok(statement, 1000, true, "the statement"));
			else if(!statement.empty())
				need(text_ok(statement, 1000, true, "the statement"));
			if(action == "hide"){
				set_hidden(message_id, HIDDEN, statement);
				notify(author, "hidden", thread_id, message_id, name, statement);
			}else if(action == "restore"){
				set_hidden(message_id, 0, "");
				notify(author, "restored", thread_id, message_id, name, statement);
			}else if(appeal){
				notify(author, "appeal_dismissed", thread_id, message_id, name,
						statement);
			}
			// A hide settles the other reports of the message too
			Q u(m_db, action == "dismiss" ?
					"UPDATE reports SET state = ?, handled_by = ?, handled_time = ?, "
					"statement = ?, bin = '' WHERE id = ?" :
					"UPDATE reports SET state = ?, handled_by = ?, handled_time = ?, "
					"statement = ?, bin = '' WHERE state = 'open' AND kind = (SELECT kind "
					"FROM reports WHERE id = ?5) AND message = (SELECT message "
					"FROM reports WHERE id = ?5)");
			u.b(ss_(action == "dismiss" ? "dismissed" : "upheld")).b(name)
					.b(now_s()).b(statement).b(jint(q, "report")).step();
			return json::Value(true);
		}
		// [TRUST_LADDER] {name, on}: an account trusted by a helper or a
		// moderator, or no longer (a helper's own approval, within 7 days)
		if(cmd == "trust"){
			const ss_ who = jstr(q, "name");
			if(lv < LV_HELPER)
				throw Exception("only a "+level_name(LV_HELPER)+" or higher "
						"trusts an account");
			need(text_ok(who, NAME_MAX, false, "the name"));
			trust_account(who, name, lv, q.get("on").is_true());
			return json::Value(true);
		}
		// {name, level}: a level below the asker's own, from a moderator
		// (accounts::set_level's rule): a moderator makes and unmakes
		// helpers, the admin moderators too
		if(cmd == "level"){
			const ss_ who = jstr(q, "name");
			ss_ why;
			accounts::access(m_server, [&](accounts::Interface *a){
				why = a->set_level(who, jint(q, "level"), name);
			});
			need(why);
			return json::Value(true);
		}
		// {name, level} of the helpers and up, to a helper and up
		if(cmd == "staff"){
			if(lv < LV_HELPER)
				throw Exception("only a "+level_name(LV_HELPER)+" or higher "
						"lists them");
			json::Value list = json::array();
			accounts::access(m_server, [&](accounts::Interface *a){
				for(const ss_ &n : a->account_names()){
					const int l = a->level(n);
					if(l < LV_HELPER)
						continue;
					json::Value v = json::object();
					v.set("name", n);
					v.set("level", l);
					list.append(v);
				}
			});
			return list;
		}
		throw Exception("no such command: "+cmd);
	}
// vim: set noet ts=4 sw=4:
