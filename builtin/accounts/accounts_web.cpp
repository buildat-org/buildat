// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// accounts in the server built for the web ([WEB_LOCAL_SERVER]), in place of
// accounts.cpp: a server in a page has one player, the page's own, who is
// the admin. util/web_server.cmake builds this one; the native server never
// does.
//
// **Who is the player**: the first peer to connect, while it stays. Every
// peer here comes through the web network module, which lets in only the
// page's own client; the slot is held so that a second connection, if one
// ever came, is never local and never joins. The name is the one the first
// join gave, kept in the app's save "_server", store "accounts"; each later
// join is that name whatever was typed. [WEB_LOCAL_PLAYER_NAME] A page
// names its player (BUILDAT_LOCAL_NAME, src/server/web/pre.js): that name,
// kept over the one before, and the page's client is in as it at once,
// with no join (an app started by the launcher names a peer with no name
// "client<peer>").
// simplified: no passwords, invites, bans, levels below the admin, guests
// or Starport IDs; the requests for them are refused or go unanswered
#include "accounts/api.h"
#include "accounts/wire.h"
#include "network/api.h"
#include "storage/api.h"
#include "core/log.h"
#include "core/version.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include <cereal/types/utility.hpp>
#include <cstdlib>
#define MODULE "accounts"

using interface::Event;
using storage::pack;
using storage::unpack;

namespace accounts {

static const char *REFUSED = "There are no accounts in a server in a browser";

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;
	storage::Store *m_store = nullptr;
	ss_ m_name;
	PeerId m_local = 0;
	bool m_joined = false;
	bool m_page_named = false;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		for(const char *name : {"accounts:get_hello", "accounts:login",
				"accounts:logout", "accounts:open_lan"})
			m_server->sub_event(this,
					Event::t(ss_("network:packet_received/")+name));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("network:packet_received/accounts:get_hello",
				on_get_hello, network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:login", on_login,
				network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:logout", on_logout,
				network::Packet)
		EVENT_TYPEN("network:packet_received/accounts:open_lan", on_open_lan,
				network::Packet)
	}

	void on_start()
	{
		storage::Save *save = nullptr;
		storage::access(m_server, [&](storage::Interface *istorage){
			save = istorage->open("_server");
			if(!save)
				save = istorage->create("_server");
		});
		if(!save){
			m_server->shutdown(1, "accounts: no server store");
			return;
		}
		m_store = save->store("accounts");
		m_store->get("local_name", m_name);
		const char *page = getenv("BUILDAT_LOCAL_NAME");
		if(page && valid_name(page)){
			m_page_named = true;
			if(m_name != page){
				m_name = page;
				m_store->set("local_name", m_name);
			}
		}
		log_i(MODULE, "accounts: the web server's: one player, %s, the admin",
				m_name.empty() ? "named at the first join" : cs(m_name));
	}

	void send(PeerId peer, const ss_ &name, const ss_ &data)
	{
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, name, data);
		});
	}

	void on_client_connected(const network::NewClient &client)
	{
		if(m_local == 0){
			m_local = client.info.id;
			if(m_page_named){
				m_joined = true;
				log_i(MODULE, "%s is in, the page's player and the admin",
						cs(m_name));
			}
			return;
		}
		log_w(MODULE, "Peer %i connected while peer %i is the player: it "
				"does not join", (int)client.info.id, (int)m_local);
	}

	void on_client_disconnected(const network::OldClient &client)
	{
		if(client.info.id != m_local)
			return;
		m_local = 0;
		m_joined = false;
	}

	void on_get_hello(const network::Packet &packet)
	{
		Hello h;
		h.local = packet.sender == m_local ? 1 : 0;
		h.version = ss_(BUILDAT_VERSION) + "-" + BUILDAT_GIT_HASH;
		send(packet.sender, "accounts:hello", pack(h));
	}

	void on_login(const network::Packet &packet)
	{
		LoginRequest cred;
		auto reply = [&](const ss_ &error){
			send(packet.sender, "accounts:login_result",
					pack(std::make_pair(std::make_pair(error, ss_()),
					error.empty() ? m_name : ss_())));
		};
		if(packet.sender != m_local)
			return reply("This server has one player, who is here");
		if(m_joined)
			return reply("Already joined");
		if(!m_store)
			return reply("No server store");
		if(!unpack(packet.data, cred))
			return reply("Malformed login");
		if(m_name.empty()){
			if(!valid_name(cred.name))
				return reply("A name is 1 to 20 letters, digits, - and _");
			m_name = cred.name;
			m_store->set("local_name", m_name);
		}
		m_joined = true;
		log_i(MODULE, "%s joined, the admin", cs(m_name));
		reply("");
		m_server->emit_event("accounts:login", new Login(m_local, m_name));
	}

	void on_logout(const network::Packet &packet)
	{
		if(packet.sender == m_local)
			send(packet.sender, "accounts:logged_out", "");
	}

	void on_open_lan(const network::Packet &packet)
	{
		send(packet.sender, "accounts:lan",
				"a server in a browser is on no network");
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}

	// The interface

	bool joined(PeerId peer){ return m_joined && peer == m_local; }
	bool is_player(const ss_ &name){ return !m_name.empty() && name == m_name; }

	ss_ name_of(PeerId peer){ return joined(peer) ? m_name : ss_(); }
	PeerId find_peer(const ss_ &name)
	{
		return m_joined && is_player(name) ? m_local : 0;
	}
	sv_<PeerId> find_peers(const ss_ &name)
	{
		const PeerId p = find_peer(name);
		return p ? sv_<PeerId>{p} : sv_<PeerId>{};
	}
	void set_multiple_logins(bool on){}
	void set_guests(bool on){}
	ss_ address_of(PeerId peer){ return ""; }
	bool is_admin(const ss_ &name){ return is_player(name); }
	bool exists(const ss_ &name){ return is_player(name); }
	bool check_kept(const ss_ &name, const ss_ &token){ return false; }
	sv_<ss_> account_names()
	{
		return m_name.empty() ? sv_<ss_>{} : sv_<ss_>{m_name};
	}
	bool is_local(PeerId peer){ return peer != 0 && peer == m_local; }
	bool launched(){ return true; }
	void set_lan_name(const ss_ &name, bool account){}
	void kick(PeerId peer, const ss_ &why)
	{
		log_i(MODULE, "Peer %i kicked: %s", (int)peer, cs(why));
		send(peer, "accounts:kicked", pack(why));
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->disconnect(peer);
		});
	}
	ss_ ban(const ss_ &name, const ss_ &by, int64_t until, const ss_ &reason)
	{
		return REFUSED;
	}
	ss_ unban(const ss_ &name_or_address, const ss_ &only_by){ return REFUSED; }
	sv_<ss_> ban_list(){ return {}; }
	ss_ create_account(const ss_ &name, const ss_ &password){ return REFUSED; }
	bool check_password(const ss_ &name, const ss_ &password){ return false; }
	ss_ set_password(const ss_ &name, const ss_ &password){ return REFUSED; }
	ss_ delete_account(const ss_ &name){ return REFUSED; }
	bool totp_on(const ss_ &name){ return false; }
	bool check_totp(const ss_ &name, const ss_ &code){ return false; }
	ss_ totp_begin(const ss_ &name){ return ""; }
	ss_ totp_confirm(const ss_ &name, const ss_ &code){ return REFUSED; }
	ss_ totp_off(const ss_ &name, const ss_ &code){ return REFUSED; }
	ss_ totp_uri(const ss_ &name, const ss_ &secret_base32){ return ""; }
	sv_<ss_> reported_bans(){ return {}; }
	bool registration_open(){ return false; }
	size_t linked_count(const ss_ &host){ return 0; }
	bool can_mail(){ return false; }
	void mail(const ss_ &to, const ss_ &subject, const ss_ &text,
			std::function<void(const ss_ &error)> done)
	{
		done("a server in a browser sends no mail");
	}
	int level(const ss_ &name){ return is_player(name) ? LV_ADMIN : LV_NEW; }
	ss_ set_level(const ss_ &name, int lv, const ss_ &by){ return REFUSED; }
	void report_storage(const ss_ &app,
			const std::map<ss_, uint64_t> &bytes){}
	uint64_t storage_budget(){ return 2048ull * 1024 * 1024; }
	void notify(int min_level, const ss_ &text, const ss_ &link){}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_accounts(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
