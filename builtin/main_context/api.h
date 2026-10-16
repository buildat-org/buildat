// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include <functional>

namespace Urho3D
{
	class Context;
	class Scene;
	class StringHash;
}

namespace main_context
{
	namespace magic = Urho3D;
	using interface::Event;

	struct OpaqueSceneReference;
	typedef OpaqueSceneReference* SceneReference;

	struct SceneDeleted: public interface::Event::Private
	{
		SceneReference scene;

		SceneDeleted(SceneReference scene): scene(scene){}
	};

	struct Interface
	{
		// NOTE: Do not store Urho3D::SharedPtr<>s or any other kinds of pointers
		//       to Urho3D objects because accessing and deleting them is not
		//       thread-safe.

		virtual magic::Context* get_context() = 0;
		virtual magic::Scene* find_scene(SceneReference ref) = 0;
		virtual magic::Scene* check_scene(SceneReference ref) = 0;

		virtual SceneReference create_scene() = 0;
		virtual void delete_scene(SceneReference ref) = 0;

		virtual void sub_magic_event(
				const magic::StringHash &event_type,
				const Event::Type &buildat_event_type) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(main_context::Interface*)> cb)
	{
		return server->access_module("main_context", [&](interface::Module *module){
			cb((main_context::Interface*)module->check_interface());
		});
	}

	// [ACCESS_ONE_SHOT]: a scene's own, under main_context's lock (its
	// nodes are main_context's thread's); throws if there is no such scene
	inline bool access(interface::Server *server, SceneReference scene_ref,
			std::function<void(magic::Scene*)> cb)
	{
		return access(server, [&](Interface *i){
			cb(i->check_scene(scene_ref));
		});
	}
	inline SceneReference create_scene(interface::Server *server)
	{
		SceneReference ref = nullptr;
		access(server, [&](Interface *i){ ref = i->create_scene(); });
		return ref;
	}
}
// vim: set noet ts=4 sw=4:
