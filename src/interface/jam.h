// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [MUSIC_SYNTH] jam, the music engine: a song's text (the jam1 format,
// doc/client_api.txt) parsed and compiled once into note events, then
// rendered a block at a time by voices, tracks with their inserts, the
// reverb and delay buses and the master. No samples, no recordings.
// The client renders it from the audio thread (lua_bindings/jam.cpp), the
// server analyses it for agents (builtin/kit); both through this.
//
// **The same samples everywhere**: the output is a function of the text and
// the position, on every platform and in every release of jam1 (own sine,
// exp2 and log2 tables, seeded noise, impl/jam.cpp built without contracted
// floating point). A change to how jam1 sounds is a jam2 beside it.
#pragma once
#include "core/types.h"
#include <memory>

namespace interface
{
	namespace jam
	{
		static const int RATE = 44100;
		static const size_t MAX_TEXT = 65536;

		struct Song;

		struct Info
		{
			ss_ title;
			double tempo = 0;
			double bar_len = 0; // samples
			int64_t loop_start = 0, end = 0; // samples
			size_t events = 0;
			sv_<ss_> tracks, moods;
		};

		// The text parsed and compiled, or null and *error "line N: ...".
		// tempo > 0 replaces the song's own
		std::shared_ptr<const Song> parse(const ss_ &text, ss_ *error,
				double tempo = 0);
		Info info(const Song &song);
		// A position on the song's timeline (samples from its start, the loop
		// repeating after its end) as a place in the song: its bar from 0
		// and the sample in the song (looped back)
		int64_t song_sample(const Song &song, int64_t at);
		int64_t bar_of(const Song &song, int64_t at);

		struct EngineImpl;
		class Engine
		{
		public:
			explicit Engine(std::shared_ptr<const Song> song);
			~Engine();
			// n stereo samples, any n: rendered in fixed blocks of 256 from
			// the last seek, so how a caller splits its reads changes nothing
			void render(float *left, float *right, size_t n);
			// A mood (a set of track gains, "" or "all" every track at 0 dB),
			// from the next bar faded over a beat, or now. false: no such mood
			bool set_mood(const ss_ &name, bool now = false);
			// To a place on the timeline: voices and buses cleared
			void seek(int64_t at);
			// The timeline's next sample, and the one a mood last switched at
			// (-1 none yet)
			int64_t position() const;
			int64_t mood_at() const;
			size_t voices() const;
			// Only these tracks heard (the others off), for analysis
			void solo(const sv_<ss_> &tracks);
			// The samples of each track as it goes into the master (after
			// its inserts, gain and pan, before the buses), for analysis
			void tap(bool on);
			const float* tapped(size_t track) const; // last block's, mono
			size_t block_size() const;
		private:
			EngineImpl *m;
		};

		// An agent's ears: the song rendered from its start over its play
		// order once and 0.1 s into the loop again (or `seconds`, at most
		// 600), measured as a JSON object: loudness in LUFS, peaks, energy
		// per band, the same per track, the loop's join, the render's cost
		// and its hash (FNV-1a over the floats: the same everywhere); mood:
		// from the start; track: that one alone
		ss_ analyze(const Song &song, double seconds, const ss_ &mood,
				const ss_ &track);
	}
}
// vim: set noet ts=4 sw=4:
