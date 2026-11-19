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
// **On the web, rendered ahead** ([MUSIC_WEB_RING], kit_plan 4z37h): SDL's
// audio callback runs on the browser's main thread there (a
// ScriptProcessorNode, SDL_emscriptenaudio.c), and a frame of 200 ms
// starved it. So the source plays silence and the song goes another way:
// rendered a second ahead into a ring, which an AudioWorklet of its own
// (an AudioContext at jam's 44100 Hz) plays on the browser's audio thread.
// With threads (buildat_mt) the ring is in the shared memory, the worklet
// reads it there and a thread of jam's own fills it, so the page's thread
// does nothing for it; without, the page's thread tops it up every 20 ms
// it gets (a timer) and posts what it rendered to the worklet. Either way
// a few frames a second, or a stall under a second, is not heard.
// position() is what is heard there (natively what is rendered, 20 ms on).
// Blip's effects stay on SDL's short path.
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
#ifdef __EMSCRIPTEN__
#include <Audio/Audio.h>
#include <emscripten.h>
#include <emscripten/eventloop.h>
#include <mutex>
#ifdef __EMSCRIPTEN_PTHREADS__
#include <chrono>
#include <thread>
#endif
#endif
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
	~JamStream();

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
#ifdef __EMSCRIPTEN__
		// (the worklet plays it: the source plays silence as long)
		memset(dest, 0, bytes & ~3u);
		return bytes & ~3u;
#else
		commands();
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
#endif
	}

	// The timeline's sample heard now (natively: rendered)
	int64_t position()
	{
#ifdef __EMSCRIPTEN__
		update_read();
		int64_t base = m_base.load(std::memory_order_acquire);
		int32_t d = m_idx[DROP].load(std::memory_order_acquire);
		int32_t r = m_read->load(std::memory_order_acquire);
		return base + (later(d, r) ? d : r);
#else
		return m_position.load(std::memory_order_acquire);
#endif
	}

	const std::shared_ptr<const jam::Song> m_song;
	std::atomic<int64_t> m_position{0}, m_mood_at{-1};
#ifdef __EMSCRIPTEN__
	// [MUSIC_WEB_RING] RING samples a channel (1.49 s), LEAD of them
	// rendered ahead of the worklet's read (1 s). Indices count samples
	// (int32, wrapping after 13 h: compared by difference): WRITE, what
	// is rendered; READ, what the worklet has played (with threads its own
	// store into the shared memory, else the page's estimate from its
	// reports); DROP, a seek's: nothing before it is played. With threads
	// READ is a slot of g_read's, never freed: the worklet may store into
	// it a quantum after its stream is gone.
	// simplified: a mood is asked of the renderer, a second ahead: heard
	// on the bar after that, up to a second later than natively
	static const int RING = 65536, LEAD = 44100;
	enum { WRITE, READ, DROP };
	// a - b > 0 on the wrapping count
	static bool later(int32_t a, int32_t b) { return (int32_t)((uint32_t)a - (uint32_t)b) > 0; }
	static int32_t ahead(int32_t a, int32_t b) { return (int32_t)((uint32_t)a - (uint32_t)b); }
	float m_ringbuf[2][RING];
	std::atomic<int32_t> m_idx[3] = {{0}, {0}, {0}};
	std::atomic<int32_t> *m_read = &m_idx[READ];
	// The timeline's sample at index 0 (since the last seek)
	std::atomic<int64_t> m_base{0};
	WeakPtr<SoundSource> m_src;
	bool m_lua_held = true;
	int m_web_id = 0;
	int32_t m_posted = 0, m_posted_drop = 0; // (without threads)
	// (without threads) READ from the worklet's reports, never past WRITE
	void update_read();
	// The producer's: the commands, then up to `most` chunks while less
	// than LEAD ahead. false: it is ahead
	bool render_ahead(int most)
	{
		commands();
		int32_t w = m_idx[WRITE].load(std::memory_order_relaxed);
		int32_t r = m_read->load(std::memory_order_acquire);
		int32_t d = m_idx[DROP].load(std::memory_order_relaxed);
		if(later(d, r))
			r = d;
		bool more = true;
		for(int i = 0; i < most && (more = ahead(w, r) < LEAD); i++){
			const size_t at = (uint32_t)w % RING; // (CHUNK divides RING)
			m_engine.render(&m_ringbuf[0][at], &m_ringbuf[1][at], CHUNK);
			w = (int32_t)((uint32_t)w + CHUNK);
			m_idx[WRITE].store(w, std::memory_order_release);
		}
		m_mood_at.store(m_engine.mood_at(), std::memory_order_release);
		return more;
	}
#endif
private:
	static const unsigned N = 64, CHUNK = 1024;
	jam::Engine m_engine;
	Cmd m_ring[N];
	std::atomic<unsigned> m_head{0}, m_tail{0};
	float m_l[CHUNK], m_r[CHUNK];

	void commands()
	{
		unsigned t = m_tail.load(std::memory_order_relaxed);
		while(t != m_head.load(std::memory_order_acquire)){
			const Cmd &c = m_ring[t % N];
			if(c.kind == Cmd::SEEK){
				m_engine.seek(c.at);
#ifdef __EMSCRIPTEN__
				// what is in the ring is not played; the timeline from here
				const int32_t w = m_idx[WRITE].load(std::memory_order_relaxed);
				m_base.store(c.at - w, std::memory_order_release);
				m_idx[DROP].store(w, std::memory_order_release);
#endif
			} else {
				m_engine.set_mood(c.name, c.kind == Cmd::MOOD_NOW);
			}
			t++;
			m_tail.store(t, std::memory_order_release);
		}
	}
};

#ifdef __EMSCRIPTEN__
// [MUSIC_WEB_RING] The page's side: an AudioContext at 44100 Hz made at the
// first song (resumed on the page's first gesture, the browsers' autoplay
// rule), the worklet's module from a blob, a node and its gain a stream.
// A node is made once the module is in; till then the ring fills and
// waits. The worklet: with `sab` the ring and its indices in the shared
// memory (Atomics), else a ring of its own filled by messages {at, l, r}
// and {drop}, its read posted back every 8 quanta (23 ms).
EM_JS(int, jam_web_open, (int lp, int rp, int size, int idxp, int readp), {
	var W = Module.jamWeb;
	if(!W){
		W = Module.jamWeb = {nodes: {}, next: 1, ready: false};
		try {
			W.ctx = new AudioContext({sampleRate: 44100, latencyHint: 'playback'});
		} catch(e){
			console.log('jam: no AudioContext at 44100 Hz: ' + e);
			W.ctx = null;
		}
		W.make = function(e){
			var sab = typeof SharedArrayBuffer !== 'undefined' &&
					HEAPF32.buffer instanceof SharedArrayBuffer;
			e.node = new AudioWorkletNode(W.ctx, 'buildat-jam', {
				numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [2],
				processorOptions: sab ? {sab: HEAPF32.buffer, l: e.lp, r: e.rp,
					size: e.size, idx: e.idxp, rd: e.readp} : {size: e.size}});
			e.gain = W.ctx.createGain();
			e.gain.gain.value = e.want;
			e.node.connect(e.gain);
			e.gain.connect(W.ctx.destination);
			e.node.port.onmessage = function(m){
				e.read = m.data;
				e.read_t = performance.now();
			};
			for(var i = 0; i < e.queue.length; i++)
				e.node.port.postMessage(e.queue[i]);
			e.queue = [];
			console.log('jam: a web music node, ' + (sab ? 'the ring in shared memory' :
					'the ring posted') + ', ' + W.ctx.sampleRate + ' Hz, ' + W.ctx.state);
		};
		if(W.ctx){
			var resume = function(){
				if(W.ctx.state !== 'running')
					W.ctx.resume();
			};
			['pointerdown', 'keydown', 'touchend'].forEach(function(t){
				window.addEventListener(t, resume, true);
			});
			var src = "class P extends AudioWorkletProcessor {" +
				"constructor(o){ super(); var p = o.processorOptions;" +
				" this.size = p.size; this.mask = p.size - 1; this.n = 0;" +
				" if(p.sab){ this.l = new Float32Array(p.sab, p.l, p.size);" +
				"  this.r = new Float32Array(p.sab, p.r, p.size);" +
				"  this.idx = new Int32Array(p.sab, p.idx, 3);" +
				"  this.rd = new Int32Array(p.sab, p.rd, 1); }" +
				" else { this.l = new Float32Array(p.size);" +
				"  this.r = new Float32Array(p.size); this.v = [0, 0, 0];" +
				"  var self = this; this.port.onmessage = function(e){" +
				"   var d = e.data; if(d.drop !== undefined){ self.v[2] = d.drop; return; }" +
				"   for(var i = 0; i < d.l.length; i++){ var j = (d.at + i) & self.mask;" +
				"    self.l[j] = d.l[i]; self.r[j] = d.r[i]; }" +
				"   self.v[0] = (d.at + d.l.length) | 0; }; } }" +
				"get(i){ return !this.idx ? this.v[i] : i == 1 ? Atomics.load(this.rd, 0) : Atomics.load(this.idx, i); }" +
				"process(ins, outs){ var o = outs[0], L = o[0], R = o[1] || o[0], n = L.length;" +
				" var w = this.get(0), r = this.get(1), d = this.get(2);" +
				" if(((d - r) | 0) > 0) r = d;" +
				" if(((w - r) | 0) > this.size) r = (w - this.size) | 0;" +
				" var k = Math.max(0, Math.min(n, (w - r) | 0));" +
				" for(var i = 0; i < k; i++){ var j = (r + i) & this.mask; L[i] = this.l[j]; R[i] = this.r[j]; }" +
				" r = (r + k) | 0;" +
				" if(this.idx) Atomics.store(this.rd, 0, r); else this.v[1] = r;" +
				" if(!this.idx && ++this.n % 8 == 0) this.port.postMessage(r);" +
				" return true; } }" +
				"registerProcessor('buildat-jam', P);";
			var url = URL.createObjectURL(new Blob([src], {type: 'application/javascript'}));
			W.ctx.audioWorklet.addModule(url).then(function(){
				W.ready = true;
				for(var id in W.nodes)
					W.make(W.nodes[id]);
			}, function(e){
				console.log('jam: the worklet did not load: ' + e);
			});
		}
	}
	if(!W.ctx)
		return 0;
	var id = W.next++;
	var e = W.nodes[id] = {lp: lp, rp: rp, size: size, idxp: idxp, readp: readp, queue: [],
		read: 0, read_t: 0, want: 0, node: null, gain: null};
	if(W.ready)
		W.make(e);
	return id;
});

