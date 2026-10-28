// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/address.h"
#include "interface/web_brand.h"
#include "network/api.h"
#include "core/log.h"
#include "core/json.h"
#include "core/version.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/tcpsocket.h"
#include "interface/packet_stream.h"
#include "interface/protocol.h"
#include "interface/thread.h"
#include "interface/os.h"
#include "interface/select_handler.h"
#include "interface/sha1.h"
#include "interface/compress.h"
#include "interface/fs.h"
#include <cereal/archives/portable_binary.hpp>
#include <deque>
#include <set>
#include <fstream>
#include <sstream>
#include <algorithm>
#include <atomic>
#include <cereal/types/vector.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/tuple.hpp>
#include <deque>
#ifdef _WIN32
	#include "ports/windows_sockets.h"
	// Vista's, which older MinGW headers leave out
	#ifndef PIPE_REJECT_REMOTE_CLIENTS
		#define PIPE_REJECT_REMOTE_CLIENTS 0x00000008
	#endif
	#include "ports/windows_compat.h" // usleep()
#else
	#include <sys/socket.h>
	#include <unistd.h> // usleep()
#endif
#include <errno.h>
#include <sys/stat.h>
#define MODULE "network"
#include <thread>
#include <random>
#include <mutex>

using interface::Event;

namespace network {

#ifdef _WIN32
// **The local client by a pipe** ([PROCESS_SANDBOX] B 2): a server boxed in
// an AppContainer cannot be reached over loopback by the client that
// started it, and a pipe it makes as \\.\pipe\LOCAL\buildat-<port> lands in
// its container's namespace, where the client opens it by the full path.
// The pipe carries the same byte stream a TCP peer does. A peer of it has
// this for its socket: no fd a select can wait on (fd() is a negative id
// of its own, which get_sockets() leaves out), so the network thread
// polls it, every few milliseconds while there is one.
// simplified: polled in the pipe's non-blocking mode rather than
// overlapped I/O; it is one local client.
struct PipeSocket: public interface::TCPSocket
{
	HANDLE m_pipe;
	int m_id;
	// The client that started this server, on this machine; or the LAN
	// player it relays ([LAN_PLAY]), named by the line it starts with
	ss_ m_remote = "127.0.0.1";
	// What came before that line is known to be there or not
	ss_ m_head;
	bool m_head_done = false;
	PipeSocket(HANDLE pipe, int id): m_pipe(pipe), m_id(id){}
	~PipeSocket(){ close_fd(); }
	int fd() const { return m_id; }
	bool good() const { return m_pipe != INVALID_HANDLE_VALUE; }
	void release_fd(){ m_pipe = INVALID_HANDLE_VALUE; }
	void close_fd()
	{
		if(m_pipe == INVALID_HANDLE_VALUE)
			return;
		DisconnectNamedPipe(m_pipe);
		CloseHandle(m_pipe);
		m_pipe = INVALID_HANDLE_VALUE;
	}
	bool listen_fd(){ return false; }
	bool connect_fd(const ss_&, const ss_&){ return false; }
	bool bind_fd(const ss_&, const ss_&){ return false; }
	bool accept_fd(const TCPSocket&){ return false; }
	bool set_nonblocking(bool){ return true; }
	bool wait_data(int){ return false; }
	ss_ get_local_address() const { return "pipe"; }
	ss_ get_remote_address() const { return m_remote; }
	bool send_fd(const ss_ &data)
	{
		size_t at = 0;
		while(at < data.size()){
			size_t sent = 0;
			if(!send_some(data, at, &sent))
				return false;
			at += sent;
			if(sent == 0)
				Sleep(1);
		}
		return true;
	}
	bool send_some(const ss_ &data, size_t offset, size_t *sent)
	{
		*sent = 0;
		if(m_pipe == INVALID_HANDLE_VALUE)
			return false;
		if(offset >= data.size())
			return true;
		// A piece that fits the pipe's buffer: a non-blocking write larger
		// than the room left writes nothing, and was tried again for good
		// (Wine, 2026-10-03: the announce went and the files never did)
		const size_t piece = std::min<size_t>(data.size() - offset, 16384);
		DWORD n = 0;
		if(!WriteFile(m_pipe, &data[offset], (DWORD)piece, &n, nullptr))
			return false;
		*sent = n;
		return true;
	}
	// > 0 bytes, 0 the client went, -1 nothing now
	int read_some(char *buf, int size)
	{
		DWORD n = 0;
		if(ReadFile(m_pipe, buf, (DWORD)size, &n, nullptr))
			return n > 0 ? (int)n : -1;
		const DWORD e = GetLastError();
		return e == ERROR_NO_DATA ? -1 : 0;
	}
};

// The pipes a client has connected, waiting for the network module to take
// them. The listening thread is the process's, not the module's: a module
// reloaded under it would leave it pointing at freed code.
static std::mutex g_pipe_mutex;
static sv_<HANDLE> g_pipe_new;
static std::atomic<bool> g_pipe_started(false);

static void pipe_listen(const ss_ &name)
{
	for(;;){
		// This machine's client only: a named pipe is reachable over the
		// network (\\host\pipe\...) unless it says otherwise, and its
		// peer is taken as 127.0.0.1 ([SECURITY_RUN_1])
		HANDLE p = CreateNamedPipeA(name.c_str(), PIPE_ACCESS_DUPLEX,
				PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
				PIPE_REJECT_REMOTE_CLIENTS,
				PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, nullptr);
		if(p == INVALID_HANDLE_VALUE){
			log_w(MODULE, "The pipe %s could not be made (%i)", cs(name),
					(int)GetLastError());
			return;
		}
		if(!ConnectNamedPipe(p, nullptr) &&
				GetLastError() != ERROR_PIPE_CONNECTED){
			CloseHandle(p);
			continue;
		}
		DWORD mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
		SetNamedPipeHandleState(p, &mode, nullptr, nullptr);
		std::lock_guard<std::mutex> lock(g_pipe_mutex);
		g_pipe_new.push_back(p);
	}
}
#endif

struct Module;

struct NetworkThread: public interface::ThreadedThing
{
	Module *m_module = nullptr;

	NetworkThread(Module *module):
		m_module(module)
	{}

	void run(interface::Thread *thread);
	void on_crash(interface::Thread *thread);
};

// A packet that counts itself out of its peer's in-flight count when the
// last module has handled it (Peer::in_flight)
struct CountedPacket: public Packet
{
	sp_<std::atomic<int>> in_flight;
	CountedPacket(const sp_<std::atomic<int>> &in_flight, PeerInfo::Id sender,
			const ss_ &name, const ss_ &data):
		Packet(sender, name, data), in_flight(in_flight){ ++*in_flight; }
	~CountedPacket(){ --*in_flight; }
};

struct Peer
{
	typedef size_t Id;

	Id id = 0;
	sp_<interface::TCPSocket> socket;
	// The client behind a trusted proxy ([FP_ACCESS] 6): the last entry of
	// its WebSocket upgrade's X-Forwarded-For, or empty
	ss_ forwarded_for;
	// Whom the game is told the peer is
	ss_ address() const {
		return forwarded_for.empty() ? socket->get_remote_address() :
				forwarded_for;
	}
	interface::InputBuffer socket_buffer;
	interface::PacketStream packet_stream;
	// This peer's packets handed to the modules and not handled yet. Over
	// MAX_IN_FLIGHT its socket is not read until they are; it is not
	// dropped for it, so a module busy for seconds only holds a client
	// back. One peer sending a cheap request at full speed queued 4.3
	// million events in 20 s, 630 MB, and an answer to anyone else took
	// over a minute ([SECURITY_RUN_1]); now its own TCP window holds it.
	static const int MAX_IN_FLIGHT = 100;
	sp_<std::atomic<int>> in_flight = std::make_shared<std::atomic<int>>(0);
	bool held() const { return *in_flight > MAX_IN_FLIGHT; }

	// One port takes the native client, a browser fetching the web client
	// and the web client's WebSocket ([WEB_CLIENT]). A new connection is
	// Sniff until its first bytes say which; only Native and WebSocket are
	// game peers, and the game hears of a peer when it becomes one.
	// RawWebSocket: one on a path an app claimed (claim_ws_path()), its
	// messages the app's and not a game stream
	enum class Kind { Sniff, Http, Native, WebSocket, RawWebSocket };
	Kind kind = Kind::Native;
	int64_t accepted_us = 0;
	// Sniff and Http: what has come of the request so far
	ss_ http_request;
	// WebSocket: what has come and is not a whole frame yet
	ss_ ws_in;
	// RawWebSocket: a message's frames so far, until its last
	ss_ ws_message;
	// Dropped once what is queued has gone: an HTTP response, the answer to
	// a WebSocket close, or a game's disconnect()
	bool closing = false;
	// Http: a request under /api/ handed to the modules, its answer awaited
	// (network:http_request)
	bool api_waiting = false;
	// disconnect()'s: dropped by then even if the peer does not read
	int64_t close_by_us = 0;
	// A refused peer is kept open this long after its goodbye: a 0.6
	// client that reads the goodbye and the end of the stream in one go
	// takes the end first and says only that the server closed it, and it
	// first reads once its window is up, seconds after connecting
	int64_t linger_until_us = 0;
	// [COMPAT_BREAK_07] 8a: a game peer is the game's once its core:hello
	// has come and plays with this end's
	bool hello_seen = false;
	// This end's, said once the peer's first byte has come: an older
	// client is told why it cannot play in its own framing instead
	bool hello_sent = false;

	bool game() const {
		return kind == Kind::Native || kind == Kind::WebSocket;
	}
	// A game peer the game has heard of
	bool playing() const { return game() && hello_seen; }

	// What has been handed to this peer and has not gone down the socket
	// yet, because the socket does not block any more: a peer that is not
	// reading used to stop the whole server inside send(2). `out_sent` is
	// how much of the front of it has already gone.
	ss_ out_buf;
	size_t out_sent = 0;
	// Behind it, the queue: packets (a fragment each at most) in the order
	// they were sent, and ahead of them the LatestOnly ones by name, one
	// per name, the newest ([NET_CHANNELS]). out_buf is what is being
	// written now; a packet moves into it when it drains.
	struct Queued {
		ss_ name;
		ss_ packet;
		bool payload; // a droppable payload, not a definition
	};
	std::deque<Queued> out_queue;
	std::deque<std::pair<ss_, ss_>> out_latest; // name, packet
	// LatestOnly names with packets still in the ordered queue, and how
	// many: the definition and the first payload go ordered (send_u), and
	// a payload in the lane while they are queued would overtake them --
	// the peer reads a type it has not been told. Until the count is
	// zero the name's payloads go ordered too.
	sm_<ss_, size_t> ordered_first;
	// A LatestOnly name's payload in the ordered queue, for its
	// replacement without a scan of the queue (a deque keeps an element
	// where it is as the ends change)
	sm_<ss_, Queued*> queued_latest;
	size_t out_queued_bytes = 0;
	// When the queue first went over the policy's limit, for Disconnect
	int64_t over_since_us = 0;
	// When the socket last took anything: a peer over the limit that is
	// reading, however slowly, is a slow link and not a dead one
	// ([NET_CHANNELS]; over a lossy link VoxeLibre's join was
	// disconnected at 24 MB unread in 30 s while the peer was reading
	// the whole time)
	int64_t last_progress_us = 0;
	// Said once per peer rather than per packet
	bool warned_full = false;
	// When this end last sent the peer anything, for keepalive(), and
	// whether it has had one: the first goes whatever else is being sent,
	// so that a client busy with a world knows it is to expect them
	int64_t last_send_us = 0;
	bool keepalive_sent = false;
	// When the peer last sent anything: a game peer silent for
	// PEER_SILENCE_US is dropped ([PEER_TIMEOUT])
	int64_t last_recv_us = 0;

	// A web client file being served: taken from the module's one copy a
	// piece at a time as the socket drains, not copied whole per download
	sp_<const ss_> file;
	size_t file_at = 0;
	size_t out_pending() const {
		return out_buf.size() - out_sent + out_queued_bytes +
				(file ? file->size() - file_at : 0);
	}
	// What the client says it has read and not yet handled
	// (network:backlog, [CHUNK_RELOAD]): its read-ahead empties the
	// socket, so out_pending() alone reads a client 64 MB behind as
	// caught up. A peer's claim slows only its own world.
	size_t client_backlog = 0;
	// The next packet into out_buf, if it is empty and there is one
	void refill()
	{
		if(out_sent < out_buf.size())
			return;
		out_buf.clear();
		out_sent = 0;
		if(!out_latest.empty()){
			out_buf = std::move(out_latest.front().second);
			out_latest.pop_front();
		} else if(!out_queue.empty()){
			Queued &q = out_queue.front();
			out_buf = std::move(q.packet);
			auto f = ordered_first.find(q.name);
			if(f != ordered_first.end() && --f->second == 0)
				ordered_first.erase(f);
			auto l = queued_latest.find(q.name);
			if(l != queued_latest.end() && l->second == &q)
				queued_latest.erase(l);
			out_queue.pop_front();
		} else if(file && file_at < file->size()){
			const size_t n = std::min(file->size() - file_at,
					(size_t)256 * 1024);
			out_buf.assign(*file, file_at, n);
			file_at += n;
			return;
		} else {
			file.reset();
			return;
		}
		out_queued_bytes -= out_buf.size();
	}
	// A LatestOnly name's payload replaces an unsent one in the lane. Its
	// definition (the undroppable packet the stream writes ahead of the
	// first payload) goes ordered, and so does the first payload: at join
	// the queue holds the client's module files, and a placement in the
	// lane overtook them and was read before the client's luanti half had
	// subscribed -- dropped, never resent ([PLAYER_POS_RACE]). While they
	// are queued a newer payload takes the queued one's place -- its spot
	// behind the modules, not the back of the queue: appended behind the
	// newest chunks it never caught up over a slow link (the clock waited
	// 200 s at join over 2 % loss). one_piece: the packet is a single
	// fragment, so a replacement is one entry; a fragmented payload of a
	// LatestOnly name goes ordered whole (simplified: none of the three
	// LatestOnly names fragments in practice).
	void enqueue(const ss_ &name, ss_ &&packet, bool latest_only,
			bool droppable, bool one_piece)
	{
		const size_t size = packet.size();
		if(latest_only && droppable && !ordered_first.count(name)){
			// simplified: a scan, of at most the three LatestOnly names
			for(auto &pair : out_latest){
				if(pair.first == name){
					out_queued_bytes -= pair.second.size();
					out_queued_bytes += size;
					pair.second = std::move(packet);
					return;
				}
			}
			out_latest.emplace_back(name, std::move(packet));
		} else {
			if(latest_only && droppable && one_piece){
				auto l = queued_latest.find(name);
				if(l != queued_latest.end()){
					out_queued_bytes -= l->second->packet.size();
					out_queued_bytes += size;
					l->second->packet = std::move(packet);
					return;
				}
			}
			out_queue.push_back(Queued{name, std::move(packet), droppable});
			if(latest_only)
				ordered_first[name]++;
			if(latest_only && droppable && one_piece)
				queued_latest[name] = &out_queue.back();
		}
		out_queued_bytes += size;
	}

	// Bytes that go as they are, ahead of nothing and behind what is queued:
	// an HTTP response, a WebSocket control frame
	void queue_raw(ss_ &&data)
	{
		out_queued_bytes += data.size();
		out_queue.push_back(Queued{ss_(), std::move(data), false});
	}

	// What a client sends is at most this a packet: the largest anything
	// here takes is the floorplanner's import, 64 MiB
	static const size_t MAX_PACKET_BYTES = 80 * 1024 * 1024;
	Peer(){ packet_stream.m_max_packet_bytes = MAX_PACKET_BYTES; }
	Peer(Id id, sp_<interface::TCPSocket> socket):
		id(id), socket(socket){
		packet_stream.m_max_packet_bytes = MAX_PACKET_BYTES;
	}
};

// The server half of RFC 6455 and the little of HTTP that serves the web
// client ([WEB_CLIENT])
namespace web {

// A browser sends its request as soon as it has connected, and a native
// client sends a packet type definition as soon as it has connected, so
// either is known by its first bytes and only by them: a browser's
// speculative preconnect is quiet until it has a request to send
// ([WEB_SNIFF_PRECONNECT]). A quiet one goes at keepalive()'s silence
// limit, and so does a native client older than [WEB_CLIENT], which never
// speaks first.
static const size_t MAX_REQUEST_BYTES = 8 * 1024;
// An app's POST body ([STARPORT])
static const size_t MAX_API_BODY = 64 * 1024;
// A request that does not arrive, or a response nobody reads
static const int64_t HTTP_STALL_US = 10000000;
static const size_t MAX_FRAME_BYTES = 16 * 1024 * 1024;
// Peers at once, under what select() can watch (FD_SETSIZE, 1024 on Linux,
// and the module's own fds besides); see on_listen_event()
// On Windows FD_SETSIZE is a count of sockets, 64 unless raised, and a socket
// past it is never waited on at all.
#ifdef _WIN32
static const size_t MAX_PEERS = FD_SETSIZE > 80 ? 900 : FD_SETSIZE - 16;
#else
static const size_t MAX_PEERS = 900;
#endif
// From one address that is not loopback or a trusted proxy: a household
// behind one NAT, with room to spare
static const size_t MAX_PEERS_PER_ADDRESS = 32;

static ss_ base64(const ss_ &data)
{
	static const char *t =
			"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	ss_ r;
	for(size_t i = 0; i < data.size(); i += 3){
		uint32_t v = (uint8_t)data[i] << 16;
		if(i + 1 < data.size()) v |= (uint8_t)data[i + 1] << 8;
		if(i + 2 < data.size()) v |= (uint8_t)data[i + 2];
		r += t[(v >> 18) & 63];
		r += t[(v >> 12) & 63];
		r += i + 1 < data.size() ? t[(v >> 6) & 63] : '=';
		r += i + 2 < data.size() ? t[v & 63] : '=';
	}
	return r;
}

// The web client's files: a closed list of names, and nothing else is
// looked at. The file's name and its type, or null.
static const std::pair<ss_, ss_>* web_file(const ss_ &target)
{
	static const sm_<ss_, std::pair<ss_, ss_>> files = {
		{"/", {"index.html", "text/html; charset=utf-8"}},
		// [PLAY_PATH] /play for a game, /app for the rest: a link picks by
		// the listing's kind; /index.html for the links made before them
		{"/play", {"index.html", "text/html; charset=utf-8"}},
		{"/app", {"index.html", "text/html; charset=utf-8"}},
		{"/index.html", {"index.html", "text/html; charset=utf-8"}},
		{"/buildat.js", {"buildat.js", "application/javascript"}},
		{"/buildat.wasm", {"buildat.wasm", "application/wasm"}},
		{"/buildat.data", {"buildat.data", "application/octet-stream"}},
		// [WEB_MESH_OFF_THREAD] the client with threads, for an isolated page
		{"/buildat_mt.js", {"buildat_mt.js", "application/javascript"}},
		{"/buildat_mt.wasm", {"buildat_mt.wasm", "application/wasm"}},
		{"/buildat_mt.data", {"buildat_mt.data", "application/octet-stream"}},
		// [FAVICON] in the list so an app claiming "/" does not take it;
		// its default file lives beside the logo, not in the web client dir
		{"/favicon.ico", {"favicon.png", "image/png"}},
		// [JOIN_STRIPES] the page's loading stripes in the client's font
		{"/Fonts/OverpassMono-Regular.ttf",
				{"Fonts/OverpassMono-Regular.ttf", "font/ttf"}},
	};
	auto it = files.find(target);
	return it == files.end() ? nullptr : &it->second;
}

// [WEB_LOCAL_SERVER] An app's server built for the web, which the page's
// ?local=<app> runs in a worker: /local/<app>/buildat_server.{js,wasm,data}
// from local/<app>/ beside the web client (util/build_web_server.sh puts
// it there). Its name and its type, or ("", "").
static std::pair<ss_, ss_> local_file(const ss_ &target)
{
	static const sm_<ss_, ss_> types = {
		{"buildat_server.js", "application/javascript"},
		{"buildat_server.wasm", "application/wasm"},
		{"buildat_server.data", "application/octet-stream"},
	};
	if(target.compare(0, 7, "/local/") != 0)
		return {};
	const size_t sl = target.find('/', 7);
	if(sl == ss_::npos || sl == 7 || sl - 7 > 64)
		return {};
	for(size_t i = 7; i < sl; i++)
		if(!isalnum((unsigned char)target[i]) && target[i] != '_')
			return {};
	auto it = types.find(target.substr(sl + 1));
	if(it == types.end())
		return {};
	return {target.substr(1), it->second};
}

static ss_ lower(ss_ s)
{
	for(char &c : s)
		c = tolower((unsigned char)c);
	return s;
}

static ss_ trim(const ss_ &s)
{
	size_t a = s.find_first_not_of(" \t");
	if(a == ss_::npos)
		return "";
	return s.substr(a, s.find_last_not_of(" \t") - a + 1);
}

// A server's frame: never masked, always whole
static ss_ frame(int opcode, const ss_ &payload)
{
	ss_ r;
	r += (char)(0x80 | opcode);
	const uint64_t n = payload.size();
	if(n < 126){
		r += (char)n;
	} else if(n < 65536){
		r += (char)126;
		r += (char)(n >> 8);
		r += (char)n;
	} else {
		r += (char)127;
		for(int i = 7; i >= 0; i--)
			r += (char)(n >> (i * 8));
	}
	return r + payload;
}

// extra: more header lines, each ending in \r\n
static ss_ response(const ss_ &status, const ss_ &content_type,
		size_t content_length, const ss_ &extra = "")
{
	return "HTTP/1.1 "+status+"\r\n"
			"Content-Type: "+content_type+"\r\n"
			"Content-Length: "+itos((int64_t)content_length)+"\r\n"
			"Cache-Control: no-cache\r\n"+extra+
			"Connection: close\r\n\r\n";
}

}

struct Module: public interface::Module, public network::Interface
{
	interface::Server *m_server;
	sp_<interface::TCPSocket> m_listening_socket;
	// What listen_on() added
	sv_<sp_<interface::TCPSocket>> m_extra_listeners;
	sm_<Peer::Id, Peer> m_peers;
	sm_<int, Peer*> m_peers_by_socket;
	size_t m_next_peer_id = 1;
	// When the listening socket is waited on again (on_listen_event)
	int64_t m_accept_paused_until_us = 0;
	int64_t m_peers_full_logged_us = 0;
	// The game's answer to a peer that will not read; see SendPolicy in
	// api.h. Disconnect is what a game that never says anything gets: a
	// queue that grows without bound is a public server's memory
	// ([API_DEFAULTS_07])
	SendPolicy m_send_policy = SendPolicy::Disconnect;
	size_t m_max_queue_bytes = 8 * 1024 * 1024;
	int64_t m_grace_us = 30000000;
	bool m_will_restore_after_unload = false;
	up_<interface::Thread> m_thread;
	// The web client's files as last read, by name, kept while the file's
	// modification time and size are the same (its ETag)
	struct Deflated {
		std::mutex mutex;
		bool done = false;
		sp_<const ss_> data;
	};
	struct WebFile {
		ss_ etag;
		sp_<const ss_> body;
		// Made beside the module ([SELECT_BAD_FD]): about a second for the
		// wasm and as much for the data held the network module, and every
		// peer with it, on the first page load after a start
		sp_<Deflated> deflated;
	};
	sm_<ss_, WebFile> m_web_files;
	sv_<std::thread> m_deflaters;
	std::set<ss_> m_claimed_paths;
	bool m_page_has_no_game = false;
	// -1 until accounts says (a server without it says nothing)
	int m_has_admin = -1;
	// [PLAY_LINKS] set_ws_origins(): who gave them -> the origins
	sm_<ss_, sv_<ss_>> m_ws_origins;
	// [FAVICON] an app's override of /favicon.ico, served from memory; ""
	// falls back to the default PNG beside the logo
	ss_ m_favicon;
	// [FAVICON_SERVER_ICON] the admin's <user>/apps/<app>/server_icon.png,
	// read at start: the server's icon in the client's list and, ahead of
	// the app's, its favicon
	ss_ m_admin_favicon;
	// [PAGE_TITLE] set_page_title()'s two names
	ss_ m_admin_title, m_app_title;
	// [LAN_DISCOVERY]: what lan_announce() said, sent every 2 s while the
	// name is not ""
	ss_ m_lan_name;
	bool m_lan_account = false;
	int m_lan_fd = -1;
	int64_t m_lan_next_us = 0;
	// [SERVER_HEALTH]: since when, the gaps between the last minute's
	// ticks as this module got them, and the token that lets /health in
	// from elsewhere than this machine
	const int64_t m_start_us = interface::os::time_us();
	std::mutex m_health_mutex;
	std::deque<int64_t> m_tick_gaps_us;
	int64_t m_last_tick_us = 0;
	ss_ m_health_token;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server),
		m_listening_socket(interface::createTCPSocket())
	{
		log_d(MODULE, "network construct");
	}

	~Module()
	{
		log_d(MODULE, "network destruct");
		interface::lan_close(m_lan_fd);

		m_thread->request_stop();
		m_thread->join();
		for(std::thread &t : m_deflaters)
			t.join();

		if(m_will_restore_after_unload){
			if(m_listening_socket->good()){
				m_listening_socket->release_fd();
			}
			for(auto pair : m_peers){
				const Peer &peer = pair.second;
				if(peer.socket->good()){
					peer.socket->release_fd();
				}
			}
		}
	}

	void init()
	{
		log_d(MODULE, "network init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("core:shutdown"));

		// Don't start thread in constructor because in there this module is not
		// guaranteed to be available by server->access_module()
		m_thread.reset(interface::createThread(new NetworkThread(this)));
		m_thread->set_name("network/select");
		m_thread->start();
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_VOIDN("core:tick", on_tick)
		EVENT_VOIDN("core:shutdown", on_shutdown)
	}

	// **A goodbye** ([SERVE_UPDATE_SMOOTH] 4): every game peer is told why
	// before the server closes. util/serve_latest_release.sh writes
	// <user>/apps/<app>/shutdown_reason ("updating to 0.6.99") before its
	// SIGTERM, and then it is a restart, which a client waits out and
	// rejoins; without the file it is a shutdown. "1" or "0", then the
	// text. The file is in the app's directory because the box cannot read
	// the user path's top level.
	void on_shutdown()
	{
		const ss_ path = m_server->get_config().get<ss_>("user_path")+
				"/apps/"+m_server->get_app_id()+"/shutdown_reason";
		ss_ reason;
		{
			std::ifstream in(path);
			std::getline(in, reason);
		}
		reason = web::trim(reason).substr(0, 200);
		const bool restart = interface::fs::path_exists(path);
		if(restart)
			::remove(path.c_str());
		const ss_ data = restart ? "1The server is restarting" +
				(reason.empty() ? ss_() : ": "+reason) :
				"0The server is shutting down";
		for(auto &pair : m_peers){
			if(pair.second.game() && pair.second.hello_sent)
				send_u(pair.second, "network:goodbye", data);
		}
		// simplified: up to a second for a peer that is behind to take it;
		// one further behind than that leaves without it
		const int64_t until = interface::os::time_us() + 1000000;
		while(interface::os::time_us() < until){
			bool pending = false;
			for(auto &pair : m_peers){
				flush_peer(pair.second);
				pending = pending || (pair.second.game() &&
						pair.second.out_pending() > 0);
			}
			if(!pending)
				break;
			interface::os::sleep_us(10000);
		}
	}

	// A dedicated server announces itself to the LAN only when its admin
	// said so (--lan-announce NAME); a launcher's game through
	// lan_announce(), when its owner opens it to the LAN.
	// simplified: "account" is whether the app has builtin/accounts at
	// all; an open server with accounts says it needs one. The accounts
	// module's own rule when someone needs the true answer.
	void start_lan_from_config()
	{
		const ss_ name = m_server->get_config().get<ss_>("lan_announce");
		if(!name.empty())
			lan_announce(name, m_server->has_module("accounts"));
	}

	// **A notice from the server's admin** ([SERVE_UPDATE_POLITE] 2):
	// <user>/apps/<app>/notice, looked for once a second, its first line
	// (200 characters at most) sent to every game peer as network:notice
	// and the file removed. util/serve_latest_release.sh warns of an
	// update through it.
	int64_t m_notice_next_us = 0;
	void check_notice(int64_t now)
	{
		if(now < m_notice_next_us)
			return;
		m_notice_next_us = now + 1000000;
		const ss_ path = m_server->get_config().get<ss_>("user_path")+
				"/apps/"+m_server->get_app_id()+"/notice";
		if(!interface::fs::path_exists(path))
			return;
		ss_ text;
		{
			std::ifstream in(path);
			std::getline(in, text);
		}
		::remove(path.c_str());
		text = web::trim(text).substr(0, 200);
		if(text.empty())
			return;
		log_i(MODULE, "Notice to every client: %s", cs(text));
		for(auto &pair : m_peers){
			if(pair.second.playing())
				send_u(pair.second, "network:notice", text);
		}
	}

	void on_tick()
	{
		check_notice(interface::os::time_us());
		{
			const int64_t now = interface::os::time_us();
			std::lock_guard<std::mutex> lock(m_health_mutex);
			if(m_last_tick_us != 0)
				m_tick_gaps_us.push_back(now - m_last_tick_us);
			m_last_tick_us = now;
			// A minute at 30 ticks a second
			while(m_tick_gaps_us.size() > 1800)
				m_tick_gaps_us.pop_front();
		}
		if(m_lan_name.empty())
			return;
		const int64_t now = interface::os::time_us();
		if(now < m_lan_next_us)
			return;
		m_lan_next_us = now + 2000000;
		if(m_lan_fd == -1){
			m_lan_fd = interface::lan_socket(false);
			if(m_lan_fd == -1)
				return;
		}
		json::Value v = json::object();
		v.set("buildat_lan", (int64_t)1);
		v.set("name", m_lan_name);
		v.set("app", m_server->get_app_id());
		v.set("version", ss_(BUILDAT_VERSION));
		v.set("port", (int64_t)atoi(m_server->get_config().get<ss_>(
				"network_port").c_str()));
		v.set("players", (int64_t)list_peers().size());
		v.set("account", json::Value(m_lan_account));
		if(!interface::lan_send(m_lan_fd, v.stringify()))
			log_d(MODULE, "LAN announce not sent");
	}

	void lan_announce(const ss_ &name, bool account)
	{
		if(name != m_lan_name)
			log_i(MODULE, "%s", name.empty() ? "Not announced to the LAN" :
					("Announced to the LAN as \""+name+"\" on "+
					interface::LAN_GROUP+":"+itos(interface::LAN_PORT)).c_str());
		m_lan_name = name.substr(0, 64);
		m_lan_account = account;
		m_lan_next_us = 0;
	}

	// [SERVER_HEALTH] the token in the app's user directory, made at the
	// first start: a monitor elsewhere than this machine sends it
	void load_health_token()
	{
		const ss_ path = m_server->get_config().get<ss_>("user_path")+
				"/apps/"+m_server->get_app_id()+"/health_token.txt";
		std::ifstream in(path);
		std::getline(in, m_health_token);
		m_health_token = web::trim(m_health_token);
		if(m_health_token.size() >= 16)
			return;
		std::random_device rd;
		char hex[33];
		for(int i = 0; i < 4; i++)
			snprintf(hex + i * 8, 9, "%08x", (unsigned)rd());
		m_health_token = hex;
		interface::fs::create_directories(
				interface::fs::strip_file_name(path));
		std::ofstream out(path);
		out<<m_health_token<<"\n";
		if(out.good())
			log_i(MODULE, "The /health token is in %s", cs(path));
		else
			log_w(MODULE, "Could not write %s: /health and /metrics answer "
					"only this machine", cs(path));
	}

	// [SERVER_HEALTH] what /health, /metrics and the admin's page say
	struct Health {
		int64_t uptime_s, players, memory_bytes;
		double tick_gap_ms_avg, tick_gap_ms_max;
	};
	Health health()
	{
		Health h;
		int64_t sum = 0, max = 0;
		size_t n = 0;
		{
			std::lock_guard<std::mutex> lock(m_health_mutex);
			for(int64_t g : m_tick_gaps_us){
				sum += g;
				max = std::max(max, g);
			}
			n = m_tick_gaps_us.size();
		}
		h.uptime_s = (interface::os::time_us() - m_start_us) / 1000000;
		h.players = (int64_t)list_peers().size();
		h.memory_bytes = interface::os::memory_bytes();
		// The tick is 1/30 s; a gap well over it is a server falling behind
		h.tick_gap_ms_avg = n ? (double)sum / n / 1000.0 : 0.0;
		h.tick_gap_ms_max = (double)max / 1000.0;
		return h;
	}

	ss_ health_json()
	{
		const Health h = health();
		json::Value v = json::object();
		v.set("ok", json::Value(true));
		v.set("app", m_server->get_app_id());
		v.set("version", ss_(BUILDAT_VERSION));
		v.set("uptime_s", h.uptime_s);
		v.set("players", h.players);
		v.set("tick_gap_ms_avg", h.tick_gap_ms_avg);
		v.set("tick_gap_ms_max", h.tick_gap_ms_max);
		v.set("memory_bytes", h.memory_bytes);
		if(m_has_admin >= 0)
			v.set("admin", json::Value(m_has_admin > 0));
		return v.stringify();
	}

	// Prometheus' text format
	ss_ health_metrics()
	{
		const Health h = health();
		char b[1024];
		snprintf(b, sizeof b,
				"# TYPE buildat_up gauge\nbuildat_up 1\n"
				"# TYPE buildat_info gauge\n"
				"buildat_info{app=\"%s\",version=\"%s\"} 1\n"
				"# TYPE buildat_uptime_seconds gauge\n"
				"buildat_uptime_seconds %lld\n"
				"# TYPE buildat_players gauge\nbuildat_players %lld\n"
				"# TYPE buildat_tick_gap_seconds gauge\n"
				"buildat_tick_gap_seconds{stat=\"avg\"} %.6f\n"
				"buildat_tick_gap_seconds{stat=\"max\"} %.6f\n"
				"# TYPE buildat_memory_bytes gauge\n"
				"buildat_memory_bytes %lld\n",
				cs(m_server->get_app_id()), BUILDAT_VERSION,
				(long long)h.uptime_s, (long long)h.players,
				h.tick_gap_ms_avg / 1000.0, h.tick_gap_ms_max / 1000.0,
				(long long)h.memory_bytes);
		return b;
	}

	// /health and /metrics: this machine's, unless through a proxy (any
	// forwarding header says so), or anyone's with the token
	bool health_allowed(const Peer &peer, sm_<ss_, ss_> &headers,
			const ss_ &query)
	{
		if(loopback(peer.socket->get_remote_address()) &&
				headers["x-forwarded-for"].empty() &&
				headers["forwarded"].empty() && headers["x-real-ip"].empty())
			return true;
		ss_ given = headers["authorization"];
		if(given.compare(0, 7, "Bearer ") == 0)
			given = web::trim(given.substr(7));
		else
			given = query.compare(0, 6, "token=") == 0 ? query.substr(6) : "";
		if(given.size() != m_health_token.size() || m_health_token.empty())
			return false;
		unsigned char d = 0;
		for(size_t i = 0; i < given.size(); i++)
			d |= given[i] ^ m_health_token[i];
		return d == 0;
	}

	void on_start()
	{
		load_health_token();
		m_admin_favicon = interface::fs::read_icon_png(
				m_server->get_config().get<ss_>("user_path")+"/apps/"+
				m_server->get_app_id()+"/server_icon.png");
		ss_ address = m_server->get_config().get<ss_>("network_address");
		ss_ port = m_server->get_config().get<ss_>("network_port");
		// Deflated before the first page load asks
		for(const char *name : {"buildat.js", "buildat.wasm", "buildat.data",
				"buildat_mt.js", "buildat_mt.wasm", "buildat_mt.data"}){
			const ss_ path = web_client_path()+"/"+name;
			struct stat st;
			if(stat(path.c_str(), &st) == 0)
				load_web_file(name, path, "");
		}

		if(!m_listening_socket->bind_fd(address, port) ||
				!m_listening_socket->listen_fd()){
			log_i(MODULE, "Failed to bind to %s:%s, fd=%i", cs(address), cs(port),
					m_listening_socket->fd());
			// We don't want to be in this state for any amount of time; it will
			// confuse the hell out of everybody otherwise
			m_server->shutdown(1, "Failed to bind socket");
			throw Exception("Failed to bind socket");
			return;
		} else {
			log_i(MODULE, "Listening at %s:%s, fd=%i", cs(address), cs(port),
					m_listening_socket->fd());
#ifdef _WIN32
			// Boxed, the client that started this server comes by a pipe;
			// BUILDAT_PIPE=1 makes one unboxed too, outside a container's
			// namespace, which is how Wine drives it
			const bool boxed = m_server->get_config().get<bool>("boxed");
			const char *env = getenv("BUILDAT_PIPE");
			if((boxed || (env && ss_(env) == "1")) && !g_pipe_started.exchange(true)){
				const ss_ name = ss_("\\\\.\\pipe\\") +
						(boxed ? "LOCAL\\" : "")+"buildat-"+port;
				std::thread(pipe_listen, name).detach();
				log_i(MODULE, "Listening at %s too", cs(name));
				// The firewall's question ([PROCESS_SANDBOX] B 3)
				if(boxed)
					log_i(MODULE, "Windows asks the first time whether to let "
							"others reach this server; its default lets in "
							"the network the machine is on (public or "
							"private), and the other kind needs its box "
							"ticked too");
			}
#endif
			log_i(MODULE, "STATUS Listening");
		}
		start_lan_from_config();
	}

	void on_unload()
	{
		log_v(MODULE, "on_unload");
		m_will_restore_after_unload = true;

		// A connection that is not a game peer is not carried over: it has
		// a request or a response half way, and the next module would not
		// know. The browser asks again.
		sv_<Peer::Id> not_game;
		for(auto &pair : m_peers){
			if(!pair.second.game())
				not_game.push_back(pair.first);
		}
		for(Peer::Id id : not_game)
			drop_peer(id);

		int listening_fd = m_listening_socket->fd();
		sv_<std::tuple<Peer::Id, int>> peer_restore_info;
		sv_<Peer::Id> websocket_peers;
		for(auto &pair : m_peers){
			Peer &peer = pair.second;
			peer_restore_info.push_back(std::tuple<Peer::Id, int>(
					peer.id, peer.socket->fd()));
			if(peer.kind == Peer::Kind::WebSocket)
				websocket_peers.push_back(peer.id);
		}

		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(listening_fd);
			ar(peer_restore_info);
			ar(websocket_peers);
		}
		m_server->tmp_store_data("network:restore_info", os.str());
	}

	void on_continue()
	{
		log_v(MODULE, "on_continue");
		start_lan_from_config();
		ss_ data = m_server->tmp_restore_data("network:restore_info");
		// name, content, path
		int listening_fd;
		sv_<std::tuple<Peer::Id, int>> peer_restore_info;
		sv_<Peer::Id> websocket_peers;
		std::istringstream is(data, std::ios::binary);
		{
			cereal::PortableBinaryInputArchive ar(is);
			ar(listening_fd);
			ar(peer_restore_info);
			// Not there when the module that unloaded predates WebSockets
			try {
				ar(websocket_peers);
			} catch(std::exception &e){
			}
		}

		m_listening_socket.reset(interface::createTCPSocket(listening_fd));

		for(auto &tuple : peer_restore_info){
			Peer::Id peer_id = std::get<0>(tuple);
			int fd = std::get<1>(tuple);
			log_i(MODULE, "Restoring peer %i: fd=%i", peer_id, fd);
			sp_<interface::TCPSocket> socket(interface::createTCPSocket(fd));
			m_peers[peer_id] = Peer(peer_id, socket);
			m_peers_by_socket[socket->fd()] = &m_peers[peer_id];
			// simplified: a frame half received when the module unloaded is
			// lost, the same as a native peer's half packet in socket_buffer
			if(std::find(websocket_peers.begin(), websocket_peers.end(),
					peer_id) != websocket_peers.end())
				m_peers[peer_id].kind = Peer::Kind::WebSocket;
			m_peers[peer_id].hello_seen = true;
			m_peers[peer_id].hello_sent = true;
		}
	}

	void on_listen_event(int event_fd)
	{
		log_v(MODULE, "network: on_listen_event(): fd=%i", event_fd);
		// Create socket
		sp_<interface::TCPSocket> socket(interface::createTCPSocket());
		// Accept connection. One that cannot be accepted -- out of file
		// descriptors -- stays in the backlog and keeps the listening
		// socket readable, so the listening socket is left out of the
		// wait for a moment rather than spun on; and nothing is stored,
		// where a peer with no socket was ([SECURITY_RUN_1]).
		interface::TCPSocket *listener = m_listening_socket.get();
		for(auto &l : m_extra_listeners){
			if(l->fd() == event_fd)
				listener = l.get();
		}
		if(!socket->accept_fd(*listener)){
			m_accept_paused_until_us = interface::os::time_us() + 200000;
			return;
		}
		// No more peers than the wait can watch: select() takes fds under
		// FD_SETSIZE, and every peer is one. Past the cap a connection is
		// accepted and closed, which empties the backlog as it goes.
		if(m_peers.size() >= web::MAX_PEERS){
			if(m_peers_full_logged_us + 10000000 < interface::os::time_us()){
				m_peers_full_logged_us = interface::os::time_us();
				log_w(MODULE, "%zu peers: refusing new connections",
						m_peers.size());
			}
			socket->close_fd();
			return;
		}
		// And no more than MAX_PEERS_PER_ADDRESS from one address, so that
		// one host cannot take every place ([SECURITY_RUN_1]). Loopback and
		// the trusted proxies carry many players each and are not counted.
		const ss_ from = socket->get_remote_address();
		if(!loopback(from) && !trusted_proxy(from)){
			const ss_ key = network::address_key(from);
			size_t same = 0;
			for(auto &pair : m_peers)
				same += network::address_key(
						pair.second.socket->get_remote_address()) == key;
			if(same >= web::MAX_PEERS_PER_ADDRESS){
				if(m_peers_full_logged_us + 10000000 < interface::os::time_us()){
					m_peers_full_logged_us = interface::os::time_us();
					log_w(MODULE, "%s has %zu connections: refusing more from it",
							cs(from), same);
				}
				socket->close_fd();
				return;
			}
		}
		// A peer's socket must not block: a send that waits for a client to
		// read holds this module, and everything that wants to send
		// anything waits behind it. What does not fit waits in the peer's
		// own queue instead; see flush_peer().
		if(!socket->set_nonblocking(true)){
			log_w(MODULE, "Could not make peer socket non-blocking; a client "
					"that stops reading will stall the server");
		}
		// Store socket. The game hears of it once sniff() knows what it is.
		Peer::Id peer_id = m_next_peer_id++;
		m_peers[peer_id] = Peer(peer_id, socket);
		m_peers_by_socket[socket->fd()] = &m_peers[peer_id];
		Peer &peer = m_peers[peer_id];
		peer.kind = Peer::Kind::Sniff;
		peer.accepted_us = interface::os::time_us();
	}

	// A reverse proxy's client ([FP_ACCESS] 6): believed only from the
	// addresses web_trusted_proxies names (comma separated; loopback by
	// default, which is nginx on the same box). The last entry is the one
	// the proxy added; one that is not an address is ignored.
	bool trusted_proxy(const ss_ &from)
	{
		const ss_ trusted = m_server->get_config().get<ss_>(
				"web_trusted_proxies");
		size_t at = 0;
		while(at <= trusted.size()){
			size_t comma = trusted.find(',', at);
			if(comma == ss_::npos)
				comma = trusted.size();
			if(web::trim(trusted.substr(at, comma - at)) == from)
				return true;
			at = comma + 1;
		}
		return false;
	}
	static bool loopback(const ss_ &a)
	{
		return a.compare(0, 4, "127.") == 0 || a == "::1" ||
				a.compare(0, 11, "::ffff:127.") == 0;
	}
	ss_ forwarded_for(const Peer &peer, const ss_ &header)
	{
		if(header.empty())
			return "";
		if(!trusted_proxy(peer.socket->get_remote_address()))
			return "";
		size_t comma = header.find_last_of(',');
		ss_ last = web::trim(comma == ss_::npos ? header : header.substr(comma + 1));
		if(last.empty() || last.size() > 45)
			return "";
		for(char c : last)
			if(!(isxdigit((unsigned char)c) || c == '.' || c == ':'))
				return "";
		return last;
	}

	// **A WebSocket from this server's own page only** ([SECURITY_RUN_1]):
	// a browser lets any site's script open one to any address and says
	// which site in Origin, so without this a page out on the web joined
	// the game a launcher keeps on 127.0.0.1 as a player. A request with
	// no Origin is no browser's; one through the trusted proxy has come
	// past the deployment's public face, which is anyone's anyway.
	// Otherwise the page's origin is the address it was asked for, and an
	// address that reached loopback is a loopback name -- a name rebound
	// to 127.0.0.1 is the same site to the browser, and not to this
	static bool ws_origin_ok(const ss_ &origin, const ss_ &host,
			const ss_ &local_address, bool through_proxy)
	{
		if(origin.empty() || through_proxy)
			return true;
		const size_t s = origin.find("://");
		if(s == ss_::npos || web::lower(origin.substr(s + 3)) != web::lower(host))
			return false;
		if(!loopback(local_address))
			return true;
		ss_ name, port;
		if(!interface::split_host_port(host, &name, &port, ""))
			return false;
		name = web::lower(name);
		return name == "localhost" || name == "::1" ||
				name.compare(0, 4, "127.") == 0;
	}

	void emit_connected(Peer &peer)
	{
		log_i(MODULE, "Client %zu from %s connected%s%s",
				peer.id, cs(peer.address()),
				peer.kind == Peer::Kind::WebSocket ? " (WebSocket)" : "",
				peer.forwarded_for.empty() ? "" :
				(" through "+peer.socket->get_remote_address()).c_str());
		send_unordered(peer);
		PeerInfo pinfo;
		pinfo.id = peer.id;
		pinfo.address = peer.address();
		pinfo.web = peer.kind == Peer::Kind::WebSocket;
		m_server->emit_event("network:client_connected", new NewClient(pinfo));
	}

	// **What the client may handle out of order** ([NET_CHANNELS]; user,
	// 2026-09-30): the LatestOnly names, whose order against the rest does
	// not matter. A client that cannot keep up with a world arriving has the
	// backlog in its own buffer, not in this queue, and an answer to a menu
	// waited behind it for a minute; a client told these handles them first.
	void send_unordered(Peer &peer)
	{
		sv_<ss_> names(m_latest_only.begin(), m_latest_only.end());
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(names);
		}
		send_u(peer, "core:unordered", os.str());
	}

	void become_native(Peer &peer)
	{
		peer.kind = Peer::Kind::Native;
		peer.socket_buffer.append(peer.http_request);
		peer.http_request.clear();
		input_packets(peer);
	}

	// The peer's core:hello, its first packet: the game hears of the peer
	// if the two play together, and otherwise the peer is told why not
	void take_hello(Peer &peer, const ss_ &data)
	{
		ss_ refusal;
		try {
			const interface::Hello h = interface::hello_of(data);
			log_v(MODULE, "Peer %zu: Buildat %s, protocol %u-%u", peer.id,
					cs(h.version), h.protocol_min, h.protocol_max);
			refusal = interface::hello_refusal(h, "client");
		} catch(interface::RecordError &e){
			refusal = e.what();
		}
		// [SERVER_FREE_RUN]: its clock is not the client's
		if(refusal.empty() && m_server->get_config().get<bool>("free_run"))
			refusal = "This server is free-running (a headless check's)";
		if(!refusal.empty()){
			log_i(MODULE, "Peer %zu refused: %s", peer.id, cs(refusal));
			send_u(peer, "network:goodbye", "0"+refusal);
			peer.closing = true;
			peer.linger_until_us = interface::os::time_us() + 10000000;
			return;
		}
		peer.hello_seen = true;
		emit_connected(peer);
	}

	// **A client from before the hello** (0.6): its first packet is a
	// core:define_packet_type in the framing without the flags byte. It is
	// told why in that framing -- the definition of network:goodbye, then
	// it -- which every 0.6 client since [SERVE_UPDATE_SMOOTH] shows.
	void refuse_old_client(Peer &peer)
	{
		auto packet = [](unsigned type, const ss_ &data){
			ss_ p;
			p += (char)(type & 0xff);
			p += (char)(type>>8 & 0xff);
			for(int i = 0; i < 4; i++)
				p += (char)(data.size()>>(8 * i) & 0xff);
			return p + data;
		};
		const ss_ name = "network:goodbye";
		ss_ def;
		def += (char)100;
		def += (char)0;
		for(int i = 0; i < 4; i++)
			def += (char)(name.size()>>(8 * i) & 0xff);
		def += name;
		const ss_ out = packet(0, def) + packet(100, ss_("0")+
				"The server runs Buildat "+BUILDAT_VERSION+", newer than this "
				"client plays with: update Buildat to join it");
		log_i(MODULE, "Peer %zu: a client from before 0.7; refused",
				peer.id);
		peer.enqueue("network:goodbye", peer.kind == Peer::Kind::WebSocket ?
				web::frame(2, out) : ss_(out), false, false, true);
		flush_peer(peer);
		peer.socket_buffer.clear();
		peer.closing = true;
		peer.linger_until_us = interface::os::time_us() + 10000000;
	}

	// Whether the peer is to be kept. The native protocol's first bytes are
	// a packet's type, and the first packet is core:hello, type 2 (before
	// 0.7 core:define_packet_type, type 0): they never read as "GET "
	// (which as a type is 0x4547).
	bool sniff(Peer &peer)
	{
		// "POST " as well, for an app's API ([STARPORT]): its first byte is
		// not 0 either
		static const ss_ methods[] = {"GET ", "POST "};
		bool maybe = false;
		for(const ss_ &m : methods){
			const size_t n = std::min(peer.http_request.size(), m.size());
			if(peer.http_request.compare(0, n, m, 0, n) != 0)
				continue;
			if(n < m.size()){
				maybe = true;
				continue;
			}
			peer.kind = Peer::Kind::Http;
			return handle_http(peer);
		}
		if(!maybe)
			become_native(peer);
		return true;
	}

	// Whether the peer is to be kept
	bool handle_http(Peer &peer)
	{
		const ss_ &req = peer.http_request;
		const size_t end = req.find("\r\n\r\n");
		if(end == ss_::npos)
			return req.size() <= web::MAX_REQUEST_BYTES;
		if(end + 4 > web::MAX_REQUEST_BYTES)
			return false;
		// "<method> <target> HTTP/1.1", then "Name: value" lines
		size_t eol = req.find("\r\n");
		const ss_ line = req.substr(0, eol);
		const size_t sp0 = line.find(' ');
		if(sp0 == ss_::npos)
			return false;
		const ss_ method = line.substr(0, sp0);
		const size_t sp = line.find(' ', sp0 + 1);
		if(sp == ss_::npos || line.compare(sp, 6, " HTTP/") != 0)
			return false;
		ss_ target = line.substr(sp0 + 1, sp - sp0 - 1);
		const size_t qm = target.find('?');
		const ss_ query = qm == ss_::npos ? ss_() : target.substr(qm + 1);
		target = target.substr(0, qm);
		sm_<ss_, ss_> headers;
		for(size_t at = eol + 2; at < end; at = eol + 2){
			eol = req.find("\r\n", at);
			const ss_ h = req.substr(at, eol - at);
			const size_t colon = h.find(':');
			if(colon == ss_::npos)
				return false;
			headers[web::lower(web::trim(h.substr(0, colon)))] =
					web::trim(h.substr(colon + 1));
		}
		// A POST's body, by its length, which may be still coming
		size_t body_len = 0;
		if(method == "POST"){
			const ss_ &cl = headers["content-length"];
			// At most nine digits: stoi() throws past INT_MAX, and a throw
			// here ends the network thread and with it the server
			if(cl.empty() || cl.size() > 9 ||
					cl.find_first_not_of("0123456789") != ss_::npos)
				return false;
			body_len = (size_t)stoi(cl);
			if(body_len > web::MAX_API_BODY)
				return false;
			if(req.size() < end + 4 + body_len)
				return true;
		}
		const ss_ rest = req.substr(end + 4);
		peer.http_request.clear();

		if(method == "GET" && (target == "/health" || target == "/metrics")){
			peer.closing = true;
			if(!health_allowed(peer, headers, query)){
				ss_ body = "The token from the server's health_token.txt\n";
				peer.queue_raw(web::response("403 Forbidden",
						"text/plain; charset=utf-8", body.size()) + body);
				return true;
			}
			const bool json = target == "/health";
			const ss_ body = json ? health_json()+"\n" : health_metrics();
			peer.queue_raw(web::response("200 OK", json ?
					"application/json" : "text/plain; version=0.0.4",
					body.size()) + body);
			return true;
		}

		// **An app's API** ([STARPORT]): handed to the modules, whose
		// answer is http_respond()'s. A WebSocket upgrade wins over a
		// claimed path, though: the web client connects to "/", which an
		// app like Hearth claims for its HTML ([FORUM_WEB_CLIENT]) -- the
		// upgrade below must get it, not the page. /api/ is never upgraded.
		const bool ws_upgrade =
				web::lower(headers["upgrade"]).find("websocket") != ss_::npos;
		// **The API is versioned** ([COMPAT_BREAK_07] 8d): /api/v1/...;
		// an /api/ path without it is a client before 0.7, told so in the
		// APIs' own answer, which a 0.6 client shows as the error
		if(target.compare(0, 5, "/api/") == 0 &&
				target.compare(0, 8, "/api/v1/") != 0){
			peer.closing = true;
			const ss_ body = "{\"ok\":false,\"code\":\"upgrade_required\","
					"\"error\":\"This needs a newer Buildat: update it\"}";
			peer.queue_raw(web::response("200 OK", "application/json",
					body.size(), "Access-Control-Allow-Origin: *\r\n") + body);
			return true;
		}
		if(target.compare(0, 5, "/api/") == 0 ||
				(claimed(target) && !ws_upgrade)){
			peer.api_waiting = true;
			const ss_ address = forwarded_for(peer, headers["x-forwarded-for"]);
			m_server->emit_event("network:http_request", new HttpRequest(
					peer.id, method, target, query, rest.substr(0, body_len),
					address.empty() ? peer.socket->get_remote_address() :
					address, headers["origin"], headers["host"]));
			return true;
		}
		if(method != "GET"){
			peer.closing = true;
			ss_ body = "Only GET here\n";
			peer.queue_raw(web::response("405 Method Not Allowed",
					"text/plain; charset=utf-8", body.size()) + body);
			return true;
		}

		if(ws_upgrade){
			const ss_ &key = headers["sec-websocket-key"];
			if(key.empty())
				return false;
			if(!ws_origin_ok(headers["origin"], headers["host"],
					peer.socket->get_local_address(),
					!forwarded_for(peer, headers["x-forwarded-for"]).empty()) &&
					!ws_origin_given(headers["origin"])){
				log_w(MODULE, "Refused a WebSocket from %s: a page of %s, "
						"asking for %s", cs(peer.socket->get_remote_address()),
						cs(headers["origin"]), cs(headers["host"]));
				peer.closing = true;
				ss_ body = "Not from this server's page\n";
				peer.queue_raw(web::response("403 Forbidden",
						"text/plain; charset=utf-8", body.size()) + body);
				return true;
			}
			ss_ r = "HTTP/1.1 101 Switching Protocols\r\n"
					"Upgrade: websocket\r\n"
					"Connection: Upgrade\r\n"
					"Sec-WebSocket-Accept: "+web::base64(interface::sha1::calculate(
					key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))+"\r\n";
			// Emscripten's socket emulation asks for it.
			// simplified: a substring match on the offered list
			if(web::lower(headers["sec-websocket-protocol"]).find("binary") !=
					ss_::npos)
				r += "Sec-WebSocket-Protocol: binary\r\n";
			r += "\r\n";
			// Ahead of anything the game sends, which only starts on the
			// event below
			peer.queue_raw(std::move(r));
			peer.ws_in = rest;
			peer.forwarded_for = forwarded_for(peer, headers["x-forwarded-for"]);
			if(ws_claimed(target)){
				peer.kind = Peer::Kind::RawWebSocket;
				m_server->emit_event("network:ws_open", new HttpRequest(
						peer.id, method, target, query, "", peer.address(),
						headers["origin"], headers["host"]));
				return deframe(peer);
			}
			peer.kind = Peer::Kind::WebSocket;
			return deframe(peer);
		}

		peer.closing = true;
		// [FAVICON] the admin's icon, then the app's own, kept in memory, win
		// over the default
		const ss_ &favicon = !m_admin_favicon.empty() ? m_admin_favicon :
				m_favicon;
		if(target == "/favicon.ico" && !favicon.empty()){
			peer.queue_raw(web::response("200 OK", "image/png",
					favicon.size()) + favicon);
			return true;
		}
		const std::pair<ss_, ss_> local = web::local_file(target);
		struct stat local_st;
		const std::pair<ss_, ss_> *wf_name = local.first.empty() ?
				web::web_file(target) : stat((web_client_path()+"/"+
				local.first).c_str(), &local_st) == 0 ? &local : nullptr;
		if(!wf_name){
			ss_ body = "Not found\n";
			peer.queue_raw(web::response("404 Not Found",
					"text/plain; charset=utf-8", body.size()) + body);
			return true;
		}
		// The default favicon lives beside the logo (always installed),
		// not in the optional web client dir; the font beside it
		const ss_ base = target == "/favicon.ico" ||
				target == "/Fonts/OverpassMono-Regular.ttf" ?
				m_server->get_config().get<ss_>("share_path")+"/client/data" :
				web_client_path();
		const ss_ path = base+"/"+wf_name->first;
		// **A reload does not download the client again** (user,
		// 2026-10-01: a phone reloads the page each time it comes back): the
		// browser asks with the ETag it has, and the same file is a 304
		// [PAGE_TITLE] index.html carries the server's title: in its ETag too
		const bool index = wf_name->first == "index.html";
		const WebFile *wf = load_web_file(wf_name->first, path,
				index ? page_title() : "");
		if(!wf){
			ss_ body = "The web client is not here: "+wf_name->first+
					" is not in the server's web_client_path.\n";
			peer.queue_raw(web::response("404 Not Found",
					"text/plain; charset=utf-8", body.size()) + body);
			return true;
		}
		// [WEB_LOCAL_SERVER] The page that runs a local server, and the
		// server's files, cross-origin isolated: its threads share memory.
		// Only that page: an isolated page's popup has no opener, and the
		// Starport ID's sign-in is one.
		// [WEB_MESH_OFF_THREAD] And the threaded client's script, which its
		// workers load too: an isolated page's worker needs the header.
		// The play page isolated for its threads where its address asks,
		// ?isolated=1.
		// simplified: asked for, not the default, until the Starport's
		// /authorize can answer an isolated page (it posts to its opener,
		// which an isolated page's popup has none of): then every page,
		// the sign-in ending on a page of this server's that tells the
		// game's by BroadcastChannel
		const bool isolated = !local.first.empty() ||
				(index && (!query_value(query, "local").empty() ||
				query_value(query, "isolated") == "1")) ||
				wf_name->first == "buildat_mt.js";
		const ss_ cache = (wf->etag.empty() ? "" : "ETag: "+wf->etag+"\r\n")+
				(isolated ? "Cross-Origin-Opener-Policy: same-origin\r\n"
				"Cross-Origin-Embedder-Policy: require-corp\r\n"
				"Cross-Origin-Resource-Policy: same-origin\r\n" : "");
		const ss_ &etag = wf->etag;
		if(!etag.empty() && headers["if-none-match"].find(etag) != ss_::npos){
			log_v(MODULE, "Peer %zu: %s not modified", peer.id, cs(path));
			peer.queue_raw("HTTP/1.1 304 Not Modified\r\n"+cache+
					"Cache-Control: no-cache\r\nConnection: close\r\n\r\n");
			return true;
		}
		// simplified: a substring match; "deflate;q=0" would still get it
		// Until its deflated copy is made, a file goes as it is
		bool deflate =
				web::lower(headers["accept-encoding"]).find("deflate") != ss_::npos;
		sp_<const ss_> body = wf->body;
		if(deflate){
			std::lock_guard<std::mutex> lock(wf->deflated->mutex);
			if(wf->deflated->done)
				body = wf->deflated->data;
			else
				deflate = false;
		}
		log_v(MODULE, "Peer %zu: serving %s (%zu bytes%s)", peer.id,
				cs(path), body->size(), deflate ? ", deflated" : "");
		// It goes out through the peer's queue like anything else, as far as
		// the socket takes it at a time.
		// The whole file is kept in memory once; each download reads it
		// as its socket drains (Peer::refill), so a slow reader holds no
		// copy of its own
		peer.queue_raw(web::response("200 OK", wf_name->second,
				body->size(), cache+(deflate ? "Content-Encoding: deflate\r\n" :
				"")+"Vary: Accept-Encoding\r\n"));
		peer.file = body;
		peer.file_at = 0;
		return true;
	}

	// A web client file, read again when its ETag changes, and its deflated
	// copy started on a thread of its own; null if it cannot be read.
	// title: index.html's ([PAGE_TITLE]), "" for the others
	const WebFile* load_web_file(const ss_ &name, const ss_ &path,
			const ss_ &title)
	{
		const bool index = name == "index.html";
		const ss_ apps = index && m_page_has_no_game ? local_apps() : "";
		struct stat st;
		const ss_ etag = stat(path.c_str(), &st) == 0 ? "\""+
				itos((int64_t)st.st_mtime)+"-"+itos((int64_t)st.st_size)+
				(index ? "-"+itos((int64_t)(std::hash<ss_>()(title+
				(m_page_has_no_game ? "\n"+apps : "")) >> 1)) : "")+
				"\"" : "";
		WebFile &wf = m_web_files[name];
		if(!etag.empty() && wf.etag == etag)
			return &wf;
		wf = WebFile();
		std::ifstream f(path, std::ios::binary);
		ss_ body;
		if(f.good()){
			std::ostringstream os(std::ios::binary);
			os<<f.rdbuf();
			body = os.str();
		}
		if(!f.good() || body.empty()){
			log_w(MODULE, "Web client file not found: %s", cs(path));
			return nullptr;
		}
		const size_t at = index ? body.find("<title>Buildat</title>") :
				ss_::npos;
		if(at != ss_::npos)
			body.replace(at, 22, "<title>"+title+"</title>");
		// [PLAY_OOTB] a page with no game of its own: index.html's server
		// line made null, so the page starts on the launch menu
		static const ss_ SERVER_LINE = "var server = host + ':' + port;";
		const size_t sl = index && m_page_has_no_game ?
				body.find(SERVER_LINE) : ss_::npos;
		if(sl != ss_::npos)
			body.replace(sl, SERVER_LINE.size(), "var server = null;");
		else if(index && m_page_has_no_game)
			log_w(MODULE, "%s has no server line to set null", cs(path));
		// [WEB_LOCAL_SERVER] And the apps it may run in the page
		static const ss_ APPS_LINE = "var local_apps = [];";
		const size_t al = apps.empty() ? ss_::npos : body.find(APPS_LINE);
		if(al != ss_::npos)
			body.replace(al, APPS_LINE.size(), "var local_apps = ["+apps+"];");
		wf.body.reset(new ss_(std::move(body)));
		wf.deflated.reset(new Deflated());
		wf.etag = etag;
		// simplified: zlib's stream, which is what HTTP's "deflate" is and
		// every browser takes; gzip only adds a header and a CRC
		sp_<const ss_> in = wf.body;
		sp_<Deflated> out = wf.deflated;
		m_deflaters.emplace_back([in, out](){
			std::ostringstream os(std::ios::binary);
			interface::compress_zlib(*in, os, 6);
			std::lock_guard<std::mutex> lock(out->mutex);
			out->data.reset(new ss_(os.str()));
			out->done = true;
		});
		return &wf;
	}

	// [WEB_LOCAL_SERVER] The apps with a server for the page beside the web
	// client, as a JavaScript list's items: 'a', 'b'. Only names that
	// local_file() would serve; not one beginning with "_", the engine's
	// own (_aitta, the server for Aitta's packages, [WEB_LOCAL_AITTA])
	ss_ local_apps()
	{
		sv_<ss_> names;
		const ss_ dir = web_client_path()+"/local/";
		for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
			const ss_ wasm = "/local/"+n.name+"/buildat_server.wasm";
			if(n.is_directory && n.name[0] != '_' &&
					!web::local_file(wasm).first.empty() &&
					interface::fs::path_exists(dir+n.name+"/buildat_server.wasm"))
				names.push_back(n.name);
		}
		std::sort(names.begin(), names.end());
		ss_ r;
		for(const ss_ &n : names)
			r += (r.empty() ? "'" : ", '")+n+"'";
		return r;
	}

	ss_ web_client_path()
	{
		const ss_ &path = m_server->get_config().get<ss_>("web_client_path");
		if(!path.empty())
			return path;
		return m_server->get_config().get<ss_>("share_path")+"/web";
	}

	// Takes what is whole of peer.ws_in; the payload is stream bytes, the
	// same as a native peer's. Whether the peer is to be kept.
	bool deframe(Peer &peer)
	{
		const ss_ &b = peer.ws_in;
		size_t at = 0;
		for(;;){
			if(peer.closing)
				break;
			if(b.size() - at < 2)
				break;
			const uint8_t b0 = b[at], b1 = b[at + 1];
			const bool fin = b0 & 0x80;
			const int opcode = b0 & 0x0f;
			// A client's frames are masked, always
			if(!(b1 & 0x80) || (b0 & 0x70))
				return false;
			uint64_t len = b1 & 0x7f;
			size_t h = 2;
			if(len == 126){
				if(b.size() - at < 4)
					break;
				len = (uint8_t)b[at + 2] << 8 | (uint8_t)b[at + 3];
				h = 4;
			} else if(len == 127){
				if(b.size() - at < 10)
					break;
				len = 0;
				for(size_t i = 0; i < 8; i++)
					len = len << 8 | (uint8_t)b[at + 2 + i];
				h = 10;
			}
			if(len > web::MAX_FRAME_BYTES){
				log_w(MODULE, "Peer %zu: WebSocket frame of %zu bytes is over "
						"the limit", peer.id, (size_t)len);
				return false;
			}
			if(opcode >= 8 && (!fin || len > 125))
				return false;
			if(b.size() - at < h + 4 + len)
				break;
			const char *mask = &b[at + h];
			ss_ payload(&b[at + h + 4], len);
			for(size_t i = 0; i < len; i++)
				payload[i] ^= mask[i & 3];
			at += h + 4 + len;
			switch(opcode){
			case 0: // continuation
			case 1: // text
			case 2: // binary
				if(peer.kind == Peer::Kind::RawWebSocket){
					peer.ws_message += payload;
					if(peer.ws_message.size() > web::MAX_FRAME_BYTES)
						return false;
					if(fin){
						m_server->emit_event("network:ws_message",
								new CountedPacket(peer.in_flight, peer.id, "",
								peer.ws_message));
						peer.ws_message.clear();
					}
					break;
				}
				// simplified: the order of a message's frames is not checked;
				// every data frame is more of the stream
				peer.socket_buffer.append(payload);
				break;
			case 8: // close: answered with its status, and the peer goes
				log_i(MODULE, "Client %zu from %s closed its WebSocket",
						peer.id, cs(peer.socket->get_remote_address()));
				peer.queue_raw(web::frame(8, payload.substr(0, 2)));
				peer.closing = true;
				break;
			case 9: // ping
				peer.queue_raw(web::frame(10, payload));
				break;
			case 10: // pong
				break;
			default:
				return false;
			}
		}
		peer.ws_in.erase(0, at);
		if(peer.closing)
			peer.ws_in.clear();
		input_packets(peer);
		return true;
	}

	void input_packets(Peer &peer)
	{
		if(!peer.hello_sent){
			if(peer.socket_buffer.empty())
				return;
			peer.hello_sent = true;
			// Type 0's first byte, where a hello's is 2
			if(peer.socket_buffer.begin()[0] == 0){
				refuse_old_client(peer);
				return;
			}
			send_u(peer, "core:hello",
					interface::hello_data(interface::Hello::own()));
		}
		try {
			peer.packet_stream.input(peer.socket_buffer,
			[&](const ss_ &name, const ss_ &data){
				if(peer.closing)
					return;
				if(!peer.hello_seen){
					if(name != "core:hello")
						throw interface::UnknownPacketReceived(
								name+" before a hello");
					take_hello(peer, data);
					return;
				}
				if(name == "network:backlog"){
					peer.client_backlog = data.size() <= 10 &&
							data.find_first_not_of("0123456789") == ss_::npos ?
							strtoull(data.c_str(), nullptr, 10) : 0;
					return;
				}
				// To whoever subscribed to it. A name nobody did has no
				// event type, and is dropped rather than given one: every
				// type is kept for the life of the process, and a client
				// names its packets ([SECURITY_RUN_1])
				const interface::Event::Type t =
						interface::getGlobalEventRegistry()->find(
								"network:packet_received/"+name);
				if(t == 0){
					log_v(MODULE, "Peer %zu: %s is no one's; dropped",
							peer.id, cs(name));
					return;
				}
				m_server->emit_event(t, new CountedPacket(
						peer.in_flight, peer.id, name, data));
			});
		} catch(interface::UnknownPacketReceived &e){
			// A stream that cannot be read on from here: the peer goes,
			// rather than its buffer growing behind the bad header
			log_w(MODULE, "Peer %zu: %s; dropping it", peer.id, e.what());
			peer.socket_buffer.clear();
			peer.closing = true;
		}
	}

	void on_incoming_data(int event_fd)
	{
		log_v(MODULE, "network: on_incoming_data(): fd=%i", event_fd);

		auto it = m_peers_by_socket.find(event_fd);
		if(it == m_peers_by_socket.end()){
			// A peer dropped after the network thread listed its socket:
			// an /api/ peer is dropped when its answer has gone (flush_peers)
			log_v(MODULE, "network: Peer with fd=%i not found", event_fd);
			return;
		}
		Peer &peer = *it->second;

		int fd = peer.socket->fd();
		if(fd != event_fd)
			throw Exception("on_incoming_data: fds don't match");
		static char buf[100000];
		ssize_t r = recv(fd, buf, 100000, 0);
		if(r == -1){
			// Nothing to read after all: a readiness listed for the fd's
			// previous peer, which a new connection took over
#ifdef _WIN32
			// Winsock says why in WSAGetLastError() and leaves errno alone
			if(WSAGetLastError() == WSAEWOULDBLOCK ||
					WSAGetLastError() == WSAEINTR)
				return;
			const ss_ why = "WSA error "+itos(WSAGetLastError());
#else
			if(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
				return;
			const ss_ why = strerror(errno);
#endif
			// Anything else is this peer's connection gone -- reset, timed
			// out, unreachable -- and the peer leaves. It was thrown, and a
			// throw here ends the network thread and the server with it
			// ([SECURITY_RUN_1]).
			log_v(MODULE, "Peer %zu: receive failed: %s", peer.id, cs(why));
			take_input(peer, buf, 0);
			return;
		}
		take_input(peer, buf, r);
	}

	// What came from a peer, by whichever transport: 0 bytes is its going
	void take_input(Peer &peer, const char *buf, ssize_t r)
	{
		if(r == 0){
			if(peer.game())
				log_i(MODULE, "Client %zu from %s disconnected",
						peer.id, cs(peer.socket->get_remote_address()));
			drop_peer(peer.id);
			return;
		}
		log_v(MODULE, "Received %zu bytes", r);
		peer.last_recv_us = interface::os::time_us();
		bool keep = true;
		switch(peer.kind){
		case Peer::Kind::Sniff:
			peer.http_request.append(buf, r);
			keep = sniff(peer);
			break;
		case Peer::Kind::Http:
			// What comes after the request is not read
			if(!peer.closing && !peer.api_waiting){
				peer.http_request.append(buf, r);
				keep = handle_http(peer);
			}
			break;
		case Peer::Kind::WebSocket:
		case Peer::Kind::RawWebSocket:
			if(!peer.closing){
				peer.ws_in.append(buf, r);
				keep = deframe(peer);
			}
			break;
		case Peer::Kind::Native:
			if(!peer.closing){
				peer.socket_buffer.append(buf, r);
				input_packets(peer);
			}
			break;
		}
		if(keep)
			flush_peer(peer);
		if(!keep || (peer.closing && peer.out_pending() == 0 &&
				interface::os::time_us() >= peer.linger_until_us)){
			if(!keep)
				log_i(MODULE, "Peer %zu from %s: bad request; dropping it",
						peer.id, cs(peer.socket->get_remote_address()));
			drop_peer(peer.id);
		}
	}

	// What has not gone yet, as far as the socket will take it now. Not an
	// error for nothing to go: the peer is not reading and the rest waits.
	void flush_peer(Peer &peer)
	{
		for(;;){
			peer.refill();
			if(peer.out_sent >= peer.out_buf.size())
				break;
			size_t sent = 0;
			if(!peer.socket->send_some(peer.out_buf, peer.out_sent, &sent)){
				// The socket is gone; the read side notices and cleans up
				peer.out_buf.clear();
				peer.out_sent = 0;
				peer.out_queue.clear();
				peer.out_latest.clear();
				peer.ordered_first.clear();
				peer.queued_latest.clear();
				peer.out_queued_bytes = 0;
				peer.file.reset();
				return;
			}
			if(sent == 0)
				break;
			peer.out_sent += sent;
			peer.last_progress_us = interface::os::time_us();
		}
		if(peer.out_pending() <= m_max_queue_bytes){
			peer.over_since_us = 0;
			peer.warned_full = false;
		}
	}

	// **network:keepalive** (user, 2026-09-30): an empty packet to a game
	// peer that has been sent nothing for KEEPALIVE_US, so that a client
	// hears from a live server every few seconds and can tell a link that
	// died without closing (src/client/state.cpp, SILENCE_US). On this
	// thread, which goes round whatever the game's modules are doing.
	static const int64_t KEEPALIVE_US = 5000000;
	static const int64_t PEER_SILENCE_US = 60000000;
	void keepalive()
	{
		const int64_t now = interface::os::time_us();
		sv_<Peer::Id> silent;
		for(auto &pair : m_peers){
			Peer &peer = pair.second;
			// **A peer silent for a minute is gone** ([PEER_TIMEOUT], user
			// 2026-10-04): a client sends network:keepalive every few
			// seconds when it has nothing else to say, so this is a
			// crashed client, a dropped NAT mapping, or a slot held on
			// purpose. A connection that has not said what it is goes
			// the same way ([WEB_SNIFF_PRECONNECT]).
			// simplified: an address that keeps sending is not stopped by
			// this; the per-address cap bounds those
			if((peer.game() || peer.kind == Peer::Kind::Sniff) &&
					now - std::max(peer.accepted_us,
					peer.last_recv_us) >= PEER_SILENCE_US){
				log_i(MODULE, "Peer %zu from %s: nothing in %.0f s; "
						"dropping it", peer.id,
						cs(peer.socket->get_remote_address()),
						PEER_SILENCE_US / 1e6);
				silent.push_back(peer.id);
				continue;
			}
			if(peer.playing() && !peer.closing && (!peer.keepalive_sent ||
					now - peer.last_send_us >= KEEPALIVE_US)){
				peer.keepalive_sent = true;
				send_u(peer, "network:keepalive", "");
			}
		}
		for(Peer::Id id : silent)
			drop_peer(id);
	}

	bool any_peer_pending()
	{
		for(auto &pair : m_peers){
			const Peer &peer = pair.second;
			// The web's peers also have clocks that flush_peers() keeps
			if(peer.out_pending() > 0 || peer.closing || peer.held() ||
					peer.kind == Peer::Kind::Http)
				return true;
		}
		return false;
	}

	void flush_peers()
	{
		sv_<Peer::Id> to_drop;
		for(auto &pair : m_peers){
			Peer &peer = pair.second;
			const int64_t now = interface::os::time_us();
			flush_peer(peer);
			if(peer.closing && ((peer.out_pending() == 0 &&
					now >= peer.linger_until_us) ||
					(peer.close_by_us != 0 && now >= peer.close_by_us))){
				to_drop.push_back(peer.id);
				continue;
			}
			if(peer.kind == Peer::Kind::Http && now - std::max(peer.accepted_us,
					peer.last_progress_us) >= web::HTTP_STALL_US){
				log_i(MODULE, "Peer %zu from %s: HTTP stalled; dropping it",
						peer.id, cs(peer.socket->get_remote_address()));
				to_drop.push_back(peer.id);
				continue;
			}
			if(!peer.game())
				continue;
			if(m_send_policy != SendPolicy::Disconnect)
				continue;
			if(peer.out_pending() <= m_max_queue_bytes)
				continue;
			if(peer.over_since_us == 0){
				peer.over_since_us = now;
				if(peer.last_progress_us == 0)
					peer.last_progress_us = now;
			} else if(now - peer.over_since_us >= m_grace_us &&
					now - peer.last_progress_us >= m_grace_us){
				// Over the limit for the grace and nothing read in it:
				// the grace measures the peer's reading, not the queue
				log_w(MODULE, "Peer %zu has read nothing of %zu queued "
						"bytes in %.0f s; disconnecting it", peer.id,
						peer.out_pending(), (now - peer.last_progress_us) / 1e6);
				to_drop.push_back(peer.id);
			}
		}
		for(Peer::Id id : to_drop)
			drop_peer(id);
	}

	void drop_peer(Peer::Id id)
	{
		auto it = m_peers.find(id);
		if(it == m_peers.end())
			return;
		Peer &peer = it->second;
		// The game heard of a game peer only once its hello came
		if(peer.playing() || peer.kind == Peer::Kind::RawWebSocket){
			PeerInfo pinfo;
			pinfo.id = peer.id;
			pinfo.address = peer.address();
			pinfo.web = true;
			if(peer.game())
				pinfo.web = peer.kind == Peer::Kind::WebSocket;
			m_server->emit_event(peer.game() ? "network:client_disconnected" :
					"network:ws_closed", new OldClient(pinfo));
		}
		m_peers_by_socket.erase(peer.socket->fd());
		peer.socket->close_fd();
		m_peers.erase(it);
	}

	void send_u(Peer &peer, const ss_ &name, const ss_ &data)
	{
		// A WebSocket peer that has said close is not sent any more
		if(peer.closing)
			return;
		peer.last_send_us = interface::os::time_us();
		const bool latest_only = m_latest_only.count(name) > 0;
		// A drop policy drops the whole of a fragmented packet or none of
		// it: the fragments of one call are one packet to the reader
		bool dropping = false;
		peer.packet_stream.output(name, data,
				[&](ss_ &&packet_data, bool droppable){
			if(dropping && droppable)
				return;
			// Over the limit, a Drop game throws the new packet away rather
			// than queueing it. Buffer and Disconnect both queue; what
			// Disconnect does about it is in flush_peers(), on the thread
			// that drains, because a peer is not to be closed from inside
			// somebody else's send.
			//
			// A packet the stream marks undroppable is queued whatever the
			// policy says: that is core:define_packet_type, and a peer that
			// misses one can never read that type again. A dropped payload
			// costs one packet; a dropped definition costs the session.
			if(droppable && m_send_policy == SendPolicy::Drop &&
					peer.out_pending() > m_max_queue_bytes){
				if(!peer.warned_full){
					peer.warned_full = true;
					log_w(MODULE, "Peer %zu is %zu bytes behind; dropping "
							"what does not fit", peer.id, peer.out_pending());
				}
				dropping = true;
				return;
			}
			// A WebSocket peer gets each packet as a frame of its own. It is
			// framed here, before the queue, so that the queue and its
			// flow control only ever see whole frames: a LatestOnly
			// replacement swaps one whole frame for another.
			peer.enqueue(name, peer.kind == Peer::Kind::WebSocket ?
					web::frame(2, packet_data) : std::move(packet_data),
					latest_only, droppable,
					data.size() <= interface::PacketStream::FRAGMENT_BYTES);
		});
		// The common case is a peer that is keeping up, and then this writes
		// the packet and leaves nothing behind
		flush_peer(peer);
	}

	void send_u(PeerInfo::Id recipient, const ss_ &name, const ss_ &data)
	{
		// Grab Peer (which contains socket)
		auto it = m_peers.find(recipient);
		if(it == m_peers.end() || !it->second.playing()){
			log_w(MODULE, "network::send(): Peer %i doesn't exist",
					recipient);
			return;
		}
		Peer &peer = it->second;

		send_u(peer, name, data);
	}

	// Interface for NetworkThread

	sv_<int> get_sockets()
	{
		sv_<int> result;
		if(interface::os::time_us() >= m_accept_paused_until_us)
			result.push_back(m_listening_socket->fd());
		if(interface::os::time_us() >= m_accept_paused_until_us){
			for(auto &l : m_extra_listeners)
				result.push_back(l->fd());
		}
		for(auto &pair : m_peers){
			Peer &peer = pair.second;
			// A pipe's peer has no fd to wait on; poll_pipes() reads it
			if(peer.socket->fd() >= 0 && !peer.held())
				result.push_back(peer.socket->fd());
		}
		return result;
	}

	// The pipes' peers ([PROCESS_SANDBOX] B 2): new ones taken, and what
	// each has sent read. Whether any are there or coming, so the network
	// thread knows to come round often.
	bool poll_pipes()
	{
#ifdef _WIN32
		sv_<HANDLE> fresh;
		{
			std::lock_guard<std::mutex> lock(g_pipe_mutex);
			fresh.swap(g_pipe_new);
		}
		for(HANDLE h : fresh){
			Peer::Id peer_id = m_next_peer_id++;
			sp_<interface::TCPSocket> socket(
					new PipeSocket(h, -1000 - (int)peer_id));
			m_peers[peer_id] = Peer(peer_id, socket);
			m_peers_by_socket[socket->fd()] = &m_peers[peer_id];
			Peer &peer = m_peers[peer_id];
			peer.kind = Peer::Kind::Sniff;
			peer.accepted_us = interface::os::time_us();
			log_v(MODULE, "Peer %zu by the pipe", peer_id);
		}
		sv_<Peer::Id> pipes;
		for(auto &pair : m_peers)
			if(pair.second.socket->fd() < 0 && !pair.second.held())
				pipes.push_back(pair.first);
		static char buf[100000];
		for(Peer::Id id : pipes){
			for(int i = 0; i < 16; i++){
				auto it = m_peers.find(id);
				if(it == m_peers.end())
					break;
				PipeSocket *ps = (PipeSocket*)it->second.socket.get();
				const int r = ps->read_some(buf, sizeof buf);
				if(r < 0)
					break;
				if(r > 0 && !ps->m_head_done){
					if(!relay_head(it->second, *ps, buf, r))
						drop_peer(id);
					continue;
				}
				take_input(it->second, buf, r);
				if(r == 0)
					break;
			}
		}
		return !pipes.empty() || g_pipe_started;
#else
		return false;
#endif
	}

#ifdef _WIN32
	// **A LAN player the client relays** ([LAN_PLAY]): a boxed server's
	// LAN port is the client's (the firewall lets the client in, not the
	// box), which hands each player over by a pipe of its own, starting it
	// "BUILDAT-RELAY <address>\n". The client writes that before any of
	// the player's bytes, so a player cannot write it, nor leave it out.
	// Anything else is the client's own stream, taken as it is. False to
	// drop the peer.
	bool relay_head(Peer &peer, PipeSocket &ps, const char *buf, int r)
	{
		static const ss_ MARK = "BUILDAT-RELAY ";
		ps.m_head.append(buf, r);
		const ss_ &h = ps.m_head;
		const size_t n = std::min(h.size(), MARK.size());
		if(h.compare(0, n, MARK, 0, n) != 0){
			ps.m_head_done = true;
			ss_ all;
			all.swap(ps.m_head);
			take_input(peer, all.data(), (int)all.size());
			return true;
		}
		const size_t nl = h.find('\n');
		if(nl == ss_::npos)
			return h.size() < MARK.size() + 46;
		const ss_ address = h.substr(MARK.size(), nl - MARK.size());
		if(address.empty() || address.size() > 45)
			return false;
		for(char c : address)
			if(!(isxdigit((unsigned char)c) || c == '.' || c == ':'))
				return false;
		ps.m_remote = address;
		ps.m_head_done = true;
		const ss_ rest = h.substr(nl + 1);
		ps.m_head.clear();
		log_v(MODULE, "Peer %zu by the pipe: relayed from %s", peer.id,
				cs(address));
		if(!rest.empty())
			take_input(peer, rest.data(), (int)rest.size());
		return true;
	}
#endif

	void handle_active_socket(int fd)
	{
		bool listener = fd == m_listening_socket->fd();
		for(auto &l : m_extra_listeners){
			if(l->fd() == fd)
				listener = true;
		}
		if(listener){
			on_listen_event(fd);
		} else {
			on_incoming_data(fd);
		}
	}

	// Interface

	void send(PeerInfo::Id recipient, const ss_ &name, const ss_ &data)
	{
		log_d(MODULE, "network::send()");
		send_u(recipient, name, data);
	}

	std::set<ss_> m_latest_only;

	void declare(const ss_ &packet_name, Channel channel)
	{
		if(channel == Channel::LatestOnly)
			m_latest_only.insert(packet_name);
		else
			m_latest_only.erase(packet_name);
		// simplified: a client is told the names at its connect, so a
		// module declares at its start, before any connects
	}

	void disconnect(PeerInfo::Id id)
	{
		auto it = m_peers.find(id);
		if(it == m_peers.end())
			return;
		it->second.closing = true;
		it->second.close_by_us = interface::os::time_us() + 2000000;
	}

	// One more listening socket, on another address and the same port --
	// the machine's LAN address beside 127.0.0.1. Not the one there is
	// closed and bound anew on every interface: the main thread's select()
	// holds a closed socket bound until it returns, so the bind was "in
	// use" or not by luck, and retrying it held this module long enough
	// for the main thread and client_file to deadlock behind it.
	bool listen_on(const ss_ &address, ss_ *error)
	{
		const ss_ port = m_server->get_config().get<ss_>("network_port");
#ifdef _WIN32
		// **Reached by a pipe, the LAN port is the client's** ([LAN_PLAY]):
		// the firewall's prompt allows a program by its path, and a boxed
		// server's process is not matched by the client's. The client
		// that started this server listens there and relays each player
		// by a pipe (relay_head()).
		// simplified: told to the clients by the pipe now; one that
		// connects later is not, as the launcher's own is there already
		if(g_pipe_started){
			int told = 0;
			for(auto &pair : m_peers){
				Peer &peer = pair.second;
				if(peer.socket->fd() < 0 && peer.playing() &&
						peer.socket->get_remote_address() == "127.0.0.1"){
					send_u(peer, "core:lan_relay", address+" "+port);
					told++;
				}
			}
			if(told == 0){
				if(error)
					*error = "no client by the pipe to listen for it";
				return false;
			}
			log_i(MODULE, "Listening at %s:%s through the client's relay",
					cs(address), cs(port));
			return true;
		}
#endif
		sp_<interface::TCPSocket> s(interface::createTCPSocket());
		if(!s->bind_fd(address, port) || !s->listen_fd()){
			if(error)
				*error = "cannot listen at "+address+":"+port;
			log_w(MODULE, "Cannot listen at %s:%s too", cs(address),
					cs(port));
			return false;
		}
		log_i(MODULE, "Listening at %s:%s too, fd=%i", cs(address), cs(port),
				s->fd());
		m_extra_listeners.push_back(s);
		return true;
	}

	void claim_http_path(const ss_ &prefix)
	{
		m_claimed_paths.insert(prefix);
	}

	std::set<ss_> m_ws_paths;

	void claim_ws_path(const ss_ &prefix)
	{
		m_ws_paths.insert(prefix);
	}

	void set_page_has_no_game()
	{
		m_page_has_no_game = true;
	}

	void set_has_admin(bool admin)
	{
		m_has_admin = admin ? 1 : 0;
	}

	bool ws_claimed(const ss_ &target)
	{
		for(const ss_ &p : m_ws_paths)
			if(target.compare(0, p.size(), p) == 0)
				return true;
		return false;
	}

	void ws_send(PeerInfo::Id id, const ss_ &data)
	{
		auto it = m_peers.find(id);
		if(it == m_peers.end() || it->second.closing ||
				it->second.kind != Peer::Kind::RawWebSocket)
			return;
		it->second.queue_raw(web::frame(2, data));
		flush_peer(it->second);
	}

	void ws_close(PeerInfo::Id id, const ss_ &reason)
	{
		auto it = m_peers.find(id);
		if(it != m_peers.end() && !it->second.closing &&
				it->second.kind == Peer::Kind::RawWebSocket){
			// 1008, policy violation; a control frame's payload is at most 125
			it->second.queue_raw(web::frame(8, ss_("\x03\xf0", 2)+
					reason.substr(0, 123)));
			flush_peer(it->second);
		}
		disconnect(id);
	}

	void set_favicon(const ss_ &png)
	{
		m_favicon = png;
	}

	void set_ws_origins(const ss_ &by, const sv_<ss_> &origins)
	{
		if(origins.empty())
			m_ws_origins.erase(by);
		else
			m_ws_origins[by] = origins;
	}

	// One of set_ws_origins()'s, as a browser writes it
	bool ws_origin_given(const ss_ &origin)
	{
		for(auto &pair : m_ws_origins)
			for(const ss_ &o : pair.second)
				if(web::lower(o) == web::lower(origin))
					return true;
		return false;
	}

	void set_page_title(const ss_ &name, bool admin)
	{
		(admin ? m_admin_title : m_app_title) = name;
	}

	ss_ page_title()
	{
		const ss_ &name = !m_admin_title.empty() ? m_admin_title : m_app_title;
		return interface::web_brand::html(name.empty() ? ss_() : name+" | ")+
				"Buildat";
	}

	bool claimed(const ss_ &target)
	{
		if(target == "/")
			return m_claimed_paths.count("/") > 0;
		if(web::web_file(target))
			return false;
		for(const ss_ &p : m_claimed_paths)
			if(p != "/" && target.compare(0, p.size(), p) == 0)
				return true;
		return false;
	}

	void http_respond(PeerInfo::Id id, int status, const ss_ &content_type,
			const ss_ &body, const ss_ &extra_headers)
	{
		auto it = m_peers.find(id);
		if(it == m_peers.end() || !it->second.api_waiting)
			return;
		Peer &peer = it->second;
		peer.api_waiting = false;
		peer.closing = true;
		const char *text = status == 200 ? "OK" : status == 400 ?
				"Bad Request" : status == 403 ? "Forbidden" : status == 404 ?
				"Not Found" : status == 429 ? "Too Many Requests" : status == 503 ?
				"Service Unavailable" : "Error";
		peer.queue_raw(web::response(itos(status)+" "+text, content_type,
				body.size(), extra_headers) + body);
		flush_peer(peer);
	}

	void set_send_policy(SendPolicy policy, size_t max_queue_bytes,
			int64_t grace_us)
	{
		m_send_policy = policy;
		if(max_queue_bytes > 0)
			m_max_queue_bytes = max_queue_bytes;
		if(grace_us > 0)
			m_grace_us = grace_us;
		log_i(MODULE, "Send policy: %s, %zu bytes a peer, %.0f s of grace",
				policy == SendPolicy::Buffer ? "buffer whatever it takes" :
				policy == SendPolicy::Drop ? "drop what does not fit" :
				"disconnect a peer that stays behind",
				m_max_queue_bytes, m_grace_us / 1e6);
	}

	sv_<PeerInfo::Id> list_peers()
	{
		sv_<PeerInfo::Id> result;
		for(auto &pair : m_peers){
			Peer &peer = pair.second;
			if(peer.playing())
				result.push_back(peer.id);
		}
		return result;
	}

	size_t pending_bytes(PeerInfo::Id peer)
	{
		auto it = m_peers.find(peer);
		return it == m_peers.end() ? 0 :
				it->second.out_pending() + it->second.client_backlog;
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

void NetworkThread::run(interface::Thread *thread)
{
	interface::SelectHandler handler;

	while(!thread->stop_requested()){
		// A peer that is behind has bytes waiting for room in its socket,
		// and nothing wakes this loop when that room appears -- the select
		// is on readability only. So while anything is waiting it comes
		// round often and pushes what fits.
		//
		// simplified: a poll rather than a select on writability, which is
		// what SelectHandler would have to grow. It costs a wakeup every
		// five milliseconds and only while a peer is actually behind.
		bool pending = false;
		sv_<int> sockets;
		// We can avoid implementing our own mutex locking in Module by using
		// interface::Server::access_module() instead of directly accessing it.
		network::access(m_module->m_server, [&](network::Interface *inetwork){
			m_module->keepalive();
			pending = m_module->any_peer_pending();
			// A pipe's peer is read here, not by the select
			if(m_module->poll_pipes())
				pending = true;
			// After keepalive(), which closes the peers it drops: a list
			// taken before it held their fds, and the select over it
			// failed ([SELECT_BAD_FD])
			sockets = m_module->get_sockets();
		});

		sv_<int> active_sockets;
		handler.check(pending ? 5000 : 500000, sockets, active_sockets);

		if(pending){
			network::access(m_module->m_server,
					[&](network::Interface *inetwork){
				m_module->flush_peers();
			});
		}

		network::access(m_module->m_server, [&](network::Interface *inetwork){
			for(int fd: active_sockets){
				m_module->handle_active_socket(fd);
			}
		});
	}
}

void NetworkThread::on_crash(interface::Thread *thread)
{
	m_module->m_server->shutdown(1, "NetworkThread crashed");
}

extern "C" {
	BUILDAT_EXPORT void* createModule_network(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
