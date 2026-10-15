// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// The node shapes as quads, the facedir tables and turns, and their
// self-check: Luanti's drawtypes in buildat's VoxelQuad. builtin/luanti
// builds its registry from these and any module may include them
// ("luanti/shapes.h").
#pragma once
#include "core/types.h"
#include "interface/voxel.h"
#include <algorithm>
#include <cassert>
#include <cmath>

namespace luanti_shapes
{

// Which way a node faces, out of its param2.
//
// Luanti's own dir_to_tile[24][8] from mapblock_mesh.cpp, read at the
// six directions buildat's faces are in -- +Y, -Y, +X, -X, +Z, -Z, which
// is the order Luanti keeps its tiles in too. Taken from
// extensions/luanti_client/shapes.lua, which read them out first and
// checks them in its engine_test.lua.
//
// This is what VoxelVariant::tile_order and tile_turns are for: the
// twenty-four turns of a facedir are twenty-four variants over one
// definition's six textures, rather than a voxel type per rotation.
// Which of the six tiles each face wears, per facedir
static const uint8_t FACEDIR_TILES[24][6] = {
	{0, 1, 2, 3, 4, 5},
	{0, 1, 4, 5, 3, 2},
	{0, 1, 3, 2, 5, 4},
	{0, 1, 5, 4, 2, 3},
	{5, 4, 2, 3, 0, 1},
	{2, 3, 4, 5, 0, 1},
	{4, 5, 3, 2, 0, 1},
	{3, 2, 5, 4, 0, 1},
	{4, 5, 2, 3, 1, 0},
	{3, 2, 4, 5, 1, 0},
	{5, 4, 3, 2, 1, 0},
	{2, 3, 5, 4, 1, 0},
	{3, 2, 0, 1, 4, 5},
	{5, 4, 0, 1, 3, 2},
	{2, 3, 0, 1, 5, 4},
	{4, 5, 0, 1, 2, 3},
	{2, 3, 1, 0, 4, 5},
	{4, 5, 1, 0, 3, 2},
	{3, 2, 1, 0, 5, 4},
	{5, 4, 1, 0, 2, 3},
	{1, 0, 3, 2, 4, 5},
	{1, 0, 5, 4, 3, 2},
	{1, 0, 2, 3, 5, 4},
	{1, 0, 4, 5, 2, 3},
};

// How far that tile is turned inside its face, in quarter turns
static const uint8_t FACEDIR_TURNS[24][6] = {
	{0, 0, 0, 0, 0, 0},
	{3, 1, 0, 0, 0, 0},
	{2, 2, 0, 0, 0, 0},
	{1, 3, 0, 0, 0, 0},
	{0, 2, 3, 1, 2, 0},
	{0, 2, 3, 1, 1, 1},
	{0, 2, 3, 1, 0, 2},
	{0, 2, 3, 1, 3, 3},
	{2, 0, 1, 3, 2, 0},
	{2, 0, 1, 3, 3, 3},
	{2, 0, 1, 3, 0, 2},
	{2, 0, 1, 3, 1, 1},
	{3, 3, 3, 3, 1, 3},
	{3, 3, 2, 0, 1, 3},
	{3, 3, 1, 1, 1, 3},
	{3, 3, 0, 2, 1, 3},
	{1, 1, 1, 1, 3, 1},
	{1, 1, 2, 0, 3, 1},
	{1, 1, 3, 3, 3, 1},
	{1, 1, 0, 2, 3, 1},
	{2, 2, 2, 2, 2, 2},
	{3, 1, 2, 2, 2, 2},
	{0, 0, 2, 2, 2, 2},
	{1, 3, 2, 2, 2, 2},
};

// The rotation a facedir is, as a matrix, derived from the table above rather
// than from Luanti's handedness conventions: FACEDIR_TILES[d][f] says world
// face f wears the tile of local face s, which means the rotation takes the
// local face s to the world direction of f. Three of those give the columns,
// and check_shapes() asserts that what comes out is a proper rotation.
//
// out[r][c], so that out * v is the rotated v.
inline void facedir_matrix(uint8_t d, int out[3][3])
{
	// Face f points this way: +Y, -Y, +X, -X, +Z, -Z
	static const int FACE_DIR[6][3] = {
		{0, 1, 0}, {0, -1, 0}, {1, 0, 0},
		{-1, 0, 0}, {0, 0, 1}, {0, 0, -1},
	};
	// Local face 2 is +X, 0 is +Y and 4 is +Z, so those three give the
	// columns of the matrix
	static const uint8_t AXIS_FACE[3] = {2, 0, 4};
	for(size_t c = 0; c < 3; c++){
		const uint8_t s = AXIS_FACE[c];
		for(size_t f = 0; f < 6; f++){
			if(FACEDIR_TILES[d][f] != s)
				continue;
			for(size_t r = 0; r < 3; r++)
				out[r][c] = FACE_DIR[f][r];
			break;
		}
	}
}

// A shape turned the way a facedir turns it. The quads keep the tiles they
// name -- a quad's texture is the local face it was built on, and that
// travels with it -- so only the corners move.
//
// simplified: the texture is not turned inside the quad. tile_turns is what
// does that for a cube's faces and the mesher does not apply it to a shape's
// quads, so a turned node box wears its textures straight.
inline void turn_quads(const sv_<interface::VoxelQuad> &in, uint8_t d,
		sv_<interface::VoxelQuad> &out)
{
	int m[3][3] = {};
	facedir_matrix(d, m);
	out = in;
	for(interface::VoxelQuad &q : out){
		for(size_t i = 0; i < 4; i++){
			const float x = q.p[i][0], y = q.p[i][1], z = q.p[i][2];
			for(size_t r = 0; r < 3; r++)
				q.p[i][r] = (float)(m[r][0] * x + m[r][1] * y + m[r][2] * z);
		}
	}
}

// Boxes, six numbers each, turned the same way and clamped to the voxel's
// own cube. simplified: what reaches outside the cube -- a fence's 1.5 --
// is cut off, because the client's physics asks each cell for its own
// boxes; a fence stays as tall as the cube it was.
inline void turn_boxes(const sv_<float> &in, uint8_t d, sv_<float> &out)
{
	int m[3][3] = {};
	facedir_matrix(d, m);
	out.clear();
	for(size_t b = 0; b + 6 <= in.size(); b += 6){
		float t[2][3];
		for(size_t c = 0; c < 2; c++){
			for(size_t r = 0; r < 3; r++){
				float v = 0;
				for(size_t k = 0; k < 3; k++)
					v += m[r][k] * in[b + c * 3 + k];
				t[c][r] = std::min(0.5f, std::max(-0.5f, v));
			}
		}
		for(size_t c = 0; c < 2; c++)
			for(size_t r = 0; r < 3; r++)
				out.push_back(c == 0 ? std::min(t[0][r], t[1][r]) :
						std::max(t[0][r], t[1][r]));
	}
}

// One point turned a quarter at a time in the plane of two of its axes, and
// the same by an arbitrary angle. Irrlicht's rotateXZBy and friends, which is
// all Luanti's own node shapes turn by.
inline void turn_quarters(float v[3], int ia, int ib, int quarters)
{
	static const float SIN[4] = {0, 1, 0, -1};
	static const float COS[4] = {1, 0, -1, 0};
	const int i = ((quarters % 4) + 4) % 4;
	const float a = v[ia], b = v[ib];
	v[ia] = COS[i] * a - SIN[i] * b;
	v[ib] = SIN[i] * a + COS[i] * b;
}

inline void turn_degrees(float v[3], int ia, int ib, float deg)
{
	// Not M_PI: the module compile has Urho3D's own M_PI in scope
	const float r = deg * 3.14159265358979323846f / 180.0f;
	const float s = std::sin(r), c = std::cos(r);
	const float a = v[ia], b = v[ib];
	v[ia] = c * a - s * b;
	v[ib] = s * a + c * b;
}

// How far the single quad of a sign or a torch is turned for each wall
// direction, in quarters. It starts against +X; Luanti's drawSignlikeNode
// and drawTorchlikeNode.
inline int wall_quad_turn(size_t wall)
{
	switch(wall){
	case 2: return 0;
	case 3: return 2;
	case 4: return 1;
	case 5: return -1;
	default: return 0;
	}
}

// A rail's tile and turn per mask of its four horizontal connections, which
// is Luanti's own rail_kinds table from content_mapblock.cpp: a rail with
// nothing or one thing beside it is straight, two opposite ones straight, two
// beside each other a curve, three a junction and four a crossing. The tiles
// are the node's first four in that order, and what turns is the quad rather
// than the texture, which is what Luanti turns too.
//
// The mask's bits are Luanti's own for this: +Z is 1, -Z is 2, -X is 4 and
// +X is 8. Taken from extensions/luanti_client/shapes.lua.
struct RailKind { uint8_t tile; int degrees; };
static const RailKind RAIL_KINDS[16] = {
	{0, 0}, {0, 0}, {0, 0}, {0, 0},
	{0, 90}, {1, 180}, {1, 270}, {2, 180},
	{0, 90}, {1, 90}, {1, 0}, {2, 0},
	{0, 90}, {2, 90}, {2, 270}, {3, 0},
};

// And the turn of a rail that climbs towards one of the four, in the order
// the masks 16...19 are in: +Z, -Z, -X, +X. Luanti's rail_slope_angle.
static const int RAIL_SLOPE_TURNS[4] = {0, 180, 90, -90};

// A wallmounted direction is a facedir too; Luanti's own
// wallmounted_to_facedir[]. 6 and 7 are the two spare states, which are
// the ceiling and the floor turned a quarter.
static const uint8_t WALLMOUNTED_FACEDIR[8] = {20, 0, 17, 15, 8, 6, 21, 1};

// The quads from first onwards, turned about Y in place
inline void turn_quads_y(sv_<interface::VoxelQuad> &out, size_t first,
		int quarters)
{
	if(((quarters % 4) + 4) % 4 == 0)
		return;
	for(size_t i = first; i < out.size(); i++){
		for(size_t c = 0; c < 4; c++)
			turn_quarters(out[i].p[c], 0, 2, quarters);
	}
}

// Four corners and a tile, with the texture filling the quad
inline void push_quad(sv_<interface::VoxelQuad> &out, const float p[4][3],
		uint8_t tile)
{
	static const float UV[4][2] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
	interface::VoxelQuad q;
	for(size_t i = 0; i < 4; i++){
		for(size_t j = 0; j < 3; j++)
			q.p[i][j] = p[i][j];
		q.uv[i][0] = UV[i][0];
		q.uv[i][1] = UV[i][1];
	}
	q.tile = tile;
	out.push_back(q);
}

// One box of a node box, as six quads in the voxel's own -0.5...0.5
// cube -- which is where Luanti's node boxes already are, so a box
// arrives as it was written.
//
// The corners of each face go counter-clockwise seen from outside it,
// because the mesher takes (p1-p0) x (p2-p0) for the normal. Each face
// shows the part of the node's texture it covers, the way Luanti's
// makeCuboid does: without that a slab wears the whole texture squeezed
// into it. See doc/plan/luanti_module_plan.md, "What a VoxelQuad has to
// be".
inline void add_box_quads(sv_<interface::VoxelQuad> &out,
		float x0, float y0, float z0, float x1, float y1, float z1)
{
	if(x1 < x0) std::swap(x0, x1);
	if(y1 < y0) std::swap(y0, y1);
	if(z1 < z0) std::swap(z0, z1);
	// The box's extents as fractions of the cube, which is what the
	// texture is cut out by
	const float ux0 = x0 + 0.5f, ux1 = x1 + 0.5f;
	const float uy0 = y0 + 0.5f, uy1 = y1 + 0.5f;
	const float uz0 = z0 + 0.5f, uz1 = z1 + 0.5f;
	auto quad = [&](uint8_t tile,
			float ax, float ay, float az, float au, float av,
			float bx, float by, float bz, float bu, float bv,
			float cx, float cy, float cz, float cu, float cv,
			float dx, float dy, float dz, float du, float dv){
		interface::VoxelQuad q;
		const float p[4][3] = {{ax, ay, az}, {bx, by, bz},
				{cx, cy, cz}, {dx, dy, dz}};
		const float uv[4][2] = {{au, av}, {bu, bv}, {cu, cv}, {du, dv}};
		for(size_t i = 0; i < 4; i++){
			for(size_t j = 0; j < 3; j++)
				q.p[i][j] = p[i][j];
			q.uv[i][0] = uv[i][0];
			q.uv[i][1] = uv[i][1];
		}
		q.tile = tile;
		out.push_back(q);
	};
	// +Y, u along x and v against z, so the top reads the way it does on
	// a full cube
	quad(0, x0, y1, z1, ux0, 1-uz1,  x1, y1, z1, ux1, 1-uz1,
			x1, y1, z0, ux1, 1-uz0,  x0, y1, z0, ux0, 1-uz0);
	// -Y
	quad(1, x0, y0, z0, ux0, uz0,    x1, y0, z0, ux1, uz0,
			x1, y0, z1, ux1, uz1,    x0, y0, z1, ux0, uz1);
	// +X
	quad(2, x1, y0, z1, uz1, 1-uy0,  x1, y0, z0, uz0, 1-uy0,
			x1, y1, z0, uz0, 1-uy1,  x1, y1, z1, uz1, 1-uy1);
	// -X
	quad(3, x0, y0, z0, 1-uz0, 1-uy0, x0, y0, z1, 1-uz1, 1-uy0,
			x0, y1, z1, 1-uz1, 1-uy1, x0, y1, z0, 1-uz0, 1-uy1);
	// +Z
	quad(4, x0, y0, z1, 1-ux0, 1-uy0, x1, y0, z1, 1-ux1, 1-uy0,
			x1, y1, z1, 1-ux1, 1-uy1, x0, y1, z1, 1-ux0, 1-uy1);
	// -Z
	quad(5, x1, y0, z0, ux1, 1-uy0,  x0, y0, z0, ux0, 1-uy0,
			x0, y1, z0, ux0, 1-uy1,  x1, y1, z0, ux1, 1-uy1);
}

// Luanti's eight liquid levels, and how high the surface of one stands
// in its own voxel. A liquid whose range is shorter than eight spends
// its levels on the top of the voxel and everything below them is the
// floor, which is Luanti's own arithmetic.
//
// The top level is the top of the voxel: that is what a node with the
// same liquid above it or a source beside it comes to, and a node at the
// top level is nearly always one of those. Between levels the mesher
// averages the four columns around each corner -- Luanti's
// getCornerLevel, which the engine already does for anything marked
// is_liquid -- so a slope is a slope and not a flight of steps.
static const int LIQUID_LEVELS = 8;

// Luanti's own: -0.5 + (level - (8 - range) + 0.5) / range, so a level-7
// node at VoxeLibre's range of 7 sits at 0.43, a fourteenth down --
// the dip beside every source that is the shoreline and the river.
// The early return to 0.5 for level 7 that stood here flattened it
// ([LIQUID_SURFACE]); the corner rule in the mesher is where a
// source's full height wins, not here.
inline float liquid_level_top(int level, int range)
{
	if(range < 1)
		range = 1;
	if(range > LIQUID_LEVELS)
		range = LIQUID_LEVELS;
	const int floor_levels = LIQUID_LEVELS - range;
	level = (level <= floor_levels) ? 0 : level - floor_levels;
	return -0.5f + ((float)level + 0.5f) / (float)range;
}

// Luanti's plantlike: two quads crossing at the middle of the voxel,
// drawn from both sides. visual_scale makes it wider and taller, rooted
// at the bottom of the voxel, which is what Luanti does with it.
//
// base is where the plant stands: the floor of its own voxel for
// plantlike, and the top of it for plantlike_rooted, whose plant is
// drawn into the space above the cube it is rooted in.
// shape: meshoptions' bits 0-2 -- 0 the "x" (two quads on the
// diagonals), 1 the "+" (two quads on the axes), 2 the "*" (three
// quads 60 degrees apart), 3 the "#" (four quads, two along each axis
// a quarter in from the middle), 4 the "#" leaning outwards. Each
// quad is visual_scale wide, as official's drawPlantlike has it
// (vertices at +-BS/2 * scale, then the turn), so a diagonal quad's
// reach along an axis is that over sqrt(2): a cross from corner to
// corner was 41 % too wide at every scale ([PLANT_SIZE]).
inline void add_plant_quads(sv_<interface::VoxelQuad> &out, float scale,
		float base = -0.5f, uint8_t tile = 0, unsigned shape = 0)
{
	const float half = 0.5f * scale;
	const float r = half * 0.70710678f;
	const float y0 = base;
	const float y1 = base + scale;
	auto quad = [&](float ax, float az, float bx, float bz){
		interface::VoxelQuad q;
		const float p[4][3] = {{ax, y0, az}, {bx, y0, bz},
				{bx, y1, bz}, {ax, y1, az}};
		const float uv[4][2] = {{0, 1}, {1, 1}, {1, 0}, {0, 0}};
		for(size_t i = 0; i < 4; i++){
			for(size_t j = 0; j < 3; j++)
				q.p[i][j] = p[i][j];
			q.uv[i][0] = uv[i][0];
			q.uv[i][1] = uv[i][1];
		}
		q.tile = tile;
		out.push_back(q);
	};
	switch(shape){
	case 1: // +
		quad(-half, 0, half, 0);
		quad(0, half, 0, -half);
		break;
	case 2: // *, three at 60 degrees, the first along x
		for(int i = 0; i < 3; i++){
			const float a = (float)i * 3.14159265f / 3.0f;
			const float dx = half * cosf(a), dz = half * sinf(a);
			quad(-dx, -dz, dx, dz);
		}
		break;
	case 3: // #, two along each axis, a quarter in from the middle
	case 4: // the same leaning outwards; simplified: drawn upright
		quad(-half, -0.25f * scale, half, -0.25f * scale);
		quad(-half, 0.25f * scale, half, 0.25f * scale);
		quad(-0.25f * scale, half, -0.25f * scale, -half);
		quad(0.25f * scale, half, 0.25f * scale, -half);
		break;
	default: // x
		quad(-r, -r, r, r);
		quad(-r, r, r, -r);
		break;
	}
}

// One quad lying flat against the surface it is mounted on, which is what
// a sign is: Luanti's drawSignlikeNode. It starts against the +X wall and
// is turned to whichever wall the wallmounted direction names.
inline void add_sign_quads(sv_<interface::VoxelQuad> &out, float scale,
		size_t wall)
{
	const float size = 0.5f * scale;
	const float off = 0.5f - 1.0f / 16.0f;
	float p[4][3] = {
		{off, size, size}, {off, size, -size},
		{off, -size, -size}, {off, -size, size},
	};
	for(size_t c = 0; c < 4; c++){
		if(wall == 0)
			turn_quarters(p[c], 0, 1, 1);       // Ceiling
		else if(wall == 1)
			turn_quarters(p[c], 0, 1, -1);      // Floor
		else
			turn_quarters(p[c], 0, 2, wall_quad_turn(wall));
	}
	push_quad(out, p, 0);
}

// One quad hanging off the wall at an angle, which is what a torch is:
// Luanti's drawTorchlikeNode. The tile is the definition's second for a
// ceiling and its third for a wall, as Luanti picks them.
inline void add_torch_quads(sv_<interface::VoxelQuad> &out, float scale,
		size_t wall)
{
	const float size = 0.5f * scale;
	uint8_t tile = 0;
	float p[4][3] = {
		{-size, size, 0}, {size, size, 0},
		{size, -size, 0}, {-size, -size, 0},
	};
	for(size_t c = 0; c < 4; c++){
		if(wall == 0 || wall == 6){             // Ceiling
			tile = 1;
			p[c][1] += 0.5f - size;
			turn_degrees(p[c], 0, 2, wall == 0 ? -45.0f : 45.0f);
		} else if(wall == 1 || wall == 7){      // Floor
			p[c][1] += size - 0.5f;
			turn_degrees(p[c], 0, 2, wall == 1 ? 45.0f : -45.0f);
		} else {
			tile = 2;
			p[c][0] += 0.5f - size;
			turn_quarters(p[c], 0, 2, wall_quad_turn(wall));
		}
	}
	push_quad(out, p, tile);
}

inline void add_wall_quads(const ss_ &kind,
		sv_<interface::VoxelQuad> &out, float scale, size_t wall)
{
	if(kind == "torchlike")
		add_torch_quads(out, scale, wall);
	else
		add_sign_quads(out, scale, wall);
}

// A post in the middle and a pair of bars towards each direction that
// has something to reach: Luanti's drawFencelikeNode, at its own
// measurements -- an eighth for the post, a sixteenth for the bars, and
// the bars a quarter of the way up and down from the middle.
//
// The bars carry connect_dir, so the mesher draws each pair only when
// that direction connects. That is what connect_dir is for and it had no
// user; the header names a fence as the case.
inline void add_fence_quads(sv_<interface::VoxelQuad> &out)
{
	const float post = 1.0f / 8.0f;
	const float bar = 1.0f / 16.0f;
	const float h = 1.0f / 4.0f;
	add_box_quads(out, -post, -0.5f, -post, post, 0.5f, post);
	// The four horizontal faces, in the mesher's own order: +X, -X, +Z,
	// -Z, which are faces 2 to 5 and therefore connect_dir 3 to 6
	for(size_t f = 2; f < 6; f++){
		const bool along_x = (f < 4);
		const float sign = (f % 2 == 0) ? 1.0f : -1.0f;
		const float near_end = post * sign;
		const float far_end = 0.5f * sign;
		for(int level = 0; level < 2; level++){
			const float y = (level == 0 ? h : -h);
			const size_t first = out.size();
			if(along_x){
				add_box_quads(out, near_end, y - bar, -bar,
						far_end, y + bar, bar);
			} else {
				add_box_quads(out, -bar, y - bar, near_end,
						bar, y + bar, far_end);
			}
			for(size_t i = first; i < out.size(); i++)
				out[i].connect_dir = (uint8_t)(f + 1);
		}
	}
}

// One quad just off the floor, which is what a rail or anything else
// painted on the ground is
inline void add_flat_quad(sv_<interface::VoxelQuad> &out, uint8_t tile)
{
	const float y = -0.5f + 1.0f / 16.0f;
	const float d = 0.5f;
	const float p[4][3] = {
		{-d, y, d}, {d, y, d}, {d, y, -d}, {-d, y, -d},
	};
	push_quad(out, p, tile);
}

// A shape per mask of a rail's four horizontal connections: sixteen flat
// ones and four that climb. What a "shape per mask" is for is a voxel
// whose whole shape changes with what is around it rather than gaining a
// piece per direction, and the mesher picks one of these per voxel; see
// VoxelDefinition::shape_masked, which had no user before this.
inline void add_rail_shapes(sv_<interface::VoxelQuad> &out,
		uint16_t begin[21])
{
	for(size_t mask = 0; mask < 16; mask++){
		begin[mask] = (uint16_t)out.size();
		const size_t first = out.size();
		add_flat_quad(out, RAIL_KINDS[mask].tile);
		turn_quads_y(out, first, RAIL_KINDS[mask].degrees / 90);
	}
	for(size_t i = 0; i < 4; i++){
		begin[16 + i] = (uint16_t)out.size();
		const size_t first = out.size();
		add_flat_quad(out, 0);
		// The +Z edge lifted by exactly one node, which is the ramp
		// Luanti draws. One node rather than "up to the top of the
		// voxel", so that the raised end meets the flat rail a step
		// above it whatever height a flat rail floats at: they are the
		// same quad, one node apart.
		out[first].p[0][1] += 1.0f;
		out[first].p[1][1] += 1.0f;
		turn_quads_y(out, first, RAIL_SLOPE_TURNS[i] / 90);
	}
	begin[20] = (uint16_t)out.size();
}

// Asserts what add_box_quads() and add_plant_quads() build, because the
// winding is what makes the normal and a quad wound the wrong way is
// invisible rather than wrong-looking. builtin/luanti runs it once at
// start.
inline void check_shapes()
{
	auto normal_of = [](const interface::VoxelQuad &q, float n[3]){
		float e1[3], e2[3];
		for(size_t i = 0; i < 3; i++){
			e1[i] = q.p[1][i] - q.p[0][i];
			e2[i] = q.p[2][i] - q.p[0][i];
		}
		n[0] = e1[1]*e2[2] - e1[2]*e2[1];
		n[1] = e1[2]*e2[0] - e1[0]*e2[2];
		n[2] = e1[0]*e2[1] - e1[1]*e2[0];
	};
	sv_<interface::VoxelQuad> box;
	add_box_quads(box, -0.5f, -0.5f, -0.5f, 0.5f, 0.0f, 0.5f);
	assert(box.size() == 6);
	// Face f faces the way face f of a cube faces
	static const float WANT[6][3] = {
		{0, 1, 0}, {0, -1, 0}, {1, 0, 0},
		{-1, 0, 0}, {0, 0, 1}, {0, 0, -1},
	};
	for(size_t f = 0; f < 6; f++){
		float n[3];
		normal_of(box[f], n);
		assert(box[f].tile == f);
		for(size_t i = 0; i < 3; i++)
			assert(n[i] * WANT[f][i] >= 0.0f);
		float dot = n[0]*WANT[f][0] + n[1]*WANT[f][1] + n[2]*WANT[f][2];
		assert(dot > 0.0f);
		// Every corner is inside the cube and every uv inside the tile
		for(size_t c = 0; c < 4; c++){
			for(size_t i = 0; i < 3; i++)
				assert(box[f].p[c][i] >= -0.5f && box[f].p[c][i] <= 0.5f);
			for(size_t i = 0; i < 2; i++)
				assert(box[f].uv[c][i] >= 0.0f && box[f].uv[c][i] <= 1.0f);
		}
	}
	// A slab's top is at y=0 and its texture is the top half of the tile
	// in the two axes it spans, not a squeezed whole one
	assert(box[0].p[0][1] == 0.0f);
	assert(box[2].uv[0][1] == 1.0f && box[2].uv[2][1] == 0.5f);
	// A box given its corners the other way round is the same box
	sv_<interface::VoxelQuad> flipped;
	add_box_quads(flipped, 0.5f, 0.0f, 0.5f, -0.5f, -0.5f, -0.5f);
	assert(flipped.size() == box.size());
	for(size_t i = 0; i < box.size(); i++){
		for(size_t c = 0; c < 4; c++){
			for(size_t j = 0; j < 3; j++)
				assert(flipped[i].p[c][j] == box[i].p[c][j]);
		}
	}
	// The facedir tables: every row a permutation of the six faces, with
	// opposite faces still opposite -- which is what a rotation of a cube
	// can do and nothing else is. A transcription error shows up here
	// rather than as a chest with two lids.
	for(size_t d = 0; d < 24; d++){
		bool seen[6] = {};
		for(size_t f = 0; f < 6; f++){
			assert(FACEDIR_TILES[d][f] < 6);
			assert(!seen[FACEDIR_TILES[d][f]]);
			seen[FACEDIR_TILES[d][f]] = true;
			assert(FACEDIR_TURNS[d][f] < 4);
		}
		// Faces 0 and 1 are opposite, and so are 2 and 3 and 4 and 5
		for(size_t f = 0; f < 6; f += 2)
			assert((FACEDIR_TILES[d][f] ^ 1) == FACEDIR_TILES[d][f + 1]);
	}
	// Facedir 0 changes nothing
	for(size_t f = 0; f < 6; f++){
		assert(FACEDIR_TILES[0][f] == f);
		assert(FACEDIR_TURNS[0][f] == 0);
	}
	// Each facedir matrix is a proper rotation -- an orthonormal basis
	// with determinant 1 -- and it takes each local face to the world
	// face the table says wears its tile. Derived from the table, so
	// this is the table checking itself against what a rotation can be.
	for(size_t d = 0; d < 24; d++){
		int m[3][3] = {};
		facedir_matrix((uint8_t)d, m);
		const int det =
				m[0][0]*(m[1][1]*m[2][2] - m[1][2]*m[2][1]) -
				m[0][1]*(m[1][0]*m[2][2] - m[1][2]*m[2][0]) +
				m[0][2]*(m[1][0]*m[2][1] - m[1][1]*m[2][0]);
		assert(det == 1);
		for(size_t c = 0; c < 3; c++){
			int len = 0;
			for(size_t r = 0; r < 3; r++)
				len += m[r][c] * m[r][c];
			assert(len == 1);
		}
		// Facedir 0 turns nothing
		if(d == 0){
			for(size_t r = 0; r < 3; r++)
				for(size_t c = 0; c < 3; c++)
					assert(m[r][c] == (r == c ? 1 : 0));
		}
	}
	// A box turned four quarters about any axis is the box it was
	{
		sv_<interface::VoxelQuad> a, b;
		add_box_quads(a, -0.5f, -0.5f, -0.5f, 0.5f, 0.0f, 0.25f);
		turn_quads(a, 0, b);
		assert(b.size() == a.size());
		for(size_t i = 0; i < a.size(); i++){
			for(size_t c = 0; c < 4; c++){
				for(size_t j = 0; j < 3; j++)
					assert(a[i].p[c][j] == b[i].p[c][j]);
			}
		}
		// Facedir 20 is the node stood on its head: y flips
		turn_quads(a, 20, b);
		for(size_t i = 0; i < a.size(); i++){
			for(size_t c = 0; c < 4; c++)
				assert(b[i].p[c][1] == -a[i].p[c][1]);
		}
	}

	// A wallmounted direction is one of the twenty-four
	for(size_t i = 0; i < 8; i++)
		assert(WALLMOUNTED_FACEDIR[i] < 24);

	// A fence is a post that is always drawn and four pairs of bars that
	// are drawn only when their direction connects, which is what
	// connect_dir says
	{
		sv_<interface::VoxelQuad> fence;
		add_fence_quads(fence);
		// One post and eight bars, six quads each
		assert(fence.size() == 9 * 6);
		size_t always = 0;
		uint8_t seen[7] = {};
		for(const interface::VoxelQuad &q : fence){
			assert(q.connect_dir < 7);
			if(q.connect_dir == 0)
				always++;
			else
				seen[q.connect_dir]++;
			for(size_t c = 0; c < 4; c++){
				for(size_t j = 0; j < 3; j++){
					assert(q.p[c][j] >= -0.5f && q.p[c][j] <= 0.5f);
				}
			}
		}
		assert(always == 6);           // The post
		for(size_t d = 3; d <= 6; d++)
			assert(seen[d] == 12);     // Two bars each way
		assert(seen[1] == 0 && seen[2] == 0); // Nothing up or down
	}

	// A rail is one quad per mask, twenty of them, and the offsets say
	// where each begins. The flat ones lie just off the floor; the four
	// that climb have two corners a node higher than the rest.
	{
		sv_<interface::VoxelQuad> rails;
		uint16_t begin[21] = {};
		add_rail_shapes(rails, begin);
		assert(rails.size() == 20);
		assert(begin[0] == 0 && begin[20] == 20);
		for(size_t m = 0; m < 20; m++){
			assert(begin[m + 1] == begin[m] + 1);
			const interface::VoxelQuad &q = rails[begin[m]];
			assert(q.tile < 4);
			int high = 0;
			for(size_t c = 0; c < 4; c++){
				// A turn about Y leaves x and z inside the voxel
				assert(q.p[c][0] >= -0.5f && q.p[c][0] <= 0.5f);
				assert(q.p[c][2] >= -0.5f && q.p[c][2] <= 0.5f);
				if(q.p[c][1] > 0.0f)
					high++;
			}
			assert(high == (m >= 16 ? 2 : 0));
		}
		// Nothing beside it and everything beside it are the two Luanti
		// draws with its first and fourth tiles
		assert(rails[begin[0]].tile == 0);
		assert(rails[begin[15]].tile == 3);

	}

	// A sign lies flat against the surface it is on, so its quad has a
	// normal along one axis and sits just off the boundary in that
	// direction. A torch leans, so its normal has no zero component in
	// the plane it leans in.
	for(size_t wall = 0; wall < 8; wall++){
		sv_<interface::VoxelQuad> sign, torch;
		add_sign_quads(sign, 1.0f, wall);
		add_torch_quads(torch, 1.0f, wall);
		assert(sign.size() == 1 && torch.size() == 1);
		for(const sv_<interface::VoxelQuad> *qs : {&sign, &torch}){
			for(size_t c = 0; c < 4; c++){
				for(size_t j = 0; j < 3; j++){
					// Inside the voxel, give or take the rounding a
					// 45 degree turn leaves
					assert((*qs)[0].p[c][j] > -0.71f &&
							(*qs)[0].p[c][j] < 0.71f);
				}
			}
		}
		// A wall torch wears the definition's third tile, a ceiling one
		// its second and a floor one its first; Luanti's own choice
		assert(torch[0].tile == (wall <= 1 || wall >= 6 ?
				(wall == 0 || wall == 6 ? 1 : 0) : 2));
	}

	// The plant is two quads that cross, standing on the voxel's floor
	sv_<interface::VoxelQuad> plant;
	add_plant_quads(plant, 1.0f);
	assert(plant.size() == 2);
	for(const interface::VoxelQuad &q : plant){
		float n[3];
		normal_of(q, n);
		assert(std::fabs(n[1]) < 1e-6f); // Upright
		assert(n[0] != 0.0f || n[2] != 0.0f);
		assert(q.p[0][1] == -0.5f && q.p[2][1] == 0.5f);
	}
}
}
// vim: set noet ts=4 sw=4:
