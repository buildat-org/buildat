// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [CHECK_TIME_SCALE] interface::os::game_us(), the game's clock
#include "interface/os.h"
#include <algorithm>
#include <mutex>

namespace interface {
namespace os {

static std::mutex g_mutex;
static bool g_on = false;
static int64_t g_game_us = 0, g_real_us = 0, g_tick_us = 0;
static double g_rate = 1;

int64_t game_us()
{
	const int64_t now = time_us();
	std::lock_guard<std::mutex> lock(g_mutex);
	if(!g_on)
		return now;
	const int64_t since = std::max<int64_t>(0, now - g_real_us);
	return g_game_us + std::min(g_tick_us, (int64_t)(since * g_rate));
}

double game_rate()
{
	std::lock_guard<std::mutex> lock(g_mutex);
	return g_on ? g_rate : 1;
}

void set_game_tick(int64_t game_us, int64_t tick_us, double rate)
{
	const int64_t now = time_us();
	std::lock_guard<std::mutex> lock(g_mutex);
	g_on = true;
	g_game_us = game_us;
	g_real_us = now;
	g_tick_us = tick_us;
	g_rate = rate;
}

}
}
// vim: set noet ts=4 sw=4:
