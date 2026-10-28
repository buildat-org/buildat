// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	namespace thread_pool
	{
		struct Task
		{
			virtual ~Task(){}
			// Called repeatedly from main thread until returns true
			virtual bool pre() = 0;
			// Called repeatedly from worker thread until returns true
			virtual bool thread() = 0;
			// The same with a deadline, for a pool that runs it on the
			// frame's own thread (the web client's): a task that can stop
			// between slices stops at until_us ([WEB_MAIN_THREAD])
			virtual bool thread_until(int64_t){ return thread(); }
			// Called repeatedly from main thread until returns true
			virtual bool post() = 0;
			// Asked once post() is done: true sends the task round once
			// more, its pre() from the next frame on ([WEB_MESH_REST]: a
			// chunk's volume read on a worker, then its textures on this
			// thread and its mesh on a worker)
			virtual bool again(){ return false; }
			// Ahead of the waiting ones rather than behind them: a chunk's
			// collision behind four meshes run a slice a frame (the web)
			// was seconds stale under the player
			// ([AGGREGATE_CHROME_NO_PHYSICS])
			virtual bool urgent() const { return false; }
		};

		struct ThreadPool
		{
			virtual ~ThreadPool(){}
			virtual void add_task(up_<Task> task) = 0;
			virtual void start(size_t num_threads) = 0;
			// 0: the tasks' threaded part runs on the calling thread
			virtual size_t get_num_threads() = 0;
			virtual void request_stop() = 0;
			virtual void join() = 0;
			virtual void run_post() = 0;
			// Tasks added and not through post() yet, the ones a worker
			// holds aside: for a caller that should wait rather than add
			// more than the pool keeps up with ([WEB_MAIN_THREAD])
			virtual size_t get_backlog() = 0;
			// Microseconds since the last call: the threaded part run
			// inline (no workers: the web client) and post()
			// ([WEB_MAIN_THREAD]'s frame split)
			virtual void take_times(int64_t *inline_us, int64_t *post_us) = 0;
		};

		ThreadPool* createThreadPool();
	}
}
// vim: set noet ts=4 sw=4:
