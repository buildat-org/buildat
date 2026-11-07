// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [KIT_SYMMETRY] kit/symmetry's slices and their maps (kit_plan 7c; api.h
// says what the type does). The plane's (x, z) about the world's origin,
// where a cell's middle is its whole coordinates: a side of 96 runs -48 to
// 47, column 0 a seam mapping to itself and -48 with no partner. Every map
// keeps the grid: mirrors across x = 0, z = 0, x = z, x = -z and quarter
// turns. Kit's own (kit.cpp; util/kit_symmetry_check.sh checks it).
#pragma once
#include "core/types.h"
#include <cmath>
#include <cstdlib>

namespace kit {
namespace symmetry {

// x' = a x + b z, z' = c x + d z: orthogonal, of whole numbers
struct Map
{
	int a = 1, b = 0, c = 0, d = 1;
	Map(){}
	Map(int a, int b, int c, int d): a(a), b(b), c(c), d(d){}
	int det() const { return a * d - b * c; }
	// It swaps the axes (a quarter turn, a diagonal's mirror)
	bool swaps() const { return a == 0; }
	Map inverse() const { return Map(a, c, b, d); }
	template<typename T> void apply(T &x, T &z) const
	{
		const T nx = a * x + b * z;
		z = c * x + d * z;
		x = nx;
	}
	bool operator==(const Map &o) const
	{
		return a == o.a && b == o.b && c == o.c && d == o.d;
	}
};

static const Map MX(-1, 0, 0, 1), MZ(1, 0, 0, -1), R90(0, 1, -1, 0),
		R180(-1, 0, 0, -1), R270(0, -1, 1, 0), SWAP(0, 1, 1, 0),
		ANTI(0, -1, -1, 0);

struct Config
{
	// The slices' maps, maps[0] the identity: slice i is maps[i] of the
	// authored one
	sv_<Map> maps;
	ss_ slice;
	// The authored slice: 0 an axis' half (s * (x or z) >= 0), 1 a
	// diagonal's half (s * (x + t z) >= 0), 2 a quadrant (sx x >= 0, sz z >=
	// 0), 3 a diagonal quadrant (s * (x or z) >= |the other|)
	int kind = 0, s = 1, t = 1, sx = 1, sz = 1;
	bool on_z = false;
	// The map's cells
	int x0 = 0, z0 = 0, width = 0, depth = 0;

	// Closed: its seams are in it
	bool in(double x, double z) const
	{
		const double e = 1e-9;
		switch(kind){
		case 0: return s * (on_z ? z : x) >= -e;
		case 1: return s * (x + t * z) >= -e;
		case 2: return sx * x >= -e && sz * z >= -e;
		default: {
			const double v = on_z ? z : x, o = on_z ? x : z;
			return s * v >= std::fabs(o) - e;
		}
		}
	}
	bool in_map(int x, int z) const
	{
		return x >= x0 && x < x0 + width && z >= z0 && z < z0 + depth;
	}
	// A cell a builder may edit: in the authored slice, its copies on the map
	bool editable(int x, int z) const
	{
		if(!in_map(x, z) || !in(x, z))
			return false;
		for(const Map &m : maps){
			int px = x, pz = z;
			m.apply(px, pz);
			if(!in_map(px, pz))
				return false;
		}
		return true;
	}
	// The authored cell (sx, sz) a cell of the map is slice i's copy of
	// (itself and 0 in the authored slice); false: it has none (its
	// partner is off the map)
	bool source(int x, int z, int &ox, int &oz, size_t &i) const
	{
		for(i = 0; i < maps.size(); i++){
			int px = x, pz = z;
			maps[i].inverse().apply(px, pz);
			if(in(px, pz) && in_map(px, pz)){
				ox = px;
				oz = pz;
				return true;
			}
		}
		return false;
	}
};

// The choices: slices "halves" | "quadrants", angle "straight" | "45", mode
// "mirrored" | "rotational", slice the authored one's name (below); the
// map's finite x0, z0, width, depth. False and why for a combination the
// map can't take
inline bool make(const ss_ &slices, const ss_ &angle, const ss_ &mode,
		const ss_ &slice, bool finite, int x0, int z0, int width, int depth,
		Config &c, ss_ &why)
{
	c = Config();
	c.slice = slice;
	c.x0 = x0, c.z0 = z0, c.width = width, c.depth = depth;
	if(!finite){
		why = "an infinite World has no middle to mirror about: make it finite";
		return false;
	}
	const bool straight = angle == "straight", halves = slices == "halves",
			mirrored = mode == "mirrored";
	const char *names = "";
	bool ok = false;
	if(halves && straight){
		names = "+x, -x, +z or -z";
		ok = slice == "+x" || slice == "-x" || slice == "+z" || slice == "-z";
		c.kind = 0;
		c.on_z = slice.size() == 2 && slice[1] == 'z';
		c.s = slice.size() && slice[0] == '-' ? -1 : 1;
		c.maps = {Map(), mirrored ? (c.on_z ? MZ : MX) : R180};
	} else if(halves){
		names = "+x-z, -x+z, +x+z or -x-z";
		ok = slice == "+x-z" || slice == "-x+z" || slice == "+x+z" ||
				slice == "-x-z";
		c.kind = 1;
		c.s = slice.size() && slice[0] == '-' ? -1 : 1;
		c.t = slice.size() == 4 && slice[2] == '-' ? -1 : 1;
		c.maps = {Map(), mirrored ? (c.t < 0 ? SWAP : ANTI) : R180};
	} else if(straight){
		names = "+x+z, -x+z, -x-z or +x-z";
		ok = slice == "+x+z" || slice == "-x+z" || slice == "-x-z" ||
				slice == "+x-z";
		c.kind = 2;
		c.sx = slice.size() && slice[0] == '-' ? -1 : 1;
		c.sz = slice.size() == 4 && slice[2] == '-' ? -1 : 1;
		c.maps = mirrored ? sv_<Map>{Map(), MX, MZ, R180} :
				sv_<Map>{Map(), R90, R180, R270};
	} else {
		names = "+x, -x, +z or -z";
		ok = slice == "+x" || slice == "-x" || slice == "+z" || slice == "-z";
		c.kind = 3;
		c.on_z = slice.size() == 2 && slice[1] == 'z';
		c.s = slice.size() && slice[0] == '-' ? -1 : 1;
		c.maps = mirrored ? sv_<Map>{Map(), SWAP, ANTI, R180} :
				sv_<Map>{Map(), R90, R180, R270};
	}
	if(!ok){
		why = "slice: "+ss_(names)+" for "+slices+" "+(straight ? "straight" :
				"at 45 degrees");
		return false;
	}
	for(const Map &m : c.maps)
		if(m.swaps() && width != depth){
			why = slices+" "+(straight ? "straight" : "at 45 degrees")+" "+mode+
					" turns x into z: the map is "+itos(width)+" x "+itos(depth)+
					", it needs a square";
			return false;
		}
	return true;
}

// A shape's param (world.h: a facing 0...3, its back to +z, +x, -z, -x; 4
// and up the same upside down) after a map. corner: an inner or outer
// stair, whose mirror is another facing (its diagonal's)
inline uint32_t facing(uint32_t pm, const Map &m, bool corner)
{
	// R90^f of (0, 1), or of the diagonal (-1, 1)
	auto dir = [&](int f, int &x, int &z){
		x = corner ? -1 : 0;
		z = 1;
		for(int i = 0; i < (f & 3); i++)
			R90.apply(x, z);
	};
	int x, z;
	dir((int)(pm & 3), x, z);
	m.apply(x, z);
	for(int f = 0; f < 4; f++){
		int fx, fz;
		dir(f, fx, fz);
		if(fx == x && fz == z)
			return (pm & ~3u) | (uint32_t)f;
	}
	return pm;
}

}
}
// vim: set noet ts=4 sw=4:
