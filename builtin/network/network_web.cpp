// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// The network module of the server built for the web ([WEB_LOCAL_SERVER]),
// in place of network.cpp, which listens on a socket a browser does not
// have. util/web_server.cmake builds this one; the native server never does.
//
// **One peer: the page's own client**, its byte stream carried by
// postMessage between the page and the worker the server runs in
// (src/server/web/pre.js; the client's end is src/client/pipe_stream.cpp).
// The stream is the native one, a core:hello first each way. The page's
// "open" is a new peer, a reconnect's "close" its going. **This is the
// trust boundary** (accounts_web.cpp lets in every peer that comes here):
// the only way in is buildat_stream_in(), which only the worker's own
// message handler calls, and a dedicated worker hears only the page that
// made it.
// simplified: no LatestOnly lane, no send policy and no in-flight cap;
// the one peer is this page's and reads as fast as it is sent to
#include "network/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/packet_stream.h"
#include "interface/protocol.h"
#include "interface/thread.h"
#include "interface/os.h"
#include <condition_variable>
#include <deque>
#include <mutex>
#include <malloc.h> // mallinfo()
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#include <emscripten/heap.h>
#else
#define EMSCRIPTEN_KEEPALIVE
#define MAIN_THREAD_ASYNC_EM_ASM(...)
#endif
#define MODULE "network"

namespace network {

// What the page sent, in order: 0 bytes, 1 open, 2 close
static std::mutex g_mutex;
static std::condition_variable g_cv;
static std::deque<std::pair<int, ss_>> g_in;
// What goes to the page, taken by the worker's thread
static ss_ g_out;
static bool g_out_close = false;
static bool g_out_told = false;
static ss_ g_taken;

// Both called on the worker's own thread, by pre.js
extern "C" EMSCRIPTEN_KEEPALIVE void buildat_stream_in(int op,
		const char *data, int size)
{
	if(op < 0 || op > 2 || size < 0)
		return;
	std::lock_guard<std::mutex> lock(g_mutex);
	g_in.emplace_back(op, ss_(data, size));
	g_cv.notify_one();
}

// The bytes for the page: their count, g_taken holding them; 0 none, and
// -1 once after them when the peer was disconnected
extern "C" EMSCRIPTEN_KEEPALIVE int buildat_stream_take()
{
	std::lock_guard<std::mutex> lock(g_mutex);
	g_taken.clear();
	if(!g_out.empty()){
		g_taken.swap(g_out);
		return (int)g_taken.size();
	}
	if(g_out_close){
		g_out_close = false;
		return -1;
	}
	g_out_told = false;
	return 0;
}

extern "C" EMSCRIPTEN_KEEPALIVE const char* buildat_stream_taken()
{
	return g_taken.data();
}

// To the page: the worker's thread is told once until it has taken all
static void stream_out(const ss_ &data, bool close)
{
	std::lock_guard<std::mutex> lock(g_mutex);
	g_out += data;
	g_out_close = g_out_close || close;
	if(g_out_told)
		return;
	g_out_told = true;
	MAIN_THREAD_ASYNC_EM_ASM({
		if(Module['buildatStreamOut'])
			Module['buildatStreamOut']();
	});
}

struct Module;

struct PumpThread: public interface::ThreadedThing
{
	Module *m_module;
	PumpThread(Module *module): m_module(module){}
	void run(interface::Thread *thread);
	void on_crash(interface::Thread *thread);
};

struct Module: public interface::Module, public network::Interface
{
	interface::Server *m_server;
	sp_<interface::Thread> m_thread;
	// The peer, 0 for none
	PeerInfo::Id m_peer = 0;
	PeerInfo::Id m_next_peer = 1;
	interface::InputBuffer m_buffer;
	interface::PacketStream m_stream;
	bool m_hello_sent = false;
	bool m_hello_seen = false;
	int64_t m_last_send_us = 0;
	// Said every 10 s: the ticks and the stream's bytes since
	int64_t m_said_us = 0;
	int m_ticks = 0;
	size_t m_bytes_in = 0, m_bytes_out = 0;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		if(m_thread){
			m_thread->request_stop();
			g_cv.notify_one();
			m_thread->join();
		}
	}

	void init()
	{
		m_server->sub_event(this, interface::Event::t("core:start"));
		m_server->sub_event(this, interface::Event::t("core:tick"));
		m_server->sub_event(this, interface::Event::t("core:shutdown"));
	}

	void event(const interface::Event::Type &type,
			const interface::Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:tick", on_tick)
		EVENT_VOIDN("core:shutdown", on_shutdown)
	}

	// The page's stream is taken from the start on, when every module
	// listens for its peer
	void on_start()
	{
		log_i(MODULE, "network: the web server's, the page's stream its "
				"one peer");
		m_thread.reset(interface::createThread(new PumpThread(this)));
		m_thread->set_name("network/page");
		m_thread->start();
	}

	void on_tick()
	{
		m_ticks++;
		const int64_t now = interface::os::time_us();
		if(m_said_us == 0)
			m_said_us = now;
		if(now - m_said_us >= 10000000){
			// [WEB_LOCAL_MEMORY] The worker's memory: the wasm's (it only
			// grows; the cap is MAXIMUM_MEMORY in util/web_server.cmake)
			// and what malloc has handed out of it
			size_t heap = 0;
#ifdef __EMSCRIPTEN__
			heap = emscripten_get_heap_size();
#endif
			log_i(MODULE, "network: %.1f ticks/s; the page's stream %zu "
					"bytes in, %zu out; memory %zu MiB, %zu MiB in use",
					m_ticks * 1e6 / (now - m_said_us), m_bytes_in, m_bytes_out,
					heap >> 20, (size_t)mallinfo().uordblks >> 20);
			m_said_us = now;
			m_ticks = 0;
			m_bytes_in = m_bytes_out = 0;
		}
		// The client takes a server silent for some seconds as gone
		if(playing() && now - m_last_send_us >= 5000000)
			send_u("network:keepalive", "");
	}

	void on_shutdown()
	{
		if(m_peer != 0 && m_hello_sent)
			send_u("network:goodbye", "0The server is shutting down");
	}

	bool playing(){ return m_peer != 0 && m_hello_seen; }

	// On the pump thread, in this module's turn
	void take(int op, const ss_ &data)
	{
		if(op == 1 || op == 2)
			drop();
		if(op == 1){
			m_peer = m_next_peer++;
			log_i(MODULE, "Client %zu: the page's stream opened", m_peer);
		}
		if(op != 0 || m_peer == 0)
			return;
		m_bytes_in += data.size();
		m_buffer.append(data);
		if(!m_hello_sent){
			m_hello_sent = true;
			send_u("core:hello",
					interface::hello_data(interface::Hello::own()));
		}
		bool refused = false;
		try {
			m_stream.input(m_buffer, [&](const ss_ &name, const ss_ &data){
				if(refused)
					return;
				if(!m_hello_seen){
					if(name != "core:hello")
						throw interface::UnknownPacketReceived(
								name+" before a hello");
					refused = !take_hello(data);
					return;
				}
				const interface::Event::Type t =
						interface::getGlobalEventRegistry()->find(
								"network:packet_received/"+name);
				if(t != 0)
					m_server->emit_event(t, new Packet(m_peer, name, data));
			});
		} catch(interface::UnknownPacketReceived &e){
			log_w(MODULE, "Client %zu: %s; dropping it", m_peer, e.what());
			refused = true;
		}
		// Not inside input(), whose stream it resets
		if(refused)
			disconnect(m_peer);
	}

	// Whether the client plays with this end; told why not if it does not
	bool take_hello(const ss_ &data)
	{
		ss_ refusal;
		try {
			refusal = interface::hello_refusal(interface::hello_of(data),
					"client");
		} catch(interface::RecordError &e){
			refusal = e.what();
		}
		if(!refusal.empty()){
			log_i(MODULE, "Client %zu refused: %s", m_peer, cs(refusal));
			send_u("network:goodbye", "0"+refusal);
			return false;
		}
		m_hello_seen = true;
		log_i(MODULE, "Client %zu from the page connected", m_peer);
		PeerInfo info;
		info.id = m_peer;
		info.address = "page";
		m_server->emit_event("network:client_connected", new NewClient(info));
		return true;
	}

	// The peer gone; the game told if it had heard of it
	void drop()
	{
		if(m_peer == 0)
			return;
		log_i(MODULE, "Client %zu from the page disconnected", m_peer);
		if(m_hello_seen){
			PeerInfo info;
			info.id = m_peer;
			info.address = "page";
			m_server->emit_event("network:client_disconnected",
					new OldClient(info));
		}
		m_peer = 0;
		m_buffer.clear();
		m_stream = interface::PacketStream();
		m_hello_sent = m_hello_seen = false;
	}

	void send_u(const ss_ &name, const ss_ &data)
	{
		ss_ out;
		m_stream.output(name, data, [&](ss_ &&packet, bool droppable){
			out += packet;
		});
		m_bytes_out += out.size();
		m_last_send_us = interface::os::time_us();
		stream_out(out, false);
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}

	void send(PeerInfo::Id recipient, const ss_ &name, const ss_ &data)
	{
		if(recipient != m_peer || !playing()){
			log_w(MODULE, "network::send(): Peer %i doesn't exist",
					(int)recipient);
			return;
		}
		send_u(name, data);
	}
	sv_<PeerInfo::Id> list_peers()
	{
		return playing() ? sv_<PeerInfo::Id>{m_peer} : sv_<PeerInfo::Id>{};
	}
	size_t pending_bytes(PeerInfo::Id peer){ return 0; }
	void set_send_policy(SendPolicy policy, size_t max_queue_bytes,
			int64_t grace_us){}
	void declare(const ss_ &packet_name, Channel channel){}
	// The page's client is told the stream closed, after what was sent
	void disconnect(PeerInfo::Id peer)
	{
		if(peer != m_peer || m_peer == 0)
			return;
		drop();
		stream_out("", true);
	}
	void http_respond(PeerInfo::Id peer, int status, const ss_ &content_type,
			const ss_ &body, const ss_ &extra_headers){}
	bool listen_on(const ss_ &address, ss_ *error)
	{
		*error = "a server in a browser listens on nothing";
		return false;
	}
	void claim_http_path(const ss_ &prefix){}
	void claim_ws_path(const ss_ &prefix){}
	void set_page_has_no_game(){}
	void ws_send(PeerInfo::Id peer, const ss_ &data){}
	void ws_close(PeerInfo::Id peer, const ss_ &reason){}
	void set_favicon(const ss_ &png){}
	void set_page_title(const ss_ &name, bool admin){}
	void lan_announce(const ss_ &name, bool account){}
	void set_ws_origins(const ss_ &by, const sv_<ss_> &origins){}
	ss_ health_json(){ return "{}"; }
	void set_has_admin(bool admin){}
};

void PumpThread::run(interface::Thread *thread)
{
	while(!thread->stop_requested()){
		std::deque<std::pair<int, ss_>> ops;
		{
			std::unique_lock<std::mutex> lock(g_mutex);
			g_cv.wait_for(lock, std::chrono::milliseconds(500),
					[&]{ return !g_in.empty() || thread->stop_requested(); });
			ops.swap(g_in);
		}
		if(ops.empty())
			continue;
		network::access(m_module->m_server, [&](network::Interface *){
			for(auto &op : ops)
				m_module->take(op.first, op.second);
		});
	}
}

void PumpThread::on_crash(interface::Thread *thread)
{
	m_module->m_server->shutdown(1, "network: the page's stream crashed");
}

extern "C" {
	BUILDAT_EXPORT void* createModule_network(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
