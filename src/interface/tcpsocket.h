// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#ifdef BUILDAT_WEB_MODULE
// [WEB_LOCAL_SERVER]: a module of the server built for the web has no
// sockets, HTTP or processes (doc/server_api.txt, "The web API")
#error "interface/tcpsocket.h is not in the web server's module API"
#endif
#include "core/types.h"

struct sockaddr;

namespace interface
{
	struct TCPSocket
	{
		virtual ~TCPSocket(){}
		virtual int fd() const = 0;
		virtual bool good() const = 0;
		virtual void release_fd() = 0;
		virtual void close_fd() = 0;
		virtual bool listen_fd() = 0;
		virtual bool connect_fd(const ss_ &address, const ss_ &port) = 0;
		// Special values "any4", "any6" and "any"
		virtual bool bind_fd(const ss_ &address, const ss_ &port) = 0;
		virtual bool accept_fd(const TCPSocket &listener) = 0;
		virtual bool send_fd(const ss_ &data) = 0;
		// What a socket that must not block needs: the fd stops waiting for
		// room, and a send says how much of the data actually went so the
		// caller can keep the rest. send_some() writes what fits and sets
		// `sent`; it is not an error for that to be zero.
		virtual bool set_nonblocking(bool nonblocking) = 0;
		virtual bool send_some(const ss_ &data, size_t offset,
				size_t *sent) = 0;
		virtual bool wait_data(int timeout_us) = 0;
		virtual ss_ get_local_address() const = 0;
		virtual ss_ get_remote_address() const = 0;
	};

	TCPSocket* createTCPSocket(int fd = -1);

	// Quiet connect attempt (50 ms); does not keep the socket.
	bool probe_connect(const ss_ &address, const ss_ &port);

	// A socket made non-blocking (on) or blocking again
	bool set_nonblocking_fd(int fd, bool on);
	// connect() made non-blocking and waited on for timeout_ms at most: ""
	// when connected, else why not, the server's sandbox refusing the port
	// named. The socket is left non-blocking. The web's is a WebSocket,
	// connected at once and opened later.
	ss_ connect_wait(int fd, const struct sockaddr *addr, size_t addrlen,
			int timeout_ms);

	// This machine's IPv4 address on the network its default route is on,
	// what someone on the LAN reaches it by; "" without one. Sends nothing.
	ss_ local_lan_address();

	// [LAN_DISCOVERY]: the group a LAN game is announced to, IPv4 only.
	// lan_socket(true) is joined to the group and bound to its port, to
	// hear; lan_socket(false) only sends (TTL 1), to the group and as a
	// broadcast to LAN_PORT. Non-blocking; -1 if not.
	// lan_recv() takes one datagram and the address it came from, false
	// when none is waiting.
	static const char *LAN_GROUP = "239.255.29.50";
	static const int LAN_PORT = 29599;
	int lan_socket(bool listen);
	bool lan_send(int fd, const ss_ &data);
	bool lan_recv(int fd, ss_ *data, ss_ *from);
	void lan_close(int fd);
}

// vim: set noet ts=4 sw=4:
