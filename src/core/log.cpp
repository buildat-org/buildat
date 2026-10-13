// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "log.h"
#include "interface/mutex.h"
//#include "interface/thread.h"
#include "c55/os.h"
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <string>
#include <cstdlib>
#include <ctime>
#include <cstring>
#include <cstdarg>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif
#ifdef _WIN32
	#include "ports/windows_compat.h"
	#include "ports/windows_minimal.h"
#else
	#include <pthread.h>
#endif

const int CORE_FATAL = 0;
const int CORE_ERROR = 1;
const int CORE_WARNING = 2;
const int CORE_INFO = 3;
const int CORE_VERBOSE = 4;
const int CORE_DEBUG = 5;
const int CORE_TRACE = 6;

// Coloured on a terminal only: a log read by a script or from a file has
// nothing to strip ([CHECK_COVERAGE])
#if defined(_WIN32) || defined(__EMSCRIPTEN__)
static const bool use_colors = false;
#else
static const bool use_colors = isatty(2);
#endif

static interface::Mutex log_mutex;
//static interface::Thread *log_active_thread = nullptr;

static std::atomic_bool disable_bloat(false);
static std::atomic_bool line_begin(true);
static std::atomic_int current_level(0);
static std::atomic_int max_level(CORE_INFO);

static FILE *file = NULL;
// The log's path and how much has gone into it, for the cap below: at
// LOG_CAP_BYTES the file is moved to <path>_1 and started again, so a
// forgotten -l 5 cannot fill a tmpfs (the verbose server log reached
// 1.5 GB in eight minutes; [TMP_HYGIENE])
static char log_path_kept[4096] = "";
static std::atomic<long long> log_written(0);
static long long LOG_CAP_BYTES = 512LL * 1024 * 1024; // BUILDAT_LOG_CAP_BYTES
// The file beside stderr rather than instead of it: the default log
// ([WIN8_START]), where the terminal and a harness reading the stream
// keep what they had
static bool tee = false;

void log_init()
{
	// A line at a time to stderr: unbuffered, a long message goes out in
	// pieces and another writer to the same stream (Urho3D's own log) lands
	// in the middle of a line, which a reader parsing the log then trips
	// on -- the driven run's scan block, 2026-09-22
	static char stderr_buf[8192];
	setvbuf(stderr, stderr_buf, _IOLBF, sizeof stderr_buf);
}

void log_set_max_level(int level)
{
	max_level = level;
}

int log_get_max_level()
{
	return max_level;
}

void log_set_file(const char *path, bool tee_)
{
	log_mutex.lock();
#ifdef _WIN32
	// Nothing to tee to: a GUI client started by a click has no stderr
	// at all, and nothing here opens a console -- the file is the
	// output. A redirected stderr (the smoke's file) and an attached
	// shell console are handles, and keep the tee ([WIN8_START] 19).
	{
		HANDLE err = GetStdHandle(STD_ERROR_HANDLE);
		if(tee_ && (err == NULL || err == INVALID_HANDLE_VALUE))
			tee_ = false;
	}
#endif
	// Binary, so that a Windows log is the same bytes as a Linux one: in
	// text mode msvcrt writes \r\n and a reader of the file sees a \r on
	// every line ([WIN8_START] 12)
	file = fopen(path, "ab");
	tee = tee_;
	if(file){
		snprintf(log_path_kept, sizeof log_path_kept, "%s", path);
		if(getenv("BUILDAT_LOG_CAP_BYTES"))
			LOG_CAP_BYTES = atoll(getenv("BUILDAT_LOG_CAP_BYTES"));
		long pos = ftell(file);
		log_written = pos > 0 ? pos : 0;
		fprintf(stderr, "Opened log file \"%s\"\n", path);
		// And stderr into the same file: a crash's backtrace is written
		// there by the signal handler, and a local server a client
		// started has no terminal for it to land on ([START_PROGRESS]).
		// Not when teeing: the stream stays what it was.
		if(!tee){
			fflush(stderr);
			dup2(fileno(file), 2);
		}
	} else
		log_w("__log", "Failed to open log file \"%s\"", path);
	log_mutex.unlock();
}

void log_raw(const char *data, size_t n)
{
	log_mutex.lock();
	if(file){
		fwrite(data, 1, n, file);
		fflush(file);
	}
	if(!file || tee){
		fwrite(data, 1, n, stderr);
		fflush(stderr);
	}
	log_mutex.unlock();
}

void log_close()
{
	log_mutex.lock();
	if(file){
		fclose(file);
		file = NULL;
	}
	log_mutex.unlock();
}

void log_disable_bloat()
{
	disable_bloat = true;
}

void log_nl_nolock()
{
	if(current_level <= max_level){
		if(file){
			fprintf(file, "\n");
			fflush(file);
		}
		if(!file || tee){
			fprintf(stderr, "\n");
			if(use_colors)
				fprintf(stderr, "\033[0m");
		}
	}
	line_begin = true;
}

void log_nl()
{
	if(current_level > max_level){ // Fast path
		line_begin = true;
		return;
	}
	interface::MutexScope ms(log_mutex);
	log_nl_nolock();
}

static void print(int level, const char *sys, const char *fmt, va_list va_args)
{
	if(use_colors && (!file || tee) &&
			(level != current_level || line_begin) && level <= max_level){
		if(level == CORE_FATAL)
			fprintf(stderr, "\033[0m\033[0;1;41m"); // reset, bright red bg
		else if(level == CORE_ERROR)
			fprintf(stderr, "\033[0m\033[1;31m"); // bright red fg, black bg
		else if(level == CORE_WARNING)
			fprintf(stderr, "\033[0m\033[1;33m"); // bright yellow fg, black bg
		else if(level == CORE_INFO)
			fprintf(stderr, "\033[0m"); // reset
		else if(level == CORE_VERBOSE)
			fprintf(stderr, "\033[0m\033[0;36m"); // cyan fg, black bg
		else if(level == CORE_DEBUG)
			fprintf(stderr, "\033[0m\033[1;30m"); // bright black fg, black bg
		else if(level == CORE_TRACE)
			fprintf(stderr, "\033[0m\033[0;35m"); //
		else
			fprintf(stderr, "\033[0m"); // reset
	}
	current_level = level;
	if(level > max_level)
		return;
	if(line_begin){
		time_t now = time(NULL);
		char timestr[30];
		if(disable_bloat){
			timestr[0] = 0;
		} else {
			size_t timestr_len = strftime(timestr, sizeof(timestr),
					"%b %d %H:%M:%S", localtime(&now));
			if(timestr_len == 0)
				timestr[0] = '\0';
			int ms = (get_timeofday_us() % 1000000) / 1000;
			timestr_len += snprintf(timestr + timestr_len,
					sizeof(timestr) - timestr_len, ".%03i", ms);
		}
		char sysstr[9];
		snprintf(sysstr, 9, "%s        ", sys);
		const char *levelcs = "FEWIVDT";
		if(file)
			fprintf(file, "%s %c %s: ", timestr, levelcs[level], sysstr);
		if(!file || tee)
			fprintf(stderr, "%s %c %s: ", timestr, levelcs[level], sysstr);
		line_begin = false;
	}
	// A peer's bytes reach the log in many a message (a name, a mode, a
	// path), and a control byte in them is the reader's terminal's to
	// act on: an escape sequence, a carriage return over the line. Each
	// is written as \xNN; a tab and a line break stay ([SECURITY_RUN_1])
	std::string text;
	{
		va_list copy;
		va_copy(copy, va_args);
		char small[512];
		int len = vsnprintf(small, sizeof small, fmt, copy);
		va_end(copy);
		if(len < 0)
			len = 0;
		if((size_t)len < sizeof small){
			text.assign(small, len);
		} else {
			text.resize(len + 1);
			va_copy(copy, va_args);
			vsnprintf(&text[0], len + 1, fmt, copy);
			va_end(copy);
			text.resize(len);
		}
		for(size_t i = 0; i < text.size(); i++){
			unsigned char c = text[i];
			if((c >= 0x20 && c != 0x7f) || c == '\n' || c == '\t')
				continue;
			char hex[5];
			snprintf(hex, sizeof hex, "\\x%02x", c);
			text.replace(i, 1, hex);
			i += 3;
		}
	}
	if(file){
		int n = fwrite(text.data(), 1, text.size(), file);
		if(n > 0 && (log_written += n) >= LOG_CAP_BYTES && log_path_kept[0]){
			// Rotated: the file so far to _1 (the one before it gone), and
			// this one opened again empty
			fflush(file);
			fclose(file);
			char rotated[4200];
			snprintf(rotated, sizeof rotated, "%s_1", log_path_kept);
			remove(rotated);
			rename(log_path_kept, rotated);
			file = fopen(log_path_kept, "ab");
			log_written = 0;
			if(file){
				if(!tee){
					fflush(stderr);
					dup2(fileno(file), 2);
				}
				fprintf(file, "log rotated at %lld bytes; the rest is in %s\n",
						LOG_CAP_BYTES, rotated);
			}
		}
	}
	if(!file || tee)
		fwrite(text.data(), 1, text.size(), stderr);
}

// Does not require any locking
/*static void fallback_print(int level, const char *sys, const char *fmt,
		va_list va_args)
{
	FILE *f = file;
	if(f == NULL)
		f = stderr;
	if(use_colors && (!file || tee))
		fprintf(f, "\033[0m"); // reset
	vfprintf(f, fmt, va_args);
	fprintf(f, "\n");
}*/

// The last lines, kept for a command sequence's wait_log ([START_WAIT]):
// a scripted client's output is a pipe it cannot read back, so what it
// waits for is remembered here. A few hundred, formatted without the
// time and the system; a wait says how many had gone by when it began.
static const size_t RECENT_MAX = 400;
static std::deque<std::string> recent_lines;
static long long recent_count = 0;
// The text one wait_log is waiting for, checked on every line as it is
// remembered: a world's load logs thousands of lines in one frame, and the
// line waited for rolled out of the last 400 before the wait looked
static std::string watch_text;
static bool watch_seen = false;

// A line is kept up to this long; the watch sees all of it. A request's
// answer can be a quarter of a megabyte of JSON, and what a wait looks for
// was past the old 1 KB cut
static const size_t RECENT_LINE_MAX = 65536;

static void remember_line(const char *fmt, va_list va_args)
{
	va_list copy;
	va_copy(copy, va_args);
	int n = vsnprintf(nullptr, 0, fmt, copy);
	va_end(copy);
	std::string line(n > 0 ? n : 0, '\0');
	if(n > 0){
		va_copy(copy, va_args);
		vsnprintf(&line[0], n + 1, fmt, copy);
		va_end(copy);
	}
	if(!watch_text.empty() && line.find(watch_text) != std::string::npos)
		watch_seen = true;
	if(line.size() > RECENT_LINE_MAX)
		line.resize(RECENT_LINE_MAX);
	recent_lines.push_back(std::move(line));
	if(recent_lines.size() > RECENT_MAX)
		recent_lines.pop_front();
	recent_count++;
}

static const size_t PROBLEMS_MAX = 100;
static std::deque<std::string> problems;
static long long problems_count = 0;

static void remember_problem(int level, const char *sys, const char *fmt,
		va_list va_args)
{
	char head[64], text[600];
	const time_t now = time(nullptr);
	struct tm t;
#ifdef _WIN32
	gmtime_s(&t, &now);
#else
	gmtime_r(&now, &t);
#endif
	strftime(head, sizeof head, "%Y-%m-%d %H:%M:%S", &t);
	va_list copy;
	va_copy(copy, va_args);
	vsnprintf(text, sizeof text, fmt, copy);
	va_end(copy);
	problems.push_back(std::string(head)+(level <= CORE_ERROR ? " E " : " W ")+
			sys+": "+text);
	if(problems.size() > PROBLEMS_MAX)
		problems.pop_front();
	problems_count++;
}

long long log_problem_count()
{
	interface::MutexScope ms(log_mutex);
	return problems_count;
}

bool log_problem_after(long long *since, char *buf, size_t size)
{
	interface::MutexScope ms(log_mutex);
	const long long first = problems_count - (long long)problems.size();
	const long long i = *since < first ? first : *since;
	if(i >= problems_count)
		return false;
	*since = i + 1;
	// Past the time, "E sys: text"
	const std::string &line = problems[(size_t)(i - first)];
	const std::string tail = line.size() > 20 ? line.substr(20) : line;
	if(size > 0){
		const size_t n = tail.size() < size - 1 ? tail.size() : size - 1;
		memcpy(buf, tail.data(), n);
		buf[n] = 0;
	}
	return true;
}

size_t log_problems(char *buf, size_t size)
{
	interface::MutexScope ms(log_mutex);
	std::string all;
	for(const std::string &line : problems)
		all += line+"\n";
	if(size > 0){
		const size_t n = all.size() < size - 1 ? all.size() : size - 1;
		memcpy(buf, all.data(), n);
		buf[n] = 0;
	}
	return all.size();
}

void log_watch(const char *text)
{
	interface::MutexScope ms(log_mutex);
	watch_text = text;
	watch_seen = false;
}

bool log_watch_seen()
{
	interface::MutexScope ms(log_mutex);
	return watch_seen;
}

long long log_line_count()
{
	interface::MutexScope ms(log_mutex);
	return recent_count;
}

bool log_lines_since_contain(long long since, const char *text)
{
	interface::MutexScope ms(log_mutex);
	long long first = recent_count - (long long)recent_lines.size();
	size_t i = 0;
	for(const std::string &line : recent_lines){
		// A scripted run's own wait lines carry the text they wait for:
		// a wait_log_any found its own "command: wait_log_any <text>"
		if(first + (long long)i >= since && line.find(text) != std::string::npos &&
				line.compare(0, 17, "command: wait_log") != 0 &&
				line.compare(0, 10, "wait_log: ") != 0)
			return true;
		i++;
	}
	return false;
}

void log_(int level, const char *sys, const char *fmt, ...)
{
	if(level > max_level){ // Fast path
		return;
	}
	interface::MutexScope ms(log_mutex);
	va_list va_args;
	va_start(va_args, fmt);
	print(level, sys, fmt, va_args);
	log_nl_nolock();
	va_end(va_args);
	va_start(va_args, fmt);
	remember_line(fmt, va_args);
	va_end(va_args);
	if(level <= CORE_WARNING){
		va_start(va_args, fmt);
		remember_problem(level, sys, fmt, va_args);
		va_end(va_args);
	}
}

void log_no_nl(int level, const char *sys, const char *fmt, ...)
{
	if(level > max_level){ // Fast path
		return;
	}
	interface::MutexScope ms(log_mutex);
	va_list va_args;
	va_start(va_args, fmt);
	print(level, sys, fmt, va_args);
	va_end(va_args);
}
// vim: set noet ts=4 sw=4:
