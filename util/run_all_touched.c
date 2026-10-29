// SPDX-License-Identifier: Apache-2.0 OR MIT
// [RUN_ALL_PICK] What a check's buildat processes read, for run_all.sh's
// --changed: preloaded (LD_PRELOAD) into everything a runner starts, it
// appends every path a buildat or buildat_server opens to the file
// BUILDAT_TOUCHED names, one a line, absolute. Any other process (bash,
// the compiler, a browser) is left alone. run_all.sh builds it into
// local/run_all/ when this file is newer.
// simplified: open/openat/fopen and their 64 forms; a read by another call
// (an mmap'd file, stat) is not seen
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int out = -1;

__attribute__((constructor)) static void init(void)
{
	char exe[4096];
	ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
	const char *t = getenv("BUILDAT_TOUCHED");
	if(n <= 0 || !t)
		return;
	exe[n] = 0;
	const char *base = strrchr(exe, '/');
	if(strncmp(base ? base + 1 : exe, "buildat", 7) != 0)
		return;
	int (*real_open)(const char *, int, ...) = dlsym(RTLD_NEXT, "open");
	out = real_open(t, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
}

static void note(int dirfd, const char *path)
{
	char line[8192];
	if(out < 0 || !path)
		return;
	if(path[0] == '/'){
		snprintf(line, sizeof line, "%s\n", path);
	} else {
		char dir[4096] = "";
		if(dirfd == AT_FDCWD){
			if(!getcwd(dir, sizeof dir))
				return;
		} else {
			char fd[64];
			snprintf(fd, sizeof fd, "/proc/self/fd/%d", dirfd);
			ssize_t n = readlink(fd, dir, sizeof dir - 1);
			if(n <= 0)
				return;
			dir[n] = 0;
		}
		snprintf(line, sizeof line, "%s/%s\n", dir, path);
	}
	// One write a line: O_APPEND keeps the processes' lines whole
	if(write(out, line, strlen(line)) < 0)
		return;
}

#define OPEN(name) \
int name(const char *path, int flags, ...) \
{ \
	static int (*real)(const char *, int, ...); \
	if(!real) real = dlsym(RTLD_NEXT, #name); \
	mode_t m = 0; \
	if(flags & (O_CREAT | O_TMPFILE)){ \
		va_list a; va_start(a, flags); m = va_arg(a, mode_t); va_end(a); \
	} \
	note(AT_FDCWD, path); \
	return real(path, flags, m); \
}
OPEN(open)
OPEN(open64)

#define OPENAT(name) \
int name(int dirfd, const char *path, int flags, ...) \
{ \
	static int (*real)(int, const char *, int, ...); \
	if(!real) real = dlsym(RTLD_NEXT, #name); \
	mode_t m = 0; \
	if(flags & (O_CREAT | O_TMPFILE)){ \
		va_list a; va_start(a, flags); m = va_arg(a, mode_t); va_end(a); \
	} \
	note(dirfd, path); \
	return real(dirfd, path, flags, m); \
}
OPENAT(openat)
OPENAT(openat64)

#define FOPEN(name) \
FILE *name(const char *path, const char *mode) \
{ \
	static FILE *(*real)(const char *, const char *); \
	if(!real) real = dlsym(RTLD_NEXT, #name); \
	note(AT_FDCWD, path); \
	return real(path, mode); \
}
FOPEN(fopen)
FOPEN(fopen64)
