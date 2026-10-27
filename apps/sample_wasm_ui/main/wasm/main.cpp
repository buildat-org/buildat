// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_wasm_ui: [CLIENT_WASM_BINDINGS]' first user, a module whose
// client is C++ only (no Lua of its own: "client_main": "wasm"), written
// against interface/buildat_client.h: a window with a button (Urho3D's
// UI, through the bindings), a cube it builds, a key, and packets both
// ways. A press of the button and the space key each send a packet,
// which echo/ answers; the button's text shows the presses.
// And the C++ twin of extensions/sandbox_test's refusals, for the calls
// the bindings cover (refuse()): what a Lua script is refused, this is
// refused, each a trap with its reason in the client's log.
#include "interface/buildat_client.h"

using namespace buildat;

static Node g_camera, g_cube;
static Window g_window;
static Button g_button;
static Text g_label;
static int g_clicks, g_colour;
static float g_time;

// "<text><number>" into a buffer: its length
static unsigned int with_n(char *buf, const char *text, int n)
{
	unsigned int l = 0;
	while(text[l]){
		buf[l] = text[l];
		l++;
	}
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
	return l;
}
static void log_n(const char *text, int n)
{
	char buf[160];
	log(Str(buf, with_n(buf, text, n)));
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

// The mesh: wasm_api.h's geometry_set into the node the client_main made
static void draw_cube()
{
	static const float faces[6][4][3] = {
		{{-1,-1,-1}, {-1, 1,-1}, { 1, 1,-1}, { 1,-1,-1}},
		{{ 1,-1, 1}, { 1, 1, 1}, {-1, 1, 1}, {-1,-1, 1}},
		{{-1,-1, 1}, {-1, 1, 1}, {-1, 1,-1}, {-1,-1,-1}},
		{{ 1,-1,-1}, { 1, 1,-1}, { 1, 1, 1}, { 1,-1, 1}},
		{{-1, 1,-1}, {-1, 1, 1}, { 1, 1, 1}, { 1, 1,-1}},
		{{-1,-1, 1}, {-1,-1,-1}, { 1,-1,-1}, { 1,-1, 1}},
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
	buildat_geometry_set((int)g_cube.handle(), 0, v, 24, ix, 36);
}

// The window: the top left third of the screen, a button filling it
static void build_ui()
{
	UIElement root = ui().root();
	root.defaultStyle(cache().GetResource("XMLFile", "UI/DefaultStyle.xml").
			as<XMLFile>());
	const IntVector2 size = root.size();
	g_window = root.CreateChild("Window", "sample window").as<Window>();
	g_window.SetStyleAuto();
	g_window.position(IntVector2{0, 0});
	g_window.SetFixedSize(size.x / 2, size.y / 3);
	g_button = g_window.CreateChild("Button", "sample button").as<Button>();
	g_button.SetStyleAuto();
	// Not focused by its click, or the space key would press it as well
	g_button.SetFocusMode(constant("FM_NOTFOCUSABLE").number);
	g_button.position(IntVector2{4, 4});
	g_button.SetFixedSize(size.x / 2 - 8, size.y / 3 - 8);
	g_label = g_button.CreateChild("Text").as<Text>();
	g_label.SetStyleAuto();
	g_label.SetAlignment(constant("HA_CENTER").number,
			constant("VA_CENTER").number);
	g_label.text("Press me");
	SubscribeToEvent(g_button, "Released");
	// [BINDINGS_SETLAYOUT] A call with its optional arguments: a vertical
	// layout spaced 4, two children 10 high, the second at y 14
	{
		UIElement box = root.CreateChild("UIElement").as<UIElement>();
		for(int i = 0; i < 2; i++)
			box.CreateChild("UIElement").as<UIElement>().SetFixedSize(10, 10);
		box.SetLayout(constant("LM_VERTICAL").number, 4);
		log_n("SetLayout: the second child at y ",
				box.GetChild(1).as<UIElement>().position().y);
		box.Remove();
	}
	log_n("ui root width: ", size.x);
	log_n("ui root height: ", size.y);
}

static void on_start(const Event &e)
{
	g_camera = Node((unsigned int)e.word(1));
	if(e.word(5) < 1)
		return;
	g_cube = Node((unsigned int)e.word(6));
	// The camera back from the cube and a little above it, looking down
	// 20 degrees, through the bindings' properties
	g_camera.position(Vector3{0, 1.5f, -4});
	g_camera.rotation(Quaternion{0.98481f, 0.17365f, 0, 0});
	const Vector3 p = g_camera.position();
	log_n("the camera is at y*10: ", (int)(p.y * 10 + 0.5f));
	draw_cube();
	build_ui();
	log("drew a cube and a window");
}

static void on_object(const Event &e)
{
	if((unsigned int)e.word(1) != g_button.handle() || e.name() != "Released")
		return;
	g_clicks++;
	char buf[40];
	g_label.text(Str(buf, with_n(buf, "Pressed ", g_clicks)));
	log_n("the button was released: presses ", g_clicks);
	const Str shown = g_label.text();
	char line[80] = "the button reads: ";
	unsigned int l = 18;
	for(unsigned int i = 0; i < shown.size && l < sizeof line; i++)
		line[l++] = shown.data[i];
	log(Str(line, l));
	char data[1] = {(char)('0' + g_clicks % 10)};
	buildat_send_packet("click", 5, data, 1);
}

static void on_packet(const Event &e)
{
	char line[200];
	const char head[] = "the server answered ";
	unsigned int l = 0;
	for(unsigned int i = 0; i < sizeof head - 1; i++)
		line[l++] = head[i];
	const Str name = e.name(), data = e.packet_data();
	for(unsigned int i = 0; i < name.size && l < 100; i++)
		line[l++] = name.data[i];
	line[l++] = ':';
	line[l++] = ' ';
	for(unsigned int i = 0; i < data.size && l < sizeof line; i++)
		line[l++] = data.data[i];
	log(Str(line, l));
}

// The refusals, one a frame, each its own frame() call since a refusal is
// a trap that ends it. An attempt that returns got through, unless what
// it returned is a refusal of the call's own (false or nil, as
// sandbox_test's reached() reads one).
static int g_attempt;
static const char *const ATTEMPTS[] = {
	"cache:Exists an absolute path",
	"cache:GetResource an absolute path",
	"cache:Exists a parent-traversal path",
	"set the UI's scale",
	"a Node's handle as a UIElement",
	"a forged handle",
	"a dropped handle",
	"an event not on the whitelist",
	"a constant that is a class",
	"values that do not parse",
	"results past the buffer",
};
static const int ATTEMPT_COUNT = sizeof ATTEMPTS / sizeof ATTEMPTS[0];
static int g_got_through;

static void refuse()
{
	if(g_attempt > ATTEMPT_COUNT)
		return;
	const int k = g_attempt++;
	if(k == ATTEMPT_COUNT){
		char buf[80];
		unsigned int l = with_n(buf, "refusals: tried ", ATTEMPT_COUNT);
		l += with_n(buf + l, ", got through: ", g_got_through);
		log(Str(buf, l));
		return;
	}
	char line[120] = "refusal: ";
	unsigned int l = 9;
	for(const char *s = ATTEMPTS[k]; *s && l < sizeof line; s++)
		line[l++] = *s;
	log(Str(line, l));
	Value v;
	v.kind = Value::BOOLEAN;
	v.boolean = true;
	switch(k){
	case 0: v = cache().Exists("/etc/hostname"); break;
	case 1: v = cache().GetResource("Image", "/etc/hostname"); break;
	case 2: v = cache().Exists("....//....//....//....//etc/hostname"); break;
	case 3: ui().scale(0.25); break;
	case 4: {
		UIElement fake(g_camera.handle());
		fake.SetStyleAuto();
		fake.release();
		break; }
	case 5: Node(0x7f0003ffu).position(); break;
	case 6: {
		Node made = Node::new_();
		const unsigned int h = made.handle();
		made.reset();
		Node(h).position();
		break; }
	case 7: SubscribeToEvent(g_button, "NotAnEvent"); break;
	case 8: constant("Node"); break;
	case 9: {
		static const unsigned char garbage[] = {200, 9, 9, 9};
		unsigned char out[16];
		buildat_c_Node_get_position(garbage, sizeof garbage, out, sizeof out);
		break; }
	case 10: {
		unsigned char none[1] = {0}, out[1];
		buildat_c_global_ui(none, 1, out, 1);
		break; }
	}
	if(v.kind == Value::NIL || (v.kind == Value::BOOLEAN && !v.boolean)){
		log("refusal: refused by its answer");
		return;
	}
	g_got_through++;
	log_n("refusal: GOT THROUGH, attempt ", k);
}

BUILDAT_WASM_EXPORT const char *packets(void)
{
	return "echo";
}

BUILDAT_WASM_EXPORT void frame(float dt)
{
	Event e;
	while(next_event(e)){
		switch(e.kind){
		case BUILDAT_EVENT_START:
			on_start(e);
			break;
		case BUILDAT_EVENT_KEY_DOWN:
			if(e.word(1) == 32 && !e.word(2) && g_cube){
				g_colour++;
				draw_cube();
				log_n("space: the colour is now ", g_colour % 3);
				char data[1] = {(char)('0' + g_colour % 3)};
				buildat_send_packet("key", 3, data, 1);
			}
			break;
		case BUILDAT_EVENT_OBJECT:
			on_object(e);
			break;
		case BUILDAT_EVENT_PACKET:
			on_packet(e);
			break;
		}
	}
	if(!g_cube)
		return;
	refuse();
	g_time += dt;
	// A turn about y, half an angle a second, through the bindings
	const float h = g_time * 0.5f;
	g_cube.rotation(Quaternion{sin_near(h + 1.5707963f), 0, sin_near(h), 0});
}
