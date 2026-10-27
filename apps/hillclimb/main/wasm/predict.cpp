// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// hillclimb's car predicted on its own client ([CLIENT_WASM] step 5), in
// the module's .wasm: car.h's step, the one the server runs, from this
// client's input at once, each substep (240 Hz) kept for 0.5 s with the
// input it took. The server's state of the car (hillclimb:state, every
// tick) is the authority: it names the input it was stepped under (the
// client's numbered packets) and for how many substeps, which is the
// substep here it is compared with; off by more than a centimetre (or 5
// cm/s, or about half a degree), the car is set to it and the
// substeps since are stepped again with their inputs: a correction.
//
// What differs from the server's car, so what a correction mends:
// - the chassis: the server's is a Bullet body; here it is integrated as
//   Bullet integrates one that touches nothing (its forces, the velocity,
//   then the pose by the exponential map), without Bullet's gyroscopic
//   term and its contacts (a chassis on the ground, a stone's push);
// - the ground: what voxelworld gave this client (Lua hands the module
//   the chunks round the car), where a part-full sand voxel under half is
//   air and the rest full (the server's fill is not sent), and no stone
//   comes loose;
// - when an input took effect: the server's tick applies it at the
//   substep it came in at, here at the frame it was pressed in.
// The server compiles this file natively too (as every module's wasm/):
// its hc_selftest() is the reference the client's is compared with.
#include "interface/wasm_api.h"
#include "predict.h"

#ifdef BUILDAT_WASM_MODULE
// What the C++ here needs of a runtime, with no libc: Ground's vtable, its
// virtual destructor's delete (never called: nothing is allocated), the
// global constructors, run once by hc_init(), and their destructors'
// registration (a module is never torn down: nothing to run)
extern "C" void __cxa_pure_virtual(){ __builtin_trap(); }
void operator delete(void *) noexcept {}
void operator delete(void *, __SIZE_TYPE__) noexcept {}
extern "C" int __cxa_atexit(void (*)(void *), void *, void *){ return 0; }
void *__dso_handle;
extern "C" void __wasm_call_ctors(void);
#endif

using car::V3;

namespace {

const float U = 8;             // voxels to the metre (hill.h's U)
const float DT = 1.0f / 240;   // main.cpp's SUBSTEPS_HZ
// Substeps kept: half a second, a round trip's time to correct by. The
// interpreter's budget for a call (before the compile is in, or with no
// compiler) is about 240 substeps: the meter charges the contact's loop
// body whole, ~190 a voxel tried, 5000 voxels a substep
const unsigned HIST = 120;

V3 v3(const float *a){ return V3(a[0], a[1], a[2]); }
// Component by component, as Urho3D's Vector3 / float
V3 div(const V3 &v, float k){ return V3(v.x / k, v.y / k, v.z / k); }

// Urho3D's Quaternion * Vector3 (q is w x y z), as main.cpp gets the axes
V3 rotate(const float q[4], const V3 &v)
{
	const V3 qv(q[1], q[2], q[3]);
	const V3 c1 = qv.cross(v), c2 = qv.cross(c1);
	return v + (c1 * q[0] + c2) * 2.0f;
}

struct Sim
{
	car::Car car;
	predict::State b; // the chassis' part of it: pos, rot, vel, ang
	Sim(): car(car::Spec(), 0)
	{
		b = predict::State();
		b.rot[0] = 1;
	}

	// One substep as main.cpp's step_car() and the physics' Update(): the
	// tyres' forces from the input and the ground, then the chassis
	void step(const car::Ground &g, const car::Input &in)
	{
		car.controls(in, DT);
		const V3 p = v3(b.pos), vel = v3(b.vel), ang = v3(b.ang);
		car::Pose pose;
		pose.pos = div(p, U);
		pose.right = rotate(b.rot, V3(1, 0, 0));
		pose.up = rotate(b.rot, V3(0, 1, 0));
		pose.forward = rotate(b.rot, V3(0, 0, 1));
		car.step(g, U, pose, [&](const V3 &at){
			// btRigidBody::getVelocityInLocalPoint()
			return div(vel + ang.cross(at * U - p), U);
		}, DT);
		// The forces, as ApplyForce() adds them, then gravity
		const float m = car.mass(), inv_m = 1.0f / m;
		V3 force, torque;
		for(const car::Wheel &w : car.wheel){
			if(w.load <= 0)
				continue;
			const V3 f = w.force * U, rel = w.at * U - p;
			force = force + f;
			torque = torque + rel.cross(f);
		}
		force = force + V3(0, -9.81f * U, 0) * m;
		// The world's inverse inertia: R diag(1 / I) R^T, I the box's
		const float *q = b.rot;
		const float s = 2.0f / (q[0] * q[0] + q[1] * q[1] + q[2] * q[2] +
				q[3] * q[3]);
		const float xs = q[1] * s, ys = q[2] * s, zs = q[3] * s;
		const float wx = q[0] * xs, wy = q[0] * ys, wz = q[0] * zs;
		const float xx = q[1] * xs, xy = q[1] * ys, xz = q[1] * zs;
		const float yy = q[2] * ys, yz = q[2] * zs, zz = q[3] * zs;
		const float R[3][3] = {{1 - (yy + zz), xy - wz, xz + wy},
				{xy + wz, 1 - (xx + zz), yz - wx},
				{xz - wy, yz + wx, 1 - (xx + yy)}};
		const car::Spec &sp = car.spec;
		const float lx = sp.box_w * U, ly = sp.box_h * U, lz = sp.box_l * U;
		const float inv_i[3] = {12 / (m * (ly * ly + lz * lz)),
				12 / (m * (lx * lx + lz * lz)), 12 / (m * (lx * lx + ly * ly))};
		const float t[3] = {torque.x, torque.y, torque.z};
		float local[3], dw[3];
		for(int i = 0; i < 3; i++)
			local[i] = (R[0][i] * t[0] + R[1][i] * t[1] + R[2][i] * t[2]) * inv_i[i];
		for(int i = 0; i < 3; i++)
			dw[i] = R[i][0] * local[0] + R[i][1] * local[1] + R[i][2] * local[2];
		// btRigidBody::integrateVelocities()
		const V3 nv = vel + force * (inv_m * DT);
		const V3 nw = ang + V3(dw[0], dw[1], dw[2]) * DT;
		// btTransformUtil::integrateTransform()
		const V3 np = p + nv * DT;
		float angle = nw.length();
		if(angle * DT > 0.785398163f)
			angle = 0.785398163f / DT;
		const V3 axis = angle < 0.001f ?
				nw * (0.5f * DT - (DT * DT * DT) * 0.020833333333f * angle * angle) :
				nw * (car_math::sinf_(0.5f * angle * DT) / angle);
		const float dq[4] = {car_math::cosf_(angle * DT * 0.5f), axis.x, axis.y,
				axis.z};
		float r[4] = {
			dq[0] * q[0] - dq[1] * q[1] - dq[2] * q[2] - dq[3] * q[3],
			dq[0] * q[1] + dq[1] * q[0] + dq[2] * q[3] - dq[3] * q[2],
			dq[0] * q[2] + dq[2] * q[0] + dq[3] * q[1] - dq[1] * q[3],
			dq[0] * q[3] + dq[3] * q[0] + dq[1] * q[2] - dq[2] * q[1]};
		const float n = car_math::sqrtf_(r[0] * r[0] + r[1] * r[1] +
				r[2] * r[2] + r[3] * r[3]);
		for(int i = 0; i < 4; i++)
			b.rot[i] = r[i] / n;
		b.pos[0] = np.x, b.pos[1] = np.y, b.pos[2] = np.z;
		b.vel[0] = nv.x, b.vel[1] = nv.y, b.vel[2] = nv.z;
		b.ang[0] = nw.x, b.ang[1] = nw.y, b.ang[2] = nw.z;
	}

	predict::State get() const
	{
		predict::State s = b;
		s.shaft = car.shaft;
		s.spin = car.spin;
		s.pedal = car.pedal;
		s.brake = car.brake;
		s.steer = car.steer;
		for(int i = 0; i < 4; i++){
			s.brush[i][0] = car.wheel[i].brush_x;
			s.brush[i][1] = car.wheel[i].brush_y;
		}
		return s;
	}
	void set(const predict::State &s)
	{
		b = s;
		car.shaft = s.shaft;
		car.spin = s.spin;
		car.pedal = s.pedal;
		car.brake = s.brake;
		car.steer = s.steer;
		for(int i = 0; i < 4; i++){
			car.wheel[i].brush_x = s.brush[i][0];
			car.wheel[i].brush_y = s.brush[i][1];
		}
	}
};

int floor_div(int a, int b){ return a >= 0 ? a / b : -((-a + b - 1) / b); }

// The ground this client has: chunks of voxelworld's (32 voxels a side),
// as main.cpp's ids (1 air, 2 sand, 3 stone, 4 fill, 5 wet sand; 0 none
// here), in 64 slots; past the hill's voxels, and in a chunk not here,
// the floor at the bottom pad's surface (ground::Grid's)
// The server's native build hands it no chunks: one slot
#ifdef BUILDAT_WASM_MODULE
const int CS = 32, SLOTS = 64;
#else
const int CS = 32, SLOTS = 1;
#endif
const int STONE = 3;
struct Slot { int cx, cy, cz; bool used; };
Slot g_slots[SLOTS];
uint8_t g_ids[SLOTS][CS * CS * CS];
predict::Setup g_setup;
int32_t g_size[3] = {0, 0, 0};

struct ChunkGround: public car::Ground
{
	mutable int last = -1;
	int slot(int cx, int cy, int cz) const
	{
		if(last >= 0 && g_slots[last].used && g_slots[last].cx == cx &&
				g_slots[last].cy == cy && g_slots[last].cz == cz)
			return last;
		for(int i = 0; i < SLOTS; i++)
			if(g_slots[i].used && g_slots[i].cx == cx && g_slots[i].cy == cy &&
					g_slots[i].cz == cz)
				return last = i;
		return -1;
	}
	bool inside(int x, int y, int z) const
	{
		return x >= 0 && y >= 0 && z >= 0 && x < g_size[0] && y < g_size[1] &&
				z < g_size[2];
	}
	// -1: not here
	int id(int x, int y, int z) const
	{
		const int cx = floor_div(x, CS), cy = floor_div(y, CS),
				cz = floor_div(z, CS);
		const int s = slot(cx, cy, cz);
		if(s < 0)
			return -1;
		return g_ids[s][((z - cz * CS) * CS + (y - cy * CS)) * CS + (x - cx * CS)];
	}
	bool solid(int x, int y, int z) const override
	{
		const int i = inside(x, y, z) ? id(x, y, z) : -1;
		return i < 0 || i == 0 ? y <= g_setup.base : i != 1;
	}
	// ground::Grid's ramp: a stone's voxel at most 2 over the ground
	// beside it that is not stone.
	// simplified: a column's top looked for from 16 over down to 2 under
	// (the hill is a height field; a column 2 m over is a wall either way)
	bool ramp(int x, int y, int z) const override
	{
		if(!inside(x, y, z) || id(x, y, z) != STONE)
			return false;
		static const int D[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
		for(auto &d : D){
			const int nx = x + d[0], nz = z + d[1];
			if(!inside(nx, 0, nz))
				continue;
			for(int t = y + 16; t >= y - 2; t--){
				if(t < 0 || t >= g_size[1] || !solid(nx, t, nz))
					continue;
				if(id(nx, t, nz) != STONE)
					return true;
				break;
			}
		}
		return false;
	}
};

Sim g_sim;
ChunkGround g_ground;
predict::State g_server;         // Lua writes the server's here
predict::State g_hist[HIST];     // the state before each substep
car::Input g_hist_in[HIST];      // and the input it took
uint32_t g_now = 0;              // substeps stepped
uint32_t g_valid = 0;            // the first one predicted from a state taken
car::Input g_in;
bool g_held = false;
uint32_t g_scratch[34 * 34 * 34];
float g_err[3];                  // the last compared: m, m/s, rad

car::Input effective()
{
	if(!g_held)
		return g_in;
	// main.cpp's: the brake on until the ground is made, and observing
	car::Input held;
	held.brake = true;
	held.gear = g_in.gear;
	return held;
}

void step(const car::Input &in)
{
	g_hist[g_now % HIST] = g_sim.get();
	g_hist_in[g_now % HIST] = in;
	g_sim.step(g_ground, in);
	g_now++;
}

// The self test's ground: bumps, part-full voxels and stones to ride up,
// from the coordinates alone
struct TestGround: public car::Ground
{
	static unsigned h(int x, int z)
	{
		return ((unsigned)x * 73856093u) ^ ((unsigned)z * 19349663u);
	}
	bool solid(int x, int y, int z) const override
	{
		return y <= (int)((h(x, z) >> 7) % 3);
	}
	float drop(int x, int y, int z) const override
	{
		return (float)((h(x, z) >> 11) % 8) / 16;
	}
	bool ramp(int x, int y, int z) const override
	{
		return (h(x, z) >> 13) % 5 == 0;
	}
};

uint32_t fnv(uint32_t hash, const void *data, unsigned n)
{
	const unsigned char *p = (const unsigned char*)data;
	for(unsigned i = 0; i < n; i++)
		hash = (hash ^ p[i]) * 16777619u;
	return hash;
}

} // namespace

BUILDAT_WASM_EXPORT uint32_t hc_selftest(void)
{
	TestGround g;
	Sim s;
	s.b.pos[1] = 8.5f;
	s.b.rot[0] = 0.9238795f, s.b.rot[2] = 0.3826834f; // 45 degrees of yaw
	uint32_t hash = 2166136261u;
	for(int i = 0; i < 120; i++){
		car::Input in;
		in.accel = i < 60 || i > 90;
		in.brake = i >= 60 && i < 75;
		in.steer = i < 15 ? 0 : i < 30 ? 1 : i < 45 ? -0.5f : 0.25f;
		in.gear = i < 50 ? car::G1 : i < 100 ? car::G3 : car::REVERSE;
		s.step(g, in);
		const predict::State st = s.get();
		hash = fnv(hash, &st, sizeof st);
	}
	return hash;
}

// Once, before anything else: the global constructors
BUILDAT_WASM_EXPORT void hc_init(void)
{
#ifdef BUILDAT_WASM_MODULE
	__wasm_call_ctors();
#endif
}

// Where Lua writes a hillclimb:setup's bytes (then calls hc_setup) and a
// hillclimb:state's (then hc_correct)
BUILDAT_WASM_EXPORT void *hc_setup_buf(void){ return &g_setup; }
BUILDAT_WASM_EXPORT void *hc_state_buf(void){ return &g_server; }

// The setup taken: the car's spec and payload, the floor's height, and
// the hill's size in voxels (from hillclimb:hill)
BUILDAT_WASM_EXPORT void hc_setup(int sx, int sy, int sz)
{
	car::Car &c = g_sim.car;
	c.spec = g_setup.spec;
	c.payload = g_setup.payload;
	const car::Car fresh(g_setup.spec, g_setup.payload);
	for(int i = 0; i < 4; i++)
		c.wheel[i].local = fresh.wheel[i].local;
	g_size[0] = sx, g_size[1] = sy, g_size[2] = sz;
}

// A chunk of voxelworld's (chunk cx, cy, cz; vol a handle to its volume)
// into a slot, its own or the one furthest from it. Returns the slot.
BUILDAT_WASM_EXPORT int hc_chunk(int vol, int cx, int cy, int cz)
{
	int r[6];
	buildat_voxels_size(vol, r);
	if(r[0] > 0 || r[1] > 0 || r[2] > 0 || r[0] + r[3] < CS ||
			r[1] + r[4] < CS || r[2] + r[5] < CS)
		return -1;
	const int box[6] = {0, 0, 0, CS, CS, CS};
	buildat_voxels_read(vol, box, g_scratch, sizeof g_scratch);
	int s = g_ground.slot(cx, cy, cz);
	for(int i = 0; s < 0 && i < SLOTS; i++)
		if(!g_slots[i].used)
			s = i;
	if(s < 0){
		int far = -1;
		for(int i = 0; i < SLOTS; i++){
			const int dx = g_slots[i].cx - cx, dy = g_slots[i].cy - cy,
					dz = g_slots[i].cz - cz;
			const int d = dx * dx + dy * dy + dz * dz;
			if(d > far)
				far = d, s = i;
		}
	}
	for(int i = 0; i < CS * CS * CS; i++){
		const uint32_t id = g_scratch[i] & 0xffff;
		g_ids[s][i] = (uint8_t)(id > 255 ? 255 : id);
	}
	g_slots[s].cx = cx, g_slots[s].cy = cy, g_slots[s].cz = cz;
	g_slots[s].used = true;
	return s;
}

// This client's input from the next substep on: steer -100..100, gear
// car.h's; held as the server holds it (the hill not made, observing)
BUILDAT_WASM_EXPORT void hc_input(int accel, int brake, int steer, int gear,
		int held)
{
	g_in.accel = accel != 0;
	g_in.brake = brake != 0;
	g_in.steer = car::clampf(steer / 100.0f, -1, 1);
	g_in.gear = gear >= car::REVERSE && gear < car::GEARS ? (car::Gear)gear :
			car::G2;
	g_held = held != 0;
}

// n substeps on; the count of them all
BUILDAT_WASM_EXPORT uint32_t hc_step(int n)
{
	for(int i = 0; i < n; i++)
		step(effective());
	return g_now;
}

// The server's state (at hc_state_buf) is the car's after substep `at` of
// this client's: compared with what was predicted for it (the errors in
// hc_out(15 to 17)). Returns 0 when within the bounds (the prediction
// kept), 1 for a correction: the car set to it and the substeps since
// stepped again with their inputs; 2 when it is taken as it is (force: the
// car was put back; and with `at` not in the history, nothing stepped
// again; 0xffffffff for an `at` not known; one before the last state taken
// whole, whose history is not the server's car).
BUILDAT_WASM_EXPORT int hc_correct(uint32_t at, int force)
{
	if(at > g_now || g_now - at >= HIST || at < g_valid){
		g_sim.set(g_server);
		// Ahead of this client (its frames late): its count is moved on;
		// 0xffffffff is "not known"
		if(at > g_now && at != 0xffffffffu)
			g_now = at;
		g_valid = g_now;
		return 2;
	}
	if(!force){
		const predict::State p = at == g_now ? g_sim.get() : g_hist[at % HIST];
		const V3 dp = div(v3(p.pos) - v3(g_server.pos), U);
		const V3 dv = div(v3(p.vel) - v3(g_server.vel), U);
		float dot = 0;
		for(int i = 0; i < 4; i++)
			dot += p.rot[i] * g_server.rot[i];
		dot = car_math::fminf_(1, car_math::fabsf_(dot));
		g_err[0] = dp.length();
		g_err[1] = dv.length();
		g_err[2] = 2 * car_math::sqrtf_(1 - dot * dot); // about the angle
		if(g_err[0] <= 0.01f && g_err[1] <= 0.05f && g_err[2] <= 0.01f)
			return 0;
	}
	g_sim.set(g_server);
	if(force)
		g_valid = at;
	const uint32_t now = g_now;
	for(g_now = at; g_now < now;)
		step(g_hist_in[g_now % HIST]);
	return force ? 2 : 1;
}

// What the client draws, as hillclimb:car's numbers 1 to 15: the chassis
// in voxels (position, rotation w x y z), the wheels' spin and the front
// ones' steering (rad), each spring's compression (voxels), the shaft
// (rev/s); 15 to 17 the last state's errors (m, m/s, rad)
BUILDAT_WASM_EXPORT float hc_out(int i)
{
	const car::Car &c = g_sim.car;
	const predict::State &b = g_sim.b;
	if(i >= 0 && i < 3)
		return b.pos[i];
	if(i >= 3 && i < 7)
		return b.rot[i - 3];
	if(i == 7)
		return c.spin;
	if(i == 8 || i == 9)
		return c.wheel[i - 8].steer;
	if(i >= 10 && i < 14)
		return c.wheel[i - 10].spring * U;
	if(i == 14)
		return c.shaft / (2 * car::PI);
	if(i >= 15 && i < 18)
		return g_err[i - 15];
	return 0;
}
