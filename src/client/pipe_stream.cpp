// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [PROCESS_SANDBOX] B 2: the client reaches a local server boxed in an
// AppContainer by a named pipe, since loopback to the box is blocked. The
// pipe carries the byte stream a TCP socket would; this is the stream
// behind client::State's Wss interface, as TLS is.
#ifdef _WIN32
#include "client/wss.h"
#include "core/log.h"
#ifndef _WIN32_WINNT
	#define _WIN32_WINNT 0x0A00
#endif
#include "ports/windows_minimal.h"
#include <winsock2.h>
#include <userenv.h>
#include <sddl.h>
#undef interface
#include "interface/tcpsocket.h"
#include "interface/os.h"
#include <algorithm>
#include <atomic>
#include <mutex>
#include <thread>
#define MODULE "pipe"

namespace client {

struct CPipeStream: public Wss
{
	HANDLE m_pipe = INVALID_HANDLE_VALUE;

	~CPipeStream()
	{
		if(m_pipe != INVALID_HANDLE_VALUE)
			CloseHandle(m_pipe);
	}

	// host is the pipe's full path
	ss_ start(const ss_ &path, const ss_ &, const ss_ &)
	{
		m_pipe = CreateFileA(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
				nullptr, OPEN_EXISTING, 0, nullptr);
		if(m_pipe == INVALID_HANDLE_VALUE)
			return "the server's pipe "+path+" did not open ("+
					itos((int)GetLastError())+")";
		// Reads answer at once, as a non-blocking socket's do
		DWORD mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
		SetNamedPipeHandleState(m_pipe, &mode, nullptr, nullptr);
		return "";
	}

	bool send(const ss_ &data)
	{
		size_t at = 0;
		while(at < data.size()){
			// A piece that fits the pipe's buffer, as the server's side
			const DWORD piece = (DWORD)std::min<size_t>(data.size() - at, 16384);
			DWORD n = 0;
			if(!WriteFile(m_pipe, &data[at], piece, &n, nullptr))
				return false;
			at += n;
			if(n == 0)
				Sleep(1);
		}
		return true;
	}

	int read(ss_ &out, ss_ *why)
	{
		char buf[100000];
		DWORD n = 0;
		if(ReadFile(m_pipe, buf, sizeof buf, &n, nullptr)){
			out.append(buf, n);
			return (int)n;
		}
		const DWORD e = GetLastError();
		if(e == ERROR_NO_DATA)
			return 0;
		*why = "the server closed the pipe ("+itos((int)e)+")";
		return -1;
	}

	// Polled: a pipe has no socket for the select
	bool pending()
	{
		return true;
	}
};

Wss* create_pipe_stream()
{
	return new CPipeStream();
}

ss_ local_server_pipe(const ss_ &app, const ss_ &port)
{
	// Wine's way: an unboxed server asked for a pipe makes it outside any
	// container's namespace
	const char *plain = getenv("BUILDAT_PIPE");
	if(plain && ss_(plain) == "1")
		return "\\\\.\\pipe\\buildat-"+port;
	// A server started unboxed listens on loopback as before: by
	// --unconfined, or with the Windows box off
	// (src/server/confine_windows.cpp)
	if(interface::os::unconfined_by_env() ||
			interface::os::windows_sandbox_off_by_env())
		return "";
	const ss_ name_a = "buildat."+app;
	std::wstring name(name_a.begin(), name_a.end());
	PSID sid = nullptr;
	if(FAILED(DeriveAppContainerSidFromAppContainerName(name.c_str(), &sid)))
		return "";
	char *sid_s = nullptr;
	ConvertSidToStringSidA(sid, &sid_s);
	FreeSid(sid);
	DWORD session = 0;
	ProcessIdToSessionId(GetCurrentProcessId(), &session);
	const ss_ path = "\\\\.\\pipe\\Sessions\\"+itos((int)session)+
			"\\AppContainerNamedObjects\\"+(sid_s ? sid_s : "")+
			"\\buildat-"+port;
	LocalFree(sid_s);
	return path;
}

bool pipe_ready(const ss_ &path)
{
	// An instance waiting, without connecting to it: a probe connect is a
	// peer to the server ([WIN8_START] 11)
	return WaitNamedPipeA(path.c_str(), 1) != 0;
}

// **The boxed server's LAN port, the client's** ([LAN_PLAY]): Windows's
// firewall prompt lets in this program by its path, and the box's process
// is not it. Each player accepted here gets a pipe of its own to the
// server, started "BUILDAT-RELAY <address>\n" (network.cpp relay_head()),
// and the bytes go both ways as they come.
// simplified: a thread a player, polling the pipe every 2 ms as the server
// polls its end; overlapped I/O when a LAN game has more than a handful
struct CLanRelay: public LanRelay
{
	sp_<interface::TCPSocket> m_listener;
	ss_ m_pipe;
	std::atomic<bool> m_stop{false};
	std::thread m_accept;
	std::mutex m_mutex;
	sv_<std::thread> m_players;

	~CLanRelay()
	{
		m_stop = true;
		if(m_accept.joinable())
			m_accept.join();
		std::lock_guard<std::mutex> lock(m_mutex);
		for(auto &t : m_players)
			t.join();
	}

	void accept_loop()
	{
		while(!m_stop){
			fd_set rs;
			FD_ZERO(&rs);
			FD_SET((SOCKET)m_listener->fd(), &rs);
			timeval tv = {0, 200000};
			if(select(0, &rs, nullptr, nullptr, &tv) <= 0)
				continue;
			sp_<interface::TCPSocket> s(interface::createTCPSocket());
			if(!s->accept_fd(*m_listener))
				continue;
			std::lock_guard<std::mutex> lock(m_mutex);
			m_players.emplace_back([this, s](){ relay(s); });
		}
	}

	void relay(sp_<interface::TCPSocket> s)
	{
		const ss_ from = s->get_remote_address();
		std::unique_ptr<Wss> pipe(create_pipe_stream());
		const ss_ err = pipe->start(m_pipe, "", "");
		if(!err.empty() || !pipe->send("BUILDAT-RELAY "+from+"\n")){
			log_w(MODULE, "LAN player %s not relayed: %s", cs(from),
					cs(err.empty() ? ss_("the pipe went") : err));
			return;
		}
		log_i(MODULE, "LAN player %s relayed to the server", cs(from));
		const SOCKET fd = (SOCKET)s->fd();
		char buf[65536];
		ss_ out, why;
		while(!m_stop){
			fd_set rs;
			FD_ZERO(&rs);
			FD_SET(fd, &rs);
			timeval tv = {0, 2000};
			if(select(0, &rs, nullptr, nullptr, &tv) > 0){
				const int n = recv(fd, buf, sizeof buf, 0);
				if(n <= 0 || !pipe->send(ss_(buf, n)))
					break;
			}
			out.clear();
			if(pipe->read(out, &why) < 0)
				break;
			if(!out.empty() && !s->send_fd(out))
				break;
		}
		log_i(MODULE, "LAN player %s gone", cs(from));
	}
};

LanRelay* start_lan_relay(const ss_ &address, const ss_ &port,
		const ss_ &pipe, ss_ *error)
{
	std::unique_ptr<CLanRelay> r(new CLanRelay());
	r->m_pipe = pipe;
	r->m_listener.reset(interface::createTCPSocket());
	if(!r->m_listener->bind_fd(address, port) || !r->m_listener->listen_fd()){
		*error = "cannot listen at "+address+":"+port;
		return nullptr;
	}
	CLanRelay *p = r.get();
	r->m_accept = std::thread([p](){ p->accept_loop(); });
	return r.release();
}

}
#else
#include "client/wss.h"
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#include <cstdlib>
// [WEB_LOCAL_SERVER]: the page's own server, in a worker of the page
// (src/server/web/pre.js), reached by "pipe:<anything>". The page keeps
// the worker and Module.buildatPipe (src/client/web/index.html): what
// came from the server in q, and why the stream is gone in closed.
EM_JS(char*, page_pipe_open, (), {
	var p = Module['buildatPipe'];
	if(!p)
		return stringToNewUTF8('this page runs no local server');
	p.open();
	return 0;
});
EM_JS(void, page_pipe_send, (const char *data, int n), {
	Module['buildatPipe'].send(HEAPU8.slice(data, data + n));
});
// What came, its size, or -1 when the stream is gone (*why the reason)
EM_JS(int, page_pipe_peek, (char **why), {
	var p = Module['buildatPipe'];
	if(p.q.length)
		return p.q[0].length;
	if(p.closed){
		HEAPU32[why >> 2] = stringToNewUTF8(p.closed);
		return -1;
	}
	return 0;
});
EM_JS(void, page_pipe_take, (char *to), {
	HEAPU8.set(Module['buildatPipe'].q.shift(), to);
});
EM_JS(void, page_pipe_close, (), {
	var p = Module['buildatPipe'];
	if(p)
		p.close();
});
namespace client {
struct CPagePipe: public Wss
{
	bool m_open = false;
	~CPagePipe()
	{
		if(m_open)
			page_pipe_close();
	}
	ss_ start(const ss_ &, const ss_ &, const ss_ &)
	{
		char *why = page_pipe_open();
		if(!why){
			m_open = true;
			return "";
		}
		const ss_ r = why;
		free(why);
		return r;
	}
	bool send(const ss_ &data)
	{
		page_pipe_send(data.data(), (int)data.size());
		return true;
	}
	int read(ss_ &out, ss_ *why)
	{
		char *w = nullptr;
		const int n = page_pipe_peek(&w);
		if(n < 0){
			*why = w ? w : "the local server is gone";
			free(w);
			return -1;
		}
		if(n > 0){
			const size_t at = out.size();
			out.resize(at + n);
			page_pipe_take(&out[at]);
		}
		return n;
	}
	// Polled: there is no socket for the select
	bool pending()
	{
		return true;
	}
};
Wss* create_pipe_stream()
{
	return new CPagePipe();
}
}
#endif
namespace client {
ss_ local_server_pipe(const ss_ &, const ss_ &){ return ""; }
bool pipe_ready(const ss_ &){ return false; }
LanRelay* start_lan_relay(const ss_ &, const ss_ &, const ss_ &, ss_ *error)
{
	*error = "a relay is for a server reached by a pipe, on Windows";
	return nullptr;
}
}
#endif
// vim: set noet ts=4 sw=4:
