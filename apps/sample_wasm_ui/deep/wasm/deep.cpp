// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_wasm_ui: [WASM_BINDING_STACK] bindings called at the bottom
// of a recursion near the call depth limit, of frames near the client's
// cap on a native frame: a binding runs on the module's native stack,
// below the 2000 frames. Started by the d key, a stage a frame; the w key
// sweeps the depth limit, the c key makes 12000 nodes in chains.
#include "interface/buildat_client.h"

using namespace buildat;

static Node g_camera;
static int g_stage = -1, g_limit;

static void log_n(const char *text, int n)
{
	char buf[160];
	unsigned int l = 0;
	while(text[l] && l < 100){
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
	log(Str(buf, l));
}

// Frames of about 2 KiB natively, as apps/sample_wasm's recurse_held:
// 240 values held across each call
static long long held[250];
static void (*volatile g_bottom)();
static int (*volatile again)(int, int);
static volatile int g_deepest;
#define HOLD(i) long long h##i = held[i] * n;
#define FOLD(i) s = (s ^ h##i) * 3 + 1;
#define TEN(M, p) M(p##0) M(p##1) M(p##2) M(p##3) M(p##4) \
		M(p##5) M(p##6) M(p##7) M(p##8) M(p##9)
#define ALL(M) TEN(M, 1) TEN(M, 2) TEN(M, 3) TEN(M, 4) TEN(M, 5) TEN(M, 6) \
		TEN(M, 7) TEN(M, 8) TEN(M, 9) TEN(M, 10) TEN(M, 11) TEN(M, 12) \
		TEN(M, 13) TEN(M, 14) TEN(M, 15) TEN(M, 16) TEN(M, 17) TEN(M, 18) \
		TEN(M, 19) TEN(M, 20) TEN(M, 21) TEN(M, 22) TEN(M, 23) TEN(M, 24)
static int recurse(int n, int to)
{
	g_deepest = n;
	if(n >= to){
		g_bottom();
		return 0;
	}
	ALL(HOLD)
	held[n % 250] = n;
	long long s = again(n + 1, to);
	ALL(FOLD)
	return (int)s;
}
static void at_depth(int to, void (*f)())
{
	again = recurse;
	g_bottom = f;
	recurse(0, to);
}

static UIElement root_styled()
{
	UIElement root = ui().root();
	root.defaultStyle(cache().GetResource("XMLFile", "UI/DefaultStyle.xml").
			as<XMLFile>());
	return root;
}

static void style()
{
	UIElement root = root_styled();
	const char *const kinds[] = {"Window", "ListView", "DropDownList",
			"ScrollView", "LineEdit", "Slider", "CheckBox", "Menu"};
	for(const char *k : kinds){
		log(k);
		UIElement e = root.CreateChild(k).as<UIElement>();
		e.SetStyleAuto();
		e.Remove();
	}
}

static void text()
{
	UIElement root = root_styled();
	Text t = root.CreateChild("Text").as<Text>();
	t.SetStyleAuto();
	t.SetFont(cache().GetResource("Font", "Fonts/BlueHighway.ttf").as<Font>(), 40);
	t.text("The quick brown fox jumps over the lazy dog 0123456789");
	t.Remove();
}

static void resources()
{
	const char *const r[][2] = {
		{"Image", "Textures/StoneDiffuse.png"},
		{"Image", "Textures/Jack_face.jpg"},
		{"Model", "Models/Jack.mdl"},
		{"Material", "Materials/StoneTiled.xml"},
		{"Texture2D", "Textures/LogoLarge.png"},
		{"XMLFile", "RenderPaths/PBRDeferred.xml"},
		{"Font", "Fonts/Anonymous Pro.ttf"},
		{"Technique", "Techniques/DiffNormalSpecEmissive.xml"},
	};
	for(auto &p : r){
		log(p[1]);
		Value v = cache().GetResource(p[0], p[1]);
		log(v.kind == Value::OBJECT ? "  loaded" : "  not loaded");
	}
}

static void layout()
{
	UIElement root = root_styled();
	UIElement w = root.CreateChild("Window").as<UIElement>();
	w.SetStyleAuto();
	for(int i = 0; i < 20; i++){
		UIElement b = w.CreateChild("Button").as<UIElement>();
		b.SetStyleAuto();
		UIElement t = b.CreateChild("Text").as<UIElement>();
		t.SetStyleAuto();
	}
	w.Remove();
}

static void focus()
{
	UIElement root = root_styled();
	UIElement e = root.CreateChild("LineEdit").as<UIElement>();
	e.SetStyleAuto();
	e.SetFocus(true);
	e.SetFocus(false);
	e.Remove();
}

static int g_chain_n;
static Node g_chain_root, g_chain_leaf;
static void make_chain(int n)
{
	g_chain_n = n;
	g_chain_root = g_camera.CreateChild("deep_chain").as<Node>();
	Node cur = g_chain_root.CreateChild("c").as<Node>();
	for(int i = 1; i < n; i++){
		cur = cur.CreateChild("c").as<Node>();
		if(i % 250 == 0 && n > 1000)
			log_n("chain ", i);
	}
	g_chain_leaf = static_cast<Node&&>(cur);
}
static void chain_ops()
{
	log_n("chain GetWorldPosition, n ", g_chain_n);
	g_chain_leaf.GetWorldPosition();
	log_n("chain Clone, n ", g_chain_n);
	Node c = g_chain_root.Clone().as<Node>();
	log_n("chain Remove clone, n ", g_chain_n);
	c.Remove();
	c.reset();
}
static void chain_leaf_pos()
{
	g_chain_leaf.GetWorldPosition();
}

static void listview()
{
	UIElement root = root_styled();
	UIElement e = root.CreateChild("DropDownList").as<UIElement>();
	e.SetStyleAuto();
	e.Remove();
}

static void stage(int k)
{
	switch(k){
	case 0: log("stage style"); style(); break;
	case 1: log("stage text"); text(); break;
	case 2: log("stage resources"); resources(); break;
	case 3: log("stage layout"); layout(); break;
	case 4: log("stage focus"); focus(); break;
	case 5: make_chain(100); log("stage chain 100"); chain_ops(); break;
	case 6: break;
	case 7: log("stage deep style"); at_depth(1990, style); break;
	case 8: log("stage deep dropdown"); at_depth(1990, listview); break;
	case 9: log("stage deep chain 100"); at_depth(1990, chain_leaf_pos); break;
	case 10: log("deep: done"); g_stage = -1; return;
	case 40: log("stage limit"); g_deepest = 0; at_depth(1 << 30, listview); break;
	case 41: g_limit = g_deepest; log_n("deep: limit ", g_limit); break;
	default:
		// c: chains of 1000 under the camera, one a frame, each node's
		// wrapper dropped for the next; the client crashed in hold_ref
		// after about 4000, its scene collected under them ([HOLD_REF_UAF]).
		// All 12 are still on the camera at the end.
		if(k >= 200 && k < 200 + 12){
			make_chain(1000);
			return;
		}
		if(k == 200 + 12){
			log_n("deep: chains done, on the camera ", (int)g_camera.GetNumChildren());
			g_stage = -1;
			return;
		}
		if(k > 41 && k < 42 + 60){
			log_n("deep: sweep at ", g_limit - (k - 42));
			at_depth(g_limit - (k - 42), listview);
			break;
		}
		if(k == 42 + 60){
			UIElement root = ui().root();
			log_n("deep: alive, root width ", root.size().x);
		}
		log("deep: done"); g_stage = -1; return;
	}
	log_n("deep: stage done ", k);
	log_n("deep: deepest ", g_deepest);
}

BUILDAT_WASM_EXPORT void frame(float dt)
{
	(void)dt;
	Event e;
	while(next_event(e)){
		if(e.kind == BUILDAT_EVENT_START)
			g_camera = Node((unsigned int)e.word(1));
		else if(e.kind == BUILDAT_EVENT_KEY_DOWN && !e.word(2) && g_stage < 0)
			g_stage = e.word(1) == 'd' ? 0 :
					e.word(1) == 'w' ? 40 :
					e.word(1) == 'c' ? 200 : -1;
	}
	// Past a stage that traps, too
	if(g_stage >= 0){
		const int k = g_stage++;
		stage(k);
	}
}
