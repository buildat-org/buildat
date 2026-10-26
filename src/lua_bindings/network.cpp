// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include "interface/tcpsocket.h"
#ifdef _WIN32
	#include "ports/windows_sockets.h"
#else
	#include <unistd.h>
	#include <sys/types.h>
	#include <sys/socket.h>
	#include <errno.h>
	#include <fcntl.h>
	#include <netinet/in.h>
	#include <netinet/tcp.h>
	#include <netdb.h>
	#include <poll.h>
#endif
#include <luabind/luabind.hpp>
#include <string.h>
#include <stdlib.h> // atoi()
#include <vector>
#include <deque>
#include <mutex>
#include <thread>
#include <atomic>
#include <chrono>
#define MODULE "lua_bindings"

// Sockets for Lua. This is the raw layer; it does not ask the user about
// anything. The extension environment guards it (client/core/network).
//
// The connect functions always return a socket object; if the connection could
// not be made, socket:good() is false and socket:error() tells why.

namespace lua_bindings {

// TCP connect blocks for up to this long. simplified: no connecting state to
// poll from Lua; a slow peer stalls one frame. Upgrade path if that shows up:
// keep the socket in a connecting state and finish it in receive()/send().
static const int TCP_CONNECT_TIMEOUT_MS = 5000;

static const size_t RECEIVE_BUFFER_SIZE = 65536;

static void close_socket_fd(int fd)
{
#ifdef _WIN32
	closesocket(fd);
#else
	::close(fd);
#endif
}

static bool sockaddr_to_ip_port(const struct sockaddr *sa, socklen_t len,
		ss_ &ip, int &port)
{
	char host[NI_MAXHOST];
	char serv[NI_MAXSERV];
	if(getnameinfo(sa, len, host, sizeof host, serv, sizeof serv,
			NI_NUMERICHOST | NI_NUMERICSERV) != 0)
		return false;
	ip = host;
	port = atoi(serv);
	return true;
}

static ss_ last_socket_error()
{
#ifdef _WIN32
	char buf[128];
	snprintf(buf, sizeof buf, "winsock error %i", WSAGetLastError());
	return buf;
#else
	return strerror(errno);
#endif
}

static bool would_block()
{
#ifdef _WIN32
	int e = WSAGetLastError();
	return e == WSAEWOULDBLOCK || e == WSAEINPROGRESS;
#else
	return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
#endif
}

struct LuaSocket
{
	int m_fd = -1;
	bool m_udp = false;
	ss_ m_remote; // "host:port" as given by the caller
	ss_ m_error;
	ss_ m_peer_ip;
	int m_peer_port = 0;

	// [ACK_OFF_FRAME]: Luanti's reliable packets acked as they arrive, by a
	// thread that reads the socket into m_queue for receive()
	std::thread m_thread;
	std::atomic<bool> m_stop{false};
	std::mutex m_mutex;
	std::deque<ss_> m_queue;
	ss_ m_thread_error;

	LuaSocket(bool udp, const ss_ &remote):
		m_udp(udp), m_remote(remote)
	{}

	~LuaSocket()
	{
		close();
	}

	void fail(const ss_ &error)
	{
		m_error = error;
		close();
	}

	bool connect_to(const ss_ &host, const ss_ &port)
	{
		struct addrinfo hints;
		memset(&hints, 0, sizeof(hints));
		hints.ai_family = AF_UNSPEC;
		hints.ai_socktype = m_udp ? SOCK_DGRAM : SOCK_STREAM;
		struct addrinfo *res0 = NULL;
		int err = getaddrinfo(host.c_str(), port.c_str(), &hints, &res0);
		if(err || res0 == NULL){
			m_error = ss_("getaddrinfo: ")+gai_strerror(err);
			return false;
		}
		m_error = "no address to connect to";
		for(struct addrinfo *res = res0; res != NULL; res = res->ai_next){
			int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
			if(fd == -1){
				m_error = "socket: "+last_socket_error();
				continue;
			}
			if(!interface::set_nonblocking_fd(fd, true)){
				m_error = "failed to set socket non-blocking";
				close_socket_fd(fd);
				continue;
			}
			m_fd = fd;
			if(m_udp){
				// The game reads its socket once a frame: what a server
				// sends in a slow frame waits here, and the default (~200
				// KiB) overflowed under a Luanti server's media burst
				// ([LUANTI_JOIN_LOSS]). The send side for the acks' bursts.
				// simplified: the OS may cap it (Linux rmem_max/wmem_max)
				int size = 4 * 1024 * 1024;
				setsockopt(fd, SOL_SOCKET, SO_RCVBUF, (const char*)&size,
						sizeof size);
				setsockopt(fd, SOL_SOCKET, SO_SNDBUF, (const char*)&size,
						sizeof size);
			}
			// UDP connect() only sets the default peer; it does not block.
			// It also makes the socket drop datagrams from anyone else.
			if(m_udp){
				if(connect(fd, res->ai_addr, res->ai_addrlen) == 0)
					break;
				m_error = "connect: "+last_socket_error();
			} else {
				m_error = interface::connect_wait(fd, res->ai_addr,
						res->ai_addrlen, TCP_CONNECT_TIMEOUT_MS);
				if(m_error.empty())
					break;
			}
			close();
		}
		freeaddrinfo(res0);
		if(m_fd == -1)
			return false;
		m_error = "";
		{
			struct sockaddr_storage sa;
			socklen_t len = sizeof(sa);
			if(getpeername(m_fd, (struct sockaddr*)&sa, &len) == 0)
				sockaddr_to_ip_port((struct sockaddr*)&sa, len,
						m_peer_ip, m_peer_port);
		}
		if(!m_udp){
			int val = 1;
			setsockopt(m_fd, IPPROTO_TCP, TCP_NODELAY, (const char*)&val,
					sizeof(val));
		}
		return true;
	}

