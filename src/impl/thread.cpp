// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/thread.h"
#include "interface/mutex.h"
#include "interface/debug.h"
#include "interface/module.h"
#include "core/log.h"
#include <c55/os.h>
#ifdef _WIN32
	#include "ports/windows_compat.h"
#else
	#include <pthread.h>
	#include <signal.h>
#endif
#define MODULE "thread"

namespace interface {

ThreadLocalKey g_current_thread_key;

Thread* Thread::get_current_thread()
{
	return (Thread*)g_current_thread_key.get();
}

int g_thread_name_counter = 0;
interface::Mutex g_thread_name_counter_mutex;

struct CThread: public Thread
{
	bool m_running = false;
	bool m_stop_requested = false;
	ss_ m_name;
	interface::Mutex m_mutex; // Protects the former variables
	ThreadedThing *m_thing;
	pthread_t m_thread;
	bool m_thread_exists = false;

	// Debug data
	std::list<debug::ThreadBacktrace> m_backtraces;
	Thread *m_caller_thread = nullptr;

	CThread(ThreadedThing *thing)
	{
		m_thing = thing;
	}

	~CThread()
	{
		// You must call request_stop() and join() explicitly; it seems that
		// Helgrind and DRD are unhappy if they are called from here.
		if(m_thread_exists){
			interface::MutexScope ms(m_mutex);
			log_e(MODULE, "Thread %p (%s) destructed but not stopped",
					this, cs(m_name));
		}
		delete m_thing;
	}

	static void* run_thread(void *arg)
	{
		CThread *thread = (CThread*)arg;

		// Set pointer in thread-local storage
		g_current_thread_key.set(thread);

		// Get name from parameter
		ss_ thread_name;
		{
			interface::MutexScope ms(thread->m_mutex);
			thread_name = thread->m_name;
		}
		log_d(MODULE, "Thread started: %p (%s)", thread, cs(thread_name));

#if !defined(_WIN32) && !defined(__EMSCRIPTEN__)
		// Set thread name
		if(!thread_name.empty()){
			ss_ limited_name = thread_name.size() <= 15 ?
						thread_name : thread_name.substr(0, 15);
			if(pthread_setname_np(thread->m_thread, limited_name.c_str())){
				log_w(MODULE, "Failed to set thread name (thread %p, name \"%s\")",
						thread, limited_name.c_str());
			}
		}

		// Disable all signals
		sigset_t sigset;
		sigemptyset(&sigset);
		(void)pthread_sigmask(SIG_SETMASK, &sigset, NULL);
#endif

		try {
			try {
				if(thread->m_thing)
					thread->m_thing->run(thread);
			} catch(ModuleAskedToStop &e){
				// A module this thread needs is going away, so this thread has
				// no work left either. Not a crash: exit quietly.
				// simplified: this cannot tell shutdown apart from a module
				// being reloaded from under an unrelated thread, which ends
				// that thread silently. Distinguishing them needs the module
				// container to know its module's child threads and stop them
				// with it; do that if reload-time thread loss ever bites.
				log_v(MODULE, "Thread %p (%s) stopping: %s",
						arg, cs(thread_name), e.what());
			}
		} catch(std::exception &e){
			log_w(MODULE, "ThreadThing of thread %p (%s) crashed: %s",
					arg, cs(thread_name), e.what());
			if(!thread->m_backtraces.empty()){
				interface::debug::log_backtrace_chain(
						thread->m_backtraces, e.what());
			} else {
				interface::debug::StoredBacktrace bt;
				interface::debug::get_exception_backtrace(bt);
				interface::debug::log_backtrace(bt,
						"Backtrace in ThreadThing("+thread_name+") for "+
						bt.exception_name+"(\""+e.what()+"\")");
			}
			// Call crash handler
			try {
				if(thread->m_thing)
					thread->m_thing->on_crash(thread);
			} catch(std::exception &e){
				log_w(MODULE, "ThreadThing::on_crash() of thread %p (%s)"
						" crashed: %s", arg, cs(thread_name), e.what());
				if(!thread->m_backtraces.empty()){
					interface::debug::log_backtrace_chain(
							thread->m_backtraces, e.what());
				} else {
					interface::debug::StoredBacktrace bt;
					interface::debug::get_exception_backtrace(bt);
					interface::debug::log_backtrace(bt,
							"Backtrace in ThreadThing("+thread_name+") for "+
							bt.exception_name+"(\""+e.what()+"\")");
				}
			}
		}

		log_d(MODULE, "Thread %p (%s) exit", arg, cs(thread_name));
		{
			interface::MutexScope ms(thread->m_mutex);
			thread->m_running = false;
		}
		pthread_exit(NULL);
	}

	// Interface

	void set_name(const ss_ &name)
	{
		{
			interface::MutexScope ms(m_mutex);
			if(m_running)
				throw Exception("Cannot set name of running thread");
			m_name = name;
		}
	}

	void start()
	{
		if(m_name.empty()){
			// Generate a name
			interface::MutexScope ms(g_thread_name_counter_mutex);
			m_name = "unknown "+itos(g_thread_name_counter++);
		}
		{
			interface::MutexScope ms(m_mutex);
			if(m_running){
				log_w(MODULE, "CThread::start(): Already running");
				return;
			}
			m_stop_requested = false;
			if(pthread_create(&m_thread, NULL, run_thread, (void*)this)){
				throw Exception("pthread_create() failed");
			}
			m_running = true;
		}
		m_thread_exists = true;
	}

	bool is_running()
	{
		interface::MutexScope ms(m_mutex);
		return m_running;
	}

	void request_stop()
	{
		interface::MutexScope ms(m_mutex);
		m_stop_requested = true;
	}

	bool stop_requested()
	{
		interface::MutexScope ms(m_mutex);
		return m_stop_requested;
	}

	void join()
	{
		{
			interface::MutexScope ms(m_mutex);
			if(!m_stop_requested){
				log_w(MODULE, "Joining a thread that was not requested "
						"to stop");
			}
		}
		if(m_thread_exists){
			pthread_join(m_thread, NULL);
			m_thread_exists = false;
		}
	}

	// Debugging interface (not thread-safe; access only from thread itself)

	ss_ get_name()
	{
		interface::MutexScope ms(m_mutex);
		return m_name;
	}

	std::list<debug::ThreadBacktrace>& ref_backtraces()
	{
		return m_backtraces;
	}

	void set_caller_thread(Thread *thread)
	{
		m_caller_thread = thread;
	}

	Thread* get_caller_thread()
	{
		return m_caller_thread;
	}
};

Thread* createThread(ThreadedThing *thing)
{
	return new CThread(thing);
}

// ThreadLocalKey

struct ThreadLocalKeyPrivate
{
	pthread_key_t key;
};

ThreadLocalKey::ThreadLocalKey():
	m_private(new ThreadLocalKeyPrivate)
{
	pthread_key_create(&m_private->key, NULL);
}

ThreadLocalKey::~ThreadLocalKey()
{
	pthread_key_delete(m_private->key);
}

void ThreadLocalKey::set(void *p)
{
	pthread_setspecific(m_private->key, p);
}

void* ThreadLocalKey::get()
{
	return pthread_getspecific(m_private->key);
}

}
// vim: set noet ts=4 sw=4:
