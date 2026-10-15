// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT] stage 5: builtin/chat/api.h says what this is. Drawn out of
// vanilla's and the floorplanner's server halves: vanilla's bucket for a
// public server's lines, the floorplanner's lines kept for whoever looks.
#include "chat/api.h"
#include "accounts/api.h"
#include "moderation/api.h"
#include "network/api.h"
#include "storage/api.h"
#include "core/log.h"
#include "core/json.h"
#include "interface/event.h"
#include "interface/os.h"
#include "interface/sha256.h"
#include "interface/bignum.h"
#include <deque>
#include <map>
#include <set>
#define MODULE "chat"

using interface::Event;
using json::jstr;

namespace chat {

// A player's lines fill a bucket that empties one a second; a line into a
// full one is refused (vanilla's CHAT_BURST)
static const double BURST = 5;
static const size_t LINE_MAX = 400, KEEP = 50, REPORT_LINES = 30;
static const double REPORT_EVERY_S = 30;
static const char *MIN_NAMES[] = {"everyone", "member", "helper"};
static const int MIN_LEVELS[] = {accounts::LV_NEW, accounts::LV_MEMBER,
		accounts::LV_HELPER};

static int64_t now_s(){ return interface::os::wall_us() / 1000000; }

struct Module: public interface::Module, public Interface,
		public moderation::Host
{
	interface::Server *m_server;
	storage::Save *m_save = nullptr;
	storage::Store *m_store = nullptr;
	// Who is in, by peer: the name they joined as
	std::map<size_t, ss_> m_in;
	std::set<ss_> m_muted;
	int m_min = 0; // index into MIN_NAMES
	std::deque<ss_> m_lines;
	std::map<size_t, std::pair<double, int64_t>> m_bucket;
	std::map<size_t, int64_t> m_last_report;
	// Each peer's address, for a report's bucket
	std::map<size_t, ss_> m_address;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server)
	{}

	~Module()
	{
		if(m_save)
			storage::access(m_server, [&](storage::Interface *i){
				i->close(m_save);
			});
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		for(const char *n : {"say", "get", "set_min", "mute", "unmute",
				"report", "queue", "decide"})
			m_server->sub_event(this, Event::t(
					ss_("network:packet_received/chat:")+n));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:client_connected", on_connected,
				network::NewClient)
		EVENT_TYPEN("network:client_disconnected", on_disconnected,
				network::OldClient)
		static const ss_ PREFIX = "network:packet_received/chat:";
		for(const char *n : {"say", "get", "set_min", "mute", "unmute",
				"report", "queue", "decide"}){
			if(type == Event::t(PREFIX+n)){
				on_packet(n, *dynamic_cast<const network::Packet*>(p));
				return;
			}
		}
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}

	void on_start()
	{
		storage::access(m_server, [&](storage::Interface *i){
			m_save = i->open("_chat");
			if(!m_save)
				m_save = i->create("_chat");
		});
		if(!m_save){
			log_e(MODULE, "The save _chat cannot be opened");
			return;
		}
		m_store = m_save->store("chat");
		ss_ v;
		if(m_store->get("min", v))
			for(int i = 0; i < 3; i++)
				if(v == MIN_NAMES[i])
					m_min = i;
		for(const ss_ &key : m_store->list("mute/"))
			m_muted.insert(key.substr(5));
	}

	void send(size_t peer, const ss_ &name, const ss_ &data)
	{
		network::access(m_server, [&](network::Interface *i){
			i->send(peer, name, data);
		});
	}

	void to_all(const ss_ &line)
	{
		m_lines.push_back(line);
		while(m_lines.size() > KEEP)
			m_lines.pop_front();
		network::access(m_server, [&](network::Interface *i){
			for(auto &pair : m_in)
				i->send(pair.first, "chat:line", line);
		});
	}

	// The level a peer acts with: the launcher's own client is the admin
	// (its owner token, not an address)
	int level_of(size_t peer)
	{
		int lv = accounts::LV_NEW;
		accounts::access(m_server, [&](accounts::Interface *i){
			lv = i->is_local(peer) ? accounts::LV_ADMIN :
					i->level(i->name_of(peer));
		});
		return lv;
	}
	int level_of(const ss_ &name)
	{
		int lv = accounts::LV_NEW;
		accounts::access(m_server, [&](accounts::Interface *i){
			const accounts::PeerId peer = i->find_peer(name);
			lv = peer && i->is_local(peer) ? accounts::LV_ADMIN :
					i->level(name);
		});
		return lv;
	}

	bool may_talk(size_t peer, const ss_ &name)
	{
		const int lv = level_of(peer);
		return !m_muted.count(name) && (lv >= accounts::LV_HELPER ||
				lv >= MIN_LEVELS[m_min]);
	}

	void send_state(size_t peer)
	{
		auto it = m_in.find(peer);
		if(it == m_in.end())
			return;
		json::Value s = json::object();
		s.set("min", MIN_NAMES[m_min]);
		s.set("may_talk", may_talk(peer, it->second));
		s.set("muted", m_muted.count(it->second) != 0);
		s.set("moderator", level_of(peer) >= accounts::LV_MODERATOR);
		json::Value people = json::array();
		for(auto &pair : m_in){
			if(pair.first == peer)
				continue;
			json::Value p = json::object();
			p.set("name", pair.second);
			p.set("muted", m_muted.count(pair.second) != 0);
			people.append(p);
		}
		s.set("people", people);
		send(peer, "chat:state", s.stringify());
	}
	void send_states()
	{
		for(auto &pair : m_in)
			send_state(pair.first);
	}

	// Interface

	void join(size_t peer, const ss_ &name)
	{
		if(name.empty())
			return;
		m_in[peer] = name;
		// What was said before, for the one coming in
		for(const ss_ &line : m_lines)
			send(peer, "chat:line", line);
		send_states();
	}

	void leave(size_t peer)
	{
		if(m_in.erase(peer))
			send_states();
		m_bucket.erase(peer);
		m_last_report.erase(peer);
	}

	void say(const ss_ &line)
	{
		to_all("*** "+line);
	}

	void on_connected(const network::NewClient &e)
	{
		m_address[e.info.id] = e.info.address;
	}
	void on_disconnected(const network::OldClient &old)
	{
		leave(old.info.id);
		m_address.erase(old.info.id);
	}

	// The moderators' changes go to builtin/moderation's audit log
	void audit(const ss_ &by, const ss_ &subject, const ss_ &action,
			const ss_ &text)
	{
		moderation::access(m_server, [&](moderation::Interface *m){
			m->audit(this, by, subject, action, "", text, false, false);
		});
	}

	void set_muted(const ss_ &name, bool muted)
	{
		if(muted){
			m_muted.insert(name);
			m_store->set("mute/"+name, "1");
		} else {
			m_muted.erase(name);
			m_store->remove("mute/"+name);
		}
	}

	void on_packet(const ss_ &what, const network::Packet &packet)
	{
		auto it = m_in.find(packet.sender);
		if(it == m_in.end() || !m_store)
			return;
		const size_t peer = packet.sender;
		const ss_ name = it->second;
		const bool moderator = level_of(peer) >= accounts::LV_MODERATOR;
		if(what == "say"){
			// One line, printable, not too long
			ss_ text;
			for(char c : packet.data.substr(0, LINE_MAX))
				if((unsigned char)c >= 32 && c != 127)
					text += c;
			if(text.empty())
				return;
			if(!may_talk(peer, name)){
				const bool muted = m_muted.count(name) != 0;
				log_i(MODULE, "%s's line refused: %s", cs(name),
						muted ? "muted" : "below the minimum level");
				send(peer, "chat:line", muted ? "(A moderator has muted you.)" :
						ss_("(The chat is for ")+MIN_NAMES[m_min]+
						"s and up now.)");
				return;
			}
			const int64_t now = interface::os::time_us();
			auto &b = m_bucket[peer];
			b.first = std::max(0.0, b.first - (now - b.second) / 1e6);
			b.second = now;
			if(b.first + 1 > BURST)
				return;
			b.first += 1;
			log_i(MODULE, "<%s> %s", cs(name), cs(text));
			to_all("<"+name+"> "+text);
		} else if(what == "get"){
			send_state(peer);
		} else if(what == "set_min" && moderator){
			for(int i = 0; i < 3; i++){
				if(packet.data == MIN_NAMES[i] && i != m_min){
					m_min = i;
					m_store->set("min", MIN_NAMES[i]);
					audit(name, "chat", "chat_min", ss_("the lowest level that "
							"may talk: ")+MIN_NAMES[i]);
					log_i(MODULE, "%s: the lowest level that may talk is %s",
							cs(name), MIN_NAMES[i]);
					say(ss_("Chat is for ")+(i == 0 ? "everyone" : i == 1 ?
							"members and up" : "helpers and up")+" now");
					send_states();
				}
			}
		} else if((what == "mute" || what == "unmute") && moderator){
			const ss_ &who = packet.data;
			const bool mute = what == "mute";
			if(who.empty() || who == name || level_of(who) >= level_of(peer) ||
					(m_muted.count(who) != 0) == mute)
				return;
			set_muted(who, mute);
			audit(name, who, what, "");
			log_i(MODULE, "%s %ss %s", cs(name), cs(what), cs(who));
			send_states();
		} else if(what == "report"){
			report(peer, name, packet.data);
		} else if(what == "queue" && moderator){
			send_queue(peer);
		} else if(what == "decide" && moderator){
			const json::Value q = json::load_string(packet.data.c_str());
			const ss_ decision = jstr(q, "decision");
			json::Value d = json::object();
			d.set("group", jstr(q, "group"));
			d.set("decision", decision == "mute" ? "uphold" : "dismiss");
			d.set("action", "mute");
			d.set("text", "");
			try {
				moderation::access(m_server, [&](moderation::Interface *m){
					m->decide(this, name, d);
				});
			} catch(std::exception &e){
				log_w(MODULE, "%s's decision: %s", cs(name), e.what());
			}
			send_queue(peer);
			send_states();
		}
	}

	// A report of `who`, with the chat's last lines: one a peer each 30 s
	void report(size_t peer, const ss_ &by, const ss_ &who)
	{
		bool there = false;
		for(auto &pair : m_in)
			there = there || pair.second == who;
		const int64_t now = now_s();
		auto last = m_last_report.find(peer);
		if(!there || who == by || (last != m_last_report.end() &&
				now - last->second < REPORT_EVERY_S))
			return;
		m_last_report[peer] = now;
		ss_ text;
		const size_t from = m_lines.size() > REPORT_LINES ?
				m_lines.size() - REPORT_LINES : 0;
		for(size_t i = from; i < m_lines.size(); i++)
			text += m_lines[i]+"\n";
		const ss_ address = m_address[peer];
		json::Value rep = json::object();
		rep.set("id", interface::sha256::hex(
				interface::bignum::random_bytes(8)));
		rep.set("listing", who);
		rep.set("reason", "chat");
		rep.set("text", text);
		rep.set("key", by);
		rep.set("address", address);
		rep.set("ts", now);
		rep.set("trusted", level_of(peer) >= accounts::LV_MEMBER);
		rep.set("weight", 1.0);
		rep.set("group", who+"|chat");
		moderation::access(m_server, [&](moderation::Interface *m){
			m->add_report(this, rep, json::object());
		});
		log_i(MODULE, "%s reports %s", cs(by), cs(who));
		send(peer, "chat:line", "*** "+who+" is reported to the moderators");
		accounts::access(m_server, [&](accounts::Interface *i){
			i->notify(accounts::LV_MODERATOR, "Chat: a new report");
		});
	}

	// The open groups, each with its reports' texts and who reported
	void send_queue(size_t peer)
	{
		json::Value out = json::array();
		moderation::access(m_server, [&](moderation::Interface *m){
			const json::Value q = m->queue(this);
			for(unsigned i = 0; i < q.size(); i++){
				json::Value g = q.at(i).deepcopy();
				const json::Value d = m->group(this, jstr(g, "id"));
				g.set("reports", d.get("reports").deepcopy());
				out.append(g);
			}
		});
		send(peer, "chat:queue", out.stringify());
	}

	// moderation::Host: a subject is a player's name

	storage::Save* save(){ return m_save; }
	ss_ name(){ return "Chat"; }
	json::Value subject(const ss_ &id)
	{
		json::Value s = json::object();
		s.set("id", id);
		s.set("name", id);
		s.set("owner", id);
		s.set("players", 1);
		return s;
	}
	sv_<ss_> members(const json::Value &group)
	{
		return {jstr(group, "listing")};
	}
	int severity(const ss_ &reason){ return 1; }
	json::Value thresholds(const json::Value &group){ return json::object(); }
	ss_ held(const json::Value &report){ return ""; }
	ss_ bucket(const json::Value &report){ return jstr(report, "key"); }
	json::Value auto_act(const json::Value &group, const ss_ &id,
			const ss_ &want)
	{
		return json::Value();
	}
	void uphold(moderation::Interface *m, const ss_ &by,
			const json::Value &group, const json::Value &q)
	{
		const ss_ who = jstr(group, "listing");
		set_muted(who, true);
		m->audit(this, by, who, "mute", "chat", "upheld a report", false,
				false);
		log_i(MODULE, "%s mutes %s, upholding a report", cs(by), cs(who));
	}
	bool undo_auto(const ss_ &id, const json::Value &group){ return false; }
	void reverse(moderation::Interface *m, const ss_ &by,
			const json::Value &appeal, const ss_ &text)
	{
		set_muted(jstr(appeal, "listing"), false);
	}
	void decided(const json::Value &report, bool upheld){}
	// simplified: no events or statements to the players; the moderators
	// get a push of a new report (accounts' notify)
	void event(const sv_<ss_> &to, const ss_ &by, const ss_ &text){}
	void notify(const json::Value &statement){}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_chat(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
