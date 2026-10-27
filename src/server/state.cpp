// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <cstdint>
#include "state.h"
#include "confine.h"
#include "core/log.h"
#include "rccpp.h"
#include "rccpp_util.h"
#include "wasm_build.h"
#include "static_modules.h"
#include "config.h"
#include "interface/module.h"
#include "interface/module_info.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/file_watch.h"
#include "interface/fs.h"
#include "interface/sha1.h"
#include "interface/mutex.h"
#include "interface/thread_pool.h"
#include "interface/thread.h"
#include "interface/semaphore.h"
#include "interface/debug.h"
#include "interface/select_handler.h"
#include "interface/os.h"
#include <iostream>
#include <algorithm>
#include <fstream>
#include <deque>
#include <list>
#include <thread>
#include <cstdlib>
#ifdef _WIN32
	#ifndef NOMINMAX
		#define NOMINMAX // std::max below
	#endif
	#include <windows.h>
#else
	#include <sched.h>
	#include <fcntl.h>
	#include <sys/file.h>
	#include <sys/stat.h>
	#include <unistd.h>
#endif
#define MODULE "__state"

#ifdef _WIN32
	#define MODULE_EXTENSION "dll"
#else
	#define MODULE_EXTENSION "so"
#endif

extern server::Config g_server_config;
extern bool g_sigint_received;

namespace server {

// [PARALLEL_COMPILE] the cores this process may run on: taskset and a
// cpuset are respected on Linux.
// simplified: a cgroup's CPU quota (cpu.max) is not read; read it once
// servers run under one
static size_t usable_cores()
{
#if defined(_WIN32) || defined(__EMSCRIPTEN__)
	return std::max(1u, std::thread::hardware_concurrency());
#else
	cpu_set_t set;
	if(sched_getaffinity(0, sizeof set, &set) == 0)
		return std::max(1, CPU_COUNT(&set));
	return std::max(1u, std::thread::hardware_concurrency());
#endif
}

// [COMPILE_SLOTS] Compiles beyond each server's first take a slot shared
// by every server of this user on the machine, so that servers started
// together run half the cores' compilers between them, not each (six at
// once ran ~50 cc1plus and filled the RAM, 2026-10-20). A slot is a file
// in /tmp/buildat-compile-<uid> (0700, ours, not a link), held by flock
// for one compile; a server that dies lets go of its locks. The files
// are opened before the box, which has no /tmp, and kept open; a lock on
// an open file is not the box's to refuse. Whatever fails -- the
// directory, a file, a lock -- the server still runs one compiler: its
// first needs no slot.
// simplified: per user, not per machine; a server of another user is
// not counted. An app's module runs in the process and could hold the
// slots, which slows other servers' compiles to one at a time, no more.
// simplified: no slots on Windows, the per-process limit as before
static sv_<int> g_compile_slots;
#ifndef _WIN32
static bool g_compile_slots_opened = false;
static std::mutex g_compile_slots_mutex;
static std::set<int> g_compile_slots_held; // by this process
#endif
void open_compile_slots()
{
#if !defined(_WIN32) && !defined(BUILDAT_STATIC_MODULES)
	if(g_compile_slots_opened)
		return;
	g_compile_slots_opened = true;
	// BUILDAT_COMPILE_SLOTS another directory (the check's own)
	const char *env = getenv("BUILDAT_COMPILE_SLOTS");
	const ss_ dir = env && *env ? ss_(env) : "/tmp/buildat-compile-"+itos(getuid());
	mkdir(dir.c_str(), 0700);
	struct stat st;
	if(lstat(dir.c_str(), &st) != 0 || !S_ISDIR(st.st_mode) ||
			st.st_uid != getuid() || (st.st_mode & 077)){
		log_w(MODULE, "Compile slots: %s is not this user's own directory; "
				"compiling one module at a time", cs(dir));
		return;
	}
	cpu_set_t set;
	const int cores = sched_getaffinity(0, sizeof set, &set) == 0 ?
			CPU_COUNT(&set) : (int)std::thread::hardware_concurrency();
	for(int i = 0; i < std::max(1, cores / 2); i++){
		const int fd = open((dir+"/slot"+itos(i)).c_str(),
				O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
		if(fd >= 0)
			g_compile_slots.push_back(fd);
	}
	if(g_compile_slots.empty())
		log_w(MODULE, "Compile slots: none could be opened in %s; compiling "
				"one module at a time", cs(dir));
#endif
}
// A free slot taken: its fd, or -1 (none free, or none at all). On
// Windows 0: no slots, none needed.
static int take_compile_slot()
{
#ifdef _WIN32
	return 0;
#else
	std::lock_guard<std::mutex> lock(g_compile_slots_mutex);
	for(int fd : g_compile_slots){
		// A lock this process holds would be granted again: skip those
		if(g_compile_slots_held.count(fd))
			continue;
		if(flock(fd, LOCK_EX | LOCK_NB) == 0){
			g_compile_slots_held.insert(fd);
			return fd;
		}
	}
	return -1;
#endif
}
static void give_compile_slot(int fd)
{
#ifndef _WIN32
	if(fd < 0)
		return;
	std::lock_guard<std::mutex> lock(g_compile_slots_mutex);
	flock(fd, LOCK_UN);
	g_compile_slots_held.erase(fd);
#endif
}

// The memory the system says is available, in bytes; -1 if unknown
static int64_t available_memory()
{
#ifdef _WIN32
	MEMORYSTATUSEX ms;
	ms.dwLength = sizeof ms;
	if(!GlobalMemoryStatusEx(&ms))
		return -1;
	return ms.ullAvailPhys;
#else
	std::ifstream f("/proc/meminfo");
	ss_ key;
	int64_t kb;
	while(f >> key >> kb){
		if(key == "MemAvailable:")
			return kb * 1024;
		f.ignore(1000, '\n');
	}
	return -1;
#endif
}

using interface::Event;

struct ModuleContainer;

struct ModuleThread: public interface::ThreadedThing
{
	ModuleContainer *mc = nullptr;

	ModuleThread(ModuleContainer *mc):
		mc(mc)
	{}

	void run(interface::Thread *thread);
	void on_crash(interface::Thread *thread);

	void handle_direct_cb(
			const std::function<void(interface::Module*)> *direct_cb);
	void handle_event(Event &event);
};

struct ModuleContainer
{
	interface::Server *server;
	interface::ThreadLocalKey *thread_local_key; // Stores mc*
	up_<interface::Module> module;
	interface::ModuleInfo info;
	up_<interface::Thread> thread;
	interface::Mutex mutex; // Protects each of the former variables

	// Allows directly executing code in the module thread
	const std::function<void(interface::Module*)> *direct_cb = nullptr;
	std::exception_ptr direct_cb_exception = nullptr;
	// The actual event queue
	std::deque<Event> event_queue; // Push back, pop front
	// How many events have gone into event_queue and how many the module's
	// thread has handled or dropped: what emit_event_sync() waits on
	uint64_t events_pushed = 0;
	uint64_t events_done = 0;
	// Packets a handler could not read: the first few are logged, then one
	// every ten seconds with how many went unsaid (the module's thread
	// only)
	uint64_t packet_failures = 0;
	uint64_t packet_failures_unlogged = 0;
	int64_t packet_failure_logged_us = 0;
	bool packet_failure_logged(){
		packet_failures++;
		const int64_t now = interface::os::time_us();
		if(packet_failures <= 10 ||
				now - packet_failure_logged_us >= 10000000){
			packet_failure_logged_us = now;
			return true;
		}
		packet_failures_unlogged++;
		return false;
	}
	std::mutex events_done_mutex;
	std::condition_variable events_done_cv;
	// Protects direct_cb and event_queue
	interface::Mutex event_queue_mutex;
	// Counts queued events, and +1 for direct_cb
	interface::Semaphore event_queue_sem;
	// post() when direct_cb has been executed, wait() for that to happen
	interface::Semaphore direct_cb_executed_sem;
	// post() when direct_cb becomes free, wait() for that to happen
	interface::Semaphore direct_cb_free_sem;
	// Which module is using the one direct_cb slot, for the log when
	// somebody has been waiting for it too long. Written by whoever holds
	// the slot and read by whoever is waiting, so a stale read says a name
	// that was true a moment ago, which is what it is for.
	ss_ direct_cb_holder;

	// When the caller currently in execute_direct_cb() started waiting for
	// the slot; see the warning there. Written and read under the slot's own
	// serialization, so there is only ever one caller in it.
	int64_t slot_wait_from = 0;

	// NOTE: thread-ref_backtraces() Holds the backtraces along the way of a
	// direct callback chain initiated by this module. Cleared when beginning to
	// execute a direct callback. Read when event() (and maybe something else)
	// returns an uncatched exception.

	// Set to true when deleting the module; used for enforcing some limitations
	bool executing_module_destructor = false;

	ModuleContainer(interface::Server *server = nullptr,
			interface::ThreadLocalKey *thread_local_key = NULL,
			interface::Module *module = NULL,
			const interface::ModuleInfo &info = interface::ModuleInfo()):
		server(server),
		thread_local_key(thread_local_key),
		module(module),
		info(info)
	{
		direct_cb_free_sem.post();
	}
	~ModuleContainer(){
		//log_t(MODULE, "M[%s]: Container: Destructing", cs(info.name));
	}
	void init_and_start_thread(){
		{
			interface::MutexScope ms(mutex);
			if(!module)
				throw Exception("init_and_start_thread(): module is null");
			if(info.name != module->m_module_name)
				throw Exception("init_and_start_thread(): Module name does not"
						" match: info.name=\""+info.name+"\","
						" module->m_module_name=\""+module->m_module_name+"\"");
			if(thread != nullptr)
				throw Exception("init_and_start_thread(): thread != nullptr");
			thread.reset(interface::createThread(new ModuleThread(this)));
			thread->set_name(info.name);
			thread->start();
		}
		// Initialize in thread
		std::exception_ptr eptr;
		execute_direct_cb([&](interface::Module *module){
			module->init();
		}, eptr, nullptr);
		if(eptr){
			std::rethrow_exception(eptr);
		}
	}
	void thread_request_stop(){
		interface::MutexScope ms(mutex);
		if(!thread)
			return;
		log_t(MODULE, "M[%s]: Container: Asking thread to exit",
				cs(info.name));
		thread->request_stop();
		// Pretend that direct_cb is now free so that execute_direct_cb can
		// continue (it will cancel due to thread->stop_requested()).
		direct_cb_free_sem.post();
		// Wake up thread so it can exit
		event_queue_sem.post();
		log_t(MODULE, "M[%s]: Container: Asked thread to exit",
				cs(info.name));
	}
	void thread_join(){
		if(thread){
			log_t(MODULE, "M[%s]: Container: Waiting thread to exit",
					cs(info.name));
			thread->join();
			log_t(MODULE, "M[%s]: Container: Thread exited; deleting thread",
					cs(info.name));
			{
				interface::MutexScope ms(mutex);
				thread.reset();
			}
			log_t(MODULE, "M[%s]: Container: Thread exited; thread deleted",
					cs(info.name));
		}
		// Module should have been deleted by the thread. In case the thread
		// failed, delete it here.
		// TODO: This is weird
		module.reset();
	}
	void push_event(const Event &event){
		interface::MutexScope ms(event_queue_mutex);
		// A tick is a heartbeat and not data: a module that takes longer
		// than the tick interval to handle one would otherwise collect a
		// queue of them that only grows, and every other event -- a
		// packet from a client, a generated section -- waits behind the
		// whole backlog. So a tick pushed at a module that has one
		// waiting is added to that one's dtime instead, which keeps the
		// time right for anything that integrates it.
		static const Event::Type tick_type =
				interface::getGlobalEventRegistry()->type("core:tick");
		if(event.type == tick_type){
			for(Event &queued : event_queue){
				if(queued.type != tick_type)
					continue;
				const auto *old_p = static_cast<
						const interface::TickEvent*>(queued.p.get());
				const auto *new_p = static_cast<
						const interface::TickEvent*>(event.p.get());
				if(!old_p || !new_p)
					break;
				queued = Event(tick_type, new interface::TickEvent(
						old_p->dtime + new_p->dtime));
				return;
			}
		}
		event_queue.push_back(event);
		events_pushed++;
		event_queue_sem.post();
	}
	void event_done(){
		{
			std::lock_guard<std::mutex> lock(events_done_mutex);
			events_done++;
		}
		events_done_cv.notify_all();
	}
	// Handled in the module's own thread, as any event is, and waited
	// for: run from the caller's thread it ran beside whatever the
	// module's thread was doing for another module -- voxelworld's save at
	// shutdown beside a relight luanti had asked for, both in its section
	// cache. Not as a direct callback either: that holds the module's slot
	// for the whole handler, and a handler that calls a module which is
	// itself waiting for this one deadlocks (network's shutdown and
	// client_file's).
	void emit_event_sync(const Event &event){
		uint64_t mine;
		{
			interface::MutexScope ms(event_queue_mutex);
			event_queue.push_back(event);
			mine = ++events_pushed;
			event_queue_sem.post();
		}
		std::unique_lock<std::mutex> lock(events_done_mutex);
		events_done_cv.wait(lock, [&]{ return events_done >= mine; });
	}
	// If returns false, the module thread is stopping and cannot be called
	// NOTE: It's not possible for the caller module to be deleted while this is
	//       being executed so a pointer to it is fine (which can be nullptr).
	void execute_direct_cb(const std::function<void(interface::Module*)> &cb,
			std::exception_ptr &result_exception,
			ModuleContainer *caller_mc)
	{
		if(caller_mc == this) // Not allowed
			throw Exception("caller_mc == this");
		log_t(MODULE, "execute_direct_cb[%s]: Waiting for direct_cb to be free",
				cs(info.name));
		// Wait for direct_cb to be free, in slices, so that a wait that
		// never ends says whose it is: one module can be inside another at
		// a time, and a caller queueing behind a call that is itself stuck
		// is how a deadlock here looks from the outside. Said after five
		// seconds and every ten after that.
		{
			// The same twenty as below, for the same reason
			static const int64_t FIRST_US = 20000000;
			static const int64_t THEN_US = 10000000;
			int64_t waited = 0;
			int64_t slice = FIRST_US;
			slot_wait_from = interface::os::time_us();
			while(!direct_cb_free_sem.wait_us(slice)){
				waited += slice;
				slice = THEN_US;
				const ss_ caller_name = caller_mc ? caller_mc->info.name :
						ss_("(not a module)");
				log_w(MODULE, "M[%s] has been waiting %.0f s to get into "
						"M[%s], which M[%s] is in", cs(caller_name),
						waited / 1e6, cs(info.name), cs(direct_cb_holder));
			}
		}
		const int64_t slot_us = interface::os::time_us() - slot_wait_from;
		direct_cb_holder = caller_mc ? caller_mc->info.name :
				ss_("(not a module)");
		// Whose queue a module is waiting in. A wait of seconds is the shape
		// of every slow thing between modules here, and which half it is --
		// waiting for the module to be free, or waiting for the callback to
		// run -- is the difference between "somebody else is in there" and
		// "what I asked for is slow". Said at a second, because a startup
		// legitimately spends longer than that and a line per access would
		// be the log.
		const int64_t cb_from = interface::os::time_us();
		{
			interface::MutexScope ms(mutex);
			// This is the last chance to turn around
			if(thread->stop_requested()){
				log_t(MODULE, "execute_direct_cb[%s]: Stop requested; cancelling.",
						cs(info.name));

				// Let the next ones pass too
				direct_cb_holder = "";
				direct_cb_free_sem.post();

				// Return an exception to make sure the caller doesn't continue
				// without knowing what it's doing
				ss_ caller_name = caller_mc ? caller_mc->info.name : "__unknown";
				throw interface::ModuleAskedToStop(
						"Target module ["+info.name+"] is stopping - "
						"called by ["+caller_name+"]");
			}
		}
		log_t(MODULE, "execute_direct_cb[%s]: Direct_cb is now free. "
				"Waiting for event queue lock", cs(info.name));
		{
			interface::MutexScope ms(event_queue_mutex);
			log_t(MODULE, "execute_direct_cb[%s]: Posting direct_cb",
					cs(info.name));
			direct_cb = &cb;
			direct_cb_exception = nullptr;
			thread->set_caller_thread(interface::Thread::get_current_thread());
			thread->ref_backtraces().clear();
			event_queue_sem.post();
		}
		log_t(MODULE, "execute_direct_cb[%s]: Waiting for execution to finish",
				cs(info.name));
		// NOTE: If execution hangs here, the problem cannot be solved by
		//       forcing this semaphore to open, because exiting this function
		//       while direct_cb is being executed is unsafe. You have to figure
		//       out what direct_cb has ended up waiting for, and fix that.
		// Wait for execution to finish, in slices, so that a wait that never
		// ends says whose it is: a module calling into another and never
		// coming back is a server that looks hung with nothing in the log,
		// and the name of both ends is the whole of what anybody chasing it
		// needs first. It says so once and then every ten seconds.
		{
			// Twenty seconds before the first word, because a module can
			// legitimately be busy for a long time -- VoxeLibre's mods take
			// eleven seconds to load and everything else waits for that --
			// and a warning that fires on every startup is one nobody reads.
			static const int64_t FIRST_US = 20000000;
			static const int64_t THEN_US = 10000000;
			int64_t waited = 0;
			int64_t slice = FIRST_US;
			while(!direct_cb_executed_sem.wait_us(slice)){
				waited += slice;
				slice = THEN_US;
				const ss_ caller_name = caller_mc ? caller_mc->info.name :
						ss_("(not a module)");
				log_w(MODULE, "M[%s] has been waiting %.0f s for M[%s] to "
						"run a direct callback", cs(caller_name),
						waited / 1e6, cs(info.name));
			}
		}
		{
			static const int64_t SLOW_ACCESS_US = 1000000;
			const int64_t cb_us = interface::os::time_us() - cb_from;
			if(slot_us + cb_us >= SLOW_ACCESS_US){
				const ss_ caller_name = caller_mc ? caller_mc->info.name :
						ss_("(not a module)");
				log_w(MODULE, "M[%s] waited %.1f s for M[%s]: %.1f s for the "
						"module to be free, %.1f s for the callback to run",
						cs(caller_name), (slot_us + cb_us) / 1e6,
						cs(info.name), slot_us / 1e6, cb_us / 1e6);
			}
		}
		// Grab execution result
		std::exception_ptr eptr = direct_cb_exception;
		direct_cb_exception = nullptr; // Not to be used anymore
		thread->set_caller_thread(nullptr);
		// Set direct_cb to be free again
		direct_cb_holder = "";
		direct_cb_free_sem.post();
		// Handle execution result
		if(eptr){
			log_t(MODULE, "execute_direct_cb[%s]: Execution finished by"
					" exception", cs(info.name));
			/*interface::debug::log_current_backtrace(
					"Backtrace for M["+info.name+"]'s caller:");*/
			result_exception = eptr;
		} else {
			log_t(MODULE, "execute_direct_cb[%s]: Execution finished",
					cs(info.name));
		}
	}
};

void ModuleThread::run(interface::Thread *thread)
{
	mc->thread_local_key->set((void*)mc);

	for(;;){
		// Wait for an event
		mc->event_queue_sem.wait();
		// NOTE: Do not stop here, because we have to process the waited direct
		//       callback or event in order for the caller to be able to safely
		//       return.
		// Grab the direct callback or an event from the queue
		const std::function<void(interface::Module*)> *direct_cb = nullptr;
		Event event;
		bool got_event = false;
		{
			interface::MutexScope ms(mc->event_queue_mutex);
			if(mc->direct_cb){
				direct_cb = mc->direct_cb;
			} else if(!mc->event_queue.empty()){
				event = mc->event_queue.front();
				mc->event_queue.pop_front();
				got_event = true;
			}
		}
		// Check if should stop
		if(thread->stop_requested()){
			log_t(MODULE, "M[%s]: Stopping event loop", cs(mc->info.name));
			// Act like we processed the request
			if(direct_cb){
				log_t(MODULE, "M[%s]: Discarding direct_cb", cs(mc->info.name));
				{
					interface::MutexScope ms(mc->event_queue_mutex);
					mc->direct_cb = nullptr;
				}
				mc->direct_cb_executed_sem.post();
			}
			if(got_event){
				log_t(MODULE, "M[%s]: Discarding event", cs(mc->info.name));
			}
			// Nothing queued will be handled now; nobody waits for it
			{
				std::lock_guard<std::mutex> lock(mc->events_done_mutex);
				mc->events_done = UINT64_MAX;
			}
			mc->events_done_cv.notify_all();
			// Stop
			break;
		}
		if(direct_cb){
			// Handle the direct callback
			handle_direct_cb(direct_cb);
		} else if(got_event){
			// Handle the event
			handle_event(event);
			mc->event_done();
		} else {
			log_w(MODULE, "M[%s]: Event semaphore indicated something happened,"
					" but there was no event, direct callback nor was the thread"
					" asked to stop.", cs(mc->info.name));
		}
	}
	// Delete module in this thread. This is important in case the destruction
	// of some objects in the module is required to be done in the same thread
	// as they were created in.
	// It is also important to delete the module outside of mc->mutex, as doing
	// it in the locked state will only cause deadlocks.
	up_<interface::Module> module_moved;
	{
		interface::MutexScope ms(mc->mutex);
		module_moved = std::move(mc->module);
	}
	mc->executing_module_destructor = true;
	module_moved.reset();
	mc->executing_module_destructor = false;
}

void ModuleThread::on_crash(interface::Thread *thread)
{
	// TODO: Could just restart or something
	mc->server->shutdown(1, "M["+mc->info.name+"] crashed");
}

void ModuleThread::handle_direct_cb(
		const std::function<void(interface::Module*)> *direct_cb)
{
	std::exception_ptr eptr = nullptr;
	if(!mc->module){
		log_w(MODULE, "M[%s]: Module is null; cannot"
				" call direct callback", cs(mc->info.name));
	} else {
		try {
			log_t(MODULE, "M[%s] ~direct_cb(): Executing",
					cs(mc->info.name));
			(*direct_cb)(mc->module.get());
			log_t(MODULE, "M[%s] ~direct_cb(): Executed",
					cs(mc->info.name));
		} catch(...){
			log_t(MODULE, "M[%s] ~direct_cb() failed (exception)",
					cs(mc->info.name));
			// direct_cb() exception should not directly shutdown the
			// server; instead they are passed to the caller. Eventually
			// a caller is reached who isn't using direct_cb(), which
			// then determines the final result of the exception.
			eptr = std::current_exception();

			// If called from another thread
			interface::Thread *current_thread =
					interface::Thread::get_current_thread();
			if(current_thread->get_caller_thread()){
				// Find out the original thread that initiated this direct_cb chain
				interface::Thread *orig_thread =
						current_thread->get_caller_thread();
				while(orig_thread->get_caller_thread()){
					orig_thread = orig_thread->get_caller_thread();
				}

				// Insert exception backtrace to original chain initiator's
				// backtrace list, IF the list is empty
				if(orig_thread->ref_backtraces().empty()){
					interface::debug::ThreadBacktrace bt_step;
					bt_step.thread_name = current_thread->get_name();
					interface::debug::get_exception_backtrace(bt_step.bt);
					orig_thread->ref_backtraces().push_back(bt_step);
				}
			}
		}
	}
	{
		interface::MutexScope ms(mc->event_queue_mutex);
		mc->direct_cb = nullptr;
		mc->direct_cb_exception = eptr;
	}
	mc->direct_cb_executed_sem.post();
}

// How long a module may spend on one event before it is worth saying so.
// A module's thread handles one event at a time and everything else waits --
// another module's access into it, and every event behind it in its own
// queue -- so a handler that takes seconds is felt everywhere as lag, and
// which handler it was is the first thing anybody chasing that wants to
// know. A second is far past anything a game does per event on purpose.
static const int64_t SLOW_EVENT_US = 1000000;

void ModuleThread::handle_event(Event &event)
{
	if(!mc->module){
		log_w(MODULE, "M[%s]: Module is null; cannot"
				" handle event", cs(mc->info.name));
	} else {
		try {
			log_t(MODULE, "M[%s]->event(): Executing",
					cs(mc->info.name));
			const int64_t t0 = interface::os::time_us();
			mc->module->event(event.type, event.p.get());
			const int64_t took = interface::os::time_us() - t0;
			if(took >= SLOW_EVENT_US){
				log_w(MODULE, "M[%s]->event(\"%s\") took %.1f s",
						cs(mc->info.name),
						cs(interface::getGlobalEventRegistry()->name(
								event.type)), took / 1e6);
			}
			log_t(MODULE, "M[%s]->event(): Executed",
					cs(mc->info.name));
		} catch(std::exception &e){
			// If event handling results in an uncatched exception, the
			// server shall shut down -- unless the event is a client's
			// packet: what a client sends is for anyone to make, and a
			// packet a handler cannot read (a short cereal archive, a size
			// it cannot allocate) is that packet's failure and not the
			// server's. It is dropped and said, backtrace and all.
			const ss_ name = interface::getGlobalEventRegistry()->name(
					event.type);
			const bool from_client =
					name.compare(0, 24, "network:packet_received/") == 0;
			if(!from_client){
				mc->server->shutdown(1, "M["+mc->info.name+"]->event() "
						"failed: "+e.what());
			} else if(!mc->packet_failure_logged()){
				// A peer sending what a handler cannot read is said a few
				// times and then counted: each line came with a backtrace
				// symbolised by a process of its own, 170 ms a packet, and
				// a client's flood of small broken packets was minutes of
				// the module's time and the log's disk ([SECURITY_RUN_1],
				// util/fuzz/proto_fuzz.sh)
				return;
			}
			log_w(MODULE, "M[%s]->event(\"%s\") failed%s: %s",
					cs(mc->info.name), cs(name),
					from_client ? " (the packet is dropped)" : "", e.what());
			if(from_client && mc->packet_failures_unlogged > 0){
				log_w(MODULE, "M[%s]: %llu more packets it could not read "
						"were dropped without a line", cs(mc->info.name),
						(unsigned long long)mc->packet_failures_unlogged);
				mc->packet_failures_unlogged = 0;
			}
			if(!mc->thread->ref_backtraces().empty()){
				interface::debug::log_backtrace_chain(
						mc->thread->ref_backtraces(), e.what());
			} else {
				interface::debug::StoredBacktrace bt;
				interface::debug::get_exception_backtrace(bt);
				interface::debug::log_backtrace(bt,
						"Backtrace in M["+mc->info.name+"] for "+
						bt.exception_name+"(\""+e.what()+"\")");
			}
		}
	}
}

struct CState;

struct FileWatchThread: public interface::ThreadedThing
{
	CState *m_server;

	FileWatchThread(CState *server):
		m_server(server)
	{}

	void run(interface::Thread *thread);
	void on_crash(interface::Thread *thread);
};

struct CState: public State, public interface::Server
{
	bool m_shutdown_requested = false;
	int m_shutdown_exit_status = 0;
	ss_ m_shutdown_reason;
	interface::Mutex m_shutdown_mutex;

	up_<rccpp::Compiler> m_compiler;
	// [CLIENT_WASM] module name -> its built .wasm
	sm_<ss_, ss_> m_module_wasm;
	ss_ m_modules_path;

	// Thread-local pointer to ModuleContainer of the module of each module
	// thread
	interface::ThreadLocalKey m_thread_local_mc_key;

	sm_<ss_, interface::ModuleInfo> m_module_info; // Info of every seen module
	sm_<ss_, sp_<ModuleContainer>> m_modules; // Currently loaded modules
	set_<ss_> m_unloads_requested;
	sv_<interface::ModuleInfo> m_reloads_requested;
	sm_<ss_, sp_<interface::FileWatch>> m_module_file_watches;
	// Module modifications are accumulated here and core:module_modified events
	// are fired every event loop based on this to lump multiple modifications
	// into one (generally a modification causes many notifications)
	set_<ss_> m_modified_modules; // Module names
	// TODO: Handle properly in reloads (unload by popping from top, then reload
	//       everything until top)
	sv_<ss_> m_module_load_order;
	size_t m_module_count = 0;
	// Each type's subscribers, copied on write: an emit holds its type's
	// list without copying the rest ([EVENT_DISPATCH])
	typedef sv_<wp_<ModuleContainer>> SubList;
	sv_<sp_<const SubList>> m_event_subs;
	// NOTE: You can make a copy of an sp_<ModuleContainer> and unlock this
	//       mutex for processing the module asynchronously (just lock mc->mutex)
	interface::Mutex m_modules_mutex;

	sm_<ss_, ss_> m_tmp_data;
	interface::Mutex m_tmp_data_mutex;

	sm_<ss_, ss_> m_file_paths;
	interface::Mutex m_file_paths_mutex;

	sp_<interface::thread_pool::ThreadPool> m_thread_pool;
	interface::Mutex m_thread_pool_mutex;

	// Must come after the members this will access, which are m_modules_mutex
	// and m_module_file_watches.
	up_<interface::Thread> m_file_watch_thread;

	CState():
		m_compiler(rccpp::createCompiler(
				g_server_config.get<ss_>("compiler_command"))),
		m_thread_pool(interface::thread_pool::createThreadPool())
	{
		m_thread_pool->start(4); // TODO: Configurable

		m_file_watch_thread.reset(interface::createThread(
				new FileWatchThread(this)));
		m_file_watch_thread->set_name("state/select");
		m_file_watch_thread->start();

		// Set basic RCC++ include directories

		// We don't want to directly add the interface path as it contains
		// stuff like mutex.h which match on Windows to Urho3D's Mutex.h
		// The parent named, not ".../interface/..": in a Windows
		// AppContainer gcc's check took a directory ending in ".." for
		// one that is not there, and no module found interface/module.h
		// ([PROCESS_SANDBOX] B, 2026-10-03)
		{
			ss_ ip = g_server_config.get<ss_>("interface_path");
			while(!ip.empty() && (ip.back() == '/' || ip.back() == '\\'))
				ip.pop_back();
			m_compiler->include_directories.push_back(
					interface::fs::strip_file_name(ip));
		}
		m_compiler->include_directories.push_back(
				g_server_config.get<ss_>(
				"interface_path")+"/../../3rdparty/cereal/include");
		m_compiler->include_directories.push_back(
				g_server_config.get<ss_>("interface_path")+
				"/../../3rdparty/polyvox/library/PolyVoxCore/include");
		// Only builtin/storage includes sqlite3.h; everything else goes
		// through its api.h. The symbols come from buildat_core, which the
		// server already has open, so no module links anything for this.
		m_compiler->include_directories.push_back(
				g_server_config.get<ss_>("interface_path")+
				"/../../3rdparty/sqlite/src");
		m_compiler->include_directories.push_back(
				g_server_config.get<ss_>("share_path")+"/builtin");

		// Setup Urho3D in RCC++

		sv_<ss_> urho3d_subdirs = {
			"Audio", "Container", "Core", "Engine", "Graphics", "IK", "Input",
			"IO", "LuaScript", "Math", "Navigation", "Network", "Physics",
			"Resource", "Scene", "UI", "Urho2D",
		};
		ss_ urho3d_path = g_server_config.get<ss_>("urho3d_path");
		m_compiler->include_directories.push_back(
				urho3d_path+"/Source/Urho3D");
		for(const ss_ &subdir : urho3d_subdirs){
			m_compiler->include_directories.push_back(
					urho3d_path+"/Source/Urho3D/"+subdir);
		}
		m_compiler->include_directories.push_back(
				urho3d_path+"/Build/include");
		m_compiler->include_directories.push_back(
				urho3d_path+"/Build/include/Urho3D");
		m_compiler->include_directories.push_back(
				urho3d_path+"/Build/include/Urho3D/ThirdParty");
		m_compiler->include_directories.push_back(
				urho3d_path+"/Build/include/Urho3D/ThirdParty/Bullet");
		// The Lua the engine was built with, for a module's <lua.h>: the
		// bundled Lua's headers land under ThirdParty/Lua and LuaJIT's
		// under ThirdParty/LuaJIT, and the server links whichever it is
		// ([LUAJIT] in doc/plan/performance_plan.md)
		m_compiler->include_directories.push_back(
				urho3d_path+"/Build/include/Urho3D/ThirdParty/"+
				ss_(BUILDAT_LUA_DIR));
		m_compiler->include_directories.push_back(
				urho3d_path+"/Source/ThirdParty/SDL/include");
		m_compiler->library_directories.push_back(
				urho3d_path+"/Build/lib");
		// And an archive's lib/ beside the share path, where the install
		// rules put libUrho3D and buildat_core ([PACKAGING]); a source
		// tree has no such directory and the line is harmless there
		m_compiler->library_directories.push_back(
				g_server_config.get<ss_>("share_path")+"/lib");
		m_compiler->libraries.push_back("-lUrho3D");
		m_compiler->include_directories.push_back(
				urho3d_path+"/Source/ThirdParty/Bullet/src");
	}
	~CState()
	{
		// Torn down by hand, a step a line: a Windows server hung past its
		// modules' stop with nothing logged, and these lines named the
		// thread pool's join (2026-10-03; the cause is in thread_pool.cpp)
		log_d(MODULE, "Teardown: the thread pool");
		m_thread_pool.reset();
		log_d(MODULE, "Teardown: the file watch thread");
		m_file_watch_thread.reset();
		log_d(MODULE, "Teardown: the module containers");
		m_event_subs.clear();
		m_modules.clear();
		log_d(MODULE, "Teardown: the module file watches");
		m_module_file_watches.clear();
		log_d(MODULE, "Teardown: the compiler");
		m_compiler.reset();
		log_d(MODULE, "Teardown: the rest");
	}

	sv_<sp_<ModuleContainer>> get_modules_in_unload_order()
	{
		// Unload modules in reverse load order to make things work more
		// predictably
		sv_<sp_<ModuleContainer>> mcs;
		{
			// Don't have this locked when handling modules because it causes
			// deadlocks
			interface::MutexScope ms(m_modules_mutex);
			for(auto name_it = m_module_load_order.rbegin();
			name_it != m_module_load_order.rend(); ++name_it){
				auto it2 = m_modules.find(*name_it);
				if(it2 == m_modules.end())
					continue;
				sp_<ModuleContainer> &mc = it2->second;
				mcs.push_back(mc);
			}
		}
		return mcs;
	}

	void thread_request_stop()
	{
		m_file_watch_thread->request_stop();
		// The modules are not stopped here. A module is destructed by its own
		// thread as it stops, and a destructor may still call into the modules
		// it was built on -- replicate clears its replication state inside
		// main_context, on purpose, because Urho3D's weak pointers are not
		// thread safe. Asking every module to stop up front makes every one of
		// those calls fail, so each is stopped in thread_join() instead, one at
		// a time and in reverse load order, with the ones below it still
		// running.
	}

	void thread_join()
	{
		log_v(MODULE, "Waiting: file watch");
		m_file_watch_thread->join();

		sv_<sp_<ModuleContainer>> mcs = get_modules_in_unload_order();

		log_v(MODULE, "Waiting: modules");
		for(sp_<ModuleContainer> &mc : mcs){
			log_d(MODULE, "Stopping module: [%s]", cs(mc->info.name));
			mc->thread_request_stop();
			mc->thread_join();
			// Remove our reference to the module container, so that any child
			// threads it will now delete will not get deadlocked in trying to
			// access the module
			// (This is a shared pointer)
			mc.reset();
		}
	}

	void shutdown(int exit_status, const ss_ &reason)
	{
		interface::MutexScope ms(m_shutdown_mutex);
		if(m_shutdown_requested && exit_status == 0){
			// Only reset these values for exit values indicating failure
			return;
		}
		log_i(MODULE, "Server shutdown requested; exit_status=%i, reason=\"%s\"",
				exit_status, cs(reason));
		m_shutdown_requested = true;
		m_shutdown_exit_status = exit_status;
		m_shutdown_reason = reason;
	}

	bool is_shutdown_requested(int *exit_status = nullptr, ss_ *reason = nullptr)
	{
		interface::MutexScope ms(m_shutdown_mutex);
		if(m_shutdown_requested){
			if(exit_status)
				*exit_status = m_shutdown_exit_status;
			if(reason)
				*reason = m_shutdown_reason;
		}
		return m_shutdown_requested;
	}

	// What building a module takes, and whether its build is current
	struct BuildJob
	{
		ss_ init_cpp_path;
		ss_ build_dst;
		ss_ hashfile_path;
		ss_ hash_hex;
		ss_ extra_cxxflags;
		ss_ extra_ldflags;
		bool skip_compile = false;
	};

	BuildJob plan_build_u(const interface::ModuleInfo &info,
			const sv_<ss_> &includes)
	{
		ss_ init_cpp_path = info.path+"/"+info.name+".cpp";
		ss_ extra_cxxflags = info.meta.cxxflags;
		ss_ extra_ldflags = info.meta.ldflags;
#ifdef _WIN32
		extra_cxxflags += " "+info.meta.cxxflags_windows;
		extra_ldflags += " "+info.meta.ldflags_windows;
		// Needed for every module
		extra_ldflags += " -lbuildat_core";
		// Always include these to make life easier
		extra_ldflags += " -lwsock32 -lws2_32";
		// Add the path of the current executable to the library search path
		{
			ss_ exe_path = interface::os::get_current_exe_path();
			ss_ exe_dir = interface::fs::strip_file_name(exe_path);
			extra_ldflags += " -L\""+exe_dir+"\"";
		}
#else
		extra_cxxflags += " "+info.meta.cxxflags_linux;
		extra_ldflags += " "+info.meta.ldflags_linux;
#endif
		log_d(MODULE, "extra_cxxflags: %s", cs(extra_cxxflags));
		log_d(MODULE, "extra_ldflags: %s", cs(extra_ldflags));

		bool skip_compile = g_server_config.get<json::Value>(
				"skip_compiling_modules").get(info.name).as_boolean();

		sv_<ss_> files_to_hash = {init_cpp_path};
		files_to_hash.insert(
				files_to_hash.begin(), includes.begin(), includes.end());

		// [CLIENT_WASM] step 5: wasm/'s C and C++, the code the clients run
		// as a .wasm, compiled into the module too, so the server calls the
		// same functions natively. A .c as C. No a * b + c fused into one
		// rounding anywhere in the module, as in the .wasm (wasm_build.cpp):
		// main.cpp inlines wasm/'s headers. The sources go on the one
		// command line through the flags, before the module's own file.
		// simplified: no import reaches the server (wasm_api.h's natively
		// trap); a module whose wasm/ cannot build natively is refused
		{
			const ss_ wasm_dir = info.path+"/wasm";
			sv_<ss_> sources;
			std::function<void(const ss_ &)> scan = [&](const ss_ &dir){
				for(const auto &n : interface::fs::list_directory(dir)){
					const ss_ p = dir+"/"+n.name;
					const size_t dot = n.name.rfind('.');
					const ss_ ext = dot == ss_::npos ? "" : n.name.substr(dot);
					if(n.is_directory)
						scan(p);
					else if(ext == ".c" || ext == ".cc" || ext == ".cpp")
						sources.push_back(p);
				}
			};
			if(interface::fs::path_exists(wasm_dir))
				scan(wasm_dir);
			std::sort(sources.begin(), sources.end());
			sv_<ss_> include_dirs = m_compiler->include_directories;
			include_dirs.push_back(m_modules_path);
			if(!sources.empty())
				extra_cxxflags += " -ffp-contract=off";
			for(const ss_ &p : sources){
				const bool c = p.size() > 2 && p.compare(p.size() - 2, 2, ".c") == 0;
				extra_cxxflags += c ? " -x c "+p+" -x none" : " "+p;
				files_to_hash.push_back(p);
				for(const ss_ &i : list_includes(p, include_dirs))
					files_to_hash.push_back(i);
			}
		}
		// The optimization flags go in too; without them a cache built at a
		// different level is kept and silently used
		ss_ content_hash = hash_files(files_to_hash,
				rccpp::cxxflags_optimize());
		log_d(MODULE, "Module hash: %s", cs(interface::sha1::hex(content_hash)));

#ifdef _WIN32
		// On Windows, we need a new name for each modification of the module
		// because Windows caches DLLs by name
		ss_ build_dst = g_server_config.get<ss_>("rccpp_build_path") +
				"/"+info.name+"_"+interface::sha1::hex(content_hash)+"."+
				MODULE_EXTENSION;
		// TODO: Delete old ones
#else
		// Named by the directory the module is in as well as its own name
		// ([LINUX_SERVER]): every game's module is "main", and one cache --
		// the one a portable archive ships -- holds every game's. The
		// directory's name, not its path, so the name holds wherever the
		// tree is unpacked.
		ss_ parent = info.path;
		while(!parent.empty() && (parent.back() == '/' || parent.back() == '\\'))
			parent.pop_back();
		parent = interface::fs::strip_file_name(parent);
		while(!parent.empty() && (parent.back() == '/' || parent.back() == '\\'))
			parent.pop_back();
		const size_t slash = parent.find_last_of("/\\");
		if(slash != ss_::npos)
			parent = parent.substr(slash + 1);
		ss_ build_dst = g_server_config.get<ss_>("rccpp_build_path") +
				"/"+(parent.empty() ? ss_() : parent+"_")+info.name+"."+
				MODULE_EXTENSION;
#endif

		ss_ hashfile_path = build_dst+".hash";

		// [PROCESS_SANDBOX]: a boxed server builds into its app's own
		// cache, and the shared build -- what an unboxed run or the
		// archive made -- is read, never written: a module whose hash
		// matches there is loaded from it as it is
		const ss_ prebuilt_dir = g_server_config.get<ss_>("rccpp_prebuilt_path");
		if(!skip_compile && !prebuilt_dir.empty() &&
				!std::ifstream(build_dst).good()){
			// The same file name in the other directory
			const ss_ prebuilt = prebuilt_dir+build_dst.substr(
					g_server_config.get<ss_>("rccpp_build_path").size());
			std::ifstream f(prebuilt+".hash");
			ss_ previous_hash;
			if(f.good())
				previous_hash = ss_((std::istreambuf_iterator<char>(f)),
						std::istreambuf_iterator<char>());
			if(std::ifstream(prebuilt).good() &&
					previous_hash == interface::sha1::hex(content_hash)){
				log_v(MODULE, "%s: the shared build's is current; loading it",
						cs(info.name));
				build_dst = prebuilt;
				hashfile_path = prebuilt+".hash";
				skip_compile = true;
			}
		}

		if(!skip_compile){
			if(!std::ifstream(build_dst).good()){
				// Result file does not exist at all, no need to check hashes
			} else {
				ss_ previous_hash;
				{
					std::ifstream f(hashfile_path);
					if(f.good()){
						previous_hash = ss_((std::istreambuf_iterator<char>(f)),
								std::istreambuf_iterator<char>());
					}
				}
				// The file holds the hash as hex: the raw bytes, read back
				// in text mode on Windows, ended at a 0x1a (Ctrl-Z) -- two
				// of fifteen modules' hashes held one and compiled on every
				// start of the box ([BOX_FIXES] c). An old raw file
				// mismatches once and is rewritten.
				if(previous_hash == interface::sha1::hex(content_hash)){
					log_v(MODULE, "No need to recompile %s", cs(info.name));
					skip_compile = true;
				} else {
					log_v(MODULE, "%s: the cached hash differs (%s against %s); "
							"compiling", cs(info.name), cs(previous_hash.substr(0, 12)),
							cs(interface::sha1::hex(content_hash).substr(0, 12)));
				}
			}
		}

		BuildJob job;
		job.init_cpp_path = init_cpp_path;
		job.build_dst = build_dst;
		job.hashfile_path = hashfile_path;
		job.hash_hex = interface::sha1::hex(content_hash);
		job.extra_cxxflags = extra_cxxflags;
		job.extra_ldflags = extra_ldflags;
		job.skip_compile = skip_compile;
		return job;
	}

	interface::Module* build_module_u(const interface::ModuleInfo &info)
	{
#ifdef BUILDAT_STATIC_MODULES
		// Linked in ([WEB_LOCAL_SERVER]): no compile, no cache, no reload
		for(const StaticModule *sm = g_static_modules; sm->name; sm++){
			if(info.name == sm->name){
				log_i(MODULE, "STATUS Loading %s (%zu of %zu)", cs(info.name),
						m_module_load_order.size() + 1, m_module_count);
				return static_cast<interface::Module*>(sm->create(this));
			}
		}
		log_w(MODULE, "Module %s is not in this build", cs(info.name));
		return nullptr;
#endif
		ss_ init_cpp_path = info.path+"/"+info.name+".cpp";

		// What this module is built out of. The build cache is keyed on all
		// of it, so the scan happens whether or not anything is watched.
		sv_<ss_> include_dirs = m_compiler->include_directories;
		include_dirs.push_back(m_modules_path);
		sv_<ss_> includes = list_includes(init_cpp_path, include_dirs);
		log_d(MODULE, "Includes: %s", cs(dump(includes)));

		// And the watch that restarts the module when one of them changes,
		// if this server is one that does that. Off by default: see
		// "reload_modules" in server/config.cpp for why, and -R for turning
		// it on. No inotify watch exists at all when it is off.
		if(g_server_config.get<bool>("reload_modules")){
			sv_<ss_> files_to_watch = {init_cpp_path};
			files_to_watch.insert(files_to_watch.end(), includes.begin(),
					includes.end());

			if(m_module_file_watches.count(info.name) == 0){
				sp_<interface::FileWatch> w(interface::createFileWatch());
				for(const ss_ &watch_path : files_to_watch){
					ss_ dir_path = interface::fs::strip_file_name(watch_path);
					w->add(dir_path, [this, info, watch_path](
							const ss_ &modified_path){
						if(modified_path != watch_path)
							return;
						log_i(MODULE, "Module modified: %s: %s",
								cs(info.name), cs(info.path));
						m_modified_modules.insert(info.name);
					});
				}
				m_module_file_watches[info.name] = w;
			}
		}

		// Build

		BuildJob job = plan_build_u(info, includes);
		const bool skip_compile = job.skip_compile;

		// The status line a start is read by ([START_PROGRESS]): the
		// client's waiting screen tails the log for "STATUS ", and a
		// shell start reads the same. A cache hit is a "Loading", a
		// compile a "Compiling", so a first start reads differently.
		if(m_module_count)
			log_i(MODULE, "STATUS %s %s (%zu of %zu)",
					skip_compile ? "Loading" : "Compiling", cs(info.name),
					m_module_load_order.size() + 1, m_module_count);
		else
			log_i(MODULE, "STATUS %s %s (%zu of ?)",
					skip_compile ? "Loading" : "Compiling", cs(info.name),
					m_module_load_order.size() + 1);

		m_compiler->include_directories.push_back(m_modules_path);
		bool build_ok = m_compiler->build(info.name, job.init_cpp_path,
				job.build_dst, job.extra_cxxflags, job.extra_ldflags, skip_compile);
		m_compiler->include_directories.pop_back();

		if(!build_ok){
			log_w(MODULE, "Failed to build module %s", cs(info.name));
			return nullptr;
		}

		// Update hash file
		if(!skip_compile){
			std::ofstream f(job.hashfile_path);
			f<<job.hash_hex;
		}

		// Construct instance

		interface::Module *m = static_cast<interface::Module*>(
				m_compiler->construct(info.name.c_str(), this));
		return m;
	}

	// Can be used for loading hardcoded modules.
	// There intentionally is no core:module_loaded event.
	void load_module_direct_u(interface::Module *m, const ss_ &name)
	{
		sp_<ModuleContainer> mc;
		{
			interface::MutexScope ms(m_modules_mutex);

			interface::ModuleInfo info;
			info.name = name;
			info.path = "";

			log_i(MODULE, "Loading module %s (hardcoded)", cs(info.name));

			m_module_info[info.name] = info;

			// TODO: Fix to something like in load_module()
			mc = sp_<ModuleContainer>(new ModuleContainer(
					this, &m_thread_local_mc_key, m, info));
			m_modules[info.name] = mc;
			m_module_load_order.push_back(info.name);
		}

		// Call init() and start thread
		mc->init_and_start_thread();
	}

	bool load_module(const interface::ModuleInfo &info)
	{
		interface::Module *m = nullptr;
		{
			interface::MutexScope ms(m_modules_mutex);

			if(m_modules.find(info.name) != m_modules.end()){
				log_w(MODULE, "Cannot load module %s from %s: Already loaded",
						cs(info.name), cs(info.path));
				return false;
			}

			log_i(MODULE, "Loading module %s from %s", cs(info.name), cs(info.path));

			m_module_info[info.name] = info;

			// [CLIENT_WASM] The client's half of wasm/, built first: a module
			// whose wasm/ does not build is refused before it starts. A
			// builtin is not: every game needs it, and its client Lua has a
			// way without the .wasm, as on a client with no wasm (macOS)
			if(interface::fs::path_exists(info.path+"/wasm")){
				const ss_ wasm = build_module_wasm(g_server_config, info.name,
						info.path);
				const bool builtin = info.path.rfind(
						get_builtin_modules_path()+"/", 0) == 0;
				if(wasm.empty() && !builtin){
					log_e(MODULE, "%s: no wasm; the module is refused",
							cs(info.name));
					return false;
				}
				if(wasm.empty())
					log_w(MODULE, "%s: no wasm; a builtin, loaded without it "
							"(its clients run their Lua instead)", cs(info.name));
				else
					m_module_wasm[info.name] = wasm;
			}

			if(!info.meta.disable_cpp){
				m = build_module_u(info);

				if(m == nullptr){
					log_w(MODULE, "Failed to construct module %s instance",
							cs(info.name));
					return false;
				}
			}
		}

		sp_<ModuleContainer> mc = sp_<ModuleContainer>(
				new ModuleContainer(this, &m_thread_local_mc_key, m, info));

		{
			interface::MutexScope ms(m_modules_mutex);

			m_modules[info.name] = mc;
			m_module_load_order.push_back(info.name);
		}

		if(!info.meta.disable_cpp){
			// Call init() and start thread
			mc->init_and_start_thread();
		}

		emit_event(Event("core:module_loaded",
				new interface::ModuleLoadedEvent(info.name)));
		return true;
	}

	void load_modules(const ss_ &path)
	{
		m_modules_path = path;

		// builtin/loader loads the app's own modules; it used to be reached
		// through an __loader module every app carried ([ENGINE_LOADER])
		interface::ModuleInfo info;
		info.name = "loader";
		info.path = get_builtin_modules_path()+"/"+info.name;

		if(!load_module(info)){
			shutdown(1, "Failed to load builtin/loader");
			return;
		}

		// Let loader load the other modules (it activates on this).
		// Emit synchronously because threading doesn't matter at this point in
		// initialization and we have to wait for it to complete.
		emit_event(Event("core:load_modules"), true);

		if(is_shutdown_requested())
			return;

		// Now that everyone is listening, we can fire the start event;
		// not for --compile-only, which leaves here ([COMPILE_ONLY])
		if(!g_server_config.get<bool>("compile_only"))
			emit_event(Event("core:start"));
	}

	// interface::Server version; doesn't directly unload
	void unload_module(const ss_ &module_name)
	{
		log_v(MODULE, "unload_module(%s)", cs(module_name));
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_modules.find(module_name);
		if(it == m_modules.end()){
			log_w(MODULE, "unload_module(%s): Not loaded", cs(module_name));
			return;
		}
		m_unloads_requested.insert(module_name);
	}

	void reload_module(const interface::ModuleInfo &info)
	{
		log_i(MODULE, "reload_module(%s)", cs(info.name));
		interface::MutexScope ms(m_modules_mutex);
		for(interface::ModuleInfo &info0 : m_reloads_requested){
			if(info0.name == info.name){
				info0 = info; // Update existing request
				return;
			}
		}
		m_reloads_requested.push_back(info);
	}

	void reload_module(const ss_ &module_name)
	{
		interface::ModuleInfo info;
		{
			interface::MutexScope ms(m_modules_mutex);
			auto it = m_module_info.find(module_name);
			if(it == m_module_info.end()){
				log_w(MODULE, "reload_module: Module info not found: %s",
						cs(module_name));
				return;
			}
			info = it->second;
		}
		reload_module(info);
	}

	// Direct version; internal and unsafe
	// Call with no mutexes locked.
	void unload_module_u(const ss_ &module_name)
	{
		log_i(MODULE, "unload_module_u(): module_name=%s", cs(module_name));
		sp_<ModuleContainer> mc;
		{
			interface::MutexScope ms(m_modules_mutex);
			// Get and lock module
			auto it = m_modules.find(module_name);
			if(it == m_modules.end()){
				log_w(MODULE, "unload_module_u(): Module not found: %s",
						cs(module_name));
				return;
			}
			mc = it->second;
			{
				interface::MutexScope mc_ms(mc->mutex);
				// Delete subscriptions
				log_t(MODULE, "unload_module_u[%s]: Deleting subscriptions",
						cs(module_name));
				{
					for(Event::Type type = 0; type < m_event_subs.size(); type++){
						if(!m_event_subs[type])
							continue;
						const SubList &sublist = *m_event_subs[type];
						auto new_sublist = std::make_shared<SubList>();
						for(const wp_<ModuleContainer> &mc1 : sublist){
							if(sp_<ModuleContainer>(mc1.lock()).get() !=
									mc.get())
								new_sublist->push_back(mc1);
							else
								log_v(MODULE,
										"Removing %s subscription to event %zu",
										cs(module_name), type);
						}
						m_event_subs[type] = new_sublist;
					}
				}
				// Remove server-wide reference to module container
				m_modules.erase(module_name);
			}
		}

		// Destruct module
		log_t(MODULE, "unload_module_u[%s]: Deleting module", cs(module_name));
		mc->thread_request_stop();
		mc->thread_join();

		{
			interface::MutexScope ms(m_modules_mutex);
			// So, hopefully this is the last reference because we're going to
			// unload the shared executable...
			if(!mc.unique())
				log_w(MODULE, "unload_module_u[%s]: This is not the last container"
						" reference; unloading shared executable is probably unsafe",
						cs(module_name));
			// Drop reference to container
			log_t(MODULE, "unload_module_u[%s]: Dropping container",
					cs(module_name));
			mc.reset();
			// Unload shared executable
			log_t(MODULE, "unload_module_u[%s]: Unloading shared executable",
					cs(module_name));
			m_compiler->unload(module_name);

			emit_event(Event("core:module_unloaded",
					new interface::ModuleUnloadedEvent(module_name)));
		}
	}

	void set_module_count(size_t count)
	{
		// The loader's list plus what is loaded already (builtin/loader)
		m_module_count = m_module_load_order.size() + count;
	}

	bool compile_modules(const sv_<interface::ModuleInfo> &infos,
			ss_ *failed_module)
	{
#ifdef BUILDAT_STATIC_MODULES
		return true;
#endif
		sv_<std::pair<ss_, BuildJob>> todo;
		{
			interface::MutexScope ms(m_modules_mutex);
			sv_<ss_> include_dirs = m_compiler->include_directories;
			include_dirs.push_back(m_modules_path);
			for(const interface::ModuleInfo &info : infos){
				if(info.meta.disable_cpp || m_modules.count(info.name))
					continue;
				BuildJob job = plan_build_u(info, list_includes(
						info.path+"/"+info.name+".cpp", include_dirs));
				if(!job.skip_compile)
					todo.emplace_back(info.name, job);
			}
		}
		// One is compiled by load_module() as it always was
		if(todo.size() < 2)
			return true;
		// The longest first, so it is not the one left running alone at the
		// end. simplified: the source file's size stands for the compile's
		// time; the last compile's time per module if it misjudges
		auto size_of = [](const ss_ &path){
			std::ifstream f(path, std::ios::binary | std::ios::ate);
			return f.good() ? (int64_t)f.tellg() : (int64_t)0;
		};
		sm_<ss_, int64_t> sizes;
		for(auto &item : todo)
			sizes[item.first] = size_of(item.second.init_cpp_path);
		std::stable_sort(todo.begin(), todo.end(),
				[&](const std::pair<ss_, BuildJob> &a,
						const std::pair<ss_, BuildJob> &b){
					return sizes[a.first] > sizes[b.first];
				});

		// One compiler's peak: builtin/luanti's, the largest, measured
		// 860 MB with /usr/bin/time (2026-10-04), rounded up.
		// simplified: one fixed peak for every module; per-module peaks if
		// this holds back too much
		const int64_t peak = 1024LL * 1024 * 1024;
		// What is left free besides; BUILDAT_COMPILE_RESERVE_MB raises it
		// (the check of the one-at-a-time path does)
		int64_t reserve = 1024LL * 1024 * 1024;
		if(const char *v = getenv("BUILDAT_COMPILE_RESERVE_MB"))
			reserve = atoll(v) * 1024 * 1024;
		const size_t cores = usable_cores();
		const size_t max_running = std::max((size_t)1, cores / 2);
		log_i(MODULE, "Compiling %zu modules, at most %zu at once (%zu cores)",
				todo.size(), max_running, cores);

		std::mutex mutex;
		std::condition_variable cv;
		std::set<ss_> running;
		size_t most_running = 0;
		size_t done = 0;
		ss_ failed;
		ss_ held_by;  // why no more ran, the last time it held
		sv_<std::thread> threads;

		// [START_STRIPES_ETA] Each module's last good compile time on this
		// machine, "<name> <seconds>" a line; an unknown one's estimate the
		// known ones' mean, or 30 s. The share of the estimates done is the
		// STATUS line's percentage, said once a second while compiling.
		// simplified: kept by the module's name, not its hash; a module
		// much changed is mis-estimated once
		const ss_ times_path = g_server_config.get<ss_>("rccpp_build_path")+
				"/compile_times.txt";
		sm_<ss_, double> times;
		{
			std::ifstream f(times_path);
			ss_ name;
			double secs;
			while(f>>name>>secs)
				if(secs > 0)
					times[name] = secs;
		}
		double mean = 0;
		for(auto &pair : times)
			mean += pair.second / times.size();
		sm_<ss_, double> estimate;
		double total = 0;
		for(auto &item : todo){
			auto it = times.find(item.first);
			estimate[item.first] = it != times.end() ? it->second :
					mean > 0 ? mean : 30;
			total += estimate[item.first];
		}
		sm_<ss_, int64_t> started_us;
		double done_estimates = 0;
		int said_percent = 0;
		int64_t said_us = 0;
		// Under the mutex
		auto status = [&](){
			const int64_t now = interface::os::time_us();
			double part = done_estimates;
			for(auto &pair : started_us)
				part += std::min((now - pair.second) / 1e6,
						0.95 * estimate[pair.first]);
			said_percent = std::max(said_percent,
					(int)std::min(100.0, 100 * part / total));
			said_us = now;
			ss_ names;
			for(const ss_ &name : running)
				names += (names.empty() ? "" : ", ") + name;
			log_i(MODULE, "STATUS Compiling %s (%zu of %zu, %d%%)",
					cs(names), done + running.size(), todo.size(), said_percent);
		};
		auto wait_a_second = [&](std::unique_lock<std::mutex> &lock){
			cv.wait_for(lock, std::chrono::seconds(1));
			if(!running.empty() &&
					interface::os::time_us() - said_us >= 1000000)
				status();
		};

		// compile() reads the include directories; nothing changes them
		// until every thread is joined
		m_compiler->include_directories.push_back(m_modules_path);
		// [COMPILE_SLOTS] Past the first, each compile a shared slot's
		open_compile_slots();
		for(auto &item : todo){
			std::unique_lock<std::mutex> lock(mutex);
			// The running ones counted again on purpose: one just started
			// has not reached its peak
			int slot = -1;
			for(;;){
				if(!failed.empty() || running.empty())
					break;
				if(running.size() >= max_running){
					held_by = "the cores";
				} else {
					const int64_t avail = available_memory();
					if(avail >= 0 && avail <
							(int64_t)(running.size() + 1) * peak + reserve){
						held_by = "memory ("+itos(avail / 1024 / 1024)+
								" MiB available)";
					} else if((slot = take_compile_slot()) >= 0){
						break;
					} else {
						held_by = g_compile_slots.empty() ? ss_("no compile "
								"slots: one at a time") :
								ss_("the slots other servers' compiles share");
					}
				}
				wait_a_second(lock);
			}
			if(!failed.empty())
				break;
			running.insert(item.first);
			most_running = std::max(most_running, running.size());
			started_us[item.first] = interface::os::time_us();
			status();
			threads.emplace_back([&, item, slot](){
				const BuildJob &job = item.second;
				interface::fs::create_directories(
						interface::fs::strip_file_name(job.build_dst));
				bool ok = m_compiler->compile(job.init_cpp_path, job.build_dst,
						job.extra_cxxflags, job.extra_ldflags);
				give_compile_slot(slot);
				if(ok){
					std::ofstream f(job.hashfile_path);
					f<<job.hash_hex;
				}
				std::unique_lock<std::mutex> lock(mutex);
				running.erase(item.first);
				done++;
				const double took = (interface::os::time_us() -
						started_us[item.first]) / 1e6;
				started_us.erase(item.first);
				done_estimates += estimate[item.first];
				if(ok)
					times[item.first] = took;
				if(!ok && failed.empty())
					failed = item.first;
				cv.notify_all();
			});
		}
		{
			std::unique_lock<std::mutex> lock(mutex);
			while(!running.empty())
				wait_a_second(lock);
			if(failed.empty())
				log_i(MODULE, "STATUS Compiled %zu modules (%zu of %zu, 100%%)",
						done, done, todo.size());
		}
		for(std::thread &t : threads)
			t.join();
		m_compiler->include_directories.pop_back();
		{
			std::ofstream f(times_path);
			for(auto &pair : times)
				f<<pair.first<<" "<<pair.second<<"\n";
		}

		log_i(MODULE, "Compiled %zu of %zu modules, at most %zu at once%s",
				done, todo.size(), most_running, held_by.empty() ? "" :
				cs(", no more for "+held_by));
		if(!failed.empty()){
			log_w(MODULE, "Failed to build module %s", cs(failed));
			if(failed_module)
				*failed_module = failed;
			return false;
		}
		return true;
	}

	ss_ get_modules_path()
	{
		return m_modules_path;
	}

	ss_ get_builtin_modules_path()
	{
		return g_server_config.get<ss_>("share_path")+"/builtin";
	}

	ss_ get_module_wasm_path(const ss_ &module_name)
	{
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_module_wasm.find(module_name);
		return it == m_module_wasm.end() ? ss_() : it->second;
	}

	ss_ get_module_path(const ss_ &module_name)
	{
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_modules.find(module_name);
		if(it == m_modules.end())
			throw ModuleNotFoundException(ss_()+"Module not found: "+module_name);
		ModuleContainer *mc = it->second.get();
		return mc->info.path;
	}

	interface::Module* get_module(const ss_ &module_name)
	{
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_modules.find(module_name);
		if(it == m_modules.end())
			return NULL;
		return it->second->module.get();
	}

	interface::Module* check_module(const ss_ &module_name)
	{
		interface::Module *m = get_module(module_name);
		if(m) return m;
		throw ModuleNotFoundException(ss_()+"Module not found: "+module_name);
	}

	bool has_module(const ss_ &module_name)
	{
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_modules.find(module_name);
		return (it != m_modules.end());
	}

	sv_<ss_> get_loaded_modules()
	{
		interface::MutexScope ms(m_modules_mutex);
		sv_<ss_> result;
		for(auto &pair : m_modules){
			result.push_back(pair.first);
		}
		return result;
	}

	// Call with m_modules_mutex locked
	bool is_dependency_u(ModuleContainer *mc_should_be_dependent,
			ModuleContainer *mc_should_be_dependency)
	{
		const ss_ &search_dep_name = mc_should_be_dependency->info.name;
		const interface::ModuleInfo &info = mc_should_be_dependent->info;
		// Breadth-first
		for(const interface::ModuleDependency &dep : info.meta.dependencies){
			/*log_t(MODULE, "is_dependency_u(): \"%s\" has dependency \"%s\"; "
					"searching for \"%s\"",
					cs(info.name), cs(dep.module), cs(search_dep_name));*/
			if(dep.module == search_dep_name)
				return true;
		}
		for(const interface::ModuleDependency &dep : info.meta.dependencies){
			auto it = m_modules.find(dep.module);
			if(it == m_modules.end())
				continue;
			ModuleContainer *mc_dependency = it->second.get();
			bool is = is_dependency_u(mc_dependency, mc_should_be_dependency);
			if(is)
				return true;
		}
		/*log_t(MODULE, "is_dependency_u(): \"%s\" does not depend on \"%s\"",
				cs(info.name), cs(search_dep_name));*/
		return false;
	}

	// Throws on invalid access
	// Call with m_modules_mutex locked
	void check_valid_access_u(
			ModuleContainer *target_mc,
			ModuleContainer *caller_mc
			){
		const ss_ &target_name = target_mc->info.name;
		const ss_ &caller_name = caller_mc->info.name;

		// Access is invalid if target is caller
		if(caller_mc == target_mc)
			throw Exception("Cannot access \""+target_name+"\" from \""+
					caller_name+"\": Accessing itself is disallowed");

		// Access is invalid if caller is a direct or indirect dependency of
		// target
		if(is_dependency_u(target_mc, caller_mc))
			throw Exception("Cannot access \""+target_name+"\" from \""+
					caller_name+"\": Target depends on caller - access must "
					"happen the other way around");

		// The thing we are trying to disallow is that if module 1 accesses
		// module 2 at some point, then at no point shall module 2 be allowed to
		// access module 1.

		// Access is valid
	}

	bool access_module(const ss_ &module_name,
			std::function<void(interface::Module*)> cb)
	{
		ModuleContainer *caller_mc =
				(ModuleContainer*)m_thread_local_mc_key.get();

		try {
			sp_<ModuleContainer> mc;
			{
				interface::MutexScope ms(m_modules_mutex);

				auto it = m_modules.find(module_name);
				if(it == m_modules.end())
					throw Exception("access_module(): Module \""+module_name+
							"\" not found");
				mc = it->second;
				if(!mc)
					throw Exception("access_module(): Module \""+module_name+
							"\" container is null");

				if(caller_mc){
					log_t(MODULE, "access_module[%s]: Called by \"%s\"",
							cs(mc->info.name), cs(caller_mc->info.name));

					// Throws exception if not valid.
					// If accessing a module from a nested access_module(), this
					// function is called from the thread of the nested module,
					// effectively taking into account the lock hierarchy.
					check_valid_access_u(mc.get(), caller_mc);
				} else {
					log_t(MODULE, "access_module[%s]: Called by something else"
							" than a module", cs(mc->info.name));
				}
			}

			// Execute callback in module thread
			std::exception_ptr eptr;
			mc->execute_direct_cb(cb, eptr, caller_mc);
			if(eptr){
				interface::Thread *current_thread =
						interface::Thread::get_current_thread();

				// If not being called by a thread, there's nowhere we can store the
				// backtrace (and it wouldn't make sense anyway as there is no
				// callback chain)
				if(current_thread == nullptr){
					std::rethrow_exception(eptr);
				}

				// NOTE: In each Thread there is a pointer to the Thread that is
				//       currently doing a direct call, or nullptr if a direct call
				//       is not being executed.
				// NOTE: The parent callers in the chain cannot be deleted while
				//       this function is executing so we can freely access them.

				// Find out the original thread that initiated this direct_cb chain
				interface::Thread *orig_thread = current_thread;
				while(orig_thread->get_caller_thread()){
					orig_thread = orig_thread->get_caller_thread();
				}

				// Insert backtrace to original chain initiator's backtrace list
				interface::debug::ThreadBacktrace bt_step;
				bt_step.thread_name = current_thread->get_name();
				interface::debug::get_current_backtrace(bt_step.bt);
				orig_thread->ref_backtraces().push_back(bt_step);

				// NOTE: When an exception comes uncatched from module->event(), the
				//       direct_cb backtrace stack can be logged after the backtrace
				//       gotten from the __cxa_throw catch. The backtrace catched by
				//       the __cxa_throw wrapper is from the furthermost thread in
				//       the direct_cb chain, from which the event was just
				//       propagated downwards (while recording the other backtraces
				//       like specified here).

				// Re-throw the exception so that the chain gets unwinded (while we
				// collect backtraces at each step)
				std::rethrow_exception(eptr);
			}
		} catch(...){
			std::exception_ptr eptr = std::current_exception();
			// If a destructor doesn't catch an exception, the whole program
			// will abort. So, do not pass exception to destructor.
			if(caller_mc && caller_mc->executing_module_destructor){
				try {
					std::rethrow_exception(eptr);
				} catch(std::exception &e){
					log_w(MODULE, "access_module[%s]: Ignoring exception in"
							" [%s] destructor: \"%s\"", cs(module_name),
							cs(caller_mc->info.name), e.what());
				} catch(...){
					log_w(MODULE, "access_module[%s]: Ignoring exception in"
							" [%s] destructor", cs(module_name),
							cs(caller_mc->info.name));
				}
				return true;
			}
			// Pass exception to caller normally
			std::rethrow_exception(eptr);
		}
		return true;
	}

	void sub_event(struct interface::Module *module,
			const Event::Type &type)
	{
		// Lock modules so that the subscribing one isn't removed asynchronously
		interface::MutexScope ms(m_modules_mutex);
		// Make sure module is a known instance
		sp_<ModuleContainer> mc0;
		ss_ module_name = "(unknown)";
		for(auto &pair : m_modules){
			sp_<ModuleContainer> &mc = pair.second;
			if(mc->module.get() == module){
				mc0 = mc;
				module_name = pair.first;
				break;
			}
		}
		if(mc0 == nullptr){
			log_w(MODULE, "sub_event(): Not a known module");
			return;
		}
		if(m_event_subs.size() <= type + 1)
			m_event_subs.resize(type + 1);
		auto sublist = std::make_shared<SubList>();
		if(m_event_subs[type])
			*sublist = *m_event_subs[type];
		bool found = false;
		for(wp_<ModuleContainer> &item : *sublist){
			if(item.lock() == mc0){
				found = true;
				break;
			}
		}
		if(found){
			log_w(MODULE, "sub_event(): Already on list: %s", cs(module_name));
			return;
		}
		auto *evreg = interface::getGlobalEventRegistry();
		log_d(MODULE, "sub_event(): %s subscribed to %s (%zu)",
				cs(module_name), cs(evreg->name(type)), type);
		sublist->push_back(wp_<ModuleContainer>(mc0));
		m_event_subs[type] = sublist;
	}

	// Do not use synchronous=true unless specifically needed in a special case.
	void emit_event(Event event, bool synchronous)
	{
		if(log_get_max_level() >= CORE_TRACE){
			auto *evreg = interface::getGlobalEventRegistry();
			log_t(MODULE, "emit_event(): %s (%zu)",
					cs(evreg->name(event.type)), event.type);
		}

		sp_<const SubList> subs;
		{
			interface::MutexScope ms(m_modules_mutex);
			if(event.type < m_event_subs.size())
				subs = m_event_subs[event.type];
		}
		if(!subs || subs->empty()){
			log_t(MODULE, "emit_event(): %zu: No subs", event.type);
			return;
		}
		if(log_get_max_level() >= CORE_TRACE){
			auto *evreg = interface::getGlobalEventRegistry();
			log_t(MODULE, "emit_event(): %s (%zu): Pushing to %zu modules",
					cs(evreg->name(event.type)), event.type, subs->size());
		}
		for(const wp_<ModuleContainer> &mc_weak : *subs){
			sp_<ModuleContainer> mc(mc_weak.lock());
			if(mc){
				if(synchronous)
					mc->emit_event_sync(event);
				else
					mc->push_event(event);
			} else {
				auto *evreg = interface::getGlobalEventRegistry();
				log_t(MODULE, "emit_event(): %s: (%zu): Subscriber weak pointer"
						" is null", cs(evreg->name(event.type)), event.type);
			}
		}
	}

	void emit_event(Event event)
	{
		emit_event(event, false);
	}

	void emit_event_synchronously(Event event)
	{
		emit_event(event, true);
	}

	void handle_events()
	{
		// Get modified modules and push events to queue
		{
			interface::MutexScope ms(m_modules_mutex);
			set_<ss_> modified_modules;
			modified_modules.swap(m_modified_modules);
			for(const ss_ &name : modified_modules){
				auto it = m_module_info.find(name);
				if(it == m_module_info.end())
					throw Exception("Info of modified module not available");
				interface::ModuleInfo &info = it->second;
				emit_event(Event("core:module_modified",
						new interface::ModuleModifiedEvent(
						info.name, info.path)));
			}
		}

		// Handle module unloads and reloads as requested
		handle_unloads_and_reloads();
	}

	void handle_unloads_and_reloads()
	{
		// Grab unload and reload requests into unload and load queues
		sv_<ss_> unloads_requested;
		sv_<interface::ModuleInfo> loads_requested;
		{
			interface::MutexScope ms(m_modules_mutex);

			for(const ss_ &module_name : m_unloads_requested){
				unloads_requested.push_back(module_name);
			}
			m_unloads_requested.clear();

			for(const interface::ModuleInfo &info : m_reloads_requested){
				unloads_requested.push_back(info.name);
				loads_requested.push_back(info);
			}
			m_reloads_requested.clear();
		}
		// Send core:unload events synchronously to modules
		for(const ss_ &module_name : unloads_requested){
			log_t(MODULE, "reload[%s]: Synchronous core:unload", cs(module_name));
			access_module(module_name, [&](interface::Module *module){
				module->event(Event::t("core:unload"), nullptr);
			});
		}
		// Unload modules
		for(const ss_ &module_name : unloads_requested){
			log_i(MODULE, "Unloading %s", cs(module_name));
			unload_module_u(module_name);
		}
		// Load modules
		for(const interface::ModuleInfo &info : loads_requested){
			log_i(MODULE, "Loading %s (reload requested)", cs(info.name));
			// Load module
			load_module(info);
			// Send core:continue synchronously to module
			access_module(info.name, [&](interface::Module *module){
				module->event(Event::t("core:continue"), nullptr);
			});
		}
	}

	void tmp_store_data(const ss_ &name, const ss_ &data)
	{
		interface::MutexScope ms(m_tmp_data_mutex);
		m_tmp_data[name] = data;
	}

	ss_ tmp_restore_data(const ss_ &name)
	{
		interface::MutexScope ms(m_tmp_data_mutex);
		ss_ data = m_tmp_data[name];
		m_tmp_data.erase(name);
		return data;
	}

	// Add resource file path (to make a mirror of the client)
	void add_file_path(const ss_ &name, const ss_ &path)
	{
		log_d(MODULE, "add_file_path(): %s -> %s", cs(name), cs(path));
		interface::MutexScope ms(m_file_paths_mutex);
		m_file_paths[name] = path;
	}

	// Returns "" if not found
	ss_ get_file_path(const ss_ &name)
	{
		interface::MutexScope ms(m_file_paths_mutex);
		auto it = m_file_paths.find(name);
		if(it == m_file_paths.end())
			return "";
		return it->second;
	}

	ss_ get_app_id()
	{
		return server::app_of(m_modules_path);
	}

	const interface::ServerConfig& get_config()
	{
		return g_server_config;
	}

	void access_thread_pool(std::function<void(
			interface::thread_pool::ThreadPool*pool)> cb)
	{
		interface::MutexScope ms(m_thread_pool_mutex);
		cb(m_thread_pool.get());
	}
};

void FileWatchThread::run(interface::Thread *thread)
{
	interface::SelectHandler handler;

	while(!thread->stop_requested()){
		sv_<int> sockets;
		{
			interface::MutexScope ms(m_server->m_modules_mutex);
			for(auto &pair : m_server->m_module_file_watches){
				sv_<int> fds = pair.second->get_fds();
				sockets.insert(sockets.begin(), fds.begin(), fds.end());
			}
		}

		sv_<int> active_sockets;
		bool ok = handler.check(500000, sockets, active_sockets);
		(void)ok; // Unused

		if(active_sockets.empty())
			continue;

		{
			interface::MutexScope ms(m_server->m_modules_mutex);
			for(auto &pair : m_server->m_module_file_watches){
				for(int fd : active_sockets){
					pair.second->report_fd(fd);
				}
			}
		}
	}
}

void FileWatchThread::on_crash(interface::Thread *thread)
{
	m_server->shutdown(1, "FileWatchThread crashed");
}

State* createState()
{
	return new CState();
}
}
// vim: set noet ts=4 sw=4:
