// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sim_rate_check's server, for util/sim_rate_check.sh
// ([CHECK_TIME_SCALE]): no client. Each tick a state stepped by the tick's
// dtime and by the ticks misplaced on the game's clock (interface::os::
// game_us(): each a tick past the last), so one misplaced changes it;
// each game second a line with the ticks, those misplaced and the state. The tick at game second 5 takes 1.5 s of the wall's: a
// slowed tick, longer than the 1 s past which a server at its 30 Hz drops
// the time ("Skipping").
#include "interface/module.h"
#include "interface/server.h"
#include "interface/os.h"
#include "core/log.h"
#include <chrono>
#include <cstring>
#include <thread>
#define MODULE "main"

namespace main_ {

struct Module: public interface::Module
{
	interface::Server *m_server;
	int64_t m_last_us = -1;
	uint64_t m_ticks = 0;
	uint64_t m_misplaced = 0;
	double m_x = 1, m_v = 0;
	uint64_t m_h = 1469598103934665603ULL;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		sub(m_server, "core:tick", &Module::on_tick);
	}

	void on_tick(const interface::TickEvent &event)
	{
		const int64_t tick_us = 1000000 / 30;
		const int64_t now = interface::os::game_us();
		// Each tick's reading on the clock a tick past the last's, give or
		// take the part of a tick it was read into: under --sim-rate the
		// ticks' time, late or not; on the wall clock a late tick's gap
		if(m_last_us >= 0 && (now - m_last_us <= 0 ||
				now - m_last_us >= 2 * tick_us))
			m_misplaced++;
		m_last_us = now;
		m_ticks++;
		// An oscillator stepped by dtime, and the count hashed in
		const double dt = event.dtime;
		m_v -= m_x * dt;
		m_x += m_v * dt;
		uint64_t bits = 0;
		memcpy(&bits, &m_x, sizeof bits);
		m_h = (m_h ^ bits ^ m_misplaced) * 1099511628211ULL;
		if(m_ticks == 150)
			std::this_thread::sleep_for(std::chrono::milliseconds(1500));
		if(m_ticks % 30 == 0)
			log_i(MODULE, "sim_rate_check: game second %d: %d ticks, %d "
					"misplaced on the clock, rate %g, state %016llx",
					(int)(m_ticks / 30), (int)m_ticks, (int)m_misplaced,
					interface::os::game_rate(), (unsigned long long)m_h);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
