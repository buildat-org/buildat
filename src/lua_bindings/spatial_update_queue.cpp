// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include "interface/os.h"
#include <tolua++.h>
#include <Vector3.h>
#include <cassert>
#include <map>
#include <unordered_map>
#define MODULE "lua_bindings"

#define DEF_METHOD(name){ \
		lua_pushcfunction(L, guarded<l_##name>); \
		lua_setfield(L, -2, #name); \
}

#define GET_TOLUA_STUFF(result_name, index, type) \
	if(!tolua_isusertype(L, index, #type, 0, &tolua_err)){ \
		tolua_error(L, __PRETTY_FUNCTION__, &tolua_err); \
		return 0; \
	} \
	type *result_name = (type*)tolua_tousertype(L, index, 0);
#define TRY_GET_TOLUA_STUFF(result_name, index, type) \
	type *result_name = nullptr; \
	if(tolua_isusertype(L, index, #type, 0, &tolua_err)){ \
		result_name = (type*)tolua_tousertype(L, index, 0); \
	}

// Just do this; Urho3D's stuff doesn't really clash with anything in buildat
using namespace Urho3D;

namespace lua_bindings {

struct SpatialUpdateQueue
{
	struct Value {
		ss_ type;
		uint32_t node_id = -1;

		bool operator==(const Value &other) const {
			return node_id == other.node_id && type == other.type;
		}
	};

	struct ValueHash {
		size_t operator()(const Value &v) const {
			return std::hash<ss_>()(v.type) ^
					(std::hash<uint32_t>()(v.node_id) * 2654435761u);
		}
	};

	struct Item { // Queue item
		Vector3 p = Vector3(0, 0, 0);
		Value value;
		float near_weight = -1.0f;
		float near_trigger_d = -1.0f;
		float far_weight = -1.0f;
		float far_trigger_d = -1.0f;
		// **The player did this** (user, 2026-09-26): a change the player
		// caused -- a dig, a place, the light either moves -- is what they
		// are waiting to see, and it outranks the world's own churn at the
		// same distance.
		bool player = false;
		// The last scoring, for find() and the peek accessors to report
		float f = -1.0f;
		float fw = -1.0f;
	};

	// **The order is read when an item is picked, not when it is put**
	// (user, 2026-09-26: "the insertion priority can be wrong by the time
	// it's being processed"). It used to be a multimap keyed at insertion,
	// with a full re-put of every item whenever the camera had moved more
	// than 20 units -- a sort of thousands of items at a hundred a frame,
	// which took a second, could not be restarted inside that second, and
	// left a chunk 39 away queued as 466 away ([MISSING_CHUNK]). A set and
	// a scan for the best against the current position has no sort to
	// restart and no threshold to be wrong inside of.
	sv_<Item> m_items;
	// Where each value sits in m_items, so a re-put finds it without a walk
	std::unordered_map<Value, size_t, ValueHash> m_index;
	Vector3 m_p;
	// Where the camera looks, for the frustum term; -Z until told otherwise,
	// which is what leaves the self-check's items on +X unfavoured
	Vector3 m_dir = Vector3(0, 0, -1);
	// The best item as of the last scan, and whether that scan still holds
	size_t m_best = 0;
	bool m_best_valid = false;

	// How much being the player's own change, and being in front of them,
	// are worth. Divisors of fw, which is "smaller is sooner".
	static constexpr float PLAYER_FW_DIV = 8.0f;
	static constexpr float VIEW_FW_DIV = 2.0f;
	// Inside this the camera can be standing on it, and which way it looks
	// says nothing
	static constexpr float VIEW_NEAR_D = 16.0f;

	// What an item is worth right now: the same near/far triggers as ever,
	// then the two factors above.
	void score(Item &item) const
	{
		Vector3 d3 = item.p - m_p;
		float d = d3.Length();
		item.f = -1.0f;
		item.fw = -1.0f;
		if(item.near_trigger_d != -1.0f){
			float f_near = d / item.near_trigger_d;
			float fw_near = f_near / item.near_weight;
			if(item.fw == -1.0f || (fw_near < item.fw &&
					(item.f == -1.0f || f_near < item.f))){
				item.f = f_near;
				item.fw = fw_near;
			}
		}
		if(item.far_trigger_d != -1.0f){
			float f_far = item.far_trigger_d / d;
			float fw_far = f_far / item.far_weight;
			if(item.fw == -1.0f || (fw_far < item.fw &&
					(item.f == -1.0f || f_far < item.f))){
				item.f = f_far;
				item.fw = fw_far;
			}
		}
		if(item.f == -1.0f || item.fw == -1.0f)
			throw Exception("item.f == -1.0f || item.fw == -1.0f");
		if(item.player)
			item.fw /= PLAYER_FW_DIV;
		if(d <= VIEW_NEAR_D ||
				(d > 0.0001f && d3.DotProduct(m_dir) / d >= 0.5f))
			item.fw /= VIEW_FW_DIV;
	}

	// Due (f <= 1) before not due, and among those the smallest fw
	static bool better(const Item &a, const Item &b)
	{
		bool a_due = a.f <= 1.0f, b_due = b.f <= 1.0f;
		if(a_due != b_due)
			return a_due;
		return a.fw < b.fw;
	}

	// One scan a pick; the scores are this moment's
	void rescan()
	{
		if(m_best_valid || m_items.empty())
			return;
		for(size_t i = 0; i < m_items.size(); i++)
			score(m_items[i]);
		size_t best = 0;
		for(size_t i = 1; i < m_items.size(); i++){
			if(better(m_items[i], m_items[best]))
				best = i;
		}
		m_best = best;
		m_best_valid = true;
	}

	void set_p(const Vector3 &p)
	{
		if(p != m_p){
			m_p = p;
			m_best_valid = false;
		}
	}

	void set_dir(const Vector3 &dir)
	{
		if(dir != m_dir){
			m_dir = dir;
			m_best_valid = false;
		}
	}

	void put_item(Item &item)
	{
		if(item.near_trigger_d == -1.0f && item.far_trigger_d == -1.0f)
			throw Exception("Item has neither trigger");
		score(item);
		auto index_it = m_index.find(item.value);
		if(index_it != m_index.end()){
			Item &have = m_items[index_it->second];
			// The player having asked for it is not forgotten by a later
			// put that did not come from them
			item.player = item.player || have.player;
			score(item);
			score(have);
			// The more important of the two stands, as it always has: a
			// put that is worth less than what is already waiting changes
			// nothing but the flag above
			if(better(item, have))
				have = item;
			else
				have.player = item.player;
			m_best_valid = false;
			return;
		}
		m_index[item.value] = m_items.size();
		m_items.push_back(item);
		m_best_valid = false;
	}

	void put(const Vector3 &p, float near_weight, float near_trigger_d,
			float far_weight, float far_trigger_d, const Value &value,
			bool player = false)
	{
		Item item;
		item.p = p;
		item.near_weight = near_weight;
		item.near_trigger_d = near_trigger_d;
		item.far_weight = far_weight;
		item.far_trigger_d = far_trigger_d;
		item.value = value;
		item.player = player;
		put_item(item);
	}

	bool empty()
	{
		return m_items.empty();
	}

	// The item for a value, or nullptr: what a chunk that never comes up
	// is waiting as ([MISSING_CHUNK]). Scored as of now.
	const Item* find(const Value &value)
	{
		auto it = m_index.find(value);
		if(it == m_index.end())
			return nullptr;
		Item &item = m_items[it->second];
		score(item);
		return &item;
	}

	void pop()
	{
		if(m_items.empty())
			throw Exception("SpatialUpdateQueue::pop(): Empty");
		rescan();
		size_t i = m_best;
		m_index.erase(m_items[i].value);
		// The last item takes its place, and its index with it
		size_t last = m_items.size() - 1;
		if(i != last){
			m_items[i] = m_items[last];
			m_index[m_items[i].value] = i;
		}
		m_items.pop_back();
		m_best_valid = false;
	}

	Value& get_value()
	{
		if(m_items.empty())
			throw Exception("SpatialUpdateQueue::get_value(): Empty");
		rescan();
		return m_items[m_best].value;
	}

	float get_f()
	{
		if(m_items.empty())
			throw Exception("SpatialUpdateQueue::get_f(): Empty");
		rescan();
		return m_items[m_best].f;
	}

	float get_fw()
	{
		if(m_items.empty())
			throw Exception("SpatialUpdateQueue::get_fw(): Empty");
		rescan();
		return m_items[m_best].fw;
	}

	size_t get_length()
	{
		return m_items.size();
	}
};

// The queue decides the order chunks are meshed in, and a silent ordering or
// replacement bug there shows up only as chunks meshing late. Runs at startup;
// it is a few microseconds.
static void self_check()
{
	auto item_value = [](const char *type, uint32_t node_id){
		SpatialUpdateQueue::Value v;
		v.type = type;
		v.node_id = node_id;
		return v;
	};

	// Whichever is closest to its near trigger comes first, and f > 1 (not due
	// yet) goes behind f <= 1 whatever the weights say
	{
		SpatialUpdateQueue q;
		q.set_p(Vector3(0, 0, 0));
		q.put(Vector3(50, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1)); // f = 0.5
		q.put(Vector3(10, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 2)); // f = 0.1
		q.put(Vector3(200, 0, 0), 0.01f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 3)); // f = 2, lowest fw of the three
		assert(q.get_length() == 3);
		assert(q.get_value().node_id == 2);
		q.pop();
		assert(q.get_value().node_id == 1);
		q.pop();
		assert(q.get_value().node_id == 3);
		q.pop();
		assert(q.empty());
	}

	// The same value put twice is one item: the more important put wins,
	// whichever order the two come in
	{
		SpatialUpdateQueue q;
		q.set_p(Vector3(0, 0, 0));
		q.put(Vector3(50, 0, 0), 0.1f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1)); // fw = 5
		q.put(Vector3(50, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1)); // fw = 0.5, more important
		assert(q.get_length() == 1);
		assert(q.get_fw() < 1.0f);
		q.put(Vector3(50, 0, 0), 0.1f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1)); // less important, discarded
		assert(q.get_length() == 1);
		assert(q.get_fw() < 1.0f);
		// Same node, other type, is a different value
		q.put(Vector3(50, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("physics", 1));
		assert(q.get_length() == 2);
	}

	// **The order follows the camera** (user, 2026-09-26): the same two
	// items come out in the other order once it has moved, with nothing
	// re-put and no threshold to cross
	{
		SpatialUpdateQueue q;
		q.set_p(Vector3(0, 0, 0));
		q.put(Vector3(0, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1));
		q.put(Vector3(500, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 2));
		assert(q.get_value().node_id == 1);
		q.set_p(Vector3(500, 0, 0));
		assert(q.get_length() == 2); // Nothing is waiting to be re-put
		assert(q.get_value().node_id == 2);
		// And one step of a walk is enough; it does not wait for twenty
		q.set_p(Vector3(200, 0, 0));
		assert(q.get_value().node_id == 1);
		q.set_p(Vector3(300, 0, 0));
		assert(q.get_value().node_id == 2);
	}

	// **The player's own change comes first** even from further away.
	// Both are outside VIEW_NEAR_D and off the camera's axis, so neither
	// takes the view term and what is left is the player term.
	{
		SpatialUpdateQueue q;
		q.set_p(Vector3(0, 0, 0));
		q.put(Vector3(20, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1));
		q.put(Vector3(40, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 2), true); // the player dug it
		assert(q.get_value().node_id == 2);
		q.pop();
		assert(q.get_value().node_id == 1);
	}

	// A put that did not come from the player does not forget that an
	// earlier one did
	{
		SpatialUpdateQueue q;
		q.set_p(Vector3(0, 0, 0));
		q.put(Vector3(40, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 2), true);
		q.put(Vector3(40, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 2), false);
		q.put(Vector3(20, 0, 0), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1));
		assert(q.get_length() == 2);
		assert(q.get_value().node_id == 2);
	}

	// **What is in front of the camera comes before what is behind it**,
	// at the same distance
	{
		SpatialUpdateQueue q;
		q.set_p(Vector3(0, 0, 0));
		q.set_dir(Vector3(0, 0, -1));
		q.put(Vector3(0, 0, 40), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1)); // behind
		q.put(Vector3(0, 0, -40), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 2)); // in front
		assert(q.get_value().node_id == 2);
		// Turning round turns the order round with it
		q.set_dir(Vector3(0, 0, 1));
		assert(q.get_value().node_id == 1);
	}

	// **A queue of thousands drains**: the client takes items while the
	// head is due, so anything that can make a due item lose to one that
	// is not stops the world being drawn (2026-09-26: a rewrite of this
	// file left 3024 items standing and chunks undrawn after two
	// seconds).
	{
		SpatialUpdateQueue q;
		q.set_p(Vector3(0, 0, 0));
		q.set_dir(Vector3(0, 0, -1));
		for(int i = 0; i < 3000; i++){
			// Spread over a shell the near trigger reaches, as the world's
			// chunks are
			float x = (float)(i % 30) * 10.0f - 150.0f;
			float y = (float)((i / 30) % 10) * 10.0f;
			float z = (float)(i / 300) * 10.0f - 50.0f;
			q.put(Vector3(x, y, z), 1.0f, 1000.0f, -1.0f, -1.0f,
					item_value("geometry", (uint32_t)i + 1));
		}
		assert(q.get_length() == 3000);
		size_t taken = 0;
		while(!q.empty() && q.get_f() <= 1.0f){
			q.pop();
			taken++;
		}
		assert(taken == 3000);
		assert(q.empty());
	}

	// Near enough and which way the camera looks says nothing: the player
	// can be standing on it
	{
		SpatialUpdateQueue q;
		q.set_p(Vector3(0, 0, 0));
		q.set_dir(Vector3(0, 0, -1));
		q.put(Vector3(0, 0, 8), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 1)); // behind, but underfoot
		q.put(Vector3(0, 0, -30), 1.0f, 100.0f, -1.0f, -1.0f,
				item_value("geometry", 2)); // in front, further
		assert(q.get_value().node_id == 1);
	}
}

struct LuaSUQ
{
	static constexpr const char *class_name = "SpatialUpdateQueue";
	SpatialUpdateQueue internal;

	static int gc_object(lua_State *L){
		delete *(LuaSUQ**)(lua_touserdata(L, 1));
		return 0;
	}
	static int l_set_p(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		tolua_Error tolua_err;
		GET_TOLUA_STUFF(p, 2, Vector3);
		o->internal.set_p(*p);
		return 0;
	}
	static int l_set_dir(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		tolua_Error tolua_err;
		GET_TOLUA_STUFF(dir, 2, Vector3);
		o->internal.set_dir(*dir);
		return 0;
	}
	static int l_put(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		tolua_Error tolua_err;
		GET_TOLUA_STUFF(p, 2, Vector3);
		float near_weight = (lua_type(L, 3) == LUA_TNIL) ?
				-1.0f : luaL_checknumber(L, 3);
		float near_trigger_d = (lua_type(L, 4) == LUA_TNIL) ?
				-1.0f : luaL_checknumber(L, 4);
		float far_weight = (lua_type(L, 5) == LUA_TNIL) ?
				-1.0f : luaL_checknumber(L, 5);
		float far_trigger_d = (lua_type(L, 6) == LUA_TNIL) ?
				-1.0f : luaL_checknumber(L, 6);
		luaL_checktype(L, 7, LUA_TTABLE);
		SpatialUpdateQueue::Value value;
		// **The table by its own index and not by the top of the stack**
		// (2026-09-26): these read -1, which was the table only while it
		// was the last argument. An eighth argument made the top a
		// boolean, every put raised "unknown C++ exception in a binding",
		// and the world stopped being drawn -- with an empty queue, which
		// is what made it look like a starving one.
		lua_getfield(L, 7, "type");
		value.type = luaL_checkstring(L, -1);
		lua_pop(L, 1);
		lua_getfield(L, 7, "node_id");
		value.node_id = luaL_checkinteger(L, -1);
		lua_pop(L, 1);
		// The eighth is "the player caused this", which outranks the
		// world's own churn at the same distance
		bool player = (lua_type(L, 8) != LUA_TNIL) && lua_toboolean(L, 8);
		o->internal.put(*p, near_weight, near_trigger_d,
				far_weight, far_trigger_d, value, player);
		return 0;
	}
	static int l_get(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		if(o->internal.empty())
			return 0;
		SpatialUpdateQueue::Value &value = o->internal.get_value();
		lua_newtable(L);
		lua_pushstring(L, value.type.c_str());
		lua_setfield(L, -2, "type");
		lua_pushinteger(L, value.node_id);
		lua_setfield(L, -2, "node_id");
		o->internal.pop();
		return 1;
	}
	// The front item without popping it ([MISSING_CHUNK]: a queue that
	// pops nothing while chunks are undrawn names what it holds)
	static int l_peek_next_value(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		if(o->internal.empty())
			return 0;
		SpatialUpdateQueue::Value &value = o->internal.get_value();
		lua_newtable(L);
		lua_pushstring(L, value.type.c_str());
		lua_setfield(L, -2, "type");
		lua_pushinteger(L, value.node_id);
		lua_setfield(L, -2, "node_id");
		return 1;
	}
	// find(type, node_id) -> f, fw, px, py, pz (the position the item was
	// put with), or nil when the queue holds no such item (mid-sort ones
	// included)
	static int l_find(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		SpatialUpdateQueue::Value value;
		value.type = luaL_checkstring(L, 2);
		value.node_id = luaL_checkinteger(L, 3);
		const SpatialUpdateQueue::Item *item = o->internal.find(value);
		if(!item)
			return 0;
		lua_pushnumber(L, item->f);
		lua_pushnumber(L, item->fw);
		lua_pushnumber(L, item->p.x_);
		lua_pushnumber(L, item->p.y_);
		lua_pushnumber(L, item->p.z_);
		return 5;
	}
	static int l_peek_next_f(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		if(o->internal.empty())
			return 0;
		float v = o->internal.get_f();
		lua_pushnumber(L, v);
		return 1;
	}
	static int l_peek_next_fw(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		if(o->internal.empty())
			return 0;
		float v = o->internal.get_fw();
		lua_pushnumber(L, v);
		return 1;
	}
	static int l_get_length(lua_State *L){
		LuaSUQ *o = internal_checkobject(L, 1);
		int l = o->internal.get_length();
		lua_pushinteger(L, l);
		return 1;
	}

	static LuaSUQ* internal_checkobject(lua_State *L, int narg){
		luaL_checktype(L, narg, LUA_TUSERDATA);
		void *ud = luaL_checkudata(L, narg, class_name);
		if(!ud) luaL_typerror(L, narg, class_name);
		return *(LuaSUQ**)ud;
	}
	static int l_create(lua_State *L){
		LuaSUQ *o = new LuaSUQ();
		*(void**)(lua_newuserdata(L, sizeof(void*))) = o;
		luaL_getmetatable(L, class_name);
		lua_setmetatable(L, -2);
		return 1;
	}
	static void register_metatable(lua_State *L){
		lua_newtable(L);
		int method_table_L = lua_gettop(L);
		luaL_newmetatable(L, class_name);
		int metatable_L = lua_gettop(L);

		// hide metatable from Lua getmetatable()
		lua_pushliteral(L, "__metatable");
		lua_pushvalue(L, method_table_L);
		lua_settable(L, metatable_L);

		lua_pushliteral(L, "__index");
		lua_pushvalue(L, method_table_L);
		lua_settable(L, metatable_L);

		lua_pushliteral(L, "__gc");
		lua_pushcfunction(L, gc_object);
		lua_settable(L, metatable_L);

		lua_pop(L, 1); // drop metatable_L

		// fill method_table_L
		DEF_METHOD(set_p);
		DEF_METHOD(set_dir);
		DEF_METHOD(put);
		DEF_METHOD(get);
		DEF_METHOD(peek_next_f);
		DEF_METHOD(peek_next_fw);
		DEF_METHOD(peek_next_value);
		DEF_METHOD(find);
		DEF_METHOD(get_length);

		// drop method_table_L
		lua_pop(L, 1);
	}
};

static int l_SpatialUpdateQueue(lua_State *L)
{
	return LuaSUQ::l_create(L);
}

void init_spatial_update_queue(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, guarded<l_##name>); \
		lua_setglobal(L, "__buildat_" #name); \
}
	self_check();

	LuaSUQ::register_metatable(L);

	DEF_BUILDAT_FUNC(SpatialUpdateQueue);
}

} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
