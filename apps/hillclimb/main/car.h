// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// The car of hillclimb ([HILLCLIMB] 2): what the four tyres do each
// substep, in SI units, with no engine types. main.cpp moves the chassis
// (a Bullet rigid body) by the forces this returns and hands it the
// chassis' pose and velocities in metres.
//
// A tyre touches the voxels as spheres at their centres, half a voxel
// across. Its deflection is the deepest sphere's overlap with the tyre's
// circle at the suspension's full droop, its normal the overlaps'
// weighted mean, and the force is that deflection through the spring and
// the tyre in series, the damper on the spring's share of the motion.
// The tyre's grip is a brush: a small deflection of the tread that is a
// spring and a damper while it holds and slides at mu times the load
// when it does not, so a braked car stands on a slope instead of
// creeping down it. All four wheels turn at one shaft speed (the
// lockers), which the gear's governor drives toward its target.
#pragma once
#include <cmath>
#include <cstdint>

namespace car {

struct V3
{
	float x = 0, y = 0, z = 0;
	V3(){}
	V3(float x, float y, float z): x(x), y(y), z(z){}
	V3 operator+(const V3 &o) const { return V3(x + o.x, y + o.y, z + o.z); }
	V3 operator-(const V3 &o) const { return V3(x - o.x, y - o.y, z - o.z); }
	V3 operator*(float k) const { return V3(x * k, y * k, z * k); }
	float dot(const V3 &o) const { return x * o.x + y * o.y + z * o.z; }
	V3 cross(const V3 &o) const {
		return V3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
	}
	float length() const { return std::sqrt(dot(*this)); }
	V3 normalized() const { float l = length(); return l > 0 ? *this * (1 / l) : *this; }
};

static const float PI = 3.14159265f;
static float clampf(float v, float a, float b){ return v < a ? a : v > b ? b : v; }
// v moved toward t by at most d
static float approach(float v, float t, float d){
	return v < t ? std::fmin(v + d, t) : std::fmax(v - d, t);
}

enum Gear { REVERSE, G1, G2, G3, G4, GEARS };

// The user's car ([HILLCLIMB]): tyres 80 cm by 30 cm, track 160 cm,
// wheelbase 280 cm, 2 t, 2 rev/s at the top. The rest picked here and
// tuned by driving.
struct Spec
{
	float mass = 2000;                     // kg, without the payload
	float tyre_r = 0.40f, tyre_w = 0.30f;  // m
	float track = 1.60f, wheelbase = 2.80f;
	// The chassis' box, which gives the inertia and the body's collision
	// with the ground when it rolls over
	float box_w = 1.6f, box_h = 0.8f, box_l = 4.2f;
	float mount_y = -0.1f;   // the suspension's top, under the centre of mass
	float droop = 0.45f;     // the hub under the mount at full droop
	float travel = 0.25f;    // the spring's compression to the bump stop
	float k_spring = 60000;  // N/m per corner
	float c_damp = 7000;     // N s/m per corner
	float k_tyre = 250000;   // N/m
	float mu = 0.6f;         // sand
	float k_brush = 150000, c_brush = 8000; // the tread's grip, per tyre
	float shaft_inertia = 150; // kg m^2: the wheels and the low range's
	                           // reflected engine
	float governor = 20000;  // N m per rad/s toward the target
	// rev/s at the wheel at full pedal, and the most torque, all four
	float gear_speed[GEARS] = {-0.5f, 0.5f, 0.9f, 1.4f, 2.0f};
	float gear_torque[GEARS] = {9000, 12000, 8000, 5500, 4000};
	float engine_brake = 0.3f; // of the gear's torque, pedal up
	float brake_torque = 16000;
	float steer_max = 0.6f, steer_rate = 0.8f; // rad, rad/s
	float pedal_rate = 0.7f;   // per second: the gentle ramps
};

struct Input
{
	bool accel = false, brake = false, left = false, right = false;
	Gear gear = G2;
};

// The chassis, as main.cpp reads it from the body, in metres
struct Pose
{
	V3 pos;                  // the centre of mass
	V3 right, up, forward;   // the chassis' axes
};

struct Wheel
{
	V3 local;                // the hub at full droop, in the chassis frame
	bool front = false;
	float steer = 0;         // rad, + to the right
	float load = 0;          // N, the ground's normal force
	float spring = 0;        // m, the spring's compression (drawing)
	float brush_x = 0, brush_y = 0; // the tread's deflection, m
	bool slipping = false;
	// This substep's force on the chassis and where it acts
	V3 force, at;
	// For the ground (ground.h): the tread's velocity over the ground,
	// m/s, the contact's normal and the axle
	V3 slide, normal, axle;
};

// Voxels are (x, y, z) with centres at integers, `u` of them to the metre
struct Ground
{
	virtual bool solid(int x, int y, int z) const = 0;
	virtual ~Ground(){}
};

struct Car
{
	Spec spec;
	float payload = 0;
	Wheel wheel[4];          // front left, front right, rear left, rear right
	float shaft = 0;         // rad/s
	float spin = 0;          // rad, for drawing
	float pedal = 0, brake = 0, steer = 0;
	Gear gear = G2;

	Car(const Spec &s, float payload_kg): spec(s), payload(payload_kg)
	{
		for(int i = 0; i < 4; i++){
			Wheel &w = wheel[i];
			w.front = i < 2;
			w.local = V3((i % 2 ? 1 : -1) * spec.track / 2,
					spec.mount_y - spec.droop,
					(w.front ? 1 : -1) * spec.wheelbase / 2);
		}
	}
	float mass() const { return spec.mass + payload; }

	void controls(const Input &in, float dt)
	{
		gear = in.gear;
		pedal = approach(pedal, in.accel ? 1 : 0,
				spec.pedal_rate * dt * (in.accel ? 1 : 2));
		brake = approach(brake, in.brake ? 1 : 0, spec.pedal_rate * dt * 2);
		float t = in.left == in.right ? 0 : in.left ? -spec.steer_max :
				spec.steer_max;
		steer = approach(steer, t, spec.steer_rate * dt);
		// Ackermann: the inner wheel on the tighter circle
		for(int i = 0; i < 2; i++){
			Wheel &w = wheel[i];
			if(std::fabs(steer) < 1e-4f){
				w.steer = 0;
				continue;
			}
			float r = spec.wheelbase / std::tan(std::fabs(steer));
			bool inner = (steer > 0) == (i == 1);
			float a = std::atan(spec.wheelbase / (r + (inner ? -1 : 1) *
					spec.track / 2));
			w.steer = steer > 0 ? a : -a;
		}
	}

	// The ground under one tyre: the deflection at full droop, m, and the
	// normal; 0 if it does not touch. hub and the axle in voxels.
	static float contact(const Ground &g, float u, const V3 &hub,
			const V3 &axle, float r, float w, V3 &normal)
	{
		const float rv = 0.5f;               // a voxel's sphere, in voxels
		const float R = r * u, hw = w * u / 2;
		const int x0 = (int)std::floor(hub.x - R - 1),
				x1 = (int)std::ceil(hub.x + R + 1);
		const int y0 = (int)std::floor(hub.y - R - 1),
				y1 = (int)std::ceil(hub.y + R + 1);
		const int z0 = (int)std::floor(hub.z - R - 1),
				z1 = (int)std::ceil(hub.z + R + 1);
		float deepest = 0;
		V3 sum;
		for(int z = z0; z <= z1; z++)
		for(int y = y0; y <= y1; y++)
		for(int x = x0; x <= x1; x++){
			V3 d = V3((float)x, (float)y, (float)z) - hub;
			float a = d.dot(axle);
			if(std::fabs(a) > hw + rv)
				continue;
			V3 radial = d - axle * a;
			float dist = radial.length();
			float pen = R + rv - dist;
			if(pen <= 0 || dist < 1e-4f || !g.solid(x, y, z))
				continue;
			deepest = std::fmax(deepest, pen);
			sum = sum - radial * (pen / dist);
		}
		if(deepest <= 0)
			return 0;
		normal = sum.normalized();
		return deepest / u;
	}

	// One substep: each wheel's force on the chassis (wheel[i].force and
	// .at, N and m), and the shaft. velocity_at() is the chassis' velocity
	// at a point, m/s.
	template<typename VelocityAt>
	void step(const Ground &g, float u, const Pose &p, VelocityAt velocity_at,
			float dt)
	{
		const Spec &s = spec;
		const float k_series = s.k_spring * s.k_tyre / (s.k_spring + s.k_tyre);
		float ground_torque = 0;
		for(int i = 0; i < 4; i++){
			Wheel &w = wheel[i];
			V3 hub = p.pos + p.right * w.local.x + p.up * w.local.y +
					p.forward * w.local.z;
			// The wheel's own axes, turned by its steering about the
			// chassis' up
			float cs = std::cos(w.steer), sn = std::sin(w.steer);
			V3 fwd = p.forward * cs + p.right * sn;
			V3 axle = p.right * cs - p.forward * sn;
			V3 n;
			float d = contact(g, u, hub * u, axle, s.tyre_r, s.tyre_w, n);
			w.force = V3();
			w.at = hub;
			w.slide = V3();
			w.axle = axle;
			if(d <= 0){
				w.load = w.spring = w.brush_x = w.brush_y = 0;
				w.slipping = false;
				continue;
			}
			V3 at = hub - n * s.tyre_r;
			V3 v = velocity_at(at);
			// The spring and the tyre in series; past the stop, the tyre
			float f = k_series * d;
			if(f / s.k_spring > s.travel)
				f = s.k_spring * s.travel + s.k_tyre *
						(d - s.travel * (1 + s.k_spring / s.k_tyre));
			f += s.c_damp * -v.dot(n) * s.k_tyre / (s.k_spring + s.k_tyre);
			f = std::fmax(0, f);
			w.load = f;
			w.spring = std::fmin(s.travel, f / s.k_spring);
			// The contact's own axes, in the ground's plane
			V3 cx = (fwd - n * fwd.dot(n)).normalized();
			V3 cy = n.cross(cx);
			float slip_x = v.dot(cx) - shaft * s.tyre_r;
			float slip_y = v.dot(cy);
			w.brush_x += slip_x * dt;
			w.brush_y += slip_y * dt;
			float fx = -s.k_brush * w.brush_x - s.c_brush * slip_x;
			float fy = -s.k_brush * w.brush_y - s.c_brush * slip_y;
			float cap = s.mu * f, mag = std::sqrt(fx * fx + fy * fy);
			w.slipping = mag > cap;
			if(w.slipping){
				fx *= cap / mag;
				fy *= cap / mag;
				// The tread holds what the cap leaves it
				float k = cap / s.k_brush / std::fmax(1e-6f, std::sqrt(
						w.brush_x * w.brush_x + w.brush_y * w.brush_y));
				if(k < 1){
					w.brush_x *= k;
					w.brush_y *= k;
				}
			}
			w.force = n * f + cx * fx + cy * fy;
			w.at = at;
			w.slide = cx * slip_x + cy * slip_y;
			w.normal = n;
			ground_torque += fx * s.tyre_r;
		}
		// The shaft: the governor toward the gear's speed at the pedal, the
		// ground's reaction, then the brake, which stops it and holds it
		float target = s.gear_speed[gear] * 2 * PI * pedal;
		float cap = s.gear_torque[gear] * (pedal > 0.01f ? 1 : s.engine_brake);
		float drive = clampf(s.governor * (target - shaft), -cap, cap);
		shaft += (drive - ground_torque) * dt / s.shaft_inertia;
		float b = s.brake_torque * brake * dt / s.shaft_inertia;
		shaft = std::fabs(shaft) <= b ? 0 : shaft - (shaft > 0 ? b : -b);
		spin = std::fmod(spin + shaft * dt, 2 * PI);
	}
};

} // namespace car
