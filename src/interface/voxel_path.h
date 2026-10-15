// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

// A path for a walking body through voxels ([SKELDAT]): A* over a box of
// cells the caller filled, with the moves a body standing on the ground has
// -- a walk to any of the eight neighbours, a step up of at most step_up
// voxels, a fall of any height up to max_fall, and up and down where it
// climbs. What asks is a server checking that a player could have got from
// one place to another, and a mob looking for its way.
//
// No voxelworld in it: the caller reads the voxels once (get_volume) and
// says which cells block a body and which it climbs in, so a search is
// array lookups and nothing else. Coordinates are voxels, a body's position
// is the voxel its feet are in.
namespace interface
{
namespace voxel_path
{
	struct P
	{
		int32_t x = 0, y = 0, z = 0;
		P(){}
		P(int32_t x, int32_t y, int32_t z): x(x), y(y), z(z){}
		bool operator==(const P &o) const {
			return x == o.x && y == o.y && z == o.z;
		}
		bool operator!=(const P &o) const { return !(*this == o); }
	};

	// What a cell is to a body. CLIMB is open, and a body in it stands
	// without ground under it and moves up and down: a ladder, water.
	enum Cell: uint8_t { OPEN = 0, SOLID = 1, CLIMB = 2 };

	// The box searched, x fastest, then z, then y. Outside it is SOLID, so
	// a path never leaves it.
	struct Field
	{
		P origin;
		int32_t w = 0, h = 0, d = 0;
		sv_<uint8_t> cells;

		void resize(const P &o, int32_t w_, int32_t h_, int32_t d_){
			origin = o; w = w_; h = h_; d = d_;
			cells.assign((size_t)w * h * d, OPEN);
		}
		bool inside(int32_t x, int32_t y, int32_t z) const {
			x -= origin.x; y -= origin.y; z -= origin.z;
			return x >= 0 && y >= 0 && z >= 0 && x < w && y < h && z < d;
		}
		size_t index(int32_t x, int32_t y, int32_t z) const {
			return (size_t)(x - origin.x) + (size_t)w * ((size_t)(z - origin.z) +
					(size_t)d * (size_t)(y - origin.y));
		}
		uint8_t at(int32_t x, int32_t y, int32_t z) const {
			return inside(x, y, z) ? cells[index(x, y, z)] : (uint8_t)SOLID;
		}
		void set(int32_t x, int32_t y, int32_t z, uint8_t c){
			if(inside(x, y, z))
				cells[index(x, y, z)] = c;
		}
	};

	struct Rules
	{
		// Voxels the body is tall: a player of 1.75 is two
		int body_height = 2;
		// How high one move climbs without a ladder: a jump
		int step_up = 1;
		// How far one move may fall
		int max_fall = 64;
		// The longest path accepted, in voxels walked horizontally (a climb
		// counts its voxels too; a step up and a fall nothing); <= 0 is no
		// limit. A search that would have to go further fails.
		float max_length = 0;
		// A ceiling on the cells a search expands, whatever the length
		size_t max_expanded = 20000;
	};

	struct Result
	{
		bool found = false;
		// Gave up at max_expanded rather than running out of cells
		bool capped = false;
		float length = 0;
		size_t expanded = 0;
		// From the start to the goal, both included, when found
		sv_<P> path;
	};

	// Whether a body stands at p: its cells free of SOLID, and ground under
	// it or a CLIMB cell in it
	bool stands(const Field &f, const Rules &r, const P &p);

	// p moved to where a body there comes to stand: up one voxel out of the
	// ground it is sunk into, then down until it stands, within max_fall.
	// false where it does not (in a wall, falling further than that).
	bool settle(const Field &f, const Rules &r, P &p);

	// From one standing position to another; both settled by the caller
	Result find(const Field &f, const P &from, const P &to, const Rules &r);

	// Asserts, a few small worlds; true when they pass
	bool self_test();
}
}
// vim: set noet ts=4 sw=4:
