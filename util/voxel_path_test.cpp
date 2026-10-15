// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// The voxel pathfinder's check ([SKELDAT]): its self test, and the time a
// search takes on what a player covers in a second at twice the walk speed
// (8 voxels), over rough random ground. Plain g++, no build system:
//
//   g++ -O2 -std=c++14 -Isrc util/voxel_path_test.cpp
//       src/impl/voxel_path.cpp -o /tmp/voxel_path_test && /tmp/voxel_path_test
//   (one line)
#include "interface/voxel_path.h"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <random>

using namespace interface::voxel_path;

int main()
{
	if(!self_test()){
		printf("FAIL: self_test\n");
		return 1;
	}
	// A box a second's reach each way: 8 out, twice that and one across,
	// and room up and down for hills, a ceiling of pillars and their falls
	const int R = 9, W = 2 * R + 1, H = 24;
	std::mt19937 rng(1);
	Rules r;
	r.max_length = 8;
	int found = 0, tries = 0;
	size_t expanded = 0;
	double total_us = 0, worst_us = 0;
	for(int world = 0; world < 50; world++){
		Field f;
		f.resize(P(-R, 0, -R), W, H, W);
		// Hills 8..12 high, a pillar here and there
		const float px = (float)(rng() % 100), pz = (float)(rng() % 100);
		for(int z = -R; z <= R; z++){
			for(int x = -R; x <= R; x++){
				const int top = 10 + (int)std::lround(
						std::sin((x + px) / 3.0f) + std::cos((z + pz) / 4.0f));
				for(int y = 0; y < top; y++)
					f.set(x, y, z, SOLID);
				if(rng() % 10 == 0)
					for(int y = top; y < top + 3; y++)
						f.set(x, y, z, SOLID);
			}
		}
		P from(0, H - 2, 0);
		if(!settle(f, r, from))
			continue;
		for(int k = 0; k < 20; k++){
			P to((int)(rng() % W) - R, H - 2, (int)(rng() % W) - R);
			if(!settle(f, r, to))
				continue;
			const auto t0 = std::chrono::steady_clock::now();
			const Result res = find(f, from, to, r);
			const double us = std::chrono::duration<double, std::micro>(
					std::chrono::steady_clock::now() - t0).count();
			total_us += us;
			if(us > worst_us)
				worst_us = us;
			expanded += res.expanded;
			tries++;
			if(res.found)
				found++;
		}
	}
	printf("voxel_path: self test passed; %d searches on a %dx%dx%d box, "
			"%d found, mean %.1f us (worst %.1f), %.0f cells expanded each\n",
			tries, W, H, W, found, total_us / tries, worst_us,
			(double)expanded / tries);
	return 0;
}
// vim: set noet ts=4 sw=4:
