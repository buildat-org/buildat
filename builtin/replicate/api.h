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
}

namespace main_context
{
	struct OpaqueSceneReference;
	typedef OpaqueSceneReference* SceneReference;
}

namespace replicate
{
	namespace magic = Urho3D;
	using interface::Event;
	using main_context::SceneReference;

	typedef size_t PeerId;

	struct PeerJoinedScene: public Event::Private
	{
		PeerId peer;
		SceneReference scene;

		PeerJoinedScene(PeerId peer, SceneReference scene):
			peer(peer), scene(scene){}
	};

	struct PeerLeftScene: public Event::Private
	{
		PeerId peer;
		SceneReference scene;

		PeerLeftScene(PeerId peer, SceneReference scene):
			peer(peer), scene(scene){}
	};

	struct Interface
	{
		// Use scene_ref=nullptr to deassign
		virtual void assign_scene_to_peer(
				main_context::SceneReference scene_ref, PeerId peer) = 0;

		virtual sv_<PeerId> find_peers_on_scene(
				main_context::SceneReference scene_ref) = 0;

		virtual sv_<PeerId> find_peers_that_know_node(
				main_context::SceneReference scene_ref, uint node_id) = 0;

		// Which nodes a peer gets, answered per peer and per node. A node
		// the filter refuses is not created on that peer, and one it stops
		// wanting is removed from it -- the same packet a deleted node sends
		// -- and created again when it is wanted again.
		//
		// What sets one is a world that streams: a client that draws four
		// sections around itself has no use for the fifth, and sending it is
		// the server's memory and the client's bandwidth spent on something
		// nobody will look at. Without a filter every peer on a scene gets
		// every node of it, which is what every scene did before this.
		//
		// The filter is asked during the sync and must not reach back into
		// any module. Pass nullptr to drop it.
		virtual void set_node_filter(main_context::SceneReference scene_ref,
				std::function<bool(PeerId peer, uint node_id)> filter) = 0;

		// Which of a peer's dirty nodes are synced first: the smallest
		// number. A streaming world gives the distance from the peer, so
		// that what it stands in comes before the rest over a slow link
		// ([LOAD_OWN_CHUNK]). Asked during the sync, as the filter is, and
		// as bound by the same rule. Pass nullptr to drop it.
		virtual void set_node_priority(main_context::SceneReference scene_ref,
				std::function<float(PeerId peer, uint node_id)> priority) = 0;

		// Ask the filter about this peer's nodes again: it answers from
		// where the peer is, and nothing else here knows that it moved.
		virtual void refresh_peer_nodes(
				main_context::SceneReference scene_ref, PeerId peer) = 0;

		virtual void emit_after_next_sync(Event event) = 0;

		virtual void sync_node_immediate(
				main_context::SceneReference scene_ref, uint node_id) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(replicate::Interface*)> cb)
	{
		return server->access_module("replicate", [&](interface::Module *module){
			cb((replicate::Interface*)module->check_interface());
		});
	}

	// [ACCESS_ONE_SHOT]: a peer shown a scene, which every game does once
	inline void assign_scene_to_peer(interface::Server *server,
			main_context::SceneReference scene_ref, PeerId peer)
	{
		access(server, [&](Interface *i){
			i->assign_scene_to_peer(scene_ref, peer);
		});
	}
}

// vim: set noet ts=4 sw=4:
