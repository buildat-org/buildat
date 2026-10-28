// Buildat: apps/skeldat/main/game.h
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// skeldat's rules as data, and the inventory and the crafting that work on
// them: skelenti's Luanti game (apps/demo_skelenti/main/game/mods/skelenti/
// init.lua) written out in C++ ([SKELDAT]). Nothing here knows the engine,
// so the self test at the bottom runs with plain g++:
//
//   g++ -std=c++11 -Isrc -DSKELDAT_GAME_TEST -x c++
//       apps/skeldat/main/game.h -o /tmp/skeldat_game && /tmp/skeldat_game
//   (one line)
#pragma once
#include "core/types.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <sstream>

namespace skeldat
{

// What a tool digs and how fast: seconds by the node's rating in the group
// (1 hardest, 3 softest), 0 where it cannot
struct Cap
{
	ss_ group;
	float times[4] = {0, 0, 0, 0};
	int uses = 0; // 0: never wears out
};

struct ItemDef
{
	ss_ name, desc, image;
	int stack_max = 99;
	bool tool = false;
	sv_<Cap> caps;
	int fleshy = 1;  // the hit's damage
	int eat = 0;     // hit points an eat gives back
	bool node = false;
};

// GAS: a mining hazard's gas ([SKELDAT_MINING_HAZARDS]), drawn translucent,
// walked and seen through, its share in param2
enum Shape { CUBE, ALLFACES, LIQUID, NODEBOX, TORCH, GAS };

struct NodeDef
{
	ss_ name, desc;
	// +Y, -Y, +X, -X, +Z, -Z, as Luanti and the voxel mesher have them
	ss_ tiles[6];
	sm_<ss_, int> groups;
	// "" drops itself, "-" nothing, else "name [count]"; leaves are a
	// chance (drop_rarity) of their drop and nothing otherwise
	ss_ drop;
	int drop_rarity = 0;
	Shape shape = CUBE;
	// A node box in sixteenths, six numbers a box
	sv_<float> boxes;
	bool facedir = false;
	// Turned to the face it is on, six ways (Luanti's wallmounted: param2
	// 0 +y, 1 -y, 2 +x, 3 -x, 4 +z, 5 -z), the box made for the floor
	bool wallmounted = false;
	bool walkable = true;
	int light_source = 0;
	bool falling = false;
	// A liquid of constant volume ([SKELDAT_MINING_HAZARDS]): its volume in
	// param2, 0..7 for 1..8 eighths, drawn at that level (Luanti's flowing
	// liquid's); the generator's water is a still source
	bool flowing = false;
};

struct Recipe
{
	ss_ output;   // "name [count]"
	int width = 0; // 0: shapeless
	sv_<ss_> items; // row by row, "" for empty
};

struct Cooking { ss_ input, output; float time; };

struct Stack
{
	ss_ name;
	int count = 0;
	int wear = 0;

	Stack(){}
	Stack(const ss_ &name, int count = 1, int wear = 0):
		name(count > 0 ? name : ""), count(name.empty() ? 0 : count),
		wear(wear){}
	bool empty() const { return count <= 0 || name.empty(); }
	// Luanti's item string: "name count wear", the trailing ones left out
	ss_ str() const {
		if(empty())
			return "";
		ss_ s = name;
		if(count != 1 || wear != 0)
			s += " " + std::to_string(count);
		if(wear != 0)
			s += " " + std::to_string(wear);
		return s;
	}
	static Stack parse(const ss_ &s){
		std::istringstream is(s);
		Stack st;
		is>>st.name;
		st.count = 1;
		is>>st.count>>st.wear;
		if(st.name.empty() || st.count <= 0)
			return Stack();
		return st;
	}
	Stack take(int n){
		n = std::min(n, count);
		Stack out(name, n, wear);
		count -= n;
		if(count <= 0)
			*this = Stack();
		return out;
	}
};

static const int WEAR_MAX = 65535;

struct Game
{
	sv_<NodeDef> nodes;   // index + 1 is the voxel id
	sm_<ss_, ItemDef> items;
	ItemDef hand;
	sv_<Recipe> recipes;
	sv_<Cooking> cooking;
	sm_<ss_, float> fuel;

	const NodeDef* node(const ss_ &name) const {
		for(const NodeDef &n : nodes)
			if(n.name == name)
				return &n;
		return nullptr;
	}
	const ItemDef* item(const ss_ &name) const {
		auto it = items.find(name);
		return it == items.end() ? nullptr : &it->second;
	}
	int stack_max(const ss_ &name) const {
		const ItemDef *d = item(name);
		return d ? d->stack_max : 99;
	}

	// How long the item takes to dig the node, and the cap that does it;
	// < 0 where it cannot. The hand's caps where the tool has none for it,
	// as Luanti falls back.
	float dig_time(const ss_ &tool, const NodeDef &n, const Cap **cap_out =
			nullptr) const {
		const ItemDef *d = item(tool);
		for(const ItemDef *t : {d, &hand}){
			if(!t)
				continue;
			for(const Cap &c : t->caps){
				auto g = n.groups.find(c.group);
				if(g == n.groups.end() || g->second < 1 || g->second > 3)
					continue;
				const float time = c.times[g->second];
				if(time > 0){
					if(cap_out)
						*cap_out = t == &hand ? nullptr : &c;
					return time;
				}
			}
		}
		return -1;
	}

	// The craft the 3x3 grid makes, or nullptr
	const Recipe* craft(const Stack grid[9]) const {
		int x0 = 3, y0 = 3, x1 = -1, y1 = -1;
		sv_<ss_> names;
		for(int i = 0; i < 9; i++){
			if(grid[i].empty())
				continue;
			x0 = std::min(x0, i % 3); x1 = std::max(x1, i % 3);
			y0 = std::min(y0, i / 3); y1 = std::max(y1, i / 3);
			names.push_back(grid[i].name);
		}
		if(names.empty())
			return nullptr;
		std::sort(names.begin(), names.end());
		for(const Recipe &r : recipes){
			if(r.width == 0){
				sv_<ss_> want = r.items;
				std::sort(want.begin(), want.end());
				if(want == names)
					return &r;
				continue;
			}
			const int h = (int)r.items.size() / r.width;
			if(r.width != x1 - x0 + 1 || h != y1 - y0 + 1)
				continue;
			bool ok = true;
			for(int y = 0; y < h && ok; y++)
				for(int x = 0; x < r.width && ok; x++)
					ok = grid[(y0 + y) * 3 + x0 + x].name ==
							r.items[y * r.width + x];
			if(ok)
				return &r;
		}
		return nullptr;
	}

	const Cooking* cooks(const ss_ &input) const {
		for(const Cooking &c : cooking)
			if(c.input == input)
				return &c;
		return nullptr;
	}

	// Into a list: onto stacks of the same item first, then the empty
	// slots. What did not fit comes back.
	Stack add(sv_<Stack> &list, Stack st) const {
		const int max = stack_max(st.name);
		for(int pass = 0; pass < 2 && !st.empty(); pass++){
			for(Stack &s : list){
				if(st.empty())
					break;
				if(pass == 0 ? (s.empty() || s.name != st.name ||
						s.wear != st.wear) : !s.empty())
					continue;
				const int n = std::min(st.count, max - s.count);
				if(n <= 0)
					continue;
				Stack moved = st.take(n);
				if(s.empty())
					s = moved;
				else
					s.count += moved.count;
			}
		}
		return st;
	}

	// A count of one slot onto another, as Luanti moves: onto nothing or
	// the same item as far as it stacks; the whole stack onto another
	// item swaps them. false where nothing moved.
	bool move(Stack &from, Stack &to, int count) const {
		if(from.empty() || count <= 0 || &from == &to)
			return false;
		count = std::min(count, from.count);
		if(to.empty() || (to.name == from.name && to.wear == from.wear)){
			const int room = stack_max(from.name) - to.count;
			const int n = std::min(count, room);
			if(n <= 0)
				return false;
			Stack moved = from.take(n);
			if(to.empty())
				to = moved;
			else
				to.count += n;
			return true;
		}
		if(count != from.count)
			return false;
		std::swap(from, to);
		return true;
	}
};

// skelenti's game, as its init.lua has it
inline Game make_game()
{
	Game g;
	auto node = [&](const ss_ &name, const ss_ &desc,
			std::initializer_list<ss_> tiles,
			std::initializer_list<std::pair<const ss_, int>> groups,
			const ss_ &drop = "") -> NodeDef& {
		NodeDef n;
		n.name = "skeldat:" + name;
		n.desc = desc;
		// One tile is all six, three are top, bottom and the sides, as
		// Luanti spreads them
		sv_<ss_> t(tiles);
		for(int i = 0; i < 6; i++)
			n.tiles[i] = "main/" + t[std::min(i, (int)t.size() - 1)] + ".png";
		n.groups = groups;
		n.drop = drop;
		g.nodes.push_back(n);
		ItemDef d;
		d.name = n.name;
		d.desc = desc;
		d.image = n.tiles[2];
		d.node = true;
		g.items[d.name] = d;
		return g.nodes.back();
	};
	node("stone", "Stone", {"stone"}, {{"cracky", 3}, {"stone", 1}},
			"skeldat:cobble");
	node("cobble", "Cobblestone", {"cobble"}, {{"cracky", 3}, {"stone", 1}});
	node("dirt", "Dirt", {"dirt"}, {{"crumbly", 3}, {"soil", 1}});
	node("grass", "Grass Block", {"grass_top", "dirt", "grass_side"},
			{{"crumbly", 3}, {"soil", 1}}, "skeldat:dirt");
	node("sand", "Sand", {"sand"}, {{"crumbly", 3}}).falling = true;
	node("gravel", "Gravel", {"gravel"}, {{"crumbly", 2}}).falling = true;
	node("tree", "Log", {"tree_top", "tree_top", "tree"},
			{{"choppy", 2}, {"tree", 1}});
	node("wood", "Planks", {"wood"}, {{"choppy", 3}, {"wood", 1}});
	{
		// [SKELDAT_APPLE_TREES] Its sapling now and then, nothing
		// otherwise: the apples are the apple trees' voxels
		NodeDef &n = node("leaves", "Leaves", {"leaves"},
				{{"snappy", 3}, {"leaves", 1}}, "skeldat:sapling");
		n.shape = ALLFACES;
		n.drop_rarity = 20;
	}
	{
		NodeDef &n = node("water_source", "Water", {"water"}, {}, "-");
		n.shape = LIQUID;
		// [SKELDAT_OWN_MAPGEN] All water in the liquid step: its volume in
		// param2, 1..7 eighths, 0 (an old world's) full
		n.flowing = true;
		g.items.erase(n.name);
	}
	node("coal_ore", "Coal Ore", {"coal_ore"}, {{"cracky", 3}},
			"skeldat:coal");
	node("iron_ore", "Iron Ore", {"iron_ore"}, {{"cracky", 2}});
	node("diamond_ore", "Diamond Ore", {"diamond_ore"}, {{"cracky", 1}},
			"skeldat:diamond");
	node("bone_block", "Bone Block", {"bone_block_top", "bone_block_top",
			"bone_block_side"}, {{"cracky", 2}});
	// The world's outermost column ([SKELDAT_EDGE_RIDGE]): the bone
	// block's look, no group a tool or the hand digs, not an item
	g.items.erase(node("bone_wall", "Bone Wall", {"bone_block_top",
			"bone_block_top", "bone_block_side"}, {}).name);
	// A skull, two, a bone: boxes in sixteenths, the face to -z
	auto bones = [&](const ss_ &name, const ss_ &desc, const ss_ &front,
			sv_<float> boxes, const ss_ &drop) {
		NodeDef &n = node(name, desc, {"skull", "skull", "skull", "skull",
				"skull", front}, {{"cracky", 3},
				{"oddly_breakable_by_hand", 3}}, drop);
		n.shape = NODEBOX;
		n.facedir = true;
		for(float &v : boxes)
			v /= 16;
		n.boxes = boxes;
		g.items[n.name].image = "main/skull_front.png";
	};
	bones("skull", "Skull", "skull_front",
			{-4, -6, -4, 4, 0, 4, -3, -8, -4, 3, -6, 1}, "");
	bones("skulls", "Skulls", "skulls_front",
			{-7, -8, -7, 1, -2, 1, 2, -8, -1, 7, -4, 4}, "skeldat:skull 2");
	bones("bone_lying", "Bone", "skull", {-6, -8, -1, 6, -6, 1,
			-8, -8, -2, -5, -5, 2, 5, -8, -2, 8, -5, 2}, "skeldat:bone");
	// A skeleton's mark where it saw a player ([SKELDAT_SKELETON_SIM]):
	// the skull in red, holding no bones; dug, itself
	{
		bones("marker_skull", "Marker Skull", "skull_front",
				{-4, -6, -4, 4, 0, 4, -3, -8, -4, 3, -6, 1}, "");
		NodeDef &n = g.nodes.back();
		for(ss_ &t : n.tiles)
			t = "main/marker_" + t.substr(5);
		g.items[n.name].image = "main/marker_skull_front.png";
	}
	// [SKELDAT_BOATS] Where skeletons take to boats: the skull in green;
	// dug, nothing; not an item
	{
		bones("green_skull", "Green Skull", "skull_front",
				{-4, -6, -4, 4, 0, 4, -3, -8, -4, 3, -6, 1}, "-");
		NodeDef &n = g.nodes.back();
		for(ss_ &t : n.tiles)
			t = "main/green_" + t.substr(5);
		g.items.erase(n.name);
	}
	// An arrow stuck for good ([SKELDAT_BOW]): the shaft out of the face
	// it went into, the head buried, two vanes; walked through, dug or
	// picked up as an arrow (main.cpp), not an item
	{
		NodeDef &n = node("stuck_arrow", "Arrow", {"stuck_arrow"},
				{{"dig_immediate", 3}}, "skeldat:arrow");
		n.shape = NODEBOX;
		n.wallmounted = true;
		n.walkable = false;
		n.boxes = {-0.5f, -8, -0.5f, 0.5f, 2, 0.5f, -2, 0, -0.25f, 2, 2, 0.25f,
				-0.25f, 0, -2, 0.25f, 2, 2};
		for(float &v : n.boxes)
			v /= 16;
		g.items.erase(n.name);
	}
	{
		NodeDef &n = node("torch", "Torch", {"torch"},
				{{"snappy", 3}, {"dig_immediate", 3}});
		n.shape = TORCH;
		n.light_source = 13;
		n.boxes = {-0.1f, -0.5f, -0.1f, 0.1f, 0.1f, 0.1f};
		g.items[n.name].image = "main/torch.png";
	}
	node("table", "Crafting Table", {"table_top", "wood", "table_side",
			"table_side", "table_side", "table_front"},
			{{"choppy", 2}}).facedir = true;
	node("furnace", "Furnace", {"furnace_top", "furnace_top", "furnace_side",
			"furnace_side", "furnace_side", "furnace_front"},
			{{"cracky", 3}}).facedir = true;
	{
		NodeDef &n = node("furnace_active", "Furnace", {"furnace_top",
				"furnace_top", "furnace_side", "furnace_side", "furnace_side",
				"furnace_front_active"}, {{"cracky", 3}}, "skeldat:furnace");
		n.facedir = true;
		n.light_source = 8;
		g.items.erase(n.name);
	}
	// A lantern ([SKELDAT_FIGHT_BACK]): coal in it, no bones grow near it
	// and those there fall (main.cpp); lit, it is the active one
	for(int lit = 0; lit < 2; lit++){
		const ss_ side = lit ? "lantern_active" : "lantern";
		NodeDef &n = node(lit ? "lantern_active" : "lantern", "Lantern",
				{"lantern_top", "lantern_top", side}, {{"cracky", 3},
				{"oddly_breakable_by_hand", 3}}, lit ? "skeldat:lantern" : "");
		n.shape = NODEBOX;
		n.boxes = {-0.3125f, -0.5f, -0.3125f, 0.3125f, 0.25f, 0.3125f};
		if(lit){
			n.light_source = 12;
			g.items.erase(n.name);
		} else
			g.items[n.name].image = "main/lantern_active.png";
	}
	// [SKELDAT_MINING_HAZARDS] The pockets in the rock: water and lava of
	// constant volume (param2 the volume less one), poison and volcanic
	// gas (param2 the share, 1..255). None is an item or dug.
	for(const char *name : {"pocket_water", "lava"}){
		const bool lava = ss_(name) == "lava";
		NodeDef &n = node(name, lava ? "Lava" : "Water", {lava ? "lava" : "water"},
				{}, "-");
		n.shape = LIQUID;
		n.flowing = true;
		if(lava)
			n.light_source = 13;
		g.items.erase(n.name);
	}
	for(const char *name : {"gas_poison", "gas_volcanic"}){
		NodeDef &n = node(name, ss_(name) == "gas_poison" ? "Poison Gas" :
				"Volcanic Gas", {name}, {}, "-");
		n.shape = GAS;
		n.walkable = false;
		g.items.erase(n.name);
	}
	// [SKELDAT_OWN_MAPGEN] A river's spring (always full) and drain (what
	// goes in is gone), drawn as water, and the sea edge's drain, drawn as
	// nothing (terrain.h); a lava spring, lava a cube that is mined to
	// nothing (stone's drop)
	for(const char *name : {"water_spring", "water_drain", "level_drain"}){
		NodeDef &n = node(name, "Water", {"water"}, {}, "-");
		n.shape = LIQUID;
		g.items.erase(n.name);
	}
	{
		NodeDef &n = node("lava_spring", "Lava Spring", {"lava"},
				{{"cracky", 3}}, "skeldat:cobble");
		n.light_source = 13;
		g.items.erase(n.name);
	}
	// [SKELDAT_APPLE_TREES] An apple tree's leaves (a sapling knows its
	// kind by them); an apple hanging in them, dug an apple and an apple
	// branch left (main.cpp), which is nothing to see or touch and an
	// apple again at midnight; the saplings, half a voxel tall, grown one
	// voxel, then a tree of their kind (main.cpp's trees)
	{
		NodeDef &n = node("apple_leaves", "Apple Tree Leaves", {"leaves"},
				{{"snappy", 3}, {"leaves", 1}}, "skeldat:apple_sapling");
		n.shape = ALLFACES;
		n.drop_rarity = 20;
	}
	{
		NodeDef &n = node("apple_fruit", "Apple", {"apple"},
				{{"snappy", 3}, {"dig_immediate", 3}}, "skeldat:apple");
		n.shape = NODEBOX;
		n.walkable = false;
		n.boxes = {-3 / 16.0f, -3 / 16.0f, -3 / 16.0f, 3 / 16.0f, 3 / 16.0f, 3 / 16.0f};
		g.items.erase(n.name);
	}
	{
		NodeDef &n = node("apple_branch", "Apple Branch", {"leaves"}, {}, "-");
		n.walkable = false;
		g.items.erase(n.name);
	}
	for(int apple = 0; apple < 2; apple++)
		for(int grown = 0; grown < 2; grown++){
			const ss_ kind = apple ? "apple_sapling" : "sapling";
			NodeDef &n = node(kind + (grown ? "_grown" : ""), ss_(apple ?
					"Apple Tree Sapling" : "Sapling") + (grown ? " (grown)" : ""),
					{kind}, {{"snappy", 3}, {"dig_immediate", 3}},
					grown ? "skeldat:" + kind : "");
			n.shape = NODEBOX;
			n.walkable = false;
			n.boxes = {-5 / 16.0f, -0.5f, -5 / 16.0f, 5 / 16.0f, grown ? 0.5f : 0.0f,
					5 / 16.0f};
			if(grown)
				g.items.erase(n.name);
		}
	// The table and the furnace show their fronts
	g.items["skeldat:table"].image = "main/table_front.png";
	g.items["skeldat:furnace"].image = "main/furnace_front.png";

	auto item = [&](const ss_ &name, const ss_ &desc, int eat = 0,
			const ss_ &image = "") -> ItemDef& {
		ItemDef d;
		d.name = "skeldat:" + name;
		d.desc = desc;
		d.image = "main/" + (image.empty() ? name : image) + ".png";
		d.eat = eat;
		return g.items[d.name] = d;
	};
	item("stick", "Stick");
	item("coal", "Coal");
	item("iron_ingot", "Iron Ingot");
	item("diamond", "Diamond");
	item("bone", "Bone");
	item("arrow", "Arrow");
	// [SKELDAT_MORE_FUN] A fire arrow: the arrow's picture, tinted (the
	// client's "#rrggbb" after an image)
	item("fire_arrow", "Fire Arrow").image = "main/arrow.png#ff7a30";
	// [SKELDAT_BOW] A bow: no caps, so it digs as the hand would, which
	// main.cpp refuses; worn by its shots
	{
		ItemDef &d = item("bow", "Bow");
		d.tool = true;
		d.stack_max = 1;
	}
	item("apple", "Apple", 4);
	item("meat_raw", "Raw Boar Meat", 3);
	item("meat_cooked", "Cooked Boar Meat", 8);
	item("skull", "Deep Skull", 0, "skull_front");
	item("crown", "Bone Crown").stack_max = 1;

	// The hand: dirt, wood slowly, leaves; no stone
	auto cap = [](const ss_ &group, float t1, float t2, float t3, int uses){
		Cap c;
		c.group = group;
		c.times[1] = t1; c.times[2] = t2; c.times[3] = t3;
		c.uses = uses;
		return c;
	};
	g.hand.name = "";
	g.hand.caps = {cap("crumbly", 0, 1.5f, 0.8f, 0),
			cap("choppy", 0, 4.0f, 3.0f, 0), cap("snappy", 0, 0, 0.4f, 0),
			cap("oddly_breakable_by_hand", 0, 0, 0.5f, 0)};

	auto craft = [&](const ss_ &output, int width, sv_<ss_> items){
		Recipe r;
		r.output = output;
		r.width = width;
		r.items = items;
		g.recipes.push_back(r);
	};
	// The ladder: a tier digs the cracky rating its index allows (wood 3,
	// stone 2, iron and diamond 1), and each is faster and lasts longer
	struct Tier { const char *key, *desc, *mat; float k; int uses, n; };
	for(const Tier &t : {Tier{"wood", "Wooden", "skeldat:wood", 1.0f, 30, 1},
			Tier{"stone", "Stone", "skeldat:cobble", 0.7f, 90, 2},
			Tier{"iron", "Iron", "skeldat:iron_ingot", 0.5f, 250, 3},
			Tier{"diamond", "Diamond", "skeldat:diamond", 0.35f, 1500, 4}}){
		const ss_ m = t.mat, s = "skeldat:stick";
		auto tool = [&](const ss_ &kind, const ss_ &name, Cap c, int fleshy,
				int width, sv_<ss_> recipe){
			ItemDef &d = item(ss_(t.key) + "_" + kind,
					ss_(t.desc) + " " + name);
			d.tool = true;
			d.stack_max = 1;
			d.caps = {c};
			d.fleshy = fleshy;
			craft(d.name, width, recipe);
		};
		tool("pick", "Pickaxe", cap("cracky", t.n >= 3 ? 4.0f * t.k : 0,
				t.n >= 2 ? 2.4f * t.k : 0, 1.6f * t.k, t.uses), 1 + t.n, 3,
				{m, m, m, "", s, "", "", s, ""});
		tool("axe", "Axe", cap("choppy", 0, 2.0f * t.k, 1.5f * t.k, t.uses),
				2 + t.n, 2, {m, m, m, s, "", s});
		tool("shovel", "Shovel", cap("crumbly", 0, 0.8f * t.k, 0.5f * t.k,
				t.uses), t.n, 1, {m, s, s});
		tool("sword", "Sword", cap("snappy", 0, 0, 0.3f * t.k, t.uses),
				3 + t.n, 1, {m, m, s});
	}
	const ss_ w = "skeldat:wood", c = "skeldat:cobble", b = "skeldat:bone";
	craft("skeldat:wood 4", 0, {"skeldat:tree"});
	craft("skeldat:stick 4", 1, {w, w});
	craft("skeldat:table", 2, {w, w, w, w});
	craft("skeldat:furnace", 3, {c, c, c, c, "", c, c, c, c});
	craft("skeldat:torch 4", 1, {"skeldat:coal", "skeldat:stick"});
	craft("skeldat:bone_block", 3, {b, b, b, b, b, b, b, b, b});
	{
		const ss_ i = "skeldat:iron_ingot";
		craft("skeldat:lantern", 3, {i, b, i, b, "", b, i, b, i});
	}
	const ss_ k = "skeldat:skull", d = "skeldat:diamond",
			bb = "skeldat:bone_block";
	craft("skeldat:crown", 3, {k, d, k, bb, k, bb});
	// [SKELDAT_BOW] Minecraft's bow, bones for the string; an arrow a bone
	// over a stick
	{
		const ss_ s = "skeldat:stick";
		craft("skeldat:bow", 3, {"", s, b, s, "", b, "", s, b});
		craft("skeldat:arrow 4", 1, {b, s});
		craft("skeldat:fire_arrow", 1, {"skeldat:coal", "skeldat:arrow"});
	}
	g.cooking = {{"skeldat:iron_ore", "skeldat:iron_ingot", 4},
			{"skeldat:meat_raw", "skeldat:meat_cooked", 3}};
	g.fuel = {{"skeldat:coal", 40}, {"skeldat:tree", 15}, {"skeldat:wood", 8},
			{"skeldat:stick", 2}};
	return g;
}

#ifdef SKELDAT_GAME_TEST
}
#include <cassert>
#include <cstdio>
namespace skeldat {
inline int self_test()
{
	Game g = make_game();
	// Dig times: the hand digs dirt, not stone; a wooden pick stone and
	// not iron ore; a stone pick iron ore
	assert(std::fabs(g.dig_time("", *g.node("skeldat:dirt")) - 0.8f) < 1e-4f);
	assert(g.dig_time("", *g.node("skeldat:stone")) < 0);
	assert(g.dig_time("skeldat:diamond_pick", *g.node("skeldat:bone_wall")) < 0 &&
			g.dig_time("", *g.node("skeldat:bone_wall")) < 0 &&
			!g.item("skeldat:bone_wall"));
	assert(g.dig_time("skeldat:wood_pick", *g.node("skeldat:stone")) > 0);
	assert(g.dig_time("skeldat:wood_pick", *g.node("skeldat:iron_ore")) < 0);
	assert(g.dig_time("skeldat:stone_pick", *g.node("skeldat:iron_ore")) > 0);
	// A pick's dig of dirt is the hand's
	assert(std::fabs(g.dig_time("skeldat:wood_pick",
			*g.node("skeldat:dirt")) - 0.8f) < 1e-4f);
	// Crafting: a log anywhere is planks; sticks in either column; a
	// pick only in its shape; nothing from nonsense
	Stack grid[9];
	grid[4] = Stack("skeldat:tree");
	assert(g.craft(grid) && g.craft(grid)->output == "skeldat:wood 4");
	for(Stack &s : grid) s = Stack();
	grid[2] = Stack("skeldat:wood");
	grid[5] = Stack("skeldat:wood");
	assert(g.craft(grid) && g.craft(grid)->output == "skeldat:stick 4");
	for(Stack &s : grid) s = Stack();
	const ss_ w = "skeldat:wood", st = "skeldat:stick";
	grid[0] = Stack(w); grid[1] = Stack(w); grid[2] = Stack(w);
	grid[4] = Stack(st); grid[7] = Stack(st);
	assert(g.craft(grid) && g.craft(grid)->output == "skeldat:wood_pick");
	grid[8] = Stack(st);
	assert(!g.craft(grid));
	// A lantern: iron at the corners, bones between ([SKELDAT_FIGHT_BACK])
	for(int i = 0; i < 9; i++)
		grid[i] = i == 4 ? Stack() : Stack(i % 2 ? "skeldat:bone" :
				"skeldat:iron_ingot");
	assert(g.craft(grid) && g.craft(grid)->output == "skeldat:lantern");
	// The bow: sticks as the arc, bones down the right; an arrow a bone
	// over a stick in any column, not a stick over a bone
	for(Stack &s : grid) s = Stack();
	grid[1] = grid[3] = grid[7] = Stack(st);
	grid[2] = grid[5] = grid[8] = Stack("skeldat:bone");
	assert(g.craft(grid) && g.craft(grid)->output == "skeldat:bow");
	assert(g.item("skeldat:bow")->tool && g.item("skeldat:bow")->caps.empty());
	for(Stack &s : grid) s = Stack();
	grid[1] = Stack("skeldat:bone"); grid[4] = Stack(st);
	assert(g.craft(grid) && g.craft(grid)->output == "skeldat:arrow 4");
	grid[1] = Stack(st); grid[4] = Stack("skeldat:bone");
	assert(!g.craft(grid));
	// [SKELDAT_MORE_FUN] A fire arrow: a coal over an arrow
	grid[1] = Stack("skeldat:coal"); grid[4] = Stack("skeldat:arrow");
	assert(g.craft(grid) && g.craft(grid)->output == "skeldat:fire_arrow");
	assert(!g.node("skeldat:stuck_arrow")->walkable &&
			!g.item("skeldat:stuck_arrow"));
	// Stacks: add fills the same item first and spills into empty slots
	sv_<Stack> list(3);
	list[1] = Stack("skeldat:dirt", 98);
	Stack left = g.add(list, Stack("skeldat:dirt", 5));
	assert(left.empty() && list[1].count == 99 && list[0].count == 4);
	left = g.add(list, Stack("skeldat:wood_pick"));
	assert(left.empty() && list[2].name == "skeldat:wood_pick");
	left = g.add(list, Stack("skeldat:stone", 1));
	assert(!left.empty());
	// Moves: part onto nothing, whole onto another item swaps, part onto
	// another item does nothing
	Stack a("skeldat:dirt", 10), b, c("skeldat:sand", 3);
	assert(g.move(a, b, 4) && a.count == 6 && b.count == 4);
	assert(!g.move(a, c, 2));
	assert(g.move(a, c, 6) && a.name == "skeldat:sand" && c.count == 6);
	// The string form
	assert(Stack::parse("skeldat:wood_pick 1 300").wear == 300);
	assert(Stack("skeldat:dirt", 5).str() == "skeldat:dirt 5");
	assert(Stack::parse("").empty());
	printf("skeldat game.h: self test passed, %zu nodes, %zu items, "
			"%zu recipes\n", g.nodes.size(), g.items.size(), g.recipes.size());
	return 0;
}
}
// With an argument: each item's picture a line, for check.sh's look at
// the PNGs ([SKELDAT_SKULL_ICON])
int main(int argc, char **argv)
{
	if(argc > 1){
		for(auto &pair : skeldat::make_game().items)
			printf("%s %s\n", pair.first.c_str(), pair.second.image.c_str());
		return 0;
	}
	return skeldat::self_test();
}
namespace skeldat {
#endif

}
// vim: set noet ts=4 sw=4:
