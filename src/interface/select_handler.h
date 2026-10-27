// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#ifdef _WIN32
	#include "ports/windows_sockets.h"
	#include "ports/windows_compat.h" // usleep()
#else
	#include <sys/socket.h>
	#include <sys/select.h> // not reached through the others under emcc
	#include <unistd.h> // usleep()
#endif
#include <cstring> // strerror()
#include <cerrno>
#ifndef _WIN32
	#include <fcntl.h> // fcntl()
#endif

namespace interface
{
	struct SelectHandler
	{
		static constexpr const char *MODULE = "SelectHandler";

		// Fds in the caller's list that were found closed after a select()
		// failed on one ([SELECT_BAD_FD]). Left out while they stay closed
		// and taken back the moment one is open again: fd numbers are
		// reused, and the next socket opened -- a listener, a new peer --
		// may well get the number of the one that went away.
		set_<int> closed_fds;

		static bool fd_open(int fd)
		{
#ifdef _WIN32
			int type = 0;
			int len = sizeof type;
			return getsockopt(fd, SOL_SOCKET, SO_TYPE, (char*)&type,
					&len) == 0 || WSAGetLastError() != WSAENOTSOCK;
#else
			return fcntl(fd, F_GETFD) != -1 || errno != EBADF;
#endif
		}

		static bool bad_fd_error()
		{
#ifdef _WIN32
			return WSAGetLastError() == WSAENOTSOCK;
#else
			return errno == EBADF;
#endif
		}

		// Returns false if there is some sort of error (no errors are fatal)
		bool check(int timeout_us, const sv_<int> &sockets,
				sv_<int> &active_sockets)
		{
			// What was closed and is open again, or is not asked about any
			// more, is not set aside
			set_<int> still_closed;
			for(int fd : sockets){
				if(closed_fds.count(fd) && !fd_open(fd))
					still_closed.insert(fd);
			}
			if(still_closed != closed_fds){
				if(!still_closed.empty())
					log_w(MODULE, "Leaving out closed fds %s of %s",
							cs(dump(still_closed)), cs(dump(sockets)));
				closed_fds = still_closed;
			}

			// Nothing to wait on -- no socket, or none that is open yet (a
			// listening socket before bind is fd -1, and a server shutting
			// down before it listened has that and nothing else) -- is a
			// sleep and not a select: on Winsock a select over an empty set
			// is an error, and the shutdown loop spun on it forever with
			// the client waiting out its timeout ([WIN_MAPGEN_BUILD])
			bool any = false;
			for(int fd : sockets)
				if(fd >= 0 && !closed_fds.count(fd)) any = true;
			if(!any){
				usleep(timeout_us);
				return true;
			}

			struct timeval tv;
			tv.tv_sec = 0;
			tv.tv_usec = timeout_us;

			fd_set rfds;
			FD_ZERO(&rfds);
			int fd_max = 0;
			for(int fd : sockets){
				if(fd < 0 || closed_fds.count(fd))
					continue;
#ifndef _WIN32
				// An fd past FD_SETSIZE is a write past the end of rfds,
				// which is on the stack. Winsock's fd_set is a list and
				// ignores what does not fit.
				if(fd >= FD_SETSIZE)
					continue;
#endif
				FD_SET(fd, &rfds);
				if(fd > fd_max)
					fd_max = fd;
			}

			int r = select(fd_max + 1, &rfds, NULL, NULL, &tv);
			if(r == -1){
				if(errno == EINTR){
					// The process is probably quitting
					return false;
				}
				if(bad_fd_error()){
					// A socket in the list was closed after the list was
					// made. Which one is asked of each, not guessed: the
					// guess used to set the listener aside for good.
					set_<int> found;
					for(int fd : sockets){
						if(fd >= 0 && !fd_open(fd))
							found.insert(fd);
					}
					log_w(MODULE, "select(): closed fds %s in %s; left out "
							"until open again", cs(dump(found)),
							cs(dump(sockets)));
					closed_fds.insert(found.begin(), found.end());
					// Closed and open again before the check: the next
					// round has a fresh list
					return false;
				}
				log_w(MODULE, "select() returned -1: %s (fds: %s)",
						strerror(errno), cs(dump(sockets)));
				// Don't consume 100% CPU and flood logs
				usleep(1000 * 100);
				return false;
			} else if(r > 0){
				for(int fd : sockets){
					if(fd >= 0 && !closed_fds.count(fd) &&
#ifndef _WIN32
							fd < FD_SETSIZE &&
#endif
							FD_ISSET(fd, &rfds)){
						log_d(MODULE, "FD_ISSET: %i", fd);
						active_sockets.push_back(fd);
					}
				}
			}
			return true;
		}
	};
}
// vim: set noet ts=4 sw=4:
