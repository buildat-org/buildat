// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include "client/app.h"
#include "interface/mesh.h"
#include "interface/voxel_volume.h"
#include "interface/thread_pool.h"
#include "interface/os.h"
#include <atomic>
#include <c55/os.h>
#include <tolua++.h>
#include <luabind/luabind.hpp>
#include <luabind/adopt_policy.hpp>
#include <luabind/pointer_traits.hpp>
#include <Scene.h>
#include <CustomGeometry.h>
#include <Image.h>
#include <algorithm>
#include <CollisionShape.h>
#include <RigidBody.h>
#define MODULE "lua_bindings"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::VoxelInstance;
using interface::VoxelVolume;
using interface::VoxelRegistry;
using interface::AtlasRegistry;
using namespace Urho3D;

namespace lua_bindings {

#define GET_TOLUA_STUFF(result_name, index, type){ \
		tolua_Error tolua_err; \
		if(!tolua_isusertype(L, index, #type, 0, &tolua_err)){ \
			tolua_error(L, __PRETTY_FUNCTION__, &tolua_err); \
			throw Exception("Expected \"" #type "\""); \
		} \
} \
	type *result_name = (type*)tolua_tousertype(L, index, 0);
#define TRY_GET_TOLUA_STUFF(result_name, index, type) \
	type *result_name = nullptr; \
	{ \
		tolua_Error tolua_err; \
		if(tolua_isusertype(L, index, #type, 0, &tolua_err)) \
			result_name = (type*)tolua_tousertype(L, index, 0); \
	}

void set_8bit_voxel_geometry(const luabind::object &node_o,
		int w, int h, int d, const luabind::object &buffer_o,
		sp_<VoxelRegistry> voxel_reg, sp_<AtlasRegistry> atlas_reg,
		int ox, int oy, int oz)
{
	lua_State *L = node_o.interpreter();

	GET_TOLUA_STUFF(node, 1, Node);
	TRY_GET_TOLUA_STUFF(buf, 5, const VectorBuffer);

	log_d(MODULE, "set_8bit_voxel_geometry(): node=%p", node);
	log_d(MODULE, "set_8bit_voxel_geometry(): buf=%p", buf);

	ss_ data;
	if(buf == nullptr)
		data = lua_tocppstring(L, 5);
	else
		data.assign((const char*)buf->GetData(), buf->GetSize());

	if((int)data.size() != w * h * d){
		throw Exception(ss_()+"set_8bit_voxel_geometry(): Data size does not match"
				" with dimensions ("+cs(data.size())+" vs. "+cs(w*h*d)+")");
	}

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Context *context = buildat_app->get_scene()->GetContext();

	CustomGeometry *cg = node->GetOrCreateComponent<CustomGeometry>(LOCAL);

	// Where this block's (0, 0, 0) sits in the world, which is what a
	// voxel of uv_scale > 1 takes its slice of the repeat from ([WORLD_UV])
	interface::mesh::set_8bit_voxel_geometry(cg, context, w, h, d, data,
			voxel_reg.get(), atlas_reg.get(),
			PolyVox::Vector3DInt32(ox, oy, oz));

	cg->SetOccluder(true);
	cg->SetCastShadows(true);
}

#ifdef DEBUG_CORE_TIMING
struct ScopeTimer {
	const char *name;
	uint64_t t0;
	ScopeTimer(const char *name = "unknown"): name(name){
		t0 = get_timeofday_us();
	}
	~ScopeTimer(){
		int d = get_timeofday_us() - t0;
		if(d > 3000)
			log_w(MODULE, "%ius (%s)", d, name);
		else
			log_v(MODULE, "%ius (%s)", d, name);
	}
};
#else
struct ScopeTimer {
	ScopeTimer(const char *name = ""){}
};
#endif

// A game gets to set up the materials of each chunk it is shown: which
// technique, which cube map, whatever its own shader wants. Called once the
// geometry exists, on the main thread. See interface/atlas.h for what the
// maps the default setup hands the shader contain.
//
// Takes no arguments: the caller knows which node it asked for, and a Node
// handed over from here would be a raw one, which the sandbox rejects.
static void call_material_cb(const luabind::object &cb)
{
	if(!cb.is_valid() || luabind::type(cb) == LUA_TNIL)
		return;
	try {
		luabind::call_function<void>(cb);
	} catch(luabind::error &e){
		lua_State *L = e.state();
		log_e(MODULE, "Material callback failed: %s", lua_tostring(L, -1));
		lua_pop(L, 1);
	}
}

// A task holds the node weakly: the world it belongs to is free to drop a
// chunk while the task for it is still in the queue, which is what happens
// every time a chunk goes out of view or a world is closed. A raw pointer
// there is a use-after-free in post().
// The horizon map out of the string a caller hands over: three int32 (the
// map's origin) and HORIZON_SIZE^2 int16 heights, as interface/mesh.h lays
// them out. See [PBR_FIT] 2c. Nothing for an empty string.
static up_<interface::mesh::HorizonMap> parse_horizon(const ss_ &horizon_data,
		const char *who)
{
	using interface::mesh::HorizonMap;
	using interface::mesh::HORIZON_SIZE;
	up_<HorizonMap> horizon;
	const size_t want = 3 * sizeof(int32_t) +
			(size_t)HORIZON_SIZE * HORIZON_SIZE * sizeof(int16_t);
	if(horizon_data.size() == want){
		horizon.reset(new HorizonMap());
		const char *p = horizon_data.data();
		memcpy(&horizon->origin_x, p, 4);
		memcpy(&horizon->origin_y, p + 4, 4);
		memcpy(&horizon->origin_z, p + 8, 4);
		memcpy(horizon->heights, p + 12, want - 12);
	} else if(!horizon_data.empty()){
		log_w(MODULE, "%s: horizon of %zu bytes, wanted %zu; ignored",
				who, horizon_data.size(), want);
	}
	return horizon;
}

struct SetVoxelGeometryTask: public interface::thread_pool::Task
{
	WeakPtr<Node> node;
	ss_ data;
	sp_<VoxelRegistry> voxel_reg;
	sp_<AtlasRegistry> atlas_reg;
	bool use_skylight;
	luabind::object material_cb;

	up_<VoxelVolume> volume;
	sm_<uint, interface::mesh::TemporaryGeometry> temp_geoms;
	// The faces of the translucent voxels, which go on a child node of their
	// own so that Urho3D sorts them against the other chunks' translucent
	// geometry rather than against the opaque geometry they are mixed with.
	sm_<uint, interface::mesh::TemporaryGeometry> alpha_geoms;
	// And the faces of the alpha-masked ones -- leaves, a plant -- which go
	// on a child of their own for a plainer reason: they are drawn with the
	// solid world and only need a material whose technique cuts the texture
	// out, and a material is per drawable.
	sm_<uint, interface::mesh::TemporaryGeometry> masked_geoms;

	// The cheap shape the occlusion buffer rasterises instead of the mesh
	// ([CLIENT_FRAME]); built in the worker beside the mesh
	magic::PODVector<magic::Vector3> occluder;

	// The terrain's horizon around the chunk, when the caller has one:
	// three int32 (the map's origin) and HORIZON_SIZE^2 int16 heights, as
	// interface/mesh.h lays them out. See [PBR_FIT] 2c.
	up_<interface::mesh::HorizonMap> horizon;

	// Where the volume's inside (0, 0, 0) sits in the world, which a voxel
	// of uv_scale > 1 takes its slice of the repeat from ([WORLD_UV]); a
	// world's chunk passes it whatever horizon is ([VOXEL_GEOMETRY_ORIGIN])
	up_<PolyVox::Vector3DInt32> uv_origin;

	SetVoxelGeometryTask(Node *node, const ss_ &data,
			sp_<VoxelRegistry> voxel_reg, sp_<AtlasRegistry> atlas_reg,
			bool use_skylight, const luabind::object &material_cb,
			const ss_ &horizon_data, up_<PolyVox::Vector3DInt32> uv_origin):
		node(node), data(data), voxel_reg(voxel_reg), atlas_reg(atlas_reg),
		use_skylight(use_skylight), material_cb(material_cb),
		horizon(parse_horizon(horizon_data, "set_voxel_geometry()")),
		uv_origin(std::move(uv_origin))
	{
		ScopeTimer timer("pre geometry");
		// The deserialise is one shot and cheap beside what follows it;
		// the textures are the part that used to take most of a second
		// and they are pre()'s now, a slice at a time ([CLIENT_FRAME])
		volume = interface::deserialize_volume(data);
	}
	interface::mesh::PreloadCursor preload_cursor;
	// Called repeatedly from the main thread until it returns true: the
	// chunk's voxels have to be in the atlas before a worker meshes it,
	// and building a segment for one seen for the first time is what a
	// join's first chunks were paying for in one go.
	bool pre()
	{
		return interface::mesh::preload_textures_sliced(
				*volume, voxel_reg.get(), atlas_reg.get(), false,
				interface::os::time_us() + 1500, preload_cursor);
	}
	// Called repeatedly from worker thread until returns true: 2 ms at a
	// time, so that the web client's pool, which runs this on the frame's
	// own thread, can stop between them ([WEB_MAIN_THREAD])
	interface::mesh::VoxelGeometryJob job;
	bool thread()
	{
		if(!interface::mesh::generate_voxel_geometry_step(job,
				interface::os::time_us() + 2000,
				temp_geoms, *volume, voxel_reg.get(), atlas_reg.get(),
				use_skylight, &alpha_geoms, &masked_geoms, horizon.get(),
				uv_origin.get()))
			return false;
		slice_check();
		interface::mesh::generate_occluder(occluder, *volume,
				voxel_reg.get());
		return true;
	}
	// BUILDAT_MESH_SLICE_CHECK=1 (util/mesh_slice_check.sh): the chunk
	// meshed again whole and in the smallest slices, each against what
	// the task made; a line every 100 chunks and one for each that differs
	void slice_check()
	{
		static const bool on = [](){
			const char *e = getenv("BUILDAT_MESH_SLICE_CHECK");
			return e && ss_(e) == "1";
		}();
		if(!on)
			return;
		typedef sm_<uint, interface::mesh::TemporaryGeometry> Geoms;
		Geoms wa, wb, wc, sa, sb, sc;
		interface::mesh::generate_voxel_geometry(wa, *volume, voxel_reg.get(),
				atlas_reg.get(), use_skylight, &wb, &wc, horizon.get(),
				uv_origin.get());
		interface::mesh::VoxelGeometryJob small;
		int steps = 1;
		while(!interface::mesh::generate_voxel_geometry_step(small, 0, sa,
				*volume, voxel_reg.get(), atlas_reg.get(), use_skylight, &sb,
				&sc, horizon.get(), uv_origin.get()))
			steps++;
		auto same = [](Geoms &x, Geoms &y){
			if(x.size() != y.size())
				return false;
			for(auto &kv : x){
				auto it = y.find(kv.first);
				if(it == y.end())
					return false;
				auto &u = kv.second.vertex_data, &v = it->second.vertex_data;
				if(u.Size() != v.Size() || (u.Size() != 0 &&
						memcmp(&u[0], &v[0], u.Size() * sizeof u[0]) != 0))
					return false;
			}
			return true;
		};
		static std::atomic<int> n_same(0), n_differ(0);
		const bool ok = same(wa, sa) && same(wb, sb) && same(wc, sc) &&
				same(wa, temp_geoms) && same(wb, alpha_geoms) &&
				same(wc, masked_geoms);
		const int n = ok ? ++n_same : ++n_differ;
		if(!ok || n % 100 == 0)
			log_i(MODULE, "mesh slice check: %i the same, %i differ "
					"(this one %i steps, %s)", (int)n_same, (int)n_differ,
					steps, ok ? "the same" : "DIFFERS");
	}
	// Called repeatedly from main thread until returns true
	bool post()
	{
		ScopeTimer timer("post geometry");
		if(!node)
			return true; // Dropped while this was in the queue
		Context *context = node->GetContext();
		CustomGeometry *cg = node->GetOrCreateComponent<CustomGeometry>(LOCAL);
		interface::mesh::set_voxel_geometry(
				cg, context, temp_geoms, atlas_reg.get());
		// The translucent faces, if the chunk has any. The child is a plain
		// node at the chunk's own origin; it exists only so that its
		// CustomGeometry is a drawable of its own, which is what lets Urho3D
		// put it in the alpha pass and sort it by distance.
		Node *alpha_node = node->GetChild("alpha");
		if(alpha_geoms.empty()){
			if(alpha_node)
				alpha_node->Remove();
		} else {
			if(!alpha_node)
				alpha_node = node->CreateChild("alpha", LOCAL);
			CustomGeometry *acg =
					alpha_node->GetOrCreateComponent<CustomGeometry>(LOCAL);
			interface::mesh::set_voxel_geometry(
					acg, context, alpha_geoms, atlas_reg.get());
			acg->SetOccluder(false);
			acg->SetCastShadows(false);
			acg->SetZoneMask(magic::DEFAULT_ZONEMASK);
		}
		// The masked faces, the same way. These are solid world: they cast
		// shadows like anything else, and whether the shadow has the
		// texture's holes in it is the technique's business.
		Node *masked_node = node->GetChild("masked");
		if(masked_geoms.empty()){
			if(masked_node)
				masked_node->Remove();
		} else {
			if(!masked_node)
				masked_node = node->CreateChild("masked", LOCAL);
			CustomGeometry *mcg =
					masked_node->GetOrCreateComponent<CustomGeometry>(LOCAL);
			interface::mesh::set_voxel_geometry(
					mcg, context, masked_geoms, atlas_reg.get());
			// Not an occluder: an occluder is rasterised as solid, and this
			// one is full of holes
			mcg->SetOccluder(false);
			mcg->SetCastShadows(true);
			mcg->SetZoneMask(magic::DEFAULT_ZONEMASK);
		}
		call_material_cb(material_cb);
		cg->SetOccluder(true);
		// The chunk's silhouette at four voxels to a cell, rather than the
		// mesh's own thousands of triangles ([CLIENT_FRAME]); after
		// set_voxel_geometry(), whose Clear() drops the last one
		cg->SetOcclusionGeometry(occluder);
		cg->SetCastShadows(true);
		// Octree update: Trigger CustomGeometry::OnWorldBoundingBoxUpdate()
		cg->SetZoneMask(magic::DEFAULT_ZONEMASK);
		return true;
	}
};

struct SetVoxelLodGeometryTask: public interface::thread_pool::Task
{
	int lod;
	WeakPtr<Node> node;
	ss_ data;
	sp_<VoxelRegistry> voxel_reg;
	sp_<AtlasRegistry> atlas_reg;
	bool use_skylight;
	luabind::object material_cb;
	// The same map the near path takes ([LOD_LIGHT])
	up_<interface::mesh::HorizonMap> horizon;

	up_<VoxelVolume> lod_volume;
	sm_<uint, interface::mesh::TemporaryGeometry> temp_geoms;

	SetVoxelLodGeometryTask(int lod, Node *node, const ss_ &data,
			sp_<VoxelRegistry> voxel_reg, sp_<AtlasRegistry> atlas_reg,
			bool use_skylight, const luabind::object &material_cb,
			const ss_ &horizon_data):
		lod(lod), node(node), data(data),
		voxel_reg(voxel_reg), atlas_reg(atlas_reg), use_skylight(use_skylight),
		material_cb(material_cb),
		horizon(parse_horizon(horizon_data, "set_voxel_lod_geometry()"))
	{
		ScopeTimer timer("pre lod geometry");
		// NOTE: Do the pre-processing here so that the calling code can
		//       meaasure how long its execution takes
		// NOTE: Could be split in three calls
		up_<VoxelVolume> volume_orig =
				interface::deserialize_volume(data);
		lod_volume = interface::mesh::generate_voxel_lod_volume(
				lod, *volume_orig, voxel_reg.get());
	}
	interface::mesh::PreloadCursor preload_cursor;
	// The far chunks' textures, on the same terms as the near ones'
	bool pre()
	{
		return interface::mesh::preload_textures_sliced(
				*lod_volume, voxel_reg.get(), atlas_reg.get(), true,
				interface::os::time_us() + 1500, preload_cursor);
	}
	// Called repeatedly from worker thread until returns true
	bool thread()
	{
		generate_voxel_lod_geometry(
				lod, temp_geoms, *lod_volume, voxel_reg.get(), atlas_reg.get(),
				use_skylight, horizon.get());
		return true;
	}
	// Called repeatedly from main thread until returns true
	bool post()
	{
		ScopeTimer timer("post lod geometry");
		if(!node)
			return true; // Dropped while this was in the queue
		Context *context = node->GetContext();
		CustomGeometry *cg = node->GetOrCreateComponent<CustomGeometry>(LOCAL);
		interface::mesh::set_voxel_lod_geometry(
				lod, cg, context, temp_geoms, atlas_reg.get());
		call_material_cb(material_cb);
		cg->SetOccluder(true);
		if(lod <= interface::MAX_LOD_WITH_SHADOWS)
			cg->SetCastShadows(true);
		else
			cg->SetCastShadows(false);
		// Octree update: Trigger CustomGeometry::OnWorldBoundingBoxUpdate()
		cg->SetZoneMask(magic::DEFAULT_ZONEMASK);
		return true;
	}
};

// Whether a node's collision shapes are already exactly these boxes.
//
// The shapes themselves are the previous state, so nothing has to be stored
// to answer this: set_voxel_physics_boxes() reuses them in order, so the
// order agrees. What it is for is below -- rebuilding shapes takes the body
// out of the physics world for a frame, and not rebuilding is the only way
// to not do that.
static bool node_already_has_boxes(Node *node,
		const sv_<interface::mesh::TemporaryBox> &boxes)
{
	PODVector<CollisionShape*> shapes;
	node->GetComponents<CollisionShape>(shapes);
	if(shapes.Size() != boxes.size())
		return false;
	for(size_t i = 0; i < boxes.size(); i++){
		if(shapes[i]->GetSize() != boxes[i].size)
			return false;
		if(shapes[i]->GetPosition() != boxes[i].position)
			return false;
	}
	return true;
}

// Set on a chunk node once its collision is actually there: the shapes are
// built and the body is in the physics world. A RigidBody component on its
// own is not that -- it is created two steps earlier -- so anything waiting
// for solid ground has to wait for this. See voxelworld's
// chunk_has_physics() in client_lua.
static const char *PHYSICS_READY_VAR = "buildat_physics_ready";

struct SetPhysicsBoxesTask: public interface::thread_pool::Task
{
	WeakPtr<Node> node;
	ss_ data;
	sp_<VoxelRegistry> voxel_reg;

	up_<VoxelVolume> volume;
	sv_<interface::mesh::TemporaryBox> result_boxes;

	SetPhysicsBoxesTask(Node *node, const ss_ &data,
			sp_<VoxelRegistry> voxel_reg):
		node(node), data(data), voxel_reg(voxel_reg)
	{
		// NOTE: Do the pre-processing here so that the calling code can
		//       meaasure how long its execution takes
		// NOTE: Could be split in two calls
		volume = interface::deserialize_volume(data);
	}
	// Called repeatedly from main thread until returns true
	bool pre()
	{
		return true;
	}
	// Called repeatedly from worker thread until returns true
	bool thread()
	{
		interface::mesh::generate_voxel_physics_boxes(
				result_boxes, *volume, voxel_reg.get());
		return true;
	}
	// Called repeatedly from main thread until returns true
	int post_step = 1;
	bool post()
	{
		ScopeTimer timer(
				post_step == 1 ? "post physics 1" :
		post_step == 2 ? "post_physics 2" :
		post_step == 3 ? "post physics 3" :
		"post physics");
		if(!node)
			return true; // Dropped while this was in the queue
		Context *context = node->GetContext();
		switch(post_step){
		case 1: {
			// The boxes come from VoxelDefinition::physically_solid, so from
			// the voxel ids: a write that changed only a game's own
			// per-voxel fields cannot have changed them. When they are the
			// same as last time there is nothing to do, and skipping is not
			// just an optimisation -- the split below releases the body from
			// the physics world and puts it back a frame or more later, and
			// anything standing on the chunk falls through in between.
			const bool was_live =
					node->GetVar(StringHash(PHYSICS_READY_VAR)).GetBool();
			if(was_live && node_already_has_boxes(node, result_boxes))
				return true;
			node->GetOrCreateComponent<RigidBody>(LOCAL);
			if(was_live){
				// A chunk that already carries someone is rebuilt in one
				// step and never leaves the physics world. The split is
				// what costs a player the floor, and a world that
				// simulates -- water moving, wood dying, rot -- rebuilds
				// the chunk you are standing on all the time, which is why
				// a game like that falls through far more than a static
				// one does. The price is the two times below added
				// together in one frame, on the one chunk that changed.
				set_voxel_physics_boxes(node, context, result_boxes, false);
				RigidBody *body = node->GetComponent<RigidBody>();
				if(body)
					body->OnSetEnabled();
				return true;
			}
			// A chunk with no collision yet has nothing to fall through, so
			// the first build stays split: it is both of those times again,
			// and it happens for every chunk of a world as it loads.
			node->SetVar(StringHash(PHYSICS_READY_VAR), Variant(false));
			break;
		}
		case 2:
#ifdef DEBUG_CORE_TIMING
			log_v(MODULE, "num boxes: %zu", result_boxes.size());
#endif
			// Times on Dell Precision M6800:
			//   0 boxes ->    30us
			//   1 box   ->   136us
			// 160 boxes ->  7625us (hilly forest)
			// 259 boxes -> 18548us (hilly forest, bad case)
			interface::mesh::set_voxel_physics_boxes(
					node, context, result_boxes, false);
			break;
		case 3:
			// Times on Dell Precision M6800:
			//   0 boxes ->    30us
			//   1 box   ->    64us
			// 160 boxes ->  8419us (hilly forest)
			// 259 boxes -> 15704us (hilly forest, bad case)
			{
				RigidBody *body = node->GetComponent<RigidBody>();
				if(body)
					body->OnSetEnabled();
				// Only now is there anything to stand on
				node->SetVar(StringHash(PHYSICS_READY_VAR), Variant(true));
			}
			return true;
		}
		post_step++;
		return false;
	}
};

void set_voxel_geometry(const luabind::object &node_o,
		const luabind::object &buffer_o,
		sp_<VoxelRegistry> voxel_reg, sp_<AtlasRegistry> atlas_reg,
		bool use_skylight, const luabind::object &material_cb,
		const luabind::object &horizon_o, const luabind::object &origin_o)
{
	lua_State *L = node_o.interpreter();
	// The horizon map, a string, or nothing
	ss_ horizon_data;
	if(horizon_o.is_valid() && luabind::type(horizon_o) == LUA_TSTRING)
		horizon_data = luabind::object_cast<ss_>(horizon_o);
	// The origin, {x=, y=, z=}, or nothing
	up_<PolyVox::Vector3DInt32> uv_origin;
	if(origin_o.is_valid() && luabind::type(origin_o) == LUA_TTABLE)
		uv_origin.reset(new PolyVox::Vector3DInt32(
				luabind::object_cast<int>(origin_o["x"]),
				luabind::object_cast<int>(origin_o["y"]),
				luabind::object_cast<int>(origin_o["z"])));

	GET_TOLUA_STUFF(node, 1, Node);
	log_d(MODULE, "set_voxel_geometry(): node=%p", node);

	TRY_GET_TOLUA_STUFF(buf, 2, const VectorBuffer);
	log_d(MODULE, "set_voxel_geometry(): buf=%p", buf);

	ss_ data;
	if(buf == nullptr)
		data = lua_checkcppstring(L, 2);
	else
		data.assign((const char*)buf->GetData(), buf->GetSize());

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);

	up_<SetVoxelGeometryTask> task(new SetVoxelGeometryTask(
			node, data, voxel_reg, atlas_reg, use_skylight, material_cb,
			horizon_data, std::move(uv_origin)));

	auto *thread_pool = buildat_app->get_thread_pool();

	thread_pool->add_task(std::move(task));
}

void set_voxel_lod_geometry(int lod, const luabind::object &node_o,
		const luabind::object &buffer_o,
		sp_<VoxelRegistry> voxel_reg, sp_<AtlasRegistry> atlas_reg,
		bool use_skylight, const luabind::object &material_cb,
		const luabind::object &horizon_o)
{
	lua_State *L = node_o.interpreter();
	ss_ horizon_data;
	if(horizon_o.is_valid() && luabind::type(horizon_o) == LUA_TSTRING)
		horizon_data = luabind::object_cast<ss_>(horizon_o);

	GET_TOLUA_STUFF(node, 2, Node);
	TRY_GET_TOLUA_STUFF(buf, 3, const VectorBuffer);

	log_d(MODULE, "set_voxel_lod_geometry(): lod=%i", lod);
	log_d(MODULE, "set_voxel_lod_geometry(): node=%p", node);
	log_d(MODULE, "set_voxel_lod_geometry(): buf=%p", buf);

	ss_ data;
	if(buf == nullptr)
		data = lua_tocppstring(L, 2);
	else
		data.assign((const char*)buf->GetData(), buf->GetSize());

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);

	up_<SetVoxelLodGeometryTask> task(new SetVoxelLodGeometryTask(
			lod, node, data, voxel_reg, atlas_reg, use_skylight, material_cb,
			horizon_data));

	auto *thread_pool = buildat_app->get_thread_pool();

	thread_pool->add_task(std::move(task));
}

void clear_voxel_geometry(const luabind::object &node_o)
{
	lua_State *L = node_o.interpreter();

	GET_TOLUA_STUFF(node, 1, Node);

	log_d(MODULE, "clear_voxel_geometry(): node=%p", node);

	CustomGeometry *cg = node->GetComponent<CustomGeometry>();
	if(cg)
		node->RemoveComponent(cg);
	// And the translucent geometry's own node, if the chunk had any
	Node *alpha_node = node->GetChild("alpha");
	if(alpha_node)
		alpha_node->Remove();
	Node *masked_node = node->GetChild("masked");
	if(masked_node)
		masked_node->Remove();
}

void set_voxel_physics_boxes(const luabind::object &node_o,
		const luabind::object &buffer_o, sp_<VoxelRegistry> voxel_reg)
{
	lua_State *L = node_o.interpreter();

	GET_TOLUA_STUFF(node, 1, Node);
	TRY_GET_TOLUA_STUFF(buf, 2, const VectorBuffer);

	log_d(MODULE, "set_voxel_physics_boxes(): node=%p", node);
	log_d(MODULE, "set_voxel_physics_boxes(): buf=%p", buf);

	ss_ data;
	if(buf == nullptr)
		data = lua_tocppstring(L, 2);
	else
		data.assign((const char*)buf->GetData(), buf->GetSize());

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);

	up_<SetPhysicsBoxesTask> task(new SetPhysicsBoxesTask(
			node, data, voxel_reg
			));

	auto *thread_pool = buildat_app->get_thread_pool();

	thread_pool->add_task(std::move(task));
}

void clear_voxel_physics_boxes(const luabind::object &node_o)
{
	lua_State *L = node_o.interpreter();

	GET_TOLUA_STUFF(node, 1, Node);

	log_d(MODULE, "clear_voxel_physics_boxes(): node=%p", node);

	RigidBody *body = node->GetComponent<RigidBody>();
	if(body)
		node->RemoveComponent(body);
	node->SetVar(StringHash(PHYSICS_READY_VAR), Variant(false));

	PODVector<CollisionShape*> previous_shapes;
	node->GetComponents<CollisionShape>(previous_shapes);
	for(size_t i = 0; i < previous_shapes.Size(); i++)
		node->RemoveComponent(previous_shapes[i]);
}

#define LUABIND_FUNC(name) def("__buildat_" #name, name)

// column_heights(buffer, voxel_reg) -> a string of w*d int16, the local y
// of each column's highest solid non-cutout voxel, HORIZON_NONE for none;
// [z][x] over the chunk's inside. What a horizon map is built from; see
// interface/mesh.h and [PBR_FIT] 2c.
ss_ column_heights(const luabind::object &buffer_o,
		sp_<VoxelRegistry> voxel_reg)
{
	lua_State *L = buffer_o.interpreter();
	TRY_GET_TOLUA_STUFF(buf, 1, const VectorBuffer);
	ss_ data;
	if(buf == nullptr)
		data = lua_checkcppstring(L, 1);
	else
		data.assign((const char*)buf->GetData(), buf->GetSize());
	up_<VoxelVolume> volume = interface::deserialize_volume(data);
	sv_<int16_t> h = interface::mesh::column_heights(*volume, voxel_reg.get());
	return ss_((const char*)h.data(), h.size() * sizeof(int16_t));
}

// horizon_merge(cys, heights, chunk) -> a string of chunk*chunk int16: a
// chunk column's tops out of its chunks' column_heights(), each the
// highest of them in world rows (cy * chunk + its own), HORIZON_NONE where
// none has one. `cys` is the chunks' y as int16, `heights` their
// column_heights() strings in the same order. voxelworld's Lua did this,
// and a column's 1024 reads were most of a remesh's Lua in a browser
// ([WEB_MAIN_THREAD]).
ss_ horizon_merge(const ss_ &cys, const ss_ &heights, int chunk)
{
	if(chunk < 1 || chunk > 256)
		throw Exception("horizon_merge: chunk out of range");
	const size_t n = (size_t)chunk * chunk;
	const size_t k = cys.size() / 2;
	if(cys.size() % 2 != 0 || heights.size() != k * n * 2)
		throw Exception("horizon_merge: the sizes do not add up");
	auto at = [](const ss_ &s, size_t i){
		int16_t v;
		memcpy(&v, s.data() + i * 2, 2);
		return v;
	};
	sv_<int16_t> out(n, interface::mesh::HORIZON_NONE);
	for(size_t c = 0; c < k; c++){
		const int cy = at(cys, c);
		for(size_t i = 0; i < n; i++){
			const int16_t h = at(heights, c * n + i);
			if(h == interface::mesh::HORIZON_NONE)
				continue;
			const int w = cy * chunk + h;
			if(w > out[i])
				out[i] = (int16_t)w;
		}
	}
	return ss_((const char*)out.data(), n * sizeof(int16_t));
}

// set_cell_geometry(node, cells, size, r, g, b, a, v): a volume of cubic cells
// as the node's CustomGeometry, one geometry, a face wherever a cell's
// neighbour is empty -- a face's normal, the colour (r, g, b, a) and the
// texture coordinate (row, v) on each vertex, one winding. `cells` is a
// flat list of key, row: a key is (x+128) + (y+128)*256 + (z+128)*65536,
// each of x, y and z from -128 to 127, and a cell is `size` across. The
// floorplanner's voxel volumes; in C++ because a face at a time from Lua
// was 24 sandbox calls, a quarter of a second for 4000 voxels natively and
// a freeze on the web (user, 2026-09-30).
void set_cell_geometry(const luabind::object &node_o,
		const luabind::object &cells, float size, float r, float g, float b,
		float a, float tv)
{
	lua_State *L = node_o.interpreter();
	GET_TOLUA_STUFF(node, 1, Node);
	std::unordered_map<int, int> row_of;
	sv_<int> flat;
	for(luabind::iterator it(cells), end; it != end; ++it)
		flat.push_back(luabind::object_cast<int>(*it));
	for(size_t i = 0; i + 1 < flat.size(); i += 2)
		row_of[flat[i]] = flat[i + 1];
	CustomGeometry *cg = node->GetOrCreateComponent<CustomGeometry>(LOCAL);
	cg->SetNumGeometries(1);
	cg->BeginGeometry(0, TRIANGLE_LIST);
	static const int F[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0},
			{0, 0, 1}, {0, 0, -1}};
	const Color col(r, g, b, a);
	for(const auto &pair : row_of){
		const int key = pair.first;
		const int x = key % 256 - 128, y = (key / 256) % 256 - 128,
				z = key / 65536 - 128;
		const Vector2 uv((float)pair.second, tv);
		for(const auto &f : F){
			const int nx = x + f[0], ny = y + f[1], nz = z + f[2];
			if(nx >= -128 && nx <= 127 && ny >= -128 && ny <= 127 &&
					nz >= -128 && nz <= 127 && row_of.count(
					(nx + 128) + (ny + 128) * 256 + (nz + 128) * 65536))
				continue;
			const Vector3 n((float)f[0], (float)f[1], (float)f[2]);
			// The face's middle, and two axes across it
			const Vector3 c((x + 0.5f + f[0] * 0.5f), (y + 0.5f + f[1] * 0.5f),
					(z + 0.5f + f[2] * 0.5f));
			Vector3 u = f[0] != 0 ? Vector3(0, 1, 0) : Vector3(1, 0, 0);
			Vector3 v = f[2] != 0 ? Vector3(0, 1, 0) : Vector3(0, 0, 1);
			if(f[1] != 0){
				u = Vector3(1, 0, 0);
				v = Vector3(0, 0, 1);
			}
			auto C = [&](float s, float t){
				return (c + (u * s + v * t) * 0.5f) * size;
			};
			const Vector3 q[4] = {C(-1, -1), C(1, -1), C(1, 1), C(-1, 1)};
			const int tris[2][3] = {{0, 1, 2}, {0, 2, 3}};
			for(const auto &t : tris){
				Vector3 pa = q[t[0]], pb = q[t[1]], pc = q[t[2]];
				// Wound to face the normal, as editor.lua's tri() winds
				if((pb - pa).CrossProduct(pc - pa).DotProduct(n) < 0)
					std::swap(pb, pc);
				for(const Vector3 &p : {pa, pb, pc}){
					cg->DefineVertex(p);
					cg->DefineNormal(n);
					cg->DefineColor(col);
					cg->DefineTexCoord(uv);
				}
			}
		}
	}
	cg->Commit();
}

// set_triangle_geometry(node, verts): a triangle list as the node's
// CustomGeometry, one geometry: `verts` is a flat list of 12 numbers a
// vertex -- position, normal, colour (r, g, b, a) and texture coordinate --
// three vertices a triangle. What the floorplanner builds its walls and
// objects into, in Lua, and hands over at once: a triangle defined a call
// at a time from the sandbox was a dozen calls, and a window 10 to 20 ms
// natively, several times that on the web (user, 2026-09-30).
void set_triangle_geometry(const luabind::object &node_o,
		const luabind::object &verts)
{
	lua_State *L = node_o.interpreter();
	GET_TOLUA_STUFF(node, 1, Node);
	CustomGeometry *cg = node->GetOrCreateComponent<CustomGeometry>(LOCAL);
	cg->SetNumGeometries(1);
	cg->BeginGeometry(0, TRIANGLE_LIST);
	verts.push(L);
	const int t = lua_gettop(L);
	const size_t n = lua_objlen(L, t) / 12;
	float f[12];
	for(size_t i = 0; i < n; i++){
		for(int k = 0; k < 12; k++){
			lua_rawgeti(L, t, (int)(i * 12 + k + 1));
			f[k] = (float)lua_tonumber(L, -1);
			lua_pop(L, 1);
		}
		cg->DefineVertex(Vector3(f[0], f[1], f[2]));
		cg->DefineNormal(Vector3(f[3], f[4], f[5]));
		cg->DefineColor(Color(f[6], f[7], f[8], f[9]));
		cg->DefineTexCoord(Vector2(f[10], f[11]));
	}
	lua_pop(L, 1);
	cg->Commit();
}

// set_line_geometry(node, verts): a line list as the node's CustomGeometry,
// one geometry: `verts` is a flat list of 7 numbers a vertex -- position and
// colour (r, g, b, a) -- two vertices a line. What the floorplanner's plan
// view draws its lines that only change with the plan or the zoom into,
// once, where the debug renderer took two sandboxed vectors a line a frame
// (user, 2026-10-01: panning a big plan in Firefox was slow).
void set_line_geometry(const luabind::object &node_o,
		const luabind::object &verts)
{
	lua_State *L = node_o.interpreter();
	GET_TOLUA_STUFF(node, 1, Node);
	CustomGeometry *cg = node->GetOrCreateComponent<CustomGeometry>(LOCAL);
	cg->SetNumGeometries(1);
	cg->BeginGeometry(0, LINE_LIST);
	verts.push(L);
	const int t = lua_gettop(L);
	const size_t n = lua_objlen(L, t) / 7;
	float f[7];
	for(size_t i = 0; i < n; i++){
		for(int k = 0; k < 7; k++){
			lua_rawgeti(L, t, (int)(i * 7 + k + 1));
			f[k] = (float)lua_tonumber(L, -1);
			lua_pop(L, 1);
		}
		cg->DefineVertex(Vector3(f[0], f[1], f[2]));
		cg->DefineColor(Color(f[3], f[4], f[5], f[6]));
		// **A texture coordinate, though no line has a texture** (user,
		// 2026-10-01: the grid was missing in Firefox): Urho3D's Unlit
		// vertex shader reads one whatever its defines, and without one
		// in this buffer the attribute was left on whatever buffer was
		// bound before. Firefox refuses such a draw outright when that
		// one is shorter ("Vertex fetch requires 52, but attribs only
		// supply 6"), so whether a line list showed went by draw order.
		cg->DefineTexCoord(Vector2(0.f, 0.f));
	}
	lua_pop(L, 1);
	cg->Commit();
}

// set_image_data(image, values): all of an Image's bytes from a flat list
// of numbers from 0 to 1, components at a time, rows from the top. One
// call for what was a SetPixel and a Color a texel from the sandbox: the
// floorplanner's room table, 2048 texels, was 20 to 60 ms of that on the
// web each time the daylight moved (user, 2026-10-02). The list is the
// image's size exactly; a value that is not a number from 0 to 1 is
// clamped, and one that is not a number at all is 0.
void set_image_data(const luabind::object &image_o,
		const luabind::object &values)
{
	lua_State *L = image_o.interpreter();
	GET_TOLUA_STUFF(image, 1, Image);
	if(image->IsCompressed() || image->GetDepth() != 1)
		throw Exception("set_image_data: a compressed or 3D image");
	const size_t n = (size_t)image->GetWidth() * image->GetHeight() *
			image->GetComponents();
	values.push(L);
	const int t = lua_gettop(L);
	if(!lua_istable(L, t) || lua_objlen(L, t) != n){
		lua_pop(L, 1);
		throw Exception("set_image_data: the list is not the image's size");
	}
	unsigned char *d = image->GetData();
	for(size_t i = 0; i < n; i++){
		lua_rawgeti(L, t, (int)(i + 1));
		const double v = lua_tonumber(L, -1);
		lua_pop(L, 1);
		d[i] = v > 0.0 ? (v < 1.0 ? (unsigned char)(v * 255.0 + 0.5) : 255) : 0;
	}
	lua_pop(L, 1);
}

// set_quad_geometry(node, quads) -> {tile, ...}: a model's quads -- a Lua
// list of {tile=, p={12 numbers}, uv={8 numbers}} -- as the node's
// CustomGeometry, one geometry per distinct tile in ascending tile order
// (the answer says which tile each geometry is), both windings of every
// quad. In C++ because a VoxeLibre skeleton was 250 ms of sandbox calls
// built quad by quad from Lua, and a posed model is one build per frame
// ([OBJECT_MESH] step 1).
luabind::object set_quad_geometry(const luabind::object &node_o,
		const luabind::object &quads)
{
	lua_State *L = node_o.interpreter();
	GET_TOLUA_STUFF(node, 1, Node);
	struct Quad { int tile; float p[12]; float uv[8]; };
	sv_<Quad> all;
	for(luabind::iterator it(quads), end; it != end; ++it){
		luabind::object q = *it;
		Quad quad;
		quad.tile = luabind::object_cast<int>(q["tile"]);
		luabind::object p = q["p"], uv = q["uv"];
		for(int i = 0; i < 12; i++)
			quad.p[i] = luabind::object_cast<float>(p[i + 1]);
		for(int i = 0; i < 8; i++)
			quad.uv[i] = luabind::object_cast<float>(uv[i + 1]);
		all.push_back(quad);
	}
	sv_<int> tiles;
	for(const Quad &q : all)
		if(std::find(tiles.begin(), tiles.end(), q.tile) == tiles.end())
			tiles.push_back(q.tile);
	std::sort(tiles.begin(), tiles.end());
	CustomGeometry *cg = node->GetOrCreateComponent<CustomGeometry>(LOCAL);
	cg->SetNumGeometries(tiles.size());
	static const int corners[12] = {0, 1, 2, 0, 2, 3, 0, 2, 1, 0, 3, 2};
	for(size_t g = 0; g < tiles.size(); g++){
		cg->BeginGeometry(g, TRIANGLE_LIST);
		for(const Quad &q : all){
			if(q.tile != tiles[g])
				continue;
			// The face's normal, for a lit technique (the held item under
			// pbr, [WIELD_MESH]); the back winding's is the other way
			Vector3 p0(q.p[0], q.p[1], q.p[2]);
			Vector3 n = (Vector3(q.p[3], q.p[4], q.p[5]) - p0).CrossProduct(
					Vector3(q.p[6], q.p[7], q.p[8]) - p0).Normalized();
			for(int i = 0; i < 12; i++){
				int c = corners[i];
				cg->DefineVertex(Vector3(q.p[c * 3], q.p[c * 3 + 1],
						q.p[c * 3 + 2]));
				cg->DefineNormal(i < 6 ? n : -n);
				cg->DefineTexCoord(Vector2(q.uv[c * 2], q.uv[c * 2 + 1]));
			}
		}
	}
	cg->Commit();
	cg->SetCastShadows(false);
	luabind::object out = luabind::newtable(L);
	for(size_t i = 0; i < tiles.size(); i++)
		out[i + 1] = tiles[i];
	return out;
}

// set_mesh_bounce(r, g, b): the unpacked mesher's bounce colour; see
// interface/mesh.h set_bounce_color()
void set_mesh_bounce(float r, float g, float b)
{
	interface::mesh::set_bounce_color(r, g, b);
}

// set_mesh_alpha_nibbles(on): see interface/mesh.h set_alpha_nibbles()
void set_mesh_alpha_nibbles(bool on)
{
	interface::mesh::set_alpha_nibbles(on);
}

void init_mesh(lua_State *L)
{
	using namespace luabind;
	module(L)[
			LUABIND_FUNC(set_quad_geometry),
			LUABIND_FUNC(set_cell_geometry),
			LUABIND_FUNC(set_triangle_geometry),
			LUABIND_FUNC(set_line_geometry),
			LUABIND_FUNC(set_image_data),
			LUABIND_FUNC(column_heights),
			LUABIND_FUNC(horizon_merge),
			LUABIND_FUNC(set_mesh_bounce),
			LUABIND_FUNC(set_mesh_alpha_nibbles),
			LUABIND_FUNC(set_8bit_voxel_geometry),
			LUABIND_FUNC(set_voxel_geometry),
			LUABIND_FUNC(set_voxel_lod_geometry),
			LUABIND_FUNC(clear_voxel_geometry),
			LUABIND_FUNC(set_voxel_physics_boxes),
			LUABIND_FUNC(clear_voxel_physics_boxes)
	];
}

} // namespace lua_bindingss


// vim: set noet ts=4 sw=4:
