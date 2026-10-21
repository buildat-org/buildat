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
			// Called repeatedly from main thread until returns true
			virtual bool post() = 0;
		};

		struct ThreadPool
		{
			virtual ~ThreadPool(){}
			virtual void add_task(up_<Task> task) = 0;
			virtual void start(size_t num_threads) = 0;
			virtual void request_stop() = 0;
			virtual void join() = 0;
			virtual void run_post() = 0;
			// Microseconds since the last call: the threaded part run
			// inline (no workers: the web client) and post()
			// ([WEB_MAIN_THREAD]'s frame split)
			virtual void take_times(int64_t *inline_us, int64_t *post_us) = 0;
		};

		ThreadPool* createThreadPool();
	}
}
// vim: set noet ts=4 sw=4:
