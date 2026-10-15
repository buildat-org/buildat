// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "interface/voxel_path.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <limits>
#include <queue>

namespace interface
{
namespace voxel_path
{

static bool body_free(const Field &f, const Rules &r, const P &p)
{
	for(int i = 0; i < r.body_height; i++)
		if(f.at(p.x, p.y + i, p.z) == SOLID)
			return false;
	return true;
}

static bool climbing(const Field &f, const Rules &r, const P &p)
{
	for(int i = 0; i < r.body_height; i++)
		if(f.at(p.x, p.y + i, p.z) == CLIMB)
			return true;
	return false;
}

bool stands(const Field &f, const Rules &r, const P &p)
{
	return body_free(f, r, p) && (f.at(p.x, p.y - 1, p.z) == SOLID ||
			climbing(f, r, p));
}

bool settle(const Field &f, const Rules &r, P &p)
{
	P q = p;
	if(!body_free(f, r, q)){
		q.y++;
		if(!body_free(f, r, q))
			return false;
	}
	for(int fell = 0; fell <= r.max_fall; fell++, q.y--){
		if(!body_free(f, r, q))
			return false;
		if(stands(f, r, q)){
			p = q;
			return true;
		}
	}
	return false;
}

// Where a body walking from s into column (x, z) ends up: the same level, a
// step up, or a fall from the same level. false where it cannot go.
static bool walk_to(const Field &f, const Rules &r, const P &s,
		int32_t x, int32_t z, P &out)
{
	// Up first: a step onto a block is the move a player makes. The body
	// has to rise in its own column before it moves over.
	for(int dy = r.step_up; dy >= 1; dy--){
		P t(x, s.y + dy, z);
		if(!stands(f, r, t))
			continue;
		bool head = true;
		for(int i = 0; i < dy; i++)
			if(f.at(s.x, s.y + r.body_height + i, s.z) == SOLID)
				head = false;
		if(head){
			out = t;
			return true;
		}
	}
	P t(x, s.y, z);
	if(!body_free(f, r, t))
		return false;
	for(int fell = 0; fell <= r.max_fall; fell++, t.y--){
		if(!body_free(f, r, t))
			return false;
		if(stands(f, r, t)){
			out = t;
			return true;
		}
	}
	return false;
}

Result find(const Field &f, const P &from, const P &to, const Rules &r)
{
	Result res;
	if(!f.inside(from.x, from.y, from.z) || !f.inside(to.x, to.y, to.z))
		return res;
	const float INF = std::numeric_limits<float>::infinity();
	sv_<float> g(f.cells.size(), INF);
	sv_<int32_t> parent(f.cells.size(), -1);
	auto h = [&](const P &p){
		const float dx = (float)(p.x - to.x), dz = (float)(p.z - to.z);
		return std::sqrt(dx * dx + dz * dz);
	};
	auto unindex = [&](size_t i){
		const int32_t x = (int32_t)(i % f.w);
		const int32_t z = (int32_t)((i / f.w) % f.d);
		const int32_t y = (int32_t)(i / ((size_t)f.w * f.d));
		return P(x + f.origin.x, y + f.origin.y, z + f.origin.z);
	};
	typedef std::pair<float, size_t> Open;
	std::priority_queue<Open, sv_<Open>, std::greater<Open>> open;
	const size_t start = f.index(from.x, from.y, from.z);
	const size_t goal = f.index(to.x, to.y, to.z);
	g[start] = 0;
	open.push(Open(h(from), start));
	// A little over, so that a straight walk of exactly the limit passes
	const float limit = r.max_length > 0 ? r.max_length + 1e-3f : INF;
	static const int DIRS[8][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1},
			{1, 1}, {1, -1}, {-1, 1}, {-1, -1}};
	while(!open.empty()){
		const Open o = open.top();
		open.pop();
		const size_t i = o.second;
		if(o.first > g[i] + h(unindex(i)) + 1e-4f)
			continue; // A stale entry: reached cheaper since
		if(i == goal){
			res.found = true;
			res.length = g[i];
			for(int32_t at = (int32_t)i; at != -1; at = parent[at])
				res.path.push_back(unindex(at));
			std::reverse(res.path.begin(), res.path.end());
			return res;
		}
		if(++res.expanded > r.max_expanded){
			res.capped = true;
			return res;
		}
		const P s = unindex(i);
		auto relax = [&](const P &t, float cost){
			const size_t j = f.index(t.x, t.y, t.z);
			const float gj = g[i] + cost;
			if(gj >= g[j] || gj + h(t) > limit)
				return;
			g[j] = gj;
			parent[j] = (int32_t)i;
			open.push(Open(gj + h(t), j));
		};
		for(const auto &d : DIRS){
			const bool diagonal = d[0] != 0 && d[1] != 0;
			// No corner cut: both sides of a diagonal open at this level
			if(diagonal && (!body_free(f, r, P(s.x + d[0], s.y, s.z)) ||
					!body_free(f, r, P(s.x, s.y, s.z + d[1]))))
				continue;
			P t;
			if(walk_to(f, r, s, s.x + d[0], s.z + d[1], t))
				relax(t, diagonal ? (float)M_SQRT2 : 1.0f);
		}
		// simplified: a climb's voxels count as walked; how fast a ladder is
		// against a walk is the caller's to fold into max_length
		if(climbing(f, r, s)){
			const P up(s.x, s.y + 1, s.z), down(s.x, s.y - 1, s.z);
			if(body_free(f, r, up))
				relax(up, 1.0f);
			if(body_free(f, r, down) && stands(f, r, down))
				relax(down, 1.0f);
		}
	}
	return res;
}

// A floor at y = 0 under a w x d box, the body's room above it
static Field flat(int w, int d, int h = 6)
{
	Field f;
	f.resize(P(0, 0, 0), w, h, d);
	for(int z = 0; z < d; z++)
		for(int x = 0; x < w; x++)
			f.set(x, 0, z, SOLID);
	return f;
}

bool self_test()
{
	Rules r;
	{
		// A straight walk, its length, and the limit both ways
		Field f = flat(12, 3);
		Result a = find(f, P(0, 1, 1), P(10, 1, 1), r);
		assert(a.found && std::fabs(a.length - 10) < 1e-3f);
		assert(a.path.front() == P(0, 1, 1) && a.path.back() == P(10, 1, 1));
		r.max_length = 10;
		assert(find(f, P(0, 1, 1), P(10, 1, 1), r).found);
		r.max_length = 9;
		assert(!find(f, P(0, 1, 1), P(10, 1, 1), r).found);
		r.max_length = 0;
		// A diagonal is shorter than its two sides
		Result dg = find(f, P(0, 1, 0), P(2, 1, 2), r);
		assert(dg.found && std::fabs(dg.length - 2 * (float)M_SQRT2) < 1e-3f);
	}
	{
		// A one-voxel step is a jump; two is not, and nor is a wall
		Field f = flat(6, 1);
		f.set(3, 1, 0, SOLID);
		assert(find(f, P(0, 1, 0), P(3, 2, 0), r).found);
		assert(find(f, P(0, 1, 0), P(5, 1, 0), r).found); // over it
		f.set(3, 2, 0, SOLID);
		assert(!find(f, P(0, 1, 0), P(3, 3, 0), r).found);
		assert(!find(f, P(0, 1, 0), P(5, 1, 0), r).found);
		// No headroom for the jump: a ceiling over the start
		Field c = flat(6, 1);
		c.set(3, 1, 0, SOLID);
		c.set(2, 3, 0, SOLID);
		assert(!find(c, P(0, 1, 0), P(3, 2, 0), r).found);
	}
	{
		// A fall of any height, and back up only where a ladder is
		Field f;
		f.resize(P(0, 0, 0), 4, 12, 1);
		for(int y = 0; y <= 8; y++)
			f.set(0, y, 0, SOLID);
		f.set(1, 0, 0, SOLID);
		f.set(2, 0, 0, SOLID);
		f.set(3, 0, 0, SOLID);
		Result down = find(f, P(0, 9, 0), P(2, 1, 0), r);
		assert(down.found && std::fabs(down.length - 2) < 1e-3f);
		assert(!find(f, P(2, 1, 0), P(0, 9, 0), r).found);
		for(int y = 1; y <= 10; y++)
			f.set(1, y, 0, CLIMB);
		assert(find(f, P(2, 1, 0), P(0, 9, 0), r).found);
		r.max_fall = 3;
		f.set(1, 1, 0, OPEN);
		for(int y = 2; y <= 10; y++)
			f.set(1, y, 0, OPEN);
		assert(!find(f, P(0, 9, 0), P(2, 1, 0), r).found);
		r.max_fall = 64;
	}
	{
		// settle: out of the ground and down to it
		Field f = flat(3, 3);
		P p(1, 0, 1);
		assert(settle(f, r, p) && p == P(1, 1, 1));
		p = P(1, 4, 1);
		assert(settle(f, r, p) && p == P(1, 1, 1));
		// Below the box is solid, so a fall further than max_fall is it
		Field v;
		v.resize(P(0, 0, 0), 3, 6, 3);
		p = P(1, 4, 1);
		r.max_fall = 2;
		assert(!settle(v, r, p));
		r.max_fall = 64;
	}
	{
		// A diagonal past a corner is refused and the way round taken
		Field f = flat(3, 3);
		for(int y = 1; y <= 3; y++)
			f.set(1, y, 0, SOLID);
		Result a = find(f, P(0, 1, 0), P(1, 1, 1), r);
		assert(a.found && std::fabs(a.length - 2) < 1e-3f);
	}
	return true;
}

}
}
// vim: set noet ts=4 sw=4:
