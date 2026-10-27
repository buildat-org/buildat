// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_wasm_only: a module whose client is C only, run by the
// engine's default client_main ("client_main": "wasm" in meta.json): a
// cube it builds and turns, a key that changes its colour and sends a
// packet, and the server's answer (echo/) logged.
// apps/sample_wasm_only_rust/main/wasm/ is the same in Rust; check.sh runs
// both.
#include "interface/wasm_api.h"

static int g_camera = -1, g_light = -1, g_cube = -1;
static int g_colour;
static float g_time;
static unsigned char g_event[BUILDAT_EVENT_MAX];

static unsigned int len(const char *s)
{
	unsigned int n = 0;
	while(s[n])
		n++;
	return n;
}

// "<text><number>" into the log
static void log_n(const char *text, int n)
{
	char buf[160];
	unsigned int l = len(text);
	for(unsigned int i = 0; i < l; i++)
		buf[i] = text[i];
	char digits[12];
	int d = 0;
	unsigned int u = n < 0 ? 0u - (unsigned int)n : (unsigned int)n;
	do {
		digits[d++] = (char)('0' + u % 10);
		u /= 10;
	} while(u);
	if(n < 0)
		buf[l++] = '-';
	while(d)
		buf[l++] = digits[--d];
	buildat_log(buf, l);
}

static int word(const unsigned char *p)
{
	return (int)((unsigned int)p[0] | (unsigned int)p[1] << 8 |
			(unsigned int)p[2] << 16 | (unsigned int)p[3] << 24);
}

// sin on [-pi, pi], near enough for turning a cube
static float sin_near(float x)
{
	const float pi = 3.14159265f;
	while(x > pi)
		x -= 2 * pi;
	while(x < -pi)
		x += 2 * pi;
	float x2 = x * x;
	return x * (1 - x2 / 6 * (1 - x2 / 20 * (1 - x2 / 42 * (1 - x2 / 72))));
}

static void draw_cube(void)
{
	static const float faces[6][4][3] = {
		{{-1,-1,-1}, {-1, 1,-1}, { 1, 1,-1}, { 1,-1,-1}}, // -z
		{{ 1,-1, 1}, { 1, 1, 1}, {-1, 1, 1}, {-1,-1, 1}}, // +z
		{{-1,-1, 1}, {-1, 1, 1}, {-1, 1,-1}, {-1,-1,-1}}, // -x
		{{ 1,-1,-1}, { 1, 1,-1}, { 1, 1, 1}, { 1,-1, 1}}, // +x
		{{-1, 1,-1}, {-1, 1, 1}, { 1, 1, 1}, { 1, 1,-1}}, // +y
		{{-1,-1, 1}, {-1,-1,-1}, { 1,-1,-1}, { 1,-1, 1}}, // -y
	};
	static const float normals[6][3] = {
		{0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, -1, 0},
	};
	static const float colours[3][3] = {
		{1.0f, 0.5f, 0.1f}, {0.2f, 0.8f, 0.3f}, {0.3f, 0.4f, 1.0f},
	};
	static float v[24 * 12];
	static unsigned int ix[36];
	const float *c = colours[g_colour % 3];
	for(int f = 0; f < 6; f++){
		for(int k = 0; k < 4; k++){
			float *o = v + (f * 4 + k) * 12;
			for(int a = 0; a < 3; a++){
				o[a] = faces[f][k][a] * 0.5f;
				o[3 + a] = normals[f][a];
				o[6 + a] = c[a] * (0.7f + 0.05f * f);
			}
			o[9] = 1;
			o[10] = k == 2 || k == 3;
			o[11] = k == 1 || k == 2;
		}
		static const unsigned int quad[6] = {0, 1, 2, 0, 2, 3};
		for(int k = 0; k < 6; k++)
			ix[f * 6 + k] = f * 4 + quad[k];
	}
	buildat_geometry_set(g_cube, 0, v, 24, ix, 36);
}

static void on_start(const unsigned char *e, int n)
{
	if(n < 24)
		return;
	g_camera = word(e + 4);
	g_light = word(e + 8);
	int nodes = word(e + 20);
	if(nodes < 1 || n < 24 + 8)
		return;
	g_cube = word(e + 24);
	// The camera back from the cube and a little above it, looking down
	// 20 degrees (a turn about x: w, x = cos, sin of half of it)
	float t[10] = {0, 1.5f, -4, 0.98481f, 0.17365f, 0, 0, 1, 1, 1};
	buildat_node_set(g_camera, t);
	draw_cube();
	log_n("drew a cube, handed nodes: ", nodes);
}

static void on_packet(const unsigned char *e, int n)
{
	if(n < 8)
		return;
	int name_len = word(e + 4);
	if(name_len < 0 || 8 + name_len > n)
		return;
	char line[200];
	const char head[] = "the server answered ";
	unsigned int l = 0;
	for(unsigned int i = 0; i < sizeof head - 1; i++)
		line[l++] = head[i];
	for(int i = 0; i < name_len && l < 100; i++)
		line[l++] = (char)e[8 + i];
	line[l++] = ':';
	line[l++] = ' ';
	for(int i = 8 + name_len; i < n && l < sizeof line; i++)
		line[l++] = (char)e[i];
	buildat_log(line, l);
}

BUILDAT_WASM_EXPORT const char *packets(void)
{
	return "echo";
}

BUILDAT_WASM_EXPORT void frame(float dt)
{
	int n;
	while((n = buildat_event_take(g_event, sizeof g_event)) >= 0){
		if(n > (int)sizeof g_event || n < 4)
			break; // Not for this module: none is that long
		switch(word(g_event)){
		case BUILDAT_EVENT_START:
			on_start(g_event, n);
			break;
		case BUILDAT_EVENT_KEY_DOWN:
			if(n >= 12 && word(g_event + 4) == 32 && !word(g_event + 8)){
				g_colour++;
				if(g_cube >= 0)
					draw_cube();
				log_n("space: the colour is now ", g_colour % 3);
				char data[1] = {(char)('0' + g_colour % 3)};
				buildat_send_packet("key", 3, data, 1);
			}
			break;
		case BUILDAT_EVENT_PACKET:
			on_packet(g_event, n);
			break;
		}
	}
	if(g_cube < 0)
		return;
	g_time += dt;
	// A turn about y, half an angle a second
	float h = g_time * 0.5f;
	float t[10] = {0, 0, 0, sin_near(h + 1.5707963f), 0, sin_near(h), 0, 1, 1, 1};
	buildat_node_set(g_cube, t);
}
