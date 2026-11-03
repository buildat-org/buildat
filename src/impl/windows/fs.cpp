// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "interface/fs.h"
// GetFinalPathNameByHandle, SetFileInformationByHandle: Vista
#ifndef _WIN32_WINNT
	#define _WIN32_WINNT 0x0600
#endif
#include "ports/windows_minimal.h"
#include <string.h>

namespace interface {
namespace fs {

uint64_t file_size(const ss_ &path)
{
	WIN32_FILE_ATTRIBUTE_DATA data;
	if(!GetFileAttributesEx(path.c_str(), GetFileExInfoStandard, &data))
		return 0;
	if(data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
		return 0;
	ULARGE_INTEGER u;
	u.LowPart = data.nFileSizeLow;
	u.HighPart = data.nFileSizeHigh;
	return u.QuadPart;
}

bool touch(const ss_ &path)
{
	HANDLE h = CreateFileA(path.c_str(), FILE_WRITE_ATTRIBUTES,
			FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
			OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
	if(h == INVALID_HANDLE_VALUE)
		return false;
	FILETIME now;
	GetSystemTimeAsFileTime(&now);
	const bool ok = SetFileTime(h, NULL, NULL, &now) != 0;
	CloseHandle(h);
	return ok;
}

static int64_t unix_time(const FILETIME &ft)
{
	ULARGE_INTEGER u;
	u.LowPart = ft.dwLowDateTime;
	u.HighPart = ft.dwHighDateTime;
	return (int64_t)(u.QuadPart / 10000000ULL) - 11644473600LL;
}

// What an open handle is, as a path, for telling it is under the root
static ss_ final_path(HANDLE h)
{
	char buf[MAX_PATH * 4];
	const DWORD n = GetFinalPathNameByHandleA(h, buf, sizeof buf,
			FILE_NAME_NORMALIZED);
	return n > 0 && n < sizeof buf ? ss_(buf, n) : ss_();
}

// Opened as itself, a link not followed, and removed only if what was
// opened is under root: a directory swapped for a junction during the
// sweep leads elsewhere, and what is there is left
static bool remove_under(const ss_ &path, const ss_ &root, bool dir)
{
	HANDLE h = CreateFileA(path.c_str(), DELETE,
			FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
			OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT |
			(dir ? FILE_FLAG_BACKUP_SEMANTICS : 0), NULL);
	if(h == INVALID_HANDLE_VALUE)
		return false; // in use, or gone
	const ss_ p = final_path(h);
	bool ok = false;
	if(p.size() > root.size() + 1 &&
			_strnicmp(p.c_str(), root.c_str(), root.size()) == 0 &&
			p[root.size()] == '\\'){
		FILE_DISPOSITION_INFO di;
		di.DeleteFile = TRUE;
		ok = SetFileInformationByHandle(h, FileDispositionInfo, &di,
				sizeof di) != 0;
	}
	CloseHandle(h);
	return ok;
}

static size_t remove_older_in(const ss_ &dir, const ss_ &root,
		int64_t before, const std::atomic<bool> *stop)
{
	WIN32_FIND_DATAA fd;
	HANDLE f = FindFirstFileA((dir+"\\*").c_str(), &fd);
	if(f == INVALID_HANDLE_VALUE)
		return 0;
	size_t n = 0;
	do {
		if(stop && *stop)
			break;
		const ss_ name = fd.cFileName;
		if(name == "." || name == "..")
			continue;
		const ss_ path = dir+"\\"+name;
		const bool old = unix_time(fd.ftLastWriteTime) < before;
		const bool link = fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT;
		if((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !link){
			n += remove_older_in(path, root, before, stop);
			// Not empty: stays
			if(old)
				remove_under(path, root, true);
		} else if(old && remove_under(path, root,
				fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)){
			n++;
		}
	} while(FindNextFileA(f, &fd));
	FindClose(f);
	return n;
}

size_t remove_older(const ss_ &dir, int64_t before,
		const std::atomic<bool> *stop)
{
	// The root itself not a link either
	HANDLE h = CreateFileA(dir.c_str(), FILE_READ_ATTRIBUTES,
			FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
			OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT |
			FILE_FLAG_BACKUP_SEMANTICS, NULL);
	if(h == INVALID_HANDLE_VALUE)
		return 0;
	BY_HANDLE_FILE_INFORMATION info;
	const bool ok = GetFileInformationByHandle(h, &info) &&
			(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
			!(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT);
	const ss_ root = final_path(h);
	CloseHandle(h);
	if(!ok || root.empty())
		return 0;
	return remove_older_in(dir, root, before, stop);
}

}
}
// vim: set noet ts=4 sw=4:
