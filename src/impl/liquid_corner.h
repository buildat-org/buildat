// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// How high a liquid's surface stands at one corner of a voxel, from the four
// columns that meet there; mesh.cpp's liquid_corner_top() reads them out of
// the volume. Apart so that it can be checked without Urho3D:
//   util/liquid_step_check.sh
#pragma once

// One of the four columns, at the voxel's row y. "The liquid" is the voxel's
// own (the same shape_group).
struct LiquidColumn {
	enum Kind { OTHER, EMPTY, SOURCE, FLOW } kind = OTHER;
	float top = 0.0f; // a FLOW's own surface; a flow with no level is SOURCE
	bool above = false; // the liquid at y + 1
	bool below = false; // the liquid at y - 1
};

// The average of the flowing columns' surfaces: Luanti's getCornerLevel,
// a surface that runs continuously from one level to the next instead of
// stepping down. On top of it, in this order:
// - A column with the liquid above it: full to the top of the voxel,
//   because that is a body of liquid rather than a surface -- and **not
//   sagged** ([SKELDAT_WATER_STEP] 2): the voxel is full there, and a sag
//   opened a slit under the side of the voxel above at a river's step down.
// - A source column: full, sagged (Luanti's "Source always has the full
//   height").
// - An empty column over the liquid: the bottom, not sagged, which is
//   where the corner of the voxel below stands by the first rule
//   ([SKELDAT_WATER_STEP] 3). Without it a corner one empty column of four
//   touches stayed at its row's level, up to a voxel over the water below.
// - Two empty columns: the bottom, a fiftieth up (0.2 / BS), so the edge of
//   a spill thins out rather than stands as a wall; no flowing column at
//   all: the middle.
// The rest are sagged by `sag`, the look of every liquid (mesh.cpp's
// LIQUID_SAG).
static inline float liquid_corner(const LiquidColumn c[4], float sag)
{
	for(int i = 0; i < 4; i++)
		if(c[i].above)
			return 0.5f;
	for(int i = 0; i < 4; i++)
		if(c[i].kind == LiquidColumn::SOURCE)
			return 0.5f - sag;
	float sum = 0.0f;
	int count = 0;
	int empty = 0;
	for(int i = 0; i < 4; i++){
		if(c[i].kind == LiquidColumn::EMPTY){
			if(c[i].below)
				return -0.5f;
			empty++;
		} else if(c[i].kind == LiquidColumn::FLOW){
			sum += c[i].top;
			count++;
		}
	}
	if(empty >= 2)
		return -0.5f + 0.02f - sag;
	if(count == 0)
		return 0.0f - sag;
	return sum / count - sag;
}

#ifdef LIQUID_CORNER_SELF_TEST
#include <cmath>
#include <cstdio>

// A river's step: flowing water at level `top` in row 1 over stone, air in
// row 1 over water in row 0. `wet[i]` says which of the corner's four
// columns hold the upper water; the rest are the step. Both voxels' heights
// at the corner, in rows: the upper's (row 1) and the lower's (row 0).
static int step(const char *what, const bool wet[4], float top)
{
	const float sag = 1.0f / 8.0f;
	LiquidColumn up[4], low[4];
	for(int i = 0; i < 4; i++){
		if(wet[i]){
			up[i].kind = LiquidColumn::FLOW;
			up[i].top = top;
			low[i].kind = LiquidColumn::OTHER; // the stone under the river
			low[i].above = true;
		} else {
			up[i].kind = LiquidColumn::EMPTY;
			up[i].below = true;
			low[i].kind = LiquidColumn::FLOW;
			low[i].top = top;
		}
	}
	float u = 1.0f + liquid_corner(up, sag);
	float l = 0.0f + liquid_corner(low, sag);
	bool ok = std::fabs(u - l) <= 0.01f;
	printf("%s %s: the upper voxel's corner %.3f, the lower's %.3f%s\n",
			ok ? "ok  " : "FAIL", what, u, l,
			ok ? "" : u > l ? " (the upper too high)" : " (the lower too low)");
	return ok ? 0 : 1;
}

int main()
{
	int bad = 0;
	const bool straight[4] = {true, false, true, false};
	const bool diagonal[4] = {true, true, true, false};
	const bool point[4] = {true, false, false, false};
	const float tops[] = {0.4f, 0.0f, -0.3f};
	for(float top : tops){
		bad += step("straight", straight, top);
		bad += step("diagonal", diagonal, top);
		bad += step("a point ", point, top);
	}
	// The rest as they were: a spill's edge thins, a source stands full
	LiquidColumn spill[4];
	spill[0].kind = LiquidColumn::FLOW;
	spill[0].top = 0.2f;
	spill[1].kind = spill[2].kind = LiquidColumn::EMPTY;
	bad += std::fabs(liquid_corner(spill, 0.125f) - (-0.48f - 0.125f)) > 1e-5f;
	spill[3].kind = LiquidColumn::SOURCE;
	bad += std::fabs(liquid_corner(spill, 0.125f) - 0.375f) > 1e-5f;
	printf(bad ? "FAIL\n" : "PASS\n");
	return bad ? 1 : 0;
}
#endif
