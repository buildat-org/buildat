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
	bool m_running = false;
	ss_ m_progress;
	// Who has the client half, and who has the menu up
	std::set<PeerId> m_scripted, m_shown;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server)
	{}

	void init()
	{
		sub(m_server, "network:client_disconnected", &Module::on_disconnected);
		typedef void (Module::*Handler)(const network::Packet&);
		static const std::pair<const char*, Handler> PACKETS[] = {
			{"get", &Module::on_get},
			{"play", &Module::on_play},
			{"create", &Module::on_create},
			{"rename", &Module::on_rename},
			{"delete", &Module::on_delete},
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

	void progress(const ss_ &text)
	{
		m_progress = text;
		for(PeerId peer : m_shown)
			send_list(peer);
	}

	void set_running(bool running)
	{
		m_running = running;
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

	bool is_local(PeerId peer)
	{
		bool local = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			local = i->is_local(peer);
		});
		return local;
	}

	// Only to a menu that is up, before a world runs, from the launcher's
	// own client
	bool may_pick(const network::Packet &packet)
	{
		if(m_running || !m_progress.empty() ||
				!m_shown.count(packet.sender) || !is_local(packet.sender)){
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

	void send_list(PeerId peer)
	{
		json::Value out = json::object();
		out.set("title", m_config.title);
		const bool pick = !m_running && m_progress.empty() && is_local(peer);
		out.set("may_pick", pick);
		out.set("wait", m_progress);
		json::Value fields = json::array();
		for(const Field &f : m_config.fields){
			json::Value v = json::object();
			v.set("key", f.key);
			v.set("label", f.label);
			v.set("default", f.def);
			v.set("hint", f.hint);
			fields.append(v);
		}
		out.set("fields", fields);
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
			const ss_ value = o.is_object() ? jstr(o, f.key.c_str()) : "";
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
		storage::access(m_server, [&](storage::Interface *i){
			if(is_world(i, name) && is_world(i, to) && i->rename(name, to))
				log_i(MODULE, "world_menu: \"%s\" renamed \"%s\"", cs(name),
						cs(to));
		});
		send_list(packet.sender);
	}

	void on_delete(const network::Packet &packet)
	{
		if(!may_pick(packet))
			return;
		const ss_ name = jstr(read(packet), "name");
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
