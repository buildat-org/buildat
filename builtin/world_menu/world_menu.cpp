// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [WORLD_MENU]: builtin/world_menu/api.h says what this is. Drawn out of
// skeldat's and skelenti's world dialogs, which were one dialog twice.
#include "world_menu/api.h"
#include "accounts/api.h"
#include "network/api.h"
#include "storage/api.h"
#include "core/log.h"
#include "core/json.h"
#include <algorithm>
#include <set>
#define MODULE "world_menu"

using json::jstr;

namespace world_menu {

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;
	Config m_config;
	std::vector<Preset> m_presets;
	bool m_running = false;
	// The running world's name while a picker has the menu in it
	ss_ m_running_name;
	ss_ m_progress;
	// Who has the client half, and who has the menu up
	std::set<PeerId> m_scripted, m_shown;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server)
	{}

	void init()
	{
		sub(m_server, "network:client_disconnected", &Module::on_disconnected);
		// [WORLD_MENU_ADMIN] Who may pick follows the account
		sub(m_server, "accounts:login", &Module::on_account);
		sub(m_server, "accounts:privs", &Module::on_account);
		typedef void (Module::*Handler)(const network::Packet&);
		static const std::pair<const char*, Handler> PACKETS[] = {
			{"get", &Module::on_get},
			{"play", &Module::on_play},
			{"create", &Module::on_create},
			{"rename", &Module::on_rename},
			{"delete", &Module::on_delete},
			{"close", &Module::on_close},
		};
		for(const auto &packet : PACKETS)
			sub(m_server, ss_("network:packet_received/world_menu:")+
					packet.first, packet.second);
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}

	void configure(const Config &config)
	{
		m_config = config;
	}

	void show(PeerId peer)
	{
		if(m_scripted.insert(peer).second)
			network::send(m_server, peer, "core:run_script",
					"require(\"buildat/module/world_menu\")");
		m_shown.insert(peer);
		send_list(peer);
	}

	void set_presets(const std::vector<Preset> &presets)
	{
		m_presets = presets;
		for(PeerId peer : m_shown)
			send_list(peer);
	}

	void progress(const ss_ &text)
	{
		m_progress = text;
		for(PeerId peer : m_shown)
			send_list(peer);
	}

	void show_running(PeerId peer, const ss_ &running)
	{
		m_running_name = running;
		show(peer);
	}

	bool is_picker(PeerId peer)
	{
		return picker(peer);
	}

	void set_running(bool running)
	{
		m_running = running;
		m_running_name.clear();
		m_progress.clear();
		if(!running)
			return;
		for(PeerId peer : m_shown)
			network::send(m_server, peer, "world_menu:up", "");
		m_shown.clear();
	}

	void on_disconnected(const network::OldClient &event)
	{
		m_scripted.erase(event.info.id);
		m_shown.erase(event.info.id);
	}

	// To every menu up: the peer's own may now pick, and the rest's wait
	// text depends on whether there is an admin
	void on_account(const accounts::Login &)
	{
		for(PeerId peer : m_shown)
			send_list(peer);
	}

	// [WORLD_MENU_ADMIN] Who picks the world: the launcher's own client
	// on the launcher's server, and an admin's account on any (a public
	// server has no launcher's client)
	bool picker(PeerId peer)
	{
		bool ok = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			const ss_ name = i->name_of(peer);
			ok = i->is_local(peer) || (!name.empty() && i->is_admin(name));
		});
		return ok;
	}

	// Whether any account is an admin: none, and the setup code's join is
	// the way to be one
	bool any_admin()
	{
		bool any = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			for(const ss_ &name : i->account_names())
				if(i->is_admin(name)){
					any = true;
					return;
				}
		});
		return any;
	}

	// Only to a menu that is up, before a world runs or shown in it, from
	// the launcher's own client or an admin (picker())
	bool open() const
	{
		return (!m_running || !m_running_name.empty()) && m_progress.empty();
	}
	bool may_pick(const network::Packet &packet)
	{
		if(!open() ||
				!m_shown.count(packet.sender) || !picker(packet.sender)){
			log_w(MODULE, "%s from peer %zu ignored", cs(packet.name),
					packet.sender);
			return false;
		}
		return true;
	}

	static bool is_world(storage::Interface *i, const ss_ &name)
	{
		return i->valid_name(name) && name[0] != '_';
	}

	static bool exists(storage::Interface *i, const ss_ &name)
	{
		for(const storage::SaveInfo &info : i->list())
			if(info.name == name)
				return true;
		return false;
	}

	void send_list(PeerId peer, const ss_ &note = "")
	{
		json::Value out = json::object();
		out.set("title", m_config.title);
		const bool pick = open() && picker(peer);
		out.set("running", m_running ? m_running_name : ss_());
		out.set("note", note);
		out.set("may_pick", pick);
		if(!pick)
			out.set("no_admin", !any_admin());
		out.set("wait", m_progress);
		json::Value fields = json::array();
		for(const Field &f : m_config.fields){
			json::Value v = json::object();
			v.set("key", f.key);
			v.set("label", f.label);
			v.set("default", f.def);
			v.set("hint", f.hint);
			v.set("ask", !f.show_only);
			json::Value choices = json::array();
			for(const auto &c : f.choices){
				json::Value pair = json::array();
				pair.append(c.first);
				pair.append(c.second);
				choices.append(pair);
			}
			v.set("choices", choices);
			fields.append(v);
		}
		out.set("fields", fields);
		json::Value presets = json::array();
		for(const Preset &p : m_presets){
			json::Value v = json::object();
			v.set("label", p.label);
			json::Value options = json::object();
			for(const auto &o : p.options)
				options.set(o.first, o.second);
			v.set("options", options);
			presets.append(v);
		}
		out.set("presets", presets);
		json::Value worlds = json::array();
		if(pick){
			storage::access(m_server, [&](storage::Interface *i){
				sv_<storage::SaveInfo> infos = i->list();
				// The one played last is the one most likely wanted next
				std::sort(infos.begin(), infos.end(),
						[](const storage::SaveInfo &a,
						const storage::SaveInfo &b){
					return a.modified_us > b.modified_us;
				});
				for(const storage::SaveInfo &info : infos){
					if(!is_world(i, info.name))
						continue;
					json::Value w = json::object();
					w.set("name", info.name);
					w.set("bytes", (int64_t)info.bytes);
					json::Value options = json::object();
					storage::Save *save = i->open(info.name);
					if(save){
						storage::Store *s = save->store("world_menu");
						ss_ v;
						for(const Field &f : m_config.fields)
							if(s->get(f.key, v))
								options.set(f.key, v);
						i->close(save);
					}
					w.set("options", options);
					worlds.append(w);
				}
			});
		}
		out.set("worlds", worlds);
		network::send(m_server, peer, "world_menu:list", out.stringify());
	}

	static json::Value read(const network::Packet &packet)
	{
		const json::Value v = json::load_string(packet.data.c_str());
		return v.is_object() ? v : json::object();
	}

	void on_get(const network::Packet &packet)
	{
		if(m_shown.count(packet.sender))
			send_list(packet.sender);
	}

	void on_play(const network::Packet &packet)
	{
		if(!may_pick(packet))
			return;
		const ss_ name = jstr(read(packet), "name");
		bool ok = false;
		storage::access(m_server, [&](storage::Interface *i){
			ok = is_world(i, name) && exists(i, name);
		});
		if(!ok){
			send_list(packet.sender);
			return;
		}
		if(m_running && name == m_running_name){
			// The running one: the menu closes
			m_shown.erase(packet.sender);
			network::send(m_server, packet.sender, "world_menu:up", "");
			return;
		}
		log_i(MODULE, "world_menu: play \"%s\"", cs(name));
		m_server->emit_event("world_menu:play",
				new Play(packet.sender, name, false, {}));
	}

	void on_create(const network::Packet &packet)
	{
		if(!may_pick(packet))
			return;
		const json::Value v = read(packet);
		const ss_ name = jstr(v, "name");
		// The app's own fields only, each a short string
		std::map<ss_, ss_> options;
		const json::Value &o = v.get("options");
		for(const Field &f : m_config.fields){
			if(f.show_only)
				continue;
			ss_ value = o.is_object() ? jstr(o, f.key.c_str()) : "";
			// A choice's value or the first's
			if(!f.choices.empty() && std::none_of(f.choices.begin(),
					f.choices.end(), [&](const std::pair<ss_, ss_> &c){
						return c.first == value; }))
				value = f.choices[0].first;
			if(!value.empty() && value.size() <= 200)
				options[f.key] = value;
		}
		bool ok = false;
		storage::access(m_server, [&](storage::Interface *i){
			if(!is_world(i, name) || exists(i, name))
				return;
			storage::Save *save = i->create(name);
			if(!save)
				return;
			storage::Store *s = save->store("world_menu");
			for(const auto &pair : options)
				s->set(pair.first, pair.second);
			i->close(save);
			ok = true;
		});
		if(!ok){
			log_w(MODULE, "world_menu: \"%s\" not made", cs(name));
			send_list(packet.sender);
			return;
		}
		log_i(MODULE, "world_menu: made \"%s\"", cs(name));
		m_server->emit_event("world_menu:play",
				new Play(packet.sender, name, true, options));
	}

	void on_rename(const network::Packet &packet)
	{
		if(!may_pick(packet))
			return;
		const json::Value v = read(packet);
		const ss_ name = jstr(v, "name"), to = jstr(v, "to");
		if(refused_running(packet, name) || refused_running(packet, to))
			return;
		storage::access(m_server, [&](storage::Interface *i){
			if(is_world(i, name) && is_world(i, to) && i->rename(name, to))
				log_i(MODULE, "world_menu: \"%s\" renamed \"%s\"", cs(name),
						cs(to));
		});
		send_list(packet.sender);
	}

	// The running world is not renamed or deleted: said in the menu
	bool refused_running(const network::Packet &packet, const ss_ &name)
	{
		if(!m_running || name != m_running_name)
			return false;
		log_w(MODULE, "world_menu: %s of the running world \"%s\" refused",
				cs(packet.name), cs(name));
		send_list(packet.sender, "The running world can't be renamed or "
				"deleted");
		return true;
	}

	void on_close(const network::Packet &packet)
	{
		if(!may_pick(packet) || !m_running)
			return;
		log_i(MODULE, "world_menu: close \"%s\"", cs(m_running_name));
		m_shown.erase(packet.sender);
		m_server->emit_event("world_menu:close", new Close(packet.sender));
	}

	void on_delete(const network::Packet &packet)
	{
		if(!may_pick(packet))
			return;
		const ss_ name = jstr(read(packet), "name");
		if(refused_running(packet, name))
			return;
		storage::access(m_server, [&](storage::Interface *i){
			if(is_world(i, name) && exists(i, name)){
				log_i(MODULE, "world_menu: \"%s\" deleted", cs(name));
				i->remove(name);
			}
		});
		send_list(packet.sender);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_world_menu(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
