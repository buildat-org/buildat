// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [VOXEL_OBJECTS] Voxel grids as objects: a model is a small voxel grid
// (data: the voxel ids of the scene's voxelworld registry, so a model's
// voxel looks as the world's does), saved, sent to the clients and edited
// in its own frame; an object is a replicated scene node with a position
// and any rotation showing a model. Every object of a model shares the
// model's meshes on a client, and its collision boxes on the server.
// Static: the objects stand where they are put (a static RigidBody);
// moving ones are later. One instance per scene.
//
// **The registry**: the scene's voxelworld instance's (voxelworld must have
// one on the scene before create_instance(); an app with no voxel world
// makes one that loads nothing: create_instance, then set_load_points({})).
// The client meshes with voxelworld's registries once it is ready.
//
// **A model's frame**: voxel (x, y, z) fills [x, x+1] x [y, y+1] x [z, z+1]
// of the model, and an object's node is the model's (0, 0, 0) corner: an
// object at p rotated by q has voxel (x, y, z)'s corner at p + q * (x, y,
// z). Voxel id 0 (VOXELTYPEID_UNDEFINED) is empty.
//
// **The data format**. A model is chunked, CHUNK^3 voxels a chunk (the
// last ones on each axis smaller). Saved, in the store "voxel_objects":
//   "<name>/<model>/meta"          "1 sx sy sz CHUNK" (the format first)
//   "<name>/<model>/<cx>,<cy>,<cz>"  a byte 1 (the format), then zstd of:
//       a big-endian uint16 n, n voxel names (a byte of length, the block
//       name, its five bytes segment_x/y/z, rotation_primary/secondary),
//       then w*h*d big-endian uint16, x fastest then y then z: 0 empty,
//       i the i-th name. A name this run does not register reads as empty
//       (a warning says how many).
// Sent: "voxel_objects:model" "1 <model> sx sy sz CHUNK" (a peer gets it
// at join and when a model is created), then for each chunk that has
// anything, and again for each one an edit touched (a voxel on a chunk's
// face resends the neighbour, whose padding has it),
// "voxel_objects:chunk" "<model> cx cy cz rev\n" and a padded voxel volume
// (interface::serialize_volume_compressed: the chunk and a voxel of its
// neighbours each way, light_sky full everywhere, ids of the registry the
// client has), which the client meshes as voxelworld meshes a chunk. rev
// counts the model's commits. "voxel_objects:remove_model" "<model>": gone.
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include "interface/voxel.h"
#include "storage/api.h"
#include <Vector3.h>
#include <Quaternion.h>
#include <functional>

namespace main_context
{
	struct OpaqueSceneReference;
	typedef OpaqueSceneReference* SceneReference;
}

namespace voxel_objects
{
	using main_context::SceneReference;
	using interface::VoxelTypeId;

	static const int CHUNK = 32;
	// A side at most, and voxels a model at most (4 bytes a voxel held)
	static const int MAX_SIDE = 1024;
	static const int64_t MAX_VOXELS = 16 * 1024 * 1024;

	struct Model
	{
		virtual const ss_& name() = 0;
		virtual int size_x() = 0;
		virtual int size_y() = 0;
		virtual int size_z() = 0;
		// True when create_model() read it from the save
		virtual bool loaded() = 0;
		// In the model's own frame; outside it is an error (an exception),
		// as is an id the registry does not have
		virtual VoxelTypeId get_voxel(int x, int y, int z) = 0;
		virtual void set_voxel(int x, int y, int z, VoxelTypeId id) = 0;
		// [KIT_FREE_PREFAB] A voxel with the registry format's param (which
		// way a shape faces) and tint; set_voxel is this with both 0.
		// simplified: the save's format has neither, so a model with a save
		// refuses them (an exception); format 2 with them in a chunk's names
		// is the upgrade
		virtual void set_voxel_state(int x, int y, int z, VoxelTypeId id,
				uint8_t param, uint8_t tint) = 0;
		// FNV-1a over every voxel id (little-endian uint32), x, y then z:
		// what a check compares between a save and a load of one app
		virtual uint32_t content_hash() = 0;
		// How many commits changed it since it was made or loaded
		virtual int rev() = 0;
	};

	struct Instance
	{
		// The save models live in, under name (the format above). Before
		// create_model(): a model is read from the save as it is created
		virtual void set_save(storage::Save *save, const ss_ &name) = 0;

		// A model of 1..MAX_SIDE a side: read from the save when it has
		// one of this name and size (loaded() true), else all empty. A
		// name is letters, digits, '_', '-' and '.'; one made already is
		// an error
		virtual Model* create_model(const ss_ &name, int sx, int sy,
				int sz) = 0;
		virtual Model* get_model(const ss_ &name) = 0;
		// [KIT_FREE_PREFAB] A model and its objects gone, here and on the
		// clients on the scene (their meshes too); what the save has of it
		// stays, and what was edited since the last commit is lost. No such
		// model: nothing
		virtual void remove_model(const ss_ &name) = 0;

		// A node in the scene's root showing the model: replicated, named
		// "voxel_object", its var "voxel_model" the model's name, a static
		// RigidBody with the model's collision boxes. Returns the node's
		// id; move or turn it as any node (the body follows)
		virtual uint create_object(const ss_ &model,
				const Urho3D::Vector3 &position,
				const Urho3D::Quaternion &rotation) = 0;
		virtual void remove_object(uint node_id) = 0;
		virtual size_t num_objects() = 0;

		// What was edited since the last commit: the chunks saved, sent to
		// the clients on the scene, and their boxes rebuilt in every object
		// of the model. Done by the module each tick; call it to have an
		// edit in the collision now
		virtual void commit() = 0;
	};

	struct Interface
	{
		virtual Instance* create_instance(SceneReference scene) = 0;
		virtual void delete_instance(SceneReference scene) = 0;
		virtual Instance* get_instance(SceneReference scene) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(voxel_objects::Interface*)> cb)
	{
		return server->access_module("voxel_objects",
				[&](interface::Module *module){
			cb((voxel_objects::Interface*)module->check_interface());
		});
	}

	inline bool access(interface::Server *server, SceneReference scene,
			std::function<void(voxel_objects::Instance*)> cb)
	{
		return access(server, [&](voxel_objects::Interface *i){
			cb(check(i->get_instance(scene)));
		});
	}
}

// vim: set noet ts=4 sw=4:
