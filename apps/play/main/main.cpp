// [PLAY_PAGE] play.buildat.org: a server that serves the web client and
// has no game of its own. The page starts on the launch menu, which joins
// any server in place, so the client code is from this one origin
// ([WEB_ID_TRUST] (d)). Run as any app, the web client where the release
// archive puts it ([PLAY_OOTB]: the network module serves its page with
// the server line null):
//   buildat_server -m apps/play
// behind a TLS proxy, and the origin in each Starport's web_clients.
//
// **The Luanti bridge** ((c)): a browser has no UDP, so the page's
// luanti_client sends its datagrams as the messages of a WebSocket to
// /luanti?to=host:port, and this sends them on from one UDP socket per
// WebSocket. Only to an address on the last fetch of Luanti's server list
// (BUILDAT_LUANTI_LIST overrides https://servers.luanti.org) -- or this
// machine's own, for a page on it ([WEB_LUANTI_JOIN]) -- only from this
// server's own page, and capped per client so that it is not an open UDP
// relay. A refusal closes the WebSocket with the reason, which the page
// shows. Every web player reaches a Luanti server from this server's
// address: a ban there bans all of them (the user's call, 2026-10-04).
#include "core/log.h"
#include "core/json.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/http.h"
#include "network/api.h"
#include <atomic>
#include <condition_variable>
#include <cstdlib>
#include <mutex>
#include <set>
#include <thread>
#ifdef _WIN32
	#include "ports/windows_sockets.h"
#else
	#include <sys/socket.h>
	#include <netdb.h>
	#include <fcntl.h>
	#include <unistd.h>
#endif
#define MODULE "main"

using interface::Event;

namespace play {

static const size_t MAX_BRIDGES = 256;
static const size_t MAX_PER_ADDRESS = 4;
// Both ways, for one WebSocket: a game's media is tens of megabytes
static const size_t MAX_BYTES = 512u * 1024 * 1024;
static const int64_t LIST_EVERY_S = 600;

struct Bridge {
	int fd = -1;
	ss_ address; // the player's
	size_t bytes = 0;
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	sm_<network::PeerId, Bridge> m_bridges;
	// "host:port" of the last fetch of the list, the host lowercased
	std::set<ss_> m_allowed;
	std::mutex m_mutex;
	std::condition_variable m_wake;
	// Atomic as http_get reads it: the stop joins m_fetcher, which a list
	// that does not answer held up to two minutes ([STARPORT_SHUTDOWN_WAL])
	std::atomic<bool> m_stop{false};
	up_<std::set<ss_>> m_fetched; // the fetcher's, taken on a tick
	std::thread m_fetcher;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		{
			std::lock_guard<std::mutex> lock(m_mutex);
			m_stop = true;
		}
		m_wake.notify_all();
		if(m_fetcher.joinable())
			m_fetcher.join();
		for(auto &b : m_bridges)
			close_fd(b.second.fd);
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("network:ws_open"));
		m_server->sub_event(this, Event::t("network:ws_message"));
		m_server->sub_event(this, Event::t("network:ws_closed"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("network:ws_open", on_open, network::HttpRequest)
		EVENT_TYPEN("network:ws_message", on_message, network::Packet)
		EVENT_TYPEN("network:ws_closed", on_closed, network::OldClient)
	}

	static void close_fd(int fd)
	{
#ifdef _WIN32
		closesocket(fd);
#else
		close(fd);
#endif
	}

	void on_start()
	{
		network::access(m_server, [&](network::Interface *i){
			i->claim_ws_path("/luanti");
			i->set_page_has_no_game();
		});
		m_fetcher = std::thread([this](){ fetcher(); });
	}

	static ss_ lower(ss_ s)
	{
		for(char &c : s)
			c = tolower((unsigned char)c);
		return s;
	}

	void fetcher()
	{
		const char *env = getenv("BUILDAT_LUANTI_LIST");
		const ss_ url = ss_(env && *env ? env : "https://servers.luanti.org")+
				"/list";
		for(;;){
			up_<std::set<ss_>> got(new std::set<ss_>());
			try {
				const json::Value v = json::load_string(
						interface::http_get(url, nullptr, &m_stop).c_str());
				const json::Value &l = v.get("list");
				for(unsigned i = 0; l.is_array() && i < l.size(); i++){
					const json::Value &s = l.at(i);
					if(s.get("address").is_string() && s.get("port").is_number())
						got->insert(lower(s.get("address").as_string())+":"+
								itos((int64_t)s.get("port").as_number()));
				}
				log_i(MODULE, "Luanti's list: %zu servers the bridge reaches",
						got->size());
			} catch(std::exception &e){
				log_w(MODULE, "Luanti's list from %s: %s", cs(url), e.what());
				got.reset();
			}
			std::unique_lock<std::mutex> lock(m_mutex);
			const bool ok = (bool)got;
			if(got)
				m_fetched = std::move(got);
			if(m_wake.wait_for(lock, std::chrono::seconds(ok ? LIST_EVERY_S :
					30), [this](){ return m_stop.load(); }))
				return;
		}
	}

	// tell: what the page shows; "" is the reason as logged
	void refuse(network::PeerId peer, const char *why, const ss_ &what,
			const ss_ &tell = "")
	{
		log_i(MODULE, "Bridge refused for peer %zu: %s (%s)", peer, why,
				cs(what));
		network::access(m_server, [&](network::Interface *i){
			i->ws_close(peer, tell.empty() ? ss_(why) : tell);
		});
	}

	void on_open(const network::HttpRequest &r)
	{
		// This server's own page only, also behind the proxy, which the
		// network module lets any page's WebSocket through
		const size_t s = r.origin.find("://");
		if(s == ss_::npos || lower(r.origin.substr(s + 3)) != lower(r.host))
			return refuse(r.peer, "not from this server's page", r.origin);
		if(r.query.compare(0, 3, "to=") != 0)
			return refuse(r.peer, "no to=", r.query);
		const ss_ to = lower(r.query.substr(3));
		const size_t colon = to.rfind(':');
		// simplified: a name or an IPv4 address; an IPv6 one is refused
		if(colon == ss_::npos || to.find_first_not_of(
				"abcdefghijklmnopqrstuvwxyz0123456789.-:") != ss_::npos)
			return refuse(r.peer, "not host:port", to);
		// **A local page reaches this machine's own servers**
		// ([WEB_LUANTI_JOIN]): asked for as localhost or 127.0.0.1, by a
		// browser on this machine. Host alone is the request's say; the
		// address is the socket's, or behind the trusted proxy the client
		// it names, so a public page's visitor is never loopback.
		// simplified: a trusted proxy on this machine that sets no
		// X-Forwarded-For makes every visitor loopback; the proxy sets it
		const ss_ to_host = to.substr(0, colon);
		const ss_ page_host = lower(r.host.substr(0, r.host.rfind(':')));
		const bool local = (to_host == "localhost" || to_host == "127.0.0.1") &&
				(page_host == "localhost" || page_host == "127.0.0.1") &&
				r.address.compare(0, 4, "127.") == 0;
		if(!local && !m_allowed.count(to))
			return refuse(r.peer, "not on Luanti's list", to,
					"this page reaches only the servers on Luanti's public "
					"list (and this machine's, from a page on it)");
		if(m_bridges.size() >= MAX_BRIDGES)
			return refuse(r.peer, "full", to);
		size_t mine = 0;
		for(auto &b : m_bridges)
			mine += b.second.address == r.address;
		if(mine >= MAX_PER_ADDRESS)
			return refuse(r.peer, "too many from one address", r.address);
		// simplified: resolved on the server's thread, which has nothing
		// else to do here; a slow DNS holds the other bridges for its time
		struct addrinfo hints = {}, *res = nullptr;
		hints.ai_family = AF_INET;
		hints.ai_socktype = SOCK_DGRAM;
		if(getaddrinfo(to.substr(0, colon).c_str(), to.substr(colon + 1).c_str(),
				&hints, &res) != 0 || !res)
			return refuse(r.peer, "cannot resolve", to);
		// **Only a public address, but for a local page**: the list names
		// a server by a name its owner controls, which may point here or
		// into this network by the time it is joined
		if(!local){
			const uint32_t a = ntohl(((struct sockaddr_in*)res->ai_addr)->
					sin_addr.s_addr);
			const bool private_ = (a >> 24) == 0 || (a >> 24) == 10 ||
					(a >> 24) == 127 || (a >> 16) == 0xa9fe ||
					(a >> 20) == 0xac1 || (a >> 16) == 0xc0a8 ||
					(a >> 22) == (100 << 2 | 1) || (a >> 28) >= 0xe;
			if(private_){
				freeaddrinfo(res);
				return refuse(r.peer, "not a public address", to);
			}
		}
		int fd = socket(res->ai_family, SOCK_DGRAM, 0);
		// What a server sends between two ticks waits here: a media burst
		// overflowed the default (~200 KiB) and each loss stalls Luanti's
		// reliable channel until it is resent ([WEB_LUANTI_JOIN])
		int rcvbuf = 4 * 1024 * 1024;
		if(fd >= 0)
			setsockopt(fd, SOL_SOCKET, SO_RCVBUF, (const char*)&rcvbuf,
					sizeof rcvbuf);
		bool ok = fd >= 0 && connect(fd, res->ai_addr, res->ai_addrlen) == 0;
		freeaddrinfo(res);
#ifdef _WIN32
		u_long nb = 1;
		ok = ok && ioctlsocket(fd, FIONBIO, &nb) == 0;
#else
		ok = ok && fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0;
#endif
		if(!ok){
			if(fd >= 0)
				close_fd(fd);
			return refuse(r.peer, "no socket", to);
		}
		Bridge &b = m_bridges[r.peer];
		b.fd = fd;
		b.address = r.address;
		log_i(MODULE, "Bridge for %s (peer %zu) to %s", cs(r.address), r.peer,
				cs(to));
	}

	bool count(network::PeerId peer, Bridge &b, size_t n)
	{
		b.bytes += n;
		if(b.bytes <= MAX_BYTES)
			return true;
		refuse(peer, "over its bytes", itos((int64_t)b.bytes));
		close_fd(b.fd);
		m_bridges.erase(peer);
		return false;
	}

	void on_message(const network::Packet &p)
	{
		auto it = m_bridges.find(p.sender);
		if(it == m_bridges.end() || p.data.empty() || p.data.size() > 65507)
			return;
		if(count(p.sender, it->second, p.data.size()))
			::send(it->second.fd, p.data.data(), p.data.size(), 0);
	}

	void on_closed(const network::OldClient &c)
	{
		auto it = m_bridges.find(c.info.id);
		if(it == m_bridges.end())
			return;
		close_fd(it->second.fd);
		m_bridges.erase(it);
	}

	// simplified: the UDP sockets are read on the tick, so a datagram waits
	// a tick at most; a thread of their own when that shows in a game
	void on_tick(const interface::TickEvent &)
	{
		{
			std::lock_guard<std::mutex> lock(m_mutex);
			if(m_fetched){
				m_allowed = std::move(*m_fetched);
				m_fetched.reset();
			}
		}
		sv_<std::pair<network::PeerId, ss_>> out;
		static char buf[65536];
		for(auto it = m_bridges.begin(); it != m_bridges.end();){
			auto next = std::next(it);
			for(;;){
				const auto n = recv(it->second.fd, buf, sizeof buf, 0);
				if(n <= 0)
					break;
				out.emplace_back(it->first, ss_(buf, n));
				if(!count(it->first, it->second, n))
					break;
			}
			it = next;
		}
		if(out.empty())
			return;
		network::access(m_server, [&](network::Interface *i){
			for(auto &o : out)
				i->ws_send(o.first, o.second);
		});
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
