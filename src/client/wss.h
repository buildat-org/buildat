// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <memory>

namespace interface {
	struct TCPSocket;
}

namespace client
{
	// **A server behind a proxy with TLS** ([STARPORT] 10g, user
	// 2026-10-02): the native client reaches it as the web client does, by
	// a WebSocket over TLS (Mbed TLS), the stream of packets inside it the
	// same as on a plain socket.
	struct Wss
	{
		virtual ~Wss(){}
		// On a connected socket: the TLS handshake, the certificate checked
		// against `ca_path`'s roots for `host`, and the upgrade. Blocks; ""
		// or why not.
		virtual ss_ start(const ss_ &host, const ss_ &port,
				const ss_ &ca_path) = 0;
		virtual bool send(const ss_ &data) = 0;
		// The stream's bytes onto `out`: > 0 some came, 0 none now, < 0 the
		// connection is gone and `why` says why
		virtual int read(ss_ &out, ss_ *why) = 0;
		// Bytes TLS has already taken off the socket and not handed out:
		// the socket does not say readable for them
		virtual bool pending() = 0;
	};

	Wss* create_wss(interface::TCPSocket *socket);
#if defined(_WIN32) || defined(__EMSCRIPTEN__)
	// A named pipe's stream ([PROCESS_SANDBOX] B 2): start() takes the
	// pipe's full path as its host. In a web page the stream to the page's
	// own server in a worker ([WEB_LOCAL_SERVER]).
	Wss* create_pipe_stream();
#endif
	// The pipe of the local server this client started, boxed on Windows
	// in the AppContainer buildat.<app>: its full path, or "" where it is
	// joined over loopback (another platform, an unboxed server)
	ss_ local_server_pipe(const ss_ &app, const ss_ &port);
	// Whether the server is listening on it
	bool pipe_ready(const ss_ &path);

	// [LAN_PLAY]: the LAN port of a local server reached by a pipe, taken
	// by this client, each player relayed to the server by a pipe of its
	// own. Deleting it stops it. nullptr with why if it cannot listen.
	struct LanRelay { virtual ~LanRelay(){} };
	LanRelay* start_lan_relay(const ss_ &address, const ss_ &port,
			const ss_ &pipe, ss_ *error);

	// "https://host[:port][/]" or "wss://...": the host and the port (443
	// unless said); false for any other address
	bool parse_secure_address(const ss_ &address, ss_ *host, ss_ *port);
}
// vim: set noet ts=4 sw=4:
