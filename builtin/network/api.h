// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include "interface/web_brand.h"
#include "interface/server_config.h"
#include "interface/sha256.h"
#include "interface/os.h"
#include "core/json.h"
#include <functional>
#include <cstdint>

namespace network
{
	typedef size_t PeerId;

	// The block an address is counted in for a limit against floods:
	// IPv4 by /24 ("1.2.3.0/24", an IPv4-mapped one too), IPv6 by /64
	// ("2001:db8:0:1::/64"), or by v6_groups groups of it (3: a /48, one
	// network); anything else as it is
	inline ss_ address_bin(ss_ a, int v6_groups = 4)
	{
		const size_t zone = a.find('%');
		if(zone != ss_::npos)
			a.resize(zone);
		if(a.find('.') != ss_::npos){
			const size_t colon = a.find_last_of(':');
			if(colon != ss_::npos)
				a = a.substr(colon + 1);
			const size_t dot = a.find_last_of('.');
			return a.substr(0, dot)+".0/24";
		}
		if(a.find(':') == ss_::npos)
			return a;
		// The groups before "::" and after it, "::" being zeros between
		const size_t dc = a.find("::");
		const ss_ head = dc == ss_::npos ? a : a.substr(0, dc);
		const ss_ tail = dc == ss_::npos ? ss_() : a.substr(dc + 2);
		auto split = [](const ss_ &s){
			sv_<ss_> out;
			size_t at = 0;
			while(!s.empty() && at <= s.size()){
				size_t c = s.find(':', at);
				if(c == ss_::npos)
					c = s.size();
				out.push_back(s.substr(at, c - at));
				at = c + 1;
			}
			return out;
		};
		sv_<ss_> g = split(head);
		const sv_<ss_> t = split(tail);
		while(g.size() + t.size() < 8)
			g.push_back("0");
		g.insert(g.end(), t.begin(), t.end());
		ss_ out;
		for(size_t i = 0; i < (size_t)v6_groups && i < g.size(); i++){
			ss_ x = g[i];
			for(char &c : x)
				c = tolower((unsigned char)c);
			while(x.size() > 1 && x[0] == '0')
				x.erase(0, 1);
			out += x+":";
		}
		return out+":/"+itos(16 * v6_groups);
	}

	// What a per-address limit or ban keys an address by: IPv4 as it is,
	// IPv6 by its /64 ([DUAL_STACK]), which one host has 2^64 of
	inline ss_ address_key(const ss_ &a)
	{
		return a.find(':') != ss_::npos && a.find('.') == ss_::npos ?
				address_bin(a) : a;
	}

	struct PeerInfo
	{
		typedef PeerId Id;

		Id id = 0;
		ss_ address;
		// Came in through a WebSocket: a browser's page, which any site
		// the user visits can open to 127.0.0.1 ([SECURITY_RUN_1])
		bool web = false;
	};

	struct Packet: public interface::Event::Private
	{
		typedef size_t Type;
		PeerInfo::Id sender = 0;
		ss_ name;
		ss_ data;
		Packet(PeerInfo::Id sender, const ss_ &name, const ss_ &data):
			sender(sender), name(name), data(data){}
	};

	struct NewClient: public interface::Event::Private
	{
		PeerInfo info;

		NewClient(const PeerInfo &info): info(info){}
	};

	// "network:bulk_room": what waits in the peer's bulk lane has fallen
	// under Interface::BULK_LOW (send_bulk())
	struct BulkRoom: public interface::Event::Private
	{
		PeerInfo::Id peer;

		BulkRoom(PeerInfo::Id peer): peer(peer){}
	};

	struct OldClient: public interface::Event::Private
	{
		PeerInfo info;

		OldClient(const PeerInfo &info): info(info){}
	};

	// **An HTTP request for an app** ([STARPORT]): what a GET or a POST to a
	// path under /api/ on the server's port carries, as the event
	// "network:http_request". The module whose path it is answers with
	// Interface::http_respond(); one not answered within ten seconds is
	// dropped. The address is the client's as the game would be told it
	// (a trusted proxy's X-Forwarded-For).
	struct HttpRequest: public interface::Event::Private
	{
		PeerInfo::Id peer = 0;
		ss_ method;       // "GET" or "POST"
		ss_ path;         // "/api/..." or a claimed path, without the query
		ss_ query;        // what follows "?", as it came
		ss_ body;         // a POST's, at most 64 KiB
		ss_ address;
		// The Origin header, as it came: a browser's page says where it is
		// from on every cross-origin request; "" from anything else
		ss_ origin;
		ss_ host;  // the Host header: what the request was sent to
		HttpRequest(PeerInfo::Id peer, const ss_ &method, const ss_ &path,
				const ss_ &query, const ss_ &body, const ss_ &address,
				const ss_ &origin = "", const ss_ &host = ""):
			peer(peer), method(method), path(path), query(query), body(body),
			address(address), origin(origin), host(host){}
		ss_ param(const ss_ &key) const;
	};

	// A value from "a=1&b=2", '+' a space and %XX decoded; a '%' not
	// followed by two hex digits is kept as it is. "" when absent.
	inline ss_ query_value(const ss_ &query, const ss_ &key)
	{
		auto nib = [](char c){
			return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ?
					c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
		};
		size_t at = 0;
		while(at <= query.size()){
			size_t amp = query.find('&', at);
			if(amp == ss_::npos)
				amp = query.size();
			const size_t eq = query.find('=', at);
			if(eq < amp && query.compare(at, eq - at, key) == 0){
				ss_ v;
				for(size_t i = eq + 1; i < amp; i++){
					int a, b;
					if(query[i] == '+'){
						v += ' ';
					} else if(query[i] == '%' && i + 2 < amp &&
							(a = nib(query[i + 1])) >= 0 &&
							(b = nib(query[i + 2])) >= 0){
						v += (char)(a << 4 | b);
						i += 2;
					} else {
						v += query[i];
					}
				}
				return v;
			}
			at = amp + 1;
		}
		return "";
	}
	// Whether one more of `what` from `who` fits in `per` seconds, a window
	// starting at a key's first use ([SHARED_HELPERS]: Starport's).
	//
	// The table is bounded ([SECURITY_RUN_1]): `who` is often what a
	// request says -- an announce's id, a login's name -- and every new
	// one would be a new entry. A long key is kept as its hash, windows
	// that have passed are swept when the table is large, and past a
	// ceiling of live ones a new key is refused: under a flood of made-up
	// keys this fails closed. Not locked: its owner's thread only.
	struct RateTable
	{
		struct Rate { int count = 0; int64_t start = 0; int64_t per = 0; };
		sm_<ss_, Rate> rates;

		// count false: whether one more would be within it, not counting it
		bool ok(const ss_ &what, ss_ who, int max, int64_t per,
				bool count = true)
		{
			if(who.size() > 64)
				who = interface::sha256::hex(interface::sha256::calculate(who));
			const ss_ key = what+"|"+who;
			const int64_t t = interface::os::wall_us() / 1000000;
			if(rates.size() >= 50000 && rates.count(key) == 0){
				for(auto it = rates.begin(); it != rates.end();){
					if(t - it->second.start >= it->second.per)
						it = rates.erase(it);
					else
						++it;
				}
				if(rates.size() >= 200000)
					return false;
			}
			Rate &r = rates[key];
			if(t - r.start >= per){
				r.count = 0;
				r.start = t;
			}
			r.per = per;
			if(r.count >= max)
				return false;
			if(count)
				r.count++;
			return true;
		}
	};

	inline void query_value_self_check()
	{
		if(query_value("xa=1&a=2", "a") != "2" ||
				query_value("a=x+y%41%4g%", "a") != "x yA%4g%" ||
				query_value("a&b=1", "a") != "" ||
				query_value("b=1=2&a=%2", "b") != "1=2" ||
				query_value("a=%2", "a") != "%2")
			throw Exception("query_value self-check");
	}
	inline ss_ HttpRequest::param(const ss_ &key) const
	{
		return query_value(query, key);
	}

	// What a server does about a peer that will not read what it is sent.
	// A peer's socket does not block any more, so what cannot go right away
	// waits in a queue of its own -- and this says what happens when that
	// queue keeps growing.
	//
	// The choice is the game's: a game knows whether a client that has
	// fallen behind is better off waiting, losing data, or being let go.
	// See set_send_policy(), and doc/plan/luanti_module_plan.md, "Settled".
	enum class SendPolicy
	{
		// Queue whatever it takes. Nothing is ever lost and nothing ever
		// waits, and a peer that never reads costs memory without bound:
		// on a public server, a client that stops reading grows the server
		// without limit. Asked for, by a game whose peers are its own.
		Buffer,
		// Over the limit, a new packet is dropped and said so once. For a
		// game whose packets are a stream of the latest of something --
		// positions -- and where an old one is worth nothing anyway.
		Drop,
		// Over the limit for longer than the grace period, the peer is
		// disconnected. Luanti's own answer, and **the default**
		// ([API_DEFAULTS_07]), at 8 MB and 30 s: "a world's worth behind",
		// the numbers apps/vanilla picked, which a healthy client does not
		// trip. builtin/network/send_policy_check.sh runs it.
		Disconnect,
	};

	struct Interface
	{
		virtual void send(PeerInfo::Id recipient, const ss_ &name,
				const ss_ &data) = 0;
		virtual sv_<PeerInfo::Id> list_peers() = 0;
		// How many bytes wait in front of a peer's socket, and behind it in
		// a client that has read them and not handled them yet
		// (network:backlog), so a producer of bulk can hold back while a
		// slow peer drains ([NET_CHANNELS], [CHUNK_RELOAD]): what is
		// queued keeps its place, and what is not yet sent is not yet
		// stale
		virtual size_t pending_bytes(PeerInfo::Id peer) = 0;
		// max_queue_bytes is what Drop and Disconnect measure against, and
		// grace_us how long Disconnect lets a peer stay over it. Buffer
		// ignores both.
		virtual void set_send_policy(SendPolicy policy,
				size_t max_queue_bytes, int64_t grace_us) = 0;
		// What a packet's name means for the queue in front of the socket
		// ([NET_CHANNELS]): the module that defines the packet declares it,
		// once, and the declaration holds for every peer. LatestOnly: the
		// packet goes ahead of everything queued and replaces an unsent
		// one of the same name -- a position, a clock, a HUD value, whose
		// order against other packets does not matter and whose stale copy
		// is worth nothing. Everything undeclared keeps its order behind
		// what was queued before it, sliced into fragments, so a
		// LatestOnly packet waits one fragment and not the bulk.
		// A client is told the LatestOnly names at its connect
		// (core:unordered) and handles them ahead of a backlog of its own,
		// so a module declares at its start.
		enum class Channel { Ordered, LatestOnly };
		virtual void declare(const ss_ &packet_name, Channel channel) = 0;
		// The peer is disconnected once what is queued for it has gone, or
		// in two seconds if it does not read: a packet sent just before,
		// such as why, still arrives. Nothing more is sent to it.
		virtual void disconnect(PeerInfo::Id peer) = 0;
		// The answer to a network:http_request; the connection closes
		// after it. A peer that has gone, or was answered, is ignored.
		// extra_headers: more header lines, each ending in \r\n (CORS, a
		// page's framing policy)
		virtual void http_respond(PeerInfo::Id peer, int status,
				const ss_ &content_type, const ss_ &body,
				const ss_ &extra_headers = "") = 0;
		// Listen on another address too, the same port: the launcher's
		// game, on 127.0.0.1, opened to the LAN at the machine's LAN
		// address. false with why if it cannot.
		virtual bool listen_on(const ss_ &address, ss_ *error) = 0;
		// Paths besides /api/ that come as network:http_request: every
		// target starting with `prefix` -- but "/" is the root page only,
		// and the web client's own files are never an app's. An app that
		// serves pages to read ([HEARTH_MVP]) claims its own at its start.
		virtual void claim_http_path(const ss_ &prefix) = 0;
		// [PLAY_PAGE] (c): a WebSocket to a path starting with `prefix` is
		// the app's, not a game client: "network:ws_open" (an HttpRequest:
		// its path, query, address, Origin and Host), then each message as
		// "network:ws_message" (a Packet, name ""), and "network:ws_closed"
		// (an OldClient). ws_send() sends one binary message; disconnect()
		// closes it. Origin is checked as for a game's WebSocket.
		virtual void claim_ws_path(const ss_ &prefix) = 0;
		// [PLAY_OOTB] the page served at / starts on the launch menu
		// instead of joining this server: for a server with no game of
		// its own (apps/play)
		virtual void set_page_has_no_game() = 0;
		virtual void ws_send(PeerInfo::Id peer, const ss_ &data) = 0;
		// A claimed WebSocket closed with a reason the page's onclose reads
		// (code 1008); the peer is disconnected after it
		virtual void ws_close(PeerInfo::Id peer, const ss_ &reason) = 0;
		// [FAVICON] the PNG served for /favicon.ico, ahead of the default
		// Buildat logo; "" restores the default. An app sets its own icon
		// (vanilla, the game's) at any time.
		virtual void set_favicon(const ss_ &png) = 0;
		// [PAGE_TITLE] the web client page's <title>, "<name> | Buildat":
		// the admin's name (starport.json's, set by starport_announce)
		// ahead of the app's (vanilla, its game's title); "" unsets one,
		// and with neither it is "Buildat"
		virtual void set_page_title(const ss_ &name, bool admin) = 0;
		// [LAN_DISCOVERY]: say every 2 s on the LAN's group (tcpsocket.h)
		// that this server is here, under `name`; "" stops. `account`:
		// whether joining needs one.
		virtual void lan_announce(const ss_ &name, bool account) = 0;
		// [PLAY_LINKS]: pages besides this server's own whose WebSocket is
		// let in, as origins ("https://play.example.org"), under who gave
		// them: starport_announce, a Starport's play page under that
		// Starport's URL. A call replaces what `by` gave; none removes it.
		virtual void set_ws_origins(const ss_ &by, const sv_<ss_> &origins) = 0;
		// [SERVER_HEALTH] what /health answers: app, version, uptime_s,
		// players, tick_gap_ms_avg and _max over the last minute,
		// memory_bytes, as JSON
		virtual ss_ health_json() = 0;
		// [HEALTH_ADMIN] whether any account has the admin priv, as
		// /health's "admin"; left out until accounts says
		virtual void set_has_admin(bool admin) = 0;

		// [FILE_TRANSFER_LATENCY] **The bulk lane**: a payload that goes
		// behind everything else the peer is sent, made into fragments
		// one at a time as the socket has room, so the game's packets
		// wait a fragment for it and not the whole (client_file's file
		// contents: a 28 MB file held every packet behind it for its
		// download). In order with the other bulk sends only. data is
		// shared, not copied: one file to many peers is one copy. Not in
		// pending_bytes() and never dropped by the send policy; the
		// sender paces it by bulk_bytes(), what of it is still waiting
		// (SIZE_MAX for a peer that is gone),
		// and network:bulk_room (BulkRoom), sent once the lane has fallen
		// under BULK_LOW after a send_bulk() left it at that or over.
		static const size_t BULK_LOW = 256 * 1024;
		virtual void send_bulk(PeerInfo::Id recipient, const ss_ &name,
				const sp_<const ss_> &data) = 0;
		virtual size_t bulk_bytes(PeerInfo::Id peer) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(network::Interface*)> cb)
	{
		return server->access_module("network", [&](interface::Module *module){
			cb((network::Interface*)module->check_interface());
		});
	}

	// [ACCESS_ONE_SHOT]: a packet to a peer, the one call nearly every app
	// made through access()
	inline void send(interface::Server *server, PeerInfo::Id recipient,
			const ss_ &name, const ss_ &data)
	{
		access(server, [&](Interface *i){ i->send(recipient, name, data); });
	}

	// **A client's JSON request answered** ([REWORK_1019_FIXES] apps 11),
	// the envelope Starport, Hearth and Aitta share: {"id": the request's,
	// "ok": true, "result": handle's} or {"id", "ok": false, "code":
	// "refused", "error": why}, sent as res_name. Refused before handle
	// runs: not_ready when it is not empty (the app is not up), a peer with
	// no account name (join first), a request that is not an object; what
	// handle throws is the refusal's text.
	//   network::answer_request(m_server, packet, "sp:res", name,
	//       m_save ? "" : "Starport is not ready",
	//       [&](const json::Value &req){ return handle(name, req); });
	inline void answer_request(interface::Server *server, const Packet &packet,
			const char *res_name, const ss_ &name, const ss_ &not_ready,
			const std::function<json::Value(const json::Value &)> &handle)
	{
		const json::Value req = json::load_string(packet.data.c_str());
		json::Value res = json::object();
		res.set("id", req.get("id"));
		ss_ error;
		json::Value result;
		if(!not_ready.empty())
			error = not_ready;
		else if(name.empty())
			error = "join first";
		else if(!req.is_object())
			error = "not a request";
		else {
			try {
				result = handle(req);
			} catch(std::exception &e){
				error = e.what();
			}
		}
		res.set("ok", error.empty());
		if(error.empty())
			res.set("result", result);
		else {
			res.set("code", "refused");
			res.set("error", error);
		}
		send(server, packet.sender, res_name, res.stringify());
	}

	// [HTML_BRAND]'s font or logo for /brand/<name>, answered; false when
	// the path is not one of them
	inline bool serve_brand(interface::Server *server, const HttpRequest &r)
	{
		ss_ data, type;
		if(r.path.compare(0, 7, "/brand/") != 0 || !interface::web_brand::file(
				server->get_config().get<ss_>("share_path"), r.path.substr(7),
				data, type))
			return false;
		access(server, [&](Interface *iface){
			iface->http_respond(r.peer, 200, type, data,
					"Cache-Control: max-age=86400\r\n");
		});
		return true;
	}
}

// vim: set noet ts=4 sw=4:
