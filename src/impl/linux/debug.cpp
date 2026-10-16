// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/debug.h"
#include "interface/mutex.h"
#include "core/log.h"
#include <c55/string_util.h>
#include <stdexcept>
#include <iostream>
#include <functional>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <cstdarg>
#include <execinfo.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#define MODULE "debug"

namespace interface {
namespace debug {

// Execute a program and return whatever it writes to stdout
static ss_ exec_get_stdout(char *cmd)
{
	FILE* pipe = popen(cmd, "r");
	if(!pipe) return "ERROR";
	char buffer[50];
	ss_ result;
	try{
		while(!feof(pipe)){
			if(fgets(buffer, 50, pipe) != NULL)
				result += buffer; // Can cause std::bad_alloc
		}
		pclose(pipe);
		return result;
	}catch(std::bad_alloc){
		return ss_();
	}
}

// Execute a program and return whatever it writes to stdout, without trailing
// newline
static ss_ exec_get_stdout_without_newline(char *cmd)
{
	ss_ s = exec_get_stdout(cmd);
	if(!s.empty() && s[s.size()-1] == '\n')
		s = s.substr(0, s.size()-1);
	return s;
}

static void* get_library_executable_address(const ss_ &lib_path)
{
	char cmdbuf[500];
	snprintf(cmdbuf, sizeof cmdbuf,
			"cat /proc/%i/maps | grep %s | grep ' ..x. ' | cut -d- -f1",
			getpid(), cs(lib_path));
	ss_ address_s = exec_get_stdout_without_newline(cmdbuf);
	//log_v(MODULE, "address_s=\"%s\"", cs(address_s));
	if(address_s.empty())
		return (void*)0x0;
	void *address = (void*)strtoul(address_s.c_str(), NULL, 16);
	return address;
}

//#define __USE_GNU
#include <ucontext.h> // REG_EIP (or REG_RIP)

#if __WORDSIZE == 64 // REG_RIP replaces REG_EIP on x86_64
	#define REG_EIP REG_RIP
#endif

static interface::Mutex backtrace_mutex;

static char backtrace_buffer[10000];
static size_t backtrace_buffer_len = 0;

// snprintf answers what it would have written: added up past the buffer,
// the next call's room wrapped to a huge size_t and it wrote past the end,
// over the globals beside it -- a long exception chain from a client's
// input did it ([SECURITY_RUN_6]). So the length stops at the last byte.
static void bt_advance(int n)
{
	if(n > 0)
		backtrace_buffer_len = std::min(backtrace_buffer_len + (size_t)n,
				sizeof backtrace_buffer - 1);
}

static void bt_print_newline()
{
	bt_advance(snprintf(
			backtrace_buffer + backtrace_buffer_len,
			sizeof backtrace_buffer - backtrace_buffer_len,
			"\n"));
}

static void bt_print(const char *fmt, ...)
{
	va_list va_args;
	va_start(va_args, fmt);
	bt_advance(vsnprintf(
			backtrace_buffer + backtrace_buffer_len,
			sizeof backtrace_buffer - backtrace_buffer_len,
			fmt, va_args));
	va_end(va_args);
	bt_print_newline();
}

enum BacktraceFilterAction {BFA_PASS, BFA_START_LATER, BFA_STOP};
typedef std::function<BacktraceFilterAction(int i, int &first_real_i,
		ss_ &cppfilt_symbol, ss_ &addr2line_output)> backtrace_filter_t;

auto bt_default_filter = [](int i, int &first_real_i, 
		ss_ &cppfilt_symbol, ss_ &addr2line_output)
{
	// Clean up the beginning of the backtrace (for whatever reason there
	// often seems to be two basic_string-related lines at the beginnong of
	// the backtrace)
	if(i <= 2 && i <= first_real_i &&
			addr2line_output.find("/basic_string.h") != ss_::npos){
		return BFA_START_LATER;
	}
	return BFA_PASS;
};

static void bt_print_backtrace(char **symbols, void* const *trace, int trace_size,
		int start_from_i = 1, backtrace_filter_t filter_f = backtrace_filter_t())
{
	if(!filter_f)
		filter_f = bt_default_filter;

	int first_real_i = start_from_i;
	for(int i = 1; i < trace_size; i++){
		char cmdbuf[500];
		// Parse symbol to get file name
		// Example: "../cache/rccpp_build/main.so(+0x14e2c) [0x7f7880d36e2c]"
		//log_v(MODULE, "symbol: %s", symbols[i]);
		c55::Strfnd f(symbols[i]);
		ss_ file_path = f.next("(");
		//log_v(MODULE, "file_path: %s", cs(file_path));

		void *address = trace[i];

		bool is_shared_lib = (file_path.find(".so") != ss_::npos);
		//log_v(MODULE, "is_shared_lib=%s", is_shared_lib?"true":"false");
		if(is_shared_lib){
			void *base_addr = get_library_executable_address(file_path);
			//log_v(MODULE, "base_addr=%p", base_addr);
			address = (void*)((char*)trace[i] - (char*)base_addr);
			//log_v(MODULE, "address=%p", address);
		}

		snprintf(cmdbuf, sizeof cmdbuf, "echo '%s' | c++filt", symbols[i]);
		ss_ cppfilt_symbol = exec_get_stdout_without_newline(cmdbuf);

		ss_ addr2line_output;
		if(address != nullptr){
			snprintf(cmdbuf, sizeof cmdbuf, "addr2line %p -e %s",
					address, cs(file_path));
			addr2line_output = exec_get_stdout_without_newline(cmdbuf);
		}

		auto r = filter_f(i, first_real_i, cppfilt_symbol,addr2line_output);
		if(r == BFA_PASS){
		} else if(r == BFA_START_LATER){
			first_real_i = i + 1;
		} else if(r == BFA_STOP){
			break;
		}

		if(addr2line_output.size() > 4){
			bt_print("    #%i  %s", i-first_real_i, cs(addr2line_output));
			//bt_print("    = %s", cs(cppfilt_symbol));
		} else {
			bt_print("    #%i  %s", i-first_real_i, cs(cppfilt_symbol));
		}
	}

	// Remove trailing newline
	if(backtrace_buffer_len > 0 &&
			backtrace_buffer[backtrace_buffer_len-1] == '\n'){
		backtrace_buffer[backtrace_buffer_len-1] = 0;
		backtrace_buffer_len--;
	}
}

static void log_backtrace(void* const *trace, int trace_size, const ss_ &title,
		bool use_lock = true)
{
	char **symbols = backtrace_symbols(trace, trace_size);

	if(use_lock){
		// Lock spinlock
		backtrace_mutex.lock();
	}

	backtrace_buffer_len = 0;
	bt_print("\n  %s", cs(title));
	// The first stack frame points to this functiton
	bt_print_backtrace(symbols, trace, trace_size, 1);

	// Print to log
	backtrace_buffer[sizeof backtrace_buffer - 1] = 0;
	log_i(MODULE, "%s", backtrace_buffer);

	if(use_lock){
		// Unlock spinlock
		backtrace_mutex.unlock();
	}

	free(symbols);
}

void log_current_backtrace(const ss_ &title)
{
	void *trace[BACKTRACE_SIZE];
	int trace_size = backtrace(trace, BACKTRACE_SIZE);

	log_backtrace(trace, trace_size, title);
}

#include <cxxabi.h>
#include <dlfcn.h>

// Per thread: every throw on every thread writes these, and a thrown
// exception is caught and read on the thread that threw it. Shared, two
// module threads refusing a malformed packet at once assigned the one
// string together -- a double free a client could cause (ASan,
// util/fuzz/proto_fuzz.sh, [SECURITY_RUN_1]).
static thread_local void *last_exception_frames[BACKTRACE_SIZE];
static thread_local int last_exception_num_frames = 0;
static thread_local ss_ last_exception_name;

// GCC-specific
static ss_ demangle(const char *name)
{
	int status;
	std::unique_ptr<char,void(*)(void*)>
			realname(abi::__cxa_demangle(name, 0, 0, &status), &std::free);
	return status ? "failed" : &*realname;
}

// GCC-specific
extern "C" {
	void __cxa_throw(void *ex, void *info, void (*dest)(void *)) {
		last_exception_name = demangle(
				reinterpret_cast<const std::type_info*>(info)->name());
		last_exception_num_frames = backtrace(last_exception_frames,
				sizeof last_exception_frames / sizeof(void*));

		static void (*const rethrow)(void*,void*,void(*)(void*))
		__attribute__((noreturn)) = (void (*)(void*,void*,void(*)(void*)))
				dlsym(RTLD_NEXT, "__cxa_throw");
		rethrow(ex,info,dest);
	}
}

void log_exception_backtrace(const ss_ &title)
{
	log_backtrace(last_exception_frames, last_exception_num_frames, title);
}

void get_current_backtrace(StoredBacktrace &result)
{
	result.exception_name.clear();
	result.num_frames = backtrace(result.frames, BACKTRACE_SIZE);
}

void get_exception_backtrace(StoredBacktrace &result)
{
	result.exception_name = last_exception_name;
	result.num_frames = last_exception_num_frames;
	for(int i = 0; i < result.num_frames; i++){
		result.frames[i] = last_exception_frames[i];
	}
}

void log_backtrace(const StoredBacktrace &result, const ss_ &title)
{
	log_backtrace(result.frames, result.num_frames, title);
}

void log_backtrace_chain(const std::list<ThreadBacktrace> &chain,
		const char *reason, bool cut_at_api)
{
	interface::MutexScope ms(backtrace_mutex);

	backtrace_buffer_len = 0;
	ss_ ex_name;
	bool header_printed = false;
	for(const interface::debug::ThreadBacktrace &bt_step : chain){
		if(!bt_step.bt.exception_name.empty()){
			ex_name = bt_step.bt.exception_name;
		}
		if(!header_printed){
			header_printed = true;
			if(!ex_name.empty())
				bt_print("\n  Backtrace for %s(\"%s\"):", cs(ex_name), reason);
			else
				bt_print("\n  Backtrace for %s:", reason);
		}
		bt_print("  Thread(%s):", cs(bt_step.thread_name));
		char **symbols = backtrace_symbols(bt_step.bt.frames, bt_step.bt.num_frames);

		bool stop_at_next = false;

		auto bt_filter = [&](int i, int &first_real_i, 
				ss_ &cppfilt_symbol, ss_ &addr2line_output)
		{
			if(stop_at_next){
				return BFA_STOP;
			}
			// Skip this stuff at the beginning
			if(i <= 2 && i <= first_real_i &&
					addr2line_output.find("/basic_string.h") != ss_::npos){
				return BFA_START_LATER;
			}
			// Stop at current module API
			if(!bt_step.thread_name.empty() && addr2line_output.find(
					"/"+bt_step.thread_name+"/api.h") != ss_::npos){
				stop_at_next = true;
				return BFA_PASS;
			}
			return BFA_PASS;
		};

		bt_print_backtrace(symbols, bt_step.bt.frames, bt_step.bt.num_frames,
				1, bt_filter);
		bt_print_newline();

		free(symbols);
	}
	// Print to log
	backtrace_buffer[sizeof backtrace_buffer - 1] = 0;
	log_i(MODULE, "%s", backtrace_buffer);
}

/*************************************************************************
 * Signal handling
 *************************************************************************/

// Used for signals because a signal often occurs inside core/log's mutex
// synchronization, causing a deadlock. Also, does not allocate new memory.
static void stderr_backtrace(void* const *trace, int trace_size, int sig)
{
	char **symbols = backtrace_symbols(trace, trace_size);

	backtrace_mutex.lock();

	backtrace_buffer_len = 0;
	// The first stack frame points to this functiton
	bt_print_backtrace(symbols, trace, trace_size, 1);

	// Print to stderr
	backtrace_buffer[sizeof backtrace_buffer - 1] = 0;
	fprintf(stderr, "  Backtrace for signal %i:\n%s\n", sig, backtrace_buffer);

	backtrace_mutex.unlock();

	free(symbols);
}

// Used for avoiding the handing of a SIGSEGV caused by trying to handle a
// SIGABRT or so.
static std::atomic_int g_signal_handlers_active(0);

static void debug_sighandler(int sig, siginfo_t *info, void *secret)
{
	// Make sure we're not handling a signal inside a signal handler
	int num_handlers_active = g_signal_handlers_active.fetch_add(1);
	if(num_handlers_active != 0){
		// Get out of here, we're in deep trouble
		g_signal_handlers_active--;
		exit(1);
	}

	// Disable worst memory allocation stuff in logging
	log_disable_bloat();

	// NOTE: Do not use log in here, because a signal can occur inside the
	//       logging functions too

	ucontext_t *uc = (ucontext_t*)secret;
	fprintf(stderr, "\n");
	if(sig == SIGSEGV){
		fprintf(stderr, "Crash: SIGSEGV: Address %p (executing %p)\n",
				info->si_addr, (void*)uc->uc_mcontext.gregs[REG_EIP]);
	} else if(sig == SIGABRT){
		fprintf(stderr, "Crash: SIGABRT\n");
	} else {
		fprintf(stderr, "Crash: Signal %d\n", sig);
	}

	void *trace[BACKTRACE_SIZE];
	int trace_size = backtrace(trace, BACKTRACE_SIZE);
	// Overwrite sigaction with caller's address
	trace[1] = (void*) uc->uc_mcontext.gregs[REG_EIP];

	stderr_backtrace(trace, trace_size, sig);

	g_signal_handlers_active--;
	exit(1);
}

// The watchdog ([WIN8_START] 14): the watched thread is sent SIGUSR2
// once it has said nothing for stall_seconds, and the handler, on that
// thread, prints its own backtrace to stderr the way a crash's is
static pthread_t g_watched_thread;
static std::atomic<int64_t> g_watched_alive_us(0);
static int g_watchdog_stall_s = 10;
static std::atomic_bool g_watchdog_started(false);
static void (*g_watchdog_on_freeze)() = nullptr;
// The next SIGUSR2 is the freeze's, not a report's
static std::atomic_bool g_watchdog_freeze(false);
static const int WATCHDOG_FREEZE_S = 30;
// Where the freeze's signal found the thread: in machine code LuaJIT
// compiled, which no hook reaches
static std::atomic_bool g_watchdog_in_jit(false);

static int64_t watchdog_now_us()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void watchdog_sighandler(int sig, siginfo_t *info, void *secret)
{
	(void)sig; (void)info;
	ucontext_t *uc = (ucontext_t*)secret;
	// **Not unwound from machine code LuaJIT made**: it has no unwind
	// tables, and the unwinder walking off it aborted the client -- the
	// watchdog turning a stall into a crash. Such code is in no object.
	// simplified: dladdr() is not async-signal-safe; it takes the loader's
	// lock, so a thread frozen inside dlopen() would hang here as well
	Dl_info dl;
	const bool in_jit = !dladdr((void*)uc->uc_mcontext.gregs[REG_EIP], &dl);
	if(g_watchdog_freeze.exchange(false)){
		g_watchdog_in_jit = in_jit;
		if(g_watchdog_on_freeze)
			g_watchdog_on_freeze();
		return;
	}
	if(in_jit){
		fprintf(stderr, "  The main thread is in no loaded object (%p): "
				"machine code LuaJIT compiled from a script\n",
				(void*)uc->uc_mcontext.gregs[REG_EIP]);
		return;
	}
	void *trace[BACKTRACE_SIZE];
	int trace_size = backtrace(trace, BACKTRACE_SIZE);
	trace[1] = (void*)uc->uc_mcontext.gregs[REG_EIP];
	stderr_backtrace(trace, trace_size, SIGUSR2);
}

static void *watchdog_main(void*)
{
	int64_t next_report = 0;
	bool stalled = false;
	bool freeze_sent = false;
	for(;;){
		sleep(1);
		const int64_t now = watchdog_now_us();
		const int64_t alive = g_watched_alive_us;
		if(now - alive < (int64_t)g_watchdog_stall_s * 1000000){
			stalled = false;
			continue;
		}
		if(!stalled){
			stalled = true;
			freeze_sent = false;
			next_report = now;
		}
		// **A compiled loop ends the client rather than its window**: the
		// hook did not reach it, nothing else will, and a window frozen
		// for good -- full screen, perhaps -- is worse than a client that
		// says why it left
		if(freeze_sent && g_watchdog_in_jit &&
				now - alive >= (int64_t)WATCHDOG_FREEZE_S * 2 * 1000000){
			fprintf(stderr, "\nWatchdog: no frame for %d s, in Lua that "
					"LuaJIT compiled and the interrupt does not reach; "
					"exiting\n", (int)((now - alive) / 1000000));
			_exit(3);
		}
		if(!freeze_sent && g_watchdog_on_freeze &&
				now - alive >= (int64_t)WATCHDOG_FREEZE_S * 1000000){
			freeze_sent = true;
			fprintf(stderr, "\nWatchdog: no frame for %d s; interrupting "
					"the main thread's Lua\n", (int)((now - alive) / 1000000));
			g_watchdog_freeze = true;
			pthread_kill(g_watched_thread, SIGUSR2);
			continue;
		}
		if(now < next_report)
			continue;
		next_report = now + 60000000;
		fprintf(stderr, "\nWatchdog: no frame for %d s; the main thread's stack:\n",
				(int)((now - alive) / 1000000));
		pthread_kill(g_watched_thread, SIGUSR2);
	}
	return nullptr;
}

void watchdog_on_freeze(void (*f)())
{
	g_watchdog_on_freeze = f;
}

void watchdog_alive(int stall_seconds)
{
	g_watched_alive_us = watchdog_now_us();
	// Every call, so a screen may lower it for its own stay
	g_watchdog_stall_s = stall_seconds;
	if(g_watchdog_started.exchange(true))
		return;
	g_watched_thread = pthread_self();
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_sigaction = watchdog_sighandler;
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_RESTART | SA_SIGINFO;
	sigaction(SIGUSR2, &sa, NULL);
	pthread_t t;
	if(pthread_create(&t, NULL, watchdog_main, NULL) == 0)
		pthread_detach(t);
	log_i(MODULE, "Watchdog: the main thread's stack is logged after %d s "
			"without a frame", stall_seconds);
}

void init_signal_handlers(const SigConfig &config)
{
	struct sigaction sa;
	sa.sa_sigaction = debug_sighandler;
	sigemptyset (&sa.sa_mask);
	sa.sa_flags = SA_RESTART | SA_SIGINFO;

	if(config.catch_segfault)
		sigaction(SIGSEGV, &sa, NULL);
	if(config.catch_abort)
		sigaction(SIGABRT, &sa, NULL);
}

void set_crash_dump_dir(const ss_ &dir, const ss_ &exe){}
ss_ crash_dump_untold(const ss_ &dir){ return ""; }

}
}
// vim: set noet ts=4 sw=4:
