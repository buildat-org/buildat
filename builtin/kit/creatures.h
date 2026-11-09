// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [KIT_CREATURES_8A] Kit's pathfinder (kit_plan stage 8): A* over a box of a
// scene's cells read once (kit.cpp's read_grid()), for a body of a footprint
// and a height in cells that walks, steps or jumps up `jump` cells and drops
// `drop`. A cell's middle is its whole coordinates; a node is the cell a
// body's feet are in: free for the body's height, solid under its middle.
// Kit's own (kit.cpp; util/kit_creatures_check.sh checks it).
// simplified: walk and jump only (swim, fly and climb later); the footprint
// is its middle column or the 3 x 3 round it
#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <queue>
#include <vector>

namespace kit {
namespace creatures {

typedef std::array<int, 3> Cell;

// Cells from (x0, y0, z0): AIR, SOLID, or UNKNOWN (not loaded; past the box
// too), which is neither stood in nor stood on
enum { AIR = 0, SOLID = 1, UNKNOWN = 2 };
struct Grid
{
	int x0 = 0, y0 = 0, z0 = 0, nx = 0, ny = 0, nz = 0;
	std::vector<uint8_t> c;
	int at(int x, int y, int z) const
	{
		x -= x0, y -= y0, z -= z0;
		if(x < 0 || y < 0 || z < 0 || x >= nx || y >= ny || z >= nz)
			return UNKNOWN;
		return c[x + (size_t)nx * (z + (size_t)nz * y)];
	}
	bool inside(const Cell &p) const
	{
		return p[0] >= x0 && p[1] >= y0 && p[2] >= z0 && p[0] < x0 + nx &&
				p[1] < y0 + ny && p[2] < z0 + nz;
	}
	size_t index(const Cell &p) const
	{
		return (p[0] - x0) + (size_t)nx * ((p[2] - z0) + (size_t)nz * (p[1] - y0));
	}
};

struct Body
{
	int half = 0; // the footprint's cells either side of its middle (0 or 1)
	int h = 2; // cells tall
	int jump = 1, drop = 3;
};

// The column at x, z free from y for n cells (the footprint's)
static inline bool free_col(const Grid &g, const Body &b, int x, int y, int z, int n)
{
	for(int dx = -b.half; dx <= b.half; dx++)
	for(int dz = -b.half; dz <= b.half; dz++)
	for(int k = 0; k < n; k++)
		if(g.at(x + dx, y + k, z + dz) != AIR)
			return false;
	return true;
}

static inline bool standable(const Grid &g, const Body &b, int x, int y, int z)
{
	return g.at(x, y - 1, z) == SOLID && free_col(g, b, x, y, z, b.h);
}

// A node the body can stand in from p: p, else the first down `b.drop`
// cells (one in the air, mid-jump); p itself when there is none
static inline Cell ground_of(const Grid &g, const Body &b, Cell p)
{
	for(int k = 0; k <= b.drop + 1; k++)
		if(standable(g, b, p[0], p[1] - k, p[2]))
			return Cell{{p[0], p[1] - k, p[2]}};
	return p;
}

// A path from `from` towards `to`, done within `range` cells of it along the
// ground (and 2 up or down): the nodes after `from`, in order. True when it
// gets there; else the path to the node nearest `to` that it found (empty:
// none nearer), within `max_nodes` expanded. `expanded` says how many were
// (the meter's charge)
static inline bool find_path(const Grid &g, const Body &b, Cell from, Cell to,
		double range, int max_nodes, std::vector<Cell> &out, int &expanded)
{
	out.clear();
	expanded = 0;
	if(!g.inside(from))
		return false;
	const size_t n = g.c.size();
	std::vector<float> cost(n, INFINITY);
	std::vector<int32_t> came(n, -1);
	std::vector<uint8_t> closed(n, 0);
	auto heur = [&](const Cell &p){
		const double dx = p[0] - to[0], dz = p[2] - to[2];
		return std::sqrt(dx * dx + dz * dz) + std::abs(p[1] - to[1]) * 0.5;
	};
	auto done = [&](const Cell &p){
		const double dx = p[0] - to[0], dz = p[2] - to[2];
		return std::sqrt(dx * dx + dz * dz) <= range + 0.01 &&
				std::abs(p[1] - to[1]) <= 2;
	};
	auto cell = [&](size_t i){
		const int x = (int)(i % g.nx), z = (int)((i / g.nx) % g.nz),
				y = (int)(i / ((size_t)g.nx * g.nz));
		return Cell{{x + g.x0, y + g.y0, z + g.z0}};
	};
	typedef std::pair<float, int32_t> Q;
	std::priority_queue<Q, std::vector<Q>, std::greater<Q>> open;
	const size_t fi = g.index(from);
	cost[fi] = 0;
	open.push(Q((float)heur(from), (int32_t)fi));
	int32_t best = (int32_t)fi;
	double best_h = heur(from);
	bool got = false;
	static const int DIRS[8][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1},
		{1, -1}, {-1, 1}, {-1, -1}};
	while(!open.empty() && expanded < max_nodes){
		const int32_t i = open.top().second;
		open.pop();
		if(closed[i])
			continue;
		closed[i] = 1;
		expanded++;
		const Cell p = cell(i);
		const double h = heur(p);
		if(h < best_h)
			best = i, best_h = h;
		if(done(p)){
			best = i;
			got = true;
			break;
		}
		for(const auto &d : DIRS){
			const int x = p[0] + d[0], z = p[2] + d[1];
			const bool diag = d[0] && d[1];
			// The level nearest its own first: level, up one, down one...
			for(int k = 0; k <= 2 * std::max(b.jump, b.drop); k++){
				const int dy = k % 2 ? (k + 1) / 2 : -(k / 2);
				if(dy > b.jump || dy < -b.drop)
					continue;
				const int y = p[1] + dy;
				if(!standable(g, b, x, y, z))
					continue;
				// Up: room over its head first; down: the way down free;
				// across a corner: both sides free at the higher level
				if(dy > 0 && !free_col(g, b, p[0], p[1] + b.h, p[2], dy))
					continue;
				if(dy < 0 && !free_col(g, b, x, y, z, b.h - dy))
					continue;
				const int top = std::max(p[1], y);
				if(diag && (!free_col(g, b, p[0] + d[0], top, p[2], b.h) ||
						!free_col(g, b, p[0], top, p[2] + d[1], b.h)))
					continue;
				const Cell q{{x, y, z}};
				if(!g.inside(q))
					continue;
				const size_t qi = g.index(q);
				if(closed[qi])
					continue;
				const float c = cost[i] + (diag ? 1.4142f : 1.0f) +
						(dy > 0 ? 0.5f * dy : dy < 0 ? -0.2f * dy : 0.0f);
				if(c < cost[qi]){
					cost[qi] = c;
					came[qi] = i;
					open.push(Q(c + (float)heur(q), (int32_t)qi));
				}
				break; // one level a direction: the nearest that stands
			}
		}
	}
	for(int32_t i = best; i >= 0 && (size_t)i != fi; i = came[i])
		out.push_back(cell(i));
	std::reverse(out.begin(), out.end());
	return got;
}

// The nodes as waypoints: each turn and each change of level, and the last
static inline std::vector<Cell> corners(const Cell &from, const std::vector<Cell> &path)
{
	std::vector<Cell> out;
	Cell prev = from;
	for(size_t i = 0; i < path.size(); i++){
		const Cell &p = path[i];
		if(i + 1 < path.size()){
			const Cell &q = path[i + 1];
			if(p[1] == prev[1] && q[1] == p[1] && q[0] - p[0] == p[0] - prev[0] &&
					q[2] - p[2] == p[2] - prev[2]){
				prev = p;
				continue;
			}
		}
		out.push_back(p);
		prev = p;
	}
	return out;
}

}
}
// vim: set noet ts=4 sw=4:
