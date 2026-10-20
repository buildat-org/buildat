#!/bin/bash
# tier: quick
# ci
# cost: ~2s (2026-10-20)
# covers: src/interface/noise.h
# [NOISE_API]: interface::noise's ranges (value and fbm in -1..1, the
# ridged in 0..1), the same seed the same values and another seed others,
# and fill2/fill3 the same values as noise2/noise3 point by point.
#   util/noise_check.sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "${t:?}"' EXIT
cat > "$t/c.cpp" <<'CPP'
#include "interface/noise.h"
#include <cassert>
using namespace interface::noise;
int main()
{
	int differ = 0;
	for(int i = 0; i < 200000; i++){
		const float x = i * 0.37f - 5000, y = i * 0.11f - 300, z = i * 0.73f;
		const float v[] = {value2(x, z, 7), value3(x, y, z, 7),
				fbm2(x, z, 7, 6, 0.6f), fbm3(x, y, z, 7, 5, 0.5f)};
		for(float a : v)
			assert(a >= -1.0001f && a <= 1.0001f);
		const float r[] = {fbm2_abs(x, z, 7, 4, 0.5f),
				fbm3_abs(x, y, z, 7, 4, 0.5f)};
		for(float a : r)
			assert(a >= 0 && a <= 1.0001f);
		assert(fbm2(x, z, 7, 6, 0.6f) == fbm2(x, z, 7, 6, 0.6f));
		differ += fbm2(x, z, 7, 3, 0.5f) != fbm2(x, z, 8, 3, 0.5f);
	}
	assert(differ > 190000);
	const NoiseParams p = {5, 3, 40, 20, 30, 4, 0.5f};
	std::vector<float> m;
	fill2(p, 3, -17, 9, 13, 11, m);
	for(int z = 0; z < 11; z++)
		for(int x = 0; x < 13; x++)
			assert(m[z * 13 + x] == noise2(p, 3, -17 + x, 9 + z));
	fill3(p, 3, 4, -6, 2, 5, 6, 7, m);
	for(int z = 0; z < 7; z++)
		for(int y = 0; y < 6; y++)
			for(int x = 0; x < 5; x++)
				assert(m[(z * 6 + y) * 5 + x] == noise3(p, 3, 4 + x, -6 + y, 2 + z));
	return 0;
}
CPP
c++ -std=c++11 -O1 -I"$here/src" "$t/c.cpp" -o "$t/c" && "$t/c"
echo "PASS: interface::noise in its ranges, the same for a seed, and the fills its points"
