// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_wasm_ui: [CLIENT_WASM_BINDINGS] a call of nothing but
// bindings is stopped by its budget: the b key calls Node:GetID() until
// the call traps, a line each 5000 calls. With BINDING_COST (wasm.cpp)
// that is near 50000 calls on every engine (the interpreter is charged
// its share of its smaller budget).
#include "interface/buildat_client.h"

using namespace buildat;

static Node g_camera;

static void log_calls(int n)
{
	char buf[40] = "budget: ";
	unsigned int l = 8;
	char digits[12];
	int d = 0;
	do {
		digits[d++] = (char)('0' + n % 10);
		n /= 10;
	} while(n);
	while(d)
		buf[l++] = digits[--d];
	const char tail[] = " calls";
	for(unsigned int i = 0; i < sizeof tail - 1; i++)
		buf[l++] = tail[i];
	log(Str(buf, l));
}

BUILDAT_WASM_EXPORT void frame(float dt)
{
	(void)dt;
	Event e;
	bool go = false;
	while(next_event(e)){
		if(e.kind == BUILDAT_EVENT_START)
			g_camera = Node((unsigned int)e.word(1));
		else if(e.kind == BUILDAT_EVENT_KEY_DOWN && !e.word(2) && e.word(1) == 'b')
			go = true;
	}
	if(!go || !g_camera)
		return;
	for(int n = 1; n <= 200000; n++){
		g_camera.GetID();
		if(n % 5000 == 0)
			log_calls(n);
	}
	log("budget: NOT STOPPED");
}
