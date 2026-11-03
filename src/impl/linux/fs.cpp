// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "interface/fs.h"
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <utime.h>

namespace interface {
namespace fs {

uint64_t file_size(const ss_ &path)
{
	struct stat st;
	if(lstat(path.c_str(), &st) != 0)
		return 0;
	if(!S_ISREG(st.st_mode))
		return 0;
	return (uint64_t)st.st_size;
}

bool touch(const ss_ &path)
{
	return utime(path.c_str(), nullptr) == 0;
}

// The directory's descriptor, taken: every name is opened and removed
// relative to it, never through a path, so nothing can be swapped for a
// link between a look and a removal
static size_t remove_older_fd(int fd, int64_t before,
		const std::atomic<bool> *stop)
{
	DIR *d = fdopendir(fd);
	if(!d){
		close(fd);
		return 0;
	}
	size_t n = 0;
	while(struct dirent *e = readdir(d)){
		if(stop && *stop)
			break;
		const ss_ name = e->d_name;
		if(name == "." || name == "..")
			continue;
		struct stat st;
		if(fstatat(dirfd(d), name.c_str(), &st, AT_SYMLINK_NOFOLLOW) != 0)
			continue;
		if(S_ISDIR(st.st_mode)){
			const int sub = openat(dirfd(d), name.c_str(),
					O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
			if(sub >= 0)
				n += remove_older_fd(sub, before, stop);
			// Not empty: stays
			if(st.st_mtime < before)
				unlinkat(dirfd(d), name.c_str(), AT_REMOVEDIR);
		} else if(st.st_mtime < before &&
				unlinkat(dirfd(d), name.c_str(), 0) == 0){
			n++;
		}
	}
	closedir(d);
	return n;
}

size_t remove_older(const ss_ &dir, int64_t before,
		const std::atomic<bool> *stop)
{
	const int fd = open(dir.c_str(),
			O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	return fd < 0 ? 0 : remove_older_fd(fd, before, stop);
}

}
}
// vim: set noet ts=4 sw=4:
