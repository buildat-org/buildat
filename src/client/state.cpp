// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/log.h"
#include "client/state.h"
#include "client/app.h"
#include "client/config.h"
#include "client/wss.h"
#include "interface/tcpsocket.h"
#include "interface/address.h"
#include "interface/packet_stream.h"
#include "interface/sha1.h"
#include "interface/fs.h"
#include "interface/os.h"
#include "interface/compress.h"
#include "interface/thread_pool.h"
#include "lua_bindings/replicate.h"
#include <c55/string_util.h>
#include <c55/os.h> // get_timeofday_us()
#include <cstdlib>
#include <mutex>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/tuple.hpp>
#include <Node.h>
#include <Scene.h>
#include <MemoryBuffer.h>
#include <SmoothedTransform.h>
#include <cstring>
#include <fstream>
#include <deque>
#include <set>
#include <thread>
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#endif
#include <atomic>

#ifdef _WIN32
	#ifndef WIN32_LEAN_AND_MEAN
		#define WIN32_LEAN_AND_MEAN
	#endif
// Without this some of the network functions are not found on mingw
	#ifndef _WIN32_WINNT
		#define _WIN32_WINNT 0x0501
	#endif
	#include <windows.h>
	#include <winsock2.h>
	#include <ws2tcpip.h>
	#ifdef _MSC_VER
		#pragma comment(lib, "ws2_32.lib")
	#endif
typedef int socklen_t;
#else
	#include <sys/socket.h>
#endif

#define MODULE "__state"
namespace magic = Urho3D;

using magic::Node;
using magic::Component;
using magic::SmoothedTransform;

extern client::Config g_client_config;

namespace client {

// A packet body the server may have compressed; see pack_packet() in
// builtin/client_file. A flag byte says which it is, because zstd on
// incompressible data is larger than the data, so the server sends whichever
// of the two is smaller and says which it sent.
static ss_ unpack_packet(const ss_ &data)
{
	if(data.empty())
		return data;
	if(data[0] == 0)
		return data.substr(1);
	std::ostringstream os(std::ios::binary);
	interface::decompress_zstd(data.substr(1), os);
	return os.str();
}


struct CState;

// **The cached files are looked up on a worker** ([CLIENT_FRAME]).
// A game announces thousands of them and this is the only thing in a join
// that is pure disk (it was hashing too, [LOAD_SHOWN]); what it hands back
// to the main thread is which of them have to be asked for and which were
// already there.
struct CheckAnnouncedTask: public interface::thread_pool::Task
{
	CState *state;
	sv_<std::tuple<ss_, ss_>> files;
	ss_ cache_path;
	// Filled by the worker
	sv_<std::tuple<ss_, ss_>> wanted;
	sv_<std::tuple<ss_, ss_, ss_>> cached; // name, hash, path

	CheckAnnouncedTask(CState *state, sv_<std::tuple<ss_, ss_>> &&files,
			const ss_ &cache_path):
		state(state), files(std::move(files)), cache_path(cache_path)
	{}

	bool pre(){ return true; }
	bool thread();
	bool post();
};

struct CState: public State
{
	sp_<interface::TCPSocket> m_socket;
	// A server behind a proxy with TLS: the stream is in a WebSocket over
	// TLS on m_socket (client/wss.h)
	std::unique_ptr<client::Wss> m_wss;
	// The LAN port this client keeps for the local server it started
	// ([LAN_PLAY]), while connected to it
	std::unique_ptr<client::LanRelay> m_lan_relay;
	// m_wss is a pipe, not TLS over m_socket
	bool m_pipe = false;
	interface::InputBuffer m_socket_buffer;
	interface::PacketStream m_packet_stream;
	sp_<app::App> m_app;
	ss_ m_remote_cache_path;
	// What this connection has written into it, against REMOTE_WRITE_MAX
	uint64_t m_remote_written = 0;
	ss_ m_tmp_path;
	sm_<ss_, ss_> m_file_hashes; // name -> hash
	set_<ss_> m_waiting_files; // name
	// **What the server says may be handled out of order**
	// (core:unordered, its LatestOnly names), and what has been read off
	// the socket and not yet handled: see handle_socket_buffer()
	set_<ss_> m_unordered;
	std::deque<std::pair<ss_, ss_>> m_parsed;
	// How many were asked for since the wait began, for the progress line
	size_t m_files_asked = 0;
	bool m_tell_after_all_files_transferred_requested = false;
	// The announced files are being read and hashed on a worker; see the
	// core:announce_files handler
	bool m_announce_checking = false;
	// core:run_script that came while announced files were still on their
	// way: a file the server announces alone after connect (luanti's shared
	// client Lua, at its module's start) is not in the wait the server's
	// first scripts are sent after, and a script ran before the file it
	// loads was in ([VL_INV_PARITY])
	sv_<ss_> m_held_scripts;
	// [LOAD_SHOWN]: the connection's first scripts are seconds of one frame
	// on a phone, so they wait m_script_frames frames for the status line
	// saying so to be drawn first
	bool m_scripts_started = false;
	int m_script_frames = 0;
	// And what came after it for the handlers it starts, kept in order
	// until it has run: a game's packets with nobody to take them were lost
	std::deque<std::pair<ss_, ss_>> m_deferred;
	// Connecting is possible only once. After that has happened, the whole
	// state has to be recreated for making a new connection.
	// In actuality the whole client application has to be recreated because
	// otherwise unwanted Lua state remains.
	bool m_connected = false;
	// Set once the connection is gone; see lost_connection()
	bool m_disconnected = false;
	// [SERVE_UPDATE_SMOOTH] 4: the server's network:goodbye, said in place
	// of the connection's end: "1" when it restarts, then why
	ss_ m_goodbye;
	// **A connection that died without closing** (user, 2026-09-30: the
	// web client froze, saying nothing): a server that sends
	// network:keepalive to an idle peer is heard from every few seconds,
	// so nothing at all for this long is a dead link. Only once one has
	// come: an older server sends none, and an idle one was quiet.
	static const int64_t SILENCE_US = 30000000;
	bool m_keepalive_seen = false;
	int64_t m_last_data_us = 0;
	// **And the server hears from this end** ([PEER_TIMEOUT], user
	// 2026-10-04): the same empty packet when nothing has gone for this
	// long, so that the server can drop a peer silent for 60 s (a crashed
	// client, a dropped NAT mapping) and keep an idle one
	// simplified: from update(), so a main thread stalled for a minute is
	// dropped too; a browser's background tab, whose frames stop, is
	// that case
	static const int64_t KEEPALIVE_US = 5000000;
	int64_t m_last_send_us = 0;
	// **What this end has read and not handled, told to the server**
	// ([CHUNK_RELOAD]): the read-ahead below takes the socket dry, so the
	// server's queue for this client looked empty while 64 MB of it waited
	// here, and replicate never held back. The view range stepped up and
	// down for a minute sent every chunk's create and remove, and the
	// client played them back for minutes after, clearing and reloading
	// the world around a player standing still. With the backlog counted
	// the server holds the nodes dirty, and a chunk dropped and wanted
	// again before it goes is not sent at all.
	static const int64_t BACKLOG_REPORT_US = 100000;
	size_t m_backlog_said = 0;
	int64_t m_backlog_said_us = 0;
	// The connect running on a worker ([BOX_PLAYTEST_2] 12). The thread
	// touches m_socket and nothing else of this, and the main thread keeps
	// off the socket while m_connect_result says 0; the result is stored
	// last, so a main thread that reads it as done sees the error with it.
	std::thread m_connect_thread;
	std::atomic<int> m_connect_result{0};
	// Set by connect(), which connect_start() runs on a thread
	std::mutex m_address_mutex;
	ss_ m_address;
	ss_ m_connect_error;
	sm_<ss_, std::function<void(const ss_ &, const ss_ &)>> m_packet_handlers;

	CState(sp_<app::App> app):
		m_socket(interface::createTCPSocket()),
		m_app(app),
		m_remote_cache_path(g_client_config.get<ss_>("cache_path")+"/remote"),
		m_tmp_path(g_client_config.get<ss_>("cache_path")+"/tmp")
	{
		// Create directory for cached files
		interface::fs::create_directories(m_remote_cache_path);
		interface::fs::create_directories(m_tmp_path);

		setup_packet_handlers();
	}

	~CState()
	{
		if(m_connect_thread.joinable())
			m_connect_thread.join();
	}

	// The connect on a worker, so that the frame loop carries on
	// ([BOX_PLAYTEST_2] 12)
	void connect_start(const ss_ &address)
	{
		// **A failed connect leaves nothing connected**, so it is not a
		// state to stay in: the result sits at -1 after the caller has
		// read it, and every later attempt was refused as "one is
		// already running" -- so a launcher could start nothing at all
		// after one server that was not there (2026-09-24, the room
		// launching a game after a failed connect to localhost).
		if(m_connect_result.load() < 0 && !m_connected)
			reset();
		if(m_connect_result.load() != 0 || m_connect_thread.joinable()){
			log_w(MODULE, "connect_start(): one is already running");
			return;
		}
		m_connect_error = "";
#ifdef __EMSCRIPTEN__
		// No threads in the web client ([WEB_CLIENT]), and no need of one:
		// its socket is a WebSocket that connect() only starts opening, and
		// what is sent before it is open waits in the browser
		{
			ss_ error;
			const bool ok = connect(address, &error);
			m_connect_error = ok ? ss_() : error;
			m_connect_result.store(ok ? 1 : -1);
			return;
		}
#endif
		m_connect_thread = std::thread([this, address](){
			ss_ error;
			const bool ok = connect(address, &error);
			// The error first, the result last: a main thread that reads
			// the result as done has the error already written
			m_connect_error = ok ? ss_() : error;
			m_connect_result.store(ok ? 1 : -1);
		});
	}

	int connect_poll(ss_ *error)
	{
		const int r = m_connect_result.load();
		if(r == 0)
			return 0;
		if(m_connect_thread.joinable())
			m_connect_thread.join();
		if(error)
			*error = m_connect_error;
		return r;
	}

	void reset()
	{
		log_i(MODULE, "client::State: reset for another connection");
		// Not connected anywhere any more: the address read as the left
		// server's, and what keys on "not connected" -- the launcher's
		// trust colour sample ([TRUST_OVERLAY_LEAVE]) -- never came back
		{
			std::lock_guard<std::mutex> lock(m_address_mutex);
			m_address.clear();
		}
		if(m_connect_thread.joinable())
			m_connect_thread.join();
		m_connect_result.store(0);
		m_connect_error = "";
		m_lan_relay.reset();
		m_wss.reset();
		m_pipe = false;
		m_socket = sp_<interface::TCPSocket>(interface::createTCPSocket());
		m_socket_buffer.clear();
		m_parsed.clear();
		m_parsed_bytes = 0;
		m_unordered.clear();
		m_packet_stream = interface::PacketStream();
		m_file_hashes.clear();
		m_waiting_files.clear();
		m_held_scripts.clear();
		m_scripts_started = false;
		m_script_frames = 0;
		m_deferred.clear();
		m_tell_after_all_files_transferred_requested = false;
		m_connected = false;
		m_disconnected = false;
		m_keepalive_seen = false;
		m_last_data_us = 0;
		m_last_send_us = 0;
		m_backlog_said = 0;
		m_backlog_said_us = 0;
	}

	void update()
	{
		if(m_disconnected)
			return;
		if(m_script_frames > 0 && --m_script_frames == 0){
			m_scripts_started = true;
			run_held_scripts();
		}
		// The worker owns the socket while a connect runs
		if(m_connect_result.load() == 0 && m_connect_thread.joinable())
			return;
		// **All there is, up to a backlog** (user, 2026-09-30: an answer
		// to a menu came a minute late): a read a frame was 100 KB, a few
		// megabytes a second, and a world arriving faster than that waited
		// in the socket, where nothing can go ahead of it. What is read is
		// handled out of order where the server allows (see
		// handle_socket_buffer()); past READ_AHEAD_BYTES of it not yet
		// handled, the socket is left alone and the server waits, as
		// before.
		for(int i = 0; i < 1000 && backlog_bytes() < READ_AHEAD_BYTES &&
				((m_wss && m_wss->pending()) || m_socket->wait_data(0)); i++){
			if(!read_socket())
				break;
		}
		if(m_disconnected)
			return;
		// A backlog this end has not got round to is not the server's
		// silence
		const int64_t now = get_timeofday_us();
		if(m_last_data_us == 0 || backlog_bytes() >= READ_AHEAD_BYTES)
			m_last_data_us = now;
		if(m_keepalive_seen && now - m_last_data_us >= SILENCE_US){
			lost_connection(ss_()+"nothing from the server in "+
					itos(SILENCE_US / 1000000)+" s");
			return;
		}
		if(m_connected && now - m_last_send_us >= KEEPALIVE_US)
			send_packet("network:keepalive", "");
		// **Nothing after the announce is read until it has been checked**
		// ([CLIENT_FRAME]): the packets that follow it -- the scripts that
		// a module's client half is made of -- expect the files to have
		// been asked for, which cannot happen until the worker has said
		// which are missing. The bytes wait in the buffer, and the frame
		// goes on being drawn meanwhile, which is the whole point.
		if(m_announce_checking)
			return;
		// **Whether or not anything new arrived** ([PACKET_STALL]): the
		// drain has a budget now and can leave packets in the buffer, and
		// a buffer that is only drained when the socket has more to say
		// would sit on them until the server spoke again.
		if(!m_socket_buffer.empty() || !m_parsed.empty())
			handle_socket_buffer();
		if(m_connected && !m_disconnected &&
				backlog_bytes() != m_backlog_said &&
				now - m_backlog_said_us >= BACKLOG_REPORT_US){
			m_backlog_said = backlog_bytes();
			m_backlog_said_us = now;
			send_packet("network:backlog", itos(m_backlog_said));
		}
	}

	// The server is gone: the app goes back to the launcher with why, or
	// shuts down with none under it; see lost_connection() in app.cpp.
	// Without this the socket stays readable at end of file and every frame
	// reads zero bytes and says so, forever.
	void lost_connection(const ss_ &reason)
	{
		if(m_disconnected)
			return;
		m_disconnected = true;
		const bool restarting = !m_goodbye.empty() && m_goodbye[0] == '1';
		const ss_ why = m_goodbye.empty() ? reason : m_goodbye.substr(1);
		log_w(MODULE, "Disconnected from server: %s", cs(why));
		if(m_app)
			m_app->lost_connection(why, restarting);
	}

	bool connect_host_port(const ss_ &address, const ss_ &port, ss_ *error)
	{
		if(m_connected){
			log_i(MODULE, "client::State: Cannot re-use state for new connection");
			if(error)
				*error = "Cannot re-use state for new connection";
			return false;
		}

		bool ok = m_pipe || m_socket->connect_fd(address, port);
		if(ok && m_wss){
			const ss_ why = m_wss->start(address, port,
					g_client_config.get<ss_>("share_path")+
					"/client/extensions/network/ca-bundle.pem");
			if(!why.empty()){
				log_w(MODULE, "client::State: %s", cs(why));
				if(error)
					*error = why;
				m_socket->close_fd();
				return false;
			}
		}
		if(ok){
			log_i(MODULE, "client::State: Connect succeeded (%s:%s)",
					cs(address), cs(port));
			m_connected = true;
			// Speak first, so that the server's network module knows this
			// for a native client at once instead of after its quiet wait
			// for a browser's request ([WEB_CLIENT]). The definition of the
			// client's first packet is what it would send anyway. On the
			// connect worker this is safe for the reason m_socket is: the
			// main thread keeps off until the result is stored.
			m_packet_stream.define("core:request_files",
					[&](const ss_ &packet_data, bool droppable){
				send_raw(packet_data);
			});
		} else {
			log_i(MODULE, "client::State: Connect failed (%s:%s)",
					cs(address), cs(port));
			if(error)
				*error = "Connect failed";
		}
		return ok;
	}

	ss_ get_address()
	{
		std::lock_guard<std::mutex> lock(m_address_mutex);
		return m_address;
	}

	// accounts:owner_token sent on this connection
	bool m_owner_sent = false;

	bool connect(const ss_ &address, ss_ *error)
	{
		{
			std::lock_guard<std::mutex> lock(m_address_mutex);
			m_address = address;
		}
		m_owner_sent = false;
		// **A cache of its own per server** ([SECURITY_RUN_1]): the files
		// are kept by their hash and a client asks only for those it does
		// not have, so in one cache every server learned which of another
		// server's files this client held -- where it had been. This
		// machine's own servers share one, the launcher's game being on a
		// new port each time. And what a connection may write into it is
		// bounded (file_contents).
		{
			ss_ name = "local";
			if(address.compare(0, 10, "localhost:") != 0 &&
					address.compare(0, 10, "127.0.0.1:") != 0 &&
					address.compare(0, 6, "[::1]:") != 0 &&
					address.compare(0, 5, "pipe:") != 0){
				name = "server_"+address;
				for(char &c : name)
					if(!(isalnum((unsigned char)c) || c == '-' || c == '.'))
						c = '_';
			}
			m_remote_cache_path = g_client_config.get<ss_>("cache_path")+
					"/remote/"+name;
			interface::fs::create_directories(m_remote_cache_path);
			m_remote_written = 0;
		}
		if(address.empty()){
			if(error)
				*error = "Cannot connect to empty address";
			return false;
		}
		ss_ host;
		ss_ port;
#ifdef _WIN32
		// "pipe:<path>": a local server boxed in an AppContainer
		// ([PROCESS_SANDBOX] B 2), which loopback does not reach
		if(address.compare(0, 5, "pipe:") == 0){
			m_pipe = true;
			m_wss.reset(client::create_pipe_stream());
			return connect_host_port(address.substr(5), "", error);
		}
#endif
		// "https://host": a server behind a proxy with TLS. The web
		// client's socket is a secure WebSocket on an https page already.
		if(client::parse_secure_address(address, &host, &port)){
#ifndef __EMSCRIPTEN__
			m_wss.reset(client::create_wss(m_socket.get()));
#endif
			return connect_host_port(host, port, error);
		}
		if(!interface::split_host_port(address, &host, &port, "29500")){
			if(error)
				*error = "Not an address: \""+address+"\"";
			return false;
		}
		return connect_host_port(host, port, error);
	}

	void send_raw(const ss_ &data)
	{
		m_last_send_us = get_timeofday_us();
		if(m_wss)
			m_wss->send(data);
		else
			m_socket->send_fd(data);
	}

	void send_packet(const ss_ &name, const ss_ &data)
	{
		log_v(MODULE, "send_packet(): name=%s", cs(name));
		m_packet_stream.output(name, data,
				[&](const ss_ &packet_data, bool droppable){
			// Nothing is dropped here: the client's socket write blocks and
			// the server is the end that has a queue policy
			send_raw(packet_data);
		});
	}

	// What the worker found: the cached files go to the resource cache and
	// the rest are asked for. See CheckAnnouncedTask.
	// **What the wait for the files is at** (user, 2026-09-30): a game of
	// thousands of files is a minute on a phone of a screen nothing draws
	// on, since nothing runs until they are in. The web page's status line
	// says how far it is; natively it is the log's.
	void show_file_progress()
	{
		const size_t left = m_waiting_files.size();
		if(left != 0 && left % 100 != 0 && left != m_files_asked)
			return;
		const size_t got = m_files_asked - left;
		set_status(left == 0 ? ss_() : "Downloading the game: "+
				itos((int)got)+" of "+itos((int)m_files_asked)+" files");
		if(left != 0)
			log_v(MODULE, "files: %zu of %zu", got, m_files_asked);
	}

	// The web page's status line ([LOAD_SHOWN]); natively the log has it
	void set_status(const ss_ &text)
	{
#ifdef __EMSCRIPTEN__
		EM_ASM({
			if(Module.setStatus)
				Module.setStatus(UTF8ToString($0));
		}, text.c_str());
#endif
	}

	void run_held_scripts()
	{
		if(!m_waiting_files.empty() || m_announce_checking ||
				m_held_scripts.empty())
			return;
		// update() calls this again when the frames are counted down
		if(!m_scripts_started){
			if(m_script_frames == 0){
				set_status("Starting the game...");
				m_script_frames = 2;
			}
			return;
		}
		sv_<ss_> scripts;
		scripts.swap(m_held_scripts);
		for(const ss_ &script : scripts){
			if(m_app)
				m_app->run_script(script);
		}
		set_status("");
		// Ahead of what has been read since, in the order they came
		for(auto it = m_deferred.rbegin(); it != m_deferred.rend(); ++it){
			m_parsed_bytes += it->second.size();
			m_parsed.push_front(std::move(*it));
		}
		m_deferred.clear();
	}

	void announce_checked(CheckAnnouncedTask &task)
	{
		m_announce_checking = false;
		for(const auto &entry : task.cached){
			// Let Lua resource wrapper know that this happened so it can
			// update the copy made for Urho3D's resource cache
			m_app->file_updated_in_cache(std::get<0>(entry),
					std::get<1>(entry), std::get<2>(entry));
		}
		if(m_waiting_files.empty())
			m_files_asked = 0;
		// [LOAD_SHOWN]: not what an earlier announce's request still waits
		// for. A server announces its files at the connect and a module's
		// again as it loads them (the Luanti media, thousands), all before
		// the first arrives, and each was sent twice: on a phone a minute
		// of a status line that did not move.
		// simplified: a file changed between the two comes as it is now,
		// under the hash its packet says
		sv_<std::tuple<ss_, ss_>> wanted;
		for(const auto &pair : task.wanted){
			if(m_waiting_files.insert(std::get<0>(pair)).second)
				wanted.push_back(pair);
		}
		m_files_asked += wanted.size();
		show_file_progress();
		log_i(MODULE, "%zu of %zu announced files are cached, %zu asked for",
				task.cached.size(), task.files.size(), wanted.size());
		if(!wanted.empty()){
			std::ostringstream os(std::ios::binary);
			{
				cereal::PortableBinaryOutputArchive ar(os);
				ar(wanted);
			}
			send_packet("core:request_files", os.str());
		}
		// The answer that was held back while this was being checked
		if(m_tell_after_all_files_transferred_requested &&
				m_waiting_files.empty())
			send_packet("core:all_files_transferred", "");
		run_held_scripts();
	}

	ss_ get_file_path(const ss_ &name, ss_ *dst_file_hash)
	{
		auto it = m_file_hashes.find(name);
		if(it == m_file_hashes.end())
			return "";
		const ss_ &file_hash = it->second;
		ss_ file_hash_hex = interface::sha1::hex(file_hash);
		ss_ path = m_remote_cache_path+"/"+file_hash_hex;
		if(dst_file_hash != nullptr)
			*dst_file_hash = file_hash;
		return path;
	}

	void add_local_files(const sv_<std::pair<ss_, ss_>> &name_paths)
	{
		m_remote_cache_path = g_client_config.get<ss_>("cache_path")+
				"/remote/local";
		interface::fs::create_directories(m_remote_cache_path);
		for(const auto &np : name_paths){
			std::ifstream f(np.second, std::ios::binary);
			if(!f.good())
				throw Exception(ss_()+"Could not open file: "+np.second);
			const ss_ content((std::istreambuf_iterator<char>(f)),
					std::istreambuf_iterator<char>());
			const ss_ hash = interface::sha1::calculate(content);
			const ss_ path = m_remote_cache_path+"/"+
					interface::sha1::hex(hash);
			// Whole or not at all: CheckAnnouncedTask takes it as it is
			interface::fs::write_file(path, content);
			m_file_hashes[np.first] = hash;
			m_app->file_updated_in_cache(np.first, hash, path);
		}
	}

	ss_ get_file_content(const ss_ &name)
	{
		ss_ file_hash;
		ss_ path = get_file_path(name, &file_hash);
		std::ifstream f(path);
		if(!f.good())
			throw Exception(ss_()+"Could not open file: "+path);
		std::string file_content((std::istreambuf_iterator<char>(f)),
				std::istreambuf_iterator<char>());
		ss_ file_hash2 = interface::sha1::calculate(file_content);
		if(file_hash != file_hash2){
			log_e(MODULE, "Opened file differs in hash: \"%s\": "
					"requested %s, actual %s", cs(name),
					cs(interface::sha1::hex(file_hash)),
					cs(interface::sha1::hex(file_hash2)));
			throw Exception(ss_()+"Invalid file content: "+path);
		}
		return file_content;
	}

	static const size_t READ_AHEAD_BYTES = 64 * 1024 * 1024;
	size_t m_parsed_bytes = 0;

	size_t backlog_bytes() const
	{
		return m_socket_buffer.size() + m_parsed_bytes;
	}

	// Whether something was read and more may be waiting
	bool read_socket()
	{
		if(m_wss){
			ss_ got, why;
			const int n = m_wss->read(got, &why);
			if(n < 0)
				lost_connection(why);
			if(n <= 0)
				return false;
			m_last_data_us = get_timeofday_us();
			m_socket_buffer.append(got);
			return !m_disconnected;
		}
		int fd = m_socket->fd();
		char buf[100000];
		ssize_t r = recv(fd, buf, 100000, 0);
		if(r == -1){
			if(errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
				return false;
			lost_connection(ss_()+"receive failed: "+strerror(errno));
			return false;
		}
		if(r == 0){
			lost_connection("the server closed the connection");
			return false;
		}
		log_d(MODULE, "Received %zu bytes", r);
		m_last_data_us = get_timeofday_us();
		m_socket_buffer.append(buf, r);
		return !m_disconnected;
	}

	void handle_socket_buffer()
	{
		// A packet whose type this end cannot name used to come out of
		// input() uncaught and abort the client, where the server logs a
		// warning for the same event: one side's oddity was the other side's
		// SIGABRT. It cannot be read past -- the type numbers are defined on
		// the wire before first use, so an unknown one means the stream is
		// no longer being read where packets start -- so the session ends
		// and says why, and the client itself lives.
		// **Read all of it, handle what may go first first** (user,
		// 2026-09-30: an answer to a menu waited a minute): a world arriving
		// faster than this handles it is a backlog here, where the server's
		// queue for this client is empty and cannot put anything ahead.
		// Reading is cheap and in order; handling is what the budget is for.
		// What the server named unordered is handled at once, in its own
		// order, and the rest in theirs, as far as the budget goes.
		try {
			m_packet_stream.input(m_socket_buffer,
			[&](const ss_ &name, const ss_ &data){
				m_parsed.emplace_back(name, data);
				m_parsed_bytes += data.size();
			});
		} catch(interface::UnknownPacketReceived &e){
			m_socket_buffer.clear();
			lost_connection(ss_()+"the server sent something this cannot "
					"read: "+e.what());
			return;
		}
		auto dispatch = [&](std::pair<ss_, ss_> &p){
			if(!m_held_scripts.empty() &&
					p.first.compare(0, 5, "core:") != 0 &&
					p.first.compare(0, 8, "network:") != 0){
				m_deferred.push_back(std::move(p));
				return;
			}
			try {
				handle_packet(p.first, p.second);
			} catch(std::exception &e){
				log_w(MODULE, "Exception on handling packet: %s", e.what());
			}
		};
		// **Never past a core: packet**: a run_script starts the handlers of
		// what follows it, and an unordered packet taken ahead of it found
		// nobody (the first placement, luanti:player_pos, was lost). Up to
		// the first one, then, and in order from there.
		if(!m_unordered.empty() && m_parsed.size() > 1){
			std::deque<std::pair<ss_, ss_>> rest;
			std::deque<std::pair<ss_, ss_>> first;
			bool fence = false;
			for(auto &p : m_parsed){
				if(!fence && p.first.compare(0, 5, "core:") == 0)
					fence = true;
				(!fence && m_unordered.count(p.first) ? first : rest).push_back(
						std::move(p));
			}
			m_parsed = std::move(rest);
			for(auto &p : first){
				m_parsed_bytes -= p.second.size();
				dispatch(p);
			}
		}
		const int64_t budget = packet_drain_us();
		const int64_t t0 = get_timeofday_us();
		while(!m_parsed.empty()){
			std::pair<ss_, ss_> p = std::move(m_parsed.front());
			m_parsed.pop_front();
			m_parsed_bytes -= p.second.size();
			dispatch(p);
			// **An announce stops the drain** until it has been checked:
			// what follows it -- a run_script -- expects its files asked
			// for. The guard in update() is a frame late for packets read
			// in the same go, which a pipe's one big read is (the Wine
			// smoke, 2026-10-03: main/init.lua run with nothing cached)
			if(m_announce_checking)
				break;
			if(budget > 0 && get_timeofday_us() - t0 >= budget)
				break;
		}
	}

	void setup_packet_handlers();

	// **A handler that eats the frame says so, by name**
	// ([PACKET_STALL]): the worst frame on the box is one packet and the
	// profile block over the Lua dispatch names none of them. Five
	// milliseconds is a third of a frame at 60 -- under it nothing is
	// worth a line, over it the name and the byte count are what say
	// which handler to take off the frame.
	static const int64_t SLOW_PACKET_US = 5000;

	// **And how long one update may spend on the buffer** ([PACKET_STALL]):
	// handle_socket_buffer() took every packet the socket had, so a burst
	// of them -- a world arriving, or the object state that comes several
	// times a second -- was one frame however many it was. Twenty
	// milliseconds is a frame at 50 and about a third of what the worst
	// single packet costs on the box; what is left over waits for the next
	// update, which now runs whether or not the socket has more to say.
	// BUILDAT_PACKET_DRAIN_US overrides it and 0 turns the budget off.
	static int64_t packet_drain_us()
	{
		static const int64_t us = []{
			const char *s = getenv("BUILDAT_PACKET_DRAIN_US");
			return s ? (int64_t)atoll(s) : (int64_t)20000;
		}();
		return us;
	}

	void handle_packet(const ss_ &packet_name, const ss_ &data)
	{
		int64_t t0 = get_timeofday_us();
		handle_packet_(packet_name, data);
		int64_t took = get_timeofday_us() - t0;
		if(took >= SLOW_PACKET_US)
			log_w(MODULE, "slow packet: %s took %i ms (%zu bytes)",
					cs(packet_name), (int)(took / 1000), data.size());
	}

	void handle_packet_(const ss_ &packet_name, const ss_ &data)
	{
		auto it = m_packet_handlers.find(packet_name);
		if(it == m_packet_handlers.end()){
			// Pass forward
			m_app->handle_packet(packet_name, data);
		} else {
			// Use handler
			auto &handler = it->second;
			handler(packet_name, data);
		}
	}
};

void CState::setup_packet_handlers()
{
	m_packet_handlers["network:keepalive"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		m_keepalive_seen = true;
	};

	m_packet_handlers["network:goodbye"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		m_goodbye = data.substr(0, 256);
	};

	m_packet_handlers["core:unordered"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		sv_<ss_> names;
		std::istringstream is(data, std::ios::binary);
		{
			cereal::PortableBinaryInputArchive ar(is);
			ar(names);
		}
		m_unordered = set_<ss_>(names.begin(), names.end());
		log_v(MODULE, "%zu packet names may be handled out of order",
				names.size());
	};

	// **Its LAN port is this client's** ([LAN_PLAY]): the local server,
	// boxed and reached by its pipe, opened to the LAN; "<address> <port>".
	// Only from that server, and only this machine's LAN address and the
	// pipe's own port.
	m_packet_handlers["core:lan_relay"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		const ss_ address = get_address();
		const size_t sp = data.find(' ');
		if(!m_pipe || address.compare(0, 5, "pipe:") != 0 ||
				sp == ss_::npos)
			return;
		const ss_ lan = data.substr(0, sp);
		const ss_ port = data.substr(sp + 1);
		const ss_ tail = "buildat-"+port;
		if(lan != interface::local_lan_address() || port.empty() ||
				address.size() < tail.size() ||
				address.compare(address.size() - tail.size(), ss_::npos,
						tail) != 0){
			log_w(MODULE, "core:lan_relay \"%s\" refused", cs(data));
			return;
		}
		ss_ error;
		m_lan_relay.reset(client::start_lan_relay(lan, port,
				address.substr(5), &error));
		if(m_lan_relay)
			log_i(MODULE, "Listening at %s:%s for the local server",
					cs(lan), cs(port));
		else
			log_w(MODULE, "LAN relay: %s", cs(error));
	};

	m_packet_handlers["core:run_script"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		log_i(MODULE, "Asked to run script:\n----\n%s\n----", cs(data));
		if(!m_waiting_files.empty() || m_announce_checking ||
				!m_held_scripts.empty() || !m_scripts_started){
			log_i(MODULE, "The script waits for %zu files still coming",
					m_waiting_files.size());
			m_held_scripts.push_back(data);
			run_held_scripts();
			return;
		}
		if(m_app)
			m_app->run_script(data);
	};

	// Every file the server has, in one packet: the whole set at connect, and
	// one entry when a file changes while connected. What is not cached is
	// asked for in one packet back, so that a game of a few thousand files is
	// a handful of packets and not a few thousand.
	m_packet_handlers["core:announce_files"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		sv_<std::tuple<ss_, ss_>> files;
		std::istringstream is(unpack_packet(data), std::ios::binary);
		{
			cereal::PortableBinaryInputArchive ar(is);
			ar(files);
		}
		log_v(MODULE, "Server announces %zu files", files.size());
		// Our own server: say so, once per connection, with the token it
		// was started with. The server's first packet is this one, so the
		// connection is up by now.
		if(!m_owner_sent){
			m_owner_sent = true;
			const ss_ token = m_app->owner_token_for(get_address());
			if(!token.empty()){
				send_packet("accounts:owner_token", token);
				send_packet("launch:untrusted", m_app->local_server_launch());
			}
		}
		// The names and their hashes are the main thread's, because
		// get_file_path() answers out of this the moment anything asks
		for(const auto &pair : files)
			m_file_hashes[std::get<0>(pair)] = std::get<1>(pair);
		// **Reading and hashing the cache is not the frame's work**
		// ([CLIENT_FRAME]): a VoxeLibre server announces five and a half
		// thousand files and checking them took **975 ms of one frame**
		// at every join. It is disk and arithmetic and nothing else, so it
		// goes to a worker; what comes back to the main thread is the list
		// to ask for and the cached ones to tell the resource cache about.
		m_announce_checking = true;
		interface::thread_pool::ThreadPool *pool =
				m_app ? m_app->get_thread_pool() : nullptr;
		up_<CheckAnnouncedTask> task(new CheckAnnouncedTask(
				this, std::move(files), m_remote_cache_path));
		if(pool){
			pool->add_task(std::move(task));
		} else {
			// No pool (a client that never started one): the old way,
			// which is correct and slow
			while(!task->thread());
			while(!task->post());
		}
	};

	m_packet_handlers["core:tell_after_all_files_transferred"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		// While the announced files are still being checked nothing is
		// known to be missing yet, and answering now would be answering
		// for a list that has not been made
		if(m_waiting_files.empty() && !m_announce_checking){
			send_packet("core:all_files_transferred", "");
		} else {
			m_tell_after_all_files_transferred_requested = true;
		}
	};

	// A bunch of files rather than one: the server packs them to a few
	// kilobytes a packet, because most of a game's files are smaller than the
	// overhead of carrying them one at a time.
	m_packet_handlers["core:file_contents"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		sv_<std::tuple<ss_, ss_, ss_>> files;
		std::istringstream is(unpack_packet(data), std::ios::binary);
		{
			cereal::PortableBinaryInputArchive ar(is);
			ar(files);
		}
		for(const auto &entry : files){
			const ss_ &file_name = std::get<0>(entry);
			const ss_ &file_hash = std::get<1>(entry);
			const ss_ &file_content = std::get<2>(entry);
			if(m_waiting_files.count(file_name) == 0){
				log_w(MODULE, "Received file was not requested: %s %s",
						cs(interface::sha1::hex(file_hash)), cs(file_name));
				continue;
			}
			m_waiting_files.erase(file_name);
			show_file_progress();
			// The server does not hash what it reads off disk before sending
			// it, so this is the check that a file is what it was announced
			// as -- and it has to be here anyway, since a file can change
			// between the announce and the request
			ss_ file_hash2 = interface::sha1::calculate(file_content);
			if(file_hash != file_hash2){
				log_w(MODULE, "Requested file differs in hash: \"%s\": "
						"requested %s, actual %s", cs(file_name),
						cs(interface::sha1::hex(file_hash)),
						cs(interface::sha1::hex(file_hash2)));
				continue;
			}
			// simplified: a ceiling per connection, not on the cache: a
			// server sends at most this much a session, and the disk is the
			// user's to clear (the cache directory)
			static const uint64_t REMOTE_WRITE_MAX =
					(uint64_t)2 * 1024 * 1024 * 1024;
			if(m_remote_written + file_content.size() > REMOTE_WRITE_MAX){
				log_w(MODULE, "The server has sent %s of files this "
						"connection; \"%s\" is not kept", "2 GiB",
						cs(file_name));
				continue;
			}
			m_remote_written += file_content.size();
			ss_ file_hash_hex = interface::sha1::hex(file_hash);
			ss_ path = m_remote_cache_path+"/"+file_hash_hex;
			log_d(MODULE, "Saving %s to %s", cs(file_name), cs(path));
			// Whole or not at all: CheckAnnouncedTask takes it as it is
			if(!interface::fs::write_file(path, file_content))
				log_w(MODULE, "Could not save \"%s\" to %s", cs(file_name),
						cs(path));
			// Let Lua resource wrapper know that this happened so it can
			// update the copy made for Urho3D's resource cache
			m_app->file_updated_in_cache(file_name, file_hash, path);
		}
		if(m_tell_after_all_files_transferred_requested &&
				m_waiting_files.empty()){
			send_packet("core:all_files_transferred", "");
			m_tell_after_all_files_transferred_requested = false;
		}
		run_held_scripts();
	};

	m_packet_handlers["replicate:create_node"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		// For a reference implementation of this kind of network
		// synchronization, see Urho3D's Network/Connection.cpp

		magic::Scene *scene = m_app->get_scene();
		magic::MemoryBuffer msg(data.c_str(), data.size());
		uint node_id = msg.ReadNetID();
		Node *node = scene->GetNode(node_id);
		if(node && node_id == 1){
			// This is the scene
		} else if(node){
			log_w(MODULE, "replicate:create_node: Node %i (old name=\"%s\")"
					" already exists. This could be due to a node having been"
					" accidentally created on the client side without mode=LOCAL."
					" If a node seems to mysteriously disappear, this is the"
					" reason.",
					node_id, node->GetName().CString());
		} else {
			log_v(MODULE, "Creating node %i", node_id);
			// Add to the root level; it may be moved as we receive the parent
			// attribute
			node = scene->CreateChild(node_id, magic::REPLICATED);
			node->CreateComponent<SmoothedTransform>(magic::LOCAL);
		}
		// Read initial attributes
		node->ReadDeltaUpdate(msg);
		// Skip transition to first position
		SmoothedTransform *transform = node->GetComponent<SmoothedTransform>();
		if(transform)
			transform->Update(1.0f, 0.0f);

		// Read initial user variables
		uint num_vars = msg.ReadVLE();
		while(num_vars && !msg.IsEof()){
			auto key = msg.ReadStringHash();
			node->SetVar(key, msg.ReadVariant());
			num_vars--;
		}

		// Read components
		uint num_c = msg.ReadVLE();
		while(num_c && !msg.IsEof()){
			num_c--;

			auto type = msg.ReadStringHash();
			uint c_id = msg.ReadNetID();
			// Only components that draw, sound, collide or hold the scene:
			// a component is made by the type hash the server sends and
			// its network attributes applied, and a LuaScriptInstance's
			// script file runs in the client's own Lua state, outside the
			// sandbox ([SECURITY_RUN_1]). The rest of the node is not
			// readable past a refused one, so the node ends there.
			static const std::set<magic::StringHash> replicable = []{
				std::set<magic::StringHash> s;
				for(const char *n : {"Octree", "PhysicsWorld", "Zone",
						"Light", "Camera", "StaticModel", "AnimatedModel",
						"AnimationController", "StaticModelGroup",
						"CustomGeometry", "BillboardSet", "ParticleEmitter",
						"RibbonTrail", "DecalSet", "Text3D", "Skybox",
						"Terrain", "RigidBody", "CollisionShape", "Constraint",
						"SoundSource", "SoundSource3D", "SmoothedTransform"})
					s.insert(magic::StringHash(n));
				return s;
			}();
			if(!replicable.count(type)){
				log_w(MODULE, "replicate:create_node: component type %s is"
						" not one a server may create; node %i ends there",
						type.ToString().CString(), node_id);
				return;
			}

			Component *c = scene->GetComponent(c_id);
			if(!c || c->GetType() != type || c->GetNode() != node){
				if(c){
					log_w(MODULE, "replicate:create_node: Component %i already"
							" exists. This could be due to a component having"
							" been accidentally created on the client side"
							" without mode=LOCAL."
							" If a component seems to mysteriously disappear,"
							" this is the reason.", c_id);
					c->Remove();
				}
				log_v(MODULE, "Creating component %i", c_id);
				c = node->CreateComponent(type, magic::REPLICATED, c_id);
				if(!c){
					log_e(MODULE, "Could not create component %i", c_id);
					return;
				}
			}
			c->ReadDeltaUpdate(msg);
			c->ApplyAttributes();
		}

		lua_State *L = m_app->get_lua();
		lua_bindings::replicate::on_node_created(L, node_id);
	};

	m_packet_handlers["replicate:create_component"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		log_w("TODO: %s", cs(packet_name));
	};

	m_packet_handlers["replicate:latest_node_data"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		magic::Scene *scene = m_app->get_scene();
		magic::MemoryBuffer msg(data.c_str(), data.size());
		uint node_id = msg.ReadNetID();
		Node *node = scene->GetNode(node_id);
		if(node){
			log_d(MODULE, "Updating node %i (LatestDataUpdate)", node_id);
			node->ReadLatestDataUpdate(msg);
		} else {
			log_w(MODULE, "Out-of-order node data ignored for %i", node_id);
			// Note: Network/Connection.cpp would buffer this
		}
	};

	m_packet_handlers["replicate:latest_component_data"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		magic::Scene *scene = m_app->get_scene();
		magic::MemoryBuffer msg(data.c_str(), data.size());
		uint c_id = msg.ReadNetID();
		Component *c = scene->GetComponent(c_id);
		if(c){
			log_d(MODULE, "Updating component %i (LatestDataUpdate)", c_id);
			c->ReadLatestDataUpdate(msg);
			c->ApplyAttributes();
		} else {
			log_w(MODULE, "Out-of-order component data ignored for %i", c_id);
			// Note: Network/Connection.cpp would buffer this
		}
	};

	m_packet_handlers["replicate:node_delta_update"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		magic::Scene *scene = m_app->get_scene();
		magic::MemoryBuffer msg(data.c_str(), data.size());
		uint node_id = msg.ReadNetID();
		Node *node = scene->GetNode(node_id);
		if(node){
			log_d(MODULE, "Updating node %i (DeltaUpdate)", node_id);
			node->ReadDeltaUpdate(msg);
			uint num_vars = msg.ReadVLE();
			while(num_vars && !msg.IsEof()){
				auto key = msg.ReadStringHash();
				node->SetVar(key, msg.ReadVariant());
				num_vars--;
			}
		} else {
			log_w(MODULE, "Out-of-order node data ignored for %i", node_id);
			// Note: Network/Connection.cpp would NOT buffer this
		}
	};

	m_packet_handlers["replicate:component_delta_update"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		log_w(MODULE, "TODO: %s", cs(packet_name));
		// Note: Network/Connection.cpp would NOT buffer this
	};

	m_packet_handlers["replicate:remove_node"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		magic::Scene *scene = m_app->get_scene();
		magic::MemoryBuffer msg(data.c_str(), data.size());
		uint node_id = msg.ReadNetID();
		lua_State *L = m_app->get_lua();
		lua_bindings::replicate::on_node_removed(L, node_id);
		Node *node = scene->GetNode(node_id);
		if(node)
			node->Remove();
	};

	m_packet_handlers["replicate:remove_component"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		magic::Scene *scene = m_app->get_scene();
		magic::MemoryBuffer msg(data.c_str(), data.size());
		uint c_id = msg.ReadNetID();
		Component *c = scene->GetComponent(c_id);
		if(c)
			c->Remove();
	};

	m_packet_handlers[""] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
	};
}

bool CheckAnnouncedTask::thread()
{
	for(const auto &pair : files){
		const ss_ &file_name = std::get<0>(pair);
		const ss_ &file_hash = std::get<1>(pair);
		const ss_ path = cache_path+"/"+interface::sha1::hex(file_hash);
		// [LOAD_SHOWN]: there, not read and hashed again. A file is saved
		// under its hash only after its content was checked against it, and
		// whole (fs::write_file); hashing them all was 975 ms natively, and
		// on the web, where there is no worker, a phone's black screen of
		// 15 s at each join.
		// simplified: a copy changed on the disk afterwards is used as it
		// is; deleting the cache directory is the way out
		const bool cached_is_ok = interface::fs::path_exists(path);
		if(cached_is_ok)
			cached.push_back(std::make_tuple(file_name, file_hash, path));
		else
			wanted.push_back(pair);
	}
	return true;
}

bool CheckAnnouncedTask::post()
{
	state->announce_checked(*this);
	return true;
}

State* createState(sp_<app::App> app)
{
	return new CState(app);
}
}
// vim: set noet ts=4 sw=4:
