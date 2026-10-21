// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/thread_pool.h"
#include "interface/mutex.h"
#include "interface/semaphore.h"
#include "interface/debug.h"
#include "core/log.h"
#include <c55/os.h>
#include <deque>
#ifdef _WIN32
	#include "ports/windows_compat.h"
#else
	#include <pthread.h>
	#include <semaphore.h>
	#include <signal.h>
#endif
#define MODULE "thread_pool"

namespace interface {
namespace thread_pool {

struct CThreadPool: public ThreadPool
{
	bool m_running = false;
	std::deque<up_<Task>> m_input_queue; // Push back, pop front
	std::deque<up_<Task>> m_output_queue; // Push back, pop front
	// Tasks whose pre() is not done: the main thread's, and never touched
	// by a worker, so no mutex ([CLIENT_FRAME])
	std::deque<up_<Task>> m_pre_queue;
	// What one frame gives them. Three milliseconds of a frame that wants
	// to be sixteen, which is what a chunk's textures are worth against
	// the second one of them used to take.
	static const int64_t PRE_BUDGET_US = 3000;
	interface::Mutex m_mutex; // Protects each of the former variables
	interface::Semaphore m_tasks_sem; // Counts input tasks

	//std::deque<up_<Task>> m_pre_tasks; // Push back, pop front

	~CThreadPool()
	{
		request_stop();
		join();
	}

	struct Thread {
		bool stop_requested = true;
		bool running = false;
		interface::Mutex mutex; // Protects each of the former variables
		CThreadPool *pool = nullptr;
		pthread_t thread;
	};
	sv_<Thread> m_threads;

	static void* run_thread(void *arg)
	{
		Thread *thread = (Thread*)arg;
		log_d(MODULE, "Worker thread %p start", arg);
#if !defined(_WIN32) && !defined(__EMSCRIPTEN__)
		// Set name
		if(pthread_setname_np(thread->thread, "buildat:worker")){
			log_w(MODULE, "Failed to set worker thread %p name", thread);
		}
		// Disable all signals
		sigset_t sigset;
		sigemptyset(&sigset);
		(void)pthread_sigmask(SIG_SETMASK, &sigset, NULL);
#endif
		// Go on
		for(;;){
			// Wait for a task
			thread->pool->m_tasks_sem.wait();
			up_<Task> current;
			{ // Grab the task from pool's input queue
				interface::MutexScope ms_pool(thread->pool->m_mutex);
				if(thread->pool->m_input_queue.empty()){
					// Can happen in special cases, eg. when stopping thread
					interface::MutexScope ms(thread->mutex);
					// So, if stopping thread, stop thread
					if(thread->stop_requested)
						break;
					continue;
				}
				current = std::move(thread->pool->m_input_queue.front());
				thread->pool->m_input_queue.pop_front();
			}
			// Run the task's threaded part
			try {
				while(!current->thread());
			} catch(std::exception &e){
				log_w(MODULE, "Worker task failed: %s", e.what());
				interface::debug::log_exception_backtrace();
			}
			// Push the task to pool's output queue
			{
				interface::MutexScope ms_pool(thread->pool->m_mutex);
				thread->pool->m_output_queue.push_back(std::move(current));
			}
		}
		log_d(MODULE, "Worker thread %p exit", arg);
		// The scope ends before the thread does: winpthreads' pthread_exit()
		// runs no C++ destructors, so a MutexScope still open at it left the
		// mutex locked for good, and join() waited on it forever -- the
		// Windows server's hang at exit (2026-10-03)
		{
			interface::MutexScope ms(thread->mutex);
			thread->running = false;
		}
		return NULL;
	}

	// Interface

	// **A task's pre() is not spun on** ([CLIENT_FRAME], 2026-09-26;
	// the TODO that stood here said the same). It runs on the calling
	// thread on purpose -- a chunk's textures have to be in the atlas
	// before a worker meshes it -- but a chunk seen for the first time
	// spent 858 to 1265 ms of its frame in there. It gets one slice now,
	// and a task that is not ready waits in a queue of its own for the
	// next frame's slice rather than holding this one.
	void add_task(up_<Task> task)
	{
		if(!task->pre()){
			m_pre_queue.push_back(std::move(task));
			return;
		}
		interface::MutexScope ms(m_mutex);
		m_input_queue.push_back(std::move(task));
		m_tasks_sem.post();
	}

	// The slice the waiting ones get, once a frame from run_post()
	void run_pre()
	{
		if(m_pre_queue.empty())
			return;
		const int64_t t0 = get_timeofday_us();
		while(!m_pre_queue.empty()){
			up_<Task> &front = m_pre_queue.front();
			bool ready = false;
			// **It used to raise inside the call that asked for the task**,
			// where the caller's own error handling caught it -- an
			// undefined voxel says which one it was. Out here it would
			// leave the frame instead, so the task is dropped and said
			// rather than taking the client with it.
			try {
				ready = front->pre();
			} catch(std::exception &e){
				log_w(MODULE, "task pre() failed, dropping it: %s", e.what());
				m_pre_queue.pop_front();
				continue;
			}
			if(!ready){
				// Not ready and the slice is spent: it keeps its place
				if(get_timeofday_us() - t0 >= PRE_BUDGET_US)
					return;
				continue;
			}
			{
				interface::MutexScope ms(m_mutex);
				m_input_queue.push_back(std::move(front));
				m_tasks_sem.post();
			}
			m_pre_queue.pop_front();
			if(get_timeofday_us() - t0 >= PRE_BUDGET_US)
				return;
		}
	}

	void start(size_t num_threads)
	{
		interface::MutexScope ms(m_mutex);
		if(!m_threads.empty()){
			log_w(MODULE, "CThreadPool::start(): Already running");
			return;
		}
		m_threads.resize(num_threads);
		for(size_t i = 0; i < num_threads; i++){
			Thread &thread = m_threads[i];
			thread.pool = this;
			thread.stop_requested = false;
			if(pthread_create(&thread.thread, NULL, run_thread, (void*)&thread)){
				throw Exception("pthread_create() failed");
			}
			thread.running = true;
		}
	}

	void request_stop()
	{
		interface::MutexScope ms(m_mutex);
		// Remove everything from task queue
		m_input_queue.clear();
		// Ask threads to stop
		for(Thread &thread : m_threads){
			interface::MutexScope ms(thread.mutex);
			thread.stop_requested = true;
		}
		// Poke the threads awake
		for(Thread &thread : m_threads){
			(void)thread;
			m_tasks_sem.post();
		}
	}

	void join()
	{
		for(Thread &thread : m_threads){
			{
				interface::MutexScope ms(thread.mutex);
				if(!thread.stop_requested){
					log_w(MODULE, "Joining a thread that was not requested "
							"to stop");
				}
			}
			pthread_join(thread.thread, NULL);
		}
		m_threads.clear();
	}

	// With no workers (the web client, which has no threads: [WEB_CLIENT])
	// the threaded part runs here, on the calling thread, a slice a frame:
	// a thread() call at a time, and a task not done when the slice is
	// over goes on next frame ([WEB_MAIN_THREAD]; a chunk's mesh steps in
	// 2 ms, and stops at the budget's end). simplified: a task whose single
	// thread() call is long still takes all of it.
	static const int64_t INLINE_BUDGET_US = 4000;
	size_t get_backlog()
	{
		interface::MutexScope ms(m_mutex);
		return m_pre_queue.size() + m_input_queue.size() +
				m_output_queue.size();
	}
	int64_t m_inline_us = 0, m_post_us = 0;
	void take_times(int64_t *inline_us, int64_t *post_us)
	{
		*inline_us = m_inline_us;
		*post_us = m_post_us;
		m_inline_us = m_post_us = 0;
	}
	void run_inline()
	{
		const int64_t t0 = get_timeofday_us();
		struct Count {
			int64_t t0, &sum;
			~Count(){ sum += get_timeofday_us() - t0; }
		} count{t0, m_inline_us};
		while(get_timeofday_us() - t0 < INLINE_BUDGET_US){
			up_<Task> current;
			{
				interface::MutexScope ms(m_mutex);
				if(m_input_queue.empty())
					return;
				current = std::move(m_input_queue.front());
				m_input_queue.pop_front();
			}
			bool done = true;
			try {
				done = current->thread_until(t0 + INLINE_BUDGET_US);
			} catch(std::exception &e){
				log_w(MODULE, "Inline task failed: %s", e.what());
			}
			interface::MutexScope ms(m_mutex);
			if(done)
				m_output_queue.push_back(std::move(current));
			else
				m_input_queue.push_front(std::move(current));
		}
	}

	void run_post()
	{
		// The ones still getting ready, first: a chunk that cannot be
		// meshed until its textures are in the atlas is what the frame is
		// waiting on, and the output queue below is last frame's work
		run_pre();
		if(m_threads.empty())
			run_inline();

		int64_t t1 = get_timeofday_us();
		struct Count {
			int64_t t0, &sum;
			~Count(){ sum += get_timeofday_us() - t0; }
		} count{t1, m_post_us};
		size_t queue_size = 0;
		size_t post_count = 0;
		bool last_was_partly_procesed = false;
		for(;;){
			// Pop an output task
			up_<Task> task;
			{
				interface::MutexScope ms(m_mutex);
				if(!m_output_queue.empty()){
					queue_size = m_output_queue.size();
					task = std::move(m_output_queue.front());
					m_output_queue.pop_front();
				}
			}
			if(!task)
				break;
			// run post() until too long has passed
			bool overtime = false;
			bool done = false;
			for(;;){
				post_count++;
				done = task->post();
				int64_t t2 = get_timeofday_us();
				// **A backlog does not buy itself a longer frame**
				// ([CLIENT_FRAME], user 2026-09-26: re-meshing is not
				// allowed to make the client feel choppy). This grew by
				// five milliseconds for every output task over four with
				// no ceiling, so eight waiting bought a 22 ms frame on
				// top of whatever else it was doing -- and the client's
				// own profiler found `Buildat|ThreadPool::post` at 18 ms
				// in one frame of a 33 ms average, which is a third of a
				// peak that reads as a hitch. It still grows, so a
				// backlog drains faster than one at a time, but not past
				// a quarter of a frame; what is left waits for the next
				// one, which is what the queue's order is for.
				int64_t max_t = 2000;
				if(queue_size > 4)
					max_t += (queue_size - 4) * 2000;
				if(max_t > 8000)
					max_t = 8000;
				if(t2 - t1 >= max_t){
					overtime = true;
					break;
				}
				// If done, take next output task (after calculating overtime)
				if(done)
					break;
			}
			// If still not done, push task to back to front of queue
			if(!done){
				interface::MutexScope ms(m_mutex);
				m_output_queue.push_front(std::move(task));
				last_was_partly_procesed = true;
			}
			// If overtime, stop processing
			if(overtime){
				break;
			}
		}
#ifdef DEBUG_CORE_TIMING
		int64_t t2 = get_timeofday_us();
		log_v(MODULE, "output post(): %ius (%zu calls; queue size: %zu%s)",
				(int)(t2 - t1), post_count, queue_size,
				(last_was_partly_procesed ? "; last was partly processed" : ""));
#else
		(void)last_was_partly_procesed; // Unused
#endif
	}
};

ThreadPool* createThreadPool()
{
	return new CThreadPool();
}

}
}
// vim: set noet ts=4 sw=4:
