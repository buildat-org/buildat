// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [MUSIC_SYNTH] jam for sandboxed Lua (interface/jam.h, the engine): a
// song parsed once, then played by a SoundStream that renders it **from the
// audio thread**, as much as the mixer asks for. A frame that drops or a
// window out of focus does not starve it natively, and it never drifts
// from the samples it has played. The main thread talks to it through a
// small lock-free queue (a mood, a seek) and reads its position from an
// atomic; the engine itself is the audio thread's alone once it plays.
//
// On the web SDL's audio callback runs on the browser's main thread (a
// ScriptProcessorNode, SDL_emscriptenaudio.c), so a long frame there does
// starve it: the music goes on from where it was, behind the shared clock,
// and the caller seeks it back (builtin/kit/client_lua/music.lua).
//
// **A trust boundary**: the text is any server's, and the engine checks it
// (interface/jam.h); a song and a player are userdata the sandbox cannot
// forge; the SoundSource is taken out of its sandbox wrapper by tolua.
#include "lua_bindings/util.h"
#include "interface/jam.h"
#include "core/log.h"
#include <tolua++.h>
#include <Audio/SoundSource.h>
#include <Audio/SoundStream.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <vector>
#define MODULE "jam"

using namespace Urho3D;
namespace jam = interface::jam;

namespace lua_bindings {
namespace jam_lua {

static const char *SONG = "buildat.JamSong";
static const char *PLAYER = "buildat.JamPlayer";

struct Cmd
{
	enum Kind { MOOD, MOOD_NOW, SEEK } kind;
	int64_t at;
	char name[48];
};

class JamStream: public SoundStream
{
public:
	explicit JamStream(std::shared_ptr<const jam::Song> song):
		m_song(song), m_engine(song)
	{
		SetFormat(jam::RATE, true, true);
	}

	// The main thread's; false: the queue is full (64 waiting)
	bool push(const Cmd &c)
	{
		unsigned h = m_head.load(std::memory_order_relaxed);
		if(h - m_tail.load(std::memory_order_acquire) >= N)
			return false;
		m_ring[h % N] = c;
		m_head.store(h + 1, std::memory_order_release);
		return true;
	}

	// The audio thread's, under Audio's mutex
	unsigned GetData(signed char *dest, unsigned bytes) override
	{
		unsigned t = m_tail.load(std::memory_order_relaxed);
		while(t != m_head.load(std::memory_order_acquire)){
			const Cmd &c = m_ring[t % N];
			if(c.kind == Cmd::SEEK)
				m_engine.seek(c.at);
			else
				m_engine.set_mood(c.name, c.kind == Cmd::MOOD_NOW);
			t++;
			m_tail.store(t, std::memory_order_release);
		}
		int16_t *out = (int16_t*)dest;
		size_t n = bytes / 4;
		for(size_t done = 0; done < n;){
			size_t k = std::min(n - done, (size_t)CHUNK);
			m_engine.render(m_l, m_r, k);
			for(size_t i = 0; i < k; i++){
				// (the limiter holds them in -1..1)
				out[(done + i) * 2] = (int16_t)std::lrint(m_l[i] * 32767.0f);
				out[(done + i) * 2 + 1] = (int16_t)std::lrint(m_r[i] * 32767.0f);
			}
			done += k;
		}
		m_position.store(m_engine.position(), std::memory_order_release);
		m_mood_at.store(m_engine.mood_at(), std::memory_order_release);
		return (unsigned)(n * 4);
	}

	const std::shared_ptr<const jam::Song> m_song;
	std::atomic<int64_t> m_position{0}, m_mood_at{-1};
private:
	static const unsigned N = 64, CHUNK = 1024;
	jam::Engine m_engine;
	Cmd m_ring[N];
	std::atomic<unsigned> m_head{0}, m_tail{0};
	float m_l[CHUNK], m_r[CHUNK];
};

struct Song { std::shared_ptr<const jam::Song> s; };
struct Player
{
	SharedPtr<JamStream> stream;
	WeakPtr<SoundSource> source;
};

template<typename T>
static T* check(lua_State *L, int narg, const char *mt, const char *what)
{
	void *p = lua_touserdata(L, narg);
	if(p && lua_getmetatable(L, narg)){
		luaL_getmetatable(L, mt);
		bool same = lua_rawequal(L, -1, -2);
		lua_pop(L, 2);
		if(same)
			return *(T**)p;
	}
	throw Exception(ss_("jam: not a ") + what);
}

template<typename T>
static void push_new(lua_State *L, T *o, const char *mt)
{
	*(T**)lua_newuserdata(L, sizeof(T*)) = o;
	luaL_getmetatable(L, mt);
	lua_setmetatable(L, -2);
}

template<typename T>
static int gc(lua_State *L)
{
	delete *(T**)lua_touserdata(L, 1);
	return 0;
}

static double number_at(lua_State *L, int i, const char *what, double lo,
		double hi)
{
	if(lua_type(L, i) != LUA_TNUMBER)
		throw Exception(ss_("jam: ") + what + " is not a number");
	double v = lua_tonumber(L, i);
	if(!(v >= lo && v <= hi))
		throw Exception(ss_("jam: ") + what + " is out of its range");
	return v;
}

static ss_ string_at(lua_State *L, int i, const char *what, size_t max)
{
	if(lua_type(L, i) != LUA_TSTRING)
		throw Exception(ss_("jam: ") + what + " is not a string");
	size_t len = 0;
	const char *s = lua_tolstring(L, i, &len);
	if(len > max)
		throw Exception(ss_("jam: ") + what + " is too long");
	return ss_(s, len);
}

static ss_ opt_string(lua_State *L, int i, const char *what, size_t max)
{
	return lua_isnoneornil(L, i) ? "" : string_at(L, i, what, max);
}

// song(text[, tempo]) -> a song, or nil and "line N: why"
static int l_song(lua_State *L)
{
	ss_ text = string_at(L, 1, "the text", jam::MAX_TEXT);
	double tempo = lua_isnoneornil(L, 2) ? 0 :
			number_at(L, 2, "the tempo", 20, 400);
	ss_ err;
	auto s = jam::parse(text, &err, tempo);
	if(!s){
		lua_pushnil(L);
		lua_pushstring(L, err.c_str());
		return 2;
	}
	push_new(L, new Song{s}, SONG);
	return 1;
}

static void set_strings(lua_State *L, const char *key, const sv_<ss_> &v)
{
	lua_createtable(L, (int)v.size(), 0);
	for(size_t i = 0; i < v.size(); i++){
		lua_pushstring(L, v[i].c_str());
		lua_rawseti(L, -2, (int)i + 1);
	}
	lua_setfield(L, -2, key);
}

// song:info() -> {title, tempo, bar (seconds), loop = {from, to}
// (seconds), events, tracks = {...}, moods = {...}}
static int l_info(lua_State *L)
{
	jam::Info i = jam::info(*check<Song>(L, 1, SONG, "song")->s);
	lua_newtable(L);
	lua_pushstring(L, i.title.c_str());
	lua_setfield(L, -2, "title");
	lua_pushnumber(L, i.tempo);
	lua_setfield(L, -2, "tempo");
	lua_pushnumber(L, i.bar_len / jam::RATE);
	lua_setfield(L, -2, "bar");
	lua_createtable(L, 2, 0);
	lua_pushnumber(L, (double)i.loop_start / jam::RATE);
	lua_rawseti(L, -2, 1);
	lua_pushnumber(L, (double)i.end / jam::RATE);
	lua_rawseti(L, -2, 2);
	lua_setfield(L, -2, "loop");
	lua_pushinteger(L, (lua_Integer)i.events);
	lua_setfield(L, -2, "events");
	set_strings(L, "tracks", i.tracks);
	set_strings(L, "moods", i.moods);
	return 1;
}

// song:analyze([seconds[, mood[, track]]]) -> a JSON string: loudness,
// peaks, bands, per track, the loop's join, the render's cost, its hash
static int l_analyze(lua_State *L)
{
	Song *s = check<Song>(L, 1, SONG, "song");
	double sec = lua_isnoneornil(L, 2) ? 0 : number_at(L, 2, "seconds", 0, 600);
	ss_ mood = opt_string(L, 3, "the mood", 64);
	ss_ track = opt_string(L, 4, "the track", 64);
	lua_pushstring(L, jam::analyze(*s->s, sec, mood, track).c_str());
	return 1;
}

// The SoundSource a sandbox passes: its wrapper's metatable holds the
// unsafe instance (client/core/magic_sandbox), and tolua says what it is
static SoundSource* source_at(lua_State *L, int index)
{
	SoundSource *src = nullptr;
	if(lua_type(L, index) == LUA_TTABLE && lua_getmetatable(L, index)){
		lua_pushliteral(L, "unsafe");
		lua_rawget(L, -2);
		tolua_Error err;
		if(tolua_isusertype(L, -1, "SoundSource", 0, &err))
			src = (SoundSource*)tolua_tousertype(L, -1, 0);
		lua_pop(L, 2);
	} else if(lua_type(L, index) == LUA_TUSERDATA){
		// trusted code's raw tolua handle
		tolua_Error err;
		if(tolua_isusertype(L, index, "SoundSource", 0, &err))
			src = (SoundSource*)tolua_tousertype(L, index, 0);
	}
	if(src == nullptr)
		throw Exception("jam: not a SoundSource");
	return src;
}

// song:play(sound_source[, at]) -> a player: the song from at seconds on
// its timeline (0), on the source, which keeps playing it till stopped
static int l_play(lua_State *L)
{
	Song *s = check<Song>(L, 1, SONG, "song");
	SoundSource *src = source_at(L, 2);
	double at = lua_isnoneornil(L, 3) ? 0 : number_at(L, 3, "at", 0, 1e7);
	SharedPtr<JamStream> stream(new JamStream(s->s));
	if(at > 0)
		stream->push({Cmd::SEEK, (int64_t)std::floor(at * jam::RATE), ""});
	src->Play(stream);
	push_new(L, new Player{stream, WeakPtr<SoundSource>(src)}, PLAYER);
	return 1;
}

static Player* player(lua_State *L)
{
	return check<Player>(L, 1, PLAYER, "player");
}

// player:mood(name[, now]) -> true, or false: no such mood. From the next
// bar, faded over a beat; now: from the next block. "all" (or "") every
// track at its own level
static int l_mood(lua_State *L)
{
	Player *p = player(L);
	ss_ name = string_at(L, 2, "the mood", 47);
	if(!name.empty() && name != "all"){
		jam::Info i = jam::info(*p->stream->m_song);
		if(std::find(i.moods.begin(), i.moods.end(), name) == i.moods.end()){
			lua_pushboolean(L, 0);
			return 1;
		}
	}
	Cmd c{lua_toboolean(L, 3) ? Cmd::MOOD_NOW : Cmd::MOOD, 0, ""};
	memcpy(c.name, name.c_str(), name.size() + 1);
	lua_pushboolean(L, p->stream->push(c));
	return 1;
}

// player:seek(seconds): to that place on the song's timeline (its start
// 0, the loop repeating past its end); the voices and tails cleared
static int l_seek(lua_State *L)
{
	Player *p = player(L);
	double at = number_at(L, 2, "seconds", 0, 1e7);
	lua_pushboolean(L, p->stream->push({Cmd::SEEK,
			(int64_t)std::floor(at * jam::RATE), ""}));
	return 1;
}

// player:position() -> the timeline's seconds rendered so far (the mixer
// renders ahead by its buffer, ~0.1 s), the song's bar there from 0, and
// the seconds the last mood switched at (nil: none yet)
static int l_position(lua_State *L)
{
	Player *p = player(L);
	int64_t at = p->stream->m_position.load(std::memory_order_acquire);
	int64_t m = p->stream->m_mood_at.load(std::memory_order_acquire);
	lua_pushnumber(L, (double)at / jam::RATE);
	lua_pushinteger(L, (lua_Integer)jam::bar_of(*p->stream->m_song, at));
	if(m < 0)
		lua_pushnil(L);
	else
		lua_pushnumber(L, (double)m / jam::RATE);
	return 3;
}

// player:stop(): the source stops (a new play() is a new player)
static int l_stop(lua_State *L)
{
	Player *p = player(L);
	if(SoundSource *s = p->source.Get())
		if(p->stream->Refs() > 1) // (the source holds it: it plays it)
			s->Stop();
	return 0;
}

// player:playing() -> whether its source still plays it
static int l_playing(lua_State *L)
{
	Player *p = player(L);
	SoundSource *s = p->source.Get();
	lua_pushboolean(L, s && s->IsPlaying() && p->stream->Refs() > 1);
	return 1;
}

static void metatable(lua_State *L, const char *name, lua_CFunction gc_fn,
		const luaL_Reg *methods)
{
	luaL_newmetatable(L, name);
	// getmetatable() on one says nothing; the methods only by name
	lua_pushboolean(L, 0);
	lua_setfield(L, -2, "__metatable");
	lua_pushcfunction(L, gc_fn);
	lua_setfield(L, -2, "__gc");
	lua_newtable(L);
	for(const luaL_Reg *m = methods; m->name; m++){
		lua_pushcfunction(L, m->func);
		lua_setfield(L, -2, m->name);
	}
	lua_setfield(L, -2, "__index");
	lua_pop(L, 1);
}

} // namespace jam_lua

void init_jam(lua_State *L)
{
	using namespace jam_lua;
	static const luaL_Reg song_methods[] = {
		{"info", guarded<l_info>},
		{"analyze", guarded<l_analyze>},
		{"play", guarded<l_play>},
		{nullptr, nullptr},
	};
	static const luaL_Reg player_methods[] = {
		{"mood", guarded<l_mood>},
		{"seek", guarded<l_seek>},
		{"position", guarded<l_position>},
		{"stop", guarded<l_stop>},
		{"playing", guarded<l_playing>},
		{nullptr, nullptr},
	};
	metatable(L, SONG, gc<Song>, song_methods);
	metatable(L, PLAYER, gc<Player>, player_methods);
	lua_pushcfunction(L, guarded<l_song>);
	lua_setglobal(L, "__buildat_jam_song");
}

} // namespace lua_bindings
// vim: set noet ts=4 sw=4:
