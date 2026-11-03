// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <atomic>

namespace interface
{
	namespace fs
	{
		struct Node {
			ss_ name;
			bool is_directory;
		};

		sv_<Node> list_directory(const ss_ &path);

		bool create_directories(const ss_ &path);

		ss_ get_cwd();

		ss_ get_absolute_path(const ss_ &path);

		// Whether path is dir itself or something under it, both taken as
		// absolute paths with "." and ".." collapsed. What asks is code
		// that has been given a path by somebody it does not trust -- the
		// client's image and resource calls, which sandboxed game code can
		// reach -- so a name that merely starts with the directory's is not
		// inside it.
		//
		// Lexical, so a symlink under dir that points elsewhere is still
		// "inside": what this keeps out is a path, not a filesystem.
		bool is_inside_path(const ss_ &path, const ss_ &dir);

		bool path_exists(const ss_ &path);

		bool copy_file(const ss_ &from, const ss_ &to);

		// A file or a directory tree, gone; false when something stayed
		bool remove_all(const ss_ &path);
		// A file or a directory to another name on the same filesystem,
		// over an existing file too, Windows included
		bool rename(const ss_ &from, const ss_ &to);
		// Whole or not at all ([USER_DIR_COPY]): written beside as
		// <path>.tmp and renamed over path, so a crash or a copy of the
		// directory never sees half of it. simplified: no fsync, so a power
		// cut can still lose the last write; it never leaves a torn one
		bool write_file(const ss_ &path, const ss_ &data);
		// **Apps were games** (2026-10-02): <user>/games, where what an
		// app keeps lived, to <user>/apps, once, when there is no apps yet.
		// Both the server and the client do it as they start, so a save or
		// a setting kept by an older version is where this one looks. And
		// <user>/luanti ([PROCESS_SANDBOX], 2026-10-02): its worlds to
		// <user>/apps/vanilla/worlds, the rest to <user>/shared/vanilla.
		void migrate_user_apps(const ss_ &user_path);

		// Bytes in a regular file; 0 if missing or not a regular file.
		uint64_t file_size(const ss_ &path);
		// Sum of file_size for every regular file under path, recursively.
		uint64_t directory_tree_size(const ss_ &path);

		// [CACHE_GC] A cache hit: the file's modification time made now
		// (atime is relatime or off); false if it could not be
		bool touch(const ss_ &path);
		// [CACHE_GC] Every file under dir modified before `before` (seconds
		// since the epoch) removed, and each directory under it older than
		// that and left empty. **No link is followed**: a box writes in
		// some of the caches this sweeps, and a link there must not take
		// the sweep into the user's files; a link is removed as a file. A
		// file that cannot be removed (in use on Windows) is skipped. Stops
		// early when *stop is set. The number of files removed.
		size_t remove_older(const ss_ &dir, int64_t before,
				const std::atomic<bool> *stop = nullptr);

		// A server's icon in the client's list and in Starport's is this
		// many pixels a side at most ([SERVER_ICONS])
		static const unsigned SERVER_ICON_SIDE = 64;
		// A PNG of 64 KB at most whose header says max_side pixels a side
		// or less (0: any size); the header is read, nothing is decoded
		bool icon_png_ok(const ss_ &data, unsigned max_side);
		// A server's icon at path ([FAVICON_SERVER_ICON]): the file when
		// icon_png_ok(), else "" (a warning when it is there but not one).
		// The client's list of servers and /favicon.ico both.
		ss_ read_icon_png(const ss_ &path, unsigned max_side = 0);

		// "image.png", "png" -> true
		bool check_file_extension(const char *path, const char *ext);
		ss_ strip_file_extension(const ss_ &path);
		ss_ strip_file_name(const ss_ &path);
	}
}
// vim: set noet ts=4 sw=4:
