// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// What the server (main.cpp) and its client's prediction (predict.cpp)
// share ([CLIENT_WASM] step 5): the car as the server has it, sent to its
// own client as these structs' bytes, hex in the packet (x86-64 and wasm32
// lay them out alike: floats and 32-bit ints; the static_asserts hold it).
#pragma once
#include "car.h"
#include <stdint.h>

namespace predict {

// hillclimb:setup, on joining and on each change of the car: car.h's Spec
// (the knobs' power and grip), the payload, and the bottom pad's surface
// (Hill::BASE), the ground where no voxels are
struct Setup
{
	car::Spec spec;
	float payload = 0;
	int32_t base = 0;
};

// hillclimb:state, every tick: the chassis as Bullet has it, in voxels
// (a voxel is 1/8 m), and car.h's state
struct State
{
	float pos[3];  // the centre of mass
	float rot[4];  // w x y z
	float vel[3];  // voxels/s
	float ang[3];  // rad/s
	float shaft, spin, pedal, brake, steer;
	float brush[4][2];
};

static_assert(sizeof(car::Spec) == 34 * 4, "car::Spec is floats");
static_assert(sizeof(Setup) == 36 * 4, "Setup's bytes");
static_assert(sizeof(State) == 26 * 4, "State's bytes");

} // namespace predict

// The car's step, the chassis' integrator and car_math.h over a made-up
// ground, 120 substeps (0.5 s) of scripted input: a hash of every state's
// bits along the way. The server logs its own (gcc, native) and sends it
// to the client, whose .wasm's must be the same.
extern "C" uint32_t hc_selftest(void);
