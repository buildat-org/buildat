// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/log.h"
#include "lua_bindings/util.h"
#include "lua_bindings/sandbox_util.h"
#include "client/app.h"
#include "interface/voxel_volume.h"
#include "interface/voxel_selector.h"
#include "interface/thread_pool.h"
#include <c55/os.h>
#include <tolua++.h>
#include <luabind/luabind.hpp>
#include <luabind/adopt_policy.hpp>
#include <luabind/pointer_traits.hpp>
#include <VectorBuffer.h>
#include <cmath>
#define MODULE "lua_bindings"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::VoxelInstance;
using interface::VoxelVolume;
using interface::VoxelRegistry;
using interface::AtlasRegistry;
using namespace Urho3D;

namespace lua_bindings {

int region_get_x0(const pv::Region &region){
	return region.getLowerCorner().getX();
}
int region_get_y0(const pv::Region &region){
	return region.getLowerCorner().getY();
}
int region_get_z0(const pv::Region &region){
	return region.getLowerCorner().getZ();
}
int region_get_x1(const pv::Region &region){
	return region.getUpperCorner().getX();
}
int region_get_y1(const pv::Region &region){
	return region.getUpperCorner().getY();
}
int region_get_z1(const pv::Region &region){
	return region.getUpperCorner().getZ();
}

// These are supposed to store the value so that negative values will be
// preserved
int32_t voxelinstance_get_int32(const VoxelInstance &v){
	return (int32_t)v.data;
}
void voxelinstance_set_int32(VoxelInstance &v, int32_t d){
	v.data = (uint32_t)d;
}

typedef VoxelVolume CommonVolume;

ss_ volume_serialize(const CommonVolume &volume)
{
	return interface::serialize_volume_simple(volume);
}

sp_<CommonVolume> deserialize_volume(
		const luabind::object &buffer_o, lua_State *L)
{
	TRY_GET_SANDBOX_STUFF(buf, 1, VectorBuffer);

	ss_ data;
	if(buf == nullptr)
		data = lua_checkcppstring(L, 1);
	else
		data.assign((const char*)buf->GetData(), buf->GetSize());

	return interface::deserialize_volume(data);
}

sp_<CommonVolume> deserialize_volume_int32(
		const luabind::object &buffer_o, lua_State *L)
{
	TRY_GET_SANDBOX_STUFF(buf, 1, VectorBuffer);

	ss_ data;
	if(buf == nullptr)
		data = lua_checkcppstring(L, 1);
	else
		data.assign((const char*)buf->GetData(), buf->GetSize());

	up_<pv::RawVolume<int32_t>> volume_int32 =
			interface::deserialize_volume_int32(data);
	// Data it could not read: nil, as deserialize_volume answers
	if(!volume_int32)
		return nullptr;

	auto region = volume_int32->getEnclosingRegion();

	sp_<CommonVolume> volume(new CommonVolume(region));

	auto &lc = region.getLowerCorner();
	auto &uc = region.getUpperCorner();
	for(int z = lc.getZ(); z <= uc.getZ(); z++){
		for(int y = lc.getY(); y <= uc.getY(); y++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				int32_t v = volume_int32->getVoxelAt(x, y, z);
				//log_w(MODULE, "v=%i", v);
				volume->setVoxelAt(x, y, z, VoxelInstance(v));
			}
		}
	}

	return volume;
}

sp_<CommonVolume> deserialize_volume_8bit(
		const luabind::object &buffer_o, lua_State *L)
{
	TRY_GET_SANDBOX_STUFF(buf, 1, VectorBuffer);

	ss_ data;
	if(buf == nullptr)
		data = lua_checkcppstring(L, 1);
	else
		data.assign((const char*)buf->GetData(), buf->GetSize());

	up_<pv::RawVolume<uint8_t>> volume_8bit =
			interface::deserialize_volume_8bit(data);
	// Data it could not read: nil, as deserialize_volume answers
	if(!volume_8bit)
		return nullptr;

	auto region = volume_8bit->getEnclosingRegion();

	sp_<CommonVolume> volume(new CommonVolume(region));

	auto &lc = region.getLowerCorner();
	auto &uc = region.getUpperCorner();
	for(int z = lc.getZ(); z <= uc.getZ(); z++){
		for(int y = lc.getY(); y <= uc.getY(); y++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				uint8_t v = volume_8bit->getVoxelAt(x, y, z);
				volume->setVoxelAt(x, y, z, VoxelInstance(v));
			}
		}
	}

	return volume;
}

// Marches rays through a set of chunk volumes and reports what each one ran
// into. This exists because doing it in Lua costs a call per voxel per ray:
// the sky visibility sampler in builtin/voxel_shading was spending half a
// millisecond a frame on 4 rays, and it wants hundreds.
//
// It is deliberately not a sky visibility function. What it answers per ray is
// "what stopped this, and where had it got to", which is as much use for a
// line of sight check or for pointing at a voxel as it is for lighting. What
// counts as passable is the registry's own physically_solid, so a world with
// glass gets glass, and stop_skylight is the one lighting-flavoured thing in
// it: a threshold at which a ray is called done, which is how a caller asks
// "did this get out to open sky" without a second pass.
//
// args (a table):
//   registry       VoxelRegistry, for physically_solid per voxel id
//   chunk_size     {x=,y=,z=} in voxels
//   volumes        array of {x=,y=,z=, volume=}, chunk positions and their
//                  volumes; a ray entering a chunk that is not in here stops
//                  with status "no data"
//   origin         {x=,y=,z=} in voxels; the voxel it is in is not sampled
//   directions     flat array of numbers, three to a ray, need not be unit
//                  vectors. Flat rather than a table per ray because this is
//                  read for every ray every frame and a table each cost more
//                  than the marching did.
//   first, count   which rays to cast, 1-based (default: all)
//   max_steps      voxels a ray may enter before giving up
//   stop_skylight  optional 1..15; a passable voxel at or above this stops the
//                  ray with status "skylight"
//   rays_per_cell  optional; see below
//
// Returns a table of four arrays, each indexed 1..count:
//   status    one of the VoxelRayStatus values below, which the client Lua
//             API exposes as buildat.VOXEL_RAY
//   hit_id    the voxel id that stopped the ray, or 0
//   skylight  skylight of the last passable voxel entered, or -1 for none
//   steps     voxels entered
//
// With rays_per_cell set, consecutive rays are taken to be one cell's and what
// comes back instead is
//   count       cells
//   visibility  their mean ray_visibility(), one per cell
// which is a few hundred numbers a frame rather than four arrays per ray, and
// is most of what this call costs at any real ray count. The price is that the
// rule turning a ray into a number is then this file's rather than the
// caller's; a caller that wants its own leaves rays_per_cell unset.
//
// The march is a DDA over voxel centers, so it enters every voxel the ray
// passes through and cannot step over a wall one voxel thick.
enum VoxelRayStatus {
	VOXEL_RAY_BLOCKED = 0,   // Ran into something not passable
	VOXEL_RAY_NO_DATA = 1,   // Left the volumes it was given
	VOXEL_RAY_RANGE = 2,     // Used up max_steps
	VOXEL_RAY_SKYLIGHT = 3,  // Reached stop_skylight
	// Stopped by something the sky is seen through anyway: a leaf, a
	// plant, a pane. Solid to walk on, not a wall to the daylight.
	VOXEL_RAY_BLOCKED_CLEAR = 4,
};

static const int VOXEL_RAY_MAX_STEPS = 4096;
static const size_t VOXEL_RAY_MAX_DIRECTIONS = 65536;

// One casting job: everything the marching reads and everything it produces,
// with no Lua anywhere in it. Separate from the binding so that the same
// marching can run on a thread pool worker, where a lua_State must not be
// touched.
struct RayJob
{
	// Inputs
	pv::Vector3DInt32 chunk_size = pv::Vector3DInt32(1, 1, 1);
	// The volumes are held rather than borrowed. A chunk that arrives while a
	// job is in flight replaces the entry in voxelworld's cache and drops its
	// reference, and the volume this job is part way through reading has to
	// outlive that. Holding them is a refcount each and no copying: the voxel
	// data itself is never written after it is deserialized.
	sv_<std::pair<pv::Vector3DInt32, sp_<CommonVolume>>> volumes;
	// Held for the same reason. The mesher's tasks already read the registry
	// from worker threads; get() is a lookup and does not write.
	sp_<VoxelRegistry> voxel_reg;
	double origin_x = 0.0, origin_y = 0.0, origin_z = 0.0;
	sv_<double> dirs;   // Three per ray, not normalized
	int max_steps = 32;
	int stop_skylight = 0;
	// Rays per cell. Zero hands back what every ray found and leaves the
	// caller to make of it what it likes; above zero, consecutive rays are one
	// cell's and the job hands back a value per cell instead. See
	// ray_visibility() on what that costs the caller in freedom, and
	// cast_voxel_rays() on why it is worth it.
	int rays_per_cell = 0;

	// Outputs. Per ray, or per cell when rays_per_cell is set.
	sv_<int> status, hit_id, skylight, steps;
	sv_<double> visibility;

	// Set by the task's post(), which the pool runs on the main thread after
	// thread() has finished; read by cast_voxel_rays_collect(). Both on the
	// main thread, so this needs no atomic of its own.
	bool done = false;
};

// Chunk position -> volume, for the duration of one job
struct RayVolumeSet
{
	const sv_<std::pair<pv::Vector3DInt32, sp_<CommonVolume>>> *volumes;
	pv::Vector3DInt32 chunk_size;
	// A flat vector rather than a hash: a ray crosses a chunk boundary once
	// every chunk_size voxels and asks again only then, and the one it asked
	// for last is nearly always the one it wants, so the scan behind that is
	// rare enough that its length does not matter
	int last_hit = -1;

	RayVolumeSet(const RayJob &job):
		volumes(&job.volumes), chunk_size(job.chunk_size){}

	CommonVolume* find(const pv::Vector3DInt32 &chunk_p)
	{
		if(last_hit >= 0 && (*volumes)[last_hit].first == chunk_p)
			return (*volumes)[last_hit].second.get();
		for(size_t i = 0; i < volumes->size(); i++){
			if((*volumes)[i].first == chunk_p){
				last_hit = i;
				return (*volumes)[i].second.get();
			}
		}
		return nullptr;
	}
};

static int floor_div(int a, int b)
{
	int q = a / b;
	if((a % b) != 0 && ((a < 0) != (b < 0)))
		q--;
	return q;
}

static double table_number(const luabind::object &t, const char *key,
		double default_value)
{
	luabind::object v = t[key];
	if(!v || luabind::type(v) != LUA_TNUMBER)
		return default_value;
	return luabind::object_cast<double>(v);
}

static pv::Vector3DInt32 table_vector3_int(const luabind::object &t,
		const char *key)
{
	luabind::object v = t[key];
	if(!v || luabind::type(v) != LUA_TTABLE)
		throw Exception(ss_("cast_voxel_rays(): args.") + key +
				" is not a table");
	return pv::Vector3DInt32(
			(int)table_number(v, "x", 0),
			(int)table_number(v, "y", 0),
			(int)table_number(v, "z", 0));
}

// What one ray is worth, as a fraction of sky along it: nothing if something
// solid stopped it, and otherwise the skylight of the air it ended in, which
// says how open the sky is above the point the ray reached. A ray that left
// the voxel data immediately had nothing around it to see.
//
// This is the one piece of policy in here, and it is here only because
// averaging rays into a cell means deciding what a ray is worth. A caller that
// wants a different rule leaves rays_per_cell unset and gets what every ray
// found, which is what this is computed from.
static double ray_visibility(int status, int skylight, int steps)
{
	// **A wall is a wall.** Only what the sky is seen through anyway --
	// a leaf, a plant, a pane -- passes the daylight it stands in; stone
	// stops the ray at nothing, which is what keeps a cave a cave. With
	// every blocker passing it, apps/sample_lighting_scene's shaft interior
	// went from no black at all to 92% of the frame ([UNDERGROUND_LIGHT]).
	if(status == VOXEL_RAY_BLOCKED)
		return 0.0;
	if(steps <= 1)
		return 1.0;
	if(skylight < 0)
		return 0.0;
	// **A ray that was stopped is worth the daylight it travelled through**,
	// not nothing. "Nothing if something solid stopped it" made a forest
	// read as a sealed chamber: a leaf is walkable, so every ray into a
	// canopy was blocked at its first step and a player standing in a
	// jungle measured chamber_light() at 0.002 -- which turns the cave
	// floor on whole and the bounce floor off, above ground, in daylight,
	// and with the floor on it is also the gray ramp's threshold, so the
	// shaded leaf tops came out pure gray ([UNDERGROUND_LIGHT], the
	// playtest fault, 2026-09-28). A canopy is not a cave, and what tells
	// them apart is already in the answer: the skylight of the air the ray
	// crossed. Under leaves that is twelve of fifteen; in a sealed room it
	// is nought, so the invariant that room reads dark at every hour
	// stands.
	return (double)skylight / (double)interface::VoxelInstance::SKYLIGHT_MAX;
}

// Marches the job's rays. Touches nothing that belongs to a thread -- no Lua,
// no Urho -- which is what lets a worker run it.
static void march_rays(RayJob &job)
{
	const size_t n = job.dirs.size() / 3;
	job.status.assign(n, VOXEL_RAY_RANGE);
	job.hit_id.assign(n, 0);
	job.skylight.assign(n, -1);
	job.steps.assign(n, 0);

	RayVolumeSet volume_set(job);

	// Which bits of a voxel are the id and the sky light, per the world's
	// own voxel format, and which definition a voxel wears -- which is the
	// id role in a world that has one and a threshold over its planes in a
	// world that does not. Read once; neither changes while a job runs.
	const interface::VoxelFormat &fmt = job.voxel_reg->get_format();
	const interface::VoxelSelector look = job.voxel_reg->get_look_selector();

	// physically_solid per voxel id, filled as ids turn up. Unknown ids stop a
	// ray: an id with no definition is not something to see the sky through.
	sv_<int8_t> solid_cache;
	sv_<int8_t> clear_cache;

	for(size_t ri = 0; ri < n; ri++){
		double dx = job.dirs[ri * 3 + 0];
		double dy = job.dirs[ri * 3 + 1];
		double dz = job.dirs[ri * 3 + 2];
		double len = sqrt(dx * dx + dy * dy + dz * dz);
		if(!(len > 1e-9))
			continue; // A zero or broken direction goes nowhere, not forever
		dx /= len; dy /= len; dz /= len;

		int status = VOXEL_RAY_RANGE;
		int hit_id = 0;
		int skylight = -1;
		int steps = 0;

		// Voxel coordinates are voxel centers, so the boundaries are at half
		// integers; shifting by a half puts them on integers, where a DDA
		// wants them.
		double px = job.origin_x + 0.5;
		double py = job.origin_y + 0.5;
		double pz = job.origin_z + 0.5;
		int vx = (int)floor(px), vy = (int)floor(py), vz = (int)floor(pz);

		int step_x = dx > 0.0 ? 1 : -1;
		int step_y = dy > 0.0 ? 1 : -1;
		int step_z = dz > 0.0 ? 1 : -1;
		// Distance along the ray to the next boundary on each axis, and the
		// distance between boundaries. Infinity for an axis the ray does not
		// move along, which then never comes up as the nearest boundary.
		double huge_d = 1e30;
		double t_delta_x = fabs(dx) > 1e-9 ? 1.0 / fabs(dx) : huge_d;
		double t_delta_y = fabs(dy) > 1e-9 ? 1.0 / fabs(dy) : huge_d;
		double t_delta_z = fabs(dz) > 1e-9 ? 1.0 / fabs(dz) : huge_d;
		double t_max_x = fabs(dx) > 1e-9 ?
				((step_x > 0 ? (vx + 1 - px) : (px - vx)) / fabs(dx)) : huge_d;
		double t_max_y = fabs(dy) > 1e-9 ?
				((step_y > 0 ? (vy + 1 - py) : (py - vy)) / fabs(dy)) : huge_d;
		double t_max_z = fabs(dz) > 1e-9 ?
				((step_z > 0 ? (vz + 1 - pz) : (pz - vz)) / fabs(dz)) : huge_d;

		CommonVolume *volume = nullptr;
		pv::Vector3DInt32 volume_chunk_p(0, 0, 0);
		bool have_volume = false;

		for(int step = 0; step < job.max_steps; step++){
			// Step into the next voxel first: the one the origin is in is the
			// caller's own and is not what it is asking about
			if(t_max_x < t_max_y && t_max_x < t_max_z){
				vx += step_x;
				t_max_x += t_delta_x;
			} else if(t_max_y < t_max_z){
				vy += step_y;
				t_max_y += t_delta_y;
			} else {
				vz += step_z;
				t_max_z += t_delta_z;
			}
			steps = step + 1;

			pv::Vector3DInt32 chunk_p(
					floor_div(vx, volume_set.chunk_size.getX()),
					floor_div(vy, volume_set.chunk_size.getY()),
					floor_div(vz, volume_set.chunk_size.getZ()));
			if(!have_volume || chunk_p != volume_chunk_p){
				volume = volume_set.find(chunk_p);
				volume_chunk_p = chunk_p;
				have_volume = true;
			}
			if(volume == nullptr){
				status = VOXEL_RAY_NO_DATA;
				break;
			}

			// The whole voxel, not the first plane's word: what stops a
			// ray is whether the definition it wears is solid, and which
			// definition that is can depend on any of its planes
			interface::VoxelSample v = volume->sample_at(
					vx - chunk_p.getX() * volume_set.chunk_size.getX(),
					vy - chunk_p.getY() * volume_set.chunk_size.getY(),
					vz - chunk_p.getZ() * volume_set.chunk_size.getZ());
			interface::VoxelTypeId id = look.id_of(v, fmt);

			if((size_t)id >= solid_cache.size()){
				solid_cache.resize((size_t)id + 1, -1);
				clear_cache.resize((size_t)id + 1, -1);
			}
			int8_t solid = solid_cache[id];
			if(solid < 0){
				const interface::VoxelDefinition *def = job.voxel_reg->get(id);
				solid = (def == nullptr || def->physically_solid) ? 1 : 0;
				solid_cache[id] = solid;
				// And whether what stops the ray is a thing the sky is
				// seen through anyway -- a leaf, a plant, a pane. See
				// ray_visibility().
				// transmits_light alone, which is Luanti's
				// sunlight_propagates: a voxel that says the sky is seen
				// through it. Not the edge material, which is empty for
				// anything that draws no face against its neighbour and
				// is true of apps/sample_lighting_scene's own blocks -- with
				// that in the test the shaft interior did not move at all.
				clear_cache[id] = (def != nullptr &&
						def->transmits_light) ? 1 : 0;
			}
			if(solid){
				status = clear_cache[id] ? VOXEL_RAY_BLOCKED_CLEAR :
						VOXEL_RAY_BLOCKED;
				hit_id = id;
				break;
			}

			skylight = (int)fmt.light_sky.get(v);
			if(job.stop_skylight > 0 && skylight >= job.stop_skylight){
				status = VOXEL_RAY_SKYLIGHT;
				break;
			}
		}

		job.status[ri] = status;
		job.hit_id[ri] = hit_id;
		job.skylight[ri] = skylight;
		job.steps[ri] = steps;
	}

	// One value per cell, if that is what was asked for
	if(job.rays_per_cell > 0){
		const size_t cells = n / (size_t)job.rays_per_cell;
		job.visibility.assign(cells, 0.0);
		size_t ri = 0;
		for(size_t c = 0; c < cells; c++){
			double sum = 0.0;
			for(int k = 0; k < job.rays_per_cell; k++, ri++)
				sum += ray_visibility(job.status[ri], job.skylight[ri],
						job.steps[ri]);
			job.visibility[c] = sum / (double)job.rays_per_cell;
		}
	}
}

// Reads the argument table into a job. Everything Lua-side happens here, so
// that what is handed to a worker is plain C++ that owns what it reads.
static void ray_job_from_lua(RayJob &job, const luabind::object &args)
{
	if(!args || luabind::type(args) != LUA_TTABLE)
		throw Exception("cast_voxel_rays(): args is not a table");

	{
		luabind::object o = args["registry"];
		if(o)
			job.voxel_reg = luabind::object_cast<sp_<VoxelRegistry>>(o);
	}
	if(job.voxel_reg == nullptr)
		throw Exception("cast_voxel_rays(): args.registry is not a registry");

	job.chunk_size = table_vector3_int(args, "chunk_size");
	if(job.chunk_size.getX() <= 0 || job.chunk_size.getY() <= 0 ||
			job.chunk_size.getZ() <= 0)
		throw Exception("cast_voxel_rays(): args.chunk_size is not positive");

	{
		luabind::object volumes_o = args["volumes"];
		if(!volumes_o || luabind::type(volumes_o) != LUA_TTABLE)
			throw Exception("cast_voxel_rays(): args.volumes is not a table");
		for(luabind::iterator it(volumes_o), end; it != end; ++it){
			luabind::object entry = *it;
			if(luabind::type(entry) != LUA_TTABLE)
				continue;
			luabind::object volume_o = entry["volume"];
			if(!volume_o)
				continue;
			sp_<CommonVolume> volume =
					luabind::object_cast<sp_<CommonVolume>>(volume_o);
			if(volume == nullptr)
				continue;
			job.volumes.push_back(std::make_pair(pv::Vector3DInt32(
					(int)table_number(entry, "x", 0),
					(int)table_number(entry, "y", 0),
					(int)table_number(entry, "z", 0)), volume));
		}
	}

	{
		luabind::object o = args["origin"];
		if(!o || luabind::type(o) != LUA_TTABLE)
			throw Exception("cast_voxel_rays(): args.origin is not a table");
		job.origin_x = table_number(o, "x", 0.0);
		job.origin_y = table_number(o, "y", 0.0);
		job.origin_z = table_number(o, "z", 0.0);
	}

	job.max_steps = (int)table_number(args, "max_steps", 32);
	if(job.max_steps < 1)
		job.max_steps = 1;
	if(job.max_steps > VOXEL_RAY_MAX_STEPS)
		job.max_steps = VOXEL_RAY_MAX_STEPS;

	job.stop_skylight = (int)table_number(args, "stop_skylight", 0);

	job.rays_per_cell = (int)table_number(args, "rays_per_cell", 0);
	if(job.rays_per_cell < 0)
		job.rays_per_cell = 0;

	// A flat array of numbers, three to a ray, rather than a table per ray:
	// this is read once a frame for every ray and a table each was most of
	// what the sampling cost. Three array reads a ray, and the caller still
	// says where every one of them points.
	luabind::object directions_o = args["directions"];
	if(!directions_o || luabind::type(directions_o) != LUA_TTABLE)
		throw Exception("cast_voxel_rays(): args.directions is not a table");

	int first = (int)table_number(args, "first", 1);
	if(first < 1)
		first = 1;
	int count = (int)table_number(args, "count", -1);

	for(int ri = first; count < 0 || ri < first + count; ri++){
		if(job.dirs.size() / 3 >= VOXEL_RAY_MAX_DIRECTIONS)
			break;
		luabind::object x_o = directions_o[(ri - 1) * 3 + 1];
		if(!x_o || luabind::type(x_o) != LUA_TNUMBER)
			break; // End of the array, or the slice asked for runs past it
		luabind::object y_o = directions_o[(ri - 1) * 3 + 2];
		luabind::object z_o = directions_o[(ri - 1) * 3 + 3];
		job.dirs.push_back(luabind::object_cast<double>(x_o));
		job.dirs.push_back(y_o && luabind::type(y_o) == LUA_TNUMBER ?
				luabind::object_cast<double>(y_o) : 0.0);
		job.dirs.push_back(z_o && luabind::type(z_o) == LUA_TNUMBER ?
				luabind::object_cast<double>(z_o) : 0.0);
	}

	if(job.rays_per_cell > 0 &&
			(job.dirs.size() / 3) % (size_t)job.rays_per_cell != 0)
		throw Exception("cast_voxel_rays(): rays are not a whole number of "
				"cells");
}

static luabind::object ray_job_to_lua(const RayJob &job, lua_State *L)
{
	// A value per cell is the whole point of asking for it: what the caller
	// gets back is then a few hundred numbers instead of four per ray, and
	// none of the per-ray tables are built at all
	if(job.rays_per_cell > 0){
		luabind::object visibility_t = luabind::newtable(L);
		for(size_t i = 0; i < job.visibility.size(); i++)
			visibility_t[i + 1] = job.visibility[i];
		luabind::object result = luabind::newtable(L);
		result["count"] = (int)job.visibility.size();
		result["visibility"] = visibility_t;
		return result;
	}

	luabind::object status_t = luabind::newtable(L);
	luabind::object hit_id_t = luabind::newtable(L);
	luabind::object skylight_t = luabind::newtable(L);
	luabind::object steps_t = luabind::newtable(L);
	for(size_t i = 0; i < job.status.size(); i++){
		status_t[i + 1] = job.status[i];
		hit_id_t[i + 1] = job.hit_id[i];
		skylight_t[i + 1] = job.skylight[i];
		steps_t[i + 1] = job.steps[i];
	}
	luabind::object result = luabind::newtable(L);
	result["count"] = (int)job.status.size();
	result["status"] = status_t;
	result["hit_id"] = hit_id_t;
	result["skylight"] = skylight_t;
	result["steps"] = steps_t;
	return result;
}

luabind::object cast_voxel_rays(const luabind::object &args, lua_State *L)
{
	RayJob job;
	ray_job_from_lua(job, args);
	march_rays(job);
	return ray_job_to_lua(job, L);
}

// The same marching on a thread pool worker. The point is not that marching is
// slow -- it is a third of a millisecond -- but that sampling wants several
// times more rays than that, and the frame has better uses for the time. The
// work itself is identical, so this should cost the machine the same and the
// frame much less; that it does is worth re-checking rather than assuming,
// since two threads walking voxel data at once share a cache.
//
// The pool is the client's own, four workers, already started and idle, and
// already used this way by the mesher.
struct CastVoxelRaysTask: public interface::thread_pool::Task
{
	sp_<RayJob> job;

	CastVoxelRaysTask(sp_<RayJob> job): job(job){}

	bool pre(){ return true; }
	bool thread(){ march_rays(*job); return true; }
	bool post(){ job->done = true; return true; }
};

// Starts a job and hands back a handle to ask about later. Takes what
// cast_voxel_rays() takes.
sp_<RayJob> cast_voxel_rays_start(const luabind::object &args, lua_State *L)
{
	sp_<RayJob> job(new RayJob());
	ray_job_from_lua(*job, args);

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	if(buildat_app == nullptr)
		throw Exception("cast_voxel_rays_start(): no app");

	up_<CastVoxelRaysTask> task(new CastVoxelRaysTask(job));
	buildat_app->get_thread_pool()->add_task(std::move(task));
	return job;
}

// Nil until the job has finished, then what cast_voxel_rays() would have
// returned. Asking again after that returns it again: the job holds its
// results until it is dropped.
luabind::object cast_voxel_rays_collect(sp_<RayJob> job, lua_State *L)
{
	if(job == nullptr || !job->done)
		return luabind::object();
	return ray_job_to_lua(*job, L);
}

// Writes an array of numbers into a VectorBuffer as floats, replacing what was
// in it. One call for the lot: WriteFloat() per value is a sandbox call each,
// and a shader array parameter rebuilt per frame is hundreds of them.
//
// The buffer is what Urho sets as a float array shader parameter once it is in
// a Variant, so this is how a script hands a shader an array.
void write_floats(const luabind::object &buffer_o,
		const luabind::object &values_o, lua_State *L)
{
	TRY_GET_SANDBOX_STUFF(buf, 1, VectorBuffer);
	if(buf == nullptr)
		throw Exception("write_floats(): first argument is not a VectorBuffer");
	if(!values_o || luabind::type(values_o) != LUA_TTABLE)
		throw Exception("write_floats(): second argument is not a table");

	buf->Clear();
	for(size_t i = 1;; i++){
		luabind::object v = values_o[i];
		if(!v || luabind::type(v) != LUA_TNUMBER)
			break;
		buf->WriteFloat((float)luabind::object_cast<double>(v));
	}
}

// The same as 16-bit samples, each floored and clamped: a sound a script
// makes is a WriteShort() a sample otherwise, ~2.8 us each in the sandbox,
// which was most of the launch room's synth ([FRAME_WORK]).
void write_shorts(const luabind::object &buffer_o,
		const luabind::object &values_o, lua_State *L)
{
	TRY_GET_SANDBOX_STUFF(buf, 1, VectorBuffer);
	if(buf == nullptr)
		throw Exception("write_shorts(): first argument is not a VectorBuffer");
	if(!values_o || luabind::type(values_o) != LUA_TTABLE)
		throw Exception("write_shorts(): second argument is not a table");

	buf->Clear();
	for(size_t i = 1;; i++){
		luabind::object v = values_o[i];
		if(!v || luabind::type(v) != LUA_TNUMBER)
			break;
		double d = std::floor(luabind::object_cast<double>(v));
		buf->WriteShort((short)(d < -32768 ? -32768 : d > 32767 ? 32767 : d));
	}
}

#define LUABIND_FUNC(name) def("__buildat_" #name, name)

void init_voxel_volume(lua_State *L)
{
	using namespace luabind;
	module(L)[
		class_<pv::Region, bases<>, sp_<pv::Region>>("__buildat_Region")
			.def(constructor<int, int, int, int, int ,int>())
			.property("x0", &region_get_x0)
			.property("y0", &region_get_y0)
			.property("z0", &region_get_z0)
			.property("x1", &region_get_x1)
			.property("y1", &region_get_y1)
			.property("z1", &region_get_z1)
		,
		class_<VoxelInstance>("__buildat_VoxelInstance")
			.def(constructor<uint32_t>())
			.def_readwrite("data", &VoxelInstance::data)
			.property("id", &VoxelInstance::legacy06_id)
			.property("int32", &voxelinstance_get_int32,
					&voxelinstance_set_int32)
			.def("get_id", &VoxelInstance::legacy06_id)
			.def("get_skylight", &VoxelInstance::legacy06_skylight)
			.def("get_lamplight", &VoxelInstance::legacy06_lamplight)
		,
		class_<CommonVolume, bases<>, sp_<CommonVolume>>("__buildat_Volume")
			.def(constructor<const pv::Region &>())
			.def("get_voxel_at", (VoxelInstance (CommonVolume::*)
					(int32_t, int32_t, int32_t) const) &CommonVolume::getVoxelAt)
			.def("set_voxel_at", (bool (CommonVolume::*)
					(int32_t, int32_t, int32_t, VoxelInstance))
					&CommonVolume::setVoxelAt)
			// One plane of a voxel, for a world whose voxels are more than
			// one; get_voxel_at() is the first plane, as it always was.
			// The value is a plain number rather than a VoxelInstance,
			// because a plane other than the first is the game's own bits
			// and the engine's roles are not in it.
			.def("get_plane_at", (uint32_t (CommonVolume::*)
					(uint8_t, int32_t, int32_t, int32_t) const)
					&CommonVolume::plane_at)
			.def("set_plane_at", (void (CommonVolume::*)
					(uint8_t, int32_t, int32_t, int32_t, uint32_t))
					&CommonVolume::set_plane_at)
			.def("get_enclosing_region", &CommonVolume::getEnclosingRegion)
			// The slow, flexible way to build voxel data from Lua: set voxels
			// one at a time and hand the result to set_voxel_geometry().
			// buildat.pack_voxel_volume() is the fast way.
			.def("serialize", &volume_serialize)
		,
		LUABIND_FUNC(deserialize_volume),
		LUABIND_FUNC(deserialize_volume_int32),
		LUABIND_FUNC(deserialize_volume_8bit),
		// An opaque handle: a job in flight, with nothing to call on it.
		// cast_voxel_rays_collect() is what asks whether it has finished.
		class_<RayJob, bases<>, sp_<RayJob>>("__buildat_VoxelRayJob")
		,
		LUABIND_FUNC(cast_voxel_rays),
		LUABIND_FUNC(cast_voxel_rays_start),
		LUABIND_FUNC(cast_voxel_rays_collect),
		LUABIND_FUNC(write_floats),
		LUABIND_FUNC(write_shorts)
	];
}

} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