// The gain now (moved to over 20 ms when it changes)
EM_JS(void, jam_web_gain, (int id, float gain), {
	var W = Module.jamWeb, e = W && W.nodes[id];
	if(e && e.want !== gain){
		e.want = gain;
		if(e.gain)
			e.gain.gain.setTargetAtTime(gain, W.ctx.currentTime, 0.02);
	}
});

// (without threads) the worklet's read by its last report and the time
// since
EM_JS(int, jam_web_read, (int id), {
	var W = Module.jamWeb, e = W && W.nodes[id];
	if(!e)
		return 0;
	if(!e.node || W.ctx.state !== 'running' || !e.read_t)
		return e.read;
	return (e.read + Math.floor((performance.now() - e.read_t) * 44.1)) | 0;
});

// (without threads) the ring's samples [from, from + n) to the worklet
EM_JS(void, jam_web_post, (int id, int lp, int rp, int size, int from, int n), {
	var e = Module.jamWeb.nodes[id];
	if(!e)
		return;
	var mask = size - 1, l = new Float32Array(n), r = new Float32Array(n);
	for(var i = 0; i < n; i++){
		var j = (from + i) & mask;
		l[i] = HEAPF32[(lp >> 2) + j];
		r[i] = HEAPF32[(rp >> 2) + j];
	}
	var m = {at: from, l: l, r: r};
	if(e.node)
		e.node.port.postMessage(m, [l.buffer, r.buffer]);
	else
		e.queue.push(m);
});

EM_JS(void, jam_web_drop, (int id, int at), {
	var e = Module.jamWeb.nodes[id];
	if(!e)
		return;
	if(e.node)
		e.node.port.postMessage({drop: at});
	else
		e.queue.push({drop: at});
});

EM_JS(void, jam_web_close, (int id), {
	var W = Module.jamWeb, e = W && W.nodes[id];
	if(!e)
		return;
	if(e.node){
		e.node.disconnect();
		e.gain.disconnect();
	}
	delete W.nodes[id];
});

// The streams with a node; the list under its mutex (with threads, jam's
// thread renders them under it)
static std::mutex g_web_mutex;
static std::vector<JamStream*> g_web;

static void web_close(JamStream *s)
{
	if(!s->m_web_id)
		return;
	{
		std::lock_guard<std::mutex> lk(g_web_mutex);
		g_web.erase(std::remove(g_web.begin(), g_web.end(), s), g_web.end());
	}
	jam_web_close(s->m_web_id);
	s->m_web_id = 0;
}

JamStream::~JamStream()
{
	web_close(this);
}

void JamStream::update_read()
{
#ifndef __EMSCRIPTEN_PTHREADS__
	if(!m_web_id)
		return;
	const int32_t w = m_idx[WRITE].load(), r = jam_web_read(m_web_id);
	m_read->store(later(r, w) ? w : r);
#endif
}

#ifdef __EMSCRIPTEN_PTHREADS__
// jam's own thread: each stream topped up 4 chunks (93 ms) at a time (a
// close waits for one such pass at most), resting 10 ms once all are ahead
static void web_thread()
{
	for(;;){
		bool more = false;
		{
			std::lock_guard<std::mutex> lk(g_web_mutex);
			for(JamStream *s : g_web)
				more = s->render_ahead(4) || more;
		}
		if(!more)
			std::this_thread::sleep_for(std::chrono::milliseconds(10));
	}
}
#endif

// The page's thread, every 20 ms it gets: a stream no longer heard (its
// source stopped or gone, or playing nothing of it) closed; the gain the
// source would have (its own, its type's and the master's); without
// threads the read taken from the worklet's reports, the ring topped up
// and what is new posted
static void web_pump(void*)
{
	std::vector<JamStream*> list;
	{
		std::lock_guard<std::mutex> lk(g_web_mutex);
		list = g_web;
	}
	for(JamStream *s : list){
		SoundSource *src = s->m_src.Get();
		Audio *audio = src ? src->GetSubsystem<Audio>() : nullptr;
		if(!audio || !src->IsPlaying() || s->Refs() <= (s->m_lua_held ? 1 : 0)){
			web_close(s);
			continue;
		}
		jam_web_gain(s->m_web_id, src->GetGain() *
				audio->GetSoundSourceMasterGain(StringHash(src->GetSoundType())));
#ifndef __EMSCRIPTEN_PTHREADS__
		s->update_read();
		s->render_ahead(1000);
		const int32_t d = s->m_idx[JamStream::DROP].load();
		if(d != s->m_posted_drop){
			jam_web_drop(s->m_web_id, d);
			s->m_posted_drop = d;
		}
		const int32_t nw = s->m_idx[JamStream::WRITE].load();
		// (what a drop passed over is not sent)
		if(JamStream::later(d, s->m_posted))
			s->m_posted = d;
		if(nw != s->m_posted){
			jam_web_post(s->m_web_id, (int)(intptr_t)s->m_ringbuf[0],
					(int)(intptr_t)s->m_ringbuf[1], JamStream::RING,
					s->m_posted, JamStream::ahead(nw, s->m_posted));
			s->m_posted = nw;
		}
#endif
	}
}

static void web_open(JamStream *s, SoundSource *src)
{
	s->m_src = src;
#ifdef __EMSCRIPTEN_PTHREADS__
	// simplified: a slot reused 256 streams on (a closed worklet stops
	// within a quantum, long before)
	static std::atomic<int32_t> g_read[256];
	static unsigned slot = 0;
	s->m_read = &g_read[slot++ % 256];
	s->m_read->store(0);
#endif
	s->m_web_id = jam_web_open((int)(intptr_t)s->m_ringbuf[0],
			(int)(intptr_t)s->m_ringbuf[1], JamStream::RING,
			(int)(intptr_t)&s->m_idx[0], (int)(intptr_t)s->m_read);
	if(!s->m_web_id){
		log_w(MODULE, "jam: no web audio for the music");
		return;
	}
	static bool started = false;
	if(!started){
		started = true;
		emscripten_set_interval(web_pump, 20, nullptr);
#ifdef __EMSCRIPTEN_PTHREADS__
		std::thread(web_thread).detach();
#endif
	}
	std::lock_guard<std::mutex> lk(g_web_mutex);
	g_web.push_back(s);
}
#else
JamStream::~JamStream() {}
#endif

struct Song { std::shared_ptr<const jam::Song> s; };
struct Player
{
	SharedPtr<JamStream> stream;
	WeakPtr<SoundSource> source;
#ifdef __EMSCRIPTEN__
	// (the web's pump tells a source's hold from this one's)
	~Player() { stream->m_lua_held = false; }
#endif
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
#ifdef __EMSCRIPTEN__
	web_open(stream, src);
#endif
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

// player:position() -> the timeline's seconds rendered so far natively
// (the mixer renders ahead by its buffer, 20 ms), heard on the web, the
// song's bar there from 0, and the seconds the last mood switched at (nil:
// none yet)
static int l_position(lua_State *L)
{
	Player *p = player(L);
	int64_t at = p->stream->position();
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