	// Lua interface

	bool good() const
	{
		return m_fd != -1;
	}

	// [WEB_TCP_CONNECT_FALSE] "open", "pending" or what failed. The web's
	// socket is a WebSocket that opens after connect() has returned (see
	// connect_wait()), and one to a port nobody is on was called connected;
	// a native one is open by then or not there at all.
	ss_ connect_state() const
	{
		if(m_fd == -1)
			return m_error.empty() ? "closed" : m_error;
#ifdef __EMSCRIPTEN__
		struct pollfd p = {m_fd, POLLOUT, 0};
		if(poll(&p, 1, 0) < 0)
			return "poll: "+last_socket_error();
		if(p.revents & (POLLERR | POLLHUP))
			return "connect: refused or closed";
		if(!(p.revents & POLLOUT))
			return "pending";
#endif
		return "open";
	}

	ss_ error() const
	{
		return m_error;
	}

	// "host:port" as the caller gave it; for showing to the user
	ss_ address() const
	{
		return m_remote;
	}

	ss_ peer_ip() const
	{
		return m_peer_ip;
	}

	int peer_port() const
	{
		return m_peer_port;
	}

	ss_ local_ip() const
	{
		ss_ ip;
		int port = 0;
		local_address(ip, port);
		return ip;
	}

	int local_port() const
	{
		ss_ ip;
		int port = 0;
		local_address(ip, port);
		return port;
	}

	void local_address(ss_ &ip, int &port) const
	{
		if(m_fd == -1)
			return;
		struct sockaddr_storage sa;
		socklen_t len = sizeof(sa);
		if(getsockname(m_fd, (struct sockaddr*)&sa, &len) == 0)
			sockaddr_to_ip_port((struct sockaddr*)&sa, len, ip, port);
	}

	// send(data) -> bytes sent, or -1 if the socket errored. Less than the
	// whole thing means the send buffer is full; there is no send queue here,
	// the caller retries with the rest.
	int send(const ss_ &data)
	{
		if(m_fd == -1)
			return -1;
		size_t sent_total = 0;
		while(sent_total < data.size()){
			int sent = ::send(m_fd, &data[sent_total], data.size() - sent_total, 0);
			if(sent < 0){
				if(would_block())
					break;
				fail("send: "+last_socket_error());
				return -1;
			}
			sent_total += sent;
			if(m_udp) // One datagram per call, whole or not at all
				break;
		}
		return sent_total;
	}

	// receive() -> data; "" means nothing was available. If the peer closed the
	// connection or the socket errored, good() turns false.
	ss_ receive()
	{
		if(m_fd == -1)
			return "";
		if(m_thread.joinable()){
			ss_ error;
			{
				std::lock_guard<std::mutex> lock(m_mutex);
				if(!m_queue.empty()){
					ss_ d = std::move(m_queue.front());
					m_queue.pop_front();
					return d;
				}
				error = m_thread_error;
			}
			if(!error.empty())
				fail(error);
			return "";
		}
		std::vector<char> buf(RECEIVE_BUFFER_SIZE);
		int r = recv(m_fd, &buf[0], buf.size(), 0);
		if(r == 0){
			if(!m_udp){
				fail("closed");
				return "";
			}
			return ""; // Empty datagram; indistinguishable from nothing
		}
		if(r < 0){
			if(would_block())
				return "";
			fail("recv: "+last_socket_error());
			return "";
		}
		return ss_(&buf[0], r);
	}

	// ack_luanti(): from now on a thread reads the socket and acks each of
	// Luanti's reliable packets at once, as Luanti's own client does: an ack
	// that waits for the game's next frame keeps the server's window at its
	// minimum. receive() hands on what it read, acked or not, as before.
	// The game still acks too, unless it leaves that to this.
	bool ack_luanti()
	{
		if(m_fd == -1 || !m_udp || m_thread.joinable())
			return false;
		m_thread = std::thread(&LuaSocket::ack_thread, this, m_fd);
		return true;
	}

	void ack_thread(int fd)
	{
		static const size_t MAX_QUEUED = 16384;
		std::vector<char> buf(RECEIVE_BUFFER_SIZE);
		uint16_t peer_id = 0; // Luanti's PEER_ID_INEXISTENT
		while(!m_stop){
			// A datagram acked is one the server never resends, so none is
			// dropped here: while the game is behind, what arrives waits
			// unread and unacked in the socket's buffer instead
			bool full;
			{
				std::lock_guard<std::mutex> lock(m_mutex);
				full = m_queue.size() >= MAX_QUEUED;
			}
			if(full){
				std::this_thread::sleep_for(std::chrono::milliseconds(5));
				continue;
			}
#ifndef _WIN32
			// [SECURITY_RUN_7] A script's many sockets: past FD_SETSIZE,
			// a write past the fd_set on the stack
			if(fd >= FD_SETSIZE){
				std::lock_guard<std::mutex> lock(m_mutex);
				m_thread_error = "too many files open";
				return;
			}
#endif
			fd_set rfds;
			FD_ZERO(&rfds);
			FD_SET(fd, &rfds);
			struct timeval tv = {0, 50000}; // How soon close() is heard
			int r = select(fd + 1, &rfds, NULL, NULL, &tv);
			if(r < 0 && !would_block()){
				std::lock_guard<std::mutex> lock(m_mutex);
				m_thread_error = "select: "+last_socket_error();
				return;
			}
			while(r > 0){
				int n = recv(fd, &buf[0], buf.size(), 0);
				if(n <= 0){
					if(n < 0 && !would_block()){
						std::lock_guard<std::mutex> lock(m_mutex);
						m_thread_error = "recv: "+last_socket_error();
						return;
					}
					break;
				}
				const unsigned char *d = (const unsigned char*)&buf[0];
				// u32 protocol id | u16 peer id | u8 channel | u8 type 3
				// (reliable) | u16 seqnum | the packet inside
				if(n >= 10 && d[0] == 0x4f && d[1] == 0x45 && d[2] == 0x74 &&
						d[3] == 0x03 && d[6] < 3 && d[7] == 3){
					// The game's order: the ack, then a SET_PEER_ID in it
					const unsigned char ack[11] = {0x4f, 0x45, 0x74, 0x03,
						(unsigned char)(peer_id >> 8), (unsigned char)peer_id,
						d[6], 0, 0, d[8], d[9]};
					// simplified: an ack the full send buffer would not take
					// is lost, and the server resends what it covered
					::send(fd, (const char*)ack, sizeof ack, 0);
					if(n >= 14 && d[10] == 0 && d[11] == 1)
						peer_id = (d[12] << 8) | d[13];
				}
				std::lock_guard<std::mutex> lock(m_mutex);
				m_queue.emplace_back(&buf[0], n);
				if(m_queue.size() >= MAX_QUEUED)
					break;
			}
		}
	}

	void close()
	{
		if(m_thread.joinable()){
			m_stop = true;
			m_thread.join();
		}
		if(m_fd != -1){
			close_socket_fd(m_fd);
			m_fd = -1;
		}
	}
};

static sp_<LuaSocket> connect_socket(bool udp, const ss_ &host, const ss_ &port)
{
	sp_<LuaSocket> socket(new LuaSocket(udp, host+":"+port));
	if(!socket->connect_to(host, port)){
		log_w(MODULE, "%s connect to %s:%s failed: %s", udp ? "udp" : "tcp",
				cs(host), cs(port), cs(socket->error()));
	} else {
		log_v(MODULE, "%s socket connected to %s:%s", udp ? "udp" : "tcp",
				cs(host), cs(port));
	}
	return socket;
}

static sp_<LuaSocket> tcp_connect(const ss_ &host, const ss_ &port)
{
	return connect_socket(false, host, port);
}

static sp_<LuaSocket> udp_connect(const ss_ &host, const ss_ &port)
{
	return connect_socket(true, host, port);
}

void init_network(lua_State *L)
{
	using namespace luabind;

	module(L)[
		class_<LuaSocket, bases<>, sp_<LuaSocket>>("Socket")
			.def("good", &LuaSocket::good)
			.def("error", &LuaSocket::error)
			.def("connect_state", &LuaSocket::connect_state)
			.def("address", &LuaSocket::address)
			.def("peer_ip", &LuaSocket::peer_ip)
			.def("peer_port", &LuaSocket::peer_port)
			.def("local_ip", &LuaSocket::local_ip)
			.def("local_port", &LuaSocket::local_port)
			.def("send", &LuaSocket::send)
			.def("receive", &LuaSocket::receive)
			.def("ack_luanti", &LuaSocket::ack_luanti)
			.def("close", &LuaSocket::close),
		def("__buildat_tcp_connect", &tcp_connect),
		def("__buildat_udp_connect", &udp_connect)
	];
}

} // namespace lua_bindings

// vim: set noet ts=4 sw=4:
