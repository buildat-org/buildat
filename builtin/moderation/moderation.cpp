// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [MODERATION_MODULE]: builtin/moderation/api.h says what this is.
#include "moderation/api.h"
#include "accounts/api.h"
#include "core/log.h"
#include "interface/os.h"
#include "interface/sha256.h"
#include "interface/bignum.h"
#include <algorithm>
#include <cmath>
#define MODULE "moderation"

using json::jstr;
using json::jint;

namespace moderation {

// [SIM_CLOCK]: the calendar, which a check may move
static int64_t now_s(){ return interface::os::wall_us() / 1000000; }
static ss_ random_hex(size_t bytes){
	return interface::sha256::hex(interface::bignum::random_bytes(bytes));
}
static double jnum(const json::Value &v, const char *k, double def = 0)
{
	const json::Value &x = v.get(k);
	return x.is_number() ? x.as_number() : def;
}
static json::Value load(Host *h, const char *store, const ss_ &key)
{
	ss_ text;
	if(!h->save()->store(store)->get(key, text))
		return json::Value();
	return json::load_string(text.c_str());
}
static void put(Host *h, const char *store, const ss_ &key,
		const json::Value &v)
{
	h->save()->store(store)->set(key, v.stringify());
}
static sv_<ss_> keys(Host *h, const char *store)
{
	return h->save()->store(store)->list("");
}

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
	}

	void init(){}
	void event(const interface::Event::Type &type,
			const interface::Event::Private *p){}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}

	// -- Reports and groups

	void add_report(Host *h, json::Value rep, const json::Value &fields)
	{
		if(jstr(rep, "state").empty()){
			const ss_ held = spam_reason(h, rep);
			rep.set("state", held.empty() ? "open" : "held");
			if(!held.empty())
				rep.set("held", held);
		}
		put(h, "reports", jstr(rep, "id"), rep);
		sweep(h);
		if(jstr(rep, "state") != "open")
			return;
		// [ADMIN_NOTIFY] The moderators' phones: the count, nothing of it
		const int64_t open = open_count(h, 1);
		accounts::access(m_server, [&](accounts::Interface *a){
			a->notify(accounts::LV_MODERATOR, h->name()+": a new report, "+
					std::to_string(open)+" open");
		});
		const ss_ gid = jstr(rep, "group");
		json::Value g = load(h, "groups", gid);
		if(!g.is_object() || jstr(g, "state") != "open")
			g = open_group(h, gid, jstr(rep, "listing"), jstr(rep, "reason"),
					"", fields);
		json::Value reps = g.get("reports").deepcopy();
		reps.append(jstr(rep, "id"));
		g.set("reports", reps);
		g.set("weight", group_weight(h, g));
		put(h, "groups", gid, g);
		auto_act(h, g);
	}

	// Why a report is held back, or ""
	ss_ spam_reason(Host *h, const json::Value &rep)
	{
		const ss_ why = h->held(rep);
		if(!why.empty())
			return why;
		const ss_ text = jstr(rep, "text");
		if(text.size() >= 20){
			// The same words as several others today, counted by the
			// text's hash ([SEC_RUN5_LEFTOVERS]: not a scan of every report)
			// simplified: a calendar day (UTC), not the 24 hours before
			const ss_ key = "text/"+std::to_string(now_s() / 86400)+"/"+
					interface::sha256::hex(interface::sha256::calculate(text));
			ss_ v;
			const int same_text = index(h)->get(key, v) ? std::atoi(v.c_str()) : 0;
			index(h)->set(key, std::to_string(same_text + 1));
			if(same_text >= 3)
				return "the same text as other reports today";
		}
		return "";
	}

	// [SEC_RUN5_LEFTOVERS] What a report would otherwise scan every
	// report for: the open count, the texts' counts a day, the last sweep
	storage::Store* index(Host *h)
	{
		return h->save()->store("moderation_index");
	}
	// The open reports, changed by `delta` (the caller has stored the
	// reports' new states); counted once on a save that has no count yet
	int64_t open_count(Host *h, int64_t delta)
	{
		ss_ v;
		int64_t open = 0;
		if(index(h)->get("open", v)){
			open = std::max((int64_t)0, (int64_t)std::atoll(v.c_str()) + delta);
		} else {
			for(const ss_ &id : keys(h, "reports"))
				open += jstr(load(h, "reports", id), "state") == "open";
		}
		index(h)->set("open", std::to_string(open));
		return open;
	}
	// Once a day: held reports (spam, never in a group) gone after 30
	// days, and the texts' counts of the days before
	void sweep(Host *h)
	{
		const int64_t t = now_s(), day = t / 86400;
		ss_ v;
		if(index(h)->get("swept", v) && std::atoll(v.c_str()) == day)
			return;
		index(h)->set("swept", std::to_string(day));
		int n = 0;
		h->save()->store("reports")->batch([&](){
			for(const ss_ &id : keys(h, "reports")){
				const json::Value r = load(h, "reports", id);
				if(jstr(r, "state") == "held" && t - jint(r, "ts") > 30 * 86400){
					h->save()->store("reports")->remove(id);
					n++;
				}
			}
		});
		const ss_ today = "text/"+std::to_string(day)+"/";
		for(const ss_ &k : index(h)->list("text/"))
			if(k.compare(0, today.size(), today) != 0)
				index(h)->remove(k);
		if(n > 0)
			log_i(MODULE, "%s: %i held reports past 30 days swept",
					cs(h->name()), n);
	}

	json::Value open_group(Host *h, const ss_ &gid, const ss_ &subject,
			const ss_ &reason, const ss_ &note, const json::Value &fields)
	{
		json::Value g = json::object();
		g.set("id", gid);
		g.set("listing", subject);
		g.set("fleet", "");
		g.set("reason", reason);
		g.set("reports", json::array());
		g.set("state", "open");
		g.set("opened", now_s());
		g.set("note", note);
		g.set("weight", 0.0);
		g.set("auto", "");
		if(fields.is_object())
			for(json::Iterator it(fields); it.valid(); it.next())
				g.set(it.key(), it.value());
		put(h, "groups", gid, g);
		return g;
	}

	// The open reports' weights, the largest one per bucket
	double group_weight(Host *h, const json::Value &g)
	{
		sm_<ss_, double> buckets;
		const json::Value &reps = g.get("reports");
		for(unsigned i = 0; i < reps.size(); i++){
			const json::Value rep = load(h, "reports", reps.at(i).as_string());
			if(!rep.is_object() || jstr(rep, "state") != "open")
				continue;
			const ss_ b = h->bucket(rep);
			buckets[b] = std::max(buckets[b], jnum(rep, "weight"));
		}
		double sum = 0;
		for(auto &pair : buckets)
			sum += pair.second;
		return sum;
	}

	// Past a threshold, hidden or delisted until a moderator looks; never
	// for good, never banned
	void auto_act(Host *h, json::Value g)
	{
		const json::Value t = h->thresholds(g);
		const double w = jnum(g, "weight");
		ss_ want;
		if(w >= jnum(t, "delist", 1e9))
			want = "delist";
		else if(w >= jnum(t, "hide", 1e9))
			want = "hide";
		if(want.empty() || want == jstr(g, "auto") ||
				(want == "hide" && jstr(g, "auto") == "delist"))
			return;
		g.set("auto", want);
		put(h, "groups", jstr(g, "id"), g);
		const ss_ reason = jstr(g, "reason");
		const ss_ text = "Automatic, pending a moderator's review: reports of "
				"\""+reason+"\" weighing "+std::to_string(w).substr(0, 4)+
				" passed this instance's threshold to "+want+".";
		for(const ss_ &id : h->members(g)){
			const json::Value l = h->auto_act(g, id, want);
			if(!l.is_object())
				continue;
			audit(h, "", id, want, reason, text, true, true);
			statement(h, l, want == "delist" ? "delisted" : "hidden", reason,
					text, "");
		}
	}

	// -- The audit log and the statements of reasons

	void audit(Host *h, const ss_ &by, const ss_ &subject, const ss_ &action,
			const ss_ &reason, const ss_ &text, bool automatic, bool tell)
	{
		json::Value a = json::object();
		const int64_t t = now_s();
		a.set("ts", t);
		a.set("by", by);
		a.set("listing", subject);
		a.set("action", action);
		a.set("reason", reason);
		a.set("text", text);
		a.set("auto", automatic);
		// Sortable by time
		char key[40];
		snprintf(key, sizeof key, "%012lld-%s", (long long)t,
				random_hex(3).c_str());
		put(h, "audit", key, a);
		// The moderators see one another's decisions and the automatic ones
		if(!tell)
			return;
		const json::Value l = h->subject(subject);
		h->event({"@moderators"}, by, (by.empty() ? h->name() : by)+" "+
				action+(automatic ? " (automatic) " : " ")+
				(l.is_object() ? jstr(l, "name")+" ("+subject+")" : subject)+
				(reason.empty() ? "" : ", "+reason)+
				(text.empty() ? "" : ": "+text));
	}

	void statement(Host *h, const json::Value &l, const ss_ &action,
			const ss_ &reason, const ss_ &text, const ss_ &by)
	{
		const ss_ owner = jstr(l, "owner");
		json::Value s = json::object();
		const ss_ id = random_hex(6);
		s.set("id", id);
		s.set("ts", now_s());
		s.set("listing", jstr(l, "id"));
		s.set("listing_name", jstr(l, "name"));
		s.set("action", action);
		s.set("reason", reason);
		s.set("text", text);
		s.set("by", by);
		s.set("owner", owner);
		s.set("appeal", "Appeal once, from your account on this "+h->name()+
				"; another moderator than the one who acted decides.");
		put(h, "statements", id, s);
		if(!owner.empty())
			h->event({owner}, by, jstr(l, "name")+": "+action+", for "+reason+
					(text.empty() ? "" : ". "+text));
		h->notify(s);
		log_i(MODULE, "Statement of reasons to %s: %s %s (%s)",
				owner.empty() ? "(unclaimed)" : cs(owner), cs(jstr(l, "id")),
				cs(action), cs(reason));
	}

	// -- The moderators' commands

	json::Value queue(Host *h)
	{
		struct Item { double priority; json::Value g; };
		std::vector<Item> items;
		const int64_t t = now_s();
		for(const ss_ &id : keys(h, "groups")){
			json::Value g = load(h, "groups", id);
			if(jstr(g, "state") != "open")
				continue;
			const json::Value l = h->subject(jstr(g, "listing"));
			bool flagger = false;
			const json::Value &reps = g.get("reports");
			for(unsigned i = 0; i < reps.size(); i++)
				if(load(h, "reports", reps.at(i).as_string()).get(
						"trusted").is_true())
					flagger = true;
			// The reason's severity, the weight, a trusted flagger, how
			// long it has waited, how many it reaches
			const double p = h->severity(jstr(g, "reason")) +
					10.0 * jnum(g, "weight") + (flagger ? 50.0 : 0.0) +
					(double)(t - jint(g, "opened")) / 3600.0 +
					log(1.0 + (double)jint(l, "players"));
			g.set("priority", p);
			g.set("listing_name", jstr(l, "name"));
			g.set("count", (int64_t)reps.size());
			g.set("trusted_flagger", flagger);
			items.push_back({p, g});
		}
		std::sort(items.begin(), items.end(), [](const Item &a, const Item &b){
			return a.priority > b.priority;
		});
		json::Value out = json::array();
		for(const Item &i : items)
			out.append(i.g);
		return out;
	}

	json::Value group(Host *h, const ss_ &gid)
	{
		json::Value g = load(h, "groups", gid);
		if(!g.is_object())
			throw Exception("no such group");
		json::Value reps = json::array();
		const json::Value &ids = g.get("reports");
		for(unsigned i = 0; i < ids.size(); i++){
			json::Value rep = load(h, "reports", ids.at(i).as_string());
			if(!rep.is_object())
				continue;
			// Who reported is not shown: their key's standing is
			rep.set("key", jstr(rep, "key").substr(0, 8));
			rep.set("address", "");
			reps.append(rep);
		}
		json::Value r = json::object();
		r.set("group", g);
		r.set("reports", reps);
		json::Value hist = json::array();
		for(const ss_ &id : keys(h, "audit")){
			const json::Value a = load(h, "audit", id);
			if(jstr(a, "listing") == jstr(g, "listing"))
				hist.append(a);
		}
		r.set("history", hist);
		return r;
	}

	void decide(Host *h, const ss_ &by, const json::Value &q)
	{
		json::Value g = load(h, "groups", jstr(q, "group"));
		if(!g.is_object() || jstr(g, "state") != "open")
			throw Exception("no such open group");
		const ss_ decision = jstr(q, "decision");
		if(decision != "dismiss" && decision != "uphold")
			throw Exception("decision: dismiss or uphold");
		const ss_ reason = jstr(g, "reason");
		if(decision == "uphold")
			h->uphold(this, by, g, q);
		else for(const ss_ &id : h->members(g)){
			if(h->undo_auto(id, g))
				audit(h, by, id, "restore", reason,
						"the automatic action undone: reports dismissed", false,
						true);
			else
				audit(h, by, id, "dismiss", reason, jstr(q, "text"), false,
						true);
		}
		// The reporters' records
		const json::Value &reps = g.get("reports");
		const int64_t t = now_s();
		int64_t were_open = 0;
		for(unsigned i = 0; i < reps.size(); i++){
			json::Value rep = load(h, "reports", reps.at(i).as_string());
			if(!rep.is_object())
				continue;
			were_open += jstr(rep, "state") == "open";
			rep.set("state", decision == "uphold" ? "upheld" : "rejected");
			rep.set("outcome", decision == "uphold" ? "acted on: "+
					jstr(q, "action") : "no action");
			rep.set("decided_at", t);
			put(h, "reports", jstr(rep, "id"), rep);
			h->decided(rep, decision == "uphold");
		}
		open_count(h, -were_open);
		g.set("state", "closed");
		g.set("decided", decision);
		g.set("decided_by", by);
		g.set("decided_at", t);
		put(h, "groups", jstr(g, "id"), g);
	}

	json::Value audit_log(Host *h)
	{
		json::Value out = json::array();
		sv_<ss_> ks = keys(h, "audit");
		for(size_t i = ks.size(); i > 0 && out.size() < 300; i--)
			out.append(load(h, "audit", ks[i - 1]));
		return out;
	}

	ss_ appeal(Host *h, const ss_ &name, const json::Value &q)
	{
		const json::Value s = load(h, "statements", jstr(q, "statement"));
		if(!s.is_object() || jstr(s, "owner") != name)
			throw Exception("no such statement of yours");
		const ss_ text = jstr(q, "text");
		if(text.empty() || text.size() > 4000)
			throw Exception("say why, in at most 4000 characters");
		// One appeal a statement ([SEC_RUN4_LEFTOVERS]): a decided one
		// closes it; a new decision is a new statement
		for(const ss_ &aid : keys(h, "appeals")){
			const json::Value o = load(h, "appeals", aid);
			if(jstr(o, "statement") != jstr(s, "id"))
				continue;
			throw Exception(jstr(o, "state") == "open" ?
					"this statement has an open appeal" :
					"this statement was appealed already");
		}
		json::Value a = json::object();
		const ss_ id = random_hex(6);
		a.set("id", id);
		a.set("statement", jstr(s, "id"));
		a.set("listing", jstr(s, "listing"));
		a.set("by", name);
		a.set("acted_by", jstr(s, "by"));
		a.set("text", text);
		a.set("ts", now_s());
		a.set("state", "open");
		put(h, "appeals", id, a);
		if(!jstr(s, "by").empty())
			h->event({jstr(s, "by")}, name, name+" appealed your decision on "+
					jstr(s, "listing_name")+" ("+jstr(s, "action")+"): "+text);
		return id;
	}

	json::Value appeals(Host *h)
	{
		json::Value out = json::array();
		for(const ss_ &id : keys(h, "appeals")){
			json::Value a = load(h, "appeals", id);
			if(jstr(a, "state") != "open")
				continue;
			a.set("statement_text", load(h, "statements",
					jstr(a, "statement")));
			out.append(a);
		}
		return out;
	}

	void decide_appeal(Host *h, const ss_ &by, const json::Value &q)
	{
		json::Value a = load(h, "appeals", jstr(q, "appeal"));
		if(!a.is_object() || jstr(a, "state") != "open")
			throw Exception("no such open appeal");
		if(jstr(a, "acted_by") == by && !jstr(a, "acted_by").empty())
			throw Exception("another moderator than the one who acted decides");
		if(jstr(a, "by") == by)
			throw Exception("another moderator than the one who appealed decides");
		const ss_ outcome = jstr(q, "outcome");
		if(outcome != "reverse" && outcome != "keep")
			throw Exception("outcome: reverse or keep");
		if(outcome == "reverse")
			h->reverse(this, by, a, jstr(q, "text"));
		a.set("state", "decided");
		a.set("outcome", outcome);
		a.set("decided_by", by);
		a.set("answer", jstr(q, "text"));
		put(h, "appeals", jstr(a, "id"), a);
		const json::Value st = load(h, "statements", jstr(a, "statement"));
		const ss_ what = jstr(st, "listing_name")+" ("+jstr(st, "action")+
				"): "+(outcome == "reverse" ? "reversed" : "kept")+
				(jstr(q, "text").empty() ? "" : ". "+jstr(q, "text"));
		h->event({jstr(a, "by")}, by, "Your appeal on "+what);
		if(!jstr(a, "acted_by").empty())
			h->event({jstr(a, "acted_by")}, by, "The appeal of your decision "
					"on "+what+", by "+by);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_moderation(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
