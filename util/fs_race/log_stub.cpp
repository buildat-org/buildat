// fs_race's log: fs.cpp's only other dependency than c55's filesys
#include <cstdarg>
#include <cstdio>
#include <cstddef>
void log_(int, const char *sys, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "%s: ", sys);
	vfprintf(stderr, fmt, ap);
	fprintf(stderr, "\n");
	va_end(ap);
}
extern const int CORE_FATAL = 0, CORE_ERROR = 1, CORE_WARNING = 2,
	CORE_INFO = 3, CORE_VERBOSE = 4, CORE_DEBUG = 5, CORE_TRACE = 6;
